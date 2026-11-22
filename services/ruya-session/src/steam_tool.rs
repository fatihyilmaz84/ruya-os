//! Steam's default compatibility tool is GE-Proton (RUY-35, ADR-025, ADR-038 "Steam").
//!
//! The image links every Proton runner of `/usr/lib/ruyaos/play/runners` into the Steam Flatpak's
//! `com.valvesoftware.Steam.CompatibilityTool` extension point (tmpfiles.d), so Steam lists it. This
//! module makes the newest one the default: Steam's `CompatToolMapping` entry `"0"` is the tool
//! used for every game without a mapping of its own.
//!
//! It runs once per profile, as the profile user, as `ExecStartPre` of the Steam unit
//! (`spawner::launch_command_in`, subcommand `steam-default-tool`), so Steam is not running while
//! its file is edited. Root never writes into a profile (RUY-35 plan audit). The first run records
//! a marker; with it there, nothing is touched, so a tool the player picks later stays.
//!
//! **The Steam folder belongs to a sandbox.** The Flatpak persists all of
//! `~/.var/app/com.valvesoftware.Steam`, so a game inside Steam can write there: the marker, the
//! config and every folder on the way. A game may delete the marker; the step then runs again,
//! which is harmless only because an existing default is never replaced. And a game may plant
//! links, so every read and write goes through `ruya_fs` (an `openat` walk from the home's folder,
//! RUY-911), which refuses a link at any step of the path and never follows one.
//!
//! Which runner: the one the launcher's scan (`ruya_play_launch::runners::scan_in`, the same code
//! ruya-library uses) finds with `kind` `proton` (the ones `platform.rs` links for Steam), the
//! newest by `resolve::compare_versions`, and the tool name is the one in that runner's own
//! `compatibilitytool.vdf`.
//!
//! Steam always starts: the step is `ExecStartPre=-`, it only reads and writes two small files,
//! and every failure is a message on stderr and a missing marker (tried again at the next start).

use std::io::{self, Read as _};
use std::path::{Path, PathBuf};

use ruya_play_format::resolve::compare_versions;
use ruya_play_launch::os::LaunchOs;
use ruya_play_launch::runners::scan_in;

use ruya_fs::Dir;

use ruya_vdf::{self as vdf, Entry, Value};

/// The Steam Flatpak (the only app this step belongs to).
pub const STEAM_APP_ID: &str = "com.valvesoftware.Steam";
/// The image's runners; each Proton one has its own `compatibilitytool.vdf` (GE-Proton's tarball).
pub const RUNNERS_DIR: &str = "/usr/lib/ruyaos/play/runners";
/// The subcommand of `ruya-session` that does this.
pub const SUBCOMMAND: &str = "steam-default-tool";
/// What Steam reads from a tool's folder.
pub const TOOL_FILE: &str = "compatibilitytool.vdf";

/// Below the profile's home: Steam's config, and the marker next to Steam's data. Both are inside
/// the sandbox's persistent folder.
const CONFIG: &str = ".var/app/com.valvesoftware.Steam/.local/share/Steam/config/config.vdf";
const MARKER: &str = ".var/app/com.valvesoftware.Steam/.ruyaos-default-tool";
/// A `compatibilitytool.vdf` is a few hundred bytes.
const MAX_TOOL_FILE: u64 = 64 * 1024;
/// Steam's `config.vdf` holds a few kilobytes to a few hundred; more is not Steam's file.
const MAX_CONFIG_FILE: u64 = 8 * 1024 * 1024;

/// The unit property that runs the step before Steam (the `-` ignores a failure).
pub fn exec_start_pre(session_program: &str) -> String {
    format!("--property=ExecStartPre=-{session_program} {SUBCOMMAND}")
}

/// The name Steam knows a tool by: the one block under `compatibilitytools/compat_tools` in its
/// `compatibilitytool.vdf`.
pub fn tool_name(vdf_text: &str) -> Option<String> {
    let root = vdf::parse(vdf_text).ok()?;
    let Value::Obj(file) = &vdf::find(&root, "compatibilitytools")?.value else {
        return None;
    };
    let Value::Obj(tools) = &vdf::find(file, "compat_tools")?.value else {
        return None;
    };
    tools
        .iter()
        .find(|t| matches!(t.value, Value::Obj(_)))
        .map(|t| t.key.clone())
}

