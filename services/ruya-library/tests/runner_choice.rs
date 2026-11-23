//! RUY-959: the per-profile runner choice and ResolveRunner of Library1, through the interface the
//! service serves (its rules, without a bus), and the resolution on the launcher's in-memory file
//! system with the launcher's own test game.

use std::path::Path;

use ruya_library::catalog::scan;
use ruya_library::choices::Status;
use ruya_library::dbus::{record, resolution_record, LibraryIface, Sources};
use ruya_library::flatpak::FixtureLister;
use ruya_library::games::Game;
use ruya_library::runners::{resolve, Resolution};
use ruya_play_format::resolve::Override;

mod common;
use common::{full_deployment, FULL_ROW};

#[path = "../../ruya-play-launch/tests/common/mod.rs"]
mod launch;

const PLAY: &str = "flatpak:play.com.example.starhopper";

/// A plain Flatpak app and the full .play app of `common`.
fn rows() -> String {
    format!("org.example.App\tApp\tflathub\n{FULL_ROW}")
}

fn library(root: &Path, state: &Path) -> LibraryIface {
    full_deployment(root);
    LibraryIface::new(Sources {
        lister: Box::new(FixtureLister::new(&rows())),
        play_root: root.to_path_buf(),
        play_runners: root.join("runners"),
        choices_dir: state.to_path_buf(),
    })
}

