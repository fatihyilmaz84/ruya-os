//! The game tree of `run.writable` (ADR-040, RUY-1019) on a real file system through `LinuxOs`
//! and ruya-fs: the modes, the links to the package and an update with a planted link. Linux only;
//! run it as a user that is not root (root ignores the modes it checks).
#![cfg(target_os = "linux")]

mod common;

use common::*;
use ruya_play_launch::game::{self, TREE};
use ruya_play_launch::linux::LinuxOs;
use ruya_play_launch::os::LaunchOs;
use ruya_play_launch::state::State;
use serde_json::json;
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::Path;

fn mode(path: &Path) -> u32 {
    fs::symlink_metadata(path)
        .expect("meta")
        .permissions()
        .mode()
        & 0o777
}

/// `game` written as a package tree at `root` (what `/app` holds).
fn write_package(game: &Game, root: &Path) {
    fs::write(root.join("play.json"), game.manifest.to_string()).expect("play.json");
    fs::write(root.join("play.files"), game.table()).expect("play.files");
    for (p, d) in &game.files {
        let at = root.join(p);
        fs::create_dir_all(at.parent().expect("parent")).expect("dirs");
        fs::write(at, d).expect("file");
    }
}

fn ut() -> Game {
    let mut g = Game::wine();
    g.set("/run/command", json!(["${game}/System/UT.exe"]))
        .set("/run/setup", json!([]));
    g.manifest["run"]["cwd"] = json!("${game}/System");
    g.manifest["run"]["writable"] = json!(["System", "Save"]);
    g.put("payload/System/UT.exe", b"MZ ut")
        .put("payload/System/UT.ini", b"[Engine] v1")
        .put("payload/System/Core.u", b"core v1")
        .put("payload/Maps/DM-Deck.unr", b"map v1");
    g.executable.push("payload/System/UT.exe".into());
    g
}

fn build(os: &mut LinuxOs, app: &str, data: &str, state: &mut State) {
    let loaded = ruya_play_launch::load_from(os, app).expect("the package loads");
    game::ensure(os, app, &loaded.manifest, &loaded.files, data, state).expect("the tree");
}

#[test]
fn the_tree_on_disk_has_its_modes_links_and_copies_and_an_update_keeps_the_games_files() {
    let tmp = tempfile::tempdir().expect("tmp");
    let app_dir = tmp.path().join("app");
    let data_dir = tmp.path().join("data");
    fs::create_dir_all(&app_dir).expect("app");
    fs::create_dir_all(&data_dir).expect("data");
    let (app, data) = (
        app_dir.to_str().expect("UTF-8").to_string(),
        data_dir.to_str().expect("UTF-8").to_string(),
    );
    let mut game = ut();
    write_package(&game, &app_dir);
    let mut os = LinuxOs;
    let mut state = State::default();
    build(&mut os, &app, &data, &mut state);
    let g = data_dir.join(TREE);
    assert_eq!(mode(&g), 0o500);
    assert_eq!(mode(&g.join("Maps")), 0o500);
    assert_eq!(mode(&g.join("System")), 0o700);
    assert_eq!(mode(&g.join("Save")), 0o700);
    assert_eq!(mode(&g.join("System/UT.ini")), 0o600);
    assert_eq!(mode(&g.join("System/UT.exe")), 0o700);
    assert_eq!(
        fs::read_link(g.join("Maps/DM-Deck.unr")).expect("a link"),
        app_dir.join("payload/Maps/DM-Deck.unr")
    );
    assert_eq!(
        fs::read(g.join("Maps/DM-Deck.unr")).expect("read"),
        b"map v1"
    );
    // A write outside the writable folders fails, as under /app/payload.
    assert!(fs::write(g.join("Maps/new.unr"), "x").is_err());
    assert!(fs::write(g.join("System/UT.log"), "log").is_ok());
    assert_eq!(state.game_build, Some(1));

    // The game changes its ini and plants a link; the update keeps both, the link as a link.
    fs::write(g.join("System/UT.ini"), "[Engine] mine").expect("write");
    let outside = tmp.path().join("outside");
    fs::write(&outside, "secret").expect("outside");
    symlink(&outside, g.join("System/evil")).expect("link");
    game.put("payload/System/Core.u", b"core v2");
    game.set("/build", json!(2));
    write_package(&game, &app_dir);
    build(&mut os, &app, &data, &mut state);
    assert_eq!(fs::read(g.join("System/Core.u")).expect("read"), b"core v2");
    assert_eq!(
        fs::read(g.join("System/UT.ini")).expect("read"),
        b"[Engine] mine"
    );
    assert_eq!(fs::read(g.join("System/UT.log")).expect("read"), b"log");
    assert_eq!(fs::read_link(g.join("System/evil")).expect("link"), outside);
    assert_eq!(fs::read(&outside).expect("read"), b"secret");
    assert!(!data_dir.join(game::NEW).exists());
    assert_eq!(state.game_build, Some(2));
    // The tree's 0500 folders do not stop a removal (the temporary folder is cleaned up).
    os.remove(&data, ".ruya-play").expect("remove");
}
