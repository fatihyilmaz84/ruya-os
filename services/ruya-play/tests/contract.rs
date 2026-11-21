//! RUY-403 / RUY-829: the interface ruya-play serves is the one in api/dbus/org.ruyaos.Play1.xml.

mod common;

use common::*;
use ruya_contract_test::{
    assert_interfaces_are, assert_record_served, assert_serves, record_signatures,
};
use ruya_play::dbus::{inspect_record, job_record, PlayIface};
use ruya_play::service::Environment;
use std::sync::Arc;

struct NoSystem;

impl Environment for NoSystem {
    fn mountinfo(&self) -> String {
        String::new()
    }
    fn shell_uid(&self) -> Option<u32> {
        None
    }
}

#[test]
fn play1_matches_the_contract() {
    let Harness { root, importer, .. } = Setup::default().build();
    let (events, _receiver) = async_channel::unbounded();
    let iface = PlayIface::new(Arc::new(importer), Arc::new(NoSystem), events, false);
    assert_serves("org.ruyaos.Play1.xml", &iface, &[]);
    assert_interfaces_are("org.ruyaos.Play1.xml", &["org.ruyaos.Play1"]);
    drop(root);
}

/// RUY-907: the keys of the Inspect record, with their signatures, are the ones the contract
/// documents. A first install, an update that adds and drops permissions, and a package the
/// inspection refuses go through the same `inspect_record()` the service serves; between them they
/// serve every documented key.
#[test]
fn play1_inspect_records_have_the_documented_keys() {
    let sample = |h: &Harness| {
        let (_, report) = h.importer.inspect(&pkg_path("game.play"));
        record_signatures(&inspect_record(&report.unwrap()))
    };
    // A manifest that declares the optional facts, so the first sample serves them all.
    let mut declared = game();
    declared.manifest["summary"] = serde_json::json!({"en": "A small game."});
    declared.manifest["developer"] = serde_json::json!({"name": "Example Games"});
    declared.manifest["players"] = serde_json::json!({"min": 1, "max": 2});
    declared.manifest["controller"] = serde_json::json!("full");
    declared.manifest["age_rating"] =
        serde_json::json!({"scheme": "oars-1.1", "content": {"violence-cartoon": "mild"}});
    let first = Setup::with(Pkg::signed(&declared)).build();
    let update = installed_with(
        serde_json::json!({"multiarch": true}),
        asking(serde_json::json!({"network": true}), 2),
    );
    let samples = [
        ("a first install", sample(&first)),
        ("an update", sample(&update)),
    ];
    assert_record_served("org.ruyaos.Play1.xml", "Inspect", &samples);
}

/// RUY-816: the keys of the ListJobs record are the ones the contract documents, for an install
/// (with its name once the manifest was read) and for a remove.
#[test]
fn play1_job_records_have_the_documented_keys() {
    let mut h = Setup::with(Pkg::signed(&game())).build();
    assert_eq!(h.install().status, ruya_play::JobStatus::Ok);
    deploy(&h, "com.example.mini", &game());
    let (status, _) = h.importer.queue_remove("com.example.mini");
    assert_eq!(status, ruya_play::MethodStatus::Ok);
    h.importer.run_next(&mut |_| {});
    let samples: Vec<_> = h
        .importer
        .list_jobs()
        .iter()
        .map(|j| (j.kind.as_str(), record_signatures(&job_record(j))))
        .collect();
    assert_eq!(samples.len(), 2);
    assert_record_served("org.ruyaos.Play1.xml", "Job", &samples);
}
