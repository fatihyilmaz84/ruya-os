//! Session core: the registry of running app instances and its state machine. All rules live
//! here; the OS is reached through `Spawner` and `ProfileDirectory`, time is passed in. Events
//! from the OS come in through `on_event` and leave as `Notice`s for the adapter to emit.
//!
//! An instance goes `starting -> running -> stopping`, and `exited` is the end: an exited
//! instance is reported once (a `Notice::Exited`) and removed, so it never shows in `list`.

use std::time::{Duration, Instant};

use crate::directory::ProfileDirectory;
use crate::spawner::{valid_app_id, valid_profile_id, Spawner, UnitEvent};

/// After `Stop`, the app has this long to quit before it is killed.
pub const STOP_GRACE: Duration = Duration::from_secs(5);

/// The status strings of `org.ruyaos.Session1` (stable API).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    UnknownApp,
    UnknownProfile,
    AlreadyRunning,
    UnknownInstance,
    Invalid,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::UnknownApp => "unknown-app",
            Status::UnknownProfile => "unknown-profile",
            Status::AlreadyRunning => "already-running",
            Status::UnknownInstance => "unknown-instance",
            Status::Invalid => "invalid",
            Status::Failed => "failed",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Starting,
    Running,
    Stopping,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Starting => "starting",
            State::Running => "running",
            State::Stopping => "stopping",
        }
    }
}

/// Why an instance ended (the `reason` of `AppExited`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExitReason {
    Quit,
    Crashed,
    Killed,
    LaunchFailed,
}

impl ExitReason {
    pub fn as_str(self) -> &'static str {
        match self {
            ExitReason::Quit => "quit",
            ExitReason::Crashed => "crashed",
            ExitReason::Killed => "killed",
            ExitReason::LaunchFailed => "launch-failed",
        }
    }
}

/// A signal for the adapter to send.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Notice {
    Started {
        instance: String,
        app_id: String,
    },
    Exited {
        instance: String,
        app_id: String,
        exit_code: i32,
        reason: ExitReason,
    },
}

/// One entry of `ListRunning`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunningApp {
    pub instance: String,
    pub app_id: String,
    pub profile: String,
    pub started: i64,
    pub state: State,
}

#[derive(Debug)]
struct Instance {
    unit: String,
    app_id: String,
    profile: String,
    started: i64,
    state: State,
    /// Did the app ever get to `running`? Decides `launch-failed`.
    reached_running: bool,
    stop_asked: Option<Instant>,
    kill_sent: bool,
}

pub struct Session<S, D> {
    spawner: S,
    directory: D,
    env: Vec<(String, String)>,
    instances: Vec<Instance>,
}

impl<S: Spawner, D: ProfileDirectory> Session<S, D> {
    /// `env` is handed to every app (for instance `WAYLAND_DISPLAY`).
    pub fn new(spawner: S, directory: D, env: Vec<(String, String)>) -> Self {
        Session {
            spawner,
            directory,
            env,
            instances: Vec::new(),
        }
    }

    pub fn directory_mut(&mut self) -> &mut D {
        &mut self.directory
    }

    /// Returns the status and the instance name ("" unless the status is `Ok`). `unix` is the
    /// wall clock in seconds, for the `started` field.
    pub fn launch(&mut self, app_id: &str, profile: &str, unix: i64) -> (Status, String) {
        if !valid_app_id(app_id) || !valid_profile_id(profile) {
            return (Status::Invalid, String::new());
        }
        let Some(user) = self.directory.unix_user(profile) else {
            return (Status::UnknownProfile, String::new());
        };
        if self
            .instances
            .iter()
            .any(|i| i.app_id == app_id && i.profile == profile)
        {
            return (Status::AlreadyRunning, String::new());
        }
        if !self.spawner.is_installed(app_id) {
            return (Status::UnknownApp, String::new());
        }
        match self.spawner.start(&user, app_id, &self.env) {
            Ok(unit) => {
                self.instances.push(Instance {
                    unit: unit.clone(),
                    app_id: app_id.to_owned(),
                    profile: profile.to_owned(),
                    started: unix,
                    state: State::Starting,
                    reached_running: false,
                    stop_asked: None,
                    kill_sent: false,
                });
                (Status::Ok, unit)
            }
            Err(err) => {
                eprintln!("ruya-session: starting {app_id} failed: {err}");
                (Status::Failed, String::new())
            }
        }
    }

