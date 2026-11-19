//! The importer: the job table, one install at a time, `Inspect`, and the install pipeline in the
//! order lead-29 fixed (05 §7.3), split by lead-33 (RUY-828) between the unprivileged helper
//! ([`crate::core::helper`], behind [`Helper`]) and this root side, which never opens a package:
//!
//! 1. **helper, `inspect`:** open the package, read the listing and the four root files once,
//!    `ruya_play_trust::inspect`, and stage the root files into `inspect/<name>/meta/` (and, for
//!    `Inspect`, the vetted art into `inspect/<name>/art/`);
//! 2. **service:** read those root files back once ([`MetaSource`], [`ReadOnce`]) and run
//!    `ruya_play_trust::inspect` over them with its own key records, the blocklist from
//!    `select_blocklist` (never `ListCheck::NotChecked`) and developer mode;
//! 3. refuse a `build` not above the installed build of the id (`build.not_newer`);
//! 4. free space: the installed size plus 10 %, before the first write (`space.not_enough`);
//! 5. **helper, `install`:** open the package again (its root files must still have the verified
//!    SHA-256s: `source.changed`), unpack into `staging/<job>/tree`, re-walk it, and vet the art
//!    into `staging/<job>/art`;
//! 6. **service:** the job folder holds `tree/` and `art/` only; re-walk the tree against the
//!    verified table (kinds, sizes, modes, link targets), re-hash every file, check revocation
//!    with the `runner` hashes of that copy, hold `art/` to what the helper named, and write the
//!    verified root files into `meta/` itself;
//! 7. `record_install` in the trust store, then the installed build, **before** the commit, so a
//!    failure fails closed (both are rolled back when the commit fails; a failed rollback is
//!    journalled);
//! 8. the [`Commit`] step (past the point of no return: `Cancel` answers `too-late`).
//!
//! Any failure or cancel removes the job's staging directory and its inspect folder; a crash
//! leaves only those, which [`Importer::open`] removes.

use crate::core::art::{self, VettedArt};
use crate::core::codes;
use crate::core::deps::{
    Blocklists, Clock, Commit, CommitError, CommitRequest, Deps, FreeSpace, Helper, Hooks,
    InstalledBuilds, Step,
};
use crate::core::helper::{self, ArtLine, Ending, Mode, Progress, Request, Session};
use crate::core::jobs::{self, JobKind, JobRecord, JobState, MAX_PATH_BYTES};
use crate::core::meta::MetaSource;
use crate::core::read_once::ReadOnce;
use crate::core::reconcile;
use crate::core::staging::{self, Dir, Kind};
use crate::core::status::{status_of, JobStatus, MethodStatus, Phase};
use crate::core::unpack::{self, staging_problem};
use crate::core::verify;
use ruya_play_format::limits::ROOT_FILES;
use ruya_play_format::Problem;
use ruya_play_trust::revocation::Selected;
use ruya_play_trust::{
    assess, diff, inspect, is_revoked, record_install, select_blocklist, Context, Continuity,
    IdRecord, Inspection, ListCheck, PermissionDiff, StoreKeys, Tier, TrustError, TrustStore,
};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

/// Where the importer keeps things (05 §7.1; RUY-829 passes `/var/lib/ruya-play/...`).
#[derive(Debug, Clone)]
pub struct Config {
    /// Downloaded packages (`incoming/`).
    pub incoming: PathBuf,
    /// Staging directories, one per running job, on the target filesystem.
    pub staging: PathBuf,
    /// The jobs table and the installed builds.
    pub state: PathBuf,
    /// One folder per helper `inspect` run: the root files it staged and, for `Inspect`, the
    /// vetted art the record points at (the newest [`MAX_PREVIEWS`] are kept).
    pub inspect: PathBuf,
    /// The Flatpak installation the apps are committed to (`/var/lib/flatpak`); `Verify` reads
    /// the deployed files there and never writes.
    pub flatpak: PathBuf,
}

impl Config {
    /// `incoming/`, `staging/`, `state/` and `inspect/` under `root`.
    pub fn under(root: &Path) -> Config {
        Config {
            incoming: root.join("incoming"),
            staging: root.join("staging"),
            state: root.join("state"),
            inspect: root.join("inspect"),
            flatpak: root.join("flatpak"),
        }
    }

    /// The same, with `staging/` and `inspect/` under `work` instead (RUY-866): the folders the
    /// helpers' output is renamed into must be on the same mount as the helpers' own state
    /// folders (`/var/lib/private/ruya-play-helper-<job>`), or `rename` fails with EXDEV: in the
    /// service's namespace every `ReadWritePaths=` entry and its `StateDirectory=` is a mount of
    /// its own, even on one filesystem.
    pub fn with_work(self, work: &Path) -> Config {
        Config {
            staging: work.join("staging"),
            inspect: work.join("inspect"),
            ..self
        }
    }

    /// The job table's file.
    pub fn jobs_file(&self) -> PathBuf {
        self.state.join("jobs")
    }

    /// The journal of records that could not be rolled back.
    pub fn journal_file(&self) -> PathBuf {
        self.state.join("journal")
    }
}

/// How many `Inspect` folders (with their vetted art) are kept.
pub const MAX_PREVIEWS: usize = 4;

/// What a running job tells the shell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// `JobProgress`: the percent never decreases and the phase never goes back.
    Progress {
        /// The job.
        job: String,
        /// 0-100.
        percent: u32,
        /// The phase.
        phase: Phase,
        /// Payload bytes written.
        bytes_done: u64,
        /// Payload bytes in all.
        bytes_total: u64,
    },
    /// `JobFinished`, exactly once per job.
    Finished {
        /// The job.
        job: String,
        /// How it ended.
        status: JobStatus,
    },
}

/// How a job ended, with everything the service reports about it.
#[derive(Debug, Clone)]
pub struct JobResult {
    /// The job.
    pub job: String,
    /// Its status.
    pub status: JobStatus,
    /// Every problem (for `ok`: art slots that were dropped).
    pub problems: Vec<Problem>,
    /// The vetted art handed to the commit step.
    pub art: Vec<VettedArt>,
    /// The inspect result, once the package passed it.
    pub inspection: Option<Inspection>,
}

/// What `Inspect` returns: data only; the helper stages the root files and the vetted art.
#[derive(Debug, Clone)]
pub struct InspectReport {
    /// What Install would end with now (`ok` or a job status).
    pub verdict: JobStatus,
    /// The problems (05 §4.5 and §9.2 codes, `build.not_newer`, and the art's).
    pub problems: Vec<Problem>,
    /// The package, when it passed the trust and format checks.
    pub inspection: Option<Inspection>,
    /// The build installed for the id now.
    pub installed_build: Option<u64>,
    /// The vetted art (Play1's `art`), files under `inspect/inspect-<n>/art/`, when the package
    /// passed; empty otherwise.
    pub art: Vec<VettedArt>,
    /// For a package whose id is installed: what it changes in the installed app's requests
    /// (05 §8). `None` when the id is not installed or the installed app's own `play.json` cannot
    /// be read.
    pub update: Option<PermissionDiff>,
}

