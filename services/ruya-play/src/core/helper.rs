//! The unprivileged helper (05 §7.3 steps 2 and 4, RUY-828): everything that reads package bytes
//! runs here, never in the root service.
//!
//! One binary, two modes: the service, and this helper, which the service starts per request (on
//! the console a transient systemd unit, [`crate::core::systemd_run`]; in tests and on Windows
//! [`InProcessHelper`], which calls [`run`] directly). A request ([`Request`]) is one of:
//!
//! - **`inspect`**: open the package, read the listing and the four root files once
//!   ([`ReadOnce`]), run `ruya_play_trust::inspect` (the request's developer mode and image
//!   blocklist; the helper never sees the key records, so key continuity is the service's), write
//!   the root files as they were read into `<staging>/meta/` and, when `art` is asked for, copy the
//!   art files into `<staging>/src/` (hashed against the table) and vet them into
//!   `<staging>/art/`;
//! - **`install`**: open the package again, check that its root files still have the SHA-256s the
//!   service verified (`source.changed`), `validate` it, unpack into `<staging>/tree/`, re-walk
//!   the tree against the table and vet the art from the staged copy into `<staging>/art/`.
//!
//! The helper answers with JSON Lines on its output ([`Line`]): `progress`, `problem` and one
//! final `result`. The service reads them with a [`Session`], which treats every line as untrusted
//! input: a line over [`MAX_LINE_BYTES`], more than [`MAX_PROBLEMS`] problems, anything that is not
//! one of the three shapes, a line after the result, no result, a non-zero exit or a stop without a
//! cancel all end the job `failed` with `helper.failed`. Whatever the helper says, the service then
//! re-walks and re-hashes the staged tree itself before anything is recorded.

use crate::core::art::{self, ArtInput};
use crate::core::codes;
use crate::core::deps::{ArtVetter, Exit, Helper, Hooks, OpenError, Opener, Step};
use crate::core::staging::{self, Dir};
use crate::core::status::Phase;
use crate::core::unpack::{self, staging_problem, Control, Stop};
use ruya_play_format::hex;
use ruya_play_format::limits::ROOT_FILES;
use ruya_play_format::{validate, EntryKind, FileEntry, Problem, Source, ValidateOptions};
use ruya_play_trust::revocation::MAX_BLOCKLIST_BYTES;
use ruya_play_trust::{
    inspect, select_blocklist, Context, Inspection, ListCheck, MemoryTrustStore, ReadOnce,
    StoreKeys, TrustStore,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::cell::Cell;
use std::collections::{BTreeMap, HashSet};
use std::io::{self, Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

/// The longest line the service reads from the helper (without its newline).
pub const MAX_LINE_BYTES: usize = 64 * 1024;
/// The most `problem` lines one helper run may send (the format's 100, the art slots and slack).
pub const MAX_PROBLEMS: usize = 200;
/// The largest request the helper reads (the image blocklist travels hex-encoded).
pub const MAX_REQUEST_BYTES: usize = 2 * MAX_BLOCKLIST_BYTES + 64 * 1024;
/// A problem's path and message are cut to this many bytes on the wire.
pub const MAX_TEXT_BYTES: usize = 4096;
/// The most art entries a result may name.
pub const MAX_ART_LINES: usize = 128;

/// What the helper is asked to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    /// Inspect, stage the root files (and the vetted art when asked).
    Inspect,
    /// Unpack, verify and vet the art.
    Install,
}

/// One helper run (serde JSON on the helper's input).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    /// The mode.
    pub mode: Mode,
    /// The job (`job-<n>`) or the inspect (`inspect-<n>`) it belongs to.
    pub job: String,
    /// The package path, as the helper sees it.
    pub source: String,
    /// The folder the helper writes into, as the helper sees it (it exists and is empty).
    pub staging: String,
    /// The service's clock (seconds since 1970), for the blocklist's dates.
    pub now: i64,
    /// The admin's developer mode, so an unsigned package is judged as the service will.
    #[serde(default)]
    pub developer_mode: bool,
    /// The image's blocklist, hex-encoded; absent when it could not be read (every install is
    /// then refused with `blocklist.unavailable`).
    #[serde(default)]
    pub blocklist: Option<String>,
    /// `inspect`: also stage and vet the art.
    #[serde(default)]
    pub art: bool,
    /// `install`: validate with the official rules (the service decided the tier).
    #[serde(default)]
    pub official: bool,
    /// `install`: the SHA-256 of each root file the service verified; a root file absent here
    /// must be absent from the package.
    #[serde(default)]
    pub expect: BTreeMap<String, String>,
}

impl Request {
    /// The request as one JSON text.
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }

    /// Parse a request (bounded by the caller).
    pub fn parse(bytes: &[u8]) -> Result<Request, String> {
        serde_json::from_slice(bytes).map_err(|e| format!("the request is not valid ({e})"))
    }
}

