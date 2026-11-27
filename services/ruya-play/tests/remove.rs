//! RUY-816 acceptance: `Play1.Remove` is the one owner of removing a `.play` app. It runs the
//! fixed Flatpak uninstall through the commit's runner, records the uninstall (the key record
//! stays, so a reinstall under another key is still refused), forgets the installed build, and
//! changes nothing when Flatpak fails. The method statuses, the job's events and the job record.

mod common;

use common::*;
use ruya_play::core::installed::MemoryInstalled;
use ruya_play::service::commit::{self, FlatpakCommit};
use ruya_play::{
    Commit, CommitError, Event, JobKind, JobResult, JobState, JobStatus, MethodStatus, Phase,
};
use std::sync::Arc;

const ID: &str = "com.example.mini";

/// A console with the game installed through the importer (key record, build 1) and deployed.
fn installed_game() -> Harness {
    let fx = game();
    let mut fx2 = game();
    fx2.manifest["build"] = serde_json::json!(2);
    let setup = Setup {
        packages: vec![
            (pkg_path("game.play"), Pkg::signed(&fx)),
            (
                pkg_path("other"),
                Pkg::Signed(Box::new(Pkg::Mem(fx2.mem())), Arc::new(other_key()), None),
            ),
        ],
        ..Setup::default()
    };
    let mut h = setup.build();
    assert_eq!(h.install().status, JobStatus::Ok);
    deploy(&h, ID, &fx);
    h
}

/// Queue a remove of `play.<id>` and run it.
fn remove(h: &mut Harness, id: &str) -> JobResult {
    let (status, job) = h.importer.queue_remove(id);
    assert_eq!(status, MethodStatus::Ok);
    let mut events = Vec::new();
    let r = h.importer.run_next(&mut |e| events.push(e)).expect("ran");
    assert_eq!(r.job, job);
    h.events = events;
    r
}

#[test]
fn the_flatpak_uninstall_is_a_fixed_argument_list_on_the_commits_runner() {
    let state = tempfile::tempdir().unwrap();
    let runner = Arc::new(FakeRunner::default());
    let flatpak = FlatpakCommit::new(state.path(), Box::new(runner.clone()));
    flatpak.uninstall(ID).unwrap();
    let want = [
        "flatpak",
        "uninstall",
        "--system",
        "--noninteractive",
        "-y",
        "play.com.example.mini",
    ]
    .map(String::from)
    .to_vec();
    assert_eq!(commit::uninstall(ID), want);
    // The uninstall is the first command; the reset of the override follows (RUY-923).
    assert_eq!(runner.calls.lock().unwrap()[0], want);
}

/// `flatpak override --system --reset play.<id>`, as `Store::drop_override` runs it.
fn reset_argv() -> Vec<String> {
    [
        "flatpak",
        "override",
        "--system",
        "--reset",
        "play.com.example.mini",
    ]
    .map(String::from)
    .to_vec()
}

#[test]
fn an_uninstall_resets_the_apps_override_after_it() {
    let state = tempfile::tempdir().unwrap();
    let runner = Arc::new(FakeRunner::default());
    let flatpak = FlatpakCommit::new(state.path(), Box::new(runner.clone()));
    flatpak.uninstall(ID).unwrap();
    assert_eq!(commit::reset_override(ID), reset_argv());
    // RUY-1245: then the app's builds leave the local repo (both refs, then a prune).
    let paths = commit::Paths::under(state.path());
    assert_eq!(
        runner.calls.lock().unwrap().as_slice(),
        [
            commit::uninstall(ID),
            reset_argv(),
            commit::delete_refs(&paths, &[commit::app_ref(ID), commit::previous_ref(ID)]),
            commit::prune(&paths),
        ],
        "the uninstall, then the reset, then the repo, nothing else"
    );
}

/// Fails the commands it is told to; records every call.
struct Failing {
    word: &'static str,
    calls: std::sync::Mutex<Vec<Vec<String>>>,
}

impl commit::Runner for Failing {
    fn run(&self, argv: &[String]) -> Result<String, String> {
        self.calls.lock().unwrap().push(argv.to_vec());
        if argv.iter().any(|a| a == self.word) {
            Err(format!("flatpak {} failed", self.word))
        } else {
            Ok(String::new())
        }
    }
}

#[test]
fn a_failed_reset_is_logged_and_does_not_fail_the_removal() {
    let state = tempfile::tempdir().unwrap();
    let runner = Arc::new(Failing {
        word: "--reset",
        calls: Default::default(),
    });
    let flatpak = FlatpakCommit::new(state.path(), Box::new(runner.clone()));
    flatpak.uninstall(ID).unwrap();
    let calls = runner.calls.lock().unwrap().clone();
    assert_eq!(calls[1], reset_argv(), "the reset was tried");
    // RUY-1245: the repo's refs of the app still go after it (uninstall, reset, refs, prune).
    assert_eq!(calls.len(), 4, "{calls:?}");
}

