//! Session core: the registry of running app instances and its state machine. All rules live
//! here; the OS is reached through `Spawner` and `ProfileDirectory`, time is passed in. Events
//! from the OS come in through `on_event` and leave as `Notice`s for the adapter to emit.
//!
//! An instance goes `starting -> running -> stopping`, and `exited` is the end: an exited
//! instance is reported once (a `Notice::Exited`) and removed, so it never shows in `list`.
//!
//! A Steam game is a child instance of the profile's Steam instance (ADR-041, RUY-1052): it comes
//! in as `UnitEvent::ChildStarted` (the spawner tells its scopes apart, `scope.rs`), is `running`
//! from the start, has `item` `steam:<appid>` and `parent` the Steam instance, and ends with an
//! `Exited` of its own name. Point 7: Stop and Kill of a parent reach its children first; Freeze
//! and Thaw of a parent reach every running child, and the parent's own unit and scopes only when
//! its app may be frozen (`Spawner::may_freeze`, the app table's `freeze`); every record's
//! `frozen` is its own. A parent that ends ends its children first.
//!
//! `launch_steam_game` (ADR-041 point 3, RUY-1067) launches a game: Steam is started with
//! `steam://rungameid/<appid>`, or a running Steam is handed the URL (`Spawner::forward_steam_url`),
//! and the child is listed `starting` under the name its scope's child will have
//! (`spawner::child_name`). Its `ChildStarted` makes it `running`; `tick` ends it `launch-failed`
//! when none came within `CHILD_LAUNCH_WAIT`. Such a child has no scope to reach yet: Stop and Kill
//! end it in the core (`stopping`, ended by the next `tick`), with no call to the OS.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::directory::ProfileDirectory;
use crate::spawner::{
    app_env, unit_app_id, with_pulse_server, AdoptLister, Listing, ScopeLister, Spawner, UnitEvent,
};
use crate::steam_tool::{steam_run_url, STEAM_APP_ID};
use async_channel::Sender;
use ruya_flatpak::scope::{is_app_scope, parse_cgroup};
use ruya_flatpak::valid_session_app_id;
use ruya_ids::{flatpak_item, profile_of_user, steam_item, valid_profile_id, valid_steam_appid};

/// After `Stop`, the app has this long to quit before it is killed: the backstop (RUY-736). It
/// counts from the stop itself, after the thaw of a frozen app (which can take up to two bounded
/// `systemctl` calls). Long, so a game that saves on quit gets its time; a player who does not want
/// to wait asks for `kill` (the closing screen's Force quit after 5 s).
pub const STOP_GRACE: Duration = Duration::from_secs(30);

/// A frozen app's memory is moved out to swap once it has been frozen this long (T-466): never
/// at the Freeze itself, which is when the Hub opens and must stay instant.
pub const RECLAIM_AFTER: Duration = Duration::from_secs(30);

/// A Steam game launched by `launch_steam_game` is `starting` until its scope appears; without one
/// this long after the launch it ends `launch-failed` (ADR-041 point 3).
pub const CHILD_LAUNCH_WAIT: Duration = Duration::from_secs(120);

/// The deadline of the Platform1 `Stopping` a `Stop` sends before its SIGTERM (RUY-1099): an app
/// that registered for its lifecycle has this long to save and call `SaveDone`.
pub const SAVE_WAIT: Duration = Duration::from_secs(5);

/// Where the time of a call comes from: an `Instant` (tests) or a clock read when the core needs
/// it (`Instant::now`), so `stop` can take the time after a slow thaw.
pub trait Clock {
    fn now(&self) -> Instant;
}

impl Clock for Instant {
    fn now(&self) -> Instant {
        *self
    }
}

impl<F: Fn() -> Instant> Clock for F {
    fn now(&self) -> Instant {
        self()
    }
}

/// The memory reclaim of one freeze (T-466).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Reclaim {
    /// Not due yet (or not frozen).
    Waiting,
    /// Started: a thaw cancels it in case it still runs.
    Sent,
    /// Not done for this freeze (no swap, or it could not start).
    Skipped,
}

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
    /// InstanceOfPid: the process is in no running instance (T-459).
    NotFound,
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
            Status::NotFound => "not-found",
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
        /// The profile it ran for and its Library1 item id: the adapter's own uses (a profile's
        /// Steam client that ends has its Steam items read again, RUY-1056), not in the signal.
        profile: String,
        item: String,
    },
}

/// One entry of `ListRunning`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunningApp {
    pub instance: String,
    pub app_id: String,
    /// The Library1 item id (ADR-041): `flatpak:<app_id>`, or `steam:<appid>` for a Steam child.
    pub item: String,
    /// The parent's instance name for a child instance, else "" (ADR-041).
    pub parent: String,
    pub profile: String,
    pub started: i64,
    pub state: State,
    /// Frozen by `freeze` (T-457).
    pub frozen: bool,
}

/// A Platform1 lifecycle event (RUY-1099, ADR-022) for the adapter to send to one instance's own
/// scopes (`Manage.NotifyLifecycle`). There is none before a freeze: it is instant, and a frozen
/// app could not act on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LifecycleEvent {
    /// A Freeze reached an instance whose app may not be frozen: it is held, still running.
    Background,
    /// A hold or a freeze ended: how long it lasted.
    Resume { frozen_ms: u64 },
    /// A `Stop`'s save wait: its deadline, counted from the notice's `at`, which bounds the whole
    /// wait (the scope listing included). The SIGTERM waits for `Session::saved`.
    Stopping { deadline_ms: u64 },
}

impl LifecycleEvent {
    /// `NotifyLifecycle`'s `event` and `value_ms`.
    pub fn as_call(self) -> (&'static str, u64) {
        match self {
            LifecycleEvent::Background => ("background", 0),
            LifecycleEvent::Resume { frozen_ms } => ("resume", frozen_ms),
            LifecycleEvent::Stopping { deadline_ms } => ("stopping", deadline_ms),
        }
    }
}

/// One lifecycle event for the instance `instance` of `profile`, in the order the core decided
/// them (`Session::with_lifecycle`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LifecycleNotice {
    pub instance: String,
    pub profile: String,
    pub event: LifecycleEvent,
    /// When the core decided it.
    pub at: Instant,
}

/// Where a `Stop`'s save wait is (RUY-1099). `since` is when its `Stopping` was told; `in_grace`
/// (power off): the grace counts from `since`, so the save window is part of `STOP_GRACE`
/// instead of adding to it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SaveWait {
    /// No wait: not stopping, or its SIGTERM is sent.
    Off,
    /// Its `Stopping` is out and not settled yet.
    Waiting { since: Instant, in_grace: bool },
    /// Settled (`saved`), but a child of it still waits: a parent's SIGTERM follows its children's.
    Settled { since: Instant, in_grace: bool },
}

impl SaveWait {
    fn waiting(self) -> bool {
        matches!(self, SaveWait::Waiting { .. })
    }

    fn settled(self) -> bool {
        matches!(self, SaveWait::Settled { .. })
    }
}

/// Which stop `stop_tree` makes (RUY-1099).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StopKind {
    /// `Stop` (Close game): the save wait, then the SIGTERM and the whole `STOP_GRACE`.
    Close,
    /// `stop_all` (power off): the save wait counts inside `STOP_GRACE`, so the bound of
    /// `shutdown::STOP_ALL_WAIT` holds.
    PowerOff,
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
    /// The profile's Unix user ("ruya-p1").
    user: String,
    app_id: String,
    /// The Library1 item id (ADR-041): `flatpak:<app_id>`, or `steam:<appid>` for a Steam child.
    item: String,
    /// The parent's instance name for a child instance (ADR-041), else "".
    parent: String,
    /// May this record's own unit and scopes be frozen (`Spawner::may_freeze`; a child: always)?
    freeze_own: bool,
    profile: String,
    started: i64,
    state: State,
    /// Did the app ever get to `running`? Decides `launch-failed`.
    reached_running: bool,
    stop_asked: Option<Instant>,
    kill_sent: bool,
    /// `kill` was asked (RUY-736): its end is "killed", whatever signal the unit died of.
    kill_asked: bool,
    /// An adopted unit of a profile that no longer exists: being stopped, never listed or
    /// reported (the shell never heard of it).
    hidden: bool,
    /// Frozen by `freeze` and not thawed since (T-457).
    frozen: bool,
    /// When this freeze began (T-466; an adopted frozen app: when it was adopted).
    frozen_at: Option<Instant>,
    /// Paused without being frozen, since then: a Freeze reached this instance but its app may not
    /// be frozen itself (`freeze_own` false, ADR-042). Separate from `frozen`, which is this
    /// record's own (ADR-041 point 7); it parks the instance's sound (`sync_audio`) and is told as
    /// `Background` (RUY-1099). Cleared by a Thaw and a Stop (both tell `Resume`) and the exit.
    held: Option<Instant>,
    /// The save wait of its `Stop` (RUY-1099): `state` is `Stopping`, the SIGTERM not sent yet.
    save: SaveWait,
    reclaim: Reclaim,
    /// A Steam game launched by `launch_steam_game` that waits for its scope: when it was asked
    /// (`tick` ends it after `CHILD_LAUNCH_WAIT`). `None` once it runs, and for every other record.
    launch_asked: Option<Instant>,
    /// Such a game ended before its scope came (Stop, Kill, its parent's Stop or Kill, the wait
    /// running out): it is `stopping` until `tick` reports it with this reason (code -1) and
    /// removes it. The OS is never asked: there is nothing of it to reach.
    cancelled: Option<ExitReason>,
}

/// Why `freeze_at` freezes: the Hub's pause of the signed-in profile's app, or a profile that left.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Pause {
    Hub,
    Away,
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
    /// The last sound request per profile user (`app_audio`: frozen apps, running apps), kept
    /// while it has a frozen app (T-466).
    audio_sent: HashMap<String, (Vec<String>, Vec<String>)>,
    /// The signed-in profile as the last `profile_changed` saw it (RUY-568): what the start check
    /// falls back to when `Profiles1` cannot be read.
    last_active: Option<String>,
    /// Did the listing `adopt` merged last see everything (RUY-23)?
    adopted_all: bool,
    /// Platform1 is told (RUY-1099, `with_lifecycle`): the notices go here, and the deadline of a
    /// `Stop`'s save wait. `None`: nothing is told, and a `Stop` sends its SIGTERM at once.
    lifecycle: Option<(Sender<LifecycleNotice>, Duration)>,
}

