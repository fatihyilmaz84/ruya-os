//! RUY-1245: `Play1.Rollback` and `GetPrevious`. An update keeps the build it replaces (the repo's
//! `previous` ref, `installed.json`'s `previous`); a rollback checks that build out, holds it to its
//! rules (older, same prefix epoch and runner, same key, not revoked), and commits it again through
//! the re-commit path; the override and the key record are never touched.

mod common;

use common::*;
use ruya_play::core::fakes::FnHooks;
use ruya_play::core::installed::Installed;
use ruya_play::core::reconcile;
use ruya_play::core::staging::Dir;
use ruya_play::dbus::previous_reply;
use ruya_play::service::commit::{self, FlatpakCommit, METADATA_GENERATION, TRUST_RECORD_IN_APP};
use ruya_play::{CommitError, InstalledBuilds, JobKind, JobStatus, MethodStatus, Step};
use ruya_play_trust::{sign_package, IdRecord, SecretKey, TrustStore};
use serde_json::json;
use std::sync::Arc;

const ID: &str = "com.example.mini";

/// `game()` as build `n`, version `1.<n>`, with a file that says which build it is.
fn build(n: u64) -> Fx {
    let mut fx = game();
    fx.manifest["build"] = json!(n);
    fx.manifest["version"] = json!(format!("1.{n}"));
    fx.file("payload/build.txt", format!("build {n}").as_bytes());
    fx
}

/// Deploy `fx` as the app `play.<id>` (replacing what was deployed), with a trust record of the
/// developer tier naming `signer` and, with a signer, its `play.sig`.
fn deploy_as(h: &Harness, id: &str, fx: &Fx, signer: Option<&SecretKey>) {
    let files = files_dir(h, id);
    if files.exists() {
        std::fs::remove_dir_all(&files).unwrap();
    }
    deploy(h, id, fx);
    let key_id = signer.map(|k| k.public().key_id());
    if let Some(key) = signer {
        let build = fx.manifest["build"].as_u64().unwrap();
        let sig =
            sign_package(key, id, build, &fx.manifest_bytes(), &fx.table(), NOW, &[]).unwrap();
        std::fs::write(files.join("play.sig"), sig).unwrap();
    }
    let record = json!({"format": 1, "tier": "developer", "signer_id": key_id, "signer_name": null, "store_signed": false});
    std::fs::write(files.join(TRUST_RECORD_IN_APP), record.to_string()).unwrap();
}

/// An updated app: `prev` was deployed and kept when `cur` replaced it; the records say so (build
/// of `cur`, `previous` the build of `prev`, the current generation), and with a signer the id is
/// recorded under that key.
struct Updated {
    h: Harness,
    trust: SharedTrust,
    installed: SharedInstalled,
}

fn updated_with(prev: &Fx, cur: &Fx, signer: Option<&SecretKey>, setup: Setup) -> Updated {
    let id = cur.manifest["id"].as_str().unwrap().to_string();
    let (trust, installed) = (SharedTrust::default(), SharedInstalled::default());
    let h = Setup {
        stores: Some((trust.clone(), installed.clone())),
        rollbacks: true,
        developer_mode: true,
        ..setup
    }
    .build();
    deploy_as(&h, &id, prev, signer);
    ruya_play::Commit::keep_previous(&*h.commit, &id).unwrap();
    deploy_as(&h, &id, cur, signer);
    {
        let mut i = installed.inner.lock().unwrap();
        i.record(&id, cur.manifest["build"].as_u64().unwrap())
            .unwrap();
        i.stamp(&id, METADATA_GENERATION).unwrap();
        i.set_previous(&id, Some(prev.manifest["build"].as_u64().unwrap()))
            .unwrap();
    }
    if let Some(key) = signer {
        trust
            .inner
            .lock()
            .unwrap()
            .put(IdRecord {
                id: id.clone(),
                key: key.public(),
                first_seen: NOW,
                seq: 0,
                retired: Vec::new(),
            })
            .unwrap();
    }
    h.commit.repo_calls.lock().unwrap().clear();
    Updated {
        h,
        trust,
        installed,
    }
}

fn updated(prev: &Fx, cur: &Fx) -> Updated {
    updated_with(prev, cur, None, Setup::default())
}

fn record(u: &Updated, id: &str) -> Option<Installed> {
    u.installed.inner.lock().unwrap().get(id).unwrap()
}

/// Queue a rollback of `play.<id>` and run it; the job's result.
fn roll_back(h: &mut Harness, id: &str) -> ruya_play::JobResult {
    let (status, job) = h.importer.queue_rollback(id);
    assert_eq!(status, MethodStatus::Ok);
    let mut events = Vec::new();
    let r = h
        .importer
        .run_next(&mut |e| events.push(e))
        .expect("a job ran");
    assert_eq!(r.job, job);
    h.events = events;
    r
}

