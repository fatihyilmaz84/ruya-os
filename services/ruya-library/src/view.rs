//! What `ListItems` serves (ADR-045): the Flatpak items of the system installation plus the Steam
//! items of the active profile. Each profile's Steam items are kept (a put for a profile that is
//! not active changes nothing visible); a switch of the active profile shows its list. Pure.

use std::collections::HashMap;

use crate::catalog::{self, Item};

/// May the caller with this Unix uid make the root-only calls (`PutProfileItems`,
/// `SetActiveProfile`)? Only root, which is ruya-session (its unit has no `User=`). The bus policy
/// denies them to ruya-shell as well; this is the service's own check.
pub fn may_put(uid: u32) -> bool {
    uid == 0
}

/// The lists and the merged view, kept in step.
#[derive(Debug, Default)]
pub struct View {
    /// The signed-in profile (`SetActiveProfile`), "" for nobody.
    active: String,
    flatpak: Vec<Item>,
    steam: HashMap<String, Vec<Item>>,
    merged: Vec<Item>,
}

impl View {
    /// No profile active, the Flatpak items of a first scan.
    pub fn new(flatpak: Vec<Item>) -> Self {
        let mut view = View {
            flatpak,
            ..View::default()
        };
        view.remerge();
        view
    }

    /// The merged list `ListItems` serves.
    pub fn items(&self) -> &[Item] {
        &self.merged
    }

    pub fn active(&self) -> &str {
        &self.active
    }

    /// Merges again; true when the served list changed.
    fn remerge(&mut self) -> bool {
        let steam = self.steam.get(&self.active).cloned().unwrap_or_default();
        let fresh = catalog::merge(steam, self.flatpak.clone());
        let changed = fresh != self.merged;
        self.merged = fresh;
        changed
    }

    /// The profile's Steam items, replacing its last list (kept for a profile that is not
    /// active: only the active profile's list is merged). True when the served list changed.
    pub fn put(&mut self, profile: &str, items: Vec<Item>) -> bool {
        self.steam.insert(profile.to_owned(), items);
        self.remerge()
    }

    /// The signed-in profile ("" = nobody: Flatpak items only). True when the served list changed.
    pub fn set_active(&mut self, profile: &str) -> bool {
        if profile == self.active {
            return false;
        }
        profile.clone_into(&mut self.active);
        self.remerge()
    }

    /// The Flatpak items of a new scan. True when the served list changed.
    pub fn set_flatpak(&mut self, items: Vec<Item>) -> bool {
        self.flatpak = items;
        self.remerge()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile_items::{item, Game};

    fn steam(appid: &str) -> Item {
        item(&Game {
            appid: appid.into(),
            name: format!("Game {appid}"),
            last_played: 0,
        })
    }

    fn flatpak() -> Vec<Item> {
        let mut app = steam("1");
        app.id = "flatpak:org.example.App".into();
        app.source = catalog::Source::Flatpak;
        vec![app]
    }

    fn ids(view: &View) -> Vec<&str> {
        view.items().iter().map(|i| i.id.as_str()).collect()
    }

    #[test]
    fn only_root_may_put() {
        assert!(may_put(0));
        for uid in [1, 999, 1000, 65534, u32::MAX] {
            assert!(!may_put(uid), "{uid}");
        }
    }

    #[test]
    fn nobody_active_serves_the_flatpak_items_only() {
        let mut view = View::new(flatpak());
        assert_eq!(view.active(), "");
        assert!(!view.put("p1", vec![steam("10")]), "p1 is not active");
        assert_eq!(ids(&view), ["flatpak:org.example.App"]);
    }

    #[test]
    fn a_put_for_another_profile_is_kept_and_shows_on_the_switch() {
        let mut view = View::new(flatpak());
        assert!(!view.set_active("p1"), "p1 has no Steam items yet");
        assert!(view.put("p1", vec![steam("10")]));
        assert!(!view.put("p2", vec![steam("20")]), "p2 is not in front");
        assert_eq!(ids(&view), ["flatpak:org.example.App", "steam:10"]);
        assert!(view.set_active("p2"), "the switch changes the list");
        assert_eq!(ids(&view), ["flatpak:org.example.App", "steam:20"]);
        assert!(view.set_active(""), "a sign-out hides every Steam item");
        assert_eq!(ids(&view), ["flatpak:org.example.App"]);
        assert!(view.set_active("p1"));
        assert_eq!(ids(&view), ["flatpak:org.example.App", "steam:10"]);
    }

    #[test]
    fn only_a_change_of_the_served_list_counts() {
        let mut view = View::new(flatpak());
        view.set_active("p1");
        assert!(view.put("p1", vec![steam("10")]));
        assert!(!view.put("p1", vec![steam("10")]), "the same list again");
        assert!(!view.set_active("p1"), "the same profile again");
        view.put("p2", vec![steam("10")]);
        assert!(!view.set_active("p2"), "p2 has the same games");
        assert!(view.set_flatpak(Vec::new()));
        assert_eq!(ids(&view), ["steam:10"]);
        assert!(!view.set_flatpak(Vec::new()));
        assert!(view.put("p2", Vec::new()), "an empty put empties the list");
        assert!(view.items().is_empty());
    }
}
