//! The real spawner (Linux): every app is one transient service in the profile user's systemd
//! manager, started with `systemd-run --machine=<user>@.host --wait` (`spawner::launch_command`).
//! That process lives as long as the app and prints its start and end, which `RunFollower` turns
//! into `UnitEvent`s; `Stop` and the kill go to the same unit through `systemctl --machine=`.
//!
//! Why this and not the manager's D-Bus API: `--machine=<user>@.host` is the supported way for
//! root to reach another user's manager (it needs no access to `/run/user/<uid>`), and
//! `--wait` hands over the unit's end, which the manager forgets the moment a `--collect`ed unit
//! ends. The cost is one small process per running app.
//!
//! A profile user's manager has to outlive the session that `systemd-run` opens for its call
//! (logind stops an idle manager after ten seconds, taking the app with it), so the account is
//! made to linger before its first launch (`loginctl enable-linger`, idempotent). `ruya-profiles`
//! ends the manager and the linger when it deletes the profile.
//!
//! A restart of this service leaves the apps running (they belong to the users' managers), but
//! ends the `systemd-run --wait` processes that told us when they ended. `adopt_running` finds the
//! `ruya-app-*` units again and follows each with a poll of `systemctl show` (`UnitWatch`).

use std::collections::HashMap;
use std::fs::File;
use std::os::unix::process::ExitStatusExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_channel::Sender;

use crate::spawner::{
    flatpak_app_installed, launch_command, parse_profile_users, parse_show, scope_pattern,
    unit_app_id, unit_name, LineTail, RunFollower, RunningUnit, ShowUnit, UnitWatch,
    SHOW_PROPERTIES,
};
use crate::spawner::{Spawner, UnitEvent};

const FLATPAK_ROOT: &str = "/var/lib/flatpak";
/// `RuntimeDirectory=ruya-session` of the unit: where each app's `systemd-run` writes its status.
const LOG_DIR: &str = "/run/ruya-session";
/// How often the status file of a running `systemd-run` is read.
const POLL: Duration = Duration::from_millis(100);
/// How often an adopted unit is looked at.
const WATCH_POLL: Duration = Duration::from_secs(2);

pub struct SystemdSpawner {
    flatpak_root: PathBuf,
    log_dir: PathBuf,
    events: Sender<UnitEvent>,
    /// unit -> (Unix user, app id), for the units that run: `Stop` and the kill need the user's
    /// manager and the app's scope.
    units: Arc<Mutex<HashMap<String, (String, String)>>>,
}

impl SystemdSpawner {
    pub fn new(events: Sender<UnitEvent>) -> Self {
        SystemdSpawner {
            flatpak_root: PathBuf::from(FLATPAK_ROOT),
            log_dir: PathBuf::from(LOG_DIR),
            events,
            units: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn owner_of(&self, unit: &str) -> Result<(String, String), String> {
        self.units
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(unit)
            .cloned()
            .ok_or_else(|| format!("no running unit {unit}"))
    }

    /// `systemctl --user --machine=<user>@.host <verb>... <unit> <scope pattern>` on its own
    /// thread: it talks to the bus and must not hold up a D-Bus call. Its failure is logged; the
    /// unit's end (or the kill after the grace time) is what the core acts on. The scope is the
    /// app itself (see `scope_pattern`); the unit is its `flatpak run` front end.
    fn systemctl(&self, unit: &str, verb: &[&str]) -> Result<(), String> {
        let (user, app_id) = self.owner_of(unit)?;
        let scope = scope_pattern(&app_id)?;
        let mut cmd = Command::new("systemctl");
        cmd.args(["--user", "--no-pager"])
            .arg(format!("--machine={user}@.host"))
            .args(verb)
            .arg(unit)
            .arg(&scope)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());
        let what = format!("systemctl {} {unit}", verb.join(" "));
        let spawned = std::thread::Builder::new()
            .name("systemctl".to_owned())
            .spawn(move || match cmd.status() {
                Ok(status) if status.success() => {}
                Ok(status) => eprintln!("ruya-session: {what} failed: {status}"),
                Err(err) => eprintln!("ruya-session: {what}: {err}"),
            });
        spawned
            .map(|_| ())
            .map_err(|err| format!("cannot start a thread for {unit}: {err}"))
    }
}

impl Spawner for SystemdSpawner {
    fn is_installed(&self, app_id: &str) -> bool {
        flatpak_app_installed(&self.flatpak_root, app_id)
    }

