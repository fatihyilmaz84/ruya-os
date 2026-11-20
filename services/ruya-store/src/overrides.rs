//! An installed app's Flatpak permissions and the console's override on top of them (RUY-744,
//! 03 §4.4). Flatpak keeps both in the same keyfile form: the app's `metadata` and the override in
//! `/var/lib/flatpak/overrides/<id>` (`flatpak override --show`). This module reads that form into
//! a [`Context`], merges an override onto an app the way Flatpak does, names the permission keys
//! of the contract (`network`, `home-files`, ...; `appstream::permissions` is this module's
//! reading of a metadata file) and decides what the console may withdraw, as fixed argument lists
//! for `flatpak override --system`. An override built from these lists only withdraws: it never
//! grants what the app does not ask for. Pure; the command itself runs in `flatpak_cli.rs`.

use std::collections::BTreeMap;

/// The permission keys of the contract (Store1.xml, App record `permissions`), in its
/// plain-language order.
pub const KEYS: [&str; 7] = [
    "network",
    "home-files",
    "host-files",
    "all-devices",
    "audio",
    "gamepad",
    "session-bus",
];

/// The `[Context]` and `[Session Bus Policy]` groups of a metadata or override keyfile. Each list
/// entry is granted (`x`) or negated (`!x`); a later entry of the same name wins, as in Flatpak.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Context {
    shared: BTreeMap<String, bool>,
    sockets: BTreeMap<String, bool>,
    devices: BTreeMap<String, bool>,
    /// Filesystem entries by path, the `:ro`/`:rw`/`:create` mode cut off.
    filesystems: BTreeMap<String, bool>,
    /// `[Session Bus Policy]`: bus name -> `talk` | `own` | `see` | `none`.
    session_bus: BTreeMap<String, String>,
}

impl Context {
    /// Reads a keyfile. Lines it does not know (other groups and keys, comments, garbage) are
    /// skipped.
    pub fn parse(keyfile: &str) -> Context {
        let mut context = Context::default();
        let mut group = "";
        for line in keyfile.lines() {
            let line = line.trim();
            if let Some(name) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
                group = name;
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let list = match (group, key.trim()) {
                ("Context", "shared") => &mut context.shared,
                ("Context", "sockets") => &mut context.sockets,
                ("Context", "devices") => &mut context.devices,
                ("Context", "filesystems") => &mut context.filesystems,
                ("Session Bus Policy", name) => {
                    context
                        .session_bus
                        .insert(name.to_owned(), value.trim().to_owned());
                    continue;
                }
                _ => continue,
            };
            for item in value.split(';').map(str::trim).filter(|i| !i.is_empty()) {
                let (granted, name) = match item.strip_prefix('!') {
                    Some(name) => (false, name),
                    None => (true, item),
                };
                let name = if key.trim() == "filesystems" {
                    filesystem_path(name)
                } else {
                    name
                };
                list.insert(name.to_owned(), granted);
            }
        }
        context
    }

    /// The app with `over` on top: every entry the override names replaces the app's (Flatpak's
    /// merge of an override onto the metadata).
    pub fn merged(&self, over: &Context) -> Context {
        let mut out = self.clone();
        out.shared.extend(over.shared.clone());
        out.sockets.extend(over.sockets.clone());
        out.devices.extend(over.devices.clone());
        out.filesystems.extend(over.filesystems.clone());
        out.session_bus.extend(over.session_bus.clone());
        out
    }

    /// The permission keys this context grants, in contract order. Negated entries grant nothing.
    pub fn keys(&self) -> Vec<String> {
        let on = |list: &BTreeMap<String, bool>, name: &str| list.get(name) == Some(&true);
        let files = |key: &str| self.granted_paths(key).next().is_some();
        let flatpak_bus = matches!(
            self.session_bus
                .get("org.freedesktop.Flatpak")
                .map(String::as_str),
            Some("talk" | "own")
        );
        let granted = [
            on(&self.shared, "network"),
            files("home-files"),
            files("host-files"),
            on(&self.devices, "all"),
            on(&self.sockets, "pulseaudio"),
            on(&self.devices, "input"),
            on(&self.sockets, "session-bus") || flatpak_bus,
        ];
        KEYS.iter()
            .zip(granted)
            .filter(|(_, on)| *on)
            .map(|(key, _)| (*key).to_owned())
            .collect()
    }

