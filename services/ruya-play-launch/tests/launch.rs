//! The launcher end to end on a fake sandbox (RUY-901): the env deny table, placeholders, the
//! argv of each runner kind, the prefix, setup once, a failed setup, the epoch rebuild and planted
//! links, the system runner scan and the arguments.

mod common;

use common::*;
use ruya_play_launch::fake::{FakeOs, Node};
use ruya_play_launch::os::{Exit, LaunchOs, MAX_COPY_DEPTH};
use ruya_play_launch::plan::{substitute, Places};
use ruya_play_launch::runners::{scan, MAX_RUNNER_DIRS};
use ruya_play_launch::state::{RunnerInUse, State};
use serde_json::json;
use std::collections::BTreeMap;
use std::time::Duration;

fn args_of(cmd: &ruya_play_launch::os::Command) -> Vec<&str> {
    cmd.argv.iter().map(String::as_str).collect()
}

// ---- the environment ----

#[test]
fn run_env_may_not_name_what_the_platform_owns() {
    for name in [
        "LD_PRELOAD",
        "PATH",
        "XDG_DATA_HOME",
        "FLATPAK_ID",
        "RUYA_RUNNER",
        "PWD",
        "UMU_ID",
    ] {
        let mut g = Game::native();
        g.set(
            "/run",
            json!({"runner": "native", "command": ["${payload}/game"],
                             "env": {name: "/tmp/evil"}}),
        );
        let mut os = g.install();
        let err = launch(&mut os, &[]).unwrap_err();
        assert_eq!(err.code, "env.reserved", "{name}");
        assert!(os.runs.is_empty(), "{name}: nothing ran");
    }
}

#[test]
fn the_environment_is_base_then_run_env_then_the_launchers_own() {
    let g = Game::wine();
    let mut os = g.install();
    let cmd = launch(&mut os, &[]).unwrap();
    // The base environment passes.
    assert_eq!(cmd.env["PATH"], "/app/bin:/usr/bin");
    assert_eq!(cmd.env["FLATPAK_ID"], "play.com.example.hop");
    // run.env adds what the deny table lets through.
    assert_eq!(cmd.env["WINEDLLOVERRIDES"], "dinput8=n,b");
    // The launcher's own variables win over the base environment.
    assert_eq!(cmd.env["WINEPREFIX"], PREFIX);
    assert_eq!(cmd.env["WINELOADER"], "/app/components/wine/bin/wine");
    assert_eq!(cmd.env["WINESERVER"], "/app/components/wine/bin/wineserver");
}

#[test]
fn winearch_is_set_only_when_the_prefix_is_created() {
    let mut os = Game::wine().install();
    let first = launch(&mut os, &[]).unwrap();
    assert_eq!(first.env.get("WINEARCH").map(String::as_str), Some("win64"));
    let mut env = base_env();
    env.insert("WINEARCH".into(), "win32".into());
    let second = ruya_play_launch::prepare(&mut os, &[], &env).unwrap();
    assert_eq!(
        second.env.get("WINEARCH"),
        None,
        "an existing prefix keeps its arch"
    );
}

#[test]
fn a_missing_data_folder_is_one_sentence() {
    let mut os = Game::native().install();
    let mut env = base_env();
    env.remove("XDG_DATA_HOME");
    let err = ruya_play_launch::prepare(&mut os, &[], &env).unwrap_err();
    assert_eq!(err.code, "launch.environment");
    env.insert("XDG_DATA_HOME".into(), "relative/data".into());
    let err = ruya_play_launch::prepare(&mut os, &[], &env).unwrap_err();
    assert_eq!(err.code, "launch.environment");
}

// ---- placeholders ----

fn places() -> Places {
    Places {
        payload: "/app/payload".into(),
        data: "/d".into(),
        config: "/c".into(),
        prefix: Some("/d/prefix".into()),
        disc: Some("/app/payload/disc1.iso".into()),
        game: Some("/d/.ruya-play/game".into()),
        components: BTreeMap::from([("wine".to_string(), "/app/runners/Wine10".to_string())]),
    }
}

#[test]
fn placeholders_substitute_only_the_named_ones() {
    let p = places();
    let cases = [
        ("${payload}/Hop.exe", "/app/payload/Hop.exe"),
        ("--save=${data}/s", "--save=/d/s"),
        ("${config}", "/c"),
        ("${prefix}/drive_c", "/d/prefix/drive_c"),
        ("${disc}", "/app/payload/disc1.iso"),
        ("${game}/System/UT.exe", "/d/.ruya-play/game/System/UT.exe"),
        ("${component:wine}/bin", "/app/runners/Wine10/bin"),
        ("${data}${data}", "/d/d"),
        // Anything else is literal.
        ("${HOME}/x", "${HOME}/x"),
        ("$data", "$data"),
        ("${payload", "${payload"),
        ("${}", "${}"),
        ("${PAYLOAD}", "${PAYLOAD}"),
        ("plain", "plain"),
    ];
    for (input, want) in cases {
        assert_eq!(substitute(input, &p).unwrap(), want, "{input}");
    }
}

