//! The OS download as an ADR-026 v2 job (`api/dbus/org.ruyaos.Update1.xml`, "Job record"): what
//! bootc's progress events make of it, its pause, resume and end, and the copy kept while it is
//! paused. Pure: time is passed in (unix seconds for `started`/`finished`, monotonic milliseconds
//! for the rate).

use crate::bootc::Progress;
use ruya_jobs::rate::Rate;

/// `percent` when every byte has arrived; the import and the deploy take it to `INSTALL_END`.
pub const DOWNLOAD_END: u32 = 90;
/// The end of the first install task (bootc's "importing"); later tasks (the deploy) share the
/// rest.
pub const IMPORT_END: u32 = 95;
pub const INSTALL_END: u32 = 99;

pub const SOURCE: &str = "update";
pub const KIND: &str = "os";

/// The finished job's `status` (stable API).
pub const STATUS_OK: &str = "ok";
pub const STATUS_FAILED: &str = "failed";
pub const STATUS_CANCELLED: &str = "cancelled";
/// `reason` of a job the download policy paused (RUY-31); "" for the user's own pause.
pub const REASON_PLAYING: &str = "playing";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobState {
    Running,
    Paused,
    Finished,
}

impl JobState {
    pub fn as_str(self) -> &'static str {
        match self {
            JobState::Running => "running",
            JobState::Paused => "paused",
            JobState::Finished => "finished",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// Layers arrive (ProgressBytes).
    Download,
    /// The import and the deploy (ProgressSteps): no bytes, cannot be paused.
    Install,
}

impl Phase {
    pub fn as_str(self) -> &'static str {
        match self {
            Phase::Download => "download",
            Phase::Install => "install",
        }
    }
}

/// What one event changed that the caller acts on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Seen {
    /// The phase changed (a state change: sent at once, not held back by the once-a-second limit).
    pub phase_changed: bool,
    /// The run's first ProgressBytes (logged: how much the machine already had).
    pub first_bytes: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Job {
    pub id: String,
    /// The version (or channel) being staged: the title is "RuyaOS <version>".
    pub version: String,
    pub state: JobState,
    /// "" unless finished, then `STATUS_*`.
    pub status: String,
    /// "" or `REASON_PLAYING`.
    pub reason: String,
    pub phase: Phase,
    /// Never decreasing within the job.
    pub percent: u32,
    /// Network bytes of the job's earlier runs.
    pub bytes_before: u64,
    /// bootc's byte count of the run in progress (from 0 each run).
    pub run_bytes: u64,
    /// `bytesTotal` of the job's first ProgressBytes: fixed for the job. None until it came.
    pub bytes_total: Option<u64>,
    pub started: i64,
    pub finished: i64,
    /// The install tasks this run reported, in their order.
    tasks: Vec<String>,
    run_seen_bytes: bool,
    rate: Rate,
}

/// The served record: every key of the contract's Job record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JobRecord {
    pub id: String,
    pub source: &'static str,
    pub kind: &'static str,
    pub app: String,
    pub title: String,
    pub state: &'static str,
    pub status: String,
    pub reason: String,
    pub phase: &'static str,
    pub percent: u32,
    pub bytes_done: u64,
    pub bytes_total: u64,
    pub rate_bps: u64,
    pub eta_s: u32,
    pub position: u32,
    pub resumable: bool,
    pub started: i64,
    pub finished: i64,
}

impl Job {
    /// A job that starts running now.
    pub fn new(id: &str, version: &str, started: i64) -> Job {
        Job {
            id: id.to_owned(),
            version: version.to_owned(),
            state: JobState::Running,
            status: String::new(),
            reason: String::new(),
            phase: Phase::Download,
            percent: 0,
            bytes_before: 0,
            run_bytes: 0,
            bytes_total: None,
            started,
            finished: 0,
            tasks: Vec::new(),
            run_seen_bytes: false,
            rate: Rate::default(),
        }
    }

    pub fn bytes_done(&self) -> u64 {
        self.bytes_before + self.run_bytes
    }

    /// PauseDownload (and CancelDownload) are offered: not once the import has begun.
    pub fn resumable(&self) -> bool {
        self.state != JobState::Finished && self.phase == Phase::Download
    }

