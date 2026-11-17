//! The install pipeline end to end with fakes: what is staged, verified, vetted and committed, the
//! checks that refuse before anything is written (trust, build, space, blocklist), the second
//! revocation check after the unpack, the art step, and the method statuses.

mod common;

use common::*;
use ruya_play::core::fakes::{FnFreeSpace, StaticBlocklists};
use ruya_play::core::installed::MemoryInstalled;
use ruya_play::core::staging::Kind;
use ruya_play::{CommitError, JobState, JobStatus, MethodStatus, Phase};
use ruya_play_format::{Entry, Problem, Source};
use ruya_play_trust::Tier;
use serde_json::json;
use std::io::{self, Cursor, Read};
use std::path::Path;
use std::sync::{Arc, Mutex};

fn game_size() -> u64 {
    game().files.iter().map(|(_, d)| d.len() as u64).sum()
}

#[test]
fn a_signed_package_is_staged_verified_vetted_and_committed() {
    let mut h = Setup::with(Pkg::signed(&game())).build();
    let r = h.install();
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    assert!(r.problems.is_empty(), "{:?}", r.problems);
    let calls = h.commit.calls();
    assert_eq!(calls.len(), 1);
    let call = &calls[0];
    assert_eq!(
        (call.id.as_str(), call.build, call.tier),
        ("com.example.mini", 1, Tier::Developer)
    );
    let tree: Vec<(&str, Kind)> = call
        .tree
        .iter()
        .map(|e| (e.path.as_str(), e.kind))
        .collect();
    assert_eq!(
        tree,
        vec![
            ("art", Kind::Dir),
            ("art/icon.png", Kind::File),
            ("payload", Kind::Dir),
            ("payload/data.bin", Kind::File),
            ("payload/game", Kind::File),
        ]
    );
    assert_eq!(call.meta, vec!["play.files", "play.json", "play.sig"]);
    assert_eq!(
        call.art,
        vec!["icon-128.webp", "icon-256.webp", "icon-512.webp"]
    );
    assert_eq!(r.art.len(), 1);
    assert_eq!(r.art[0].slot, "icon");
    // The staged bytes are the package's, and the staging copy is gone.
    let installed = h.target.join("play.com.example.mini");
    assert_eq!(
        std::fs::read(installed.join("payload").join("data.bin")).unwrap(),
        payload(1024 * 1024 + 17)
    );
    assert_eq!(h.staging(), Vec::<String>::new());
    h.assert_events_ordered();
    let phases: Vec<Phase> = h
        .events
        .iter()
        .filter_map(|e| match e {
            ruya_play::Event::Progress { phase, .. } => Some(*phase),
            _ => None,
        })
        .fold(Vec::new(), |mut v, p| {
            if v.last() != Some(&p) {
                v.push(p);
            }
            v
        });
    assert_eq!(
        phases,
        vec![
            Phase::Staging,
            Phase::Verifying,
            Phase::VettingArt,
            Phase::Committing,
            Phase::Installing
        ]
    );
    let jobs = h.importer.list_jobs();
    assert_eq!(jobs.len(), 1);
    let j = &jobs[0];
    assert_eq!(
        (j.state, j.status, j.percent),
        (JobState::Finished, Some(JobStatus::Ok), 100)
    );
    assert_eq!(j.app, "play.com.example.mini");
    assert_eq!((j.bytes_done, j.bytes_total), (game_size(), game_size()));
    assert_eq!((j.started, j.finished), (NOW, NOW));
    assert_eq!(j.error, "");
}

#[test]
fn a_zip_and_a_folder_install_the_same_way() {
    let fx = game();
    let folder = tempfile::tempdir().unwrap();
    fx.write_dir(folder.path());
    let key = Arc::new(dev_key());
    let setup = Setup {
        packages: vec![
            (
                pkg_path("a.play.zip"),
                Pkg::Signed(Box::new(Pkg::Zip(fx.zip())), key.clone(), None),
            ),
            (
                pkg_path("b.play"),
                Pkg::Signed(Box::new(Pkg::Folder(folder.path().into())), key, None),
            ),
        ],
        ..Setup::default()
    };
    let mut h = setup.build();
    assert_eq!(h.install_at(&pkg_path("a.play.zip")).status, JobStatus::Ok);
    // The same id and build again is not newer.
    let r = h.install_at(&pkg_path("b.play"));
    assert_eq!(r.status, JobStatus::InvalidPackage);
    assert_eq!(codes(&r), vec!["build.not_newer"]);
}

fn with_build(build: u64) -> Pkg {
    let mut fx = game();
    fx.manifest["build"] = json!(build);
    Pkg::signed(&fx)
}

