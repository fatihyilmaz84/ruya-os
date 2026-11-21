//! Golden test vectors of the signature encoding (05 §9.2). The keys come from fixed seeds that are
//! printed here on purpose: they are test keys, worth nothing, so another implementation (ruya-pack,
//! RUY-95; the developer chapter) can check itself byte for byte. Ed25519 signing is deterministic,
//! so every value below is exact. If one changes, the format changed: that needs a new envelope
//! `format` (05 §15), not an edit of this file.

use base64ct::{Base64, Encoding};
use ruya_play_format::sha256_hex;
use ruya_play_trust::envelope::{self, Domain};
use ruya_play_trust::statement::{
    BlocklistStatement, PlayStatement, RotationStatement, StoreStatement,
};
use ruya_play_trust::time::parse_utc;
use ruya_play_trust::{
    verify_downloaded, verify_signatures, PackageBytes, PublicKey, SecretKey, StoreKeys, Tier,
};

/// Seeds: bytes 0x00..=0x1f (developer), 0x20..=0x3f (store), 0x40..=0x5f (the developer's next key).
fn seed(first: u8) -> [u8; 32] {
    core::array::from_fn(|i| first + i as u8)
}

const DEV_KEY: &str = "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=";
const DEV_KEY_ID: &str = "56475aa75463474c0285df5dbf2bcab7";
const STORE_KEY: &str = "Kay64UG8yvCyLhqU000LxzYeUm0L/hLIl5S8kyKWbdc=";
const STORE_KEY_ID: &str = "24f6ed6acbfe1009c030d7ca567c33ca";
const NEXT_KEY: &str = "JUO5L/EJVRFHatyDadtt3JM2ZaEZeN2hQE7hBmypVZ0=";
const NEXT_KEY_ID: &str = "03396219237f75a64f12aeb7f39723ab";

const SIGNED_AT: &str = "2026-11-17T12:00:00Z";
/// The package: this `play.json` and an empty `play.files`.
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

const STORE_STATEMENT: &str = concat!(
    r#"{"id":"com.example.mini","build":7,"#,
    r#""play_sig_sha256":"bd24028aa10615f79f97dd7cff3fbec5911afbd06cd51b2ab3718aae033568d8","#,
    r#""signed_at":"2026-11-17T12:00:00Z"}"#
);
const STORE_SIG_SIG: &str =
    "dZ0ule9ibLohiCNqcbJ/vXzbof8ykVC9u8vWyLKtVUVTdW9hVz97XlRZ3rA2wedb12sWnnuhOFbXE3dMj+9TDA==";

const ROTATION_STATEMENT: &str = concat!(
    r#"{"id":"com.example.mini","#,
    r#""old_key":"A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=","#,
    r#""new_key":"JUO5L/EJVRFHatyDadtt3JM2ZaEZeN2hQE7hBmypVZ0=","#,
    r#""seq":1,"signed_at":"2026-11-17T12:00:00Z"}"#
);
const ROTATION_SIG: &str =
    "/Yc83rdD9EgvTr5tRH19UG+AUPxLRUdB+PGSt9Sakwor5TVNK7qpQ93ZeoOpE6LIrz4be1qBNt5cFPIc+XzxCQ==";
/// SHA-256 of `<rotation statement base64>\n<rotation sig base64>`.
const ROTATIONS_SHA256: &str = "e5da24e9888f4598cfa33c0bb251dbd7ffa5ba6ba7459d0464c8b02f2336451d";

/// Build 8, signed by the next key, carrying the rotation above.
const ROTATED_STATEMENT: &str = concat!(
    r#"{"id":"com.example.mini","build":8,"#,
    r#""play_json_sha256":"2f0fd78a91263ee7352df687964d366f9e7323d54cb0412cb1c1d73afeb5bcf1","#,
    r#""play_files_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","#,
    r#""signed_at":"2026-11-17T12:00:00Z","#,
    r#""rotations_sha256":"e5da24e9888f4598cfa33c0bb251dbd7ffa5ba6ba7459d0464c8b02f2336451d"}"#
);
const ROTATED_SIG: &str =
    "tSYqM57nwm0fXHcuX8+XeG4y2EdR0vHEwuOZhjEkEgBXg5C67jb3uhAT2SN1F4dU0g5a7ZJS0KAz2ITJ22U6Bg==";

