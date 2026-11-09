//! Starting and stopping app units. The trait is the only door to the OS; the fake serves tests
//! and `--session`, `systemd::SystemdSpawner` (Linux) is the real one. The pure parts of the real
//! one live here and are tested on every host: the `systemd-run` argument list
//! (`launch_command`), the reading of its output (`parse_run_line`) and the unit events made from
//! it (`RunFollower`).

use std::collections::HashSet;
use std::fs::File;
use std::io::Read;
use std::path::Path;
use std::sync::Mutex;

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
}

impl<T: Spawner + ?Sized> Spawner for Box<T> {
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
/// checked again: only `[A-Za-z0-9_.-]` can be in it, so the only glob character is the `*`.
pub fn scope_pattern(app_id: &str) -> Result<String, String> {
    if !valid_app_id(app_id) {
        return Err(format!("not an application id: {app_id:?}"));
    }
    Ok(format!("app-flatpak-{app_id}-*.scope"))
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
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | '/'));
        if !key_ok || !value_ok {
            return Err(format!("bad environment entry: {key:?}"));
        }
        args.push(format!("--setenv={key}={value}"));
    }
    args.extend(["--", "flatpak", "run"].map(str::to_owned));
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
}

impl ShowUnit {
    /// Is it still a unit with a running (or starting, or stopping) program?
    pub fn alive(&self) -> bool {
        self.load_state != "not-found"
            && !matches!(self.active_state.as_str(), "inactive" | "failed" | "")
    }
}

/// The `-p` arguments of the `systemctl show` call that `parse_show` reads.
pub const SHOW_PROPERTIES: [&str; 6] = [
    "Id",
    "LoadState",
    "ActiveState",
    "ActiveEnterTimestamp",
    "ExecMainStatus",
    "ExecMainCode",
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
            _ => {}
        }
    }
    units
}

/// Follows a unit this service did not start (it has no `systemd-run --wait` to tell its end):
/// fed with what `systemctl show` said about it about every two seconds, it reports the end once.
/// The exit status is the last one seen while the unit was alive: a `--collect`ed unit is gone
/// the moment it ends, so for an app that dies on its own this is mostly 0.
pub struct UnitWatch {
    unit: String,
    code: i32,
    signaled: bool,
    misses: u32,
}

/// Consecutive failed `systemctl` calls after which the unit counts as gone (the manager that
/// ran it is gone, for instance when its profile was deleted).
const WATCH_MAX_MISSES: u32 = 5;

impl UnitWatch {
    pub fn new(unit: &str) -> Self {
        UnitWatch {
            unit: unit.to_owned(),
            code: 0,
            signaled: false,
            misses: 0,
        }
    }

    /// `seen` is the unit's `show` block, or `None` when `systemctl` failed.
    pub fn observe(&mut self, seen: Option<&ShowUnit>) -> Option<UnitEvent> {
        match seen {
            Some(show) if show.alive() => {
                self.misses = 0;
                if show.exec_main_code != 0 {
                    self.code = show.exec_main_status;
                    self.signaled = matches!(show.exec_main_code, 2 | 3);
                }
                None
            }
            Some(_) => Some(self.ended()),
            None => {
                self.misses += 1;
                (self.misses >= WATCH_MAX_MISSES).then(|| self.ended())
            }
        }
    }

    fn ended(&self) -> UnitEvent {
        UnitEvent::Exited {
            unit: self.unit.clone(),
            code: self.code,
            signaled: self.signaled,
        }
    }
}

/// For tests and `--session`. Records the calls; with an event channel it behaves like a quick
/// OS: `start` is followed by `Started`, `stop` by a normal exit, `kill` by a signal exit.
#[derive(Default)]
pub struct FakeSpawner {
    state: Mutex<FakeState>,
    events: Option<Sender<UnitEvent>>,
}

#[derive(Default)]
struct FakeState {
    installed: HashSet<String>,
    fail_start: bool,
    calls: Vec<String>,
    running: Vec<RunningUnit>,
    last_env: Vec<(String, String)>,
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
        });
        self
    }

    pub fn failing_start(self) -> Self {
        self.lock().fail_start = true;
        self
    }

    /// "start user app", "stop unit", "kill unit", in order.
    pub fn calls(&self) -> Vec<String> {
        self.lock().calls.clone()
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
}

#[cfg(test)]
mod tests {
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
        }
    }

    #[test]
    fn a_watched_unit_reports_its_end_once_with_the_last_status_seen() {
        let mut w = UnitWatch::new("u.service");
        assert_eq!(w.observe(Some(&show("active", 0, 0))), None);
        assert_eq!(w.observe(Some(&show("deactivating", 15, 2))), None);
        assert_eq!(
            w.observe(Some(&show("inactive", 0, 0))),
            Some(exited(15, true))
        );
        let mut w = UnitWatch::new("u.service");
        w.observe(Some(&show("active", 0, 0)));
        assert_eq!(
            w.observe(Some(&show("failed", 0, 0))),
            Some(exited(0, false))
        );
        let mut w = UnitWatch::new("u.service");
        w.observe(Some(&show("active", 3, 1)));
        assert_eq!(
            w.observe(Some(&ShowUnit {
                load_state: "not-found".to_owned(),
                ..show("inactive", 0, 0)
            })),
            Some(exited(3, false))
        );
    }

    #[test]
    fn a_manager_that_stays_unreachable_ends_the_watch() {
        let mut w = UnitWatch::new("u.service");
        for _ in 0..WATCH_MAX_MISSES - 1 {
            assert_eq!(w.observe(None), None);
        }
        // One good answer in between starts the count again.
        assert_eq!(w.observe(Some(&show("active", 0, 0))), None);
        for _ in 0..WATCH_MAX_MISSES - 1 {
            assert_eq!(w.observe(None), None);
        }
        assert_eq!(w.observe(None), Some(exited(0, false)));
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