    /// The granted filesystem paths that make up `key` ("home-files" or "host-files").
    fn granted_paths<'a>(&'a self, key: &'a str) -> impl Iterator<Item = &'a str> + 'a {
        self.filesystems
            .iter()
            .filter(move |(path, granted)| **granted && filesystem_key(path) == Some(key))
            .map(|(path, _)| path.as_str())
    }
}

/// `xdg-download:ro` -> `xdg-download`.
fn filesystem_path(entry: &str) -> &str {
    entry.split(':').next().unwrap_or(entry)
}

/// Which key a filesystem path belongs to: the whole system (`host`, `host-os`, `host-etc`, an
/// absolute path) is `host-files`; the home folder and what lies in it (`home`, `~/...`, every
/// `xdg-...` entry) is `home-files`, `xdg-run/...` included (the runtime folder, counted with the
/// home files); anything else none.
fn filesystem_key(path: &str) -> Option<&'static str> {
    if matches!(path, "host" | "host-os" | "host-etc") || path.starts_with('/') {
        Some("host-files")
    } else if path == "home" || path.starts_with('~') || path.starts_with("xdg-") {
        Some("home-files")
    } else {
        None
    }
}

/// The parts of all devices an app keeps when all devices are withdrawn: its controllers and its
/// GPU.
const KEPT_DEVICES: [&str; 2] = ["input", "dri"];

/// Why a key cannot be withdrawn or restored.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// Not a key of the contract, or one the app does not ask for (`invalid`).
    Invalid,
    /// A key the console leaves alone (`not-withdrawable`).
    NotWithdrawable,
}

/// What an app has and what the console's override took away.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Permissions {
    /// What the app gets now: its metadata with the override on top, in contract order. An
    /// override written outside the Store can add keys; they are here as they are.
    pub effective: Vec<String>,
    /// Keys of the app's metadata the override takes away, in contract order.
    pub withdrawn: Vec<String>,
    /// Keys of the app's metadata the console can withdraw here (whether withdrawn now or not).
    pub withdrawable: Vec<String>,
}

/// The permissions of an app whose installed metadata reads as `app`, with the override `over`
/// on top (an empty context without one). `device_input`: this console's Flatpak has
/// `--device=input` (see [`device_input_supported`]).
pub fn permissions(app: &Context, over: &Context, device_input: bool) -> Permissions {
    let asked = app.keys();
    let effective = app.merged(over).keys();
    Permissions {
        withdrawn: asked
            .iter()
            .filter(|k| !effective.contains(k))
            .cloned()
            .collect(),
        withdrawable: asked
            .iter()
            .filter(|k| withdraw_args(app, k, device_input).is_ok())
            .cloned()
            .collect(),
        effective,
    }
}

/// Whether the console withdraws `key` at all, for an app that asks for it. Audio carries output
/// and microphone in one socket (no switch that would take both, RUY-80); without the session bus
/// apps break unpredictably; a console's controllers are never taken away; all devices only where
/// Flatpak can keep the controllers (`--device=input`).
fn withdrawable(key: &str, device_input: bool) -> Result<(), Refusal> {
    match key {
        "network" | "home-files" | "host-files" => Ok(()),
        "all-devices" if device_input => Ok(()),
        "all-devices" | "audio" | "session-bus" | "gamepad" => Err(Refusal::NotWithdrawable),
        _ => Err(Refusal::Invalid),
    }
}