fn deployed_json(h: &Harness, id: &str) -> Vec<u8> {
    std::fs::read(files_dir(h, id).join("play.json")).unwrap()
}

#[test]
fn a_rollback_brings_the_kept_build_back() {
    let (prev, cur) = (build(1), build(2));
    let mut u = updated(&prev, &cur);
    let previous = u.h.importer.previous(ID).unwrap();
    assert_eq!((previous.version.as_str(), previous.build), ("1.1", 1));
    u.h.commit.repo_calls.lock().unwrap().clear();
    let r = roll_back(&mut u.h, ID);
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    u.h.assert_events_ordered();
    // The kept build went through the re-commit path, read back from its checkout.
    let calls = u.h.commit.recommits();
    assert_eq!(calls.len(), 1);
    assert_eq!((calls[0].id.as_str(), calls[0].build), (ID, 1));
    for want in [
        "play.json",
        "play.files",
        "payload/build.txt",
        TRUST_RECORD_IN_APP,
    ] {
        assert!(
            calls[0].files.iter().any(|f| f == want),
            "{want}: {:?}",
            calls[0].files
        );
    }
    // What is deployed now is the kept build: its play.json, its files, and the trust record of
    // today's decision (unsigned, developer mode on: unverified, whatever its old record said).
    assert_eq!(deployed_json(&u.h, ID), prev.manifest_bytes());
    let trust_json =
        std::fs::read_to_string(files_dir(&u.h, ID).join(TRUST_RECORD_IN_APP)).unwrap();
    assert!(trust_json.contains("\"unverified\""), "{trust_json}");
    assert_eq!(
        std::fs::read_to_string(files_dir(&u.h, ID).join("payload/build.txt")).unwrap(),
        "build 1"
    );
    // installed.json is the deployed build, at the current generation, and keeps nothing.
    let rec = record(&u, ID).unwrap();
    assert_eq!(
        (rec.build, rec.generation, rec.previous),
        (1, METADATA_GENERATION, None)
    );
    assert_eq!(
        u.h.commit.repo_calls(),
        vec![format!("checkout {ID}"), format!("drop {ID}")]
    );
    assert!(u.h.commit.kept(ID).is_none());
    assert!(u.h.staging().is_empty(), "{:?}", u.h.staging());
    // The reconcile finds nothing to correct.
    let deployed = reconcile::deployed_apps(&u.h.cfg.flatpak).unwrap();
    assert_eq!(deployed[ID].build, Some(1));
    let actions = u.h.importer.reconcile_listed(Ok(deployed)).unwrap();
    assert!(actions.is_empty(), "{actions:?}");
    // Nothing is kept any more.
    assert_eq!(u.h.importer.previous(ID), Err(MethodStatus::NoPrevious));
    assert_eq!(u.h.importer.queue_rollback(ID).0, MethodStatus::NoPrevious);
    let jobs = u.h.importer.list_jobs();
    assert_eq!(
        (jobs[0].kind, jobs[0].app.as_str()),
        (JobKind::Rollback, "play.com.example.mini")
    );
    assert_eq!(jobs[0].name, "Mini");
}

#[test]
fn without_an_older_kept_build_it_is_no_previous_and_runs_nothing() {
    // Never updated: no previous in the record.
    let u = updated(&build(1), &build(2));
    u.installed
        .inner
        .lock()
        .unwrap()
        .set_previous(ID, None)
        .unwrap();
    assert_eq!(u.h.importer.queue_rollback(ID).0, MethodStatus::NoPrevious);
    assert_eq!(u.h.importer.previous(ID), Err(MethodStatus::NoPrevious));
    // A kept build equal to or above the installed one (records put back after a failed update).
    for kept in [2, 3] {
        u.installed
            .inner
            .lock()
            .unwrap()
            .set_previous(ID, Some(kept))
            .unwrap();
        assert_eq!(
            u.h.importer.queue_rollback(ID).0,
            MethodStatus::NoPrevious,
            "{kept}"
        );
        assert_eq!(
            u.h.importer.previous(ID),
            Err(MethodStatus::NoPrevious),
            "{kept}"
        );
    }
    assert!(u.h.importer.run_next(&mut |_| {}).is_none());
    assert!(
        u.h.commit.repo_calls().is_empty(),
        "{:?}",
        u.h.commit.repo_calls()
    );
    assert!(u.h.commit.recommits().is_empty());
    assert!(u.h.commit.calls().is_empty());
    // An app that is not installed, or not a plain id.
    assert_eq!(
        u.h.importer.queue_rollback("com.example.none").0,
        MethodStatus::UnknownApp
    );
    assert_eq!(
        u.h.importer.previous("com.example.none"),
        Err(MethodStatus::UnknownApp)
    );
    assert_eq!(u.h.importer.queue_rollback("a/b").0, MethodStatus::Invalid);
    assert_eq!(u.h.importer.previous(""), Err(MethodStatus::Invalid));
}

