//! Which Steam game a scope of Steam's run belongs to (ADR-041 point 2, RUY-1052).
//!
//! A Steam game runs in a portal subsandbox scope of its own (`app-flatpak-<Steam>-<n>.scope`),
//! beside the scope the run attached (Steam's sandbox) and the scopes of Steam's own helpers. The
//! service asks this helper once per new scope of a `children = steam` run (`apps.rs`), never for
//! the attached scope: `ruya-session steam-probe <scope>`, run as the profile user in the profile's
//! manager (`spawner::steam_probe_command`), the `x11-run` / `steam-default-tool` pattern. Root
//! reads no environ of a profile's processes; the profile user can read its own.
//!
//! The rule (`game_of`) looks at one process only, the sandbox's **top process**: the oldest
//! process in the scope (start time in `/proc/<pid>/stat`, then pid) whose environ carries
//! `FLATPAK_ID`, which `flatpak` sets inside every sandbox (pressure-vessel's `pv-adverb` in a
//! game's scope). The scope belongs to child G when that environ has **both** `SteamAppId` and
//! `SteamGameId`, each a Steam app id (digits, at most 10, not 0, `steam_game_id`), and
//! G = `SteamGameId`. Anything else, and every scope where it cannot be told, is the parent's:
//!
//! - Steam's attached scope carries the id in the reaper and `_v2-entry-point` while a game runs,
//!   but its top process is Steam's own `steam.sh` (spike RUY-1047): "any process carries the id"
//!   would make Steam a game;
//! - the client scope's top process is its own `pv-adverb`, without the ids;
//! - UpdatingDRM's short scope has `SteamGameId` without `SteamAppId`, an install script only
//!   `STEAM_COMPAT_APP_ID`;
//! - a non-Steam shortcut has `SteamAppId=0` and a 64-bit `SteamGameId`;
//! - the `bwrap` wrappers outside the sandbox show an empty environ, and the `xdg-dbus-proxy` of a
//!   scope, with its own `bwrap`, starts before the sandbox with the manager's environment and no
//!   `FLATPAK_ID` (Dell 0.0.102, 2026-11-22: the oldest process with a non-empty environ in Half-Life's
//!   scope was that proxy's `bwrap`, not `pv-adverb`).
//!
//! The helper prints G and a newline, or nothing. The service checks the answer again with
//! `steam_game_id` (`parse_answer`).

use std::io::Read;

use ruya_ids::valid_steam_appid;

use crate::spawner::user_manager_uid;

/// The subcommand of `ruya-session` that runs this.
pub const SUBCOMMAND: &str = "steam-probe";
/// The variable every Flatpak sandbox has: what tells a process inside the sandbox from the
/// wrappers and the D-Bus proxy beside it.
pub const SANDBOX_KEY: &str = "FLATPAK_ID";
/// The most pids read from one scope (a Proton game has a few dozen).
pub const MAX_PROCS: usize = 4096;
/// The most bytes read of one environ (a game's has a few kilobytes).
pub const MAX_ENVIRON: u64 = 256 * 1024;
/// The most bytes read of `cgroup.procs` or a `stat` file.
const MAX_SMALL_FILE: u64 = 64 * 1024;

/// One process of the scope as the helper read it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proc {
    pub pid: u32,
    /// Field 22 of `/proc/<pid>/stat`: clock ticks since boot.
    pub start: u64,
    /// `/proc/<pid>/environ` (NUL-separated `KEY=value`); empty when it could not be read.
    pub environ: Vec<u8>,
}

/// A Steam app id as the rule takes it: `ruya_ids::valid_steam_appid` (digits, 1 to 10) and not 0,
/// the `SteamAppId` of a non-Steam shortcut.
pub fn steam_game_id(value: &str) -> Option<&str> {
    (valid_steam_appid(value) && value.bytes().any(|b| b != b'0')).then_some(value)
}

/// The value of `key` in an environ, `None` when it is not there or is not UTF-8.
pub fn env_value<'a>(environ: &'a [u8], key: &str) -> Option<&'a str> {
    environ.split(|b| *b == 0).find_map(|entry| {
        let rest = entry.strip_prefix(key.as_bytes())?.strip_prefix(b"=")?;
        std::str::from_utf8(rest).ok()
    })
}

