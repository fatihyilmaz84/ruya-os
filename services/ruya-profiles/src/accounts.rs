//! Unix accounts backing each profile (ADR-004: one Unix user per profile).
//!
//! Regular profiles take their uid from useradd below the guest range; temporary guests (RUY-125,
//! ADR-017 point 7) get an explicit uid from `GUEST_UIDS`, which the service hands out only once.

use std::io;
use std::ops::RangeInclusive;

use ruya_ids::user_of;

/// Uids (and gids) of temporary guests. Regular profiles never get one (`REGULAR_ID_MAX`).
pub const GUEST_UIDS: RangeInclusive<u32> = 50000..=59999;
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

pub trait Accounts {
    fn create(&self, profile_id: &str, kind: AccountKind) -> io::Result<()>;
    /// Removes the Unix user and its home directory.
    fn remove(&self, profile_id: &str) -> io::Result<()>;
    /// Removes a temporary guest's user and home, but only when the user carries the guest
    /// marker (comment, home, a uid in `GUEST_UIDS` equal to `uid`); a user that does not exist
    /// is nothing to remove. Anything else is an error and nothing is deleted.
    fn remove_guest(&self, profile_id: &str, uid: u32) -> io::Result<()>;
    /// True when a user or a group already has this id.
    fn id_in_use(&self, id: u32) -> io::Result<bool>;
}

impl<T: Accounts + ?Sized> Accounts for Box<T> {
    fn create(&self, profile_id: &str, kind: AccountKind) -> io::Result<()> {
        (**self).create(profile_id, kind)
    }
    fn remove(&self, profile_id: &str) -> io::Result<()> {
        (**self).remove(profile_id)
    }
    fn remove_guest(&self, profile_id: &str, uid: u32) -> io::Result<()> {
        (**self).remove_guest(profile_id, uid)
    }
    fn id_in_use(&self, id: u32) -> io::Result<bool> {
        (**self).id_in_use(id)
    }
}

/// The `useradd` arguments for a profile user. A regular profile is kept below the guest range
/// (`-K UID_MAX`, `-K GID_MAX`); a guest gets its uid, and its user group the same gid or
/// useradd fails (`GID_MIN` = `GID_MAX` = uid), so a taken uid or gid is refused, never shared.
pub fn useradd_args(profile_id: &str, kind: AccountKind) -> Vec<String> {
    let user = user_of(profile_id);
    let mut args: Vec<String> = vec![
        "--create-home".into(),
        "--home-dir".into(),
        format!("/var/home/{user}"),
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

/// What the wipe may do with the passwd line of a temporary guest's user.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuestEntry {
    /// No such user: nothing to remove.
    Missing,
    /// The user carries the guest marker: `userdel --remove` may run.
    Guest,
    /// Some other user has the name: it is never deleted.
    NotAGuest,
}

/// Classifies `getent passwd ruya-<id>`'s line ("" when there is none) for a guest with `uid`.
pub fn guest_entry(passwd_line: &str, profile_id: &str, uid: u32) -> GuestEntry {
    let line = passwd_line.trim_end_matches(['\r', '\n']);
    if line.is_empty() {
        return GuestEntry::Missing;
    }
    let user = user_of(profile_id);
    let fields: Vec<&str> = line.split(':').collect();
    if fields.len() < 7 || fields[0] != user {
        return GuestEntry::NotAGuest;
    }
    let listed_uid: Option<u32> = fields[2].parse().ok();
    let is_guest = listed_uid == Some(uid)
        && GUEST_UIDS.contains(&uid)
        && fields[4] == GUEST_COMMENT
        && fields[5] == format!("/var/home/{user}");
    if is_guest {
        GuestEntry::Guest
    } else {
        GuestEntry::NotAGuest
    }
}

/// For tests and non-Linux development hosts.
#[derive(Debug, Default)]
pub struct NoAccounts;

impl Accounts for NoAccounts {
    fn create(&self, _profile_id: &str, _kind: AccountKind) -> io::Result<()> {
        Ok(())
    }
    fn remove(&self, _profile_id: &str) -> io::Result<()> {
        Ok(())
    }
    fn remove_guest(&self, _profile_id: &str, _uid: u32) -> io::Result<()> {
        Ok(())
    }
    fn id_in_use(&self, _id: u32) -> io::Result<bool> {
        Ok(false)
    }
}

#[cfg(target_os = "linux")]
fn userdel(user: &str) -> io::Result<std::process::ExitStatus> {
    std::process::Command::new("userdel")
        .arg("--remove")
        .arg(user)
        .status()
}

/// `getent <db> <key>`: Some(output) when found, None when not (exit 2).
#[cfg(target_os = "linux")]
fn getent(db: &str, key: &str) -> io::Result<Option<String>> {
    let out = std::process::Command::new("getent")
        .args([db, key])
        .output()?;
    match out.status.code() {
        Some(0) => Ok(Some(String::from_utf8_lossy(&out.stdout).into_owned())),
        Some(2) => Ok(None),
        _ => Err(io::Error::other(format!(
            "getent {db} {key} failed: {}",
            out.status
        ))),
    }
}

/// Creates real users with `useradd`. Homes live in /var/home (persistent on bootc).
#[cfg(target_os = "linux")]
#[derive(Debug, Default)]
pub struct UnixAccounts;

#[cfg(target_os = "linux")]
impl UnixAccounts {
    /// Ends the user's manager and apps, drops the linger, then `userdel --remove`.
    fn delete_user(user: &str) -> io::Result<()> {
        // `ruya-session` keeps a profile's systemd manager running (linger) once an app was
        // launched as it, and userdel refuses a user with processes. End the manager and its
        // apps and drop the linger first; both are no-ops for a user that never launched.
        for args in [["terminate-user", user], ["disable-linger", user]] {
            match std::process::Command::new("loginctl").args(args).status() {
                Ok(_) => {}
                Err(err) => eprintln!("ruya-profiles: loginctl {}: {err}", args[0]),
            }
        }
        // terminate-user returns before the processes are gone: userdel exits 8 until they are.
        let mut status = userdel(user)?;
        for _ in 0..10 {
            if status.code() != Some(8) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(500));
            status = userdel(user)?;
        }
        // userdel exits 6 when the user does not exist: nothing left to remove.
        if status.success() || status.code() == Some(6) {
            Ok(())
        } else {
            Err(io::Error::other(format!("userdel {user} failed: {status}")))
        }
    }
}