    fn start(&self, user: &str, app_id: &str, env: &[(String, String)]) -> Result<String, String> {
        let args = launch_command(user, app_id, env)?;
        let unit = unit_name(user, app_id);
        self.units
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(unit.clone(), (user.to_owned(), app_id.to_owned()));
        let job = Job {
            args,
            user: user.to_owned(),
            unit: unit.clone(),
            log_dir: self.log_dir.clone(),
            events: self.events.clone(),
            units: self.units.clone(),
        };
        std::thread::Builder::new()
            .name("systemd-run".to_owned())
            .spawn(move || job.run())
            .map_err(|err| {
                self.units
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .remove(&unit);
                format!("cannot start a thread: {err}")
            })?;
        Ok(unit)
    }

    fn stop(&self, unit: &str) -> Result<(), String> {
        self.systemctl(unit, &["stop", "--no-block"])
    }

    fn kill(&self, unit: &str) -> Result<(), String> {
        self.systemctl(unit, &["kill", "--signal=SIGKILL", "--kill-whom=all"])
    }

    fn adopt_running(&self) -> Vec<RunningUnit> {
        let users = Command::new("loginctl")
            .args(["list-users", "--no-legend", "--no-pager"])
            .stdin(Stdio::null())
            .stderr(Stdio::inherit())
            .output()
            .ok()
            .filter(|out| out.status.success())
            .map(|out| parse_profile_users(&String::from_utf8_lossy(&out.stdout)))
            .unwrap_or_else(|| {
                eprintln!("ruya-session: loginctl list-users failed: no app is adopted");
                Vec::new()
            });
        let mut found = Vec::new();
        for user in users {
            let Some(text) = show_units(&user, "ruya-app-*.service") else {
                eprintln!("ruya-session: cannot list the apps of {user}");
                continue;
            };
            for show in parse_show(&text).into_iter().filter(ShowUnit::alive) {
                let Some(app_id) = unit_app_id(&user, &show.id) else {
                    continue;
                };
                self.units
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(show.id.clone(), (user.clone(), app_id.clone()));
                let watcher = Watcher {
                    user: user.clone(),
                    unit: show.id.clone(),
                    events: self.events.clone(),
                    units: self.units.clone(),
                };
                let spawned = std::thread::Builder::new()
                    .name("watch".to_owned())
                    .spawn(move || watcher.run());
                if let Err(err) = spawned {
                    eprintln!("ruya-session: cannot watch {}: {err}", show.id);
                    self.units
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .remove(&show.id);
                    continue;
                }
                eprintln!("ruya-session: adopted {}", show.id);
                found.push(RunningUnit {
                    unit: show.id,
                    user: user.clone(),
                    app_id,
                    started: show.entered,
                });
            }
        }
        found
    }
}

/// `systemctl --user -M <user>@.host show` of the units matching `pattern`, or `None` when the
/// call failed. Times come as `@<unix seconds>`.
fn show_units(user: &str, pattern: &str) -> Option<String> {
    let mut cmd = Command::new("systemctl");
    cmd.args(["--user", "--no-pager", "--timestamp=unix"])
        .arg(format!("--machine={user}@.host"))
        .arg("show");
    for property in SHOW_PROPERTIES {
        cmd.arg(format!("--property={property}"));
    }
    let out = cmd
        .arg(pattern)
        .stdin(Stdio::null())
        .stderr(Stdio::inherit())
        .output()
        .ok()
        .filter(|out| out.status.success())?;
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Follows one adopted unit until it ends, on its own thread.
struct Watcher {
    user: String,
    unit: String,
    events: Sender<UnitEvent>,
    units: Arc<Mutex<HashMap<String, (String, String)>>>,
}

impl Watcher {
    fn run(self) {
        let mut watch = UnitWatch::new(&self.unit);
        loop {
            std::thread::sleep(WATCH_POLL);
            let seen = show_units(&self.user, &self.unit)
                .and_then(|text| parse_show(&text).into_iter().next());
            if let Some(event) = watch.observe(seen.as_ref()) {
                self.units
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .remove(&self.unit);
                let _ = self.events.send_blocking(event);
                return;
            }
        }
    }
}

/// One app's `systemd-run --wait`, on its own thread.
struct Job {
    args: Vec<String>,
    user: String,
    unit: String,
    log_dir: PathBuf,
    events: Sender<UnitEvent>,
    units: Arc<Mutex<HashMap<String, (String, String)>>>,
}

impl Job {
    fn run(self) {
        ensure_manager(&self.user);
        let (code, signaled, follower) = self.follow();
        let event = follower.finish(code, signaled);
        // The unit is gone for the registry too: forget its user before the core hears of it.
        self.units
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.unit);
        let _ = self.events.send_blocking(event);
    }

    /// Runs `systemd-run`, forwards the events its lines make, returns how it ended.
    ///
    /// Its stderr is a file in the service's runtime directory, not a pipe: `systemd-run
    /// --machine=` hands its stderr on to PID 1 (for the helper it starts in the user's login),
    /// and SELinux does not let PID 1 write to a pipe of this service, which ends the call with
    /// "Connection reset by peer" (VM, T-162). A file in `/run` is fine. Stdout and stdin are
    /// /dev/null. The file is read about ten times a second until the process has ended.
    fn follow(&self) -> (i32, bool, RunFollower) {
        let mut follower = RunFollower::new(&self.unit);
        let Some((program, rest)) = self.args.split_first() else {
            return (1, false, follower);
        };
        let log_path = self.log_dir.join(format!("{}.log", self.unit));
        let opened = std::fs::create_dir_all(&self.log_dir)
            .and_then(|()| File::create(&log_path))
            .and_then(|log| LineTail::open(&log_path).map(|tail| (log, tail)));
        let (log, mut tail) = match opened {
            Ok(pair) => pair,
            Err(err) => {
                eprintln!("ruya-session: {}: no status file: {err}", self.unit);
                return (1, false, follower);
            }
        };
        let spawned = Command::new(program)
            .args(rest)
            .env("LC_ALL", "C")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::from(log))
            .spawn();
        let mut child = match spawned {
            Ok(child) => child,
            Err(err) => {
                eprintln!("ruya-session: {}: cannot run {program}: {err}", self.unit);
                let _ = std::fs::remove_file(&log_path);
                return (1, false, follower);
            }
        };
        let status = loop {
            let done = match child.try_wait() {
                Ok(done) => done,
                Err(err) => {
                    eprintln!("ruya-session: {}: waiting failed: {err}", self.unit);
                    break None;
                }
            };
            // Read after the exit was seen: what it wrote last is still in the file.
            for line in tail.poll() {
                eprintln!("ruya-session: {}: {line}", self.unit);
                if let Some(event) = follower.line(&line) {
                    let _ = self.events.send_blocking(event);
                }
            }
            if done.is_some() {
                break done;
            }
            std::thread::sleep(POLL);
        };
        let _ = std::fs::remove_file(&log_path);
        match status {
            Some(status) => match status.signal() {
                Some(signal) => (signal, true, follower),
                None => (status.code().unwrap_or(1), false, follower),
            },
            None => (1, false, follower),
        }
    }
}