    /// Asks the app to quit; `tick` kills it if it does not. Stopping an instance that is
    /// already stopping is `Ok` and changes nothing.
    pub fn stop(&mut self, instance: &str, now: Instant) -> Status {
        let Some(inst) = self.instances.iter_mut().find(|i| i.unit == instance) else {
            return Status::UnknownInstance;
        };
        if inst.state == State::Stopping {
            return Status::Ok;
        }
        match self.spawner.stop(&inst.unit) {
            Ok(()) => {
                inst.state = State::Stopping;
                inst.stop_asked = Some(now);
                Status::Ok
            }
            Err(err) => {
                eprintln!("ruya-session: stopping {} failed: {err}", inst.unit);
                Status::Failed
            }
        }
    }

    pub fn list(&self) -> Vec<RunningApp> {
        self.instances
            .iter()
            .map(|i| RunningApp {
                instance: i.unit.clone(),
                app_id: i.app_id.clone(),
                profile: i.profile.clone(),
                started: i.started,
                state: i.state,
            })
            .collect()
    }

    /// Takes in what the OS reports. Events for units we do not know are ignored.
    pub fn on_event(&mut self, event: UnitEvent) -> Option<Notice> {
        match event {
            UnitEvent::Started { unit } => {
                let inst = self.instances.iter_mut().find(|i| i.unit == unit)?;
                if inst.reached_running {
                    return None;
                }
                inst.reached_running = true;
                if inst.state == State::Starting {
                    inst.state = State::Running;
                }
                Some(Notice::Started {
                    instance: inst.unit.clone(),
                    app_id: inst.app_id.clone(),
                })
            }
            UnitEvent::Exited {
                unit,
                code,
                signaled,
            } => {
                let at = self.instances.iter().position(|i| i.unit == unit)?;
                let inst = self.instances.remove(at);
                let (exit_code, reason) = exit_reason(&inst, code, signaled);
                Some(Notice::Exited {
                    instance: inst.unit,
                    app_id: inst.app_id,
                    exit_code,
                    reason,
                })
            }
        }
    }

    /// Kills the apps that did not quit within `STOP_GRACE` of their `Stop`. Call about once a
    /// second.
    pub fn tick(&mut self, now: Instant) {
        for inst in &mut self.instances {
            let overdue = inst
                .stop_asked
                .is_some_and(|t| now.saturating_duration_since(t) >= STOP_GRACE);
            if overdue && !inst.kill_sent {
                inst.kill_sent = true;
                if let Err(err) = self.spawner.kill(&inst.unit) {
                    eprintln!("ruya-session: killing {} failed: {err}", inst.unit);
                }
            }
        }
    }
}