/// The downloaded blocklist `serial 1\n`, valid 30 days.
const BLOCKLIST_STATEMENT: &str = concat!(
    r#"{"blocklist_sha256":"75847078c62e445b79e8af1b63b43df64b48745cd3d23e196b1d4f38d839331f","#,
    r#""signed_at":"2026-11-17T12:00:00Z","expires":"2026-12-17T12:00:00Z"}"#
);
const BLOCKLIST_SIG: &str =
    "iaoinJOOK+CTagYNE6NEJekqO1I5xuAPrfXiGjqYKyMve//iW4neFOF7psTUUuXiEnpBK7YNkuTOrQkd7+OgAQ==";

fn b64(s: &str) -> String {
    Base64::encode_string(s.as_bytes())
}

/// An envelope written by hand from the constants, compact (any JSON layout verifies).
fn envelope(key: &str, statement: &str, sig: &str) -> String {
    format!(
        r#"{{"format":1,"key":"{key}","statement":"{}","sig":"{sig}"}}"#,
        b64(statement)
    )
}

fn sig_of(sealed: &[u8]) -> String {
    let v: serde_json::Value = serde_json::from_slice(sealed).unwrap();
    v["sig"].as_str().unwrap().to_string()
}

fn t() -> i64 {
    parse_utc(SIGNED_AT).unwrap()
}

#[test]
fn keys_from_the_seeds() {
    for (first, key, id) in [
        (0x00, DEV_KEY, DEV_KEY_ID),
        (0x20, STORE_KEY, STORE_KEY_ID),
        (0x40, NEXT_KEY, NEXT_KEY_ID),
    ] {
        let public = SecretKey::from_seed(&seed(first)).public();
        assert_eq!(public.to_base64(), key);
        assert_eq!(public.key_id(), id);
        assert_eq!(id, &sha256_hex(public.as_bytes())[..32]);
    }
}

#[test]
fn the_statements_are_these_bytes() {
    let dev = PublicKey::from_base64(DEV_KEY).unwrap();
    let next = PublicKey::from_base64(NEXT_KEY).unwrap();
    let play = PlayStatement {
        id: "com.example.mini".into(),
        build: 7,
        play_json_sha256: sha256_hex(PLAY_JSON),
        play_files_sha256: sha256_hex(PLAY_FILES),
        signed_at: t(),
        rotations_sha256: None,
    };
    assert_eq!(play.to_bytes(), PLAY_STATEMENT.as_bytes());
    assert_eq!(
        PlayStatement::parse(PLAY_STATEMENT.as_bytes()).unwrap(),
        play
    );
    let rotation = RotationStatement {
        id: "com.example.mini".into(),
        old_key: dev,
        new_key: next,
        seq: 1,
        signed_at: t(),
    };
    assert_eq!(rotation.to_bytes(), ROTATION_STATEMENT.as_bytes());
    let rotated = PlayStatement {
        build: 8,
        rotations_sha256: Some(ROTATIONS_SHA256.into()),
        ..play
    };
    assert_eq!(rotated.to_bytes(), ROTATED_STATEMENT.as_bytes());
    let store = StoreStatement {
        id: "com.example.mini".into(),
        build: 7,
        play_sig_sha256: "bd24028aa10615f79f97dd7cff3fbec5911afbd06cd51b2ab3718aae033568d8".into(),
        signed_at: t(),
    };
    assert_eq!(store.to_bytes(), STORE_STATEMENT.as_bytes());
    let blocklist = BlocklistStatement {
        blocklist_sha256: sha256_hex(b"serial 1\n"),
        signed_at: t(),
        expires: t() + 30 * 86_400,
    };
    assert_eq!(blocklist.to_bytes(), BLOCKLIST_STATEMENT.as_bytes());
}

