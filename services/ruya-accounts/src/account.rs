//! The Unix users backing each profile (ADR-004: one Unix user per profile): what `useradd` is
//! asked for, and which existing users the helper may delete.
//!
//! Regular profiles take their uid from useradd below the guest range; temporary guests (RUY-125,
//! ADR-017 point 7) get an explicit uid from `GUEST_UIDS`, which ruya-profiles hands out only
//! once.

use std::ops::RangeInclusive;

use ruya_ids::user_of;
use ruya_users::Passwd;

/// Uids (and gids) of temporary guests. Regular profiles never get one (`REGULAR_ID_MAX`).
pub const GUEST_UIDS: RangeInclusive<u32> = 50000..=59999;
/// The lowest uid useradd gives a regular user (Fedora's `UID_MIN`): a profile user is never below.
pub const FIRST_REGULAR_UID: u32 = 1000;
/// The highest uid and gid useradd may pick for a regular profile.
pub const REGULAR_ID_MAX: u32 = 49999;
/// The passwd comment of a regular profile user. ruya-inputd accepts every comment that starts
/// with it (`profile_uid_in_passwd`).
pub const PROFILE_COMMENT: &str = "RuyaOS profile";
/// The passwd comment of a temporary guest user: the marker the wipe checks before `userdel`.
pub const GUEST_COMMENT: &str = "RuyaOS profile (guest)";

/// Which kind of profile user to make.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccountKind {
    /// A kept profile: useradd picks the uid, at most `REGULAR_ID_MAX`.
    Regular,
    /// A temporary guest with this uid (and the same gid) from `GUEST_UIDS`.
    Guest { uid: u32 },
}

/// The home of a profile user.
pub fn home_of(profile_id: &str) -> String {
    format!("/var/home/{}", user_of(profile_id))
}

/// The `useradd` arguments for a profile user. A regular profile is kept below the guest range
/// (`-K UID_MAX`, `-K GID_MAX`); a guest gets its uid, and its user group the same gid or
/// useradd fails (`GID_MIN` = `GID_MAX` = uid), so a taken uid or gid is refused, never shared.
pub fn useradd_args(profile_id: &str, kind: AccountKind) -> Vec<String> {
    let user = user_of(profile_id);
    let mut args: Vec<String> = vec![
        "--create-home".into(),
        "--home-dir".into(),
        home_of(profile_id),
        "--user-group".into(),
        "--shell".into(),
        "/usr/sbin/nologin".into(),
        "--comment".into(),
    ];
    match kind {
        AccountKind::Regular => {
            args.push(PROFILE_COMMENT.into());
            for key in ["UID_MAX", "GID_MAX"] {
                args.push("-K".into());
                args.push(format!("{key}={REGULAR_ID_MAX}"));
            }
        }
        AccountKind::Guest { uid } => {
            args.push(GUEST_COMMENT.into());
            args.push("--uid".into());
            args.push(uid.to_string());
            for key in ["GID_MIN", "GID_MAX"] {
                args.push("-K".into());
                args.push(format!("{key}={uid}"));
            }
            // A temporary user gets no /etc/subuid and /etc/subgid range.
            for key in ["SUB_UID_COUNT", "SUB_GID_COUNT"] {
                args.push("-K".into());
                args.push(format!("{key}=0"));
            }
        }
    }
    args.push(user);
    args
}

/// What the helper may do with the existing user `ruya-<id>`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UserEntry {
    /// No such user: nothing to remove.
    Missing,
    /// The user carries the marker asked for: `userdel --remove` may run.
    Ours,
    /// Some other user has the name (a system user such as `ruya-shell`, another kind of
    /// profile, a changed home or uid): it is never deleted.
    NotOurs,
}