/// The exit code for the signal and the reason, from the state the instance was in.
fn exit_reason(inst: &Instance, code: i32, signaled: bool) -> (i32, ExitReason) {
    if inst.state == State::Stopping {
        // Asked to stop: a signal exit means it had to be killed (or the system did it).
        return (
            code,
            if signaled {
                ExitReason::Killed
            } else {
                ExitReason::Quit
            },
        );
    }
    if !inst.reached_running {
        return (-1, ExitReason::LaunchFailed);
    }
    let reason = if signaled {
        ExitReason::Killed
    } else if code == 0 {
        ExitReason::Quit
    } else {
        ExitReason::Crashed
    };
    (code, reason)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::directory::ProfileSnapshot;
    use crate::spawner::{unit_name, FakeSpawner};

    const APP: &str = "org.ruyaos.Racer";

    fn session() -> Session<FakeSpawner, ProfileSnapshot> {
        let spawner = FakeSpawner::new()
            .with_app(APP)
            .with_app("org.ruyaos.Puzzle");
        let dir = ProfileSnapshot::new(["p1".to_owned(), "p2".to_owned()]);
        Session::new(
            spawner,
            dir,
            vec![("WAYLAND_DISPLAY".to_owned(), "wayland-0".to_owned())],
        )
    }

    fn running(s: &mut Session<FakeSpawner, ProfileSnapshot>) -> String {
        let (status, unit) = s.launch(APP, "p1", 100);
        assert_eq!(status, Status::Ok);
        assert!(s
            .on_event(UnitEvent::Started { unit: unit.clone() })
            .is_some());
        unit
    }

    fn exited(unit: &str, code: i32, signaled: bool) -> UnitEvent {
        UnitEvent::Exited {
            unit: unit.to_owned(),
            code,
            signaled,
        }
    }

    fn reason(n: Option<Notice>) -> (i32, &'static str) {
        match n {
            Some(Notice::Exited {
                exit_code, reason, ..
            }) => (exit_code, reason.as_str()),
            other => panic!("expected an exit, got {other:?}"),
        }
    }

    #[test]
    fn status_strings_are_the_contract() {
        let all = [
            (Status::Ok, "ok"),
            (Status::UnknownApp, "unknown-app"),
            (Status::UnknownProfile, "unknown-profile"),
            (Status::AlreadyRunning, "already-running"),
            (Status::UnknownInstance, "unknown-instance"),
            (Status::Invalid, "invalid"),
            (Status::Failed, "failed"),
        ];
        for (s, text) in all {
            assert_eq!(s.as_str(), text);
        }
    }

    #[test]
    fn launch_goes_through_starting_to_running() {
        let mut s = session();
        let (status, unit) = s.launch(APP, "p1", 100);
        assert_eq!(
            (status, unit.as_str()),
            (Status::Ok, unit_name("ruya-p1", APP).as_str())
        );
        assert_eq!(s.list()[0].state, State::Starting);
        let notice = s.on_event(UnitEvent::Started { unit: unit.clone() });
        assert_eq!(
            notice,
            Some(Notice::Started {
                instance: unit.clone(),
                app_id: APP.to_owned()
            })
        );
        let list = s.list();
        assert_eq!(list.len(), 1);
        assert_eq!(
            (
                list[0].state.as_str(),
                list[0].profile.as_str(),
                list[0].started
            ),
            ("running", "p1", 100)
        );
        // A second Started for the same unit is not announced twice.
        assert_eq!(s.on_event(UnitEvent::Started { unit }), None);
    }

    #[test]
    fn launch_runs_as_the_profiles_unix_user() {
        let mut s = session();
        s.launch(APP, "p2", 0);
        assert_eq!(s.spawner.calls(), [format!("start ruya-p2 {APP}")]);
    }

    #[test]
    fn invalid_arguments() {
        let mut s = session();
        for app in [
            "",
            "Racer",
            "org.ruyaos.Rac er",
            "org.ruyaos.A;B",
            "--help",
            "org.ruyaos.A\"B",
        ] {
            assert_eq!(
                s.launch(app, "p1", 0),
                (Status::Invalid, String::new()),
                "{app:?}"
            );
        }
        for profile in ["", "p 1", "p1;id", "../p1"] {
            assert_eq!(
                s.launch(APP, profile, 0),
                (Status::Invalid, String::new()),
                "{profile:?}"
            );
        }
        assert!(s.spawner.calls().is_empty());
    }

    #[test]
    fn refuses_accounts_that_are_not_profiles() {
        let mut s = session();
        for profile in ["root", "ruya-shell", "ruya-p1", "nobody", "p9"] {
            assert_eq!(
                s.launch(APP, profile, 0),
                (Status::UnknownProfile, String::new()),
                "{profile}"
            );
        }
        assert!(s.spawner.calls().is_empty());
        assert!(s.list().is_empty());
    }

    #[test]
    fn unknown_app() {
        let mut s = session();
        assert_eq!(
            s.launch("org.ruyaos.Missing", "p1", 0),
            (Status::UnknownApp, String::new())
        );
    }

    #[test]
    fn double_launch_is_already_running_per_profile() {
        let mut s = session();
        let (_, first) = s.launch(APP, "p1", 0);
        // Still starting counts.
        assert_eq!(
            s.launch(APP, "p1", 1),
            (Status::AlreadyRunning, String::new())
        );
        s.on_event(UnitEvent::Started { unit: first });
        assert_eq!(
            s.launch(APP, "p1", 2),
            (Status::AlreadyRunning, String::new())
        );
        // Another profile, or another app, is a different instance.
        assert_eq!(s.launch(APP, "p2", 3).0, Status::Ok);
        assert_eq!(s.launch("org.ruyaos.Puzzle", "p1", 4).0, Status::Ok);
        assert_eq!(s.list().len(), 3);
    }

    #[test]
    fn failing_spawner_is_failed_and_leaves_no_instance() {
        let spawner = FakeSpawner::new().with_app(APP).failing_start();
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, vec![]);
        assert_eq!(s.launch(APP, "p1", 0), (Status::Failed, String::new()));
        assert!(s.list().is_empty());
    }

    #[test]
    fn stop_of_an_unknown_instance() {
        let mut s = session();
        assert_eq!(
            s.stop("nope.service", Instant::now()),
            Status::UnknownInstance
        );
        assert_eq!(s.stop("", Instant::now()), Status::UnknownInstance);
    }

    #[test]
    fn stop_then_exit_is_quit() {
        let mut s = session();
        let unit = running(&mut s);
        let now = Instant::now();
        assert_eq!(s.stop(&unit, now), Status::Ok);
        assert_eq!(s.list()[0].state, State::Stopping);
        // Stopping twice is ok and asks the OS only once.
        assert_eq!(s.stop(&unit, now), Status::Ok);
        assert_eq!(
            s.spawner
                .calls()
                .iter()
                .filter(|c| c.starts_with("stop"))
                .count(),
            1
        );
        assert_eq!(reason(s.on_event(exited(&unit, 0, false))), (0, "quit"));
        assert!(s.list().is_empty());
        // The instance is gone: a later event is ignored and Stop says so.
        assert_eq!(s.on_event(exited(&unit, 0, false)), None);
        assert_eq!(s.stop(&unit, now), Status::UnknownInstance);
    }

    #[test]
    fn nonzero_exit_after_stop_is_still_quit() {
        // Apps often answer SIGTERM with 143 after their own cleanup.
        let mut s = session();
        let unit = running(&mut s);
        s.stop(&unit, Instant::now());
        assert_eq!(reason(s.on_event(exited(&unit, 143, false))), (143, "quit"));
    }

    #[test]
    fn app_that_ignores_stop_is_killed_after_the_grace_period() {
        let mut s = session();
        let unit = running(&mut s);
        let t0 = Instant::now();
        s.stop(&unit, t0);
        s.tick(t0 + STOP_GRACE - Duration::from_millis(1));
        assert!(!s.spawner.calls().iter().any(|c| c.starts_with("kill")));
        s.tick(t0 + STOP_GRACE);
        s.tick(t0 + STOP_GRACE * 2);
        assert_eq!(
            s.spawner
                .calls()
                .iter()
                .filter(|c| c.starts_with("kill"))
                .count(),
            1
        );
        assert_eq!(reason(s.on_event(exited(&unit, 9, true))), (9, "killed"));
    }

    #[test]
    fn tick_leaves_apps_that_were_not_stopped_alone() {
        let mut s = session();
        running(&mut s);
        s.tick(Instant::now() + Duration::from_secs(3600));
        assert!(!s.spawner.calls().iter().any(|c| c.starts_with("kill")));
    }

    #[test]
    fn exit_reasons_of_a_running_app() {
        let cases = [
            (0, false, (0, "quit")),
            (1, false, (1, "crashed")),
            (139, false, (139, "crashed")),
            (11, true, (11, "killed")),
        ];
        for (code, signaled, expected) in cases {
            let mut s = session();
            let unit = running(&mut s);
            assert_eq!(reason(s.on_event(exited(&unit, code, signaled))), expected);
            assert!(s.list().is_empty());
        }
    }

    #[test]
    fn app_that_never_ran_is_launch_failed_with_code_minus_one() {
        for (code, signaled) in [(0, false), (1, false), (9, true)] {
            let mut s = session();
            let (_, unit) = s.launch(APP, "p1", 0);
            assert_eq!(
                reason(s.on_event(exited(&unit, code, signaled))),
                (-1, "launch-failed")
            );
        }
    }

    #[test]
    fn app_that_exits_by_itself_can_be_started_again() {
        let mut s = session();
        let unit = running(&mut s);
        s.on_event(exited(&unit, 0, false));
        assert_eq!(s.launch(APP, "p1", 200).0, Status::Ok);
    }

    #[test]
    fn events_for_unknown_units_are_ignored() {
        let mut s = session();
        assert_eq!(
            s.on_event(UnitEvent::Started {
                unit: "x.service".into()
            }),
            None
        );
        assert_eq!(s.on_event(exited("x.service", 1, false)), None);
    }

    #[test]
    fn stop_during_starting_ends_as_quit() {
        let mut s = session();
        let (_, unit) = s.launch(APP, "p1", 0);
        assert_eq!(s.stop(&unit, Instant::now()), Status::Ok);
        // The app comes up while stopping: still stopping, announced once.
        assert!(s
            .on_event(UnitEvent::Started { unit: unit.clone() })
            .is_some());
        assert_eq!(s.list()[0].state, State::Stopping);
        assert_eq!(reason(s.on_event(exited(&unit, 0, false))), (0, "quit"));
    }
}
