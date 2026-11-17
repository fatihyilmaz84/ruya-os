//! Signatures (05 §9.2): what verifies, and each way a signature or a signed list is refused with
//! its own code. Every key is generated here.

mod common;

use common::*;
use ruya_play_trust::envelope::{self, Domain};
use ruya_play_trust::keys::sha256_hex;
use ruya_play_trust::statement::{PlayStatement, StoreStatement};
use ruya_play_trust::{
    select_blocklist, sign_blocklist, verify_downloaded, Blocklist, ListSource, Tier, TierReason,
    TrustError,
};
use serde_json::{json, Value};

fn tamper_json(bytes: &[u8], f: impl FnOnce(&mut Value)) -> Vec<u8> {
    let mut v: Value = serde_json::from_slice(bytes).unwrap();
    f(&mut v);
    serde_json::to_vec(&v).unwrap()
}

#[test]
fn a_valid_signature_gives_developer() {
    let (console, dev) = (Console::new(), key());
    let i = console.inspect(&Pkg::minimal().signed(&dev)).unwrap();
    assert_eq!(i.tier.tier, Tier::Developer);
    assert_eq!(i.tier.reason, TierReason::DeveloperSigned);
    assert_eq!(i.signatures.key(), Some(&dev.public()));
    assert_eq!(
        i.signatures.developer.as_ref().unwrap().statement.signed_at,
        now() - 3600
    );
    assert!(i.signatures.store.is_none());
}

#[test]
fn a_valid_store_sig_gives_official() {
    let (console, dev) = (Console::new(), key());
    let pkg = Pkg::minimal().signed(&dev).countersigned(&console.store);
    let i = console.inspect(&pkg).unwrap();
    assert_eq!(i.tier.tier, Tier::Official);
    assert_eq!(i.tier.reason, TierReason::StoreCountersigned);
    assert_eq!(
        i.signatures.store.as_ref().unwrap().key,
        console.store.public()
    );
}

#[test]
fn official_is_passed_to_the_validator_only_from_a_verified_store_sig() {
    // A reserved id is allowed only with `ValidateOptions.official`, which only store.sig sets.
    let (console, dev) = (Console::new(), key());
    let pkg = Pkg::minimal()
        .with_id("org.ruyaos.bundled-game")
        .signed(&dev);
    assert_refused(&console.inspect(&pkg), "id.reserved");
    let i = console.inspect(&pkg.countersigned(&console.store)).unwrap();
    assert_eq!(i.tier.tier, Tier::Official);
    assert_eq!(i.package.manifest.id, "org.ruyaos.bundled-game");
}

#[test]
fn tampered_play_json_is_refused() {
    let (console, dev) = (Console::new(), key());
    let mut pkg = Pkg::minimal().signed(&dev);
    pkg.manifest_after = Some(tamper_json(&pkg.manifest_bytes(), |m| {
        m["name"]["en"] = json!("Settings Plus")
    }));
    let r = console.inspect(&pkg);
    assert_refused(&r, "sig.play_json_changed");
    assert_eq!(r.unwrap_err().problems()[0].path, "play.json");
}

#[test]
fn tampered_play_files_is_refused() {
    let (console, dev) = (Console::new(), key());
    let mut pkg = Pkg::minimal().signed(&dev);
    // The attacker swaps the game and writes a table that matches the new file.
    let mut evil = pkg.clone();
    evil.files[1].1 = b"#!/bin/sh\nrm -rf ~\n".to_vec();
    pkg.files_after = vec![evil.files[1].clone()];
    pkg.table_after = Some(evil.table());
    assert_refused(&console.inspect(&pkg), "sig.play_files_changed");
}

#[test]
fn a_changed_file_is_refused_by_the_format_hash_check() {
    let (console, dev) = (Console::new(), key());
    let mut pkg = Pkg::minimal().signed(&dev);
    pkg.files_after = vec![("payload/game".into(), b"#!/bin/sh\necho ho\n".to_vec())];
    let r = console.inspect(&pkg);
    assert_refused(&r, "package.hash_mismatch");
    assert!(matches!(r, Err(ruya_play_trust::Refusal::Format(_))));
}

#[test]
fn a_signature_for_another_id_is_refused() {
    let (console, dev) = (Console::new(), key());
    let pkg = Pkg::minimal();
    let pkg = pkg.signed_for(&dev, "com.example.other", 7, &[]);
    let r = console.inspect(&pkg);
    assert_refused(&r, "sig.wrong_id");
    assert_eq!(r.unwrap_err().problems()[0].path, "play.sig");
}