/// How a helper run ended, in its `result` line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Finish {
    /// Done; for `install` the tree and the art are staged.
    Ok,
    /// Refused; the `problem` lines say why.
    Refused,
    /// The cancel flag was set.
    Cancelled,
    /// Nothing is at the source path.
    Missing,
}

/// The vetted files of one art slot, relative to `<staging>/art/`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ArtLine {
    /// `icon`, `screenshot-0`, ...
    pub slot: String,
    /// The language of a per-language logo.
    #[serde(default)]
    pub lang: Option<String>,
    /// The canonical files written (`icon-512.webp`, `logo-0/logo-512.webp`).
    pub files: Vec<String>,
}

/// One line of the helper's output.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub enum Line {
    /// Progress in a phase: `staging` counts payload bytes, `verifying` and `vetting-art` steps.
    Progress {
        /// `staging`, `verifying` or `vetting-art`.
        phase: String,
        /// Done so far.
        done: u64,
        /// In all.
        total: u64,
    },
    /// One problem (05 §4.5, §9.2 and the importer's codes).
    Problem {
        /// The code.
        code: String,
        /// The JSON pointer or package path.
        path: String,
        /// For logs.
        message: String,
    },
    /// The last line.
    Result {
        /// How it ended.
        outcome: Finish,
        /// The vetted art (`ok` only).
        #[serde(default)]
        art: Vec<ArtLine>,
        /// `inspect`: the art refuses the package (a broken icon or hero).
        #[serde(default)]
        art_refuses: bool,
    },
}

/// A `progress` line the service accepted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Progress {
    /// The phase.
    pub phase: Phase,
    /// Done so far (never above `total`).
    pub done: u64,
    /// In all.
    pub total: u64,
}

/// How a helper run ended, as the service reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Ending {
    /// Nothing is at the source path.
    Missing,
    /// The package was refused with these problems.
    Refused(Vec<Problem>),
    /// Cancelled, as asked.
    Cancelled,
    /// Done.
    Ok {
        /// Problems that do not refuse (art slots that were dropped).
        problems: Vec<Problem>,
        /// The vetted art.
        art: Vec<ArtLine>,
        /// `inspect`: the art refuses the package.
        art_refuses: bool,
    },
    /// The helper broke its contract: `helper.failed`.
    Failed(Problem),
}

fn helper_failed(why: impl Into<String>) -> Problem {
    Problem::new(codes::HELPER_FAILED, "", why.into())
}

fn code_ok(code: &str) -> bool {
    !code.is_empty()
        && code.len() <= 64
        && code
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'.' || b == b'_')
}

fn word_ok(word: &str, max: usize, extra: fn(u8) -> bool) -> bool {
    !word.is_empty()
        && word.len() <= max
        && word.bytes().all(|b| b.is_ascii_alphanumeric() || extra(b))
}

/// A relative art path: one or two plain components (`icon-512.webp`, `logo-0/logo-512.webp`).
pub fn art_path_ok(rel: &str) -> bool {
    let parts: Vec<&str> = rel.split('/').collect();
    (1..=2).contains(&parts.len()) && parts.iter().all(|p| staging::component(p).is_ok())
}

/// The service side of one helper run: splits the output into bounded lines and checks each.
#[derive(Debug, Default)]
pub struct Session {
    pending: Vec<u8>,
    problems: Vec<Problem>,
    result: Option<(Finish, Vec<ArtLine>, bool)>,
    broken: Option<String>,
}

impl Session {
    /// A session before the first byte.
    pub fn new() -> Session {
        Session::default()
    }

    /// Take `bytes` of output; `on_progress` gets every accepted `progress` line. Returns false
    /// once the output broke the contract (the helper is then stopped).
    pub fn feed(&mut self, bytes: &[u8], on_progress: &mut dyn FnMut(&Progress)) -> bool {
        if self.broken.is_some() {
            return false;
        }
        let mut rest = bytes;
        while let Some(i) = rest.iter().position(|&b| b == b'\n') {
            let head = &rest[..i];
            if self.pending.len() + head.len() > MAX_LINE_BYTES {
                self.broken = Some(format!("a line is longer than {MAX_LINE_BYTES} bytes"));
                return false;
            }
            self.pending.extend_from_slice(head);
            let line = std::mem::take(&mut self.pending);
            if let Err(why) = self.line(&line, on_progress) {
                self.broken = Some(why);
                return false;
            }
            rest = &rest[i + 1..];
        }
        if self.pending.len() + rest.len() > MAX_LINE_BYTES {
            self.broken = Some(format!("a line is longer than {MAX_LINE_BYTES} bytes"));
            return false;
        }
        self.pending.extend_from_slice(rest);
        true
    }