#[test]
fn a_record_that_names_an_older_build_than_the_repo_keeps_is_refused_and_changes_nothing() {
    // The record says build 1 is kept, but the repo keeps build 2 (a failed update kept the
    // deployed build, then put the records back).
    let mut u = updated(&build(2), &build(2));
    u.installed
        .inner
        .lock()
        .unwrap()
        .set_previous(ID, Some(1))
        .unwrap();
    assert_eq!(u.h.importer.previous(ID), Err(MethodStatus::NoPrevious));
    let r = roll_back(&mut u.h, ID);
    assert_eq!(
        (r.status, codes(&r)),
        (JobStatus::Failed, vec!["rollback.not_older".to_string()])
    );
    assert_eq!(record(&u, ID).unwrap().build, 2);
    assert!(u.h.commit.recommits().is_empty());
    assert!(u.h.staging().is_empty(), "{:?}", u.h.staging());
}

/// A rollback refused by a rule: the job's status and code, and nothing changed (records,
/// deployment, kept build; no commit).
#[track_caller]
fn refused(mut u: Updated, id: &str, status: JobStatus, code: &str) {
    let before = (
        record(&u, id),
        deployed_json(&u.h, id),
        u.trust.inner.lock().unwrap().get(id).unwrap(),
    );
    let r = roll_back(&mut u.h, id);
    assert_eq!(r.status, status, "{:?}", r.problems);
    assert_eq!(codes(&r), vec![code.to_string()]);
    let after = (
        record(&u, id),
        deployed_json(&u.h, id),
        u.trust.inner.lock().unwrap().get(id).unwrap(),
    );
    assert_eq!(after, before);
    assert!(u.h.commit.recommits().is_empty());
    assert!(u.h.commit.kept(id).is_some(), "the kept build stays");
    assert!(u.h.staging().is_empty(), "{:?}", u.h.staging());
}

fn wine(build: u64, epoch: u64) -> Fx {
    let mut fx = Fx::wine_full();
    fx.manifest["build"] = json!(build);
    fx.manifest["run"]["prefix"]["epoch"] = json!(epoch);
    fx
}

const WINE_ID: &str = "com.example.starhopper";

#[test]
fn another_prefix_epoch_is_refused() {
    refused(
        updated(&wine(141, 0), &wine(142, 1)),
        WINE_ID,
        JobStatus::Unsupported,
        "rollback.prefix_epoch",
    );
    // The same epoch goes ahead.
    let mut u = updated(&wine(141, 1), &wine(142, 1));
    let r = roll_back(&mut u.h, WINE_ID);
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
}

#[test]
fn another_runner_is_refused() {
    let mut native = build(141);
    native.manifest["id"] = json!(WINE_ID);
    refused(
        updated(&native, &wine(142, 1)),
        WINE_ID,
        JobStatus::Unsupported,
        "rollback.runner_changed",
    );
}

#[test]
fn a_build_of_another_key_is_refused() {
    let dev = dev_key();
    // The kept build was signed by the key the id had before a rotation; the record names the new.
    let u = updated_with(&build(1), &build(2), Some(&dev), Setup::default());
    let (prev, cur) = (build(1), build(2));
    deploy_as(&u.h, ID, &prev, Some(&other_key()));
    ruya_play::Commit::keep_previous(&*u.h.commit, ID).unwrap();
    deploy_as(&u.h, ID, &cur, Some(&dev));
    u.h.commit.repo_calls.lock().unwrap().clear();
    refused(u, ID, JobStatus::DifferentDeveloper, "rollback.key_changed");
    // An unsigned kept build of an id recorded under a key.
    let u = updated(&build(1), &build(2));
    u.trust
        .inner
        .lock()
        .unwrap()
        .put(IdRecord {
            id: ID.into(),
            key: dev.public(),
            first_seen: NOW,
            seq: 0,
            retired: Vec::new(),
        })
        .unwrap();
    refused(u, ID, JobStatus::DifferentDeveloper, "rollback.key_changed");
    // Signed by the key the id is recorded under: it goes ahead, and the record stays as it was.
    let mut u = updated_with(&build(1), &build(2), Some(&dev), Setup::default());
    let before = u.trust.inner.lock().unwrap().get(ID).unwrap();
    let r = roll_back(&mut u.h, ID);
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    assert_eq!(u.trust.inner.lock().unwrap().get(ID).unwrap(), before);
}

