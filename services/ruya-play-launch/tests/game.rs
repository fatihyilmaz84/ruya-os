//! The game tree of `run.writable` (ADR-040, RUY-1019) on the fake OS: how it is built, how an
//! update sorts what the game wrote, and what a game that tampers with its own folder can and
//! cannot make the launcher do.

mod common;

use common::*;
use ruya_play_launch::fake::{FakeOs, Node};
use ruya_play_launch::game::{Base, BASE, NEW, STAGE, TREE};
use ruya_play_launch::os::LaunchOs;
use serde_json::json;
use std::io;

/// `${game}`.
fn g(rel: &str) -> String {
    if rel.is_empty() {
        format!("{DATA}/{TREE}")
    } else {
        format!("{DATA}/{TREE}/{rel}")
    }
}

/// `game-kept/<build>/<rel>` (the set itself for an empty `rel`).
fn kept(build: u64, rel: &str) -> String {
    let set = format!("{DATA}/.ruya-play/game-kept/{build}");
    if rel.is_empty() {
        set
    } else {
        format!("{set}/{rel}")
    }
}

/// A Windows game that writes next to its program, as Unreal Tournament does: `System/` (its
/// program, ini and log) and `Save/` (not in the package: made empty) are writable; `Maps/` is
/// not.
fn ut() -> Game {
    let mut g = Game::wine();
    g.set("/run/command", json!(["${game}/System/UT.exe", "-log"]))
        .set("/run/setup", json!([]));
    g.manifest["run"]["cwd"] = json!("${game}/System");
    g.manifest["run"]["writable"] = json!(["System", "Save"]);
    g.manifest["data"] = json!({"saves": ["game:Save"]});
    g.put("payload/System/UT.exe", b"MZ ut")
        .put("payload/System/UT.ini", b"[Engine] v1")
        .put("payload/System/Core.u", b"core v1")
        .put("payload/Maps/DM-Deck.unr", b"map v1");
    g.executable.push("payload/System/UT.exe".into());
    g
}

/// `game` updated to `build`, installed over what `os` has.
fn update(os: &mut FakeOs, game: &mut Game, build: u64) {
    game.set("/build", json!(build));
    game.install_into(os);
}

fn file(os: &FakeOs, path: &str) -> String {
    String::from_utf8_lossy(os.read(path).unwrap_or_else(|| panic!("no file {path}"))).into()
}

fn base(os: &FakeOs) -> Base {
    Base::parse(os.read(&format!("{DATA}/{BASE}")).expect("the base exists")).expect("it parses")
}

#[test]
fn the_tree_links_outside_the_writable_folders_and_copies_inside() {
    let mut os = ut().install();
    let cmd = launch(&mut os, &[]).expect("launch");
    // The game runs from its tree: the program is a copy, the working folder a real folder.
    assert!(cmd.argv.contains(&g("System/UT.exe")), "{:?}", cmd.argv);
    assert_eq!(cmd.cwd, g("System"));
    assert_eq!(cmd.env.get("PWD"), Some(&g("System")));
    assert_eq!(
        os.nodes.get(&g("Maps/DM-Deck.unr")),
        Some(&Node::Link("/app/payload/Maps/DM-Deck.unr".into()))
    );
    assert_eq!(os.nodes.get(&g("Maps")), Some(&Node::Dir));
    assert_eq!(file(&os, &g("System/UT.ini")), "[Engine] v1");
    assert_eq!(file(&os, &g("System/UT.exe")), "MZ ut");
    assert_eq!(os.nodes.get(&g("Save")), Some(&Node::Dir), "made empty");
    // Modes: 0500 outside, 0700 inside, copies 0600 or 0700 with x.
    for (path, mode) in [
        (g(""), 0o500),
        (g("Maps"), 0o500),
        (g("System"), 0o700),
        (g("Save"), 0o700),
        (g("System/UT.ini"), 0o600),
        (g("System/Core.u"), 0o600),
        (g("System/UT.exe"), 0o700),
    ] {
        assert_eq!(os.mode(&path), Some(mode), "{path}");
    }
    // The record: the build in the status file, every copy's table hash in the base.
    assert_eq!(state(&os).game_build, Some(1));
    let b = base(&os);
    assert_eq!(b.build, 1);
    assert_eq!(
        b.files.keys().collect::<Vec<_>>(),
        ["System/Core.u", "System/UT.exe", "System/UT.ini"]
    );
    assert_eq!(b.files["System/UT.ini"], sha256(b"[Engine] v1"));
    // Nothing of the build is left over.
    assert!(os.below(&format!("{DATA}/{NEW}")).is_empty());
    assert!(os.below(&format!("{DATA}/{STAGE}")).is_empty());
    assert!(os.below(&format!("{DATA}/.ruya-play/game-kept")).is_empty());
}

