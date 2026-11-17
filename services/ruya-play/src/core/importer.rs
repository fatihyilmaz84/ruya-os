//! The importer: the job table, one install at a time, `Inspect`, and the install pipeline in the
//! order lead-29 fixed (05 §7.3):
//!
//! 1. read `play.json`, `play.files`, `play.sig` and `store.sig` once, as bounded bytes
//!    ([`ReadOnce`]);
//! 2. `ruya_play_trust::inspect` (verify, tier, `validate` with `official` only from a verified
//!    `store.sig`, id and build binding, continuity, ceiling, blocklist), with the list from
//!    `select_blocklist` and never `ListCheck::NotChecked`;
//! 3. refuse a `build` not above the installed build of the id (`build.not_newer`);
//! 4. free space: the installed size plus 10 %, before the first write (`space.not_enough`);
//! 5. unpack into `staging/<job>/tree`, created exclusively, through directory handles;
//! 6. re-walk the staged tree against the table and check revocation again, now with the `runner`
//!    hashes of the bundled components;
//! 7. vet the art from the staged copy;
//! 8. `record_install` in the trust store, then the installed build, **before** the commit, so a
//!    failure fails closed (both are rolled back when the commit fails; a failed rollback is
//!    journalled);
//! 9. the [`Commit`] step (past the point of no return: `Cancel` answers `too-late`).
//!
//! The source is read once; everything after step 5 reads the staged copy only. Any failure or
//! cancel removes the job's staging directory; a crash leaves only staging directories, which
//! [`Importer::open`] removes.

use crate::core::art::{self, VettedArt};
use crate::core::codes;
use crate::core::deps::{
    ArtVetter, Blocklists, Clock, Commit, CommitError, CommitRequest, Deps, FreeSpace, Hooks,
    InstalledBuilds, OpenError, Opener, Step,
};
use crate::core::jobs::{self, JobKind, JobRecord, JobState, MAX_PATH_BYTES};
use crate::core::read_once::ReadOnce;
use crate::core::staging::{self, Dir};
use crate::core::status::{status_of, JobStatus, MethodStatus, Phase};
use crate::core::unpack::{self, staging_problem, Control, Stop, Unpacked};
use ruya_play_format::Problem;
use ruya_play_trust::revocation::Selected;
use ruya_play_trust::{
    inspect, is_revoked, record_install, select_blocklist, Context, Continuity, IdRecord,
    Inspection, ListCheck, StoreKeys, TrustError, TrustStore,
};
use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

/// Where the importer keeps things (05 §7.1; RUY-100 passes `/var/lib/ruya-play/...`).
#[derive(Debug, Clone)]
pub struct Config {
    /// Downloaded packages (`incoming/`).
    pub incoming: PathBuf,
    /// Staging directories, one per running job, on the target filesystem.
    pub staging: PathBuf,
    /// The jobs table and the installed builds.
    pub state: PathBuf,
}

