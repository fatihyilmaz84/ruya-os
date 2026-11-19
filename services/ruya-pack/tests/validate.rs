//! `validate`: the rules of the crates, the licence duty, and the shape of the result.

mod common;
use common::*;
use ruya_pack::png;
use serde_json::json;

#[test]
fn the_init_skeleton_fails_only_on_its_placeholder_icon() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("game");
    assert_ok(&run_p(&["init"], &[&dir]));
    // The skeleton has no play.files yet: build writes it, and its own validate is the check.
    let (built, _) = build(&dir, &[]);
    assert_eq!(built.exit, 1, "{}", built.text);
    assert_eq!(problem_codes(&built), ["art.too_small"]);
    let p = &built.json["problems"][0];
    assert_eq!(p["path"], json!("art/icon.png"));
    assert!(p["fix"].as_str().unwrap().contains("512x512"), "{p}");
    // No zip is left behind for a package that fails.
    assert!(!t.path().join("game.play.zip").exists());
    assert!(!t.path().join("game.play.zip.tmp").exists());
    // The folder form says the same through validate.
    let v = run_p(&["validate"], &[&dir]);
    assert_eq!(problem_codes(&v), ["art.too_small"]);
}

#[test]
fn a_filled_in_package_passes_and_reports_its_facts() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("game");
    native(&dir);
    assert_ok(&build(&dir, &[]).0);
    let v = run_p(&["validate", "--json"], &[&dir]);
    assert_ok(&v);
    assert_eq!(v.json["id"], json!("com.example.mygame"));
    assert_eq!(v.json["form"], json!("folder"));
    assert_eq!(v.json["art"][0]["slot"], json!("icon"));
    assert_eq!(v.json["art"][0]["ok"], json!(true));
    assert!(v.json["installed_bytes"].as_u64().unwrap() > 0);
    // A folder with a changed file no longer matches its table.
    put(&dir, "payload/run.sh", b"#!/bin/sh\necho changed\n");
    let bad = run_p(&["validate"], &[&dir]);
    assert_eq!(bad.exit, 1);
    assert!(problem_codes(&bad)
        .iter()
        .any(|c| c == "package.size_mismatch" || c == "package.hash_mismatch"));
}

#[test]
fn every_problem_carries_code_path_message_and_fix() {
    let o = run(&["validate", "--json", "no/such/place"]);
    assert_eq!(o.exit, 3);
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("empty");
    std::fs::create_dir(&dir).unwrap();
    let o = run_p(&["validate", "--json"], &[&dir]);
    assert_eq!(o.exit, 1);
    assert_eq!(o.json["ok"], json!(false));
    for p in o.json["problems"].as_array().unwrap() {
        for k in ["code", "path", "message", "fix"] {
            assert!(p[k].is_string(), "{k} in {p}");
        }
        assert!(!p["fix"].as_str().unwrap().is_empty());
        assert!(!p["code"].as_str().unwrap().is_empty());
    }
    assert!(problem_codes(&o).contains(&"package.no_manifest".to_string()));
}

#[test]
fn a_real_symlink_in_a_folder_fails() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("game");
    native(&dir);
    let link = dir.join("payload").join("link");
    #[cfg(unix)]
    let made = std::os::unix::fs::symlink("run.sh", &link).is_ok();
    #[cfg(windows)]
    let made = std::os::windows::fs::symlink_file("run.sh", &link).is_ok();
    if !made {
        // Windows without the symlink privilege: the zip form below covers the same rule.
        eprintln!("cannot create a symlink on this host; the zip-form test covers entry.symlink");
        return;
    }
    let v = run_p(&["validate"], &[&dir]);
    assert_eq!(v.exit, 1);
    assert!(
        problem_codes(&v).contains(&"entry.symlink".to_string()),
        "{}",
        v.text
    );
    let p = v.json["problems"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["code"] == "entry.symlink")
        .unwrap();
    assert_eq!(p["path"], json!("payload/link"));
    assert!(p["fix"].as_str().unwrap().contains("--links-as-data"));
    // build refuses it too, with its own code, and writes nothing.
    let (b, zip) = build(&dir, &[]);
    assert_eq!(b.exit, 1);
    assert_eq!(problem_codes(&b), ["build.symlink"]);
    assert!(!zip.exists());
}