    fn line(&mut self, bytes: &[u8], on_progress: &mut dyn FnMut(&Progress)) -> Result<(), String> {
        if self.result.is_some() {
            return Err("the helper wrote after its result".into());
        }
        let line: Line = serde_json::from_slice(bytes)
            .map_err(|e| format!("the helper wrote a line that is not its JSON ({e})"))?;
        match line {
            Line::Progress { phase, done, total } => {
                let phase = match Phase::parse(&phase) {
                    Some(p @ (Phase::Staging | Phase::Verifying | Phase::VettingArt)) => p,
                    _ => return Err(format!("the helper reported the phase {phase:?}")),
                };
                if done > total {
                    return Err("the helper reported more done than in all".into());
                }
                on_progress(&Progress { phase, done, total });
            }
            Line::Problem {
                code,
                path,
                message,
            } => {
                if self.problems.len() >= MAX_PROBLEMS {
                    return Err(format!("the helper sent more than {MAX_PROBLEMS} problems"));
                }
                if !code_ok(&code) || path.len() > MAX_TEXT_BYTES || message.len() > MAX_TEXT_BYTES
                {
                    return Err("the helper sent a malformed problem".into());
                }
                self.problems.push(Problem::new(&code, &path, message));
            }
            Line::Result {
                outcome,
                art,
                art_refuses,
            } => {
                if art.len() > MAX_ART_LINES {
                    return Err("the helper named too much art".into());
                }
                for a in &art {
                    let slot_ok = word_ok(&a.slot, 32, |b| b == b'-');
                    let lang_ok = a
                        .lang
                        .as_deref()
                        .map_or(true, |l| word_ok(l, 35, |b| b == b'-'));
                    if !slot_ok || !lang_ok || !a.files.iter().all(|f| art_path_ok(f)) {
                        return Err("the helper named art that is not a plain path".into());
                    }
                }
                self.result = Some((outcome, art, art_refuses));
            }
        }
        Ok(())
    }

    /// How the run ended, given how the process ended and whether the job was cancelled.
    pub fn finish(self, exit: &Exit, cancelled: bool) -> Ending {
        if let Some(why) = self.broken {
            return Ending::Failed(helper_failed(why));
        }
        if !self.pending.is_empty() {
            return Ending::Failed(helper_failed("the helper's output ended inside a line"));
        }
        match exit {
            Exit::Stopped if cancelled => return Ending::Cancelled,
            Exit::Stopped => {
                return Ending::Failed(helper_failed(
                    "the helper was stopped (a memory or time limit)",
                ))
            }
            Exit::Lost(why) => return Ending::Failed(helper_failed(why.clone())),
            Exit::Code(0) => {}
            Exit::Code(c) => {
                return Ending::Failed(helper_failed(format!("the helper exited with {c}")))
            }
        }
        match self.result {
            None => Ending::Failed(helper_failed("the helper ended without a result")),
            Some((Finish::Missing, ..)) => Ending::Missing,
            Some((Finish::Refused, ..)) => Ending::Refused(self.problems),
            Some((Finish::Cancelled, ..)) if cancelled => Ending::Cancelled,
            Some((Finish::Cancelled, ..)) => Ending::Failed(helper_failed(
                "the helper says it was cancelled, but no cancel was asked",
            )),
            Some((Finish::Ok, art, art_refuses)) => Ending::Ok {
                problems: self.problems,
                art,
                art_refuses,
            },
        }
    }
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok())
        .collect()
}

/// SHA-256 of `bytes`, lowercase hex.
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

/// What the helper needs from outside: it opens the package and vets the art; the service never
/// does either.
pub struct HelperDeps {
    /// Opens packages.
    pub opener: Box<dyn Opener>,
    /// Art and video vetting.
    pub art: Box<dyn ArtVetter>,
    /// The pinned store keys (the image's).
    pub store_keys: StoreKeys,
    /// Step observers (tests; the binary passes none).
    pub hooks: Box<dyn Hooks>,
}

thread_local! {
    static INSIDE: Cell<bool> = const { Cell::new(false) };
}

/// True while this thread runs [`run`] (a test's opener asserts it: the service side never opens a
/// package).
pub fn inside() -> bool {
    INSIDE.with(Cell::get)
}

struct Inside(bool);

impl Inside {
    fn enter() -> Inside {
        Inside(INSIDE.with(|c| c.replace(true)))
    }
}

impl Drop for Inside {
    fn drop(&mut self) {
        let was = self.0;
        INSIDE.with(|c| c.set(was));
    }
}

fn cut(text: &str) -> String {
    if text.len() <= MAX_TEXT_BYTES {
        return text.to_string();
    }
    let mut end = MAX_TEXT_BYTES;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_string()
}

/// Writes the helper's lines; after a failed write (the service closed the pipe or refused a line)
/// it writes nothing more and the run stops at its next check.
struct Emitter<'a> {
    out: &'a mut dyn Write,
    broken: bool,
}