#[test]
fn a_revoked_kept_build_is_refused_and_an_unreadable_list_fails_closed() {
    let with_list = |list: ruya_play::core::fakes::StaticBlocklists| Setup {
        blocklist: list,
        ..Setup::default()
    };
    let lists = [
        ("id com.example.mini 1 Build 1 is broken", "revoked.id"),
        ("id com.example.mini 1-1 Build 1 is broken", "revoked.id"),
    ];
    for (line, code) in lists {
        let setup = with_list(ruya_play::core::fakes::StaticBlocklists::with(&[line]));
        refused(
            updated_with(&build(1), &build(2), None, setup),
            ID,
            JobStatus::Revoked,
            code,
        );
    }
    // Its content: the SHA-256 of its play.files.
    let prev = build(1);
    let line = format!(
        "content {} Known malware",
        ruya_play_format::sha256_hex(&prev.table())
    );
    let setup = with_list(ruya_play::core::fakes::StaticBlocklists::with(&[&line]));
    refused(
        updated_with(&prev, &build(2), None, setup),
        ID,
        JobStatus::Revoked,
        "revoked.content",
    );
    // A block list of builds above it does not refuse it.
    let setup = with_list(ruya_play::core::fakes::StaticBlocklists::with(&[
        "id com.example.mini 2- Bad",
    ]));
    let mut u = updated_with(&build(1), &build(2), None, setup);
    assert_eq!(roll_back(&mut u.h, ID).status, JobStatus::Ok);
    // No list: never rolled back unchecked.
    let setup = with_list(ruya_play::core::fakes::StaticBlocklists { image: None });
    refused(
        updated_with(&build(1), &build(2), None, setup),
        ID,
        JobStatus::Failed,
        "blocklist.unavailable",
    );
}

/// Review round 1: the tier is today's decision, as an install's inspect makes it.
#[test]
fn an_unsigned_kept_build_needs_developer_mode_now() {
    let u = updated(&build(1), &build(2));
    u.trust
        .inner
        .lock()
        .unwrap()
        .set_developer_mode(false)
        .unwrap();
    refused(
        u,
        ID,
        JobStatus::NeedsDeveloperMode,
        "trust.needs_developer_mode",
    );
    // A signed one does not.
    let dev = dev_key();
    let mut u = updated_with(&build(1), &build(2), Some(&dev), Setup::default());
    u.trust
        .inner
        .lock()
        .unwrap()
        .set_developer_mode(false)
        .unwrap();
    assert_eq!(roll_back(&mut u.h, ID).status, JobStatus::Ok);
}

#[test]
fn the_rolled_back_build_carries_todays_trust_record() {
    let dev = dev_key();
    let mut u = updated_with(&build(1), &build(2), Some(&dev), Setup::default());
    // The kept build's own record says something else than today's decision.
    let kept = u.h.commit.kept(ID).unwrap().join(TRUST_RECORD_IN_APP);
    std::fs::write(
        &kept,
        br#"{"format":1,"tier":"unverified","signer_id":null,"signer_name":null,"store_signed":false}"#,
    )
    .unwrap();
    assert_eq!(roll_back(&mut u.h, ID).status, JobStatus::Ok);
    let deployed: serde_json::Value = serde_json::from_slice(
        &std::fs::read(files_dir(&u.h, ID).join(TRUST_RECORD_IN_APP)).unwrap(),
    )
    .unwrap();
    assert_eq!(deployed["tier"], "developer");
    assert_eq!(deployed["signer_id"], dev.public().key_id());
}

#[test]
fn a_failed_update_keeps_no_build_the_repo_no_longer_holds() {
    // Build 2 keeps build 1; the update to 3 keeps 2 (1 is pruned), then its commit fails.
    let mut u = updated_with(
        &build(1),
        &build(2),
        None,
        Setup {
            packages: packages(&[3]),
            ..Setup::default()
        },
    );
    *u.h.commit.fail.lock().unwrap() = Some(CommitError::Failed("export failed".into()));
    let r = u.h.install_at(&pkg_path("b3.play"));
    assert_eq!(r.status, JobStatus::Failed, "{:?}", r.problems);
    let rec = record(&u, ID).unwrap();
    assert_eq!(
        (rec.build, rec.previous),
        (2, None),
        "build 1 is gone from the repo"
    );
    assert_eq!(u.h.importer.previous(ID), Err(MethodStatus::NoPrevious));
}

/// Review round 1: a deployed commit the repo lost (pruned by another app's update while no ref
/// named it) keeps nothing, and the update still installs.
#[test]
fn an_update_whose_deployed_commit_is_gone_installs_and_keeps_nothing() {
    let u = updated_with(
        &build(1),
        &build(2),
        None,
        Setup {
            packages: packages(&[3]),
            ..Setup::default()
        },
    );
    let mut u = u;
    u.h.commit
        .deployed_pruned
        .store(true, std::sync::atomic::Ordering::SeqCst);
    let r = u.h.install_at(&pkg_path("b3.play"));
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    let rec = record(&u, ID).unwrap();
    assert_eq!((rec.build, rec.previous), (3, None));
    assert!(u.h.commit.kept(ID).is_none());
    assert_eq!(u.h.importer.queue_rollback(ID).0, MethodStatus::NoPrevious);
}

