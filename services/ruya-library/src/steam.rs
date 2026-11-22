//! Steam games, read-only, from `steamapps/libraryfolders.vdf` and `steamapps/appmanifest_*.acf`.
//! Every file is read through `ruya_fs::Dir` (never through a link) with a size cap: the Steam
//! folders belong to the player and to Steam, not to this service.

use std::path::{Path, PathBuf};

use ruya_fs::{Dir, Kind as FsKind};
use ruya_vdf::{self as vdf, Value};

use crate::catalog::{Item, Kind, Source};

/// The most a `libraryfolders.vdf` may hold; a real one is a few kilobytes.
const MAX_LIBRARYFOLDERS: u64 = 1024 * 1024;
/// The most an `appmanifest_*.acf` may hold; a real one is a few kilobytes.
const MAX_MANIFEST: u64 = 1024 * 1024;
/// The most manifests read from one library; a real library has a few hundred.
const MAX_MANIFESTS: usize = 4096;

/// Entries that are tooling, not games.
const SKIPPED_PREFIXES: [&str; 3] = [
    "Proton",
    "Steam Linux Runtime",
    "Steamworks Common Redistributables",
];

/// `StateFlags` bit 4: fully installed.
const FULLY_INSTALLED: u64 = 4;

/// Library folders of a Steam root: the root itself, then the paths in `libraryfolders.vdf`
/// (new format: `"0" { "path" "..." }`; old format: `"1" "path"`). A missing or broken file
/// leaves just the root.
pub fn library_paths(root: &Path) -> Vec<PathBuf> {
    let mut paths = vec![root.to_path_buf()];
    let rel = Path::new("steamapps").join("libraryfolders.vdf");
    let Some(text) = read_text(root, &rel, MAX_LIBRARYFOLDERS) else {
        return paths;
    };
    let Ok(doc) = vdf::parse(&text) else {
        eprintln!("ruya-library: cannot parse {}", root.join(&rel).display());
        return paths;
    };
    let Some(folders) = vdf::find(&doc, "libraryfolders") else {
        return paths;
    };
    for entry in folders.value.entries() {
        let key = &entry.key;
        if key.is_empty() || !key.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let path = match &entry.value {
            Value::Str(p) => Some(p.as_str()),
            value @ Value::Obj(_) => value.get_str("path"),
        };
        if let Some(p) = path.filter(|p| !p.is_empty()) {
            let p = PathBuf::from(p);
            if !paths.contains(&p) {
                paths.push(p);
            }
        }
    }
    paths
}

/// The text of the file `rel` below the folder `base` (which is trusted: it is a Steam root or
/// a library path). `None` when it is missing, a link, not a regular file, over `limit` bytes or
/// not UTF-8.
fn read_text(base: &Path, rel: &Path, limit: u64) -> Option<String> {
    let dir = Dir::open(base).ok()?;
    let bytes = dir.read(rel, limit).ok()?;
    String::from_utf8(bytes).ok()
}

/// One game from the text of an `appmanifest_*.acf`; `None` for anything that is not a fully
/// installed game.
pub fn parse_manifest(text: &str) -> Option<Item> {
    let doc = Value::Obj(vdf::parse(text).ok()?);
    let state = doc.get("AppState")?;
    let appid = state.get_str("appid")?.trim();
    if appid.is_empty() || !appid.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let flags: u64 = state.get_str("StateFlags")?.trim().parse().ok()?;
    if flags & FULLY_INSTALLED == 0 {
        return None;
    }
    let name = state.get_str("name")?.trim();
    if name.is_empty() || SKIPPED_PREFIXES.iter().any(|p| name.starts_with(p)) {
        return None;
    }
    let last_played = state
        .get_str("LastPlayed")
        .and_then(|s| s.trim().parse::<i64>().ok())
        .unwrap_or(0)
        .max(0);
    Some(Item {
        id: format!("steam:{appid}"),
        kind: Kind::Game,
        title: name.to_owned(),
        source: Source::Steam,
        launch: format!("steam://rungameid/{appid}"),
        art: Vec::new(),
        last_played,
        play: None,
    })
}

