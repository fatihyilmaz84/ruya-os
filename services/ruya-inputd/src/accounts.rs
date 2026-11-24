//! Which accounts a virtual pad may be given to: RuyaOS profile accounts only (ADR-004), never
//! root, a system user or `ruya-shell`. The same naming rule as `ruya-profiles` and
//! `ruya-session`: profile id `p3` is the Unix user `ruya-p3`.

use ruya_ids::{user_of, valid_profile_id};

/// A profile account: its uid, and whether it is a temporary guest (RUY-125), which is never
/// remembered as a pad's owner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Account {
    pub uid: u32,
    pub guest: bool,
}

/// Looks a profile id up. `None` when it is not a profile account. One call answers both the uid
/// and the guest question, so the real lookup reads `/etc/passwd` once.
pub trait Accounts: Send {
    fn account(&self, profile: &str) -> Option<Account>;
}

/// The first regular uid `useradd` hands out; profile accounts are regular users.
const FIRST_REGULAR_UID: u32 = 1000;
const LAST_REGULAR_UID: u32 = 60000;

/// The passwd comment of a temporary guest account (RUY-125), `ruya-profiles`.
const GUEST_COMMENT: &str = "RuyaOS profile (guest)";

/// Finds profile `id` in `/etc/passwd` text: user `ruya-<id>`, a regular uid, the home
/// `/var/home/ruya-<id>` and the comment "RuyaOS profile" that `ruya-profiles` writes (a guest:
/// "RuyaOS profile (guest)").
pub fn profile_in_passwd(passwd: &str, id: &str) -> Option<Account> {
    if !valid_profile_id(id) {
        return None;
    }
    let user = user_of(id);
    let home = format!("/var/home/{user}");
    passwd.lines().find_map(|line| {
        let fields: Vec<&str> = line.split(':').collect();
        if fields.len() < 7 || fields[0] != user {
            return None;
        }
        let uid: u32 = fields[2].parse().ok()?;
        let regular = (FIRST_REGULAR_UID..LAST_REGULAR_UID).contains(&uid);
        (regular && fields[4].starts_with("RuyaOS profile") && fields[5] == home).then_some(
            Account {
                uid,
                guest: fields[4] == GUEST_COMMENT,
            },
        )
    })
}

/// Reads `/etc/passwd` at every lookup (a profile created a second ago counts).
pub struct PasswdAccounts;

impl Accounts for PasswdAccounts {
    fn account(&self, profile: &str) -> Option<Account> {
        let passwd = std::fs::read_to_string("/etc/passwd").ok()?;
        profile_in_passwd(&passwd, profile)
    }
}

/// Fixed accounts for `--session` and tests (none of them a guest).
pub struct FixedAccounts(pub Vec<(String, u32)>);

impl Accounts for FixedAccounts {
    fn account(&self, profile: &str) -> Option<Account> {
        self.0
            .iter()
            .find(|(id, _)| id == profile)
            .map(|&(_, uid)| Account { uid, guest: false })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ruya_flatpak::{valid_session_app_id, MAX_SESSION_APP_ID};

    const PASSWD: &str = "root:x:0:0:Super User:/root:/bin/bash\n\
ruya-shell:x:990:990:RuyaOS shell:/var/lib/ruya-shell:/usr/sbin/nologin\n\
ruya-p1:x:1001:1001:RuyaOS profile:/var/home/ruya-p1:/usr/sbin/nologin\n\
ruya-p2:x:1002:1002:Someone else:/var/home/ruya-p2:/usr/sbin/nologin\n\
ruya-p3:x:500:500:RuyaOS profile:/var/home/ruya-p3:/usr/sbin/nologin\n";

    #[test]
    fn a_profile_account_is_found() {
        assert_eq!(profile_in_passwd(PASSWD, "p1").map(|a| a.uid), Some(1001));
    }

    #[test]
    fn system_users_and_lookalikes_are_not_profiles() {
        assert_eq!(profile_in_passwd(PASSWD, "shell"), None);
        assert_eq!(profile_in_passwd(PASSWD, "p2"), None); // not made by ruya-profiles
        assert_eq!(profile_in_passwd(PASSWD, "p3"), None); // a system uid
        assert_eq!(profile_in_passwd(PASSWD, "p9"), None);
        assert_eq!(profile_in_passwd(PASSWD, "p1:x"), None);
        assert_eq!(profile_in_passwd(PASSWD, ""), None);
    }

    #[test]
    fn a_guest_is_found_by_its_passwd_comment() {
        let passwd = format!(
            "{PASSWD}ruya-g1:x:1005:1005:RuyaOS profile (guest):/var/home/ruya-g1:/usr/sbin/nologin
"
        );
        let guest = |id| profile_in_passwd(&passwd, id).map(|a| a.guest);
        assert_eq!(guest("g1"), Some(true));
        assert_eq!(guest("p1"), Some(false));
        assert_eq!(guest("nobody"), None);
        assert_eq!(profile_in_passwd(&passwd, "g1").map(|a| a.uid), Some(1005));
    }

    #[test]
    fn app_ids_follow_the_session_rule() {
        assert!(valid_session_app_id("net.supertuxkart.SuperTuxKart"));
        assert!(!valid_session_app_id("supertuxkart"));
        assert!(!valid_session_app_id("org..x"));
        assert!(!valid_session_app_id("org.1x.y"));
        assert!(!valid_session_app_id("org.x.y;rm"));
        assert!(!valid_session_app_id(&format!(
            "org.a.{}",
            "x".repeat(MAX_SESSION_APP_ID)
        )));
    }
}
