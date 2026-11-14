//! Starting and stopping app units. The trait is the only door to the OS; the fake serves tests
//! and `--session`, `systemd::SystemdSpawner` (Linux) is the real one. The pure parts of the real
//! one live here and are tested on every host: the `systemd-run` argument list
//! (`launch_command`), the reading of its output (`parse_run_line`) and the unit events made from
//! it (`RunFollower`).

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::Read;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_channel::Sender;

/// What the OS tells us about a unit. The adapter drains these from a channel into the core.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnitEvent {
    /// The unit is active: the app runs.
    Started { unit: String },
    /// The unit ended. `code` is the exit status; `signaled` means a signal ended it (then `code`
    /// is the signal number).
    Exited {
        unit: String,
        code: i32,
        signaled: bool,
    },
    /// The program of the unit could not be executed (exit status 203/EXEC): the app never ran.
    ExecFailed { unit: String },
}

/// An app unit that was already running when the service started (see `Spawner::adopt_running`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunningUnit {
    pub unit: String,
    /// The Unix user whose manager runs it ("ruya-p1").
    pub user: String,
    pub app_id: String,
    /// When the unit became active, in unix seconds (0 when unknown).
    pub started: i64,
    /// The unit is frozen (`FreezerState` frozen or freezing): a Freeze of the service before its
    /// restart (T-457).
    pub frozen: bool,
}

pub trait Spawner {
    /// Is this Flatpak application installed?
    fn is_installed(&self, app_id: &str) -> bool;
    /// Queues the app as `user` and returns the unit name. `UnitEvent`s follow.
    fn start(&self, user: &str, app_id: &str, env: &[(String, String)]) -> Result<String, String>;
    /// Asks the unit to end (SIGTERM).
    fn stop(&self, unit: &str) -> Result<(), String>;
    /// Ends the unit by force (SIGKILL).
    fn kill(&self, unit: &str) -> Result<(), String>;
    /// The app units that run already (a restart of this service does not end them), in every
    /// profile's manager. From now on their end is reported as a `UnitEvent::Exited`. Stop and
    /// kill work on them like on a unit this service started.
    fn adopt_running(&self) -> Vec<RunningUnit> {
        Vec::new()
    }
    /// Makes sure `user`'s sound server runs (`ruya-pulse@<user>.service` in `ruya-shell`'s
    /// manager, ADR-010, T-365) before an app of `user` starts. Returns once it is started.
    fn start_sound(&self, _user: &str) -> Result<(), String> {
        Ok(())
    }
    /// Freezes the unit and every active scope of its app with the cgroup freezer (T-457) and
    /// returns once it is done. Bounded: a manager that does not answer is an error.
    fn freeze(&self, unit: &str) -> Result<(), String> {
        Err(format!("cannot freeze {unit} here"))
    }
    /// Thaws what `freeze` froze; thawing a unit that is not frozen is a no-op. Bounded.
    fn thaw(&self, unit: &str) -> Result<(), String> {
        Err(format!("cannot thaw {unit} here"))
    }
    /// The cgroup file of a process (`/proc/<pid>/cgroup`, T-459); `None` when there is no such
    /// process or it cannot be read.
    fn process_cgroup(&self, _pid: u32) -> Option<String> {
        None
    }
    /// The name of the Unix user with this uid.
    fn user_name(&self, _uid: u32) -> Option<String> {
        None
    }
    /// Parks the sound of `user`'s frozen apps and puts back the rest (T-466): `frozen` are its
    /// frozen apps, `running` all its apps that are not stopping (both sorted). Returns at once;
    /// the work is queued, in order, and only the newest request per user is carried out.
    fn app_audio(&self, _user: &str, _frozen: &[String], _running: &[String]) {}
    /// Is any swap active (T-466)? A reclaim without swap only drops clean cache.
    fn swap_active(&self) -> bool {
        false
    }
    /// Starts moving the memory of the unit's app (the unit and every active scope) out to swap
    /// with `memory.reclaim` (T-466). Returns at once; the reclaim runs on.
    fn reclaim(&self, unit: &str) -> Result<(), String> {
        Err(format!("cannot reclaim {unit} here"))
    }
    /// Ends a reclaim of the unit's app that may still run (a thaw must not be slowed by it).
    /// Returns at once.
    fn cancel_reclaim(&self, _unit: &str) {}
}

impl<T: Spawner + ?Sized> Spawner for Box<T> {
    fn start_sound(&self, user: &str) -> Result<(), String> {
        (**self).start_sound(user)
    }
    fn is_installed(&self, app_id: &str) -> bool {
        (**self).is_installed(app_id)
    }
    fn start(&self, user: &str, app_id: &str, env: &[(String, String)]) -> Result<String, String> {
        (**self).start(user, app_id, env)
    }
    fn stop(&self, unit: &str) -> Result<(), String> {
        (**self).stop(unit)
    }
    fn kill(&self, unit: &str) -> Result<(), String> {
        (**self).kill(unit)
    }
    fn adopt_running(&self) -> Vec<RunningUnit> {
        (**self).adopt_running()
    }
    fn freeze(&self, unit: &str) -> Result<(), String> {
        (**self).freeze(unit)
    }
    fn thaw(&self, unit: &str) -> Result<(), String> {
        (**self).thaw(unit)
    }
    fn process_cgroup(&self, pid: u32) -> Option<String> {
        (**self).process_cgroup(pid)
    }
    fn user_name(&self, uid: u32) -> Option<String> {
        (**self).user_name(uid)
    }
    fn app_audio(&self, user: &str, frozen: &[String], running: &[String]) {
        (**self).app_audio(user, frozen, running)
    }
    fn swap_active(&self) -> bool {
        (**self).swap_active()
    }
    fn reclaim(&self, unit: &str) -> Result<(), String> {
        (**self).reclaim(unit)
    }
    fn cancel_reclaim(&self, unit: &str) {
        (**self).cancel_reclaim(unit)
    }
}

const MAX_APP_ID: usize = 120;

/// The Flatpak id grammar, strictly: reverse-DNS with at least three elements ("org.x.App", so at
/// least two dots), each non-empty and not starting with a digit, characters `[A-Za-z0-9_-]`
/// (Flatpak allows `-` only in the last element; allowing it everywhere is harmless in a unit
/// name and an argument list).
pub fn valid_app_id(id: &str) -> bool {
    if id.is_empty() || id.len() > MAX_APP_ID {
        return false;
    }
    let parts: Vec<&str> = id.split('.').collect();
    parts.len() >= 3
        && parts.iter().all(|p| {
            !p.is_empty()
                && !p.starts_with(|c: char| c.is_ascii_digit())
                && p.chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        })
}

/// A profile id as `ruya-profiles` makes them ("p3"): short, `[A-Za-z0-9_-]`.
pub fn valid_profile_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 32
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// The unit an app runs in: one per (user, app).
pub fn unit_name(user: &str, app_id: &str) -> String {
    format!("ruya-app-{user}-{app_id}.service")
}

/// The pattern of the scope `flatpak run` puts the sandbox in (`app-flatpak-<id>-<number>.scope`,
/// in the user's manager). The processes of the app live there, not in our unit: `flatpak run`
/// moves itself into the scope and the sandbox starts from it, so stopping the unit alone leaves
/// the app running. `systemctl stop|kill` take this pattern next to the unit name. The id is
/// checked again: only `[A-Za-z0-9_.-]` can be in it. systemd escapes the `-` of the id in the
/// unit name (`unit_escape`: `\x2d`); a backslash would escape the next character in the glob, so
/// it is written as `?` (the names that come back are checked with `is_app_scope` anyway).
pub fn scope_pattern(app_id: &str) -> Result<String, String> {
    if !valid_app_id(app_id) {
        return Err(format!("not an application id: {app_id:?}"));
    }
    Ok(format!(
        "app-flatpak-{}-*.scope",
        unit_escape(app_id).replace('\\', "?")
    ))
}

/// The id as systemd writes it in a unit name (`systemd-escape`): every byte outside
/// `[A-Za-z0-9_.:]` becomes `\xNN`, so the `-` of `attack-vector-alpha` is `\x2d` (a leading `.`
/// too, which an app id never has). Only valid app ids are expected; others get the same rule.
pub fn unit_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for (i, b) in s.bytes().enumerate() {
        let plain = b.is_ascii_alphanumeric() || matches!(b, b'_' | b':') || (b == b'.' && i > 0);
        if plain {
            out.push(b as char);
        } else {
            out.push_str(&format!("\\x{b:02x}"));
        }
    }
    out
}

