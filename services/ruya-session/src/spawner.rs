//! Starting and stopping app units. The trait is the only door to the OS; the fake serves tests
//! and `--session`. The real spawner is not written yet: `launch_command` is the pure part of it
//! (the exact `systemd-run` argument list), tested here and executed by a later task.

use std::collections::HashSet;
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

/// The argument list that starts `flatpak run <app_id>` as `user` in that user's systemd manager.
/// Pure: nothing is executed. Every value is validated again here (the core has checked them
/// already), so the list holds only plain identifiers, and the application id comes after `--`
/// so it can never be read as an option.
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
        "--quiet",
        "--collect",
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
                "--quiet",
                "--collect",
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