#[test]
fn a_failed_uninstall_resets_nothing() {
    let state = tempfile::tempdir().unwrap();
    let runner = Arc::new(Failing {
        word: "uninstall",
        calls: Default::default(),
    });
    let flatpak = FlatpakCommit::new(state.path(), Box::new(runner.clone()));
    assert!(flatpak.uninstall(ID).is_err());
    assert_eq!(
        runner.calls.lock().unwrap().as_slice(),
        [commit::uninstall(ID)],
        "an app that is still installed keeps its override"
    );
}

#[test]
fn a_remove_uninstalls_records_it_and_keeps_the_key() {
    let mut h = installed_game();
    assert_eq!(h.importer.installed_build(ID).unwrap(), Some(1));
    let r = remove(&mut h, ID);
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    assert_eq!(h.commit.uninstalls(), vec![ID.to_string()]);
    assert_eq!(h.importer.installed_build(ID).unwrap(), None);

    h.assert_events_ordered();
    let phases: Vec<Phase> = h
        .events
        .iter()
        .filter_map(|e| match e {
            Event::Progress { phase, .. } => Some(*phase),
            _ => None,
        })
        .collect();
    assert!(!phases.is_empty());
    assert!(phases.iter().all(|p| *p == Phase::Removing), "{phases:?}");
    let record = h.importer.list_jobs().pop().unwrap();
    assert_eq!(record.kind, JobKind::Remove);
    assert_eq!(record.state, JobState::Finished);
    assert_eq!(record.app, format!("play.{ID}"));
    assert_eq!(record.name, "Mini");
    assert_eq!(record.percent, 100);

    // The key record survived (the player's data is kept): another key is still refused, the
    // first key may come back.
    let again = h.install_at(&pkg_path("other"));
    assert_eq!(
        (again.status, codes(&again)),
        (
            JobStatus::DifferentDeveloper,
            vec!["trust.different_developer".to_string()]
        )
    );
    assert_eq!(h.install().status, JobStatus::Ok);
}

#[test]
fn a_failed_uninstall_leaves_every_record_as_it_was() {
    let mut h = installed_game();
    *h.commit.fail.lock().unwrap() = Some(CommitError::Failed("flatpak is busy".into()));
    let r = remove(&mut h, ID);
    assert_eq!(
        (r.status, codes(&r)),
        (JobStatus::Failed, vec!["uninstall.failed".to_string()])
    );
    assert_eq!(h.importer.installed_build(ID).unwrap(), Some(1));
    let other = h.install_at(&pkg_path("other"));
    assert_eq!(other.status, JobStatus::DifferentDeveloper);
    let record = h
        .importer
        .list_jobs()
        .into_iter()
        .find(|j| j.kind == JobKind::Remove);
    assert_eq!(record.unwrap().status, Some(JobStatus::Failed));
}

#[test]
fn a_record_that_cannot_be_written_after_the_uninstall_fails_the_job() {
    let installed = SharedInstalled::default();
    let fx = game();
    let setup = Setup {
        stores: Some((SharedTrust::default(), installed.clone())),
        ..Setup::with(Pkg::signed(&fx))
    };
    let mut h = setup.build();
    assert_eq!(h.install().status, JobStatus::Ok);
    deploy(&h, ID, &fx);
    installed
        .faults
        .forget
        .store(true, std::sync::atomic::Ordering::SeqCst);
    let r = remove(&mut h, ID);
    assert_eq!(
        (r.status, codes(&r)),
        (JobStatus::Failed, vec!["installed.io".to_string()])
    );
    // Flatpak did uninstall; the next start's reconcile forgets the build.
    assert_eq!(h.commit.uninstalls(), vec![ID.to_string()]);
}

#[test]
fn only_an_app_of_ours_is_unknown_or_removed() {
    let h = installed_game();
    // Not a plain name.
    assert_eq!(h.importer.queue_remove("").0, MethodStatus::Invalid);
    assert_eq!(h.importer.queue_remove("a/b").0, MethodStatus::Invalid);
    // Not installed.
    assert_eq!(
        h.importer.queue_remove("com.example.none").0,
        MethodStatus::UnknownApp
    );
    // Deployed from another remote (a Flathub app named play.<x>).
    write_deploy(&h.cfg.flatpak, ID, "flathub");
    assert_eq!(h.importer.queue_remove(ID).0, MethodStatus::UnknownApp);
    assert!(h
        .importer
        .list_jobs()
        .iter()
        .all(|j| j.kind != JobKind::Remove));
    // Turned foreign between the queueing and the run: never uninstalled.
    write_deploy(&h.cfg.flatpak, ID, ruya_play_art::PLAY_REMOTE);
    let (status, _) = h.importer.queue_remove(ID);
    assert_eq!(status, MethodStatus::Ok);
    write_deploy(&h.cfg.flatpak, ID, "flathub");
    let r = h.importer.run_next(&mut |_| {}).unwrap();
    assert_eq!(
        (r.status, codes(&r)),
        (JobStatus::Failed, vec!["uninstall.failed".to_string()])
    );
    assert!(h.commit.uninstalls().is_empty());
}