#[test]
fn the_build_must_be_above_the_installed_build() {
    let setup = Setup {
        packages: vec![
            (pkg_path("b1"), with_build(1)),
            (pkg_path("b2"), with_build(2)),
        ],
        ..Setup::default()
    };
    let mut h = setup.build();
    assert_eq!(h.install_at(&pkg_path("b1")).status, JobStatus::Ok);
    for (path, ok) in [("b1", false), ("b2", true), ("b2", false), ("b1", false)] {
        let r = h.install_at(&pkg_path(path));
        if ok {
            assert_eq!(r.status, JobStatus::Ok, "{path}: {:?}", r.problems);
        } else {
            assert_eq!(r.status, JobStatus::InvalidPackage, "{path}");
            assert_eq!(codes(&r), vec!["build.not_newer"], "{path}");
            assert_eq!(r.problems[0].path, "/build");
        }
    }
    assert_eq!(h.commit.calls().len(), 2);

    // Refused before anything is written, also when the record came from an earlier run.
    let mut setup = Setup::with(with_build(3));
    setup.installed = MemoryInstalled::new().with("COM.EXAMPLE.MINI", 5);
    let mut h = setup.build();
    let r = h.install();
    assert_eq!(codes(&r), vec!["build.not_newer"]);
    h.assert_nothing_left();
    assert_eq!(h.free.calls.load(std::sync::atomic::Ordering::SeqCst), 0);
}

#[test]
fn a_package_larger_than_free_space_is_refused_before_anything_is_written() {
    let total = game_size();
    let needed = total + total.div_ceil(10);
    for (free, expect) in [
        (needed - 1, JobStatus::DiskFull),
        (needed, JobStatus::Ok),
        (0, JobStatus::DiskFull),
    ] {
        let seen: Arc<Mutex<Vec<Vec<String>>>> = Arc::default();
        let seen2 = Arc::clone(&seen);
        let mut setup = Setup::with(Pkg::signed(&game()));
        setup.free_space = Some(Box::new(FnFreeSpace(move |dir: &Path| {
            // The disk at the moment of the check: nothing staged yet.
            seen2.lock().unwrap().push(listing(dir));
            Ok::<u64, io::Error>(free)
        })));
        let mut h = setup.build();
        let r = h.install();
        assert_eq!(r.status, expect, "free {free}: {:?}", r.problems);
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen, vec![Vec::<String>::new()], "free {free}");
        if expect == JobStatus::DiskFull {
            assert_eq!(codes(&r), vec!["space.not_enough"]);
            h.assert_nothing_left();
            // No byte was copied: the job never got past the check.
            let j = &h.importer.list_jobs()[0];
            assert_eq!((j.bytes_done, j.bytes_total), (0, total));
        }
    }
}

#[test]
fn a_free_space_check_that_fails_is_a_staging_fault() {
    let mut setup = Setup::with(Pkg::signed(&game()));
    setup.free_space = Some(Box::new(FnFreeSpace(|_dir: &Path| {
        Err::<u64, io::Error>(io::Error::other("statvfs failed"))
    })));
    let mut h = setup.build();
    let r = h.install();
    assert_eq!(
        (r.status, codes(&r)),
        (JobStatus::Failed, vec!["staging.io".to_string()])
    );
    h.assert_nothing_left();
}

#[test]
fn the_blocklist_is_always_checked_and_an_unreadable_one_refuses_every_install() {
    // ListCheck::NotChecked would let all three through.
    let key_id = dev_key().public().key_id();
    for (list, status, code) in [
        (
            StaticBlocklists { image: None },
            JobStatus::Failed,
            "blocklist.unavailable",
        ),
        (
            StaticBlocklists {
                image: Some(b"serial 1\n[packages]\nkey nothex x\n".to_vec()),
            },
            JobStatus::Failed,
            "blocklist.unavailable",
        ),
        (
            StaticBlocklists::with(&[&format!("key {key_id} The key was stolen")]),
            JobStatus::Revoked,
            "revoked.key",
        ),
        (
            StaticBlocklists::with(&["id com.example.mini 1 Malware"]),
            JobStatus::Revoked,
            "revoked.id",
        ),
    ] {
        let mut setup = Setup::with(Pkg::signed(&game()));
        setup.blocklist = list.clone();
        let mut h = setup.build();
        let r = h.install();
        assert_eq!((r.status, codes(&r)), (status, vec![code.to_string()]));
        h.assert_nothing_left();
        let (st, report) = h.importer.inspect(&pkg_path("game.play"));
        assert_eq!(st, MethodStatus::Ok);
        let report = report.unwrap();
        assert_eq!(report.verdict, status, "{code}");
    }
}