/// The arguments of `flatpak override --system <args> <id>` that withdraw `key` from an app whose
/// permissions are `current` (its metadata, with any override on top), or why it cannot be.
/// Only negations, except `--device=input` and `--device=dri` with `--nodevice=all`: both are a
/// part of all devices, so the app keeps its controllers and its GPU (a game without it is broken)
/// and gains nothing. Each is written only when `current` names it nowhere: an app that asks for
/// it on its own keeps it without the override, and one an override negated stays negated. A file
/// key takes every path that makes it up (`home` and `xdg-download` are both home files), so the
/// key is really gone afterwards.
pub fn withdraw_args(
    current: &Context,
    key: &str,
    device_input: bool,
) -> Result<Vec<String>, Refusal> {
    withdrawable(key, device_input)?;
    let args = match key {
        "network" => vec!["--unshare=network".to_owned()],
        "all-devices" => std::iter::once("--nodevice=all".to_owned())
            .chain(
                KEPT_DEVICES
                    .iter()
                    .filter(|d| !current.devices.contains_key(**d))
                    .map(|d| format!("--device={d}")),
            )
            .collect(),
        _ => current
            .granted_paths(key)
            .map(|path| format!("--nofilesystem={path}"))
            .collect(),
    };
    Ok(args)
}

/// The arguments that withdraw `keys` again from an app with no override (`metadata` only): what
/// a restore writes after it reset the override. Keys the console does not withdraw are skipped.
pub fn rewithdraw_args(metadata: &Context, keys: &[String], device_input: bool) -> Vec<String> {
    keys.iter()
        .filter_map(|k| withdraw_args(metadata, k, device_input).ok())
        .flatten()
        .collect()
}

/// `flatpak override` without `--reset` or `--show`: the arguments around the withdraw arguments.
pub fn override_command(id: &str, args: &[String]) -> Vec<String> {
    let mut out = vec!["override".to_owned(), "--system".to_owned()];
    out.extend(args.iter().cloned());
    out.push(id.to_owned());
    out
}

/// `flatpak override --system --reset <id>`: removes the app's override, whoever wrote it. Every
/// uninstall runs it (`Store::drop_override`), and so can another service that removes a Flatpak.
pub fn reset_command(id: &str) -> Vec<String> {
    ["override", "--system", "--reset", id]
        .map(str::to_owned)
        .to_vec()
}

/// `flatpak override --system --show <id>`: the override keyfile, empty without one.
pub fn show_command(id: &str) -> Vec<String> {
    ["override", "--system", "--show", id]
        .map(str::to_owned)
        .to_vec()
}

/// Whether the Flatpak that printed `version` (`flatpak --version`: "Flatpak 1.18.4") has
/// `--device=input`, which came with 1.15.6. Unreadable text counts as no.
pub fn device_input_supported(version: &str) -> bool {
    let Some(number) = version
        .split_whitespace()
        .find(|w| w.starts_with(|c: char| c.is_ascii_digit()))
    else {
        return false;
    };
    let mut parts = number.split('.').map(|p| p.parse::<u32>().ok());
    let (Some(Some(major)), Some(Some(minor)), patch) = (parts.next(), parts.next(), parts.next())
    else {
        return false;
    };
    let patch = patch.flatten().unwrap_or(0);
    (major, minor, patch) >= (1, 15, 6)
}

#[cfg(test)]
mod tests {
    use super::*;

    const RACER: &str = "[Application]\nname=org.example.Racer\n\n[Context]\nshared=network;ipc;\nsockets=wayland;pulseaudio;\ndevices=all;\nfilesystems=home;xdg-download:ro;/media;\n";

