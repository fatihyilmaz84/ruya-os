//! RUY-834 acceptance: `Play1.Verify` re-hashes an installed app's deployed files against the
//! `play.files` the commit stored in them (05 §7.3 "Re-verification"): ok, a changed byte, a
//! missing file, an extra file, a link replaced by a file, the method statuses, progress, cancel,
//! and that nothing is written or followed out of the deployment.

mod common;

use common::*;
use ruya_play::core::installed::MemoryInstalled;
use ruya_play::{Event, JobKind, JobResult, JobState, JobStatus, MethodStatus, Phase};
use std::path::{Path, PathBuf};

const ID: &str = "com.example.mini";

fn files_dir(h: &Harness, id: &str) -> PathBuf {
    h.cfg
        .flatpak
        .join("app")
        .join(format!("play.{id}"))
        .join("current")
        .join("active")
        .join("files")
}

#[cfg(unix)]
fn mode(path: &Path, bits: u32) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(bits)).unwrap();
}

#[cfg(not(unix))]
fn mode(_path: &Path, _bits: u32) {}

/// The deployment of `fx` as the commit lays it out: the tree with the modes of `play.files`, the
/// root files, and what the console adds (`launcher/`, the desktop entry, the art).
fn deploy(h: &Harness, id: &str, fx: &Fx) -> PathBuf {
    let files = files_dir(h, id);
    std::fs::create_dir_all(&files).unwrap();
    write_deploy(&h.cfg.flatpak, id, ruya_play_art::PLAY_REMOTE);
    for (p, d) in &fx.files {
        let full = files.join(p);
        std::fs::create_dir_all(full.parent().unwrap()).unwrap();
        std::fs::write(&full, d).unwrap();
        mode(&full, if fx.exec.contains(p) { 0o755 } else { 0o644 });
    }
    for d in &fx.dirs {
        std::fs::create_dir_all(files.join(d)).unwrap();
    }
    std::fs::write(files.join("play.files"), fx.table()).unwrap();
    std::fs::write(files.join("play.json"), fx.manifest_bytes()).unwrap();
    std::fs::write(files.join(".ref"), b"").unwrap();
    std::fs::create_dir_all(files.join("launcher")).unwrap();
    std::fs::create_dir_all(files.join("share/applications")).unwrap();
    std::fs::write(
        files.join(format!("share/applications/play.{id}.desktop")),
        b"[Desktop Entry]\n",
    )
    .unwrap();
    std::fs::create_dir_all(files.join("share/ruyaos/play/art")).unwrap();
    std::fs::write(files.join("share/ruyaos/play/art/icon.png"), b"art").unwrap();
    // Every folder is 0755 (Unix), as the commit's canonical modes make them.
    for e in listing(&files) {
        let p = files.join(&e);
        if !e.contains(" -> ") && p.is_dir() {
            mode(&p, 0o755);
        }
    }
    mode(&files, 0o755);
    files
}

fn harness() -> (Harness, Fx) {
    let h = Setup {
        installed: MemoryInstalled::new().with(ID, 1),
        ..Setup::default()
    }
    .build();
    (h, game())
}

/// Queue a verify of `play.<id>` and run it.
fn verify(h: &mut Harness, id: &str) -> JobResult {
    let (status, job) = h.importer.queue_verify(id);
    assert_eq!(status, MethodStatus::Ok);
    let mut events = Vec::new();
    let r = h.importer.run_next(&mut |e| events.push(e)).expect("ran");
    assert_eq!(r.job, job);
    h.events = events;
    r
}

#[test]
fn an_intact_deployment_verifies_ok_with_progress() {
    let (mut h, fx) = harness();
    deploy(&h, ID, &fx);
    let r = verify(&mut h, ID);
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    assert!(r.problems.is_empty());
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
    assert!(phases.iter().all(|p| *p == Phase::Verifying), "{phases:?}");
    match h.events.iter().rev().nth(1) {
        Some(Event::Progress {
            percent,
            bytes_done,
            bytes_total,
            ..
        }) => {
            assert_eq!(*percent, 100);
            assert_eq!(bytes_done, bytes_total);
            assert!(*bytes_total > 1024 * 1024);
        }
        other => panic!("last progress: {other:?}"),
    }
    let record = h.importer.list_jobs().pop().unwrap();
    assert_eq!(record.kind, JobKind::Verify);
    assert_eq!(record.state, JobState::Finished);
    assert_eq!(record.app, format!("play.{ID}"));
}

#[test]
fn one_changed_byte_is_a_hash_mismatch_naming_the_file() {
    let (mut h, fx) = harness();
    let files = deploy(&h, ID, &fx);
    let target = files.join("payload/data.bin");
    let mut bytes = std::fs::read(&target).unwrap();
    bytes[500_000] ^= 1;
    std::fs::write(&target, bytes).unwrap();
    let r = verify(&mut h, ID);
    assert_eq!(r.status, JobStatus::InvalidPackage);
    assert_eq!(codes(&r), ["package.hash_mismatch"]);
    assert_eq!(r.problems[0].path, "payload/data.bin");
    assert_eq!(
        h.importer.list_jobs().pop().unwrap().error,
        "package.hash_mismatch"
    );
}

