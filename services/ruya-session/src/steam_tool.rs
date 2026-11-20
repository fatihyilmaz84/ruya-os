//! Steam's default compatibility tool is GE-Proton (RUY-35, ADR-025, ADR-038 "Steam").
//!
//! The image links every Proton runner of `/usr/lib/ruyaos/play/runners` into the Steam Flatpak's
//! `com.valvesoftware.Steam.CompatibilityTool` extension point (tmpfiles.d), so Steam lists it. This
//! module makes it the default: Steam's `CompatToolMapping` entry `"0"` is the tool used for every
//! game without a mapping of its own.
//!
//! It runs once per profile, as the profile user, as `ExecStartPre` of the Steam unit
//! (`spawner::launch_command_in`, subcommand `steam-default-tool`), so Steam is not running while
//! its file is edited. Root never writes into a profile (RUY-35 plan audit). The first run records a
//! marker in the profile's Steam data; after that nothing is touched again, so a tool the player
//! picks later stays. Steam always starts: the step is `ExecStartPre=-`, it only reads and writes
//! two small files, and every failure is a message on stderr and a missing marker (tried again at
//! the next start).

use std::fs;
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};

use crate::vdf::{self, Entry, Value};

/// The Steam Flatpak (the only app this step belongs to).
pub const STEAM_APP_ID: &str = "com.valvesoftware.Steam";
/// The image's runners; each Proton one has its own `compatibilitytool.vdf` (GE-Proton's tarball).
pub const RUNNERS_DIR: &str = "/usr/lib/ruyaos/play/runners";
/// The subcommand of `ruya-session` that does this.
pub const SUBCOMMAND: &str = "steam-default-tool";
/// What Steam reads from a tool's folder.
pub const TOOL_FILE: &str = "compatibilitytool.vdf";

/// Steam's data in the Flatpak's per-user folder (`$HOME` is the profile's).
const STEAM_DATA: &str = ".var/app/com.valvesoftware.Steam/.local/share/Steam";
/// Written next to Steam's own data (outside what the sandbox sees) when the step is settled.
const MARKER: &str = ".var/app/com.valvesoftware.Steam/.ruyaos-default-tool";

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

/// Which runner folder is the newest: the biggest number at the end of its name
/// (`ProtonGE11` over `ProtonGE10`), then the name.
fn rank(folder: &str) -> (u64, &str) {
    let digits = folder.len() - folder.trim_end_matches(|c: char| c.is_ascii_digit()).len();
    let major = folder[folder.len() - digits..].parse().unwrap_or(0);
    (major, folder)
}

/// The tool to make the default: of the runners that carry a `compatibilitytool.vdf`, the newest.
pub fn default_tool(runners: &Path) -> Result<String, String> {
    let mut found: Vec<(String, String)> = Vec::new();
    let dir = fs::read_dir(runners).map_err(|e| format!("{}: {e}", runners.display()))?;
    for entry in dir.flatten() {
        let Ok(folder) = entry.file_name().into_string() else {
            continue;
        };
        let Ok(text) = fs::read_to_string(entry.path().join(TOOL_FILE)) else {
            continue;
        };
        if let Some(tool) = tool_name(&text) {
            found.push((folder, tool));
        }
    }
    found
        .into_iter()
        .max_by(|a, b| rank(&a.0).cmp(&rank(&b.0)))
        .map(|(_, tool)| tool)
        .ok_or_else(|| format!("no runner in {} has a {TOOL_FILE}", runners.display()))
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

/// Writes `text` to `path` through a temporary file next to it, so Steam never reads half a file.
fn replace_file(path: &Path, text: &str) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("no parent folder"))?;
    fs::create_dir_all(parent)?;
    let tmp = parent.join(".ruyaos-config.tmp");
    let mut file = fs::File::create(&tmp)?;
    file.write_all(text.as_bytes())?;
    file.sync_all()?;
    fs::rename(&tmp, path).inspect_err(|_| {
        let _ = fs::remove_file(&tmp);
    })
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
pub fn run(home: &Path, runners: &Path) -> Result<Done, String> {
    let marker: PathBuf = home.join(MARKER);
    if marker.exists() {
        return Ok(Done::AlreadySettled);
    }
    let tool = default_tool(runners)?;
    let config = home.join(STEAM_DATA).join("config/config.vdf");
    let current = match fs::read_to_string(&config) {
        Ok(text) => Some(text),
        Err(e) if e.kind() == io::ErrorKind::NotFound => None,
        Err(e) => return Err(format!("{}: {e}", config.display())),
    };
    let done = match with_default(current.as_deref(), &tool)
        .map_err(|e| format!("{} is left as it is: {e}", config.display()))?
    {
        Some(text) => {
            replace_file(&config, &text).map_err(|e| format!("{}: {e}", config.display()))?;
            Done::Set(tool)
        }
        None => Done::KeptExisting,
    };
    replace_file(&marker, "done\n").map_err(|e| format!("{}: {e}", marker.display()))?;
    Ok(done)
}

