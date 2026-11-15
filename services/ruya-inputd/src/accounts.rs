//! Which accounts a virtual pad may be given to: RuyaOS profile accounts only (ADR-004), never
//! root, a system user or `ruya-shell`. The same naming rule as `ruya-profiles` and
//! `ruya-session`: profile id `p3` is the Unix user `ruya-p3`.

/// Looks a profile id up. `None` when it is not a profile account.
pub trait Accounts: Send {
    fn profile_uid(&self, profile: &str) -> Option<u32>;
    /// Whether `profile` is a temporary guest account (RUY-125): never remembered as a pad's owner.
    fn is_guest(&self, _profile: &str) -> bool {
        false
    }
}

/// A profile id as `ruya-profiles` makes them ("p3"): short, `[A-Za-z0-9_-]`.
pub fn valid_profile_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 32
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

const MAX_APP_ID: usize = 120;

/// A Flatpak app id, the rule of `Session1` ("invalid" otherwise): three or more dot-separated
/// parts of `[A-Za-z0-9_-]`, none empty or starting with a digit, at most 120 characters.
pub fn valid_app_id(id: &str) -> bool {
    if id.is_empty() || id.len() > MAX_APP_ID {
        return false;
    }
    let parts: Vec<&str> = id.split('.').collect();
    parts.len() >= 3
        && parts.iter().all(|p| {
            !p.is_empty()
                && !p.starts_with(|c: char| c.is_ascii_digit())
                && p.chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        })
}

/// The first regular uid `useradd` hands out; profile accounts are regular users.
const FIRST_REGULAR_UID: u32 = 1000;
const LAST_REGULAR_UID: u32 = 60000;

/// Finds profile `id` in `/etc/passwd` text: user `ruya-<id>`, a regular uid, the home
/// `/var/home/ruya-<id>` and the comment "RuyaOS profile" that `ruya-profiles` writes.
pub fn profile_uid_in_passwd(passwd: &str, id: &str) -> Option<u32> {
    if !valid_profile_id(id) {
        return None;
    }
    let user = format!("ruya-{id}");
    let home = format!("/var/home/{user}");
    passwd.lines().find_map(|line| {
        let fields: Vec<&str> = line.split(':').collect();
        if fields.len() < 7 || fields[0] != user {
            return None;
        }
        let uid: u32 = fields[2].parse().ok()?;
        let regular = (FIRST_REGULAR_UID..LAST_REGULAR_UID).contains(&uid);
        (regular && fields[4].starts_with("RuyaOS profile") && fields[5] == home).then_some(uid)
    })
}

/// The passwd comment of a temporary guest account (RUY-125), `ruya-profiles`.
const GUEST_COMMENT: &str = "RuyaOS profile (guest)";

/// Whether profile `id` is a temporary guest in `/etc/passwd` text (a profile account, by the comment).
pub fn profile_is_guest_in_passwd(passwd: &str, id: &str) -> bool {
    if profile_uid_in_passwd(passwd, id).is_none() {
        return false;
    }
    let user = format!("ruya-{id}");
    passwd.lines().any(|line| {
        let fields: Vec<&str> = line.split(':').collect();
        fields.len() >= 7 && fields[0] == user && fields[4] == GUEST_COMMENT
    })
}

/// Reads `/etc/passwd` at every lookup (a profile created a second ago counts).
pub struct PasswdAccounts;

impl Accounts for PasswdAccounts {
    fn profile_uid(&self, profile: &str) -> Option<u32> {
        let passwd = std::fs::read_to_string("/etc/passwd").ok()?;
        profile_uid_in_passwd(&passwd, profile)
    }

    fn is_guest(&self, profile: &str) -> bool {
        std::fs::read_to_string("/etc/passwd")
            .is_ok_and(|p| profile_is_guest_in_passwd(&p, profile))
    }
}

/// Fixed accounts for `--session` and tests.
pub struct FixedAccounts(pub Vec<(String, u32)>);

impl Accounts for FixedAccounts {
    fn profile_uid(&self, profile: &str) -> Option<u32> {
        self.0
            .iter()
            .find(|(id, _)| id == profile)
            .map(|&(_, uid)| uid)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PASSWD: &str = "root:x:0:0:Super User:/root:/bin/bash\n\
ruya-shell:x:990:990:RuyaOS shell:/var/lib/ruya-shell:/usr/sbin/nologin\n\
ruya-p1:x:1001:1001:RuyaOS profile:/var/home/ruya-p1:/usr/sbin/nologin\n\
ruya-p2:x:1002:1002:Someone else:/var/home/ruya-p2:/usr/sbin/nologin\n\
ruya-p3:x:500:500:RuyaOS profile:/var/home/ruya-p3:/usr/sbin/nologin\n";

    #[test]
    fn a_profile_account_is_found() {
        assert_eq!(profile_uid_in_passwd(PASSWD, "p1"), Some(1001));
    }

    #[test]
    fn system_users_and_lookalikes_are_not_profiles() {
        assert_eq!(profile_uid_in_passwd(PASSWD, "shell"), None);
        assert_eq!(profile_uid_in_passwd(PASSWD, "p2"), None); // not made by ruya-profiles
        assert_eq!(profile_uid_in_passwd(PASSWD, "p3"), None); // a system uid
        assert_eq!(profile_uid_in_passwd(PASSWD, "p9"), None);
        assert_eq!(profile_uid_in_passwd(PASSWD, "p1:x"), None);
        assert_eq!(profile_uid_in_passwd(PASSWD, ""), None);
    }

    #[test]
    fn a_guest_is_found_by_its_passwd_comment() {
        let passwd = format!(
            "{PASSWD}ruya-g1:x:1005:1005:RuyaOS profile (guest):/var/home/ruya-g1:/usr/sbin/nologin\n"
        );
        assert!(profile_is_guest_in_passwd(&passwd, "g1"));
        assert!(!profile_is_guest_in_passwd(&passwd, "p1"));
        assert!(!profile_is_guest_in_passwd(&passwd, "nobody"));
    }

    #[test]
    fn app_ids_follow_the_session_rule() {
        assert!(valid_app_id("net.supertuxkart.SuperTuxKart"));
        assert!(!valid_app_id("supertuxkart"));
        assert!(!valid_app_id("org..x"));
        assert!(!valid_app_id("org.1x.y"));
        assert!(!valid_app_id("org.x.y;rm"));
        assert!(!valid_app_id(&format!("org.a.{}", "x".repeat(MAX_APP_ID))));
    }
}