/// Every placeholder of the format's list gets its value here (RUY-1019: `${game}` once fell
/// to `${disc}`'s value), so a name added to the list without a launcher arm fails.
#[test]
fn every_placeholder_of_the_format_has_its_own_value() {
    let p = places();
    let mut seen = Vec::new();
    for name in ruya_play_format::limits::PLACEHOLDERS {
        let got = substitute(&format!("${{{name}}}"), &p).unwrap();
        assert_ne!(got, format!("${{{name}}}"), "{name} is not substituted");
        assert!(
            !seen.contains(&got),
            "{name} has another placeholder's value {got}"
        );
        seen.push(got);
    }
}

#[test]
fn a_named_placeholder_without_a_value_fails() {
    let mut p = places();
    p.prefix = None;
    assert_eq!(
        substitute("${prefix}", &p).unwrap_err().code,
        "launch.placeholder"
    );
    p.game = None;
    assert_eq!(
        substitute("${game}/x", &p).unwrap_err().code,
        "launch.placeholder"
    );
    assert_eq!(
        substitute("${component:dosbox}", &p).unwrap_err().code,
        "launch.placeholder"
    );
}

#[test]
fn a_native_game_runs_its_command() {
    let mut os = Game::native().install();
    let cmd = launch(&mut os, &[]).unwrap();
    assert_eq!(
        args_of(&cmd),
        ["/app/payload/game", &format!("--data={DATA}/x")]
    );
    assert_eq!(cmd.cwd, "/app/payload");
    assert_eq!(
        cmd.env.get("WINEPREFIX").map(String::as_str),
        Some("/tmp/elsewhere")
    );
    assert!(os.runs.is_empty());
}

// ---- runner kinds ----

#[test]
fn wine_runs_through_its_loader() {
    let mut os = Game::wine().install();
    let cmd = launch(&mut os, &[]).unwrap();
    assert_eq!(
        args_of(&cmd),
        [
            "/app/components/wine/bin/wine",
            "/app/payload/Hop.exe",
            "-fullscreen"
        ]
    );
    let s = state(&os);
    assert_eq!(
        s.runner,
        Some(RunnerInUse {
            component: "wine".into(),
            family: "wine".into(),
            version: "9.20".into(),
            source: "bundled".into(),
            hash: None,
        })
    );
}

/// The wine game turned into a Proton one with the system GE-Proton, before the first launch.
fn proton_os(cwd: Option<&str>) -> FakeOs {
    let mut g = Game::wine();
    g.set(
        "/components/0",
        json!({"id": "proton", "type": "proton", "source": "system", "min": "9"}),
    )
    .set("/run/component", json!("proton"))
    .set("/run/runner", json!("proton"));
    if let Some(cwd) = cwd {
        g.manifest["run"]["cwd"] = json!(cwd);
    }
    g.files.retain(|(p, _)| !p.starts_with("components/"));
    let mut os = g.install();
    add_system_runner(
        &mut os,
        "ProtonGE10",
        "proton-ge",
        "proton",
        "GE-Proton10-9",
    );
    os
}

#[test]
fn proton_runs_waitforexitandrun_with_its_compat_folders() {
    let mut os = proton_os(None);
    os.file(
        "/app/runners/ProtonGE10/.ruya-runner-hash",
        format!("{}\n", "ab".repeat(32)),
    );
    let cmd = launch(&mut os, &[]).unwrap();
    assert_eq!(
        args_of(&cmd),
        [
            "/app/runners/ProtonGE10/proton",
            "waitforexitandrun",
            "/app/payload/Hop.exe",
            "-fullscreen"
        ]
    );
    assert_eq!(
        cmd.env.get("WINEPREFIX"),
        None,
        "Proton derives its own prefix"
    );
    assert_eq!(cmd.env["STEAM_COMPAT_DATA_PATH"], format!("{DATA}/proton"));
    assert_eq!(
        cmd.env["STEAM_COMPAT_CLIENT_INSTALL_PATH"],
        format!("{DATA}/proton/client")
    );
    assert_eq!(
        os.kind(DATA, "proton/client").unwrap(),
        Some(ruya_play_launch::os::Kind::Dir)
    );
    // The prefix is proton's pfx, made from the template.
    assert!(os
        .read(&format!("{DATA}/proton/pfx/drive_c/windows/system.ini"))
        .is_some());
    // The setup step runs through "proton run", with no wineserver step.
    assert_eq!(os.runs.len(), 1);
    assert_eq!(
        args_of(&os.runs[0])[..3],
        [
            "/app/runners/ProtonGE10/proton",
            "run",
            "/app/payload/redist/vc.exe"
        ]
    );
    let r = state(&os).runner.unwrap();
    assert_eq!(
        (r.family.as_str(), r.source.as_str()),
        ("proton-ge", "system")
    );
    assert_eq!(r.hash, Some("ab".repeat(32)));
}