#[test]
fn a_signature_for_another_build_is_refused() {
    let (console, dev) = (Console::new(), key());
    let pkg = Pkg::minimal().signed_for(&dev, "com.example.mini", 6, &[]);
    assert_refused(&console.inspect(&pkg), "sig.wrong_build");
}

#[test]
fn a_wrong_key_for_a_known_id_is_refused() {
    let (mut console, first, second) = (Console::new(), key(), key());
    let i = console.inspect(&Pkg::minimal().signed(&first)).unwrap();
    ruya_play_trust::record_install(
        &mut console.trust,
        "com.example.mini",
        Some(&first.public()),
        &i.continuity,
        now(),
    )
    .unwrap();
    let r = console.inspect(&Pkg::minimal().signed(&second));
    assert_refused(&r, "trust.different_developer");
}

#[test]
fn a_bad_signature_is_an_error_not_unverified() {
    for developer_mode in [false, true] {
        let (mut console, dev) = (Console::new(), key());
        ruya_play_trust::TrustStore::set_developer_mode(&mut console.trust, developer_mode)
            .unwrap();
        let mut pkg = Pkg::minimal().signed(&dev);
        // Flip one bit of the signature.
        pkg.play_sig = Some(tamper_json(pkg.play_sig.as_ref().unwrap(), |v| {
            let sig = v["sig"].as_str().unwrap();
            let flipped = if sig.starts_with('A') { "B" } else { "A" };
            v["sig"] = json!(format!("{flipped}{}", &sig[1..]));
        }));
        assert_refused(&console.inspect(&pkg), "sig.bad_signature");
    }
}

#[test]
fn a_changed_statement_breaks_the_signature() {
    use base64ct::{Base64, Encoding};
    let (console, dev) = (Console::new(), key());
    let mut pkg = Pkg::minimal().signed(&dev);
    pkg.play_sig = Some(tamper_json(pkg.play_sig.as_ref().unwrap(), |v| {
        let st = Base64::decode_vec(v["statement"].as_str().unwrap()).unwrap();
        let st = tamper_json(&st, |s| s["build"] = json!(8));
        v["statement"] = json!(Base64::encode_string(&st));
    }));
    assert_refused(&console.inspect(&pkg), "sig.bad_signature");
}

#[test]
fn a_signature_made_for_another_purpose_does_not_verify() {
    // The same statement bytes signed as a store countersignature are not a play.sig.
    let (console, dev) = (Console::new(), key());
    let pkg = Pkg::minimal();
    let statement = PlayStatement {
        id: pkg.id(),
        build: pkg.build(),
        play_json_sha256: sha256_hex(&pkg.manifest_bytes()),
        play_files_sha256: sha256_hex(&pkg.table()),
        signed_at: now(),
        rotations_sha256: None,
    };
    let mut wrong = pkg.clone();
    wrong.play_sig = Some(envelope::seal(
        &dev,
        Domain::StoreSig,
        &statement.to_bytes(),
    ));
    assert_refused(&console.inspect(&wrong), "sig.bad_signature");
    let mut right = pkg;
    right.play_sig = Some(envelope::seal(&dev, Domain::PlaySig, &statement.to_bytes()));
    assert!(console.inspect(&right).is_ok());
}

#[test]
fn a_play_sig_with_a_duplicate_key_is_refused() {
    let (console, dev) = (Console::new(), key());
    let mut pkg = Pkg::minimal().signed(&dev);
    let text = String::from_utf8(pkg.play_sig.clone().unwrap()).unwrap();
    let doubled = text.replacen("\"format\": 1,", "\"format\": 1,\n  \"format\": 1,", 1);
    assert_ne!(text, doubled);
    pkg.play_sig = Some(doubled.into_bytes());
    let r = console.inspect(&pkg);
    assert_refused(&r, "sig.duplicate_key");
    // A duplicate inside the statement is refused too.
    let statement = br#"{"id":"com.example.mini","id":"com.example.mini","build":7}"#;
    assert!(matches!(
        PlayStatement::parse(statement),
        Err(TrustError::DuplicateKey { .. })
    ));
}

