//! RUY-829 on the host: the Flatpak commit's command lines and build folder over a real staged
//! install, the start-up reconcile and its hold (`installed.unreconciled`), the mount gate before
//! a helper run (`source.unsafe_mount`), the Inspect record, and the shipped blocklist.

mod common;

use common::*;
use ruya_play::core::helper::{Ending, Session};
use ruya_play::core::reconcile::Deployed;
use ruya_play::dbus::{art_roles, inspect_record, job_record};
use ruya_play::service::commit::{self, FlatpakCommit};
use ruya_play::service::{Environment, GatedHelper};
use ruya_play::{CommitRequest, Exit, Helper, JobStatus, MethodStatus, Request};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use zbus::zvariant::Value;

fn copy_tree(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for e in std::fs::read_dir(from).unwrap() {
        let e = e.unwrap();
        let t = to.join(e.file_name());
        if e.file_type().unwrap().is_dir() {
            copy_tree(&e.path(), &t);
        } else {
            std::fs::copy(e.path(), t).unwrap();
        }
    }
}

type Seen = Arc<Mutex<Vec<Result<(), String>>>>;

/// A harness whose commit step also runs the Flatpak commit over a copy of the staged job.
fn with_flatpak(state: PathBuf, runner: Arc<FakeRunner>) -> (Harness, Seen) {
    let seen: Seen = Arc::default();
    let s2 = seen.clone();
    let mut setup = Setup::with(Pkg::signed(&game()));
    setup.commit_hook = Some(Box::new(move |req: &CommitRequest<'_>| {
        let job = req.tree.parent().unwrap();
        let copy = state.join("copy").join(req.job);
        copy_tree(job, &copy);
        let tree = copy.join("tree");
        let art = copy.join("art");
        let meta = copy.join("meta");
        let request = CommitRequest {
            job: req.job,
            tree: &tree,
            art: &art,
            meta: &meta,
            manifest: req.manifest,
            tier: req.tier,
            assessment: req.assessment,
            signatures: req.signatures,
        };
        let fc = FlatpakCommit::new(&state, Box::new(runner.clone())).keeping_owner();
        let mut phases = Vec::new();
        let r = ruya_play::Commit::commit(&fc, &request, &mut |p, f| phases.push((p, f)));
        s2.lock().unwrap().push(r.map_err(|e| format!("{e:?}")));
        assert_eq!(
            phases.first().map(|p| p.0),
            Some(ruya_play::Phase::Committing)
        );
        assert_eq!(phases.last(), Some(&(ruya_play::Phase::Installing, 1.0)));
    }));
    (setup.build(), seen)
}

#[test]
fn the_flatpak_commit_lays_out_signs_and_installs() {
    let state = tempfile::tempdir().unwrap();
    let runner = Arc::new(FakeRunner::default());
    let (mut h, seen) = with_flatpak(state.path().to_path_buf(), runner.clone());
    let r = h.install();
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    assert_eq!(seen.lock().unwrap().as_slice(), &[Ok(())]);
    let id = r.inspection.as_ref().unwrap().package.manifest.id.clone();
    let app = format!("play.{id}");

    // The build folder: metadata, the tree, the root files, the art, the launcher's mount folder
    // and the app's own desktop entry.
    let layout = runner.layout.lock().unwrap().clone();
    for want in [
        "metadata".to_string(),
        "files/play.json".to_string(),
        "files/play.files".to_string(),
        "files/play.sig".to_string(),
        "files/payload/game".to_string(),
        "files/launcher".to_string(),
        "files/share/ruyaos/play/art/icon-512.webp".to_string(),
        format!("files/share/applications/{app}.desktop"),
    ] {
        assert!(
            layout.iter().any(|l| l.starts_with(&want)),
            "missing {want}: {layout:?}"
        );
    }
    // Every mount folder the generated metadata declares is there (ADR-038: Flatpak needs each
    // one in `/app`), the runners' too.
    let metadata = runner.metadata.lock().unwrap().clone();
    let dirs: Vec<&str> = metadata
        .lines()
        .filter_map(|l| l.strip_prefix("directory="))
        .collect();
    assert!(dirs.contains(&commit::RUNNER_DIR), "{metadata}");
    for d in dirs {
        assert!(
            layout.contains(&format!("files/{d}")),
            "no mount folder {d}: {layout:?}"
        );
    }

    // The command lines, in order: the key on first use, the repo and the remote, then finish,
    // export (signed) and install (from the local remote, signature checked).
    let calls = runner.calls.lock().unwrap().clone();
    let names: Vec<String> = calls
        .iter()
        .map(|c| match c[0].as_str() {
            "gpg" => {
                let op = c
                    .iter()
                    .find(|a| {
                        ["--list-secret-keys", "--quick-gen-key", "--export"].contains(&a.as_str())
                    })
                    .unwrap();
                format!("gpg {op}")
            }
            other => format!("{other} {}", c[1]),
        })
        .collect();
    assert_eq!(
        names,
        vec![
            "gpg --list-secret-keys",
            "gpg --quick-gen-key",
            "gpg --list-secret-keys",
            "gpg --export",
            "ostree init",
            "flatpak remote-add",
            "flatpak remote-modify",
            "flatpak build-finish",
            "flatpak build-export",
            "flatpak install",
        ]
    );
    let export = &calls[8];
    assert!(export.contains(&format!("--gpg-sign={FPR}")), "{export:?}");
    let install = &calls[9];
    assert!(install.contains(&"--or-update".to_string()));
    assert!(install.contains(&"--system".to_string()));
    assert!(install.contains(&commit::REMOTE.to_string()));
    assert!(install.contains(&format!("app/{app}/x86_64/stable")));
    for c in &calls {
        assert!(!c.iter().any(|a| a.contains("no-gpg-verify")), "{c:?}");
    }
    let init = &calls[4];
    assert!(init.contains(&"--mode=bare-user-only".to_string()));

    // The device key is made once: the next commit reuses it without calling gpg.
    runner.calls.lock().unwrap().clear();
    let again: Vec<Vec<String>> = {
        let fc = FlatpakCommit::new(state.path(), Box::new(runner.clone())).keeping_owner();
        assert_eq!(fc.device_key().unwrap(), FPR);
        runner.calls.lock().unwrap().clone()
    };
    assert!(again.is_empty(), "the key was made again: {again:?}");
}

