//! The job table (`ListJobs`): what is queued or running and the last finished jobs, kept in a
//! small text file so a restarted service still knows them. The file is read as untrusted input:
//! a line that does not parse is dropped, and every app id passes `valid_app_id` again.

use crate::app::{valid_app_id, JobStatus};
use crate::flatpak::{Operation, Phase};

/// Finished jobs kept besides the active ones.
pub const FINISHED_KEPT: usize = 20;

const HEADER: &str = "ruya-store-jobs 1";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobKind {
    Install,
    Remove,
    Update,
    Rollback,
}

impl JobKind {
    pub fn of(op: &Operation) -> Self {
        match op {
            Operation::Install { .. } => JobKind::Install,
            Operation::Uninstall { .. } => JobKind::Remove,
            Operation::Update { .. } => JobKind::Update,
            Operation::Rollback { .. } => JobKind::Rollback,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            JobKind::Install => "install",
            JobKind::Remove => "remove",
            JobKind::Update => "update",
            JobKind::Rollback => "rollback",
        }
    }

    fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "install" => JobKind::Install,
            "remove" => JobKind::Remove,
            "update" => JobKind::Update,
            "rollback" => JobKind::Rollback,
            _ => return None,
        })
    }

    /// The phase a job of this kind starts in.
    pub fn phase(self) -> Phase {
        match self {
            JobKind::Install => Phase::Install,
            JobKind::Remove => Phase::Remove,
            JobKind::Update | JobKind::Rollback => Phase::Update,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobState {
    Queued,
    Running,
    Finished,
}

impl JobState {
    pub fn as_str(self) -> &'static str {
        match self {
            JobState::Queued => "queued",
            JobState::Running => "running",
            JobState::Finished => "finished",
        }
    }

    fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "queued" => JobState::Queued,
            "running" => JobState::Running,
            "finished" => JobState::Finished,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JobInfo {
    pub id: String,
    pub app: String,
    pub kind: JobKind,
    pub state: JobState,
    /// Set once the job is finished.
    pub status: Option<JobStatus>,
    /// The service died while the job was queued or running (`reason` of the contract).
    pub interrupted: bool,
    pub percent: u32,
    pub phase: Phase,
}

impl JobInfo {
    pub fn queued(id: &str, op: &Operation) -> Self {
        let kind = JobKind::of(op);
        JobInfo {
            id: id.to_owned(),
            app: op.app().to_owned(),
            kind,
            state: JobState::Queued,
            status: None,
            interrupted: false,
            percent: 0,
            phase: kind.phase(),
        }
    }

    pub fn is_active(&self) -> bool {
        self.state != JobState::Finished
    }

    pub fn reason(&self) -> &'static str {
        if self.interrupted {
            "interrupted"
        } else {
            ""
        }
    }

    pub fn finish(&mut self, status: JobStatus) {
        self.state = JobState::Finished;
        self.status = Some(status);
        if status == JobStatus::Ok {
            self.percent = 100;
        }
    }
}

/// Drops the oldest finished jobs beyond `FINISHED_KEPT`; active jobs stay.
pub fn trim(jobs: &mut Vec<JobInfo>) {
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

/// The number in "job-12".
pub fn job_number(id: &str) -> Option<u64> {
    id.strip_prefix("job-")?.parse().ok()
}

/// The file's content: the highest job number handed out (names are never reused), then one line
/// per job. Fields are tab-separated; none can contain a tab (ids are validated, the rest are
/// fixed words).
pub fn encode(counter: u64, jobs: &[JobInfo]) -> String {
    let mut text = format!("{HEADER}\ncounter\t{counter}\n");
    for j in jobs {
        text.push_str(&format!(
            "job\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
            j.id,
            j.app,
            j.kind.as_str(),
            j.state.as_str(),
            j.status.map_or("", |s| s.as_str()),
            if j.interrupted { "interrupted" } else { "" },
            j.percent.min(100),
        ));
    }
    text
}

/// The counter and the jobs of a file written by `encode`; nothing for a file that is not one.
/// The counter is at least the highest number of any job read.
pub fn decode(text: &str) -> (u64, Vec<JobInfo>) {
    let mut lines = text.lines();
    if lines.next() != Some(HEADER) {
        return (0, Vec::new());
    }
    let mut counter = 0u64;
    let mut jobs: Vec<JobInfo> = Vec::new();
    for line in lines {
        let f: Vec<&str> = line.split('\t').collect();
        match f.as_slice() {
            ["counter", n] => counter = counter.max(n.parse().unwrap_or(0)),
            ["job", id, app, kind, state, status, reason, percent] => {
                let (Some(number), Some(kind), Some(state)) =
                    (job_number(id), JobKind::parse(kind), JobState::parse(state))
                else {
                    continue;
                };
                let status = if status.is_empty() {
                    None
                } else {
                    match JobStatus::parse(status) {
                        Some(s) => Some(s),
                        None => continue,
                    }
                };
                // A finished job has a result, an active one has none.
                if (state == JobState::Finished) != status.is_some() || !valid_app_id(app) {
                    continue;
                }
                if jobs.iter().any(|j| j.id == *id) {
                    continue;
                }
                counter = counter.max(number);
                jobs.push(JobInfo {
                    id: (*id).to_owned(),
                    app: (*app).to_owned(),
                    kind,
                    state,
                    status,
                    interrupted: *reason == "interrupted",
                    percent: percent.parse::<u32>().unwrap_or(0).min(100),
                    phase: kind.phase(),
                });
            }
            _ => {}
        }
    }
    (counter, jobs)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job(n: u64, state: JobState, status: Option<JobStatus>) -> JobInfo {
        JobInfo {
            id: format!("job-{n}"),
            app: "org.example.Racer".into(),
            kind: JobKind::Install,
            state,
            status,
            interrupted: false,
            percent: 40,
            phase: Phase::Install,
        }
    }

    #[test]
    fn the_file_round_trips() {
        let mut interrupted = job(3, JobState::Finished, Some(JobStatus::Failed));
        interrupted.interrupted = true;
        let jobs = vec![
            job(1, JobState::Finished, Some(JobStatus::Ok)),
            job(2, JobState::Running, None),
            interrupted,
            job(4, JobState::Queued, None),
        ];
        let (counter, back) = decode(&encode(9, &jobs));
        assert_eq!(
            counter, 9,
            "the counter outlives the jobs that were trimmed"
        );
        assert_eq!(back, jobs);
    }

    #[test]
    fn the_counter_is_at_least_the_highest_job() {
        let text = encode(0, &[job(7, JobState::Queued, None)]);
        assert_eq!(decode(&text).0, 7);
    }

    #[test]
    fn a_damaged_file_gives_what_is_readable() {
        assert_eq!(decode(""), (0, Vec::new()));
        assert_eq!(decode("something else\ncounter\t5\n"), (0, Vec::new()));
        let good = encode(2, &[job(2, JobState::Queued, None)]);
        let text = format!(
            "{good}job\tjob-x\torg.example.Racer\tinstall\tqueued\t\t\t0\n\
             job\tjob-5\t--user\tinstall\tqueued\t\t\t0\n\
             job\tjob-6\torg.example.Racer\tfly\tqueued\t\t\t0\n\
             job\tjob-7\torg.example.Racer\tinstall\tfinished\t\t\t0\n\
             job\tjob-8\torg.example.Racer\tinstall\tqueued\tok\t\t0\n\
             job\tjob-2\torg.example.Racer\tinstall\tqueued\t\t\t0\n\
             half a line\n"
        );
        let (counter, jobs) = decode(&text);
        assert_eq!(jobs.len(), 1, "{jobs:?}");
        assert_eq!(counter, 2);
    }

    #[test]
    fn only_the_newest_finished_jobs_are_kept() {
        let mut jobs: Vec<JobInfo> = (1..=25)
            .map(|n| job(n, JobState::Finished, Some(JobStatus::Ok)))
            .collect();
        jobs.insert(0, job(100, JobState::Running, None));
        trim(&mut jobs);
        assert_eq!(jobs.len(), FINISHED_KEPT + 1);
        assert_eq!(jobs[0].id, "job-100", "an active job is never dropped");
        assert_eq!(jobs[1].id, "job-6", "the oldest finished ones went");
    }
}
