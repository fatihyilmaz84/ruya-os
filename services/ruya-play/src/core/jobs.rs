//! The job table: what is queued or running and the last finished jobs, kept in a small file so a
//! restarted service still knows them (`Play1.ListJobs`, RUY-96). The record uses ADR-026's v2
//! field names where they apply (`job`, `source` = `"play"`, `kind`, `state`, `phase`,
//! `bytes_done`, `bytes_total`, `started`, `finished`, `error`) plus the contract's own (`path`,
//! `app`, `status`, `reason`, `percent`).
//!
//! The file (`<state>/jobs`) is JSON Lines: a header `{"format":1,"counter":N}`, then one job per
//! line. It is read as untrusted input like `ruya-store`'s: a line that does not parse or breaks a
//! rule is dropped, a file that is not one gives an empty table, and nothing in it is ever resumed:
//! a job left queued or running is settled once to `failed` with the reason `interrupted`.
//!
//! **Forward-compatible (RUY-900):** a key this service does not know, in the header or on a job
//! line, is ignored, so a file written by a newer image still reads after a bootc rollback. A
//! field may only be added with a safe default for a reader that does not know it; a change an
//! older reader must not misread raises `format` (a file of another format is an empty table).

use crate::core::codes;
use crate::core::status::{JobStatus, Phase};
use ruya_play_format::Problem;
use ruya_play_trust::time::UnixSeconds;
use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write};
use std::path::Path;

/// Finished jobs kept besides the active ones (the contract's "last 20").
pub const FINISHED_KEPT: usize = 20;
/// The format of the file this console writes.
pub const JOBS_FORMAT: u64 = 1;
/// Most bytes read from the file.
pub const MAX_JOBS_FILE_BYTES: u64 = 1024 * 1024;
/// Most bytes of a package path in a record.
pub const MAX_PATH_BYTES: usize = 4096;
/// Most bytes of an app's display name in a record.
pub const MAX_NAME_BYTES: usize = 1024;

/// What a job does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobKind {
    /// Import a package.
    Install,
    /// Re-hash an installed package (RUY-100).
    Verify,
    /// Uninstall an installed package (RUY-816).
    Remove,
}

impl JobKind {
    /// The contract's word.
    pub fn as_str(self) -> &'static str {
        match self {
            JobKind::Install => "install",
            JobKind::Verify => "verify",
            JobKind::Remove => "remove",
        }
    }

    fn parse(word: &str) -> Option<JobKind> {
        match word {
            "install" => Some(JobKind::Install),
            "verify" => Some(JobKind::Verify),
            "remove" => Some(JobKind::Remove),
            _ => None,
        }
    }
}

/// Where a job is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobState {
    /// Waiting for the one running job.
    Queued,
    /// Running.
    Running,
    /// Done; `status` says how.
    Finished,
}

impl JobState {
    /// The contract's word.
    pub fn as_str(self) -> &'static str {
        match self {
            JobState::Queued => "queued",
            JobState::Running => "running",
            JobState::Finished => "finished",
        }
    }

    fn parse(word: &str) -> Option<JobState> {
        match word {
            "queued" => Some(JobState::Queued),
            "running" => Some(JobState::Running),
            "finished" => Some(JobState::Finished),
            _ => None,
        }
    }
}

/// One job.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JobRecord {
    /// `job-N`; names are never reused.
    pub job: String,
    /// What it does.
    pub kind: JobKind,
    /// The package path (install) or `""` (verify).
    pub path: String,
    /// `play.<id>` once the manifest is read, else `""`.
    pub app: String,
    /// The app's display name (English, else the first language) once known, else `""`
    /// (RUY-816: a toast after a restart says what the job was about).
    pub name: String,
    /// Where it is.
    pub state: JobState,
    /// Set once finished.
    pub status: Option<JobStatus>,
    /// The service stopped while the job was queued or running.
    pub interrupted: bool,
    /// The current phase.
    pub phase: Phase,
    /// 0-100, never decreasing.
    pub percent: u32,
    /// Payload bytes written so far.
    pub bytes_done: u64,
    /// Payload bytes in all (0 = not known yet).
    pub bytes_total: u64,
    /// When it started running (0 = not yet).
    pub started: UnixSeconds,
    /// When it finished (0 = not yet).
    pub finished: UnixSeconds,
    /// The code of the first problem of a job that did not end `ok`, else `""`.
    pub error: String,
}