/// Is `name` a scope `flatpak run <app_id>` makes (`app-flatpak-<escaped app_id>-<number>.scope`,
/// the `-` of the id written `\x2d`)? The part after the id must be digits only, so
/// `org.x.App-Extra` is not taken for `org.x.App`.
pub fn is_app_scope(app_id: &str, name: &str) -> bool {
    valid_app_id(app_id)
        && name
            .strip_prefix("app-flatpak-")
            .and_then(|rest| rest.strip_prefix(unit_escape(app_id).as_str()))
            .and_then(|rest| rest.strip_prefix('-'))
            .and_then(|rest| rest.strip_suffix(".scope"))
            .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

/// `systemctl` in `user`'s manager, the start of every list below. The user is validated again.
fn user_systemctl(user: &str) -> Result<Vec<String>, String> {
    if !user.strip_prefix("ruya-").is_some_and(valid_profile_id) {
        return Err(format!("not a profile user: {user:?}"));
    }
    let mut args: Vec<String> = ["systemctl", "--user", "--no-pager"]
        .into_iter()
        .map(str::to_owned)
        .collect();
    args.push(format!("--machine={user}@.host"));
    Ok(args)
}

/// The `systemctl` argument list that lists the loaded scopes that may be `app_id`'s in
/// `user`'s manager (any state, so a `failed` one too): `list-units --all --plain --no-legend`
/// with `scope_pattern`. The glob also matches a sibling app whose id starts with `<app_id>-`
/// (`io.github.Foo-bar.App` for `io.github.Foo`), so the answer goes through `app_scopes`
/// before any name reaches `stop`, `kill` or `reset-failed` (T-435). Pure.
pub fn list_scopes_command(user: &str, app_id: &str) -> Result<Vec<String>, String> {
    let mut args = user_systemctl(user)?;
    args.extend(
        ["list-units", "--all", "--plain", "--no-legend"]
            .into_iter()
            .map(str::to_owned),
    );
    args.push(scope_pattern(app_id)?);
    Ok(args)
}

/// The scopes of `app_id` in what `list_scopes_command` printed: the first word of each line
/// (a leading status mark is skipped), kept only when `is_app_scope` takes it, so a sibling
/// app's `app-flatpak-<app_id>-Extra-1.scope` is never named. Sorted, no duplicates.
pub fn app_scopes(app_id: &str, listing: &str) -> Vec<String> {
    let mut names: Vec<String> = listing
        .lines()
        .filter_map(|line| {
            line.split_whitespace()
                .find(|word| word.starts_with("app-flatpak-"))
        })
        .filter(|name| is_app_scope(app_id, name))
        .map(str::to_owned)
        .collect();
    names.sort();
    names.dedup();
    names
}

/// The scopes of `app_id` in what `list_scopes_command` printed that are active (ACTIVE column
/// "active"): the ones `freeze` and `thaw` may name, since systemd refuses to freeze or thaw a unit
/// that is not active (a `failed` scope the sweep has not cleared yet). Exact names as `app_scopes`
/// takes them, so never a sibling app's. Sorted, no duplicates. Pure (T-457).
pub fn active_app_scopes(app_id: &str, listing: &str) -> Vec<String> {
    let active: String = listing
        .lines()
        .filter(|line| {
            let mut words = line
                .split_whitespace()
                .skip_while(|w| !w.starts_with("app-flatpak-"));
            // UNIT LOAD ACTIVE SUB DESCRIPTION
            words.next().is_some() && words.nth(1) == Some("active")
        })
        .map(|line| format!("{line}\n"))
        .collect();
    app_scopes(app_id, &active)
}

/// The `systemctl` argument list that applies `verb` (`stop --no-block`, `kill ...`) to the unit
/// and to `scopes`, the app's own scopes in `user`'s manager as `app_scopes` found them. Every
/// one of them, not only the scope the run has attached (T-435): an Electron app has two (the
/// browser's from `flatpak run`, its sandboxed zygote's from the Flatpak portal), entered in the
/// same second, and the run may have attached either; naming one let the other run on after
/// `Stop`. One app runs once per profile user, so the app's scopes in that manager are all this
/// run's. Exact names only, never the glob (it would reach a sibling app, see
/// `list_scopes_command`). Pure; user, app and every scope are validated again.
pub fn control_command(
    user: &str,
    verb: &[&str],
    unit: &str,
    app_id: &str,
    scopes: &[String],
) -> Result<Vec<String>, String> {
    let mut args = user_systemctl(user)?;
    if !valid_app_id(app_id) {
        return Err(format!("not an application id: {app_id:?}"));
    }
    if let Some(bad) = scopes.iter().find(|s| !is_app_scope(app_id, s)) {
        return Err(format!("not a scope of {app_id}: {bad:?}"));
    }
    args.extend(verb.iter().map(|v| (*v).to_owned()));
    args.push(unit.to_owned());
    args.extend(scopes.iter().cloned());
    Ok(args)
}

/// The `systemctl` argument lists that clear what is left of a run of `app_id` in `user`'s
/// manager once its end is handed on (`scope::Sweep`, T-435): stop the app's scopes that are
/// still loaded (a second scope the Flatpak portal made, such as an Electron app's sandboxed
/// zygote), then clear the `failed` state of the ones systemd had to kill, so no scope of the
/// app stays listed. `scopes` is what `app_scopes` found (exact names; none: nothing to do).
/// `--no-block`: the stop is queued, so the sweep is quick and over before the end reaches the
/// core. Pure; user, app and every scope are validated again.
pub fn sweep_commands(
    user: &str,
    app_id: &str,
    scopes: &[String],
) -> Result<Vec<Vec<String>>, String> {
    let base = user_systemctl(user)?;
    if !valid_app_id(app_id) {
        return Err(format!("not an application id: {app_id:?}"));
    }
    if let Some(bad) = scopes.iter().find(|s| !is_app_scope(app_id, s)) {
        return Err(format!("not a scope of {app_id}: {bad:?}"));
    }
    if scopes.is_empty() {
        return Ok(Vec::new());
    }
    let command = |verb: &[&str]| {
        let mut args = base.clone();
        args.extend(verb.iter().map(|v| (*v).to_owned()));
        args.extend(scopes.iter().cloned());
        args
    };
    Ok(vec![
        command(&["stop", "--no-block"]),
        command(&["reset-failed"]),
    ])
}

/// The environment every app on the console gets (`app_env` then adds its Wayland socket and
/// `with_pulse_server` its sound server). The console has no X server (no XWayland), so the
/// toolkits that would try X11 first are told this is a Wayland session:
///   - `SDL_VIDEODRIVER=wayland`: SDL 2 otherwise tries X11 first and, without the
///     xdg-decoration protocol, may never try Wayland ("No available video device").
///   - `XDG_SESSION_TYPE=wayland` (T-435): Chromium and Electron choose their Ozone platform by
///     it (`--ozone-platform-hint=auto`); without it they take X11, find no `$DISPLAY` and exit
///     ("Missing X server or $DISPLAY"). ACBR (Electron 42) on the Dell showed no window for
///     that reason. `flatpak run` passes the variable into the sandbox.
pub fn console_env() -> Vec<(String, String)> {
    vec![
        ("SDL_VIDEODRIVER".to_owned(), "wayland".to_owned()),
        ("XDG_SESSION_TYPE".to_owned(), "wayland".to_owned()),
    ]
}

/// Is the application in the system Flatpak installation under `root` (`/var/lib/flatpak`)?
/// Flatpak keeps `app/<id>/current` (a link to `<arch>/<branch>`) for an installed app and
/// removes the directory on uninstall. A file check, so no process is started per launch.
pub fn flatpak_app_installed(root: &Path, app_id: &str) -> bool {
    valid_app_id(app_id) && root.join("app").join(app_id).join("current").exists()
}

/// The version of the installed app, from the first `<release version="...">` of its AppStream
/// file, or "" when it has none (or the app is not installed). For the play ledger (T-247); an
/// update that lands while the app runs is not noticed, so a session keeps the version it began
/// with.
pub fn flatpak_app_version(root: &Path, app_id: &str) -> String {
    if !valid_app_id(app_id) {
        return String::new();
    }
    let files = root
        .join("app")
        .join(app_id)
        .join("current")
        .join("active")
        .join("files");
    let candidates = [
        files
            .join("share/metainfo")
            .join(format!("{app_id}.metainfo.xml")),
        files
            .join("share/appdata")
            .join(format!("{app_id}.appdata.xml")),
    ];
    for path in candidates {
        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        if let Some(i) = text.find("<release ") {
            let tag = &text[i..];
            let tag = &tag[..tag.find('>').unwrap_or(tag.len())];
            if let Some(v) = tag.split("version=\"").nth(1) {
                let version = v.split('"').next().unwrap_or("");
                if !version.is_empty() && version.len() <= 32 {
                    return version.to_owned();
                }
            }
        }
    }
    String::new()
}

/// Where the compositor (`ruya-shell`) keeps one Wayland socket per profile user (ADR-023):
/// `/run/ruya-wayland/<user>`, owned by `ruya-shell`, mode 0600 plus one ACL entry that lets only
/// that user connect. The directory is the compositor unit's `RuntimeDirectory` (0711).
pub const WAYLAND_DIR: &str = "/run/ruya-wayland";

/// The `WAYLAND_DISPLAY` an app of `user` gets: the absolute path of that user's socket in `dir`.
/// `flatpak run` binds exactly this socket into the sandbox (as `wayland-0`), never the directory,
/// so a sandboxed app never learns where the sockets of other profiles are. `None` for anything
/// that is not a profile user.
pub fn wayland_display(dir: &str, user: &str) -> Option<String> {
    user.strip_prefix("ruya-")
        .is_some_and(valid_profile_id)
        .then(|| format!("{dir}/{user}"))
}

/// Where `ruya-pulse@.service` makes each profile user's sound server socket (ADR-010, T-365):
/// `/run/ruya-pulse/<user>/native`, in a directory only that user can pass.
pub const PULSE_DIR: &str = "/run/ruya-pulse";

/// The `PULSE_SERVER` an app of `user` gets: that user's own pulse socket in `dir`. `flatpak run
/// --socket=pulseaudio` binds exactly this socket into the sandbox. `None` for anything that is
/// not a profile user.
pub fn pulse_server(dir: &str, user: &str) -> Option<String> {
    user.strip_prefix("ruya-")
        .is_some_and(valid_profile_id)
        .then(|| format!("unix:{dir}/{user}/native"))
}

/// `env` with `PULSE_SERVER` set to `user`'s own sound server (one already there is replaced).
pub fn with_pulse_server(
    mut env: Vec<(String, String)>,
    dir: &str,
    user: &str,
) -> Vec<(String, String)> {
    if let Some(server) = pulse_server(dir, user) {
        env.retain(|(key, _)| key != "PULSE_SERVER");
        env.push(("PULSE_SERVER".to_owned(), server));
    }
    env
}

/// The argument list that starts `user`'s sound server in `ruya-shell`'s manager and waits until
/// it runs. Pure; the user is validated again, so the instance name is a plain identifier.
pub fn pulse_start_command(user: &str) -> Result<Vec<String>, String> {
    if !user.strip_prefix("ruya-").is_some_and(valid_profile_id) {
        return Err(format!("not a profile user: {user:?}"));
    }
    Ok(vec![
        "systemctl".to_owned(),
        "--user".to_owned(),
        "--no-pager".to_owned(),
        "--no-ask-password".to_owned(),
        "--machine=ruya-shell@.host".to_owned(),
        "start".to_owned(),
        format!("ruya-pulse@{user}.service"),
    ])
}

/// Where `ruya-devices` is installed: `--park-audio` runs it in `ruya-shell`'s manager (T-466).
pub const DEVICES_PROGRAM: &str = "/usr/bin/ruya-devices";

fn checked_user(user: &str) -> Result<(), String> {
    if user.strip_prefix("ruya-").is_some_and(valid_profile_id) {
        Ok(())
    } else {
        Err(format!("not a profile user: {user:?}"))
    }
}

fn checked_apps(ids: &[String]) -> Result<String, String> {
    match ids.iter().find(|id| !valid_app_id(id)) {
        Some(bad) => Err(format!("not an application id: {bad:?}")),
        None => Ok(ids.join(",")),
    }
}

/// The argument list that parks the sound of `user`'s frozen apps and puts back the others
/// (T-466): `ruya-devices --park-audio` as a transient unit of `ruya-shell`'s manager, the only
/// place that reaches the console's PipeWire (ADR-010; this service runs as root with no
/// capability and no access to `/run/user`). Waited for and bounded (`RuntimeMaxSec`). Pure;
/// every name is validated again.
pub fn park_audio_command(
    user: &str,
    frozen: &[String],
    running: &[String],
) -> Result<Vec<String>, String> {
    checked_user(user)?;
    let frozen = checked_apps(frozen)?;
    let running = checked_apps(running)?;
    let mut args: Vec<String> = [
        "systemd-run",
        "--machine=ruya-shell@.host",
        "--user",
        "--wait",
        "--quiet",
        "--collect",
        "--no-ask-password",
        "--property=RuntimeMaxSec=15",
        "--",
        DEVICES_PROGRAM,
        "--park-audio",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    args.push(user.to_owned());
    args.push(format!("--frozen={frozen}"));
    args.push(format!("--running={running}"));
    Ok(args)
}

/// One sound request (`Spawner::app_audio`, T-466): a profile user, its frozen apps, its running ones.
pub type AudioJob = (String, Vec<String>, Vec<String>);

/// How often a sound request is tried in all (a failed restore would leave a thawed game playing
/// into the null sink until its next Freeze).
pub const PARK_TRIES: u32 = 3;
/// The pause before a failed request is tried again.
pub const PARK_RETRY: Duration = Duration::from_secs(2);

/// The sound requests waiting for the worker, in order (T-466). Each request is the whole state of
/// its user, so a newer one replaces a queued one of the same user, and a failed one is tried
/// again only while no newer one of that user is queued. Pure.
#[derive(Debug, Default)]
pub struct AudioQueue {
    /// The request and how often it was tried.
    jobs: Vec<(AudioJob, u32)>,
}

impl AudioQueue {
    /// Queues `job`, replacing a queued request (or a pending retry) of the same user.
    pub fn push(&mut self, job: AudioJob) {
        self.jobs.retain(|(queued, _)| queued.0 != job.0);
        self.jobs.push((job, 0));
    }

    /// The next request to run and how often it was tried before.
    pub fn pop(&mut self) -> Option<(AudioJob, u32)> {
        (!self.jobs.is_empty()).then(|| self.jobs.remove(0))
    }

    /// `job` failed after `tries` earlier tries: queued again (true) unless it has had
    /// `PARK_TRIES` or a newer request of its user is queued.
    pub fn failed(&mut self, job: AudioJob, tries: u32) -> bool {
        if tries + 1 >= PARK_TRIES || self.jobs.iter().any(|(queued, _)| queued.0 == job.0) {
            return false;
        }
        self.jobs.push((job, tries + 1));
        true
    }

    pub fn is_empty(&self) -> bool {
        self.jobs.is_empty()
    }

    /// Is a request of `user` queued (a newer one than a retry being waited for)?
    pub fn has(&self, user: &str) -> bool {
        self.jobs.iter().any(|(queued, _)| queued.0 == user)
    }
}

/// The share of a frozen app's `memory.current` that `memory.reclaim` is asked for (T-466): the
/// kernel takes the coldest pages first, and what stays is what the game touches first when it is
/// thawed. A starting value; the Dell numbers decide (task T-466 Outcome).
pub const RECLAIM_PERCENT: u64 = 50;

/// The bytes to ask `memory.reclaim` for, for a cgroup with `current` bytes charged.
pub fn reclaim_amount(current: u64) -> u64 {
    current / 100 * RECLAIM_PERCENT
}

/// The transient unit a reclaim of `app_id` runs as, in the profile user's manager.
pub fn reclaim_unit(app_id: &str) -> String {
    format!("ruya-reclaim-{app_id}.service")
}

/// The script of the reclaim unit: writes each amount to its `memory.reclaim`. A write that the
/// kernel could not satisfy in full fails (EAGAIN) and the next one still runs.
pub const RECLAIM_SCRIPT: &str =
    "while [ \"$#\" -ge 2 ]; do echo \"$1\" > \"$2\"; shift 2; done; exit 0";

/// The frozen apps whose reclaim unit was really started (RUY-573): the thaw stops the
/// `ruya-reclaim-*` unit only for these, never one that was not made (the reclaim thread can
/// bail before it starts the unit).
#[derive(Default)]
pub struct ReclaimLedger(std::sync::Mutex<std::collections::HashSet<String>>);

impl ReclaimLedger {
    pub fn started(&self, unit: &str) {
        if let Ok(mut set) = self.0.lock() {
            set.insert(unit.to_owned());
        }
    }

    /// Takes `unit` out; true when its reclaim had started.
    pub fn take(&self, unit: &str) -> bool {
        self.0.lock().map(|mut set| set.remove(unit)).unwrap_or(false)
    }
}

/// A cgroup of a profile user's manager, as `systemctl show -p ControlGroup` gives it: absolute,
/// under `/user.slice/`, no `..`, only the characters unit names use.
pub fn valid_user_cgroup(path: &str) -> bool {
    path.starts_with("/user.slice/user-")
        && !path.split('/').any(|part| part == "..")
        && path
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '.' | '-' | '_' | '@' | '\\'))
}