#[test]
fn symlink_traversal_and_case_collision_in_a_zip_fail_with_their_codes() {
    let t = tempfile::tempdir().unwrap();
    let zip = t.path().join("bad.play.zip");
    std::fs::write(
        &zip,
        raw_zip(&[
            ("play.json", b"{}", 0o100644),
            ("play.files", b"", 0o100644),
            ("payload/link", b"run.sh", 0o120777), // a real symlink entry
            ("payload/../escape", b"x", 0o100644),
            ("payload/Game.dat", b"a", 0o100644),
            ("payload/game.dat", b"b", 0o100644),
        ]),
    )
    .unwrap();
    let v = run_p(&["validate", "--json"], &[&zip]);
    assert_eq!(v.exit, 1);
    let codes = problem_codes(&v);
    for want in ["entry.symlink", "path.traversal", "path.case_collision"] {
        assert!(codes.contains(&want.to_string()), "{want} in {codes:?}");
    }
    let by = |code: &str| {
        v.json["problems"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["code"] == code)
            .unwrap()
            .clone()
    };
    assert_eq!(by("entry.symlink")["path"], json!("payload/link"));
    assert!(by("entry.symlink")["fix"]
        .as_str()
        .unwrap()
        .contains("--links-as-data"));
    assert!(by("path.traversal")["path"]
        .as_str()
        .unwrap()
        .contains(".."));
    assert!(by("path.case_collision")["fix"]
        .as_str()
        .unwrap()
        .contains("letter case"));
}

#[test]
fn a_bundled_wine_needs_its_licence_text_and_a_source() {
    let t = tempfile::tempdir().unwrap();

    // No licence text under licences/.
    let a = t.path().join("a");
    wine_with(&a, |_| {}, false, true);
    let (b, _) = build(&a, &[]);
    assert_eq!(problem_codes(&b), ["licence.text_missing"]);
    let p = &b.json["problems"][0];
    assert_eq!(p["path"], json!("/components/0/bundled/licence"));
    assert!(p["message"].as_str().unwrap().contains("LGPL-2.1-or-later"));
    assert!(p["fix"].as_str().unwrap().contains("licences/"));

    // Text, but LGPL code without a source_url.
    let c = t.path().join("c");
    wine_with(&c, |_| {}, true, false);
    let (b, _) = build(&c, &[]);
    assert_eq!(problem_codes(&b), ["licence.source_missing"]);
    assert_eq!(
        b.json["problems"][0]["path"],
        json!("/components/0/bundled/source_url")
    );

    // The source itself under licences/ also satisfies the duty.
    // A licences/ file that merely has "source" in its name is not the source.
    put(
        &c,
        "licences/source-notes.txt",
        b"we have the source somewhere",
    );
    let (b, _) = build(&c, &[]);
    assert_eq!(problem_codes(&b), ["licence.source_missing"]);
    put(&c, "sources/wine-9.20.tar.xz", b"source");
    let (b, _) = build(&c, &[]);
    assert_ok(&b);

    // Both: ok, and a permissive licence needs no source.
    let d = t.path().join("d");
    wine_with(&d, |_| {}, true, true);
    assert_ok(&build(&d, &[]).0);
    let e = t.path().join("e");
    wine_with(
        &e,
        |m| {
            m["components"][0]["bundled"] =
                json!({"path": "components/wine", "version": "9.20", "licence": "MIT"})
        },
        false,
        false,
    );
    put(&e, "licences/MIT.txt", b"MIT licence");
    assert_ok(&build(&e, &[]).0);
}

#[test]
fn art_problems_name_the_file_and_the_fix() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("g");
    wine_with(
        &dir,
        |m| m["art"]["hero"] = json!("art/hero.png"),
        true,
        true,
    );
    put(
        &dir,
        "art/hero.png",
        &png::solid(2400, 1200, [1, 2, 3, 255]),
    );
    let (b, _) = build(&dir, &[]);
    assert_eq!(problem_codes(&b), ["art.aspect_ratio"]);
    let p = &b.json["problems"][0];
    assert_eq!(p["path"], json!("art/hero.png"));
    assert!(p["message"].as_str().unwrap().contains("16:9"));
    assert!(p["fix"].as_str().unwrap().contains("16:9"));
    // The report lists the art that passed and the art that did not.
    let v = run_p(&["validate", "--json"], &[&dir]);
    let art = v.json["art"].as_array().unwrap();
    assert_eq!(
        art.iter().find(|a| a["slot"] == "icon").unwrap()["ok"],
        json!(true)
    );
    assert_eq!(
        art.iter().find(|a| a["slot"] == "hero").unwrap()["code"],
        json!("art.aspect_ratio")
    );
}