#[test]
fn proton_outside_steam_has_a_game_id_of_zero_that_nothing_overrides() {
    // protonfixes parses a game id out of STEAM_COMPAT_DATA_PATH when none of SteamAppId,
    // SteamGameId and UMU_ID is set, and stops on a path without digits (RUY-969).
    let mut os = proton_os(None);
    let mut env = base_env();
    env.insert("SteamAppId".into(), "620".into());
    env.insert("SteamGameId".into(), "620".into());
    env.insert("UMU_ID".into(), "umu-620".into());
    let cmd = ruya_play_launch::prepare(&mut os, &[], &env).unwrap();
    assert_eq!(cmd.env["SteamAppId"], "0", "an inherited id is replaced");
    assert_eq!(cmd.env["SteamGameId"], "0");
    assert!(
        !cmd.env.contains_key("UMU_ID"),
        "an inherited umu id would beat the 0: {:?}",
        cmd.env.get("UMU_ID")
    );
    assert!(
        !os.runs[0].env.contains_key("UMU_ID"),
        "nor in a setup step"
    );
    // The setup step runs through the same environment.
    assert_eq!(os.runs[0].env["SteamAppId"], "0");
    assert_eq!(os.runs[0].env["SteamGameId"], "0");
}

#[test]
fn run_env_cannot_set_the_steam_game_id_names() {
    // They are not names the grammar allows (capital letters only), so with PWD and UMU_ID in the
    // deny table no package gets between the launcher and what protonfixes reads.
    for name in ["SteamAppId", "SteamGameId"] {
        let mut g = Game::native();
        g.set(
            "/run",
            json!({"runner": "native", "command": ["${payload}/game"], "env": {name: "1"}}),
        );
        let mut os = g.install();
        let err = launch(&mut os, &[]).unwrap_err();
        assert_eq!(err.code, "env.bad_name", "{name}");
        assert!(os.runs.is_empty(), "{name}: nothing ran");
    }
}

#[test]
fn every_kind_gets_the_working_folder_as_pwd() {
    // No shell sets it before the exec; protonfixes reads it without a fallback.
    let mut env = base_env();
    env.insert("PWD".into(), "/somewhere/else".into());
    let mut os = Game::native().install();
    let cmd = ruya_play_launch::prepare(&mut os, &[], &env).unwrap();
    assert_eq!(cmd.cwd, "/app/payload");
    assert_eq!(cmd.env["PWD"], cmd.cwd);
    let mut os = Game::wine().install();
    let cmd = ruya_play_launch::prepare(&mut os, &[], &env).unwrap();
    assert_eq!(cmd.env["PWD"], "/app/payload");
    assert_eq!(os.runs[0].env["PWD"], os.runs[0].cwd, "a setup step too");
    // run.cwd moves it along.
    let mut os = proton_os(Some("${data}/work"));
    let cmd = ruya_play_launch::prepare(&mut os, &[], &env).unwrap();
    assert_eq!(cmd.cwd, format!("{DATA}/work"));
    assert_eq!(cmd.env["PWD"], cmd.cwd);
    assert_eq!(os.runs[0].env["PWD"], os.runs[0].cwd);
}

#[test]
fn only_proton_gets_a_steam_game_id() {
    for mut os in [Game::native().install(), Game::wine().install()] {
        let cmd = launch(&mut os, &[]).unwrap();
        assert!(!cmd.env.contains_key("SteamAppId"));
        assert!(!cmd.env.contains_key("SteamGameId"));
    }
}

#[test]
fn an_emulator_names_its_component_itself() {
    let mut g = Game::native();
    g.set(
        "/run",
        json!({"runner": "emulator", "component": "dosbox",
                         "command": ["${component:dosbox}/dosbox", "${disc}"],
                         "discs": ["payload/disc1.iso"]}),
    );
    g.manifest["components"] =
        json!([{"id": "dosbox", "type": "emulator", "source": "system", "min": "0.74"}]);
    g.files.push(("payload/disc1.iso".into(), b"iso".to_vec()));
    let mut os = g.install();
    add_system_runner(&mut os, "DOSBox", "dosbox", "emulator", "0.74.3");
    let cmd = launch(&mut os, &[]).unwrap();
    assert_eq!(
        args_of(&cmd),
        ["/app/runners/DOSBox/dosbox", "/app/payload/disc1.iso"]
    );
}

