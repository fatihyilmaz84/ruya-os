//! `runner-check` (RUY-34): a runner folder on disk is read the way the console reads it, and its
//! runner hash is the format's formula over the table `build` would write for the same tree.

mod common;
use common::*;
use ruya_play_format::runner::{RunnerEntry, RunnerHasher, HASH_FILE};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

const RUNNER_JSON: &str = r#"{"format": 1, "family": "proton-ge", "kind": "proton",
  "version": "GE-Proton11-12", "arch": "x86_64", "entry": {"proton": "proton"},
  "licence": "BSD-3-Clause AND LGPL-2.1-or-later",
  "source_url": "https://github.com/GloriousEggroll/proton-ge-custom/releases/tag/GE-Proton11-12"}"#;

const PROTON: &[u8] = b"#!/usr/bin/env python3\nprint('proton')\n";
const WINE: &[u8] = b"\x7fELF fake wine";
const LIB: &[u8] = b"a library";

fn sha(b: &[u8]) -> String {
    Sha256::digest(b)
        .iter()
        .map(|x| format!("{x:02x}"))
        .collect()
}

#[cfg(unix)]
fn executable(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}
#[cfg(not(unix))]
fn executable(_path: &Path) {} // ruya-pack reads the bit from the first bytes there (#!, ELF)

/// A runner folder `<t>/ProtonGE11`: runner.json, the proton script, a program, a library and an
/// empty folder.
fn runner(t: &Path) -> PathBuf {
    let dir = t.join("ProtonGE11");
    put(&dir, "runner.json", RUNNER_JSON.as_bytes());
    put(&dir, "proton", PROTON);
    put(&dir, "files/bin/wine", WINE);
    put(&dir, "files/lib/a.so.1", LIB);
    std::fs::create_dir_all(dir.join("files").join("share").join("empty")).unwrap();
    executable(&dir.join("proton"));
    executable(&dir.join("files").join("bin").join("wine"));
    dir
}

/// The hash computed here from the lines of 05 section 7.3, in path order, independently of the
/// tool's table.
fn expected_hash(extra: &[RunnerEntry<'_>]) -> String {
    let (rj, proton, wine, lib) = (
        sha(RUNNER_JSON.as_bytes()),
        sha(PROTON),
        sha(WINE),
        sha(LIB),
    );
    let mut lines = vec![
        RunnerEntry::File {
            rel: "files/bin/wine",
            sha256: &wine,
            exec: true,
        },
        RunnerEntry::File {
            rel: "files/lib/a.so.1",
            sha256: &lib,
            exec: false,
        },
        RunnerEntry::Dir {
            rel: "files/share/empty",
        },
        RunnerEntry::File {
            rel: "proton",
            sha256: &proton,
            exec: true,
        },
        RunnerEntry::File {
            rel: "runner.json",
            sha256: &rj,
            exec: false,
        },
    ];
    lines.extend_from_slice(extra);
    lines.sort_by(|a, b| rel(a).as_bytes().cmp(rel(b).as_bytes()));
    let mut h = RunnerHasher::new();
    for l in &lines {
        h.add(l);
    }
    h.finish()
}

fn rel<'a>(e: &RunnerEntry<'a>) -> &'a str {
    match e {
        RunnerEntry::File { rel, .. }
        | RunnerEntry::Link { rel, .. }
        | RunnerEntry::Dir { rel } => rel,
    }
}

fn check(dir: &Path, extra: &[&str]) -> ruya_pack::Outcome {
    let mut a = vec!["runner-check", dir.to_str().unwrap()];
    a.extend_from_slice(extra);
    run(&a)
}

#[test]
fn the_hash_is_the_formula_over_the_tree_and_leaves_its_own_file_out() {
    let t = tempfile::tempdir().unwrap();
    let dir = runner(t.path());
    let o = check(&dir, &[]);
    assert_ok(&o);
    let want = expected_hash(&[]);
    assert_eq!(o.json["hash"], json!(want), "{}", o.text);
    assert_eq!(o.json["entries"], json!(5));
    assert_eq!(
        o.json["runner"],
        json!({"name": "ProtonGE11", "family": "proton-ge", "kind": "proton",
               "version": "GE-Proton11-12", "licence": "BSD-3-Clause AND LGPL-2.1-or-later",
               "source_url": "https://github.com/GloriousEggroll/proton-ge-custom/releases/tag/GE-Proton11-12"})
    );
    assert!(
        !dir.join(HASH_FILE).exists(),
        "nothing is written without --write-hash"
    );

    // --write-hash writes the hash and a line feed; the file is not part of the next hash.
    let w = check(&dir, &["--write-hash"]);
    assert_ok(&w);
    assert_eq!(
        std::fs::read_to_string(dir.join(HASH_FILE)).unwrap(),
        format!("{want}\n")
    );
    let again = check(&dir, &["--write-hash"]);
    assert_eq!(again.json["hash"], json!(want));

    // Any change of the tree changes the hash.
    put(&dir, "files/lib/a.so.1", b"another library");
    assert_ne!(check(&dir, &[]).json["hash"], json!(want));
}

