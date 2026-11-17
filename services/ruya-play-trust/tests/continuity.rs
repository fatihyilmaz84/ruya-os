//! Key continuity (05 §9.2, §18 items 16 to 18): trust on first use, rotation by the old key,
//! replay, uninstall with kept data, and the admin's "forget".

mod common;

use common::*;
use ruya_play_trust::envelope::{self, Domain};
use ruya_play_trust::statement::RotationStatement;
use ruya_play_trust::{
    check_continuity, forget, record_install, record_uninstall, sign_rotation, Continuity,
    IdRecord, Inspection, SecretKey, TrustError, TrustStore,
};

const ID: &str = "com.example.mini";

/// Inspect and, when accepted, record the install as the commit step would.
fn install(console: &mut Console, pkg: &Pkg) -> Result<Inspection, String> {
    let r = console.inspect(pkg);
    let i = r.map_err(|e| e.problems()[0].code.clone())?;
    record_install(
        &mut console.trust,
        ID,
        i.signatures.key(),
        &i.continuity,
        now(),
    )
    .unwrap();
    Ok(i)
}

fn owner(console: &Console) -> Option<IdRecord> {
    console.trust.get(ID).unwrap()
}

fn rotation(old: &SecretKey, new: &SecretKey, seq: u64) -> Vec<u8> {
    sign_rotation(old, ID, &new.public(), seq, now() - 600)
}

#[test]
fn first_sight_records_the_key_and_the_time() {
    let (mut console, a) = (Console::new(), key());
    let i = install(&mut console, &Pkg::minimal().signed(&a)).unwrap();
    assert_eq!(i.continuity, Continuity::FirstSight { seq: 0 });
    let rec = owner(&console).unwrap();
    assert_eq!((rec.key, rec.first_seen, rec.seq), (a.public(), now(), 0));
    // The same key installs again and updates.
    let i = install(&mut console, &Pkg::minimal().signed(&a)).unwrap();
    assert_eq!(i.continuity, Continuity::SameKey);
}

#[test]
fn another_key_is_a_different_developer_and_the_message_names_the_way_out() {
    let (mut console, a, b) = (Console::new(), key(), key());
    install(&mut console, &Pkg::minimal().signed(&a)).unwrap();
    let r = console.inspect(&Pkg::minimal().signed(&b));
    assert_refused(&r, "trust.different_developer");
    let message = r.unwrap_err().problems()[0].message.clone();
    assert!(message.contains(&a.public().key_id()), "{message}");
    assert!(message.contains(&b.public().key_id()), "{message}");
    assert!(
        message.contains("Forget this game's data and key"),
        "{message}"
    );
}

#[test]
fn ids_that_differ_only_in_case_are_the_same_id() {
    let (mut console, a, b) = (Console::new(), key(), key());
    install(&mut console, &Pkg::minimal().signed(&a)).unwrap();
    let squat = Pkg::minimal().with_id("com.Example.MINI").signed(&b);
    assert_refused(&console.inspect(&squat), "trust.different_developer");
}

#[test]
fn an_unsigned_package_cannot_take_a_signed_id() {
    let (mut console, a) = (Console::new(), key());
    install(&mut console, &Pkg::minimal().signed(&a)).unwrap();
    console.trust.set_developer_mode(true).unwrap();
    assert_refused(
        &console.inspect(&Pkg::minimal()),
        "trust.different_developer",
    );
}

#[test]
fn an_unsigned_install_records_nothing() {
    let mut console = Console::new();
    console.trust.set_developer_mode(true).unwrap();
    let i = install(&mut console, &Pkg::minimal()).unwrap();
    assert_eq!(i.continuity, Continuity::Unsigned);
    assert!(owner(&console).is_none());
}