#[test]
fn a_failed_commit_puts_the_build_record_back() {
    let mut u = updated(&build(1), &build(2));
    *u.h.commit.fail.lock().unwrap() = Some(CommitError::Failed("export failed".into()));
    let r = roll_back(&mut u.h, ID);
    assert_eq!(
        (r.status, codes(&r)),
        (JobStatus::Failed, vec!["commit.failed".to_string()])
    );
    let rec = record(&u, ID).unwrap();
    assert_eq!((rec.build, rec.previous), (2, Some(1)));
    assert!(u.h.commit.kept(ID).is_some());
    // It can be tried again.
    assert_eq!(roll_back(&mut u.h, ID).status, JobStatus::Ok);
}

/// A rollback that stops hard (a panic stands for the power cut) at `at`; then the service starts
/// again over the same folders and stores and reconciles: `installed.json` names the deployed
/// build, and what is kept is consistent with it.
fn crash_at(at: Step<'static>) -> (Updated, u64) {
    let hooks = FnHooks(move |_job: &str, step: &Step<'_>| {
        if *step == at {
            panic!("power cut");
        }
    });
    let u = updated_with(
        &build(1),
        &build(2),
        None,
        Setup {
            hooks: Box::new(hooks),
            ..Setup::default()
        },
    );
    let (status, _) = u.h.importer.queue_rollback(ID);
    assert_eq!(status, MethodStatus::Ok);
    let crashed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        u.h.importer.run_next(&mut |_| {})
    }));
    assert!(crashed.is_err());
    let Updated {
        h,
        trust,
        installed,
    } = u;
    let Harness { root, .. } = h;
    let h = Harness::open_in(
        root,
        Setup {
            stores: Some((trust.clone(), installed.clone())),
            rollbacks: true,
            // The unsigned fixture still needs developer mode after the restart.
            developer_mode: true,
            ..Setup::default()
        },
    );
    let deployed = reconcile::deployed_apps(&h.cfg.flatpak).unwrap();
    let build = deployed[ID].build.unwrap();
    h.importer.reconcile_listed(Ok(deployed)).unwrap();
    assert_eq!(
        installed
            .inner
            .lock()
            .unwrap()
            .get(ID)
            .unwrap()
            .unwrap()
            .build,
        build
    );
    (
        Updated {
            h,
            trust,
            installed,
        },
        build,
    )
}

#[test]
fn a_crash_at_each_step_ends_with_the_deployed_build_recorded() {
    // Before the commit: build 2 is still deployed, and still keeps build 1, so it can be tried again.
    let (mut u, deployed) = crash_at(Step::Committing);
    assert_eq!(deployed, 2);
    assert_eq!(record(&u, ID).unwrap().older_previous(), Some(1));
    assert_eq!(u.h.importer.previous(ID).unwrap().build, 1);
    assert_eq!(roll_back(&mut u.h, ID).status, JobStatus::Ok);
    // After the commit, before the kept build is forgotten: build 1 is deployed; what is still
    // kept is not older, so there is nothing to roll back to.
    let (u, deployed) = crash_at(Step::Committed);
    assert_eq!(deployed, 1);
    assert_eq!(record(&u, ID).unwrap().older_previous(), None);
    assert_eq!(u.h.importer.previous(ID), Err(MethodStatus::NoPrevious));
    assert_eq!(u.h.importer.queue_rollback(ID).0, MethodStatus::NoPrevious);
}

#[test]
fn a_recommit_keeps_the_kept_build() {
    let u = updated(&build(1), &build(2));
    u.installed.inner.lock().unwrap().stamp(ID, 0).unwrap();
    assert_eq!(u.h.importer.recommit(ID), Ok(ruya_play::Recommitted::Done));
    assert_eq!(record(&u, ID).unwrap().previous, Some(1));
    assert!(
        u.h.commit.repo_calls().is_empty(),
        "{:?}",
        u.h.commit.repo_calls()
    );
    assert!(u.h.commit.kept(ID).is_some());
}

#[test]
fn remove_forgets_the_kept_build() {
    let u = updated(&build(1), &build(2));
    let (status, _) = u.h.importer.queue_remove(ID);
    assert_eq!(status, MethodStatus::Ok);
    assert_eq!(
        u.h.importer.run_next(&mut |_| {}).unwrap().status,
        JobStatus::Ok
    );
    assert_eq!(record(&u, ID), None);
    assert!(u.h.commit.kept(ID).is_none());
}