#[test]
fn a_system_runner_of_another_kind_is_refused() {
    let mut g = Game::wine();
    g.set("/components/0/source", json!("system"));
    g.manifest["components"][0]
        .as_object_mut()
        .unwrap()
        .remove("bundled");
    g.files.retain(|(p, _)| !p.starts_with("components/"));
    let mut os = g.install();
    add_system_runner(&mut os, "Odd", "wine", "proton", "10.0");
    let err = launch(&mut os, &[]).unwrap_err();
    assert_eq!(err.code, "launch.runner_kind");
}

// ---- prefix and setup ----

#[test]
fn a_new_prefix_is_the_template_copied_with_dosdevices() {
    let mut os = Game::wine().install();
    launch(&mut os, &[]).unwrap();
    assert_eq!(
        os.read(&format!("{PREFIX}/drive_c/windows/system.ini")),
        Some(&b"[boot]"[..])
    );
    assert_eq!(
        os.nodes.get(&format!("{PREFIX}/dosdevices/c:")),
        Some(&Node::Link("../drive_c".into()))
    );
    assert_eq!(
        os.nodes.get(&format!("{PREFIX}/dosdevices/z:")),
        Some(&Node::Link("/".into()))
    );
    assert_eq!(state(&os).epoch, 1);
}

#[test]
fn a_prefix_without_template_is_left_to_the_runner() {
    let mut g = Game::wine();
    g.set("/run/prefix", json!({"arch": "win32"}));
    let mut os = g.install();
    let cmd = launch(&mut os, &[]).unwrap();
    assert_eq!(os.kind(PREFIX, "").unwrap(), None);
    assert_eq!(cmd.env["WINEARCH"], "win32");
}

#[test]
fn setup_runs_once() {
    let mut g = Game::wine();
    g.set(
        "/run/setup",
        json!([
            {"id": "vcredist", "command": ["${payload}/redist/vc.exe", "/q"], "once": true},
            {"id": "every", "command": ["${payload}/redist/vc.exe", "/check"]}
        ]),
    );
    let mut os = g.install();
    launch(&mut os, &[]).unwrap();
    let first: Vec<Vec<String>> = os.runs.iter().map(|c| c.argv.clone()).collect();
    assert_eq!(
        first,
        vec![
            vec![
                "/app/components/wine/bin/wine".to_string(),
                "/app/payload/redist/vc.exe".into(),
                "/q".into()
            ],
            vec![
                "/app/components/wine/bin/wineserver".to_string(),
                "-w".into()
            ],
            vec![
                "/app/components/wine/bin/wine".to_string(),
                "/app/payload/redist/vc.exe".into(),
                "/check".into()
            ],
            vec![
                "/app/components/wine/bin/wineserver".to_string(),
                "-w".into()
            ],
        ]
    );
    assert_eq!(
        os.runs[0].env["WINEPREFIX"], PREFIX,
        "setup runs in the game's environment"
    );
    assert_eq!(state(&os).setup_done, vec!["vcredist".to_string()]);

    os.runs.clear();
    launch(&mut os, &[]).unwrap();
    let again: Vec<&str> = os.runs.iter().map(|c| c.argv[1].as_str()).collect();
    assert_eq!(
        again,
        ["/app/payload/redist/vc.exe", "-w"],
        "only the step without once"
    );
    assert_eq!(os.runs[0].argv[2], "/check");
}

#[test]
fn a_failed_setup_is_reported_and_the_game_does_not_start() {
    let mut os = Game::wine().install();
    os.on_run("vc.exe", Exit::Code(3), Duration::from_secs(5));
    let err = launch(&mut os, &[]).unwrap_err();
    assert_eq!(err.code, "launch.setup_failed");
    assert!(
        err.message.contains("vcredist") && err.message.contains("code 3"),
        "{}",
        err.message
    );
    let s = state(&os);
    assert_eq!(
        s.setup_failed.as_ref().map(|f| f.step.as_str()),
        Some("vcredist")
    );
    assert_eq!(s.setup_failed.unwrap().message, err.message);
    assert!(s.setup_done.is_empty());
    assert_eq!(os.runs.len(), 1, "no wineserver -w after a failed step");

    // The next launch runs the step again; passing clears the failure.
    os.rules.clear();
    os.runs.clear();
    launch(&mut os, &[]).unwrap();
    assert_eq!(os.runs.len(), 2);
    let s = state(&os);
    assert_eq!(s.setup_failed, None);
    assert_eq!(s.setup_done, vec!["vcredist".to_string()]);
}