#[test]
fn the_signatures_are_these_bytes() {
    let dev = SecretKey::from_seed(&seed(0x00));
    let store = SecretKey::from_seed(&seed(0x20));
    let next = SecretKey::from_seed(&seed(0x40));
    for (key, domain, statement, sig) in [
        (&dev, Domain::PlaySig, PLAY_STATEMENT, PLAY_SIG_SIG),
        (&store, Domain::StoreSig, STORE_STATEMENT, STORE_SIG_SIG),
        (&dev, Domain::Rotation, ROTATION_STATEMENT, ROTATION_SIG),
        (&next, Domain::PlaySig, ROTATED_STATEMENT, ROTATED_SIG),
        (
            &store,
            Domain::Blocklist,
            BLOCKLIST_STATEMENT,
            BLOCKLIST_SIG,
        ),
    ] {
        let sealed = envelope::seal(key, domain, statement.as_bytes());
        assert_eq!(sig_of(&sealed), sig, "{domain:?}");
    }
    assert_eq!(
        sha256_hex(format!("{}\n{ROTATION_SIG}", b64(ROTATION_STATEMENT)).as_bytes()),
        ROTATIONS_SHA256
    );
}

#[test]
fn hand_written_envelopes_verify() {
    let store_keys = StoreKeys::new(vec![PublicKey::from_base64(STORE_KEY).unwrap()]);
    // play.sig as the reference signer writes it (the store countersigns these exact bytes).
    let dev = SecretKey::from_seed(&seed(0x00));
    let play_sig = envelope::seal(&dev, Domain::PlaySig, PLAY_STATEMENT.as_bytes());
    let pretty = format!(
        "{{\n  \"format\": 1,\n  \"key\": \"{DEV_KEY}\",\n  \"statement\": \"{}\",\n  \"sig\": \"{PLAY_SIG_SIG}\"\n}}\n",
        b64(PLAY_STATEMENT)
    );
    assert_eq!(play_sig, pretty.as_bytes());
    assert_eq!(
        sha256_hex(&play_sig),
        "bd24028aa10615f79f97dd7cff3fbec5911afbd06cd51b2ab3718aae033568d8"
    );
    let store_sig = envelope(STORE_KEY, STORE_STATEMENT, STORE_SIG_SIG);
    let sigs = verify_signatures(
        &PackageBytes {
            play_json: PLAY_JSON,
            play_files: PLAY_FILES,
            play_sig: Some(&play_sig),
            store_sig: Some(store_sig.as_bytes()),
        },
        &store_keys,
    )
    .unwrap();
    assert_eq!(sigs.key().unwrap().key_id(), DEV_KEY_ID);
    assert_eq!(
        ruya_play_trust::decide_tier(&sigs, false).unwrap().tier,
        Tier::Official
    );

    // Build 8 by the next key, carrying the rotation (compact JSON this time).
    let rotated = format!(
        r#"{{"format":1,"key":"{NEXT_KEY}","statement":"{}","sig":"{ROTATED_SIG}","rotations":[{}]}}"#,
        b64(ROTATED_STATEMENT),
        envelope(DEV_KEY, ROTATION_STATEMENT, ROTATION_SIG)
    );
    let sigs = verify_signatures(
        &PackageBytes {
            play_json: PLAY_JSON,
            play_files: PLAY_FILES,
            play_sig: Some(rotated.as_bytes()),
            store_sig: None,
        },
        &store_keys,
    )
    .unwrap();
    let dev_sig = sigs.developer.unwrap();
    assert_eq!(dev_sig.key.key_id(), NEXT_KEY_ID);
    assert_eq!(dev_sig.rotations[0].old_key.key_id(), DEV_KEY_ID);
    assert_eq!(dev_sig.rotations[0].seq, 1);

    // The downloaded blocklist.
    let sig = envelope(STORE_KEY, BLOCKLIST_STATEMENT, BLOCKLIST_SIG);
    let (list, statement) =
        verify_downloaded(b"serial 1\n", sig.as_bytes(), &store_keys, t() + 60).unwrap();
    assert_eq!((list.serial, statement.expires), (1, t() + 30 * 86_400));
}

#[test]
fn the_vectors_are_in_the_spec() {
    let spec = std::fs::read_to_string(format!(
        "{}/../../docs/specs/05-play-packages.md",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap();
    for value in [
        DEV_KEY,
        DEV_KEY_ID,
        STORE_KEY,
        PLAY_STATEMENT,
        PLAY_SIG_SIG,
        STORE_STATEMENT,
        STORE_SIG_SIG,
        ROTATION_SIG,
        ROTATIONS_SHA256,
    ] {
        assert!(spec.contains(value), "05 §9.2 does not show {value}");
    }
}