#[test]
fn a_rotation_by_the_old_key_is_accepted_once() {
    let (mut console, a, b) = (Console::new(), key(), key());
    install(&mut console, &Pkg::minimal().signed(&a)).unwrap();
    let r1 = rotation(&a, &b, 1);
    let i = install(&mut console, &Pkg::minimal().signed_rotating(&b, &[&r1])).unwrap();
    assert_eq!(
        i.continuity,
        Continuity::Rotated {
            from: a.public(),
            to: b.public(),
            seq: 1
        }
    );
    let rec = owner(&console).unwrap();
    assert_eq!((rec.key.clone(), rec.seq), (b.public(), 1));
    assert_eq!(rec.retired, vec![a.public().key_id()]);
    assert_eq!(rec.first_seen, now(), "first sight stays");
    // The id is B's now: the old key is refused, and the applied rotation does not bring it back.
    assert_refused(
        &console.inspect(&Pkg::minimal().signed(&a)),
        "trust.different_developer",
    );
    assert_refused(
        &console.inspect(&Pkg::minimal().signed_rotating(&a, &[&r1])),
        "trust.different_developer",
    );
    // B's later packages may keep carrying the statement.
    let i = install(&mut console, &Pkg::minimal().signed_rotating(&b, &[&r1])).unwrap();
    assert_eq!(i.continuity, Continuity::SameKey);
    assert_eq!(owner(&console).unwrap().seq, 1);
}

#[test]
fn a_rotation_signed_by_the_new_key_is_rejected() {
    let (mut console, a, b) = (Console::new(), key(), key());
    install(&mut console, &Pkg::minimal().signed(&a)).unwrap();
    let forged = RotationStatement {
        id: ID.into(),
        old_key: a.public(),
        new_key: b.public(),
        seq: 1,
        signed_at: now(),
    };
    let by_new = envelope::seal(&b, Domain::Rotation, &forged.to_bytes());
    let r = console.inspect(&Pkg::minimal().signed_rotating(&b, &[&by_new]));
    assert_refused(&r, "rotation.not_by_old_key");
    assert_eq!(r.unwrap_err().problems()[0].path, "play.sig rotation 1");
    assert_eq!(owner(&console).unwrap().key, a.public());
}

#[test]
fn a_replayed_older_rotation_is_rejected() {
    // The console first saw A with its history up to seq 5. An older statement of A (seq 3, a key
    // change A gave up) is replayed by whoever holds B to take the id.
    let (mut console, a, b, w) = (Console::new(), key(), key(), key());
    install(
        &mut console,
        &Pkg::minimal().signed_rotating(&a, &[&rotation(&w, &a, 5)]),
    )
    .unwrap();
    assert_eq!(owner(&console).unwrap().seq, 5);
    let old = rotation(&a, &b, 3);
    let r = console.inspect(&Pkg::minimal().signed_rotating(&b, &[&old]));
    assert_refused(&r, "rotation.replayed");
    assert_eq!(owner(&console).unwrap().key, a.public());
}

#[test]
fn a_retired_key_stays_retired() {
    // A -> B (1) was applied; A then signs B's way back as "B -> A (2)" with B's help: refused.
    let (mut console, a, b) = (Console::new(), key(), key());
    install(&mut console, &Pkg::minimal().signed(&a)).unwrap();
    let r1 = rotation(&a, &b, 1);
    install(&mut console, &Pkg::minimal().signed_rotating(&b, &[&r1])).unwrap();
    let back = rotation(&b, &a, 2);
    let r = console.inspect(&Pkg::minimal().signed_rotating(&a, &[&r1, &back]));
    assert_refused(&r, "rotation.to_retired_key");
    assert!(r.unwrap_err().problems()[0]
        .message
        .contains(&a.public().key_id()));
    assert_eq!(owner(&console).unwrap().key, b.public());
}