#[test]
fn the_program_is_a_copy_even_outside_the_writable_folders() {
    // The program at the root, the only writable folder Save.
    let mut game = ut();
    game.put("payload/Game.exe", b"MZ root");
    game.set("/run/command", json!(["${game}/Game.exe"]));
    game.manifest["run"]["cwd"] = json!("${game}");
    game.manifest["run"]["writable"] = json!(["Save"]);
    let mut os = game.install();
    let cmd = launch(&mut os, &[]).expect("launch");
    assert_eq!(cmd.cwd, g(""));
    assert_eq!(file(&os, &g("Game.exe")), "MZ root");
    assert_eq!(os.mode(&g("Game.exe")), Some(0o600));
    // System is not writable here: its files are links, its folder shut.
    assert_eq!(
        os.nodes.get(&g("System/UT.ini")),
        Some(&Node::Link("/app/payload/System/UT.ini".into()))
    );
    assert_eq!(os.mode(&g("System")), Some(0o500));
    assert_eq!(
        base(&os).files.keys().collect::<Vec<_>>(),
        ["Game.exe"],
        "the copy outside is recorded, so an update can tell it unchanged"
    );
}

#[test]
fn a_relaunch_of_the_same_build_leaves_the_tree_as_the_game_left_it() {
    let mut os = ut().install();
    launch(&mut os, &[]).expect("launch");
    os.file(&g("System/UT.log"), "log");
    os.file(&g("System/UT.ini"), "[Engine] mine");
    let lines = os.lines.borrow().len();
    launch(&mut os, &[]).expect("again");
    assert_eq!(file(&os, &g("System/UT.log")), "log");
    assert_eq!(file(&os, &g("System/UT.ini")), "[Engine] mine");
    assert!(
        !os.lines.borrow()[lines..]
            .iter()
            .any(|l| l.contains("making the game folder")),
        "no rebuild: {:?}",
        os.lines.borrow()
    );
}