/// The argument list that reclaims `targets` (bytes, cgroup path as `ControlGroup` gives it) as
/// `user`, in that user's manager (T-466): the user owns the cgroups of its own apps (systemd
/// delegates the manager's subtree to it), while this service may not write the cgroup tree at
/// all (`ProtectControlGroups=`, no capability). Waited for; bounded by `RuntimeMaxSec`. Pure;
/// every name and path is validated again.
pub fn reclaim_command(
    user: &str,
    app_id: &str,
    targets: &[(u64, String)],
) -> Result<Vec<String>, String> {
    checked_user(user)?;
    if !valid_app_id(app_id) {
        return Err(format!("not an application id: {app_id:?}"));
    }
    if targets.is_empty() {
        return Err(format!("nothing of {app_id} to reclaim"));
    }
    let mut args: Vec<String> = vec![
        "systemd-run".to_owned(),
        format!("--machine={user}@.host"),
        "--user".to_owned(),
        "--wait".to_owned(),
        "--quiet".to_owned(),
        "--collect".to_owned(),
        "--no-ask-password".to_owned(),
        format!("--unit={}", reclaim_unit(app_id)),
        "--property=RuntimeMaxSec=30".to_owned(),
        "--".to_owned(),
        "/usr/bin/sh".to_owned(),
        "-c".to_owned(),
        RECLAIM_SCRIPT.to_owned(),
        "ruya-reclaim".to_owned(),
    ];
    for (bytes, cgroup) in targets {
        if !valid_user_cgroup(cgroup) {
            return Err(format!("not a cgroup of a user's manager: {cgroup:?}"));
        }
        args.push(bytes.to_string());
        args.push(format!("/sys/fs/cgroup{cgroup}/memory.reclaim"));
    }
    Ok(args)
}

/// `systemctl --user -M <user>@.host stop --no-block ruya-reclaim-<app>.service`: a running
/// reclaim ends (its write is interrupted by the signal). Pure.
pub fn cancel_reclaim_command(user: &str, app_id: &str) -> Result<Vec<String>, String> {
    let mut args = user_systemctl(user)?;
    if !valid_app_id(app_id) {
        return Err(format!("not an application id: {app_id:?}"));
    }
    args.extend([
        "stop".to_owned(),
        "--no-block".to_owned(),
        reclaim_unit(app_id),
    ]);
    Ok(args)
}

/// `systemctl --user -M <user>@.host show -p ControlGroup --value <unit>...`. Pure.
pub fn control_groups_command(user: &str, units: &[String]) -> Result<Vec<String>, String> {
    let mut args = user_systemctl(user)?;
    if units.is_empty()
        || units.iter().any(|u| {
            u.is_empty()
                || !u
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "._-@\\".contains(c))
        })
    {
        return Err(format!("not unit names: {units:?}"));
    }
    args.extend(["show", "-p", "ControlGroup", "--value"].map(str::to_owned));
    args.extend(units.iter().cloned());
    Ok(args)
}

/// The cgroups `control_groups_command` printed: one per unit, blank lines between units. Only
/// valid user cgroups (`valid_user_cgroup`); no duplicates.
pub fn parse_control_groups(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for line in text.lines().map(str::trim) {
        if valid_user_cgroup(line) && !out.iter().any(|o| o == line) {
            out.push(line.to_owned());
        }
    }
    out
}

/// The active swap devices, in the system manager (systemd follows every swap in /proc/swaps
/// as a `.swap` unit; this service's `ProcSubset=pid` hides /proc/swaps itself).
pub const SWAP_COMMAND: [&str; 7] = [
    "systemctl",
    "list-units",
    "--type=swap",
    "--state=active",
    "--plain",
    "--no-legend",
    "--no-pager",
];

/// Does the listing of `SWAP_COMMAND` name an active swap unit?
pub fn any_swap(listing: &str) -> bool {
    listing.lines().any(|line| {
        line.split_whitespace()
            .next()
            .is_some_and(|unit| unit.ends_with(".swap"))
    })
}

/// The environment of one app of `user`: `base`, with `WAYLAND_DISPLAY` set to the user's own
/// socket when there is a socket directory (one in `base` is replaced).
pub fn app_env(
    base: &[(String, String)],
    wayland_dir: Option<&str>,
    user: &str,
) -> Vec<(String, String)> {
    let mut env = base.to_vec();
    if let Some(display) = wayland_dir.and_then(|dir| wayland_display(dir, user)) {
        env.retain(|(key, _)| key != "WAYLAND_DISPLAY");
        env.push(("WAYLAND_DISPLAY".to_owned(), display));
    }
    env
}

/// The argument list that starts `flatpak run <app_id>` as `user` in that user's systemd manager
/// and waits for it (`--wait`: the process lives as long as the app does, and prints the
/// start and the end on stderr, see `parse_run_line`). `Type=exec` makes the start line mean
/// "the program was executed". Pure: nothing is executed. Every value is validated again here
/// (the core has checked them already), so the list holds only plain identifiers, and the
/// application id comes after `--` so it can never be read as an option.
pub fn launch_command(
    user: &str,
    app_id: &str,
    env: &[(String, String)],
) -> Result<Vec<String>, String> {
    launch_command_in(user, app_id, env, DisplayMode::Wayland)
}

/// How an app reaches the screen (ADR-034): on the profile's Wayland socket, or through a private
/// X server that the unit's helper starts first (`x11::needs_x11`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisplayMode {
    Wayland,
    X11,
}

/// This binary in the image; in X11 mode it is the unit's main process (`x11-run`) and its
/// `ExecStopPost` (`x11-cleanup`).
pub const SESSION_PROGRAM: &str = "/usr/bin/ruya-session";

/// `launch_command` for either display mode. In X11 mode the unit runs
/// `ruya-session x11-run <app_id>` (which starts the X server and then `flatpak run`) and cleans
/// up with `ruya-session x11-cleanup <app_id>` after any end, a Stop included.
pub fn launch_command_in(
    user: &str,
    app_id: &str,
    env: &[(String, String)],
    mode: DisplayMode,
) -> Result<Vec<String>, String> {
    if !user.strip_prefix("ruya-").is_some_and(valid_profile_id) {
        return Err(format!("not a profile user: {user:?}"));
    }
    if !valid_app_id(app_id) {
        return Err(format!("not an application id: {app_id:?}"));
    }
    let mut args: Vec<String> = [
        "systemd-run",
        "--user",
        "--wait",
        "--collect",
        "--property=Type=exec",
        "--property=KillMode=control-group",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    args.push(format!("--machine={user}@.host"));
    args.push(format!("--unit={}", unit_name(user, app_id)));
    for (key, value) in env {
        let key_ok = !key.is_empty()
            && !key.starts_with(|c: char| c.is_ascii_digit())
            && key
                .chars()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_');
        let value_ok = !value.is_empty()
            && value
                .chars()
                // `:` for `PULSE_SERVER=unix:/...` (T-365); still one plain argv entry.
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | '/' | ':'));
        if !key_ok || !value_ok {
            return Err(format!("bad environment entry: {key:?}"));
        }
        args.push(format!("--setenv={key}={value}"));
    }
    match mode {
        DisplayMode::Wayland => args.extend(["--", "flatpak", "run"].map(str::to_owned)),
        DisplayMode::X11 => {
            args.push(format!(
                "--property=ExecStopPost={SESSION_PROGRAM} x11-cleanup {app_id}"
            ));
            args.extend(["--", SESSION_PROGRAM, "x11-run"].map(str::to_owned));
        }
    }
    args.push(app_id.to_owned());
    Ok(args)
}

/// What one line of `systemd-run --wait` says (it writes them to stderr):
///   `Running as unit: <unit>[; invocation ID: ...]`                 the program was executed
///   `Main processes terminated with: code=exited, status=3/NOTIMPLEMENTED`   (or `code=killed,
///   status=15/TERM`; `status` is the exit status, or the signal number after `killed`/`dumped`)
/// Other lines (result, runtime, CPU) say nothing we need.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunLine {
    Running,
    Ended {
        code: i32,
        signaled: bool,
    },
    /// `status=203/EXEC`: systemd could not execute the program.
    ExecFailed,
}

/// The exit status systemd gives a service whose program it could not execute.
const EXIT_EXEC: i32 = 203;