    fn keys(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_owned()).collect()
    }

    fn args(list: &[&str]) -> Vec<String> {
        keys(list)
    }

    /// `permissions` of a metadata and an override text.
    fn perms(metadata: &str, over: &str, device_input: bool) -> Permissions {
        permissions(
            &Context::parse(metadata),
            &Context::parse(over),
            device_input,
        )
    }

    #[test]
    fn without_an_override_the_effective_set_is_the_apps() {
        let p = perms(RACER, "", true);
        assert_eq!(
            p.effective,
            keys(&[
                "network",
                "home-files",
                "host-files",
                "all-devices",
                "audio"
            ])
        );
        assert!(p.withdrawn.is_empty());
        assert_eq!(
            p.withdrawable,
            keys(&["network", "home-files", "host-files", "all-devices"])
        );
    }

    #[test]
    fn an_override_takes_its_keys_away_and_reports_them() {
        // What `flatpak override --system --unshare=network --nodevice=all --device=input` writes.
        let over = "[Context]\nshared=!network;\ndevices=!all;input;\n";
        let p = perms(RACER, over, true);
        // Controllers stay: input is a part of all devices, so `gamepad` shows up as effective.
        assert_eq!(
            p.effective,
            keys(&["home-files", "host-files", "audio", "gamepad"])
        );
        assert_eq!(p.withdrawn, keys(&["network", "all-devices"]));
    }

    #[test]
    fn each_withdrawable_key_has_its_exact_arguments() {
        let app = Context::parse(RACER);
        assert_eq!(
            withdraw_args(&app, "network", true),
            Ok(args(&["--unshare=network"]))
        );
        assert_eq!(
            withdraw_args(&app, "all-devices", true),
            Ok(args(&["--nodevice=all", "--device=input", "--device=dri"]))
        );
        assert_eq!(
            withdraw_args(&app, "host-files", true),
            Ok(args(&["--nofilesystem=/media"]))
        );
        // Every path that makes the key, the mode cut off.
        assert_eq!(
            withdraw_args(&app, "home-files", true),
            Ok(args(&[
                "--nofilesystem=home",
                "--nofilesystem=xdg-download"
            ]))
        );
        let host = Context::parse("[Context]\nfilesystems=host;\n");
        assert_eq!(
            withdraw_args(&host, "host-files", true),
            Ok(args(&["--nofilesystem=host"]))
        );
        assert_eq!(
            override_command("org.example.Racer", &args(&["--unshare=network"])),
            args(&[
                "override",
                "--system",
                "--unshare=network",
                "org.example.Racer"
            ])
        );
        assert_eq!(
            reset_command("org.example.Racer"),
            args(&["override", "--system", "--reset", "org.example.Racer"])
        );
        assert_eq!(
            show_command("org.example.Racer"),
            args(&["override", "--system", "--show", "org.example.Racer"])
        );
    }

    #[test]
    fn a_withdrawn_file_key_is_really_gone() {
        // Withdrawing `home` alone would leave `xdg-download`, and with it the key.
        let over = "[Context]\nfilesystems=!home;!xdg-download;\n";
        let p = perms(RACER, over, true);
        assert!(!p.effective.contains(&"home-files".to_owned()));
        assert_eq!(p.withdrawn, keys(&["home-files"]));
        let half = perms(RACER, "[Context]\nfilesystems=!home;\n", true);
        assert!(half.effective.contains(&"home-files".to_owned()));
        assert!(half.withdrawn.is_empty());
    }

    #[test]
    fn input_comes_with_withdrawing_all_devices_only() {
        let app = Context::parse(RACER);
        for key in ["network", "home-files", "host-files"] {
            let list = withdraw_args(&app, key, true).unwrap();
            assert!(!list.iter().any(|a| a.contains("input")), "{key}: {list:?}");
            assert!(
                list.iter()
                    .all(|a| a.starts_with("--no") || a.starts_with("--unshare")),
                "{key} only negates: {list:?}"
            );
        }
        assert!(withdraw_args(&app, "all-devices", true)
            .unwrap()
            .contains(&"--device=input".to_owned()));
    }

    #[test]
    fn withdrawing_all_devices_keeps_only_the_input_and_gpu_that_came_with_them() {
        // Asked for on their own, input and dri stay without the override writing them.
        let own = Context::parse("[Context]\ndevices=all;input;dri;\n");
        assert_eq!(
            withdraw_args(&own, "all-devices", true),
            Ok(args(&["--nodevice=all"]))
        );
        // An override that negated the GPU keeps it negated: the withdrawal never grants it back.
        let app = Context::parse(RACER);
        let now = app.merged(&Context::parse("[Context]\ndevices=!dri;\n"));
        assert_eq!(
            withdraw_args(&now, "all-devices", true),
            Ok(args(&["--nodevice=all", "--device=input"]))
        );
        // What the override then grants is no key beyond the controllers.
        let over = "[Context]\ndevices=!all;input;dri;\n";
        assert_eq!(
            perms(RACER, over, true).effective,
            keys(&["network", "home-files", "host-files", "audio", "gamepad"])
        );
    }

    #[test]
    fn audio_session_bus_and_gamepad_are_not_withdrawable() {
        let all = "[Context]\nsockets=pulseaudio;session-bus;\ndevices=input;all;\n";
        let app = Context::parse(all);
        for key in ["audio", "session-bus", "gamepad"] {
            assert_eq!(
                withdraw_args(&app, key, true),
                Err(Refusal::NotWithdrawable),
                "{key}"
            );
        }
        let p = perms(all, "", true);
        assert_eq!(p.withdrawable, keys(&["all-devices"]));
    }

    #[test]
    fn all_devices_needs_device_input() {
        let app = Context::parse(RACER);
        assert_eq!(
            withdraw_args(&app, "all-devices", false),
            Err(Refusal::NotWithdrawable)
        );
        assert!(!perms(RACER, "", false)
            .withdrawable
            .contains(&"all-devices".to_owned()));
        assert!(device_input_supported("Flatpak 1.18.4\n"));
        assert!(device_input_supported("Flatpak 1.15.6"));
        assert!(device_input_supported("Flatpak 2.0"));
        assert!(!device_input_supported("Flatpak 1.15.5"));
        assert!(!device_input_supported("Flatpak 1.14.10"));
        assert!(!device_input_supported(""));
        assert!(!device_input_supported("flatpak: command not found"));
    }

    #[test]
    fn unknown_keys_are_invalid() {
        let app = Context::parse(RACER);
        assert_eq!(withdraw_args(&app, "camera", true), Err(Refusal::Invalid));
        assert_eq!(withdraw_args(&app, "", true), Err(Refusal::Invalid));
    }

    #[test]
    fn a_foreign_override_is_reported_as_it_is() {
        // Written by hand: sound taken, the network given to an app that does not ask for it.
        let app = "[Context]\nsockets=pulseaudio;\n";
        let over = "[Context]\nshared=network;\nsockets=!pulseaudio;\n";
        let p = perms(app, over, true);
        assert_eq!(p.effective, keys(&["network"]));
        assert_eq!(p.withdrawn, keys(&["audio"]));
        assert!(
            p.withdrawable.is_empty(),
            "nothing of the app's own can be withdrawn here"
        );
    }

    #[test]
    fn the_session_bus_policy_is_merged_too() {
        let app = "[Session Bus Policy]\norg.freedesktop.Flatpak=talk\n";
        assert_eq!(perms(app, "", true).effective, keys(&["session-bus"]));
        let p = perms(
            app,
            "[Session Bus Policy]\norg.freedesktop.Flatpak=none\n",
            true,
        );
        assert!(p.effective.is_empty());
        assert_eq!(p.withdrawn, keys(&["session-bus"]));
    }

    #[test]
    fn a_restore_withdraws_the_other_keys_again() {
        let app = Context::parse(RACER);
        let rest = rewithdraw_args(&app, &keys(&["network", "audio", "all-devices"]), true);
        // audio is skipped: the console does not withdraw it.
        assert_eq!(
            rest,
            args(&[
                "--unshare=network",
                "--nodevice=all",
                "--device=input",
                "--device=dri"
            ])
        );
        assert!(rewithdraw_args(&app, &[], true).is_empty());
    }
}
