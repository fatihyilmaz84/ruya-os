//! The rules of Update1: the status record, which call is allowed when, what a check and a
//! download make of `bootc`'s answers, the image job (ADR-026 v2: pause, resume, cancel) and the
//! download ledger. No I/O except through `Bootc` and the small state files under
//! `/var/lib/ruya-update`. Time is passed in.

use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

use crate::bootc::{tag_of, with_tag, Bootc, HostStatus, Progress, Pull, PullEnd, Stop};
use crate::job::{
    Job, JobRecord, JobState, REASON_PLAYING, STATUS_CANCELLED, STATUS_FAILED, STATUS_OK,
};
use crate::ledger::{self, local_day, oldest_kept, Day, Ledger, LEDGER_FILE};
use crate::schedule::{parse_seconds, Clock, Reboot, Schedule};

/// Statuses of the method replies (stable API, `api/dbus/org.ruyaos.Update1.xml`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    Busy,
    Unavailable,
    Invalid,
    Forbidden,
    Failed,
    WrongState,
    Unsupported,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::Busy => "busy",
            Status::Unavailable => "unavailable",
            Status::Invalid => "invalid",
            Status::Forbidden => "forbidden",
            Status::Failed => "failed",
            Status::WrongState => "wrong-state",
            Status::Unsupported => "unsupported",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Idle,
    Checking,
    Downloading,
    Staged,
    UpToDate,
    Failed,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Idle => "idle",
            State::Checking => "checking",
            State::Downloading => "downloading",
            State::Staged => "staged",
            State::UpToDate => "up-to-date",
            State::Failed => "failed",
        }
    }

    fn running(self) -> bool {
        matches!(self, State::Checking | State::Downloading)
    }
}

/// The `a{sv}` record of `GetStatus`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub state: State,
    pub current: String,
    pub available: String,
    pub staged: String,
    pub channel: String,
    pub auto_restart: bool,
    pub last_check: i64,
    /// Unix seconds of the announced automatic restart, 0 = none announced.
    pub restart_at: i64,
    pub progress: u32,
    pub rollback_available: bool,
    pub error: String,
}

const CHANNELS: [&str; 2] = ["stable", "beta"];
const CHANNEL_FILE: &str = "channel";
const AUTO_RESTART_FILE: &str = "auto_restart";
const LAST_CHECK_FILE: &str = "last_check";
/// The image job while it is paused or runs (so a restart finds it paused).
const JOB_FILE: &str = "download_job";
/// While a download runs, its changes are sent at most this often (a phase change at once).
pub const JOB_EMIT_MS: u64 = 1000;

/// Why the running pull is being stopped.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Stopping {
    /// Paused, with the job's reason ("" or "playing").
    Pause(String),
    Cancel,
}

struct Inner {
    state: State,
    available: String,
    error: String,
    last_check: i64,
    progress: u32,
    /// The tag the user chose with `SetChannel`; None until then (the host's own tag is tracked).
    channel: Option<String>,
    /// Why the remembered channel could not be read; "" when it could. Shown as the error
    /// until `SetChannel` writes a good file.
    channel_problem: String,
    host: HostStatus,
    /// "Restart automatically for updates"; on until an admin turns it off.
    auto_restart: bool,
    schedule: Schedule,
    /// The image job: running, paused, or the last one that finished since the service started.
    job: Option<Job>,
    /// Stops the running pull; made when the job begins or resumes.
    stop: Option<Stop>,
    stopping: Option<Stopping>,
    /// When the running job's change was last sent (`JOB_EMIT_MS`).
    last_job_emit_ms: Option<u64>,
    ledger: Ledger,
    /// Why the kept ledger could not be read; "" when it could. It is then neither written nor
    /// reported (GetDownloadStats answers "failed").
    ledger_problem: String,
}

pub struct Update<B: Bootc> {
    bootc: B,
    /// Where the channel is remembered; None in development.
    dir: Option<PathBuf>,
    inner: Mutex<Inner>,
    /// One `bootc` command at a time.
    commands: Mutex<()>,
}

