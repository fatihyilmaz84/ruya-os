//! The library's dry run (RUY-903): the launcher's own resolution with the package tree and the
//! runners folder somewhere else, without starting anything.

mod common;

use common::*;
use ruya_play_format::resolve::Override::{self, Bundled, PackageDefault, System};
use ruya_play_launch::dry_run;
use ruya_play_launch::fake::FakeOs;
use serde_json::json;

/// Where the image keeps its runners (the launcher sees them at `/app/runners`).
const IMAGE_RUNNERS: &str = "/usr/lib/ruyaos/play/runners";

fn with_image_runner(os: &mut FakeOs, family: &str, version: &str) {
    add_runner_at(
        os,
        &format!("{IMAGE_RUNNERS}/{family}-{version}"),
        family,
        "wine",
        version,
    );
}

#[test]
fn a_system_package_uses_the_runner_the_image_has() {
    let mut g = Game::wine();
    g.set("/components/0/source", json!("system"));
    let mut os = g.install();
    with_image_runner(&mut os, "wine", "10.2");
    let runner = dry_run(&os, "/app", IMAGE_RUNNERS, PackageDefault)
        .unwrap()
        .runner
        .unwrap();
    assert_eq!(runner.in_use.source, "system");
    assert_eq!(
        (
            runner.in_use.family.as_str(),
            runner.in_use.version.as_str()
        ),
        ("wine", "10.2")
    );
    assert_eq!(runner.in_use.component, "wine");
}

#[test]
fn a_system_package_without_the_runner_says_why() {
    let mut g = Game::wine();
    g.set("/components/0/source", json!("system"));
    let os = g.install();
    let err = dry_run(&os, "/app", IMAGE_RUNNERS, PackageDefault).unwrap_err();
    assert_eq!(err.code, "resolve.no_system_runner");
    assert!(err.message.contains("wine"), "{}", err.message);
}

#[test]
fn a_runner_older_than_min_gives_the_sentence() {
    let mut g = Game::wine();
    g.set("/components/0/source", json!("system"));
    let mut os = g.install();
    with_image_runner(&mut os, "wine", "8.0");
    let err = dry_run(&os, "/app", IMAGE_RUNNERS, PackageDefault).unwrap_err();
    assert_eq!(err.code, "resolve.system_too_old");
    assert_eq!(
        err.message,
        "The OS runner is 8.0, older than the required 9.0."
    );
}

#[test]
fn a_newest_package_prefers_the_newer_image_runner_and_keeps_its_tested_version() {
    let mut g = Game::wine();
    g.manifest["components"][0]["tested"] = json!("9.20");
    let mut os = g.install();
    with_image_runner(&mut os, "wine", "10.2");
    let runner = dry_run(&os, "/app", IMAGE_RUNNERS, PackageDefault)
        .unwrap()
        .runner
        .unwrap();
    assert_eq!(runner.in_use.source, "system");
    assert_eq!(runner.tested.as_deref(), Some("9.20"));

    // Without the image's runner the shipped copy runs.
    let os = g.install();
    let runner = dry_run(&os, "/app", IMAGE_RUNNERS, PackageDefault)
        .unwrap()
        .runner
        .unwrap();
    assert_eq!(runner.in_use.source, "bundled");
    assert_eq!(runner.in_use.version, "9.20");
}

#[test]
fn a_native_package_has_no_runner() {
    let os = Game::native().install();
    assert_eq!(
        dry_run(&os, "/app", IMAGE_RUNNERS, PackageDefault)
            .unwrap()
            .runner,
        None
    );
}

#[test]
fn the_package_tree_is_read_from_the_root_it_is_given() {
    let os = Game::native().install();
    let err = dry_run(&os, "/nowhere", IMAGE_RUNNERS, PackageDefault).unwrap_err();
    assert!(
        err.message.contains("cannot be read") || err.message.contains("damaged"),
        "{}",
        err.message
    );
}

/// RUY-959: the choice is the one `--runner` gives the launch, applied by the same resolver.
#[test]
fn the_choice_picks_the_runner_the_launch_would_get_with_that_runner_argument() {
    let mut g = Game::wine();
    g.manifest["components"][0]["tested"] = json!("9.20");
    let mut os = g.install();
    with_image_runner(&mut os, "wine", "10.2");
    let source = |over: Override| {
        dry_run(&os, "/app", IMAGE_RUNNERS, over)
            .unwrap()
            .runner
            .unwrap()
            .in_use
            .source
    };
    assert_eq!(
        source(PackageDefault),
        "system",
        "newest: the newer image runner"
    );
    assert_eq!(source(Bundled), "bundled");
    assert_eq!(source(System), "system");
}

/// A choice the package cannot honour falls back to the package's default, as the launch does
/// (`resolve`'s `OverrideBundledUnavailable` note); with no runner for that either, the answer is
/// the launch's refusal.
#[test]
fn choosing_the_bundled_copy_of_a_package_without_one_is_the_package_default() {
    let mut g = Game::wine();
    g.set("/components/0/source", json!("system"));
    g.manifest["components"][0]
        .as_object_mut()
        .unwrap()
        .remove("bundled");
    g.files.retain(|(p, _)| !p.starts_with("components/"));
    let os = g.install();
    let err = dry_run(&os, "/app", IMAGE_RUNNERS, Bundled).unwrap_err();
    assert_eq!(
        err,
        dry_run(&os, "/app", IMAGE_RUNNERS, PackageDefault).unwrap_err()
    );
    assert_eq!(err.code, "resolve.no_system_runner");

    let mut os = g.install();
    with_image_runner(&mut os, "wine", "10.2");
    let runner = dry_run(&os, "/app", IMAGE_RUNNERS, Bundled)
        .unwrap()
        .runner
        .unwrap();
    assert_eq!(runner.in_use.source, "system");
    assert!(runner.fallback, "the bundled choice could not be honoured");
}

/// RUY-905: `fallback` says the choice could not be honoured, so the runner is the package
/// default's: the System choice with an image runner below `min` gets the bundled copy, flagged;
/// the package default and a choice that applies are not flagged.
#[test]
fn a_choice_that_cannot_be_honoured_is_flagged_as_the_package_default() {
    let mut os = Game::wine().install();
    with_image_runner(&mut os, "wine", "8.0");
    let runner = |over: Override| {
        dry_run(&os, "/app", IMAGE_RUNNERS, over)
            .unwrap()
            .runner
            .unwrap()
    };
    let system = runner(System);
    assert_eq!(
        system.in_use.source, "bundled",
        "newest: the 8.0 is below min"
    );
    assert!(system.fallback, "the system choice could not be honoured");
    assert!(!runner(PackageDefault).fallback);
    let bundled = runner(Bundled);
    assert_eq!(bundled.in_use.source, "bundled");
    assert!(!bundled.fallback, "the bundled choice applied");
}
