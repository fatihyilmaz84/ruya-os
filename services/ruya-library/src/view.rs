//! What `ListItems` serves (ADR-045): the Flatpak items of the system installation plus the Steam
//! items of the active profile, as the games they make under that profile's links (RUY-137,
//! `games.rs`). Each profile's Steam items are kept (a put for a profile that is not active
//! changes nothing visible); a switch of the active profile shows its list. Pure.

use std::collections::HashMap;

use crate::catalog::{self, Item};
use crate::games::{self, Game, GameChoices};

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
    /// The active profile's links and preferences.
    choices: GameChoices,
    /// The installations of the active profile's view.
    merged: Vec<Item>,
    /// What `ListItems` serves.
    games: Vec<Game>,
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

    /// Every installation of the active profile's view (each game's, ungrouped).
    pub fn items(&self) -> &[Item] {
        &self.merged
    }

    /// The games `ListItems` serves.
    pub fn games(&self) -> &[Game] {
        &self.games
    }

    /// The games `profile` would see with `choices`: the active profile's view for it, else the
    /// Flatpak items and its own Steam items (the installation calls take any profile).
    pub fn games_of(&self, profile: &str, choices: &GameChoices) -> Vec<Game> {
        let steam = self.steam.get(profile).cloned().unwrap_or_default();
        games::group(&catalog::merge(steam, self.flatpak.clone()), choices)
    }

    pub fn active(&self) -> &str {
        &self.active
    }

    /// Merges and groups again; true when the served list changed.
    fn remerge(&mut self) -> bool {
        let steam = self.steam.get(&self.active).cloned().unwrap_or_default();
        self.merged = catalog::merge(steam, self.flatpak.clone());
        let fresh = games::group(&self.merged, &self.choices);
        let changed = fresh != self.games;
        self.games = fresh;
        changed
    }

    /// The profile's Steam items, replacing its last list (kept for a profile that is not
    /// active: only the active profile's list is merged). True when the served list changed.
    pub fn put(&mut self, profile: &str, items: Vec<Item>) -> bool {
        self.steam.insert(profile.to_owned(), items);
        self.remerge()
    }

    /// The signed-in profile ("" = nobody: Flatpak items only) and its links and preferences. True
    /// when the served list changed.
    pub fn set_active(&mut self, profile: &str, choices: GameChoices) -> bool {
        if profile == self.active && choices == self.choices {
            return false;
        }
        profile.clone_into(&mut self.active);
        self.choices = choices;
        self.remerge()
    }

    /// `profile`'s links and preferences after a change; only the active profile's are served.
    /// True when the served list changed.
    pub fn set_choices(&mut self, profile: &str, choices: GameChoices) -> bool {
        if profile != self.active {
            return false;
        }
        self.set_active(profile, choices)
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

    impl View {
        /// A switch with no links.
        fn set_active_plain(&mut self, profile: &str) -> bool {
            self.set_active(profile, GameChoices::default())
        }
    }

    fn linked(a: &str, b: &str) -> GameChoices {
        let mut c = GameChoices::default();
        c.links.insert(a.into(), vec![b.into()]);
        c
    }

    #[test]
    fn the_games_follow_the_active_profiles_links() {
        let mut view = View::new(flatpak());
        view.put("p1", vec![steam("10")]);
        let links = linked("flatpak:org.example.App", "steam:10");
        assert!(view.set_active("p1", links.clone()), "p1's own grouping");
        assert_eq!(view.games().len(), 1);
        assert_eq!(view.games()[0].installations.len(), 2);
        assert_eq!(
            ids(&view),
            ["flatpak:org.example.App", "steam:10"],
            "items stay ungrouped"
        );
        assert!(
            !view.set_choices("p2", GameChoices::default()),
            "p2 is not in front"
        );
        assert!(
            view.set_choices("p1", GameChoices::default()),
            "an unlink splits"
        );
        assert_eq!(view.games().len(), 2);
        assert!(!view.set_choices("p1", GameChoices::default()), "no change");
        // Another profile's view, for its own calls.
        view.put("p2", vec![steam("20")]);
        let theirs = view.games_of("p2", &linked("flatpak:org.example.App", "steam:20"));
        assert_eq!(theirs.len(), 1);
        assert_eq!(view.games().len(), 2, "the served list is p1's");
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
        assert!(!view.set_active_plain("p1"), "p1 has no Steam items yet");
        assert!(view.put("p1", vec![steam("10")]));
        assert!(!view.put("p2", vec![steam("20")]), "p2 is not in front");
        assert_eq!(ids(&view), ["flatpak:org.example.App", "steam:10"]);
        assert!(view.set_active_plain("p2"), "the switch changes the list");
        assert_eq!(ids(&view), ["flatpak:org.example.App", "steam:20"]);
        assert!(
            view.set_active_plain(""),
            "a sign-out hides every Steam item"
        );
        assert_eq!(ids(&view), ["flatpak:org.example.App"]);
        assert!(view.set_active_plain("p1"));
        assert_eq!(ids(&view), ["flatpak:org.example.App", "steam:10"]);
    }

    #[test]
    fn only_a_change_of_the_served_list_counts() {
        let mut view = View::new(flatpak());
        view.set_active_plain("p1");
        assert!(view.put("p1", vec![steam("10")]));
        assert!(!view.put("p1", vec![steam("10")]), "the same list again");
        assert!(!view.set_active_plain("p1"), "the same profile again");
        view.put("p2", vec![steam("10")]);
        assert!(!view.set_active_plain("p2"), "p2 has the same games");
        assert!(view.set_flatpak(Vec::new()));
        assert_eq!(ids(&view), ["steam:10"]);
        assert!(!view.set_flatpak(Vec::new()));
        assert!(view.put("p2", Vec::new()), "an empty put empties the list");
        assert!(view.items().is_empty());
    }
}