impl JobRecord {
    /// A new queued job.
    pub fn queued(job: &str, kind: JobKind, path: &str) -> JobRecord {
        JobRecord {
            job: job.to_string(),
            kind,
            path: path.to_string(),
            app: String::new(),
            name: String::new(),
            state: JobState::Queued,
            status: None,
            interrupted: false,
            phase: Phase::None,
            percent: 0,
            bytes_done: 0,
            bytes_total: 0,
            started: 0,
            finished: 0,
            error: String::new(),
        }
    }

    /// Queued or running.
    pub fn is_active(&self) -> bool {
        self.state != JobState::Finished
    }

    /// `"interrupted"` or `""` (the contract's `reason`).
    pub fn reason(&self) -> &'static str {
        if self.interrupted {
            "interrupted"
        } else {
            ""
        }
    }

    /// Finish with `status`; `error` is the first problem's code.
    pub fn finish(&mut self, status: JobStatus, error: &str, now: UnixSeconds) {
        self.state = JobState::Finished;
        self.status = Some(status);
        self.error = if status == JobStatus::Ok {
            String::new()
        } else {
            error.to_string()
        };
        self.finished = now;
        if status == JobStatus::Ok {
            self.percent = 100;
        }
    }
}

/// The number in `job-12`.
pub fn job_number(job: &str) -> Option<u64> {
    let digits = job.strip_prefix("job-")?;
    if digits.is_empty() || digits.len() > 19 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

/// Drop the oldest finished jobs beyond [`FINISHED_KEPT`]; active jobs stay.
pub fn trim(jobs: &mut Vec<JobRecord>) {
    let finished = jobs.iter().filter(|j| !j.is_active()).count();
    let mut drop = finished.saturating_sub(FINISHED_KEPT);
    jobs.retain(|j| {
        if drop > 0 && !j.is_active() {
            drop -= 1;
            false
        } else {
            true
        }
    });
}

/// Settle what a previous run left queued or running: `failed`, reason `interrupted`, error
/// `job.interrupted`. Nothing is resumed. Returns how many jobs changed.
pub fn settle(jobs: &mut [JobRecord], now: UnixSeconds) -> usize {
    let mut n = 0;
    for j in jobs.iter_mut().filter(|j| j.is_active()) {
        j.interrupted = true;
        j.finish(JobStatus::Failed, codes::JOB_INTERRUPTED, now);
        n += 1;
    }
    n
}

#[derive(Serialize, Deserialize)]
struct Header {
    format: u64,
    counter: u64,
}

#[derive(Serialize, Deserialize)]
struct RawJob {
    job: String,
    source: String,
    kind: String,
    path: String,
    app: String,
    /// Added by RUY-816: a file written before it has no name.
    #[serde(default)]
    name: String,
    state: String,
    status: String,
    reason: String,
    phase: String,
    percent: u32,
    bytes_done: u64,
    bytes_total: u64,
    started: i64,
    finished: i64,
    error: String,
}

fn plain_text(s: &str, max: usize) -> bool {
    s.len() <= max && !s.chars().any(char::is_control)
}

/// Empty (a job without an app) or a `.play` package's Flatpak id: `play.` and an id
/// `valid_app_id` accepts.
fn valid_app(app: &str) -> bool {
    app.is_empty() || (app.starts_with("play.") && ruya_flatpak::valid_app_id(app))
}

fn valid_code(code: &str) -> bool {
    code.len() <= 64
        && code
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'.' || b == b'_')
}

impl RawJob {
    fn of(j: &JobRecord) -> RawJob {
        RawJob {
            job: j.job.clone(),
            source: "play".into(),
            kind: j.kind.as_str().into(),
            path: j.path.clone(),
            app: j.app.clone(),
            name: j.name.clone(),
            state: j.state.as_str().into(),
            status: j.status.map_or("", JobStatus::as_str).into(),
            reason: j.reason().into(),
            phase: j.phase.as_str().into(),
            percent: j.percent.min(100),
            bytes_done: j.bytes_done,
            bytes_total: j.bytes_total,
            started: j.started,
            finished: j.finished,
            error: j.error.clone(),
        }
    }