impl Config {
    /// `incoming/`, `staging/` and `state/` under `root`.
    pub fn under(root: &Path) -> Config {
        Config {
            incoming: root.join("incoming"),
            staging: root.join("staging"),
            state: root.join("state"),
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

/// What `Inspect` returns: data only, nothing written.
#[derive(Debug, Clone)]
pub struct InspectReport {
    /// What Install would end with now (`ok` or a job status).
    pub verdict: JobStatus,
    /// The problems (05 §4.5 and §9.2 codes, and `build.not_newer`).
    pub problems: Vec<Problem>,
    /// The package, when it passed the trust and format checks.
    pub inspection: Option<Inspection>,
    /// The build installed for the id now.
    pub installed_build: Option<u64>,
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
    running: Mutex<()>,
    opener: Box<dyn Opener>,
    free_space: Box<dyn FreeSpace>,
    art: Box<dyn ArtVetter>,
    commit: Box<dyn Commit>,
    clock: Box<dyn Clock>,
    blocklists: Box<dyn Blocklists>,
    store_keys: StoreKeys,
    trust: Mutex<Box<dyn TrustStore + Send>>,
    installed: Mutex<Box<dyn InstalledBuilds + Send>>,
    hooks: Box<dyn Hooks>,
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
}

/// Percent at the end of each phase.
const STAGED: u32 = 70;
const VERIFIED: u32 = 75;
const VETTED: u32 = 85;
const COMMITTED: u32 = 95;

struct UnpackCtl<'a, 'r> {
    job: &'a str,
    cancel: &'a AtomicBool,
    hooks: &'a dyn Hooks,
    reporter: &'a mut Reporter<'r>,
}

impl Control for UnpackCtl<'_, '_> {
    fn cancelled(&self) -> bool {
        self.cancel.load(Ordering::SeqCst)
    }
    fn progress(&mut self, done: u64) {
        let total = self.reporter.bytes_total.max(1);
        self.reporter.bytes_done = done;
        let pct = u32::try_from(done.saturating_mul(u64::from(STAGED)) / total).unwrap_or(STAGED);
        self.reporter.at(Phase::Staging, pct.min(STAGED));
    }
    fn step(&mut self, step: &Step<'_>) {
        self.hooks.step(self.job, step);
    }
}

impl Importer {
    /// Open the importer: create the folders, remove every staging directory a crash left, and
    /// settle the jobs a previous run left queued or running (`failed`, `interrupted`, once).
    pub fn open(cfg: Config, deps: Deps) -> Result<Importer, Problem> {
        for dir in [&cfg.incoming, &cfg.staging, &cfg.state] {
            create_private_dir(dir).map_err(|e| staging_problem("", &e))?;
        }
        let staging_root = Dir::open_root(&cfg.staging).map_err(|e| staging_problem("", &e))?;
        staging::clear(&staging_root).map_err(|e| staging_problem("", &e))?;
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
            running: Mutex::new(()),
            opener: deps.opener,
            free_space: deps.free_space,
            art: deps.art,
            commit: deps.commit,
            clock: deps.clock,
            blocklists: deps.blocklists,
            store_keys: deps.store_keys,
            trust: Mutex::new(deps.trust),
            installed: Mutex::new(deps.installed),
            hooks: deps.hooks,
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

    /// Steps 1 to 3 on a source that is read once.
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
                // The unpacker hashes every file while it copies it: the source is read once.
                verify_content: false,
            };
            inspect(source, &ctx).map_err(|r| Box::new((r.problems(), None)))?
        };
        let id = inspection.package.manifest.id.clone();
        let build = inspection.package.manifest.build;
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

    /// `Inspect(path)`: steps 1 to 3, reading data only; nothing is written.
    pub fn inspect(&self, path: &Path) -> (MethodStatus, Option<InspectReport>) {
        if !path.is_absolute() {
            return (MethodStatus::Invalid, None);
        }
        let source = match self.opener.open(path) {
            Err(OpenError::Missing) => return (MethodStatus::UnknownSource, None),
            Err(OpenError::Problems(p)) => {
                return (
                    MethodStatus::Ok,
                    Some(InspectReport {
                        verdict: status_of(&p),
                        problems: p,
                        inspection: None,
                        installed_build: None,
                    }),
                )
            }
            Ok(s) => s,
        };
        let once = ReadOnce::new(&*source);
        let report = match self.check(&once) {
            Ok(c) => InspectReport {
                verdict: JobStatus::Ok,
                problems: Vec::new(),
                inspection: Some(c.inspection),
                installed_build: c.installed_build,
            },
            Err(refusal) => {
                let (problems, inspection) = *refusal;
                let installed_build = inspection.as_ref().and_then(|i| {
                    self.installed()
                        .build_of(&i.package.manifest.id)
                        .ok()
                        .flatten()
                });
                InspectReport {
                    verdict: status_of(&problems),
                    problems,
                    inspection,
                    installed_build,
                }
            }
        };
        (MethodStatus::Ok, Some(report))
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

    /// Run the oldest queued job to its end (blocking), sending its events in order. Only one job
    /// runs at a time: a second caller waits. Returns the result, or `None` when nothing is queued.
    pub fn run_next(&self, emit: &mut dyn FnMut(Event)) -> Option<JobResult> {
        let _one = self.running.lock().unwrap_or_else(|e| e.into_inner());
        let now = self.clock.now();
        let (job, path, flag) = {
            let mut st = self.shared.lock();
            let record = st.jobs.iter_mut().find(|j| j.state == JobState::Queued)?;
            record.state = JobState::Running;
            record.started = now;
            let (job, path) = (record.job.clone(), record.path.clone());
            let flag = Arc::clone(
                st.cancels
                    .entry(job.clone())
                    .or_insert_with(|| Arc::new(AtomicBool::new(false))),
            );
            self.shared.save(&mut st);
            (job, path, flag)
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
            } else {
                reporter.at(Phase::Staging, 0);
                self.install(&job, Path::new(&path), &flag, &mut reporter)
            }
        };
        let error = result.problems.first().map_or("", |p| p.code.as_str());
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
        let source = match self.opener.open(path) {
            Err(OpenError::Missing) => {
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
            Err(OpenError::Problems(p)) => return refused(job, p, None),
            Ok(s) => s,
        };
        let once = ReadOnce::new(&*source);
        let checked = match self.check(&once) {
            Ok(c) => c,
            Err(refusal) => {
                let (p, insp) = *refusal;
                return refused(job, p, insp);
            }
        };
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

        // 5 to 9 write into the job's staging directory, which goes away whatever happens.
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
        let mut result = self.staged(job, &job_dir, &once, &checked, cancel, reporter);
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

    /// Steps 5 to 9 inside `job_dir`.
    fn staged(
        &self,
        job: &str,
        job_dir: &Dir,
        once: &ReadOnce<'_>,
        checked: &Checked,
        cancel: &AtomicBool,
        reporter: &mut Reporter<'_>,
    ) -> JobResult {
        let insp = &checked.inspection;
        let fail = |problems: Vec<Problem>| refused(job, problems, Some(insp.clone()));
        let dirs = (|| {
            Ok::<_, std::io::Error>((
                job_dir.create_dir("tree", unpack::EXEC_MODE)?,
                job_dir.create_dir("meta", 0o700)?,
                job_dir.create_dir("art", unpack::EXEC_MODE)?,
            ))
        })();
        let (tree, meta, art_dir) = match dirs {
            Ok(d) => d,
            Err(e) => return fail(vec![staging_problem("", &e)]),
        };
        self.hooks.step(
            job,
            &Step::StagingCreated {
                dir: job_dir.path(),
            },
        );
        // The root files, exactly the bytes that were verified.
        for name in ["play.json", "play.files", "play.sig", "store.sig"] {
            let Some(bytes) = once.root(name) else {
                continue;
            };
            let written = meta
                .create_file(name, unpack::FILE_MODE)
                .and_then(|mut f| f.write_all(&bytes));
            if let Err(e) = written {
                return fail(vec![staging_problem(name, &e)]);
            }
        }

        // 5. Unpack.
        let files = &insp.package.files;
        let unpacked: Unpacked = {
            let mut ctl = UnpackCtl {
                job,
                cancel,
                hooks: &*self.hooks,
                reporter,
            };
            match unpack::unpack(once, files, &tree, &mut ctl) {
                Ok(u) => u,
                Err(Stop::Cancelled) => return cancelled(job, Some(insp.clone())),
                Err(Stop::Package(p)) | Err(Stop::Staging(p)) => return fail(vec![p]),
            }
        };
        self.hooks.step(job, &Step::Unpacked);
        reporter.bytes_done = unpacked.bytes;
        reporter.at(Phase::Staging, STAGED);

        // 6. The staged tree against the table, then revocation with the runner hashes.
        reporter.at(Phase::Verifying, STAGED);
        let found = match unpack::walk(&tree) {
            Ok(f) => f,
            Err(e) => return fail(vec![staging_problem("", &e)]),
        };
        if let Err(p) = unpack::check_tree(files, &found) {
            return fail(vec![p]);
        }
        let runners = unpack::runner_hashes(&insp.package.manifest, files, &unpacked);
        match &checked.selected {
            Ok(selected) => {
                if let Some(revoked) = is_revoked(&selected.list, &insp.facts(), &runners) {
                    return fail(vec![revoked.to_problem()]);
                }
            }
            // inspect refused this already; never install unchecked.
            Err(e) => return fail(vec![e.to_problem()]),
        }
        reporter.at(Phase::Verifying, VERIFIED);
        if cancel.load(Ordering::SeqCst) {
            return cancelled(job, Some(insp.clone()));
        }

        // 7. Art, from the staged copy.
        reporter.at(Phase::VettingArt, VERIFIED);
        let inputs = art::inputs(&insp.package.manifest.art);
        let (mut results, mut problems, mut vetted) = (Vec::new(), Vec::new(), Vec::new());
        for (i, input) in inputs.iter().enumerate() {
            if cancel.load(Ordering::SeqCst) {
                return cancelled(job, Some(insp.clone()));
            }
            self.hooks.step(
                job,
                &Step::ArtSlot {
                    slot: input.slot.key(),
                },
            );
            let out_dir = match &input.subdir {
                None => art_dir.path().to_path_buf(),
                Some(sub) => match art_dir.create_dir(sub, unpack::EXEC_MODE) {
                    Ok(d) => d.path().to_path_buf(),
                    Err(e) => return fail(vec![staging_problem("", &e)]),
                },
            };
            let staged = match unpack::staged_path(&tree, &input.package_path) {
                Ok(p) => p,
                Err(p) => return fail(vec![p]),
            };
            let Some(result) = self
                .art
                .vet(&[(input.slot, staged)], &out_dir)
                .into_iter()
                .next()
            else {
                continue;
            };
            if let ruya_play_art::Outcome::Ok { files } = &result.outcome {
                vetted.push(VettedArt {
                    slot: input.slot.key(),
                    lang: input.lang.clone(),
                    files: files.clone(),
                });
            }
            problems.extend(art::problem_of(input, &result));
            results.push(result);
            let n = u32::try_from(inputs.len()).unwrap_or(u32::MAX).max(1);
            let i = u32::try_from(i + 1).unwrap_or(u32::MAX);
            reporter.at(
                Phase::VettingArt,
                VERIFIED + (VETTED - VERIFIED).saturating_mul(i) / n,
            );
        }
        if art::refuses(&results) {
            return fail(problems);
        }

        // 8 and 9. Past this point Cancel answers too-late.
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
            meta: meta.path(),
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

    /// Step 8, before the commit: `record_install` in the trust store, then the installed build.
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
