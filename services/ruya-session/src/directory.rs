//! Which accounts apps may run as. Only RuyaOS profiles qualify: `root`, system users and
//! `ruya-shell` are never a profile (ADR-004).

use std::collections::HashSet;

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_listed_profiles_have_a_user() {
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        assert_eq!(dir.unix_user("p1").as_deref(), Some("ruya-p1"));
        assert_eq!(dir.unix_user("root"), None);
        assert_eq!(dir.unix_user("ruya-shell"), None);
        assert_eq!(dir.unix_user(""), None);
    }
}