    fn record(self) -> Option<JobRecord> {
        job_number(&self.job)?;
        let kind = JobKind::parse(&self.kind)?;
        let state = JobState::parse(&self.state)?;
        let phase = Phase::parse(&self.phase)?;
        let status = match self.status.as_str() {
            "" => None,
            s => Some(JobStatus::parse(s)?),
        };
        let interrupted = match self.reason.as_str() {
            "" => false,
            "interrupted" => true,
            _ => return None,
        };
        // A finished job has a result, an active one has none.
        let ok = self.source == "play"
            && (state == JobState::Finished) == status.is_some()
            && plain_text(&self.path, MAX_PATH_BYTES)
            && valid_app(&self.app)
            && plain_text(&self.name, MAX_NAME_BYTES)
            && valid_code(&self.error)
            && self.percent <= 100
            && self.started >= 0
            && self.finished >= 0;
        ok.then_some(JobRecord {
            job: self.job,
            kind,
            path: self.path,
            app: self.app,
            name: self.name,
            state,
            status,
            interrupted,
            phase,
            percent: self.percent,
            bytes_done: self.bytes_done,
            bytes_total: self.bytes_total,
            started: self.started,
            finished: self.finished,
            error: self.error,
        })
    }
}

/// The file's content: the highest job number handed out, then one line per job.
pub fn encode(counter: u64, jobs: &[JobRecord]) -> String {
    let header = Header {
        format: JOBS_FORMAT,
        counter,
    };
    let mut text = serde_json::to_string(&header).unwrap_or_default();
    text.push('\n');
    for j in jobs {
        if let Ok(line) = serde_json::to_string(&RawJob::of(j)) {
            text.push_str(&line);
            text.push('\n');
        }
    }
    text
}

/// The counter and the jobs of a file written by [`encode`]; nothing for a file that is not one.
/// The counter is at least the highest number of any job read; a job named twice keeps its first
/// line.
pub fn decode(text: &str) -> (u64, Vec<JobRecord>) {
    let mut lines = text.lines();
    let Some(Ok(header)) = lines.next().map(serde_json::from_str::<Header>) else {
        return (0, Vec::new());
    };
    if header.format != JOBS_FORMAT {
        return (0, Vec::new());
    }
    let mut counter = header.counter;
    let mut jobs: Vec<JobRecord> = Vec::new();
    for line in lines {
        let Some(job) = serde_json::from_str::<RawJob>(line)
            .ok()
            .and_then(RawJob::record)
        else {
            continue;
        };
        if jobs.iter().any(|j| j.job == job.job) {
            continue;
        }
        counter = counter.max(job_number(&job.job).unwrap_or(0));
        jobs.push(job);
    }
    (counter, jobs)
}

/// Read the file at `path`: an absent file is an empty table; at most [`MAX_JOBS_FILE_BYTES`] are
/// read (a longer file is cut, its last line then fails to parse and is dropped).
pub fn load(path: &Path) -> io::Result<(u64, Vec<JobRecord>)> {
    let file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok((0, Vec::new())),
        Err(e) => return Err(e),
    };
    let mut bytes = Vec::new();
    file.take(MAX_JOBS_FILE_BYTES).read_to_end(&mut bytes)?;
    Ok(decode(&String::from_utf8_lossy(&bytes)))
}

/// Write `text` to `path` atomically: a temporary file next to it, flushed, then renamed over it,
/// so after a power cut the name never points at a file whose data did not reach the disk.
pub fn write_atomic(path: &Path, text: &[u8]) -> io::Result<()> {
    let tmp = path.with_extension("tmp");
    {
        let mut o = std::fs::OpenOptions::new();
        o.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            o.mode(0o600);
        }
        let mut file = o.open(&tmp)?;
        file.write_all(text)?;
        file.sync_all()?;
    }
    std::fs::rename(&tmp, path)?;
    #[cfg(unix)]
    if let Some(dir) = path.parent() {
        // The rename itself reaches the disk with the folder.
        std::fs::File::open(dir)?.sync_all()?;
    }
    Ok(())
}

