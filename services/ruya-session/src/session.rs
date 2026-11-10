//! Session core: the registry of running app instances and its state machine. All rules live
//! here; the OS is reached through `Spawner` and `ProfileDirectory`, time is passed in. Events
//! from the OS come in through `on_event` and leave as `Notice`s for the adapter to emit.
//!
//! An instance goes `starting -> running -> stopping`, and `exited` is the end: an exited
//! instance is reported once (a `Notice::Exited`) and removed, so it never shows in `list`.

use std::time::{Duration, Instant};

use crate::directory::ProfileDirectory;
use crate::spawner::{
    app_env, valid_app_id, valid_profile_id, with_pulse_server, Spawner, UnitEvent,
};

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
    /// Freeze/Thaw: no running instance with that name (T-457).
    NotRunning,
    /// Freeze/Thaw: the app is not the signed-in profile's (T-457).
    NotAllowed,
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
            Status::NotRunning => "not-running",
            Status::NotAllowed => "not-allowed",
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
    /// Frozen by `freeze` (T-457).
    pub frozen: bool,
}

/// A change of an app's `frozen` for the adapter to announce (`FrozenChanged`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrozenChange {
    pub instance: String,
    pub frozen: bool,
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
    /// An adopted unit of a profile that no longer exists: being stopped, never listed or
    /// reported (the shell never heard of it).
    hidden: bool,
    /// Frozen by `freeze` and not thawed since (T-457).
    frozen: bool,
}

pub struct Session<S, D> {
    spawner: S,
    directory: D,
    env: Vec<(String, String)>,
    wayland_dir: Option<String>,
    pulse_dir: Option<String>,
    instances: Vec<Instance>,
    /// `frozen` changes not yet taken by the adapter (`take_frozen_changes`).
    frozen_changes: Vec<FrozenChange>,
}

impl<S: Spawner, D: ProfileDirectory> Session<S, D> {
    /// `env` is handed to every app (for instance `SDL_VIDEODRIVER`).
    pub fn new(spawner: S, directory: D, env: Vec<(String, String)>) -> Self {
        Session {
            spawner,
            directory,
            env,
            wayland_dir: None,
            pulse_dir: None,
            instances: Vec::new(),
            frozen_changes: Vec::new(),
        }
    }

    /// Each app then gets `WAYLAND_DISPLAY` set to its profile user's own socket in `dir`
    /// (`spawner::app_env`, ADR-023).
    pub fn with_wayland_dir(mut self, dir: &str) -> Self {
        self.wayland_dir = Some(dir.to_owned());
        self
    }