/// The `runner` hash of 05 §7.3 for the component under `prefix`, from the fixture's own table.
fn runner_hash_of(fx: &Fx, prefix: &str) -> String {
    let mut lines: Vec<(String, String)> = Vec::new();
    for (p, d) in &fx.files {
        if let Some(rel) = p.strip_prefix(prefix) {
            let x = if fx.exec.contains(p) { "x" } else { "-" };
            lines.push((p.clone(), format!("f\0{rel}\0{}\0{x}\n", sha_hex(d))));
        }
    }
    for (p, to) in &fx.links {
        if let Some(rel) = p.strip_prefix(prefix) {
            lines.push((p.clone(), format!("l\0{rel}\0{to}\n")));
        }
    }
    for p in &fx.dirs {
        if let Some(rel) = p.strip_prefix(prefix) {
            lines.push((p.clone(), format!("d\0{rel}\n")));
        }
    }
    lines.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    let text: String = lines.into_iter().map(|(_, l)| l).collect();
    sha_hex(text.as_bytes())
}

#[test]
fn revocation_is_checked_again_after_the_unpack_with_the_bundled_runner_hash() {
    let fx = Fx::wine_full();
    let runner = runner_hash_of(&fx, "components/wine/");
    for (line, status) in [
        (
            format!("runner {runner} Wine 9.20 has a sandbox escape"),
            JobStatus::Revoked,
        ),
        (
            format!("runner {} Another Wine", "a".repeat(64)),
            JobStatus::Ok,
        ),
    ] {
        let unpacked = Arc::new(Mutex::new(false));
        let seen = Arc::clone(&unpacked);
        let mut setup = Setup::with(Pkg::signed(&fx));
        setup.art = Box::new(PassArt);
        setup.blocklist = StaticBlocklists::with(&[&line]);
        setup.hooks = Box::new(ruya_play::core::fakes::FnHooks(
            move |_job: &str, step: &ruya_play::Step<'_>| {
                if *step == ruya_play::Step::Unpacked {
                    *seen.lock().unwrap() = true;
                }
            },
        ));
        let mut h = setup.build();
        let r = h.install();
        assert_eq!(r.status, status, "{line}: {:?}", r.problems);
        // Inspect cannot know the runner: it passes, the unpack happens, then the check refuses.
        assert!(*unpacked.lock().unwrap(), "{line}");
        if status == JobStatus::Revoked {
            assert_eq!(codes(&r), vec!["revoked.runner"]);
            h.assert_nothing_left();
            assert_eq!(
                h.importer
                    .inspect(&pkg_path("game.play"))
                    .1
                    .unwrap()
                    .verdict,
                JobStatus::Ok
            );
        }
    }
}

/// Serves the first `play.json` it was asked for, and another one after that (a hostile drive).
struct Shifty {
    genuine: Box<dyn Source>,
    forged: Vec<u8>,
    reads: Mutex<u32>,
}

impl Source for Shifty {
    fn entries(&self) -> Result<Vec<Entry>, Vec<Problem>> {
        self.genuine.entries()
    }
    fn open(&self, path: &str) -> io::Result<Box<dyn Read + '_>> {
        if path == "play.json" {
            let mut n = self.reads.lock().unwrap();
            *n += 1;
            if *n > 1 {
                return Ok(Box::new(Cursor::new(self.forged.clone())));
            }
        }
        self.genuine.open(path)
    }
}

#[test]
fn the_source_is_read_once_so_the_verified_manifest_is_the_installed_one() {
    let fx = game();
    let mut forged = fx.clone();
    forged.manifest["name"] = json!({"en": "Forged"});
    forged.manifest["permissions"] = json!({"network": true, "removable_media": "write"});
    let forged_json = forged.manifest_bytes();
    let genuine = fx.clone();
    let shifty = Pkg::Custom(Arc::new(move || {
        Box::new(Shifty {
            genuine: signed(Box::new(genuine.mem()), &dev_key(), None),
            forged: forged_json.clone(),
            reads: Mutex::new(0),
        }) as Box<dyn Source>
    }));
    let mut h = Setup::with(shifty).build();
    let r = h.install();
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    let manifest = r.inspection.unwrap().package.manifest;
    assert_eq!(manifest.name["en"], "Mini");
    assert!(!manifest.permissions.network);
    assert_eq!(
        h.commit.calls()[0].meta,
        vec!["play.files", "play.json", "play.sig"]
    );
}