#[test]
fn a_missing_file_is_invalid_package() {
    let (mut h, fx) = harness();
    let files = deploy(&h, ID, &fx);
    std::fs::remove_file(files.join("payload/game")).unwrap();
    let r = verify(&mut h, ID);
    assert_eq!(r.status, JobStatus::InvalidPackage);
    assert_eq!(codes(&r), ["staging.changed"]);
    assert_eq!(r.problems[0].path, "payload/game");
}

#[test]
fn an_extra_file_is_invalid_package() {
    let (mut h, fx) = harness();
    let files = deploy(&h, ID, &fx);
    std::fs::write(files.join("payload/extra.bin"), b"x").unwrap();
    let r = verify(&mut h, ID);
    assert_eq!(r.status, JobStatus::InvalidPackage);
    assert_eq!(codes(&r), ["staging.changed"]);
    assert_eq!(r.problems[0].path, "payload/extra.bin");
}

#[test]
fn a_missing_play_files_is_invalid_package() {
    let (mut h, fx) = harness();
    let files = deploy(&h, ID, &fx);
    std::fs::remove_file(files.join("play.files")).unwrap();
    let r = verify(&mut h, ID);
    assert_eq!(r.status, JobStatus::InvalidPackage);
    assert_eq!(r.problems[0].path, "play.files");
}

#[test]
fn the_methods_statuses() {
    let (h, fx) = harness();
    // Recorded but not deployed (uninstalled with the Store): unknown.
    assert_eq!(h.importer.queue_verify(ID).0, MethodStatus::UnknownApp);
    deploy(&h, ID, &fx);
    // Not installed at all.
    assert_eq!(
        h.importer.queue_verify("com.example.other").0,
        MethodStatus::UnknownApp
    );
    for bad in ["", "a/b", "a\\b", "a\nb"] {
        assert_eq!(
            h.importer.queue_verify(bad).0,
            MethodStatus::Invalid,
            "{bad:?}"
        );
    }
    let (status, first) = h.importer.queue_verify(ID);
    assert_eq!(status, MethodStatus::Ok);
    assert!(first.starts_with("job-"));
    // Queued: the same app is busy, and nothing was queued for it.
    assert_eq!(
        h.importer.queue_verify(ID),
        (MethodStatus::Busy, String::new())
    );
    let r = h.importer.run_next(&mut |_| {}).expect("ran");
    assert_eq!(r.status, JobStatus::Ok);
    // Finished: a new verify is fine.
    assert_eq!(h.importer.queue_verify(ID).0, MethodStatus::Ok);
}

#[test]
fn an_app_that_turns_foreign_between_queue_and_run_is_refused() {
    let (mut h, fx) = harness();
    deploy(&h, ID, &fx);
    let (status, job) = h.importer.queue_verify(ID);
    assert_eq!(status, MethodStatus::Ok);
    // Another remote now owns the deployment (a Flathub app named `play.<id>`).
    write_deploy(&h.cfg.flatpak, ID, "flathub");
    let r = h.importer.run_next(&mut |_| {}).expect("ran");
    assert_eq!(r.job, job);
    assert_eq!(r.status, JobStatus::Failed);
    assert_eq!(codes(&r), ["staging.io"]);
    // And a verify asked now is not even queued.
    assert_eq!(h.importer.queue_verify(ID).0, MethodStatus::UnknownApp);
}

#[test]
fn cancelling_a_queued_verify_finishes_cancelled() {
    let (h, fx) = harness();
    let files = deploy(&h, ID, &fx);
    let before = listing(&files);
    let (_, job) = h.importer.queue_verify(ID);
    assert_eq!(h.importer.cancel(&job), MethodStatus::Ok);
    let r = h.importer.run_next(&mut |_| {}).expect("ran");
    assert_eq!(r.status, JobStatus::Cancelled);
    assert_eq!(listing(&files), before);
}

#[test]
fn cancelling_a_running_verify_stops_it_and_changes_nothing() {
    let (h, fx) = harness();
    let files = deploy(&h, ID, &fx);
    let before = listing(&files);
    let data = std::fs::read(files.join("payload/data.bin")).unwrap();
    let (_, job) = h.importer.queue_verify(ID);
    let canceller = h.importer.canceller();
    let mut events = Vec::new();
    let mut answer = None;
    let r = h
        .importer
        .run_next(&mut |e| {
            // The first progress past the start (a file hashed) cancels the job.
            if matches!(e, Event::Progress { percent, .. } if percent > 0) && answer.is_none() {
                answer = Some(canceller.cancel(&job));
            }
            events.push(e);
        })
        .expect("ran");
    assert_eq!(answer, Some(MethodStatus::Ok));
    assert_eq!(r.status, JobStatus::Cancelled);
    assert!(matches!(
        events.last(),
        Some(Event::Finished {
            status: JobStatus::Cancelled,
            ..
        })
    ));
    assert_eq!(listing(&files), before);
    assert_eq!(std::fs::read(files.join("payload/data.bin")).unwrap(), data);
}

