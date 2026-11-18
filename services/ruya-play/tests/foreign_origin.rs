//! RUY-863: `.play` is a real top-level domain, so a Flathub app can be named `play.<x>`. Every
//! reader of `app/play.*` (the start-up reconcile, Verify, the installed permissions of the
//! update diff) goes through `reconcile::ours`: only a deployment whose `deploy` file names the
//! console's own remote is ours; a missing file, another remote and a prefix of ours are not.

mod common;

use common::*;
use ruya_play::core::installed::MemoryInstalled;
use ruya_play::core::reconcile::{self, Action};
use ruya_play::MethodStatus;
use ruya_play_art::PLAY_REMOTE;
use std::path::Path;

const SPOOF: &str = "com.example.spoof";

/// A deployment of `play.<id>` with a valid-looking `play.json` and a `play.sig`, committed from
/// `origin` (`None`: no `deploy` file at all).
fn deploy_as(installation: &Path, id: &str, origin: Option<&[u8]>) {
    let active = installation
        .join("app")
        .join(format!("play.{id}"))
        .join("current")
        .join("active");
    let files = active.join("files");
    std::fs::create_dir_all(&files).unwrap();
    let json = format!(r#"{{"format":1,"id":"{id}","build":7,"permissions":{{"network":true}}}}"#);
    std::fs::write(files.join("play.json"), json).unwrap();
    std::fs::write(files.join("play.sig"), b"sig").unwrap();
    std::fs::write(files.join("play.files"), b"").unwrap();
    if let Some(o) = origin {
        std::fs::write(active.join("deploy"), o).unwrap();
    }
}

fn foreign_origins() -> Vec<(&'static str, Option<Vec<u8>>)> {
    let evil = format!("{PLAY_REMOTE}-evil\0abc\0").into_bytes();
    let unterminated = PLAY_REMOTE.as_bytes().to_vec();
    vec![
        ("flathub", Some(b"flathub\0abc\0".to_vec())),
        ("a prefix of ours", Some(evil)),
        ("a deploy file with no NUL", Some(unterminated)),
        ("an empty deploy file", Some(Vec::new())),
        ("no deploy file", None),
    ]
}

#[test]
fn only_our_remote_is_ours() {
    let h = Setup::default().build();
    let flatpak = &h.cfg.flatpak;
    deploy_as(flatpak, "com.example.own", Some(&own_deploy()));
    assert!(reconcile::ours(flatpak, "com.example.own"));
    assert!(reconcile::our_files(flatpak, "com.example.own").is_some());
    assert!(reconcile::deployed_play_json(flatpak, "com.example.own").is_some());
    for (what, origin) in foreign_origins() {
        deploy_as(flatpak, SPOOF, origin.as_deref());
        assert!(!reconcile::ours(flatpak, SPOOF), "{what}");
        assert!(reconcile::our_files(flatpak, SPOOF).is_none(), "{what}");
        assert!(
            reconcile::deployed_play_json(flatpak, SPOOF).is_none(),
            "{what}: the installed permissions lookup"
        );
    }
    assert!(!reconcile::ours(flatpak, "com.example.absent"));
    assert!(!reconcile::ours(flatpak, "a/b"));
}

fn own_deploy() -> Vec<u8> {
    format!("{PLAY_REMOTE}\0abc\0").into_bytes()
}

#[test]
fn reconcile_does_not_adopt_a_foreign_play_app() {
    for (what, origin) in foreign_origins() {
        let h = Setup::default().build();
        deploy_as(&h.cfg.flatpak, SPOOF, origin.as_deref());
        deploy_as(&h.cfg.flatpak, "com.example.own", Some(&own_deploy()));
        let deployed = reconcile::deployed_apps(&h.cfg.flatpak).unwrap();
        assert_eq!(
            deployed.keys().collect::<Vec<_>>(),
            ["com.example.own"],
            "{what}"
        );
        let actions = h.importer.reconcile(&deployed).unwrap();
        assert!(
            !actions
                .iter()
                .any(|a| matches!(a, Action::Hold { id, .. } if id == SPOOF)),
            "{what}: not held either"
        );
        assert_eq!(h.importer.installed_build(SPOOF).unwrap(), None, "{what}");
        // Ours with the same files is adopted: the foreign one differs by its origin only.
        assert_eq!(
            h.importer.installed_build("com.example.own").unwrap(),
            Some(7),
            "{what}"
        );
    }
}

#[test]
fn a_recorded_build_whose_deployment_turned_foreign_is_forgotten_not_uninstalled() {
    let setup = Setup {
        installed: MemoryInstalled::new().with(SPOOF, 7),
        ..Setup::default()
    };
    let h = setup.build();
    deploy_as(&h.cfg.flatpak, SPOOF, Some(b"flathub\0abc\0"));
    let deployed = reconcile::deployed_apps(&h.cfg.flatpak).unwrap();
    let actions = h.importer.reconcile(&deployed).unwrap();
    assert_eq!(actions, vec![Action::ForgetBuild { id: SPOOF.into() }]);
    assert_eq!(h.importer.installed_build(SPOOF).unwrap(), None);
    // Nothing of the foreign app was touched.
    assert!(h
        .cfg
        .flatpak
        .join("app")
        .join(format!("play.{SPOOF}/current/active/files/play.json"))
        .is_file());
}

#[test]
fn verify_of_a_foreign_play_app_is_unknown() {
    for (what, origin) in foreign_origins() {
        // Recorded (a stale record) or not, a foreign deployment is `unknown-app`.
        for recorded in [false, true] {
            let mut installed = MemoryInstalled::new();
            if recorded {
                installed = installed.with(SPOOF, 7);
            }
            let h = Setup {
                installed,
                ..Setup::default()
            }
            .build();
            deploy_as(&h.cfg.flatpak, SPOOF, origin.as_deref());
            assert_eq!(
                h.importer.queue_verify(SPOOF).0,
                MethodStatus::UnknownApp,
                "{what}, recorded {recorded}"
            );
            assert!(h.importer.list_jobs().is_empty(), "{what}: nothing queued");
        }
    }
}