#[test]
fn an_update_replaces_what_the_game_left_alone_and_keeps_what_it_wrote() {
    let mut game = ut();
    let mut os = game.install();
    launch(&mut os, &[]).expect("build 1");
    os.file(&g("System/UT.ini"), "[Engine] mine");
    os.file(&g("System/UT.log"), "log");
    os.file(&g("Save/Save1.usa"), "slot 1");
    os.file(&g("System/Cache/c.bin"), "cache");
    game.put("payload/System/Core.u", b"core v2")
        .put("payload/System/UT.ini", b"[Engine] v2")
        .put("payload/Maps/DM-New.unr", b"map v2");
    update(&mut os, &mut game, 2);
    launch(&mut os, &[]).expect("build 2");
    // Unchanged: replaced by the new build's file.
    assert_eq!(file(&os, &g("System/Core.u")), "core v2");
    // Changed or made by the game: kept where it was.
    assert_eq!(file(&os, &g("System/UT.ini")), "[Engine] mine");
    assert_eq!(file(&os, &g("System/UT.log")), "log");
    assert_eq!(file(&os, &g("Save/Save1.usa")), "slot 1");
    assert_eq!(file(&os, &g("System/Cache/c.bin")), "cache");
    assert_eq!(
        os.nodes.get(&g("Maps/DM-New.unr")),
        Some(&Node::Link("/app/payload/Maps/DM-New.unr".into()))
    );
    assert_eq!(state(&os).game_build, Some(2));
    assert_eq!(base(&os).build, 2);
    assert_eq!(base(&os).files["System/Core.u"], sha256(b"core v2"));
    assert!(os.below(&format!("{DATA}/.ruya-play/game-kept")).is_empty());
    assert!(os.below(&format!("{DATA}/{NEW}")).is_empty());
    // The kept ini is the game's: at the next update it is still not the build's.
    game.put("payload/System/UT.ini", b"[Engine] v3");
    update(&mut os, &mut game, 3);
    launch(&mut os, &[]).expect("build 3");
    assert_eq!(file(&os, &g("System/UT.ini")), "[Engine] mine");
}

#[test]
fn a_dropped_writable_folder_goes_to_game_kept_and_only_the_newest_set_stays() {
    let mut game = ut();
    game.put("payload/Save/Default.usa", b"default");
    let mut os = game.install();
    launch(&mut os, &[]).expect("build 1");
    os.file(&g("Save/Save1.usa"), "slot 1");
    // Build 2 drops Save and adds Logs.
    game.manifest["run"]["writable"] = json!(["System", "Logs"]);
    game.manifest["data"] = json!({});
    update(&mut os, &mut game, 2);
    launch(&mut os, &[]).expect("build 2");
    assert_eq!(file(&os, &kept(1, "Save/Save1.usa")), "slot 1");
    assert!(
        os.read(&kept(1, "Save/Default.usa")).is_none(),
        "the build's own unchanged file is not kept"
    );
    assert_eq!(
        os.nodes.get(&g("Save/Default.usa")),
        Some(&Node::Link("/app/payload/Save/Default.usa".into()))
    );
    assert!(os
        .lines
        .borrow()
        .iter()
        .any(|l| l.contains("1 files the game wrote") && l.contains("game-kept/1")));
    // Build 3 drops Logs: its set replaces the older one.
    os.file(&g("Logs/run.log"), "log");
    game.manifest["run"]["writable"] = json!(["System"]);
    update(&mut os, &mut game, 3);
    launch(&mut os, &[]).expect("build 3");
    assert_eq!(file(&os, &kept(2, "Logs/run.log")), "log");
    assert!(
        os.below(&kept(1, "")).is_empty(),
        "only the newest set is kept"
    );
}

#[test]
fn an_update_without_a_kept_file_leaves_the_last_set() {
    let mut game = ut();
    let mut os = game.install();
    launch(&mut os, &[]).expect("build 1");
    os.file(&g("Save/Save1.usa"), "slot 1");
    game.manifest["run"]["writable"] = json!(["System"]);
    game.manifest["data"] = json!({});
    update(&mut os, &mut game, 2);
    launch(&mut os, &[]).expect("build 2");
    update(&mut os, &mut game, 3);
    launch(&mut os, &[]).expect("build 3");
    assert_eq!(file(&os, &kept(1, "Save/Save1.usa")), "slot 1");
}

