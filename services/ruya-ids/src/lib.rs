//! The ids the RuyaOS services share (RUY-1008). One rule, one place: a service never copies the
//! profile-id grammar. Flatpak app ids stay in `ruya-flatpak`.

/// The longest profile id, in bytes.
pub const MAX_PROFILE_ID: usize = 32;

/// The prefix of a profile's Unix user name (ADR-004: one Unix user per profile).
const USER_PREFIX: &str = "ruya-";

/// A profile id as `ruya-profiles` makes them ("p3"): non-empty, at most `MAX_PROFILE_ID` bytes,
/// `[A-Za-z0-9_-]`, so it is safe as a file name and inside a unit name.
pub fn valid_profile_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_PROFILE_ID
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// The Unix user of a profile id ("p3" -> "ruya-p3"). Does not check the id.
pub fn user_of(profile_id: &str) -> String {
    format!("{USER_PREFIX}{profile_id}")
}

/// The profile id of a Unix user name ("ruya-p3" -> "p3"); `None` for any other user (`root`,
/// `ruya-shell`) and for a name whose id is not a valid profile id.
pub fn profile_of_user(user: &str) -> Option<&str> {
    user.strip_prefix(USER_PREFIX)
        .filter(|id| valid_profile_id(id))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_ids() {
        for ok in ["p3", "guest", "a", "A_b-9", &"x".repeat(32)] {
            assert!(valid_profile_id(ok), "{ok}");
        }
        for bad in [
            "",
            "a/b",
            "a b",
            "a.b",
            "../x",
            "p\u{e9}",
            "p\0",
            &"x".repeat(33),
        ] {
            assert!(!valid_profile_id(bad), "{bad}");
        }
    }

    #[test]
    fn user_names_round_trip() {
        assert_eq!(user_of("p3"), "ruya-p3");
        assert_eq!(profile_of_user("ruya-p3"), Some("p3"));
        assert_eq!(profile_of_user(&user_of("a_b-1")), Some("a_b-1"));
        for bad in ["root", "ruya-", "p3", "ruya-a/b", "ruya-ruya x", ""] {
            assert_eq!(profile_of_user(bad), None, "{bad}");
        }
        assert_eq!(profile_of_user(&user_of(&"x".repeat(33))), None);
    }
}