/// The tool to make the default: the newest `proton` runner of `runners`, by its `runner.json`
/// version, and the name in that runner's `compatibilitytool.vdf`. A runner that is the newest but
/// has no readable tool file is an error, never a fall back to an older one.
pub fn default_tool(os: &dyn LaunchOs, runners: &str) -> Result<String, String> {
    let found = scan_in(os, runners);
    let newest = found
        .iter()
        .filter(|f| f.runner.kind == "proton")
        .max_by(|a, b| compare_versions(&a.runner.version, &b.runner.version))
        .ok_or_else(|| format!("no Proton runner in {runners}"))?;
    let mut text = String::new();
    os.open(&newest.root, TOOL_FILE)
        .and_then(|r| r.take(MAX_TOOL_FILE).read_to_string(&mut text))
        .map_err(|e| format!("{}/{TOOL_FILE}: {e}", newest.root))?;
    tool_name(&text).ok_or_else(|| format!("{}/{TOOL_FILE} names no tool", newest.root))
}

/// `config.vdf` with `tool` as the default (`CompatToolMapping` entry `"0"`). `None` text is a
/// config Steam has not made yet. `Ok(None)`: the file already has a default, whoever set it, and
/// stays as it is. `Err`: the text is not a Steam file (or has a string where a block belongs);
/// the caller leaves it alone.
pub fn with_default(config: Option<&str>, tool: &str) -> Result<Option<String>, String> {
    let mut root = vdf::parse(config.unwrap_or(""))?;
    let mut list = &mut root;
    for key in ["InstallConfigStore", "Software", "Valve", "Steam"] {
        list = vdf::block_mut(list, key)?;
    }
    let mapping = vdf::block_mut(list, "CompatToolMapping")?;
    if vdf::find(mapping, "0").is_some() {
        return Ok(None);
    }
    let text = |key: &str, value: &str| Entry {
        key: key.to_owned(),
        value: Value::Str(value.to_owned()),
    };
    mapping.push(Entry {
        key: "0".to_owned(),
        value: Value::Obj(vec![
            text("name", tool),
            text("config", ""),
            text("priority", "75"),
        ]),
    });
    Ok(Some(vdf::write(&root)))
}

/// What `run` did, for the log.
#[derive(Debug, PartialEq, Eq)]
pub enum Done {
    /// A marker from an earlier start: nothing touched.
    AlreadySettled,
    /// The config already named a default: kept, marker written.
    KeptExisting,
    /// The default is now this tool.
    Set(String),
}

/// The whole step for the profile whose home is `home`. An `Err` writes no marker, so the next
/// start tries again; a config that is not valid is never overwritten.
pub fn run(home: &Path, os: &dyn LaunchOs, runners: &str) -> Result<Done, String> {
    let (config, marker) = (Path::new(CONFIG), Path::new(MARKER));
    if std::fs::symlink_metadata(home.join(marker)).is_ok() {
        return Ok(Done::AlreadySettled);
    }
    let tool = default_tool(os, runners)?;
    let home_dir = Dir::open(home).map_err(|e| format!("{}: {e}", home.display()))?;
    let current = match home_dir.read(config, MAX_CONFIG_FILE).and_then(|bytes| {
        String::from_utf8(bytes).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }) {
        Ok(text) => Some(text),
        Err(e) if e.kind() == io::ErrorKind::NotFound => None,
        Err(e) => return Err(format!("{CONFIG}: {e}")),
    };
    let done = match with_default(current.as_deref(), &tool)
        .map_err(|e| format!("{CONFIG} is left as it is: {e}"))?
    {
        Some(text) => {
            home_dir
                .write(config, text.as_bytes())
                .map_err(|e| format!("{CONFIG}: {e}"))?;
            Done::Set(tool)
        }
        None => Done::KeptExisting,
    };
    home_dir
        .write(marker, b"done\n")
        .map_err(|e| format!("{MARKER}: {e}"))?;
    Ok(done)
}