#[test]
fn a_setup_step_that_runs_too_long_is_a_failure() {
    let mut os = Game::wine().install();
    os.on_run("vc.exe", Exit::Code(0), Duration::from_secs(9 * 60));
    os.on_run("wineserver", Exit::Code(0), Duration::from_secs(2 * 60));
    let err = launch(&mut os, &[]).unwrap_err();
    assert_eq!(err.code, "launch.setup_failed");
    assert!(err.message.contains("10 minutes"), "{}", err.message);
    assert_eq!(os.runs.len(), 2, "the step and its wait share one deadline");
}

#[test]
fn a_wait_that_runs_too_long_fails_the_step() {
    let mut os = Game::wine().install();
    os.on_run("wineserver", Exit::Code(0), Duration::from_secs(11 * 60));
    let err = launch(&mut os, &[]).unwrap_err();
    assert_eq!(err.code, "launch.setup_failed");
    assert_eq!(state(&os).setup_done, Vec::<String>::new());
}

// ---- the epoch rebuild ----

fn played_once() -> FakeOs {
    let mut os = Game::wine().install();
    launch(&mut os, &[]).unwrap();
    let save = format!("{PREFIX}/drive_c/users/steamuser/Documents/Hop");
    os.file(&format!("{save}/slot1.sav"), "level 7");
    os.file(
        &format!("{PREFIX}/drive_c/windows/junk.dll"),
        "old runner's file",
    );
    os
}

fn update_to_epoch(os: &mut FakeOs, epoch: u64) {
    let mut g = Game::wine();
    g.set("/run/prefix/epoch", json!(epoch));
    g.install_into(os);
}

#[test]
fn an_epoch_rebuild_keeps_the_saves() {
    let mut os = played_once();
    update_to_epoch(&mut os, 2);
    os.runs.clear();
    launch(&mut os, &[]).unwrap();
    let save = format!("{PREFIX}/drive_c/users/steamuser/Documents/Hop/slot1.sav");
    assert_eq!(os.read(&save), Some(&b"level 7"[..]), "the save is back");
    assert_eq!(
        os.read(&format!("{PREFIX}/drive_c/windows/junk.dll")),
        None,
        "the prefix is new"
    );
    assert!(os
        .read(&format!("{PREFIX}/drive_c/windows/system.ini"))
        .is_some());
    assert_eq!(
        os.read(&format!(
            "{DATA}/.ruya-play/epoch-1-backup/drive_c/users/steamuser/Documents/Hop/slot1.sav"
        )),
        Some(&b"level 7"[..]),
        "the backup stays"
    );
    let s = state(&os);
    assert_eq!((s.epoch, s.backup_of), (2, None));
    assert_eq!(os.runs.len(), 2, "setup runs again for the new prefix");
}

/// Only the newest backup is kept (05 §6.3): the rebuild from epoch 2 removes `epoch-1-backup`
/// and an older one, a link with a backup's name goes as a link, other names stay.
#[test]
fn only_the_newest_epoch_backup_is_kept() {
    let mut os = played_once();
    update_to_epoch(&mut os, 2);
    launch(&mut os, &[]).unwrap();
    let dir = format!("{DATA}/.ruya-play");
    os.file(&format!("{dir}/epoch-0-backup/old.sav"), "older");
    os.file("/home/p/keep/f", "not the launcher's");
    os.link(&format!("{dir}/epoch-7-backup"), "/home/p/keep");
    os.file(&format!("{dir}/epoch-x-backup/f"), "not a backup name");
    update_to_epoch(&mut os, 3);
    launch(&mut os, &[]).unwrap();
    let names: Vec<String> = os
        .list(&dir, "")
        .unwrap()
        .into_iter()
        .map(|(n, _)| n)
        .collect();
    assert_eq!(names, ["epoch-2-backup", "epoch-x-backup", "state.json"]);
    assert_eq!(
        os.read(&format!(
            "{dir}/epoch-2-backup/drive_c/users/steamuser/Documents/Hop/slot1.sav"
        )),
        Some(&b"level 7"[..]),
        "the newest backup stays"
    );
    assert_eq!(os.read("/home/p/keep/f"), Some(&b"not the launcher's"[..]));
    assert_eq!(state(&os).epoch, 3);
}