pub fn parse_run_line(line: &str) -> Option<RunLine> {
    let line = line.trim();
    if line.starts_with("Running as unit:") {
        return Some(RunLine::Running);
    }
    let rest = line.strip_prefix("Main process")?;
    let rest = rest.split_once("terminated with:")?.1;
    let mut code_kind = None;
    let mut status = None;
    let mut status_name = "";
    for part in rest.split(',') {
        let part = part.trim();
        if let Some(kind) = part.strip_prefix("code=") {
            code_kind = Some(kind.trim());
        } else if let Some(num) = part.strip_prefix("status=") {
            // "3/NOTIMPLEMENTED": the number comes first.
            status = num.split('/').next().and_then(|n| n.trim().parse().ok());
            status_name = num.split('/').nth(1).map_or("", str::trim);
        }
    }
    let code = status?;
    match code_kind? {
        "exited" if code == EXIT_EXEC && status_name == "EXEC" => Some(RunLine::ExecFailed),
        "exited" => Some(RunLine::Ended {
            code,
            signaled: false,
        }),
        "killed" | "dumped" => Some(RunLine::Ended {
            code,
            signaled: true,
        }),
        _ => None,
    }
}

/// Turns the lines of one `systemd-run --wait` process, and its own end, into `UnitEvent`s: one
/// `Started` at most, and exactly one `Exited`. The end the unit reported wins over the exit
/// status of `systemd-run` itself (which is only a copy of it, and the only thing there is when
/// the start failed before a unit existed).
pub struct RunFollower {
    unit: String,
    started: bool,
    ended: Option<(i32, bool)>,
    exec_failed: bool,
}

impl RunFollower {
    pub fn new(unit: &str) -> Self {
        RunFollower {
            unit: unit.to_owned(),
            started: false,
            ended: None,
            exec_failed: false,
        }
    }

    pub fn line(&mut self, line: &str) -> Option<UnitEvent> {
        match parse_run_line(line)? {
            RunLine::Running if !self.started => {
                self.started = true;
                Some(UnitEvent::Started {
                    unit: self.unit.clone(),
                })
            }
            RunLine::Running => None,
            RunLine::Ended { code, signaled } => {
                self.ended.get_or_insert((code, signaled));
                None
            }
            RunLine::ExecFailed => {
                if self.ended.is_none() {
                    self.ended = Some((EXIT_EXEC, false));
                    self.exec_failed = true;
                }
                None
            }
        }
    }

    /// `systemd-run` ended: with this exit code, or (`signaled`) killed by this signal.
    pub fn finish(self, code: i32, signaled: bool) -> UnitEvent {
        if self.exec_failed {
            return UnitEvent::ExecFailed { unit: self.unit };
        }
        let (code, signaled) = self.ended.unwrap_or((code, signaled));
        UnitEvent::Exited {
            unit: self.unit,
            code,
            signaled,
        }
    }
}

/// Reads the lines a process appends to a file, a bit at a time: `poll` returns the complete
/// lines that came since the last call and keeps a half-written one for the next.
pub struct LineTail {
    file: File,
    partial: Vec<u8>,
}

impl LineTail {
    pub fn open(path: &Path) -> std::io::Result<Self> {
        Ok(LineTail {
            file: File::open(path)?,
            partial: Vec::new(),
        })
    }

    pub fn poll(&mut self) -> Vec<String> {
        let mut chunk = [0u8; 4096];
        loop {
            match self.file.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => self.partial.extend_from_slice(&chunk[..n]),
            }
        }
        let mut lines = Vec::new();
        while let Some(end) = self.partial.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.partial.drain(..=end).collect();
            lines.push(String::from_utf8_lossy(&line[..end]).into_owned());
        }
        lines
    }
}

/// The application id of a unit this service named (`unit_name`), given the user whose manager
/// runs it. The user is known from the manager that was asked, so the split is never a guess (a
/// profile id and the first element of an app id may both contain `-`).
pub fn unit_app_id(user: &str, unit: &str) -> Option<String> {
    let app = unit
        .strip_prefix("ruya-app-")?
        .strip_prefix(user)?
        .strip_prefix('-')?
        .strip_suffix(".service")?;
    valid_app_id(app).then(|| app.to_owned())
}

/// Where a process is, read from its `/proc/<pid>/cgroup` (T-459): the uid of the user manager
/// whose tree holds it and the units between that manager and the process, the deepest first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessPlace {
    pub uid: u32,
    pub units: Vec<String>,
}

/// The place of a process out of its cgroup file: the cgroup v2 line (`0::<path>`) whose path
/// goes through a user manager (`.../user@<uid>.service/app.slice/<unit>`). `None` for a process
/// outside every user manager (a system service, the kernel) or a file of another shape.
pub fn parse_cgroup(text: &str) -> Option<ProcessPlace> {
    let path = text.lines().find_map(|l| l.strip_prefix("0::"))?;
    let parts: Vec<&str> = path.trim().split('/').filter(|p| !p.is_empty()).collect();
    let at = parts.iter().position(|p| {
        p.strip_prefix("user@")
            .and_then(|r| r.strip_suffix(".service"))
            .is_some_and(|uid| !uid.is_empty() && uid.bytes().all(|b| b.is_ascii_digit()))
    })?;
    let uid = parts[at]
        .strip_prefix("user@")
        .and_then(|r| r.strip_suffix(".service"))
        .and_then(|uid| uid.parse().ok())?;
    let units = parts[at + 1..]
        .iter()
        .rev()
        .map(|p| (*p).to_owned())
        .collect();
    Some(ProcessPlace { uid, units })
}

/// The profile users out of `loginctl list-users --no-legend` (`UID USER LINGER STATE` per
/// line): the names `ruya-<id>`. `ruya-shell` is a name of that shape too; whether it is a
/// profile is for the directory to say, not for this parser.
pub fn parse_profile_users(output: &str) -> Vec<String> {
    output
        .lines()
        .filter_map(|line| line.split_whitespace().nth(1))
        .filter(|name| name.strip_prefix("ruya-").is_some_and(valid_profile_id))
        .map(str::to_owned)
        .collect()
}

/// What `systemctl show` says about one unit (the properties `SHOW_PROPERTIES` asks for).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ShowUnit {
    pub id: String,
    pub load_state: String,
    pub active_state: String,
    /// `ActiveEnterTimestamp` in unix seconds (`--timestamp=unix` prints `@<seconds>`), 0 if none.
    pub entered: i64,
    /// `ExecMainStatus`: the exit status, or the signal number when `exec_main_code` is 2 or 3.
    pub exec_main_status: i32,
    /// `ExecMainCode`: 1 exited, 2 killed, 3 dumped (the `CLD_*` codes), 0 not ended yet.
    pub exec_main_code: i32,
    /// `CPUUsageNSec`: CPU time used so far, in nanoseconds; `None` for `[not set]` (accounting
    /// off) or a unit that was not asked.
    pub cpu_nsec: Option<u64>,
    /// `FreezerState`: "running", "freezing", "frozen", "thawing" ("" when not asked), T-457.
    pub freezer_state: String,
}

impl ShowUnit {
    /// Is it still a unit with a running (or starting, or stopping) program?
    pub fn alive(&self) -> bool {
        self.load_state != "not-found"
            && !matches!(self.active_state.as_str(), "inactive" | "failed" | "")
    }
}

/// The `-p` arguments of the `systemctl show` call that `parse_show` reads.
pub const SHOW_PROPERTIES: [&str; 8] = [
    "Id",
    "LoadState",
    "ActiveState",
    "ActiveEnterTimestamp",
    "ExecMainStatus",
    "ExecMainCode",
    "CPUUsageNSec",
    "FreezerState",
];

/// The units of a `systemctl show` output: `Key=Value` lines, a blank line between units.
pub fn parse_show(output: &str) -> Vec<ShowUnit> {
    let mut units = Vec::new();
    let mut cur = ShowUnit::default();
    let mut any = false;
    for line in output.lines().chain(std::iter::once("")) {
        let line = line.trim_end();
        if line.is_empty() {
            if any && !cur.id.is_empty() {
                units.push(std::mem::take(&mut cur));
            }
            cur = ShowUnit::default();
            any = false;
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        any = true;
        match key {
            "Id" => cur.id = value.to_owned(),
            "LoadState" => cur.load_state = value.to_owned(),
            "ActiveState" => cur.active_state = value.to_owned(),
            "ActiveEnterTimestamp" => {
                cur.entered = value
                    .strip_prefix('@')
                    .and_then(|n| n.trim().parse().ok())
                    .unwrap_or(0);
            }
            "ExecMainStatus" => cur.exec_main_status = value.trim().parse().unwrap_or(0),
            "ExecMainCode" => cur.exec_main_code = value.trim().parse().unwrap_or(0),
            // "[not set]" (accounting off) and "18446744073709551615" (systemd's "unknown") are
            // no reading.
            "CPUUsageNSec" => {
                cur.cpu_nsec = value.trim().parse().ok().filter(|n| *n != u64::MAX);
            }
            "FreezerState" => cur.freezer_state = value.trim().to_owned(),
            _ => {}
        }
    }
    units
}

/// What the manager says changed about a unit (a `PropertiesChanged`): only the properties that
/// were in the signal.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct UnitChange {
    pub active_state: Option<String>,
    pub exec_main_status: Option<i32>,
    pub exec_main_code: Option<i32>,
}

/// Follows a unit this service did not start (it has no `systemd-run --wait` to tell its end):
/// fed with what the manager says about it (`apply` for a change signal, `observe` for a full
/// `show`), it reports the end once. The exit status is the last one seen while the unit was
/// alive or on its way out: the manager forgets a `--collect`ed unit the moment it ends, so only
/// the change signals that come before `UnitRemoved` carry the real status.
pub struct UnitWatch {
    unit: String,
    status: i32,
    main_code: i32,
}

impl UnitWatch {
    pub fn new(unit: &str) -> Self {
        UnitWatch {
            unit: unit.to_owned(),
            status: 0,
            main_code: 0,
        }
    }

    /// A full look at the unit.
    pub fn observe(&mut self, show: &ShowUnit) -> Option<UnitEvent> {
        if !show.alive() {
            // A dead (or never loaded) unit says nothing about how its program ended.
            return self.apply(&UnitChange {
                active_state: Some("inactive".to_owned()),
                ..UnitChange::default()
            });
        }
        self.apply(&UnitChange {
            active_state: Some(show.active_state.clone()),
            exec_main_status: Some(show.exec_main_status),
            exec_main_code: Some(show.exec_main_code),
        })
    }

    /// A change of some properties. `Some` once the unit is no longer active.
    pub fn apply(&mut self, change: &UnitChange) -> Option<UnitEvent> {
        // `ExecMainCode` 0 means "the program has not ended": its status says nothing yet.
        if change.exec_main_code != Some(0) {
            if let Some(status) = change.exec_main_status {
                self.status = status;
            }
        }
        if let Some(code) = change.exec_main_code.filter(|c| *c != 0) {
            self.main_code = code;
        }
        match change.active_state.as_deref() {
            Some("inactive" | "failed") => Some(self.ended()),
            _ => None,
        }
    }

    /// The exit as far as it is known. The signal number counts when the main process was
    /// killed (`ExecMainCode` 2 or 3).
    pub fn ended(&self) -> UnitEvent {
        UnitEvent::Exited {
            unit: self.unit.clone(),
            code: self.status,
            signaled: matches!(self.main_code, 2 | 3),
        }
    }
}