impl Emitter<'_> {
    fn send(&mut self, line: &Line) {
        if self.broken {
            return;
        }
        let Ok(mut text) = serde_json::to_string(line) else {
            self.broken = true;
            return;
        };
        text.push('\n');
        if self
            .out
            .write_all(text.as_bytes())
            .and_then(|()| self.out.flush())
            .is_err()
        {
            self.broken = true;
        }
    }

    fn problem(&mut self, p: &Problem) {
        self.send(&Line::Problem {
            code: p.code.clone(),
            path: cut(&p.path),
            message: cut(&p.message),
        });
    }

    fn progress(&mut self, phase: Phase, done: u64, total: u64) {
        self.send(&Line::Progress {
            phase: phase.as_str().to_string(),
            done: done.min(total),
            total,
        });
    }

    fn result(&mut self, outcome: Finish, art: Vec<ArtLine>, art_refuses: bool) {
        self.send(&Line::Result {
            outcome,
            art,
            art_refuses,
        });
    }
}

/// The helper's end of a run: the outcome, the art and (inspect) whether the art refuses.
type Done = (Finish, Vec<ArtLine>, bool);

fn refuse(em: &mut Emitter<'_>, problems: &[Problem]) -> Done {
    for p in problems.iter().take(MAX_PROBLEMS) {
        em.problem(p);
    }
    (Finish::Refused, Vec::new(), false)
}

fn cancelled(cancel: &AtomicBool, em: &Emitter<'_>) -> bool {
    cancel.load(Ordering::SeqCst) || em.broken
}

/// Run one request, writing its lines to `out`. `cancel` is checked before the unpack, after every
/// chunk and every file, after the unpack and before every art slot.
pub fn run(request: &Request, deps: &HelperDeps, out: &mut dyn Write, cancel: &AtomicBool) {
    let _inside = Inside::enter();
    let mut em = Emitter { out, broken: false };
    let (outcome, art, art_refuses) = match request.mode {
        Mode::Inspect => inspect_mode(request, deps, &mut em, cancel),
        Mode::Install => install_mode(request, deps, &mut em, cancel),
    };
    em.result(outcome, art, art_refuses);
}

/// The helper binary's entry: read one request from `input` (at most [`MAX_REQUEST_BYTES`]), run
/// it, and return the process exit code (0 when a result was written, 2 for a bad request).
pub fn serve(
    input: &mut dyn Read,
    out: &mut dyn Write,
    deps: &HelperDeps,
    cancel: &AtomicBool,
) -> i32 {
    let mut bytes = Vec::new();
    if let Err(e) = input
        .take(MAX_REQUEST_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
    {
        eprintln!("ruya-play helper: reading the request failed: {e}");
        return 2;
    }
    if bytes.len() > MAX_REQUEST_BYTES {
        eprintln!("ruya-play helper: the request is larger than {MAX_REQUEST_BYTES} bytes");
        return 2;
    }
    match Request::parse(&bytes) {
        Ok(request) => {
            run(&request, deps, out, cancel);
            0
        }
        Err(e) => {
            eprintln!("ruya-play helper: {e}");
            2
        }
    }
}

fn open<'d>(
    request: &Request,
    deps: &'d HelperDeps,
    em: &mut Emitter<'_>,
) -> Result<Box<dyn Source + 'd>, Done> {
    match deps.opener.open(Path::new(&request.source)) {
        Ok(s) => Ok(s),
        Err(OpenError::Missing) => Err((Finish::Missing, Vec::new(), false)),
        Err(OpenError::Problems(p)) => Err(refuse(em, &p)),
    }
}

/// `ruya_play_trust::inspect` as the helper can run it: the request's developer mode and image
/// blocklist, and no key records (continuity is decided by the service).
fn helper_inspect(
    request: &Request,
    deps: &HelperDeps,
    once: &ReadOnce<'_>,
) -> Result<Inspection, Vec<Problem>> {
    // A list that does not decode is no list: every install is refused (fail closed).
    let image = request.blocklist.as_deref().and_then(unhex);
    let selected = select_blocklist(image.as_deref(), None, &deps.store_keys, request.now);
    let mut trust = MemoryTrustStore::new();
    trust
        .set_developer_mode(request.developer_mode)
        .map_err(|e| vec![e.to_problem()])?;
    let ctx = Context {
        store_keys: &deps.store_keys,
        trust: &trust,
        blocklist: ListCheck::of(&selected),
        runner_hashes: &[],
        verify_content: false,
    };
    inspect(once, &ctx).map_err(|r| r.problems())
}

fn write_meta(staging: &Dir, once: &ReadOnce<'_>) -> Result<(), Problem> {
    let meta = staging
        .create_dir("meta", 0o700)
        .map_err(|e| staging_problem("", &e))?;
    for name in ROOT_FILES {
        let Some(bytes) = once.root(name) else {
            continue;
        };
        meta.create_file(name, unpack::FILE_MODE)
            .and_then(|mut f| f.write_all(&bytes))
            .map_err(|e| staging_problem(name, &e))?;
    }
    Ok(())
}