/// Runs a helper to its end with stdout on /dev/null and stderr in the journal; a failure is
/// logged and returned as `false`.
fn run_quiet(program: &str, args: &[&str]) -> bool {
    match Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .status()
    {
        Ok(status) if status.success() => true,
        Ok(status) => {
            eprintln!("ruya-session: {program} {}: {status}", args.join(" "));
            false
        }
        Err(err) => {
            eprintln!("ruya-session: {program} {}: {err}", args.join(" "));
            false
        }
    }
}

/// Keeps the profile user's manager alive without a login session, and has it running when this
/// returns. Idempotent and cheap; a failure is logged and the launch goes on.
///
/// The order matters (VM, T-162): `enable-linger` makes logind start the manager in the
/// background, and a `systemd-run --machine=` call that arrives meanwhile opens a session of its
/// own for the same manager; the two starts then wait for each other until the 45 s start
/// timeout. `systemctl start` joins the start that is under way and returns once it is done.
fn ensure_manager(user: &str) {
    run_quiet("loginctl", &["enable-linger", user]);
    let uid = Command::new("id")
        .args(["-u", user])
        .stdin(Stdio::null())
        .stderr(Stdio::inherit())
        .output()
        .ok()
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit()));
    match uid {
        Some(uid) => {
            run_quiet("systemctl", &["start", &format!("user@{uid}.service")]);
        }
        None => eprintln!("ruya-session: no uid for {user}"),
    }
}
