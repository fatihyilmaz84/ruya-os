//! The runner dry run of `validate` and `inspect` (05 section 6.2), through the command line.

mod common;
use common::*;
use serde_json::json;

fn built(t: &std::path::Path, edit: impl FnOnce(&mut serde_json::Value)) -> std::path::PathBuf {
    let dir = t.join("g");
    wine_with(&dir, edit, true, true);
    assert_ok(&build(&dir, &[]).0);
    dir
}

fn resolution(dir: &std::path::Path, flags: &[&str]) -> ruya_pack::Outcome {
    let mut a = vec!["validate", "--json"];
    a.extend_from_slice(flags);
    run_p(&a, &[dir])
}

#[test]
fn newest_takes_the_system_runner_when_it_is_newer_and_the_bundled_one_otherwise() {
    let t = tempfile::tempdir().unwrap();
    let dir = built(t.path(), |_| {});
    let o = resolution(&dir, &["--system-wine", "10.2"]);
    assert_ok(&o);
    assert_eq!(o.json["resolution"][0]["runner"], json!("system"));
    assert_eq!(o.json["resolution"][0]["family"], json!("wine"));
    assert_eq!(o.json["resolution"][0]["version"], json!("10.2"));
    assert_eq!(o.json["resolution"][0]["tested"], json!("9.20"));
    assert!(o.text.contains("the system wine 10.2"), "{}", o.text);

    let o = resolution(&dir, &["--system-wine", "9.0"]);
    assert_ok(&o);
    assert_eq!(o.json["resolution"][0]["runner"], json!("bundled"));
    assert_eq!(o.json["resolution"][0]["version"], json!("9.20"));

    // A list names more than one; the newest of the family counts.
    let o = resolution(&dir, &["--system-wine", "9.0", "--system-wine", "10.1"]);
    assert_eq!(o.json["resolution"][0]["version"], json!("10.1"));
}

#[test]
fn max_major_fences_the_system_runner() {
    let t = tempfile::tempdir().unwrap();
    let dir = built(t.path(), |m| m["components"][0]["max_major"] = json!(9));
    let o = resolution(&dir, &["--system-wine", "10.2"]);
    assert_ok(&o);
    assert_eq!(
        o.json["resolution"][0]["runner"],
        json!("bundled"),
        "10.x is above the fence"
    );
    let o = resolution(&dir, &["--system-wine", "9.22"]);
    assert_eq!(o.json["resolution"][0]["version"], json!("9.22"));
}

#[test]
fn a_system_only_component_that_cannot_be_served_is_a_problem_with_its_cause() {
    let t = tempfile::tempdir().unwrap();
    let dir = built(t.path(), |m| {
        m["components"][0]["source"] = json!("system");
        m["components"][0]["min"] = json!("11.0");
        m["components"][0]
            .as_object_mut()
            .unwrap()
            .remove("bundled");
    });
    // The bundled folder is now unused but still in the table; the manifest is valid.
    let o = resolution(&dir, &["--system-wine", "10.2"]);
    assert_eq!(o.exit, 1, "{}", o.text);
    assert_eq!(problem_codes(&o), ["resolve.system_too_old"]);
    assert_eq!(o.json["problems"][0]["path"], json!("/components/0"));
    assert!(o.json["problems"][0]["message"]
        .as_str()
        .unwrap()
        .contains("10.2"));
    assert!(o.json["problems"][0]["fix"]
        .as_str()
        .unwrap()
        .contains("prefer-system"));
    let o = resolution(&dir, &["--system-proton-ge", "10.9"]);
    // A Proton never stands in for Wine: naming only a Proton checks nothing about the Wine component.
    assert_ok(&o);
    assert_eq!(o.json["warnings"][0]["code"], json!("resolve.not_checked"));
    let o = resolution(&dir, &["--system-wine", "9.0", "--system-proton-ge", "99"]);
    assert_eq!(problem_codes(&o), ["resolve.system_too_old"]);
    assert_eq!(resolution(&dir, &["--system-wine", "12.0"]).exit, 0);
}

#[test]
fn without_a_runner_list_the_dry_run_is_skipped_and_says_so() {
    let t = tempfile::tempdir().unwrap();
    let dir = built(t.path(), |_| {});
    let o = resolution(&dir, &[]);
    assert_ok(&o);
    assert_eq!(o.json["warnings"][0]["code"], json!("resolve.not_checked"));
    assert!(o.json["resolution"].is_null());
    // A bundled-only component needs no list.
    let t2 = tempfile::tempdir().unwrap();
    let dir2 = built(t2.path(), |m| {
        m["components"][0]["source"] = json!("bundled")
    });
    let o = resolution(&dir2, &[]);
    assert_ok(&o);
    assert_eq!(o.json["warnings"].as_array().unwrap().len(), 0);
    assert_eq!(o.json["resolution"][0]["runner"], json!("bundled"));
}

#[test]
fn emulators_and_proton_ge_have_their_own_flags() {
    let t = tempfile::tempdir().unwrap();
    let dir = built(t.path(), |m| {
        m["components"] = json!([
            {"id": "proton", "type": "proton", "source": "system", "min": "9"},
            {"id": "rpcs3", "type": "emulator", "source": "system", "min": "0.0.30"}
        ]);
        m["run"] = json!({"runner": "proton", "component": "proton", "command": ["${payload}/StarHopper.exe"]});
    });
    let o = resolution(
        &dir,
        &[
            "--system-proton-ge",
            "10.9",
            "--system-runner",
            "rpcs3=0.0.35",
        ],
    );
    assert_ok(&o);
    assert_eq!(o.json["resolution"][0]["family"], json!("proton-ge"));
    assert_eq!(o.json["resolution"][1]["family"], json!("rpcs3"));
    let o = resolution(&dir, &["--system-proton-ge", "10.9"]);
    assert_eq!(
        o.json["warnings"][0]["code"],
        json!("resolve.not_checked"),
        "rpcs3 was not named"
    );
    assert!(o.json["warnings"][0]["message"]
        .as_str()
        .unwrap()
        .contains("rpcs3"));
}

#[test]
fn inspect_prints_the_resolution_next_to_the_tested_version() {
    let t = tempfile::tempdir().unwrap();
    let dir = built(t.path(), |_| {});
    let o = run_p(&["inspect", "--system-wine", "10.2"], &[&dir]);
    assert_ok(&o);
    assert!(
        o.text.contains("the system wine 10.2, tested with 9.20"),
        "{}",
        o.text
    );
}