#[test]
fn usage_errors_exit_two_and_io_errors_three() {
    for a in [
        &["frobnicate"][..],
        &["validate"],
        &["validate", "a", "b"],
        &["validate", "--nope", "x"],
        &[],
    ] {
        let o = run(a);
        assert_eq!(o.exit, 2, "{a:?}: {}", o.text);
        assert_eq!(o.json["ok"], json!(false));
        assert_eq!(o.json["problems"][0]["code"], json!("usage.error"));
        assert!(o.json["problems"][0]["fix"]
            .as_str()
            .unwrap()
            .contains("--help"));
    }
    let o = run(&["validate", "--system-runner", "wine", "x"]);
    assert_eq!(o.exit, 2);
    let o = run(&["inspect", "no/such/file.play.zip"]);
    assert_eq!(o.exit, 3);
    assert_eq!(o.json["problems"][0]["code"], json!("io.error"));
    assert_eq!(run(&["--help"]).exit, 0);
    assert_eq!(run(&["validate", "--help"]).exit, 0);
}

#[test]
fn a_zip_over_four_gib_and_a_file_over_four_gib_warn_about_fat32() {
    use ruya_play_format::{FileEntry, Package};
    let m = {
        let t = tempfile::tempdir().unwrap();
        let dir = t.path().join("g");
        native(&dir);
        let (b, zip) = build(&dir, &[]);
        assert_ok(&b);
        ruya_play_format::validate_zip_file(&zip, &Default::default())
            .unwrap()
            .manifest
    };
    let pkg = Package {
        manifest: m,
        files: vec![FileEntry::File {
            path: "payload/huge.bin".into(),
            size: 5_000_000_000,
            sha256: "0".repeat(64),
            executable: false,
        }],
        installed_bytes: 5_000_000_000,
    };
    let mut w = Vec::new();
    ruya_pack::validate::fat32(&pkg, 4_294_967_296, &mut w);
    assert_eq!(w.len(), 2);
    assert!(w
        .iter()
        .all(|x| x.code == "size.fat32" && x.fix.contains("exFAT")));
    assert_eq!(w[0].path, "payload/huge.bin");
    let mut none = Vec::new();
    ruya_pack::validate::fat32(&pkg, 4_294_967_295, &mut none);
    assert_eq!(
        none.len(),
        1,
        "only the file: a zip of 4 GiB - 1 still fits"
    );
}

#[test]
fn licence_files_match_by_whole_words_not_by_substring() {
    let t = tempfile::tempdir().unwrap();
    // "wine" is inside "swineherd" and "winery" but names neither.
    let a = t.path().join("a");
    wine_with(&a, |_| {}, false, true);
    put(&a, "licences/swineherd.txt", b"x");
    put(&a, "licences/winery/readme.txt", b"x");
    let (b, _) = build(&a, &[]);
    assert_eq!(problem_codes(&b), ["licence.text_missing"]);
    // A folder named for the component counts, and so does the licence id as a file name.
    put(&a, "licences/Wine/COPYING.LIB", b"x");
    assert_ok(&build(&a, &[]).0);
    let c = t.path().join("c");
    wine_with(&c, |_| {}, false, true);
    put(&c, "licences/LGPL-2.1-or-later.txt", b"x");
    assert_ok(&build(&c, &[]).0);
}

#[test]
fn a_reserved_top_level_name_is_refused_with_its_own_fix_but_a_nested_one_is_not() {
    // The console writes .ref, launcher and share into the installed app (RUY-870).
    for rel in [".ref/x", "launcher/bin/a", "share/x"] {
        let t = tempfile::tempdir().unwrap();
        let dir = t.path().join("game");
        native(&dir);
        put(&dir, rel, b"x");
        let (built, _) = build(&dir, &[]);
        assert_eq!(built.exit, 1, "{rel}: {}", built.text);
        let p = built.json["problems"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["code"] == json!("table.reserved_top_level"))
            .unwrap_or_else(|| panic!("{rel}: {}", built.json));
        assert_eq!(p["path"], json!(rel));
        assert!(p["fix"].as_str().unwrap().contains("another folder"), "{p}");
    }
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("game");
    native(&dir);
    put(&dir, "payload/share/x", b"x");
    put(&dir, "payload/.ref/x", b"x");
    assert_ok(&build(&dir, &[]).0);
}