/// The packages of the install tests below: build `n` of `game()` at `b<n>.play`, unsigned.
fn packages(builds: &[u64]) -> Vec<(std::path::PathBuf, Pkg)> {
    builds
        .iter()
        .map(|n| (pkg_path(&format!("b{n}.play")), Pkg::Mem(build(*n).mem())))
        .collect()
}

#[test]
fn an_update_keeps_the_build_it_replaces_and_only_that_one() {
    let (trust, installed) = (SharedTrust::default(), SharedInstalled::default());
    let mut h = Setup {
        packages: packages(&[1, 2, 3]),
        stores: Some((trust, installed.clone())),
        rollbacks: true,
        developer_mode: true,
        ..Setup::default()
    }
    .build();
    // A first install keeps nothing.
    assert_eq!(h.install_at(&pkg_path("b1.play")).status, JobStatus::Ok);
    assert!(
        h.commit.repo_calls().is_empty(),
        "{:?}",
        h.commit.repo_calls()
    );
    assert_eq!(
        installed
            .inner
            .lock()
            .unwrap()
            .get(ID)
            .unwrap()
            .unwrap()
            .previous,
        None
    );
    deploy_as(&h, ID, &build(1), None);
    // The update keeps the deployed build 1 before its commit.
    assert_eq!(h.install_at(&pkg_path("b2.play")).status, JobStatus::Ok);
    assert_eq!(h.commit.repo_calls(), vec![format!("keep {ID}")]);
    assert_eq!(
        installed
            .inner
            .lock()
            .unwrap()
            .get(ID)
            .unwrap()
            .unwrap()
            .previous,
        Some(1)
    );
    let kept = h.commit.kept(ID).unwrap();
    assert_eq!(
        std::fs::read_to_string(kept.join("payload/build.txt")).unwrap(),
        "build 1"
    );
    deploy_as(&h, ID, &build(2), None);
    // The next one keeps build 2: build 1 is gone (one kept build per app).
    assert_eq!(h.install_at(&pkg_path("b3.play")).status, JobStatus::Ok);
    assert_eq!(
        installed
            .inner
            .lock()
            .unwrap()
            .get(ID)
            .unwrap()
            .unwrap()
            .previous,
        Some(2)
    );
    let kept = h.commit.kept(ID).unwrap();
    assert_eq!(
        std::fs::read_to_string(kept.join("payload/build.txt")).unwrap(),
        "build 2"
    );
}

#[test]
fn an_update_that_cannot_keep_the_replaced_build_fails_and_puts_the_records_back() {
    let (trust, installed) = (SharedTrust::default(), SharedInstalled::default());
    {
        let mut i = installed.inner.lock().unwrap();
        i.record(ID, 1).unwrap();
    }
    let mut h = Setup {
        packages: packages(&[2]),
        stores: Some((trust, installed.clone())),
        rollbacks: true,
        developer_mode: true,
        ..Setup::default()
    }
    .build();
    deploy_as(&h, ID, &build(1), None);
    *h.commit.fail_keep.lock().unwrap() = Some(CommitError::Failed("ostree refs failed".into()));
    let r = h.install_at(&pkg_path("b2.play"));
    assert_eq!(
        (r.status, codes(&r)),
        (JobStatus::Failed, vec!["commit.failed".to_string()])
    );
    let rec = installed.inner.lock().unwrap().get(ID).unwrap().unwrap();
    assert_eq!((rec.build, rec.previous), (1, None));
    assert!(
        h.commit.calls().is_empty(),
        "nothing of build 2 was committed"
    );
}

#[test]
fn after_a_rollback_an_install_must_be_above_the_build_rolled_back_to() {
    let mut u = updated_with(
        &build(1),
        &build(2),
        None,
        Setup {
            packages: packages(&[1, 2]),
            ..Setup::default()
        },
    );
    assert_eq!(roll_back(&mut u.h, ID).status, JobStatus::Ok);
    let r = u.h.install_at(&pkg_path("b1.play"));
    assert_eq!(
        (r.status, codes(&r)),
        (
            JobStatus::InvalidPackage,
            vec!["build.not_newer".to_string()]
        )
    );
    // The build rolled back from is an update again.
    let r = u.h.install_at(&pkg_path("b2.play"));
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    assert_eq!(record(&u, ID).unwrap().build, 2);
}