struct HelperCtl<'a, 'b> {
    job: &'a str,
    cancel: &'a AtomicBool,
    hooks: Option<&'a dyn Hooks>,
    em: &'a mut Emitter<'b>,
    total: u64,
}

impl Control for HelperCtl<'_, '_> {
    fn cancelled(&self) -> bool {
        cancelled(self.cancel, self.em)
    }
    fn progress(&mut self, done: u64) {
        if self.hooks.is_some() {
            self.em.progress(Phase::Staging, done, self.total);
        }
    }
    fn step(&mut self, step: &Step<'_>) {
        if let Some(h) = self.hooks {
            h.step(self.job, step);
        }
    }
}

/// How the art step ended.
enum ArtEnd {
    /// Every slot was vetted: the art, the problems of dropped slots, and whether they refuse.
    Done(Vec<ArtLine>, Vec<Problem>, bool),
    /// A staging fault: only this problem.
    Fault(Problem),
    /// Cancelled before a slot.
    Cancelled,
}

fn relative(files: &[std::path::PathBuf], root: &Path) -> Option<Vec<String>> {
    files
        .iter()
        .map(|f| {
            let rel = f.strip_prefix(root).ok()?;
            let parts: Option<Vec<&str>> =
                rel.components().map(|c| c.as_os_str().to_str()).collect();
            Some(parts?.join("/"))
        })
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn vet_art(
    inputs: &[ArtInput],
    tree: &Dir,
    art_dir: &Dir,
    deps: &HelperDeps,
    job: &str,
    em: &mut Emitter<'_>,
    cancel: &AtomicBool,
    report: bool,
) -> ArtEnd {
    let (mut results, mut problems, mut lines) = (Vec::new(), Vec::new(), Vec::new());
    let n = u64::try_from(inputs.len()).unwrap_or(u64::MAX).max(1);
    if report {
        em.progress(Phase::VettingArt, 0, n);
    }
    for (i, input) in inputs.iter().enumerate() {
        if cancelled(cancel, em) {
            return ArtEnd::Cancelled;
        }
        if report {
            deps.hooks.step(
                job,
                &Step::ArtSlot {
                    slot: input.slot.key(),
                },
            );
        }
        let out_dir = match &input.subdir {
            None => art_dir.path().to_path_buf(),
            Some(sub) => match art_dir.create_dir(sub, unpack::EXEC_MODE) {
                Ok(d) => d.path().to_path_buf(),
                Err(e) => return ArtEnd::Fault(staging_problem("", &e)),
            },
        };
        let staged = match unpack::staged_path(tree, &input.package_path) {
            Ok(p) => p,
            Err(p) => return ArtEnd::Fault(p),
        };
        let Some(result) = deps
            .art
            .vet(&[(input.slot, staged)], &out_dir)
            .into_iter()
            .next()
        else {
            continue;
        };
        if let ruya_play_art::Outcome::Ok { files } = &result.outcome {
            let Some(files) = relative(files, art_dir.path()) else {
                return ArtEnd::Fault(Problem::new(
                    codes::STAGING_CHANGED,
                    &input.package_path,
                    "The art step wrote outside the art folder.",
                ));
            };
            lines.push(ArtLine {
                slot: input.slot.key(),
                lang: input.lang.clone(),
                files,
            });
        }
        problems.extend(art::problem_of(input, &result));
        results.push(result);
        if report {
            let done = u64::try_from(i + 1).unwrap_or(u64::MAX);
            em.progress(Phase::VettingArt, done, n);
        }
    }
    let refuses = art::refuses(&results);
    ArtEnd::Done(lines, problems, refuses)
}

fn inspect_mode(
    request: &Request,
    deps: &HelperDeps,
    em: &mut Emitter<'_>,
    cancel: &AtomicBool,
) -> Done {
    let source = match open(request, deps, em) {
        Ok(s) => s,
        Err(done) => return done,
    };
    let once = ReadOnce::new(&*source);
    let insp = match helper_inspect(request, deps, &once) {
        Ok(i) => i,
        Err(p) => return refuse(em, &p),
    };
    let staging = match Dir::open_root(Path::new(&request.staging)) {
        Ok(d) => d,
        Err(e) => return refuse(em, &[staging_problem("", &e)]),
    };
    if let Err(p) = write_meta(&staging, &once) {
        return refuse(em, &[p]);
    }
    if !request.art {
        return (Finish::Ok, Vec::new(), false);
    }
    // The art files only, copied (and hashed against the table) from the source read once.
    let inputs = art::inputs(&insp.package.manifest.art);
    let wanted: HashSet<&str> = inputs.iter().map(|i| i.package_path.as_str()).collect();
    let files: Vec<FileEntry> = insp
        .package
        .files
        .iter()
        .filter(|f| matches!(f, FileEntry::File { .. }) && wanted.contains(f.path()))
        .cloned()
        .collect();
    let dirs = staging
        .create_dir("src", unpack::EXEC_MODE)
        .and_then(|s| Ok((s, staging.create_dir("art", unpack::EXEC_MODE)?)));
    let (src, art_dir) = match dirs {
        Ok(d) => d,
        Err(e) => return refuse(em, &[staging_problem("", &e)]),
    };
    let mut ctl = HelperCtl {
        job: &request.job,
        cancel,
        hooks: None,
        em,
        total: 0,
    };
    match unpack::unpack(&once, &files, &src, &mut ctl) {
        Ok(_) => {}
        Err(Stop::Cancelled) => return (Finish::Cancelled, Vec::new(), false),
        Err(Stop::Package(p)) | Err(Stop::Staging(p)) => {
            em.problem(&p);
            return (Finish::Ok, Vec::new(), true);
        }
    }
    match vet_art(
        &inputs,
        &src,
        &art_dir,
        deps,
        &request.job,
        em,
        cancel,
        false,
    ) {
        ArtEnd::Cancelled => (Finish::Cancelled, Vec::new(), false),
        ArtEnd::Fault(p) => {
            em.problem(&p);
            (Finish::Ok, Vec::new(), true)
        }
        ArtEnd::Done(lines, problems, refuses) => {
            for p in &problems {
                em.problem(p);
            }
            (Finish::Ok, lines, refuses)
        }
    }
}

/// The root files of `once` against the SHA-256s the service verified.
fn check_roots(once: &ReadOnce<'_>, expect: &BTreeMap<String, String>) -> Result<(), Vec<Problem>> {
    let entries = once.entries()?;
    for name in ROOT_FILES {
        let listed = entries
            .iter()
            .any(|e| e.path == name && e.kind == EntryKind::File);
        let got = if listed {
            let mut bytes = Vec::new();
            match once.open(name).and_then(|mut r| r.read_to_end(&mut bytes)) {
                Ok(_) => Some(sha256_hex(&bytes)),
                Err(_) => Some(String::new()),
            }
        } else {
            None
        };
        if got.as_deref() != expect.get(name).map(String::as_str) {
            return Err(vec![Problem::new(
                codes::SOURCE_CHANGED,
                name,
                "The package changed on its drive between the inspect and the unpack.",
            )]);
        }
    }
    Ok(())
}

fn install_mode(
    request: &Request,
    deps: &HelperDeps,
    em: &mut Emitter<'_>,
    cancel: &AtomicBool,
) -> Done {
    let source = match open(request, deps, em) {
        Ok(s) => s,
        Err(done) => return done,
    };
    let once = ReadOnce::new(&*source);
    if let Err(p) = check_roots(&once, &request.expect) {
        return refuse(em, &p);
    }
    let opts = ValidateOptions {
        verify_content: false,
        official: request.official,
    };
    let package = match validate(&once, &opts) {
        Ok(p) => p,
        Err(p) => return refuse(em, &p),
    };
    let job = request.job.as_str();
    let staging = match Dir::open_root(Path::new(&request.staging)) {
        Ok(d) => d,
        Err(e) => return refuse(em, &[staging_problem("", &e)]),
    };
    let dirs = staging
        .create_dir("tree", unpack::EXEC_MODE)
        .and_then(|t| Ok((t, staging.create_dir("art", unpack::EXEC_MODE)?)));
    let (tree, art_dir) = match dirs {
        Ok(d) => d,
        Err(e) => return refuse(em, &[staging_problem("", &e)]),
    };
    deps.hooks.step(
        job,
        &Step::StagingCreated {
            dir: staging.path(),
        },
    );

    // Unpack.
    let total = package.installed_bytes;
    let unpacked = {
        let mut ctl = HelperCtl {
            job,
            cancel,
            hooks: Some(&*deps.hooks),
            em,
            total,
        };
        match unpack::unpack(&once, &package.files, &tree, &mut ctl) {
            Ok(u) => u,
            Err(Stop::Cancelled) => return (Finish::Cancelled, Vec::new(), false),
            Err(Stop::Package(p)) | Err(Stop::Staging(p)) => return refuse(em, &[p]),
        }
    };
    deps.hooks.step(job, &Step::Unpacked);
    em.progress(Phase::Staging, unpacked.bytes, total);

    // The staged tree against the table.
    em.progress(Phase::Verifying, 0, 1);
    let found = match unpack::walk(&tree) {
        Ok(f) => f,
        Err(e) => return refuse(em, &[staging_problem("", &e)]),
    };
    if let Err(p) = unpack::check_tree(&package.files, &found, unpack::Compare::StructureAndSize) {
        return refuse(em, &[p]);
    }
    em.progress(Phase::Verifying, 1, 1);
    if cancelled(cancel, em) {
        return (Finish::Cancelled, Vec::new(), false);
    }

    // Art, from the staged copy.
    let inputs = art::inputs(&package.manifest.art);
    match vet_art(&inputs, &tree, &art_dir, deps, job, em, cancel, true) {
        ArtEnd::Cancelled => (Finish::Cancelled, Vec::new(), false),
        ArtEnd::Fault(p) => refuse(em, &[p]),
        ArtEnd::Done(_, problems, true) => refuse(em, &problems),
        ArtEnd::Done(lines, problems, false) => {
            if cancelled(cancel, em) {
                return (Finish::Cancelled, Vec::new(), false);
            }
            for p in &problems {
                em.problem(p);
            }
            (Finish::Ok, lines, false)
        }
    }
}

/// The helper in the service's own process: tests and Windows development. It runs [`run`] on the
/// calling thread and forwards its output.
pub struct InProcessHelper {
    deps: HelperDeps,
}

impl InProcessHelper {
    /// A helper over `deps`.
    pub fn new(deps: HelperDeps) -> InProcessHelper {
        InProcessHelper { deps }
    }
}

struct Forward<'a> {
    f: &'a mut dyn FnMut(&[u8]) -> bool,
    refused: bool,
}