#[test]
fn a_job_of_the_same_app_makes_a_remove_busy() {
    let h = installed_game();
    let (status, _) = h.importer.queue_verify(ID);
    assert_eq!(status, MethodStatus::Ok);
    assert_eq!(h.importer.queue_remove(ID).0, MethodStatus::Busy);
    // Once the verify is done the remove is accepted, and a second one is busy.
    h.importer.run_next(&mut |_| {}).unwrap();
    assert_eq!(h.importer.queue_remove(ID).0, MethodStatus::Ok);
    assert_eq!(h.importer.queue_remove(ID).0, MethodStatus::Busy);
}

#[test]
fn a_queued_remove_can_be_cancelled_and_then_uninstalls_nothing() {
    let mut h = installed_game();
    let (_, job) = h.importer.queue_remove(ID);
    assert_eq!(h.importer.cancel(&job), MethodStatus::Ok);
    let r = h.importer.run_next(&mut |_| {}).unwrap();
    assert_eq!(r.status, JobStatus::Cancelled);
    assert!(h.commit.uninstalls().is_empty());
    assert_eq!(h.importer.installed_build(ID).unwrap(), Some(1));
    // A finished remove cannot be cancelled.
    let r = remove(&mut h, ID);
    assert_eq!(h.importer.cancel(&r.job), MethodStatus::TooLate);
}

#[test]
fn a_remove_lifts_the_hold_of_its_id() {
    let mut h = installed_game();
    h.importer.hold(ID, "the build cannot be read");
    assert_eq!(h.importer.held(), vec![ID.to_string()]);
    assert_eq!(remove(&mut h, ID).status, JobStatus::Ok);
    assert!(h.importer.held().is_empty());
}

#[test]
fn jobs_carry_the_apps_name_and_old_tables_read_without_one() {
    let h = installed_game();
    let install = h.importer.list_jobs().remove(0);
    assert_eq!(
        (install.kind, install.name.as_str()),
        (JobKind::Install, "Mini")
    );
    let (_, job) = h.importer.queue_verify(ID);
    let verify = h
        .importer
        .list_jobs()
        .into_iter()
        .find(|j| j.job == job)
        .unwrap();
    assert_eq!(verify.name, "Mini");
    h.importer.run_next(&mut |_| {}).unwrap();
    // The name survives a restart.
    let Harness { root, .. } = h;
    let h = Harness::open_in(root, Setup::default());
    assert!(h.importer.list_jobs().iter().all(|j| j.name == "Mini"));
    // A table written before the field existed has none.
    let text = std::fs::read_to_string(h.cfg.jobs_file()).unwrap();
    let old: String = text
        .lines()
        .map(|l| l.replace(r#""name":"Mini","#, ""))
        .collect::<Vec<_>>()
        .join("\n");
    assert!(!old.contains("Mini"));
    let (_, jobs) = ruya_play::core::jobs::decode(&old);
    assert_eq!(jobs.len(), 2);
    assert!(jobs.iter().all(|j| j.name.is_empty()));
}

#[test]
fn removing_one_app_leaves_the_record_of_another() {
    let setup = Setup {
        installed: MemoryInstalled::new()
            .with(ID, 1)
            .with("com.example.other", 3),
        ..Setup::default()
    };
    let mut h = setup.build();
    deploy(&h, ID, &game());
    assert_eq!(remove(&mut h, ID).status, JobStatus::Ok);
    assert_eq!(
        h.importer.installed_build("com.example.other").unwrap(),
        Some(3)
    );
    assert_eq!(h.importer.installed_build(ID).unwrap(), None);
}

#[test]
fn a_running_install_of_the_same_id_makes_a_remove_busy() {
    use ruya_play::core::fakes::FnHooks;
    use ruya_play::Step;
    use std::sync::{mpsc, Mutex};
    let (reached_tx, reached) = mpsc::channel::<()>();
    let (go, go_rx) = mpsc::channel::<()>();
    let (reached_tx, go_rx) = (Mutex::new(reached_tx), Mutex::new(go_rx));
    let fx = game();
    let mut setup = Setup::with(Pkg::signed(&fx));
    // The install stands still before it unpacks: its app name is on the job by then.
    setup.hooks = Box::new(FnHooks(move |_job: &str, step: &Step<'_>| {
        if *step == Step::BeforeUnpack {
            reached_tx.lock().unwrap().send(()).unwrap();
            go_rx.lock().unwrap().recv().unwrap();
        }
    }));
    let h = setup.build();
    deploy(&h, ID, &fx);
    let (status, _) = h.importer.queue_install(&pkg_path("game.play"), true);
    assert_eq!(status, MethodStatus::Ok);
    std::thread::scope(|s| {
        let runner = s.spawn(|| h.importer.run_next(&mut |_| {}));
        reached.recv().unwrap();
        let while_running = h.importer.queue_remove(ID).0;
        go.send(()).unwrap(); // before any assertion: a panic must not leave the install waiting
        runner.join().unwrap();
        assert_eq!(while_running, MethodStatus::Busy);
    });
    assert_eq!(
        h.importer.queue_remove(ID).0,
        MethodStatus::Ok,
        "once it is over"
    );
}
