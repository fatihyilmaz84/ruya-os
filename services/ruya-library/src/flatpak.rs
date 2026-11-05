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

    /// The text of the installed appstream metainfo of an application id, if there is one.
    fn metainfo(&self, _id: &str) -> Option<String> {
        None
    }
}

/// Fixed output, for tests and `--session` development.
pub struct FixtureLister {
    list: String,
    desktops: HashMap<String, String>,
    metainfos: HashMap<String, String>,
}

impl FixtureLister {
    pub fn new(list: &str) -> Self {
        FixtureLister {
            list: list.to_owned(),
            desktops: HashMap::new(),
            metainfos: HashMap::new(),
        }
    }

    /// Adds the desktop entry of an application id.
    pub fn with_desktop(mut self, id: &str, text: &str) -> Self {
        self.desktops.insert(id.to_owned(), text.to_owned());
        self
    }

    /// Adds the appstream metainfo of an application id.
    pub fn with_metainfo(mut self, id: &str, text: &str) -> Self {
        self.metainfos.insert(id.to_owned(), text.to_owned());
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

    fn metainfo(&self, id: &str) -> Option<String> {
        self.metainfos.get(id).cloned()
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
            // --system: the image serves the system installation only (spec 03 §5); a user
            // installation of the service's own account would be empty anyway.
            .args([
                "list",
                "--system",
                "--app",
                "--columns=application,name,origin",
            ])
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
        read_text(
            &std::path::Path::new(SYSTEM_INSTALLATION)
                .join("exports/share/applications")
                .join(format!("{id}.desktop")),
        )
    }

    fn metainfo(&self, id: &str) -> Option<String> {
        if id.contains('/') || id.contains('\\') {
            return None;
        }
        // Flatpak exports the metainfo next to the desktop entry; the app's own files are the
        // fallback (the `current` branch's active deployment).
        let root = std::path::Path::new(SYSTEM_INSTALLATION);
        [
            root.join(format!("exports/share/metainfo/{id}.metainfo.xml")),
            root.join(format!("exports/share/appdata/{id}.appdata.xml")),
            root.join(format!(
                "app/{id}/current/active/files/share/metainfo/{id}.metainfo.xml"
            )),
        ]
        .iter()
        .find_map(|p| read_text(p))
    }
}

#[cfg(target_os = "linux")]
fn read_text(path: &std::path::Path) -> Option<String> {
    std::fs::read(path)
        .ok()
        .map(|b| String::from_utf8_lossy(&b).into_owned())
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

/// The unlocalized `Name=` of the `[Desktop Entry]` group (`Name[de]=` is a different key).
pub fn desktop_name(desktop: &str) -> Option<String> {
    let mut in_entry = false;
    for line in desktop.lines().map(str::trim) {
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
        } else if in_entry {
            if let Some((key, value)) = line.split_once('=') {
                if key.trim() == "Name" {
                    return Some(value.trim().to_owned()).filter(|v| !v.is_empty());
                }
            }
        }
    }
    None
}

fn unescape(text: &str) -> String {
    text.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

/// The position of the next opening tag `<tag>` or `<tag attr...>` at or after `from` (not
/// `<tag_other>`, not a self-closing `<tag/>`), and the end of that tag.
fn open_tag(xml: &str, tag: &str, from: usize) -> Option<(usize, usize)> {
    let needle = format!("<{tag}");
    let mut at = from;
    while let Some(found) = xml[at..].find(&needle) {
        let start = at + found;
        let after = start + needle.len();
        let end = after + xml[after..].find('>')?;
        let next = xml[after..].chars().next()?;
        if (next == '>' || next.is_whitespace()) && !xml[..end].ends_with('/') {
            return Some((start, end + 1));
        }
        at = after;
    }
    None
}

/// The unlocalized `<name>` of an appstream metainfo. A `<developer>` block has a `<name>` of its
/// own (who made the app, not what it is called) and is skipped; `<name xml:lang="de">` is a
/// translation and is skipped, while other attributes (`translatable="no"`) are fine. Not an XML
/// parser: a metainfo that is not plain text of this shape gives `None` and the next source is
/// tried.
pub fn metainfo_name(xml: &str) -> Option<String> {
    let mut rest = xml.to_owned();
    while let Some((start, tag_end)) = open_tag(&rest, "developer", 0) {
        match rest[tag_end..].find("</developer>") {
            Some(end) => rest.replace_range(start..tag_end + end + "</developer>".len(), ""),
            None => rest.truncate(start),
        }
    }
    let mut from = 0;
    while let Some((start, tag_end)) = open_tag(&rest, "name", from) {
        from = tag_end;
        if rest[start..tag_end].contains("xml:lang") {
            continue;
        }
        let len = rest[tag_end..].find("</name>")?;
        let name = unescape(rest[tag_end..tag_end + len].trim());
        return Some(name).filter(|n| !n.is_empty());
    }
    None
}

/// What `flatpak list` prints when the app has no appstream name: the last part of the id.
fn is_placeholder(listed: &str, id: &str) -> bool {
    listed.is_empty() || id.rsplit('.').next() == Some(listed)
}

/// The title of an app. `flatpak list` reads the name from the remote's appstream catalog; when
/// that has none (a local or test repository, a sideload) it prints the id's last part, which is
/// no name. Then the app's own exported files are asked, in this order: the desktop entry's
/// `Name=` (every launchable app has one, and it is the name the app calls itself), then the
/// installed metainfo `<name>`; the id is the last resort. A listed name that merely equals the
/// last id part ("Notes" for `org.ruyaos.Notes`) is kept when the files do not say otherwise.
fn title_of(id: &str, listed: &str, lister: &dyn AppLister) -> String {
    if !is_placeholder(listed, id) {
        return listed.to_owned();
    }
    lister
        .desktop_entry(id)
        .and_then(|d| desktop_name(&d))
        .or_else(|| lister.metainfo(id).and_then(|m| metainfo_name(&m)))
        .unwrap_or_else(|| if listed.is_empty() { id } else { listed }.to_owned())
}

/// One item per row. A row without an application id is skipped; a missing name falls back to
/// the id (see `title_of`). The origin column is not used yet. The kind is `game` when the desktop entry's
/// categories say so (`is_game`), else `app`.
pub fn parse_list(output: &str, lister: &dyn AppLister) -> Vec<Item> {
    output
        .lines()
        .filter_map(|line| {
            let mut cols = line.split('\t').map(str::trim);
            let id = cols.next().filter(|id| !id.is_empty())?;
            let title = title_of(id, cols.next().unwrap_or(""), lister);
            Some(Item {
                id: format!("flatpak:{id}"),
                kind: if lister.desktop_entry(id).is_some_and(|d| is_game(&d)) {
                    Kind::Game
                } else {
                    Kind::App
                },
                title,
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

    fn title_with(row: &str, desktop: Option<&str>, metainfo: Option<&str>) -> String {
        let mut lister = FixtureLister::new(row);
        if let Some(text) = desktop {
            lister = lister.with_desktop("org.example.TestGame", text);
        }
        if let Some(text) = metainfo {
            lister = lister.with_metainfo("org.example.TestGame", text);
        }
        parse_list(row, &lister)[0].title.clone()
    }

    const PLACEHOLDER: &str = "org.example.TestGame\tTestGame\ttest\n";

    #[test]
    fn a_placeholder_title_becomes_the_desktop_entry_name() {
        let d = "[Desktop Entry]\nName[de]=Testspiel\nName=Test Game\nCategories=Game;\n";
        assert_eq!(title_with(PLACEHOLDER, Some(d), None), "Test Game");
        // No name column at all is a placeholder too.
        assert_eq!(
            title_with("org.example.TestGame\t\ttest\n", Some(d), None),
            "Test Game"
        );
    }

    #[test]
    fn without_a_desktop_name_the_metainfo_name_is_used() {
        let m = "<component>\n <id>org.example.TestGame</id>\n <name xml:lang=\"de\">Testspiel</name>\n <name>Test &amp; Game</name>\n</component>";
        assert_eq!(title_with(PLACEHOLDER, None, Some(m)), "Test & Game");
        let no_name = "[Desktop Entry]\nCategories=Game;\n";
        assert_eq!(
            title_with(PLACEHOLDER, Some(no_name), Some(m)),
            "Test & Game"
        );
        let dev = "<component><developer><name>Some Studio</name></developer><name>Real Name</name></component>";
        assert_eq!(title_with(PLACEHOLDER, None, Some(dev)), "Real Name");
        let only_dev = "<component><developer><name>Some Studio</name></developer></component>";
        assert_eq!(title_with(PLACEHOLDER, None, Some(only_dev)), "TestGame");
    }

    #[test]
    fn metainfo_name_takes_other_attributes_but_not_translations() {
        let m = "<component><name xml:lang=\"de\">Testspiel</name><name translatable=\"no\">Test Game</name></component>";
        assert_eq!(title_with(PLACEHOLDER, None, Some(m)), "Test Game");
        let only_translated = "<component><name xml:lang=\"de\">Testspiel</name></component>";
        assert_eq!(
            title_with(PLACEHOLDER, None, Some(only_translated)),
            "TestGame"
        );
        // `<developer_name>` is not a `<developer>` block and must not cut the document short.
        let m =
            "<component><developer_name>Studio</developer_name><name>Real Name</name></component>";
        assert_eq!(title_with(PLACEHOLDER, None, Some(m)), "Real Name");
        assert_eq!(
            metainfo_name("<names>x</names><name/><name>Y</name>").as_deref(),
            Some("Y")
        );
    }

    #[test]
    fn the_desktop_name_wins_over_the_metainfo_and_a_real_listed_name_over_both() {
        let d = "[Desktop Entry]\nName=From Desktop\n";
        let m = "<component><name>From Metainfo</name></component>";
        assert_eq!(title_with(PLACEHOLDER, Some(d), Some(m)), "From Desktop");
        assert_eq!(
            title_with(
                "org.example.TestGame\tListed Name\ttest\n",
                Some(d),
                Some(m)
            ),
            "Listed Name"
        );
    }

    #[test]
    fn no_source_keeps_the_listed_name_or_the_id() {
        assert_eq!(title_with(PLACEHOLDER, None, None), "TestGame");
        assert_eq!(
            title_with("org.example.TestGame\t\ttest\n", None, None),
            "org.example.TestGame"
        );
        assert_eq!(
            title_with(
                PLACEHOLDER,
                Some("[Desktop Entry]\nName=\n"),
                Some("<broken")
            ),
            "TestGame"
        );
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