impl<S: Spawner, D: ProfileDirectory> Session<S, D> {
    /// The signed-in profile the watcher saw last (`""`: locked), `None` before its first value.
    pub fn last_active(&self) -> Option<&str> {
        self.last_active.as_deref()
    }

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
            audio_sent: HashMap::new(),
            last_active: None,
            adopted_all: true,
            lifecycle: None,
        }
    }

    /// The instances' lifecycle is told to Platform1 (RUY-1099, ADR-022): every `LifecycleNotice`
    /// goes to `outbox`, in order, and a `Stop` waits for its `Stopping` (deadline `save_wait`,
    /// `SAVE_WAIT` on the console) to settle (`saved`) before its SIGTERM. A notice the outbox no
    /// longer takes is dropped, and a `Stop` then sends its SIGTERM at once.
    pub fn with_lifecycle(mut self, outbox: Sender<LifecycleNotice>, save_wait: Duration) -> Self {
        self.lifecycle = Some((outbox, save_wait));
        self
    }

    /// The listing of `instance`'s own active scopes (`Spawner::scope_lister`), for the adapter to
    /// run without the lock: whom a `LifecycleNotice` is for.
    pub fn scope_lister(&self, instance: &str) -> ScopeLister {
        self.spawner.scope_lister(instance)
    }

    /// Hands `event` for the instance at `at` to the outbox. False when nothing is told (no
    /// outbox, or it is closed).
    fn tell(&self, at: usize, event: LifecycleEvent, now: Instant) -> bool {
        let Some((outbox, _)) = &self.lifecycle else {
            return false;
        };
        let inst = &self.instances[at];
        outbox
            .try_send(LifecycleNotice {
                instance: inst.unit.clone(),
                profile: inst.profile.clone(),
                event,
                at: now,
            })
            .is_ok()
    }

    /// Tells the instance at `at` that its hold or freeze, begun at `since`, ended at `now`.
    fn tell_resume(&self, at: usize, since: Instant, now: Instant) {
        let frozen_ms =
            u64::try_from(now.saturating_duration_since(since).as_millis()).unwrap_or(u64::MAX);
        self.tell(at, LifecycleEvent::Resume { frozen_ms }, now);
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
    /// wall clock in seconds, for the `started` field. `launch_args` follow the app id
    /// (`Spawner::start`); the adapter asks for them before it takes the lock.
    pub fn launch(
        &mut self,
        app_id: &str,
        profile: &str,
        unix: i64,
        launch_args: &[String],
    ) -> (Status, String) {
        if !valid_session_app_id(app_id) || !valid_profile_id(profile) {
            return (Status::Invalid, String::new());
        }
        let Some(user) = self.directory.unix_user(profile) else {
            return (Status::UnknownProfile, String::new());
        };
        // The app's own instance; a Steam game's child carries Steam's app id too.
        let same =
            |i: &&Instance| i.app_id == app_id && i.profile == profile && i.parent.is_empty();
        if self
            .instances
            .iter()
            .filter(same)
            .any(|i| i.state != State::Stopping)
        {
            return (Status::AlreadyRunning, String::new());
        }
        if self.instances.iter().any(|i| same(&i)) {
            // The old unit was told to stop and is not gone yet: its name is still taken. The
            // adapter waits for it (`is_stopping`) before it gets here; this is the answer when the
            // wait ran out. With the 30 s backstop (RUY-736) a run may stay that long: it is still
            // there, so "already-running" (the shell says the game is still closing).
            eprintln!("ruya-session: {app_id} is still ending, not launched");
            return (Status::AlreadyRunning, String::new());
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
        match self.spawner.start(&user, app_id, &env, launch_args) {
            Ok(unit) => {
                self.instances.push(Instance {
                    unit: unit.clone(),
                    user: user.clone(),
                    app_id: app_id.to_owned(),
                    item: flatpak_item(app_id),
                    parent: String::new(),
                    freeze_own: self.spawner.may_freeze(app_id),
                    profile: profile.to_owned(),
                    started: unix,
                    state: State::Starting,
                    reached_running: false,
                    stop_asked: None,
                    kill_sent: false,
                    kill_asked: false,
                    hidden: false,
                    frozen: false,
                    frozen_at: None,
                    held: None,
                    save: SaveWait::Off,
                    reclaim: Reclaim::Waiting,
                    launch_asked: None,
                    cancelled: None,
                });
                // A new app of a profile with a frozen one may play: its sound must not be parked.
                self.sync_audio(&user, false);
                (Status::Ok, unit)
            }
            Err(err) => {
                eprintln!("ruya-session: starting {app_id} failed: {err}");
                (Status::Failed, String::new())
            }
        }
    }

    /// `LaunchItem` of the Steam game `appid` (ADR-041 point 3, RUY-1067): the status and the
    /// child's instance name. A child of that game for this profile, whatever its state (launched
    /// here or started in Steam's own UI), is "already-running" with its name, and nothing is
    /// asked of the OS. Otherwise, when the profile's Steam is not running (or is on its way out),
    /// it is launched as `launch` does, with `steam://rungameid/<appid>` as its argument (the
    /// profile check, a Steam still ending, "unknown-app" and the sound are `launch`'s); when it
    /// runs or starts, the URL is handed to it (`Spawner::forward_steam_url`) and Steam's record is
    /// unchanged. Then the child is listed `starting` under the name its scope will give it
    /// (`child_name`), until `ChildStarted` or `tick`'s `CHILD_LAUNCH_WAIT`. A failed start or
    /// forwarder is "failed"; no record is left after any refusal. `unix` dates the records, `now`
    /// starts the wait.
    pub fn launch_steam_game(
        &mut self,
        appid: &str,
        profile: &str,
        unix: i64,
        now: Instant,
    ) -> (Status, String) {
        let Some(url) = steam_run_url(appid) else {
            return (Status::Invalid, String::new());
        };
        if !valid_profile_id(profile) {
            return (Status::Invalid, String::new());
        }
        let Some(user) = self.directory.unix_user(profile) else {
            return (Status::UnknownProfile, String::new());
        };
        let item = steam_item(appid);
        if let Some(child) = self
            .instances
            .iter()
            .find(|i| i.item == item && i.profile == profile && !i.hidden)
        {
            return (Status::AlreadyRunning, child.unit.clone());
        }
        let steam = self
            .instances
            .iter()
            .find(|i| {
                i.app_id == STEAM_APP_ID
                    && i.profile == profile
                    && i.parent.is_empty()
                    && i.state != State::Stopping
            })
            .map(|i| i.unit.clone());
        let parent = match steam {
            Some(parent) => {
                if !self.spawner.is_installed(STEAM_APP_ID) {
                    return (Status::UnknownApp, String::new());
                }
                if let Err(err) = self.spawner.forward_steam_url(&user, appid) {
                    eprintln!("ruya-session: {item} not handed to {parent}: {err}");
                    return (Status::Failed, String::new());
                }
                parent
            }
            None => match self.launch(STEAM_APP_ID, profile, unix, &[url]) {
                (Status::Ok, parent) => parent,
                refused => return refused,
            },
        };
        let child = crate::spawner::child_name(&parent, appid);
        let Some(p_at) = self.instances.iter().position(|i| i.unit == parent) else {
            // `launch` and the lookup above both left Steam's record there.
            return (Status::Failed, String::new());
        };
        let inst = self.child_of(p_at, child.clone(), appid, unix, Some(now));
        self.instances.push(inst);
        self.sync_audio(&user, false);
        (Status::Ok, child)
    }

    /// The record of the Steam game `appid` named `unit` in the run of the parent at `p_at`
    /// (ADR-041): the parent's user, profile, app id and `hidden`, item `steam:<appid>`, its own
    /// `frozen` (false here). `launch_asked` `Some` is a game `launch_steam_game` asked for, which
    /// is `starting` until its scope comes; `None` is one whose scope is there (`child_started`),
    /// `running`. `started` 0 takes the parent's.
    fn child_of(
        &self,
        p_at: usize,
        unit: String,
        appid: &str,
        started: i64,
        launch_asked: Option<Instant>,
    ) -> Instance {
        let p = &self.instances[p_at];
        let runs = launch_asked.is_none();
        Instance {
            unit,
            user: p.user.clone(),
            app_id: p.app_id.clone(),
            item: steam_item(appid),
            parent: p.unit.clone(),
            freeze_own: true,
            profile: p.profile.clone(),
            started: if started > 0 { started } else { p.started },
            state: if runs {
                State::Running
            } else {
                State::Starting
            },
            reached_running: runs,
            stop_asked: None,
            kill_sent: false,
            kill_asked: false,
            hidden: p.hidden,
            frozen: false,
            frozen_at: None,
            held: None,
            save: SaveWait::Off,
            reclaim: Reclaim::Waiting,
            launch_asked,
            cancelled: None,
        }
    }

    /// Ends the Steam game at `at` that still waits for its scope (`launch_asked`), with `reason`,
    /// in the core alone: it is `stopping` until `tick` reports and removes it. Nothing is asked
    /// of the OS (there is no scope of it yet). A later reason replaces an earlier one (a Kill
    /// after a Stop is "killed").
    fn cancel_launch(&mut self, at: usize, reason: ExitReason) {
        let inst = &mut self.instances[at];
        inst.cancelled = Some(reason);
        let was_stopping = inst.state == State::Stopping;
        inst.state = State::Stopping;
        if !was_stopping {
            let user = inst.user.clone();
            self.sync_audio(&user, false);
        }
    }

    /// Does the record at `at` wait for its scope (a Steam game launched by `launch_steam_game`)?
    fn awaits_scope(&self, at: usize) -> bool {
        self.instances[at].launch_asked.is_some()
    }

    /// Is an instance of this app of this profile on its way out (told to stop, not gone yet)?
    pub fn is_stopping(&self, app_id: &str, profile: &str) -> bool {
        self.instances.iter().any(|i| {
            i.app_id == app_id
                && i.profile == profile
                && i.parent.is_empty()
                && i.state == State::Stopping
        })
    }

    /// The positions of `unit`'s child instances (ADR-041), in the order they started. Stop, Kill,
    /// Freeze and Thaw never remove an instance, so the positions stay valid through them.
    fn children_of(&self, unit: &str) -> Vec<usize> {
        self.instances
            .iter()
            .enumerate()
            .filter(|(_, i)| i.parent == unit)
            .map(|(at, _)| at)
            .collect()
    }

    /// Asks the app to quit; `tick` kills it if it does not. Stopping an instance that is
    /// already stopping is `Ok` and changes nothing. The grace time starts when the stop is sent:
    /// `clock` is read after the thaw of a frozen app, so a slow thaw does not eat it. A parent's
    /// children are stopped first (ADR-041 point 7; a child's failed stop is logged, the parent is
    /// stopped anyway).
    ///
    /// A Steam game that still waits for its scope ends in the core (`cancel_launch`, no call to
    /// the OS): "quit" when it is the one stopped, "launch-failed" when its parent is.
    ///
    /// With `with_lifecycle` (RUY-1099) each instance stopped is first told `Stopping` (after the
    /// `Resume` of its thaw or hold) and is `stopping` from then on, but its SIGTERM waits until
    /// the adapter reports the `Stopping` settled (`saved`), or `tick` finds its deadline passed;
    /// the grace starts at the SIGTERM. A parent's SIGTERM still follows its children's.
    pub fn stop(&mut self, instance: &str, clock: impl Clock) -> Status {
        self.stop_tree(instance, clock, StopKind::Close)
    }

    /// `stop` (`StopKind::Close`) or the stop of `stop_all` (`StopKind::PowerOff`: the grace
    /// counts from the `Stopping`, also for an instance whose Close game still waits for its save).
    fn stop_tree(&mut self, instance: &str, clock: impl Clock, kind: StopKind) -> Status {
        let Some(at) = self.instances.iter().position(|i| i.unit == instance) else {
            return Status::UnknownInstance;
        };
        if self.instances[at].state == State::Stopping {
            if let (StopKind::PowerOff, SaveWait::Waiting { since, .. }) =
                (kind, self.instances[at].save)
            {
                self.instances[at].save = SaveWait::Waiting {
                    since,
                    in_grace: true,
                };
            }
            return Status::Ok;
        }
        if self.awaits_scope(at) {
            self.cancel_launch(at, ExitReason::Quit);
            return Status::Ok;
        }
        let now = || clock.now();
        for child in self.children_of(instance) {
            if self.instances[child].state == State::Stopping {
                continue;
            }
            if self.awaits_scope(child) {
                self.cancel_launch(child, ExitReason::LaunchFailed);
            } else {
                self.stop_at(child, now, kind);
            }
        }
        self.stop_at(at, now, kind)
    }

    /// The stop of the one instance at `at` (not stopping yet): a frozen one is thawed first, and
    /// a held or frozen one is told `Resume`. With `with_lifecycle` it is told `Stopping` and
    /// waits for `saved` (not a hidden one: its profile is gone); otherwise its SIGTERM goes now
    /// (`send_stop`).
    fn stop_at(&mut self, at: usize, clock: impl Clock, kind: StopKind) -> Status {
        let inst = &mut self.instances[at];
        let held_since = inst.held.take();
        let mut paused_since = held_since;
        if inst.frozen {
            // A frozen app cannot handle the SIGTERM of the stop: thaw it first (T-457). A failed
            // thaw still stops it; the kill after the grace time ends even a frozen process.
            if inst.reclaim == Reclaim::Sent {
                self.spawner.cancel_reclaim(&inst.unit);
            }
            let frozen_since = inst.frozen_at.take();
            inst.reclaim = Reclaim::Waiting;
            match self.spawner.thaw(&inst.unit) {
                Ok(()) => paused_since = earlier(held_since, frozen_since),
                Err(err) => {
                    // Still frozen: it is not told that it runs again.
                    paused_since = None;
                    eprintln!(
                        "ruya-session: thawing {} before its stop failed: {err}",
                        inst.unit
                    );
                }
            }
            inst.frozen = false;
            self.frozen_changes.push(FrozenChange {
                instance: inst.unit.clone(),
                frozen: false,
            });
        }
        // Read after the thaw, as the grace's start is.
        let now = clock.now();
        if let Some(since) = paused_since {
            self.tell_resume(at, since, now);
        }
        let deadline = self.lifecycle.as_ref().map(|(_, wait)| *wait);
        if let (false, Some(deadline)) = (self.instances[at].hidden, deadline) {
            let deadline_ms = u64::try_from(deadline.as_millis()).unwrap_or(u64::MAX);
            if self.tell(at, LifecycleEvent::Stopping { deadline_ms }, now) {
                let inst = &mut self.instances[at];
                inst.state = State::Stopping;
                inst.save = SaveWait::Waiting {
                    since: now,
                    in_grace: kind == StopKind::PowerOff,
                };
                let user = inst.user.clone();
                self.sync_audio(&user, false);
                return Status::Ok;
            }
        }
        self.send_stop(at, clock)
    }

    /// The SIGTERM of the instance at `at` (`Spawner::stop`): it is then `stopping`, and the grace
    /// of `tick`'s backstop starts, now or, for a power off's save wait, when its `Stopping` was
    /// told.
    fn send_stop(&mut self, at: usize, clock: impl Clock) -> Status {
        let inst = &mut self.instances[at];
        let grace_from = match std::mem::replace(&mut inst.save, SaveWait::Off) {
            SaveWait::Waiting {
                since,
                in_grace: true,
            }
            | SaveWait::Settled {
                since,
                in_grace: true,
            } => Some(since),
            _ => None,
        };
        let user = inst.user.clone();
        let status = match self.spawner.stop(&inst.unit) {
            Ok(()) => {
                inst.state = State::Stopping;
                inst.stop_asked = Some(grace_from.unwrap_or_else(|| clock.now()));
                Status::Ok
            }
            Err(err) => {
                eprintln!("ruya-session: stopping {} failed: {err}", inst.unit);
                Status::Failed
            }
        };
        self.sync_audio(&user, false);
        status
    }

    /// The `Stopping` of `instance` has settled (RUY-1099): the app saved, its deadline passed,
    /// nothing of it is registered, or Platform1 did not answer in time. Its SIGTERM goes now,
    /// unless a child of it still waits (then it follows that child's), it was killed meanwhile,
    /// or it has ended. `UnknownInstance` when no such instance waits. A parent whose own wait had
    /// settled and that waited only for this child is stopped too.
    pub fn saved(&mut self, instance: &str, clock: impl Clock) -> Status {
        let status = match self
            .instances
            .iter()
            .position(|i| i.unit == instance && i.save.waiting())
        {
            Some(at) => {
                self.settle(at);
                Status::Ok
            }
            None => Status::UnknownInstance,
        };
        self.release_settled(clock);
        status
    }

    /// The save wait at `at` (waiting) has settled.
    fn settle(&mut self, at: usize) {
        if let SaveWait::Waiting { since, in_grace } = self.instances[at].save {
            self.instances[at].save = SaveWait::Settled { since, in_grace };
        }
    }

    /// Sends the SIGTERM of every settled save wait none of whose children still waits, children
    /// first.
    fn release_settled(&mut self, clock: impl Clock) {
        while let Some(at) = (0..self.instances.len()).find(|&at| {
            self.instances[at].save.settled()
                && self
                    .children_of(&self.instances[at].unit)
                    .iter()
                    .all(|&c| self.instances[c].save == SaveWait::Off)
        }) {
            let now = clock.now();
            if self.send_stop(at, now) != Status::Ok {
                // It was told it stops already: the backstop's kill follows after the grace.
                self.instances[at].stop_asked.get_or_insert(now);
            }
        }
    }

    /// The system goes down (RUY-888, `StopAll`): every app of every profile, frozen or not,
    /// starting, running or hidden, is stopped through `stop`, one after the other, so a frozen
    /// one is thawed right before its own SIGTERM and `tick` kills only what outlives the grace.
    /// Returns each instance asked, with the outcome; an app already stopping is `Ok` and keeps
    /// its grace. With `with_lifecycle` (RUY-1099) each one gets the save wait of `stop`, all at
    /// once, but its grace counts from its `Stopping`: the save window is part of `STOP_GRACE`
    /// (an instance whose Close game still waits for its save too), so the bound of
    /// `shutdown::STOP_ALL_WAIT` holds.
    pub fn stop_all(&mut self, clock: impl Clock + Copy) -> Vec<(String, Status)> {
        let units: Vec<String> = self.instances.iter().map(|i| i.unit.clone()).collect();
        units
            .into_iter()
            .map(|unit| {
                let status = self.stop_tree(&unit, clock, StopKind::PowerOff);
                (unit, status)
            })
            .collect()
    }

    /// Is any of `units` still known (not ended yet)? What `StopAll` waits on.
    pub fn any_left(&self, units: &[String]) -> bool {
        self.instances.iter().any(|i| units.contains(&i.unit))
    }

    /// Ends the app at once (RUY-736, the closing screen's Force quit): SIGKILL to the unit, if it
    /// is still loaded, and every scope of the app (`Spawner::kill`). A starting, running, stopping
    /// or frozen app of the signed-in profile (`active`; `None` in development mode, no check); a
    /// frozen one is not thawed (the kill ends it anyway). The instance is then stopping and its end
    /// is "killed". `tick` sends no second kill for it; a second `kill` does. `clock` gives the
    /// start of the stop for an app that was not stopping yet.
    ///
    /// A parent's children are killed first (ADR-041 point 7; a child's failed kill is logged, the
    /// parent is killed anyway). A Steam game that still waits for its scope ends in the core, as
    /// for `stop`: "killed" when it is the one killed, "launch-failed" when its parent is.
    pub fn kill(&mut self, instance: &str, active: Option<&str>, clock: impl Clock) -> Status {
        let Some(at) = self
            .instances
            .iter()
            .position(|i| i.unit == instance && !i.hidden)
        else {
            return Status::UnknownInstance;
        };
        if active.is_some_and(|a| a.is_empty() || a != self.instances[at].profile) {
            return Status::NotAllowed;
        }
        if self.awaits_scope(at) {
            self.cancel_launch(at, ExitReason::Killed);
            return Status::Ok;
        }
        let now = || clock.now();
        for child in self.children_of(instance) {
            if !self.awaits_scope(child) {
                self.kill_at(child, now);
            } else if self.instances[child].cancelled.is_none() {
                self.cancel_launch(child, ExitReason::LaunchFailed);
            }
        }
        self.kill_at(at, now)
    }

    /// The kill of the one instance at `at`.
    fn kill_at(&mut self, at: usize, clock: impl Clock) -> Status {
        let inst = &mut self.instances[at];
        if let Err(err) = self.spawner.kill(&inst.unit) {
            eprintln!("ruya-session: killing {} failed: {err}", inst.unit);
            return Status::Failed;
        }
        eprintln!("ruya-session: killing {} (Kill)", inst.unit);
        if inst.reclaim == Reclaim::Sent {
            self.spawner.cancel_reclaim(&inst.unit);
            inst.reclaim = Reclaim::Skipped;
        }
        inst.kill_asked = true;
        inst.kill_sent = true;
        // A save wait ends here: the kill replaces its SIGTERM (`saved` sends none).
        inst.save = SaveWait::Off;
        let was_stopping = inst.state == State::Stopping;
        inst.state = State::Stopping;
        inst.stop_asked.get_or_insert_with(|| clock.now());
        if !was_stopping {
            let user = inst.user.clone();
            self.sync_audio(&user, false);
        }
        Status::Ok
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
    ///
    /// T-466: a frozen app's sound is parked (`app_audio`) and, after `RECLAIM_AFTER`, its memory
    /// is moved to swap (`tick`); `now` is when this freeze begins.
    pub fn freeze(&mut self, instance: &str, active: Option<&str>, now: Instant) -> Status {
        match self.freezable(instance, active) {
            Ok(at) => self.freeze_at(at, now, Pause::Hub),
            Err(status) => status,
        }
    }

    /// The freezer path of `freeze` and `profile_changed`: the running instance at `at` is frozen
    /// (already frozen: `Ok`, the OS is not asked again), or a failed freeze is undone. ADR-041
    /// point 7: a parent's running children first, then its own unit and scopes; a failure undoes
    /// what this call froze. A Hub pause (`Pause::Hub`) freezes an app's own unit only when it may
    /// be frozen (`freeze_own`, ADR-042 point 3: a `never` app is held); a profile that leaves
    /// (`Pause::Away`) freezes it whatever `freeze_own` says (ADR-046 point 2, RUY-1063: a
    /// running Steam of a profile that left keeps its `/dev/uinput` descriptor, and a device it
    /// made later would be credited to the next profile).
    fn freeze_at(&mut self, at: usize, now: Instant, pause: Pause) -> Status {
        let mut froze = Vec::new();
        for child in self.children_of(&self.instances[at].unit.clone()) {
            let c = &self.instances[child];
            if c.frozen || c.hidden || c.state != State::Running {
                continue;
            }
            if self.freeze_one(child, now) != Status::Ok {
                self.undo_freezes(&froze, now);
                return Status::Failed;
            }
            froze.push(child);
        }
        if pause == Pause::Hub && !self.instances[at].freeze_own {
            // ADR-042: the unit keeps running; only its sound is parked, with its children's. It
            // is told `Background` (RUY-1099), once, and not while it is frozen anyway.
            let inst = &mut self.instances[at];
            let newly = inst.held.is_none() && !inst.frozen;
            inst.held.get_or_insert(now);
            let user = inst.user.clone();
            self.sync_audio(&user, false);
            if newly {
                self.tell(at, LifecycleEvent::Background, now);
            }
            return Status::Ok;
        }
        let status = self.freeze_one(at, now);
        if status != Status::Ok {
            self.undo_freezes(&froze, now);
        }
        status
    }

    /// Thaws what a failed `freeze_at` had frozen already, so nothing of it stays frozen.
    fn undo_freezes(&mut self, froze: &[usize], now: Instant) {
        for &at in froze {
            self.thaw_one(at, now, None);
        }
    }

    /// The freeze of the one instance at `at`.
    fn freeze_one(&mut self, at: usize, now: Instant) -> Status {
        let inst = &mut self.instances[at];
        if inst.frozen {
            return Status::Ok;
        }
        match self.spawner.freeze(&inst.unit) {
            Ok(()) => {
                eprintln!("{}", freezer_line(&inst.unit, "Freeze"));
                inst.frozen = true;
                inst.frozen_at = Some(now);
                inst.reclaim = Reclaim::Waiting;
                self.frozen_changes.push(FrozenChange {
                    instance: inst.unit.clone(),
                    frozen: true,
                });
                let user = inst.user.clone();
                self.sync_audio(&user, false);
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

    /// The signed-in profile changed from `old` to `new` (`""`: locked), T-165 and ADR-004: every
    /// running app of `old` is frozen through the freezer path of `freeze`, so a profile that leaves
    /// (a switch from the Hub or the picker, a sign-out, the idle lock) leaves no game running
    /// behind the next one. Its apps stay frozen until it signs in again, when the shell thaws them
    /// (`thaw` serves only the signed-in profile's apps). `old` is `None` when it is not known (the
    /// first value after this service started): then the apps of every profile but `new` are
    /// frozen. A frozen app is left as it is; an app still starting or stopping is not frozen. A
    /// failed freeze is undone like `freeze`'s, and the app keeps running. Returns each app asked,
    /// with the outcome, for the journal.
    pub fn profile_changed(
        &mut self,
        old: Option<&str>,
        new: &str,
        now: Instant,
    ) -> Vec<(String, Status)> {
        self.last_active = Some(new.to_owned());
        if old == Some(new) {
            return Vec::new();
        }
        let away: Vec<usize> = self
            .instances
            .iter()
            .enumerate()
            .filter(|(_, i)| {
                !i.hidden
                    && !i.frozen
                    && i.state == State::Running
                    && i.profile != new
                    && match old {
                        Some(o) => i.profile == o,
                        None => true,
                    }
            })
            .map(|(at, _)| at)
            .collect();
        // `freeze_at` never removes an instance, so the positions stay valid.
        away.into_iter()
            .map(|at| {
                let status = self.freeze_at(at, now, Pause::Away);
                (self.instances[at].unit.clone(), status)
            })
            .collect()
    }

    /// RUY-568: an app that reached running (`on_event(Started)`) after its profile left is frozen
    /// now, through the freezer path of `profile_changed`; `profile_changed` freezes only apps
    /// that were already running. `active` is the signed-in profile now (`""`: locked). Returns
    /// the outcome when a freeze was tried, `None` when there was nothing to do: an unknown,
    /// hidden, not running or frozen instance, or one of the signed-in profile.
    pub fn freeze_if_away(&mut self, instance: &str, active: &str, now: Instant) -> Option<Status> {
        let at = self.instances.iter().position(|i| {
            i.unit == instance
                && !i.hidden
                && !i.frozen
                && i.state == State::Running
                && i.profile != active
        })?;
        Some(self.freeze_at(at, now, Pause::Away))
    }

    /// Thaws a running app of the signed-in profile (T-457). The OS is asked even when the app is
    /// not known to be frozen (a restart of this service forgets it); thawing a running app is a
    /// no-op there. A failed thaw keeps `frozen`, so a later Thaw or Stop tries again. ADR-041
    /// point 7: a parent's running children are thawed first, then its own unit and scopes when
    /// its app may be frozen (what `freeze_at` froze); any failure is `Failed`, after every thaw
    /// was tried. Every record that was frozen or held and runs again is told `Resume`, with how
    /// long that lasted (RUY-1099); `now` is when the thaw happens.
    pub fn thaw(&mut self, instance: &str, active: Option<&str>, now: Instant) -> Status {
        let at = match self.freezable(instance, active) {
            Ok(at) => at,
            Err(status) => return status,
        };
        let mut status = Status::Ok;
        let held_since = self.instances[at].held.take();
        for child in self.children_of(instance) {
            let c = &self.instances[child];
            if c.hidden || c.state != State::Running {
                continue;
            }
            if self.thaw_one(child, now, None) != Status::Ok {
                status = Status::Failed;
            }
        }
        if held_since.is_some() {
            let user = self.instances[at].user.clone();
            self.sync_audio(&user, false);
        }
        // A record frozen anyway (adopted frozen, its app's rule changed, or a `never` app frozen
        // because its profile left, RUY-1063) is thawed too.
        let own = &self.instances[at];
        if own.freeze_own || own.frozen {
            if self.thaw_one(at, now, held_since) != Status::Ok {
                status = Status::Failed;
            }
        } else if let Some(since) = held_since {
            self.tell_resume(at, since, now);
        }
        status
    }

    /// The thaw of the one instance at `at`. When it works and the record was frozen, or held
    /// since `held_since`, it is told `Resume` from the earlier of the two.
    fn thaw_one(&mut self, at: usize, now: Instant, held_since: Option<Instant>) -> Status {
        let inst = &mut self.instances[at];
        if inst.reclaim == Reclaim::Sent {
            // A reclaim still running would page the game out while it plays again (T-466).
            self.spawner.cancel_reclaim(&inst.unit);
            inst.reclaim = Reclaim::Skipped;
        }
        match self.spawner.thaw(&inst.unit) {
            Ok(()) => {
                eprintln!("{}", freezer_line(&inst.unit, "Thaw"));
                let frozen_since = inst.frozen.then_some(inst.frozen_at).flatten();
                if let Some(since) = earlier(held_since, frozen_since) {
                    self.tell_resume(at, since, now);
                }
                let inst = &mut self.instances[at];
                if inst.frozen {
                    inst.frozen = false;
                    inst.frozen_at = None;
                    inst.reclaim = Reclaim::Waiting;
                    self.frozen_changes.push(FrozenChange {
                        instance: inst.unit.clone(),
                        frozen: false,
                    });
                    let user = inst.user.clone();
                    self.sync_audio(&user, false);
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

    /// The listing of the running app units as a closure for the caller to run without the
    /// session lock (RUY-621): `loginctl` and a `systemctl` per profile may take seconds, and a
    /// `Session1` call must not wait for them. `adopt_listed` takes its result.
    pub fn adopt_lister(&self) -> AdoptLister {
        self.spawner.adopt_lister()
    }

    /// Start-up and every later pass: takes over the app units that run already (a restart of
    /// this service does not end the apps). Lists them itself; the service lists outside the
    /// lock and calls `adopt_listed`.
    pub fn adopt(&mut self, unix: i64, now: Instant, profiles_known: bool) -> Vec<RunningApp> {
        let listing = (self.spawner.adopt_lister())();
        self.adopt_listed(listing, unix, now, profiles_known)
    }

    /// Merges a `listing`: the units are `running` from the start and announce nothing; their
    /// end is reported like any other. A unit this session knows already is skipped (a pass can
    /// race a normal launch, or an earlier pass). When the profiles are `known` (the directory is
    /// current), a unit of a profile that no longer exists is stopped and never listed. Returns
    /// the apps taken over by this call, not the ones an earlier pass listed.
    pub fn adopt_listed(
        &mut self,
        listing: Listing,
        unix: i64,
        now: Instant,
        profiles_known: bool,
    ) -> Vec<RunningApp> {
        self.adopted_all = listing.complete;
        let mut gained: Vec<String> = Vec::new();
        let mut units: Vec<String> = Vec::new();
        for found in listing.found {
            let Some(profile) = profile_of_user(&found.user) else {
                continue;
            };
            if !valid_session_app_id(&found.app_id)
                || self.instances.iter().any(|i| i.unit == found.unit)
            {
                continue;
            }
            // Ended while the listing ran beside the event loop: its end found no instance and
            // was dropped, so adding it now would leave a unit nothing ever ends (RUY-621).
            if !self.spawner.tracks(&found.unit) {
                continue;
            }
            let orphan = profiles_known && self.directory.unix_user(profile).is_none();
            let mut inst = Instance {
                unit: found.unit,
                user: found.user.clone(),
                item: flatpak_item(&found.app_id),
                parent: String::new(),
                freeze_own: self.spawner.may_freeze(&found.app_id),
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
                kill_asked: false,
                hidden: orphan,
                // Left frozen by a Freeze before the restart: listed as frozen, so a Stop thaws it
                // first and a Thaw announces the change (T-457).
                frozen: found.frozen,
                frozen_at: found.frozen.then_some(now),
                held: None,
                save: SaveWait::Off,
                reclaim: Reclaim::Waiting,
                launch_asked: None,
                cancelled: None,
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
            gained.push(inst.user.clone());
            units.push(inst.unit.clone());
            self.instances.push(inst);
        }
        // Whatever was parked before the restart is set right for the users that gained an
        // instance: frozen apps parked, the rest put back (T-466). The others are unchanged.
        gained.sort();
        gained.dedup();
        for user in gained {
            self.sync_audio(&user, true);
        }
        self.list()
            .into_iter()
            .filter(|a| units.contains(&a.instance))
            .collect()
    }

    /// Did the last merged listing see everything? When not, the service lists again later
    /// (RUY-23).
    pub fn adoption_complete(&self) -> bool {
        self.adopted_all
    }

    /// The instance a process belongs to (T-459): its cgroup is read, and the instance whose unit,
    /// or one of whose app's Flatpak scopes (`is_app_scope`, any of an Electron app's two), holds
    /// it in the manager of that instance's own user is the answer. The deepest unit on the
    /// process's path decides. A hidden instance (of a removed profile) is never named. A scope of
    /// a child instance (`Spawner::child_of_scope`, a Steam game) names the child, not its parent
    /// (ADR-041 point 5).
    pub fn instance_of_pid(&self, pid: u32) -> (Status, String) {
        if pid == 0 {
            return (Status::Invalid, String::new());
        }
        let found = self
            .spawner
            .process_cgroup(pid)
            .and_then(|text| parse_cgroup(&text))
            .and_then(|place| {
                let user = self.spawner.user_name(place.uid)?;
                place.units.iter().find_map(|unit| {
                    let child = self.spawner.child_of_scope(&user, unit).and_then(|name| {
                        self.instances
                            .iter()
                            .find(|i| i.unit == name && i.user == user && !i.hidden)
                    });
                    if let Some(child) = child {
                        return Some(child.unit.clone());
                    }
                    self.instances
                        .iter()
                        .filter(|i| !i.hidden)
                        .filter(|i| unit_app_id(&user, &i.unit).as_deref() == Some(&i.app_id))
                        .find(|i| i.unit == *unit || is_app_scope(&i.app_id, unit))
                        .map(|i| i.unit.clone())
                })
            });
        match found {
            Some(instance) => (Status::Ok, instance),
            None => (Status::NotFound, String::new()),
        }
    }

    pub fn list(&self) -> Vec<RunningApp> {
        self.instances
            .iter()
            .filter(|i| !i.hidden)
            .map(|i| RunningApp {
                instance: i.unit.clone(),
                app_id: i.app_id.clone(),
                item: i.item.clone(),
                parent: i.parent.clone(),
                profile: i.profile.clone(),
                started: i.started,
                state: i.state,
                frozen: i.frozen,
            })
            .collect()
    }

    /// Takes in what the OS reports; the notices to send, in order (an instance's end comes after
    /// the ends of its children). Events for units we do not know are ignored.
    pub fn on_event(&mut self, event: UnitEvent) -> Vec<Notice> {
        match event {
            UnitEvent::Started { unit } => {
                let Some(inst) = self.instances.iter_mut().find(|i| i.unit == unit) else {
                    return Vec::new();
                };
                if inst.reached_running || inst.hidden {
                    return Vec::new();
                }
                inst.reached_running = true;
                if inst.state == State::Starting {
                    inst.state = State::Running;
                }
                vec![Notice::Started {
                    instance: inst.unit.clone(),
                    app_id: inst.app_id.clone(),
                }]
            }
            UnitEvent::Exited {
                unit,
                code,
                signaled,
            } => self.end(&unit, |inst| exit_reason(inst, code, signaled)),
            UnitEvent::ExecFailed { unit } => self.end(&unit, |inst| {
                // The program never ran, whatever `Running as unit` said before: `launch-failed`
                // (code -1) unless the app was being stopped anyway.
                if inst.state == State::Stopping {
                    exit_reason(inst, 0, false)
                } else {
                    (-1, ExitReason::LaunchFailed)
                }
            }),
            UnitEvent::ChildStarted {
                parent,
                child,
                appid,
                started,
                frozen,
            } => self.child_started(&parent, child, &appid, started, frozen),
        }
    }

    /// The end of `unit`, its children's first (ADR-041 point 7: a child whose own end has not
    /// come yet ends with its parent, as a child's end would, code 0). `why` gives the parent's
    /// code and reason. A hidden instance is removed without a notice.
    fn end(&mut self, unit: &str, why: impl Fn(&Instance) -> (i32, ExitReason)) -> Vec<Notice> {
        let mut out = Vec::new();
        if !self.instances.iter().any(|i| i.unit == unit) {
            return out;
        }
        while let Some(at) = self.instances.iter().position(|i| i.parent == unit) {
            out.extend(self.remove_at(at, |c| exit_reason(c, 0, false)));
        }
        if let Some(at) = self.instances.iter().position(|i| i.unit == unit) {
            out.extend(self.remove_at(at, why));
        }
        out
    }

    /// Removes the instance at `at`: its `Exited` notice, `None` for a hidden one.
    fn remove_at(
        &mut self,
        at: usize,
        why: impl Fn(&Instance) -> (i32, ExitReason),
    ) -> Option<Notice> {
        let inst = self.instances.remove(at);
        self.sync_audio(&inst.user, false);
        if inst.hidden {
            return None;
        }
        let (exit_code, reason) = why(&inst);
        Some(Notice::Exited {
            instance: inst.unit,
            app_id: inst.app_id,
            exit_code,
            reason,
            profile: inst.profile,
            item: inst.item,
        })
    }

    /// A Steam game's first scope appeared in `parent`'s run (ADR-041 points 2 and 4): its child
    /// instance `child` is listed, `running`, with `item` `steam:<appid>`, the parent's app id,
    /// profile and user, and announced with the parent's app id. Hidden while its parent is. The
    /// game `launch_steam_game` listed `starting` under that name becomes `running` here and is
    /// announced (the one place it does, RUY-1067). Any other child that is known already (running,
    /// stopping, or ended before its scope came), a parent that is not, or a bad app id changes
    /// nothing.
    fn child_started(
        &mut self,
        parent: &str,
        child: String,
        appid: &str,
        started: i64,
        frozen: bool,
    ) -> Vec<Notice> {
        let Some(p_at) = self
            .instances
            .iter()
            .position(|i| i.unit == parent && i.parent.is_empty())
        else {
            return Vec::new();
        };
        if !valid_steam_appid(appid) {
            return Vec::new();
        }
        if let Some(known) = self.instances.iter_mut().find(|i| i.unit == child) {
            if known.parent != parent || known.state != State::Starting {
                return Vec::new();
            }
            known.state = State::Running;
            known.reached_running = true;
            known.launch_asked = None;
            known.frozen = frozen;
            if started > 0 {
                known.started = started;
            }
            return (!known.hidden)
                .then(|| Notice::Started {
                    instance: known.unit.clone(),
                    app_id: known.app_id.clone(),
                })
                .into_iter()
                .collect();
        }
        let inst = Instance {
            frozen,
            ..self.child_of(p_at, child, appid, started, None)
        };
        let notice = (!inst.hidden).then(|| Notice::Started {
            instance: inst.unit.clone(),
            app_id: inst.app_id.clone(),
        });
        let user = inst.user.clone();
        self.instances.push(inst);
        self.sync_audio(&user, false);
        notice.into_iter().collect()
    }

    /// Sends the SIGTERM of a save wait past its deadline (`end_overdue_saves`, RUY-1099), kills
    /// the apps that did not quit within `STOP_GRACE` of their `Stop`, and starts the
    /// memory reclaim of the apps frozen for `RECLAIM_AFTER` (T-466; only when swap is active,
    /// since without it a reclaim only drops clean cache). Call about once a second.
    ///
    /// It also ends the Steam games that never got their scope (RUY-1067): one still `starting`
    /// `CHILD_LAUNCH_WAIT` after its launch is "launch-failed", and every one ended before its
    /// scope came (`cancel_launch`) is reported with its reason (code -1) and removed. Returns
    /// those notices, for the adapter to deliver as it delivers `on_event`'s.
    pub fn tick(&mut self, now: Instant) -> Vec<Notice> {
        for inst in &mut self.instances {
            let waited_out = inst
                .launch_asked
                .is_some_and(|t| now.saturating_duration_since(t) >= CHILD_LAUNCH_WAIT);
            if waited_out && inst.cancelled.is_none() {
                eprintln!(
                    "ruya-session: {}: no scope of {} within {} s",
                    inst.unit,
                    inst.item,
                    CHILD_LAUNCH_WAIT.as_secs()
                );
                inst.cancelled = Some(ExitReason::LaunchFailed);
            }
        }
        let mut ended = Vec::new();
        while let Some(at) = self.instances.iter().position(|i| i.cancelled.is_some()) {
            ended.extend(self.remove_at(at, |i| exit_reason(i, 0, false)));
        }
        self.end_overdue_saves(now);
        self.kill_and_reclaim(now);
        ended
    }

    /// A save wait whose deadline has passed settles here (RUY-1099): the adapter's own bound is
    /// the same, this one holds when its answer is lost.
    fn end_overdue_saves(&mut self, now: Instant) {
        let Some(wait) = self.lifecycle.as_ref().map(|(_, wait)| *wait) else {
            return;
        };
        for at in 0..self.instances.len() {
            if let SaveWait::Waiting { since, .. } = self.instances[at].save {
                if now.saturating_duration_since(since) >= wait {
                    eprintln!(
                        "ruya-session: {}: no answer to its Stopping within {} ms",
                        self.instances[at].unit,
                        wait.as_millis()
                    );
                    self.settle(at);
                }
            }
        }
        self.release_settled(now);
    }

    /// `tick`'s backstop kills and memory reclaims.
    fn kill_and_reclaim(&mut self, now: Instant) {
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
        // A child is not reclaimed on its own: the reclaim reaches a unit and its app's scopes.
        let due = |i: &Instance| {
            i.frozen
                && !i.hidden
                && i.parent.is_empty()
                && i.state == State::Running
                && i.reclaim == Reclaim::Waiting
                && i.frozen_at
                    .is_some_and(|t| now.saturating_duration_since(t) >= RECLAIM_AFTER)
        };
        if !self.instances.iter().any(due) {
            return;
        }
        let swap = self.spawner.swap_active();
        for inst in self.instances.iter_mut().filter(|i| due(i)) {
            inst.reclaim = if !swap {
                eprintln!(
                    "ruya-session: {}: no swap is active, its memory stays",
                    inst.unit
                );
                Reclaim::Skipped
            } else {
                match self.spawner.reclaim(&inst.unit) {
                    Ok(()) => Reclaim::Sent,
                    Err(err) => {
                        eprintln!("ruya-session: reclaiming {} failed: {err}", inst.unit);
                        Reclaim::Skipped
                    }
                }
            };
        }
    }

    /// Asks for the sound of `user`'s apps to match what is frozen (T-466): its frozen and held
    /// apps are parked, the rest put back. Only a change is sent, and only while the user has a
    /// frozen or held app or had one at the last request; `force` sends it anyway (after a restart
    /// of this service, when what is parked is not known).
    fn sync_audio(&mut self, user: &str, force: bool) {
        let mine: Vec<&Instance> = self
            .instances
            .iter()
            .filter(|i| i.user == user && !i.hidden)
            .collect();
        let mut frozen: Vec<String> = mine
            .iter()
            .filter(|i| i.frozen || i.held.is_some())
            .map(|i| i.app_id.clone())
            .collect();
        let mut running: Vec<String> = mine
            .iter()
            .filter(|i| i.state != State::Stopping)
            .map(|i| i.app_id.clone())
            .collect();
        for list in [&mut frozen, &mut running] {
            list.sort();
            list.dedup();
        }
        let before = self.audio_sent.get(user);
        let changed = before != Some(&(frozen.clone(), running.clone()));
        if force || (changed && (!frozen.is_empty() || before.is_some())) {
            self.spawner.app_audio(user, &frozen, &running);
        }
        if frozen.is_empty() {
            self.audio_sent.remove(user);
        } else {
            self.audio_sent.insert(user.to_owned(), (frozen, running));
        }
    }
}

/// The exit code for the signal and the reason, from the state the instance was in.
fn exit_reason(inst: &Instance, code: i32, signaled: bool) -> (i32, ExitReason) {
    if let Some(reason) = inst.cancelled {
        // A Steam game ended before its scope came: nothing of it ever ran (RUY-1067).
        return (-1, reason);
    }
    if inst.kill_asked {
        // Force quit (RUY-736): the player ended it, whatever the unit died of (its front end may
        // have ended on the stop's SIGTERM while the scope held the run).
        return (code, ExitReason::Killed);
    }
    if inst.state == State::Stopping {
        // Asked to stop: the stop itself is a SIGTERM, so dying of a signal before the backstop is
        // still a quit. Once `tick` has sent its kill (the run outlived the grace), a signalled
        // end is "killed" whatever its status: the unit's end is held for its scope, so the status
        // is the SIGTERM the app ignored (15), not the SIGKILL that ended the run (VM 0.0.88,
        // RUY-770). It cannot be told from a late report of an early SIGTERM death, and in both
        // the run held past the grace and the OS had to kill it.
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

/// The earlier of two optional times.
fn earlier(a: Option<Instant>, b: Option<Instant>) -> Option<Instant> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    }
}

/// The journal line of a freezer call the OS accepted (RUY-547): `froze <unit> (Freeze)` or
/// `thawed <unit> (Thaw)`. Failures have their own lines.
fn freezer_line(unit: &str, verb: &str) -> String {
    let done = if verb == "Freeze" { "froze" } else { "thawed" };
    format!("ruya-session: {done} {unit} ({verb})")
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
        let (status, unit) = s.launch(APP, "p1", 100, &[]);
        assert_eq!(status, Status::Ok);
        assert!(s.on_event(UnitEvent::Started { unit: unit.clone() }).len() == 1);
        unit
    }

    fn exited(unit: &str, code: i32, signaled: bool) -> UnitEvent {
        UnitEvent::Exited {
            unit: unit.to_owned(),
            code,
            signaled,
        }
    }

    /// The code and reason of the one exit in `n`.
    fn reason(n: Vec<Notice>) -> (i32, &'static str) {
        match n.as_slice() {
            [Notice::Exited {
                exit_code, reason, ..
            }] => (*exit_code, reason.as_str()),
            other => panic!("expected one exit, got {other:?}"),
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
            (Status::NotFound, "not-found"),
        ];
        for (s, text) in all {
            assert_eq!(s.as_str(), text);
        }
    }

    // ---- InstanceOfPid (T-459) ---------------------------------------------------------------

    fn cgroup(uid: u32, unit: &str) -> String {
        format!("0::/user.slice/user-{uid}.slice/user@{uid}.service/app.slice/{unit}\n")
    }

    /// p1 (ruya-p1, uid 1001) runs Racer, p2 (ruya-p2, uid 1002) runs Racer and Puzzle; the
    /// processes: 10 in p1's unit, 11 and 12 in p1's two Flatpak scopes (Electron, T-435), 20 in
    /// p2's Racer scope, 30 in p2's Puzzle scope, 40 in a sibling app's scope, 50 in a system
    /// service, 60 in p1's manager outside any app.
    fn pid_session() -> (Session<FakeSpawner, ProfileSnapshot>, [String; 3]) {
        let spawner = FakeSpawner::new()
            .with_app(APP)
            .with_app("org.ruyaos.Puzzle")
            .with_user(1001, "ruya-p1")
            .with_user(1002, "ruya-p2")
            .with_process(10, &cgroup(1001, &unit_name("ruya-p1", APP)))
            .with_process(11, &cgroup(1001, "app-flatpak-org.ruyaos.Racer-4711.scope"))
            .with_process(12, &cgroup(1001, "app-flatpak-org.ruyaos.Racer-4712.scope"))
            .with_process(20, &cgroup(1002, "app-flatpak-org.ruyaos.Racer-5000.scope"))
            .with_process(
                30,
                &cgroup(1002, "app-flatpak-org.ruyaos.Puzzle-5001.scope"),
            )
            .with_process(
                40,
                &cgroup(1001, "app-flatpak-org.ruyaos.Racer-Extra-1.scope"),
            )
            .with_process(50, "0::/system.slice/ruya-session.service\n")
            .with_process(60, &cgroup(1001, "app-org.gnome.Terminal@1.service"));
        let dir = ProfileSnapshot::new(["p1".to_owned(), "p2".to_owned()]);
        let mut s = Session::new(spawner, dir, Vec::new());
        let p1 = s.launch(APP, "p1", 100, &[]).1;
        let p2 = s.launch(APP, "p2", 100, &[]).1;
        let puzzle = s.launch("org.ruyaos.Puzzle", "p2", 100, &[]).1;
        (s, [p1, p2, puzzle])
    }

    #[test]
    fn a_pid_in_the_unit_or_any_app_scope_names_its_instance() {
        let (s, [p1, p2, puzzle]) = pid_session();
        assert_eq!(s.instance_of_pid(10), (Status::Ok, p1.clone()));
        // Both scopes of an Electron app (its zygote's second scope, T-435).
        assert_eq!(s.instance_of_pid(11), (Status::Ok, p1.clone()));
        assert_eq!(s.instance_of_pid(12), (Status::Ok, p1));
        // The same app of another profile: that profile's instance, found by its manager's user.
        assert_eq!(s.instance_of_pid(20), (Status::Ok, p2));
        assert_eq!(s.instance_of_pid(30), (Status::Ok, puzzle));
    }

    #[test]
    fn a_pid_outside_every_instance_is_not_found() {
        let (mut s, [p1, ..]) = pid_session();
        // A sibling app whose id starts with Racer's, a system service, the manager's own
        // processes, an unknown pid, and an unknown user.
        for pid in [40, 50, 60, 99] {
            assert_eq!(
                s.instance_of_pid(pid),
                (Status::NotFound, String::new()),
                "pid {pid}"
            );
        }
        assert_eq!(s.instance_of_pid(0), (Status::Invalid, String::new()));
        // An instance that has ended is not named any more.
        assert!(s.on_event(exited(&p1, 0, false)).len() == 1);
        assert_eq!(s.instance_of_pid(10), (Status::NotFound, String::new()));
        assert_eq!(s.instance_of_pid(11), (Status::NotFound, String::new()));
    }

    #[test]
    fn a_pid_of_an_unknown_user_is_not_found() {
        let spawner = FakeSpawner::new()
            .with_app(APP)
            .with_process(10, &cgroup(1001, &unit_name("ruya-p1", APP)));
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, Vec::new());
        assert_eq!(s.launch(APP, "p1", 100, &[]).0, Status::Ok);
        assert_eq!(s.instance_of_pid(10), (Status::NotFound, String::new()));
    }

    // ---- Freeze and Thaw (T-457) -----------------------------------------------------------

    fn frozen_of(s: &Session<FakeSpawner, ProfileSnapshot>, unit: &str) -> bool {
        s.list()
            .into_iter()
            .find(|a| a.instance == unit)
            .is_some_and(|a| a.frozen)
    }

    #[test]
    fn freezer_lines_name_the_unit_and_the_verb() {
        assert_eq!(
            freezer_line("ruya-p1-app.service", "Freeze"),
            "ruya-session: froze ruya-p1-app.service (Freeze)"
        );
        assert_eq!(
            freezer_line("ruya-p1-app.service", "Thaw"),
            "ruya-session: thawed ruya-p1-app.service (Thaw)"
        );
    }

    #[test]
    fn freeze_and_thaw_go_to_the_os_and_are_announced() {
        let mut s = session();
        let unit = running(&mut s);
        assert!(!frozen_of(&s, &unit));
        assert_eq!(s.freeze(&unit, Some("p1"), Instant::now()), Status::Ok);
        assert!(frozen_of(&s, &unit));
        assert_eq!(
            s.take_frozen_changes(),
            [FrozenChange {
                instance: unit.clone(),
                frozen: true
            }]
        );
        // A second freeze is a no-op: the OS is not asked again, nothing is announced.
        assert_eq!(s.freeze(&unit, Some("p1"), Instant::now()), Status::Ok);
        assert!(s.take_frozen_changes().is_empty());
        assert_eq!(s.thaw(&unit, Some("p1"), Instant::now()), Status::Ok);
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
        assert_eq!(s.thaw(&unit, Some("p1"), Instant::now()), Status::Ok);
        assert!(s.take_frozen_changes().is_empty());
        assert_eq!(s.spawner.calls().last(), Some(&format!("thaw {unit}")));
    }

    #[test]
    fn another_profiles_app_is_never_frozen() {
        let mut s = session();
        let unit = running(&mut s); // p1's
        for active in [Some("p2"), Some("")] {
            assert_eq!(
                s.freeze(&unit, active, Instant::now()),
                Status::NotAllowed,
                "{active:?}"
            );
            assert_eq!(
                s.thaw(&unit, active, Instant::now()),
                Status::NotAllowed,
                "{active:?}"
            );
        }
        assert!(!frozen_of(&s, &unit));
        assert_eq!(s.spawner.calls(), [format!("start ruya-p1 {APP}")]);
        // Development mode (no active profile known) does not check.
        assert_eq!(s.freeze(&unit, None, Instant::now()), Status::Ok);
    }

    #[test]
    fn only_a_running_app_is_frozen() {
        let mut s = session();
        assert_eq!(s.freeze("", Some("p1"), Instant::now()), Status::Invalid);
        assert_eq!(
            s.freeze("nope.service", Some("p1"), Instant::now()),
            Status::NotRunning
        );
        assert_eq!(
            s.thaw("nope.service", Some("p1"), Instant::now()),
            Status::NotRunning
        );
        let (_, unit) = s.launch(APP, "p1", 0, &[]); // still starting
        assert_eq!(
            s.freeze(&unit, Some("p1"), Instant::now()),
            Status::NotRunning
        );
        s.on_event(UnitEvent::Started { unit: unit.clone() });
        assert_eq!(s.stop(&unit, Instant::now()), Status::Ok); // stopping
        assert_eq!(
            s.freeze(&unit, Some("p1"), Instant::now()),
            Status::NotRunning
        );
        assert!(!s.spawner.calls().iter().any(|c| c.starts_with("freeze")));
    }

    #[test]
    fn a_failed_freeze_is_undone_and_the_app_keeps_running() {
        let spawner = FakeSpawner::new().with_app(APP).failing_freeze();
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, Vec::new());
        let unit = running(&mut s);
        assert_eq!(s.freeze(&unit, Some("p1"), Instant::now()), Status::Failed);
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
        assert_eq!(s.freeze(&unit, Some("p1"), Instant::now()), Status::Ok);
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
        let (_, other) = s.launch("org.ruyaos.Puzzle", "p1", 0, &[]);
        s.on_event(UnitEvent::Started {
            unit: other.clone(),
        });
        assert_eq!(s.stop(&other, Instant::now()), Status::Ok);
        assert_eq!(s.spawner.calls().last(), Some(&format!("stop {other}")));
        assert!(!s.spawner.calls().contains(&format!("thaw {other}")));
    }

    #[test]
    fn the_grace_of_a_frozen_apps_stop_starts_after_its_thaw() {
        // The clock is read only once the thaw is done (a slow thaw, up to two bounded systemctl
        // calls, must not eat the 5 s the app has to quit).
        let mut s = session();
        let unit = running(&mut s);
        let t0 = Instant::now();
        assert_eq!(s.freeze(&unit, Some("p1"), t0), Status::Ok);
        let spy = s.spawner.observer();
        let thawed = format!("thaw {unit}");
        let t1 = t0 + Duration::from_secs(9);
        let clock = move || {
            assert!(
                spy.calls().contains(&thawed),
                "the clock was read before the thaw"
            );
            t1
        };
        assert_eq!(s.stop(&unit, clock), Status::Ok);
        s.tick(t1 + STOP_GRACE - Duration::from_millis(1));
        assert!(!s.spawner.calls().contains(&format!("kill {unit}")));
        s.tick(t1 + STOP_GRACE);
        assert_eq!(s.spawner.calls().last(), Some(&format!("kill {unit}")));
    }

    // ---- A profile that leaves has its apps frozen (T-165, ADR-004) --------------------------

    /// A running instance of `app` for `profile`.
    fn run_as(s: &mut Session<FakeSpawner, ProfileSnapshot>, app: &str, profile: &str) -> String {
        let (status, unit) = s.launch(app, profile, 100, &[]);
        assert_eq!(status, Status::Ok, "{app} for {profile}");
        s.on_event(UnitEvent::Started { unit: unit.clone() });
        unit
    }

    fn freezes(s: &Session<FakeSpawner, ProfileSnapshot>) -> Vec<String> {
        s.spawner
            .calls()
            .into_iter()
            .filter(|c| c.starts_with("freeze "))
            .collect()
    }

    #[test]
    fn a_profile_that_leaves_has_every_app_frozen_and_the_next_ones_are_untouched() {
        let mut s = session();
        let racer = run_as(&mut s, APP, "p1");
        let puzzle = run_as(&mut s, PUZZLE, "p1");
        let theirs = run_as(&mut s, APP, "p2");
        let asked = s.profile_changed(Some("p1"), "p2", Instant::now());
        assert_eq!(
            asked,
            [(racer.clone(), Status::Ok), (puzzle.clone(), Status::Ok)]
        );
        assert!(frozen_of(&s, &racer) && frozen_of(&s, &puzzle));
        assert!(
            !frozen_of(&s, &theirs),
            "the profile that came is untouched"
        );
        assert_eq!(
            freezes(&s),
            [format!("freeze {racer}"), format!("freeze {puzzle}")]
        );
        // Announced like a Freeze, in order.
        assert_eq!(
            s.take_frozen_changes(),
            [
                FrozenChange {
                    instance: racer.clone(),
                    frozen: true
                },
                FrozenChange {
                    instance: puzzle.clone(),
                    frozen: true
                }
            ]
        );
        // p2 locks in turn: its app is frozen; p1's stay frozen and are not asked again.
        let asked = s.profile_changed(Some("p2"), "", Instant::now());
        assert_eq!(asked, [(theirs.clone(), Status::Ok)]);
        assert!(frozen_of(&s, &theirs));
        assert_eq!(freezes(&s).len(), 3);
    }

    #[test]
    fn apps_frozen_already_stay_frozen_and_the_os_is_not_asked_again() {
        let mut s = session();
        let racer = run_as(&mut s, APP, "p1");
        let puzzle = run_as(&mut s, PUZZLE, "p1");
        assert_eq!(s.freeze(&racer, Some("p1"), Instant::now()), Status::Ok); // the Hub's
        s.take_frozen_changes();
        let asked = s.profile_changed(Some("p1"), "", Instant::now());
        assert_eq!(asked, [(puzzle.clone(), Status::Ok)]);
        assert!(frozen_of(&s, &racer) && frozen_of(&s, &puzzle));
        assert_eq!(
            freezes(&s),
            [format!("freeze {racer}"), format!("freeze {puzzle}")]
        );
        assert_eq!(
            s.take_frozen_changes(),
            [FrozenChange {
                instance: puzzle,
                frozen: true
            }]
        );
    }

    #[test]
    fn a_sign_in_and_no_change_freeze_nothing() {
        // Only the apps of the profile that left are frozen: a sign-in from the picker ("" before)
        // freezes nobody's, not even another profile's.
        let mut s = session();
        let racer = run_as(&mut s, APP, "p1");
        let theirs = run_as(&mut s, APP, "p2");
        assert!(s.profile_changed(Some(""), "p1", Instant::now()).is_empty());
        assert!(s
            .profile_changed(Some("p1"), "p1", Instant::now())
            .is_empty());
        assert!(s.profile_changed(Some(""), "", Instant::now()).is_empty());
        assert!(!frozen_of(&s, &racer) && !frozen_of(&s, &theirs));
        assert!(freezes(&s).is_empty());
        assert!(s.take_frozen_changes().is_empty());
    }

    #[test]
    fn the_first_value_after_a_start_freezes_every_profile_but_the_signed_in_one() {
        let mut s = session();
        let mine = run_as(&mut s, APP, "p1");
        let theirs = run_as(&mut s, APP, "p2");
        assert_eq!(
            s.profile_changed(None, "p1", Instant::now()),
            [(theirs.clone(), Status::Ok)]
        );
        assert!(!frozen_of(&s, &mine));
        assert!(frozen_of(&s, &theirs));
        // Locked at the start: every app.
        let mut s = session();
        let mine = run_as(&mut s, APP, "p1");
        let theirs = run_as(&mut s, APP, "p2");
        assert_eq!(s.profile_changed(None, "", Instant::now()).len(), 2);
        assert!(frozen_of(&s, &mine) && frozen_of(&s, &theirs));
    }

    #[test]
    fn apps_that_start_or_stop_are_not_frozen_by_a_change() {
        let mut s = session();
        let (_, starting) = s.launch(APP, "p1", 0, &[]);
        let stopping = run_as(&mut s, PUZZLE, "p1");
        assert_eq!(s.stop(&stopping, Instant::now()), Status::Ok);
        assert!(s
            .profile_changed(Some("p1"), "p2", Instant::now())
            .is_empty());
        assert!(!frozen_of(&s, &starting) && !frozen_of(&s, &stopping));
        assert!(freezes(&s).is_empty());
    }

    #[test]
    fn a_failed_freeze_at_a_change_is_undone_and_the_app_keeps_running() {
        let spawner = FakeSpawner::new().with_app(APP).failing_freeze();
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, Vec::new());
        let unit = running(&mut s);
        assert_eq!(
            s.profile_changed(Some("p1"), "", Instant::now()),
            [(unit.clone(), Status::Failed)]
        );
        assert!(!frozen_of(&s, &unit));
        assert!(s.take_frozen_changes().is_empty());
        assert_eq!(
            s.spawner.calls()[1..],
            [format!("freeze {unit}"), format!("thaw {unit}")]
        );
    }

    #[test]
    fn a_crash_while_frozen_by_a_change_is_reported_once() {
        let mut s = session();
        let unit = running(&mut s);
        s.profile_changed(Some("p1"), "p2", Instant::now());
        assert!(frozen_of(&s, &unit));
        assert_eq!(reason(s.on_event(exited(&unit, 3, false))), (3, "crashed"));
        assert!(
            s.on_event(exited(&unit, 3, false)).is_empty(),
            "reported once"
        );
        assert!(s.list().is_empty());
    }

    #[test]
    fn stop_works_on_an_app_frozen_by_a_change() {
        // The profile that left cannot Thaw its app (not-allowed), but Stop still ends it: thawed
        // first, so it can handle the SIGTERM.
        let mut s = session();
        let unit = running(&mut s);
        s.profile_changed(Some("p1"), "", Instant::now());
        s.take_frozen_changes();
        assert_eq!(s.thaw(&unit, Some(""), Instant::now()), Status::NotAllowed);
        assert!(frozen_of(&s, &unit));
        assert_eq!(s.stop(&unit, Instant::now()), Status::Ok);
        assert_eq!(
            s.spawner.calls()[1..],
            [
                format!("freeze {unit}"),
                format!("thaw {unit}"),
                format!("stop {unit}")
            ]
        );
        assert_eq!(reason(s.on_event(exited(&unit, 0, false))), (0, "quit"));
    }

    #[test]
    fn the_hubs_thaw_right_before_the_switch_still_ends_frozen() {
        // Switch profile from the Hub (Shell.qml): the Hub closes, which thaws the game, then the
        // profile locks. The adapter serves the Thaw and the change one at a time, in order: in
        // either order the game ends frozen.
        let mut s = session();
        let unit = running(&mut s);
        assert_eq!(s.freeze(&unit, Some("p1"), Instant::now()), Status::Ok); // the Hub opens
                                                                             // The Thaw first, then the change.
        assert_eq!(s.thaw(&unit, Some("p1"), Instant::now()), Status::Ok);
        s.profile_changed(Some("p1"), "", Instant::now());
        assert!(frozen_of(&s, &unit));
        // The change first: the Thaw then reads "" as the signed-in profile and is refused.
        let mut s = session();
        let unit = running(&mut s);
        assert_eq!(s.freeze(&unit, Some("p1"), Instant::now()), Status::Ok);
        s.profile_changed(Some("p1"), "", Instant::now());
        assert_eq!(s.thaw(&unit, Some(""), Instant::now()), Status::NotAllowed);
        assert!(frozen_of(&s, &unit));
        // p1 signs in again: the shell's Thaw works.
        s.profile_changed(Some(""), "p1", Instant::now());
        assert_eq!(s.thaw(&unit, Some("p1"), Instant::now()), Status::Ok);
        assert!(!frozen_of(&s, &unit));
    }

    // ---- An app that reaches running after its profile left (RUY-568) -------------------------

    fn started(s: &mut Session<FakeSpawner, ProfileSnapshot>, unit: &str) {
        assert!(
            s.on_event(UnitEvent::Started {
                unit: unit.to_owned()
            })
            .len()
                == 1
        );
    }

    #[test]
    fn an_app_that_reaches_running_after_its_profile_left_is_frozen_then() {
        let mut s = session();
        let (status, unit) = s.launch(APP, "p1", 100, &[]);
        assert_eq!(status, Status::Ok);
        // p1 leaves while the app is still starting: nothing to freeze yet.
        assert!(s
            .profile_changed(Some("p1"), "p2", Instant::now())
            .is_empty());
        assert!(freezes(&s).is_empty());
        // Still starting: the check has nothing to freeze yet.
        assert_eq!(s.freeze_if_away(&unit, "p2", Instant::now()), None);
        assert!(freezes(&s).is_empty());
        started(&mut s, &unit);
        assert_eq!(
            s.freeze_if_away(&unit, "p2", Instant::now()),
            Some(Status::Ok)
        );
        assert!(frozen_of(&s, &unit));
        assert_eq!(freezes(&s), [format!("freeze {unit}")]);
        assert_eq!(
            s.take_frozen_changes(),
            [FrozenChange {
                instance: unit.clone(),
                frozen: true
            }]
        );
        // A second check leaves it alone.
        assert_eq!(s.freeze_if_away(&unit, "p2", Instant::now()), None);
        assert_eq!(freezes(&s).len(), 1);
    }

    #[test]
    fn an_app_whose_profile_signed_in_again_before_the_check_is_not_frozen() {
        let mut s = session();
        let (_, unit) = s.launch(APP, "p1", 100, &[]);
        s.profile_changed(Some("p1"), "p2", Instant::now());
        s.profile_changed(Some("p2"), "p1", Instant::now());
        started(&mut s, &unit);
        assert_eq!(s.freeze_if_away(&unit, "p1", Instant::now()), None);
        assert!(!frozen_of(&s, &unit));
        assert!(freezes(&s).is_empty());
        assert!(s.take_frozen_changes().is_empty());
    }

    #[test]
    fn an_app_of_the_signed_in_profile_is_not_frozen_when_it_starts() {
        let mut s = session();
        let (_, unit) = s.launch(APP, "p1", 100, &[]);
        started(&mut s, &unit);
        assert_eq!(s.freeze_if_away(&unit, "p1", Instant::now()), None);
        assert!(!frozen_of(&s, &unit));
        assert!(freezes(&s).is_empty());
        // Unknown instances are ignored too.
        assert_eq!(s.freeze_if_away("nope.service", "p2", Instant::now()), None);
    }

    #[test]
    fn a_hidden_instance_is_never_frozen_at_its_start() {
        let spawner = FakeSpawner::new()
            .with_app(APP)
            .with_running("ruya-p9", APP, 1_000);
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, vec![]);
        s.adopt(5_000, Instant::now(), true);
        let orphan = unit_name("ruya-p9", APP);
        // The orphan is being stopped; make it look running, so only `hidden` keeps it out.
        let at = s.instances.iter().position(|i| i.unit == orphan).unwrap();
        assert!(s.instances[at].hidden);
        s.instances[at].state = State::Running;
        assert_eq!(s.freeze_if_away(&orphan, "p1", Instant::now()), None);
        assert!(!s.spawner.calls().contains(&format!("freeze {orphan}")));
    }

    // ---- The sound of a frozen app (T-466) ----------------------------------------------------

    #[test]
    fn a_frozen_apps_sound_is_parked_and_put_back_on_the_thaw() {
        let mut s = session();
        let unit = running(&mut s);
        // Running alone asks nothing.
        assert!(s.spawner.audio_calls().is_empty());
        assert_eq!(s.freeze(&unit, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(
            s.spawner.audio_calls(),
            [format!("ruya-p1 frozen={APP} running={APP}")]
        );
        // A second Freeze changes nothing and asks nothing.
        assert_eq!(s.freeze(&unit, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(s.spawner.audio_calls().len(), 1);
        assert_eq!(s.thaw(&unit, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(
            s.spawner.audio_calls()[1..],
            [format!("ruya-p1 frozen= running={APP}")]
        );
        // A thaw of an app that is not frozen, a stop and the end ask nothing more.
        assert_eq!(s.thaw(&unit, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(s.stop(&unit, Instant::now()), Status::Ok);
        assert!(s.on_event(exited(&unit, 0, false)).len() == 1);
        assert_eq!(s.spawner.audio_calls().len(), 2);
    }

    #[test]
    fn every_change_of_a_profile_with_a_frozen_app_is_sent_and_no_other() {
        let mut s = session();
        let racer = running(&mut s);
        assert_eq!(s.freeze(&racer, Some("p1"), Instant::now()), Status::Ok);
        // Another app of the profile starts: it may play, so the request says it runs.
        let (_, puzzle) = s.launch("org.ruyaos.Puzzle", "p1", 0, &[]);
        // Another profile's app changes nothing for p1 and, frozen nothing, asks nothing.
        let (_, p2) = s.launch(APP, "p2", 0, &[]);
        assert!(s.on_event(exited(&p2, 0, false)).len() == 1);
        assert!(s.on_event(exited(&puzzle, 0, false)).len() == 1);
        // The frozen app is closed: thawed and stopping, so nothing of p1 is frozen or running.
        assert_eq!(s.stop(&racer, Instant::now()), Status::Ok);
        assert!(s.on_event(exited(&racer, 0, false)).len() == 1);
        assert_eq!(
            s.spawner.audio_calls(),
            [
                format!("ruya-p1 frozen={APP} running={APP}"),
                format!("ruya-p1 frozen={APP} running=org.ruyaos.Puzzle,{APP}"),
                format!("ruya-p1 frozen={APP} running={APP}"),
                "ruya-p1 frozen= running=".to_owned(),
            ]
        );
    }

    #[test]
    fn a_restart_sets_the_sound_of_every_profile_with_apps_right() {
        // Before the restart a stream may have been parked (or put back) behind this service's
        // back: one request per profile user, frozen or not.
        let spawner = FakeSpawner::new()
            .with_frozen_running("ruya-p1", APP, 50)
            .with_running("ruya-p2", APP, 60);
        let dir = ProfileSnapshot::new(["p1".to_owned(), "p2".to_owned()]);
        let mut s = Session::new(spawner, dir, Vec::new());
        s.adopt(100, Instant::now(), true);
        assert_eq!(
            s.spawner.audio_calls(),
            [
                format!("ruya-p1 frozen={APP} running={APP}"),
                format!("ruya-p2 frozen= running={APP}"),
            ]
        );
    }

    // ---- The memory of a frozen app (T-466) ---------------------------------------------------

    fn swap_session() -> Session<FakeSpawner, ProfileSnapshot> {
        let spawner = FakeSpawner::new().with_app(APP).with_swap();
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        Session::new(spawner, dir, Vec::new())
    }

    fn reclaims(s: &Session<FakeSpawner, ProfileSnapshot>) -> Vec<String> {
        s.spawner
            .calls()
            .into_iter()
            .filter(|c| c.contains("reclaim"))
            .collect()
    }

    #[test]
    fn a_frozen_apps_memory_is_reclaimed_once_after_30_s_never_at_the_freeze() {
        let mut s = swap_session();
        let unit = running(&mut s);
        let t0 = Instant::now();
        assert_eq!(s.freeze(&unit, Some("p1"), t0), Status::Ok);
        s.tick(t0);
        s.tick(t0 + RECLAIM_AFTER - Duration::from_millis(1));
        assert!(reclaims(&s).is_empty(), "{:?}", s.spawner.calls());
        s.tick(t0 + RECLAIM_AFTER);
        assert_eq!(reclaims(&s), [format!("reclaim {unit}")]);
        // Once per freeze.
        s.tick(t0 + RECLAIM_AFTER * 3);
        assert_eq!(reclaims(&s).len(), 1);
        // The thaw ends a reclaim that may still run, before it thaws.
        assert_eq!(s.thaw(&unit, Some("p1"), Instant::now()), Status::Ok);
        let calls = s.spawner.calls();
        assert_eq!(
            calls[calls.len() - 2..],
            [format!("cancel-reclaim {unit}"), format!("thaw {unit}")]
        );
        // The next freeze counts from its own start.
        let t1 = t0 + RECLAIM_AFTER * 4;
        assert_eq!(s.freeze(&unit, Some("p1"), t1), Status::Ok);
        s.tick(t1 + RECLAIM_AFTER - Duration::from_millis(1));
        assert_eq!(reclaims(&s).len(), 2);
        s.tick(t1 + RECLAIM_AFTER);
        assert_eq!(reclaims(&s).len(), 3);
    }

    #[test]
    fn a_thaw_within_the_delay_means_no_reclaim_and_a_new_freeze_starts_it_again() {
        let mut s = swap_session();
        let unit = running(&mut s);
        let t0 = Instant::now();
        assert_eq!(s.freeze(&unit, Some("p1"), t0), Status::Ok);
        s.tick(t0 + Duration::from_secs(20));
        assert_eq!(s.thaw(&unit, Some("p1"), Instant::now()), Status::Ok);
        let t1 = t0 + Duration::from_secs(25);
        assert_eq!(s.freeze(&unit, Some("p1"), t1), Status::Ok);
        s.tick(t0 + RECLAIM_AFTER + Duration::from_secs(1));
        assert!(reclaims(&s).is_empty(), "{:?}", s.spawner.calls());
        s.tick(t1 + RECLAIM_AFTER);
        assert_eq!(reclaims(&s), [format!("reclaim {unit}")]);
    }

    #[test]
    fn without_swap_no_memory_is_reclaimed() {
        let mut s = session();
        let unit = running(&mut s);
        let t0 = Instant::now();
        assert_eq!(s.freeze(&unit, Some("p1"), t0), Status::Ok);
        s.tick(t0 + RECLAIM_AFTER * 2);
        assert!(reclaims(&s).is_empty(), "{:?}", s.spawner.calls());
        // Nothing to cancel at the thaw either.
        assert_eq!(s.thaw(&unit, Some("p1"), Instant::now()), Status::Ok);
        assert!(reclaims(&s).is_empty());
    }

    #[test]
    fn a_running_app_is_never_reclaimed_and_a_stopped_frozen_one_cancels_its_reclaim() {
        let mut s = swap_session();
        let unit = running(&mut s);
        let t0 = Instant::now();
        s.tick(t0 + RECLAIM_AFTER * 2);
        assert!(reclaims(&s).is_empty());
        assert_eq!(s.freeze(&unit, Some("p1"), t0), Status::Ok);
        s.tick(t0 + RECLAIM_AFTER);
        assert_eq!(reclaims(&s), [format!("reclaim {unit}")]);
        assert_eq!(s.stop(&unit, t0 + RECLAIM_AFTER), Status::Ok);
        let calls = s.spawner.calls();
        assert_eq!(
            calls[calls.len() - 3..],
            [
                format!("cancel-reclaim {unit}"),
                format!("thaw {unit}"),
                format!("stop {unit}")
            ]
        );
    }

    #[test]
    fn an_adopted_frozen_app_is_reclaimed_30_s_after_its_adoption() {
        let spawner = FakeSpawner::new()
            .with_frozen_running("ruya-p1", APP, 50)
            .with_swap();
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, Vec::new());
        let t0 = Instant::now();
        s.adopt(100, t0, true);
        s.tick(t0 + RECLAIM_AFTER - Duration::from_millis(1));
        assert!(reclaims(&s).is_empty());
        s.tick(t0 + RECLAIM_AFTER);
        assert_eq!(
            reclaims(&s),
            [format!("reclaim {}", unit_name("ruya-p1", APP))]
        );
    }

    #[test]
    fn launch_goes_through_starting_to_running() {
        let mut s = session();
        let (status, unit) = s.launch(APP, "p1", 100, &[]);
        assert_eq!(
            (status, unit.as_str()),
            (Status::Ok, unit_name("ruya-p1", APP).as_str())
        );
        assert_eq!(s.list()[0].state, State::Starting);
        let notice = s.on_event(UnitEvent::Started { unit: unit.clone() });
        assert_eq!(
            notice,
            [Notice::Started {
                instance: unit.clone(),
                app_id: APP.to_owned()
            }]
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
        assert!(s.on_event(UnitEvent::Started { unit }).is_empty());
    }

    #[test]
    fn every_record_names_its_flatpak_item_and_no_parent() {
        // ADR-041 point 1 (RUY-1051): a launched app and an adopted one alike.
        let spawner =
            FakeSpawner::new()
                .with_app(APP)
                .with_running("ruya-p1", "org.ruyaos.Puzzle", 50);
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, Vec::new());
        s.adopt(100, Instant::now(), true);
        assert_eq!(s.launch(APP, "p1", 100, &[]).0, Status::Ok);
        let mut keys: Vec<(String, String, String)> = s
            .list()
            .into_iter()
            .map(|a| (a.app_id, a.item, a.parent))
            .collect();
        keys.sort();
        assert_eq!(
            keys,
            [
                (
                    "org.ruyaos.Puzzle".to_owned(),
                    "flatpak:org.ruyaos.Puzzle".to_owned(),
                    String::new()
                ),
                (APP.to_owned(), format!("flatpak:{APP}"), String::new()),
            ]
        );
    }

    #[test]
    fn launch_runs_as_the_profiles_unix_user() {
        let mut s = session();
        s.launch(APP, "p2", 0, &[]);
        assert_eq!(s.spawner.calls(), [format!("start ruya-p2 {APP}")]);
    }

    #[test]
    fn the_launch_arguments_reach_the_spawner() {
        let mut s = session();
        let args = vec!["--runner=bundled".to_owned()];
        assert_eq!(s.launch(APP, "p1", 0, &args).0, Status::Ok);
        assert_eq!(s.spawner.last_launch_args(), args);
        s.launch("org.ruyaos.Puzzle", "p1", 0, &[]);
        assert!(s.spawner.last_launch_args().is_empty());
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
        let (status, _) = s.launch(APP, "p1", 0, &[]);
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
        dev.launch(APP, "p2", 0, &[]);
        assert_eq!(dev.spawner.calls(), vec![format!("start ruya-p2 {APP}")]);
        assert_eq!(pulse(&dev), None);
    }

    #[test]
    fn a_failed_pulse_start_still_launches_the_app() {
        let spawner = FakeSpawner::new().with_app(APP).failing_sound();
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, Vec::new()).with_pulse_dir("/run/ruya-pulse");
        let (status, instance) = s.launch(APP, "p1", 0, &[]);
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
        s.launch(APP, "p1", 0, &[]);
        assert_eq!(display(&s).as_deref(), Some("/run/ruya-wayland/ruya-p1"));
        s.launch("org.ruyaos.Puzzle", "p2", 0, &[]);
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
        dev.launch(APP, "p1", 0, &[]);
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
                s.launch(app, "p1", 0, &[]),
                (Status::Invalid, String::new()),
                "{app:?}"
            );
        }
        for profile in ["", "p 1", "p1;id", "../p1"] {
            assert_eq!(
                s.launch(APP, profile, 0, &[]),
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
                s.launch(APP, profile, 0, &[]),
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
            s.launch("org.ruyaos.Missing", "p1", 0, &[]),
            (Status::UnknownApp, String::new())
        );
    }

    #[test]
    fn double_launch_is_already_running_per_profile() {
        let mut s = session();
        let (_, first) = s.launch(APP, "p1", 0, &[]);
        // Still starting counts.
        assert_eq!(
            s.launch(APP, "p1", 1, &[]),
            (Status::AlreadyRunning, String::new())
        );
        s.on_event(UnitEvent::Started { unit: first });
        assert_eq!(
            s.launch(APP, "p1", 2, &[]),
            (Status::AlreadyRunning, String::new())
        );
        // Another profile, or another app, is a different instance.
        assert_eq!(s.launch(APP, "p2", 3, &[]).0, Status::Ok);
        assert_eq!(s.launch("org.ruyaos.Puzzle", "p1", 4, &[]).0, Status::Ok);
        assert_eq!(s.list().len(), 3);
    }

    #[test]
    fn failing_spawner_is_failed_and_leaves_no_instance() {
        let spawner = FakeSpawner::new().with_app(APP).failing_start();
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, vec![]);
        assert_eq!(s.launch(APP, "p1", 0, &[]), (Status::Failed, String::new()));
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
        assert!(s.on_event(exited(&unit, 0, false)).is_empty());
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
    fn the_backstop_kill_is_killed_even_when_the_status_is_the_ignored_sigterm() {
        // VM 0.0.88 (RUY-770): the app ignores the stop's SIGTERM, `tick` sends its kill after the
        // grace, and the run's end carries status 15 (the unit's own, held for its scope).
        let mut s = session();
        let unit = running(&mut s);
        let t0 = Instant::now();
        s.stop(&unit, t0);
        s.tick(t0 + STOP_GRACE);
        assert!(s.spawner.calls().iter().any(|c| c.starts_with("kill")));
        assert_eq!(reason(s.on_event(exited(&unit, 15, true))), (15, "killed"));
    }

    #[test]
    fn a_sigterm_death_before_the_backstop_is_a_quit() {
        let mut s = session();
        let unit = running(&mut s);
        let t0 = Instant::now();
        s.stop(&unit, t0);
        s.tick(t0 + STOP_GRACE - Duration::from_millis(1));
        assert_eq!(reason(s.on_event(exited(&unit, 15, true))), (15, "quit"));
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
            let (_, unit) = s.launch(APP, "p1", 0, &[]);
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
        assert_eq!(s.launch(APP, "p1", 200, &[]).0, Status::Ok);
    }

    #[test]
    fn events_for_unknown_units_are_ignored() {
        let mut s = session();
        assert!(s
            .on_event(UnitEvent::Started {
                unit: "x.service".into()
            })
            .is_empty());
        assert!(s.on_event(exited("x.service", 1, false)).is_empty());
    }

    #[test]
    fn stop_during_starting_ends_as_quit() {
        let mut s = session();
        let (_, unit) = s.launch(APP, "p1", 0, &[]);
        assert_eq!(s.stop(&unit, Instant::now()), Status::Ok);
        // The app comes up while stopping: still stopping, announced once.
        assert!(s.on_event(UnitEvent::Started { unit: unit.clone() }).len() == 1);
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
    fn an_adopted_frozen_unit_is_listed_frozen_and_thawed_before_its_stop() {
        let spawner = FakeSpawner::new()
            .with_app(APP)
            .with_frozen_running("ruya-p1", APP, 1_000);
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, vec![]);
        s.adopt(5_000, Instant::now(), true);
        let unit = unit_name("ruya-p1", APP);
        assert!(s.list()[0].frozen, "frozen after the restart");
        assert_eq!(s.stop(&unit, Instant::now()), Status::Ok);
        assert_eq!(
            s.spawner.calls()[1..],
            [format!("thaw {unit}"), format!("stop {unit}")]
        );
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
            s.launch(APP, "p1", 6_000, &[]),
            (Status::AlreadyRunning, String::new())
        );
        // The same app for another profile is another instance.
        assert_eq!(s.launch(APP, "p2", 6_000, &[]).0, Status::Ok);
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
        assert!(s
            .on_event(UnitEvent::Started {
                unit: racer.clone()
            })
            .is_empty());
        assert_eq!(reason(s.on_event(exited(&racer, 0, false))), (0, "quit"));
        assert!(s.on_event(exited(&racer, 0, false)).is_empty());
        assert_eq!(
            reason(s.on_event(exited(&puzzle, 11, true))),
            (11, "killed")
        );
        assert!(s.list().is_empty());
        // Gone, so it can be launched again.
        assert_eq!(s.launch(APP, "p1", 7_000, &[]).0, Status::Ok);
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
        assert!(s.on_event(exited(&orphan, 0, false)).is_empty());
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
    fn a_listed_unit_that_ended_before_the_merge_is_not_adopted() {
        // Its end arrived while the listing ran beside the event loop and found no instance; the
        // unit must not come back as a running app that nothing ends (RUY-621).
        let gone = crate::spawner::unit_name("ruya-p1", APP);
        let spawner = FakeSpawner::new().with_app(APP).with_ended_unit(&gone);
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, vec![]);
        let listing = Listing {
            found: vec![unit_of("ruya-p1", APP)],
            complete: true,
        };
        assert!(s
            .adopt_listed(listing, 5_000, Instant::now(), true)
            .is_empty());
        assert!(s.list().is_empty());
        assert!(s.spawner.audio_calls().is_empty());
    }

    #[test]
    fn adopting_twice_does_not_duplicate() {
        let mut s = restarted();
        s.adopt(5_000, Instant::now(), true);
        s.adopt(5_001, Instant::now(), true);
        assert_eq!(s.list().len(), 2);
    }

    #[test]
    fn an_adoption_that_found_nothing_is_tried_again_and_takes_over_what_runs_then() {
        // The boot race (Dell 0.0.60): the profile's manager is not up when the service
        // starts, the listing fails, and it answers a moment later.
        let spawner = FakeSpawner::new()
            .with_app(APP)
            .with_app(PUZZLE)
            .with_running("ruya-p1", APP, 1_000)
            .with_running("ruya-p2", PUZZLE, 2_000)
            .with_adopt_failures(2);
        let dir = ProfileSnapshot::new(["p1".to_owned(), "p2".to_owned()]);
        let mut s = Session::new(spawner, dir, vec![]);
        assert!(s.adopt(5_000, Instant::now(), true).is_empty());
        assert!(!s.adoption_complete(), "the caller is told to ask again");
        assert!(s.adopt(5_002, Instant::now(), true).is_empty());
        assert!(!s.adoption_complete());
        let late = s.adopt(5_004, Instant::now(), true);
        assert_eq!(late.len(), 2, "both apps are taken over now");
        assert!(late.iter().all(|a| a.state == State::Running));
        assert!(s.adoption_complete());
        // A further pass finds them already taken: nothing is listed twice or announced again.
        assert!(s.adopt(5_006, Instant::now(), true).is_empty());
        assert_eq!(s.list().len(), 2);
    }

    fn unit_of(user: &str, app: &str) -> crate::spawner::RunningUnit {
        crate::spawner::RunningUnit {
            unit: crate::spawner::unit_name(user, app),
            user: user.to_owned(),
            app_id: app.to_owned(),
            started: 1_000,
            frozen: false,
        }
    }

    #[test]
    fn a_listing_that_failed_leaves_the_adoption_incomplete_and_the_next_one_takes_over() {
        // A timeout of loginctl or a manager is a listing that is not complete (RUY-621): not
        // "nothing runs".
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(FakeSpawner::new().with_app(APP), dir, vec![]);
        let failed = Listing {
            found: vec![],
            complete: false,
        };
        assert!(s
            .adopt_listed(failed, 5_000, Instant::now(), true)
            .is_empty());
        assert!(!s.adoption_complete());
        let ok = Listing {
            found: vec![unit_of("ruya-p1", APP)],
            complete: true,
        };
        assert_eq!(s.adopt_listed(ok, 5_002, Instant::now(), true).len(), 1);
        assert!(s.adoption_complete());
    }

    #[test]
    fn a_listed_unit_the_session_knows_is_not_taken_twice() {
        // A pass that raced a normal launch: the unit is in the registry when the lock is taken.
        let spawner = FakeSpawner::new().with_app(APP);
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, vec![]);
        let (_, unit) = s.launch(APP, "p1", 1, &[]);
        let listing = Listing {
            found: vec![unit_of("ruya-p1", APP)],
            complete: true,
        };
        assert!(s
            .adopt_listed(listing, 5_000, Instant::now(), true)
            .is_empty());
        assert_eq!(s.list().len(), 1);
        assert_eq!(s.list()[0].instance, unit);
    }

    #[test]
    fn audio_is_synced_only_for_the_users_that_gained_an_instance() {
        let dir = ProfileSnapshot::new(["p1".to_owned(), "p2".to_owned()]);
        let mut s = Session::new(
            FakeSpawner::new().with_app(APP).with_app(PUZZLE),
            dir,
            vec![],
        );
        let pass = |found: Vec<_>| Listing {
            found,
            complete: false,
        };
        let p1 = unit_of("ruya-p1", APP);
        let p2 = unit_of("ruya-p2", PUZZLE);
        s.adopt_listed(pass(vec![p1.clone()]), 5_000, Instant::now(), true);
        assert_eq!(s.spawner.audio_calls().len(), 1);
        // Later passes list p1's unit again and add p2's: only p2 is synced, once.
        s.adopt_listed(pass(vec![p1.clone()]), 5_002, Instant::now(), true);
        assert_eq!(s.spawner.audio_calls().len(), 1, "nothing gained");
        s.adopt_listed(
            pass(vec![p1.clone(), p2.clone()]),
            5_004,
            Instant::now(),
            true,
        );
        s.adopt_listed(pass(vec![p1, p2]), 5_006, Instant::now(), true);
        let calls = s.spawner.audio_calls();
        assert_eq!(calls.len(), 2, "{calls:?}");
        assert!(calls[0].starts_with("ruya-p1 ") && calls[1].starts_with("ruya-p2 "));
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
        let (_, unit) = s.launch(APP, "p1", 0, &[]);
        assert_eq!(
            reason(s.on_event(exec_failed(&unit))),
            (-1, "launch-failed")
        );
        assert!(s.on_event(exec_failed(&unit)).is_empty());
    }

    #[test]
    fn an_exec_failure_while_stopping_is_a_quit() {
        let mut s = session();
        let unit = running(&mut s);
        s.stop(&unit, Instant::now());
        assert_eq!(reason(s.on_event(exec_failed(&unit))), (0, "quit"));
    }

    #[test]
    fn launch_while_a_stop_has_not_ended_answers_already_running() {
        let mut s = session();
        let unit = running(&mut s);
        // Running: a second launch is already-running.
        assert_eq!(s.launch(APP, "p1", 101, &[]).0, Status::AlreadyRunning);
        assert_eq!(s.stop(&unit, Instant::now()), Status::Ok);
        assert!(s.is_stopping(APP, "p1"));
        // The old unit is still around (the 30 s backstop, RUY-736): still "already-running" once
        // the adapter's wait has run out, and no second unit on its name.
        assert_eq!(
            s.launch(APP, "p1", 102, &[]),
            (Status::AlreadyRunning, String::new())
        );
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
        assert_eq!(s.launch(APP, "p1", 103, &[]).0, Status::Ok);
        // Another profile was never in the way.
        assert_eq!(s.launch(APP, "p2", 104, &[]).0, Status::Ok);
    }

    // ---- Kill (RUY-736, the closing screen's Force quit) and the 30 s backstop ---------------

    fn kills(s: &Session<FakeSpawner, ProfileSnapshot>) -> usize {
        s.spawner
            .calls()
            .iter()
            .filter(|c| c.starts_with("kill"))
            .count()
    }

    #[test]
    fn the_backstop_of_a_stop_is_thirty_seconds() {
        assert_eq!(STOP_GRACE, Duration::from_secs(30));
        let mut s = session();
        let unit = running(&mut s);
        let t0 = Instant::now();
        s.stop(&unit, t0);
        // The old 5 s grace kills nothing any more: a game that saves on quit has its time.
        s.tick(t0 + Duration::from_secs(5));
        s.tick(t0 + Duration::from_millis(29_999));
        assert_eq!(kills(&s), 0);
        s.tick(t0 + Duration::from_secs(30));
        assert_eq!(kills(&s), 1, "the backstop still kills");
        assert_eq!(reason(s.on_event(exited(&unit, 9, true))), (9, "killed"));
    }

    #[test]
    fn kill_after_a_stop_ends_the_app_before_the_grace() {
        let mut s = session();
        let unit = running(&mut s);
        let t0 = Instant::now();
        assert_eq!(s.stop(&unit, t0), Status::Ok);
        s.tick(t0 + Duration::from_secs(5));
        assert_eq!(kills(&s), 0);
        assert_eq!(
            s.kill(&unit, Some("p1"), t0 + Duration::from_secs(5)),
            Status::Ok
        );
        assert_eq!(s.spawner.calls().last(), Some(&format!("kill {unit}")));
        // The backstop sends no second kill for it.
        s.tick(t0 + STOP_GRACE);
        assert_eq!(kills(&s), 1);
        assert_eq!(s.list()[0].state, State::Stopping);
        assert_eq!(reason(s.on_event(exited(&unit, 9, true))), (9, "killed"));
        assert!(s.list().is_empty());
    }

    #[test]
    fn kill_of_a_run_whose_unit_ended_on_the_sigterm_is_still_killed() {
        // The Dell (2026-11-15): the unit's front end died of the stop's SIGTERM, the run was held
        // by its live scope (the core has not seen the end yet). Kill still reaches the run, and
        // its end, with the unit's own status 15, is "killed": the player ended it.
        let mut s = session();
        let unit = running(&mut s);
        let t0 = Instant::now();
        s.stop(&unit, t0);
        assert_eq!(s.kill(&unit, Some("p1"), t0), Status::Ok);
        assert_eq!(kills(&s), 1);
        assert_eq!(reason(s.on_event(exited(&unit, 15, true))), (15, "killed"));
    }

    #[test]
    fn kill_without_a_stop_ends_a_running_or_frozen_app() {
        let mut s = session();
        let unit = running(&mut s);
        assert_eq!(s.freeze(&unit, Some("p1"), Instant::now()), Status::Ok);
        let calls = s.spawner.calls().len();
        assert_eq!(s.kill(&unit, Some("p1"), Instant::now()), Status::Ok);
        // Not thawed first: the kill ends a frozen process anyway.
        assert_eq!(
            s.spawner.calls()[calls..],
            [format!("kill {unit}")],
            "only the kill"
        );
        assert_eq!(s.list()[0].state, State::Stopping);
        // A second Kill sends it again.
        assert_eq!(s.kill(&unit, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(kills(&s), 2);
        assert_eq!(reason(s.on_event(exited(&unit, 9, true))), (9, "killed"));
    }

    #[test]
    fn kill_of_an_unknown_instance() {
        let mut s = session();
        running(&mut s);
        for name in ["nope.service", ""] {
            assert_eq!(
                s.kill(name, Some("p1"), Instant::now()),
                Status::UnknownInstance,
                "{name:?}"
            );
        }
        assert_eq!(kills(&s), 0);
    }

    #[test]
    fn kill_of_another_profiles_app_is_not_allowed() {
        let mut s = session();
        let unit = running(&mut s);
        // Another profile is signed in, or nobody is: refused, nothing is killed.
        for active in ["p2", ""] {
            assert_eq!(
                s.kill(&unit, Some(active), Instant::now()),
                Status::NotAllowed,
                "{active:?}"
            );
        }
        assert_eq!(kills(&s), 0);
        assert_eq!(s.list()[0].state, State::Running, "untouched");
        // Development mode (no profile check) kills it.
        assert_eq!(s.kill(&unit, None, Instant::now()), Status::Ok);
        assert_eq!(kills(&s), 1);
    }

    #[test]
    fn a_kill_the_os_refuses_is_failed_and_changes_nothing() {
        let spawner = FakeSpawner::new().with_app(APP).failing_kill();
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, vec![]);
        let unit = running(&mut s);
        assert_eq!(s.kill(&unit, Some("p1"), Instant::now()), Status::Failed);
        assert_eq!(s.list()[0].state, State::Running);
        // Its end is what it would have been without the Kill.
        assert_eq!(reason(s.on_event(exited(&unit, 0, false))), (0, "quit"));
    }

    // ---- The system goes down: StopAll (RUY-888) ---------------------------------------------

    #[test]
    fn stop_all_thaws_each_frozen_app_of_every_profile_before_its_stop_and_kills_nothing_early() {
        // A game frozen behind a profile switch and one frozen by the Hub (the Dell, 2026-11-18:
        // the user manager's stop at power-off killed such games, and they lost their settings).
        let mut s = session();
        let t0 = Instant::now();
        let racer = run_as(&mut s, APP, "p1");
        let puzzle = run_as(&mut s, PUZZLE, "p1");
        let theirs = run_as(&mut s, APP, "p2");
        s.profile_changed(Some("p1"), "p2", t0);
        assert_eq!(s.freeze(&theirs, Some("p2"), t0), Status::Ok);
        assert!(frozen_of(&s, &racer) && frozen_of(&s, &puzzle) && frozen_of(&s, &theirs));
        s.take_frozen_changes();
        let before = s.spawner.calls().len();

        let t1 = t0 + Duration::from_secs(5);
        let asked = s.stop_all(t1);
        assert_eq!(
            asked,
            [
                (racer.clone(), Status::Ok),
                (puzzle.clone(), Status::Ok),
                (theirs.clone(), Status::Ok)
            ]
        );
        // Each app is thawed right before its own SIGTERM; nothing is killed.
        assert_eq!(
            s.spawner.calls()[before..],
            [
                format!("thaw {racer}"),
                format!("stop {racer}"),
                format!("thaw {puzzle}"),
                format!("stop {puzzle}"),
                format!("thaw {theirs}"),
                format!("stop {theirs}"),
            ]
        );
        assert!(s
            .list()
            .iter()
            .all(|a| !a.frozen && a.state == State::Stopping));
        let thawed: Vec<FrozenChange> = [&racer, &puzzle, &theirs]
            .into_iter()
            .map(|u| FrozenChange {
                instance: u.clone(),
                frozen: false,
            })
            .collect();
        assert_eq!(s.take_frozen_changes(), thawed);

        // The grace counts from each stop: no kill before it is over.
        let units = [racer.clone(), puzzle.clone(), theirs.clone()];
        s.tick(t1 + STOP_GRACE - Duration::from_millis(1));
        assert_eq!(kills(&s), 0);
        assert!(s.any_left(&units));
        // They quit on the SIGTERM: a clean end, and nothing is left to wait for.
        for unit in &units {
            assert_eq!(reason(s.on_event(exited(unit, 0, false))), (0, "quit"));
        }
        assert!(!s.any_left(&units));
        assert_eq!(kills(&s), 0);
    }

    #[test]
    fn stop_all_leaves_an_app_already_stopping_alone_and_the_backstop_still_ends_it() {
        let mut s = session();
        let t0 = Instant::now();
        let closing = run_as(&mut s, APP, "p1");
        let playing = run_as(&mut s, PUZZLE, "p1");
        assert_eq!(s.stop(&closing, t0), Status::Ok);
        let before = s.spawner.calls().len();
        let t1 = t0 + Duration::from_secs(20);
        assert_eq!(
            s.stop_all(t1),
            [(closing.clone(), Status::Ok), (playing.clone(), Status::Ok)]
        );
        // A running app is stopped without a thaw; the one already closing is not asked again.
        assert_eq!(s.spawner.calls()[before..], [format!("stop {playing}")]);
        // Its grace still counts from its own Stop.
        s.tick(t0 + STOP_GRACE);
        assert_eq!(s.spawner.calls().last(), Some(&format!("kill {closing}")));
        assert_eq!(kills(&s), 1);
        s.tick(t1 + STOP_GRACE);
        assert_eq!(kills(&s), 2);
    }

    #[test]
    fn stop_all_with_nothing_running_has_nothing_to_wait_for() {
        let mut s = session();
        assert!(s.stop_all(Instant::now()).is_empty());
        assert!(!s.any_left(&[]));
        assert!(s.spawner.calls().is_empty());
    }

    // Steam's games as child instances (ADR-041, RUY-1052).

    const STEAM: &str = "com.valvesoftware.Steam";
    const GAME_SCOPE: &str = "app-flatpak-com.valvesoftware.Steam-1623993748.scope";
    const STEAM_SCOPE: &str = "app-flatpak-com.valvesoftware.Steam-2192235278.scope";

    fn child_started(parent: &str, appid: &str, frozen: bool) -> UnitEvent {
        UnitEvent::ChildStarted {
            parent: parent.to_owned(),
            child: crate::spawner::child_name(parent, appid),
            appid: appid.to_owned(),
            started: 1_500,
            frozen,
        }
    }

    /// Steam of p1 running, with the Half-Life child (70) announced. The spawner's calls so far
    /// are cleared out of the way by the callers that look at them (`calls_since`).
    fn steam_with_game(
        spawner: FakeSpawner,
    ) -> (Session<FakeSpawner, ProfileSnapshot>, String, String) {
        let dir = ProfileSnapshot::new(["p1".to_owned(), "p2".to_owned()]);
        let mut s = Session::new(spawner.with_app(STEAM), dir, vec![]);
        let (status, steam) = s.launch(STEAM, "p1", 100, &[]);
        assert_eq!(status, Status::Ok);
        assert_eq!(
            s.on_event(UnitEvent::Started {
                unit: steam.clone()
            })
            .len(),
            1
        );
        let child = crate::spawner::child_name(&steam, "70");
        assert_eq!(
            s.on_event(child_started(&steam, "70", false)),
            [Notice::Started {
                instance: child.clone(),
                app_id: STEAM.to_owned()
            }]
        );
        (s, steam, child)
    }

    fn calls_since(s: &Session<FakeSpawner, ProfileSnapshot>, before: usize) -> Vec<String> {
        s.spawner.calls()[before..].to_vec()
    }

    #[test]
    fn a_steam_game_is_a_child_listed_with_its_item_and_parent_and_announced() {
        let (mut s, steam, child) = steam_with_game(FakeSpawner::new());
        let list = s.list();
        assert_eq!(list.len(), 2);
        let game = list.iter().find(|a| a.instance == child).expect("listed");
        assert_eq!(
            *game,
            RunningApp {
                instance: child.clone(),
                app_id: STEAM.to_owned(),
                item: "steam:70".to_owned(),
                parent: steam.clone(),
                profile: "p1".to_owned(),
                started: 1_500,
                state: State::Running,
                frozen: false,
            }
        );
        let parent = list.iter().find(|a| a.instance == steam).expect("listed");
        assert_eq!(parent.item, "flatpak:com.valvesoftware.Steam");
        assert_eq!(parent.parent, "");
        // The same child twice, a parent that is not running and a bad id change nothing.
        assert!(s.on_event(child_started(&steam, "70", false)).is_empty());
        assert!(s
            .on_event(child_started("ruya-app-ruya-p1-x.y.Z.service", "70", false))
            .is_empty());
        assert!(s.on_event(child_started(&steam, "7a", false)).is_empty());
        assert_eq!(s.list().len(), 2);
        // A second launch of Steam is still Steam's own answer, the child aside.
        assert_eq!(s.launch(STEAM, "p1", 200, &[]).0, Status::AlreadyRunning);
    }

    #[test]
    fn a_childs_end_is_a_quit_and_its_parent_runs_on() {
        let (mut s, steam, child) = steam_with_game(FakeSpawner::new());
        assert_eq!(reason(s.on_event(exited(&child, 0, false))), (0, "quit"));
        let list = s.list();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].instance, steam);
        // The game again: a new child of the same name.
        assert_eq!(s.on_event(child_started(&steam, "70", false)).len(), 1);
    }

    #[test]
    fn stop_kill_and_freeze_of_a_child_reach_only_the_child() {
        let (mut s, steam, child) = steam_with_game(FakeSpawner::new());
        let before = s.spawner.calls().len();
        assert_eq!(s.freeze(&child, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(calls_since(&s, before), [format!("freeze {child}")]);
        assert!(frozen_of(&s, &child));
        assert!(!frozen_of(&s, &steam), "each record's frozen is its own");
        assert_eq!(
            s.take_frozen_changes(),
            [FrozenChange {
                instance: child.clone(),
                frozen: true
            }]
        );
        let before = s.spawner.calls().len();
        assert_eq!(s.thaw(&child, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(calls_since(&s, before), [format!("thaw {child}")]);
        let before = s.spawner.calls().len();
        assert_eq!(s.stop(&child, Instant::now()), Status::Ok);
        assert_eq!(calls_since(&s, before), [format!("stop {child}")]);
        let before = s.spawner.calls().len();
        assert_eq!(s.kill(&child, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(calls_since(&s, before), [format!("kill {child}")]);
        let states: Vec<(String, State)> = s
            .list()
            .into_iter()
            .map(|a| (a.instance, a.state))
            .collect();
        assert_eq!(states, [(steam, State::Running), (child, State::Stopping)]);
    }

    #[test]
    fn stop_and_kill_of_the_parent_reach_its_children_first() {
        let (mut s, steam, child) = steam_with_game(FakeSpawner::new());
        let before = s.spawner.calls().len();
        assert_eq!(s.stop(&steam, Instant::now()), Status::Ok);
        assert_eq!(
            calls_since(&s, before),
            [format!("stop {child}"), format!("stop {steam}")]
        );
        assert!(s.list().iter().all(|a| a.state == State::Stopping));

        let (mut s, steam, child) = steam_with_game(FakeSpawner::new());
        let before = s.spawner.calls().len();
        assert_eq!(s.kill(&steam, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(
            calls_since(&s, before),
            [format!("kill {child}"), format!("kill {steam}")]
        );
        // Both ends are "killed".
        assert_eq!(reason(s.on_event(exited(&child, 0, false))), (0, "killed"));
    }

    #[test]
    fn a_frozen_child_is_thawed_before_the_stop_of_its_parent() {
        let (mut s, steam, child) = steam_with_game(FakeSpawner::new());
        assert_eq!(s.freeze(&child, Some("p1"), Instant::now()), Status::Ok);
        let before = s.spawner.calls().len();
        assert_eq!(s.stop(&steam, Instant::now()), Status::Ok);
        assert_eq!(
            calls_since(&s, before),
            [
                format!("thaw {child}"),
                format!("stop {child}"),
                format!("stop {steam}")
            ]
        );
    }

    /// `freeze` freezes Steam's game, then Steam's own unit; the Thaw of Steam thaws both, the game
    /// first.
    fn freezes_both_and_thaw_thaws_both(
        s: &mut Session<FakeSpawner, ProfileSnapshot>,
        steam: &str,
        child: &str,
        freeze: impl FnOnce(&mut Session<FakeSpawner, ProfileSnapshot>),
    ) {
        let before = s.spawner.calls().len();
        freeze(s);
        assert_eq!(
            calls_since(s, before),
            [format!("freeze {child}"), format!("freeze {steam}")]
        );
        assert!(frozen_of(s, child) && frozen_of(s, steam));
        let before = s.spawner.calls().len();
        assert_eq!(s.thaw(steam, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(
            calls_since(s, before),
            [format!("thaw {child}"), format!("thaw {steam}")]
        );
        assert!(!frozen_of(s, child) && !frozen_of(s, steam));
    }

    #[test]
    fn freeze_and_thaw_of_a_parent_reach_its_children_and_itself_as_its_app_allows() {
        // freeze = always (Steam's table today): the child, then the parent's own.
        let (mut s, steam, child) = steam_with_game(FakeSpawner::new());
        freezes_both_and_thaw_thaws_both(&mut s, &steam, &child, |s| {
            assert_eq!(s.freeze(&steam, Some("p1"), Instant::now()), Status::Ok);
        });

        // freeze = never (ADR-042, what B5 sets): the child only; Steam keeps running.
        let (mut s, steam, child) = steam_with_game(FakeSpawner::new().with_freeze_never(STEAM));
        let before = s.spawner.calls().len();
        assert_eq!(s.freeze(&steam, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(calls_since(&s, before), [format!("freeze {child}")]);
        assert!(frozen_of(&s, &child));
        assert!(!frozen_of(&s, &steam), "the parent's frozen is its own");
        let before = s.spawner.calls().len();
        assert_eq!(s.thaw(&steam, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(calls_since(&s, before), [format!("thaw {child}")]);
    }

    #[test]
    fn a_switch_freezes_a_never_frozen_steam_and_its_game_and_the_way_back_thaws_both() {
        // A profile that leaves freezes the game and Steam too (ADR-046 point 2, RUY-1063: a
        // running Steam would keep its /dev/uinput descriptor for the next profile's time). p1
        // back: the shell's Thaw of Steam thaws its game first, then the unit itself.
        let (mut s, steam, child) = steam_with_game(FakeSpawner::new().with_freeze_never(STEAM));
        freezes_both_and_thaw_thaws_both(&mut s, &steam, &child, |s| {
            let asked = s.profile_changed(Some("p1"), "p2", Instant::now());
            assert!(asked.iter().all(|(_, status)| *status == Status::Ok));
            assert!(asked.iter().any(|(unit, _)| *unit == steam));
            s.profile_changed(Some("p2"), "p1", Instant::now());
        });
        // The Hub's pause of the same app still only holds Steam (ADR-042 point 3).
        let before = s.spawner.calls().len();
        assert_eq!(s.freeze(&steam, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(calls_since(&s, before), [format!("freeze {child}")]);
        assert!(!frozen_of(&s, &steam));
    }

    #[test]
    fn a_never_frozen_app_that_starts_after_its_profile_left_is_frozen() {
        let dir = ProfileSnapshot::new(["p1".to_owned(), "p2".to_owned()]);
        let mut s = Session::new(
            FakeSpawner::new().with_app(STEAM).with_freeze_never(STEAM),
            dir,
            vec![],
        );
        let (_, steam) = s.launch(STEAM, "p1", 100, &[]);
        s.profile_changed(Some("p1"), "p2", Instant::now());
        s.on_event(UnitEvent::Started {
            unit: steam.clone(),
        });
        assert_eq!(
            s.freeze_if_away(&steam, "p2", Instant::now()),
            Some(Status::Ok)
        );
        assert!(frozen_of(&s, &steam));
    }

    // ---- A paused parent whose app is never frozen is held (ADR-042 point 3) -------------------

    #[test]
    fn a_never_frozen_parent_with_a_game_is_held_so_its_sound_is_parked_with_the_games() {
        let (mut s, steam, child) = steam_with_game(FakeSpawner::new().with_freeze_never(STEAM));
        s.take_frozen_changes();
        assert!(s.spawner.audio_calls().is_empty());
        assert_eq!(s.freeze(&steam, Some("p1"), Instant::now()), Status::Ok);
        // Sound is per app id today (RUY-1081): the game's freeze already parks "Steam", and the
        // held parent changes nothing more in the request.
        assert_eq!(
            s.spawner.audio_calls(),
            [format!("ruya-p1 frozen={STEAM} running={STEAM}")]
        );
        assert!(s
            .instances
            .iter()
            .any(|i| i.held.is_some() && i.unit == steam));
        // Only the game's record changed: `FrozenChanged` is never sent for the held parent.
        assert_eq!(
            s.take_frozen_changes(),
            [FrozenChange {
                instance: child.clone(),
                frozen: true
            }]
        );
        assert!(!frozen_of(&s, &steam));
        assert_eq!(s.thaw(&steam, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(
            s.spawner.audio_calls().last().unwrap(),
            &format!("ruya-p1 frozen= running={STEAM}")
        );
        // A thaw of a parent that is no longer held asks no more.
        let calls = s.spawner.audio_calls().len();
        assert_eq!(s.thaw(&steam, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(s.spawner.audio_calls().len(), calls);
    }

    #[test]
    fn a_never_frozen_parent_paused_alone_is_held_and_no_frozen_change_is_sent() {
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(
            FakeSpawner::new().with_app(STEAM).with_freeze_never(STEAM),
            dir,
            vec![],
        );
        let (_, steam) = s.launch(STEAM, "p1", 100, &[]);
        s.on_event(UnitEvent::Started {
            unit: steam.clone(),
        });
        assert_eq!(s.freeze(&steam, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(
            s.spawner.audio_calls(),
            [format!("ruya-p1 frozen={STEAM} running={STEAM}")]
        );
        assert!(s.take_frozen_changes().is_empty());
        assert!(!s.spawner.calls().iter().any(|c| c.starts_with("freeze ")));
        // A second Freeze changes nothing; the Thaw puts the sound back.
        assert_eq!(s.freeze(&steam, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(s.spawner.audio_calls().len(), 1);
        assert_eq!(s.thaw(&steam, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(
            s.spawner.audio_calls()[1..],
            [format!("ruya-p1 frozen= running={STEAM}")]
        );
        assert!(s.take_frozen_changes().is_empty());
        // A Stop of a held parent clears it: the end leaves nothing parked.
        assert_eq!(s.freeze(&steam, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(s.stop(&steam, Instant::now()), Status::Ok);
        assert_eq!(s.on_event(exited(&steam, 0, false)).len(), 1);
        assert_eq!(
            s.spawner.audio_calls().last().unwrap(),
            "ruya-p1 frozen= running="
        );
    }

    #[test]
    fn a_failed_freeze_of_a_parent_undoes_its_childrens() {
        let (mut s, steam, child) = steam_with_game(FakeSpawner::new());
        // The shared fake: from now on every freeze fails.
        let _ = s.spawner.observer().failing_freeze();
        assert_eq!(s.freeze(&steam, Some("p1"), Instant::now()), Status::Failed);
        assert!(!frozen_of(&s, &child) && !frozen_of(&s, &steam));
    }

    #[test]
    fn a_pid_in_a_game_scope_names_the_child_and_one_in_steams_names_steam() {
        let spawner = FakeSpawner::new()
            .with_user(1000, "ruya-p1")
            .with_user(1001, "ruya-p2")
            .with_process(42, &cgroup(1000, GAME_SCOPE))
            .with_process(43, &cgroup(1000, STEAM_SCOPE))
            .with_process(44, &cgroup(1001, GAME_SCOPE));
        let parent = unit_name("ruya-p1", STEAM);
        let child = crate::spawner::child_name(&parent, "70");
        let (s, steam, listed) =
            steam_with_game(spawner.with_child_scope("ruya-p1", GAME_SCOPE, &child));
        assert_eq!(listed, child);
        assert_eq!(s.instance_of_pid(42), (Status::Ok, child));
        assert_eq!(s.instance_of_pid(43), (Status::Ok, steam));
        // The same scope name in another profile's manager is not this child's.
        assert_eq!(s.instance_of_pid(44), (Status::NotFound, String::new()));
    }

    #[test]
    fn a_parent_that_ends_ends_its_children_first() {
        let (mut s, steam, child) = steam_with_game(FakeSpawner::new());
        let notices = s.on_event(exited(&steam, 0, false));
        assert_eq!(
            notices,
            [
                Notice::Exited {
                    instance: child,
                    app_id: STEAM.to_owned(),
                    exit_code: 0,
                    reason: ExitReason::Quit,
                    profile: "p1".to_owned(),
                    item: "steam:70".to_owned()
                },
                Notice::Exited {
                    instance: steam,
                    app_id: STEAM.to_owned(),
                    exit_code: 0,
                    reason: ExitReason::Quit,
                    profile: "p1".to_owned(),
                    item: format!("flatpak:{STEAM}")
                }
            ]
        );
        assert!(s.list().is_empty());
    }

    #[test]
    fn an_adopted_steam_gets_its_games_again_and_a_hidden_ones_stay_hidden() {
        let spawner = FakeSpawner::new()
            .with_app(STEAM)
            .with_running("ruya-p1", STEAM, 1_000)
            .with_running("ruya-p9", STEAM, 1_000);
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let mut s = Session::new(spawner, dir, vec![]);
        assert_eq!(s.adopt(5_000, Instant::now(), true).len(), 1);
        let steam = unit_name("ruya-p1", STEAM);
        let child = crate::spawner::child_name(&steam, "70");
        // The game left frozen before the restart comes back frozen.
        assert_eq!(s.on_event(child_started(&steam, "70", true)).len(), 1);
        let game = s
            .list()
            .into_iter()
            .find(|a| a.instance == child)
            .expect("listed");
        assert_eq!(
            (game.item.as_str(), game.parent.as_str()),
            ("steam:70", steam.as_str())
        );
        assert!(game.frozen);
        // The game of a removed profile's Steam is hidden like its parent: never announced.
        let orphan = unit_name("ruya-p9", STEAM);
        assert!(s.on_event(child_started(&orphan, "70", false)).is_empty());
        assert!(s.list().iter().all(|a| a.parent != orphan));
    }

    // LaunchItem of a Steam game (ADR-041 point 3, RUY-1067).

    /// p1 and p2, Steam installed (or not), nothing running.
    fn steam_session(
        spawner: FakeSpawner,
        installed: bool,
    ) -> Session<FakeSpawner, ProfileSnapshot> {
        let dir = ProfileSnapshot::new(["p1".to_owned(), "p2".to_owned()]);
        let spawner = if installed {
            spawner.with_app(STEAM)
        } else {
            spawner
        };
        Session::new(spawner, dir, vec![])
    }

    /// Steam of p1 launched and, when `running`, announced: its instance.
    fn steam_up(s: &mut Session<FakeSpawner, ProfileSnapshot>, running: bool) -> String {
        let (status, steam) = s.launch(STEAM, "p1", 100, &[]);
        assert_eq!(status, Status::Ok);
        if running {
            assert_eq!(
                s.on_event(UnitEvent::Started {
                    unit: steam.clone()
                })
                .len(),
                1
            );
        }
        steam
    }

    fn record_of(s: &Session<FakeSpawner, ProfileSnapshot>, instance: &str) -> Option<RunningApp> {
        s.list().into_iter().find(|a| a.instance == instance)
    }

    /// The end of p1's Steam game `instance` that never got its scope.
    fn never_ran(instance: &str, item: &str, reason: ExitReason) -> Notice {
        Notice::Exited {
            instance: instance.to_owned(),
            app_id: STEAM.to_owned(),
            exit_code: -1,
            reason,
            profile: "p1".to_owned(),
            item: item.to_owned(),
        }
    }

    /// p1's Steam running, with steam:70 asked for by LaunchItem and still starting.
    fn steam_with_starting_game() -> (Session<FakeSpawner, ProfileSnapshot>, String, String) {
        let mut s = steam_session(FakeSpawner::new(), true);
        let steam = steam_up(&mut s, true);
        let (_, child) = s.launch_steam_game("70", "p1", 100, Instant::now());
        (s, steam, child)
    }

    /// `verb` ("stop" or "kill", as p1) of `instance`.
    fn end_by(s: &mut Session<FakeSpawner, ProfileSnapshot>, verb: &str, instance: &str) -> Status {
        if verb == "stop" {
            s.stop(instance, Instant::now())
        } else {
            s.kill(instance, Some("p1"), Instant::now())
        }
    }

    #[test]
    fn a_steam_game_with_steam_stopped_starts_steam_with_its_url() {
        let mut s = steam_session(FakeSpawner::new(), true);
        let (status, child) = s.launch_steam_game("70", "p1", 100, Instant::now());
        let steam = unit_name("ruya-p1", STEAM);
        assert_eq!(
            (status, child.as_str()),
            (
                Status::Ok,
                crate::spawner::child_name(&steam, "70").as_str()
            )
        );
        assert_eq!(s.spawner.calls(), [format!("start ruya-p1 {STEAM}")]);
        assert_eq!(s.spawner.last_launch_args(), ["steam://rungameid/70"]);
        let parent = record_of(&s, &steam).expect("Steam is listed");
        assert_eq!(
            (parent.state, parent.parent.as_str()),
            (State::Starting, "")
        );
        assert_eq!(
            record_of(&s, &child),
            Some(RunningApp {
                instance: child.clone(),
                app_id: STEAM.to_owned(),
                item: "steam:70".to_owned(),
                parent: steam.clone(),
                profile: "p1".to_owned(),
                started: 100,
                state: State::Starting,
                frozen: false,
            })
        );
        // Starting is no frozen-able state: Freeze of the game is "not-running".
        assert_eq!(
            s.freeze(&child, Some("p1"), Instant::now()),
            Status::NotRunning
        );
    }

    #[test]
    fn a_steam_game_with_steam_running_or_starting_is_handed_to_it() {
        for running in [true, false] {
            let mut s = steam_session(FakeSpawner::new(), true);
            let steam = steam_up(&mut s, running);
            let before = s.spawner.calls().len();
            let (status, child) = s.launch_steam_game("7670", "p1", 200, Instant::now());
            assert_eq!(
                (status, child.as_str()),
                (
                    Status::Ok,
                    crate::spawner::child_name(&steam, "7670").as_str()
                ),
                "Steam running: {running}"
            );
            assert_eq!(calls_since(&s, before), ["forward ruya-p1 7670"]);
            let parent = record_of(&s, &steam).expect("Steam is listed");
            let state = if running {
                State::Running
            } else {
                State::Starting
            };
            assert_eq!(
                (parent.state, parent.started),
                (state, 100),
                "Steam is unchanged"
            );
            let game = record_of(&s, &child).expect("the game is listed");
            assert_eq!(
                (game.state, game.parent.as_str(), game.item.as_str()),
                (State::Starting, steam.as_str(), "steam:7670")
            );
        }
    }

    #[test]
    fn the_launched_game_runs_from_its_scope_and_is_announced_once() {
        let mut s = steam_session(FakeSpawner::new(), true);
        let (_, child) = s.launch_steam_game("70", "p1", 100, Instant::now());
        let steam = unit_name("ruya-p1", STEAM);
        assert_eq!(
            s.on_event(UnitEvent::Started {
                unit: steam.clone()
            }),
            [Notice::Started {
                instance: steam.clone(),
                app_id: STEAM.to_owned()
            }],
            "Steam's own start is Steam's alone"
        );
        assert_eq!(
            record_of(&s, &child).map(|a| a.state),
            Some(State::Starting)
        );
        assert_eq!(
            s.on_event(child_started(&steam, "70", false)),
            [Notice::Started {
                instance: child.clone(),
                app_id: STEAM.to_owned()
            }]
        );
        let game = record_of(&s, &child).expect("listed");
        assert_eq!((game.state, game.started), (State::Running, 1_500));
        assert!(s.on_event(child_started(&steam, "70", false)).is_empty());
        // Running from its scope: no wait runs out any more.
        assert!(s.tick(Instant::now() + CHILD_LAUNCH_WAIT * 2).is_empty());
        assert_eq!(s.list().len(), 2);
    }

    #[test]
    fn a_game_without_a_scope_is_launch_failed_after_120_s() {
        let mut s = steam_session(FakeSpawner::new(), true);
        let steam = steam_up(&mut s, true);
        let t0 = Instant::now();
        let (_, child) = s.launch_steam_game("70", "p1", 100, t0);
        let before = s.spawner.calls().len();
        assert!(s.tick(t0 + Duration::from_secs(119)).is_empty());
        assert!(record_of(&s, &child).is_some());
        assert_eq!(
            s.tick(t0 + Duration::from_secs(120)),
            [never_ran(&child, "steam:70", ExitReason::LaunchFailed)]
        );
        assert!(record_of(&s, &child).is_none(), "the record is gone");
        assert!(record_of(&s, &steam).is_some(), "Steam runs on");
        assert_eq!(calls_since(&s, before), Vec::<String>::new());
        assert!(s.tick(t0 + Duration::from_secs(121)).is_empty());
    }

    #[test]
    fn a_game_that_is_starting_running_or_stopping_is_already_running() {
        let mut s = steam_session(FakeSpawner::new(), true);
        let steam = steam_up(&mut s, true);
        let (_, child) = s.launch_steam_game("70", "p1", 100, Instant::now());
        let before = s.spawner.calls().len();
        let again = |s: &mut Session<FakeSpawner, ProfileSnapshot>| {
            s.launch_steam_game("70", "p1", 300, Instant::now())
        };
        assert_eq!(again(&mut s), (Status::AlreadyRunning, child.clone()));
        s.on_event(child_started(&steam, "70", false));
        assert_eq!(again(&mut s), (Status::AlreadyRunning, child.clone()));
        let stops = s.spawner.calls().len();
        assert_eq!(s.stop(&child, Instant::now()), Status::Ok);
        assert_eq!(
            record_of(&s, &child).map(|a| a.state),
            Some(State::Stopping)
        );
        assert_eq!(again(&mut s), (Status::AlreadyRunning, child.clone()));
        assert_eq!(
            calls_since(&s, before),
            [format!("stop {child}")],
            "no launch reached the OS"
        );
        assert_eq!(s.spawner.calls().len(), stops + 1);
        // Another profile's game of the same id is its own.
        assert_eq!(
            s.launch_steam_game("70", "p2", 300, Instant::now()).0,
            Status::Ok
        );

        // A game started in Steam's own UI is the same child.
        let (mut s, _steam, child) = steam_with_game(FakeSpawner::new());
        let before = s.spawner.calls().len();
        assert_eq!(
            s.launch_steam_game("70", "p1", 300, Instant::now()),
            (Status::AlreadyRunning, child)
        );
        assert_eq!(calls_since(&s, before), Vec::<String>::new());
    }

    #[test]
    fn stop_and_kill_of_a_starting_game_end_it_in_the_core() {
        for (verb, reason) in [("stop", ExitReason::Quit), ("kill", ExitReason::Killed)] {
            let (mut s, steam, child) = steam_with_starting_game();
            let before = s.spawner.calls().len();
            assert_eq!(end_by(&mut s, verb, &child), Status::Ok, "{verb}");
            assert_eq!(calls_since(&s, before), Vec::<String>::new(), "{verb}");
            assert_eq!(
                record_of(&s, &child).map(|a| a.state),
                Some(State::Stopping)
            );
            // Its scope coming now changes nothing: it was ended.
            assert!(s.on_event(child_started(&steam, "70", false)).is_empty());
            assert_eq!(
                s.tick(Instant::now()),
                [never_ran(&child, "steam:70", reason)],
                "{verb}"
            );
            assert!(record_of(&s, &child).is_none());
            assert_eq!(record_of(&s, &steam).map(|a| a.state), Some(State::Running));
        }
        // Kill after Stop is "killed"; Kill keeps its profile check.
        let (mut s, _, child) = steam_with_starting_game();
        assert_eq!(
            s.kill(&child, Some("p2"), Instant::now()),
            Status::NotAllowed
        );
        assert_eq!(s.stop(&child, Instant::now()), Status::Ok);
        assert_eq!(s.kill(&child, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(reason(s.tick(Instant::now())), (-1, "killed"));
    }

    #[test]
    fn stop_or_kill_of_steam_ends_its_starting_game_first() {
        for verb in ["stop", "kill"] {
            let (mut s, steam, child) = steam_with_starting_game();
            let before = s.spawner.calls().len();
            assert_eq!(end_by(&mut s, verb, &steam), Status::Ok);
            assert_eq!(
                calls_since(&s, before),
                [format!("{verb} {steam}")],
                "the game has nothing to reach"
            );
            assert!(s.list().iter().all(|a| a.state == State::Stopping));
            assert_eq!(
                s.tick(Instant::now()),
                [never_ran(&child, "steam:70", ExitReason::LaunchFailed)]
            );
            assert_eq!(s.list().len(), 1);
        }
        // Steam's end before the next tick: the game's end still comes first.
        let (mut s, steam, child) = steam_with_starting_game();
        assert_eq!(s.stop(&steam, Instant::now()), Status::Ok);
        let ends: Vec<(String, i32, ExitReason)> = s
            .on_event(exited(&steam, 0, false))
            .into_iter()
            .map(|n| match n {
                Notice::Exited {
                    instance,
                    exit_code,
                    reason,
                    ..
                } => (instance, exit_code, reason),
                other => panic!("{other:?}"),
            })
            .collect();
        assert_eq!(
            ends,
            [
                (child, -1, ExitReason::LaunchFailed),
                (steam, 0, ExitReason::Quit)
            ]
        );
        assert!(s.list().is_empty());
        assert!(s.tick(Instant::now()).is_empty());
    }

    #[test]
    fn a_refused_steam_game_leaves_no_record() {
        let now = Instant::now();
        let mut s = steam_session(FakeSpawner::new(), true);
        for (appid, profile) in [("70", "../p1"), ("70", ""), ("7a", "p1"), ("", "p1")] {
            assert_eq!(
                s.launch_steam_game(appid, profile, 1, now),
                (Status::Invalid, String::new()),
                "{appid} {profile}"
            );
        }
        assert_eq!(
            s.launch_steam_game("70", "p9", 1, now),
            (Status::UnknownProfile, String::new())
        );
        assert!(s.list().is_empty());
        assert!(s.spawner.calls().is_empty());

        let mut s = steam_session(FakeSpawner::new(), false);
        assert_eq!(
            s.launch_steam_game("70", "p1", 1, now),
            (Status::UnknownApp, String::new())
        );
        assert!(s.list().is_empty());

        let mut s = steam_session(FakeSpawner::new().failing_start(), true);
        assert_eq!(
            s.launch_steam_game("70", "p1", 1, now),
            (Status::Failed, String::new())
        );
        assert!(s.list().is_empty());

        let mut s = steam_session(FakeSpawner::new().failing_forward(), true);
        let steam = steam_up(&mut s, true);
        assert_eq!(
            s.launch_steam_game("70", "p1", 1, now),
            (Status::Failed, String::new())
        );
        let left: Vec<String> = s.list().into_iter().map(|a| a.instance).collect();
        assert_eq!(left, [steam]);
    }

    // ---- The lifecycle told to Platform1 (RUY-1099, ADR-022) -----------------------------------

    use async_channel::Receiver;

    /// `s` with its notices in a channel, as the console runs it.
    fn told(
        s: Session<FakeSpawner, ProfileSnapshot>,
    ) -> (
        Session<FakeSpawner, ProfileSnapshot>,
        Receiver<LifecycleNotice>,
    ) {
        let (outbox, notices) = async_channel::unbounded();
        (s.with_lifecycle(outbox, SAVE_WAIT), notices)
    }

    /// The notices sent so far, as (instance, event).
    fn notices(rx: &Receiver<LifecycleNotice>) -> Vec<(String, LifecycleEvent)> {
        std::iter::from_fn(|| rx.try_recv().ok())
            .map(|n| {
                assert_eq!(n.profile, "p1");
                (n.instance, n.event)
            })
            .collect()
    }

    /// The backstop's kill of `unit` comes at `at`, not a moment before.
    fn killed_at(s: &mut Session<FakeSpawner, ProfileSnapshot>, unit: &str, at: Instant) {
        s.tick(at - Duration::from_millis(1));
        assert!(!s.spawner.calls().contains(&format!("kill {unit}")));
        s.tick(at);
        assert_eq!(s.spawner.calls().last(), Some(&format!("kill {unit}")));
    }

    const STOPPING: LifecycleEvent = LifecycleEvent::Stopping { deadline_ms: 5000 };

    fn resume(ms: u64) -> LifecycleEvent {
        LifecycleEvent::Resume { frozen_ms: ms }
    }

    fn held_steam() -> (
        Session<FakeSpawner, ProfileSnapshot>,
        Receiver<LifecycleNotice>,
        String,
    ) {
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let s = Session::new(
            FakeSpawner::new().with_app(STEAM).with_freeze_never(STEAM),
            dir,
            vec![],
        );
        let (mut s, rx) = told(s);
        let (_, steam) = s.launch(STEAM, "p1", 100, &[]);
        s.on_event(UnitEvent::Started {
            unit: steam.clone(),
        });
        (s, rx, steam)
    }

    #[test]
    fn a_freeze_tells_nothing_and_its_thaw_tells_resume_with_the_frozen_time() {
        let (mut s, rx) = told(session());
        let unit = running(&mut s);
        let t0 = Instant::now();
        assert_eq!(s.freeze(&unit, Some("p1"), t0), Status::Ok);
        assert!(frozen_of(&s, &unit));
        assert!(notices(&rx).is_empty(), "no notice before or at a freeze");
        let t1 = t0 + Duration::from_millis(1500);
        assert_eq!(s.thaw(&unit, Some("p1"), t1), Status::Ok);
        assert_eq!(notices(&rx), [(unit.clone(), resume(1500))]);
        // A thaw of an app that was not frozen tells nothing.
        assert_eq!(s.thaw(&unit, Some("p1"), t1), Status::Ok);
        assert!(notices(&rx).is_empty());
        // Neither does a profile that leaves: its freeze is a freeze like the Hub's.
        s.profile_changed(Some("p1"), "p2", t1);
        assert!(frozen_of(&s, &unit));
        assert!(notices(&rx).is_empty());
    }

    #[test]
    fn only_a_hold_tells_background_once_and_its_end_tells_resume() {
        let (mut s, rx, steam) = held_steam();
        let t0 = Instant::now();
        assert_eq!(s.freeze(&steam, Some("p1"), t0), Status::Ok);
        assert!(!frozen_of(&s, &steam));
        assert_eq!(notices(&rx), [(steam.clone(), LifecycleEvent::Background)]);
        // A second Freeze while held tells nothing more.
        assert_eq!(
            s.freeze(&steam, Some("p1"), t0 + Duration::from_secs(1)),
            Status::Ok
        );
        assert!(notices(&rx).is_empty());
        // The Thaw ends the hold: the time since it began.
        let t1 = t0 + Duration::from_millis(700);
        assert_eq!(s.thaw(&steam, Some("p1"), t1), Status::Ok);
        assert_eq!(notices(&rx), [(steam.clone(), resume(700))]);
        // A profile that leaves freezes even a `never` app (RUY-1063): no Background then.
        s.profile_changed(Some("p1"), "", t1);
        assert!(frozen_of(&s, &steam));
        assert!(notices(&rx).is_empty());
    }

    #[test]
    fn a_held_app_frozen_later_is_told_one_resume_from_the_hold() {
        let (mut s, rx, steam) = held_steam();
        let t0 = Instant::now();
        assert_eq!(s.freeze(&steam, Some("p1"), t0), Status::Ok);
        // Its profile leaves while it is held, and signs in again.
        s.profile_changed(Some("p1"), "", t0 + Duration::from_secs(2));
        s.profile_changed(Some(""), "p1", t0 + Duration::from_secs(3));
        assert_eq!(notices(&rx), [(steam.clone(), LifecycleEvent::Background)]);
        assert_eq!(
            s.thaw(&steam, Some("p1"), t0 + Duration::from_secs(4)),
            Status::Ok
        );
        assert_eq!(notices(&rx), [(steam, resume(4000))]);
    }

    #[test]
    fn a_child_is_told_its_own_resume_and_a_frozen_parent_its_own() {
        let (s, steam, child) = steam_with_game(FakeSpawner::new());
        let (mut s, rx) = told(s);
        let t0 = Instant::now();
        assert_eq!(s.freeze(&steam, Some("p1"), t0), Status::Ok);
        assert!(notices(&rx).is_empty());
        assert_eq!(
            s.thaw(&steam, Some("p1"), t0 + Duration::from_millis(250)),
            Status::Ok
        );
        assert_eq!(notices(&rx), [(child, resume(250)), (steam, resume(250))]);
    }

    #[test]
    fn a_stop_tells_stopping_and_sends_its_sigterm_once_the_wait_settled() {
        let (mut s, rx) = told(session());
        let unit = running(&mut s);
        let t0 = Instant::now();
        assert_eq!(s.stop(&unit, t0), Status::Ok);
        assert_eq!(notices(&rx), [(unit.clone(), STOPPING)]);
        assert!(!s.spawner.calls().contains(&format!("stop {unit}")));
        assert_eq!(s.list()[0].state, State::Stopping);
        // A second Stop while it waits changes nothing.
        assert_eq!(s.stop(&unit, t0), Status::Ok);
        assert!(notices(&rx).is_empty());
        // Nothing while it saves: no SIGTERM, and the grace has not started.
        let t1 = t0 + Duration::from_secs(3);
        s.tick(t1 - Duration::from_millis(1));
        assert!(!s.spawner.calls().contains(&format!("stop {unit}")));
        // Settled: the SIGTERM, and Close game's whole grace starts now.
        assert_eq!(s.saved(&unit, t1), Status::Ok);
        assert_eq!(s.spawner.calls().last(), Some(&format!("stop {unit}")));
        assert_eq!(s.saved(&unit, t1), Status::UnknownInstance, "settled once");
        killed_at(&mut s, &unit, t1 + STOP_GRACE);
    }

    #[test]
    fn an_app_that_quits_while_it_saves_is_a_quit_and_its_late_answer_does_nothing() {
        let (mut s, rx) = told(session());
        let unit = running(&mut s);
        assert_eq!(s.stop(&unit, Instant::now()), Status::Ok);
        assert_eq!(notices(&rx).len(), 1);
        assert_eq!(reason(s.on_event(exited(&unit, 0, false))), (0, "quit"));
        assert_eq!(s.saved(&unit, Instant::now()), Status::UnknownInstance);
        assert!(!s.spawner.calls().contains(&format!("stop {unit}")));
    }

    #[test]
    fn a_kill_while_it_saves_ends_the_wait_and_no_sigterm_follows() {
        let (mut s, rx) = told(session());
        let unit = running(&mut s);
        assert_eq!(s.stop(&unit, Instant::now()), Status::Ok);
        assert_eq!(notices(&rx).len(), 1);
        assert_eq!(s.kill(&unit, Some("p1"), Instant::now()), Status::Ok);
        assert_eq!(s.saved(&unit, Instant::now()), Status::UnknownInstance);
        assert!(!s.spawner.calls().contains(&format!("stop {unit}")));
        assert_eq!(reason(s.on_event(exited(&unit, 0, true))), (0, "killed"));
    }

    #[test]
    fn a_frozen_app_is_thawed_told_resume_then_stopping() {
        let (mut s, rx) = told(session());
        let unit = running(&mut s);
        let t0 = Instant::now();
        assert_eq!(s.freeze(&unit, Some("p1"), t0), Status::Ok);
        assert_eq!(s.stop(&unit, t0 + Duration::from_millis(3000)), Status::Ok);
        assert_eq!(s.spawner.calls().last(), Some(&format!("thaw {unit}")));
        assert_eq!(
            notices(&rx),
            [(unit.clone(), resume(3000)), (unit.clone(), STOPPING)]
        );
    }

    #[test]
    fn a_parents_sigterm_follows_its_childrens_after_every_wait_settled() {
        let (s, steam, child) = steam_with_game(FakeSpawner::new());
        let (mut s, rx) = told(s);
        let before = s.spawner.calls().len();
        assert_eq!(s.stop(&steam, Instant::now()), Status::Ok);
        assert_eq!(
            notices(&rx),
            [(child.clone(), STOPPING), (steam.clone(), STOPPING)]
        );
        // Steam's own wait settles first (it did not register): it waits for its game.
        assert_eq!(s.saved(&steam, Instant::now()), Status::Ok);
        assert!(calls_since(&s, before).is_empty());
        assert_eq!(s.saved(&child, Instant::now()), Status::Ok);
        assert_eq!(
            calls_since(&s, before),
            [format!("stop {child}"), format!("stop {steam}")]
        );
    }

    #[test]
    fn without_platform1_a_stop_sends_its_sigterm_at_once() {
        // No outbox (`--session` tests, a service without the sender), or one nobody reads.
        let mut s = session();
        let unit = running(&mut s);
        assert_eq!(s.stop(&unit, Instant::now()), Status::Ok);
        assert_eq!(s.spawner.calls().last(), Some(&format!("stop {unit}")));
        let (mut s, rx) = told(session());
        drop(rx);
        let unit = running(&mut s);
        assert_eq!(s.stop(&unit, Instant::now()), Status::Ok);
        assert_eq!(s.spawner.calls().last(), Some(&format!("stop {unit}")));
    }

    #[test]
    fn a_save_wait_without_an_answer_ends_at_its_deadline_in_tick() {
        let (mut s, rx) = told(session());
        let unit = running(&mut s);
        let t0 = Instant::now();
        assert_eq!(s.stop(&unit, t0), Status::Ok);
        assert_eq!(notices(&rx).len(), 1);
        s.tick(t0 + SAVE_WAIT - Duration::from_millis(1));
        assert!(!s.spawner.calls().contains(&format!("stop {unit}")));
        let t1 = t0 + SAVE_WAIT;
        s.tick(t1);
        assert_eq!(s.spawner.calls().last(), Some(&format!("stop {unit}")));
        // The answer that comes late changes nothing.
        assert_eq!(s.saved(&unit, t1), Status::UnknownInstance);
        // Close game: the whole grace from the SIGTERM.
        killed_at(&mut s, &unit, t1 + STOP_GRACE);
    }

    #[test]
    fn at_power_off_the_save_window_is_part_of_the_grace() {
        let (mut s, rx) = told(session());
        let unit = running(&mut s);
        let t0 = Instant::now();
        assert_eq!(s.stop_all(t0), [(unit.clone(), Status::Ok)]);
        assert_eq!(notices(&rx), [(unit.clone(), STOPPING)]);
        assert!(!s.spawner.calls().contains(&format!("stop {unit}")));
        // It saved after 2 s: the SIGTERM then, and the kill still 30 s after the Stopping.
        assert_eq!(s.saved(&unit, t0 + Duration::from_secs(2)), Status::Ok);
        assert_eq!(s.spawner.calls().last(), Some(&format!("stop {unit}")));
        killed_at(&mut s, &unit, t0 + STOP_GRACE);
    }

    #[test]
    fn at_power_off_a_silent_app_gets_its_sigterm_at_5_s_and_its_kill_at_30_s() {
        let (mut s, rx) = told(session());
        let unit = running(&mut s);
        let t0 = Instant::now();
        assert_eq!(s.stop_all(t0), [(unit.clone(), Status::Ok)]);
        assert_eq!(notices(&rx).len(), 1);
        s.tick(t0 + SAVE_WAIT);
        assert_eq!(s.spawner.calls().last(), Some(&format!("stop {unit}")));
        killed_at(&mut s, &unit, t0 + STOP_GRACE);
    }

    #[test]
    fn a_power_off_during_a_close_games_save_wait_counts_its_grace_from_that_stopping() {
        let (mut s, rx) = told(session());
        let unit = running(&mut s);
        let t0 = Instant::now();
        assert_eq!(s.stop(&unit, t0), Status::Ok);
        assert_eq!(
            s.stop_all(t0 + Duration::from_secs(1)),
            [(unit.clone(), Status::Ok)]
        );
        assert_eq!(
            notices(&rx),
            [(unit.clone(), STOPPING)],
            "no second Stopping"
        );
        assert_eq!(s.saved(&unit, t0 + Duration::from_secs(4)), Status::Ok);
        s.tick(t0 + STOP_GRACE);
        assert_eq!(s.spawner.calls().last(), Some(&format!("kill {unit}")));
    }

    #[test]
    fn at_power_off_children_and_parents_wait_side_by_side_and_end_in_order() {
        let (s, steam, child) = steam_with_game(FakeSpawner::new());
        let (mut s, rx) = told(s);
        let before = s.spawner.calls().len();
        let t0 = Instant::now();
        assert_eq!(s.stop_all(t0).len(), 2);
        assert_eq!(
            notices(&rx),
            [(child.clone(), STOPPING), (steam.clone(), STOPPING)]
        );
        s.tick(t0 + SAVE_WAIT);
        assert_eq!(
            calls_since(&s, before),
            [format!("stop {child}"), format!("stop {steam}")]
        );
    }
}
