//! Fixtures: packages generated here (no binary blobs in git) and helpers to run the tool.
#![allow(dead_code)]

use ruya_pack::{png, Context, Outcome};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

pub const NOW: i64 = 1_794_873_600; // 2026-11-17T00:00:00Z

pub fn ctx() -> Context {
    Context::new(NOW, None)
}

pub fn args(a: &[&str]) -> Vec<String> {
    a.iter().map(|s| s.to_string()).collect()
}

pub fn run(a: &[&str]) -> Outcome {
    ruya_pack::run(&args(a), &ctx())
}

pub fn run_with(a: &[&str], c: &Context) -> Outcome {
    ruya_pack::run(&args(a), c)
}

pub fn s(p: &Path) -> String {
    p.to_str().expect("test paths are UTF-8").to_string()
}

pub fn run_p(a: &[&str], paths: &[&Path]) -> Outcome {
    let mut v = args(a);
    v.extend(paths.iter().map(|p| s(p)));
    ruya_pack::run(&v, &ctx())
}

pub fn put(dir: &Path, rel: &str, bytes: &[u8]) {
    let path = rel.split('/').fold(dir.to_path_buf(), |a, c| a.join(c));
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, bytes).unwrap();
}

pub fn problem_codes(o: &Outcome) -> Vec<String> {
    o.json["problems"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["code"].as_str().unwrap().to_string())
        .collect()
}

pub fn assert_ok(o: &Outcome) {
    assert_eq!(o.exit, 0, "{}\n{}", o.text, o.json);
    assert_eq!(o.json["ok"], json!(true));
}

/// The icon the art check accepts.
pub fn icon() -> Vec<u8> {
    png::solid(512, 512, [10, 120, 200, 255])
}

/// A native package: the `init` skeleton with a real icon.
pub fn native(dir: &Path) {
    let o = run_p(&["init"], &[dir]);
    assert_ok(&o);
    put(dir, "art/icon.png", &icon());
}

/// A Windows package that bundles Wine. `edit` changes the manifest; `licence_text` and
/// `source_url` switch the licence duty on and off.
pub fn wine_with(dir: &Path, edit: impl FnOnce(&mut Value), licence_text: bool, source_url: bool) {
    let mut bundled =
        json!({"path": "components/wine", "version": "9.20", "licence": "LGPL-2.1-or-later"});
    if source_url {
        bundled["source_url"] = json!("https://dl.winehq.org/wine/source/");
    }
    let mut m = json!({
        "format": 1,
        "id": "com.example.starhopper",
        "name": {"en": "Star Hopper"},
        "version": "1.4.2",
        "build": 142,
        "art": {"icon": "art/icon.png"},
        "components": [{"id": "wine", "type": "wine", "source": "newest", "min": "9.0",
                        "tested": "9.20", "bundled": bundled}],
        "run": {"runner": "wine", "component": "wine", "command": ["${payload}/StarHopper.exe"]},
        "permissions": {"input": "controllers+keyboard-mouse", "multiarch": true}
    });
    edit(&mut m);
    put(
        dir,
        "play.json",
        serde_json::to_string_pretty(&m).unwrap().as_bytes(),
    );
    put(dir, "art/icon.png", &icon());
    put(dir, "payload/StarHopper.exe", b"MZ not really");
    put(dir, "components/wine/bin/wine", b"\x7fELF not really");
    if licence_text {
        put(
            dir,
            "licences/wine-LGPL-2.1.txt",
            b"GNU LESSER GENERAL PUBLIC LICENSE ...",
        );
    }
}

pub fn wine(dir: &Path) {
    wine_with(dir, |_| {}, true, true);
}

/// Build `dir` into `<dir>.play.zip` next to it.
pub fn build(dir: &Path, extra: &[&str]) -> (Outcome, PathBuf) {
    let out = dir.with_extension("play.zip");
    let mut a = vec!["build", dir.to_str().unwrap(), "-o", out.to_str().unwrap()];
    a.extend_from_slice(extra);
    (run(&a), out)
}

/// A key file in `dir` from a fixed seed; returns its path.
pub fn key_file(dir: &Path, name: &str, first: u8) -> PathBuf {
    let seed: [u8; 32] = core::array::from_fn(|i| first + i as u8);
    let key = ruya_play_trust::SecretKey::from_seed(&seed);
    let path = dir.join(name);
    std::fs::write(&path, ruya_pack::keys::key_file_text(&key)).unwrap();
    path
}

/// A zip written by hand, so a test can put in what `ruya-pack build` never would. Entries are
/// `(name, data, unix mode)`; the mode is stored as the entry's external attributes.
pub fn raw_zip(entries: &[(&str, &[u8], u32)]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut central = Vec::new();
    for (name, data, mode) in entries {
        let offset = out.len() as u32;
        let mut crc = flate2::Crc::new();
        crc.update(data);
        let le32 = |v: &mut Vec<u8>, x: u32| v.extend_from_slice(&x.to_le_bytes());
        let le16 = |v: &mut Vec<u8>, x: u16| v.extend_from_slice(&x.to_le_bytes());
        le32(&mut out, 0x0403_4b50);
        le16(&mut out, 20);
        le16(&mut out, 0);
        le16(&mut out, 0);
        le16(&mut out, 0);
        le16(&mut out, 0x21);
        le32(&mut out, crc.sum());
        le32(&mut out, data.len() as u32);
        le32(&mut out, data.len() as u32);
        le16(&mut out, name.len() as u16);
        le16(&mut out, 0);
        out.extend_from_slice(name.as_bytes());
        out.extend_from_slice(data);
        le32(&mut central, 0x0201_4b50);
        le16(&mut central, (3 << 8) | 20);
        le16(&mut central, 20);
        le16(&mut central, 0);
        le16(&mut central, 0);
        le16(&mut central, 0);
        le16(&mut central, 0x21);
        le32(&mut central, crc.sum());
        le32(&mut central, data.len() as u32);
        le32(&mut central, data.len() as u32);
        le16(&mut central, name.len() as u16);
        le16(&mut central, 0);
        le16(&mut central, 0);
        le16(&mut central, 0);
        le16(&mut central, 0);
        le32(&mut central, mode << 16);
        le32(&mut central, offset);
        central.extend_from_slice(name.as_bytes());
    }
    let cd_off = out.len() as u32;
    let cd_len = central.len() as u32;
    out.extend_from_slice(&central);
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    out.extend_from_slice(&[0, 0, 0, 0]);
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&cd_len.to_le_bytes());
    out.extend_from_slice(&cd_off.to_le_bytes());
    out.extend_from_slice(&[0, 0]);
    out
}
