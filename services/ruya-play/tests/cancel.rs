//! RUY-99 acceptance: a cancel at five points (before the unpack, in the middle of a file, after
//! the last file, during the art step, during the commit) ends with nothing left in staging and
//! the right status; plus the cancel of a queued job and the method statuses of `Cancel`.

mod common;

use common::*;
use ruya_play::core::fakes::FnHooks;
use ruya_play::{Canceller, Event, JobStatus, MethodStatus, Step};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

/// What the hook saw when it cancelled: the answer of `Cancel` and the staging directory's
/// content; then every step that still came after the cancel.
type Seen = Arc<Mutex<(Vec<(MethodStatus, Vec<String>)>, Vec<String>)>>;

/// A harness whose hook cancels the job at the first step `at` accepts.
fn cancelling(at: fn(&Step<'_>) -> bool) -> (Harness, Seen) {
    let canceller: Arc<OnceLock<Canceller>> = Arc::default();
    let staging: Arc<OnceLock<PathBuf>> = Arc::default();
    let seen: Seen = Arc::default();
    let (c, s, seen2) = (
        Arc::clone(&canceller),
        Arc::clone(&staging),
        Arc::clone(&seen),
    );
    let mut setup = Setup::with(Pkg::signed(&game()));
    setup.hooks = Box::new(FnHooks(move |job: &str, step: &Step<'_>| {
        if let Step::StagingCreated { dir } = step {
            let _ = s.set(dir.to_path_buf());
        }
        let mut seen = seen2.lock().unwrap();
        if !seen.0.is_empty() {
            seen.1.push(format!("{step:?}"));
        } else if at(step) {
            let answer = c.get().expect("set after build").cancel(job);
            let staged = s.get().map(|d| listing(d)).unwrap_or_default();
            seen.0.push((answer, staged));
        }
    }));
    let h = setup.build();
    let _ = canceller.set(h.importer.canceller());
    (h, seen)
}

#[track_caller]
fn assert_cancelled(h: &Harness, seen: &Seen, r: &ruya_play::JobResult) -> Vec<String> {
    assert_eq!(r.status, JobStatus::Cancelled, "{:?}", r.problems);
    assert!(r.problems.is_empty(), "{:?}", r.problems);
    h.assert_nothing_left();
    h.assert_events_ordered();
    assert_eq!(
        h.events.last(),
        Some(&Event::Finished {
            job: "job-1".into(),
            status: JobStatus::Cancelled
        })
    );
    assert_eq!(h.importer.list_jobs()[0].status, Some(JobStatus::Cancelled));
    let seen = seen.lock().unwrap();
    assert_eq!(seen.0.len(), 1, "the hook never cancelled");
    assert_eq!(seen.0[0].0, MethodStatus::Ok);
    // The job stopped where it was cancelled: no later step ran.
    assert_eq!(seen.1, Vec::<String>::new(), "steps after the cancel");
    seen.0[0].1.clone()
}

#[test]
fn cancel_before_the_unpack() {
    let (mut h, seen) = cancelling(|s| *s == Step::BeforeUnpack);
    let r = h.install();
    let staged = assert_cancelled(&h, &seen, &r);
    assert_eq!(staged, Vec::<String>::new(), "nothing was staged yet");
}

#[test]
fn cancel_in_the_middle_of_a_file() {
    let (mut h, seen) = cancelling(
        |s| matches!(s, Step::Chunk { path, done } if *path == "payload/data.bin" && *done < 1024 * 1024),
    );
    let r = h.install();
    let staged = assert_cancelled(&h, &seen, &r);
    assert!(
        staged.contains(&"tree/payload/data.bin".to_string()),
        "the file was being written: {staged:?}"
    );
    assert!(
        !staged.contains(&"tree/payload/game".to_string()),
        "{staged:?}"
    );
}

#[test]
fn cancel_after_the_last_file() {
    let (mut h, seen) = cancelling(|s| *s == Step::Unpacked);
    let r = h.install();
    let staged = assert_cancelled(&h, &seen, &r);
    assert!(
        staged.contains(&"tree/payload/game".to_string()),
        "{staged:?}"
    );
}

#[test]
fn cancel_during_the_art_step() {
    let (mut h, seen) = cancelling(|s| matches!(s, Step::ArtSlot { slot } if slot == "icon"));
    let r = h.install();
    assert_cancelled(&h, &seen, &r);
}

#[test]
fn cancel_during_the_commit_is_too_late_and_the_install_ends_ok() {
    let canceller: Arc<OnceLock<Canceller>> = Arc::default();
    let answers: Arc<Mutex<Vec<MethodStatus>>> = Arc::default();
    let (c, a) = (Arc::clone(&canceller), Arc::clone(&answers));
    let mut setup = Setup::with(Pkg::signed(&game()));
    setup.commit_hook = Some(Box::new(move |req| {
        a.lock().unwrap().push(c.get().unwrap().cancel(req.job));
    }));
    let mut h = setup.build();
    let _ = canceller.set(h.importer.canceller());
    let r = h.install();
    assert_eq!(*answers.lock().unwrap(), vec![MethodStatus::TooLate]);
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    assert_eq!(h.staging(), Vec::<String>::new());
    assert!(h
        .installed_files()
        .contains(&"play.com.example.mini/payload/game".to_string()));
    h.assert_events_ordered();
}

#[test]
fn a_queued_job_is_cancelled_without_opening_the_package() {
    let mut h = Setup::with(Pkg::signed(&game())).build();
    let (_, job) = h.importer.queue_install(&pkg_path("game.play"), true);
    assert_eq!(h.importer.cancel(&job), MethodStatus::Ok);
    let mut events = Vec::new();
    let r = h.importer.run_next(&mut |e| events.push(e)).unwrap();
    assert_eq!(r.status, JobStatus::Cancelled);
    assert!(r.inspection.is_none(), "the package was opened");
    assert_eq!(
        events,
        vec![Event::Finished {
            job: job.clone(),
            status: JobStatus::Cancelled
        }]
    );
    h.events = events;
    h.assert_nothing_left();
    assert_eq!(h.importer.cancel(&job), MethodStatus::TooLate);
    assert_eq!(h.importer.cancel("job-99"), MethodStatus::UnknownJob);
}