#[test]
fn malformed_play_sigs_are_refused() {
    let (console, dev) = (Console::new(), key());
    let good = Pkg::minimal().signed(&dev);
    type Tamper = Box<dyn Fn(&mut Value)>;
    let cases: Vec<(&str, Tamper)> = vec![
        ("unknown key", Box::new(|v| v["signer"] = json!("me"))),
        (
            "missing sig",
            Box::new(|v| {
                v.as_object_mut().unwrap().remove("sig");
            }),
        ),
        ("short key", Box::new(|v| v["key"] = json!("AAAA"))),
        ("not base64", Box::new(|v| v["sig"] = json!("!!!!"))),
        ("format 0", Box::new(|v| v["format"] = json!(0))),
        ("format text", Box::new(|v| v["format"] = json!("1"))),
        (
            "rotations not a list",
            Box::new(|v| v["rotations"] = json!({})),
        ),
    ];
    for (what, f) in cases {
        let mut pkg = good.clone();
        pkg.play_sig = Some(tamper_json(good.play_sig.as_ref().unwrap(), f));
        let r = console.inspect(&pkg);
        assert_eq!(code_of(&r), "sig.malformed", "{what}");
    }
    for bytes in [
        &b"not json"[..],
        &b"[]"[..],
        &b"\xff\xfe"[..],
        &[b'['; 64][..],
    ] {
        let mut pkg = good.clone();
        pkg.play_sig = Some(bytes.to_vec());
        assert_eq!(
            code_of(&console.inspect(&pkg)),
            "sig.malformed",
            "{bytes:?}"
        );
    }
    let mut pkg = good.clone();
    pkg.play_sig = Some(vec![b' '; 64 * 1024 + 1]);
    assert_eq!(code_of(&console.inspect(&pkg)), "sig.malformed", "too big");
}

#[test]
fn a_play_sig_from_a_newer_format_says_so() {
    let (console, dev) = (Console::new(), key());
    let mut pkg = Pkg::minimal().signed(&dev);
    pkg.play_sig = Some(tamper_json(pkg.play_sig.as_ref().unwrap(), |v| {
        v["format"] = json!(2)
    }));
    assert_refused(&console.inspect(&pkg), "sig.format_too_new");
}

#[test]
fn a_weak_key_is_refused() {
    use base64ct::{Base64, Encoding};
    let (console, dev) = (Console::new(), key());
    let mut pkg = Pkg::minimal().signed(&dev);
    let mut identity = [0u8; 32];
    identity[0] = 1;
    pkg.play_sig = Some(tamper_json(pkg.play_sig.as_ref().unwrap(), |v| {
        v["key"] = json!(Base64::encode_string(&identity));
    }));
    assert_refused(&console.inspect(&pkg), "sig.weak_key");
}

#[test]
fn a_store_sig_by_a_key_that_is_not_pinned_is_ignored() {
    // A third-party store's countersignature is not RuyaOS's: the package stays `developer`.
    let (console, dev, other_store) = (Console::new(), key(), key());
    let pkg = Pkg::minimal().signed(&dev).countersigned(&other_store);
    let i = console.inspect(&pkg).unwrap();
    assert_eq!(i.tier.tier, Tier::Developer);
    assert!(i.signatures.store.is_none());
    assert_eq!(
        i.signatures.unpinned_store_key,
        Some(other_store.public().key_id())
    );
    // A reserved id stays refused: an ignored store.sig does not make it official.
    let reserved = Pkg::minimal()
        .with_id("org.ruyaos.bundled-game")
        .signed(&dev)
        .countersigned(&other_store);
    assert_refused(&console.inspect(&reserved), "id.reserved");
    // A broken one is still an error, not ignored.
    let mut broken = pkg;
    broken.store_sig = Some(b"{}".to_vec());
    assert_refused(&console.inspect(&broken), "sig.malformed");
}

#[test]
fn a_store_sig_without_a_play_sig_is_refused() {
    let (console, dev) = (Console::new(), key());
    let mut pkg = Pkg::minimal().signed(&dev).countersigned(&console.store);
    pkg.play_sig = None;
    assert_refused(&console.inspect(&pkg), "store_sig.without_play_sig");
}

#[test]
fn a_store_sig_over_another_play_sig_is_refused() {
    let (console, dev, other) = (Console::new(), key(), key());
    let countersigned = Pkg::minimal().signed(&dev).countersigned(&console.store);
    // Same package, re-signed by another key: the store never reviewed that play.sig.
    let mut pkg = Pkg::minimal().signed(&other);
    pkg.store_sig = countersigned.store_sig;
    assert_refused(&console.inspect(&pkg), "store_sig.play_sig_changed");
}