#[cfg(unix)]
#[test]
fn the_build_folder_gets_the_modes_of_play_files() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let f = dir.path().join("art.webp");
    std::fs::write(&f, b"x").unwrap();
    std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o600)).unwrap();
    let x = dir.path().join("game");
    std::fs::write(&x, b"x").unwrap();
    std::fs::set_permissions(&x, std::fs::Permissions::from_mode(0o700)).unwrap();
    let d = dir.path().join("sub");
    std::fs::create_dir(&d).unwrap();
    std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o700)).unwrap();
    commit::canonicalise(dir.path(), false).unwrap();
    let mode = |p: &Path| std::fs::symlink_metadata(p).unwrap().permissions().mode() & 0o7777;
    assert_eq!(mode(&f), 0o644);
    assert_eq!(mode(&x), 0o755);
    assert_eq!(mode(&d), 0o755);
}

#[test]
fn the_layout_still_refuses_a_reserved_top_level_name_in_the_tree() {
    // A package cannot get this far (`table.reserved_top_level`); the layout keeps its own check
    // as an invariant, so a tree that has one anyway is `commit.failed`, never merged.
    for name in ["launcher", "runners", "share"] {
        let state = tempfile::tempdir().unwrap();
        let seen: Seen = Arc::default();
        let s2 = seen.clone();
        let base = state.path().to_path_buf();
        let mut setup = Setup::with(Pkg::signed(&game()));
        setup.commit_hook = Some(Box::new(move |req: &CommitRequest<'_>| {
            let copy = base.join(req.job);
            copy_tree(req.tree.parent().unwrap(), &copy);
            let (tree, art, meta) = (copy.join("tree"), copy.join("art"), copy.join("meta"));
            std::fs::create_dir_all(tree.join(name)).unwrap();
            let request = CommitRequest {
                job: req.job,
                tree: &tree,
                art: &art,
                meta: &meta,
                manifest: req.manifest,
                tier: req.tier,
                assessment: req.assessment,
                signatures: req.signatures,
            };
            s2.lock().unwrap().push(
                commit::lay_out(&request)
                    .map(|_| ())
                    .map_err(|e| format!("{e:?}")),
            );
        }));
        let mut h = setup.build();
        let _ = h.install();
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        let err = seen[0].as_ref().unwrap_err();
        assert!(err.contains("top-level") && err.contains(name), "{err}");
    }
}