/// The game a scope belongs to, by the rule in the module text: `Some(G)` for child G, `None` for
/// the parent.
pub fn game_of(procs: &[Proc]) -> Option<String> {
    let top = procs
        .iter()
        .filter(|p| env_value(&p.environ, SANDBOX_KEY).is_some_and(|v| !v.is_empty()))
        .min_by_key(|p| (p.start, p.pid))?;
    let app = env_value(&top.environ, "SteamAppId").and_then(steam_game_id);
    let game = env_value(&top.environ, "SteamGameId").and_then(steam_game_id);
    app.and(game).map(str::to_owned)
}

/// The start time out of a `/proc/<pid>/stat` line: field 22, counted after the command name in
/// parentheses (which may hold spaces and parentheses itself, so the last `)` ends it).
pub fn start_time(stat: &str) -> Option<u64> {
    let after = &stat[stat.rfind(')')? + 1..];
    // Fields 3.. follow the name: field 22 is the 20th of them.
    after.split_whitespace().nth(19)?.parse().ok()
}

/// The user manager's `app.slice` out of the helper's own `/proc/self/cgroup` (it runs in a
/// transient unit there): `/user.slice/user-1000.slice/user@1000.service/app.slice`.
pub fn app_slice(own_cgroup: &str) -> Option<String> {
    let path = own_cgroup
        .lines()
        .find_map(|l| l.strip_prefix("0::"))?
        .trim();
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    let at = parts.iter().position(|p| user_manager_uid(p).is_some())?;
    Some(format!("/{}/app.slice", parts[..=at].join("/")))
}

/// A scope name the helper accepts: `app-flatpak-...-<n>.scope`, one path component of printable
/// ASCII (systemd writes a `-` of an app id as `\x2d`).
pub fn valid_scope(scope: &str) -> bool {
    scope.starts_with("app-flatpak-")
        && scope.ends_with(".scope")
        && scope.len() <= 255
        && scope.bytes().all(|b| b.is_ascii_graphic() && b != b'/')
}

/// The service's check of the helper's answer: G, or `None` for an empty or bad answer.
pub fn parse_answer(out: &str) -> Option<String> {
    steam_game_id(out.trim()).map(str::to_owned)
}

fn read_capped(path: &str, cap: u64) -> Option<Vec<u8>> {
    let file = std::fs::File::open(path).ok()?;
    let mut bytes = Vec::new();
    file.take(cap).read_to_end(&mut bytes).ok()?;
    Some(bytes)
}

