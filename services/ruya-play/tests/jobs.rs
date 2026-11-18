//! RUY-99 acceptance: after a restart a job left running (or queued) becomes `failed` with the
//! reason `interrupted` once and stays so; it is never resumed; what a crash left in staging is
//! removed at start; the table on disk uses ADR-026's field names.

mod common;

use common::*;
use ruya_play::core::fakes::FnHooks;
use ruya_play::core::jobs::{self, JobKind, JobRecord};
use ruya_play::{JobState, JobStatus, Step};

/// Run the game install and stop the service hard after the last file (a panic stands for the
/// power cut): the staging directory and a `running` job stay behind.
fn crash_after_unpack() -> tempfile::TempDir {
    let mut setup = Setup::with(Pkg::signed(&game()));
    setup.hooks = Box::new(FnHooks(|_job: &str, step: &Step<'_>| {
        if *step == Step::Unpacked {
            panic!("power cut");
        }
    }));
    let h = setup.build();
    let (status, _) = h.importer.queue_install(&pkg_path("game.play"), true);
    assert_eq!(status, ruya_play::MethodStatus::Ok);
    let crashed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        h.importer.run_next(&mut |_| {})
    }));
    assert!(crashed.is_err());
    let left = h.staging();
    assert!(
        left.contains(&"job-1/tree/payload/game".to_string()),
        "{left:?}"
    );
    let (_, on_disk) = jobs::load(&h.cfg.jobs_file()).unwrap();
    assert_eq!(on_disk[0].state, JobState::Running);
    let Harness { root, .. } = h;
    root
}

#[test]
fn a_job_left_running_is_failed_interrupted_once_and_stays_so() {
    let root = crash_after_unpack();
    let h = Harness::open_in(root, Setup::with(Pkg::signed(&game())));
    assert_eq!(
        h.staging(),
        Vec::<String>::new(),
        "the crash's staging is removed"
    );
    let jobs = h.importer.list_jobs();
    assert_eq!(jobs.len(), 1);
    let j = &jobs[0];
    assert_eq!(
        (j.state, j.status),
        (JobState::Finished, Some(JobStatus::Failed))
    );
    assert_eq!(
        (j.reason(), j.error.as_str()),
        ("interrupted", "job.interrupted")
    );
    assert_eq!(j.finished, NOW);
    // Never resumed.
    assert!(h.importer.run_next(&mut |_| {}).is_none());
    assert!(h.commit.calls().is_empty());

    // A second start, later, leaves it as it is.
    let Harness { root, .. } = h;
    let mut later = Setup::with(Pkg::signed(&game()));
    later.now = NOW + 3600;
    let h = Harness::open_in(root, later);
    let again = h.importer.list_jobs();
    assert_eq!(again, jobs);
    // Names are never reused.
    assert_eq!(
        h.importer.queue_install(&pkg_path("game.play"), true).1,
        "job-2"
    );
}

#[test]
fn a_queued_job_is_settled_too_and_finished_ones_stay() {
    let root = tempfile::tempdir().unwrap();
    let cfg = ruya_play::Config::under(root.path());
    std::fs::create_dir_all(&cfg.state).unwrap();
    let queued = JobRecord::queued("job-4", JobKind::Install, "/run/media/usb/a.play");
    let mut done = JobRecord::queued("job-3", JobKind::Install, "/run/media/usb/b.play");
    done.finish(JobStatus::Revoked, "revoked.key", 7);
    std::fs::write(cfg.jobs_file(), jobs::encode(4, &[done.clone(), queued])).unwrap();
    let h = Harness::open_in(root, Setup::default());
    let jobs = h.importer.list_jobs();
    assert_eq!(jobs[0], done);
    assert_eq!(jobs[1].status, Some(JobStatus::Failed));
    assert!(jobs[1].interrupted);
    assert_eq!(h.importer.queue_install(&pkg_path("x"), true).1, "job-5");
}

