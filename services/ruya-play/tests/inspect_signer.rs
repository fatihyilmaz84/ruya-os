//! RUY-914: Play1's Inspect record serves `signer_name` (the manifest's developer name, only for a
//! package with a verified developer key) and `age_label` (the label of the manifest's OARS
//! answers, `ruya_play_format::oars::age_label`, the Store's mapping).

mod common;

use common::*;
use ruya_play::dbus::inspect_record;
use ruya_play::MethodStatus;
use ruya_play_trust::TrustRecord;
use serde_json::json;
use std::collections::BTreeMap;
use zbus::zvariant::{OwnedValue, Value};

fn record_of(pkg: Pkg) -> BTreeMap<String, OwnedValue> {
    // Developer mode, so an unsigned package is inspected too.
    let h = Setup {
        developer_mode: true,
        ..Setup::with(pkg)
    }
    .build();
    let (status, report) = h.importer.inspect(&pkg_path("game.play"));
    assert_eq!(status, MethodStatus::Ok);
    inspect_record(&report.unwrap())
}

fn with_developer(name: &str) -> Fx {
    let mut fx = game();
    fx.manifest["developer"] = json!({ "name": name });
    fx
}

#[test]
fn a_signed_package_with_a_developer_serves_its_name_beside_the_key() {
    let r = record_of(Pkg::signed(&with_developer("Example Games")));
    assert_eq!(&*r["signer_name"], &Value::from("Example Games"));
    assert!(r.contains_key("signer_key_id"), "the name comes with a key");
    assert_eq!(&*r["developer"], &Value::from("Example Games"));
}

#[test]
fn a_signed_package_without_a_developer_serves_no_name() {
    let r = record_of(Pkg::signed(&game()));
    assert!(r.contains_key("signer_key_id"));
    assert!(!r.contains_key("signer_name"), "{:?}", r.keys());
    assert!(!r.contains_key("developer"));
}

#[test]
fn an_unsigned_package_serves_no_name_even_with_a_developer() {
    let r = record_of(Pkg::Mem(with_developer("Example Games").mem()));
    assert_eq!(&*r["tier"], &Value::from("unverified"));
    assert!(!r.contains_key("signer_key_id"));
    assert!(!r.contains_key("signer_name"), "{:?}", r.keys());
    // The developer line is still the manifest's own claim, unrelated to a signature.
    assert_eq!(&*r["developer"], &Value::from("Example Games"));
}

/// The name Inspect shows is the one the commit writes into `trust.json` (one rule).
#[test]
fn the_name_is_the_one_the_trust_record_will_carry() {
    let h = Setup::with(Pkg::signed(&with_developer("Example Games"))).build();
    let (_, report) = h.importer.inspect(&pkg_path("game.play"));
    let report = report.unwrap();
    let insp = report.inspection.as_ref().unwrap();
    let record = TrustRecord::of(insp.tier.tier, &insp.signatures, &insp.package.manifest);
    assert_eq!(
        record.signer_name.as_deref(),
        Some("Example Games"),
        "trust.json"
    );
    assert_eq!(
        &*inspect_record(&report)["signer_name"],
        &Value::from("Example Games")
    );
}

fn rated(content: serde_json::Value) -> Fx {
    let mut fx = game();
    fx.manifest["age_rating"] = json!({ "scheme": "oars-1.1", "content": content });
    fx
}

#[test]
fn the_age_label_is_the_label_of_the_oars_answers() {
    for (content, label) in [
        (json!({ "violence-cartoon": "none" }), "all"),
        (
            json!({ "violence-cartoon": "mild", "social-chat": "none" }),
            "7+",
        ),
        (json!({ "violence-fantasy": "moderate" }), "12+"),
        (json!({ "violence-fantasy": "intense" }), "16+"),
        (
            json!({ "sex-nudity": "intense", "social-chat": "mild" }),
            "18+",
        ),
    ] {
        let r = record_of(Pkg::signed(&rated(content.clone())));
        assert_eq!(&*r["age_label"], &Value::from(label), "{content}");
    }
}

#[test]
fn a_package_that_declares_no_answer_is_not_rated() {
    let r = record_of(Pkg::signed(&game()));
    assert!(!r.contains_key("age_label"), "{:?}", r.keys());
    let r = record_of(Pkg::signed(&rated(json!({}))));
    assert!(!r.contains_key("age_label"), "an empty answer is not 'all'");
}