struct State {
    counter: u64,
    jobs: Vec<JobRecord>,
    cancels: HashMap<String, Arc<AtomicBool>>,
    no_return: HashSet<String>,
}

struct Shared {
    state: Mutex<State>,
    jobs_file: PathBuf,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Trim and write the table. A failed write is logged: the job still runs, only its trace
    /// after a restart is lost (the `ruya-store` rule).
    fn save(&self, state: &mut State) {
        jobs::trim(&mut state.jobs);
        let text = jobs::encode(state.counter, &state.jobs);
        if let Err(e) = jobs::write_atomic(&self.jobs_file, text.as_bytes()) {
            eprintln!(
                "ruya-play: writing {} failed: {e}",
                self.jobs_file.display()
            );
        }
    }

    fn update(&self, job: &str, persist: bool, f: impl FnOnce(&mut JobRecord)) {
        let mut st = self.lock();
        if let Some(r) = st.jobs.iter_mut().find(|r| r.job == job) {
            f(r);
        }
        if persist {
            self.save(&mut st);
        }
    }

    fn cancel(&self, job: &str) -> MethodStatus {
        let mut st = self.lock();
        let Some(record) = st.jobs.iter().find(|r| r.job == job) else {
            return MethodStatus::UnknownJob;
        };
        if record.state == JobState::Finished || st.no_return.contains(job) {
            return MethodStatus::TooLate;
        }
        st.cancels
            .entry(job.to_string())
            .or_insert_with(|| Arc::new(AtomicBool::new(false)))
            .store(true, Ordering::SeqCst);
        MethodStatus::Ok
    }
}

/// Cancels jobs from another thread (the D-Bus side, or a test hook).
#[derive(Clone)]
pub struct Canceller(Arc<Shared>);

impl Canceller {
    /// `Cancel(job)`: `ok` (the job will finish `cancelled`), `unknown-job`, or `too-late` once
    /// the job is finished or in the commit step.
    pub fn cancel(&self, job: &str) -> MethodStatus {
        self.0.cancel(job)
    }
}

/// The importer.
pub struct Importer {
    cfg: Config,
    shared: Arc<Shared>,
    staging: Dir,
    scratch: Dir,
    previews: Mutex<VecDeque<String>>,
    inspects: AtomicU64,
    running: Mutex<()>,
    helper: Box<dyn Helper>,
    free_space: Box<dyn FreeSpace>,
    commit: Box<dyn Commit>,
    clock: Box<dyn Clock>,
    blocklists: Box<dyn Blocklists>,
    store_keys: StoreKeys,
    trust: Mutex<Box<dyn TrustStore + Send>>,
    installed: Mutex<Box<dyn InstalledBuilds + Send>>,
    hooks: Box<dyn Hooks>,
    /// Ids whose committed app could not be reconciled (lower case), with why.
    held: Mutex<BTreeMap<String, String>>,
    /// Every id is held (the installed apps could not be reconciled at all), with why.
    held_all: Mutex<Option<String>>,
}

/// What [`Importer::record`] found before it wrote, to undo it.
struct Prior {
    id: String,
    trust_written: bool,
    trust_before: Option<IdRecord>,
    build_written: bool,
    build_before: Option<u64>,
}

/// A refusal of steps 1 to 3: the problems, and the inspection when the package got that far.
type Refusal = Box<(Vec<Problem>, Option<Inspection>)>;

/// The package after the checks before any write (steps 1 to 3).
struct Checked {
    inspection: Inspection,
    selected: Result<Selected, TrustError>,
    installed_build: Option<u64>,
}

/// Steps 1 to 3: the helper's `inspect` run, then the service's own checks.
enum Front {
    /// Nothing at the path.
    Missing,
    /// Refused: the problems, and the inspection when the service got that far.
    Refused(Refusal),
    /// The job was cancelled during the helper run.
    Cancelled,
    /// The helper broke its contract.
    Failed(Problem),
    /// Passed.
    Checked(Box<Passed>),
}

/// A package that passed steps 1 to 3.
struct Passed {
    checked: Checked,
    meta: MetaSource,
    art: Vec<VettedArt>,
    art_problems: Vec<Problem>,
    art_refuses: bool,
}

fn create_private_dir(path: &Path) -> std::io::Result<()> {
    let mut b = std::fs::DirBuilder::new();
    b.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        b.mode(0o700);
    }
    b.create(path)
}

fn one(code: &str, path: &str, message: impl Into<String>) -> Vec<Problem> {
    vec![Problem::new(code, path, message)]
}

/// A helper run that ends `Missing` for a path that was there before the run and still is after it
/// is a read failure, not a missing package: `OpenFile=...:graceful` makes a path PID 1 may not open
/// look like a missing one. Both helper runs (inspect and install) apply this one rule.
fn unreadable_if_there(seen_before: bool, path: &Path) -> Option<Problem> {
    (seen_before && std::fs::symlink_metadata(path).is_ok()).then(|| {
        Problem::new(
            codes::SOURCE_UNREADABLE,
            "",
            "The package is there but the console could not read it.",
        )
    })
}

fn refused(job: &str, problems: Vec<Problem>, inspection: Option<Inspection>) -> JobResult {
    JobResult {
        job: job.to_string(),
        status: status_of(&problems),
        problems,
        art: Vec::new(),
        inspection,
    }
}

fn cancelled(job: &str, inspection: Option<Inspection>) -> JobResult {
    JobResult {
        job: job.to_string(),
        status: JobStatus::Cancelled,
        problems: Vec::new(),
        art: Vec::new(),
        inspection,
    }
}

/// The progress of one job: the percent never decreases and the phase never goes back.
struct Reporter<'a> {
    shared: &'a Shared,
    job: String,
    emit: &'a mut dyn FnMut(Event),
    percent: u32,
    phase: Phase,
    bytes_done: u64,
    bytes_total: u64,
}