#[test]
fn an_interrupted_rebuild_resumes_from_game_new() {
    let mut game = ut();
    let mut os = game.install();
    launch(&mut os, &[]).expect("build 1");
    os.file(&g("System/UT.ini"), "[Engine] mine");
    os.file(&g("System/UT.log"), "log");
    game.put("payload/System/Core.u", b"core v2");
    update(&mut os, &mut game, 2);
    // Cut short while sorting: the ini is moved, the log is not.
    os.fail_rename(&g("System/UT.log"), io::ErrorKind::Interrupted);
    let err = launch(&mut os, &[]).expect_err("cut short");
    assert_eq!(err.code, "launch.game");
    let new = |rel: &str| format!("{DATA}/{NEW}/{rel}");
    assert_eq!(file(&os, &new("System/UT.ini")), "[Engine] mine");
    assert_eq!(file(&os, &g("System/UT.log")), "log");
    assert_eq!(state(&os).game_build, Some(1));
    // Cut short again just before the new tree takes the old one's place.
    os.rename_errors.clear();
    os.fail_rename(&format!("{DATA}/{NEW}"), io::ErrorKind::Interrupted);
    let err = launch(&mut os, &[]).expect_err("cut short at the end");
    assert_eq!(err.code, "launch.game");
    assert_eq!(state(&os).game_build, Some(2), "recorded before the swap");
    os.rename_errors.clear();
    launch(&mut os, &[]).expect("resumed");
    assert_eq!(file(&os, &g("System/UT.ini")), "[Engine] mine");
    assert_eq!(file(&os, &g("System/UT.log")), "log");
    assert_eq!(file(&os, &g("System/Core.u")), "core v2");
    assert_eq!(os.mode(&g("")), Some(0o500));
    assert!(os.below(&format!("{DATA}/{NEW}")).is_empty());
    assert!(os.below(&format!("{DATA}/.ruya-play/game-kept")).is_empty());
}

#[test]
fn a_forged_base_can_only_keep_data() {
    for forged in [
        b"not json".to_vec(),
        // The build of another tree.
        Base {
            build: 7,
            files: [("System/Core.u".into(), sha256(b"core v1"))].into(),
        }
        .to_bytes(),
        // Hashes that match nothing the game has.
        Base {
            build: 1,
            files: [("System/Core.u".into(), sha256(b"other"))].into(),
        }
        .to_bytes(),
        // A path out of the tree makes the whole record unreadable.
        format!(
            r#"{{"format":1,"build":1,"files":{{"../../x":"{}","System/Core.u":"{}"}}}}"#,
            sha256(b"x"),
            sha256(b"core v1")
        )
        .into_bytes(),
    ] {
        let mut game = ut();
        let mut os = game.install();
        launch(&mut os, &[]).expect("build 1");
        os.file(&format!("{DATA}/{BASE}"), forged.clone());
        game.put("payload/System/Core.u", b"core v2");
        update(&mut os, &mut game, 2);
        launch(&mut os, &[]).expect("build 2");
        let what = String::from_utf8_lossy(&forged).to_string();
        assert_eq!(file(&os, &g("System/Core.u")), "core v1", "{what}");
        assert_eq!(file(&os, &g("System/UT.ini")), "[Engine] v1", "{what}");
        assert_eq!(base(&os).build, 2, "the new record replaces the forged one");
    }
}

#[test]
fn a_planted_link_is_never_followed() {
    let mut game = ut();
    let mut os = game.install();
    os.file("/etc/passwd", "root").file("/etc/x/y", "z");
    launch(&mut os, &[]).expect("build 1");
    // The game swaps a copy for a link, and its Save folder for a link to a folder.
    os.link(&g("System/UT.ini"), "/etc/passwd");
    os.remove(DATA, &format!("{TREE}/Save")).expect("remove");
    os.link(&g("Save"), "/etc/x");
    // And plants links where the launcher builds.
    os.link(&format!("{DATA}/{NEW}"), "/etc");
    os.link(&format!("{DATA}/{STAGE}"), "/etc/passwd");
    game.put("payload/System/UT.ini", b"[Engine] v2");
    update(&mut os, &mut game, 2);
    launch(&mut os, &[]).expect("build 2");
    // The game's links are its data: kept as links, never read through.
    assert_eq!(
        os.nodes.get(&g("System/UT.ini")),
        Some(&Node::Link("/etc/passwd".into()))
    );
    assert_eq!(
        os.nodes.get(&kept(1, "Save")),
        Some(&Node::Link("/etc/x".into()))
    );
    assert_eq!(os.nodes.get(&g("Save")), Some(&Node::Dir));
    assert_eq!(file(&os, "/etc/passwd"), "root");
    assert_eq!(
        os.below("/etc"),
        ["/etc", "/etc/passwd", "/etc/x", "/etc/x/y"]
    );
    assert_eq!(file(&os, "/etc/x/y"), "z");
    // The whole tree swapped for a link: replaced, the target untouched.
    os.remove(DATA, TREE).expect("remove");
    os.link(&g(""), "/etc");
    update(&mut os, &mut game, 3);
    launch(&mut os, &[]).expect("build 3");
    assert_eq!(os.nodes.get(&g("")), Some(&Node::Dir));
    assert_eq!(
        os.below("/etc"),
        ["/etc", "/etc/passwd", "/etc/x", "/etc/x/y"]
    );
}