#[test]
fn an_app_that_cannot_be_reconciled_holds_its_id() {
    let mut h = Setup::with(Pkg::signed(&game())).build();
    let id = {
        let (status, report) = h.importer.inspect(&pkg_path("game.play"));
        assert_eq!(status, MethodStatus::Ok);
        report.unwrap().inspection.unwrap().package.manifest.id
    };
    // A signed app is committed for the id, but the key record is gone.
    let deployed: BTreeMap<String, Deployed> = [(
        id.to_ascii_lowercase(),
        Deployed {
            build: Some(1),
            signed: true,
        },
    )]
    .into_iter()
    .collect();
    let actions = h.importer.reconcile(&deployed).unwrap();
    assert!(!actions.is_empty());
    assert_eq!(h.importer.held(), vec![id.to_ascii_lowercase()]);
    // The build was recorded from the committed app.
    assert_eq!(h.importer.installed_build(&id).unwrap(), Some(1));
    let r = h.install();
    assert_eq!(codes(&r), vec!["installed.unreconciled".to_string()]);
    assert_eq!(r.status, JobStatus::Failed);
    assert!(h.commit.calls.lock().unwrap().is_empty());
    // Inspect says so too.
    let (_, report) = h.importer.inspect(&pkg_path("game.play"));
    assert_eq!(report.unwrap().verdict, JobStatus::Failed);
}

#[test]
fn a_recorded_build_without_an_app_is_forgotten() {
    let installed = ruya_play::core::installed::MemoryInstalled::new().with("com.example.gone", 9);
    let setup = Setup {
        installed,
        ..Setup::with(Pkg::signed(&game()))
    };
    let h = setup.build();
    h.importer.reconcile(&BTreeMap::new()).unwrap();
    assert_eq!(
        h.importer.installed_build("com.example.gone").unwrap(),
        None
    );
    assert!(h.importer.held().is_empty());
}