#[test]
fn a_rebuild_cut_short_resumes_from_the_complete_backup() {
    let mut os = played_once();
    update_to_epoch(&mut os, 2);
    // A crash after the backup and the removal: the status file says the backup is complete.
    let backup = format!("{DATA}/.ruya-play/epoch-1-backup/drive_c/users/steamuser/Documents/Hop");
    os.file(&format!("{backup}/slot1.sav"), "level 7");
    for k in os.below(PREFIX) {
        os.nodes.remove(&k);
    }
    os.dir(PREFIX);
    let mut s = state(&os);
    s.backup_of = Some(1);
    os.file(&format!("{DATA}/.ruya-play/state.json"), s.to_bytes());
    launch(&mut os, &[]).unwrap();
    assert_eq!(
        os.read(&format!(
            "{PREFIX}/drive_c/users/steamuser/Documents/Hop/slot1.sav"
        )),
        Some(&b"level 7"[..])
    );
    assert_eq!(state(&os).epoch, 2);
}

#[test]
fn an_epoch_rebuild_never_follows_a_planted_link() {
    let mut os = played_once();
    // Outside what the prefix holds: a secret the sandbox shows.
    os.file("/home/p/.ssh/id_ed25519", "secret");
    // A link inside a save folder, and a save folder that is itself a link.
    let save = format!("{PREFIX}/drive_c/users/steamuser/Documents/Hop");
    os.link(&format!("{save}/keys"), "/home/p/.ssh");
    let mut g = Game::wine();
    g.set(
        "/data/saves",
        json!([
            "prefix:drive_c/users/steamuser/Documents/Hop",
            "prefix:drive_c/users/steamuser/Saved Games/Hop",
            "prefix:drive_c/users/link/Hop"
        ]),
    )
    .set("/run/prefix/epoch", json!(2));
    g.install_into(&mut os);
    os.link(
        &format!("{PREFIX}/drive_c/users/steamuser/Saved Games/Hop"),
        "/home/p/.ssh",
    );
    os.link(&format!("{PREFIX}/drive_c/users/link"), "/home/p");
    let before = os.below("/home/p/.ssh");

    launch(&mut os, &[]).unwrap();

    // Links were copied as links, never followed: the secret is nowhere but where it was.
    let copies: Vec<_> = os
        .nodes
        .iter()
        .filter(|(k, n)| !k.starts_with("/home/p/.ssh") && **n == Node::File(b"secret".to_vec()))
        .collect();
    assert!(copies.is_empty(), "{copies:?}");
    assert_eq!(os.below("/home/p/.ssh"), before);
    assert_eq!(
        os.nodes.get(&format!("{save}/keys")),
        Some(&Node::Link("/home/p/.ssh".into()))
    );
    assert_eq!(os.read(&format!("{save}/slot1.sav")), Some(&b"level 7"[..]));
    // The save behind a linked folder is skipped with a log line.
    assert!(
        os.lines
            .borrow()
            .iter()
            .any(|l| l.contains("users/link/Hop") && l.contains("not followed")),
        "{:?}",
        os.lines.borrow()
    );
    assert_eq!(state(&os).epoch, 2);
}

#[test]
fn the_status_file_is_not_followed_when_it_is_a_link() {
    let mut os = Game::native().install();
    os.file("/srv/p/notes.txt", "mine");
    let planted = State {
        epoch: 9,
        ..State::default()
    };
    os.file("/srv/p/state.json", planted.to_bytes());
    os.link(&format!("{DATA}/.ruya-play"), "/srv/p");
    let err = launch(&mut os, &[]).unwrap_err();
    assert_eq!(err.code, "launch.state");
    // Not read through the link either: the launch stops there, it does not start from none.
    assert!(err.message.contains("not followed"), "{}", err.message);
    assert_eq!(os.read("/srv/p/notes.txt"), Some(&b"mine"[..]));
    assert_eq!(os.read("/srv/p/state.json"), Some(&planted.to_bytes()[..]));
    assert_eq!(
        os.below("/srv/p").len(),
        3,
        "nothing written behind the link"
    );
}

#[test]
fn a_status_file_that_cannot_be_checked_fails_the_launch() {
    let mut os = Game::native().install();
    os.fail_kind(
        &format!("{DATA}/.ruya-play/state.json"),
        std::io::ErrorKind::PermissionDenied,
    );
    let err = launch(&mut os, &[]).unwrap_err();
    assert_eq!(err.code, "launch.state");
    assert!(err.message.contains("cannot be checked"), "{}", err.message);
}

#[test]
fn a_status_file_that_cannot_be_read_fails_the_launch() {
    let mut os = Game::native().install();
    let path = format!("{DATA}/.ruya-play/state.json");
    os.file(&path, State::default().to_bytes());
    os.fail_open(&path, std::io::ErrorKind::PermissionDenied);
    let err = launch(&mut os, &[]).unwrap_err();
    assert_eq!(err.code, "launch.state");
    assert!(os.runs.is_empty(), "the game was not started over it");
}

