//! init -> fill -> build -> validate -> sign -> inspect, and the console's own verifier accepts the
//! result. Rotation, folder and zip forms, and the tier a tool-signed package gets.

mod common;
use common::*;
use ruya_play_format::{FolderSource, Source, ZipSource};
use ruya_play_trust::{
    inspect, record_install, Continuity, IdRecord, ListCheck, MemoryTrustStore, StoreKeys, Tier,
    TrustStore,
};
use serde_json::json;
use std::path::Path;

/// The console's inspect step, with developer mode as given.
fn console(
    source: &dyn Source,
    store: &MemoryTrustStore,
) -> Result<ruya_play_trust::Inspection, ruya_play_trust::Refusal> {
    let keys = StoreKeys::none();
    inspect(
        source,
        &ruya_play_trust::Context {
            store_keys: &keys,
            trust: store,
            blocklist: ListCheck::NotChecked,
            runner_hashes: &[],
            verify_content: true,
        },
    )
}

fn zip_source(p: &Path) -> ZipSource<std::fs::File> {
    ZipSource::new(std::fs::File::open(p).unwrap()).unwrap()
}

#[test]
fn init_fill_build_validate_sign_inspect() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("game");
    native(&dir); // init, then the real icon in place of the placeholder

    let (b, zip) = build(&dir, &[]);
    assert_ok(&b);
    assert_ok(&run_p(&["validate"], &[&zip]));

    let kg = run(&["keygen", t.path().join("dev").to_str().unwrap(), "--json"]);
    assert_ok(&kg);
    let key = t.path().join("dev.key");
    assert!(key.is_file() && t.path().join("dev.pub").is_file());

    let s = run_p(&["sign", "--key", key.to_str().unwrap()], &[&zip]);
    assert_ok(&s);
    assert_eq!(s.json["key_id"], kg.json["key_id"]);
    assert_eq!(s.json["tier"], json!("developer"));

    // The console's verifier accepts the output: developer tier, the key, no developer mode needed.
    let store = MemoryTrustStore::new();
    let i = console(&zip_source(&zip), &store).unwrap_or_else(|e| panic!("{:?}", e.problems()));
    assert_eq!(i.tier.tier, Tier::Developer);
    assert_eq!(
        i.signatures.key().unwrap().key_id(),
        kg.json["key_id"].as_str().unwrap()
    );
    assert_eq!(i.package.manifest.id, "com.example.mygame");
    assert!(matches!(i.continuity, Continuity::FirstSight { seq: 0 }));

    // The signed zip still passes validate, and inspect says what the console says.
    assert_ok(&run_p(&["validate"], &[&zip]));
    let o = run_p(&["inspect", "--json"], &[&zip]);
    assert_ok(&o);
    assert_eq!(o.json["tier"], json!("developer"));
    assert_eq!(o.json["signer_key_id"], kg.json["key_id"]);
    assert_eq!(o.json["name"], json!("My Game"));
    assert_eq!(
        o.json["permissions"][0]["words"],
        json!("Uses controllers, keyboard and mouse")
    );
    assert_eq!(o.json["permissions"][0]["risk"], json!("low"));
    let text = run_p(&["inspect"], &[&zip]).text;
    assert!(text.contains("Plays sound, uses graphics"), "{text}");
    assert!(text.contains("tier developer"), "{text}");
    assert!(text.contains("icon: ok"), "{text}");

    // Changing the manifest after signing breaks the signature the console checks.
    let unsigned = t.path().join("unsigned");
    native(&unsigned);
    assert_ok(&build(&unsigned, &[]).0);
    let wrong = run_p(&["sign", "--key", key.to_str().unwrap()], &[&unsigned]);
    assert_ok(&wrong);
    put(
        &unsigned,
        "play.json",
        &std::fs::read(unsigned.join("play.json"))
            .unwrap()
            .iter()
            .chain(b"\n")
            .copied()
            .collect::<Vec<u8>>(),
    );
    let refused = console(&FolderSource::new(&unsigned), &store).expect_err("must be refused");
    assert_eq!(refused.problems()[0].code, "sig.play_json_changed");
    let after = run_p(&["inspect"], &[&unsigned]);
    assert_eq!(after.exit, 1);
    assert_eq!(problem_codes(&after), ["sig.play_json_changed"]);
}

