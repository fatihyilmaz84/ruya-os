//! RUY-900 (ADR-038): the metadata generation. A commit stamps `METADATA_GENERATION` into
//! `installed.json`; the start-up reconcile plans a re-commit for each app of ours recorded with an
//! older one, and `Importer::recommit` sends a copy of the deployed `/app` through the commit again
//! (`Commit::recommit`, the same layout of the generated parts, signing and install), once.

mod common;

use common::*;
use ruya_play::core::fakes::RecommitCall;
use ruya_play::core::reconcile::{self, Action};
use ruya_play::core::staging::{self, Dir};
use ruya_play::service::commit::{
    extension_points, metadata, FlatpakCommit, COMPAT_I386_DIR, METADATA_GENERATION, RUNNER_DIR,
};
use ruya_play::{Commit, CommitError, InstalledBuilds, JobStatus, RecommitRequest};

const ID: &str = "com.example.mini";

/// A harness with stores the test can look into, `play.<ID>` deployed from `fx` and recorded at
/// build 1 with `generation`.
fn deployed(fx: &Fx, generation: u32) -> (Harness, SharedInstalled) {
    let installed = SharedInstalled::default();
    {
        let mut i = installed.inner.lock().unwrap();
        i.record(ID, 1).unwrap();
        i.stamp(ID, generation).unwrap();
    }
    let h = Setup {
        stores: Some((SharedTrust::default(), installed.clone())),
        ..Setup::default()
    }
    .build();
    deploy(&h, ID, fx);
    (h, installed)
}

fn generation(installed: &SharedInstalled) -> u32 {
    installed
        .inner
        .lock()
        .unwrap()
        .get(ID)
        .unwrap()
        .unwrap()
        .generation
}

fn recommits_planned(h: &Harness) -> Vec<String> {
    let deployed = reconcile::deployed_apps(&h.cfg.flatpak).unwrap();
    h.importer
        .reconcile_listed(Ok(deployed))
        .unwrap()
        .into_iter()
        .filter_map(|a| match a {
            Action::Recommit { id } => Some(id),
            _ => None,
        })
        .collect()
}

#[test]
fn an_app_of_an_older_generation_is_committed_again_once() {
    let (h, installed) = deployed(&Fx::minimal(), 0);
    let before = listing(&h.cfg.flatpak);
    assert_eq!(recommits_planned(&h), vec![ID.to_string()]);
    assert_eq!(h.importer.recommit(ID), Ok(true));
    let calls: Vec<RecommitCall> = h.commit.recommits();
    assert_eq!(calls.len(), 1);
    let call = &calls[0];
    assert_eq!((call.id.as_str(), call.build), (ID, 1));
    // The copy holds the whole deployed /app (root files, the console's own files) but not
    // Flatpak's `.ref`.
    for want in [
        "play.json",
        "play.files",
        "payload/game",
        "launcher",
        "share/ruyaos/play/trust.json",
    ] {
        assert!(
            call.files.iter().any(|f| f == want),
            "{want}: {:?}",
            call.files
        );
    }
    assert!(!call.files.iter().any(|f| f == ".ref"), "{:?}", call.files);
    assert_eq!(generation(&installed), METADATA_GENERATION);
    // The deployment was only read, and the staging copy is gone.
    assert_eq!(listing(&h.cfg.flatpak), before);
    assert!(h.staging().is_empty(), "{:?}", h.staging());
    // Idempotent: the next start plans nothing, and a second call does nothing.
    assert!(recommits_planned(&h).is_empty());
    assert_eq!(h.importer.recommit(ID), Ok(false));
    assert_eq!(h.commit.recommits().len(), 1);
}

#[test]
fn a_current_or_held_app_is_left_alone() {
    let (h, _) = deployed(&Fx::minimal(), METADATA_GENERATION);
    assert!(recommits_planned(&h).is_empty());
    assert_eq!(h.importer.recommit(ID), Ok(false));
    // Signed without a key record: held, never committed again.
    let (h, installed) = deployed(&Fx::minimal(), 0);
    std::fs::write(files_dir(&h, ID).join("play.sig"), b"sig").unwrap();
    assert!(recommits_planned(&h).is_empty());
    assert_eq!(h.importer.held(), vec![ID.to_string()]);
    assert_eq!(h.importer.recommit(ID), Ok(false));
    assert!(h.commit.recommits().is_empty());
    assert_eq!(generation(&installed), 0);
}

#[test]
fn a_failed_recommit_keeps_the_generation_and_is_tried_again() {
    let (h, installed) = deployed(&Fx::minimal(), 0);
    *h.commit.fail.lock().unwrap() = Some(CommitError::Failed("export failed".into()));
    let err = h.importer.recommit(ID).unwrap_err();
    assert_eq!(err.code, "commit.failed");
    assert_eq!(generation(&installed), 0);
    assert!(h.staging().is_empty(), "{:?}", h.staging());
    assert_eq!(recommits_planned(&h), vec![ID.to_string()]);
    assert_eq!(h.importer.recommit(ID), Ok(true));
    assert_eq!(generation(&installed), METADATA_GENERATION);
}