#[test]
fn a_prefix_that_cannot_be_checked_fails_the_launch() {
    let mut os = Game::wine().install();
    os.fail_kind(PREFIX, std::io::ErrorKind::PermissionDenied);
    let err = launch(&mut os, &[]).unwrap_err();
    assert_eq!(err.code, "launch.prefix");
    assert!(err.message.contains("cannot be checked"), "{}", err.message);
    assert!(os.runs.is_empty(), "nothing was rebuilt over it");
}

#[test]
fn a_missing_status_file_and_prefix_are_absent_not_errors() {
    let mut os = Game::wine().install();
    launch(&mut os, &[]).unwrap();
    assert_eq!(state(&os).epoch, 1);
}

#[test]
fn a_template_deeper_than_the_cap_is_a_prefix_failure() {
    let mut g = Game::wine();
    let deep = vec!["d"; MAX_COPY_DEPTH + 1].join("/");
    g.files
        .push((format!("payload/prefix-template/{deep}/f"), b"x".to_vec()));
    let mut os = g.install();
    let err = launch(&mut os, &[]).unwrap_err();
    assert_eq!(err.code, "launch.prefix");
    assert!(err.message.contains("folders deep"), "{}", err.message);
}

#[test]
fn a_status_file_the_game_scribbled_counts_as_absent() {
    let mut os = Game::wine().install();
    os.file(&format!("{DATA}/.ruya-play/state.json"), "{not json");
    os.dir(PREFIX);
    launch(&mut os, &[]).unwrap();
    // Epoch 0 against the package's 1: rebuilt with saves kept, setup again.
    assert_eq!(state(&os).epoch, 1);
    assert!(os.lines.borrow().iter().any(|l| l.contains("status file")));
}

// ---- the system runner scan ----