/// For tests and `--session`. Records the calls; with an event channel it behaves like a quick
/// OS: `start` is followed by `Started`, `stop` by a normal exit, `kill` by a signal exit.
#[derive(Default)]
pub struct FakeSpawner {
    state: Arc<Mutex<FakeState>>,
    events: Option<Sender<UnitEvent>>,
}

#[derive(Default)]
struct FakeState {
    installed: HashSet<String>,
    fail_start: bool,
    fail_sound: bool,
    fail_freeze: bool,
    calls: Vec<String>,
    /// `app_audio` requests, as "user frozen=a,b running=a,b,c" (T-466).
    audio: Vec<String>,
    /// `swap_active` answers this.
    swap: bool,
    running: Vec<RunningUnit>,
    last_env: Vec<(String, String)>,
    /// pid -> cgroup file (`process_cgroup`, T-459).
    processes: HashMap<u32, String>,
    /// uid -> user name (`user_name`).
    users: HashMap<u32, String>,
}

impl FakeSpawner {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_events(mut self, events: Sender<UnitEvent>) -> Self {
        self.events = Some(events);
        self
    }

    pub fn with_app(self, app_id: &str) -> Self {
        self.lock().installed.insert(app_id.to_owned());
        self
    }

    /// A unit that runs already when the service starts (`adopt_running`).
    pub fn with_running(self, user: &str, app_id: &str, started: i64) -> Self {
        self.lock().running.push(RunningUnit {
            unit: unit_name(user, app_id),
            user: user.to_owned(),
            app_id: app_id.to_owned(),
            started,
            frozen: false,
        });
        self
    }

    /// Like `with_running`, but the unit was left frozen (T-457).
    pub fn with_frozen_running(self, user: &str, app_id: &str, started: i64) -> Self {
        self.lock().running.push(RunningUnit {
            unit: unit_name(user, app_id),
            user: user.to_owned(),
            app_id: app_id.to_owned(),
            started,
            frozen: true,
        });
        self
    }

    /// A process whose `/proc/<pid>/cgroup` reads `cgroup` (T-459).
    pub fn with_process(self, pid: u32, cgroup: &str) -> Self {
        self.lock().processes.insert(pid, cgroup.to_owned());
        self
    }

    /// A Unix user `name` with this uid.
    pub fn with_user(self, uid: u32, name: &str) -> Self {
        self.lock().users.insert(uid, name.to_owned());
        self
    }

    pub fn failing_start(self) -> Self {
        self.lock().fail_start = true;
        self
    }

    /// `start_sound` fails (the profile's sound server cannot start).
    pub fn failing_sound(self) -> Self {
        self.lock().fail_sound = true;
        self
    }

    /// `freeze` fails (and the thaw that undoes it works), T-457.
    pub fn failing_freeze(self) -> Self {
        self.lock().fail_freeze = true;
        self
    }

    /// Swap is active (T-466).
    pub fn with_swap(self) -> Self {
        self.lock().swap = true;
        self
    }

    /// The same fake (its calls and its state), without the events: for a test that looks at the
    /// calls from inside a call (a clock, T-466).
    pub fn observer(&self) -> FakeSpawner {
        FakeSpawner {
            state: Arc::clone(&self.state),
            events: None,
        }
    }

    /// "sound user", "start user app", "stop unit", "kill unit", "freeze unit", "thaw unit",
    /// "reclaim unit", "cancel-reclaim unit", in order.
    pub fn calls(&self) -> Vec<String> {
        self.lock().calls.clone()
    }

    /// The `app_audio` requests, in order: "user frozen=a,b running=a,b,c" (T-466).
    pub fn audio_calls(&self) -> Vec<String> {
        self.lock().audio.clone()
    }

