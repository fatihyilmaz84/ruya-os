//! Where a Flatpak app runs, as systemd and the kernel name it: the scope unit `flatpak run`
//! makes for an instance (`app-flatpak-<escaped id>-<instance-id>.scope`) and the cgroup file of a
//! process (`/proc/<pid>/cgroup`). Pure. `ruya-session` finds and stops an app's scopes with it
//! (T-435, T-459), `ruya-platform` checks a caller's identity against it (RUY-1098, ADR-022).

use crate::{valid_app_id, valid_session_app_id};

/// The id as systemd writes it in a unit name (`systemd-escape`): every byte outside
/// `[A-Za-z0-9_.:]` becomes `\xNN`, so the `-` of `attack-vector-alpha` is `\x2d` (a leading `.`
/// too, which an app id never has). Only valid app ids are expected; others get the same rule.
pub fn unit_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for (i, b) in s.bytes().enumerate() {
        let plain = b.is_ascii_alphanumeric() || matches!(b, b'_' | b':') || (b == b'.' && i > 0);
        if plain {
            out.push(b as char);
        } else {
            out.push_str(&format!("\\x{b:02x}"));
        }
    }
    out
}

/// Is `name` a scope `flatpak run <app_id>` makes (`app-flatpak-<escaped app_id>-<number>.scope`,
/// the `-` of the id written `\x2d`)? The part after the id must be digits only, so
/// `org.x.App-Extra` is not taken for `org.x.App`.
pub fn is_app_scope(app_id: &str, name: &str) -> bool {
    valid_session_app_id(app_id)
        && name
            .strip_prefix("app-flatpak-")
            .and_then(|rest| rest.strip_prefix(unit_escape(app_id).as_str()))
            .and_then(|rest| rest.strip_prefix('-'))
            .and_then(|rest| rest.strip_suffix(".scope"))
            .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

/// The longest Flatpak instance id taken: Flatpak writes a decimal number, far shorter.
pub const MAX_INSTANCE_ID: usize = 20;

/// A Flatpak instance id (`[Instance] instance-id` of `.flatpak-info`, the number in the scope's
/// name): 1 to `MAX_INSTANCE_ID` ASCII digits.
pub fn valid_instance_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= MAX_INSTANCE_ID && id.bytes().all(|b| b.is_ascii_digit())
}

/// The scope of exactly one instance: `app-flatpak-<escaped app_id>-<instance_id>.scope`, or
/// `None` when the app id or the instance id is not one (`valid_app_id`, `valid_instance_id`).
/// The name a caller's cgroup must end in for `ruya-platform` to take it for that instance.
pub fn instance_scope(app_id: &str, instance_id: &str) -> Option<String> {
    (valid_app_id(app_id) && valid_instance_id(instance_id))
        .then(|| format!("app-flatpak-{}-{instance_id}.scope", unit_escape(app_id)))
}

/// Where a process is, read from its `/proc/<pid>/cgroup` (T-459): the uid of the user manager
/// whose tree holds it and the units between that manager and the process, the deepest first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessPlace {
    pub uid: u32,
    pub units: Vec<String>,
}

/// The uid of a user manager's cgroup component (`user@1000.service` -> 1000), else `None`.
pub fn user_manager_uid(part: &str) -> Option<u32> {
    part.strip_prefix("user@")
        .and_then(|r| r.strip_suffix(".service"))
        .filter(|uid| !uid.is_empty() && uid.bytes().all(|b| b.is_ascii_digit()))
        .and_then(|uid| uid.parse().ok())
}

/// The place of a process out of its cgroup file: the cgroup v2 line (`0::<path>`) whose path
/// goes through a user manager (`.../user@<uid>.service/app.slice/<unit>`). `None` for a process
/// outside every user manager (a system service, the kernel) or a file of another shape.
pub fn parse_cgroup(text: &str) -> Option<ProcessPlace> {
    let path = text.lines().find_map(|l| l.strip_prefix("0::"))?;
    let parts: Vec<&str> = path.trim().split('/').filter(|p| !p.is_empty()).collect();
    let (at, uid) = parts
        .iter()
        .enumerate()
        .find_map(|(at, p)| user_manager_uid(p).map(|uid| (at, uid)))?;
    let units = parts[at + 1..]
        .iter()
        .rev()
        .map(|p| (*p).to_owned())
        .collect();
    Some(ProcessPlace { uid, units })
}

/// Is the process of this cgroup file directly in `scope` of the user manager of `uid`? The
/// deepest unit must be `scope` itself (not a unit below or beside it) and the manager must be
/// `user@<uid>.service`, so a scope of the same name in another user's manager does not count.
pub fn runs_in_scope(cgroup: &str, uid: u32, scope: &str) -> bool {
    parse_cgroup(cgroup).is_some_and(|place| {
        place.uid == uid && place.units.first().map(String::as_str) == Some(scope)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const APP: &str = "org.example.Racer-Two";
    const CGROUP: &str = "0::/user.slice/user-1001.slice/user@1001.service/app.slice/app-flatpak-org.example.Racer\\x2dTwo-2468.scope\n";

    #[test]
    fn instance_ids_are_digits() {
        assert!(valid_instance_id("1"));
        assert!(valid_instance_id(&"9".repeat(MAX_INSTANCE_ID)));
        for bad in [
            "",
            "12a",
            "-1",
            " 1",
            "1\n",
            &"9".repeat(MAX_INSTANCE_ID + 1),
        ] {
            assert!(!valid_instance_id(bad), "{bad:?}");
        }
    }

    #[test]
    fn the_scope_of_one_instance() {
        assert_eq!(
            instance_scope(APP, "2468").as_deref(),
            Some("app-flatpak-org.example.Racer\\x2dTwo-2468.scope")
        );
        assert_eq!(instance_scope("Racer", "2468"), None);
        assert_eq!(instance_scope(APP, "24x"), None);
        assert_eq!(instance_scope(APP, ""), None);
    }

    #[test]
    fn a_process_runs_in_its_scope_only_under_its_own_user_manager() {
        let scope = instance_scope(APP, "2468").expect("a valid id");
        assert!(runs_in_scope(CGROUP, 1001, &scope));
        assert!(
            !runs_in_scope(CGROUP, 1002, &scope),
            "another uid's manager"
        );
        let other = instance_scope(APP, "2469").expect("a valid id");
        assert!(!runs_in_scope(CGROUP, 1001, &other), "another instance");
        let deeper = CGROUP.replace(".scope\n", ".scope/sub\n");
        assert!(
            !runs_in_scope(&deeper, 1001, &scope),
            "a cgroup below the scope"
        );
        let system = "0::/system.slice/app-flatpak-org.example.Racer\\x2dTwo-2468.scope\n";
        assert!(
            !runs_in_scope(system, 1001, &scope),
            "outside every user manager"
        );
        assert!(!runs_in_scope("", 1001, &scope));
    }
}
