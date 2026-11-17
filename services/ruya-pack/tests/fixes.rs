//! The fix table covers every code a command can print, and the process exit codes.

use ruya_pack::fixes::{catalogue, fix_for, FALLBACK};
use std::process::Command;

#[test]
fn every_known_code_has_a_fix_line_of_its_own_or_its_groups() {
    let all = catalogue();
    assert!(all.len() > 200, "{} codes", all.len());
    for (code, fix) in &all {
        assert_ne!(*fix, FALLBACK, "no fix line for {code}");
        assert!(fix.len() > 10 && fix.ends_with('.'), "{code}: {fix}");
        assert!(!fix.contains('\n'), "{code}: one line");
    }
    // The catalogue is sorted and has no duplicates, so a guide can be generated from it.
    let codes: Vec<&str> = all.iter().map(|(c, _)| *c).collect();
    let mut sorted = codes.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(codes, sorted);
    assert_eq!(fix_for("no.such_code"), FALLBACK);
}

#[test]
fn the_commonly_hit_codes_have_their_own_line_not_the_groups() {
    // A group line is a fallback; these are what a developer meets first.
    for code in [
        "art.too_small",
        "art.aspect_ratio",
        "entry.symlink",
        "path.case_collision",
        "licence.text_missing",
        "licence.source_missing",
        "package.hash_mismatch",
        "sig.play_files_changed",
        "ceiling.refused",
        "resolve.system_too_old",
    ] {
        assert_ne!(
            fix_for(code),
            fix_for(&format!("{}.", code.split('.').next().unwrap())),
            "{code}"
        );
    }
}

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_ruya-pack"))
}

#[test]
fn the_program_exits_0_1_2_3_and_prints_the_result_object_with_json() {
    let help = bin().arg("--help").output().unwrap();
    assert_eq!(help.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&help.stdout).contains("usage: ruya-pack"));

    let empty = tempfile::tempdir().unwrap();
    let p = bin()
        .args(["validate", "--json"])
        .arg(empty.path())
        .output()
        .unwrap();
    assert_eq!(p.status.code(), Some(1));
    let v: serde_json::Value = serde_json::from_slice(&p.stdout).unwrap();
    assert_eq!(v["ok"], false);
    assert!(v["problems"][0]["fix"].is_string());

    let usage = bin().arg("frobnicate").output().unwrap();
    assert_eq!(usage.status.code(), Some(2));
    assert!(usage.stdout.is_empty(), "usage errors go to stderr");
    assert!(String::from_utf8_lossy(&usage.stderr).contains("usage.error"));
    let usage = bin().args(["--json", "frobnicate"]).output().unwrap();
    assert_eq!(usage.status.code(), Some(2));
    let v: serde_json::Value = serde_json::from_slice(&usage.stdout).unwrap();
    assert_eq!(v["problems"][0]["code"], "usage.error");

    let io = bin()
        .args(["validate", "--json", "/no/such/package"])
        .output()
        .unwrap();
    assert_eq!(io.status.code(), Some(3));
    let v: serde_json::Value = serde_json::from_slice(&io.stdout).unwrap();
    assert_eq!(v["problems"][0]["code"], "io.error");

    // The environment variable reaches the program.
    let d = tempfile::tempdir().unwrap();
    let pkg = d.path().join("g");
    assert_eq!(
        bin().arg("init").arg(&pkg).output().unwrap().status.code(),
        Some(0)
    );
    let k = bin()
        .env("RUYA_PACK_KEY", "not base64!")
        .arg("sign")
        .arg(&pkg)
        .output()
        .unwrap();
    assert_eq!(k.status.code(), Some(2));
    assert!(!String::from_utf8_lossy(&k.stderr).contains("not base64!"));
}
