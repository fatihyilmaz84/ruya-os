//! The merged library: Steam games and Flatpak apps in one deterministic order.

use std::path::PathBuf;

use crate::flatpak::{self, AppLister};
use crate::steam;

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

/// Reads every Steam root and the Flatpak list. A failing part contributes nothing (and is
/// logged): the library of the other source still shows.
pub fn scan(steam_roots: &[PathBuf], lister: &dyn AppLister) -> Vec<Item> {
    let mut steam_items: Vec<Item> = Vec::new();
    for root in steam_roots {
        for item in steam::scan_root(root) {
            if !steam_items.iter().any(|i| i.id == item.id) {
                steam_items.push(item);
            }
        }
    }
    let flatpak_items = match lister.list() {
        Ok(text) => flatpak::parse_list(&text),
        Err(err) => {
            eprintln!("ruya-library: Flatpak list unavailable: {err}");
            Vec::new()
        }
    };
    merge(steam_items, flatpak_items)
}

/// Steam roots under a home directory (spec 03 §5): native Steam and the Flatpak Steam.
pub fn steam_roots(home: &std::path::Path) -> Vec<PathBuf> {
    vec![
        home.join(".local/share/Steam"),
        home.join(".var/app/com.valvesoftware.Steam/.local/share/Steam"),
    ]
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
    fn scan_merges_both_sources_and_survives_a_failing_lister() {
        struct Broken;
        impl AppLister for Broken {
            fn list(&self) -> Result<String, String> {
                Err("no flatpak".into())
            }
        }
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("Steam");
        std::fs::create_dir_all(root.join("steamapps")).unwrap();
        std::fs::write(
            root.join("steamapps/appmanifest_5.acf"),
            "\"AppState\" { \"appid\" \"5\" \"name\" \"Five\" \"StateFlags\" \"4\" }",
        )
        .unwrap();
        let roots = vec![root.clone(), root];
        let both = scan(&roots, &FixtureLister("a.b.C\tCee\tflathub\n".into()));
        assert_eq!(
            both.len(),
            2,
            "the same root twice lists a game once: {both:?}"
        );
        assert_eq!(scan(&roots, &Broken).len(), 1);
    }

    #[test]
    fn steam_roots_are_native_then_flatpak() {
        let roots = steam_roots(std::path::Path::new("/home/p"));
        assert!(roots[0].ends_with(".local/share/Steam"));
        assert!(roots[1]
            .to_string_lossy()
            .contains("com.valvesoftware.Steam"));
    }
}
