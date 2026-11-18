//! Tiers and the permission ceilings by tier (05 §8, §9.2).

mod common;

use common::*;
use ruya_play_format::limits::{BOOL_PERMISSIONS, INPUT_MODES, REMOVABLE_MEDIA};
use ruya_play_format::manifest::Permissions;
use ruya_play_trust::{
    assess, ceiling, check_ceiling, decide_tier, Gate, Risk, Signatures, Tier, TierReason,
    TrustStore, CEILINGS, HIGH_RISK_PAIRS, PERMISSIONS,
};
use serde_json::json;

fn developer_mode(console: &mut Console) {
    console.trust.set_developer_mode(true).unwrap();
}

#[test]
fn no_signature_needs_developer_mode() {
    let console = Console::new();
    let r = console.inspect(&Pkg::minimal());
    assert_refused(&r, "trust.needs_developer_mode");
    assert!(r.unwrap_err().problems()[0]
        .message
        .contains("developer mode"));
}

#[test]
fn no_signature_gives_unverified_only_in_developer_mode() {
    let mut console = Console::new();
    developer_mode(&mut console);
    let i = console.inspect(&Pkg::minimal()).unwrap();
    assert_eq!(i.tier.tier, Tier::Unverified);
    assert_eq!(i.tier.reason, TierReason::UnsignedInDeveloperMode);
    assert!(i.signatures.developer.is_none());
}

#[test]
fn a_signed_package_does_not_need_developer_mode_and_keeps_its_tier_with_it() {
    let (mut console, dev) = (Console::new(), key());
    developer_mode(&mut console);
    let i = console.inspect(&Pkg::minimal().signed(&dev)).unwrap();
    assert_eq!(i.tier.tier, Tier::Developer);
}

#[test]
fn the_tier_rule_itself() {
    let none = Signatures::default();
    assert_eq!(
        decide_tier(&none, false).unwrap_err().code(),
        "trust.needs_developer_mode"
    );
    assert_eq!(decide_tier(&none, true).unwrap().tier, Tier::Unverified);
    assert_eq!(
        [Tier::Official, Tier::Developer, Tier::Unverified].map(Tier::as_str),
        ["official", "developer", "unverified"]
    );
}

#[test]
fn ceiling_unverified_high_is_refused() {
    let mut console = Console::new();
    developer_mode(&mut console);
    for perms in [
        json!({"devel": true}),
        json!({"input": "all-devices"}),
        json!({"network": true, "removable_media": "read"}),
    ] {
        let pkg = Pkg::minimal().with_permissions(perms.clone());
        let r = console.inspect(&pkg);
        // Refused, not reduced: the package cannot be installed at all.
        assert_refused(&r, "ceiling.refused");
        assert!(
            r.unwrap_err().problems()[0]
                .path
                .starts_with("/permissions/"),
            "{perms}"
        );
    }
}

#[test]
fn unverified_low_and_medium_install_as_asked() {
    let mut console = Console::new();
    developer_mode(&mut console);
    let pkg = Pkg::minimal()
        .with_permissions(json!({"network": true, "multiarch": true, "gamemode": true}));
    let i = console.inspect(&pkg).unwrap();
    assert_eq!(i.assessment.risk, Risk::Medium);
    assert_eq!(i.assessment.gate, Gate::Allowed);
    assert!(
        i.package.manifest.permissions.network,
        "nothing was reduced"
    );
}

#[test]
fn developer_high_needs_the_admin_pin_with_a_warning_and_official_the_admin_pin() {
    let (console, dev) = (Console::new(), key());
    let pkg = Pkg::minimal().with_permissions(json!({"devel": true}));
    let d = console.inspect(&pkg.clone().signed(&dev)).unwrap();
    assert_eq!(d.assessment.risk, Risk::High);
    assert_eq!(d.assessment.gate, Gate::AdminPinWithWarning);
    let o = console
        .inspect(&pkg.signed(&dev).countersigned(&console.store))
        .unwrap();
    assert_eq!(o.assessment.gate, Gate::AdminPin);
}