#[cfg(unix)]
#[test]
fn a_link_is_compared_as_a_link_and_never_followed() {
    let (mut h, mut fx) = harness();
    fx.links.push(("payload/latest".into(), "game".into()));
    let files = deploy(&h, ID, &fx);
    std::os::unix::fs::symlink("game", files.join("payload/latest")).unwrap();
    let r = verify(&mut h, ID);
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);

    // The listed link replaced by a file with the same content.
    std::fs::remove_file(files.join("payload/latest")).unwrap();
    std::fs::write(files.join("payload/latest"), b"#!/bin/sh\necho hi\n").unwrap();
    let r = verify(&mut h, ID);
    assert_eq!(r.status, JobStatus::InvalidPackage);
    assert_eq!(codes(&r), ["staging.changed"]);
    assert_eq!(r.problems[0].path, "payload/latest");

    // The folder `payload` replaced by a link to a folder outside that holds the same files: it
    // is reported, not entered.
    let outside = h.outside.join("etc");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("game"), b"#!/bin/sh\necho hi\n").unwrap();
    std::fs::write(outside.join("data.bin"), payload(1024 * 1024 + 17)).unwrap();
    std::fs::remove_dir_all(files.join("payload")).unwrap();
    std::os::unix::fs::symlink(&outside, files.join("payload")).unwrap();
    let r = verify(&mut h, ID);
    assert_eq!(r.status, JobStatus::InvalidPackage);
    assert_eq!(codes(&r), ["staging.changed"]);
    assert!(
        std::fs::symlink_metadata(files.join("payload"))
            .unwrap()
            .file_type()
            .is_symlink(),
        "the link was left as it was"
    );
}

#[test]
fn verify_never_writes_to_the_deployment() {
    let (mut h, fx) = harness();
    let files = deploy(&h, ID, &fx);
    let snapshot = |dir: &Path| -> Vec<(String, Vec<u8>)> {
        listing(dir)
            .into_iter()
            .map(|p| {
                let full = dir.join(&p);
                let data = if full.is_file() {
                    std::fs::read(&full).unwrap()
                } else {
                    Vec::new()
                };
                (p, data)
            })
            .collect()
    };
    let before = snapshot(&files);
    assert_eq!(verify(&mut h, ID).status, JobStatus::Ok);
    assert_eq!(snapshot(&files), before);
    std::fs::write(files.join("payload/extra.bin"), b"x").unwrap();
    let damaged = snapshot(&files);
    assert_eq!(verify(&mut h, ID).status, JobStatus::InvalidPackage);
    assert_eq!(snapshot(&files), damaged);
    assert_eq!(h.staging(), Vec::<String>::new());
}

#[test]
fn flatpaks_empty_top_level_ref_is_left_out_but_others_are_compared() {
    let (mut h, fx) = harness();
    let files = deploy(&h, ID, &fx);
    assert!(files.join(".ref").is_file());
    assert_eq!(verify(&mut h, ID).status, JobStatus::Ok);

    // Not empty: an entry play.files does not list.
    std::fs::write(files.join(".ref"), b"x").unwrap();
    let r = verify(&mut h, ID);
    assert_eq!(r.status, JobStatus::InvalidPackage);
    assert_eq!(r.problems[0].path, ".ref");

    // Nested: also compared.
    std::fs::write(files.join(".ref"), b"").unwrap();
    std::fs::write(files.join("payload/.ref"), b"").unwrap();
    let r = verify(&mut h, ID);
    assert_eq!(r.status, JobStatus::InvalidPackage);
    assert_eq!(r.problems[0].path, "payload/.ref");
}

#[test]
fn a_running_install_of_the_same_app_makes_verify_busy() {
    let mut setup = Setup::with(Pkg::signed(&game()));
    setup.installed = MemoryInstalled::new().with(ID, 0);
    let h = setup.build();
    deploy(&h, ID, &game());
    let (status, _) = h.importer.queue_install(&pkg_path("game.play"), true);
    assert_eq!(status, MethodStatus::Ok);
    // The first progress past the start is the staging of the files: the job's app is known.
    let mut answer = None;
    let mut extra_job = None;
    h.importer
        .run_next(&mut |e| {
            if matches!(e, Event::Progress { percent, .. } if percent > 0) && answer.is_none() {
                let a = h.importer.queue_verify(ID);
                if a.0 == MethodStatus::Ok {
                    extra_job = Some(a.1.clone());
                }
                answer = Some(a);
            }
        })
        .expect("ran");
    assert_eq!(answer, Some((MethodStatus::Busy, String::new())));
    assert_eq!(extra_job, None);
}
