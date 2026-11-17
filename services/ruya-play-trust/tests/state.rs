//! The file-backed trust store: atomic writes, root-only mode, and corrupt state as an error.

mod common;

use common::*;
use ruya_play_trust::store::{decode_state, encode_state, MAX_RETIRED};
use ruya_play_trust::{FileTrustStore, IdRecord, MemoryTrustStore, TrustStore};
use std::fs;

fn record(id: &str) -> IdRecord {
    IdRecord {
        id: id.into(),
        key: key().public(),
        first_seen: now(),
        seq: 2,
        retired: vec!["0123456789abcdef0123456789abcdef".into()],
    }
}

#[test]
fn a_missing_file_is_empty_and_changes_round_trip() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("sub/trust.json");
    let mut s = FileTrustStore::open(&path).unwrap();
    assert!(!s.developer_mode().unwrap());
    assert_eq!(s.get("com.example.a").unwrap(), None);
    let r = record("com.example.a");
    s.put(r.clone()).unwrap();
    s.set_developer_mode(true).unwrap();
    assert!(path.exists());
    assert!(!dir.path().join("sub/trust.json.tmp").exists());

    let s = FileTrustStore::open(&path).unwrap();
    assert_eq!(s.get("COM.EXAMPLE.A").unwrap(), Some(r));
    assert!(s.developer_mode().unwrap());
}

#[test]
fn remove_is_saved() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("trust.json");
    let mut s = FileTrustStore::open(&path).unwrap();
    s.put(record("com.example.a")).unwrap();
    assert!(s.remove("com.example.A").unwrap());
    assert!(!s.remove("com.example.a").unwrap());
    assert_eq!(
        FileTrustStore::open(&path)
            .unwrap()
            .get("com.example.a")
            .unwrap(),
        None
    );
}

#[test]
fn corrupt_state_is_an_error_and_the_file_is_left_alone() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("trust.json");
    let mut good = MemoryTrustStore::new();
    good.put(record("com.example.a")).unwrap();
    let text = String::from_utf8(encode_state(&good)).unwrap();
    let key_line = text
        .lines()
        .find(|l| l.contains("\"key\":"))
        .unwrap()
        .to_string();
    let first_seen = text
        .lines()
        .find(|l| l.contains("first_seen"))
        .unwrap()
        .to_string();
    let cases = [
        ("not json", "{".to_string()),
        ("empty", String::new()),
        ("format 2", text.replace("\"format\": 1", "\"format\": 2")),
        (
            "unknown key",
            text.replace("\"developer_mode\"", "\"extra\": 1,\n  \"developer_mode\""),
        ),
        (
            "duplicate key",
            text.replace("\"developer_mode\"", "\"format\": 1,\n  \"developer_mode\""),
        ),
        (
            "bad key",
            text.replace(&key_line, "      \"key\": \"AAAA\","),
        ),
        (
            "key id mismatch",
            text.replace("\"key_id\": \"", "\"key_id\": \"0"),
        ),
        (
            "bad time",
            text.replace(&first_seen, "      \"first_seen\": \"yesterday\","),
        ),
        (
            "bad retired",
            text.replace("0123456789abcdef0123456789abcdef", "nothex"),
        ),
    ];
    for (what, bytes) in cases {
        assert_ne!(bytes, text, "{what}: the case changes nothing");
        fs::write(&path, &bytes).unwrap();
        let e = FileTrustStore::open(&path).unwrap_err();
        assert_eq!(e.code(), "state.corrupt", "{what}");
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            bytes,
            "{what}: the file was rewritten"
        );
    }
}

#[test]
fn two_records_for_one_id_in_any_case_are_corrupt() {
    let mut s = MemoryTrustStore::new();
    s.put(record("com.example.a")).unwrap();
    let text = String::from_utf8(encode_state(&s)).unwrap();
    let start = text.find("    {").unwrap();
    let end = text.rfind("    }").unwrap() + 5;
    let entry = &text[start..end];
    let twice = text.replace(
        entry,
        &format!(
            "{entry},\n{}",
            entry.replace("com.example.a", "com.Example.A")
        ),
    );
    assert_eq!(
        decode_state(twice.as_bytes()).unwrap_err().code(),
        "state.corrupt"
    );
}

#[test]
fn a_failed_write_keeps_the_old_state() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("trust.json");
    let mut s = FileTrustStore::open(&path).unwrap();
    s.put(record("com.example.a")).unwrap();
    // The temporary file's place is taken by a folder: the write fails.
    fs::create_dir(dir.path().join("trust.json.tmp")).unwrap();
    let e = s.put(record("com.example.b")).unwrap_err();
    assert_eq!(e.code(), "state.io");
    assert_eq!(
        s.get("com.example.b").unwrap(),
        None,
        "memory follows the file"
    );
    assert!(s.get("com.example.a").unwrap().is_some());
    assert!(s.set_developer_mode(true).is_err());
    assert!(!s.developer_mode().unwrap());
}

#[test]
fn a_leftover_temporary_file_does_not_affect_the_next_open() {
    let dir = tempfile::tempdir().unwrap();
    let (path, tmp) = (
        dir.path().join("trust.json"),
        dir.path().join("trust.json.tmp"),
    );
    // A crash before the first rename: only the temporary file exists.
    fs::write(&tmp, b"{ half a state").unwrap();
    let mut s = FileTrustStore::open(&path).unwrap();
    assert_eq!(s.get("com.example.a").unwrap(), None);
    s.put(record("com.example.a")).unwrap();
    // A crash before a later rename: the state file is the last good one.
    fs::write(&tmp, b"{ another half").unwrap();
    let mut s = FileTrustStore::open(&path).unwrap();
    assert!(s.get("com.example.a").unwrap().is_some());
    // The next write replaces the leftover and keeps everything.
    s.put(record("com.example.b")).unwrap();
    assert!(!tmp.exists());
    let s = FileTrustStore::open(&path).unwrap();
    assert!(s.get("com.example.a").unwrap().is_some());
    assert!(s.get("com.example.b").unwrap().is_some());
}

#[test]
fn too_many_retired_keys_are_refused() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = FileTrustStore::open(dir.path().join("trust.json")).unwrap();
    let mut r = record("com.example.a");
    r.retired = vec!["0123456789abcdef0123456789abcdef".into(); MAX_RETIRED + 1];
    assert_eq!(s.put(r).unwrap_err().code(), "state.io");
}

#[cfg(unix)]
#[test]
fn the_file_is_root_only() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("trust.json");
    FileTrustStore::open(&path)
        .unwrap()
        .set_developer_mode(false)
        .unwrap();
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
}