#[test]
fn a_rotation_with_an_equal_seq_is_a_replay() {
    let (a, b) = (key(), key());
    let record = IdRecord {
        id: ID.into(),
        key: a.public(),
        first_seen: now(),
        seq: 3,
        retired: vec![],
    };
    let statement = |seq| RotationStatement {
        id: ID.into(),
        old_key: a.public(),
        new_key: b.public(),
        seq,
        signed_at: now(),
    };
    for seq in [1, 3] {
        let r = check_continuity(Some(&record), ID, Some(&b.public()), &[statement(seq)]);
        assert_eq!(
            r,
            Err(TrustError::RotationReplayed { seq, applied: 3 }),
            "seq {seq}"
        );
    }
    let r = check_continuity(Some(&record), ID, Some(&b.public()), &[statement(4)]);
    assert_eq!(
        r,
        Ok(Continuity::Rotated {
            from: a.public(),
            to: b.public(),
            seq: 4
        })
    );
}

#[test]
fn a_chain_of_rotations_is_followed_in_seq_order() {
    let (mut console, a, b, c) = (Console::new(), key(), key(), key());
    install(&mut console, &Pkg::minimal().signed(&a)).unwrap();
    // Carried out of order: the rule sorts them.
    let (r1, r2) = (rotation(&a, &b, 1), rotation(&b, &c, 2));
    let i = install(
        &mut console,
        &Pkg::minimal().signed_rotating(&c, &[&r2, &r1]),
    )
    .unwrap();
    assert_eq!(
        i.continuity,
        Continuity::Rotated {
            from: a.public(),
            to: c.public(),
            seq: 2
        }
    );
    let rec = owner(&console).unwrap();
    assert_eq!(rec.key, c.public());
    assert_eq!(rec.retired, vec![a.public().key_id()]);
}

#[test]
fn a_rotation_that_does_not_reach_the_key_is_a_different_developer() {
    let (mut console, a, b, c) = (Console::new(), key(), key(), key());
    install(&mut console, &Pkg::minimal().signed(&a)).unwrap();
    let r1 = rotation(&a, &b, 1);
    assert_refused(
        &console.inspect(&Pkg::minimal().signed_rotating(&c, &[&r1])),
        "trust.different_developer",
    );
}

#[test]
fn a_rotation_for_another_id_is_rejected() {
    let (mut console, a, b) = (Console::new(), key(), key());
    install(&mut console, &Pkg::minimal().signed(&a)).unwrap();
    let other = sign_rotation(&a, "com.example.other", &b.public(), 1, now());
    assert_refused(
        &console.inspect(&Pkg::minimal().signed_rotating(&b, &[&other])),
        "rotation.wrong_id",
    );
}

#[test]
fn a_broken_rotation_is_refused_even_on_first_sight() {
    let (console, a, b) = (Console::new(), key(), key());
    let mut env: serde_json::Value = serde_json::from_slice(&rotation(&a, &b, 1)).unwrap();
    let sig = env["sig"].as_str().unwrap().to_string();
    let flipped = if sig.starts_with('A') { "B" } else { "A" };
    env["sig"] = serde_json::json!(format!("{flipped}{}", &sig[1..]));
    let r1 = serde_json::to_vec(&env).unwrap();
    let r = console.inspect(&Pkg::minimal().signed_rotating(&b, &[&r1]));
    assert_refused(&r, "sig.bad_signature");
    assert_eq!(r.unwrap_err().problems()[0].path, "play.sig rotation 1");
}

/// Add `rotation` to a signed package's `play.sig` after it was signed (a mirror or a USB copy
/// splicing one in), leaving the developer's signature as it was.
fn splice(pkg: &mut Pkg, rotation: &[u8]) {
    let mut env: serde_json::Value =
        serde_json::from_slice(pkg.play_sig.as_ref().unwrap()).unwrap();
    let r: serde_json::Value = serde_json::from_slice(rotation).unwrap();
    match env.get_mut("rotations") {
        Some(list) => list.as_array_mut().unwrap().push(r),
        None => env["rotations"] = serde_json::json!([r]),
    }
    pkg.play_sig = Some(serde_json::to_vec(&env).unwrap());
}

