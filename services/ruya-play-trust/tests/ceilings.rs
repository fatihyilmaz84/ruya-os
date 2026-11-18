//! Every tier x every permission of the table (RUY-851, 05 §8): allowed, gated or refused as
//! `CEILINGS` says, generated from `PERMISSIONS` and the pairs, and `CEILINGS` itself held to the
//! spec's sentence.

use ruya_play_format::manifest::Permissions;
use ruya_play_trust::{
    assess, ceiling, check_ceiling, Gate, Risk, Tier, CEILINGS, HIGH_RISK_PAIRS, PERMISSIONS,
};

const TIERS: [Tier; 3] = [Tier::Official, Tier::Developer, Tier::Unverified];

/// Permissions that ask for `key` = `value` and nothing else that is not low (the default input
/// mode is low and stays unless the row is an input mode).
fn asking(key: &str, value: &str) -> Permissions {
    let mut p = Permissions::default();
    match key {
        "input" => p.input = value.to_string(),
        "removable_media" => p.removable_media = value.to_string(),
        "network" => p.network = true,
        "multiarch" => p.multiarch = true,
        "gamemode" => p.gamemode = true,
        "realtime" => p.realtime = true,
        "devel" => p.devel = true,
        other => panic!("the test does not know {other}"),
    }
    p
}

#[test]
fn every_tier_and_every_permission_meets_its_ceiling() {
    let mut cases = 0;
    for tier in TIERS {
        let c = ceiling(tier);
        for row in PERMISSIONS {
            let p = asking(row.key, row.value);
            let want = c.gate(row.risk);
            let a = assess(tier, &p);
            let r = a
                .requests
                .iter()
                .find(|r| r.key == row.key && r.value == row.value)
                .unwrap_or_else(|| panic!("{}={} is not a request", row.key, row.value));
            assert_eq!(r.risk, row.risk, "{}={}", row.key, row.value);
            assert_eq!(a.gate, want, "{} {}={}", tier.as_str(), row.key, row.value);
            match check_ceiling(tier, &p) {
                Ok(checked) => {
                    assert_ne!(want, Gate::Refused, "{} {}", tier.as_str(), row.key);
                    assert_eq!(checked.gate, want);
                }
                Err(e) => {
                    assert_eq!(want, Gate::Refused, "{} {}: {e:?}", tier.as_str(), row.key);
                    assert_eq!(e.code(), "ceiling.refused");
                }
            }
            cases += 1;
        }
        for pair in HIGH_RISK_PAIRS {
            let mut p = asking(pair.a, "true");
            let other = asking(pair.b, "read");
            p.removable_media = other.removable_media;
            let a = assess(tier, &p);
            let name = format!("{}+{}", pair.a, pair.b);
            assert!(a
                .requests
                .iter()
                .any(|r| r.key == name && r.risk == Risk::High));
            assert_eq!(a.gate, c.gate(Risk::High), "{} {name}", tier.as_str());
            assert_eq!(
                check_ceiling(tier, &p).is_err(),
                c.gate(Risk::High) == Gate::Refused
            );
            cases += 1;
        }
    }
    assert_eq!(
        cases,
        TIERS.len() * (PERMISSIONS.len() + HIGH_RISK_PAIRS.len())
    );
}

#[test]
fn the_ceilings_are_the_specs() {
    // 05 §8: official low, medium, high (high with the admin gate); developer low and medium
    // freely, high with the admin's PIN and a warning; unverified low and medium only.
    let want = [
        (
            Tier::Official,
            [Gate::Allowed, Gate::Allowed, Gate::AdminPin],
        ),
        (
            Tier::Developer,
            [Gate::Allowed, Gate::Allowed, Gate::AdminPinWithWarning],
        ),
        (
            Tier::Unverified,
            [Gate::Allowed, Gate::Allowed, Gate::Refused],
        ),
    ];
    for (tier, gates) in want {
        let c = ceiling(tier);
        assert_eq!([c.low, c.medium, c.high], gates, "{}", tier.as_str());
    }
    assert_eq!(CEILINGS.len(), 3);
}

#[test]
fn a_gate_has_a_stable_name() {
    let names: Vec<&str> = [
        Gate::Allowed,
        Gate::AdminPin,
        Gate::AdminPinWithWarning,
        Gate::Refused,
    ]
    .iter()
    .map(|g| g.as_str())
    .collect();
    assert_eq!(
        names,
        ["allowed", "admin-pin", "admin-pin-warning", "refused"]
    );
}