/// The subcommand: reports on stderr, exits 0 whatever happened (Steam starts regardless).
pub fn main_step() {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        eprintln!("ruya-session: {SUBCOMMAND}: HOME is not set");
        return;
    };
    #[cfg(target_os = "linux")]
    let result = run(&home, &ruya_play_launch::linux::LinuxOs, RUNNERS_DIR);
    #[cfg(not(target_os = "linux"))]
    let result: Result<Done, String> = Err(format!("{}: needs Linux", home.display()));
    match result {
        Ok(Done::Set(tool)) => eprintln!("ruya-session: Steam's default tool is now {tool}"),
        Ok(done) => eprintln!("ruya-session: {SUBCOMMAND}: {done:?}"),
        Err(e) => eprintln!("ruya-session: {SUBCOMMAND}: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ruya_play_launch::fake::FakeOs;
    use std::fs;

    const GE_VDF: &str = "\"compatibilitytools\"\n{\n  \"compat_tools\"\n  {\n    \"GE-Proton11-12\"\n    {\n      \"install_path\" \".\"\n      \"display_name\" \"GE-Proton11-12\"\n      \"from_oslist\" \"windows\"\n      \"to_oslist\" \"linux\"\n    }\n  }\n}\n";
    const TOOL: &str = "GE-Proton11-12";

    fn mapping_of(text: &str) -> Vec<Entry> {
        let mut root = vdf::parse(text).expect("valid");
        let mut list = &mut root;
        for key in [
            "InstallConfigStore",
            "Software",
            "Valve",
            "Steam",
            "CompatToolMapping",
        ] {
            list = vdf::block_mut(list, key).expect("block");
        }
        list.clone()
    }

    fn name_of(entry: &Entry) -> &str {
        let Value::Obj(inner) = &entry.value else {
            panic!("a block")
        };
        match &vdf::find(inner, "name").expect("name").value {
            Value::Str(s) => s,
            Value::Obj(_) => panic!("a string"),
        }
    }

    #[test]
    fn a_fresh_config_gets_the_default() {
        let text = with_default(None, TOOL).expect("ok").expect("changed");
        let mapping = mapping_of(&text);
        assert_eq!(mapping.len(), 1);
        assert_eq!(mapping[0].key, "0");
        assert_eq!(name_of(&mapping[0]), TOOL);
        // An empty file is the same as none.
        assert_eq!(with_default(Some(" \n"), TOOL).expect("ok"), Some(text));
    }

    #[test]
    fn a_config_of_steam_keeps_everything_and_gains_the_default() {
        let config = "\"InstallConfigStore\"\n{\n\t\"Software\"\n\t{\n\t\t\"Valve\"\n\t\t{\n\t\t\t\"Steam\"\n\t\t\t{\n\t\t\t\t\"AutoUpdateWindowStart\"\t\t\"-1\"\n\t\t\t\t\"CompatToolMapping\"\n\t\t\t\t{\n\t\t\t\t\t\"1245620\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"name\"\t\t\"proton_9\"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n";
        let text = with_default(Some(config), TOOL)
            .expect("ok")
            .expect("changed");
        assert!(text.contains("AutoUpdateWindowStart"));
        let mapping = mapping_of(&text);
        let keys: Vec<&str> = mapping.iter().map(|e| e.key.as_str()).collect();
        assert_eq!(keys, ["1245620", "0"]);
        assert_eq!(name_of(&mapping[0]), "proton_9");
        assert_eq!(name_of(&mapping[1]), TOOL);
    }

    #[test]
    fn an_existing_default_is_left_untouched() {
        let config = "\"InstallConfigStore\"\n{\n\t\"Software\"\n\t{\n\t\t\"Valve\"\n\t\t{\n\t\t\t\"Steam\"\n\t\t\t{\n\t\t\t\t\"CompatToolMapping\"\n\t\t\t\t{\n\t\t\t\t\t\"0\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"name\"\t\t\"proton_experimental\"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n";
        assert_eq!(with_default(Some(config), TOOL), Ok(None));
    }

    #[test]
    fn a_config_that_is_not_steams_is_an_error() {
        for bad in [
            "\"InstallConfigStore\" {",
            "garbage",
            "\"InstallConfigStore\" \"text\"",
            "\"InstallConfigStore\" { \"Software\" { \"Valve\" { \"Steam\" { \"CompatToolMapping\" \"x\" } } } }",
        ] {
            assert!(with_default(Some(bad), TOOL).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn the_tool_name_is_read_from_the_tools_own_file() {
        assert_eq!(tool_name(GE_VDF).as_deref(), Some(TOOL));
        for bad in [
            "",
            "garbage",
            "\"compatibilitytools\" { }",
            "\"compat_tools\" \"x\"",
        ] {
            assert_eq!(tool_name(bad), None, "{bad:?}");
        }
    }

    const RUNNER_JSON: &str = include_str!("../../../image/play/runners/ProtonGE11/runner.json");
    const RUNNERS: &str = "/runners";

    /// A fake image: (folder, version, tool name) per Proton runner, with the real runner.json of
    /// the image as the template.
    fn image(runners: &[(&str, &str, &str)]) -> FakeOs {
        let mut os = FakeOs::new();
        for (folder, version, tool) in runners {
            let root = format!("{RUNNERS}/{folder}");
            os.file(
                &format!("{root}/runner.json"),
                RUNNER_JSON.replace("GE-Proton11-12", version),
            );
            os.file(&format!("{root}/proton"), "#!/bin/sh\n");
            os.file(&format!("{root}/{TOOL_FILE}"), GE_VDF.replace(TOOL, tool));
        }
        os
    }

    #[test]
    fn the_newest_proton_runner_by_its_version_wins_not_the_folder_name() {
        let os = image(&[
            ("ProtonGE99", "GE-Proton10-34", "GE-Proton10-34"),
            ("ProtonGE11", "GE-Proton11-12", TOOL),
        ]);
        assert_eq!(default_tool(&os, RUNNERS), Ok(TOOL.to_owned()));
    }

    #[test]
    fn only_proton_runners_count() {
        let mut os = image(&[("ProtonGE10", "GE-Proton10-34", "GE-Proton10-34")]);
        os.file(
            "/runners/Other/runner.json",
            RUNNER_JSON
                .replace("GE-Proton11-12", "GE-Proton12-1")
                .replace("\"kind\": \"proton\"", "\"kind\": \"emulator\"")
                .replace("\"entry\": { \"proton\": \"proton\" },", ""),
        );
        os.file("/runners/Other/compatibilitytool.vdf", GE_VDF);
        let found = scan_in(&os, RUNNERS);
        assert_eq!(
            found.len(),
            2,
            "the emulator runner is found: {:?}",
            os.lines
        );
        assert_eq!(default_tool(&os, RUNNERS), Ok("GE-Proton10-34".to_owned()));
    }

    #[test]
    fn a_newest_runner_without_a_readable_tool_file_is_an_error() {
        let mut os = image(&[
            ("ProtonGE10", "GE-Proton10-34", "GE-Proton10-34"),
            ("ProtonGE11", "GE-Proton11-12", TOOL),
        ]);
        os.nodes.remove("/runners/ProtonGE11/compatibilitytool.vdf");
        assert!(default_tool(&os, RUNNERS).is_err());
        os.file("/runners/ProtonGE11/compatibilitytool.vdf", "garbage");
        assert!(default_tool(&os, RUNNERS).is_err());
        assert!(default_tool(&FakeOs::new(), RUNNERS).is_err());
    }

    /// A home whose Steam already wrote `config` (when given); the step runs once. Returns the
    /// home, the result and the config as it is afterwards.
    fn start_with(
        tmp: &Path,
        config: Option<&str>,
    ) -> (PathBuf, Result<Done, String>, Option<String>) {
        let os = image(&[("ProtonGE11", "GE-Proton11-12", TOOL)]);
        let home = tmp.join("home");
        let file = home.join(CONFIG);
        fs::create_dir_all(file.parent().expect("parent")).expect("dirs");
        if let Some(text) = config {
            fs::write(&file, text).expect("config");
        }
        let result = run(&home, &os, RUNNERS);
        let after = fs::read_to_string(&file).ok();
        (home, result, after)
    }

    #[test]
    fn the_default_is_set_once_and_a_later_choice_stays() {
        let tmp = tempfile::tempdir().expect("tmp");
        let (home, result, first) = start_with(tmp.path(), None);
        assert_eq!(result, Ok(Done::Set(TOOL.to_owned())));
        let first = first.expect("written");
        assert_eq!(name_of(&mapping_of(&first)[0]), TOOL);
        assert!(home.join(MARKER).exists());

        // The player picks another tool in Steam; the next start leaves it.
        let chosen = first.replace(TOOL, "proton_9");
        fs::write(home.join(CONFIG), &chosen).expect("player's choice");
        let os = image(&[("ProtonGE11", "GE-Proton11-12", TOOL)]);
        assert_eq!(run(&home, &os, RUNNERS), Ok(Done::AlreadySettled));
        assert_eq!(fs::read_to_string(home.join(CONFIG)).expect("read"), chosen);

        // A game deletes the marker: the step runs again and keeps what is there.
        fs::remove_file(home.join(MARKER)).expect("marker");
        assert_eq!(run(&home, &os, RUNNERS), Ok(Done::KeptExisting));
        assert_eq!(fs::read_to_string(home.join(CONFIG)).expect("read"), chosen);
    }

    #[test]
    fn an_existing_default_is_kept_and_settled() {
        let tmp = tempfile::tempdir().expect("tmp");
        let theirs = with_default(None, "proton_9").expect("ok").expect("text");
        let (home, result, after) = start_with(tmp.path(), Some(&theirs));
        assert_eq!(result, Ok(Done::KeptExisting));
        assert_eq!(after.as_deref(), Some(theirs.as_str()));
        assert!(home.join(MARKER).exists());
    }

    #[test]
    fn a_malformed_config_is_left_as_it_is_and_tried_again_later() {
        let tmp = tempfile::tempdir().expect("tmp");
        let bad = "\"InstallConfigStore\" {";
        let (home, result, after) = start_with(tmp.path(), Some(bad));
        let err = result.expect_err("refused");
        assert!(err.contains("is left as it is"), "{err}");
        assert_eq!(after.as_deref(), Some(bad));
        assert!(!home.join(MARKER).exists());
    }

    #[test]
    fn no_runner_is_an_error_and_writes_nothing() {
        let tmp = tempfile::tempdir().expect("tmp");
        let home = tmp.path().join("home");
        assert!(run(&home, &FakeOs::new(), RUNNERS).is_err());
        assert!(!home.exists());
    }

    #[test]
    fn the_unit_property_is_one_plain_command() {
        assert_eq!(
            exec_start_pre("/usr/bin/ruya-session"),
            "--property=ExecStartPre=-/usr/bin/ruya-session steam-default-tool"
        );
    }

    /// What a game inside Steam can plant: links where the step reads and writes (RUY-35 review).
    #[cfg(unix)]
    mod planted {
        use super::*;
        use std::ffi::OsStr;
        use std::os::unix::fs::symlink;

        /// A home with Steam's folders, a victim file and a folder outside the home.
        fn home_with_victim(tmp: &Path) -> (PathBuf, PathBuf, PathBuf) {
            let home = tmp.join("home");
            fs::create_dir_all(home.join(CONFIG).parent().expect("parent")).expect("dirs");
            let victim = tmp.join("other-app-save");
            fs::write(&victim, "precious").expect("victim");
            let outside = tmp.join("outside");
            fs::create_dir(&outside).expect("outside");
            (home, victim, outside)
        }

        fn step(home: &Path) -> Result<Done, String> {
            run(
                home,
                &image(&[("ProtonGE11", "GE-Proton11-12", TOOL)]),
                RUNNERS,
            )
        }

        #[test]
        fn a_link_as_the_temporary_file_is_not_written_through() {
            let tmp = tempfile::tempdir().expect("tmp");
            let (home, victim, _) = home_with_victim(tmp.path());
            for file in [CONFIG, MARKER] {
                let tmp = ruya_fs::temp_name(OsStr::new(file));
                symlink(&victim, home.join(tmp)).expect("link");
            }
            assert_eq!(step(&home), Ok(Done::Set(TOOL.to_owned())));
            assert_eq!(fs::read_to_string(&victim).expect("read"), "precious");
        }

        #[test]
        fn a_link_as_the_config_is_refused() {
            let tmp = tempfile::tempdir().expect("tmp");
            let (home, victim, _) = home_with_victim(tmp.path());
            symlink(&victim, home.join(CONFIG)).expect("link");
            assert!(step(&home).is_err());
            assert_eq!(fs::read_to_string(&victim).expect("read"), "precious");
            assert!(!home.join(MARKER).exists());
        }

        #[test]
        fn a_linked_folder_below_the_steam_folder_is_refused() {
            let tmp = tempfile::tempdir().expect("tmp");
            let (home, victim, outside) = home_with_victim(tmp.path());
            let steam_data = home.join(".var/app/com.valvesoftware.Steam/.local/share");
            fs::remove_dir_all(&steam_data).expect("remove");
            fs::create_dir_all(steam_data.parent().expect("parent")).expect("dirs");
            symlink(&outside, &steam_data).expect("link");
            let err = step(&home).expect_err("refused");
            assert!(err.contains("is a link"), "{err}");
            assert_eq!(fs::read_dir(&outside).expect("list").count(), 0);
            assert_eq!(fs::read_to_string(&victim).expect("read"), "precious");
        }
    }
}
