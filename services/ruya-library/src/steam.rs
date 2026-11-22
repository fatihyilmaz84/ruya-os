//! The profile's Steam games, read-only, from `steamapps/libraryfolders.vdf` and
//! `steamapps/appmanifest_*.acf`: the reader of `ruya-library profile-scan` (ADR-045), which
//! ruya-session runs as the profile's user. The service itself never calls it: it reads no home.
//!
//! Every file is read through `ruya_fs::Dir` (never through a link) with a size cap. The home is
//! walked relatively from one handle (`STEAM_ROOTS`), so a Steam root that is a link (or has a
//! link above it) is refused; the extra library folders `libraryfolders.vdf` names are opened as
//! bases of their own (where a library lives is the player's choice), and everything below them
//! is read never through a link.

use std::io;
use std::path::{Path, PathBuf};

use ruya_fs::{Dir, Kind as FsKind};
use ruya_vdf::{self as vdf, Value};

use crate::profile_items::{Game, MAX_ITEMS};

/// The Steam roots below a home (spec 03 section 5): native Steam, then the Flatpak Steam.
pub const STEAM_ROOTS: [&str; 2] = [
    ".local/share/Steam",
    ".var/app/com.valvesoftware.Steam/.local/share/Steam",
];

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

/// The library folders a Steam root's `libraryfolders.vdf` names (new format:
/// `"0" { "path" "..." }`; old format: `"1" "path"`), in the file's order, each once. A missing
/// or broken file names none.
pub fn library_paths(root: &Dir) -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = Vec::new();
    let rel = Path::new("steamapps").join("libraryfolders.vdf");
    let Some(text) = read_text(root, &rel, MAX_LIBRARYFOLDERS) else {
        return paths;
    };
    let Ok(doc) = vdf::parse(&text) else {
        eprintln!(
            "ruya-library: cannot parse {}",
            root.path().join(&rel).display()
        );
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

/// The text of the file `rel` below `base`. `None` when it is missing, a link, not a regular
/// file, over `limit` bytes or not UTF-8.
fn read_text(base: &Dir, rel: &Path, limit: u64) -> Option<String> {
    let bytes = base.read(rel, limit).ok()?;
    String::from_utf8(bytes).ok()
}

/// One game from the text of an `appmanifest_*.acf`; `None` for anything that is not a fully
/// installed game with a valid app id (`ruya_ids::valid_steam_appid`, the shared rule).
pub fn parse_manifest(text: &str) -> Option<Game> {
    let doc = Value::Obj(vdf::parse(text).ok()?);
    let state = doc.get("AppState")?;
    let appid = state.get_str("appid")?.trim();
    if !ruya_ids::valid_steam_appid(appid) {
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
    Some(Game {
        appid: appid.to_owned(),
        name: name.to_owned(),
        last_played,
    })
}

/// Adds the games of one library folder to `games` (each app id once, at most `MAX_ITEMS` in
/// all). Unreadable files are skipped, links are not followed, and a library is read up to
/// `MAX_MANIFESTS` manifests.
fn scan_library(lib: &Dir, games: &mut Vec<Game>) {
    let Ok(entries) = lib.entries(Path::new("steamapps")) else {
        return;
    };
    let manifests = entries
        .into_iter()
        .filter(|(name, kind)| {
            let name = name.to_string_lossy();
            *kind == FsKind::File && name.starts_with("appmanifest_") && name.ends_with(".acf")
        })
        .take(MAX_MANIFESTS);
    for (name, _) in manifests {
        if games.len() >= MAX_ITEMS {
            return;
        }
        let rel = Path::new("steamapps").join(name);
        let Some(text) = read_text(lib, &rel, MAX_MANIFEST) else {
            continue;
        };
        if let Some(game) = parse_manifest(&text) {
            if !games.iter().any(|g| g.appid == game.appid) {
                games.push(game);
            }
        }
    }
}

/// Every game of the Steam libraries below `home`: each root of `STEAM_ROOTS` walked from one
/// handle on `home`, then the library folders its `libraryfolders.vdf` names (a folder that was
/// read already, a root included, is read once). At most `MAX_ITEMS` games.
pub fn scan_home(home: &Path) -> Vec<Game> {
    let mut games = Vec::new();
    let home_dir = match Dir::open(home) {
        Ok(dir) => dir,
        Err(err) => {
            eprintln!("ruya-library: cannot open {}: {err}", home.display());
            return games;
        }
    };
    let mut read: Vec<PathBuf> = Vec::new();
    for rel in STEAM_ROOTS {
        let root = match home_dir.walk(Path::new(rel)) {
            Ok(dir) => dir,
            Err(err) => {
                if err.kind() != io::ErrorKind::NotFound {
                    eprintln!("ruya-library: {rel} not read: {err}");
                }
                continue;
            }
        };
        scan_library(&root, &mut games);
        read.push(home.join(rel));
        for path in library_paths(&root) {
            if read.contains(&path) {
                continue;
            }
            read.push(path.clone());
            match Dir::open(&path) {
                Ok(lib) => scan_library(&lib, &mut games),
                Err(err) => eprintln!("ruya-library: {} not read: {err}", path.display()),
            }
        }
    }
    games
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

    /// A home with native Steam and a second library folder outside it; `@ROOT@` and `@LIB2@` in
    /// libraryfolders.vdf are the two library paths. (temp, home, root, lib2).
    fn fixture_home() -> (tempfile::TempDir, PathBuf, PathBuf, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let root = home.join(STEAM_ROOTS[0]);
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
        (dir, home, root, lib2)
    }

    fn appids(games: &[Game]) -> Vec<&str> {
        let mut ids: Vec<&str> = games.iter().map(|g| g.appid.as_str()).collect();
        ids.sort_unstable();
        ids
    }

    fn manifest(appid: &str, flags: &str) -> String {
        format!("\"AppState\"\n{{\n\"appid\" \"{appid}\"\n\"name\" \"Game {appid}\"\n\"StateFlags\" \"{flags}\"\n}}\n")
    }

    #[test]
    fn the_fixture_home_yields_the_two_real_games() {
        let (_dir, home, _, _) = fixture_home();
        let mut games = scan_home(&home);
        games.sort_by(|a, b| a.appid.cmp(&b.appid));
        assert_eq!(appids(&games), ["220", "400"], "Proton is skipped");
        assert_eq!(games[0].name, "Turbo Racer");
        assert_eq!(games[0].last_played, 1_700_000_000);
        assert_eq!(games[1].name, "Block Puzzle");
        assert_eq!(games[1].last_played, 0, "no LastPlayed means unknown");
    }

    #[test]
    fn both_roots_are_read_and_a_game_in_both_counts_once() {
        let (_dir, home, _, _) = fixture_home();
        let flat = home.join(STEAM_ROOTS[1]).join("steamapps");
        std::fs::create_dir_all(&flat).unwrap();
        std::fs::write(flat.join("appmanifest_70.acf"), manifest("70", "4")).unwrap();
        std::fs::write(flat.join("appmanifest_220.acf"), MANIFEST_RACER).unwrap();
        assert_eq!(appids(&scan_home(&home)), ["220", "400", "70"]);
    }

    #[test]
    fn library_paths_lists_the_folders_once() {
        let (_dir, home, root, lib2) = fixture_home();
        let steam = Dir::open(&home)
            .unwrap()
            .walk(Path::new(STEAM_ROOTS[0]))
            .unwrap();
        assert_eq!(
            library_paths(&steam),
            vec![root, lib2],
            "Steam lists the root itself first"
        );
    }

    #[test]
    fn old_format_library_folders() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("steamapps")).unwrap();
        std::fs::write(
            dir.path().join("steamapps/libraryfolders.vdf"),
            "\"LibraryFolders\"\n{\n\t\"TimeNextStatsReport\"\t\"1\"\n\t\"1\"\t\"/mnt/other\"\n}\n",
        )
        .unwrap();
        let paths = library_paths(&Dir::open(dir.path()).unwrap());
        assert_eq!(paths, vec![PathBuf::from("/mnt/other")]);
    }

    #[test]
    fn a_missing_home_root_or_broken_library_file_gives_what_is_there() {
        let dir = tempfile::tempdir().unwrap();
        assert!(scan_home(&dir.path().join("nobody")).is_empty());
        assert!(scan_home(dir.path()).is_empty(), "no Steam at all");
        let root = dir.path().join(STEAM_ROOTS[0]);
        std::fs::create_dir_all(root.join("steamapps")).unwrap();
        std::fs::write(root.join("steamapps/libraryfolders.vdf"), "\"a\" {").unwrap();
        std::fs::write(root.join("steamapps/appmanifest_9.acf"), manifest("9", "4")).unwrap();
        assert!(library_paths(&Dir::open(&root).unwrap()).is_empty());
        assert_eq!(appids(&scan_home(dir.path())), ["9"]);
    }

    #[test]
    fn only_fully_installed_manifests_count() {
        assert!(parse_manifest(&manifest("7", "4")).is_some());
        assert!(
            parse_manifest(&manifest("7", "6")).is_some(),
            "bit 4 among others"
        );
        assert!(
            parse_manifest(&manifest("7", "1026")).is_none(),
            "update required, bit 4 clear"
        );
        assert!(parse_manifest(&manifest("7", "0")).is_none());
        assert!(parse_manifest(&manifest("7", "x")).is_none());
    }

    #[test]
    fn app_ids_follow_the_shared_rule() {
        assert!(parse_manifest(&manifest("1234567890", "4")).is_some());
        assert!(
            parse_manifest(&manifest("12345678901", "4")).is_none(),
            "eleven digits"
        );
        assert!(parse_manifest(&manifest("../x", "4")).is_none());
        assert!(parse_manifest(&manifest("", "4")).is_none());
    }

    #[test]
    fn keys_in_any_case() {
        let text = "\"AppState\" { \"AppID\" \"9\" \"Name\" \"Nine\" \"stateflags\" \"4\" \"lastplayed\" \"5\" }";
        let game = parse_manifest(text).unwrap();
        assert_eq!(game.appid, "9");
        assert_eq!(game.last_played, 5);
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
    }

    #[test]
    fn an_oversized_manifest_is_refused() {
        let (_dir, home, root, _) = fixture_home();
        let big = format!(
            "{}{}",
            manifest("220", "4"),
            " ".repeat(MAX_MANIFEST as usize)
        );
        std::fs::write(root.join("steamapps/appmanifest_220.acf"), big).unwrap();
        assert_eq!(
            appids(&scan_home(&home)),
            ["400"],
            "only the small manifest is read"
        );
    }

    #[test]
    fn an_oversized_library_file_leaves_the_root_only() {
        let (_dir, home, root, _) = fixture_home();
        let file = root.join("steamapps/libraryfolders.vdf");
        // A comment pads the real fixture past the cap and it still parses: only the cap refuses it.
        let mut big = std::fs::read_to_string(&file).unwrap();
        big.push_str(&format!("//{}\n", "x".repeat(MAX_LIBRARYFOLDERS as usize)));
        std::fs::write(&file, big).unwrap();
        assert_eq!(appids(&scan_home(&home)), ["220"]);
    }

    #[test]
    fn more_manifests_than_the_caps_are_not_read() {
        let (_dir, home, root, _) = fixture_home();
        // 4097 more manifests in the root library: past both caps.
        for id in 1000..1000 + MAX_MANIFESTS + 1 {
            let at = root.join(format!("steamapps/appmanifest_{id}.acf"));
            std::fs::write(at, manifest(&id.to_string(), "4")).unwrap();
        }
        let games = scan_home(&home);
        assert_eq!(
            games.len(),
            MAX_ITEMS,
            "the home stops at the document's cap"
        );
        assert!(
            !games.iter().any(|g| g.appid == "400"),
            "the second library adds nothing past the cap"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_link_to_a_manifest_is_refused() {
        let (dir, home, root, _) = fixture_home();
        let elsewhere = dir.path().join("elsewhere.acf");
        std::fs::write(&elsewhere, manifest("7", "4")).unwrap();
        std::os::unix::fs::symlink(&elsewhere, root.join("steamapps/appmanifest_7.acf")).unwrap();
        assert_eq!(appids(&scan_home(&home)), ["220", "400"]);
    }

    #[cfg(unix)]
    #[test]
    fn a_steam_root_that_is_a_link_is_refused() {
        let (dir, home, root, _) = fixture_home();
        let moved = dir.path().join("moved-steam");
        std::fs::rename(&root, &moved).unwrap();
        std::os::unix::fs::symlink(&moved, &root).unwrap();
        assert!(
            scan_home(&home).is_empty(),
            "the root and the libraries it names are not read"
        );
        // A link higher up (.local) is refused the same way.
        std::fs::remove_file(&root).unwrap();
        let local = home.join(".local");
        let elsewhere = dir.path().join("moved-local");
        std::fs::rename(&local, &elsewhere).unwrap();
        std::fs::rename(&moved, elsewhere.join("share/Steam")).unwrap();
        std::os::unix::fs::symlink(&elsewhere, &local).unwrap();
        assert!(scan_home(&home).is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn a_link_to_the_library_file_leaves_the_root_only() {
        let (dir, home, root, _) = fixture_home();
        let real = root.join("steamapps/libraryfolders.vdf");
        let moved = dir.path().join("moved.vdf");
        std::fs::rename(&real, &moved).unwrap();
        std::os::unix::fs::symlink(&moved, &real).unwrap();
        assert_eq!(appids(&scan_home(&home)), ["220"]);
    }
}
