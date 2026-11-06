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
    Ended { code: i32, signaled: bool },
}

pub fn parse_run_line(line: &str) -> Option<RunLine> {
    let line = line.trim();
    if line.starts_with("Running as unit:") {
        return Some(RunLine::Running);
    }
    let rest = line.strip_prefix("Main process")?;
    let rest = rest.split_once("terminated with:")?.1;
    let mut code_kind = None;
    let mut status = None;
    for part in rest.split(',') {
        let part = part.trim();
        if let Some(kind) = part.strip_prefix("code=") {
            code_kind = Some(kind.trim());
        } else if let Some(num) = part.strip_prefix("status=") {
            // "3/NOTIMPLEMENTED": the number comes first.
            status = num.split('/').next().and_then(|n| n.trim().parse().ok());
        }
    }
    let code = status?;
    match code_kind? {
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
}

impl RunFollower {
    pub fn new(unit: &str) -> Self {
        RunFollower {
            unit: unit.to_owned(),
            started: false,
            ended: None,
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
        }
    }

    /// `systemd-run` ended: with this exit code, or (`signaled`) killed by this signal.
    pub fn finish(self, code: i32, signaled: bool) -> UnitEvent {
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

    pub fn failing_start(self) -> Self {
        self.lock().fail_start = true;
        self
    }

    /// "start user app", "stop unit", "kill unit", in order.
    pub fn calls(&self) -> Vec<String> {
        self.lock().calls.clone()
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

    fn start(&self, user: &str, app_id: &str, _env: &[(String, String)]) -> Result<String, String> {
        let mut state = self.lock();
        state.calls.push(format!("start {user} {app_id}"));
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
}

#[cfg(test)]
mod tests {
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
            parse_run_line("  Main process terminated with: code=exited, status=203/EXEC "),
            ended(203, false)
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