struct Mounts(&'static str);

impl Environment for Mounts {
    fn mountinfo(&self) -> String {
        self.0.to_string()
    }
    fn shell_uid(&self) -> Option<u32> {
        None
    }
}

struct CountingHelper(Arc<AtomicU32>);

impl Helper for CountingHelper {
    fn run(&self, _r: &Request, _c: &AtomicBool, _o: &mut dyn FnMut(&[u8]) -> bool) -> Exit {
        self.0.fetch_add(1, Ordering::SeqCst);
        Exit::Code(0)
    }
}

fn gated_run(mountinfo: &'static str, source: &str) -> (Ending, u32) {
    let runs = Arc::new(AtomicU32::new(0));
    let gated = GatedHelper::new(CountingHelper(runs.clone()), Arc::new(Mounts(mountinfo)));
    let request = Request {
        mode: ruya_play::core::helper::Mode::Install,
        job: "job-1".into(),
        source: source.into(),
        staging: "/var/lib/ruya-play/staging/job-1".into(),
        now: 0,
        developer_mode: false,
        blocklist: None,
        art: false,
        official: false,
        expect: BTreeMap::new(),
    };
    let mut session = Session::new();
    let cancel = AtomicBool::new(false);
    let exit = gated.run(&request, &cancel, &mut |b| session.feed(b, &mut |_| {}));
    (session.finish(&exit, false), runs.load(Ordering::SeqCst))
}

#[test]
fn a_drive_mounted_without_the_flags_is_never_read() {
    let unsafe_mount =
        "61 22 8:17 / /run/media/ruya-shell/USB rw,nosuid,relatime - vfat /dev/sdb1 rw\n";
    let (ending, runs) = gated_run(unsafe_mount, "/run/media/ruya-shell/USB/game.play.zip");
    assert_eq!(runs, 0, "the helper started");
    match ending {
        Ending::Refused(p) => {
            assert_eq!(p[0].code, "source.unsafe_mount");
            assert_eq!(ruya_play::status_of(&p), JobStatus::Failed);
        }
        other => panic!("{other:?}"),
    }
    let safe =
        "61 22 8:17 / /run/media/ruya-shell/USB rw,nosuid,nodev,noexec - vfat /dev/sdb1 rw\n";
    let (_, runs) = gated_run(safe, "/run/media/ruya-shell/USB/game.play.zip");
    assert_eq!(runs, 1);
    // A download is not removable media.
    let (_, runs) = gated_run(unsafe_mount, "/var/lib/ruya-play/incoming/dl.play.zip");
    assert_eq!(runs, 1);
}

#[test]
fn the_inspect_record_has_the_contracts_keys() {
    let h = Setup::with(Pkg::signed(&game())).build();
    let (status, report) = h.importer.inspect(&pkg_path("game.play"));
    assert_eq!(status, MethodStatus::Ok);
    let record = inspect_record(&report.unwrap());
    for key in [
        "id",
        "name",
        "version",
        "build",
        "size",
        "requirement",
        "verdict",
        "tier",
        "signer_key_id",
        "key_state",
        "permissions",
        "gate",
        "art",
        "screenshots",
        "revoked",
        "problems",
    ] {
        assert!(
            record.contains_key(key),
            "missing {key}: {:?}",
            record.keys()
        );
    }
    assert_eq!(&*record["verdict"], &Value::from("ok"));
    assert_eq!(&*record["key_state"], &Value::from("new"));
    assert_eq!(&*record["tier"], &Value::from("developer"));
    // The icon role is the vetted 512 px file.
    match &*record["art"] {
        Value::Dict(d) => {
            let icon: Option<String> = d.get(&"icon").unwrap();
            assert!(icon.unwrap().ends_with("icon-512.webp"));
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn art_files_map_to_roles() {
    let art = vec![
        ruya_play::core::art::VettedArt {
            slot: "icon".into(),
            lang: None,
            files: vec![
                PathBuf::from("/a/icon-512.webp"),
                PathBuf::from("/a/icon-128.webp"),
            ],
        },
        ruya_play::core::art::VettedArt {
            slot: "logo".into(),
            lang: Some("de".into()),
            files: vec![PathBuf::from("/a/logo-0/logo.webp")],
        },
        ruya_play::core::art::VettedArt {
            slot: "logo".into(),
            lang: Some("en".into()),
            files: vec![PathBuf::from("/a/logo-1/logo.webp")],
        },
        ruya_play::core::art::VettedArt {
            slot: "screenshot-1".into(),
            lang: None,
            files: vec![
                PathBuf::from("/a/screenshot-1-1080.webp"),
                PathBuf::from("/a/screenshot-1-thumb.webp"),
            ],
        },
        ruya_play::core::art::VettedArt {
            slot: "screenshot-0".into(),
            lang: None,
            files: vec![PathBuf::from("/a/screenshot-0-1080.webp")],
        },
    ];
    let (roles, shots) = art_roles(&art);
    let p = |s: &str| PathBuf::from(s).to_string_lossy().into_owned();
    assert_eq!(roles.get("icon"), Some(&p("/a/icon-512.webp")));
    assert_eq!(roles.get("logo"), Some(&p("/a/logo-1/logo.webp")));
    assert_eq!(roles.len(), 2);
    assert_eq!(
        shots,
        vec![
            p("/a/screenshot-0-1080.webp"),
            p("/a/screenshot-1-1080.webp")
        ]
    );
}

#[test]
fn the_job_record_has_the_contracts_keys() {
    let mut h = Setup::with(Pkg::signed(&game())).build();
    let r = h.install();
    assert_eq!(r.status, JobStatus::Ok);
    let jobs = h.importer.list_jobs();
    let rec = job_record(&jobs[0]);
    let keys: Vec<&str> = rec.keys().map(String::as_str).collect();
    assert_eq!(
        keys,
        vec!["app", "id", "kind", "name", "path", "percent", "phase", "reason", "state", "status"]
    );
    assert_eq!(&*rec["status"], &Value::from("ok"));
    assert_eq!(&*rec["percent"], &Value::from(100u32));
}

#[test]
fn the_image_ships_a_blocklist_that_parses() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../image/rootfs/usr/share/ruyaos/store-blocklist"
    );
    let bytes = std::fs::read(path).expect("the image ships store-blocklist");
    ruya_play_trust::revocation::Blocklist::parse(&bytes).expect("it parses");
}

#[test]
fn a_listing_that_fails_holds_every_id_until_a_reconcile_succeeds() {
    let mut h = Setup::with(Pkg::signed(&game())).build();
    let failed = h
        .importer
        .reconcile_listed(Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "/var/lib/flatpak/app",
        )))
        .unwrap_err();
    assert_eq!(failed.code, "installed.unreconciled");
    assert!(h.importer.held_all().is_some());
    // Every id is refused, this one has no app and no record at all.
    let r = h.install();
    assert_eq!(codes(&r), vec!["installed.unreconciled".to_string()]);
    assert_eq!(r.status, JobStatus::Failed);
    assert!(h.commit.calls.lock().unwrap().is_empty());
    let (_, report) = h.importer.inspect(&pkg_path("game.play"));
    assert_eq!(report.unwrap().verdict, JobStatus::Failed);
    // A reconcile that succeeds (the service's next start) lifts the hold.
    h.importer.reconcile_listed(Ok(BTreeMap::new())).unwrap();
    assert_eq!(h.importer.held_all(), None);
    assert_eq!(h.install().status, JobStatus::Ok);
}