impl Reporter<'_> {
    fn at(&mut self, phase: Phase, percent: u32) {
        let phase = phase.max(self.phase);
        let percent = percent.min(100).max(self.percent);
        if phase == self.phase && percent == self.percent {
            return;
        }
        let new_phase = phase != self.phase;
        self.phase = phase;
        self.percent = percent;
        let (done, total) = (self.bytes_done, self.bytes_total);
        self.shared.update(&self.job, new_phase, |r| {
            r.phase = phase;
            r.percent = percent;
            r.bytes_done = done;
            r.bytes_total = total;
        });
        (self.emit)(Event::Progress {
            job: self.job.clone(),
            percent,
            phase,
            bytes_done: done,
            bytes_total: total,
        });
    }

    /// A `progress` line of the helper, on the job's ranges. The helper's numbers are only
    /// positions: the byte total is the service's own, and nothing goes back or past its phase.
    fn helper(&mut self, p: &Progress) {
        let part = |from: u32, to: u32, done: u64, total: u64| {
            let span = u64::from(to - from);
            let at = done.min(total).saturating_mul(span) / total.max(1);
            from + u32::try_from(at).unwrap_or(to - from)
        };
        match p.phase {
            Phase::Staging => {
                let total = self.bytes_total;
                let done = p.done.min(total);
                self.bytes_done = done;
                let pct = if done >= total {
                    STAGED
                } else {
                    part(0, STAGED, done, total)
                };
                self.at(Phase::Staging, pct);
            }
            Phase::Verifying => self.at(Phase::Verifying, part(STAGED, VERIFIED, p.done, p.total)),
            Phase::VettingArt => {
                self.at(Phase::VettingArt, part(VERIFIED, VETTED, p.done, p.total))
            }
            _ => {}
        }
    }
}

/// Percent at the end of each phase.
const STAGED: u32 = 70;
const VERIFIED: u32 = 75;
const VETTED: u32 = 85;
const COMMITTED: u32 = 95;

fn changed(path: &str, what: impl Into<String>) -> Problem {
    Problem::new(codes::STAGING_CHANGED, path, what)
}

/// The top-level entries of a folder the helper wrote must be folders named in `allowed`.
fn only_dirs(dir: &Dir, allowed: &[&str]) -> Result<(), Problem> {
    let entries = dir.entries().map_err(|e| staging_problem("", &e))?;
    for e in entries {
        if e.kind != Kind::Dir || !allowed.contains(&e.name.as_str()) {
            return Err(changed(
                &e.name,
                "The helper left an entry the importer does not take.",
            ));
        }
    }
    Ok(())
}

/// One vetted art file before the shell can see it (RUY-829): a name `ruya-play-art` writes, at
/// most the bytes such a file can have, and the first bytes of its container. Read through the
/// folder handle, without following a link.
fn check_art_file(art_dir: &Dir, rel: &str, size: u64) -> Result<(), Problem> {
    use std::io::Read;
    let name = rel.rsplit('/').next().unwrap_or(rel);
    let Some((container, max)) = art::vetted_file_limit(name) else {
        return Err(changed(
            rel,
            "The art step does not write a file of that name.",
        ));
    };
    if size > max {
        return Err(changed(
            rel,
            format!("A vetted art file has {size} bytes; at most {max} are possible."),
        ));
    }
    let file = match rel.split_once('/') {
        Some((sub, leaf)) => art_dir.open_dir(sub).and_then(|d| d.open_file(leaf)),
        None => art_dir.open_file(rel),
    };
    let mut head = Vec::with_capacity(art::HEADER_BYTES);
    file.and_then(|f| {
        f.take(art::HEADER_BYTES as u64)
            .read_to_end(&mut head)
            .map(|_| ())
    })
    .map_err(|e| staging_problem(rel, &e))?;
    if !art::header_matches(container, &head, size) {
        return Err(changed(
            rel,
            "A vetted art file does not start as its format does.",
        ));
    }
    Ok(())
}

/// On an `ok` result the helper reports only what the art step dropped (`art.*` and `video.*`,
/// 05 §5): any other problem there breaks its contract (RUY-829).
fn art_only(problems: Vec<Problem>) -> Result<Vec<Problem>, Problem> {
    if problems
        .iter()
        .all(|p| p.code.starts_with("art.") || p.code.starts_with("video."))
    {
        return Ok(problems);
    }
    Err(Problem::new(
        codes::HELPER_FAILED,
        "",
        "The helper finished a run and reported a problem that is not the art step's.",
    ))
}

/// Hold `art/` to what the helper said it wrote: those files, folders one level down, nothing
/// else, and no setuid, setgid or sticky bit anywhere.
fn check_art(art_dir: &Dir, lines: &[ArtLine]) -> Result<Vec<VettedArt>, Problem> {
    let found = unpack::walk(art_dir).map_err(|e| staging_problem("art", &e))?;
    let named: BTreeSet<&str> = lines
        .iter()
        .flat_map(|l| l.files.iter().map(String::as_str))
        .collect();
    for (path, f) in &found {
        let ok = match f.kind {
            Kind::File => named.contains(path.as_str()),
            Kind::Dir => !path.contains('/'),
            _ => false,
        } && f.mode & 0o7000 == 0;
        if !ok {
            return Err(changed(
                path,
                "The art folder holds an entry the art step did not write.",
            ));
        }
    }
    let mut out = Vec::new();
    for l in lines {
        let mut files = Vec::new();
        for f in &l.files {
            let Some(entry) = found.get(f.as_str()).filter(|e| e.kind == Kind::File) else {
                return Err(changed(f, "A vetted art file is missing."));
            };
            check_art_file(art_dir, f, entry.size)?;
            files.push(
                staging::join_checked(art_dir.path(), f).map_err(|e| staging_problem(f, &e))?,
            );
        }
        out.push(VettedArt {
            slot: l.slot.clone(),
            lang: l.lang.clone(),
            files,
        });
    }
    Ok(out)
}