/// Classifies the passwd record of `ruya-<id>` (`None` when there is none) against the user the
/// request names: a regular profile user (`AccountKind::Regular`: the comment "RuyaOS profile",
/// the home `/var/home/ruya-<id>`, a uid from `FIRST_REGULAR_UID` to `REGULAR_ID_MAX`), or the
/// temporary guest with exactly that uid (the guest comment, the home, the uid in `GUEST_UIDS`).
pub fn classify(entry: Option<&Passwd>, profile_id: &str, kind: AccountKind) -> UserEntry {
    let Some(entry) = entry else {
        return UserEntry::Missing;
    };
    if entry.name != user_of(profile_id) || entry.home != home_of(profile_id) {
        return UserEntry::NotOurs;
    }
    let ours = match kind {
        AccountKind::Regular => {
            entry.gecos == PROFILE_COMMENT
                && (FIRST_REGULAR_UID..=REGULAR_ID_MAX).contains(&entry.uid)
        }
        AccountKind::Guest { uid } => {
            entry.gecos == GUEST_COMMENT && entry.uid == uid && GUEST_UIDS.contains(&uid)
        }
    };
    if ours {
        UserEntry::Ours
    } else {
        UserEntry::NotOurs
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn user(name: &str, uid: u32, gecos: &str, home: &str) -> Passwd {
        Passwd {
            name: name.into(),
            uid,
            gid: uid,
            gecos: gecos.into(),
            home: home.into(),
        }
    }

    #[test]
    fn a_regular_profile_stays_below_the_guest_range() {
        let args = useradd_args("p3", AccountKind::Regular);
        let joined = args.join(" ");
        assert!(joined.contains("-K UID_MAX=49999"), "{joined}");
        assert!(joined.contains("-K GID_MAX=49999"), "{joined}");
        assert!(!joined.contains("--uid"), "{joined}");
        assert!(joined.contains("--comment RuyaOS profile -K"), "{joined}");
        assert_eq!(args.last().map(String::as_str), Some("ruya-p3"));
        assert!(REGULAR_ID_MAX < *GUEST_UIDS.start());
    }

    #[test]
    fn a_guest_gets_its_uid_and_the_same_gid() {
        let args = useradd_args("p7", AccountKind::Guest { uid: 50004 });
        let joined = args.join(" ");
        assert!(joined.contains("--uid 50004"), "{joined}");
        assert!(
            joined.contains("-K GID_MIN=50004 -K GID_MAX=50004"),
            "{joined}"
        );
        assert!(joined.contains("--home-dir /var/home/ruya-p7"), "{joined}");
        let comment = args.iter().position(|a| a == "--comment").unwrap();
        assert_eq!(args[comment + 1], GUEST_COMMENT);
        assert!(GUEST_COMMENT.starts_with(PROFILE_COMMENT));
        assert_eq!(args.last().map(String::as_str), Some("ruya-p7"));
    }

    #[test]
    fn only_a_marked_guest_user_is_wiped() {
        let guest_kind = AccountKind::Guest { uid: 50004 };
        let guest = user("ruya-p7", 50004, GUEST_COMMENT, "/var/home/ruya-p7");
        assert_eq!(classify(Some(&guest), "p7", guest_kind), UserEntry::Ours);
        assert_eq!(classify(None, "p7", guest_kind), UserEntry::Missing);
        // A regular profile user with that name, the wrong uid, a uid outside the range, another
        // home or another user: never deleted.
        let regular = user("ruya-p7", 1003, PROFILE_COMMENT, "/var/home/ruya-p7");
        assert_eq!(
            classify(Some(&regular), "p7", guest_kind),
            UserEntry::NotOurs
        );
        let other_uid = user("ruya-p7", 50005, GUEST_COMMENT, "/var/home/ruya-p7");
        assert_eq!(
            classify(Some(&other_uid), "p7", guest_kind),
            UserEntry::NotOurs
        );
        let low = user("ruya-p7", 1004, GUEST_COMMENT, "/var/home/ruya-p7");
        let low_kind = AccountKind::Guest { uid: 1004 };
        assert_eq!(classify(Some(&low), "p7", low_kind), UserEntry::NotOurs);
        let home = user("ruya-p7", 50004, GUEST_COMMENT, "/root");
        assert_eq!(classify(Some(&home), "p7", guest_kind), UserEntry::NotOurs);
        assert_eq!(classify(Some(&guest), "p8", guest_kind), UserEntry::NotOurs);
    }

    #[test]
    fn only_a_marked_regular_profile_user_is_deleted() {
        let regular = user("ruya-p3", 1003, PROFILE_COMMENT, "/var/home/ruya-p3");
        let kind = AccountKind::Regular;
        assert_eq!(classify(Some(&regular), "p3", kind), UserEntry::Ours);
        assert_eq!(classify(None, "p3", kind), UserEntry::Missing);
        // The shell's own user is `ruya-shell`, the name of the profile id "shell": never deleted.
        let shell = user("ruya-shell", 989, "RuyaOS shell", "/var/lib/ruya-shell");
        assert_eq!(classify(Some(&shell), "shell", kind), UserEntry::NotOurs);
        // A system uid, a guest, a uid above the regular range, another comment or home.
        let system = user("ruya-p3", 999, PROFILE_COMMENT, "/var/home/ruya-p3");
        assert_eq!(classify(Some(&system), "p3", kind), UserEntry::NotOurs);
        let guest = user("ruya-p3", 50001, GUEST_COMMENT, "/var/home/ruya-p3");
        assert_eq!(classify(Some(&guest), "p3", kind), UserEntry::NotOurs);
        let high = user("ruya-p3", 50001, PROFILE_COMMENT, "/var/home/ruya-p3");
        assert_eq!(classify(Some(&high), "p3", kind), UserEntry::NotOurs);
        let comment = user("ruya-p3", 1003, "someone", "/var/home/ruya-p3");
        assert_eq!(classify(Some(&comment), "p3", kind), UserEntry::NotOurs);
        let home = user("ruya-p3", 1003, PROFILE_COMMENT, "/root");
        assert_eq!(classify(Some(&home), "p3", kind), UserEntry::NotOurs);
    }
}
