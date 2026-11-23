//! The merged library: Steam games and Flatpak apps in one deterministic order.

use std::path::Path;

use crate::flatpak::{self, AppLister};
use crate::games::Key;
use crate::play::{self, PlayInfo};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Game,
    App,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Game => "game",
            Kind::App => "app",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Steam,
    Flatpak,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::Steam => "steam",
            Source::Flatpak => "flatpak",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Item {
    /// `steam:<appid>` or `flatpak:<application id>`.
    pub id: String,
    pub kind: Kind,
    pub title: String,
    pub source: Source,
    /// Opaque to the shell; the session service starts it.
    pub launch: String,
    /// Role (`tile`, `hero`, `icon`) to file or URL. Empty until artwork is found.
    pub art: Vec<(String, String)>,
    /// Unix seconds, 0 if unknown.
    pub last_played: i64,
    /// Set for a `.play` app with a readable `play.json` (`play.rs`).
    pub play: Option<PlayInfo>,
    /// Identification keys its source declares beside the one its own id is (`games::keys`): none
    /// from Steam and Flatpak today; an app-provided game declares its Steam app id (RUY-452).
    pub declared: Vec<Key>,
}

/// Last played first, then title (case-insensitive), then id, so equal titles keep a fixed order.
pub fn merge(steam: Vec<Item>, flatpak: Vec<Item>) -> Vec<Item> {
    let mut items: Vec<Item> = steam.into_iter().chain(flatpak).collect();
    items.sort_by(|a, b| {
        b.last_played
            .cmp(&a.last_played)
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
            .then_with(|| a.id.cmp(&b.id))
    });
    items.dedup_by(|a, b| a.id == b.id);
    items
}

/// The most characters a title from a file this service does not control keeps (a `.play` app's
/// `play.json`, a profile's Steam item).
pub const MAX_TEXT_CHARS: usize = 120;

/// Text from a file this service does not control, as an item shows it: control characters
/// stripped, trimmed, cut at `MAX_TEXT_CHARS`; `None` when nothing is left.
pub fn clip(s: &str) -> Option<String> {
    let clean: String = s.chars().filter(|c| !c.is_control()).collect();
    let clean = clean.trim();
    (!clean.is_empty()).then(|| clean.chars().take(MAX_TEXT_CHARS).collect())
}

/// The Flatpak items of the system installation (a `.play` app with its extra keys), in the
/// order of `merge`. A failing lister gives nothing (and is logged). The Steam items are per
/// profile and come in through `PutProfileItems` (ADR-045, `view.rs`): this service reads no home.
pub fn scan(lister: &dyn AppLister, play_root: &Path, runners_dir: &Path) -> Vec<Item> {
    let flatpak_items = match lister.list() {
        Ok(text) => {
            let mut items = flatpak::parse_list(&text, lister);
            // Only apps from the console's own remote: another remote's `play.*` app could
            // ship a trust.json of its own.
            let ours = flatpak::play_origin_ids(&text);
            for item in &mut items {
                if let Some(id) = item.id.strip_prefix("flatpak:") {
                    if ours.contains(id) {
                        let id = id.to_owned();
                        play::enrich(item, &id, play_root, runners_dir);
                    }
                }
            }
            items
        }
        Err(err) => {
            eprintln!("ruya-library: Flatpak list unavailable: {err}");
            Vec::new()
        }
    };
    merge(Vec::new(), flatpak_items)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::flatpak::FixtureLister;

    fn item(id: &str, source: Source, title: &str, last_played: i64) -> Item {
        Item {
            id: id.to_owned(),
            kind: if source == Source::Steam {
                Kind::Game
            } else {
                Kind::App
            },
            title: title.to_owned(),
            source,
            launch: String::new(),
            art: Vec::new(),
            last_played,
            play: None,
            declared: Vec::new(),
        }
    }

    #[test]
    fn order_is_last_played_then_title_then_id() {
        let steam = vec![
            item("steam:2", Source::Steam, "banana", 0),
            item("steam:1", Source::Steam, "Zeta", 100),
        ];
        let flat = vec![
            item("flatpak:b", Source::Flatpak, "Apple", 0),
            item("flatpak:a", Source::Flatpak, "apple", 0),
            item("flatpak:c", Source::Flatpak, "Mid", 50),
        ];
        let ids: Vec<String> = merge(steam, flat).into_iter().map(|i| i.id).collect();
        assert_eq!(
            ids,
            ["steam:1", "flatpak:c", "flatpak:a", "flatpak:b", "steam:2"]
        );
    }

    #[test]
    fn order_does_not_depend_on_input_order() {
        let a = vec![item("steam:1", Source::Steam, "Same", 0)];
        let b = vec![item("flatpak:x", Source::Flatpak, "Same", 0)];
        assert_eq!(merge(a.clone(), b.clone()), merge(b.clone(), a.clone()));
        assert_eq!(merge(a, b)[0].id, "flatpak:x");
    }

    #[test]
    fn scan_lists_the_flatpak_apps_and_survives_a_failing_lister() {
        struct Broken;
        impl AppLister for Broken {
            fn list(&self) -> Result<String, String> {
                Err("no flatpak".into())
            }
        }
        let lister = FixtureLister::new("a.b.C\tCee\tflathub\nd.e.Game\tTux\tflathub\n")
            .with_desktop("d.e.Game", "[Desktop Entry]\nCategories=Game;\n");
        let none = Path::new("/nonexistent");
        let kinds: Vec<(String, Kind)> = scan(&lister, none, none)
            .into_iter()
            .map(|i| (i.id, i.kind))
            .collect();
        assert_eq!(
            kinds,
            [
                ("flatpak:a.b.C".to_owned(), Kind::App),
                ("flatpak:d.e.Game".to_owned(), Kind::Game)
            ]
        );
        assert!(scan(&Broken, none, none).is_empty());
    }

    #[test]
    fn clip_strips_control_characters_trims_and_cuts() {
        assert_eq!(clip("  a\u{7}b\nc  ").as_deref(), Some("abc"));
        assert_eq!(clip(" \t\n "), None);
        assert_eq!(
            clip(&"\u{e9}".repeat(130)).unwrap().chars().count(),
            MAX_TEXT_CHARS
        );
    }
}