#[test]
fn the_ceilings_are_the_table_of_the_spec() {
    let rows: Vec<(Tier, Gate, Gate, Gate)> = CEILINGS
        .iter()
        .map(|c| (c.tier, c.low, c.medium, c.high))
        .collect();
    assert_eq!(
        rows,
        vec![
            (Tier::Official, Gate::Allowed, Gate::Allowed, Gate::AdminPin),
            (
                Tier::Developer,
                Gate::Allowed,
                Gate::Allowed,
                Gate::AdminPinWithWarning
            ),
            (
                Tier::Unverified,
                Gate::Allowed,
                Gate::Allowed,
                Gate::Refused
            ),
        ]
    );
    assert_eq!(ceiling(Tier::Unverified).gate(Risk::High), Gate::Refused);
}

#[test]
fn the_risk_table_is_the_table_of_the_spec() {
    let rows: Vec<(&str, &str, Risk)> = PERMISSIONS
        .iter()
        .map(|r| (r.key, r.value, r.risk))
        .collect();
    assert_eq!(
        rows,
        vec![
            ("input", "controllers", Risk::Low),
            ("input", "controllers+keyboard-mouse", Risk::Low),
            ("input", "all-devices", Risk::High),
            ("network", "true", Risk::Medium),
            ("removable_media", "read", Risk::Medium),
            ("removable_media", "write", Risk::Medium),
            ("multiarch", "true", Risk::Medium),
            ("gamemode", "true", Risk::Low),
            ("realtime", "true", Risk::Low),
            ("devel", "true", Risk::High),
        ]
    );
    let pairs: Vec<(&str, &str)> = HIGH_RISK_PAIRS.iter().map(|p| (p.a, p.b)).collect();
    assert_eq!(pairs, [("network", "removable_media")]);
}

#[test]
fn every_value_of_the_vocabulary_is_classed() {
    let classed = |k: &str, v: &str| PERMISSIONS.iter().any(|r| r.key == k && r.value == v);
    for v in INPUT_MODES {
        assert!(classed("input", v), "input {v}");
    }
    for v in REMOVABLE_MEDIA.iter().filter(|v| **v != "none") {
        assert!(classed("removable_media", v), "removable_media {v}");
    }
    for k in BOOL_PERMISSIONS {
        assert!(classed(k, "true"), "{k}");
    }
}

#[test]
fn network_with_removable_media_counts_as_high_risk() {
    let p = Permissions {
        network: true,
        removable_media: "write".into(),
        ..Permissions::default()
    };
    let a = assess(Tier::Developer, &p);
    assert_eq!(a.risk, Risk::High);
    assert!(a
        .requests
        .iter()
        .any(|r| r.key == "network+removable_media" && r.risk == Risk::High));
    assert_eq!(a.gate, Gate::AdminPinWithWarning);
    let r = check_ceiling(Tier::Unverified, &p).unwrap_err();
    assert_eq!(r.code(), "ceiling.refused");
    // Each alone is medium.
    for p in [
        Permissions {
            network: true,
            ..Permissions::default()
        },
        Permissions {
            removable_media: "read".into(),
            ..Permissions::default()
        },
    ] {
        assert_eq!(assess(Tier::Unverified, &p).risk, Risk::Medium);
        assert!(check_ceiling(Tier::Unverified, &p).is_ok());
    }
}

#[test]
fn nothing_asked_is_low_and_allowed() {
    let a = assess(Tier::Unverified, &Permissions::default());
    assert_eq!(a.risk, Risk::Low);
    assert_eq!(a.gate, Gate::Allowed);
    assert_eq!(a.requests.len(), 1, "only the input mode: {:?}", a.requests);
}

#[test]
fn a_value_missing_from_the_table_counts_as_high() {
    let p = Permissions {
        input: "a-future-mode".into(),
        ..Permissions::default()
    };
    assert_eq!(assess(Tier::Developer, &p).risk, Risk::High);
}
