//! What an update changes in the requests (RUY-851, 05 §8): added, removed and the high-risk ones
//! added.

use ruya_play_format::manifest::Permissions;
use ruya_play_trust::{assess, diff, words, Risk, Tier};

fn keys(rs: &[ruya_play_trust::Request]) -> Vec<String> {
    rs.iter()
        .map(|r| {
            if r.value == "true" || r.value.is_empty() {
                r.key.clone()
            } else {
                format!("{}:{}", r.key, r.value)
            }
        })
        .collect()
}

fn installed() -> Permissions {
    Permissions {
        input: "controllers".into(),
        multiarch: true,
        ..Permissions::default()
    }
}

#[test]
fn the_same_requests_change_nothing() {
    let a = assess(Tier::Developer, &installed());
    let d = diff(&a, &a);
    assert!(d.added.is_empty() && d.removed.is_empty() && d.high_risk_added.is_empty());
}

#[test]
fn adding_network_shows_it() {
    let old = assess(Tier::Developer, &installed());
    let new = assess(
        Tier::Developer,
        &Permissions {
            network: true,
            ..installed()
        },
    );
    let d = diff(&old, &new);
    assert_eq!(keys(&d.added), ["network"]);
    assert_eq!(d.added[0].risk, Risk::Medium);
    assert_eq!(
        words(&d.added[0].key, &d.added[0].value),
        "Uses the network"
    );
    assert!(d.removed.is_empty());
    assert!(d.high_risk_added.is_empty(), "network alone is medium");
}

#[test]
fn adding_devel_is_high_risk() {
    let old = assess(Tier::Developer, &installed());
    let new = assess(
        Tier::Developer,
        &Permissions {
            devel: true,
            ..installed()
        },
    );
    let d = diff(&old, &new);
    assert_eq!(keys(&d.added), ["devel"]);
    assert_eq!(keys(&d.high_risk_added), ["devel"]);
}

#[test]
fn removing_and_changing_a_mode_are_listed() {
    let old = assess(Tier::Developer, &installed());
    let new = assess(
        Tier::Developer,
        &Permissions {
            input: "all-devices".into(),
            ..Permissions::default()
        },
    );
    let d = diff(&old, &new);
    assert_eq!(keys(&d.added), ["input:all-devices"]);
    assert_eq!(keys(&d.high_risk_added), ["input:all-devices"]);
    assert_eq!(keys(&d.removed), ["input:controllers", "multiarch"]);
}

#[test]
fn a_pair_that_becomes_complete_is_a_high_risk_addition() {
    let old = assess(
        Tier::Developer,
        &Permissions {
            network: true,
            ..Permissions::default()
        },
    );
    let new = assess(
        Tier::Developer,
        &Permissions {
            network: true,
            removable_media: "read".into(),
            ..Permissions::default()
        },
    );
    let d = diff(&old, &new);
    assert_eq!(
        keys(&d.added),
        ["removable_media:read", "network+removable_media"]
    );
    assert_eq!(keys(&d.high_risk_added), ["network+removable_media"]);
    assert_eq!(
        words("network+removable_media", ""),
        "Uses the network and reaches USB drives"
    );
}
