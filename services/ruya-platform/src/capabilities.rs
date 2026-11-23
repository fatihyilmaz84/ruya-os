//! The capability table: each capability's key and what it is before the player chose. The one
//! place a default is decided. A capability that is not in it is off until the player turns it
//! on, so a new sensitive capability needs no line here; only one that is on by default does,
//! and that line is a decision (ADR-022's tier-B list, ADR-046 point 4).

/// (capability key, allowed by default).
pub const DEFAULTS: &[(&str, bool)] = &[
    // Lifecycle tells an app only about itself (ADR-022, lead-44): on.
    ("lifecycle", true),
];

/// What a capability is for a (profile, app) the player never chose for.
pub fn default_allowed(key: &str) -> bool {
    DEFAULTS.iter().any(|(k, on)| *k == key && *on)
}

/// A capability key: 1 to 32 of `[a-z0-9-]`, starting with a letter.
pub fn valid_capability(key: &str) -> bool {
    key.len() <= crate::limits::MAX_CAPABILITY
        && key.starts_with(|c: char| c.is_ascii_lowercase())
        && key
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lifecycle_is_on_and_everything_else_off() {
        assert!(default_allowed("lifecycle"));
        for other in ["captures", "now-playing", "achievements", "", "Lifecycle"] {
            assert!(!default_allowed(other), "{other}");
        }
    }

    #[test]
    fn keys() {
        assert!(valid_capability("lifecycle"));
        assert!(valid_capability("now-playing2"));
        assert!(valid_capability(&"a".repeat(32)));
        for bad in [
            "",
            "Lifecycle",
            "2d",
            "-x",
            "now_playing",
            "a b",
            &"a".repeat(33),
        ] {
            assert!(!valid_capability(bad), "{bad:?}");
        }
        for (key, _) in DEFAULTS {
            assert!(valid_capability(key), "{key}");
        }
    }
}
