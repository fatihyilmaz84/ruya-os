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
    self, extension_points, metadata, FlatpakCommit, COMPAT_I386_DIR, METADATA_GENERATION,
    RUNNER_DIR,
};
use ruya_play::{Commit, CommitError, InstalledBuilds, JobStatus, RecommitRequest, Recommitted};

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
    assert_eq!(h.importer.recommit(ID), Ok(Recommitted::Done));
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
    assert_eq!(h.importer.recommit(ID), Ok(Recommitted::NotNeeded));
    assert_eq!(h.commit.recommits().len(), 1);
}

#[test]
fn a_current_or_held_app_is_left_alone() {
    let (h, _) = deployed(&Fx::minimal(), METADATA_GENERATION);
    assert!(recommits_planned(&h).is_empty());
    assert_eq!(h.importer.recommit(ID), Ok(Recommitted::NotNeeded));
    // Signed without a key record: held, never committed again.
    let (h, installed) = deployed(&Fx::minimal(), 0);
    std::fs::write(files_dir(&h, ID).join("play.sig"), b"sig").unwrap();
    assert!(recommits_planned(&h).is_empty());
    assert_eq!(h.importer.held(), vec![ID.to_string()]);
    assert_eq!(h.importer.recommit(ID), Ok(Recommitted::NotNeeded));
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
    assert_eq!(h.importer.recommit(ID), Ok(Recommitted::Done));
    assert_eq!(generation(&installed), METADATA_GENERATION);
}

/// RUY-1004: a start-up re-commit that cannot fetch the platform says `platform.offline` (main.rs
/// logs the code and the text), keeps the generation, and is planned again at the next start.
#[test]
fn an_offline_recommit_says_platform_offline_and_is_tried_again() {
    let (h, installed) = deployed(&Fx::minimal(), 0);
    *h.commit.fail.lock().unwrap() = Some(CommitError::NoNetwork("Could not resolve host".into()));
    let err = h.importer.recommit(ID).unwrap_err();
    assert_eq!(err.code, "platform.offline");
    assert_eq!(generation(&installed), 0);
    assert!(h.staging().is_empty(), "{:?}", h.staging());
    assert_eq!(recommits_planned(&h), vec![ID.to_string()]);
    assert_eq!(h.importer.recommit(ID), Ok(Recommitted::Done));
    assert_eq!(generation(&installed), METADATA_GENERATION);
}

#[test]
fn a_recommit_asks_for_space_as_an_install_does() {
    use std::sync::atomic::Ordering;
    let (h, installed) = deployed(&Fx::minimal(), 0);
    // Less than the deployed /app takes: nothing is copied or committed.
    h.free.bytes.store(4, Ordering::SeqCst);
    let err = h.importer.recommit(ID).unwrap_err();
    assert_eq!(err.code, "space.not_enough");
    assert!(h.free.calls.load(Ordering::SeqCst) >= 1);
    assert!(h.commit.recommits().is_empty());
    assert!(h.staging().is_empty(), "{:?}", h.staging());
    assert_eq!(generation(&installed), 0);
    h.free.bytes.store(u64::MAX, Ordering::SeqCst);
    assert_eq!(h.importer.recommit(ID), Ok(Recommitted::Done));
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

/// The deployed app's `metadata` file (beside `files/`).
fn deployed_metadata(h: &Harness) -> std::path::PathBuf {
    files_dir(h, ID).parent().unwrap().join("metadata")
}

/// Nothing a re-commit would add may be missing from the deployed metadata: `edit` changes the
/// text the commit wrote, and the re-commit is refused when the new set is not within it.
fn refused_after(fx: &Fx, edit: impl Fn(&str) -> String, added: &[&str]) {
    let (h, installed) = deployed(fx, 0);
    let path = deployed_metadata(&h);
    let text = std::fs::read_to_string(&path).unwrap();
    let edited = edit(&text);
    assert_ne!(edited, text, "the edit changed nothing");
    std::fs::write(&path, &edited).unwrap();
    let before = listing(&h.cfg.flatpak);
    assert_eq!(recommits_planned(&h), vec![ID.to_string()]);
    assert_eq!(
        h.importer.recommit(ID),
        Ok(Recommitted::Widens(
            added.iter().map(|a| a.to_string()).collect()
        ))
    );
    // Nothing was committed, the app is as deployed, the generation is the old one and the
    // staging folder was never made; the next start plans it again.
    assert!(h.commit.recommits().is_empty());
    assert_eq!(generation(&installed), 0);
    assert_eq!(listing(&h.cfg.flatpak), before);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), edited);
    assert!(h.staging().is_empty(), "{:?}", h.staging());
    assert_eq!(recommits_planned(&h), vec![ID.to_string()]);
}

