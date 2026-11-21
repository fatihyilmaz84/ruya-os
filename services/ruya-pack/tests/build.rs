//! `build`: play.files, links and executable bits, the deterministic zip, what is refused.

mod common;
use common::*;
use ruya_play_format::sha256_hex;
use serde_json::json;

#[test]
fn deterministic() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("g");
    wine(&dir);
    put(&dir, "payload/data/level1.pak", &vec![7u8; 100_000]);
    std::fs::create_dir_all(dir.join("payload").join("saves")).unwrap(); // an empty folder

    let (a, zip_a) = build(&dir, &[]);
    assert_ok(&a);
    let first = std::fs::read(&zip_a).unwrap();

    // Same directory, another output name, a later modification time on every file, the table
    // removed first: the same bytes.
    std::fs::remove_file(dir.join("play.files")).unwrap();
    for f in ["play.json", "payload/data/level1.pak", "art/icon.png"] {
        let p = dir.join(f);
        let bytes = std::fs::read(&p).unwrap();
        std::fs::write(&p, bytes).unwrap();
    }
    let zip_b = t.path().join("other-name.play.zip");
    let b = run(&[
        "build",
        dir.to_str().unwrap(),
        "-o",
        zip_b.to_str().unwrap(),
    ]);
    assert_ok(&b);
    assert_eq!(
        first,
        std::fs::read(&zip_b).unwrap(),
        "two builds of one directory differ"
    );
    assert_eq!(a.json["sha256"], b.json["sha256"]);
    assert_eq!(a.json["sha256"], json!(sha256_hex(&first)));

    // The same holds when deflated, and deflating is a different archive of the same package.
    let (d1, z1) = build(&dir, &["--deflate"]);
    assert_ok(&d1);
    let deflated = std::fs::read(&z1).unwrap();
    let z2 = t.path().join("again.play.zip");
    assert_ok(&run(&[
        "build",
        dir.to_str().unwrap(),
        "-o",
        z2.to_str().unwrap(),
        "--deflate",
    ]));
    assert_eq!(deflated, std::fs::read(&z2).unwrap());
    assert_ne!(deflated, first);
    assert!(deflated.len() < first.len());

    // Timestamps in the archive are 1980-01-01 00:00:00 whatever the files' times are.
    let n = first
        .windows(4)
        .position(|w| w == [0x50, 0x4b, 0x03, 0x04])
        .unwrap();
    assert_eq!(
        &first[n + 10..n + 14],
        &[0, 0, 0x21, 0],
        "DOS time 0, DOS date 1980-01-01"
    );
}

#[test]
fn play_files_is_sorted_hashed_and_records_empty_folders_and_executables() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("g");
    native(&dir);
    put(&dir, "payload/b.txt", b"bee");
    put(&dir, "payload/a.txt", b"ay");
    std::fs::create_dir_all(dir.join("payload").join("saves")).unwrap();
    assert_ok(&build(&dir, &["--exec", "payload/a.txt"]).0);
    let table = std::fs::read_to_string(dir.join("play.files")).unwrap();
    let lines: Vec<&str> = table.lines().collect();
    let paths: Vec<String> = lines
        .iter()
        .map(|l| {
            serde_json::from_str::<serde_json::Value>(l).unwrap()["p"]
                .as_str()
                .unwrap()
                .to_string()
        })
        .collect();
    let mut sorted = paths.clone();
    sorted.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
    assert_eq!(paths, sorted);
    assert!(table.ends_with('\n') && !table.contains("\r"));
    assert!(
        lines.contains(
            &format!(
                "{{\"p\":\"payload/a.txt\",\"t\":\"f\",\"s\":2,\"h\":\"{}\",\"x\":1}}",
                sha256_hex(b"ay")
            )
            .as_str()
        ),
        "{table}"
    );
    assert!(
        lines.contains(
            &format!(
                "{{\"p\":\"payload/b.txt\",\"t\":\"f\",\"s\":3,\"h\":\"{}\"}}",
                sha256_hex(b"bee")
            )
            .as_str()
        ),
        "{table}"
    );
    assert!(lines.contains(&"{\"p\":\"payload/saves\",\"t\":\"d\"}"));
    // run.sh starts with a shebang (and is 0755 on Unix): executable. Roots are not listed.
    assert!(
        lines
            .iter()
            .any(|l| l.contains("payload/run.sh") && l.ends_with(",\"x\":1}")),
        "{table}"
    );
    for root in ["play.json", "play.files", "play.sig"] {
        assert!(!table.contains(&format!("\"p\":\"{root}\"")));
    }
    // licences/ stays an empty folder entry; a folder with content is not listed.
    assert!(
        lines.contains(&"{\"p\":\"licences\",\"t\":\"d\"}"),
        "{table}"
    );
    assert!(!lines.iter().any(|l| l.contains("\"p\":\"payload\",")));
    // installed_mb is computed by the console, never written.
    let manifest = std::fs::read_to_string(dir.join("play.json")).unwrap();
    assert!(!manifest.contains("installed_mb"));
}