#[test]
fn trust_decides_the_status_and_the_key_is_recorded_only_after_the_commit() {
    // Unsigned: developer mode decides.
    let mut h = Setup::with(Pkg::Mem(game().mem())).build();
    let r = h.install();
    assert_eq!(
        (r.status, codes(&r)),
        (
            JobStatus::NeedsDeveloperMode,
            vec!["trust.needs_developer_mode".to_string()]
        )
    );
    h.assert_nothing_left();
    let mut setup = Setup::with(Pkg::Mem(game().mem()));
    setup.developer_mode = true;
    let mut h = setup.build();
    let r = h.install();
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    assert_eq!(h.commit.calls()[0].tier, Tier::Unverified);

    // A failed commit records no key: another developer may then take the id.
    let mut fx2 = game();
    fx2.manifest["build"] = json!(2);
    let setup = Setup {
        packages: vec![
            (pkg_path("dev"), Pkg::signed(&game())),
            (
                pkg_path("other"),
                Pkg::Signed(Box::new(Pkg::Mem(fx2.mem())), Arc::new(other_key()), None),
            ),
        ],
        ..Setup::default()
    };
    let mut h = setup.build();
    *h.commit.fail.lock().unwrap() = Some(CommitError::Failed("no".into()));
    let r = h.install_at(&pkg_path("dev"));
    assert_eq!(
        (r.status, codes(&r)),
        (JobStatus::Failed, vec!["commit.failed".to_string()])
    );
    assert_eq!(h.staging(), Vec::<String>::new());
    let r = h.install_at(&pkg_path("other"));
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);

    // After an install, the id belongs to its key.
    let setup = Setup {
        packages: vec![
            (pkg_path("dev"), Pkg::signed(&game())),
            (
                pkg_path("other"),
                Pkg::Signed(Box::new(Pkg::Mem(fx2.mem())), Arc::new(other_key()), None),
            ),
        ],
        ..Setup::default()
    };
    let mut h = setup.build();
    assert_eq!(h.install_at(&pkg_path("dev")).status, JobStatus::Ok);
    let r = h.install_at(&pkg_path("other"));
    assert_eq!(
        (r.status, codes(&r)),
        (
            JobStatus::DifferentDeveloper,
            vec!["trust.different_developer".to_string()]
        )
    );
    assert_eq!(h.commit.calls().len(), 1);
    assert_eq!(h.staging(), Vec::<String>::new());

    // A commit that runs out of space is disk-full.
    let mut h = Setup::with(Pkg::signed(&game())).build();
    *h.commit.fail.lock().unwrap() = Some(CommitError::NoSpace("full".into()));
    let r = h.install();
    assert_eq!(
        (r.status, codes(&r)),
        (JobStatus::DiskFull, vec!["space.not_enough".to_string()])
    );
}

#[test]
fn a_changed_package_is_a_bad_signature_and_a_newer_format_is_unsupported() {
    let fx = game();
    let genuine = signed(Box::new(fx.mem()), &dev_key(), None);
    let mut sig = Vec::new();
    genuine
        .open("play.sig")
        .unwrap()
        .read_to_end(&mut sig)
        .unwrap();
    let mut changed = fx.clone();
    changed.manifest["name"] = json!({"en": "Changed"});
    let mut m = changed.mem();
    m.add_file("play.sig", sig);
    let mut h = Setup::with(Pkg::Mem(m)).build();
    let r = h.install();
    assert_eq!(
        (r.status, codes(&r)),
        (
            JobStatus::BadSignature,
            vec!["sig.play_json_changed".to_string()]
        )
    );
    h.assert_nothing_left();

    let mut newer = game();
    newer.manifest["format"] = json!(2);
    let mut h = Setup::with(Pkg::signed(&newer)).build();
    let r = h.install();
    assert_eq!(
        (r.status, codes(&r)),
        (JobStatus::Unsupported, vec!["format.too_new".to_string()])
    );
    h.assert_nothing_left();

    let mut ceiling = game();
    ceiling.manifest["permissions"] = json!({"devel": true});
    let mut setup = Setup::with(Pkg::Mem(ceiling.mem()));
    setup.developer_mode = true;
    let mut h = setup.build();
    let r = h.install();
    assert_eq!(
        (r.status, codes(&r)),
        (
            JobStatus::InvalidPackage,
            vec!["ceiling.refused".to_string()]
        )
    );
    h.assert_nothing_left();
}