/// The subcommand: reports on stderr, exits 0 whatever happened (Steam starts regardless).
pub fn main_step() {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        eprintln!("ruya-session: {SUBCOMMAND}: HOME is not set");
        return;
    };
    match run(&home, Path::new(RUNNERS_DIR)) {
        Ok(Done::Set(tool)) => eprintln!("ruya-session: Steam's default tool is now {tool}"),
        Ok(done) => eprintln!("ruya-session: {SUBCOMMAND}: {done:?}"),
        Err(e) => eprintln!("ruya-session: {SUBCOMMAND}: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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

    #[test]
    fn the_newest_runner_wins() {
        assert!(rank("ProtonGE11") > rank("ProtonGE10"));
        assert!(rank("ProtonGE10") > rank("ProtonGE9"));
        assert!(rank("ProtonGE9") > rank("Wine"));
    }

    fn image(root: &Path, runners: &[(&str, &str)]) -> PathBuf {
        let dir = root.join("runners");
        for (folder, tool) in runners {
            fs::create_dir_all(dir.join(folder)).expect("folder");
            fs::write(dir.join(folder).join(TOOL_FILE), GE_VDF.replace(TOOL, tool)).expect("vdf");
        }
        dir
    }

    #[test]
    fn the_default_is_set_once_and_a_later_choice_stays() {
        let tmp = tempfile::tempdir().expect("tmp");
        let runners = image(
            tmp.path(),
            &[("ProtonGE10", "GE-Proton10-34"), ("ProtonGE11", TOOL)],
        );
        fs::create_dir_all(runners.join("WineStable")).expect("a runner with no vdf");
        let home = tmp.path().join("home");
        let config = home.join(STEAM_DATA).join("config/config.vdf");

        assert_eq!(run(&home, &runners), Ok(Done::Set(TOOL.to_owned())));
        let first = fs::read_to_string(&config).expect("written");
        assert_eq!(name_of(&mapping_of(&first)[0]), TOOL);
        assert!(home.join(MARKER).exists());

        // The player picks another tool in Steam; the next start leaves it.
        let chosen = first.replace(TOOL, "proton_9");
        fs::write(&config, &chosen).expect("player's choice");
        assert_eq!(run(&home, &runners), Ok(Done::AlreadySettled));
        assert_eq!(fs::read_to_string(&config).expect("read"), chosen);
    }

    #[test]
    fn an_existing_default_is_kept_and_settled() {
        let tmp = tempfile::tempdir().expect("tmp");
        let runners = image(tmp.path(), &[("ProtonGE11", TOOL)]);
        let home = tmp.path().join("home");
        let config = home.join(STEAM_DATA).join("config/config.vdf");
        fs::create_dir_all(config.parent().expect("parent")).expect("dirs");
        let theirs = with_default(None, "proton_9").expect("ok").expect("text");
        fs::write(&config, &theirs).expect("config");
        assert_eq!(run(&home, &runners), Ok(Done::KeptExisting));
        assert_eq!(fs::read_to_string(&config).expect("read"), theirs);
        assert!(home.join(MARKER).exists());
    }

    #[test]
    fn a_malformed_config_is_left_as_it_is_and_tried_again_later() {
        let tmp = tempfile::tempdir().expect("tmp");
        let runners = image(tmp.path(), &[("ProtonGE11", TOOL)]);
        let home = tmp.path().join("home");
        let config = home.join(STEAM_DATA).join("config/config.vdf");
        fs::create_dir_all(config.parent().expect("parent")).expect("dirs");
        fs::write(&config, "\"InstallConfigStore\" {").expect("config");
        let err = run(&home, &runners).expect_err("refused");
        assert!(err.contains("is left as it is"), "{err}");
        assert_eq!(
            fs::read_to_string(&config).expect("read"),
            "\"InstallConfigStore\" {"
        );
        assert!(!home.join(MARKER).exists());
    }

    #[test]
    fn no_runner_with_a_tool_file_is_an_error_and_writes_nothing() {
        let tmp = tempfile::tempdir().expect("tmp");
        let runners = tmp.path().join("runners");
        fs::create_dir_all(runners.join("WineStable")).expect("runner");
        let home = tmp.path().join("home");
        assert!(run(&home, &runners).is_err());
        assert!(run(&home, &tmp.path().join("missing")).is_err());
        assert!(!home.exists());
    }

    #[test]
    fn the_unit_property_is_one_plain_command() {
        assert_eq!(
            exec_start_pre("/usr/bin/ruya-session"),
            "--property=ExecStartPre=-/usr/bin/ruya-session steam-default-tool"
        );
    }
}