#[test]
fn a_recommit_that_adds_a_context_entry_is_refused() {
    refused_after(
        &Fx::minimal(),
        |t| t.replace("shared=ipc;", ""),
        &["[Context] shared=ipc"],
    );
}

#[test]
fn a_recommit_that_adds_a_bus_name_is_refused() {
    let fx = asking(
        serde_json::json!({"input": "controllers", "gamemode": true}),
        1,
    );
    refused_after(
        &fx,
        |t| {
            t.replace(
                "com.feralinteractive.GameMode=talk
",
                "",
            )
        },
        &["[Session Bus Policy] com.feralinteractive.GameMode=talk"],
    );
}

#[test]
fn a_recommit_that_equals_or_narrows_the_deployed_grants_goes_ahead() {
    // Equal: the fixture's own metadata (an_app_of_an_older_generation... covers it too).
    let (h, installed) = deployed(&Fx::minimal(), 0);
    let path = deployed_metadata(&h);
    // Narrower than deployed: the app used to have the network, a bus name and more devices.
    let text = std::fs::read_to_string(&path).unwrap();
    let broader = text
        .replace("shared=ipc;", "shared=ipc;network;")
        .replace("devices=dri;", "devices=all;")
        + "[Session Bus Policy]
com.example.Old=talk

";
    std::fs::write(&path, broader).unwrap();
    assert_eq!(h.importer.recommit(ID), Ok(Recommitted::Done));
    assert_eq!(h.commit.recommits().len(), 1);
    assert_eq!(generation(&installed), METADATA_GENERATION);
}

/// A deployed `metadata` that cannot be compared safely: the app is left as deployed.
fn unreadable_after(edit: impl Fn(&str) -> Option<String>) {
    let (h, installed) = deployed(&Fx::minimal(), 0);
    let path = deployed_metadata(&h);
    match edit(&std::fs::read_to_string(&path).unwrap()) {
        Some(text) => std::fs::write(&path, text).unwrap(),
        None => std::fs::remove_file(&path).unwrap(),
    }
    assert_eq!(h.importer.recommit(ID), Ok(Recommitted::MetadataUnreadable));
    assert!(h.commit.recommits().is_empty());
    assert_eq!(generation(&installed), 0);
    assert!(h.staging().is_empty(), "{:?}", h.staging());
}

#[test]
fn an_app_without_metadata_is_not_committed() {
    unreadable_after(|_| None);
}

#[test]
fn an_app_whose_metadata_has_a_removal_or_a_repeated_key_is_not_committed() {
    unreadable_after(|t| Some(t.replace("shared=ipc;", "shared=ipc;!network;")));
    unreadable_after(|t| {
        Some(format!(
            "{t}
[Context]
shared=ipc;
"
        ))
    });
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
    let flatpak: Vec<Vec<String>> = runner
        .calls
        .lock()
        .unwrap()
        .iter()
        .filter(|c| c[0] == "flatpak")
        .cloned()
        .collect();
    let calls: Vec<&str> = flatpak.iter().map(|c| c[1].as_str()).collect();
    assert_eq!(
        calls,
        [
            "remote-add",
            "remote-modify",
            "build-finish",
            "build-export",
            "list",
            "install",
            "install"
        ]
    );
    // A Windows app: the runtime and the 32-bit libraries and GL drivers its points mount, from
    // Flathub, before the app itself (RUY-999).
    let platform = &flatpak[5];
    let at = platform
        .iter()
        .position(|a| a == commit::PLATFORM_REMOTE)
        .expect("from Flathub");
    assert_eq!(
        &platform[at + 1..],
        &[
            "runtime/org.freedesktop.Platform/x86_64/26.08".to_string(),
            "runtime/org.freedesktop.Platform.Compat.i386/x86_64/26.08".to_string(),
            "runtime/org.freedesktop.Platform.GL32.default/x86_64/26.08".to_string(),
        ]
    );
    assert!(!platform.iter().any(|a| a == "--or-update"), "{platform:?}");
    assert!(
        flatpak[6].contains(&commit::REMOTE.to_string()),
        "{:?}",
        flatpak[6]
    );
}