/// The helper's main: reads the scope's processes and prints G or nothing. Exit code 2 for a bad
/// call, 1 when the scope cannot be read (the service then leaves the scope to the parent), 0
/// otherwise.
pub fn main_step(args: &[String]) -> i32 {
    let [scope] = args else {
        eprintln!("ruya-session {SUBCOMMAND}: usage: {SUBCOMMAND} <scope>");
        return 2;
    };
    if !valid_scope(scope) {
        eprintln!("ruya-session {SUBCOMMAND}: not a Flatpak scope: {scope:?}");
        return 2;
    }
    let slice = read_capped("/proc/self/cgroup", MAX_SMALL_FILE)
        .and_then(|b| String::from_utf8(b).ok())
        .and_then(|text| app_slice(&text));
    let Some(slice) = slice else {
        eprintln!("ruya-session {SUBCOMMAND}: not running in a user manager");
        return 1;
    };
    let path = format!("/sys/fs/cgroup{slice}/{scope}/cgroup.procs");
    let Some(listing) = read_capped(&path, MAX_SMALL_FILE).and_then(|b| String::from_utf8(b).ok())
    else {
        eprintln!("ruya-session {SUBCOMMAND}: cannot read {path}");
        return 1;
    };
    let procs: Vec<Proc> = listing
        .lines()
        .filter_map(|l| l.trim().parse::<u32>().ok())
        .take(MAX_PROCS)
        .filter_map(|pid| {
            let stat = read_capped(&format!("/proc/{pid}/stat"), MAX_SMALL_FILE)?;
            let start = start_time(&String::from_utf8_lossy(&stat))?;
            let environ =
                read_capped(&format!("/proc/{pid}/environ"), MAX_ENVIRON).unwrap_or_default();
            Some(Proc {
                pid,
                start,
                environ,
            })
        })
        .collect();
    if let Some(game) = game_of(&procs) {
        println!("{game}");
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> Vec<u8> {
        let mut out = Vec::new();
        for (k, v) in pairs {
            out.extend_from_slice(format!("{k}={v}").as_bytes());
            out.push(0);
        }
        out
    }

    fn p(pid: u32, start: u64, pairs: &[(&str, &str)]) -> Proc {
        Proc {
            pid,
            start,
            environ: env(pairs),
        }
    }

    const IN: (&str, &str) = ("FLATPAK_ID", "com.valvesoftware.Steam");
    /// The `xdg-dbus-proxy` and its `bwrap`: the manager's environment, no `FLATPAK_ID`.
    const PROXY: [(&str, &str); 2] = [("HOME", "/var/home/ruya-p1"), ("PULSE_SERVER", "x")];

    /// The wrappers and the proxy every scope starts with (Dell 0.0.102): an empty `bwrap`, the
    /// proxy's `bwrap` and the proxy (non-empty, older than the sandbox), a second empty `bwrap`.
    fn wrappers(first: u32, start: u64) -> Vec<Proc> {
        vec![
            p(first, start, &[]),
            p(first + 1, start + 7, &PROXY),
            p(first + 2, start + 7, &PROXY),
            p(first + 3, start + 9, &[]),
        ]
    }

    fn scope_of(mut head: Vec<Proc>, tail: Vec<Proc>) -> Vec<Proc> {
        head.extend(tail);
        head
    }

    #[test]
    fn a_games_scope_is_its_game() {
        // Half-Life on the Dell: pv-adverb is the sandbox's top process, with all four ids.
        let ids = [
            IN,
            ("SteamAppId", "70"),
            ("SteamGameId", "70"),
            ("STEAM_COMPAT_APP_ID", "70"),
            ("SteamOverlayGameId", "70"),
        ];
        let scope = scope_of(
            wrappers(114190, 5812117),
            vec![p(114201, 5812130, &ids), p(114224, 5812164, &ids)],
        );
        assert_eq!(game_of(&scope).as_deref(), Some("70"));
        // G is SteamGameId.
        let scope = vec![p(
            1,
            1,
            &[IN, ("SteamAppId", "7670"), ("SteamGameId", "7671")],
        )];
        assert_eq!(game_of(&scope).as_deref(), Some("7671"));
    }

    #[test]
    fn steams_attached_scope_is_the_parent_although_the_reaper_carries_the_id() {
        // steam.sh is the top process; the reaper and _v2-entry-point came later with the id.
        let ids = [IN, ("SteamAppId", "70"), ("SteamGameId", "70")];
        let scope = scope_of(
            wrappers(113161, 5807916),
            vec![
                p(113171, 5807927, &[IN, ("STEAMSCRIPT", "steam.sh")]),
                p(113211, 5807979, &[IN]),
                p(114145, 5811966, &ids),
                p(114146, 5811974, &ids),
            ],
        );
        assert_eq!(game_of(&scope), None);
    }

    #[test]
    fn the_client_scope_with_the_launch_client_is_the_parent() {
        // pv-adverb of the client and its steamwebhelper first; the launch client
        // (`steam-runtime-launch-client --alongside-steam`) carries the id, but later.
        let scope = scope_of(
            wrappers(113300, 5808400),
            vec![
                p(
                    113311,
                    5808409,
                    &[IN, ("SRT_LAUNCHER_SERVICE_ALONGSIDE_STEAM", "1")],
                ),
                p(113373, 5808461, &[IN]),
                p(
                    114300,
                    5812100,
                    &[IN, ("SteamAppId", "70"), ("SteamGameId", "70")],
                ),
            ],
        );
        assert_eq!(game_of(&scope), None);
    }

    #[test]
    fn pre_launch_scopes_are_the_parents() {
        // UpdatingDRM: SteamGameId without SteamAppId.
        let drm = vec![p(5, 50, &[IN, ("SteamGameId", "21670")])];
        assert_eq!(game_of(&drm), None);
        // An install script: STEAM_COMPAT_APP_ID only.
        let install = vec![p(6, 60, &[IN, ("STEAM_COMPAT_APP_ID", "7670")])];
        assert_eq!(game_of(&install), None);
    }

    #[test]
    fn a_scope_of_empty_or_outside_environs_is_the_parents() {
        // Only the wrappers: the bwrap environs are empty, the proxy's carries no FLATPAK_ID.
        assert_eq!(game_of(&wrappers(1, 10)), None);
        // Even when such a process carries the ids, it is not inside the sandbox.
        let outside = vec![p(1, 1, &[("SteamAppId", "70"), ("SteamGameId", "70")])];
        assert_eq!(game_of(&outside), None);
        assert_eq!(game_of(&[]), None);
    }

    #[test]
    fn a_non_steam_shortcut_and_bad_values_are_the_parents() {
        for (app, game) in [
            ("0", "12345678901234567890"),
            ("0", "70"),
            ("70", "0"),
            ("70", "12345678901"),
            ("7a", "70"),
            ("70", ""),
            ("70", " 70"),
            ("-1", "70"),
        ] {
            let scope = vec![p(1, 1, &[IN, ("SteamAppId", app), ("SteamGameId", game)])];
            assert_eq!(game_of(&scope), None, "{app:?} {game:?}");
        }
    }

    #[test]
    fn the_top_process_is_the_oldest_then_the_lowest_pid() {
        let game = [IN, ("SteamAppId", "70"), ("SteamGameId", "70")];
        let steam = [IN];
        assert_eq!(
            game_of(&[p(9, 5, &game), p(3, 7, &steam)]).as_deref(),
            Some("70")
        );
        assert_eq!(game_of(&[p(9, 5, &game), p(3, 5, &steam)]), None);
    }

    #[test]
    fn environ_values_are_read_by_exact_key() {
        let e = env(&[("SteamAppIdX", "1"), ("SteamAppId", "70"), ("A", "b=c")]);
        assert_eq!(env_value(&e, "SteamAppId"), Some("70"));
        assert_eq!(env_value(&e, "A"), Some("b=c"));
        assert_eq!(env_value(&e, "Steam"), None);
        assert_eq!(env_value(b"", "A"), None);
    }

    #[test]
    fn a_stat_line_gives_its_start_time_whatever_the_name() {
        let fields = "S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 5812130 20 21";
        assert_eq!(
            start_time(&format!("114201 (pv-adverb) {fields}")),
            Some(5812130)
        );
        assert_eq!(start_time(&format!("7 (a) b (c)) {fields}")), Some(5812130));
        assert_eq!(start_time("7 (short) S 1 2"), None);
        assert_eq!(start_time("no parens"), None);
    }

    #[test]
    fn the_app_slice_comes_from_the_helpers_own_cgroup() {
        let own = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-p111160-i104118.service\n";
        assert_eq!(
            app_slice(own).as_deref(),
            Some("/user.slice/user-1000.slice/user@1000.service/app.slice")
        );
        assert_eq!(app_slice("0::/system.slice/ruya-session.service\n"), None);
        assert_eq!(app_slice(""), None);
    }

    #[test]
    fn only_a_flatpak_scope_name_is_probed() {
        assert!(valid_scope(
            "app-flatpak-com.valvesoftware.Steam-1623993748.scope"
        ));
        assert!(valid_scope("app-flatpak-org.x\\x2dy.App-7.scope"));
        for bad in [
            "",
            "app-flatpak-a/../../x.scope",
            "app-flatpak-a b-1.scope",
            "ruya-app-ruya-p1-x.service",
            "app-flatpak-x-1.service",
        ] {
            assert!(!valid_scope(bad), "{bad:?}");
        }
    }

    #[test]
    fn the_service_takes_only_an_app_id_from_the_helper() {
        assert_eq!(parse_answer("70\n").as_deref(), Some("70"));
        for bad in ["", "\n", "0", "12345678901", "70 71", "x", "-70"] {
            assert_eq!(parse_answer(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn a_bad_call_is_refused() {
        assert_eq!(main_step(&[]), 2);
        assert_eq!(main_step(&["a".to_owned(), "b".to_owned()]), 2);
        assert_eq!(main_step(&["../etc".to_owned()]), 2);
    }
}
