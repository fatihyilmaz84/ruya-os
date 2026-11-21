//! The two samples under `samples/hello-play-*` (RUY-105): their committed `package/` folders hold
//! the manifest, the art and the licences but no binary. Each test copies the folder to a scratch
//! directory, writes a stub where the build script would put the compiled program, and runs
//! `build`, `validate` and `inspect` through the library, so the samples cannot drift from the
//! rules the console checks with, and nothing here needs a compiler.

mod common;
use common::*;
use std::path::{Path, PathBuf};

fn sample_root(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("samples")
        .join(name)
}

fn copy_tree(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for e in std::fs::read_dir(from).unwrap() {
        let e = e.unwrap();
        let target = to.join(e.file_name());
        if e.file_type().unwrap().is_dir() {
            copy_tree(&e.path(), &target);
        } else {
            std::fs::copy(e.path(), target).unwrap();
        }
    }
}

/// The sample's `package/` folder copied to `<scratch>/pkg`, with `stubs` (paths below the package
/// root) written as stand-ins for what `build.sh` compiles.
fn staged(name: &str, stubs: &[&str]) -> (tempfile::TempDir, PathBuf) {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("pkg");
    copy_tree(&sample_root(name).join("package"), &dir);
    for s in stubs {
        put(&dir, s, b"stub payload, not a real program\n");
    }
    (t, dir)
}

fn png_size(path: &Path) -> (u32, u32) {
    let b = std::fs::read(path).unwrap();
    assert_eq!(&b[..8], b"\x89PNG\r\n\x1a\n", "{}", path.display());
    let be = |i: usize| u32::from_be_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]]);
    (be(16), be(20))
}

/// The programs `build.sh` compiles for the Windows sample (check.exe is the 32-bit one the VM check
/// runs, RUY-902).
const WINE_STUBS: &[&str] = &[
    "payload/hello.exe",
    "payload/setup.exe",
    "payload/check.exe",
];

/// The GE-Proton the image ships (the `version` of `image/play/runners/ProtonGE11/runner.json`):
/// the sample's `min` must be met by it, so its dry run is made against this version.
fn pinned_ge_proton() -> String {
    let runner = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../image/play/runners/ProtonGE11/runner.json");
    let json: serde_json::Value = serde_json::from_slice(&std::fs::read(runner).unwrap()).unwrap();
    json["version"].as_str().unwrap().to_owned()
}

#[test]
fn the_native_sample_builds_validates_and_inspects() {
    let (t, dir) = staged("hello-play-native", &["payload/hello-game"]);
    let (b, zip) = build(&dir, &[]);
    assert_ok(&b);
    let v = run_p(&["validate"], &[&zip]);
    assert_ok(&v);
    let i = run_p(&["inspect"], &[&zip]);
    assert_ok(&i);
    assert_eq!(i.json["id"], "org.example.helloplaynative");
    assert_eq!(i.json["runner"], "native");
    // The folder form is accepted too once play.files exists.
    assert_ok(&run_p(&["validate"], &[&dir]));
    drop(t);
}

#[test]
fn the_windows_sample_builds_validates_and_inspects_with_the_system_ge_proton() {
    let (t, dir) = staged("hello-play-wine", WINE_STUBS);
    let (b, zip) = build(&dir, &[]);
    assert_ok(&b);
    // Without a named system runner the dry run says it did not check; with one it resolves.
    let unchecked = run_p(&["validate"], &[&zip]);
    assert_ok(&unchecked);
    let checked = run(&[
        "validate",
        zip.to_str().unwrap(),
        "--system-proton-ge",
        &pinned_ge_proton(),
    ]);
    assert_ok(&checked);
    assert!(
        checked.json["warnings"]
            .as_array()
            .unwrap()
            .iter()
            .all(|w| w["code"] != "resolve.not_checked"),
        "{}",
        checked.json
    );
    let i = run(&[
        "inspect",
        zip.to_str().unwrap(),
        "--system-proton-ge",
        &pinned_ge_proton(),
    ]);
    assert_ok(&i);
    assert_eq!(i.json["id"], "org.example.helloplaywine");
    assert_eq!(i.json["runner"], "proton");
    drop(t);
}

#[test]
fn the_windows_sample_is_refused_by_a_system_ge_proton_older_than_min() {
    let (_t, dir) = staged("hello-play-wine", WINE_STUBS);
    let (b, zip) = build(&dir, &[]);
    assert_ok(&b);
    let o = run(&[
        "validate",
        zip.to_str().unwrap(),
        "--system-proton-ge",
        "GE-Proton10-9",
    ]);
    assert_eq!(o.exit, 1, "{}", o.json);
    assert!(problem_codes(&o).contains(&"resolve.system_too_old".to_string()));
}

#[test]
fn a_sample_without_its_built_program_is_not_a_package_the_build_accepts() {
    // The committed folder alone has no payload: the manifest names a command that is not there.
    let (_t, dir) = staged("hello-play-native", &[]);
    let (b, _) = build(&dir, &[]);
    assert_eq!(b.exit, 1, "{}", b.json);
}

#[test]
fn the_committed_art_is_the_size_the_guide_says_and_no_binary_is_committed() {
    for name in ["hello-play-native", "hello-play-wine"] {
        let art = sample_root(name).join("package").join("art");
        assert_eq!(png_size(&art.join("icon.png")), (512, 512), "{name} icon");
        assert_eq!(png_size(&art.join("hero.png")), (1920, 1080), "{name} hero");
        assert!(
            sample_root(name).join("make-art.py").is_file(),
            "{name}: the script that made the art"
        );
        // Files committed under package/ are text or the two PNGs: no program, no archive.
        let mut files = Vec::new();
        walk(&sample_root(name).join("package"), &mut files);
        for f in files {
            let name = f.file_name().unwrap().to_string_lossy().to_string();
            let ext = f.extension().map(|e| e.to_string_lossy().to_string());
            assert!(
                matches!(ext.as_deref(), Some("json") | Some("png") | Some("txt")),
                "unexpected file in a sample package folder: {name}"
            );
        }
    }
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
    // A developer who ran build.sh has package/payload and play.files here; they are git-ignored,
    // so the committed folder never has them. Skip them so a local build does not fail the test.
    for e in std::fs::read_dir(dir).unwrap() {
        let e = e.unwrap();
        let p = e.path();
        let n = e.file_name().to_string_lossy().to_string();
        if n == "payload" || n == "play.files" || n == "play.sig" {
            continue;
        }
        if e.file_type().unwrap().is_dir() {
            walk(&p, out);
        } else {
            out.push(p);
        }
    }
}