#[test]
fn links_become_table_lines_only_with_the_flag_and_only_when_they_stay_inside() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("g");
    wine(&dir);
    let w = dir.join("components").join("wine");
    #[cfg(unix)]
    let sym =
        |target: &str, link: &std::path::Path| std::os::unix::fs::symlink(target, link).is_ok();
    #[cfg(windows)]
    let sym = |target: &str, link: &std::path::Path| {
        std::os::windows::fs::symlink_file(target, link).is_ok()
    };
    if !sym("wine", &w.join("bin").join("wine64")) {
        eprintln!("cannot create a symlink on this host");
        return;
    }
    assert!(sym("../../../../outside", &w.join("bin").join("escape")));
    let (no_flag, zip) = build(&dir, &[]);
    assert_eq!(problem_codes(&no_flag), ["build.symlink", "build.symlink"]);
    assert!(!zip.exists());

    let (escape, zip) = build(&dir, &["--links-as-data"]);
    assert_eq!(
        problem_codes(&escape),
        ["build.symlink_unsupported"],
        "{}",
        escape.text
    );
    assert_eq!(
        escape.json["problems"][0]["path"],
        json!("components/wine/bin/escape")
    );
    assert!(!zip.exists());

    std::fs::remove_file(w.join("bin").join("escape")).unwrap();
    let (ok, zip) = build(&dir, &["--links-as-data"]);
    assert_ok(&ok);
    let table = std::fs::read_to_string(dir.join("play.files")).unwrap();
    assert!(
        table.contains("{\"p\":\"components/wine/bin/wine64\",\"t\":\"l\",\"to\":\"wine\"}"),
        "{table}"
    );
    // The zip holds no link entry; the console's reader sees only files and folders.
    let z = ruya_play_format::validate_zip_file(&zip, &Default::default()).unwrap();
    assert!(z
        .files
        .iter()
        .any(|f| matches!(f, ruya_play_format::FileEntry::Link { to, .. } if to == "wine")));
}

#[test]
fn a_signature_in_the_folder_is_not_built_into_the_zip() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("g");
    native(&dir);
    put(&dir, "play.sig", b"stale");
    let (b, zip) = build(&dir, &[]);
    assert_ok(&b);
    assert_eq!(
        b.json["warnings"][0]["code"],
        json!("build.signature_dropped")
    );
    let z = ruya_play_format::ZipSource::new(std::fs::File::open(zip).unwrap()).unwrap();
    use ruya_play_format::Source;
    assert!(!z.entries().unwrap().iter().any(|e| e.path == "play.sig"));
}

#[test]
fn the_output_may_not_be_inside_the_folder() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("g");
    native(&dir);
    let inside = dir.join("out.play.zip");
    let b = run(&[
        "build",
        dir.to_str().unwrap(),
        "-o",
        inside.to_str().unwrap(),
    ]);
    assert_eq!(problem_codes(&b), ["build.output_inside"]);
    assert!(!inside.exists());
}

#[test]
fn the_default_output_sits_next_to_the_folder_and_a_missing_folder_is_usage() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("Star Hopper.play");
    native(&dir);
    let b = run_p(&["build"], &[&dir]);
    assert_ok(&b);
    assert!(t.path().join("Star Hopper.play.zip").is_file());
    assert_eq!(run(&["build", "no/such/dir"]).exit, 2);
}

#[test]
fn a_built_zip_is_read_by_the_consoles_reader_and_sizes_are_summed_from_the_table() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("g");
    wine(&dir);
    let (b, zip) = build(&dir, &["--deflate"]);
    assert_ok(&b);
    let p = ruya_play_format::validate_zip_file(&zip, &Default::default()).unwrap();
    assert_eq!(p.manifest.id, "com.example.starhopper");
    let sum: u64 = p
        .files
        .iter()
        .map(|f| match f {
            ruya_play_format::FileEntry::File { size, .. } => *size,
            _ => 0,
        })
        .sum();
    assert_eq!(p.installed_bytes, sum);
    assert_eq!(b.json["installed_bytes"], json!(sum));
}
