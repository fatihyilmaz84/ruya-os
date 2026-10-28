//! The one transaction queue (spec 03 §4.3): jobs run one at a time in the order they were
//! queued, and an app with a job queued or running refuses another with `busy`. Pure state, no
//! threads: the service takes the next job when the previous one has finished.

use std::collections::VecDeque;

use crate::flatpak::{Operation, Phase};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Job {
    /// Opaque to clients ("job-1").
    pub id: String,
    pub op: Operation,
}

#[derive(Debug, Default)]
pub struct Queue {
    pending: VecDeque<Job>,
    running: Option<Job>,
    counter: u64,
}

impl Queue {
    /// Queues a transaction; `None` when the app already has a job queued or running.
    pub fn enqueue(&mut self, op: Operation) -> Option<String> {
        if self.busy(op.app()) {
            return None;
        }
        self.counter += 1;
        let id = format!("job-{}", self.counter);
        self.pending.push_back(Job { id: id.clone(), op });
        Some(id)
    }

    pub fn busy(&self, app: &str) -> bool {
        self.running
            .iter()
            .chain(self.pending.iter())
            .any(|j| j.op.app() == app)
    }

    /// Starts the oldest queued job unless one is running.
    pub fn take_next(&mut self) -> Option<Job> {
        if self.running.is_some() {
            return None;
        }
        let job = self.pending.pop_front()?;
        self.running = Some(job.clone());
        Some(job)
    }

    pub fn finish(&mut self, id: &str) {
        if self.running.as_ref().is_some_and(|j| j.id == id) {
            self.running = None;
        }
    }

    pub fn is_idle(&self) -> bool {
        self.running.is_none() && self.pending.is_empty()
    }
}

/// Keeps the progress of one job from going backwards and from repeating itself.
#[derive(Debug, Default)]
pub struct Monotone {
    last: Option<u32>,
}

impl Monotone {
    /// The percentage to report for a raw one (clamped to 100), or `None` when it would not
    /// move the bar.
    pub fn next(&mut self, percent: u32, _phase: Phase) -> Option<u32> {
        let percent = percent.min(100);
        match self.last {
            Some(last) if percent <= last => None,
            _ => {
                self.last = Some(percent);
                Some(percent)
            }
        }
    }

    pub fn reached(&self) -> u32 {
        self.last.unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn install(id: &str) -> Operation {
        Operation::Install {
            id: id.to_owned(),
            remote: "ruya".to_owned(),
        }
    }

    #[test]
    fn jobs_run_one_at_a_time_in_order() {
        let mut q = Queue::default();
        let a = q.enqueue(install("org.a.One")).unwrap();
        let b = q.enqueue(install("org.a.Two")).unwrap();
        assert_ne!(a, b);
        assert_eq!(q.take_next().unwrap().id, a);
        assert!(q.take_next().is_none(), "one is running");
        q.finish(&a);
        assert_eq!(q.take_next().unwrap().id, b);
        q.finish(&b);
        assert!(q.take_next().is_none());
        assert!(q.is_idle());
    }

    #[test]
    fn a_second_job_for_the_same_app_is_busy() {
        let mut q = Queue::default();
        let first = q.enqueue(install("org.a.One")).unwrap();
        assert!(q.enqueue(install("org.a.One")).is_none(), "queued");
        assert!(q
            .enqueue(Operation::Uninstall {
                id: "org.a.One".into(),
                delete_data: false
            })
            .is_none());
        q.take_next();
        assert!(q.enqueue(install("org.a.One")).is_none(), "running");
        q.finish(&first);
        assert!(q.enqueue(install("org.a.One")).is_some(), "finished");
    }

    #[test]
    fn finishing_another_job_changes_nothing() {
        let mut q = Queue::default();
        q.enqueue(install("org.a.One")).unwrap();
        q.take_next().unwrap();
        q.finish("job-99");
        assert!(q.busy("org.a.One"));
    }

    #[test]
    fn progress_never_decreases_or_repeats() {
        let mut m = Monotone::default();
        let seen: Vec<_> = [0, 10, 10, 5, 60, 40, 100, 100, 250]
            .into_iter()
            .filter_map(|p| m.next(p, Phase::Download))
            .collect();
        assert_eq!(seen, [0, 10, 60, 100]);
        assert_eq!(m.reached(), 100);
    }
}