    pub fn progress(&mut self, event: &Progress, now_ms: u64) -> Seen {
        let mut seen = Seen::default();
        match event {
            Progress::Bytes {
                bytes, bytes_total, ..
            } => {
                seen.first_bytes = !self.run_seen_bytes;
                self.run_seen_bytes = true;
                let total = *self.bytes_total.get_or_insert(*bytes_total);
                self.run_bytes = self.run_bytes.max(*bytes);
                if total > 0 {
                    let share = u128::from(self.bytes_done()) * u128::from(DOWNLOAD_END)
                        / u128::from(total);
                    let share =
                        u32::try_from(share.min(u128::from(DOWNLOAD_END))).unwrap_or(DOWNLOAD_END);
                    self.percent = self.percent.max(share);
                }
                self.rate.sample(now_ms, self.bytes_done());
            }
            Progress::Steps {
                task,
                steps,
                steps_total,
            } => {
                seen.phase_changed = self.phase != Phase::Install;
                self.phase = Phase::Install;
                let index = match self.tasks.iter().position(|t| t == task) {
                    Some(i) => i,
                    None => {
                        self.tasks.push(task.clone());
                        self.tasks.len() - 1
                    }
                };
                let (from, to) = if index == 0 {
                    (DOWNLOAD_END, IMPORT_END)
                } else {
                    (IMPORT_END, INSTALL_END)
                };
                let done = (*steps).min(*steps_total);
                let span = u64::from(to - from);
                let add = if *steps_total == 0 {
                    0
                } else {
                    span * done / steps_total
                };
                let at = from + u32::try_from(add).unwrap_or(to - from);
                self.percent = self.percent.max(at.min(to));
            }
        }
        seen
    }

    /// The end of a run: its bytes join the earlier runs'.
    fn end_run(&mut self) {
        self.bytes_before += self.run_bytes;
        self.run_bytes = 0;
        self.tasks.clear();
        self.run_seen_bytes = false;
        self.rate = Rate::default();
    }

    /// Stopped with the layers it has: `reason` "" (the user) or `REASON_PLAYING`.
    pub fn pause(&mut self, reason: &str) {
        self.end_run();
        self.state = JobState::Paused;
        self.phase = Phase::Download;
        self.reason = reason.to_owned();
    }

    /// The paused job runs again (bootc fetches only the layers it does not have).
    pub fn resume(&mut self) {
        self.end_run();
        self.state = JobState::Running;
        self.phase = Phase::Download;
        self.reason.clear();
    }

    pub fn finish(&mut self, status: &str, now: i64) {
        self.end_run();
        self.state = JobState::Finished;
        self.status = status.to_owned();
        self.reason.clear();
        self.finished = now;
        if status == STATUS_OK {
            self.percent = 100;
        }
    }

    pub fn record(&self, now_ms: u64) -> JobRecord {
        let running = self.state == JobState::Running;
        let rate_bps = if running { self.rate.bps(now_ms) } else { 0 };
        let total = self.bytes_total.unwrap_or(0);
        let eta_s = if running && self.phase == Phase::Download && rate_bps > 0 && total > 0 {
            let left = total.saturating_sub(self.bytes_done());
            u32::try_from(left.div_ceil(rate_bps)).unwrap_or(u32::MAX)
        } else {
            0
        };
        JobRecord {
            id: self.id.clone(),
            source: SOURCE,
            kind: KIND,
            app: String::new(),
            title: format!("RuyaOS {}", self.version),
            state: self.state.as_str(),
            status: self.status.clone(),
            reason: self.reason.clone(),
            phase: self.phase.as_str(),
            percent: self.percent,
            bytes_done: self.bytes_done(),
            bytes_total: total,
            rate_bps,
            eta_s,
            position: 0,
            resumable: self.resumable(),
            started: self.started,
            finished: self.finished,
        }
    }

    // ---- the copy kept while it is paused ---------------------------------------------

    /// The job as it is kept in the state directory: what a paused job needs after a restart.
    pub fn to_json(&self) -> String {
        serde_json::json!({
            "id": self.id,
            "version": self.version,
            "reason": self.reason,
            "percent": self.percent,
            "bytes_done": self.bytes_done(),
            "bytes_total": self.bytes_total,
            "started": self.started,
        })
        .to_string()
    }