#[test]
fn the_choice_is_per_profile_and_survives_a_restart() {
    let (root, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let lib = library(root.path(), state.path());
    assert_eq!(lib.runner_choice("p1", PLAY).as_deref(), Ok("package"));
    assert_eq!(lib.store_runner_choice("p1", PLAY, "bundled"), Ok(true));
    assert_eq!(lib.store_runner_choice("p2", PLAY, "system"), Ok(true));
    assert_eq!(lib.runner_choice("p1", PLAY).as_deref(), Ok("bundled"));
    assert_eq!(lib.runner_choice("p2", PLAY).as_deref(), Ok("system"));
    assert_eq!(lib.store_runner_choice("p1", PLAY, "bundled"), Ok(false));

    let again = library(root.path(), state.path());
    assert_eq!(again.runner_choice("p1", PLAY).as_deref(), Ok("bundled"));
    assert_eq!(again.runner_choice("p2", PLAY).as_deref(), Ok("system"));
}

#[test]
fn package_clears_the_choice() {
    let (root, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let lib = library(root.path(), state.path());
    lib.store_runner_choice("p1", PLAY, "system").unwrap();
    assert_eq!(lib.store_runner_choice("p1", PLAY, "package"), Ok(true));
    assert_eq!(lib.runner_choice("p1", PLAY).as_deref(), Ok("package"));
    assert_eq!(std::fs::read_dir(state.path()).unwrap().count(), 0);
}

#[test]
fn an_unknown_id_a_plain_app_and_an_unknown_choice_are_refused() {
    let (root, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let lib = library(root.path(), state.path());
    let refusals = [
        ("flatpak:play.not.installed", "system", Status::Unknown),
        ("flatpak:org.example.App", "system", Status::NotPlay),
        (PLAY, "proton", Status::Invalid),
        (PLAY, "", Status::Invalid),
    ];
    for (id, choice, status) in refusals {
        assert_eq!(
            lib.store_runner_choice("p1", id, choice),
            Err(status),
            "{id} {choice}"
        );
        assert_eq!(
            lib.runner_resolution(id, choice).map(|_| ()),
            Err(status),
            "{id} {choice}"
        );
    }
    assert_eq!(
        lib.runner_choice("p1", "flatpak:play.not.installed"),
        Err(Status::Unknown)
    );
    assert_eq!(
        lib.runner_choice("p1", "flatpak:org.example.App"),
        Err(Status::NotPlay)
    );
    assert_eq!(lib.runner_choice("../x", PLAY), Err(Status::Invalid));
    assert_eq!(
        lib.store_runner_choice("../x", PLAY, "system"),
        Err(Status::Invalid)
    );
    assert_eq!(std::fs::read_dir(state.path()).unwrap().count(), 0);
}

/// The item's runner keys and ResolveRunner(package) are one code path: the same record for the
/// same deployment (empty off Linux, the launcher's answer on Linux).
#[test]
fn resolve_runner_package_is_what_the_item_says() {
    let (root, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let lib = library(root.path(), state.path());
    let item = scan(
        &FixtureLister::new(&rows()),
        root.path(),
        &root.path().join("runners"),
    )
    .into_iter()
    .find(|i| i.id == PLAY)
    .unwrap();
    let resolved = lib.runner_resolution(PLAY, "package").unwrap();
    assert_eq!(&resolved, &item.play.as_ref().unwrap().resolution);
    let from_item = record(&Game::alone(item));
    for (key, value) in resolution_record(&resolved) {
        assert_eq!(from_item.get(&key), Some(&value), "{key}");
    }
}

const IMAGE_RUNNERS: &str = "/usr/lib/ruyaos/play/runners";

/// A system Wine package without a bundled copy, as the launcher's tests build it.
fn system_only() -> launch::Game {
    let mut g = launch::Game::wine();
    g.set("/components/0/source", serde_json::json!("system"));
    g.manifest["components"][0]["tested"] = serde_json::json!("9.20");
    g.manifest["components"][0]
        .as_object_mut()
        .unwrap()
        .remove("bundled");
    g.files.retain(|(p, _)| !p.starts_with("components/"));
    g
}

#[test]
fn resolving_bundled_for_a_package_without_one_gives_its_resolve_error() {
    let os = system_only().install();
    let r = resolve(&os, "/app", IMAGE_RUNNERS, Override::Bundled);
    assert_eq!(r.runner, None);
    let err = r.resolve_error.expect("the launch would refuse");
    assert!(err.contains("wine"), "{err}");
    assert_eq!(r.resolve_code.as_deref(), Some("resolve.no_system_runner"));
    assert!(!r.fallback, "a refusal is no runner, so no fallback");
}

/// ResolveRunner(system) holds RUY-903's keys for the same fixture: the item record's.
#[test]
fn resolving_system_gives_the_keys_the_item_has() {
    let mut os = system_only().install();
    launch::add_runner_at(
        &mut os,
        &format!("{IMAGE_RUNNERS}/Wine10"),
        "wine",
        "wine",
        "10.2",
    );
    let r = resolve(&os, "/app", IMAGE_RUNNERS, Override::System);
    assert_eq!(
        r,
        Resolution {
            runner: Some("wine 10.2".into()),
            runner_source: Some("system".into()),
            runner_tested: Some("9.20".into()),
            resolve_error: None,
            resolve_code: None,
            fallback: false,
        }
    );
    assert_eq!(
        r,
        resolve(&os, "/app", IMAGE_RUNNERS, Override::PackageDefault)
    );
    let rec = resolution_record(&r);
    let mut keys: Vec<&str> = rec.keys().map(String::as_str).collect();
    keys.sort();
    assert_eq!(
        keys,
        ["play_runner", "play_runner_source", "play_runner_tested"]
    );
}

/// The choice reaches the launcher's resolution: a package with a bundled Wine 9.20 and the image's
/// newer 10.2 resolves to each by the choice.
#[test]
fn the_choice_picks_the_bundled_copy_or_the_image_runner() {
    let mut os = launch::Game::wine().install();
    launch::add_runner_at(
        &mut os,
        &format!("{IMAGE_RUNNERS}/Wine10"),
        "wine",
        "wine",
        "10.2",
    );
    let source = |over| resolve(&os, "/app", IMAGE_RUNNERS, over).runner;
    assert_eq!(source(Override::Bundled).as_deref(), Some("wine 9.20"));
    assert_eq!(source(Override::System).as_deref(), Some("wine 10.2"));
}

/// RUY-905: each refusal of the resolver carries its stable code beside the sentence, so the shell
/// words it by the code: no image runner, one below `min`, one above `max_major`, and a package
/// whose files are damaged.
#[test]
fn each_refusal_carries_its_code() {
    let code = |os: &ruya_play_launch::fake::FakeOs| {
        resolve(os, "/app", IMAGE_RUNNERS, Override::PackageDefault).resolve_code
    };
    let none = system_only().install();
    assert_eq!(code(&none).as_deref(), Some("resolve.no_system_runner"));

    let mut old = system_only().install();
    launch::add_runner_at(
        &mut old,
        &format!("{IMAGE_RUNNERS}/Wine8"),
        "wine",
        "wine",
        "8.0",
    );
    assert_eq!(code(&old).as_deref(), Some("resolve.system_too_old"));

    let mut fenced = system_only();
    fenced.manifest["components"][0]["max_major"] = serde_json::json!(10);
    let mut fenced = fenced.install();
    launch::add_runner_at(
        &mut fenced,
        &format!("{IMAGE_RUNNERS}/Wine11"),
        "wine",
        "wine",
        "11.0",
    );
    assert_eq!(code(&fenced).as_deref(), Some("resolve.system_too_new"));

    let damaged = ruya_play_launch::fake::FakeOs::new();
    let r = resolve(&damaged, "/app", IMAGE_RUNNERS, Override::PackageDefault);
    assert!(r.resolve_error.is_some());
    assert!(r
        .resolve_code
        .is_some_and(|c| !c.is_empty() && !c.starts_with("resolve.")));
}

/// RUY-905: a choice the package cannot honour gives the package default's runner, flagged
/// (`play_fallback`), and the record serves the flag; the package default is never flagged.
#[test]
fn a_choice_that_cannot_be_honoured_is_flagged() {
    let mut os = launch::Game::wine().install();
    launch::add_runner_at(
        &mut os,
        &format!("{IMAGE_RUNNERS}/Wine8"),
        "wine",
        "wine",
        "8.0",
    );
    let system = resolve(&os, "/app", IMAGE_RUNNERS, Override::System);
    assert_eq!(
        system.runner.as_deref(),
        Some("wine 9.20"),
        "the bundled copy"
    );
    assert!(system.fallback);
    assert!(resolution_record(&system).contains_key("play_fallback"));
    let package = resolve(&os, "/app", IMAGE_RUNNERS, Override::PackageDefault);
    assert!(!package.fallback);
    assert!(!resolution_record(&package).contains_key("play_fallback"));
}
