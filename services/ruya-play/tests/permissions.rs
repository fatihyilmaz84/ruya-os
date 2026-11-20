//! Play1's Inspect and Install and the permission gate (RUY-851, 05 §8): Inspect reports the
//! tier's gate so the shell can ask for the admin's PIN; Install keeps needing `admin_approved`
//! for every package, a gated one included; Inspect of a package whose id is installed reports
//! what it adds, drops, and whether an addition is high risk.

mod common;

use common::*;
use ruya_play::dbus::inspect_record;
use ruya_play::{JobStatus, MethodStatus};
use serde_json::json;
use zbus::zvariant::{OwnedValue, Value};

type Triples = Vec<(String, String, String)>;

fn triples(v: &OwnedValue) -> Triples {
    Triples::try_from(v.try_clone().unwrap()).unwrap()
}

fn record_of(h: &Harness) -> std::collections::BTreeMap<String, OwnedValue> {
    let (status, report) = h.importer.inspect(&pkg_path("game.play"));
    assert_eq!(status, MethodStatus::Ok);
    inspect_record(&report.unwrap())
}

#[test]
fn inspect_reports_the_gate_of_the_tier() {
    let h = Setup::with(Pkg::signed(&asking(json!({"network": true}), 1))).build();
    assert_eq!(&*record_of(&h)["gate"], &Value::from("allowed"));
    let h = Setup::with(Pkg::signed(&asking(json!({"devel": true}), 1))).build();
    assert_eq!(&*record_of(&h)["gate"], &Value::from("admin-pin-warning"));
    let official = Pkg::Signed(
        Box::new(Pkg::Mem(asking(json!({"input": "all-devices"}), 1).mem())),
        std::sync::Arc::new(dev_key()),
        Some(std::sync::Arc::new(store_key())),
    );
    let h = Setup::with(official).build();
    let r = record_of(&h);
    assert_eq!(&*r["tier"], &Value::from("official"));
    assert_eq!(&*r["gate"], &Value::from("admin-pin"));
}

#[test]
fn install_needs_admin_approval_for_every_package_gated_or_not() {
    for perms in [json!({}), json!({"devel": true})] {
        let mut h = Setup::with(Pkg::signed(&asking(perms.clone(), 1))).build();
        let (status, job) = h.importer.queue_install(&pkg_path("game.play"), false);
        assert_eq!(status, MethodStatus::Forbidden, "{perms}");
        assert!(job.is_empty());
        assert!(h.importer.list_jobs().is_empty(), "nothing was queued");
        // With the admin's approval the gated package installs.
        let r = h.install();
        assert_eq!(r.status, JobStatus::Ok, "{perms}: {:?}", r.problems);
    }
}

#[test]
fn inspect_of_an_update_lists_what_it_adds_and_drops() {
    let h = installed_with(
        json!({"input": "controllers", "multiarch": true}),
        asking(
            json!({"input": "controllers", "network": true, "devel": true}),
            2,
        ),
    );
    let r = record_of(&h);
    assert_eq!(
        triples(&r["permissions_added"]),
        vec![
            (
                "devel".to_string(),
                "Can inspect other programs".to_string(),
                "high".to_string()
            ),
            (
                "network".to_string(),
                "Uses the network".to_string(),
                "medium".to_string()
            ),
        ]
    );
    assert_eq!(
        triples(&r["permissions_removed"]),
        vec![(
            "multiarch".to_string(),
            "Runs 32-bit programs".to_string(),
            "medium".to_string()
        )]
    );
    assert_eq!(&*r["adds_high_risk"], &Value::from(true));
}

#[test]
fn an_update_that_adds_only_network_is_not_high_risk() {
    let h = installed_with(json!({}), asking(json!({"network": true}), 2));
    let r = record_of(&h);
    assert_eq!(
        triples(&r["permissions_added"])
            .into_iter()
            .map(|t| t.0)
            .collect::<Vec<_>>(),
        ["network"]
    );
    assert!(triples(&r["permissions_removed"]).is_empty());
    assert_eq!(&*r["adds_high_risk"], &Value::from(false));
}

#[test]
fn no_update_keys_when_nothing_is_installed_or_it_cannot_be_read() {
    let h = Setup::with(Pkg::signed(&asking(json!({"network": true}), 2))).build();
    let r = record_of(&h);
    for key in ["permissions_added", "permissions_removed", "adds_high_risk"] {
        assert!(!r.contains_key(key), "{key} for a first install");
    }
    // Installed, but its play.json names a value the vocabulary does not have.
    let h = installed_with(
        json!({"input": "everything"}),
        asking(json!({"network": true}), 2),
    );
    let r = record_of(&h);
    assert!(!r.contains_key("permissions_added"));
    assert!(r.contains_key("gate"));
}
