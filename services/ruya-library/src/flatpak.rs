//! Installed Flatpak apps, from the text output of
//! `flatpak list --app --columns=application,name,origin` (tab-separated, no header).

use crate::catalog::{Item, Kind, Source};

use std::collections::HashMap;

/// Runs `flatpak list` and reads exported desktop entries; a trait so the rest is testable
/// without Flatpak.
pub trait AppLister: Send + Sync {
    /// The raw output of the list command.
    fn list(&self) -> Result<String, String>;

    /// The text of the exported desktop entry of an application id, if there is one.
    fn desktop_entry(&self, _id: &str) -> Option<String> {
        None
    }
}

/// Fixed output, for tests and `--session` development.
pub struct FixtureLister {
    list: String,
    desktops: HashMap<String, String>,
}

impl FixtureLister {
    pub fn new(list: &str) -> Self {
        FixtureLister {
            list: list.to_owned(),
            desktops: HashMap::new(),
        }
    }

    /// Adds the desktop entry of an application id.
    pub fn with_desktop(mut self, id: &str, text: &str) -> Self {
        self.desktops.insert(id.to_owned(), text.to_owned());
        self
    }
}

impl AppLister for FixtureLister {
    fn list(&self) -> Result<String, String> {
        Ok(self.list.clone())
    }

    fn desktop_entry(&self, id: &str) -> Option<String> {
        self.desktops.get(id).cloned()
    }
}

/// The system installation; user installations are out of scope.
#[cfg(target_os = "linux")]
const SYSTEM_INSTALLATION: &str = "/var/lib/flatpak";

#[cfg(target_os = "linux")]
pub struct FlatpakCli;

#[cfg(target_os = "linux")]
impl AppLister for FlatpakCli {
    fn list(&self) -> Result<String, String> {
        let out = std::process::Command::new("flatpak")
            .args(["list", "--app", "--columns=application,name,origin"])
            .output()
            .map_err(|e| format!("cannot run flatpak: {e}"))?;
        if !out.status.success() {
            return Err(format!("flatpak list failed: {}", out.status));
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }

    fn desktop_entry(&self, id: &str) -> Option<String> {
        // An id with a separator would leave the exports directory.
        if id.contains('/') || id.contains('\\') {
            return None;
        }
        let path = std::path::Path::new(SYSTEM_INSTALLATION)
            .join("exports/share/applications")
            .join(format!("{id}.desktop"));
        std::fs::read(path)
            .ok()
            .map(|b| String::from_utf8_lossy(&b).into_owned())
    }
}

/// True when the `[Desktop Entry]` group's `Categories` list contains `Game`. Other groups and
/// localized keys are ignored; text that is not a desktop file is simply not a game.
pub fn is_game(desktop: &str) -> bool {
    let mut in_entry = false;
    for line in desktop.lines().map(str::trim) {
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
        } else if in_entry {
            if let Some((key, value)) = line.split_once('=') {
                if key.trim() == "Categories" {
                    return value.split(';').any(|c| c.trim() == "Game");
                }
            }
        }
    }
    false
}

/// One item per row. A row without an application id is skipped; a missing name falls back to
/// the id. The origin column is not used yet. The kind is `game` when the desktop entry's
/// categories say so (`is_game`), else `app`.
pub fn parse_list(output: &str, lister: &dyn AppLister) -> Vec<Item> {
    output
        .lines()
        .filter_map(|line| {
            let mut cols = line.split('\t').map(str::trim);
            let id = cols.next().filter(|id| !id.is_empty())?;
            let title = cols.next().filter(|t| !t.is_empty()).unwrap_or(id);
            Some(Item {
                id: format!("flatpak:{id}"),
                kind: if lister.desktop_entry(id).is_some_and(|d| is_game(&d)) {
                    Kind::Game
                } else {
                    Kind::App
                },
                title: title.to_owned(),
                source: Source::Flatpak,
                launch: format!("flatpak:{id}"),
                art: Vec::new(),
                last_played: 0,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn none() -> FixtureLister {
        FixtureLister::new("")
    }

    fn kind_of(desktop: Option<&str>) -> Kind {
        let row = "x.Y\tWhy\tflathub\n";
        let mut lister = FixtureLister::new(row);
        if let Some(text) = desktop {
            lister = lister.with_desktop("x.Y", text);
        }
        parse_list(row, &lister)[0].kind
    }

    #[test]
    fn game_category_makes_a_game() {
        let d = "[Desktop Entry]\nName=Tux\nCategories=Game;ArcadeGame;\n";
        assert_eq!(kind_of(Some(d)), Kind::Game);
        assert_eq!(
            kind_of(Some("[Desktop Entry]\nCategories = Utility; Game\n")),
            Kind::Game
        );
    }

    #[test]
    fn other_categories_no_file_and_garbage_are_apps() {
        assert_eq!(
            kind_of(Some("[Desktop Entry]\nCategories=AudioVideo;\n")),
            Kind::App
        );
        assert_eq!(kind_of(None), Kind::App);
        assert_eq!(kind_of(Some("\u{0}\u{1}=;;[[\n=\n[")), Kind::App);
        assert_eq!(kind_of(Some("")), Kind::App);
    }

    #[test]
    fn game_outside_the_desktop_entry_group_is_an_app() {
        let d = "[Desktop Entry]\nName=X\n[Desktop Action new]\nCategories=Game;\n";
        assert_eq!(kind_of(Some(d)), Kind::App);
        assert_eq!(kind_of(Some("[Other]\nCategories=Game;\n")), Kind::App);
    }

    #[test]
    fn localized_and_similar_keys_are_ignored() {
        let d = "[Desktop Entry]\nCategories[de]=Game;\nXCategories=Game;\nCategories=Utility;\n";
        assert_eq!(kind_of(Some(d)), Kind::App);
    }

    #[test]
    fn empty_output_is_no_items() {
        assert!(parse_list("", &none()).is_empty());
        assert!(parse_list("\n\n", &none()).is_empty());
    }

    #[test]
    fn normal_rows() {
        let items = parse_list(
            "org.example.Racer\tTurbo Racer\tflathub\norg.example.Doc\tDocs\tflathub\n",
            &none(),
        );
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].id, "flatpak:org.example.Racer");
        assert_eq!(items[0].title, "Turbo Racer");
        assert_eq!(items[0].launch, "flatpak:org.example.Racer");
        assert_eq!(items[0].kind, Kind::App);
        assert_eq!(items[0].source, Source::Flatpak);
    }

    #[test]
    fn rows_with_missing_columns() {
        let items = parse_list(
            "org.example.OnlyId\norg.example.NoOrigin\tNamed\n\torphan name\t\n",
            &none(),
        );
        assert_eq!(items.len(), 2, "the row without an id is skipped");
        assert_eq!(items[0].title, "org.example.OnlyId");
        assert_eq!(items[1].title, "Named");
    }

    #[test]
    fn windows_line_endings_and_blank_rows() {
        let items = parse_list("a.b.C\tCee\tflathub\r\n\r\n", &none());
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].title, "Cee");
    }
}
