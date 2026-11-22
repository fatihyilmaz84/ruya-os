//! The image's app table (RUY-1050, ADR-043): `/usr/share/ruyaos/apps/<flatpak-id>.conf`, one
//! keyfile per app that needs something the app's own Flatpak metadata does not say. A new
//! per-app behaviour is a new key here, never a new file. Group `[App]`, keys:
//!
//! - `args`: the arguments `flatpak run` passes to the app, space separated, each one plain word
//!   (`spawner::valid_app_arg`). Steam: `-gamepadui`.
//! - `display`: `wayland`, `x11` or `gamescope` (overrides the metadata's sockets,
//!   `x11::needs_x11`). `gamescope` parses, and the launch refuses it until it is built.
//! - `freeze`: `always` or `never` (parsed and exposed; the Hub's pause reads it later).
//! - `children`: `steam` (parsed and exposed; the games an app starts are listed later).
//!
//! The file name must be a valid Flatpak id. A file that does not parse, names an unknown key or
//! holds a bad value is refused as a whole (the app then has no entry) and reported by `problems`.

use std::collections::HashMap;
use std::path::Path;

use ruya_flatpak::valid_session_app_id;
use ruya_keyfile::Keyfile;

use crate::spawner::valid_app_arg;

/// Where the image ships the table.
pub const APPS_DIR: &str = "/usr/share/ruyaos/apps";
const GROUP: &str = "App";
const KEYS: [&str; 4] = ["args", "display", "freeze", "children"];
const EXTENSION: &str = ".conf";

/// How an app reaches the screen, as the table says.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Display {
    Wayland,
    X11,
    Gamescope,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Freeze {
    Always,
    Never,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Children {
    Steam,
}

/// One app's row; a key the file does not have is `None` (or no arguments).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AppEntry {
    pub args: Vec<String>,
    pub display: Option<Display>,
    pub freeze: Option<Freeze>,
    pub children: Option<Children>,
}

impl AppEntry {
    /// Read one file's text. The error says what is wrong, for the log.
    pub fn parse(text: &str) -> Result<AppEntry, String> {
        let file = Keyfile::parse(text).map_err(|e| e.to_string())?;
        if let Some(other) = file.groups().iter().find(|g| g.name != GROUP) {
            return Err(format!("unknown group [{}]", other.name));
        }
        let Some(group) = file.group(GROUP) else {
            return Err(format!("no [{GROUP}] group"));
        };
        if let Some(key) = group.unknown_key(&KEYS) {
            return Err(format!("unknown key {key}"));
        }
        let mut entry = AppEntry::default();
        if let Some(args) = group.get("args") {
            entry.args = args.split_whitespace().map(str::to_owned).collect();
            if let Some(bad) = entry.args.iter().find(|a| !valid_app_arg(a)) {
                return Err(format!("args: {bad:?} is not a plain word"));
            }
        }
        if let Some(v) = group.get("display") {
            entry.display = Some(match v {
                "wayland" => Display::Wayland,
                "x11" => Display::X11,
                "gamescope" => Display::Gamescope,
                _ => return Err(format!("display: {v:?} is not wayland, x11 or gamescope")),
            });
        }
        if let Some(v) = group.get("freeze") {
            entry.freeze = Some(match v {
                "always" => Freeze::Always,
                "never" => Freeze::Never,
                _ => return Err(format!("freeze: {v:?} is not always or never")),
            });
        }
        if let Some(v) = group.get("children") {
            entry.children = Some(match v {
                "steam" => Children::Steam,
                _ => return Err(format!("children: {v:?} is not steam")),
            });
        }
        Ok(entry)
    }
}

/// Every app's row. Built per launch from the image folder (a handful of tiny files).
#[derive(Debug, Default)]
pub struct AppTable {
    entries: HashMap<String, AppEntry>,
    problems: Vec<String>,
}

impl AppTable {
    /// Read every `<id>.conf` in `dir`. A missing folder is an empty table; a refused file is
    /// listed in `problems` and gives its app no entry.
    pub fn load(dir: &Path) -> AppTable {
        let mut table = AppTable::default();
        let Ok(read) = std::fs::read_dir(dir) else {
            return table;
        };
        for item in read.flatten() {
            let name = item.file_name().to_string_lossy().into_owned();
            let Some(id) = name.strip_suffix(EXTENSION) else {
                table.problems.push(format!("{name}: not a .conf file"));
                continue;
            };
            if !valid_session_app_id(id) {
                table
                    .problems
                    .push(format!("{name}: the name is not a Flatpak id"));
                continue;
            }
            let text = match std::fs::read_to_string(item.path()) {
                Ok(text) => text,
                Err(e) => {
                    table.problems.push(format!("{name}: {e}"));
                    continue;
                }
            };
            match AppEntry::parse(&text) {
                Ok(entry) => {
                    table.entries.insert(id.to_owned(), entry);
                }
                Err(e) => table.problems.push(format!("{name}: {e}")),
            }
        }
        table.problems.sort();
        table
    }

