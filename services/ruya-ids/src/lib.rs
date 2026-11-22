//! The ids the RuyaOS services share (RUY-1008; the Library1 item id, RUY-1051). One rule, one
//! place: a service never copies the profile-id or the item-id grammar. Flatpak app ids stay in
//! `ruya-flatpak`.

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

/// The prefix of a Flatpak app's Library1 item id ("flatpak:org.example.Racer").
pub const FLATPAK_ITEM: &str = "flatpak:";
/// The prefix of a Steam game's Library1 item id ("steam:70").
pub const STEAM_ITEM: &str = "steam:";
/// The most digits a Steam app id has (a 32-bit number).
pub const MAX_STEAM_APPID: usize = 10;

/// What a Library1 item id names (ADR-041): the source and the id inside it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ItemId<'a> {
    /// A Flatpak app; its id is not checked here (the grammar is `ruya-flatpak`'s).
    Flatpak(&'a str),
    /// A Steam game: its app id, ASCII digits only.
    Steam(&'a str),
}

/// A Steam app id as it appears in an item id: 1 to `MAX_STEAM_APPID` ASCII digits.
pub fn valid_steam_appid(appid: &str) -> bool {
    !appid.is_empty() && appid.len() <= MAX_STEAM_APPID && appid.bytes().all(|b| b.is_ascii_digit())
}

/// Reads a Library1 item id: `flatpak:<id>` with a non-empty id, or `steam:<digits>`. `None` for
/// any other prefix and for a Steam id that is not digits.
pub fn parse_item(item: &str) -> Option<ItemId<'_>> {
    if let Some(id) = item.strip_prefix(FLATPAK_ITEM) {
        return (!id.is_empty()).then_some(ItemId::Flatpak(id));
    }
    item.strip_prefix(STEAM_ITEM)
        .filter(|appid| valid_steam_appid(appid))
        .map(ItemId::Steam)
}

/// The item id of a Flatpak app ("org.example.Racer" -> "flatpak:org.example.Racer").
pub fn flatpak_item(app_id: &str) -> String {
    format!("{FLATPAK_ITEM}{app_id}")
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

    #[test]
    fn item_ids() {
        assert_eq!(
            parse_item("flatpak:org.example.Racer"),
            Some(ItemId::Flatpak("org.example.Racer"))
        );
        assert_eq!(
            parse_item(&flatpak_item("a.b.C")),
            Some(ItemId::Flatpak("a.b.C"))
        );
        assert_eq!(parse_item("steam:70"), Some(ItemId::Steam("70")));
        assert_eq!(
            parse_item("steam:4294967295"),
            Some(ItemId::Steam("4294967295"))
        );
        for bad in [
            "",
            "flatpak:",
            "steam:",
            "steam:7a",
            "steam:-1",
            "steam: 70",
            "steam:12345678901",
            "Steam:70",
            "org.example.Racer",
            "play:x",
            ":70",
        ] {
            assert_eq!(parse_item(bad), None, "{bad:?}");
        }
    }
}