#[test]
fn get_previous_names_the_kept_build_and_what_it_asks_for_again() {
    let mut prev = build(1);
    prev.manifest["permissions"] = json!({"network": true});
    let mut cur = build(2);
    cur.manifest["permissions"] = json!({"gamemode": true});
    let u = updated(&prev, &cur);
    let p = u.h.importer.previous(ID).unwrap();
    assert_eq!((p.version.as_str(), p.build), ("1.1", 1));
    let keys = |r: &[ruya_play_trust::Request]| r.iter().map(|r| r.key.clone()).collect::<Vec<_>>();
    assert_eq!(keys(&p.update.added), vec!["network"]);
    assert_eq!(keys(&p.update.removed), vec!["gamemode"]);
    // One read of the repo, nothing else.
    assert_eq!(u.h.commit.repo_calls(), vec![format!("file {ID}")]);
    // The D-Bus answer: status, version, build, then the two lists as Inspect's triples.
    let (status, version, build, added, removed) = previous_reply(Ok(p));
    assert_eq!((status.as_str(), version.as_str(), build), ("ok", "1.1", 1));
    assert_eq!(added[0].0, "network");
    assert_eq!(added[0].2, "medium");
    assert_eq!(removed[0].0, "gamemode");
    assert_eq!(
        previous_reply(Err(MethodStatus::NoPrevious)),
        (
            "no-previous".into(),
            String::new(),
            0,
            Vec::new(),
            Vec::new()
        )
    );
}

/// RUY-1245 on the real command lines: an importer over a `FlatpakCommit` whose runner answers
/// like Flatpak and OSTree (`FakeRunner`, the kept build as the checkout).
fn flatpak_updated(
    runner: &Arc<FakeRunner>,
    prev: &Fx,
    cur: &Fx,
) -> (Harness, SharedInstalled, tempfile::TempDir) {
    let lib = tempfile::tempdir().unwrap();
    let (trust, installed) = (SharedTrust::default(), SharedInstalled::default());
    let fc = FlatpakCommit::new(lib.path(), Box::new(runner.clone())).keeping_owner();
    let h = Setup {
        stores: Some((trust, installed.clone())),
        commit: Some(Box::new(fc)),
        developer_mode: true,
        ..Setup::default()
    }
    .build();
    // The kept build: the deployment of `prev`, copied.
    deploy_as(&h, ID, prev, None);
    let kept = lib.path().join("kept");
    copy_dir(&files_dir(&h, ID), &kept);
    std::fs::remove_file(kept.join(".ref")).unwrap();
    *runner.kept.lock().unwrap() = Some(kept);
    deploy_as(&h, ID, cur, None);
    {
        let mut i = installed.inner.lock().unwrap();
        i.record(ID, 2).unwrap();
        i.stamp(ID, METADATA_GENERATION).unwrap();
        i.set_previous(ID, Some(1)).unwrap();
    }
    (h, installed, lib)
}

#[test]
fn the_flatpak_rollback_checks_out_commits_again_and_drops_the_ref() {
    let runner = Arc::new(FakeRunner::default());
    let (prev, cur) = (build(1), build(2));
    let (mut h, installed, lib) = flatpak_updated(&runner, &prev, &cur);
    let r = roll_back(&mut h, ID);
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    let calls = runner.calls.lock().unwrap().clone();
    // The checkout: the kept ref's files/, as copies, without ownership, into the staging folder.
    let checkout = calls
        .iter()
        .find(|c| c[0] == "ostree" && c[1] == "checkout")
        .unwrap();
    for want in [
        "--user-mode",
        "--force-copy",
        "--subpath=/files",
        "ruyaos/previous/play.com.example.mini",
    ] {
        assert!(checkout.contains(&want.to_string()), "{want}: {checkout:?}");
    }
    assert!(
        std::path::Path::new(checkout.last().unwrap())
            .ends_with(std::path::Path::new("rollback-com.example.mini").join("files")),
        "{checkout:?}"
    );
    // The build folder the publish finished is the kept build's /app with the metadata generated now.
    let layout = runner.layout.lock().unwrap().clone();
    assert!(
        layout.contains(&"files/payload/build.txt".to_string()),
        "{layout:?}"
    );
    let (m, a) = {
        let tmp = tempfile::tempdir().unwrap();
        let copy = tmp.path().join("files");
        copy_dir(runner.kept.lock().unwrap().as_ref().unwrap(), &copy);
        reconcile::installed_app(&Dir::open_root(&copy).unwrap()).unwrap()
    };
    assert_eq!(m.build, 1);
    assert_eq!(*runner.metadata.lock().unwrap(), commit::metadata(&m, &a));
    // The order: checkout, finish, signed export, install of the stable ref from the local remote,
    // then the kept ref is deleted and the repo pruned.
    let names: Vec<String> = calls
        .iter()
        .filter(|c| !matches!(c[0].as_str(), "gpg"))
        .map(|c| format!("{} {}", c[0], c[1]))
        .collect();
    let at = |n: &str| {
        names
            .iter()
            .position(|x| x == n)
            .unwrap_or_else(|| panic!("{n}: {names:?}"))
    };
    assert!(at("ostree checkout") < at("flatpak build-finish"));
    assert!(at("flatpak build-export") < at("flatpak install"));
    let install = calls
        .iter()
        .rev()
        .find(|c| c[0] == "flatpak" && c[1] == "install")
        .unwrap();
    assert!(
        install.contains(&"app/play.com.example.mini/x86_64/stable".to_string()),
        "{install:?}"
    );
    let delete = calls
        .iter()
        .position(|c| c[0] == "ostree" && c.contains(&"--delete".to_string()))
        .unwrap();
    assert_eq!(
        calls[delete].last().unwrap(),
        "ruyaos/previous/play.com.example.mini"
    );
    let installed_at = calls
        .iter()
        .rposition(|c| c[0] == "flatpak" && c[1] == "install")
        .unwrap();
    assert!(
        delete > installed_at,
        "the ref is dropped after the install: {calls:?}"
    );
    assert_eq!(
        calls.last().unwrap(),
        &commit::prune(&commit::Paths::under(lib.path()))
    );
    // Never Flatpak's own rollback, never a reset of the override.
    for c in &calls {
        let line = c.join(" ");
        assert!(!line.contains("--commit="), "{line}");
        assert!(
            !line.contains("override") && !line.contains("--reset"),
            "{line}"
        );
    }
    let rec = installed.inner.lock().unwrap().get(ID).unwrap().unwrap();
    assert_eq!(
        (rec.build, rec.generation, rec.previous),
        (1, METADATA_GENERATION, None)
    );
}