    /// What the files refused, one line each, for the journal.
    pub fn problems(&self) -> &[String] {
        &self.problems
    }

    pub fn args(&self, id: &str) -> Vec<String> {
        self.entries
            .get(id)
            .map(|e| e.args.clone())
            .unwrap_or_default()
    }

    pub fn display(&self, id: &str) -> Option<Display> {
        self.entries.get(id).and_then(|e| e.display)
    }

    pub fn freeze(&self, id: &str) -> Option<Freeze> {
        self.entries.get(id).and_then(|e| e.freeze)
    }

    pub fn children(&self, id: &str) -> Option<Children> {
        self.entries.get(id).and_then(|e| e.children)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    const STEAM: &str = "com.valvesoftware.Steam";

    pub(crate) fn image_dir() -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../image/rootfs/usr/share/ruyaos/apps")
    }

    #[test]
    fn every_shipped_file_parses_and_steam_has_its_values() {
        let table = AppTable::load(&image_dir());
        assert_eq!(table.problems(), Vec::<String>::new());
        assert_eq!(table.args(STEAM), ["-gamepadui"]);
        assert_eq!(table.display(STEAM), Some(Display::X11));
        assert_eq!(table.freeze(STEAM), Some(Freeze::Always));
        assert_eq!(table.children(STEAM), Some(Children::Steam));
        // Another app has no row.
        assert!(table.args("org.other.App").is_empty());
        assert_eq!(table.display("org.other.App"), None);
        assert_eq!(table.freeze("org.other.App"), None);
        assert_eq!(table.children("org.other.App"), None);
    }

    #[test]
    fn a_row_is_read_key_by_key() {
        let e = AppEntry::parse(
            "# why\n[App]\nargs = -a  --b=1\ndisplay=gamescope\nfreeze=never\nchildren=steam\n",
        )
        .expect("parses");
        assert_eq!(e.args, ["-a", "--b=1"]);
        assert_eq!(e.display, Some(Display::Gamescope));
        assert_eq!(e.freeze, Some(Freeze::Never));
        assert_eq!(e.children, Some(Children::Steam));
        assert_eq!(
            AppEntry::parse("[App]\n").expect("empty"),
            AppEntry::default()
        );
        assert_eq!(
            AppEntry::parse("[App]\ndisplay=wayland\n")
                .expect("w")
                .display,
            Some(Display::Wayland)
        );
    }

    #[test]
    fn a_row_with_anything_unknown_or_bad_is_refused() {
        for (text, want) in [
            ("[App]\nargz=-a\n", "unknown key argz"),
            ("[App]\ndisplay=vulkan\n", "display"),
            ("[App]\nfreeze=sometimes\n", "freeze"),
            ("[App]\nchildren=wine\n", "children"),
            ("[App]\nargs=-ok bad;word\n", "plain word"),
            ("[App]\nargs=-a\n[Extra]\n", "unknown group"),
            ("[Extra]\nargs=-a\n", "unknown group"),
            ("args=-a\n", "before any"),
            ("[App]\nargs=-a\nargs=-b\n", "twice"),
            ("", "no [App]"),
        ] {
            let err = AppEntry::parse(text).expect_err(text);
            assert!(err.contains(want), "{text:?}: {err}");
        }
        let long = format!("[App]\nargs={}\n", "x".repeat(65));
        assert!(AppEntry::parse(&long).is_err());
    }

    #[test]
    fn a_file_name_that_is_not_a_flatpak_id_is_refused() {
        let dir = tempfile::tempdir().expect("tmp");
        let ok = "[App]\nargs=-a\n";
        std::fs::write(dir.path().join("org.good.App.conf"), ok).expect("write");
        std::fs::write(dir.path().join("NotAnId.conf"), ok).expect("write");
        std::fs::write(dir.path().join("org.bad.App.conf"), "[App]\nnope=1\n").expect("write");
        std::fs::write(dir.path().join("org.other.App.txt"), ok).expect("write");
        let table = AppTable::load(dir.path());
        assert_eq!(table.args("org.good.App"), ["-a"]);
        assert!(table.args("NotAnId").is_empty());
        assert!(table.args("org.bad.App").is_empty());
        let problems = table.problems();
        assert_eq!(problems.len(), 3, "{problems:?}");
        assert!(problems
            .iter()
            .any(|p| p.contains("NotAnId.conf: the name")));
        assert!(problems
            .iter()
            .any(|p| p.contains("org.bad.App.conf: unknown key")));
        assert!(problems.iter().any(|p| p.contains("org.other.App.txt")));
        // A missing folder is an empty table, not an error.
        assert!(AppTable::load(&dir.path().join("none"))
            .problems()
            .is_empty());
    }
}