#[test]
fn a_link_is_hashed_as_written_and_may_not_leave_the_runner() {
    let t = tempfile::tempdir().unwrap();
    let dir = runner(t.path());
    let lib = dir.join("files").join("lib");
    #[cfg(unix)]
    let sym = |target: &str, link: &Path| std::os::unix::fs::symlink(target, link).is_ok();
    #[cfg(windows)]
    let sym = |target: &str, link: &Path| std::os::windows::fs::symlink_file(target, link).is_ok();
    if !sym("a.so.1", &lib.join("a.so")) {
        eprintln!("cannot create a symlink on this host");
        return;
    }
    let o = check(&dir, &[]);
    assert_ok(&o);
    assert_eq!(
        o.json["hash"],
        json!(expected_hash(&[RunnerEntry::Link {
            rel: "files/lib/a.so",
            to: "a.so.1"
        }]))
    );
    assert!(sym("../../../outside", &lib.join("escape")));
    let o = check(&dir, &[]);
    assert_eq!(o.exit, 1);
    assert_eq!(problem_codes(&o), ["build.symlink_unsupported"]);
    assert_eq!(o.json["problems"][0]["path"], json!("files/lib/escape"));
}

#[test]
fn a_runner_without_a_valid_runner_json_or_its_entry_is_refused() {
    let t = tempfile::tempdir().unwrap();
    let dir = runner(t.path());

    std::fs::remove_file(dir.join("proton")).unwrap();
    let o = check(&dir, &["--write-hash"]);
    assert_eq!(o.exit, 1, "{}", o.text);
    assert_eq!(problem_codes(&o), ["runner.entry_missing"]);
    assert_eq!(
        o.json["problems"][0]["path"],
        json!("ProtonGE11/runner.json#/entry/proton")
    );
    assert!(
        !dir.join(HASH_FILE).exists(),
        "no hash for a refused runner"
    );
    put(&dir, "proton", PROTON);

    put(
        &dir,
        "runner.json",
        RUNNER_JSON
            .replace("\"arch\"", "\"colour\": 1, \"arch\"")
            .as_bytes(),
    );
    let o = check(&dir, &[]);
    assert_eq!(problem_codes(&o), ["runner.unknown_key"]);
    assert_eq!(
        o.json["problems"][0]["path"],
        json!("ProtonGE11/runner.json#/colour")
    );

    std::fs::remove_file(dir.join("runner.json")).unwrap();
    let o = check(&dir, &[]);
    assert_eq!(problem_codes(&o), ["runner.not_a_file"]);
    std::fs::create_dir(dir.join("runner.json")).unwrap();
    assert_eq!(problem_codes(&check(&dir, &[])), ["runner.not_a_file"]);
}

#[test]
fn record_adds_one_line_per_runner_and_needs_an_id_name() {
    let t = tempfile::tempdir().unwrap();
    let dir = runner(t.path());
    let list = t.path().join("runners.list");
    assert_ok(&check(&dir, &["--record", list.to_str().unwrap()]));
    let other = t.path().join("Wine11");
    put(
        &other,
        "runner.json",
        br#"{"format": 1, "family": "wine", "kind": "wine", "version": "11.0", "arch": "x86_64",
             "entry": {"wine": "bin/wine", "wineserver": "bin/wineserver"}}"#,
    );
    put(&other, "bin/wine", WINE);
    put(&other, "bin/wineserver", WINE);
    assert_ok(&check(&other, &["--record", list.to_str().unwrap()]));
    assert_eq!(
        std::fs::read_to_string(&list).unwrap(),
        "ProtonGE11\tproton-ge\tproton\tGE-Proton11-12\tBSD-3-Clause AND LGPL-2.1-or-later\thttps://github.com/GloriousEggroll/proton-ge-custom/releases/tag/GE-Proton11-12\n\
         Wine11\twine\twine\t11.0\t\t\n"
    );

    // The folder name becomes org.ruyaos.Play.Runner.<Name>: a name that cannot is a usage error.
    let bad = t.path().join("Proton-GE");
    std::fs::rename(&dir, &bad).unwrap();
    let o = check(&bad, &["--record", list.to_str().unwrap()]);
    assert_eq!(o.exit, 2, "{}", o.text);
    assert_ok(&check(&bad, &[])); // without --record any folder name is fine
}