/// All games of the libraries of one Steam root. Unreadable files are skipped, links are not
/// followed, and a library is read up to [`MAX_MANIFESTS`] manifests.
pub fn scan_root(root: &Path) -> Vec<Item> {
    let mut items: Vec<Item> = Vec::new();
    for lib in library_paths(root) {
        let Ok(dir) = Dir::open(&lib) else {
            continue;
        };
        let Ok(entries) = dir.entries(Path::new("steamapps")) else {
            continue;
        };
        let manifests = entries
            .into_iter()
            .filter(|(name, kind)| {
                let name = name.to_string_lossy();
                *kind == FsKind::File && name.starts_with("appmanifest_") && name.ends_with(".acf")
            })
            .take(MAX_MANIFESTS);
        for (name, _) in manifests {
            let rel = Path::new("steamapps").join(name);
            let Some(text) = read_text(&lib, &rel, MAX_MANIFEST) else {
                continue;
            };
            if let Some(item) = parse_manifest(&text) {
                if !items.iter().any(|i| i.id == item.id) {
                    items.push(item);
                }
            }
        }
    }
    items
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIBRARYFOLDERS: &str =
        include_str!("../tests/fixtures/steam/steamapps/libraryfolders.vdf");
    const MANIFEST_RACER: &str =
        include_str!("../tests/fixtures/steam/steamapps/appmanifest_220.acf");
    const MANIFEST_PROTON: &str =
        include_str!("../tests/fixtures/lib2/steamapps/appmanifest_1493710.acf");
    const MANIFEST_PUZZLE: &str =
        include_str!("../tests/fixtures/lib2/steamapps/appmanifest_400.acf");

    /// The fixture tree on disk; `@ROOT@` and `@LIB2@` in libraryfolders.vdf are the two library
    /// paths.
    fn fixture_tree() -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("Steam");
        let lib2 = dir.path().join("games");
        std::fs::create_dir_all(root.join("steamapps")).unwrap();
        std::fs::create_dir_all(lib2.join("steamapps")).unwrap();
        let quote = |p: &Path| p.to_string_lossy().replace('\\', "\\\\");
        std::fs::write(
            root.join("steamapps/libraryfolders.vdf"),
            LIBRARYFOLDERS
                .replace("@ROOT@", &quote(&root))
                .replace("@LIB2@", &quote(&lib2)),
        )
        .unwrap();
        std::fs::write(root.join("steamapps/appmanifest_220.acf"), MANIFEST_RACER).unwrap();
        std::fs::write(lib2.join("steamapps/appmanifest_400.acf"), MANIFEST_PUZZLE).unwrap();
        std::fs::write(
            lib2.join("steamapps/appmanifest_1493710.acf"),
            MANIFEST_PROTON,
        )
        .unwrap();
        (dir, root)
    }

    #[test]
    fn fixture_tree_yields_the_two_real_games() {
        let (_dir, root) = fixture_tree();
        let mut items = scan_root(&root);
        items.sort_by(|a, b| a.id.cmp(&b.id));
        assert_eq!(items.len(), 2, "Proton is skipped: {items:?}");
        assert_eq!(items[0].id, "steam:220");
        assert_eq!(items[0].title, "Turbo Racer");
        assert_eq!(items[0].last_played, 1_700_000_000);
        assert_eq!(items[0].launch, "steam://rungameid/220");
        assert_eq!(items[0].kind, Kind::Game);
        assert_eq!(items[1].id, "steam:400");
        assert_eq!(items[1].title, "Block Puzzle");
        assert_eq!(items[1].last_played, 0, "no LastPlayed means unknown");
    }

    #[test]
    fn library_paths_lists_root_then_folders_once() {
        let (_dir, root) = fixture_tree();
        let paths = library_paths(&root);
        assert_eq!(paths.len(), 2, "{paths:?}");
        assert_eq!(paths[0], root);
    }

    #[test]
    fn old_format_library_folders() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("Steam");
        std::fs::create_dir_all(root.join("steamapps")).unwrap();
        std::fs::write(
            root.join("steamapps/libraryfolders.vdf"),
            "\"LibraryFolders\"\n{\n\t\"TimeNextStatsReport\"\t\"1\"\n\t\"1\"\t\"/mnt/other\"\n}\n",
        )
        .unwrap();
        let paths = library_paths(&root);
        assert_eq!(paths, vec![root, PathBuf::from("/mnt/other")]);
    }

    #[test]
    fn missing_or_broken_library_file_leaves_the_root() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(library_paths(dir.path()), vec![dir.path().to_path_buf()]);
        std::fs::create_dir_all(dir.path().join("steamapps")).unwrap();
        std::fs::write(dir.path().join("steamapps/libraryfolders.vdf"), "\"a\" {").unwrap();
        assert_eq!(library_paths(dir.path()), vec![dir.path().to_path_buf()]);
        assert!(scan_root(dir.path()).is_empty());
    }

    fn manifest(flags: &str) -> String {
        format!("\"AppState\"\n{{\n\"appid\" \"7\"\n\"name\" \"Seven\"\n\"StateFlags\" \"{flags}\"\n}}\n")
    }

    #[test]
    fn only_fully_installed_manifests_count() {
        assert!(parse_manifest(&manifest("4")).is_some());
        assert!(
            parse_manifest(&manifest("6")).is_some(),
            "bit 4 among others"
        );
        assert!(
            parse_manifest(&manifest("1026")).is_none(),
            "update required, bit 4 clear"
        );
        assert!(parse_manifest(&manifest("0")).is_none());
        assert!(parse_manifest(&manifest("x")).is_none());
    }

    #[test]
    fn keys_in_any_case() {
        let text = "\"AppState\" { \"AppID\" \"9\" \"Name\" \"Nine\" \"stateflags\" \"4\" \"lastplayed\" \"5\" }";
        let item = parse_manifest(text).unwrap();
        assert_eq!(item.id, "steam:9");
        assert_eq!(item.last_played, 5);
    }

    #[test]
    fn tooling_is_skipped() {
        for name in [
            "Proton 9.0",
            "Proton Experimental",
            "Steam Linux Runtime 3.0 (sniper)",
            "Steamworks Common Redistributables",
        ] {
            let text = format!(
                "\"AppState\" {{ \"appid\" \"1\" \"name\" \"{name}\" \"StateFlags\" \"4\" }}"
            );
            assert!(parse_manifest(&text).is_none(), "{name}");
        }
    }

    #[test]
    fn garbage_manifests_are_none() {
        assert!(parse_manifest("").is_none());
        assert!(parse_manifest("\"AppState\" {").is_none());
        assert!(parse_manifest("\"Other\" { \"appid\" \"1\" }").is_none());
        assert!(parse_manifest(
            "\"AppState\" { \"appid\" \"../x\" \"name\" \"n\" \"StateFlags\" \"4\" }"
        )
        .is_none());
    }

    #[test]
    fn an_oversized_manifest_is_refused() {
        let (_dir, root) = fixture_tree();
        let big = format!("{}{}", manifest("4"), " ".repeat(MAX_MANIFEST as usize));
        std::fs::write(root.join("steamapps/appmanifest_220.acf"), big).unwrap();
        let ids: Vec<_> = scan_root(&root).into_iter().map(|i| i.id).collect();
        assert_eq!(ids, vec!["steam:400"], "only the small manifest is read");
    }

    #[test]
    fn an_oversized_library_file_leaves_the_root() {
        let (_dir, root) = fixture_tree();
        let big = " ".repeat(MAX_LIBRARYFOLDERS as usize + 1);
        std::fs::write(root.join("steamapps/libraryfolders.vdf"), big).unwrap();
        assert_eq!(library_paths(&root), vec![root]);
    }

    #[cfg(unix)]
    #[test]
    fn a_link_to_a_manifest_is_refused() {
        let (dir, root) = fixture_tree();
        let elsewhere = dir.path().join("elsewhere.acf");
        std::fs::write(&elsewhere, manifest("4")).unwrap();
        std::os::unix::fs::symlink(&elsewhere, root.join("steamapps/appmanifest_7.acf")).unwrap();
        let ids: Vec<_> = scan_root(&root).into_iter().map(|i| i.id).collect();
        assert!(!ids.contains(&"steam:7".to_owned()), "{ids:?}");
        assert!(ids.contains(&"steam:220".to_owned()));
    }

    #[cfg(unix)]
    #[test]
    fn a_link_to_the_library_file_leaves_the_root() {
        let (dir, root) = fixture_tree();
        let real = root.join("steamapps/libraryfolders.vdf");
        let moved = dir.path().join("moved.vdf");
        std::fs::rename(&real, &moved).unwrap();
        std::os::unix::fs::symlink(&moved, &real).unwrap();
        assert_eq!(library_paths(&root), vec![root]);
    }
}
