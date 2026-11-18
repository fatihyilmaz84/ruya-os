//! Trust tiers (05 §9.2) and the permission ceilings by tier (05 §8), as data. RUY-102 maps the
//! gates to the admin flow; this module only says what each tier allows.

use crate::error::TrustError;
use crate::permissions::{permission, HighRiskPair, HIGH_RISK_PAIRS};
use crate::signing::Signatures;
use ruya_play_format::manifest::Permissions;

/// How far a package is trusted. Write "third-party store" for the place a `developer` package
/// comes from, never "developer remote" (05 §18 item 6).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Tier {
    /// Unsigned: developer mode only, low and medium permissions only.
    Unverified,
    /// Signed by the developer's key (trust on first use).
    Developer,
    /// Signed by the developer and countersigned by the RuyaOS store key.
    Official,
}

impl Tier {
    /// The stable name: `official`, `developer` or `unverified`.
    pub fn as_str(self) -> &'static str {
        match self {
            Tier::Official => "official",
            Tier::Developer => "developer",
            Tier::Unverified => "unverified",
        }
    }
}

/// Why a package has its tier.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TierReason {
    /// A valid `store.sig` by a pinned store key over a valid `play.sig`.
    StoreCountersigned,
    /// A valid `play.sig`, no `store.sig`.
    DeveloperSigned,
    /// No `play.sig`, and developer mode is on.
    UnsignedInDeveloperMode,
}

/// A tier and its reason.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TierDecision {
    /// The tier.
    pub tier: Tier,
    /// Why.
    pub reason: TierReason,
}

/// The tier of verified signatures. Only a verified `store.sig` gives `official`; this is the one
/// place `ValidateOptions.official` comes from (never from the manifest). An unsigned package is
/// `unverified` only with developer mode on; otherwise it is refused.
pub fn decide_tier(sigs: &Signatures, developer_mode: bool) -> Result<TierDecision, TrustError> {
    let (tier, reason) = match (&sigs.developer, &sigs.store) {
        (Some(_), Some(_)) => (Tier::Official, TierReason::StoreCountersigned),
        (Some(_), None) => (Tier::Developer, TierReason::DeveloperSigned),
        (None, _) if developer_mode => (Tier::Unverified, TierReason::UnsignedInDeveloperMode),
        (None, _) => return Err(TrustError::NeedsDeveloperMode),
    };
    Ok(TierDecision { tier, reason })
}

/// How risky a permission is (05 §8).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Risk {
    /// Shown, never gated by risk.
    Low,
    /// "Uses the network", "Reads files on USB drives", ...
    Medium,
    /// "Accesses all devices", "Can inspect other programs", and risky pairs.
    High,
}

/// What a tier lets a request of one risk do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Gate {
    /// Installs as asked.
    Allowed,
    /// Needs the admin's PIN.
    AdminPin,
    /// Needs the admin's PIN, after a warning.
    AdminPinWithWarning,
    /// The package cannot be installed (never silently reduced).
    Refused,
}

impl Gate {
    /// The stable name of Play1's Inspect record: `allowed`, `admin-pin`, `admin-pin-warning` or
    /// `refused`.
    pub fn as_str(self) -> &'static str {
        match self {
            Gate::Allowed => "allowed",
            Gate::AdminPin => "admin-pin",
            Gate::AdminPinWithWarning => "admin-pin-warning",
            Gate::Refused => "refused",
        }
    }
}

/// The ceiling of one tier.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ceiling {
    /// The tier.
    pub tier: Tier,
    /// Low-risk requests.
    pub low: Gate,
    /// Medium-risk requests.
    pub medium: Gate,
    /// High-risk requests.
    pub high: Gate,
}