#[test]
fn an_unsigned_package_is_unverified_and_the_folder_form_signs_too() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("game");
    native(&dir);
    assert_ok(&build(&dir, &[]).0);
    let o = run_p(&["inspect", "--json"], &[&dir]);
    assert_ok(&o);
    assert_eq!(o.json["tier"], json!("unverified"));
    assert!(o.json["signer_key_id"].is_null());
    // Without developer mode the console refuses it.
    let store = MemoryTrustStore::new();
    assert_eq!(
        console(&FolderSource::new(&dir), &store)
            .err()
            .unwrap()
            .problems()[0]
            .code,
        "trust.needs_developer_mode"
    );

    let key = key_file(t.path(), "a.key", 1);
    assert_ok(&run_p(&["sign", "--key", key.to_str().unwrap()], &[&dir]));
    assert!(dir.join("play.sig").is_file());
    assert_eq!(
        console(&FolderSource::new(&dir), &store).unwrap().tier.tier,
        Tier::Developer
    );
    // Signing again replaces the signature (the same statement, byte for byte, with a fixed time).
    let a = run_p(
        &[
            "sign",
            "--key",
            key.to_str().unwrap(),
            "--signed-at",
            "2026-11-17T12:00:00Z",
        ],
        &[&dir],
    );
    let first = std::fs::read(dir.join("play.sig")).unwrap();
    assert_ok(&a);
    assert_ok(&run_p(
        &[
            "sign",
            "--key",
            key.to_str().unwrap(),
            "--signed-at",
            "2026-11-17T12:00:00Z",
        ],
        &[&dir],
    ));
    assert_eq!(first, std::fs::read(dir.join("play.sig")).unwrap());
}

#[test]
fn a_rotation_hands_the_id_to_a_new_key_and_the_console_follows_it() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("game");
    native(&dir);
    let (b, zip) = build(&dir, &[]);
    assert_ok(&b);
    let (old, new) = (
        key_file(t.path(), "old.key", 1),
        key_file(t.path(), "new.key", 100),
    );
    let (old_id, new_id) = {
        let seed = |first: u8| {
            ruya_play_trust::SecretKey::from_seed(&core::array::from_fn(|i| first + i as u8))
                .public()
        };
        (seed(1), seed(100))
    };

    // The console saw the old key first.
    let mut store = MemoryTrustStore::new();
    store
        .put(IdRecord {
            id: "com.example.mygame".into(),
            key: old_id.clone(),
            first_seen: 0,
            seq: 0,
            retired: vec![],
        })
        .unwrap();

    // The new key alone is a different developer.
    let alone = t.path().join("alone.play.zip");
    std::fs::copy(&zip, &alone).unwrap();
    assert_ok(&run_p(&["sign", "--key", new.to_str().unwrap()], &[&alone]));
    assert_eq!(
        console(&zip_source(&alone), &store)
            .err()
            .unwrap()
            .problems()[0]
            .code,
        "trust.different_developer"
    );

    // With --rotate-from the old key vouches for the new one.
    let o = run_p(
        &[
            "sign",
            "--json",
            "--key",
            new.to_str().unwrap(),
            "--rotate-from",
            old.to_str().unwrap(),
        ],
        &[&zip],
    );
    assert_ok(&o);
    assert_eq!(o.json["rotations"], json!(1));
    let i = console(&zip_source(&zip), &store).unwrap_or_else(|e| panic!("{:?}", e.problems()));
    match &i.continuity {
        Continuity::Rotated { from, to, seq } => {
            assert_eq!((from, to, *seq), (&old_id, &new_id, 1));
        }
        other => panic!("{other:?}"),
    }
    let now = 0;
    record_install(
        &mut store,
        &i.package.manifest.id,
        i.signatures.key(),
        &i.continuity,
        now,
    )
    .unwrap();
    assert_eq!(
        store.get("com.example.mygame").unwrap().unwrap().key,
        new_id
    );

    // A later build signed by the new key alone is the same key now.
    assert_ok(&run_p(&["sign", "--key", new.to_str().unwrap()], &[&zip]));
    let again = console(&zip_source(&zip), &store).unwrap();
    assert_eq!(again.continuity, Continuity::SameKey);

    // The tool refuses to rotate a key into itself.
    let same = run_p(
        &[
            "sign",
            "--key",
            new.to_str().unwrap(),
            "--rotate-from",
            new.to_str().unwrap(),
        ],
        &[&zip],
    );
    assert_eq!(same.exit, 2);
}

#[test]
fn a_second_rotation_carries_the_first_and_numbers_itself_two() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("game");
    native(&dir);
    let (b, zip) = build(&dir, &[]);
    assert_ok(&b);
    let (k1, k2, k3) = (
        key_file(t.path(), "k1", 1),
        key_file(t.path(), "k2", 50),
        key_file(t.path(), "k3", 100),
    );
    let pk = |first: u8| {
        ruya_play_trust::SecretKey::from_seed(&core::array::from_fn(|i| first + i as u8)).public()
    };
    let k = |p: &Path| p.to_str().unwrap().to_string();
    assert_ok(&run_p(
        &["sign", "--key", &k(&k2), "--rotate-from", &k(&k1)],
        &[&zip],
    ));
    assert_ok(&run_p(
        &["sign", "--key", &k(&k3), "--rotate-from", &k(&k2)],
        &[&zip],
    ));
    let mut store = MemoryTrustStore::new();
    store
        .put(IdRecord {
            id: "com.example.mygame".into(),
            key: pk(1),
            first_seen: 0,
            seq: 0,
            retired: vec![],
        })
        .unwrap();
    let i = console(&zip_source(&zip), &store).unwrap_or_else(|e| panic!("{:?}", e.problems()));
    assert_eq!(i.signatures.developer.as_ref().unwrap().rotations.len(), 2);
    assert!(
        matches!(i.continuity, Continuity::Rotated { seq: 2, .. }),
        "{:?}",
        i.continuity
    );
}