#[test]
fn the_scan_skips_links_bad_files_and_missing_entries() {
    let mut os = FakeOs::new();
    add_system_runner(&mut os, "A-Wine10", "wine", "wine", "10.2");
    add_system_runner(&mut os, "B-Repeat", "wine", "wine", "10.2");
    // A link to a valid runner elsewhere: never followed.
    add_runner_at(&mut os, "/opt/Wine12", "wine", "wine", "12.0");
    os.link("/app/runners/C-Link", "/opt/Wine12");
    os.file(
        "/app/runners/D-Bad/runner.json",
        r#"{"format":1,"family":"Wine"}"#,
    );
    os.file(
        "/app/runners/E-NoEntry/runner.json",
        runner_json("wine", "wine", "11.0"),
    );
    os.dir("/app/runners/F-Empty");
    os.file("/app/runners/G-Future/runner.json", r#"{"format":2}"#);
    add_system_runner(&mut os, "H-Proton", "proton-ge", "proton", "GE-Proton10-9");
    os.link("/app/runners/H-Proton/proton", "/usr/bin/python3");
    add_system_runner(&mut os, "I-Hash", "wine", "wine", "9.0");
    os.file("/app/runners/I-Hash/.ruya-runner-hash", "f".repeat(64));
    add_system_runner(&mut os, "J-BadHash", "wine", "wine", "8.0");
    os.file("/app/runners/J-BadHash/.ruya-runner-hash", "nothex");
    let found = scan(&os);
    let names: Vec<_> = found.iter().map(|f| f.root.as_str()).collect();
    assert_eq!(
        names,
        [
            "/app/runners/A-Wine10",
            "/app/runners/I-Hash",
            "/app/runners/J-BadHash"
        ]
    );
    assert_eq!(found[1].hash, Some("f".repeat(64)));
    assert_eq!(found[2].hash, None);
    let log = os.lines.borrow().join("\n");
    for needle in [
        "B-Repeat",
        "C-Link",
        "D-Bad",
        "E-NoEntry",
        "F-Empty",
        "G-Future",
        "H-Proton",
        "J-BadHash",
    ] {
        assert!(log.contains(needle), "{needle} is logged:\n{log}");
    }
}

#[test]
fn the_scan_reads_at_most_32_folders() {
    let mut os = FakeOs::new();
    for i in 0..=MAX_RUNNER_DIRS {
        add_system_runner(
            &mut os,
            &format!("W{i:02}"),
            "wine",
            "wine",
            &format!("10.{i}"),
        );
    }
    os.file("/app/runners/a-file", "not a folder");
    let found = scan(&os);
    assert_eq!(found.len(), MAX_RUNNER_DIRS);
    assert_eq!(
        found.last().unwrap().root,
        format!("/app/runners/W{:02}", MAX_RUNNER_DIRS - 1)
    );
    assert!(os.lines.borrow().iter().any(|l| l.contains("W32")));
}

#[test]
fn no_runners_folder_is_no_system_runners() {
    let os = FakeOs::new();
    assert!(scan(&os).is_empty());
    assert!(os.lines.borrow().is_empty());
}

// ---- the package and the arguments ----

#[test]
fn a_damaged_package_is_one_sentence() {
    let mut os = Game::native().install();
    os.file("/app/play.json", r#"{"format": 1, "id": "x"}"#);
    let err = launch(&mut os, &[]).unwrap_err();
    assert!(err.message.contains("reinstall"), "{}", err.message);

    let mut os = Game::native().install();
    os.nodes.remove("/app/play.files");
    let err = launch(&mut os, &[]).unwrap_err();
    assert!(err.message.contains("play.files"), "{}", err.message);

    // A file the table does not list is refused, as at install.
    let mut g = Game::native();
    g.files.retain(|(p, _)| p != "payload/game");
    let mut os = g.install();
    let err = launch(&mut os, &[]).unwrap_err();
    assert_eq!(err.code, "run.command_missing");
}

#[test]
fn a_bundled_runner_json_is_read_at_launch() {
    let mut g = Game::wine();
    g.files.push((
        "components/wine/runner.json".into(),
        br#"{"format":1,"family":"wine-ge","kind":"wine","version":"8.26","arch":"x86_64","entry":{"wine":"bin/wine64","wineserver":"bin/wineserver"}}"#.to_vec(),
    ));
    g.files
        .push(("components/wine/bin/wine64".into(), b"elf".to_vec()));
    let mut os = g.install();
    // A newer system runner of another family never replaces it.
    add_system_runner(&mut os, "Wine11", "wine", "wine", "11.0");
    let cmd = launch(&mut os, &[]).unwrap();
    assert_eq!(cmd.argv[0], "/app/components/wine/bin/wine64");
    assert_eq!(state(&os).runner.unwrap().family, "wine-ge");
}

#[test]
fn runner_arg_is_what_parse_args_reads_back() {
    use ruya_play_format::resolve::Override;
    use ruya_play_launch::{parse_args, runner_arg};
    assert_eq!(runner_arg(Override::PackageDefault), None);
    for choice in [Override::Bundled, Override::System] {
        let arg = runner_arg(choice).expect("a flag");
        assert_eq!(parse_args(&[arg]).unwrap(), choice);
    }
    assert_eq!(
        runner_arg(Override::Bundled).as_deref(),
        Some("--runner=bundled")
    );
    assert_eq!(
        runner_arg(Override::System).as_deref(),
        Some("--runner=system")
    );
}

#[test]
fn the_runner_argument() {
    use ruya_play_format::resolve::Override;
    use ruya_play_launch::parse_args;
    let s = |v: &[&str]| v.iter().map(|a| a.to_string()).collect::<Vec<_>>();
    assert_eq!(parse_args(&s(&[])).unwrap(), Override::PackageDefault);
    assert_eq!(
        parse_args(&s(&["--runner=package"])).unwrap(),
        Override::PackageDefault
    );
    assert_eq!(
        parse_args(&s(&["--runner=bundled"])).unwrap(),
        Override::Bundled
    );
    assert_eq!(
        parse_args(&s(&["--runner=system"])).unwrap(),
        Override::System
    );
    for bad in [
        &["--runner=newest"][..],
        &["--runner"],
        &["-c", "sh"],
        &["--runner=system", "--runner=bundled"],
    ] {
        assert_eq!(
            parse_args(&s(bad)).unwrap_err().code,
            "launch.argument",
            "{bad:?}"
        );
    }
}

#[test]
fn the_system_override_reaches_the_resolver() {
    let mut os = Game::wine().install();
    add_system_runner(&mut os, "Wine9", "wine", "wine", "9.10");
    // newest: the bundled 9.20 beats 9.10.
    let cmd = launch(&mut os, &[]).unwrap();
    assert_eq!(cmd.argv[0], "/app/components/wine/bin/wine");
    let cmd = launch(&mut os, &["--runner=system"]).unwrap();
    assert_eq!(cmd.argv[0], "/app/runners/Wine9/bin/wine");
    assert_eq!(state(&os).runner.unwrap().source, "system");
}

#[test]
fn the_status_file_keeps_the_last_runner() {
    let mut os = Game::native().install();
    launch(&mut os, &[]).unwrap();
    assert_eq!(
        state(&os),
        State {
            runner: None,
            ..State::default()
        }
    );
}