/// The ceilings of 05 §8. `official` high: the store reviewed it, the admin gate still applies;
/// `developer` high: the admin's PIN and a warning; `unverified` high: uninstallable.
pub const CEILINGS: [Ceiling; 3] = [
    Ceiling {
        tier: Tier::Official,
        low: Gate::Allowed,
        medium: Gate::Allowed,
        high: Gate::AdminPin,
    },
    Ceiling {
        tier: Tier::Developer,
        low: Gate::Allowed,
        medium: Gate::Allowed,
        high: Gate::AdminPinWithWarning,
    },
    Ceiling {
        tier: Tier::Unverified,
        low: Gate::Allowed,
        medium: Gate::Allowed,
        high: Gate::Refused,
    },
];

/// The ceiling of `tier`.
pub fn ceiling(tier: Tier) -> &'static Ceiling {
    CEILINGS
        .iter()
        .find(|c| c.tier == tier)
        .expect("CEILINGS has every tier")
}

impl Ceiling {
    /// The gate for a request of `risk`.
    pub fn gate(&self, risk: Risk) -> Gate {
        match risk {
            Risk::Low => self.low,
            Risk::Medium => self.medium,
            Risk::High => self.high,
        }
    }
}

/// One request and its risk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    /// The key, or `<a>+<b>` for a pair.
    pub key: String,
    /// The value asked for (empty for a pair).
    pub value: String,
    /// Its risk.
    pub risk: Risk,
}

/// What a package asks for, and what its tier makes of it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Assessment {
    /// Every request, pairs last.
    pub requests: Vec<Request>,
    /// The highest risk (low when nothing is asked).
    pub risk: Risk,
    /// The strictest gate of any request.
    pub gate: Gate,
}

fn asked(p: &Permissions) -> Vec<(&'static str, String)> {
    let mut out = vec![("input", p.input.clone())];
    let bools = [
        ("network", p.network),
        ("multiarch", p.multiarch),
        ("gamemode", p.gamemode),
        ("realtime", p.realtime),
        ("devel", p.devel),
    ];
    for (k, on) in bools {
        if on {
            out.push((k, "true".into()));
        }
    }
    if p.removable_media != "none" {
        out.push(("removable_media", p.removable_media.clone()));
    }
    out.sort_by_key(|(k, _)| *k);
    out
}

/// Assess `perms` under the ceiling of `tier`, with the risks of the one permission table
/// ([`crate::permissions::PERMISSIONS`]). A value missing from the table counts as high risk
/// (a new vocabulary value must be classed before it can be installed).
pub fn assess(tier: Tier, perms: &Permissions) -> Assessment {
    let mut requests: Vec<Request> = asked(perms)
        .into_iter()
        .map(|(key, value)| {
            let risk = permission(key, &value).map_or(Risk::High, |r| r.risk);
            Request {
                key: key.to_string(),
                value,
                risk,
            }
        })
        .collect();
    for HighRiskPair { a, b, .. } in HIGH_RISK_PAIRS {
        let has = |k: &str| requests.iter().any(|r| r.key == k);
        if has(a) && has(b) {
            requests.push(Request {
                key: format!("{a}+{b}"),
                value: String::new(),
                risk: Risk::High,
            });
        }
    }
    let risk = requests.iter().map(|r| r.risk).max().unwrap_or(Risk::Low);
    let c = ceiling(tier);
    let gate = requests
        .iter()
        .map(|r| c.gate(r.risk))
        .max()
        .unwrap_or(Gate::Allowed);
    Assessment {
        requests,
        risk,
        gate,
    }
}

/// Refuse a package whose requests are above its tier's ceiling (`ceiling.refused`, naming the
/// first such request); otherwise the assessment, whose `gate` the admin flow applies.
pub fn check_ceiling(tier: Tier, perms: &Permissions) -> Result<Assessment, TrustError> {
    let a = assess(tier, perms);
    let c = ceiling(tier);
    if let Some(r) = a.requests.iter().find(|r| c.gate(r.risk) == Gate::Refused) {
        return Err(TrustError::CeilingRefused {
            tier: tier.as_str().to_string(),
            permission: r.key.clone(),
        });
    }
    Ok(a)
}