/// The most problems [`problem_log_lines`] writes for one job.
pub const MAX_LOGGED_PROBLEMS: usize = 8;
/// The most characters of one field of a logged problem.
pub const MAX_LOGGED_FIELD: usize = 256;

/// The journal lines for a job that did not end `ok` (RUY-866): the job record keeps only the
/// first code, so the message (the io error text, the rule that was broken) is logged here, one
/// line per problem, at most [`MAX_LOGGED_PROBLEMS`], each field cleaned of control characters
/// and cut to [`MAX_LOGGED_FIELD`] characters. Problems never carry secrets (05 §7). No lines for
/// an `ok` or a `cancelled` job.
pub fn problem_log_lines(job: &str, status: JobStatus, problems: &[Problem]) -> Vec<String> {
    if matches!(status, JobStatus::Ok | JobStatus::Cancelled) {
        return Vec::new();
    }
    let clean = |s: &str| -> String {
        s.chars()
            .map(|c| if c.is_control() { ' ' } else { c })
            .take(MAX_LOGGED_FIELD)
            .collect()
    };
    let mut out: Vec<String> = problems
        .iter()
        .take(MAX_LOGGED_PROBLEMS)
        .map(|p| {
            format!(
                "ruya-play: {} {}: {} {}: {}",
                clean(job),
                status.as_str(),
                clean(&p.code),
                clean(&p.path),
                clean(&p.message)
            )
        })
        .collect();
    if problems.len() > MAX_LOGGED_PROBLEMS {
        out.push(format!(
            "ruya-play: {} {}: {} more problems",
            clean(job),
            status.as_str(),
            problems.len() - MAX_LOGGED_PROBLEMS
        ));
    }
    if out.is_empty() {
        out.push(format!(
            "ruya-play: {} {}: no problem given",
            clean(job),
            status.as_str()
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_job_app_is_empty_or_a_play_flatpak_id() {
        assert!(valid_app(""));
        assert!(valid_app("play.com.example.mini"));
        // Not Flatpak ids: one element too few, an element opening with a digit, a stray `/`.
        for bad in [
            "play.mini",
            "play.com.1x.mini",
            "play.com.ex/ample.x",
            "org.example.Racer",
        ] {
            assert!(!valid_app(bad), "{bad:?}");
        }
    }

    #[test]
    fn a_failed_job_logs_each_problem_cleaned_and_bounded() {
        let p = Problem::new(
            codes::STAGING_IO,
            "",
            "Writing into the staging folder failed (Not a directory (os error 20)).\n\x1b[2Jx",
        );
        let lines = problem_log_lines("job-4", JobStatus::Failed, std::slice::from_ref(&p));
        assert_eq!(lines.len(), 1);
        assert!(lines[0].starts_with("ruya-play: job-4 failed: staging.io : Writing into"));
        assert!(lines[0].contains("(os error 20)"));
        assert!(!lines[0].chars().any(char::is_control));

        let long = Problem::new("x", "p".repeat(1000), "m".repeat(1000));
        let many = vec![long; MAX_LOGGED_PROBLEMS + 3];
        let lines = problem_log_lines("job-5", JobStatus::InvalidPackage, &many);
        assert_eq!(lines.len(), MAX_LOGGED_PROBLEMS + 1);
        assert!(lines[0].len() < 3 * MAX_LOGGED_FIELD);
        assert!(lines[MAX_LOGGED_PROBLEMS].ends_with("3 more problems"));
    }

    #[test]
    fn an_ok_job_logs_nothing_and_a_bare_failure_still_logs_a_line() {
        let p = Problem::new("x", "", "y");
        assert!(problem_log_lines("job-1", JobStatus::Ok, std::slice::from_ref(&p)).is_empty());
        assert!(problem_log_lines("job-1", JobStatus::Cancelled, &[p]).is_empty());
        assert_eq!(
            problem_log_lines("job-2", JobStatus::Failed, &[]),
            vec!["ruya-play: job-2 failed: no problem given".to_string()]
        );
    }

    fn job(n: u64, state: JobState, status: Option<JobStatus>) -> JobRecord {
        let mut j = JobRecord::queued(&format!("job-{n}"), JobKind::Install, "/run/media/a/x.play");
        j.state = state;
        j.status = status;
        j
    }

    #[test]
    fn the_file_round_trips() {
        let mut done = job(3, JobState::Finished, Some(JobStatus::Revoked));
        done.app = "play.com.example.game".into();
        done.error = "revoked.key".into();
        done.phase = Phase::Staging;
        done.bytes_total = 1234;
        done.started = 10;
        done.finished = 20;
        let jobs = vec![done, job(4, JobState::Running, None)];
        let text = encode(4, &jobs);
        assert!(text.contains("\"source\":\"play\""), "{text}");
        assert_eq!(decode(&text), (4, jobs));
    }

    #[test]
    fn a_file_from_a_newer_image_reads_after_a_rollback() {
        // Unknown keys in the header and on a job line are ignored, never a dropped table.
        let jobs = vec![job(3, JobState::Queued, None)];
        let text = encode(3, &jobs);
        let mut lines = text.lines();
        let header = lines.next().unwrap().replacen('{', "{\"later\":true,", 1);
        let line = lines.next().unwrap().replacen('{', "{\"eta_s\":12,", 1);
        assert_eq!(decode(&format!("{header}\n{line}\n")), (3, jobs));
    }

    #[test]
    fn a_damaged_file_gives_what_is_readable() {
        let good = encode(2, &[job(1, JobState::Queued, None)]);
        let mut text = good.clone();
        text.push_str("{not json\n");
        // A finished job without a status, a queued one with one, an unknown word, a bad app.
        for bad in [
            job(5, JobState::Finished, None),
            job(6, JobState::Queued, Some(JobStatus::Ok)),
        ] {
            text.push_str(encode(0, &[bad]).lines().nth(1).unwrap());
            text.push('\n');
        }
        let mut odd = encode(0, &[job(7, JobState::Queued, None)]);
        odd = odd.replace("\"queued\"", "\"paused\"");
        text.push_str(odd.lines().nth(1).unwrap());
        text.push('\n');
        let mut app = job(8, JobState::Queued, None);
        app.app = "org.evil\tapp".into();
        text.push_str(encode(0, &[app]).lines().nth(1).unwrap());
        text.push('\n');
        let (counter, jobs) = decode(&text);
        assert_eq!(counter, 2);
        assert_eq!(jobs.len(), 1);
        assert_eq!(decode("ruya-store-jobs 1\n"), (0, Vec::new()));
        assert_eq!(decode("{\"format\":2,\"counter\":3}\n"), (0, Vec::new()));
    }

    #[test]
    fn the_counter_is_at_least_the_highest_job() {
        let text = encode(1, &[job(9, JobState::Queued, None)]);
        assert_eq!(decode(&text).0, 9);
    }

    #[test]
    fn job_names_are_job_and_a_number() {
        assert_eq!(job_number("job-12"), Some(12));
        for bad in ["job-", "job-1a", "job--1", "12", "job-+1"] {
            assert_eq!(job_number(bad), None, "{bad}");
        }
    }

    #[test]
    fn only_the_newest_finished_jobs_are_kept() {
        let mut jobs: Vec<JobRecord> = (0..30)
            .map(|n| job(n, JobState::Finished, Some(JobStatus::Ok)))
            .collect();
        jobs.push(job(30, JobState::Queued, None));
        trim(&mut jobs);
        assert_eq!(jobs.len(), FINISHED_KEPT + 1);
        assert_eq!(jobs[0].job, "job-10");
        assert!(jobs.last().unwrap().is_active());
    }

    #[test]
    fn settling_fails_active_jobs_once() {
        let mut jobs = vec![
            job(1, JobState::Running, None),
            job(2, JobState::Queued, None),
            job(3, JobState::Finished, Some(JobStatus::Ok)),
        ];
        assert_eq!(settle(&mut jobs, 50), 2);
        for j in &jobs[..2] {
            assert_eq!(j.status, Some(JobStatus::Failed));
            assert!(j.interrupted);
            assert_eq!(j.error, "job.interrupted");
            assert_eq!(j.finished, 50);
        }
        assert!(!jobs[2].interrupted);
        assert_eq!(settle(&mut jobs, 60), 0);
        assert_eq!(jobs[0].finished, 50);
    }
}
