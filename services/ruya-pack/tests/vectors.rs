//! The golden vectors of `ruya-play-trust/tests/vectors.rs` round-trip through `ruya-pack sign`:
//! the same seeds and inputs give the same signature bytes. If one changes, the envelope format
//! changed (05 section 15), not this test. The constants are copied from that file on purpose: a
//! second implementation (this tool) checks itself against the written-down values.

mod common;
use base64ct::{Base64, Encoding};
use common::*;
use ruya_pack::sign::{sign_bytes, SignInput};
use ruya_play_trust::time::parse_utc;
use ruya_play_trust::SecretKey;
use serde_json::Value;

fn seed(first: u8) -> [u8; 32] {
    core::array::from_fn(|i| first + i as u8)
}

const DEV_KEY: &str = "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=";
const NEXT_KEY: &str = "JUO5L/EJVRFHatyDadtt3JM2ZaEZeN2hQE7hBmypVZ0=";
const SIGNED_AT: &str = "2026-11-17T12:00:00Z";
const PLAY_JSON: &[u8] = b"{\"format\":1}\n";
const PLAY_FILES: &[u8] = b"";

const PLAY_STATEMENT: &str = concat!(
    r#"{"id":"com.example.mini","build":7,"#,
    r#""play_json_sha256":"2f0fd78a91263ee7352df687964d366f9e7323d54cb0412cb1c1d73afeb5bcf1","#,
    r#""play_files_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","#,
    r#""signed_at":"2026-11-17T12:00:00Z"}"#
);
const PLAY_SIG_SIG: &str =
    "WIbdGZBhzNtEb4Yqmd1dBplJoS1fBvvDs1SOtHAdIVPlnpTrrpLH0zlrvsKMWD2JzeEtB6qLzm+YtNGtrHw/DQ==";

const ROTATION_STATEMENT: &str = concat!(
    r#"{"id":"com.example.mini","#,
    r#""old_key":"A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=","#,
    r#""new_key":"JUO5L/EJVRFHatyDadtt3JM2ZaEZeN2hQE7hBmypVZ0=","#,
    r#""seq":1,"signed_at":"2026-11-17T12:00:00Z"}"#
);
const ROTATION_SIG: &str =
    "/Yc83rdD9EgvTr5tRH19UG+AUPxLRUdB+PGSt9Sakwor5TVNK7qpQ93ZeoOpE6LIrz4be1qBNt5cFPIc+XzxCQ==";

const ROTATED_STATEMENT: &str = concat!(
    r#"{"id":"com.example.mini","build":8,"#,
    r#""play_json_sha256":"2f0fd78a91263ee7352df687964d366f9e7323d54cb0412cb1c1d73afeb5bcf1","#,
    r#""play_files_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","#,
    r#""signed_at":"2026-11-17T12:00:00Z","#,
    r#""rotations_sha256":"e5da24e9888f4598cfa33c0bb251dbd7ffa5ba6ba7459d0464c8b02f2336451d"}"#
);
const ROTATED_SIG: &str =
    "tSYqM57nwm0fXHcuX8+XeG4y2EdR0vHEwuOZhjEkEgBXg5C67jb3uhAT2SN1F4dU0g5a7ZJS0KAz2ITJ22U6Bg==";

fn field(env: &Value, k: &str) -> String {
    env[k].as_str().unwrap().to_string()
}

fn statement(env: &Value) -> String {
    String::from_utf8(Base64::decode_vec(&field(env, "statement")).unwrap()).unwrap()
}

#[test]
fn sign_bytes_reproduces_the_golden_play_sig() {
    let dev = SecretKey::from_seed(&seed(0));
    assert_eq!(dev.public().to_base64(), DEV_KEY);
    let sig = sign_bytes(&SignInput {
        key: &dev,
        id: "com.example.mini",
        build: 7,
        play_json: PLAY_JSON,
        play_files: PLAY_FILES,
        signed_at: parse_utc(SIGNED_AT).unwrap(),
        rotate_from: None,
        carried: &[],
        rotation_seq: None,
    })
    .unwrap();
    let env: Value = serde_json::from_slice(&sig).unwrap();
    assert_eq!(field(&env, "key"), DEV_KEY);
    assert_eq!(statement(&env), PLAY_STATEMENT);
    assert_eq!(field(&env, "sig"), PLAY_SIG_SIG);
}

#[test]
fn sign_bytes_reproduces_the_golden_rotation() {
    let (dev, next) = (
        SecretKey::from_seed(&seed(0)),
        SecretKey::from_seed(&seed(0x40)),
    );
    assert_eq!(next.public().to_base64(), NEXT_KEY);
    let sig = sign_bytes(&SignInput {
        key: &next,
        id: "com.example.mini",
        build: 8,
        play_json: PLAY_JSON,
        play_files: PLAY_FILES,
        signed_at: parse_utc(SIGNED_AT).unwrap(),
        rotate_from: Some(&dev),
        carried: &[],
        rotation_seq: None,
    })
    .unwrap();
    let env: Value = serde_json::from_slice(&sig).unwrap();
    assert_eq!(field(&env, "key"), NEXT_KEY);
    assert_eq!(statement(&env), ROTATED_STATEMENT);
    assert_eq!(field(&env, "sig"), ROTATED_SIG);
    let rot = &env["rotations"][0];
    assert_eq!(statement(rot), ROTATION_STATEMENT);
    assert_eq!(field(rot, "sig"), ROTATION_SIG);
}

/// The command line writes what `sign_bytes` produces, for a real package: the key from a file
/// and from `RUYA_PACK_KEY` give the same bytes as the library, signed at the fixed time.
#[test]
fn the_command_writes_the_same_bytes_from_a_key_file_and_from_the_environment() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("g");
    native(&dir);
    assert_ok(&build(&dir, &[]).0);
    let (json, files) = (
        std::fs::read(dir.join("play.json")).unwrap(),
        std::fs::read(dir.join("play.files")).unwrap(),
    );
    let dev = SecretKey::from_seed(&seed(0));
    let want = sign_bytes(&SignInput {
        key: &dev,
        id: "com.example.mygame",
        build: 1,
        play_json: &json,
        play_files: &files,
        signed_at: parse_utc(SIGNED_AT).unwrap(),
        rotate_from: None,
        carried: &[],
        rotation_seq: None,
    })
    .unwrap();

    let key = key_file(t.path(), "dev.key", 0);
    let a = run_p(
        &[
            "sign",
            "--key",
            key.to_str().unwrap(),
            "--signed-at",
            SIGNED_AT,
        ],
        &[&dir],
    );
    assert_ok(&a);
    assert_eq!(std::fs::read(dir.join("play.sig")).unwrap(), want);

    std::fs::remove_file(dir.join("play.sig")).unwrap();
    let env_key = Some(Base64::encode_string(&seed(0)));
    let b = run_with(
        &["sign", dir.to_str().unwrap(), "--signed-at", SIGNED_AT],
        &ruya_pack::Context::new(NOW, env_key),
    );
    assert_ok(&b);
    assert_eq!(std::fs::read(dir.join("play.sig")).unwrap(), want);
}