#[test]
fn an_app_that_cannot_be_read_back_is_not_committed() {
    let (h, installed) = deployed(&Fx::minimal(), 0);
    std::fs::remove_file(files_dir(&h, ID).join("share/ruyaos/play/trust.json")).unwrap();
    let err = h.importer.recommit(ID).unwrap_err();
    assert_eq!(err.code, "installed.unreconciled");
    assert!(err.message.contains("trust record"), "{}", err.message);
    assert!(h.commit.recommits().is_empty());
    assert_eq!(generation(&installed), 0);
}

#[test]
fn an_install_stamps_the_current_generation() {
    let installed = SharedInstalled::default();
    let mut setup = Setup::with(Pkg::signed(&game()));
    setup.stores = Some((SharedTrust::default(), installed.clone()));
    let mut h = setup.build();
    let r = h.install();
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    let id = r.inspection.unwrap().package.manifest.id;
    let got = installed.inner.lock().unwrap().get(&id).unwrap().unwrap();
    assert_eq!(got.generation, METADATA_GENERATION);
}

/// A copy of the deployed `/app` of `play.<ID>` in `<state>/recommit/files`, as the importer
/// makes it.
fn staged_copy(h: &Harness, state: &std::path::Path) -> std::path::PathBuf {
    let job = state.join("recommit");
    std::fs::create_dir_all(job.join("files")).unwrap();
    let from = reconcile::our_files(&h.cfg.flatpak, ID).unwrap();
    let to = Dir::open_root(&job.join("files")).unwrap();
    staging::copy_tree(&from, &to, &|_, _| false).unwrap();
    job.join("files")
}

#[test]
fn the_flatpak_recommit_regenerates_the_metadata_and_mount_folders_and_installs() {
    let mut fx = Fx::wine_full();
    fx.manifest["id"] = serde_json::json!(ID);
    let (h, _) = deployed(&fx, 0);
    // Generation 0 had only the launcher's mount folder.
    let files = files_dir(&h, ID);
    std::fs::remove_dir(files.join(RUNNER_DIR)).unwrap();
    std::fs::remove_dir_all(files.join("lib")).unwrap();
    let (manifest, assessment) =
        reconcile::installed_app(&reconcile::our_files(&h.cfg.flatpak, ID).unwrap()).unwrap();
    let state = tempfile::tempdir().unwrap();
    let copy = staged_copy(&h, state.path());
    let runner = std::sync::Arc::new(FakeRunner::default());
    let fc =
        FlatpakCommit::new(&state.path().join("lib"), Box::new(runner.clone())).keeping_owner();
    let request = RecommitRequest {
        files: &copy,
        manifest: &manifest,
        assessment: &assessment,
    };
    fc.recommit(&request).unwrap();
    assert_eq!(
        runner.metadata.lock().unwrap().as_str(),
        metadata(&manifest, &assessment)
    );
    let layout = runner.layout.lock().unwrap().clone();
    for p in extension_points("wine") {
        assert!(
            layout.contains(&format!("files/{}", p.directory)),
            "no {}: {layout:?}",
            p.directory
        );
    }
    for want in ["files/play.json", "files/share/ruyaos/play/trust.json"] {
        assert!(layout.iter().any(|l| l == want), "{want}: {layout:?}");
    }
    let calls: Vec<String> = runner
        .calls
        .lock()
        .unwrap()
        .iter()
        .filter(|c| c[0] == "flatpak")
        .map(|c| c[1].clone())
        .collect();
    assert_eq!(
        calls,
        [
            "remote-add",
            "remote-modify",
            "build-finish",
            "build-export",
            "install"
        ]
    );
}

#[test]
fn a_mount_folder_never_hides_the_apps_own_files() {
    let mut fx = Fx::wine_full();
    fx.manifest["id"] = serde_json::json!(ID);
    let (h, _) = deployed(&fx, 0);
    let (manifest, assessment) =
        reconcile::installed_app(&reconcile::our_files(&h.cfg.flatpak, ID).unwrap()).unwrap();
    for (what, plant) in [
        (RUNNER_DIR, "runners/notes.txt"),
        (COMPAT_I386_DIR, "lib/i386-linux-gnu/libfoo.so"),
    ] {
        let state = tempfile::tempdir().unwrap();
        let copy = staged_copy(&h, state.path());
        std::fs::write(copy.join(plant), b"the app's own").unwrap();
        let runner = std::sync::Arc::new(FakeRunner::default());
        let fc =
            FlatpakCommit::new(&state.path().join("lib"), Box::new(runner.clone())).keeping_owner();
        let request = RecommitRequest {
            files: &copy,
            manifest: &manifest,
            assessment: &assessment,
        };
        match fc.recommit(&request) {
            Err(CommitError::Failed(m)) => assert!(m.contains(what), "{m}"),
            other => panic!("{what}: {other:?}"),
        }
        assert!(!runner
            .calls
            .lock()
            .unwrap()
            .iter()
            .any(|c| c[1] == "install"));
    }
}