#[test]
fn the_flatpak_commit_keeps_the_deployed_commit_and_prunes() {
    let runner = Arc::new(FakeRunner::default());
    let lib = tempfile::tempdir().unwrap();
    let fc = FlatpakCommit::new(lib.path(), Box::new(runner.clone())).keeping_owner();
    let paths = commit::Paths::under(lib.path());
    assert!(ruya_play::Commit::keep_previous(&fc, ID).unwrap());
    // The deployed commit (not the repo's stable head), that the repo holds it, the ref moved
    // onto it, then the prune.
    assert_eq!(
        runner.calls.lock().unwrap().clone(),
        vec![
            commit::deployed_commit(ID),
            commit::show_commit(&paths, DEPLOYED_COMMIT),
            commit::keep_ref(&paths, ID, DEPLOYED_COMMIT),
            commit::prune(&paths),
        ]
    );
    // A deployed commit the repo no longer holds (no ref named it, another update pruned it):
    // nothing is kept, the old kept ref goes, and the update is not blocked.
    let pruned = Arc::new(FakeRunner::default());
    *pruned.fail_with_arg.lock().unwrap() = Some("show".into());
    *pruned.fail_text.lock().unwrap() = Some("error: No such metadata object".into());
    let fc2 = FlatpakCommit::new(lib.path(), Box::new(pruned.clone())).keeping_owner();
    assert!(!ruya_play::Commit::keep_previous(&fc2, ID).unwrap());
    assert_eq!(
        pruned.calls.lock().unwrap().clone(),
        vec![
            commit::deployed_commit(ID),
            commit::show_commit(&paths, DEPLOYED_COMMIT),
            commit::delete_refs(&paths, &[commit::previous_ref(ID)]),
            commit::prune(&paths),
        ]
    );
    let keep = commit::keep_ref(&paths, ID, DEPLOYED_COMMIT);
    assert!(keep.contains(&"--force".to_string()));
    assert!(keep.contains(&"--create=ruyaos/previous/play.com.example.mini".to_string()));
    let prune = commit::prune(&paths);
    assert!(prune.contains(&"--refs-only".to_string()) && prune.contains(&"--depth=0".to_string()));
    // GetPrevious reads one file of the kept ref.
    assert_eq!(
        commit::cat_previous(&paths, ID, "play.json")[3..],
        [
            "ruyaos/previous/play.com.example.mini".to_string(),
            "/files/play.json".to_string()
        ]
    );
    // Remove drops both refs of the app (tests/remove.rs holds the uninstall's command lines).
    assert_eq!(
        commit::delete_refs(&paths, &[commit::app_ref(ID), commit::previous_ref(ID)])[3..],
        [
            "--delete".to_string(),
            "app/play.com.example.mini/x86_64/stable".to_string(),
            "ruyaos/previous/play.com.example.mini".to_string()
        ]
    );
    // A commit that is not a checksum keeps nothing.
    assert_eq!(commit::parse_checksum("  abc\n"), None);
    assert_eq!(
        commit::parse_checksum(&format!("{DEPLOYED_COMMIT}\n")).as_deref(),
        Some(DEPLOYED_COMMIT)
    );
    assert_eq!(
        commit::parse_checksum(&DEPLOYED_COMMIT.to_uppercase()),
        None
    );
}