    /// A kept job: paused, whatever it was doing when the service stopped (the layers bootc had
    /// fully fetched are still in the repository, also after a reboot).
    pub fn from_json(text: &str) -> Result<Job, String> {
        let v: serde_json::Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
        let text_of = |key: &str| {
            v.get(key)
                .and_then(|s| s.as_str())
                .map(str::to_owned)
                .ok_or_else(|| format!("no {key}"))
        };
        let number = |key: &str| {
            v.get(key)
                .and_then(|n| n.as_u64())
                .ok_or_else(|| format!("no {key}"))
        };
        let id = text_of("id")?;
        let version = text_of("version")?;
        if id.is_empty() || version.is_empty() {
            return Err("an empty id or version".to_owned());
        }
        let reason = text_of("reason")?;
        if !reason.is_empty() && reason != REASON_PLAYING {
            return Err(format!("unknown reason {reason:?}"));
        }
        let percent = u32::try_from(number("percent")?)
            .ok()
            .filter(|p| *p <= INSTALL_END)
            .ok_or("percent out of range")?;
        let bytes_total = match v.get("bytes_total") {
            Some(serde_json::Value::Null) => None,
            Some(n) => Some(n.as_u64().ok_or("bad bytes_total")?),
            None => return Err("no bytes_total".to_owned()),
        };
        let started = v
            .get("started")
            .and_then(|n| n.as_i64())
            .ok_or("no started")?;
        let mut job = Job::new(&id, &version, started);
        job.percent = percent;
        job.bytes_before = number("bytes_done")?;
        job.bytes_total = bytes_total;
        job.pause(&reason);
        Ok(job)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bytes(bytes: u64, total: u64) -> Progress {
        Progress::Bytes {
            bytes,
            bytes_total: total,
            bytes_cached: 0,
            steps: 0,
            steps_total: 10,
            steps_cached: 0,
        }
    }

    fn steps(task: &str, steps: u64, total: u64) -> Progress {
        Progress::Steps {
            task: task.to_owned(),
            steps,
            steps_total: total,
        }
    }

    #[test]
    fn bytes_fill_the_first_ninety_percent() {
        let mut job = Job::new("os-1", "0.0.20", 100);
        assert_eq!(job.record(0).percent, 0);
        assert_eq!(
            job.record(0).bytes_total,
            0,
            "unknown before the first event"
        );
        job.progress(&bytes(500, 1000), 0);
        let r = job.record(0);
        assert_eq!((r.percent, r.bytes_done, r.bytes_total), (45, 500, 1000));
        assert_eq!(r.phase, "download");
        assert!(r.resumable);
        job.progress(&bytes(1000, 1000), 1000);
        assert_eq!(job.record(1000).percent, DOWNLOAD_END);
    }

    #[test]
    fn the_import_and_the_deploy_take_ninety_to_ninety_nine() {
        let mut job = Job::new("os-1", "0.0.20", 100);
        job.progress(&bytes(1000, 1000), 0);
        let seen = job.progress(&steps("importing", 0, 1), 0);
        assert!(seen.phase_changed);
        let r = job.record(0);
        assert_eq!((r.phase, r.percent, r.resumable), ("install", 90, false));
        assert_eq!(r.eta_s, 0, "the import's length is not reported");
        job.progress(&steps("importing", 1, 1), 0);
        assert_eq!(job.percent, IMPORT_END);
        job.progress(&steps("deploying", 1, 3), 0);
        assert_eq!(job.percent, 96);
        job.progress(&steps("deploying", 3, 3), 0);
        assert_eq!(job.percent, INSTALL_END);
        job.finish(STATUS_OK, 200);
        let r = job.record(0);
        assert_eq!(
            (r.state, r.status.as_str(), r.percent),
            ("finished", "ok", 100)
        );
        assert_eq!(r.finished, 200);
    }

    #[test]
    fn the_recorded_run_never_goes_back() {
        let mut job = Job::new("os-1", "0.0.106", 100);
        let mut last = 0;
        let mut first = 0;
        for (i, line) in include_str!("../tests/fixtures/bootc-progress-0.0.105-to-0.0.106.jsonl")
            .lines()
            .enumerate()
        {
            if let Some(event) = crate::bootc::parse_progress(line).expect("parses") {
                let seen = job.progress(&event, i as u64 * 1000);
                if seen.first_bytes {
                    first += 1;
                }
                assert!(
                    job.percent >= last,
                    "line {i}: {} after {last}",
                    job.percent
                );
                last = job.percent;
            }
        }
        assert_eq!(first, 1, "one first ProgressBytes per run");
        assert_eq!(
            job.bytes_total,
            Some(2_381_035_309),
            "the first event's total"
        );
        assert_eq!(
            job.percent, IMPORT_END,
            "bytes done, import done, no deploy recorded"
        );
    }

    #[test]
    fn percent_never_decreases_when_a_pause_landed_in_the_import() {
        // A pause sent just as the import began: bootc stopped in it, the job is paused at 95 %.
        let mut job = Job::new("os-1", "0.0.20", 100);
        job.progress(&bytes(1000, 1000), 0);
        job.progress(&steps("importing", 1, 1), 0);
        assert_eq!(job.percent, IMPORT_END);
        job.pause("");
        job.resume();
        // The next run fetches nothing but reports its bytes again, then imports from the start.
        job.progress(&bytes(0, 0), 1000);
        assert_eq!(
            job.percent, IMPORT_END,
            "the bytes' share does not take it back"
        );
        job.progress(&steps("importing", 0, 1), 2000);
        assert_eq!(job.percent, IMPORT_END, "nor does the import starting over");
    }

    #[test]
    fn percent_never_decreases_across_a_pause_and_resume() {
        let mut job = Job::new("os-1", "0.0.20", 100);
        job.progress(&bytes(400, 1000), 0);
        assert_eq!(job.percent, 36);
        job.pause("");
        let r = job.record(0);
        assert_eq!((r.state, r.percent, r.bytes_done), ("paused", 36, 400));
        assert_eq!(r.rate_bps, 0);
        job.resume();
        // The resumed run has fewer bytes to fetch (whole layers were kept, the one in flight
        // was lost) and counts its own bytes from 0.
        let seen = job.progress(&bytes(0, 700), 10_000);
        assert!(seen.first_bytes);
        assert_eq!(job.percent, 36, "not back to 0");
        assert_eq!(
            job.bytes_total,
            Some(1000),
            "fixed by the job's first event"
        );
        job.progress(&bytes(100, 700), 11_000);
        assert_eq!(job.record(11_000).bytes_done, 500);
        assert_eq!(job.percent, 45);
        job.progress(&bytes(700, 700), 12_000);
        assert_eq!(
            job.percent, DOWNLOAD_END,
            "capped: the lost layer was fetched twice"
        );
        assert_eq!(job.record(12_000).bytes_done, 1100);
    }

    #[test]
    fn rate_and_eta_while_running() {
        let mut job = Job::new("os-1", "0.0.20", 100);
        job.progress(&bytes(0, 100_000_000), 0);
        job.progress(&bytes(10_000_000, 100_000_000), 1000);
        let r = job.record(1000);
        assert_eq!(r.rate_bps, 10_000_000);
        assert_eq!(r.eta_s, 9);
        assert_eq!(job.record(20_000).rate_bps, 0, "stalled");
        assert_eq!(job.record(20_000).eta_s, 0);
    }

    #[test]
    fn the_record_has_the_contracts_constants() {
        let r = Job::new("os-7", "0.0.20", 100).record(0);
        assert_eq!((r.source, r.kind, r.app.as_str()), ("update", "os", ""));
        assert_eq!(r.title, "RuyaOS 0.0.20");
        assert_eq!((r.state, r.position, r.started), ("running", 0, 100));
        assert_eq!(JobState::Paused.as_str(), "paused");
        assert_eq!(JobState::Finished.as_str(), "finished");
        assert_eq!(
            (STATUS_OK, STATUS_FAILED, STATUS_CANCELLED, REASON_PLAYING),
            ("ok", "failed", "cancelled", "playing")
        );
    }

    #[test]
    fn a_kept_job_comes_back_paused() {
        let mut job = Job::new("os-1", "0.0.20", 100);
        job.progress(&bytes(400, 1000), 0);
        job.pause(REASON_PLAYING);
        let back = Job::from_json(&job.to_json()).expect("reads");
        let r = back.record(0);
        assert_eq!(r, job.record(0));
        assert_eq!(r.reason, "playing");
        // A job kept while it ran (the service stopped under it) is paused.
        let mut running = Job::new("os-2", "0.0.20", 100);
        running.progress(&bytes(10, 1000), 0);
        let back = Job::from_json(&running.to_json()).expect("reads");
        assert_eq!(back.state, JobState::Paused);
        assert_eq!(back.bytes_done(), 10);
        for bad in [
            "not json",
            "{}",
            r#"{"id":"","version":"x","reason":"","percent":1,"bytes_done":1,"bytes_total":null,"started":1}"#,
            r#"{"id":"a","version":"x","reason":"why","percent":1,"bytes_done":1,"bytes_total":null,"started":1}"#,
            r#"{"id":"a","version":"x","reason":"","percent":100,"bytes_done":1,"bytes_total":null,"started":1}"#,
        ] {
            assert!(Job::from_json(bad).is_err(), "{bad}");
        }
    }
}