#[cfg(target_os = "linux")]
impl Accounts for UnixAccounts {
    fn create(&self, profile_id: &str, kind: AccountKind) -> io::Result<()> {
        let user = user_of(profile_id);
        let status = std::process::Command::new("useradd")
            .args(useradd_args(profile_id, kind))
            .status()?;
        if status.success() {
            Ok(())
        } else {
            Err(io::Error::other(format!("useradd {user} failed: {status}")))
        }
    }

    fn remove(&self, profile_id: &str) -> io::Result<()> {
        Self::delete_user(&user_of(profile_id))
    }

    fn remove_guest(&self, profile_id: &str, uid: u32) -> io::Result<()> {
        let user = user_of(profile_id);
        let line = getent("passwd", &user)?.unwrap_or_default();
        match guest_entry(&line, profile_id, uid) {
            GuestEntry::Missing => Ok(()),
            GuestEntry::Guest => Self::delete_user(&user),
            GuestEntry::NotAGuest => Err(io::Error::other(format!(
                "{user} is not a temporary guest user (uid {uid}): not removed"
            ))),
        }
    }

    fn id_in_use(&self, id: u32) -> io::Result<bool> {
        let key = id.to_string();
        Ok(getent("passwd", &key)?.is_some() || getent("group", &key)?.is_some())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let guest =
            "ruya-p7:x:50004:50004:RuyaOS profile (guest):/var/home/ruya-p7:/usr/sbin/nologin\n";
        assert_eq!(guest_entry(guest, "p7", 50004), GuestEntry::Guest);
        assert_eq!(guest_entry("", "p7", 50004), GuestEntry::Missing);
        // A regular profile user with that name, the wrong uid, a uid outside the range, another
        // home or another user: never deleted.
        let regular = "ruya-p7:x:1003:1003:RuyaOS profile:/var/home/ruya-p7:/usr/sbin/nologin";
        assert_eq!(guest_entry(regular, "p7", 50004), GuestEntry::NotAGuest);
        let not_marked = guest.replace(GUEST_COMMENT, PROFILE_COMMENT);
        assert_eq!(guest_entry(&not_marked, "p7", 50004), GuestEntry::NotAGuest);
        let other_uid = guest.replace("50004:50004", "50005:50005");
        assert_eq!(guest_entry(&other_uid, "p7", 50004), GuestEntry::NotAGuest);
        let low = guest.replace("50004:50004", "1004:1004");
        assert_eq!(guest_entry(&low, "p7", 1004), GuestEntry::NotAGuest);
        let home = guest.replace("/var/home/ruya-p7", "/root");
        assert_eq!(guest_entry(&home, "p7", 50004), GuestEntry::NotAGuest);
        assert_eq!(guest_entry(guest, "p8", 50004), GuestEntry::NotAGuest);
        assert_eq!(guest_entry("garbage", "p7", 50004), GuestEntry::NotAGuest);
    }
}