#[test]
fn a_store_sig_for_another_id_or_build_is_refused() {
    let (console, dev) = (Console::new(), key());
    let pkg = Pkg::minimal().signed(&dev);
    let sig = pkg.play_sig.clone().unwrap();
    for (id, build, code) in [
        ("com.example.other", 7, "sig.wrong_id"),
        ("com.example.mini", 8, "sig.wrong_build"),
    ] {
        let statement = StoreStatement {
            id: id.into(),
            build,
            play_sig_sha256: sha256_hex(&sig),
            signed_at: now(),
        };
        let mut p = pkg.clone();
        p.store_sig = Some(envelope::seal(
            &console.store,
            Domain::StoreSig,
            &statement.to_bytes(),
        ));
        let r = console.inspect(&p);
        assert_refused(&r, code);
        assert_eq!(r.unwrap_err().problems()[0].path, "store.sig");
    }
}

#[test]
fn a_store_sig_with_rotations_is_refused() {
    let (console, dev) = (Console::new(), key());
    let mut pkg = Pkg::minimal().signed(&dev).countersigned(&console.store);
    pkg.store_sig = Some(tamper_json(pkg.store_sig.as_ref().unwrap(), |v| {
        v["rotations"] = json!([])
    }));
    assert_refused(&console.inspect(&pkg), "sig.malformed");
}

// The downloaded blocklist (05 §9.2): its own signature by the store key, and `expires`.

const LIST: &[u8] = b"serial 5\n[packages]\nkey 0123456789abcdef0123456789abcdef A stolen key\n";
const IMAGE_LIST: &[u8] =
    b"serial 2\n[packages]\nkey fedcba9876543210fedcba9876543210 From the image\n";

#[test]
fn an_expired_revocation_list_is_refused() {
    let console = Console::new();
    let sig = sign_blocklist(&console.store, LIST, now() - 40 * 86_400, now() - 1);
    let r = verify_downloaded(LIST, &sig, &console.store_keys, now());
    assert_eq!(r.unwrap_err().code(), "blocklist.expired");
    // At the second it expires it is already stale.
    let sig = sign_blocklist(&console.store, LIST, now() - 86_400, now());
    assert_eq!(
        verify_downloaded(LIST, &sig, &console.store_keys, now())
            .unwrap_err()
            .code(),
        "blocklist.expired"
    );
    let sig = sign_blocklist(&console.store, LIST, now() - 86_400, now() + 1);
    assert_eq!(
        verify_downloaded(LIST, &sig, &console.store_keys, now())
            .unwrap()
            .0
            .serial,
        5
    );
}

#[test]
fn a_revocation_list_signed_by_a_non_store_key_is_refused() {
    let (console, other) = (Console::new(), key());
    let sig = sign_blocklist(&other, LIST, now() - 60, now() + 86_400);
    let r = verify_downloaded(LIST, &sig, &console.store_keys, now());
    assert_eq!(r.unwrap_err().code(), "blocklist.not_store_key");
}

#[test]
fn a_revocation_list_that_is_not_the_signed_text_is_refused() {
    let console = Console::new();
    let sig = sign_blocklist(&console.store, LIST, now() - 60, now() + 86_400);
    let shorter = b"serial 5\n[packages]\n";
    let r = verify_downloaded(shorter, &sig, &console.store_keys, now());
    assert_eq!(r.unwrap_err().code(), "blocklist.changed");
    // A package signature is not a list signature.
    let wrong = envelope::seal(&console.store, Domain::StoreSig, b"{}");
    assert_eq!(
        verify_downloaded(LIST, &wrong, &console.store_keys, now())
            .unwrap_err()
            .code(),
        "sig.bad_signature"
    );
}

#[test]
fn the_image_blocklist_is_used_when_the_downloaded_copy_is_expired() {
    let console = Console::new();
    let image = Blocklist::parse(IMAGE_LIST).unwrap();
    let sig = sign_blocklist(&console.store, LIST, now() - 40 * 86_400, now() - 86_400);
    let s = select_blocklist(
        Some(IMAGE_LIST),
        Some((LIST, &sig)),
        &console.store_keys,
        now(),
    )
    .unwrap();
    assert_eq!(s.source, ListSource::Image);
    assert_eq!(s.list, image);
    assert_eq!(s.set_aside.unwrap().code(), "blocklist.expired");
}