impl Importer {
    /// Open the importer: create the folders, remove every staging and inspect folder a crash left
    /// (and the helper's own leftovers), and settle the jobs a previous run left queued or running
    /// (`failed`, `interrupted`, once).
    pub fn open(cfg: Config, deps: Deps) -> Result<Importer, Problem> {
        for dir in [&cfg.incoming, &cfg.staging, &cfg.state, &cfg.inspect] {
            create_private_dir(dir).map_err(|e| staging_problem("", &e))?;
        }
        let staging_root = Dir::open_root(&cfg.staging).map_err(|e| staging_problem("", &e))?;
        staging::clear(&staging_root).map_err(|e| staging_problem("", &e))?;
        let scratch = Dir::open_root(&cfg.inspect).map_err(|e| staging_problem("", &e))?;
        staging::clear(&scratch).map_err(|e| staging_problem("", &e))?;
        if let Err(e) = deps.helper.clear() {
            // Leftovers outside our folders only cost space; the service still starts.
            eprintln!("ruya-play: removing the helpers' leftovers failed: {e}");
        }
        let (counter, mut list) = jobs::load(&cfg.jobs_file()).map_err(|e| {
            Problem::new(
                codes::STAGING_IO,
                "jobs",
                format!("The job table could not be read ({e})."),
            )
        })?;
        let settled = jobs::settle(&mut list, deps.clock.now());
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                counter,
                jobs: list,
                cancels: HashMap::new(),
                no_return: HashSet::new(),
            }),
            jobs_file: cfg.jobs_file(),
        });
        if settled > 0 {
            let mut st = shared.lock();
            shared.save(&mut st);
        }
        Ok(Importer {
            cfg,
            shared,
            staging: staging_root,
            scratch,
            previews: Mutex::new(VecDeque::new()),
            inspects: AtomicU64::new(0),
            running: Mutex::new(()),
            helper: deps.helper,
            free_space: deps.free_space,
            commit: deps.commit,
            clock: deps.clock,
            blocklists: deps.blocklists,
            store_keys: deps.store_keys,
            trust: Mutex::new(deps.trust),
            installed: Mutex::new(deps.installed),
            hooks: deps.hooks,
            held: Mutex::new(BTreeMap::new()),
            held_all: Mutex::new(None),
        })
    }

    /// The configuration.
    pub fn config(&self) -> &Config {
        &self.cfg
    }

    /// A handle that cancels jobs from another thread.
    pub fn canceller(&self) -> Canceller {
        Canceller(Arc::clone(&self.shared))
    }

    /// `ListJobs`: queued, running and the last finished jobs, oldest first.
    pub fn list_jobs(&self) -> Vec<JobRecord> {
        self.shared.lock().jobs.clone()
    }

    /// `Cancel(job)`.
    pub fn cancel(&self, job: &str) -> MethodStatus {
        self.shared.cancel(job)
    }

    fn trust(&self) -> MutexGuard<'_, Box<dyn TrustStore + Send>> {
        self.trust.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn installed(&self) -> MutexGuard<'_, Box<dyn InstalledBuilds + Send>> {
        self.installed.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The build installed for `id` (`state/installed.json`).
    pub fn installed_build(&self, id: &str) -> Result<Option<u64>, Problem> {
        self.installed().build_of(id)
    }

    /// Admin's developer mode (05 §7.2), from the trust store.
    pub fn developer_mode(&self) -> Result<bool, Problem> {
        self.trust().developer_mode().map_err(|e| e.to_problem())
    }

    /// Turn developer mode on or off; the caller checked that an admin asked.
    pub fn set_developer_mode(&self, on: bool) -> Result<(), Problem> {
        self.trust()
            .set_developer_mode(on)
            .map_err(|e| e.to_problem())
    }

    /// Refuse installs of `id` with `installed.unreconciled` (the start-up reconcile).
    pub fn hold(&self, id: &str, reason: &str) {
        self.held
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id.to_ascii_lowercase(), reason.to_string());
    }

    /// Refuse installs of every id with `installed.unreconciled` (the reconcile could not run).
    pub fn hold_all(&self, reason: &str) {
        *self.held_all.lock().unwrap_or_else(|e| e.into_inner()) = Some(reason.to_string());
    }

    /// Why every id is held, when it is.
    pub fn held_all(&self) -> Option<String> {
        self.held_all
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// The start-up reconcile over the listing of the installed apps, failing closed (RUY-829
    /// round 2): when the apps cannot be listed, or the records cannot be read, every id is held
    /// ([`Self::hold_all`]) and the error is returned; a reconcile that succeeds lifts that hold.
    /// The service runs it once at start, so a global hold lasts until the next start.
    pub fn reconcile_listed(
        &self,
        listed: std::io::Result<BTreeMap<String, reconcile::Deployed>>,
    ) -> Result<Vec<reconcile::Action>, Problem> {
        let result = match listed {
            Ok(deployed) => self.reconcile(&deployed),
            Err(e) => Err(Problem::new(
                codes::INSTALLED_UNRECONCILED,
                "",
                format!("The installed apps cannot be listed ({e})."),
            )),
        };
        match &result {
            Ok(_) => *self.held_all.lock().unwrap_or_else(|e| e.into_inner()) = None,
            Err(p) => self.hold_all(&p.message),
        }
        result
    }

    /// The held ids, lower case.
    pub fn held(&self) -> Vec<String> {
        self.held
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .keys()
            .cloned()
            .collect()
    }

    /// The start-up reconcile ([`reconcile::plan`]) against the committed apps `deployed`: the
    /// recorded builds are corrected and the ids that cannot be matched are held. A record that
    /// cannot be read or written holds the ids it concerns. Returns the steps taken, for the log.
    pub fn reconcile(
        &self,
        deployed: &BTreeMap<String, reconcile::Deployed>,
    ) -> Result<Vec<reconcile::Action>, Problem> {
        let recorded = self.installed().all()?;
        let mut trusted = BTreeSet::new();
        for id in deployed.keys() {
            if self.trust().get(id).map_err(|e| e.to_problem())?.is_some() {
                trusted.insert(id.clone());
            }
        }
        let actions = reconcile::plan(deployed, &recorded, &trusted);
        for a in &actions {
            let done = match a {
                reconcile::Action::ForgetBuild { id } => self.installed().forget(id),
                reconcile::Action::RecordBuild { id, build } => self.installed().record(id, *build),
                reconcile::Action::Hold { id, reason } => {
                    self.hold(id, reason);
                    Ok(())
                }
            };
            if let Err(p) = done {
                let id = match a {
                    reconcile::Action::ForgetBuild { id }
                    | reconcile::Action::RecordBuild { id, .. }
                    | reconcile::Action::Hold { id, .. } => id,
                };
                self.hold(
                    id,
                    &format!("its record could not be corrected ({})", p.message),
                );
            }
        }
        Ok(actions)
    }

    /// Steps 2 and 3 over the root files the service read back (a source that is read once).
    fn check(&self, source: &ReadOnce<'_>) -> Result<Checked, Refusal> {
        let image = self.blocklists.image();
        let downloaded = self.blocklists.downloaded();
        let selected = select_blocklist(
            image.as_deref(),
            downloaded
                .as_ref()
                .map(|(t, s)| (t.as_slice(), s.as_slice())),
            &self.store_keys,
            self.clock.now(),
        );
        let inspection = {
            let trust = self.trust();
            let ctx = Context {
                store_keys: &self.store_keys,
                trust: &**trust,
                // Never ListCheck::NotChecked: an install is always checked (RUY-93 review).
                blocklist: ListCheck::of(&selected),
                runner_hashes: &[],
                // Only the root files are here; the helper hashes every file while it copies it,
                // and the service re-hashes the staged copy.
                verify_content: false,
            };
            inspect(source, &ctx).map_err(|r| Box::new((r.problems(), None)))?
        };
        let id = inspection.package.manifest.id.clone();
        let build = inspection.package.manifest.build;
        let held = self.held_all().or_else(|| {
            self.held
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&id.to_ascii_lowercase())
                .cloned()
        });
        if let Some(reason) = held {
            return Err(Box::new((
                one(
                    codes::INSTALLED_UNRECONCILED,
                    "/id",
                    format!("The installed app of this id cannot be matched with its records ({reason}); uninstall it first."),
                ),
                Some(inspection),
            )));
        }
        let installed_build = self
            .installed()
            .build_of(&id)
            .map_err(|p| Box::new((vec![p], Some(inspection.clone()))))?;
        if let Some(have) = installed_build {
            if build <= have {
                return Err(Box::new((
                    one(
                        codes::BUILD_NOT_NEWER,
                        "/build",
                        format!(
                            "This is build {build}; build {have} is installed. A package can only replace an older build."
                        ),
                    ),
                    Some(inspection),
                )));
            }
        }
        Ok(Checked {
            inspection,
            selected,
            installed_build,
        })
    }

    /// A request for the helper, or `None` when a path is not plain text.
    fn request(&self, mode: Mode, job: &str, source: &Path, staging: &Path) -> Option<Request> {
        Some(Request {
            mode,
            job: job.to_string(),
            source: source.to_str()?.to_string(),
            staging: staging.to_str()?.to_string(),
            now: self.clock.now(),
            // A store that cannot be read is reported by the service's own inspect.
            developer_mode: self.trust().developer_mode().unwrap_or(false),
            blocklist: self.blocklists.image().map(|b| helper::hex(&b)),
            art: false,
            official: false,
            expect: BTreeMap::new(),
        })
    }

    /// Run the helper for `request` and read its output as untrusted lines.
    fn run_helper(
        &self,
        request: &Request,
        cancel: &AtomicBool,
        on_progress: &mut dyn FnMut(&Progress),
    ) -> Ending {
        let mut session = Session::new();
        let exit = self.helper.run(request, cancel, &mut |bytes| {
            session.feed(bytes, &mut *on_progress)
        });
        session.finish(&exit, cancel.load(Ordering::SeqCst))
    }

    /// Steps 1 to 3: the helper inspects `path` into `inspect/<name>`, then the service checks
    /// the root files it staged. With `art`, the vetted art stays in that folder (for `Inspect`);
    /// otherwise the folder is gone when this returns.
    fn front(&self, name: &str, path: &Path, art: bool, cancel: &AtomicBool) -> Front {
        let dir = match self.scratch.create_dir(name, 0o700) {
            Ok(d) => d,
            Err(e) => {
                if staging::is_changed(&e) {
                    let _ = self.scratch.remove_entry(name);
                }
                return Front::Failed(staging_problem("", &e));
            }
        };
        let front = self.front_in(&dir, name, path, art, cancel);
        drop(dir);
        let keep = art && matches!(front, Front::Checked(_));
        let cleaned = if keep {
            // The record points at art/ only.
            ["meta", "src"]
                .iter()
                .try_for_each(|n| match self.scratch.open_dir(name) {
                    Ok(d) => match d.remove_entry(n) {
                        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                        other => other,
                    },
                    Err(e) => Err(e),
                })
        } else {
            self.scratch.remove_entry(name)
        };
        match (cleaned, front) {
            (Err(e), Front::Checked(_)) => Front::Failed(staging_problem("", &e)),
            (_, front) => front,
        }
    }

    fn front_in(
        &self,
        dir: &Dir,
        name: &str,
        path: &Path,
        art: bool,
        cancel: &AtomicBool,
    ) -> Front {
        let Some(mut request) = self.request(Mode::Inspect, name, path, dir.path()) else {
            return Front::Failed(Problem::new(
                codes::HELPER_FAILED,
                "",
                "A path is not plain text.",
            ));
        };
        request.art = art;
        let seen = std::fs::symlink_metadata(path).is_ok();
        let (art_lines, art_problems, art_refuses) =
            match self.run_helper(&request, cancel, &mut |_| {}) {
                Ending::Missing => {
                    return match unreadable_if_there(seen, path) {
                        Some(p) => Front::Refused(Box::new((vec![p], None))),
                        None => Front::Missing,
                    }
                }
                Ending::Refused(p) => return Front::Refused(Box::new((p, None))),
                Ending::Cancelled => return Front::Cancelled,
                Ending::Failed(p) => return Front::Failed(p),
                Ending::Ok {
                    problems,
                    art,
                    art_refuses,
                } => match art_only(problems) {
                    Ok(problems) => (art, problems, art_refuses),
                    Err(p) => return Front::Failed(p),
                },
            };
        let allowed: &[&str] = if art {
            &["meta", "src", "art"]
        } else {
            &["meta"]
        };
        let meta = only_dirs(dir, allowed)
            .and_then(|()| {
                dir.open_dir("meta")
                    .map_err(|e| staging_problem("meta", &e))
            })
            .and_then(|m| MetaSource::read(&m));
        let meta = match meta {
            Ok(m) => m,
            Err(p) => return Front::Refused(Box::new((vec![p], None))),
        };
        let checked = match self.check(&ReadOnce::new(&meta)) {
            Ok(c) => c,
            Err(refusal) => return Front::Refused(refusal),
        };
        let vetted = if art {
            let found = match dir.open_dir("art") {
                Ok(a) => check_art(&a, &art_lines),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound && art_lines.is_empty() => {
                    Ok(Vec::new())
                }
                Err(e) => Err(staging_problem("art", &e)),
            };
            match found {
                Ok(v) => v,
                Err(p) => return Front::Refused(Box::new((vec![p], Some(checked.inspection)))),
            }
        } else {
            Vec::new()
        };
        Front::Checked(Box::new(Passed {
            checked,
            meta,
            art: vetted,
            art_problems,
            art_refuses,
        }))
    }

    /// Remember an `Inspect` folder and drop the oldest beyond [`MAX_PREVIEWS`].
    fn keep_preview(&self, name: String) {
        let mut kept = self.previews.lock().unwrap_or_else(|e| e.into_inner());
        kept.push_back(name);
        while kept.len() > MAX_PREVIEWS {
            if let Some(old) = kept.pop_front() {
                let _ = self.scratch.remove_entry(&old);
            }
        }
    }

    /// `Inspect(path)`: steps 1 to 3 and the art. Nothing is written but the helper's inspect
    /// folder (no staging folder, no job, no free-space query). `failed` when the helper broke
    /// its contract.
    pub fn inspect(&self, path: &Path) -> (MethodStatus, Option<InspectReport>) {
        if !path.is_absolute() || path.to_str().is_none() {
            return (MethodStatus::Invalid, None);
        }
        let n = self
            .inspects
            .fetch_add(1, Ordering::SeqCst)
            .saturating_add(1);
        let name = format!("inspect-{n}");
        let report = match self.front(&name, path, true, &AtomicBool::new(false)) {
            Front::Missing => return (MethodStatus::UnknownSource, None),
            Front::Cancelled | Front::Failed(_) => return (MethodStatus::Failed, None),
            Front::Refused(refusal) => {
                let (problems, inspection) = *refusal;
                let installed_build = inspection.as_ref().and_then(|i| {
                    self.installed()
                        .build_of(&i.package.manifest.id)
                        .ok()
                        .flatten()
                });
                let update = self.update_of(inspection.as_ref(), installed_build);
                InspectReport {
                    verdict: status_of(&problems),
                    problems,
                    inspection,
                    installed_build,
                    art: Vec::new(),
                    update,
                }
            }
            Front::Checked(passed) => {
                let p = *passed;
                self.keep_preview(name);
                let update = self.update_of(Some(&p.checked.inspection), p.checked.installed_build);
                InspectReport {
                    update,
                    verdict: if p.art_refuses {
                        status_of(&p.art_problems)
                    } else {
                        JobStatus::Ok
                    },
                    problems: p.art_problems,
                    inspection: Some(p.checked.inspection),
                    installed_build: p.checked.installed_build,
                    art: p.art,
                }
            }
        };
        (MethodStatus::Ok, Some(report))
    }

    /// What the inspected package changes in the requests of the installed app of its id: the
    /// installed app's own `play.json` (our verified commit, read from the deployment as the
    /// reconcile reads it) assessed against the new one. `None` when nothing is installed or the
    /// installed requests cannot be read.
    fn update_of(
        &self,
        inspection: Option<&Inspection>,
        installed_build: Option<u64>,
    ) -> Option<PermissionDiff> {
        let insp = inspection?;
        installed_build?;
        let id = &insp.package.manifest.id;
        let bytes = reconcile::deployed_play_json(&self.cfg.flatpak, id)?;
        let installed = reconcile::permissions_in(&bytes, id)?;
        let old = assess(insp.tier.tier, &installed);
        Some(diff(&old, &insp.assessment))
    }

    /// `Install(path, options)`: queue an install. `forbidden` without `admin_approved`, `invalid`
    /// for a path that is not absolute plain text, `busy` while a job for the same path is queued
    /// or running. The job's name is returned with `ok`.
    pub fn queue_install(&self, path: &Path, admin_approved: bool) -> (MethodStatus, String) {
        if !admin_approved {
            return (MethodStatus::Forbidden, String::new());
        }
        let Some(text) = path.to_str() else {
            return (MethodStatus::Invalid, String::new());
        };
        if !path.is_absolute() || text.len() > MAX_PATH_BYTES || text.chars().any(char::is_control)
        {
            return (MethodStatus::Invalid, String::new());
        }
        let mut st = self.shared.lock();
        if st.jobs.iter().any(|j| j.is_active() && j.path == text) {
            return (MethodStatus::Busy, String::new());
        }
        // The counter comes from a file: at its end no name is handed out twice and nothing
        // panics.
        let Some(next) = st.counter.checked_add(1) else {
            return (MethodStatus::Failed, String::new());
        };
        st.counter = next;
        let job = format!("job-{next}");
        st.jobs
            .push(JobRecord::queued(&job, JobKind::Install, text));
        self.shared.save(&mut st);
        (MethodStatus::Ok, job)
    }

    /// `Verify(app_id)`: queue a re-hash of the installed app `play.<id>` (05 §7.3). `invalid` for
    /// an id that is not a plain name, `unknown-app` when no build is recorded for it or its
    /// deployment is gone, `busy` while a verify of it is queued or running or the running install
    /// is for it (jobs run one at a time, so a queued install of it waits its turn).
    pub fn queue_verify(&self, id: &str) -> (MethodStatus, String) {
        if !reconcile::plain_id(id) || id.len() > MAX_PATH_BYTES {
            return (MethodStatus::Invalid, String::new());
        }
        match self.installed_build(id) {
            Ok(Some(_)) => {}
            Ok(None) => return (MethodStatus::UnknownApp, String::new()),
            Err(_) => return (MethodStatus::Failed, String::new()),
        }
        let Some(files) = reconcile::our_files(&self.cfg.flatpak, id) else {
            return (MethodStatus::UnknownApp, String::new());
        };
        if std::fs::symlink_metadata(&files).is_err() {
            return (MethodStatus::UnknownApp, String::new());
        }
        let app = format!("play.{id}");
        let mut st = self.shared.lock();
        let same = |j: &&JobRecord| {
            j.is_active()
                && j.app.eq_ignore_ascii_case(&app)
                && (j.kind == JobKind::Verify || j.state == JobState::Running)
        };
        if st.jobs.iter().any(|j| same(&j)) {
            return (MethodStatus::Busy, String::new());
        }
        let Some(next) = st.counter.checked_add(1) else {
            return (MethodStatus::Failed, String::new());
        };
        st.counter = next;
        let job = format!("job-{next}");
        let mut record = JobRecord::queued(&job, JobKind::Verify, "");
        record.app = app;
        st.jobs.push(record);
        self.shared.save(&mut st);
        (MethodStatus::Ok, job)
    }

    /// The pipeline of one verify job: the deployed files against their stored `play.files`.
    fn verify(
        &self,
        job: &str,
        app: &str,
        cancel: &AtomicBool,
        reporter: &mut Reporter<'_>,
    ) -> JobResult {
        let id = app.strip_prefix("play.").unwrap_or(app);
        let Some(files) = reconcile::our_files(&self.cfg.flatpak, id) else {
            return refused(
                job,
                vec![staging_problem("", &std::io::ErrorKind::NotFound.into())],
                None,
            );
        };
        let tree = match Dir::open_root(&files) {
            Ok(d) => d,
            Err(e) => return refused(job, vec![staging_problem("", &e)], None),
        };
        let mut tick = |t: verify::Tick| {
            reporter.bytes_total = t.bytes_total;
            reporter.bytes_done = t.bytes_done;
            let percent = if t.files_total == 0 {
                0
            } else {
                u32::try_from(t.files_done * 100 / t.files_total).unwrap_or(100)
            };
            reporter.at(Phase::Verifying, percent.min(99));
            !cancel.load(Ordering::SeqCst)
        };
        match verify::verify_files(&tree, &mut tick) {
            verify::Verdict::Match => {
                reporter.at(Phase::Verifying, 100);
                JobResult {
                    job: job.to_string(),
                    status: JobStatus::Ok,
                    problems: Vec::new(),
                    art: Vec::new(),
                    inspection: None,
                }
            }
            verify::Verdict::Stopped => cancelled(job, None),
            verify::Verdict::Differs(problems) => {
                // The payload differs from what was verified at install: that is
                // `invalid-package` whatever the code; only a read fault is `failed`.
                let io = problems.iter().any(|p| p.code == codes::STAGING_IO);
                let mut r = refused(job, problems, None);
                r.status = if io {
                    JobStatus::Failed
                } else {
                    JobStatus::InvalidPackage
                };
                r
            }
        }
    }

    /// Run the oldest queued job to its end (blocking), sending its events in order. Only one job
    /// runs at a time: a second caller waits. Returns the result, or `None` when nothing is queued.
    pub fn run_next(&self, emit: &mut dyn FnMut(Event)) -> Option<JobResult> {
        let _one = self.running.lock().unwrap_or_else(|e| e.into_inner());
        let now = self.clock.now();
        let (job, path, kind, app, flag) = {
            let mut st = self.shared.lock();
            let record = st.jobs.iter_mut().find(|j| j.state == JobState::Queued)?;
            record.state = JobState::Running;
            record.started = now;
            let (job, path) = (record.job.clone(), record.path.clone());
            let (kind, app) = (record.kind, record.app.clone());
            let flag = Arc::clone(
                st.cancels
                    .entry(job.clone())
                    .or_insert_with(|| Arc::new(AtomicBool::new(false))),
            );
            self.shared.save(&mut st);
            (job, path, kind, app, flag)
        };
        let result = {
            let mut reporter = Reporter {
                shared: &self.shared,
                job: job.clone(),
                emit: &mut *emit,
                percent: 0,
                phase: Phase::None,
                bytes_done: 0,
                bytes_total: 0,
            };
            if flag.load(Ordering::SeqCst) {
                cancelled(&job, None)
            } else if kind == JobKind::Verify {
                reporter.at(Phase::Verifying, 0);
                self.verify(&job, &app, &flag, &mut reporter)
            } else {
                reporter.at(Phase::Staging, 0);
                self.install(&job, Path::new(&path), &flag, &mut reporter)
            }
        };
        let error = result.problems.first().map_or("", |p| p.code.as_str());
        for line in jobs::problem_log_lines(&job, result.status, &result.problems) {
            eprintln!("{line}");
        }
        let finished = self.clock.now();
        {
            let mut st = self.shared.lock();
            if let Some(r) = st.jobs.iter_mut().find(|r| r.job == job) {
                r.finish(result.status, error, finished);
            }
            st.cancels.remove(&job);
            st.no_return.remove(&job);
            self.shared.save(&mut st);
        }
        emit(Event::Finished {
            job: job.clone(),
            status: result.status,
        });
        Some(result)
    }

    /// The pipeline of one install job.
    fn install(
        &self,
        job: &str,
        path: &Path,
        cancel: &AtomicBool,
        reporter: &mut Reporter<'_>,
    ) -> JobResult {
        let passed = match self.front(job, path, false, cancel) {
            Front::Missing => {
                return refused(
                    job,
                    one(
                        codes::SOURCE_MISSING,
                        "",
                        "The package is not there any more.",
                    ),
                    None,
                )
            }
            Front::Refused(r) => {
                let (p, insp) = *r;
                return refused(job, p, insp);
            }
            Front::Cancelled => return cancelled(job, None),
            Front::Failed(p) => return refused(job, vec![p], None),
            Front::Checked(p) => *p,
        };
        let (checked, meta) = (passed.checked, passed.meta);
        let insp = checked.inspection.clone();
        let total = insp.package.installed_bytes;
        reporter.bytes_total = total;
        let app = format!("play.{}", insp.package.manifest.id);
        self.shared.update(job, true, |r| {
            r.app = app;
            r.bytes_total = total;
        });
        if cancel.load(Ordering::SeqCst) {
            return cancelled(job, Some(insp));
        }

        // 4. Space, before the first write: the installed size plus 10 %.
        let needed = total.saturating_add(total.div_ceil(10));
        match self.free_space.available(&self.cfg.staging) {
            Err(e) => return refused(job, vec![staging_problem("", &e)], Some(insp)),
            Ok(free) if free < needed => {
                return refused(
                    job,
                    one(
                        codes::SPACE_NOT_ENOUGH,
                        "",
                        format!("The package needs {needed} bytes free (its size plus 10 %); {free} are free."),
                    ),
                    Some(insp),
                )
            }
            Ok(_) => {}
        }
        self.hooks.step(job, &Step::BeforeUnpack);
        if cancel.load(Ordering::SeqCst) {
            return cancelled(job, Some(insp));
        }

        // 5 to 8 write into the job's staging directory, which goes away whatever happens.
        let job_dir = match self.staging.create_dir(job, 0o700) {
            Ok(d) => d,
            Err(e) => {
                if staging::is_changed(&e) {
                    // Someone else put the name there. It is in our staging root, so it goes
                    // (removed without following it), and the job fails.
                    let _ = self.staging.remove_entry(job);
                }
                return refused(job, vec![staging_problem("", &e)], Some(insp));
            }
        };
        let mut result = self.staged(job, path, &job_dir, &meta, &checked, cancel, reporter);
        drop(job_dir);
        if let Err(e) = self.staging.remove_entry(job) {
            result.problems.push(staging_problem("", &e));
            if result.status == JobStatus::Ok {
                // Installed, but the staging copy is still there: report it.
                result.status = JobStatus::Failed;
            }
        }
        result
    }

    /// Steps 5 to 8 inside `job_dir`.
    #[allow(clippy::too_many_arguments)]
    fn staged(
        &self,
        job: &str,
        path: &Path,
        job_dir: &Dir,
        meta: &MetaSource,
        checked: &Checked,
        cancel: &AtomicBool,
        reporter: &mut Reporter<'_>,
    ) -> JobResult {
        let insp = &checked.inspection;
        let fail = |problems: Vec<Problem>| refused(job, problems, Some(insp.clone()));

        // 5. The helper unpacks, re-walks and vets the art.
        let Some(mut request) = self.request(Mode::Install, job, path, job_dir.path()) else {
            return fail(one(codes::HELPER_FAILED, "", "A path is not plain text."));
        };
        request.official = insp.tier.tier == Tier::Official;
        request.expect = meta.digests();
        let seen = std::fs::symlink_metadata(path).is_ok();
        let ending = self.run_helper(&request, cancel, &mut |p| reporter.helper(p));
        let (problems, art_lines) = match ending {
            Ending::Ok { problems, art, .. } => match art_only(problems) {
                Ok(problems) => (problems, art),
                Err(p) => return fail(vec![p]),
            },
            Ending::Cancelled => return cancelled(job, Some(insp.clone())),
            Ending::Refused(p) => return fail(p),
            Ending::Missing => {
                return fail(match unreadable_if_there(seen, path) {
                    Some(p) => vec![p],
                    None => one(
                        codes::SOURCE_MISSING,
                        "",
                        "The package is not there any more.",
                    ),
                })
            }
            Ending::Failed(p) => return fail(vec![p]),
        };

        // 6. The service's own pass: nothing the helper wrote is trusted.
        let files = &insp.package.files;
        let dirs = only_dirs(job_dir, &["tree", "art"]).and_then(|()| {
            let open = |n: &str| {
                job_dir.open_dir(n).map_err(|e| {
                    if e.kind() == std::io::ErrorKind::NotFound {
                        changed(n, "The helper did not stage it.")
                    } else {
                        staging_problem(n, &e)
                    }
                })
            };
            Ok((open("tree")?, open("art")?))
        });
        let (tree, art_dir) = match dirs {
            Ok(d) => d,
            Err(p) => return fail(vec![p]),
        };
        let found = match unpack::walk(&tree) {
            Ok(f) => f,
            Err(e) => return fail(vec![staging_problem("", &e)]),
        };
        if let Err(p) = unpack::check_tree(files, &found) {
            return fail(vec![p]);
        }
        let rehashed = match unpack::rehash(&tree, files) {
            Ok(u) => u,
            Err(p) => return fail(vec![p]),
        };
        reporter.bytes_done = rehashed.bytes;
        let runners = unpack::runner_hashes(&insp.package.manifest, files, &rehashed);
        match &checked.selected {
            Ok(selected) => {
                if let Some(revoked) = is_revoked(&selected.list, &insp.facts(), &runners) {
                    return fail(vec![revoked.to_problem()]);
                }
            }
            // inspect refused this already; never install unchecked.
            Err(e) => return fail(vec![e.to_problem()]),
        }
        let vetted = match check_art(&art_dir, &art_lines) {
            Ok(v) => v,
            Err(p) => return fail(vec![p]),
        };
        // The root files, exactly the bytes the service verified.
        let meta_dir = match job_dir.create_dir("meta", 0o700) {
            Ok(d) => d,
            Err(e) => return fail(vec![staging_problem("meta", &e)]),
        };
        for name in ROOT_FILES {
            let Some(bytes) = meta.root(name) else {
                continue;
            };
            let written = meta_dir
                .create_file(name, unpack::FILE_MODE)
                .and_then(|mut f| f.write_all(bytes));
            if let Err(e) = written {
                return fail(vec![staging_problem(name, &e)]);
            }
        }

        // 7 and 8. Past this point Cancel answers too-late.
        {
            let mut st = self.shared.lock();
            if cancel.load(Ordering::SeqCst) {
                drop(st);
                return cancelled(job, Some(insp.clone()));
            }
            st.no_return.insert(job.to_string());
        }
        // The key record and the installed build are written before the commit, so a failure
        // leaves at worst a record that refuses another key (fail closed), never a committed app
        // without one.
        let prior = match self.record(insp) {
            Ok(p) => p,
            Err(problems) => return fail(problems),
        };
        self.hooks.step(job, &Step::Committing);
        reporter.at(Phase::Committing, VETTED);
        let request = CommitRequest {
            job,
            tree: tree.path(),
            art: art_dir.path(),
            meta: meta_dir.path(),
            manifest: &insp.package.manifest,
            tier: insp.tier.tier,
            assessment: &insp.assessment,
            signatures: &insp.signatures,
        };
        let committed = self.commit.commit(&request, &mut |phase, frac| {
            let frac = frac.clamp(0.0, 1.0);
            let (from, to) = match phase {
                Phase::Installing => (COMMITTED, 100),
                _ => (VETTED, COMMITTED),
            };
            let pct = from + ((to - from) as f32 * frac) as u32;
            reporter.at(phase.max(Phase::Committing), pct);
        });
        let failure = match committed {
            Ok(()) => None,
            Err(CommitError::NoSpace(m)) => Some(Problem::new(codes::SPACE_NOT_ENOUGH, "", m)),
            Err(CommitError::Failed(m)) => Some(Problem::new(codes::COMMIT_FAILED, "", m)),
        };
        if let Some(p) = failure {
            let mut result = fail(vec![p]);
            // The status stays the commit's; a failed rollback is journalled and listed.
            result.problems.extend(self.roll_back(job, insp, prior));
            return result;
        }
        reporter.at(Phase::Installing, 100);
        JobResult {
            job: job.to_string(),
            status: JobStatus::Ok,
            problems,
            art: vetted,
            inspection: Some(insp.clone()),
        }
    }

    /// Step 7, before the commit: `record_install` in the trust store, then the installed build.
    /// Returns what was there before, for [`Self::roll_back`]. When the second write fails, the
    /// first one is rolled back.
    fn record(&self, insp: &Inspection) -> Result<Prior, Vec<Problem>> {
        let manifest = &insp.package.manifest;
        let id = manifest.id.clone();
        // Only first sight and a rotation change the trust record.
        let trust_written = matches!(
            insp.continuity,
            Continuity::FirstSight { .. } | Continuity::Rotated { .. }
        );
        let trust_before = self.trust().get(&id).map_err(|e| vec![e.to_problem()])?;
        record_install(
            &mut **self.trust(),
            &id,
            insp.signatures.key(),
            &insp.continuity,
            self.clock.now(),
        )
        .map_err(|e| vec![e.to_problem()])?;
        let mut prior = Prior {
            id,
            trust_written,
            trust_before,
            build_written: false,
            build_before: None,
        };
        let before = self.installed().build_of(&prior.id);
        let written = before.and_then(|b| {
            prior.build_before = b;
            self.installed().record(&prior.id, manifest.build)
        });
        if let Err(p) = written {
            let mut problems = vec![p];
            problems.extend(self.roll_back("", insp, prior));
            return Err(problems);
        }
        prior.build_written = true;
        Ok(prior)
    }

    /// Undo [`Self::record`] after a failed commit: a record this install created is dropped, one
    /// that existed before is put back, and so is the installed build. If that fails, the stale
    /// record can only refuse a different key later (the safe direction); it is written to the
    /// journal (`state/journal`) and returned as `rollback.failed`.
    fn roll_back(&self, job: &str, insp: &Inspection, prior: Prior) -> Option<Problem> {
        let mut faults = Vec::new();
        if prior.trust_written {
            let undone = match prior.trust_before {
                None => self.trust().remove(&prior.id).map(|_| ()),
                Some(record) => self.trust().put(record),
            };
            if let Err(e) = undone {
                faults.push(format!("the key record: {}", e.message()));
            }
        }
        if prior.build_written {
            let undone = match prior.build_before {
                None => self.installed().forget(&prior.id),
                Some(b) => self.installed().record(&prior.id, b),
            };
            if let Err(p) = undone {
                faults.push(format!("the installed build: {}", p.message));
            }
        }
        if faults.is_empty() {
            return None;
        }
        let detail = faults.join("; ");
        self.journal(job, &insp.package.manifest.id, &detail);
        Some(Problem::new(
            codes::ROLLBACK_FAILED,
            "",
            format!("The install failed and its records could not be undone ({detail}); they can only refuse another key."),
        ))
    }

    /// Append one line to `state/journal` (and to the log).
    fn journal(&self, job: &str, id: &str, detail: &str) {
        let line = serde_json::json!({
            "time": self.clock.now(),
            "job": job,
            "id": id,
            "event": "rollback_failed",
            "detail": detail,
        });
        eprintln!("ruya-play: {line}");
        let mut o = std::fs::OpenOptions::new();
        o.create(true).append(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            o.mode(0o600);
        }
        let written = o.open(self.cfg.journal_file()).and_then(|mut f| {
            f.write_all(format!("{line}\n").as_bytes())?;
            f.sync_all()
        });
        if let Err(e) = written {
            eprintln!("ruya-play: writing the journal failed: {e}");
        }
    }
}