    /// The environment the last `start` was given.
    pub fn last_env(&self) -> Vec<(String, String)> {
        self.lock().last_env.clone()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, FakeState> {
        // A poisoned lock only means another thread panicked; the data is still usable.
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn emit(&self, event: UnitEvent) {
        if let Some(tx) = &self.events {
            let _ = tx.try_send(event);
        }
    }
}

impl Spawner for FakeSpawner {
    fn is_installed(&self, app_id: &str) -> bool {
        self.lock().installed.contains(app_id)
    }

    fn start_sound(&self, user: &str) -> Result<(), String> {
        let mut state = self.lock();
        state.calls.push(format!("sound {user}"));
        if state.fail_sound {
            return Err("fake sound failure".to_owned());
        }
        Ok(())
    }

    fn start(&self, user: &str, app_id: &str, env: &[(String, String)]) -> Result<String, String> {
        let mut state = self.lock();
        state.calls.push(format!("start {user} {app_id}"));
        state.last_env = env.to_vec();
        if state.fail_start {
            return Err("fake start failure".to_owned());
        }
        drop(state);
        let unit = unit_name(user, app_id);
        self.emit(UnitEvent::Started { unit: unit.clone() });
        Ok(unit)
    }

    fn stop(&self, unit: &str) -> Result<(), String> {
        self.lock().calls.push(format!("stop {unit}"));
        self.emit(UnitEvent::Exited {
            unit: unit.to_owned(),
            code: 0,
            signaled: false,
        });
        Ok(())
    }

    fn kill(&self, unit: &str) -> Result<(), String> {
        self.lock().calls.push(format!("kill {unit}"));
        self.emit(UnitEvent::Exited {
            unit: unit.to_owned(),
            code: 9,
            signaled: true,
        });
        Ok(())
    }

    fn adopt_running(&self) -> Vec<RunningUnit> {
        let mut state = self.lock();
        state.calls.push("adopt".to_owned());
        state.running.clone()
    }

    fn freeze(&self, unit: &str) -> Result<(), String> {
        let mut state = self.lock();
        state.calls.push(format!("freeze {unit}"));
        if state.fail_freeze {
            return Err("fake freeze failure".to_owned());
        }
        Ok(())
    }

    fn thaw(&self, unit: &str) -> Result<(), String> {
        self.lock().calls.push(format!("thaw {unit}"));
        Ok(())
    }

    fn process_cgroup(&self, pid: u32) -> Option<String> {
        self.lock().processes.get(&pid).cloned()
    }

    fn user_name(&self, uid: u32) -> Option<String> {
        self.lock().users.get(&uid).cloned()
    }

    fn app_audio(&self, user: &str, frozen: &[String], running: &[String]) {
        self.lock().audio.push(format!(
            "{user} frozen={} running={}",
            frozen.join(","),
            running.join(",")
        ));
    }

    fn swap_active(&self) -> bool {
        self.lock().swap
    }

    fn reclaim(&self, unit: &str) -> Result<(), String> {
        self.lock().calls.push(format!("reclaim {unit}"));
        Ok(())
    }

    fn cancel_reclaim(&self, unit: &str) {
        self.lock().calls.push(format!("cancel-reclaim {unit}"));
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_cgroup_file_names_the_user_manager_and_the_units_deepest_first() {
        use super::{parse_cgroup, ProcessPlace};
        let flatpak = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-flatpak-io.github.x.Game-12345.scope\n";
        assert_eq!(
            parse_cgroup(flatpak),
            Some(ProcessPlace {
                uid: 1000,
                units: vec![
                    "app-flatpak-io.github.x.Game-12345.scope".to_owned(),
                    "app.slice".to_owned()
                ],
            })
        );
        // A hybrid hierarchy has other lines first; only the v2 line counts.
        let hybrid = "12:pids:/user.slice\n0::/user.slice/user-1001.slice/user@1001.service/app.slice/ruya-app-ruya-p2-org.x.App.service";
        assert_eq!(parse_cgroup(hybrid).map(|p| p.uid), Some(1001));
        // Outside every user manager, or not a cgroup file at all.
        assert_eq!(
            parse_cgroup("0::/system.slice/ruya-session.service\n"),
            None
        );
        assert_eq!(
            parse_cgroup("0::/user.slice/user-1000.slice/user@.service/x.scope"),
            None
        );
        assert_eq!(parse_cgroup("garbage"), None);
        assert_eq!(parse_cgroup(""), None);
    }

    #[test]
    fn the_version_comes_from_the_first_release_of_the_appstream_file() {
        let root = std::env::temp_dir().join(format!("ruya-ver-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let dir = root.join("app/org.ruyaos.Racer/current/active/files/share/metainfo");
        std::fs::create_dir_all(&dir).unwrap_or_else(|e| panic!("{e}"));
        let file = dir.join("org.ruyaos.Racer.metainfo.xml");
        std::fs::write(
            &file,
            "<component><releases><release version=\"1.4.2\" date=\"2026-01-01\"/><release version=\"1.0\"/></releases></component>",
        )
        .unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(flatpak_app_version(&root, "org.ruyaos.Racer"), "1.4.2");
        std::fs::write(&file, "<component/>").unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(flatpak_app_version(&root, "org.ruyaos.Racer"), "");
        assert_eq!(flatpak_app_version(&root, "org.ruyaos.Other"), "");
        assert_eq!(flatpak_app_version(&root, "../x"), "");
        let _ = std::fs::remove_dir_all(&root);
    }

    use super::*;

    fn env() -> Vec<(String, String)> {
        vec![("WAYLAND_DISPLAY".to_owned(), "wayland-0".to_owned())]
    }

    #[test]
    fn app_id_grammar() {
        for ok in [
            "org.ruyaos.Racer",
            "org.mozilla.firefox",
            "com.valvesoftware.Steam",
            "a.b.c_d-e",
        ] {
            assert!(valid_app_id(ok), "{ok}");
        }
        for bad in [
            "",
            "Racer",
            "org.Racer",
            "org..Racer",
            ".org.ruyaos.Racer",
            "org.ruyaos.Racer.",
            "org.ruyaos.Rac er",
            "org.ruyaos.Racer;rm",
            "org.ruyaos.\"Racer\"",
            "org.ruyaos.Racer\n",
            "org.1x.Racer",
            "--help",
            "org.ruyaos.Racer --root",
        ] {
            assert!(!valid_app_id(bad), "{bad:?}");
        }
        assert!(!valid_app_id(&format!("org.a.{}", "x".repeat(MAX_APP_ID))));
    }

    #[test]
    fn profile_id_grammar() {
        assert!(valid_profile_id("p3"));
        assert!(valid_profile_id("guest"));
        let long = "a".repeat(33);
        for bad in ["", "p 3", "p;3", "p/3", long.as_str(), "p\u{e9}"] {
            assert!(!valid_profile_id(bad), "{bad:?}");
        }
    }

    #[test]
    fn launch_command_exact_arguments() {
        let args = launch_command("ruya-p1", "org.ruyaos.Racer", &env()).expect("valid");
        assert_eq!(
            args,
            [
                "systemd-run",
                "--user",
                "--wait",
                "--collect",
                "--property=Type=exec",
                "--property=KillMode=control-group",
                "--machine=ruya-p1@.host",
                "--unit=ruya-app-ruya-p1-org.ruyaos.Racer.service",
                "--setenv=WAYLAND_DISPLAY=wayland-0",
                "--",
                "flatpak",
                "run",
                "org.ruyaos.Racer",
            ]
        );
    }

    #[test]
    fn an_x11_launch_runs_the_helper_and_cleans_up_after_it() {
        let app = "io.github.divVerent.aaaaxy";
        let args = launch_command_in("ruya-p1", app, &env(), DisplayMode::X11).expect("valid");
        assert_eq!(
            args,
            [
                "systemd-run",
                "--user",
                "--wait",
                "--collect",
                "--property=Type=exec",
                "--property=KillMode=control-group",
                "--machine=ruya-p1@.host",
                "--unit=ruya-app-ruya-p1-io.github.divVerent.aaaaxy.service",
                "--setenv=WAYLAND_DISPLAY=wayland-0",
                "--property=ExecStopPost=/usr/bin/ruya-session x11-cleanup io.github.divVerent.aaaaxy",
                "--",
                "/usr/bin/ruya-session",
                "x11-run",
                "io.github.divVerent.aaaaxy",
            ]
        );
        // No PrivateTmp: Flatpak binds the host's /tmp/.X11-unix/X<n> into the sandbox.
        assert!(!args.iter().any(|a| a.contains("PrivateTmp")));
        assert_eq!(
            launch_command_in("ruya-p1", app, &env(), DisplayMode::Wayland),
            launch_command("ruya-p1", app, &env())
        );
        assert!(launch_command_in("ruya-p1", "../x", &env(), DisplayMode::X11).is_err());
    }

    #[test]
    fn each_profile_user_gets_its_own_wayland_socket() {
        assert_eq!(
            wayland_display(WAYLAND_DIR, "ruya-p1").as_deref(),
            Some("/run/ruya-wayland/ruya-p1")
        );
        for bad in ["ruya-shell;x", "root", "ruya-", "ruya-../p1", "p1", ""] {
            assert_eq!(wayland_display(WAYLAND_DIR, bad), None, "{bad:?}");
        }
        let base = vec![
            ("SDL_VIDEODRIVER".to_owned(), "wayland".to_owned()),
            ("WAYLAND_DISPLAY".to_owned(), "wayland-0".to_owned()),
        ];
        let p1 = app_env(&base, Some(WAYLAND_DIR), "ruya-p1");
        assert_eq!(
            p1,
            [
                ("SDL_VIDEODRIVER".to_owned(), "wayland".to_owned()),
                (
                    "WAYLAND_DISPLAY".to_owned(),
                    "/run/ruya-wayland/ruya-p1".to_owned()
                ),
            ]
        );
        assert!(app_env(&base, Some(WAYLAND_DIR), "ruya-p2").contains(&(
            "WAYLAND_DISPLAY".to_owned(),
            "/run/ruya-wayland/ruya-p2".to_owned()
        )));
        // No socket directory (the development mode): the base is used as it is.
        assert_eq!(app_env(&base, None, "ruya-p1"), base);
        // The absolute path passes the argument check of the launch command.
        let args = launch_command("ruya-p1", "org.ruyaos.Racer", &p1).expect("valid");
        assert!(args.contains(&"--setenv=WAYLAND_DISPLAY=/run/ruya-wayland/ruya-p1".to_owned()));
    }

    #[test]
    fn an_app_gets_its_profiles_pulse_server() {
        assert_eq!(
            pulse_server(PULSE_DIR, "ruya-p1").as_deref(),
            Some("unix:/run/ruya-pulse/ruya-p1/native")
        );
        for bad in ["root", "ruya-", "ruya-p1/../p2", "p1", "ruya-P 1"] {
            assert_eq!(pulse_server(PULSE_DIR, bad), None, "{bad:?}");
        }
        let base = vec![("PULSE_SERVER".to_owned(), "unix:/tmp/other".to_owned())];
        let env = with_pulse_server(base, PULSE_DIR, "ruya-p2");
        assert_eq!(
            env,
            vec![(
                "PULSE_SERVER".to_owned(),
                "unix:/run/ruya-pulse/ruya-p2/native".to_owned()
            )]
        );
        // It passes the argument check of the launch command.
        let args = launch_command("ruya-p2", "org.ruyaos.Racer", &env).expect("valid");
        assert!(
            args.contains(&"--setenv=PULSE_SERVER=unix:/run/ruya-pulse/ruya-p2/native".to_owned())
        );
    }

    #[test]
    fn the_pulse_start_command_names_only_a_profile_users_instance() {
        let args = pulse_start_command("ruya-p1").expect("valid");
        assert_eq!(
            args.last().map(String::as_str),
            Some("ruya-pulse@ruya-p1.service")
        );
        assert!(args.contains(&"--machine=ruya-shell@.host".to_owned()));
        assert!(args.contains(&"start".to_owned()));
        for bad in ["root", "ruya-", "ruya-p1;x", "ruya-p1 x", "../ruya-p1"] {
            assert!(pulse_start_command(bad).is_err(), "{bad:?}");
        }
    }

    fn ids(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn park_audio_runs_ruya_devices_in_the_shells_manager_with_the_whole_state() {
        let args = park_audio_command(
            "ruya-p1",
            &ids(&["org.x.Game"]),
            &ids(&["org.x.Game", "org.y.Other"]),
        )
        .expect("valid");
        assert_eq!(args[0], "systemd-run");
        assert!(args.contains(&"--machine=ruya-shell@.host".to_owned()));
        assert!(args.contains(&"--wait".to_owned()));
        assert!(args
            .iter()
            .any(|a| a.starts_with("--property=RuntimeMaxSec=")));
        let tail = &args[args.iter().position(|a| a == "--").expect("--") + 1..];
        assert_eq!(
            tail,
            ids(&[
                DEVICES_PROGRAM,
                "--park-audio",
                "ruya-p1",
                "--frozen=org.x.Game",
                "--running=org.x.Game,org.y.Other"
            ])
        );
        let none = park_audio_command("ruya-p1", &[], &[]).expect("valid");
        assert!(none.ends_with(&ids(&["--frozen=", "--running="])));
        assert!(park_audio_command("root", &[], &[]).is_err());
        assert!(park_audio_command("ruya-p1", &ids(&["a;b"]), &[]).is_err());
        assert!(park_audio_command("ruya-p1", &[], &ids(&["--x"])).is_err());
    }

    #[test]
    fn a_reclaim_writes_each_cgroup_as_the_profile_user_and_names_only_its_cgroups() {
        let cg = "/user.slice/user-1001.slice/user@1001.service/app.slice/ruya-app-ruya-p1-org.x.Game.service";
        let scope = "/user.slice/user-1001.slice/user@1001.service/app.slice/app-flatpak-org.x.Game-42.scope";
        let args = reclaim_command(
            "ruya-p1",
            "org.x.Game",
            &[(100, cg.to_owned()), (2048, scope.to_owned())],
        )
        .expect("valid");
        assert!(args.contains(&"--machine=ruya-p1@.host".to_owned()));
        assert!(args.contains(&"--unit=ruya-reclaim-org.x.Game.service".to_owned()));
        let tail = &args[args.iter().position(|a| a == "--").expect("--") + 1..];
        assert_eq!(
            tail,
            [
                "/usr/bin/sh".to_owned(),
                "-c".to_owned(),
                RECLAIM_SCRIPT.to_owned(),
                "ruya-reclaim".to_owned(),
                "100".to_owned(),
                format!("/sys/fs/cgroup{cg}/memory.reclaim"),
                "2048".to_owned(),
                format!("/sys/fs/cgroup{scope}/memory.reclaim"),
            ]
        );
        for bad in [
            "/system.slice/ruya-session.service",
            "/user.slice/user-1001.slice/../../system.slice",
            "/user.slice/user-1001.slice/x;y",
            "user.slice/user-1001.slice/x",
        ] {
            assert!(
                reclaim_command("ruya-p1", "org.x.Game", &[(1, bad.to_owned())]).is_err(),
                "{bad:?}"
            );
        }
        assert!(reclaim_command("ruya-p1", "org.x.Game", &[]).is_err());
        assert!(reclaim_command("root", "org.x.Game", &[(1, cg.to_owned())]).is_err());
        assert!(cancel_reclaim_command("ruya-p1", "org.x.Game")
            .expect("valid")
            .ends_with(&ids(&[
                "stop",
                "--no-block",
                "ruya-reclaim-org.x.Game.service"
            ])));
    }

    #[test]
    fn half_of_the_charged_memory_is_asked_for() {
        assert_eq!(reclaim_amount(0), 0);
        assert_eq!(reclaim_amount(1_000_000_000), 500_000_000);
    }

    #[test]
    fn the_cgroups_of_the_units_are_read_from_systemctl_show() {
        let args = control_groups_command("ruya-p1", &ids(&["a.service", "app-flatpak-x-1.scope"]))
            .expect("valid");
        assert!(args.ends_with(&ids(&[
            "show",
            "-p",
            "ControlGroup",
            "--value",
            "a.service",
            "app-flatpak-x-1.scope"
        ])));
        assert!(control_groups_command("ruya-p1", &[]).is_err());
        assert!(control_groups_command("ruya-p1", &ids(&["a b"])).is_err());
        // A dash in the id is escaped in the scope's name (RUY-546): the backslash passes.
        let scopes = active_app_scopes(
            "org.x.Dash-App",
            "app-flatpak-org.x.Dash\\x2dApp-12.scope loaded active running x\n",
        );
        let mut units = ids(&["a.service"]);
        units.extend(scopes);
        let args = control_groups_command("ruya-p1", &units).expect("escaped scope name");
        assert!(args.ends_with(&ids(&[
            "a.service",
            "app-flatpak-org.x.Dash\\x2dApp-12.scope"
        ])));
        let text = "/user.slice/user-1001.slice/user@1001.service/app.slice/a.service\n\n\
                    /user.slice/user-1001.slice/user@1001.service/app.slice/b.scope\n\n\n\
                    /user.slice/user-1001.slice/user@1001.service/app.slice/a.service\n";
        assert_eq!(parse_control_groups(text).len(), 2);
        // A unit that is gone has an empty ControlGroup: nothing.
        assert!(parse_control_groups("\n\n").is_empty());
    }

    #[test]
    fn only_a_started_reclaim_is_stopped_by_the_thaw() {
        let ledger = ReclaimLedger::default();
        assert!(!ledger.take("app-a.service"), "never started: nothing to stop");
        ledger.started("app-a.service");
        assert!(!ledger.take("app-b.service"));
        assert!(ledger.take("app-a.service"));
        assert!(!ledger.take("app-a.service"), "taken once");
    }

    fn job(user: &str, frozen: &[&str]) -> AudioJob {
        (user.to_owned(), ids(frozen), ids(&["org.x.Game"]))
    }

    #[test]
    fn a_newer_sound_request_of_a_user_replaces_the_queued_one() {
        let mut q = AudioQueue::default();
        q.push(job("ruya-p1", &["org.x.Game"]));
        q.push(job("ruya-p2", &["org.x.Game"]));
        q.push(job("ruya-p1", &[]));
        assert_eq!(q.pop(), Some((job("ruya-p2", &["org.x.Game"]), 0)));
        assert_eq!(q.pop(), Some((job("ruya-p1", &[]), 0)));
        assert_eq!(q.pop(), None);
    }

    #[test]
    fn a_failed_sound_request_is_tried_three_times_in_all() {
        let mut q = AudioQueue::default();
        q.push(job("ruya-p1", &[]));
        let (first, tries) = q.pop().expect("queued");
        assert!(q.failed(first, tries));
        let (second, tries) = q.pop().expect("retry");
        assert_eq!(tries, 1);
        assert!(q.failed(second, tries));
        let (third, tries) = q.pop().expect("retry");
        assert_eq!(tries, 2);
        // The third failure is the last.
        assert!(!q.failed(third, tries));
        assert!(q.is_empty());
        assert_eq!(PARK_TRIES, 3);
    }

    #[test]
    fn a_retry_gives_way_to_a_newer_request_of_its_user() {
        // A newer request queued before the failure: no retry.
        let mut q = AudioQueue::default();
        q.push(job("ruya-p1", &[]));
        let (old, tries) = q.pop().expect("queued");
        q.push(job("ruya-p1", &["org.x.Game"]));
        assert!(!q.failed(old, tries));
        assert_eq!(q.pop(), Some((job("ruya-p1", &["org.x.Game"]), 0)));
        // A newer request after the retry was queued replaces it (and starts from try 0); another
        // user's request does not.
        q.push(job("ruya-p1", &[]));
        let (old, tries) = q.pop().expect("queued");
        assert!(q.failed(old.clone(), tries));
        q.push(job("ruya-p2", &[]));
        assert!(q.has("ruya-p1"));
        q.push(job("ruya-p1", &["org.x.Game"]));
        assert_eq!(q.pop(), Some((job("ruya-p2", &[]), 0)));
        assert_eq!(q.pop(), Some((job("ruya-p1", &["org.x.Game"]), 0)));
        assert!(!q.has("ruya-p1"));
    }

    #[test]
    fn swap_is_an_active_swap_unit() {
        assert!(any_swap(
            "dev-zram0.swap loaded active active Compressed Swap on /dev/zram0\n"
        ));
        assert!(!any_swap(""));
        assert!(!any_swap("\n"));
    }

    #[test]
    fn launch_command_refuses_anything_but_identifiers() {
        for app in [
            "org.ruyaos.Rac er",
            "x;y.z.w",
            "--help",
            "org.ruyaos.\"A\"",
            "",
        ] {
            assert!(launch_command("ruya-p1", app, &env()).is_err(), "{app:?}");
        }
        // Only the grammar is enforced here: the directory is what refuses "ruya-shell".
        for user in ["root", "ruya-", "ruya-p 1", "ruya-p1;id", "p1", ""] {
            assert!(
                launch_command(user, "org.ruyaos.Racer", &env()).is_err(),
                "{user:?}"
            );
        }
        for (k, v) in [
            ("wayland", "x"),
            ("A B", "x"),
            ("A", "x y"),
            ("A", "x;y"),
            ("A", "$HOME"),
            ("A", ""),
            ("1A", "x"),
        ] {
            let bad = vec![(k.to_owned(), v.to_owned())];
            assert!(
                launch_command("ruya-p1", "org.ruyaos.Racer", &bad).is_err(),
                "{k:?}={v:?}"
            );
        }
    }

    #[test]
    fn run_lines_as_systemd_run_prints_them() {
        let ended = |code, signaled| Some(RunLine::Ended { code, signaled });
        assert_eq!(
            parse_run_line(
                "Running as unit: a.service; invocation ID: 565dbc8a2c7b4b568f99fdbe17b4469f"
            ),
            Some(RunLine::Running)
        );
        assert_eq!(
            parse_run_line("Running as unit: a.service"),
            Some(RunLine::Running)
        );
        assert_eq!(
            parse_run_line("Main processes terminated with: code=exited, status=3/NOTIMPLEMENTED"),
            ended(3, false)
        );
        assert_eq!(
            parse_run_line("Main processes terminated with: code=exited, status=0/SUCCESS"),
            ended(0, false)
        );
        assert_eq!(
            parse_run_line("Main processes terminated with: code=killed, status=15/TERM"),
            ended(15, true)
        );
        assert_eq!(
            parse_run_line("Main processes terminated with: code=dumped, status=11/SEGV"),
            ended(11, true)
        );
        // The padding systemd-run puts in front, and a single process.
        assert_eq!(
            parse_run_line("  Main process terminated with: code=exited, status=1/FAILURE "),
            ended(1, false)
        );
        // 203 is the exec failure only under its own name; a bare 203 is an exit code like any.
        assert_eq!(
            parse_run_line("  Main process terminated with: code=exited, status=203/EXEC "),
            Some(RunLine::ExecFailed)
        );
        assert_eq!(
            parse_run_line("Main processes terminated with: code=exited, status=203/EXEC"),
            Some(RunLine::ExecFailed)
        );
        assert_eq!(
            parse_run_line("Main process terminated with: code=exited, status=203"),
            ended(203, false)
        );
        assert_eq!(
            parse_run_line("Main process terminated with: code=killed, status=203/EXEC"),
            ended(203, true)
        );
        for other in [
            "",
            "          Finished with result: exit-code",
            "            Service runtime: 1.034s",
            "Failed to start transient service unit: Remote peer disconnected",
            "Main processes terminated with: code=exited",
            "Main processes terminated with: code=weird, status=1/X",
            "Main processes terminated with: code=exited, status=x/FAIL",
        ] {
            assert_eq!(parse_run_line(other), None, "{other:?}");
        }
    }

    fn follow(lines: &[&str], code: i32, signaled: bool) -> Vec<UnitEvent> {
        let mut follower = RunFollower::new("u.service");
        let mut events: Vec<UnitEvent> = lines.iter().filter_map(|l| follower.line(l)).collect();
        events.push(follower.finish(code, signaled));
        events
    }

    fn started() -> UnitEvent {
        UnitEvent::Started {
            unit: "u.service".to_owned(),
        }
    }

    fn exited(code: i32, signaled: bool) -> UnitEvent {
        UnitEvent::Exited {
            unit: "u.service".to_owned(),
            code,
            signaled,
        }
    }

    #[test]
    fn follower_reports_the_exit_code_of_the_app() {
        let lines = [
            "Running as unit: u.service",
            "          Finished with result: exit-code",
            "Main processes terminated with: code=exited, status=3/NOTIMPLEMENTED",
        ];
        // systemd-run's own status (3 too, here) is not what decides.
        assert_eq!(follow(&lines, 99, false), [started(), exited(3, false)]);
    }

    #[test]
    fn follower_reports_a_signal() {
        let lines = [
            "Running as unit: u.service; invocation ID: 1",
            "Main processes terminated with: code=killed, status=9/KILL",
        ];
        assert_eq!(follow(&lines, 255, false), [started(), exited(9, true)]);
    }

    #[test]
    fn follower_never_started() {
        // The bus hop failed: no start line, systemd-run exits 1.
        let lines = ["Failed to start transient service unit: Remote peer disconnected"];
        assert_eq!(follow(&lines, 1, false), [exited(1, false)]);
        assert_eq!(follow(&[], 1, true), [exited(1, true)]);
    }

    #[test]
    fn follower_without_the_end_line_uses_the_exit_of_systemd_run() {
        let lines = ["Running as unit: u.service"];
        assert_eq!(follow(&lines, 15, true), [started(), exited(15, true)]);
    }

    #[test]
    fn follower_starts_once_and_keeps_the_first_end() {
        let lines = [
            "Running as unit: u.service",
            "Running as unit: u.service",
            "Main processes terminated with: code=exited, status=1/FAILURE",
            "Main processes terminated with: code=exited, status=2/INVALIDARGUMENT",
        ];
        assert_eq!(follow(&lines, 0, false), [started(), exited(1, false)]);
    }

    #[test]
    fn follower_reports_an_exec_failure_as_its_own_event() {
        let lines = [
            "Running as unit: u.service",
            "Main process terminated with: code=exited, status=203/EXEC",
        ];
        assert_eq!(
            follow(&lines, 203, false),
            [
                started(),
                UnitEvent::ExecFailed {
                    unit: "u.service".to_owned()
                }
            ]
        );
        // Any other non-zero status stays an exit code (the core calls it `crashed`).
        let lines = [
            "Running as unit: u.service",
            "Main process terminated with: code=exited, status=1/FAILURE",
        ];
        assert_eq!(follow(&lines, 1, false), [started(), exited(1, false)]);
    }

    #[test]
    fn the_app_id_comes_back_out_of_a_unit_name() {
        let unit = unit_name("ruya-p-1", "my-org.ruyaos.Racer");
        // The profile id and the app id both contain a dash: the user decides the split.
        assert_eq!(
            unit_app_id("ruya-p-1", &unit).as_deref(),
            Some("my-org.ruyaos.Racer")
        );
        assert_eq!(unit_app_id("ruya-p", &unit), None);
        for bad in [
            "ruya-app-ruya-p1-Racer.service",
            "ruya-app-ruya-p1-org.ruyaos.Racer.scope",
            "other-ruya-p1-org.ruyaos.Racer.service",
            "ruya-app-ruya-p1-org.ruyaos.Racer",
            "",
        ] {
            assert_eq!(unit_app_id("ruya-p1", bad), None, "{bad:?}");
        }
    }

    #[test]
    fn profile_users_out_of_loginctl() {
        let out = "  1000 ruya-shell yes active
  1002 ruya-p1    yes lingering
                   1003 ruya-guest no  active
    0 root      no  active
  1004 someone   no active

";
        assert_eq!(
            parse_profile_users(out),
            ["ruya-shell", "ruya-p1", "ruya-guest"]
        );
        assert!(parse_profile_users("").is_empty());
    }

    const SHOW_TWO: &str = "Id=ruya-app-ruya-p1-org.ruyaos.Racer.service
LoadState=loaded
ActiveState=active
ActiveEnterTimestamp=@1731000000
ExecMainStatus=0
ExecMainCode=0
FreezerState=frozen

Id=ruya-app-ruya-p1-org.ruyaos.Puzzle.service
LoadState=loaded
ActiveState=deactivating
ActiveEnterTimestamp=
ExecMainStatus=15
ExecMainCode=2
";

    #[test]
    fn systemctl_show_blocks_are_parsed() {
        let units = parse_show(SHOW_TWO);
        assert_eq!(units.len(), 2);
        assert_eq!(units[0].id, "ruya-app-ruya-p1-org.ruyaos.Racer.service");
        assert_eq!(units[0].entered, 1_731_000_000);
        assert_eq!(units[0].freezer_state, "frozen");
        assert_eq!(units[1].freezer_state, "");
        assert!(units[0].alive());
        assert_eq!(
            (
                units[1].entered,
                units[1].exec_main_status,
                units[1].exec_main_code
            ),
            (0, 15, 2)
        );
        assert!(units[1].alive(), "deactivating still runs");
        assert!(parse_show("").is_empty());
        assert!(parse_show(
            "

"
        )
        .is_empty());
        let gone = parse_show(
            "Id=x.service
LoadState=not-found
ActiveState=inactive
",
        );
        assert!(!gone[0].alive());
        let failed = parse_show(
            "Id=x.service
LoadState=loaded
ActiveState=failed
",
        );
        assert!(!failed[0].alive());
    }

    fn show(state: &str, status: i32, code: i32) -> ShowUnit {
        ShowUnit {
            id: "u.service".to_owned(),
            load_state: "loaded".to_owned(),
            active_state: state.to_owned(),
            entered: 0,
            exec_main_status: status,
            exec_main_code: code,
            cpu_nsec: None,
            freezer_state: String::new(),
        }
    }

    #[test]
    fn a_watched_unit_reports_its_end_once_with_the_last_status_seen() {
        let mut w = UnitWatch::new("u.service");
        assert_eq!(w.observe(&show("active", 0, 0)), None);
        assert_eq!(w.observe(&show("deactivating", 15, 2)), None);
        assert_eq!(w.observe(&show("inactive", 0, 0)), Some(exited(15, true)));
        let mut w = UnitWatch::new("u.service");
        w.observe(&show("active", 0, 0));
        assert_eq!(w.observe(&show("failed", 0, 0)), Some(exited(0, false)));
        let mut w = UnitWatch::new("u.service");
        w.observe(&show("active", 3, 1));
        assert_eq!(
            w.observe(&ShowUnit {
                load_state: "not-found".to_owned(),
                ..show("inactive", 0, 0)
            }),
            Some(exited(3, false))
        );
    }

    #[test]
    fn the_fake_lists_the_units_that_run_already() {
        let fake = FakeSpawner::new().with_running("ruya-p1", "org.ruyaos.Racer", 77);
        let found = fake.adopt_running();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].unit, unit_name("ruya-p1", "org.ruyaos.Racer"));
        assert_eq!((found[0].user.as_str(), found[0].started), ("ruya-p1", 77));
    }

    #[test]
    fn installed_means_a_current_link_in_the_system_installation() {
        let root = std::env::temp_dir().join(format!("ruya-session-fp-{}", std::process::id()));
        let app = "org.ruyaos.Racer";
        let _ = std::fs::remove_dir_all(&root);
        assert!(!flatpak_app_installed(&root, app));
        // Half-removed: the directory without its `current`.
        std::fs::create_dir_all(root.join("app").join(app)).expect("mkdir");
        assert!(!flatpak_app_installed(&root, app));
        std::fs::create_dir_all(root.join("app").join(app).join("current")).expect("mkdir");
        assert!(flatpak_app_installed(&root, app));
        assert!(!flatpak_app_installed(&root, "org.ruyaos.Puzzle"));
        // Never a path out of the installation, whatever the caller passes.
        assert!(!flatpak_app_installed(&root, "../../x"));
        assert!(!flatpak_app_installed(&root, "org.ruyaos.Racer/../.."));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn scope_pattern_for_flatpak_runs() {
        assert_eq!(
            scope_pattern("org.ruyaos.Racer").as_deref(),
            Ok("app-flatpak-org.ruyaos.Racer-*.scope")
        );
        for bad in [
            "",
            "x",
            "org.ruyaos.*",
            "org.ruyaos.[a]",
            "a.b.c?",
            "a.b.c d",
        ] {
            assert!(scope_pattern(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn scope_names_use_systemd_escaping_for_a_dash_in_the_id() {
        let id = "page.codeberg.jaerrib.attack-vector-alpha";
        let scope =
            "app-flatpak-page.codeberg.jaerrib.attack\\x2dvector\\x2dalpha-2797448864.scope";
        assert_eq!(
            unit_escape(id),
            "page.codeberg.jaerrib.attack\\x2dvector\\x2dalpha"
        );
        assert!(is_app_scope(id, scope));
        // The unescaped form is not what systemd writes; near misses stay false.
        assert!(!is_app_scope(
            id,
            "app-flatpak-page.codeberg.jaerrib.attack-vector-alpha-1.scope"
        ));
        assert!(!is_app_scope(
            id,
            "app-flatpak-page.codeberg.jaerrib.attack\\x2dvector-1.scope"
        ));
        assert!(!is_app_scope(
            id,
            "app-flatpak-page.codeberg.jaerrib.attack\\x2dvector\\x2dalpha\\x2dextra-1.scope"
        ));
        assert!(!is_app_scope("page.codeberg.jaerrib.attack", scope));
        assert_eq!(
            scope_pattern(id).as_deref(),
            Ok("app-flatpak-page.codeberg.jaerrib.attack?x2dvector?x2dalpha-*.scope")
        );
    }

    #[test]
    fn sweep_stops_every_scope_of_the_app_and_clears_failed_ones() {
        let base = [
            "systemctl",
            "--user",
            "--no-pager",
            "--machine=ruya-p1@.host",
        ];
        let app = "com.binarynonsense.acbr";
        let scopes = [
            "app-flatpak-com.binarynonsense.acbr-1808253546.scope".to_owned(),
            "app-flatpak-com.binarynonsense.acbr-2927365367.scope".to_owned(),
        ];
        let commands = sweep_commands("ruya-p1", app, &scopes).expect("sweep");
        let mut stop: Vec<&str> = base.to_vec();
        stop.extend(["stop", "--no-block", &scopes[0], &scopes[1]]);
        let mut reset: Vec<&str> = base.to_vec();
        reset.extend(["reset-failed", &scopes[0], &scopes[1]]);
        assert_eq!(commands, [stop, reset]);
        // Nothing left: nothing to run.
        assert!(sweep_commands("ruya-p1", app, &[])
            .expect("empty")
            .is_empty());
        assert!(sweep_commands("root", app, &scopes).is_err());
        assert!(sweep_commands("ruya-p1", "org.ruyaos.*", &[]).is_err());
        // Never a glob or another app's scope.
        let glob = ["app-flatpak-com.binarynonsense.acbr-*.scope".to_owned()];
        assert!(sweep_commands("ruya-p1", app, &glob).is_err());
    }

    #[test]
    fn a_sibling_app_whose_id_extends_ours_is_never_named() {
        // T-435 review: the glob app-flatpak-io.github.Foo-*.scope also matches the scopes of
        // io.github.Foo-bar.App; Stop, the kill and the sweep of io.github.Foo must not reach it.
        let app = "io.github.Foo";
        let listing = "app-flatpak-io.github.Foo-12.scope loaded active running app-flatpak-io.github.Foo-12.scope
app-flatpak-io.github.Foo-bar.App-34.scope loaded active running app-flatpak-io.github.Foo-bar.App-34.scope
app-flatpak-io.github.Foo-Extra-56.scope loaded failed failed app-flatpak-io.github.Foo-Extra-56.scope
* app-flatpak-io.github.Foo-78.scope loaded failed failed app-flatpak-io.github.Foo-78.scope
";
        let list = list_scopes_command("ruya-p1", app).expect("list");
        assert_eq!(
            list,
            [
                "systemctl",
                "--user",
                "--no-pager",
                "--machine=ruya-p1@.host",
                "list-units",
                "--all",
                "--plain",
                "--no-legend",
                "app-flatpak-io.github.Foo-*.scope",
            ]
        );
        let ours = app_scopes(app, listing);
        assert_eq!(
            ours,
            [
                "app-flatpak-io.github.Foo-12.scope",
                "app-flatpak-io.github.Foo-78.scope"
            ]
        );
        let unit = unit_name("ruya-p1", app);
        let stop =
            control_command("ruya-p1", &["stop", "--no-block"], &unit, app, &ours).expect("stop");
        let sweep = sweep_commands("ruya-p1", app, &ours).expect("sweep");
        for args in std::iter::once(&stop).chain(sweep.iter()) {
            assert!(
                !args
                    .iter()
                    .any(|a| a.contains("Foo-bar") || a.contains("Foo-Extra") || a.contains('*')),
                "{args:?}"
            );
        }
        assert_eq!(&stop[stop.len() - 3..], [unit.as_str(), &ours[0], &ours[1]]);
        // The sibling's scope is refused if it is handed in anyway.
        let sibling = ["app-flatpak-io.github.Foo-bar.App-34.scope".to_owned()];
        assert!(control_command("ruya-p1", &["stop"], &unit, app, &sibling).is_err());
        assert!(sweep_commands("ruya-p1", app, &sibling).is_err());
    }

    #[test]
    fn freeze_and_thaw_name_every_active_scope_of_the_app_and_no_sibling() {
        // T-457: an Electron app has two scopes (T-435), both are frozen; a sibling app whose id
        // extends ours, and a failed scope of ours (systemd refuses to freeze an inactive unit),
        // are never named.
        let app = "io.github.Foo";
        let listing = "app-flatpak-io.github.Foo-12.scope loaded active running app-flatpak-io.github.Foo-12.scope
app-flatpak-io.github.Foo-bar.App-34.scope loaded active running app-flatpak-io.github.Foo-bar.App-34.scope
app-flatpak-io.github.Foo-56.scope loaded active running app-flatpak-io.github.Foo-56.scope
* app-flatpak-io.github.Foo-78.scope loaded failed failed app-flatpak-io.github.Foo-78.scope
\u{25cf} app-flatpak-io.github.Foo-90.scope loaded active running app-flatpak-io.github.Foo-90.scope
";
        let ours = active_app_scopes(app, listing);
        assert_eq!(
            ours,
            [
                "app-flatpak-io.github.Foo-12.scope",
                "app-flatpak-io.github.Foo-56.scope",
                "app-flatpak-io.github.Foo-90.scope"
            ]
        );
        let unit = unit_name("ruya-p1", app);
        for verb in ["freeze", "thaw"] {
            let args = control_command("ruya-p1", &[verb], &unit, app, &ours).expect(verb);
            assert_eq!(
                args,
                [
                    "systemctl",
                    "--user",
                    "--no-pager",
                    "--machine=ruya-p1@.host",
                    verb,
                    unit.as_str(),
                    &ours[0],
                    &ours[1],
                    &ours[2],
                ]
            );
            assert!(
                !args
                    .iter()
                    .any(|a| a.contains("Foo-bar") || a.contains("Foo-78") || a.contains('*')),
                "{args:?}"
            );
        }
        // Nothing active: only the unit itself.
        assert!(active_app_scopes(app, "").is_empty());
    }

    #[test]
    fn console_apps_are_told_it_is_a_wayland_session() {
        // T-435: Electron (ACBR) picks X11 without XDG_SESSION_TYPE and exits ("Missing X
        // server or $DISPLAY"); there is no X server on the console.
        let env = console_env();
        for (key, value) in [
            ("SDL_VIDEODRIVER", "wayland"),
            ("XDG_SESSION_TYPE", "wayland"),
        ] {
            assert!(
                env.contains(&(key.to_owned(), value.to_owned())),
                "{key}={value} missing"
            );
        }
        let args = launch_command("ruya-p1", "com.binarynonsense.acbr", &env).expect("launch");
        assert!(args.contains(&"--setenv=XDG_SESSION_TYPE=wayland".to_owned()));
    }

    #[test]
    fn line_tail_returns_complete_lines_only() {
        use std::io::Write;
        let path = std::env::temp_dir().join(format!("ruya-session-tail-{}", std::process::id()));
        let mut out = File::create(&path).expect("create");
        let mut tail = LineTail::open(&path).expect("open");
        assert!(tail.poll().is_empty());
        write!(out, "Running as unit: a\nMain proc").expect("write");
        assert_eq!(tail.poll(), ["Running as unit: a"]);
        assert!(tail.poll().is_empty());
        writeln!(out, "esses terminated with: code=exited, status=0/SUCCESS").expect("write");
        write!(out, "\nlast").expect("write");
        assert_eq!(
            tail.poll(),
            [
                "Main processes terminated with: code=exited, status=0/SUCCESS",
                ""
            ]
        );
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn fake_emits_events_and_records_calls() {
        let (tx, rx) = async_channel::unbounded();
        let fake = FakeSpawner::new()
            .with_app("org.ruyaos.Racer")
            .with_events(tx);
        assert!(fake.is_installed("org.ruyaos.Racer"));
        assert!(!fake.is_installed("org.ruyaos.Puzzle"));
        let unit = fake
            .start("ruya-p1", "org.ruyaos.Racer", &[])
            .expect("start");
        fake.stop(&unit).expect("stop");
        assert_eq!(
            rx.try_recv().ok(),
            Some(UnitEvent::Started { unit: unit.clone() })
        );
        assert_eq!(
            rx.try_recv().ok(),
            Some(UnitEvent::Exited {
                unit,
                code: 0,
                signaled: false
            })
        );
        assert_eq!(fake.calls().len(), 2);
    }
}