impl Write for Forward<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.refused || !(self.f)(buf) {
            self.refused = true;
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "the service stopped reading",
            ));
        }
        Ok(buf.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Helper for InProcessHelper {
    fn run(
        &self,
        request: &Request,
        cancel: &AtomicBool,
        on_output: &mut dyn FnMut(&[u8]) -> bool,
    ) -> Exit {
        let mut out = Forward {
            f: on_output,
            refused: false,
        };
        run(request, &self.deps, &mut out, cancel);
        if out.refused {
            Exit::Stopped
        } else {
            Exit::Code(0)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed_all(lines: &[String]) -> (Session, bool) {
        let mut s = Session::new();
        let mut ok = true;
        for l in lines {
            ok &= s.feed(format!("{l}\n").as_bytes(), &mut |_| {});
        }
        (s, ok)
    }

    fn result_ok() -> String {
        r#"{"type":"result","outcome":"ok"}"#.to_string()
    }

    #[test]
    fn a_line_of_the_limit_is_read_and_one_byte_more_breaks_the_run() {
        // A problem line padded to exactly MAX_LINE_BYTES, then one byte longer.
        let base = r#"{"type":"problem","code":"art.x","path":"","message":""}"#;
        for (extra, ok) in [(0usize, true), (1, false)] {
            let pad = MAX_LINE_BYTES - base.len() + extra;
            let line = format!(
                r#"{{"type":"problem","code":"art.x","path":"","message":""{}}}"#,
                " ".repeat(pad)
            );
            assert_eq!(line.len(), MAX_LINE_BYTES + extra);
            // A message that long is refused by MAX_TEXT_BYTES, so pad with JSON white space.
            let mut s = Session::new();
            assert_eq!(
                s.feed(format!("{line}\n").as_bytes(), &mut |_| {}),
                ok,
                "{extra}"
            );
            if ok {
                assert!(s.feed(format!("{}\n", result_ok()).as_bytes(), &mut |_| {}));
                assert!(matches!(s.finish(&Exit::Code(0), false), Ending::Ok { .. }));
            } else {
                assert!(
                    matches!(s.finish(&Exit::Code(0), false), Ending::Failed(p) if p.code == codes::HELPER_FAILED)
                );
            }
        }
        // Without a newline the bound holds too, and in pieces.
        let mut s = Session::new();
        assert!(s.feed(&vec![b' '; MAX_LINE_BYTES], &mut |_| {}));
        assert!(!s.feed(b" ", &mut |_| {}));
    }

    #[test]
    fn the_problem_count_is_bounded() {
        let p = r#"{"type":"problem","code":"art.x","path":"a","message":"m"}"#.to_string();
        let (mut s, ok) = feed_all(&vec![p.clone(); MAX_PROBLEMS]);
        assert!(ok);
        assert!(s.feed(
            format!("{}\n", r#"{"type":"result","outcome":"refused"}"#).as_bytes(),
            &mut |_| {}
        ));
        assert!(
            matches!(s.finish(&Exit::Code(0), false), Ending::Refused(v) if v.len() == MAX_PROBLEMS)
        );
        let (s, ok) = feed_all(&vec![p; MAX_PROBLEMS + 1]);
        assert!(!ok);
        assert!(
            matches!(s.finish(&Exit::Code(0), false), Ending::Failed(p) if p.code == codes::HELPER_FAILED)
        );
    }

    #[test]
    fn malformed_lines_and_endings_fail() {
        for lines in [
            vec!["not json".to_string()],
            vec![r#"{"type":"shout"}"#.to_string()],
            vec![r#"{"type":"result","outcome":"ok","extra":1}"#.to_string()],
            vec![r#"{"type":"progress","phase":"committing","done":0,"total":1}"#.to_string()],
            vec![r#"{"type":"progress","phase":"staging","done":2,"total":1}"#.to_string()],
            vec![r#"{"type":"problem","code":"NOT A CODE","path":"","message":""}"#.to_string()],
            vec![
                r#"{"type":"result","outcome":"ok","art":[{"slot":"icon","files":["../x"]}]}"#
                    .to_string(),
            ],
            vec![result_ok(), result_ok()],
        ] {
            let (s, _) = feed_all(&lines);
            assert!(
                matches!(s.finish(&Exit::Code(0), false), Ending::Failed(ref p) if p.code == codes::HELPER_FAILED),
                "{lines:?}"
            );
        }
        let ends: [(Vec<String>, Exit, bool); 6] = [
            (vec![], Exit::Code(0), false),
            (vec![result_ok()], Exit::Code(1), false),
            (vec![result_ok()], Exit::Stopped, false),
            (vec![], Exit::Lost("no systemd-run".into()), false),
            (
                vec![r#"{"type":"result","outcome":"cancelled"}"#.to_string()],
                Exit::Code(0),
                false,
            ),
            (vec![], Exit::Code(9), true),
        ];
        for (lines, exit, cancel) in ends {
            let (s, _) = feed_all(&lines);
            assert!(
                matches!(s.finish(&exit, cancel), Ending::Failed(ref p) if p.code == codes::HELPER_FAILED),
                "{lines:?} {exit:?}"
            );
        }
        let mut s = Session::new();
        assert!(s.feed(b"{\"type\":\"result\"", &mut |_| {}));
        assert!(matches!(s.finish(&Exit::Code(0), false), Ending::Failed(_)));
        // Stopped after a cancel is a cancel, whatever was written.
        let (s, _) = feed_all(&[]);
        assert_eq!(s.finish(&Exit::Stopped, true), Ending::Cancelled);
    }

    #[test]
    fn progress_reaches_the_service_in_order() {
        let mut seen = Vec::new();
        let mut s = Session::new();
        let text = "{\"type\":\"progress\",\"phase\":\"staging\",\"done\":1,\"total\":4}\n{\"type\":\"progress\",\"phase\":\"vetting-art\",\"done\":1,\"total\":1}\n";
        // Split in the middle of a line: the session joins the pieces.
        let (a, b) = text.as_bytes().split_at(20);
        assert!(s.feed(a, &mut |p| seen.push(*p)));
        assert!(s.feed(b, &mut |p| seen.push(*p)));
        assert_eq!(
            seen,
            vec![
                Progress {
                    phase: Phase::Staging,
                    done: 1,
                    total: 4
                },
                Progress {
                    phase: Phase::VettingArt,
                    done: 1,
                    total: 1
                },
            ]
        );
    }

    #[test]
    fn requests_round_trip_and_unknown_fields_are_refused() {
        let r = Request {
            mode: Mode::Install,
            job: "job-1".into(),
            source: "/run/media/usb/game.play.zip".into(),
            staging: "/var/lib/ruya-play/staging/job-1".into(),
            now: 5,
            developer_mode: true,
            blocklist: Some(hex(b"serial 1\n")),
            art: false,
            official: true,
            expect: BTreeMap::from([("play.json".to_string(), "ab".to_string())]),
        };
        assert_eq!(Request::parse(r.to_json().as_bytes()), Ok(r));
        assert!(Request::parse(
            br#"{"mode":"install","job":"j","source":"/s","staging":"/t","now":0,"shell":"sh"}"#
        )
        .is_err());
        assert_eq!(unhex(&hex(b"\x00\xffab")), Some(b"\x00\xffab".to_vec()));
        assert_eq!(unhex("abc"), None);
        assert_eq!(unhex("zz"), None);
    }

    #[test]
    fn serve_refuses_a_request_over_the_limit_or_malformed() {
        let deps = HelperDeps {
            opener: Box::new(crate::core::fakes::FnOpener(|_: &Path| {
                Err::<Box<dyn Source>, _>(OpenError::Missing)
            })),
            art: Box::new(crate::core::deps::RuyaPlayArt),
            store_keys: StoreKeys::none(),
            hooks: Box::new(crate::core::deps::NoHooks),
        };
        let flag = AtomicBool::new(false);
        let mut out = Vec::new();
        assert_eq!(serve(&mut &b"{"[..], &mut out, &deps, &flag), 2);
        let big = vec![b' '; MAX_REQUEST_BYTES + 1];
        assert_eq!(serve(&mut &big[..], &mut out, &deps, &flag), 2);
        assert!(out.is_empty());
        // At the limit it is read (white space around a valid request).
        let mut req =
            br#"{"mode":"inspect","job":"inspect-1","source":"/gone","staging":"/s","now":0}"#
                .to_vec();
        req.resize(MAX_REQUEST_BYTES, b' ');
        assert_eq!(serve(&mut &req[..], &mut out, &deps, &flag), 0);
        let mut s = Session::new();
        assert!(s.feed(&out, &mut |_| {}));
        assert_eq!(s.finish(&Exit::Code(0), false), Ending::Missing);
    }
}