#[test]
fn a_folder_in_another_letter_case_is_not_the_writable_one() {
    let mut game = ut();
    let mut os = game.install();
    launch(&mut os, &[]).expect("build 1");
    // `system` is not `System` on the console's file system: what is in it is kept aside, never
    // merged into the writable folder of that name.
    os.file(&g("system/UT.ini"), "[Engine] lower");
    update(&mut os, &mut game, 2);
    launch(&mut os, &[]).expect("build 2");
    assert_eq!(file(&os, &kept(1, "system/UT.ini")), "[Engine] lower");
    assert_eq!(file(&os, &g("System/UT.ini")), "[Engine] v1");
    assert!(os.below(&g("system")).is_empty());
}

#[test]
fn a_tree_that_cannot_be_updated_fails_the_launch_and_keeps_the_old_one() {
    let mut game = ut();
    let mut os = game.install();
    launch(&mut os, &[]).expect("build 1");
    os.file(&g("Save/Save1.usa"), "slot 1");
    os.link(&format!("{DATA}/.ruya-play/game-kept"), "/etc");
    game.manifest["run"]["writable"] = json!(["System"]);
    game.manifest["data"] = json!({});
    update(&mut os, &mut game, 2);
    let err = launch(&mut os, &[]).expect_err("no place to keep the save");
    assert_eq!(err.code, "launch.game");
    assert!(err.message.contains("is a link"), "{}", err.message);
    assert_eq!(file(&os, &g("Save/Save1.usa")), "slot 1");
    assert!(os.below("/etc").is_empty());
}

#[test]
fn without_writable_there_is_no_tree() {
    let mut os = Game::wine().install();
    launch(&mut os, &[]).expect("launch");
    assert!(os.below(&g("")).is_empty());
    assert_eq!(state(&os).game_build, None);
}

#[test]
fn an_epoch_rebuild_of_the_prefix_leaves_the_tree_alone() {
    let mut game = ut();
    let mut os = game.install();
    launch(&mut os, &[]).expect("epoch 1");
    os.file(&g("Save/Save1.usa"), "slot 1");
    game.manifest["run"]["prefix"]["epoch"] = json!(2);
    game.install_into(&mut os);
    launch(&mut os, &[]).expect("epoch 2");
    assert_eq!(state(&os).epoch, 2);
    assert_eq!(file(&os, &g("Save/Save1.usa")), "slot 1");
}

#[test]
fn the_setup_steps_run_in_the_tree() {
    let mut game = ut();
    game.set(
        "/run/setup",
        json!([{"id": "first", "command": ["${game}/System/UT.exe", "-init"], "once": true}]),
    );
    let mut os = game.install();
    launch(&mut os, &[]).expect("launch");
    let step = &os.runs[0];
    assert!(step.argv.contains(&g("System/UT.exe")), "{:?}", step.argv);
    assert_eq!(step.cwd, g("System"));
}