#[test]
fn on_first_sight_only_rotations_the_package_key_signed_set_the_seq() {
    let (mut console, a, b, x) = (Console::new(), key(), key(), key());
    // B's own package names its history: the seq is remembered.
    let ok = console
        .inspect(&Pkg::minimal().signed_rotating(&b, &[&rotation(&a, &b, 4)]))
        .unwrap();
    assert_eq!(ok.continuity, Continuity::FirstSight { seq: 4 });
    // A throwaway key X splices in "X -> B, seq u64::MAX" to lock out B's later key changes.
    let mut spliced = Pkg::minimal().signed(&b);
    splice(
        &mut spliced,
        &sign_rotation(&x, ID, &b.public(), u64::MAX, now()),
    );
    let r = console.inspect(&spliced);
    assert_refused(&r, "sig.rotations_changed");
    assert!(install(&mut console, &spliced).is_err());
    assert!(owner(&console).is_none(), "nothing was recorded");
    // Added next to B's own rotation, or with B's rotation swapped out, it is refused too.
    let mut added = Pkg::minimal().signed_rotating(&b, &[&rotation(&a, &b, 1)]);
    splice(
        &mut added,
        &sign_rotation(&x, ID, &b.public(), u64::MAX, now()),
    );
    assert_refused(&console.inspect(&added), "sig.rotations_changed");
    let mut removed = Pkg::minimal().signed_rotating(&b, &[&rotation(&a, &b, 1)]);
    let mut env: serde_json::Value =
        serde_json::from_slice(removed.play_sig.as_ref().unwrap()).unwrap();
    env.as_object_mut().unwrap().remove("rotations");
    removed.play_sig = Some(serde_json::to_vec(&env).unwrap());
    assert_refused(&console.inspect(&removed), "sig.rotations_changed");
}

#[test]
fn a_spliced_third_key_rotation_cannot_lock_out_a_genuine_one() {
    let (mut console, b, c, x) = (Console::new(), key(), key(), key());
    install(&mut console, &Pkg::minimal().signed(&b)).unwrap();
    let mut spliced = Pkg::minimal().signed(&b);
    splice(
        &mut spliced,
        &sign_rotation(&x, ID, &b.public(), u64::MAX, now()),
    );
    assert_refused(&console.inspect(&spliced), "sig.rotations_changed");
    assert_eq!(owner(&console).unwrap().seq, 0);
    // B's genuine key change still works.
    let i = install(
        &mut console,
        &Pkg::minimal().signed_rotating(&c, &[&rotation(&b, &c, 1)]),
    )
    .unwrap();
    assert_eq!(
        i.continuity,
        Continuity::Rotated {
            from: b.public(),
            to: c.public(),
            seq: 1
        }
    );
}

#[test]
fn the_record_survives_an_uninstall_that_keeps_data() {
    let (mut console, a, b) = (Console::new(), key(), key());
    install(&mut console, &Pkg::minimal().signed(&a)).unwrap();
    record_uninstall(&mut console.trust, ID, true).unwrap();
    assert!(owner(&console).is_some());
    // The kept saves cannot be inherited by another key.
    assert_refused(
        &console.inspect(&Pkg::minimal().signed(&b)),
        "trust.different_developer",
    );
    // The admin forgets the game's data and key: trust on first use starts again.
    assert!(forget(&mut console.trust, ID).unwrap());
    assert!(!forget(&mut console.trust, ID).unwrap());
    let i = install(&mut console, &Pkg::minimal().signed(&b)).unwrap();
    assert_eq!(i.continuity, Continuity::FirstSight { seq: 0 });
    assert_eq!(owner(&console).unwrap().key, b.public());
}

#[test]
fn an_uninstall_without_kept_data_frees_the_id() {
    let (mut console, a, b) = (Console::new(), key(), key());
    install(&mut console, &Pkg::minimal().signed(&a)).unwrap();
    record_uninstall(&mut console.trust, ID, false).unwrap();
    assert!(owner(&console).is_none());
    assert!(console.inspect(&Pkg::minimal().signed(&b)).is_ok());
}
