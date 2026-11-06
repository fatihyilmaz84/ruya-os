//! Which accounts apps may run as. Only RuyaOS profiles qualify: `root`, system users and
//! `ruya-shell` are never a profile (ADR-004).

use std::collections::HashSet;

use crate::spawner::valid_profile_id;

pub trait ProfileDirectory {
    /// The Unix user of this profile id, or `None` when it is not a RuyaOS profile.
    fn unix_user(&self, profile: &str) -> Option<String>;
}

/// Unix user name for a profile id ("p3" -> "ruya-p3"); the same rule as `ruya-profiles`.
pub fn unix_user_of(profile_id: &str) -> String {
    format!("ruya-{profile_id}")
}

/// A set of profile ids. The adapter refreshes it from `Profiles1.ListProfiles` before a launch
/// (the profile store holds PIN hashes and is root-only, so this service never reads it); tests
/// and `--session` fill it directly.
#[derive(Debug, Default, Clone)]
pub struct ProfileSnapshot {
    ids: HashSet<String>,
}

impl ProfileSnapshot {
    pub fn new<I: IntoIterator<Item = String>>(ids: I) -> Self {
        ProfileSnapshot {
            ids: ids.into_iter().collect(),
        }
    }

    pub fn set<I: IntoIterator<Item = String>>(&mut self, ids: I) {
        self.ids = ids.into_iter().collect();
    }
}

impl ProfileDirectory for ProfileSnapshot {
    fn unix_user(&self, profile: &str) -> Option<String> {
        self.ids.contains(profile).then(|| unix_user_of(profile))
    }
}

/// One row of `Profiles1.ListProfiles`: (id, display name, colour, role, has PIN).
pub type ProfileRow = (String, String, String, String, bool);

/// The profile ids of a `ListProfiles` answer. Only the id is taken (never the PIN flag or the
/// name), and an id outside the grammar `ruya-profiles` makes is dropped: it could never be a
/// Unix user name we would run an app as.
pub fn profile_ids(rows: Vec<ProfileRow>) -> Vec<String> {
    rows.into_iter()
        .map(|row| row.0)
        .filter(|id| valid_profile_id(id))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str, role: &str) -> ProfileRow {
        (
            id.to_owned(),
            format!("Name of {id}"),
            "#112233".to_owned(),
            role.to_owned(),
            true,
        )
    }

    #[test]
    fn list_profiles_rows_become_ids() {
        let ids = profile_ids(vec![
            row("p1", "admin"),
            row("p2", "standard"),
            row("guest", "guest"),
        ]);
        assert_eq!(ids, ["p1", "p2", "guest"]);
        let dir = ProfileSnapshot::new(ids);
        assert_eq!(dir.unix_user("p2").as_deref(), Some("ruya-p2"));
        assert_eq!(dir.unix_user("p3"), None);
    }

    #[test]
    fn rows_with_a_bad_id_are_dropped() {
        let ids = profile_ids(vec![
            row("p1", "admin"),
            row("", "standard"),
            row("p 2", "standard"),
            row("../root", "standard"),
            row("p;id", "standard"),
        ]);
        assert_eq!(ids, ["p1"]);
        assert!(profile_ids(Vec::new()).is_empty());
    }

    #[test]
    fn only_listed_profiles_have_a_user() {
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        assert_eq!(dir.unix_user("p1").as_deref(), Some("ruya-p1"));
        assert_eq!(dir.unix_user("root"), None);
        assert_eq!(dir.unix_user("ruya-shell"), None);
        assert_eq!(dir.unix_user(""), None);
    }
}