/// RUY-854: an admin's withdrawal (`flatpak override --system`, a file of its own under
/// `/var/lib/flatpak/overrides/`) is never undone by a re-commit. The commit installs with
/// `--or-update`, which Flatpak keeps the override across, and runs no command that removes the
/// app or resets an override.
#[test]
fn a_recommit_runs_no_command_that_drops_an_override() {
    let mut fx = Fx::wine_full();
    fx.manifest["id"] = serde_json::json!(ID);
    let (h, _) = deployed(&fx, 0);
    let (manifest, assessment) =
        reconcile::installed_app(&reconcile::our_files(&h.cfg.flatpak, ID).unwrap()).unwrap();
    let state = tempfile::tempdir().unwrap();
    let copy = staged_copy(&h, state.path());
    let runner = std::sync::Arc::new(FakeRunner::default());
    let fc =
        FlatpakCommit::new(&state.path().join("lib"), Box::new(runner.clone())).keeping_owner();
    fc.recommit(&RecommitRequest {
        files: &copy,
        manifest: &manifest,
        assessment: &assessment,
    })
    .unwrap();
    let calls = runner.calls.lock().unwrap().clone();
    for call in &calls {
        assert!(
            !call
                .iter()
                .any(|a| a == "override" || a == "uninstall" || a == "--reset"),
            "a command that could drop an override: {call:?}"
        );
    }
    let install = calls
        .iter()
        .find(|c| {
            c.get(1).map(String::as_str) == Some("install") && c.contains(&commit::REMOTE.into())
        })
        .expect("the re-commit installs the app");
    assert!(
        install.iter().any(|a| a == "--or-update"),
        "an update, not a new install: {install:?}"
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

/// A `FlatpakCommit` over `runner`, and the re-commit of the Windows app `play.<ID>` deployed at
/// `generation`, the way the importer sends it.
fn flatpak_recommit(
    runner: &std::sync::Arc<FakeRunner>,
    generation: u32,
) -> Result<Vec<Vec<String>>, CommitError> {
    let mut fx = Fx::wine_full();
    fx.manifest["id"] = serde_json::json!(ID);
    let (h, _) = deployed(&fx, generation);
    let (manifest, assessment) =
        reconcile::installed_app(&reconcile::our_files(&h.cfg.flatpak, ID).unwrap()).unwrap();
    let state = tempfile::tempdir().unwrap();
    let copy = staged_copy(&h, state.path());
    let fc =
        FlatpakCommit::new(&state.path().join("lib"), Box::new(runner.clone())).keeping_owner();
    let result = fc.recommit(&RecommitRequest {
        files: &copy,
        manifest: &manifest,
        assessment: &assessment,
    });
    let calls = runner.calls.lock().unwrap().clone();
    result.map(|()| calls)
}

fn installs_from(calls: &[Vec<String>], remote: &str) -> Vec<Vec<String>> {
    calls
        .iter()
        .filter(|c| {
            c.get(1).map(String::as_str) == Some("install") && c.iter().any(|a| a == remote)
        })
        .cloned()
        .collect()
}

/// RUY-1003: an app installed before RUY-999 is re-committed (generation 1 < 2) and gets the 32-bit
/// platform; one that is current is not planned at all.
#[test]
fn a_generation_1_windows_app_gets_the_32_bit_platform_at_reconcile() {
    let mut fx = Fx::wine_full();
    fx.manifest["id"] = serde_json::json!(ID);
    let (h, _) = deployed(&fx, 1);
    assert_eq!(recommits_planned(&h), vec![ID.to_string()]);
    let (h, _) = deployed(&fx, METADATA_GENERATION);
    assert!(recommits_planned(&h).is_empty());
    let runner = std::sync::Arc::new(FakeRunner::default());
    // Flathub's runtime only: the two 32-bit refs are missing and are the install's argument.
    *runner.runtimes.lock().unwrap() = "org.freedesktop.Platform/x86_64/26.08
"
    .into();
    let calls = flatpak_recommit(&runner, 1).unwrap();
    let platform = installs_from(&calls, commit::PLATFORM_REMOTE);
    assert_eq!(platform.len(), 1, "{calls:?}");
    assert_eq!(
        &platform[0][platform[0].len() - 2..],
        &[
            "runtime/org.freedesktop.Platform.Compat.i386/x86_64/26.08".to_string(),
            "runtime/org.freedesktop.Platform.GL32.default/x86_64/26.08".to_string(),
        ]
    );
}

/// RUY-1003, offline start: with every platform ref installed (`flatpak list`, not Flathub, says
/// so) the re-commit never names Flathub, so it needs no network.
#[test]
fn an_offline_recommit_with_the_platform_installed_does_not_touch_flathub() {
    let runner = std::sync::Arc::new(FakeRunner::default());
    *runner.runtimes.lock().unwrap() = "org.freedesktop.Platform/x86_64/26.08
         org.freedesktop.Platform.Compat.i386/x86_64/26.08
         org.freedesktop.Platform.GL32.default/x86_64/26.08
"
    .into();
    *runner.fail_with_arg.lock().unwrap() = Some(commit::PLATFORM_REMOTE.into());
    let calls = flatpak_recommit(&runner, 1).unwrap();
    assert!(installs_from(&calls, commit::PLATFORM_REMOTE).is_empty());
    assert_eq!(installs_from(&calls, commit::REMOTE).len(), 1);
}

/// RUY-1003, offline start with a ref missing: the re-commit fails before the app is installed (it
/// stays as it was); the importer logs it and plans it again at the next start
/// (`a_failed_recommit_keeps_the_generation_and_is_tried_again`).
#[test]
fn an_offline_recommit_with_a_platform_ref_missing_fails_and_leaves_the_app() {
    let runner = std::sync::Arc::new(FakeRunner::default());
    *runner.fail_with_arg.lock().unwrap() = Some(commit::PLATFORM_REMOTE.into());
    let err = flatpak_recommit(&runner, 1).unwrap_err();
    assert!(matches!(err, CommitError::NoNetwork(_)), "{err:?}");
    let calls = runner.calls.lock().unwrap().clone();
    assert!(
        installs_from(&calls, commit::REMOTE).is_empty(),
        "{calls:?}"
    );
}

/// RUY-1004: what Flatpak says when it cannot reach Flathub is `NoNetwork`, whatever the words; any
/// other failure of the platform install stays `Failed`.
#[test]
fn the_platform_install_tells_no_network_from_other_failures() {
    let offline = [
        "error: Unable to load summary from remote flathub: While fetching https://dl.flathub.org/repo/summary: [6] Could not resolve host: dl.flathub.org",
        "error: While fetching https://dl.flathub.org/repo/summary: [7] Couldn't connect to server",
        "error: Unable to load summary from remote flathub: While fetching https://dl.flathub.org/repo/summary.idx: [7] Could not connect to server",
        "error: Unable to connect to dl.flathub.org:443",
        "error: Network is unreachable",
        "error: Temporary failure in name resolution",
        "error: Connection timed out",
        "error: Connection refused",
    ];
    for text in offline {
        let runner = std::sync::Arc::new(FakeRunner::default());
        *runner.fail_with_arg.lock().unwrap() = Some(commit::PLATFORM_REMOTE.into());
        *runner.fail_text.lock().unwrap() = Some(text.into());
        let err = flatpak_recommit(&runner, 1).unwrap_err();
        assert!(matches!(err, CommitError::NoNetwork(_)), "{text}: {err:?}");
    }
    for text in [
        "error: Runtime org.freedesktop.Platform not found",
        "error: Something else broke",
    ] {
        let runner = std::sync::Arc::new(FakeRunner::default());
        *runner.fail_with_arg.lock().unwrap() = Some(commit::PLATFORM_REMOTE.into());
        *runner.fail_text.lock().unwrap() = Some(text.into());
        let err = flatpak_recommit(&runner, 1).unwrap_err();
        assert!(matches!(err, CommitError::Failed(_)), "{text}: {err:?}");
    }
    // Only the platform install asks: the same words from the app's own install stay `commit.failed`.
    let runner = std::sync::Arc::new(FakeRunner::default());
    *runner.fail_with_arg.lock().unwrap() = Some(commit::REMOTE.into());
    let err = flatpak_recommit(&runner, 1).unwrap_err();
    assert!(matches!(err, CommitError::Failed(_)), "{err:?}");
}