#[test]
fn a_broken_hero_refuses_the_package_and_a_broken_cover_only_loses_its_art() {
    let mut fx = game();
    fx.manifest["art"]["cover"] = json!("art/cover.png");
    fx.file("art/cover.png", b"this is not an image");
    let mut h = Setup::with(Pkg::signed(&fx)).build();
    let r = h.install();
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    assert_eq!(r.problems.len(), 1, "{:?}", r.problems);
    assert_eq!(r.problems[0].path, "art/cover.png");
    assert!(r.problems[0].code.starts_with("art."), "{:?}", r.problems);
    assert_eq!(
        h.commit.calls()[0].art,
        vec!["icon-128.webp", "icon-256.webp", "icon-512.webp"]
    );

    let mut fx = game();
    fx.manifest["art"]["hero"] = json!("art/hero.png");
    fx.file("art/hero.png", b"this is not an image");
    let mut h = Setup::with(Pkg::signed(&fx)).build();
    let r = h.install();
    assert_eq!(r.status, JobStatus::InvalidPackage, "{:?}", r.problems);
    assert_eq!(r.problems[0].path, "art/hero.png");
    assert!(r.problems[0].code.starts_with("art."), "{:?}", r.problems);
    h.assert_nothing_left();
    assert_eq!(h.importer.list_jobs()[0].error, r.problems[0].code);
}

#[test]
fn inspect_reads_only_data() {
    let mut setup = Setup::with(Pkg::signed(&game()));
    setup.installed = MemoryInstalled::new().with("com.example.mini", 1);
    let h = setup.build();
    let (st, report) = h.importer.inspect(&pkg_path("game.play"));
    assert_eq!(st, MethodStatus::Ok);
    let report = report.unwrap();
    assert_eq!(report.verdict, JobStatus::InvalidPackage);
    assert_eq!(report.problems[0].code, "build.not_newer");
    assert_eq!(report.installed_build, Some(1));
    assert_eq!(
        report.inspection.unwrap().package.manifest.id,
        "com.example.mini"
    );
    assert_eq!(h.staging(), Vec::<String>::new());
    assert!(!h.cfg.jobs_file().exists(), "inspect wrote the job table");
    assert_eq!(h.free.calls.load(std::sync::atomic::Ordering::SeqCst), 0);
    assert!(h.commit.calls().is_empty());

    let h = Setup::with(Pkg::signed(&game())).build();
    let report = h.importer.inspect(&pkg_path("game.play")).1.unwrap();
    assert_eq!(
        (report.verdict, report.installed_build),
        (JobStatus::Ok, None)
    );
    assert_eq!(
        h.importer.inspect(&pkg_path("gone")).0,
        MethodStatus::UnknownSource
    );
    assert_eq!(
        h.importer.inspect(Path::new("relative/game.play")).0,
        MethodStatus::Invalid
    );
    let report = {
        let h = Setup::with(Pkg::Zip(b"not a zip".to_vec())).build();
        h.importer.inspect(&pkg_path("game.play")).1.unwrap()
    };
    assert_eq!(report.verdict, JobStatus::InvalidPackage);
    assert_eq!(report.problems[0].code, "zip.not_a_zip");
}

#[test]
fn install_statuses_and_one_job_at_a_time() {
    let h = Setup::with(Pkg::signed(&game())).build();
    let p = pkg_path("game.play");
    assert_eq!(
        h.importer.queue_install(&p, false),
        (MethodStatus::Forbidden, String::new())
    );
    assert_eq!(
        h.importer.queue_install(Path::new("game.play"), true),
        (MethodStatus::Invalid, String::new())
    );
    assert_eq!(
        h.importer.queue_install(&p, true),
        (MethodStatus::Ok, "job-1".to_string())
    );
    assert_eq!(
        h.importer.queue_install(&p, true),
        (MethodStatus::Busy, String::new())
    );
    let gone = pkg_path("gone.play");
    assert_eq!(
        h.importer.queue_install(&gone, true),
        (MethodStatus::Ok, "job-2".to_string())
    );
    // One run, one job: the second waits.
    let first = h.importer.run_next(&mut |_| {}).unwrap();
    assert_eq!(first.job, "job-1");
    let jobs = h.importer.list_jobs();
    assert_eq!(
        (jobs[0].state, jobs[1].state),
        (JobState::Finished, JobState::Queued)
    );
    let second = h.importer.run_next(&mut |_| {}).unwrap();
    assert_eq!(
        (second.status, codes(&second)),
        (JobStatus::Failed, vec!["source.missing".to_string()])
    );
    assert!(h.importer.run_next(&mut |_| {}).is_none());
    // The path is free again once its job finished.
    assert_eq!(h.importer.queue_install(&p, true).0, MethodStatus::Ok);
}