/// The remembered channel. A file that cannot be used is an `Err` naming it; it stays as it is
/// until `SetChannel` replaces it.
fn load_channel(dir: &std::path::Path) -> Result<Option<String>, String> {
    let path = dir.join(CHANNEL_FILE);
    match fs::read_to_string(&path) {
        Ok(text) => {
            let text = text.trim();
            if CHANNELS.contains(&text) {
                Ok(Some(text.to_owned()))
            } else {
                Err(format!("{}: unknown channel {text:?}", path.display()))
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

/// Writes one small state file atomically (tmp + rename).
fn save_file(dir: &std::path::Path, name: &str, text: &str) -> std::io::Result<()> {
    fs::create_dir_all(dir)?;
    let tmp = dir.join(format!("{name}.tmp"));
    fs::write(&tmp, format!("{text}\n"))?;
    fs::rename(tmp, dir.join(name))
}

fn save_channel(dir: &std::path::Path, channel: &str) -> std::io::Result<()> {
    save_file(dir, CHANNEL_FILE, channel)
}

/// The remembered automatic-restart setting; on when there is none or it is unreadable (a
/// state file never stops the service).
fn load_auto_restart(dir: &std::path::Path) -> bool {
    match fs::read_to_string(dir.join(AUTO_RESTART_FILE)) {
        Ok(text) if text.trim() == "off" => false,
        Ok(text) if text.trim() == "on" => true,
        Ok(text) => {
            eprintln!("ruya-update: ignoring auto_restart {:?}", text.trim());
            true
        }
        Err(_) => true,
    }
}

/// The kept image job, paused. One that cannot be read is ignored (a state file never stops the
/// service); the next pause replaces it.
fn load_job(dir: &std::path::Path) -> Option<Job> {
    let path = dir.join(JOB_FILE);
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
        Err(e) => {
            eprintln!("ruya-update: ignoring {}: {e}", path.display());
            return None;
        }
    };
    match Job::from_json(text.trim()) {
        Ok(job) => Some(job),
        Err(e) => {
            eprintln!("ruya-update: ignoring {}: {e}", path.display());
            None
        }
    }
}

/// A job id that differs from the last job's: "os-<unix seconds it began>".
fn next_job_id(last: Option<&Job>, now: i64) -> String {
    let base = format!("os-{now}");
    let mut id = base.clone();
    let mut n = 2;
    while last.is_some_and(|j| j.id == id) {
        id = format!("{base}-{n}");
        n += 1;
    }
    id
}

impl<B: Bootc> Update<B> {
    /// `dir`: where the channel is remembered. A corrupt state file does not stop the service
    /// (`/var` survives an image rollback, so a fatal start would fail every boot): the host's
    /// own tag is followed and the problem is the status error until `SetChannel`.
    pub fn new(bootc: B, dir: Option<PathBuf>) -> Self {
        let (channel, channel_problem) = match dir.as_deref().map(load_channel) {
            Some(Ok(channel)) => (channel, String::new()),
            Some(Err(problem)) => {
                eprintln!("ruya-update: ignoring the remembered channel: {problem}");
                (None, problem)
            }
            None => (None, String::new()),
        };
        let auto_restart = dir.as_deref().map(load_auto_restart).unwrap_or(true);
        let last_check = dir
            .as_deref()
            .and_then(|d| fs::read_to_string(d.join(LAST_CHECK_FILE)).ok())
            .map_or(0, |text| parse_seconds(&text));
        let job = dir.as_deref().and_then(load_job);
        // A paused download is an update waiting: Download (or ResumeDownload) continues it.
        let available = job.as_ref().map(|j| j.version.clone()).unwrap_or_default();
        let (ledger, ledger_problem) = match dir.as_deref().map(ledger::load) {
            Some(Ok(ledger)) => (ledger, String::new()),
            Some(Err(problem)) => {
                eprintln!("ruya-update: not counting downloads: {problem}");
                (Ledger::default(), problem)
            }
            None => (Ledger::default(), String::new()),
        };
        Update {
            bootc,
            dir,
            inner: Mutex::new(Inner {
                state: State::Idle,
                available,
                error: String::new(),
                last_check,
                progress: job.as_ref().map_or(0, |j| j.percent),
                channel,
                channel_problem,
                host: HostStatus::default(),
                auto_restart,
                schedule: Schedule::default(),
                job,
                stop: None,
                stopping: None,
                last_job_emit_ms: None,
                ledger,
                ledger_problem,
            }),
            commands: Mutex::new(()),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn command_lock(&self) -> std::sync::MutexGuard<'_, ()> {
        self.commands.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Reads the host's deployments (at start, and after every job). A staged image or a queued
    /// rollback means "restart to finish".
    pub fn refresh(&self) -> Result<(), String> {
        let _cmd = self.command_lock();
        let host = self.bootc.status()?;
        let mut inner = self.lock();
        if inner.state == State::Idle && staged_label(&host).is_some() {
            inner.state = State::Staged;
        }
        inner.host = host;
        Ok(())
    }

    pub fn record(&self) -> Record {
        let inner = self.lock();
        // A staged image or a running job matters more than the bad file.
        let problem = !inner.channel_problem.is_empty()
            && matches!(inner.state, State::Idle | State::UpToDate | State::Failed);
        Record {
            state: if problem { State::Failed } else { inner.state },
            current: inner
                .host
                .booted
                .as_ref()
                .map(|d| d.label())
                .unwrap_or_default(),
            available: inner.available.clone(),
            staged: staged_label(&inner.host).unwrap_or_default(),
            channel: effective_channel(&inner),
            auto_restart: inner.auto_restart,
            last_check: inner.last_check,
            // Only an announcement that still holds: the schedule clears the rest at its next
            // look, but a client must not read a stale one before that.
            restart_at: match inner.schedule.pending_restart() {
                Some(at) if inner.state == State::Staged && inner.auto_restart => at,
                _ => 0,
            },
            progress: inner.progress,
            rollback_available: inner.host.rollback.is_some() && !inner.host.rollback_queued,
            error: if problem && inner.error.is_empty() {
                inner.channel_problem.clone()
            } else {
                inner.error.clone()
            },
        }
    }

    // ---- check -----------------------------------------------------------------------

    /// Starts a check; `run_check` does the work (on a thread).
    pub fn begin_check(&self) -> Status {
        let mut inner = self.lock();
        if inner.state.running() {
            return Status::Busy;
        }
        inner.state = State::Checking;
        inner.error.clear();
        Status::Ok
    }

    /// Asks the registry about the tracked tag. With a channel other than the host's tag there is
    /// nothing to ask (`bootc` cannot look at another tag without staging it): the channel
    /// itself is "available", and `run_download` switches to it.
    pub fn run_check(&self, now: i64, emit: &mut dyn FnMut()) {
        let result = {
            let _cmd = self.command_lock();
            self.check_locked()
        };
        {
            let mut inner = self.lock();
            match result {
                Err(e) => {
                    inner.state = State::Failed;
                    inner.error = e;
                }
                Ok((host, switching)) => {
                    inner.last_check = now;
                    if let Some(dir) = &self.dir {
                        if let Err(e) = save_file(dir, LAST_CHECK_FILE, &now.to_string()) {
                            eprintln!("ruya-update: cannot remember the check time: {e}");
                        }
                    }
                    inner.available = available_version(&host, switching, &inner);
                    inner.host = host;
                    inner.state = if staged_label(&inner.host).is_some() {
                        inner.available.clear();
                        State::Staged
                    } else if inner.available.is_empty() {
                        State::UpToDate
                    } else {
                        State::Idle
                    };
                }
            }
        }
        emit();
    }

    /// The `bootc` part of a check, with `commands` held: the host's answer and whether the
    /// chosen channel differs from the tracked tag.
    fn check_locked(&self) -> Result<(HostStatus, bool), String> {
        // The start-up reading may not have finished (or failed): learn the tracked image now.
        if self.lock().host.tracked.is_empty() {
            let host = self.bootc.status()?;
            self.lock().host = host;
        }
        if self.lock().host.tracked.is_empty() {
            return Err("bootc does not say which image this console follows".to_owned());
        }
        if self.switch_target().is_some() {
            return Ok((self.bootc.status()?, true));
        }
        self.bootc.check()?;
        Ok((self.bootc.status()?, false))
    }

    // ---- download --------------------------------------------------------------------

    /// Download: stages the image a check found, as a new job; with a paused job, continues it
    /// (as ResumeDownload). `run_download` does the work (on a thread).
    pub fn begin_download(&self, now: i64) -> Status {
        let mut inner = self.lock();
        self.begin_locked(&mut inner, now)
    }

    /// ResumeDownload: "wrong-state" unless a download is paused.
    pub fn resume_download(&self, now: i64) -> Status {
        let mut inner = self.lock();
        if !inner
            .job
            .as_ref()
            .is_some_and(|j| j.state == JobState::Paused)
        {
            return Status::WrongState;
        }
        self.begin_locked(&mut inner, now)
    }

    fn begin_locked(&self, inner: &mut Inner, now: i64) -> Status {
        if inner.state.running() {
            return Status::Busy;
        }
        let paused = inner
            .job
            .as_ref()
            .is_some_and(|j| j.state == JobState::Paused);
        if !paused && inner.available.is_empty() {
            return Status::Unavailable;
        }
        // Whoever starts a download takes over: a failure of this one is retried only if the
        // schedule started it (`scheduled_download` notes that afterwards).
        inner.schedule.download_begun();
        if paused {
            if let Some(job) = inner.job.as_mut() {
                job.resume();
            }
        } else {
            let id = next_job_id(inner.job.as_ref(), now);
            inner.job = Some(Job::new(&id, &inner.available, now));
        }
        if let Some(job) = &inner.job {
            // Kept while it runs too: a service stopped under it finds it paused at its next
            // start.
            self.keep_job(job);
            inner.progress = job.percent;
        }
        inner.state = State::Downloading;
        inner.error.clear();
        inner.stop = Some(Stop::default());
        inner.stopping = None;
        inner.last_job_emit_ms = None;
        Status::Ok
    }

    /// Runs `bootc upgrade` (or `switch` to the chosen channel) with its progress events, until
    /// it stages the image, fails, or is stopped by a pause or a cancel.
    pub fn run_download(&self, clock: &dyn Clock, emit: &mut dyn FnMut()) {
        let target = match self.switch_target() {
            Some(image) => Pull::Switch(image),
            None => Pull::Upgrade,
        };
        let stop = self.lock().stop.clone().unwrap_or_default();
        let (result, host) = {
            let _cmd = self.command_lock();
            let result = self.bootc.pull(&target, &stop, &mut |event| {
                self.on_progress(&event, clock, emit);
            });
            // Read whatever the end: a stopped pull must have left the deployments as they were.
            (result, self.bootc.status())
        };
        self.end_run(result, host, clock);
        emit();
    }

    fn on_progress(&self, event: &Progress, clock: &dyn Clock, emit: &mut dyn FnMut()) {
        let now_ms = clock.monotonic_ms();
        let send = {
            let mut guard = self.lock();
            let inner = &mut *guard;
            let Some(job) = inner.job.as_mut() else {
                return;
            };
            let seen = job.progress(event, now_ms);
            if let (
                true,
                Progress::Bytes {
                    bytes_total,
                    bytes_cached,
                    steps_total,
                    steps_cached,
                    ..
                },
            ) = (seen.first_bytes, event)
            {
                // scripts/vm-update-check.sh `download` compares these lines of two runs.
                eprintln!(
                    "ruya-update: download {}: {steps_cached} layers ({bytes_cached} bytes) here, {steps_total} layers ({bytes_total} bytes) to fetch",
                    job.id
                );
            }
            inner.progress = job.percent;
            let due = inner
                .last_job_emit_ms
                .map_or(true, |at| now_ms >= at + JOB_EMIT_MS);
            if seen.phase_changed || due {
                inner.last_job_emit_ms = Some(now_ms);
            }
            seen.phase_changed || due
        };
        if send {
            emit();
        }
    }

    /// What a run's end makes of the job and the status record.
    fn end_run(
        &self,
        result: Result<PullEnd, String>,
        host: Result<HostStatus, String>,
        clock: &dyn Clock,
    ) {
        enum End {
            Staged,
            Paused(String),
            Cancelled,
            Failed(String),
        }
        let now = clock.now();
        let mut guard = self.lock();
        let inner = &mut *guard;
        let stopping = inner.stopping.take();
        inner.stop = None;
        let end = match (result, stopping) {
            (Ok(PullEnd::Done), _) => match &host {
                Ok(h) if staged_label(h).is_some() => End::Staged,
                Ok(_) => End::Failed("bootc staged nothing".to_owned()),
                Err(e) => End::Failed(e.clone()),
            },
            (_, Some(Stopping::Cancel)) => End::Cancelled,
            (_, Some(Stopping::Pause(reason))) => End::Paused(reason),
            (Ok(PullEnd::Stopped), None) => End::Failed("bootc was stopped".to_owned()),
            (Err(e), None) => End::Failed(e),
        };
        if let Ok(h) = host {
            inner.host = h;
        }
        let Some(job) = inner.job.as_mut() else {
            return;
        };
        let run_bytes = job.run_bytes;
        let finished = match end {
            End::Staged => {
                job.finish(STATUS_OK, now);
                inner.available.clear();
                inner.state = State::Staged;
                Some(false)
            }
            End::Paused(reason) => {
                job.pause(&reason);
                self.keep_job(job);
                inner.state = idle_or_staged(&inner.host);
                None
            }
            End::Cancelled => {
                job.finish(STATUS_CANCELLED, now);
                inner.state = idle_or_staged(&inner.host);
                Some(false)
            }
            End::Failed(e) => {
                job.finish(STATUS_FAILED, now);
                inner.state = State::Failed;
                inner.error = e;
                Some(true)
            }
        };
        inner.progress = job.percent;
        if finished.is_some() {
            self.forget_job();
        }
        self.count(inner, clock, run_bytes, finished);
    }

    /// PauseDownload: the running download stops and keeps its fetched layers.
    pub fn pause_download(&self) -> Status {
        self.pause_with("")
    }

    /// The download policy (RUY-31, "pause while playing") pauses the running download; the
    /// schedule resumes it by itself once no app runs.
    pub fn policy_pause(&self) -> Status {
        self.pause_with(REASON_PLAYING)
    }

    fn pause_with(&self, reason: &str) -> Status {
        let mut inner = self.lock();
        let Some(job) = inner.job.as_ref().filter(|j| j.state == JobState::Running) else {
            return Status::WrongState;
        };
        if !job.resumable() {
            return Status::Unsupported;
        }
        match inner.stopping {
            Some(Stopping::Cancel) => return Status::WrongState,
            Some(Stopping::Pause(_)) => return Status::Ok,
            None => {}
        }
        inner.stopping = Some(Stopping::Pause(reason.to_owned()));
        if let Some(stop) = &inner.stop {
            stop.request();
        }
        Status::Ok
    }

    /// CancelDownload: a running download stops for good, a paused one ends at once; nothing is
    /// staged. "unsupported" once the import has begun.
    pub fn cancel_download(&self, clock: &dyn Clock) -> Status {
        let mut guard = self.lock();
        let inner = &mut *guard;
        let Some(job) = inner.job.as_ref() else {
            return Status::WrongState;
        };
        match job.state {
            JobState::Running => {
                if !job.resumable() {
                    return Status::Unsupported;
                }
                inner.stopping = Some(Stopping::Cancel);
                if let Some(stop) = &inner.stop {
                    stop.request();
                }
                Status::Ok
            }
            JobState::Paused => {
                self.cancel_paused(inner, clock);
                Status::Ok
            }
            JobState::Finished => Status::WrongState,
        }
    }

    /// A paused job ends as cancelled: CancelDownload, or what it would stage is no longer wanted
    /// (SetChannel, Rollback).
    fn cancel_paused(&self, inner: &mut Inner, clock: &dyn Clock) {
        let Some(job) = inner.job.as_mut().filter(|j| j.state == JobState::Paused) else {
            return;
        };
        job.finish(STATUS_CANCELLED, clock.now());
        inner.progress = job.percent;
        self.forget_job();
        self.count(inner, clock, 0, Some(false));
    }

    /// The image job's record: None when there has been none since the service started.
    pub fn job_record(&self, now_ms: u64) -> Option<JobRecord> {
        self.lock().job.as_ref().map(|j| j.record(now_ms))
    }

    /// GetDownloadStats: per local day, newest first, at most `days` (1..90).
    pub fn download_stats(&self, days: u32, clock: &dyn Clock) -> (Status, Vec<Day>) {
        if days == 0 || i64::from(days) > ledger::KEEP_DAYS {
            return (Status::Invalid, Vec::new());
        }
        let inner = self.lock();
        if !inner.ledger_problem.is_empty() {
            return (Status::Failed, Vec::new());
        }
        let oldest = oldest_kept(clock.now(), clock.utc_offset_secs());
        (Status::Ok, inner.ledger.stats(days, &oldest))
    }

    fn keep_job(&self, job: &Job) {
        if let Some(dir) = &self.dir {
            if let Err(e) = save_file(dir, JOB_FILE, &job.to_json()) {
                eprintln!("ruya-update: cannot keep the download job: {e}");
            }
        }
    }

    fn forget_job(&self) {
        if let Some(dir) = &self.dir {
            match fs::remove_file(dir.join(JOB_FILE)) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                    eprintln!("ruya-update: cannot remove the kept download job: {e}");
                }
                _ => {}
            }
        }
    }

    /// The ledger counts `bytes` and a finished job (`Some(failed)`) on today's local date.
    fn count(&self, inner: &mut Inner, clock: &dyn Clock, bytes: u64, finished: Option<bool>) {
        if !inner.ledger_problem.is_empty() || (bytes == 0 && finished.is_none()) {
            return;
        }
        let (now, offset) = (clock.now(), clock.utc_offset_secs());
        inner.ledger.add(&local_day(now, offset), bytes, finished);
        inner.ledger.prune(&oldest_kept(now, offset));
        if let Some(dir) = &self.dir {
            if let Err(e) = save_file(dir, LEDGER_FILE, &inner.ledger.to_json()) {
                eprintln!("ruya-update: cannot write the download ledger: {e}");
            }
        }
    }

    // ---- admin calls -----------------------------------------------------------------

    /// `admin`: the caller is root, or the shell while the active profile is an admin. A paused
    /// download ends as cancelled: resumed, it would stage the newer image over the rollback.
    pub fn rollback(&self, admin: bool, clock: &dyn Clock) -> Status {
        if !admin {
            return Status::Forbidden;
        }
        // Busy at once rather than after a download that holds `commands`.
        if self.lock().state.running() {
            return Status::Busy;
        }
        // `commands` is held to the end: a check begun meanwhile waits for it and then sees the
        // rolled-back host. (`inner` is never held while waiting: status reads take it.) The
        // rules are asked again under it, because the host may have changed while waiting.
        let _cmd = self.command_lock();
        {
            let inner = self.lock();
            if inner.state.running() {
                return Status::Busy;
            }
            if inner.host.rollback.is_none() || inner.host.rollback_queued {
                return Status::Unavailable;
            }
        }
        let result = self.bootc.rollback().and_then(|()| self.bootc.status());
        let mut inner = self.lock();
        match result {
            Err(e) => {
                inner.error = e;
                Status::Failed
            }
            Ok(host) => {
                inner.host = host;
                inner.available.clear();
                inner.error.clear();
                self.cancel_paused(&mut inner, clock);
                // A job that began while `bootc` worked settles the state itself.
                if !inner.state.running() {
                    inner.state = State::Staged;
                }
                Status::Ok
            }
        }
    }

    /// A paused download ends as cancelled: it was for the other channel.
    pub fn set_channel(&self, channel: &str, admin: bool, clock: &dyn Clock) -> Status {
        if !admin {
            return Status::Forbidden;
        }
        if !CHANNELS.contains(&channel) {
            return Status::Invalid;
        }
        let mut inner = self.lock();
        if inner.state.running() {
            return Status::Busy;
        }
        if let Some(dir) = &self.dir {
            if save_channel(dir, channel).is_err() {
                return Status::Failed;
            }
        }
        inner.channel = Some(channel.to_owned());
        inner.channel_problem.clear();
        inner.available.clear();
        self.cancel_paused(&mut inner, clock);
        if matches!(inner.state, State::UpToDate | State::Failed) {
            inner.state = State::Idle;
        }
        Status::Ok
    }

    pub fn set_auto_restart(&self, enabled: bool, admin: bool) -> Status {
        if !admin {
            return Status::Forbidden;
        }
        let mut inner = self.lock();
        if let Some(dir) = &self.dir {
            let text = if enabled { "on" } else { "off" };
            if save_file(dir, AUTO_RESTART_FILE, text).is_err() {
                return Status::Failed;
            }
        }
        inner.auto_restart = enabled;
        if !enabled {
            inner.schedule.cancel_restart();
        }
        Status::Ok
    }

    /// Input arrived (the shell's report): the console is not idle, and `app_running` says
    /// whether an app is in front. Returns whether an announced restart was called off, which
    /// is a change of the record.
    pub fn report_activity(&self, now: i64, app_running: bool) -> bool {
        self.lock().schedule.activity(now, app_running)
    }

    // ---- schedule --------------------------------------------------------------------

    /// One look at the schedule, once a minute and at start (after `refresh`): the daily check
    /// with the download it leads to, then the restart into a staged image. Blocks while a
    /// check or download runs, so it belongs on its own thread.
    pub fn tick(&self, clock: &dyn Clock, reboot: &dyn Reboot, emit: &mut dyn FnMut()) {
        let now = clock.now();
        self.lock().schedule.seen(now);
        self.scheduled_resume(clock, emit);
        self.scheduled_check(clock, emit);
        self.scheduled_download_retry(clock, emit);
        self.scheduled_restart(clock, reboot, emit);
    }

    /// A download the policy paused ("playing") runs again by itself once no app runs; one the
    /// user paused waits for the user.
    fn scheduled_resume(&self, clock: &dyn Clock, emit: &mut dyn FnMut()) {
        {
            let inner = self.lock();
            let by_policy = inner
                .job
                .as_ref()
                .is_some_and(|j| j.state == JobState::Paused && j.reason == REASON_PLAYING);
            if !by_policy || inner.schedule.app_running() {
                return;
            }
        }
        self.scheduled_download(clock, emit);
    }

    fn scheduled_check(&self, clock: &dyn Clock, emit: &mut dyn FnMut()) {
        let now = clock.now();
        {
            let inner = self.lock();
            // A staged image waits for its restart: a check could only say "staged".
            if inner.state == State::Staged || !inner.schedule.check_due(inner.last_check, now) {
                return;
            }
        }
        if self.begin_check() != Status::Ok {
            return; // a job is running; the next tick looks again
        }
        self.lock().schedule.attempted(now);
        emit();
        self.run_check(now, emit);
        // Only what this check found (not an older find that the check could not confirm).
        let found = {
            let inner = self.lock();
            inner.state == State::Idle && !inner.available.is_empty()
        };
        if found {
            self.scheduled_download(clock, emit);
        }
    }

    /// A download the schedule starts (or a paused one it continues): if it fails it is tried
    /// again after `RETRY_SECS`.
    fn scheduled_download(&self, clock: &dyn Clock, emit: &mut dyn FnMut()) {
        let now = clock.now();
        if self.begin_download(now) != Status::Ok {
            return;
        }
        emit();
        self.run_download(clock, emit);
        let mut inner = self.lock();
        if inner.state == State::Failed {
            inner.schedule.download_failed(now);
        }
    }

    /// The retry of a failed scheduled download. Anything that settled it meanwhile (the user's
    /// own download, a new check, a channel change) leaves nothing to retry: `begin_download`
    /// refuses without an update found and clears the note.
    fn scheduled_download_retry(&self, clock: &dyn Clock, emit: &mut dyn FnMut()) {
        let now = clock.now();
        {
            let mut inner = self.lock();
            if !inner.schedule.download_retry_due(now) {
                return;
            }
            if inner.state != State::Failed || inner.available.is_empty() {
                inner.schedule.download_begun();
                return;
            }
        }
        self.scheduled_download(clock, emit);
    }

    /// The restart into a staged image: announced first, done at the look after the grace period
    /// if the rules still hold (`Schedule::restart_step`).
    fn scheduled_restart(&self, clock: &dyn Clock, reboot: &dyn Reboot, emit: &mut dyn FnMut()) {
        let (due, changed) = {
            let mut inner = self.lock();
            let can = inner.state == State::Staged && inner.auto_restart;
            let before = inner.schedule.pending_restart();
            let due = inner
                .schedule
                .restart_step(clock.now(), clock.minute_of_day(), can);
            (due, inner.schedule.pending_restart() != before)
        };
        if changed {
            emit();
        }
        if !due {
            return;
        }
        eprintln!("ruya-update: the console is idle, restarting into the staged image");
        if let Err(e) = reboot.reboot() {
            eprintln!("ruya-update: automatic restart failed: {e}");
        }
    }

    /// The image reference to `bootc switch` to, when the chosen channel is not the tag the host
    /// tracks.
    fn switch_target(&self) -> Option<String> {
        let inner = self.lock();
        let channel = inner.channel.as_deref()?;
        // Not read yet: a reference like ":beta" would be a switch to nowhere.
        if inner.host.tracked.is_empty() {
            return None;
        }
        (tag_of(&inner.host.tracked) != channel).then(|| with_tag(&inner.host.tracked, channel))
    }
}

/// The state after a download stopped without staging: a staged image from before still waits.
fn idle_or_staged(host: &HostStatus) -> State {
    if staged_label(host).is_some() {
        State::Staged
    } else {
        State::Idle
    }
}

fn staged_label(host: &HostStatus) -> Option<String> {
    if let Some(staged) = &host.staged {
        return Some(staged.label());
    }
    if host.rollback_queued {
        return host.rollback.as_ref().map(|d| d.label());
    }
    None
}

/// The channel shown: the one chosen, else the host's tag when it is a channel, else "stable".
fn effective_channel(inner: &Inner) -> String {
    if let Some(channel) = &inner.channel {
        return channel.clone();
    }
    let tag = tag_of(&inner.host.tracked);
    if CHANNELS.contains(&tag) {
        tag.to_owned()
    } else {
        CHANNELS[0].to_owned()
    }
}

/// What a finished check found: "" for nothing.
fn available_version(host: &HostStatus, switching: bool, inner: &Inner) -> String {
    if switching {
        return inner.channel.clone().unwrap_or_default();
    }
    let Some(update) = &host.cached_update else {
        return String::new();
    };
    let known = |digest: &str| {
        host.booted.as_ref().is_some_and(|d| d.digest == digest)
            || host.staged.as_ref().is_some_and(|d| d.digest == digest)
    };
    if update.digest.is_empty() || known(&update.digest) {
        String::new()
    } else {
        update.label()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bootc::{Deployment, FakeBootc};
    use crate::schedule::{FakeClock, FakeReboot, ZonedClock};

    fn dep(image: &str, version: &str, digest: &str) -> Deployment {
        Deployment {
            image: image.to_owned(),
            version: version.to_owned(),
            digest: digest.to_owned(),
        }
    }

    fn host() -> HostStatus {
        HostStatus {
            tracked: "reg:5000/ruyaos:stable".to_owned(),
            booted: Some(dep("reg:5000/ruyaos:stable", "0.0.19", "sha256:a")),
            staged: None,
            rollback: Some(dep("reg:5000/ruyaos:stable", "0.0.18", "sha256:z")),
            rollback_queued: false,
            cached_update: Some(dep("reg:5000/ruyaos:stable", "0.0.20", "sha256:b")),
        }
    }

    fn service(host: HostStatus) -> Update<FakeBootc> {
        let u = Update::new(FakeBootc::new(host), None);
        u.refresh().expect("refresh");
        u
    }

    /// A clock for the calls that stamp a job or count a day.
    fn clk() -> FakeClock {
        FakeClock::new(1000, 12 * 60)
    }

    fn check(u: &Update<FakeBootc>) {
        assert_eq!(u.begin_check(), Status::Ok);
        u.run_check(1000, &mut || {});
    }

    #[test]
    fn status_strings_are_the_contract() {
        let all = [
            (Status::Ok, "ok"),
            (Status::Busy, "busy"),
            (Status::Unavailable, "unavailable"),
            (Status::Invalid, "invalid"),
            (Status::Forbidden, "forbidden"),
            (Status::Failed, "failed"),
        ];
        for (s, text) in all {
            assert_eq!(s.as_str(), text);
        }
        let states = [
            (State::Idle, "idle"),
            (State::Checking, "checking"),
            (State::Downloading, "downloading"),
            (State::Staged, "staged"),
            (State::UpToDate, "up-to-date"),
            (State::Failed, "failed"),
        ];
        for (s, text) in states {
            assert_eq!(s.as_str(), text);
        }
    }

    #[test]
    fn the_record_comes_from_bootc() {
        let r = service(host()).record();
        assert_eq!(r.state, State::Idle);
        assert_eq!(r.current, "0.0.19");
        assert_eq!(r.channel, "stable");
        assert_eq!(r.available, "");
        assert_eq!(r.staged, "");
        assert_eq!(r.last_check, 0);
        assert!(r.rollback_available);
    }

    #[test]
    fn a_dev_tag_is_stable_until_a_channel_is_chosen() {
        let mut h = host();
        h.tracked = "reg:5000/ruyaos:0.0.19".to_owned();
        assert_eq!(service(h).record().channel, "stable");
    }

    #[test]
    fn check_finds_a_newer_image() {
        let u = service(host());
        assert_eq!(u.begin_check(), Status::Ok);
        assert_eq!(u.record().state, State::Checking);
        u.run_check(1234, &mut || {});
        let r = u.record();
        assert_eq!(r.state, State::Idle);
        assert_eq!(r.available, "0.0.20");
        assert_eq!(r.last_check, 1234);
        assert_eq!(u.bootc.calls(), ["status", "check", "status"]);
    }

    #[test]
    fn check_without_news_is_up_to_date() {
        let mut h = host();
        h.cached_update = None;
        let u = service(h);
        check(&u);
        assert_eq!(u.record().state, State::UpToDate);
    }

    #[test]
    fn a_cached_update_equal_to_the_booted_image_is_no_news() {
        let mut h = host();
        h.cached_update = Some(dep("reg:5000/ruyaos:stable", "0.0.19", "sha256:a"));
        let u = service(h);
        check(&u);
        assert_eq!(u.record().state, State::UpToDate);
    }

    #[test]
    fn a_failed_check_says_why() {
        let u = service(host());
        assert_eq!(u.begin_check(), Status::Ok);
        u.bootc.fail_next("registry unreachable");
        u.run_check(5, &mut || {});
        let r = u.record();
        assert_eq!(r.state, State::Failed);
        assert_eq!(r.error, "registry unreachable");
        assert_eq!(r.last_check, 0, "a failed check is not a finished check");
        assert_eq!(u.begin_check(), Status::Ok, "and can be retried");
        assert_eq!(u.record().error, "");
    }

    #[test]
    fn busy_while_a_check_runs() {
        let u = service(host());
        assert_eq!(u.begin_check(), Status::Ok);
        assert_eq!(u.begin_check(), Status::Busy);
        assert_eq!(u.begin_download(1000), Status::Busy);
        assert_eq!(u.rollback(true, &clk()), Status::Busy);
        assert_eq!(u.set_channel("beta", true, &clk()), Status::Busy);
    }

    #[test]
    fn download_needs_a_found_update() {
        let u = service(host());
        assert_eq!(u.begin_download(1000), Status::Unavailable);
    }

    #[test]
    fn download_stages_the_image() {
        let u = service(host());
        check(&u);
        assert_eq!(u.begin_download(1000), Status::Ok);
        let r = u.record();
        assert_eq!((r.state, r.progress), (State::Downloading, 0));
        assert_eq!(u.begin_check(), Status::Busy);
        assert_eq!(u.begin_download(1000), Status::Busy);
        let mut changes = 0;
        u.run_download(&clk(), &mut || changes += 1);
        let r = u.record();
        assert_eq!(r.state, State::Staged);
        assert_eq!(r.staged, "0.0.20");
        assert_eq!(r.available, "");
        assert_eq!(r.progress, 100);
        assert_eq!(changes, 1);
        assert!(u.bootc.calls().contains(&"upgrade".to_owned()));
        assert_eq!(u.begin_download(1000), Status::Unavailable);
    }

    #[test]
    fn a_failed_download_keeps_the_found_update() {
        let u = service(host());
        check(&u);
        assert_eq!(u.begin_download(1000), Status::Ok);
        u.bootc.fail_next("disk full");
        u.run_download(&clk(), &mut || {});
        let r = u.record();
        assert_eq!(r.state, State::Failed);
        assert_eq!(r.error, "disk full");
        assert_eq!(r.available, "0.0.20");
        assert_eq!(u.begin_download(1000), Status::Ok, "retry");
    }

    #[test]
    fn a_staged_image_is_found_again_by_a_check() {
        let u = service(host());
        check(&u);
        assert_eq!(u.begin_download(1000), Status::Ok);
        u.run_download(&clk(), &mut || {});
        check(&u);
        assert_eq!(u.record().state, State::Staged);
    }

    #[test]
    fn a_staged_image_at_start_offers_the_restart() {
        let mut h = host();
        h.staged = Some(dep("reg:5000/ruyaos:stable", "0.0.20", "sha256:b"));
        let r = service(h).record();
        assert_eq!((r.state, r.staged.as_str()), (State::Staged, "0.0.20"));
    }

    #[test]
    fn rollback_is_for_admins() {
        let u = service(host());
        assert_eq!(u.rollback(false, &clk()), Status::Forbidden);
        assert!(!u.bootc.calls().contains(&"rollback".to_owned()));
        assert!(u.record().rollback_available);
    }

    #[test]
    fn rollback_stages_the_previous_image_once() {
        let u = service(host());
        assert_eq!(u.rollback(true, &clk()), Status::Ok);
        let r = u.record();
        assert_eq!((r.state, r.staged.as_str()), (State::Staged, "0.0.18"));
        assert!(!r.rollback_available);
        assert_eq!(u.rollback(true, &clk()), Status::Unavailable);
    }

    #[test]
    fn rollback_without_a_previous_image_is_unavailable() {
        let mut h = host();
        h.rollback = None;
        assert_eq!(service(h).rollback(true, &clk()), Status::Unavailable);
    }

    #[test]
    fn a_failing_rollback_is_failed_and_changes_nothing() {
        let u = service(host());
        u.bootc.fail_next("no");
        assert_eq!(u.rollback(true, &clk()), Status::Failed);
        let r = u.record();
        assert_eq!(r.state, State::Idle);
        assert!(r.rollback_available);
    }

    #[test]
    fn set_channel_rules() {
        let u = service(host());
        assert_eq!(u.set_channel("beta", false, &clk()), Status::Forbidden);
        assert_eq!(u.set_channel("nightly", true, &clk()), Status::Invalid);
        assert_eq!(u.record().channel, "stable");
        check(&u);
        assert_eq!(u.record().available, "0.0.20");
        assert_eq!(u.set_channel("beta", true, &clk()), Status::Ok);
        let r = u.record();
        assert_eq!((r.channel.as_str(), r.available.as_str()), ("beta", ""));
        assert_eq!(u.begin_download(1000), Status::Unavailable);
    }

    #[test]
    fn set_channel_leaves_up_to_date_and_failed() {
        let mut h = host();
        h.cached_update = None;
        let u = service(h);
        check(&u);
        assert_eq!(u.record().state, State::UpToDate);
        assert_eq!(u.set_channel("beta", true, &clk()), Status::Ok);
        assert_eq!(u.record().state, State::Idle);
    }

    #[test]
    fn a_new_channel_is_switched_to_on_download() {
        let u = service(host());
        assert_eq!(u.set_channel("beta", true, &clk()), Status::Ok);
        check(&u);
        let r = u.record();
        assert_eq!((r.state, r.available.as_str()), (State::Idle, "beta"));
        assert!(!u.bootc.calls().contains(&"check".to_owned()));
        assert_eq!(u.begin_download(1000), Status::Ok);
        u.run_download(&clk(), &mut || {});
        assert!(u
            .bootc
            .calls()
            .contains(&"switch reg:5000/ruyaos:beta".to_owned()));
        let r = u.record();
        assert_eq!((r.state, r.staged.as_str()), (State::Staged, "beta"));
        assert_eq!(r.channel, "beta");
    }

    #[test]
    fn the_channel_survives_a_restart() {
        let dir = tempfile::tempdir().expect("tempdir");
        let u = Update::new(FakeBootc::new(host()), Some(dir.path().join("state")));
        assert_eq!(u.set_channel("beta", true, &clk()), Status::Ok);
        let u = Update::new(FakeBootc::new(host()), Some(dir.path().join("state")));
        assert_eq!(u.record().channel, "beta");
    }

    #[test]
    fn a_corrupt_state_file_does_not_stop_the_service() {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join(CHANNEL_FILE), "nightly").expect("write");
        let u = Update::new(FakeBootc::new(host()), Some(dir.path().to_owned()));
        u.refresh().expect("refresh");
        let r = u.record();
        assert_eq!(r.state, State::Failed);
        assert!(r.error.contains(CHANNEL_FILE), "{}", r.error);
        assert!(r.error.contains("nightly"), "{}", r.error);
        assert_eq!(r.channel, "stable", "the host's own tag is followed");

        // A check still works, and the file is still reported afterwards.
        check(&u);
        let r = u.record();
        assert_eq!((r.state, r.available.as_str()), (State::Failed, "0.0.20"));
        assert!(r.error.contains(CHANNEL_FILE));
        assert!(!u.bootc.calls().iter().any(|c| c.starts_with("switch")));

        // SetChannel replaces the file and clears the report.
        assert_eq!(u.set_channel("stable", true, &clk()), Status::Ok);
        let r = u.record();
        assert_eq!((r.state, r.error.as_str()), (State::Idle, ""));
        let dir_text = fs::read_to_string(dir.path().join(CHANNEL_FILE)).expect("read");
        assert_eq!(dir_text, "stable\n");
    }

    #[test]
    fn an_unreadable_state_file_does_not_stop_the_service_either() {
        let dir = tempfile::tempdir().expect("tempdir");
        // A directory where the file belongs: reading it fails with something other than NotFound.
        fs::create_dir(dir.path().join(CHANNEL_FILE)).expect("mkdir");
        let u = Update::new(FakeBootc::new(host()), Some(dir.path().to_owned()));
        assert_eq!(u.record().state, State::Failed);
        assert!(u.record().error.contains(CHANNEL_FILE));
    }

    #[test]
    fn a_staged_image_is_not_hidden_by_the_bad_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join(CHANNEL_FILE), "nightly").expect("write");
        let mut h = host();
        h.staged = Some(dep("reg:5000/ruyaos:stable", "0.0.20", "sha256:b"));
        let u = Update::new(FakeBootc::new(h), Some(dir.path().to_owned()));
        u.refresh().expect("refresh");
        assert_eq!(u.record().state, State::Staged);
    }

    #[test]
    fn without_a_known_tracked_image_a_check_fails_before_any_switch() {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join(CHANNEL_FILE), "beta\n").expect("write");
        let mut h = host();
        h.tracked = String::new();
        let u = Update::new(FakeBootc::new(h), Some(dir.path().to_owned()));
        // The start-up reading has not finished: nothing is known about the host.
        assert_eq!(u.begin_check(), Status::Ok);
        u.run_check(5, &mut || {});
        let r = u.record();
        assert_eq!(r.state, State::Failed);
        assert!(r.error.contains("which image"), "{}", r.error);
        assert!(!u.bootc.calls().iter().any(|c| c.starts_with("switch")));
        assert!(!u.bootc.calls().contains(&"check".to_owned()));
        assert_eq!(u.begin_download(1000), Status::Unavailable);
    }

    #[test]
    fn a_check_learns_the_tracked_image_when_the_first_reading_failed() {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join(CHANNEL_FILE), "beta\n").expect("write");
        let u = Update::new(FakeBootc::new(host()), Some(dir.path().to_owned()));
        // No refresh() yet: the check reads the host itself and finds a channel to switch to.
        check(&u);
        let r = u.record();
        assert_eq!((r.state, r.available.as_str()), (State::Idle, "beta"));
        assert!(!u.bootc.calls().iter().any(|c| c.starts_with("switch")));
    }

    #[test]
    fn a_download_that_staged_nothing_is_a_failure() {
        let u = service(host());
        check(&u);
        assert_eq!(u.begin_download(1000), Status::Ok);
        // The image vanished from the registry between the check and the download.
        u.bootc.set_cached_update(None);
        u.run_download(&clk(), &mut || {});
        let r = u.record();
        assert_eq!(r.state, State::Failed);
        assert_eq!(r.error, "bootc staged nothing");
        assert_eq!(r.progress, 0);
        assert_eq!(r.staged, "");
    }

    #[test]
    fn a_check_begun_during_a_rollback_ends_staged_with_the_rollback() {
        let u = service(host());
        let (started, release) = u.bootc.hold_next_rollback();
        std::thread::scope(|scope| {
            let rollback = scope.spawn(|| u.rollback(true, &clk()));
            // `bootc rollback` is running, with `commands` held.
            started.recv().expect("rollback started");
            assert_eq!(
                u.begin_check(),
                Status::Ok,
                "no job runs yet: a check may begin"
            );
            let check = scope.spawn(|| u.run_check(7, &mut || {}));
            std::thread::sleep(std::time::Duration::from_millis(50));
            assert_eq!(u.record().state, State::Checking, "it waits for bootc");
            release.send(()).expect("release");
            assert_eq!(rollback.join().expect("rollback thread"), Status::Ok);
            check.join().expect("check thread");
        });
        let r = u.record();
        assert_eq!((r.state, r.staged.as_str()), (State::Staged, "0.0.18"));
        assert!(!r.rollback_available);
        assert_eq!(r.available, "");
        assert_eq!(r.last_check, 7);
        // The check read the host after the rollback, never before.
        let calls = u.bootc.calls();
        let at = |name: &str| calls.iter().position(|c| c == name).expect("call");
        assert!(at("rollback") < at("check"), "{calls:?}");
    }

    #[test]
    fn a_rollback_does_not_wait_for_a_download() {
        let u = service(host());
        check(&u);
        assert_eq!(u.begin_download(1000), Status::Ok);
        assert_eq!(u.rollback(true, &clk()), Status::Busy);
    }

    // ---- schedule --------------------------------------------------------------------

    const T0: i64 = 1_800_000_000;
    const DAY: i64 = 24 * 3600;
    const IDLE: i64 = 30 * 60;
    const GRACE: i64 = crate::schedule::GRACE_SECS;
    const RETRY: i64 = crate::schedule::RETRY_SECS;
    /// 03:10 local time.
    const NIGHT: u32 = 3 * 60 + 10;

    fn calls_named(u: &Update<FakeBootc>, name: &str) -> usize {
        u.bootc.calls().iter().filter(|c| *c == name).count()
    }

    /// A service whose remembered last check was `ago` seconds before `T0`.
    fn service_checked(ago: i64, h: HostStatus) -> (Update<FakeBootc>, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join(LAST_CHECK_FILE), format!("{}\n", T0 - ago)).expect("write");
        let u = Update::new(FakeBootc::new(h), Some(dir.path().to_owned()));
        u.refresh().expect("refresh");
        (u, dir)
    }

    fn staged_service() -> Update<FakeBootc> {
        let mut h = host();
        h.staged = Some(dep("reg:5000/ruyaos:stable", "0.0.20", "sha256:b"));
        service(h)
    }

    #[test]
    fn a_check_runs_at_start_when_the_last_one_is_old() {
        let clock = FakeClock::new(T0, NIGHT);
        let reboot = FakeReboot::default();
        let (u, _dir) = service_checked(DAY + 1, host());
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(calls_named(&u, "check"), 1);
        assert_eq!(u.record().last_check, T0);

        // Never checked (nothing remembered) is old too.
        let u = service(host());
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(calls_named(&u, "check"), 1);
    }

    #[test]
    fn a_check_does_not_run_at_start_when_the_last_one_is_new() {
        let clock = FakeClock::new(T0, NIGHT);
        let reboot = FakeReboot::default();
        let (u, _dir) = service_checked(DAY - 60, host());
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(calls_named(&u, "check"), 0);
        assert_eq!(
            u.record().last_check,
            T0 - DAY + 60,
            "remembered over a restart"
        );
    }

    #[test]
    fn the_check_repeats_every_24_hours() {
        let mut h = host();
        h.cached_update = None;
        let clock = FakeClock::new(T0, NIGHT);
        let reboot = FakeReboot::default();
        let (u, _dir) = service_checked(DAY + 1, h);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(calls_named(&u, "check"), 1);
        clock.set(T0 + DAY - 1, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(calls_named(&u, "check"), 1, "a second short of a day");
        clock.set(T0 + DAY, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(calls_named(&u, "check"), 2);
    }

    #[test]
    fn a_scheduled_check_that_finds_an_update_downloads_it() {
        let clock = FakeClock::new(T0, NIGHT);
        let u = service(host());
        let mut changes = 0;
        u.tick(&clock, &FakeReboot::default(), &mut || changes += 1);
        let r = u.record();
        assert_eq!((r.state, r.staged.as_str()), (State::Staged, "0.0.20"));
        assert_eq!(calls_named(&u, "upgrade"), 1);
        assert!(
            changes >= 3,
            "checking, found, downloading, staged: {changes}"
        );
    }

    #[test]
    fn a_manual_check_does_not_download() {
        let u = service(host());
        check(&u);
        assert_eq!(u.record().available, "0.0.20");
        assert_eq!(calls_named(&u, "upgrade"), 0);
        // The user's check counts as the day's check: the schedule leaves the find to them.
        let clock = FakeClock::new(1000 + 60, NIGHT);
        u.tick(&clock, &FakeReboot::default(), &mut || {});
        assert_eq!(calls_named(&u, "upgrade"), 0);
        assert_eq!(calls_named(&u, "check"), 1);
    }

    #[test]
    fn nothing_is_downloaded_when_there_is_nothing_new() {
        let mut h = host();
        h.cached_update = None;
        let u = service(h);
        u.tick(
            &FakeClock::new(T0, NIGHT),
            &FakeReboot::default(),
            &mut || {},
        );
        assert_eq!(u.record().state, State::UpToDate);
        assert_eq!(calls_named(&u, "upgrade"), 0);
    }

    #[test]
    fn a_failed_scheduled_check_is_retried_after_an_hour() {
        let clock = FakeClock::new(T0, NIGHT);
        let reboot = FakeReboot::default();
        let u = service(host());
        u.bootc.fail_next("offline");
        u.tick(&clock, &reboot, &mut || {});
        let r = u.record();
        assert_eq!((r.state, r.error.as_str()), (State::Failed, "offline"));
        assert_eq!(
            calls_named(&u, "upgrade"),
            0,
            "a failed check downloads nothing"
        );
        clock.set(T0 + 3599, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(calls_named(&u, "check"), 1);
        clock.set(T0 + 3600, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(calls_named(&u, "check"), 2);
        assert_eq!(
            u.record().state,
            State::Staged,
            "and this time it went through"
        );
    }

    #[test]
    fn no_scheduled_check_while_a_job_runs_or_an_update_waits() {
        let clock = FakeClock::new(T0, NIGHT);
        let u = service(host());
        assert_eq!(u.begin_check(), Status::Ok);
        u.tick(&clock, &FakeReboot::default(), &mut || {});
        assert_eq!(calls_named(&u, "check"), 0, "busy: skipped");

        let u = staged_service();
        u.tick(&clock, &FakeReboot::default(), &mut || {});
        assert_eq!(calls_named(&u, "check"), 0, "staged: nothing to look for");
    }

    #[test]
    fn the_console_restarts_only_when_it_is_quiet() {
        let reboot = FakeReboot::default();
        let u = staged_service();
        let clock = FakeClock::new(T0, NIGHT);

        u.tick(&clock, &reboot, &mut || {}); // the start counts as activity
        assert_eq!(reboot.count(), 0, "not idle yet");
        clock.set(T0 + IDLE - 1, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 0, "29:59 idle");

        // Activity resets the idle time.
        u.report_activity(T0 + IDLE - 1, false);
        clock.set(T0 + IDLE + 60, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 0);

        // An app in front blocks it however long the console is idle.
        u.report_activity(T0 + IDLE - 1, true);
        clock.set(T0 + 3 * IDLE, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 0, "app running");

        u.report_activity(T0 + IDLE - 1, false);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(
            reboot.count(),
            0,
            "idle, no app, 03:10, setting on: announced"
        );
        assert_eq!(u.record().restart_at, T0 + 3 * IDLE + GRACE);
        clock.set(T0 + 3 * IDLE + GRACE, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 1);
    }

    #[test]
    fn the_console_restarts_only_inside_the_window() {
        let reboot = FakeReboot::default();
        let u = staged_service();
        let clock = FakeClock::new(T0, 12 * 60);
        u.tick(&clock, &reboot, &mut || {});
        for (minute, expected) in [(12 * 60, 0), (3 * 60 - 1, 0), (5 * 60, 0), (3 * 60, 1)] {
            clock.set(T0 + 2 * IDLE, minute);
            u.tick(&clock, &reboot, &mut || {});
            assert_eq!(reboot.count(), 0, "minute {minute}: at most announced");
            assert_eq!(
                u.record().restart_at != 0,
                expected == 1,
                "minute {minute}: announced only inside the window"
            );
        }
        clock.set(T0 + 2 * IDLE + GRACE, 3 * 60);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 1);
    }

    #[test]
    fn the_console_does_not_restart_with_the_setting_off_or_nothing_staged() {
        let reboot = FakeReboot::default();
        let clock = FakeClock::new(T0, NIGHT);
        let u = staged_service();
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(u.set_auto_restart(false, true), Status::Ok);
        clock.set(T0 + 2 * IDLE, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 0, "turned off");
        assert_eq!(u.set_auto_restart(true, true), Status::Ok);
        restart_after_grace(&u, &clock, &reboot);
        assert_eq!(reboot.count(), 1);

        // Nothing staged (the 03:10 check finds no update): nothing to restart into.
        let mut h = host();
        h.cached_update = None;
        let reboot = FakeReboot::default();
        let u = service(h);
        let clock = FakeClock::new(T0, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        clock.set(T0 + 2 * IDLE, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 0);
    }

    #[test]
    fn an_update_found_overnight_restarts_after_the_idle_time() {
        // The whole path: the tick checks, downloads, and 30 idle minutes later restarts.
        let reboot = FakeReboot::default();
        let clock = FakeClock::new(T0, NIGHT);
        let u = service(host());
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(u.record().state, State::Staged);
        assert_eq!(reboot.count(), 0);
        clock.set(T0 + IDLE, NIGHT + 30);
        restart_after_grace(&u, &clock, &reboot);
        assert_eq!(reboot.count(), 1);
    }

    #[test]
    fn a_failed_restart_is_tried_again_at_the_next_tick() {
        let reboot = FakeReboot::default();
        let u = staged_service();
        let clock = FakeClock::new(T0, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        clock.set(T0 + IDLE, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        clock.set(T0 + IDLE + GRACE, NIGHT);
        reboot.fail_next();
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 0);
        clock.set(T0 + IDLE + GRACE + 60, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 1);
    }

    /// The announcement, then the restart at the first look after the grace period.
    fn restart_after_grace(u: &Update<FakeBootc>, clock: &FakeClock, reboot: &FakeReboot) {
        u.tick(clock, reboot, &mut || {});
        assert_eq!(reboot.count(), 0, "announced first");
        let now = clock.now();
        clock.set(now + GRACE, clock.minute_of_day());
        u.tick(clock, reboot, &mut || {});
    }

    // ---- notice before the restart -----------------------------------------------------

    /// A staged service at 03:10 that has been idle for 30 minutes.
    fn quiet_service() -> (Update<FakeBootc>, FakeClock, FakeReboot) {
        let u = staged_service();
        let clock = FakeClock::new(T0, NIGHT);
        let reboot = FakeReboot::default();
        u.tick(&clock, &reboot, &mut || {});
        clock.set(T0 + IDLE, NIGHT);
        (u, clock, reboot)
    }

    /// A staged service that has been idle for the idle time at `start` (unix seconds) in the zone
    /// `utc_offset` east of UTC, with the clock at `start + IDLE`.
    fn quiet_service_in(
        start: i64,
        utc_offset: i64,
    ) -> (Update<FakeBootc>, ZonedClock, FakeReboot) {
        let u = staged_service();
        let clock = ZonedClock::new(start, utc_offset);
        let reboot = FakeReboot::default();
        u.tick(&clock, &reboot, &mut || {});
        clock.set_now(start + IDLE);
        (u, clock, reboot)
    }

    #[test]
    fn the_restart_window_is_local_time_not_utc() {
        const HOUR: i64 = 3600;
        const TOKYO: i64 = 9 * HOUR;
        let utc_midnight = T0 - 8 * HOUR;

        // 18:10 UTC: 03:10 in Tokyo, so it restarts there ...
        let start = utc_midnight + 18 * HOUR + 10 * 60;
        let (u, clock, reboot) = quiet_service_in(start, TOKYO);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(
            u.record().restart_at,
            start + IDLE + GRACE,
            "03:40 in Tokyo"
        );
        clock.set_now(start + IDLE + GRACE);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 1);

        // ... and not in London (UTC), where it is 18:40.
        let (u, clock, reboot) = quiet_service_in(start, 0);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(u.record().restart_at, 0);
        clock.set_now(start + IDLE + GRACE);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 0);

        // 03:10 UTC is 12:10 in Tokyo: the UTC hour must not open the window there.
        let start = utc_midnight + 3 * HOUR + 10 * 60;
        let (u, clock, reboot) = quiet_service_in(start, TOKYO);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(u.record().restart_at, 0);
        clock.set_now(start + IDLE + GRACE);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 0);
    }

    #[test]
    fn choosing_another_zone_moves_the_window_at_once() {
        const HOUR: i64 = 3600;
        let start = T0 - 8 * HOUR + 18 * HOUR + 10 * 60;
        let (u, clock, reboot) = quiet_service_in(start, 0);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(u.record().restart_at, 0, "18:40 where the console was");

        clock.set_zone(9 * HOUR); // the owner chose Tokyo: 03:40 now
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(u.record().restart_at, start + IDLE + GRACE);

        clock.set_zone(0); // and back before the restart: it is called off
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(u.record().restart_at, 0);
        clock.set_now(start + IDLE + GRACE);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 0);
    }

    #[test]
    fn the_restart_is_announced_two_minutes_ahead() {
        let (u, clock, reboot) = quiet_service();
        assert_eq!(u.record().restart_at, 0);
        let mut changes = 0;
        u.tick(&clock, &reboot, &mut || changes += 1);
        assert_eq!(u.record().restart_at, T0 + IDLE + GRACE);
        assert_eq!(changes, 1, "StatusChanged when it is set");
        assert_eq!(reboot.count(), 0, "no reboot yet");
        clock.set(T0 + IDLE + GRACE - 1, NIGHT);
        u.tick(&clock, &reboot, &mut || changes += 1);
        assert_eq!(reboot.count(), 0, "119 s: not yet");
        assert_eq!(changes, 1, "and nothing new to say");
        assert_eq!(
            u.record().restart_at,
            T0 + IDLE + GRACE,
            "the time does not move"
        );
        clock.set(T0 + IDLE + GRACE, NIGHT);
        u.tick(&clock, &reboot, &mut || changes += 1);
        assert_eq!(reboot.count(), 1, "120 s: one reboot");
    }

    #[test]
    fn activity_calls_off_the_restart_and_the_idle_time_starts_over() {
        let (u, clock, reboot) = quiet_service();
        u.tick(&clock, &reboot, &mut || {});
        assert_ne!(u.record().restart_at, 0);
        assert!(
            u.report_activity(T0 + IDLE + 30, false),
            "there was one to call off"
        );
        assert_eq!(u.record().restart_at, 0, "cleared at once");
        assert!(
            !u.report_activity(T0 + IDLE + 31, false),
            "nothing announced now"
        );
        clock.set(T0 + IDLE + GRACE + 60, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 0, "no reboot follows");
        assert_eq!(u.record().restart_at, 0);
        // Quiet again only after 30 more idle minutes (counted from the last report, +31 s).
        clock.set(T0 + IDLE + 31 + IDLE - 1, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(u.record().restart_at, 0, "29:59 since the activity");
        clock.set(T0 + IDLE + 31 + IDLE, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(u.record().restart_at, T0 + 2 * IDLE + 31 + GRACE);
        clock.set(T0 + 2 * IDLE + 31 + GRACE, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 1);
    }

    #[test]
    fn an_app_starting_calls_off_the_restart() {
        let (u, clock, reboot) = quiet_service();
        u.tick(&clock, &reboot, &mut || {});
        assert!(u.report_activity(T0 + IDLE + 5, true));
        clock.set(T0 + 5 * IDLE, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!((reboot.count(), u.record().restart_at), (0, 0));
    }

    #[test]
    fn turning_the_setting_off_calls_off_the_restart() {
        let (u, clock, reboot) = quiet_service();
        u.tick(&clock, &reboot, &mut || {});
        assert_ne!(u.record().restart_at, 0);
        assert_eq!(u.set_auto_restart(false, true), Status::Ok);
        assert_eq!(u.record().restart_at, 0, "cleared at once");
        clock.set(T0 + IDLE + 10 * GRACE, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(reboot.count(), 0);
        // On again: a new announcement with a new grace period, not the old one.
        assert_eq!(u.set_auto_restart(true, true), Status::Ok);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(u.record().restart_at, T0 + IDLE + 10 * GRACE + GRACE);
        assert_eq!(reboot.count(), 0);
    }

    #[test]
    fn nothing_staged_during_the_grace_calls_off_the_restart() {
        let (u, clock, reboot) = quiet_service();
        u.tick(&clock, &reboot, &mut || {});
        assert_ne!(u.record().restart_at, 0);
        // The image is no longer staged.
        {
            let mut inner = u.lock();
            inner.state = State::UpToDate;
            inner.last_check = T0 + IDLE; // no scheduled check brings the staged image back
        }
        assert_eq!(u.record().restart_at, 0, "a client never reads a stale one");
        let mut changes = 0;
        clock.set(T0 + IDLE + GRACE, NIGHT);
        u.tick(&clock, &reboot, &mut || changes += 1);
        assert_eq!(reboot.count(), 0);
        assert_eq!(changes, 1, "the schedule says it is gone");
        u.lock().state = State::Staged;
        assert_eq!(u.record().restart_at, 0);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(
            u.record().restart_at,
            T0 + IDLE + 2 * GRACE,
            "a new announcement"
        );
    }

    #[test]
    fn leaving_the_window_during_the_grace_calls_off_the_restart() {
        let (u, clock, reboot) = quiet_service();
        clock.set(T0 + IDLE, 5 * 60 - 1);
        u.tick(&clock, &reboot, &mut || {});
        assert_ne!(u.record().restart_at, 0);
        clock.set(T0 + IDLE + GRACE, 5 * 60 + 1);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!((reboot.count(), u.record().restart_at), (0, 0));
    }

    #[test]
    fn an_announcement_set_far_ahead_by_a_wrong_clock_is_replaced() {
        let (u, clock, reboot) = quiet_service();
        u.tick(&clock, &reboot, &mut || {});
        // The clock was set back an hour: the announced time is not waited for.
        clock.set(T0 + IDLE - 3600, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(
            u.record().restart_at,
            0,
            "idle time restarted from the earlier clock"
        );
        clock.set(T0 + IDLE - 3600 + IDLE, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(u.record().restart_at, T0 + IDLE - 3600 + IDLE + GRACE);
        assert_eq!(reboot.count(), 0);
    }

    // ---- download retry ----------------------------------------------------------------

    #[test]
    fn a_failed_scheduled_download_is_retried_after_an_hour() {
        let clock = FakeClock::new(T0, NIGHT);
        let reboot = FakeReboot::default();
        let u = service(host());
        u.bootc.fail_next_call("upgrade", "no space");
        u.tick(&clock, &reboot, &mut || {});
        let r = u.record();
        assert_eq!((r.state, r.error.as_str()), (State::Failed, "no space"));
        assert_eq!(calls_named(&u, "upgrade"), 1);
        clock.set(T0 + RETRY - 1, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(calls_named(&u, "upgrade"), 1, "not before the hour");
        assert_eq!(
            calls_named(&u, "check"),
            1,
            "and a download is not a new check"
        );
        clock.set(T0 + RETRY, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(calls_named(&u, "upgrade"), 2);
        assert_eq!(
            u.record().state,
            State::Staged,
            "and this time it went through"
        );
        clock.set(T0 + 3 * RETRY, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(calls_named(&u, "upgrade"), 2, "once is enough");
    }

    #[test]
    fn a_failed_retry_is_retried_again_after_another_hour() {
        let clock = FakeClock::new(T0, NIGHT);
        let reboot = FakeReboot::default();
        let u = service(host());
        u.bootc.fail_next_call("upgrade", "no space");
        u.tick(&clock, &reboot, &mut || {});
        clock.set(T0 + RETRY, NIGHT);
        u.bootc.fail_next_call("upgrade", "still no space");
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(calls_named(&u, "upgrade"), 2);
        clock.set(T0 + 2 * RETRY - 1, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(calls_named(&u, "upgrade"), 2);
        clock.set(T0 + 2 * RETRY, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(calls_named(&u, "upgrade"), 3);
        assert_eq!(u.record().state, State::Staged);
    }

    #[test]
    fn a_failed_manual_download_is_not_retried() {
        let u = service(host());
        check(&u);
        assert_eq!(u.begin_download(1000), Status::Ok);
        u.bootc.fail_next_call("upgrade", "no space");
        u.run_download(&clk(), &mut || {});
        assert_eq!(u.record().state, State::Failed);
        let clock = FakeClock::new(1000 + 10 * RETRY, NIGHT);
        u.tick(&clock, &FakeReboot::default(), &mut || {});
        clock.set(1000 + 20 * RETRY, NIGHT);
        u.tick(&clock, &FakeReboot::default(), &mut || {});
        assert_eq!(
            calls_named(&u, "upgrade"),
            1,
            "the user's download stays the user's"
        );
    }

    #[test]
    fn the_users_download_takes_over_a_scheduled_failure() {
        let clock = FakeClock::new(T0, NIGHT);
        let reboot = FakeReboot::default();
        let u = service(host());
        u.bootc.fail_next_call("upgrade", "no space");
        u.tick(&clock, &reboot, &mut || {});
        // The user presses Download; it fails too. That failure is theirs to retry.
        assert_eq!(u.begin_download(1000), Status::Ok);
        u.bootc.fail_next_call("upgrade", "no space");
        u.run_download(&clk(), &mut || {});
        clock.set(T0 + 2 * RETRY, NIGHT);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(calls_named(&u, "upgrade"), 2);
    }

    #[test]
    fn the_automatic_restart_setting_is_for_admins_and_survives_a_restart() {
        let dir = tempfile::tempdir().expect("tempdir");
        let new = || Update::new(FakeBootc::new(host()), Some(dir.path().to_owned()));
        let u = new();
        assert!(u.record().auto_restart, "on by default");
        assert_eq!(u.set_auto_restart(false, false), Status::Forbidden);
        assert!(u.record().auto_restart);
        assert_eq!(u.set_auto_restart(false, true), Status::Ok);
        assert!(!u.record().auto_restart);
        assert!(!new().record().auto_restart, "remembered");
        assert_eq!(u.set_auto_restart(true, true), Status::Ok);
        assert!(new().record().auto_restart);
    }

    #[test]
    fn a_bad_auto_restart_file_means_the_default() {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join(AUTO_RESTART_FILE), "maybe").expect("write");
        let u = Update::new(FakeBootc::new(host()), Some(dir.path().to_owned()));
        assert!(u.record().auto_restart);
    }

    // ---- the image job (RUY-29) ------------------------------------------------------

    use crate::bootc::{FakeEnd, FakeRun};
    use std::sync::Arc;

    fn bytes_ev(bytes: u64, total: u64) -> Progress {
        Progress::Bytes {
            bytes,
            bytes_total: total,
            bytes_cached: 0,
            steps: 0,
            steps_total: 10,
            steps_cached: 0,
        }
    }

    fn steps_ev(task: &str, steps: u64, total: u64) -> Progress {
        Progress::Steps {
            task: task.to_owned(),
            steps,
            steps_total: total,
        }
    }

    fn run(events: Vec<Progress>, end: FakeEnd) -> FakeRun {
        FakeRun { events, end }
    }

    /// A service that found 0.0.20, keeping its state in `dir` when given.
    fn found_in(dir: Option<&std::path::Path>, runs: Vec<FakeRun>) -> Arc<Update<FakeBootc>> {
        let fake = FakeBootc::new(host());
        fake.script_pulls(runs);
        let u = Update::new(fake, dir.map(|d| d.to_owned()));
        u.refresh().expect("refresh");
        check(&u);
        Arc::new(u)
    }

    fn found(runs: Vec<FakeRun>) -> Arc<Update<FakeBootc>> {
        found_in(None, runs)
    }

    /// Runs the download on a thread; returns once the fake's pull holds for its stop.
    fn download_until_held(u: &Arc<Update<FakeBootc>>) -> std::thread::JoinHandle<()> {
        let holds = u.bootc.pull_holds();
        let runner = u.clone();
        let thread = std::thread::spawn(move || runner.run_download(&clk(), &mut || {}));
        holds.recv().expect("the pull holds");
        thread
    }

    fn job(u: &Update<FakeBootc>) -> JobRecord {
        u.job_record(0).expect("a job")
    }

    #[test]
    fn new_status_strings_are_the_contract() {
        assert_eq!(Status::WrongState.as_str(), "wrong-state");
        assert_eq!(Status::Unsupported.as_str(), "unsupported");
    }

    #[test]
    fn a_download_reports_bytes_then_the_install() {
        let u = found(vec![run(
            vec![
                bytes_ev(0, 1000),
                bytes_ev(500, 1000),
                bytes_ev(1000, 1000),
                steps_ev("importing", 0, 1),
                steps_ev("importing", 1, 1),
                steps_ev("deploying", 3, 3),
            ],
            FakeEnd::Done,
        )]);
        assert!(
            u.job_record(0).is_none(),
            "no job before the first download"
        );
        assert_eq!(u.begin_download(1000), Status::Ok);
        let j = job(&u);
        assert_eq!(
            (j.id.as_str(), j.title.as_str()),
            ("os-1000", "RuyaOS 0.0.20")
        );
        assert_eq!((j.state, j.phase, j.percent), ("running", "download", 0));
        let mut seen = Vec::new();
        u.run_download(&clk(), &mut || {
            let j = u.job_record(0).expect("a job");
            seen.push((j.phase, j.percent, u.record().progress));
        });
        // The clock stands still: the first event, the phase change and the end are sent, the
        // other byte events wait for the next second.
        assert_eq!(
            seen,
            [
                ("download", 0, 0),
                ("install", 90, 90),
                ("install", 100, 100)
            ]
        );
        let j = job(&u);
        assert_eq!((j.state, j.status.as_str()), ("finished", "ok"));
        assert_eq!(
            (j.bytes_done, j.bytes_total, j.finished),
            (1000, 1000, 1000)
        );
        assert_eq!(u.record().state, State::Staged);
    }

    #[test]
    fn changes_are_sent_once_a_second_while_bytes_arrive() {
        let u = found(vec![run(
            vec![bytes_ev(0, 1000), bytes_ev(100, 1000), bytes_ev(200, 1000)],
            FakeEnd::Done,
        )]);
        assert_eq!(u.begin_download(1000), Status::Ok);
        let mut sent = 0;
        let clock = FakeClock::new(1000, 0);
        u.on_progress(&bytes_ev(0, 1000), &clock, &mut || sent += 1);
        u.on_progress(&bytes_ev(100, 1000), &clock, &mut || sent += 1);
        assert_eq!(sent, 1, "the second within the same second waits");
        clock.set(1001, 0);
        u.on_progress(&bytes_ev(200, 1000), &clock, &mut || sent += 1);
        assert_eq!(sent, 2);
    }

    #[test]
    fn pause_keeps_the_job_and_resume_continues_it() {
        let u = found(vec![
            run(
                vec![bytes_ev(0, 1000), bytes_ev(400, 1000)],
                FakeEnd::HoldForStop,
            ),
            run(
                vec![
                    bytes_ev(0, 700),
                    bytes_ev(700, 700),
                    steps_ev("importing", 1, 1),
                ],
                FakeEnd::Done,
            ),
        ]);
        assert_eq!(u.begin_download(1000), Status::Ok);
        let thread = download_until_held(&u);
        assert_eq!(u.pause_download(), Status::Ok);
        assert_eq!(
            u.pause_download(),
            Status::Ok,
            "a pause under way: ok again"
        );
        thread.join().expect("the download thread");
        let j = job(&u);
        assert_eq!((j.state, j.percent, j.bytes_done), ("paused", 36, 400));
        assert!(j.resumable);
        assert_eq!((j.rate_bps, j.eta_s), (0, 0));
        let r = u.record();
        assert_eq!(
            (r.state, r.available.as_str(), r.progress),
            (State::Idle, "0.0.20", 36)
        );
        assert_eq!(r.staged, "", "nothing staged");
        assert_eq!(u.pause_download(), Status::WrongState, "nothing runs");

        assert_eq!(u.resume_download(2000), Status::Ok);
        assert_eq!(job(&u).state, "running");
        let mut percents = Vec::new();
        u.run_download(&clk(), &mut || percents.push(job(&u).percent));
        assert!(
            percents.iter().all(|p| *p >= 36),
            "never back below the paused percent: {percents:?}"
        );
        let j = job(&u);
        assert_eq!(j.id, "os-1000", "the same job");
        assert_eq!(
            (j.status.as_str(), j.percent, j.bytes_done),
            ("ok", 100, 1100)
        );
        assert_eq!(j.bytes_total, 1000, "fixed by the first run");
        assert_eq!(u.record().state, State::Staged);
        assert_eq!(calls_named(&u, "upgrade"), 2, "the same command again");
    }

    #[test]
    fn download_continues_a_paused_job() {
        let u = found(vec![run(vec![bytes_ev(400, 1000)], FakeEnd::HoldForStop)]);
        assert_eq!(u.begin_download(1000), Status::Ok);
        let thread = download_until_held(&u);
        assert_eq!(u.pause_download(), Status::Ok);
        thread.join().expect("thread");
        assert_eq!(u.begin_download(1500), Status::Ok);
        let j = job(&u);
        assert_eq!(
            (j.id.as_str(), j.state, j.bytes_done),
            ("os-1000", "running", 400)
        );
    }

    #[test]
    fn a_pause_before_bootc_starts_stops_it_from_starting() {
        let u = found(vec![]);
        assert_eq!(u.begin_download(1000), Status::Ok);
        assert_eq!(u.pause_download(), Status::Ok);
        u.run_download(&clk(), &mut || {});
        assert_eq!(job(&u).state, "paused");
        assert_eq!(u.record().staged, "");
    }

    #[test]
    fn cancel_stops_a_running_download_and_stages_nothing() {
        let u = found(vec![run(vec![bytes_ev(400, 1000)], FakeEnd::HoldForStop)]);
        assert_eq!(u.begin_download(1000), Status::Ok);
        let thread = download_until_held(&u);
        assert_eq!(u.cancel_download(&clk()), Status::Ok);
        assert_eq!(
            u.pause_download(),
            Status::WrongState,
            "a cancel is under way"
        );
        thread.join().expect("thread");
        let j = job(&u);
        assert_eq!((j.state, j.status.as_str()), ("finished", "cancelled"));
        assert_eq!(j.finished, 1000);
        let r = u.record();
        assert_eq!((r.state, r.staged.as_str()), (State::Idle, ""));
        assert_eq!(r.available, "0.0.20", "it can be downloaded again");
        assert_eq!(u.cancel_download(&clk()), Status::WrongState, "finished");
        assert_eq!(u.resume_download(1000), Status::WrongState);
        assert_eq!(u.begin_download(1000), Status::Ok, "a new job");
        assert_eq!(job(&u).id, "os-1000-2", "not the cancelled job's id");
    }

    #[test]
    fn a_cancel_after_a_pause_request_wins() {
        let u = found(vec![run(vec![bytes_ev(400, 1000)], FakeEnd::HoldForStop)]);
        assert_eq!(u.begin_download(1000), Status::Ok);
        let thread = download_until_held(&u);
        assert_eq!(u.pause_download(), Status::Ok);
        assert_eq!(u.cancel_download(&clk()), Status::Ok);
        thread.join().expect("thread");
        assert_eq!(job(&u).status, "cancelled");
    }

    #[test]
    fn cancel_ends_a_paused_download_at_once() {
        let u = found(vec![run(vec![bytes_ev(400, 1000)], FakeEnd::HoldForStop)]);
        assert_eq!(u.begin_download(1000), Status::Ok);
        let thread = download_until_held(&u);
        assert_eq!(u.pause_download(), Status::Ok);
        thread.join().expect("thread");
        assert_eq!(u.cancel_download(&clk()), Status::Ok);
        let j = job(&u);
        assert_eq!((j.state, j.status.as_str()), ("finished", "cancelled"));
        assert_eq!(u.resume_download(1000), Status::WrongState);
    }

    #[test]
    fn nothing_to_pause_resume_or_cancel_is_wrong_state() {
        let u = found(vec![]);
        assert_eq!(u.pause_download(), Status::WrongState);
        assert_eq!(u.resume_download(1000), Status::WrongState);
        assert_eq!(u.cancel_download(&clk()), Status::WrongState);
    }

    #[test]
    fn pause_and_cancel_are_refused_once_the_import_has_begun() {
        let u = found(vec![run(
            vec![bytes_ev(1000, 1000), steps_ev("importing", 0, 1)],
            FakeEnd::HoldForStop,
        )]);
        assert_eq!(u.begin_download(1000), Status::Ok);
        let thread = download_until_held(&u);
        assert!(!job(&u).resumable);
        assert_eq!(u.pause_download(), Status::Unsupported);
        assert_eq!(u.cancel_download(&clk()), Status::Unsupported);
        assert_eq!(job(&u).state, "running", "untouched");
        // End the held pull the way nothing in the service would: bootc stopped on its own.
        if let Some(stop) = u.lock().stop.clone() {
            stop.request();
        }
        thread.join().expect("thread");
        let j = job(&u);
        assert_eq!((j.state, j.status.as_str()), ("finished", "failed"));
        assert_eq!(u.record().error, "bootc was stopped");
    }

    #[test]
    fn resume_while_a_check_runs_is_busy() {
        let u = found(vec![run(vec![bytes_ev(400, 1000)], FakeEnd::HoldForStop)]);
        assert_eq!(u.begin_download(1000), Status::Ok);
        let thread = download_until_held(&u);
        assert_eq!(u.pause_download(), Status::Ok);
        thread.join().expect("thread");
        assert_eq!(u.begin_check(), Status::Ok);
        assert_eq!(u.resume_download(1000), Status::Busy);
    }

    #[test]
    fn a_failed_run_finishes_the_job_failed() {
        let u = found(vec![run(
            vec![bytes_ev(300, 1000)],
            FakeEnd::Fail("registry gone".to_owned()),
        )]);
        assert_eq!(u.begin_download(1000), Status::Ok);
        u.run_download(&clk(), &mut || {});
        let j = job(&u);
        assert_eq!(
            (j.state, j.status.as_str(), j.bytes_done),
            ("finished", "failed", 300)
        );
        assert_eq!(u.record().state, State::Failed);
        assert_eq!(u.record().error, "registry gone");
    }

    #[test]
    fn a_restart_while_paused_keeps_the_job_paused() {
        let dir = tempfile::tempdir().expect("tempdir");
        let u = found_in(
            Some(dir.path()),
            vec![run(vec![bytes_ev(400, 1000)], FakeEnd::HoldForStop)],
        );
        assert_eq!(u.begin_download(1000), Status::Ok);
        let thread = download_until_held(&u);
        assert_eq!(u.policy_pause(), Status::Ok);
        thread.join().expect("thread");
        let before = job(&u);
        drop(u);

        let again = Update::new(FakeBootc::new(host()), Some(dir.path().to_owned()));
        again.refresh().expect("refresh");
        let j = again.job_record(0).expect("the kept job");
        assert_eq!(j, before, "the same paused job: id, percent, bytes, reason");
        assert_eq!(j.reason, "playing");
        let r = again.record();
        assert_eq!(
            (r.state, r.available.as_str(), r.progress),
            (State::Idle, "0.0.20", 36)
        );
        assert_eq!(again.resume_download(2000), Status::Ok);
        again.run_download(&clk(), &mut || {});
        let j = again.job_record(0).expect("job");
        assert_eq!((j.id.as_str(), j.status.as_str()), ("os-1000", "ok"));
        assert!(
            !dir.path().join(JOB_FILE).exists(),
            "a finished job is not kept"
        );
        let third = Update::new(FakeBootc::new(host()), Some(dir.path().to_owned()));
        assert!(third.job_record(0).is_none());
    }

    #[test]
    fn a_service_stopped_under_a_running_download_finds_it_paused() {
        let dir = tempfile::tempdir().expect("tempdir");
        let u = found_in(Some(dir.path()), vec![]);
        assert_eq!(u.begin_download(1000), Status::Ok);
        drop(u);
        let again = Update::new(FakeBootc::new(host()), Some(dir.path().to_owned()));
        assert_eq!(again.job_record(0).expect("kept").state, "paused");
    }

    #[test]
    fn a_bad_kept_job_is_ignored() {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join(JOB_FILE), "{garbage").expect("write");
        let u = Update::new(FakeBootc::new(host()), Some(dir.path().to_owned()));
        assert!(u.job_record(0).is_none());
        assert_eq!(u.record().available, "");
    }

    fn paused(u: &Arc<Update<FakeBootc>>) {
        assert_eq!(u.begin_download(1000), Status::Ok);
        let thread = download_until_held(u);
        assert_eq!(u.pause_download(), Status::Ok);
        thread.join().expect("thread");
        assert_eq!(job(u).state, "paused");
    }

    #[test]
    fn set_channel_and_rollback_cancel_a_paused_download() {
        let u = found(vec![run(vec![bytes_ev(400, 1000)], FakeEnd::HoldForStop)]);
        paused(&u);
        assert_eq!(u.set_channel("beta", true, &clk()), Status::Ok);
        assert_eq!(job(&u).status, "cancelled");

        let u = found(vec![run(vec![bytes_ev(400, 1000)], FakeEnd::HoldForStop)]);
        paused(&u);
        assert_eq!(u.rollback(true, &clk()), Status::Ok);
        assert_eq!(job(&u).status, "cancelled");
        assert_eq!(u.resume_download(1000), Status::WrongState);
    }

    #[test]
    fn a_download_paused_by_the_policy_resumes_when_no_app_runs() {
        let u = found(vec![run(vec![bytes_ev(400, 1000)], FakeEnd::HoldForStop)]);
        assert_eq!(u.begin_download(1000), Status::Ok);
        let thread = download_until_held(&u);
        assert_eq!(u.policy_pause(), Status::Ok);
        thread.join().expect("thread");
        assert_eq!(job(&u).reason, "playing");
        let clock = FakeClock::new(1060, 12 * 60);
        let reboot = FakeReboot::default();
        u.report_activity(1060, true);
        u.tick(&clock, &reboot, &mut || {});
        assert_eq!(job(&u).state, "paused", "an app still runs");
        u.report_activity(1070, false);
        clock.set(1120, 12 * 60);
        u.tick(&clock, &reboot, &mut || {});
        let j = job(&u);
        assert_eq!((j.id.as_str(), j.status.as_str()), ("os-1000", "ok"));
        assert_eq!(u.record().state, State::Staged);
    }

    #[test]
    fn a_download_the_user_paused_waits_for_the_user() {
        let u = found(vec![run(vec![bytes_ev(400, 1000)], FakeEnd::HoldForStop)]);
        paused(&u);
        let clock = FakeClock::new(1060, 12 * 60);
        u.tick(&clock, &FakeReboot::default(), &mut || {});
        assert_eq!(job(&u).state, "paused");
    }

    #[test]
    fn the_ledger_counts_each_runs_bytes_and_the_finished_job() {
        let dir = tempfile::tempdir().expect("tempdir");
        let u = found_in(
            Some(dir.path()),
            vec![
                run(vec![bytes_ev(400, 1000)], FakeEnd::HoldForStop),
                run(vec![bytes_ev(700, 700)], FakeEnd::Done),
            ],
        );
        paused(&u);
        let (status, days) = u.download_stats(7, &clk());
        assert_eq!(status, Status::Ok);
        assert_eq!(
            days,
            [Day {
                day: "1970-01-01".into(),
                bytes: 400,
                jobs: 0,
                failed: 0
            }]
        );
        assert_eq!(u.resume_download(1000), Status::Ok);
        u.run_download(&clk(), &mut || {});
        let (_, days) = u.download_stats(7, &clk());
        assert_eq!((days[0].bytes, days[0].jobs, days[0].failed), (1100, 1, 0));
        let kept = ledger::load(dir.path()).expect("written");
        assert_eq!(kept.stats(7, "1970-01-01"), days);
        assert_eq!(u.download_stats(0, &clk()).0, Status::Invalid);
        assert_eq!(u.download_stats(91, &clk()).0, Status::Invalid);
        assert_eq!(u.download_stats(90, &clk()).0, Status::Ok);
    }

    #[test]
    fn a_corrupt_ledger_is_reported_and_never_overwritten() {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join(LEDGER_FILE), "garbage").expect("write");
        let u = found_in(
            Some(dir.path()),
            vec![run(vec![bytes_ev(10, 10)], FakeEnd::Done)],
        );
        assert_eq!(u.download_stats(7, &clk()).0, Status::Failed);
        assert_eq!(u.begin_download(1000), Status::Ok);
        u.run_download(&clk(), &mut || {});
        assert_eq!(job(&u).status, "ok", "the download itself is not held up");
        assert_eq!(
            fs::read_to_string(dir.path().join(LEDGER_FILE)).expect("read"),
            "garbage"
        );
    }
}