    /// Each app then gets its profile user's own sound server, started first, as `PULSE_SERVER`
    /// (`spawner::with_pulse_server`, ADR-010).
    pub fn with_pulse_dir(mut self, dir: &str) -> Self {
        self.pulse_dir = Some(dir.to_owned());
        self
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
        let same = |i: &&Instance| i.app_id == app_id && i.profile == profile;
        if self
            .instances
            .iter()
            .filter(same)
            .any(|i| i.state != State::Stopping)
        {
            return (Status::AlreadyRunning, String::new());
        }
        if self.instances.iter().any(|i| same(&i)) {
            // The old unit was told to stop and is not gone yet: its name is still taken, and the
            // app is not "already running" either. The adapter waits for it (`is_stopping`)
            // before it gets here; this is the answer when the wait ran out.
            eprintln!("ruya-session: {app_id} is still ending, not launched");
            return (Status::Failed, String::new());
        }
        if !self.spawner.is_installed(app_id) {
            return (Status::UnknownApp, String::new());
        }
        let mut env = app_env(&self.env, self.wayland_dir.as_deref(), &user);
        if let Some(dir) = self.pulse_dir.as_deref() {
            // The profile's own sound server must listen before the app looks for it. Without it
            // the app still starts, without sound (ADR-010, T-365).
            match self.spawner.start_sound(&user) {
                Ok(()) => env = with_pulse_server(env, dir, &user),
                Err(err) => eprintln!("ruya-session: no sound server for {user}: {err}"),
            }
        }
        match self.spawner.start(&user, app_id, &env) {
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
                    hidden: false,
                    frozen: false,
                });
                (Status::Ok, unit)
            }
            Err(err) => {
                eprintln!("ruya-session: starting {app_id} failed: {err}");
                (Status::Failed, String::new())
            }
        }
    }

    /// Is an instance of this app of this profile on its way out (told to stop, not gone yet)?
    pub fn is_stopping(&self, app_id: &str, profile: &str) -> bool {
        self.instances
            .iter()
            .any(|i| i.app_id == app_id && i.profile == profile && i.state == State::Stopping)
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
        if inst.frozen {
            // A frozen app cannot handle the SIGTERM of the stop: thaw it first (T-457). A failed
            // thaw still stops it; the kill after the grace time ends even a frozen process.
            if let Err(err) = self.spawner.thaw(&inst.unit) {
                eprintln!(
                    "ruya-session: thawing {} before its stop failed: {err}",
                    inst.unit
                );
            }
            inst.frozen = false;
            self.frozen_changes.push(FrozenChange {
                instance: inst.unit.clone(),
                frozen: false,
            });
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

    /// The running, listed instance named `instance`, checked for Freeze and Thaw: it must be
    /// running and, when `active` is known (system mode), the signed-in profile's.
    fn freezable(&self, instance: &str, active: Option<&str>) -> Result<usize, Status> {
        if instance.is_empty() {
            return Err(Status::Invalid);
        }
        let at = self
            .instances
            .iter()
            .position(|i| i.unit == instance && !i.hidden)
            .ok_or(Status::NotRunning)?;
        let inst = &self.instances[at];
        if active.is_some_and(|a| a.is_empty() || a != inst.profile) {
            return Err(Status::NotAllowed);
        }
        if inst.state != State::Running {
            return Err(Status::NotRunning);
        }
        Ok(at)
    }

    /// Freezes a running app of the signed-in profile (`active`; `None` in development mode, no
    /// check), T-457. A frozen app is left as it is (`Ok`, the OS is not asked again). A failed
    /// freeze is undone (a thaw of the same units) so the app keeps running: `Failed`.
    pub fn freeze(&mut self, instance: &str, active: Option<&str>) -> Status {
        let at = match self.freezable(instance, active) {
            Ok(at) => at,
            Err(status) => return status,
        };
        let inst = &mut self.instances[at];
        if inst.frozen {
            return Status::Ok;
        }
        match self.spawner.freeze(&inst.unit) {
            Ok(()) => {
                inst.frozen = true;
                self.frozen_changes.push(FrozenChange {
                    instance: inst.unit.clone(),
                    frozen: true,
                });
                Status::Ok
            }
            Err(err) => {
                eprintln!("ruya-session: freezing {} failed: {err}", inst.unit);
                // A part may be frozen (the unit but not a scope): it must not stay so.
                if let Err(err) = self.spawner.thaw(&inst.unit) {
                    eprintln!(
                        "ruya-session: thawing {} after the failed freeze failed: {err}",
                        inst.unit
                    );
                }
                Status::Failed
            }
        }
    }

    /// Thaws a running app of the signed-in profile (T-457). The OS is asked even when the app is
    /// not known to be frozen (a restart of this service forgets it); thawing a running app is a
    /// no-op there. A failed thaw keeps `frozen`, so a later Thaw or Stop tries again.
    pub fn thaw(&mut self, instance: &str, active: Option<&str>) -> Status {
        let at = match self.freezable(instance, active) {
            Ok(at) => at,
            Err(status) => return status,
        };
        let inst = &mut self.instances[at];
        match self.spawner.thaw(&inst.unit) {
            Ok(()) => {
                if inst.frozen {
                    inst.frozen = false;
                    self.frozen_changes.push(FrozenChange {
                        instance: inst.unit.clone(),
                        frozen: false,
                    });
                }
                Status::Ok
            }
            Err(err) => {
                eprintln!("ruya-session: thawing {} failed: {err}", inst.unit);
                Status::Failed
            }
        }
    }

    /// The `frozen` changes since the last call, in order, for `FrozenChanged`.
    pub fn take_frozen_changes(&mut self) -> Vec<FrozenChange> {
        std::mem::take(&mut self.frozen_changes)
    }

    /// Start-up: takes over the app units that run already (a restart of this service does not
    /// end the apps). They are `running` from the start and announce nothing; their end is
    /// reported like any other. When the profiles are `known` (the directory is current), a unit
    /// of a profile that no longer exists is stopped and never listed. Returns what was adopted.
    pub fn adopt(&mut self, unix: i64, now: Instant, profiles_known: bool) -> Vec<RunningApp> {
        for found in self.spawner.adopt_running() {
            let Some(profile) = found
                .user
                .strip_prefix("ruya-")
                .filter(|p| valid_profile_id(p))
            else {
                continue;
            };
            if !valid_app_id(&found.app_id) || self.instances.iter().any(|i| i.unit == found.unit) {
                continue;
            }
            let orphan = profiles_known && self.directory.unix_user(profile).is_none();
            let mut inst = Instance {
                unit: found.unit,
                app_id: found.app_id,
                profile: profile.to_owned(),
                started: if found.started > 0 {
                    found.started
                } else {
                    unix
                },
                state: State::Running,
                reached_running: true,
                stop_asked: None,
                kill_sent: false,
                hidden: orphan,
                frozen: false,
            };
            if orphan {
                match self.spawner.stop(&inst.unit) {
                    Ok(()) => {
                        inst.state = State::Stopping;
                        inst.stop_asked = Some(now);
                    }
                    Err(err) => {
                        eprintln!("ruya-session: stopping {} failed: {err}", inst.unit);
                        continue;
                    }
                }
            }
            self.instances.push(inst);
        }
        self.list()
    }

    pub fn list(&self) -> Vec<RunningApp> {
        self.instances
            .iter()
            .filter(|i| !i.hidden)
            .map(|i| RunningApp {
                instance: i.unit.clone(),
                app_id: i.app_id.clone(),
                profile: i.profile.clone(),
                started: i.started,
                state: i.state,
                frozen: i.frozen,
            })
            .collect()
    }

    /// Takes in what the OS reports. Events for units we do not know are ignored.
    pub fn on_event(&mut self, event: UnitEvent) -> Option<Notice> {
        match event {
            UnitEvent::Started { unit } => {
                let inst = self.instances.iter_mut().find(|i| i.unit == unit)?;
                if inst.reached_running || inst.hidden {
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
                if inst.hidden {
                    return None;
                }
                let (exit_code, reason) = exit_reason(&inst, code, signaled);
                Some(Notice::Exited {
                    instance: inst.unit,
                    app_id: inst.app_id,
                    exit_code,
                    reason,
                })
            }
            UnitEvent::ExecFailed { unit } => {
                let at = self.instances.iter().position(|i| i.unit == unit)?;
                let inst = self.instances.remove(at);
                if inst.hidden {
                    return None;
                }
                // The program never ran, whatever `Running as unit` said before: `launch-failed`
                // (code -1) unless the app was being stopped anyway.
                let (exit_code, reason) = if inst.state == State::Stopping {
                    exit_reason(&inst, 0, false)
                } else {
                    (-1, ExitReason::LaunchFailed)
                };
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
        // Asked to stop: the stop itself is a SIGTERM, so dying of a signal is still a quit.
        // Only an exit after the kill of `tick` is "killed".
        return (
            code,
            if signaled && inst.kill_sent {
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
            (Status::NotRunning, "not-running"),
            (Status::NotAllowed, "not-allowed"),
        ];
        for (s, text) in all {
            assert_eq!(s.as_str(), text);
        }
    }

    // ---- Freeze and Thaw (T-457) -----------------------------------------------------------

    fn frozen_of(s: &Session<FakeSpawner, ProfileSnapshot>, unit: &str) -> bool {
        s.list()
            .into_iter()
            .find(|a| a.instance == unit)
            .is_some_and(|a| a.frozen)
    }

    #[test]
    fn freeze_and_thaw_go_to_the_os_and_are_announced() {
        let mut s = session();
        let unit = running(&mut s);
        assert!(!frozen_of(&s, &unit));
        assert_eq!(s.freeze(&unit, Some("p1")), Status::Ok);
        assert!(frozen_of(&s, &unit));
        assert_eq!(
            s.take_frozen_changes(),
            [FrozenChange {
                instance: unit.clone(),
                frozen: true
            }]
        );
        // A second freeze is a no-op: the OS is not asked again, nothing is announced.
        assert_eq!(s.freeze(&unit, Some("p1")), Status::Ok);
        assert!(s.take_frozen_changes().is_empty());
        assert_eq!(s.thaw(&unit, Some("p1")), Status::Ok);
        assert!(!frozen_of(&s, &unit));
        assert_eq!(
            s.take_frozen_changes(),
            [FrozenChange {
                instance: unit.clone(),
                frozen: false
            }]
        );
        assert_eq!(
            s.spawner.calls(),
            [
                format!("start ruya-p1 {APP}"),
                format!("freeze {unit}"),
                format!("thaw {unit}")
            ]
        );
        // A thaw of an app that is not frozen still asks the OS (a restart of the service forgets
        // the state), announces nothing and is ok.
        assert_eq!(s.thaw(&unit, Some("p1")), Status::Ok);
        assert!(s.take_frozen_changes().is_empty());
        assert_eq!(s.spawner.calls().last(), Some(&format!("thaw {unit}")));
    }

    #[test]
    fn another_profiles_app_is_never_frozen() {
        let mut s = session();
        let unit = running(&mut s); // p1's
        for active in [Some("p2"), Some("")] {
            assert_eq!(s.freeze(&unit, active), Status::NotAllowed, "{active:?}");
            assert_eq!(s.thaw(&unit, active), Status::NotAllowed, "{active:?}");
        }
        assert!(!frozen_of(&s, &unit));
        assert_eq!(s.spawner.calls(), [format!("start ruya-p1 {APP}")]);
        // Development mode (no active profile known) does not check.
        assert_eq!(s.freeze(&unit, None), Status::Ok);
    }

    #[test]
    fn only_a_running_app_is_frozen() {
        let mut s = session();
        assert_eq!(s.freeze("", Some("p1")), Status::Invalid);
        assert_eq!(s.freeze("nope.service", Some("p1")), Status::NotRunning);
        assert_eq!(s.thaw("nope.service", Some("p1")), Status::NotRunning);
        let (_, unit) = s.launch(APP, "p1", 0); // still starting
        assert_eq!(s.freeze(&unit, Some("p1")), Status::NotRunning);
        s.on_event(UnitEvent::Started { unit: unit.clone() });
        assert_eq!(s.stop(&unit, Instant::now()), Status::Ok); // stopping
        assert_eq!(s.freeze(&unit, Some("p1")), Status::NotRunning);
        assert!(!s.spawner.calls().iter().any(|c| c.starts_with("freeze")));
    }

    #[test]
    fn a_failed_freeze_is_undone_and_the_app_keeps_running() {
        let spawner = FakeSpawner::new().with_app(APP).failing_freeze();
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, Vec::new());
        let unit = running(&mut s);
        assert_eq!(s.freeze(&unit, Some("p1")), Status::Failed);
        assert!(!frozen_of(&s, &unit));
        assert!(s.take_frozen_changes().is_empty());
        assert_eq!(
            s.spawner.calls()[1..],
            [format!("freeze {unit}"), format!("thaw {unit}")]
        );
    }

    #[test]
    fn a_frozen_app_is_thawed_before_its_stop() {
        let mut s = session();
        let unit = running(&mut s);
        assert_eq!(s.freeze(&unit, Some("p1")), Status::Ok);
        s.take_frozen_changes();
        assert_eq!(s.stop(&unit, Instant::now()), Status::Ok);
        assert_eq!(
            s.spawner.calls()[1..],
            [
                format!("freeze {unit}"),
                format!("thaw {unit}"),
                format!("stop {unit}")
            ]
        );
        assert!(!frozen_of(&s, &unit));
        assert_eq!(
            s.take_frozen_changes(),
            [FrozenChange {
                instance: unit.clone(),
                frozen: false
            }]
        );
        // An app that is not frozen is stopped without a thaw.
        let (_, other) = s.launch("org.ruyaos.Puzzle", "p1", 0);
        s.on_event(UnitEvent::Started {
            unit: other.clone(),
        });
        assert_eq!(s.stop(&other, Instant::now()), Status::Ok);
        assert_eq!(s.spawner.calls().last(), Some(&format!("stop {other}")));
        assert!(!s.spawner.calls().contains(&format!("thaw {other}")));
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

    fn pulse(s: &Session<FakeSpawner, ProfileSnapshot>) -> Option<String> {
        s.spawner
            .last_env()
            .into_iter()
            .find(|(k, _)| k == "PULSE_SERVER")
            .map(|(_, v)| v)
    }

    #[test]
    fn the_pulse_server_is_started_before_the_app() {
        let mut s = session().with_pulse_dir("/run/ruya-pulse");
        let (status, _) = s.launch(APP, "p1", 0);
        assert_eq!(status, Status::Ok);
        assert_eq!(
            s.spawner.calls(),
            vec!["sound ruya-p1".to_owned(), format!("start ruya-p1 {APP}")]
        );
        assert_eq!(
            pulse(&s).as_deref(),
            Some("unix:/run/ruya-pulse/ruya-p1/native")
        );
        // Without a pulse directory (`--session`): no server is started, no PULSE_SERVER.
        let mut dev = session();
        dev.launch(APP, "p2", 0);
        assert_eq!(dev.spawner.calls(), vec![format!("start ruya-p2 {APP}")]);
        assert_eq!(pulse(&dev), None);
    }

    #[test]
    fn a_failed_pulse_start_still_launches_the_app() {
        let spawner = FakeSpawner::new().with_app(APP).failing_sound();
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, Vec::new()).with_pulse_dir("/run/ruya-pulse");
        let (status, instance) = s.launch(APP, "p1", 0);
        assert_eq!(status, Status::Ok);
        assert!(!instance.is_empty());
        assert_eq!(
            s.spawner.calls().last(),
            Some(&format!("start ruya-p1 {APP}"))
        );
        // No PULSE_SERVER pointing at a socket nobody listens on.
        assert_eq!(pulse(&s), None);
    }

    #[test]
    fn each_app_gets_the_wayland_socket_of_its_own_profile() {
        let display = |s: &Session<FakeSpawner, ProfileSnapshot>| {
            s.spawner
                .last_env()
                .into_iter()
                .find(|(k, _)| k == "WAYLAND_DISPLAY")
                .map(|(_, v)| v)
        };
        let mut s = session().with_wayland_dir("/run/ruya-wayland");
        s.launch(APP, "p1", 0);
        assert_eq!(display(&s).as_deref(), Some("/run/ruya-wayland/ruya-p1"));
        s.launch("org.ruyaos.Puzzle", "p2", 0);
        assert_eq!(display(&s).as_deref(), Some("/run/ruya-wayland/ruya-p2"));
        // Exactly one WAYLAND_DISPLAY: the base one is replaced, not doubled.
        let count = s
            .spawner
            .last_env()
            .iter()
            .filter(|(k, _)| k == "WAYLAND_DISPLAY")
            .count();
        assert_eq!(count, 1);
        // Without a socket directory (development) the base environment is handed on as it is.
        let mut dev = session();
        dev.launch(APP, "p1", 0);
        assert_eq!(display(&dev).as_deref(), Some("wayland-0"));
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
    fn dying_of_the_stop_signal_is_quit_not_killed() {
        // `systemctl stop` sends SIGTERM; an app without a handler dies of it before any kill.
        let mut s = session();
        let unit = running(&mut s);
        s.stop(&unit, Instant::now());
        assert_eq!(reason(s.on_event(exited(&unit, 15, true))), (15, "quit"));
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

    const PUZZLE: &str = "org.ruyaos.Puzzle";

    /// A service that restarts while `ruya-p1` runs Racer and `ruya-p2` runs Puzzle.
    fn restarted() -> Session<FakeSpawner, ProfileSnapshot> {
        let spawner = FakeSpawner::new()
            .with_app(APP)
            .with_app(PUZZLE)
            .with_running("ruya-p1", APP, 1_000)
            .with_running("ruya-p2", PUZZLE, 2_000);
        let dir = ProfileSnapshot::new(["p1".to_owned(), "p2".to_owned()]);
        Session::new(spawner, dir, vec![])
    }

    #[test]
    fn adopted_units_are_listed_as_running_with_their_start_time() {
        let mut s = restarted();
        let adopted = s.adopt(5_000, Instant::now(), true);
        assert_eq!(adopted, s.list());
        let mut got: Vec<_> = s
            .list()
            .into_iter()
            .map(|a| (a.instance, a.app_id, a.profile, a.started, a.state))
            .collect();
        got.sort_by(|a, b| a.0.cmp(&b.0));
        assert_eq!(
            got,
            [
                (
                    unit_name("ruya-p1", APP),
                    APP.to_owned(),
                    "p1".to_owned(),
                    1_000,
                    State::Running
                ),
                (
                    unit_name("ruya-p2", PUZZLE),
                    PUZZLE.to_owned(),
                    "p2".to_owned(),
                    2_000,
                    State::Running
                ),
            ]
        );
    }

    #[test]
    fn a_relaunch_of_an_adopted_app_is_already_running() {
        let mut s = restarted();
        s.adopt(5_000, Instant::now(), true);
        assert_eq!(
            s.launch(APP, "p1", 6_000),
            (Status::AlreadyRunning, String::new())
        );
        // The same app for another profile is another instance.
        assert_eq!(s.launch(APP, "p2", 6_000).0, Status::Ok);
        assert!(
            s.spawner
                .calls()
                .iter()
                .filter(|c| c.starts_with("start"))
                .count()
                == 1
        );
    }

    #[test]
    fn an_adopted_app_that_ends_is_reported_once_with_its_reason() {
        let mut s = restarted();
        s.adopt(5_000, Instant::now(), true);
        let racer = unit_name("ruya-p1", APP);
        let puzzle = unit_name("ruya-p2", PUZZLE);
        // Adoption announced nothing and a late `Started` of the same unit is not news either.
        assert_eq!(
            s.on_event(UnitEvent::Started {
                unit: racer.clone()
            }),
            None
        );
        assert_eq!(reason(s.on_event(exited(&racer, 0, false))), (0, "quit"));
        assert_eq!(s.on_event(exited(&racer, 0, false)), None);
        assert_eq!(
            reason(s.on_event(exited(&puzzle, 11, true))),
            (11, "killed")
        );
        assert!(s.list().is_empty());
        // Gone, so it can be launched again.
        assert_eq!(s.launch(APP, "p1", 7_000).0, Status::Ok);
    }

    #[test]
    fn an_adopted_app_can_be_stopped_and_killed() {
        let mut s = restarted();
        s.adopt(5_000, Instant::now(), true);
        let racer = unit_name("ruya-p1", APP);
        let t0 = Instant::now();
        assert_eq!(s.stop(&racer, t0), Status::Ok);
        assert_eq!(
            s.list()
                .iter()
                .filter(|a| a.state == State::Stopping)
                .count(),
            1
        );
        s.tick(t0 + STOP_GRACE);
        assert!(s.spawner.calls().contains(&format!("kill {racer}")));
        assert_eq!(reason(s.on_event(exited(&racer, 9, true))), (9, "killed"));
    }

    #[test]
    fn a_unit_of_a_profile_that_is_gone_is_stopped_and_stays_unseen() {
        let spawner = FakeSpawner::new()
            .with_app(APP)
            .with_running("ruya-p1", APP, 1_000)
            .with_running("ruya-p9", APP, 1_000);
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, vec![]);
        let t0 = Instant::now();
        let adopted = s.adopt(5_000, t0, true);
        let orphan = unit_name("ruya-p9", APP);
        assert_eq!(adopted.len(), 1);
        assert_eq!(adopted[0].profile, "p1");
        assert!(s.spawner.calls().contains(&format!("stop {orphan}")));
        assert!(!s
            .spawner
            .calls()
            .contains(&format!("stop {}", unit_name("ruya-p1", APP))));
        // It is not listed and its end is not announced; it is killed if it ignores the stop.
        assert!(s.list().iter().all(|a| a.profile != "p9"));
        s.tick(t0 + STOP_GRACE);
        assert!(s.spawner.calls().contains(&format!("kill {orphan}")));
        assert_eq!(s.on_event(exited(&orphan, 0, false)), None);
    }

    #[test]
    fn units_are_kept_when_the_profile_list_could_not_be_read() {
        let mut s = restarted();
        *s.directory_mut() = ProfileSnapshot::default();
        assert_eq!(s.adopt(5_000, Instant::now(), false).len(), 2);
        assert!(!s.spawner.calls().iter().any(|c| c.starts_with("stop")));
    }

    #[test]
    fn units_that_are_not_ours_are_skipped() {
        let spawner = FakeSpawner::new()
            .with_running("root", APP, 1)
            .with_running("ruya-", APP, 1)
            .with_running("ruya-p 1", APP, 1)
            .with_running("ruya-p1", "Racer", 1);
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, vec![]);
        assert!(s.adopt(5_000, Instant::now(), true).is_empty());
        assert!(s.spawner.calls().iter().all(|c| !c.starts_with("stop")));
    }

    #[test]
    fn adopting_twice_does_not_duplicate() {
        let mut s = restarted();
        s.adopt(5_000, Instant::now(), true);
        s.adopt(5_001, Instant::now(), true);
        assert_eq!(s.list().len(), 2);
    }

    #[test]
    fn a_unit_without_a_start_time_gets_the_adoption_time() {
        let spawner = FakeSpawner::new()
            .with_app(APP)
            .with_running("ruya-p1", APP, 0);
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, vec![]);
        assert_eq!(s.adopt(5_000, Instant::now(), true)[0].started, 5_000);
    }

    fn exec_failed(unit: &str) -> UnitEvent {
        UnitEvent::ExecFailed {
            unit: unit.to_owned(),
        }
    }

    #[test]
    fn an_exec_failure_is_launch_failed_not_crashed() {
        let mut s = session();
        let unit = running(&mut s); // `Running as unit` came first, as systemd-run prints it
        assert_eq!(
            reason(s.on_event(exec_failed(&unit))),
            (-1, "launch-failed")
        );
        assert!(s.list().is_empty());
        // The same status as a plain exit code stays what it was.
        let unit = running(&mut s);
        assert_eq!(
            reason(s.on_event(exited(&unit, 203, false))),
            (203, "crashed")
        );
        // Never started at all: also launch-failed.
        let (_, unit) = s.launch(APP, "p1", 0);
        assert_eq!(
            reason(s.on_event(exec_failed(&unit))),
            (-1, "launch-failed")
        );
        assert_eq!(s.on_event(exec_failed(&unit)), None);
    }

    #[test]
    fn an_exec_failure_while_stopping_is_a_quit() {
        let mut s = session();
        let unit = running(&mut s);
        s.stop(&unit, Instant::now());
        assert_eq!(reason(s.on_event(exec_failed(&unit))), (0, "quit"));
    }

    #[test]
    fn launch_after_stop_does_not_answer_already_running() {
        let mut s = session();
        let unit = running(&mut s);
        // Running: a second launch is already-running.
        assert_eq!(s.launch(APP, "p1", 101).0, Status::AlreadyRunning);
        assert_eq!(s.stop(&unit, Instant::now()), Status::Ok);
        assert!(s.is_stopping(APP, "p1"));
        // The old unit is still around: not "already running", and no second unit on its name.
        assert_eq!(s.launch(APP, "p1", 102), (Status::Failed, String::new()));
        assert_eq!(
            s.spawner
                .calls()
                .iter()
                .filter(|c| c.starts_with("start"))
                .count(),
            1
        );
        // Once the old one has ended the launch goes through.
        s.on_event(exited(&unit, 0, false));
        assert!(!s.is_stopping(APP, "p1"));
        assert_eq!(s.launch(APP, "p1", 103).0, Status::Ok);
        // Another profile was never in the way.
        assert_eq!(s.launch(APP, "p2", 104).0, Status::Ok);
    }
}
