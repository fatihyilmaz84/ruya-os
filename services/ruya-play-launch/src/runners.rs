//! The runners the OS provides (ADR-038): `/app/runners/<Name>/runner.json`, mounted from the
//! image through the `org.ruyaos.Play.Runner` extension point.
//!
//! At most [`MAX_RUNNER_DIRS`] folders are looked at, in name order; a link is not followed; the
//! folder's name means nothing (family and version come from its `runner.json`, read by the one
//! parser, `ruya_play_format::runner::parse_runner`). A runner whose file is missing or invalid,
//! or whose entry is not a regular file, is skipped with a log line and never stops the others.

use crate::os::{join, AppSource, Kind, LaunchOs};
use ruya_play_format::limits::MAX_RUNNER_JSON_BYTES;
use ruya_play_format::problem::Problems;
use ruya_play_format::resolve::SystemRunner;
use ruya_play_format::runner::{self, RunnerJson};

/// Where the system runners are mounted in the sandbox.
pub const RUNNERS_DIR: &str = "/app/runners";
/// The most runner folders looked at.
pub const MAX_RUNNER_DIRS: usize = 32;
/// The file the image build writes at a system runner's root: its runner hash (05 §7.3).
pub use ruya_play_format::runner::HASH_FILE;

/// A runner of the OS, found in the sandbox.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoundRunner {
    /// Its folder, `/app/runners/<Name>`.
    pub root: String,
    /// Its checked `runner.json`.
    pub runner: RunnerJson,
    /// Its `.ruya-runner-hash`, when the folder has a valid one (reported only).
    pub hash: Option<String>,
}

impl FoundRunner {
    /// What `resolve::resolve` takes.
    pub fn system_runner(&self) -> SystemRunner {
        SystemRunner::new(&self.runner.family, &self.runner.version)
    }
}

/// Whether `root/rel` is a regular file. An error asking is logged and counts as no: a runner
/// that cannot be checked is not used (the OS's runner folder, not the player's data).
fn is_file(os: &dyn LaunchOs, root: &str, rel: &str) -> bool {
    match os.kind(root, rel) {
        Ok(kind) => kind == Some(Kind::File),
        Err(e) => {
            os.log(&format!(
                "{}/{rel} cannot be checked ({e})",
                root.trim_end_matches('/')
            ));
            false
        }
    }
}

fn read_hash(os: &dyn LaunchOs, root: &str) -> Option<String> {
    if !is_file(os, root, HASH_FILE) {
        return None;
    }
    let bytes = ruya_play_format::read_within(&AppSource::new(os, root), HASH_FILE, 128)
        .ok()
        .flatten();
    let hash = bytes
        .as_deref()
        .and_then(|b| std::str::from_utf8(b).ok())
        .map(|s| s.strip_suffix('\n').unwrap_or(s))
        .filter(|s| ruya_play_format::table::is_sha256_hex(s));
    if hash.is_none() {
        os.log(&format!("{root}/{HASH_FILE} is not a runner hash; ignored"));
    }
    hash.map(str::to_string)
}

fn read_runner(os: &dyn LaunchOs, root: &str) -> Option<RunnerJson> {
    let file = join(root, runner::FILE_NAME);
    if !is_file(os, root, runner::FILE_NAME) {
        os.log(&format!(
            "{file} is missing or not a regular file; runner skipped"
        ));
        return None;
    }
    let src = AppSource::new(os, root);
    let bytes = match ruya_play_format::read_small(&src, runner::FILE_NAME, MAX_RUNNER_JSON_BYTES) {
        Ok(b) => b,
        Err(p) => {
            os.log(&format!("{file}: {}; runner skipped", p.message));
            return None;
        }
    };
    let mut problems = Problems::new();
    let parsed = runner::parse_runner(&bytes, &file, &mut problems);
    if let Some(p) = problems.finish().first() {
        os.log(&format!("{p}; runner skipped"));
        return None;
    }
    let r = parsed?;
    for (key, rel) in r.entry.paths() {
        if !is_file(os, root, rel) {
            os.log(&format!(
                "{file}: entry {key} ({rel}) is not a regular file; runner skipped"
            ));
            return None;
        }
    }
    Some(r)
}

/// Every usable runner under [`RUNNERS_DIR`] ([`scan_in`]).
pub fn scan(os: &dyn LaunchOs) -> Vec<FoundRunner> {
    scan_in(os, RUNNERS_DIR)
}

/// Every usable runner under `dir`, in folder name order. Two folders with the same family and
/// version keep the first. The launcher scans [`RUNNERS_DIR`]; the library's dry run
/// ([`crate::dry_run`]) scans the image's own folder with the same code.
pub fn scan_in(os: &dyn LaunchOs, dir: &str) -> Vec<FoundRunner> {
    let mut entries = match os.list(dir, "") {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Vec::new(),
        Err(e) => {
            os.log(&format!("{dir} cannot be listed ({e}); no system runners"));
            return Vec::new();
        }
    };
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    let mut out: Vec<FoundRunner> = Vec::new();
    let mut dirs = 0;
    for (name, kind) in entries {
        match kind {
            Kind::Dir => {}
            Kind::Link => {
                os.log(&format!("{dir}/{name} is a link; not followed"));
                continue;
            }
            _ => continue,
        }
        dirs += 1;
        if dirs > MAX_RUNNER_DIRS {
            os.log(&format!(
                "more than {MAX_RUNNER_DIRS} runner folders; {name} and the ones after it are skipped"
            ));
            break;
        }
        let root = join(dir, &name);
        let Some(runner) = read_runner(os, &root) else {
            continue;
        };
        if let Some(first) = out
            .iter()
            .find(|f| f.runner.family == runner.family && f.runner.version == runner.version)
        {
            os.log(&format!(
                "{root} repeats {} {} of {}; skipped",
                runner.family, runner.version, first.root
            ));
            continue;
        }
        let hash = read_hash(os, &root);
        out.push(FoundRunner { root, runner, hash });
    }
    out
}