#[test]
fn the_table_on_disk_uses_the_adr026_names() {
    let mut h = Setup::with(Pkg::signed(&game())).build();
    assert_eq!(h.install().status, JobStatus::Ok);
    let text = std::fs::read_to_string(h.cfg.jobs_file()).unwrap();
    let line: serde_json::Value = serde_json::from_str(text.lines().nth(1).unwrap()).unwrap();
    let size = game()
        .files
        .iter()
        .map(|(_, d)| d.len() as u64)
        .sum::<u64>();
    assert_eq!(line["job"], "job-1");
    assert_eq!(line["source"], "play");
    assert_eq!(line["kind"], "install");
    assert_eq!(line["state"], "finished");
    assert_eq!(line["status"], "ok");
    assert_eq!(line["phase"], "installing");
    assert_eq!(line["percent"], 100);
    assert_eq!(line["bytes_done"], size);
    assert_eq!(line["bytes_total"], size);
    assert_eq!(line["started"], NOW);
    assert_eq!(line["finished"], NOW);
    assert_eq!(line["error"], "");
    assert_eq!(line["app"], "play.com.example.mini");
}

#[test]
#[cfg_attr(
    not(unix),
    ignore = "Unix only: a link left in staging that points outside (runs in CI on Linux and in the VM queue, vm-play-check.sh, RUY-100)"
)]
fn leftovers_are_removed_without_following_links() {
    #[cfg(unix)]
    {
        let root = tempfile::tempdir().unwrap();
        let cfg = ruya_play::Config::under(root.path());
        let outside = root.path().join("keep");
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("precious"), b"x").unwrap();
        let left = cfg.staging.join("job-7").join("tree");
        std::fs::create_dir_all(&left).unwrap();
        std::os::unix::fs::symlink(&outside, left.join("escape")).unwrap();
        std::os::unix::fs::symlink(&outside, cfg.staging.join("job-8")).unwrap();
        let h = Harness::open_in(root, Setup::default());
        assert_eq!(h.staging(), Vec::<String>::new());
        assert_eq!(
            std::fs::read(h.root.path().join("keep").join("precious")).unwrap(),
            b"x"
        );
    }
}

#[test]
fn a_counter_at_its_end_hands_out_no_name_and_does_not_panic() {
    let root = tempfile::tempdir().unwrap();
    let cfg = ruya_play::Config::under(root.path());
    std::fs::create_dir_all(&cfg.state).unwrap();
    let mut last = JobRecord::queued("job-7", JobKind::Install, "/run/media/usb/a.play");
    last.finish(JobStatus::Ok, "", 7);
    std::fs::write(cfg.jobs_file(), jobs::encode(u64::MAX, &[last])).unwrap();
    let h = Harness::open_in(root, Setup::with(Pkg::signed(&game())));
    assert_eq!(
        h.importer.queue_install(&pkg_path("game.play"), true),
        (ruya_play::MethodStatus::Failed, String::new())
    );
    assert_eq!(h.importer.list_jobs().len(), 1);
    let text = std::fs::read_to_string(h.cfg.jobs_file()).unwrap();
    assert!(
        text.starts_with(&format!("{{\"format\":1,\"counter\":{}}}", u64::MAX)),
        "{text}"
    );
}

/// RUY-866: the service's staging/ and inspect/ move to the helpers' mount; the rest stays.
#[test]
fn with_work_moves_only_staging_and_inspect() {
    use std::path::Path;
    let cfg = ruya_play::Config::under(Path::new("/var/lib/ruya-play"))
        .with_work(Path::new("/var/lib/private/ruya-play-work"));
    assert_eq!(
        cfg.staging,
        Path::new("/var/lib/private/ruya-play-work/staging")
    );
    assert_eq!(
        cfg.inspect,
        Path::new("/var/lib/private/ruya-play-work/inspect")
    );
    assert_eq!(cfg.incoming, Path::new("/var/lib/ruya-play/incoming"));
    assert_eq!(cfg.state, Path::new("/var/lib/ruya-play/state"));
    assert_eq!(cfg.jobs_file(), Path::new("/var/lib/ruya-play/state/jobs"));
}
