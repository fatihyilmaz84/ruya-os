//! The watch of one profile user's manager (T-290, T-340, RUY-1250): one thread and one
//! long-lived connection per user (`UserWatch`, `ManagerLink`), shared by everything the service
//! follows there, and only while it follows something (a run it started or adopted).
//!
//! - **The Flatpak scopes of the runs** (`scope::RunScopes`): after each `Subscribe` one listing
//!   over the bus, then the manager's `UnitNew`, `PropertiesChanged` and `UnitRemoved` attach a
//!   run's scope, end it and hand on the unit end it held; the CPU is read over the bus. The wait
//!   lasts until the next thing that has no signal (`RunScopes::next_deadline`), a signal, or a
//!   poke of another thread (a held end, a probe's verdict, a new run).
//! - **The app units that were already running when the service started** (`Follower`):
//!   `PropertiesChanged` of a unit (`ActiveState`, `ExecMainStatus`, `ExecMainCode`) and
//!   `UnitRemoved` keep the real exit status that a `--collect`ed unit takes with it. A unit
//!   launched since has its `systemd-run --wait` for that (`spawner::RunFollower`).
//!
//! No process is started while the connection lives. When it is lost both fall back: the scopes
//! to `systemctl show` at their own pace (`RunScopes::plan`), the adopted units to a look at each
//! every two seconds (`ManagerLink::probe`); the connection is tried again with a growing pause
//! (`Backoff`), and once it is back the scopes are listed and every unit looked at once.
//!
//! A unit is never given up on a failed look: after `WATCH_MAX_MISSES` of them in a row the
//! manager is asked whether the unit still exists (`ManagerLink::exists`), and only a "no" ends
//! the watch; an Alive look in between starts the count again, and an error of logind or of
//! the user database is not a "no" (`existence`). The OS is behind `ManagerLink` and `Sink`
//! (`systemd.rs`), so all of this runs on every host against a fake manager.

use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use zbus::message::{Message, Type};

use crate::scope::{ProbeRequest, RunScopes, Sweep};
use crate::spawner::{ShowUnit, UnitChange, UnitEvent, UnitWatch};
use ruya_ids::profile_of_user;

/// How often a unit is looked at while the connection is down.
pub const WATCH_POLL: Duration = Duration::from_secs(2);
/// How long one wait for a signal lasts when nothing arrives (an idle round, no work).
pub const EVENT_WAIT: Duration = Duration::from_secs(30);
/// Consecutive failed looks after which the manager is asked whether the unit still exists.
pub const WATCH_MAX_MISSES: u32 = 5;

/// What the manager's connection delivered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ManagerEvent {
    /// `UnitNew`: the manager loaded a unit (a new scope); it says nothing of its state yet.
    New {
        unit: String,
    },
    Changed {
        unit: String,
        change: UnitChange,
    },
    Removed {
        unit: String,
    },
}

/// The outcome of waiting for the manager.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Wake {
    Event(ManagerEvent),
    /// Nothing came within the time (or another thread poked the watch).
    Quiet,
    /// The connection is gone.
    Lost,
}

/// One look at a unit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Probe {
    Alive(ShowUnit),
    /// The manager answered: there is no such active unit any more.
    Gone,
    /// The manager could not be asked.
    Unknown,
}

/// The manager of one profile user, as its watch needs it.
pub trait ManagerLink {
    /// The watch's clock.
    fn now(&self) -> Instant;
    /// Blocks up to `max`: for the next event of a unit while connected, `Lost` when the
    /// connection ends; without a connection it only waits. A poke ends the wait early (`Quiet`).
    fn wait(&mut self, max: Duration) -> Wake;
    /// Tries to (re)connect and subscribe, unless the pause after the last failure (`Backoff`)
    /// has not passed yet; true when it is connected now.
    fn reconnect(&mut self) -> bool;
    /// The units matching `names` (names and globs), any state, over the connection, with
    /// `ActiveEnterTimestamp`, `FreezerState` and `CPUUsageNSec`; `None` when the connection broke
    /// (it is dropped then). Starts no process.
    fn list(&mut self, names: &[String]) -> Option<Vec<ShowUnit>>;
    /// `CPUUsageNSec` of each of `units` that has one, over the connection; `None` when the
    /// connection broke (it is dropped then). Starts no process.
    fn cpu(&mut self, units: &[String]) -> Option<Vec<(String, u64)>>;
    /// `systemctl show` of `names`, for the scopes while there is no connection; `None` when it
    /// failed.
    fn show(&mut self, names: &[String]) -> Option<Vec<ShowUnit>>;
    /// Looks at one unit (a bus call when connected, a `systemctl show` otherwise).
    fn probe(&mut self, unit: &str) -> Probe;
    /// Does the unit still exist? `Some(false)` only when the manager answered that it does not
    /// (`existence`: the user is unknown, its manager is stopped, or the unit is inactive);
    /// `None` when that cannot be told either, a hiccup of logind or the user database among
    /// them (then the unit is kept).
    fn exists(&mut self, unit: &str) -> Option<bool>;
}

/// The answer of `ManagerLink::exists`, from what the system said, asked step by step:
/// whether the profile user exists (`user_known`: `Some(false)` is a clear "no such user",
/// `None` is "the user database could not be asked"), whether its manager runs, and the unit's
/// state (`active`, `inactive`, ...). A step that could not be asked ends in `None`, which keeps
/// the unit: an error is never taken for a "no" (RUY-23).
pub fn existence(
    user_known: Option<bool>,
    manager_running: impl FnOnce() -> Option<bool>,
    unit_state: impl FnOnce() -> Option<String>,
) -> Option<bool> {
    if !user_known? {
        return Some(false);
    }
    if !manager_running()? {
        return Some(false);
    }
    match unit_state()?.trim() {
        "active" | "activating" | "deactivating" | "reloading" => Some(true),
        "inactive" | "failed" => Some(false),
        _ => None,
    }
}

struct Watched {
    watch: UnitWatch,
    unit: String,
    misses: u32,
}

/// The adopted units of one user's manager, until each has ended.
pub struct Follower {
    watched: Vec<Watched>,
}

impl Follower {
    pub fn new(units: &[String]) -> Self {
        let mut follower = Follower {
            watched: Vec::new(),
        };
        follower.add(units);
        follower
    }

    /// More adopted units (a late adoption); one followed already is not added twice.
    pub fn add(&mut self, units: &[String]) {
        for unit in units {
            if !self.watched.iter().any(|w| w.unit == *unit) {
                self.watched.push(Watched {
                    watch: UnitWatch::new(unit),
                    unit: unit.clone(),
                    misses: 0,
                });
            }
        }
    }

    pub fn is_done(&self) -> bool {
        self.watched.is_empty()
    }

    /// A signal of the manager: the end of a followed unit, if it says so.
    pub fn on_event(&mut self, event: &ManagerEvent) -> Option<UnitEvent> {
        let (unit, ended) = match event {
            ManagerEvent::New { .. } => return None,
            ManagerEvent::Changed { unit, change } => {
                let at = self.watched.iter_mut().find(|w| w.unit == *unit)?;
                (unit, at.watch.apply(change))
            }
            ManagerEvent::Removed { unit } => {
                let at = self.watched.iter().find(|w| w.unit == *unit)?;
                (unit, Some(at.watch.ended()))
            }
        };
        let ended = ended?;
        self.watched.retain(|w| w.unit != *unit);
        Some(ended)
    }

    /// One look at every followed unit (`ManagerLink::probe`): the ones that ended.
    pub fn look_at_all(&mut self, link: &mut dyn ManagerLink) -> Vec<UnitEvent> {
        let mut ended = Vec::new();
        let mut i = 0;
        while i < self.watched.len() {
            let w = &mut self.watched[i];
            let end = match link.probe(&w.unit) {
                Probe::Alive(show) => {
                    w.misses = 0;
                    w.watch.observe(&show)
                }
                Probe::Gone => Some(w.watch.ended()),
                Probe::Unknown => {
                    w.misses += 1;
                    if w.misses >= WATCH_MAX_MISSES {
                        w.misses = 0;
                        match link.exists(&w.unit) {
                            Some(false) => Some(w.watch.ended()),
                            Some(true) => None,
                            None => {
                                eprintln!(
                                    "ruya-session: cannot tell whether {} still exists, keeping it",
                                    w.unit
                                );
                                None
                            }
                        }
                    } else {
                        None
                    }
                }
            };
            match end {
                Some(event) => {
                    ended.push(event);
                    self.watched.remove(i);
                }
                None => i += 1,
            }
        }
        ended
    }
}

/// Where a user's watch hands on what it found (`systemd::Gate`; a recorder in the tests).
pub trait Sink {
    /// The scopes of every run, shared with the spawner and the probe worker. Never held across
    /// a call to the manager.
    fn scopes(&self) -> &Mutex<RunScopes>;
    /// Clears what is left of runs that ended, before their ends are sent (`spawner::sweep_commands`).
    fn sweep(&self, sweeps: Vec<Sweep>);
    /// An event on its way to the core.
    fn send(&self, event: UnitEvent);
    /// Probes to run (`steam-probe`), on a worker of their own; each verdict comes back through
    /// `RunScopes::probed`.
    fn probe(&self, probes: Vec<ProbeRequest>);
}

fn scopes_of(sink: &dyn Sink) -> MutexGuard<'_, RunScopes> {
    sink.scopes().lock().unwrap_or_else(|e| e.into_inner())
}

/// Runs `judge` on the scopes and hands on what it released: the sweeps first, then the ends (a
/// child's before its parent's, in `RunScopes`' order), then the probes it asked for.
pub fn settle(sink: &dyn Sink, judge: impl FnOnce(&mut RunScopes) -> Vec<UnitEvent>) {
    let (ended, sweeps, probes) = {
        let mut scopes = scopes_of(sink);
        let ended = judge(&mut scopes);
        (ended, scopes.take_sweeps(), scopes.take_probes())
    };
    sink.sweep(sweeps);
    for event in ended {
        sink.send(event);
    }
    sink.probe(probes);
}

/// A unit's own event on its way to the core (T-363): the end of a unit whose scope still lives
/// is held by `RunScopes::on_unit_event` until the scope is gone. True when it was held.
pub fn deliver(sink: &dyn Sink, event: UnitEvent, now: Instant) -> bool {
    let (passed, sweeps) = {
        let mut scopes = scopes_of(sink);
        let passed = scopes.on_unit_event(event, now);
        (passed, scopes.take_sweeps())
    };
    sink.sweep(sweeps);
    match passed {
        Some(event) => {
            sink.send(event);
            false
        }
        None => true,
    }
}

/// The watch of one profile user's manager: its adopted units (`Follower`) and the scopes of its
/// runs (`RunScopes`), over one connection (`ManagerLink`).
pub struct UserWatch {
    user: String,
    follower: Follower,
    /// Is the connection up, subscribed and listed?
    linked: bool,
    /// Units were adopted since the last listing: list and look again.
    fresh: bool,
    /// Without the connection, when the adopted units are looked at next (`None`: at once).
    look_at: Option<Instant>,
}

impl UserWatch {
    pub fn new(user: &str) -> Self {
        UserWatch {
            user: user.to_owned(),
            follower: Follower::new(&[]),
            linked: false,
            fresh: false,
            look_at: None,
        }
    }

    /// Units adopted after a restart of the service (their runs begun in `RunScopes` already):
    /// they are looked at once at the next round, so an end between the listing and now is seen.
    pub fn adopt(&mut self, units: &[String]) {
        self.follower.add(units);
        self.fresh = true;
        self.look_at = None;
    }

    /// Are adopted units still followed?
    pub fn adopted_left(&self) -> bool {
        !self.follower.is_done()
    }

    /// One round: waits for the manager (or, without the connection, for the next look) and hands
    /// on what it found. False, at once, when nothing of the user is followed any more: the caller
    /// then drops the connection.
    pub fn step(&mut self, link: &mut dyn ManagerLink, sink: &dyn Sink) -> bool {
        if self.follower.is_done() && !scopes_of(sink).has_runs(&self.user) {
            return false;
        }
        if self.linked {
            self.step_linked(link, sink);
        } else {
            self.step_down(link, sink);
        }
        true
    }

    fn step_linked(&mut self, link: &mut dyn ManagerLink, sink: &dyn Sink) {
        if self.fresh {
            let now = link.now();
            if !self.list_and_look(link, sink, now) {
                return;
            }
        }
        let now = link.now();
        let due = scopes_of(sink).next_deadline(&self.user);
        let max = due
            .map_or(EVENT_WAIT, |at| at.saturating_duration_since(now))
            .min(EVENT_WAIT);
        match link.wait(max) {
            Wake::Event(event) => {
                let now = link.now();
                if let Some(end) = self.follower.on_event(&event) {
                    deliver(sink, end, now);
                }
                if !self.on_event(link, sink, &event, now) {
                    return;
                }
            }
            Wake::Quiet => {}
            Wake::Lost => {
                eprintln!("ruya-session: lost a user manager, looking at its apps every 2 s");
                self.lose(sink, link.now());
                return;
            }
        }
        let now = link.now();
        let names = scopes_of(sink).cpu_due(&self.user, now);
        if !names.is_empty() {
            let Some(readings) = link.cpu(&names) else {
                self.lose(sink, now);
                return;
            };
            scopes_of(sink).on_cpu(&self.user, &readings);
        }
        settle(sink, |s| s.tick(&self.user, now));
    }

    /// A signal for the scopes: a new unit they care about is read over the connection first (a
    /// `UnitNew` names it only). False when the connection broke.
    fn on_event(
        &mut self,
        link: &mut dyn ManagerLink,
        sink: &dyn Sink,
        event: &ManagerEvent,
        now: Instant,
    ) -> bool {
        if let ManagerEvent::New { unit } = event {
            if !scopes_of(sink).concerns(&self.user, unit) {
                return true;
            }
            let Some(shows) = link.list(std::slice::from_ref(unit)) else {
                self.lose(sink, now);
                return false;
            };
            settle(sink, |s| s.on_read(&self.user, &shows, now));
            return true;
        }
        settle(sink, |s| s.on_manager_event(&self.user, event, now));
        true
    }

    fn step_down(&mut self, link: &mut dyn ManagerLink, sink: &dyn Sink) {
        let now = link.now();
        let looks = (!self.follower.is_done()).then(|| self.look_at.unwrap_or(now));
        let due = [looks, scopes_of(sink).next_deadline(&self.user)]
            .into_iter()
            .flatten()
            .min();
        // At least every `WATCH_POLL` a try to connect again (the link's backoff decides).
        let pause = due
            .map_or(WATCH_POLL, |at| at.saturating_duration_since(now))
            .min(WATCH_POLL);
        link.wait(pause);
        let now = link.now();
        if link.reconnect() {
            eprintln!(
                "ruya-session: following the manager of {} over one connection",
                self.user
            );
            self.linked = true;
            self.list_and_look(link, sink, now);
            return;
        }
        if !self.follower.is_done() && self.look_at.map_or(true, |at| now >= at) {
            for end in self.follower.look_at_all(link) {
                deliver(sink, end, now);
            }
            self.look_at = Some(now + WATCH_POLL);
        }
        let query = scopes_of(sink).plan(&self.user, now);
        if let Some(query) = query {
            let shows = link.show(&query.names);
            settle(sink, |s| s.apply(&self.user, shows.as_deref(), now));
        }
    }

    /// Right after `Subscribe` (or an adoption): the runs' units and scopes listed over the
    /// connection, so a scope made before the subscription is not missed, and every adopted
    /// unit looked at once. False when the connection broke meanwhile.
    fn list_and_look(&mut self, link: &mut dyn ManagerLink, sink: &dyn Sink, now: Instant) -> bool {
        self.fresh = false;
        let query = scopes_of(sink).listing(&self.user);
        let shows = match query {
            Some(query) => match link.list(&query.names) {
                Some(shows) => shows,
                None => {
                    self.lose(sink, now);
                    return false;
                }
            },
            None => Vec::new(),
        };
        settle(sink, |s| s.on_listing(&self.user, &shows, now));
        for end in self.follower.look_at_all(link) {
            deliver(sink, end, now);
        }
        true
    }

    /// The connection is gone: the scopes are looked at with `systemctl show` at once, the
    /// adopted units every `WATCH_POLL`.
    fn lose(&mut self, sink: &dyn Sink, now: Instant) {
        self.linked = false;
        self.look_at = Some(now + WATCH_POLL);
        scopes_of(sink).link_lost(&self.user, now);
    }
}

/// The D-Bus address of the bridge to one profile user's manager, the same `unixexec:` route
/// `systemctl --user --machine=<user>@.host` takes: `systemd-run` starts `systemd-stdio-bridge`
/// inside that user's manager and its stdin/stdout are the bus connection. Built from a
/// validated `ruya-<profile id>` user only. These are the arguments of `systemd-run` (the
/// program, `BRIDGE_PROGRAM`); the caller builds zbus's typed `Unixexec` address from them. Not
/// an address string: zbus 5.19 does not percent-decode `unixexec` arguments, so an escaped
/// `--machine%3d...` reached `systemd-run` literally and the bridge ended at once ("Unexpected
/// EOF during handshake", VM 0.0.59, lead-7).
pub fn bridge_args(user: &str) -> Result<Vec<String>, String> {
    if profile_of_user(user).is_none() {
        return Err(format!("not a profile user: {user:?}"));
    }
    Ok(vec![
        format!("--machine={user}@.host"),
        "--user".to_owned(),
        "--pipe".to_owned(),
        "--quiet".to_owned(),
        "--collect".to_owned(),
        "systemd-stdio-bridge".to_owned(),
        "--user".to_owned(),
    ])
}

/// The program `bridge_args` belongs to.
pub const BRIDGE_PROGRAM: &str = "systemd-run";

/// How long to wait before the next try to start the bridge again: 2 s, doubling, at most 60 s.
#[derive(Debug, Default)]
pub struct Backoff {
    failures: u32,
}

impl Backoff {
    pub fn delay(&self) -> Duration {
        Duration::from_secs((2_u64 << self.failures.min(5)).min(60))
    }
    pub fn failed(&mut self) {
        self.failures = self.failures.saturating_add(1);
    }
    pub fn worked(&mut self) {
        self.failures = 0;
    }
}

const UNIT_PATH: &str = "/org/freedesktop/systemd1/unit/";

/// The object path of a unit (`sd_bus_path_encode`): the characters that are not `[A-Za-z0-9]`
/// become `_` and two hex digits.
pub fn unit_path(unit: &str) -> String {
    let mut path = String::from(UNIT_PATH);
    for b in unit.bytes() {
        if b.is_ascii_alphanumeric() {
            path.push(char::from(b));
        } else {
            path.push_str(&format!("_{b:02x}"));
        }
    }
    path
}

/// The unit of an object path made by `unit_path`.
pub fn unit_of_path(path: &str) -> Option<String> {
    let rest = path.strip_prefix(UNIT_PATH)?;
    let bytes = rest.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'_' {
            let hex = rest.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok().filter(|u| !u.is_empty())
}

/// A systemd timestamp (microseconds since the epoch) in whole seconds, as `ShowUnit::entered`.
pub fn usec_to_secs(usec: u64) -> i64 {
    i64::try_from(usec / 1_000_000).unwrap_or(0)
}

/// The event a signal from the manager means for the units we follow, or `None` for any other
/// message.
pub fn parse_signal(message: &Message) -> Option<ManagerEvent> {
    let header = message.header();
    if header.message_type() != Type::Signal {
        return None;
    }
    let member = header.member()?.as_str();
    match member {
        "UnitNew" | "UnitRemoved" => {
            let (unit, _path): (String, zbus::zvariant::OwnedObjectPath) =
                message.body().deserialize().ok()?;
            Some(if member == "UnitNew" {
                ManagerEvent::New { unit }
            } else {
                ManagerEvent::Removed { unit }
            })
        }
        "PropertiesChanged" => {
            let unit = unit_of_path(header.path()?.as_str())?;
            let (interface, changed, _invalidated): (
                String,
                std::collections::HashMap<String, zbus::zvariant::OwnedValue>,
                Vec<String>,
            ) = message.body().deserialize().ok()?;
            if interface != "org.freedesktop.systemd1.Unit"
                && interface != "org.freedesktop.systemd1.Service"
            {
                return None;
            }
            let int = |name: &str| {
                changed
                    .get(name)
                    .and_then(|v| i32::try_from(v.clone()).ok())
            };
            let text = |name: &str| {
                changed
                    .get(name)
                    .and_then(|v| String::try_from(v.clone()).ok())
            };
            let change = UnitChange {
                active_state: text("ActiveState"),
                exec_main_status: int("ExecMainStatus"),
                exec_main_code: int("ExecMainCode"),
                // Microseconds in the signal, whole seconds like `systemctl show --timestamp=unix`.
                entered: changed
                    .get("ActiveEnterTimestamp")
                    .and_then(|v| u64::try_from(v.clone()).ok())
                    .map(usec_to_secs),
                freezer_state: text("FreezerState"),
            };
            Some(ManagerEvent::Changed { unit, change })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scope::tests::{FakeManager, USER};
    use crate::scope::Query;
    use std::cell::RefCell;
    use std::collections::{HashMap, VecDeque};

    const A: &str = "ruya-app-ruya-p1-org.ruyaos.Racer.service";
    const B: &str = "ruya-app-ruya-p1-org.ruyaos.Puzzle.service";
    const C: &str = "ruya-app-ruya-p1-org.ruyaos.Chess.service";

    fn units(names: &[&str]) -> Vec<String> {
        names.iter().map(|n| (*n).to_owned()).collect()
    }

    fn exited(unit: &str, code: i32, signaled: bool) -> UnitEvent {
        UnitEvent::Exited {
            unit: unit.to_owned(),
            code,
            signaled,
        }
    }

    fn changed(unit: &str, state: Option<&str>, status: Option<i32>, code: Option<i32>) -> Wake {
        Wake::Event(ManagerEvent::Changed {
            unit: unit.to_owned(),
            change: UnitChange {
                active_state: state.map(str::to_owned),
                exec_main_status: status,
                exec_main_code: code,
                ..UnitChange::default()
            },
        })
    }

    fn alive(unit: &str) -> Probe {
        Probe::Alive(ShowUnit {
            id: unit.to_owned(),
            load_state: "loaded".to_owned(),
            active_state: "active".to_owned(),
            ..ShowUnit::default()
        })
    }

    /// A manager that says what it is told, with a clock that only moves when the watch waits,
    /// and counts the `systemctl` processes a real one would have started (`spawns`: a look at a
    /// unit or a `show` without the connection) and the bus calls (`lists`, `cpu_reads`).
    struct FakeLink {
        epoch: Instant,
        /// What `wait` returns while connected, in order; `Quiet` when empty (the whole time
        /// passes). Without the connection the whole time passes.
        wakes: VecDeque<Wake>,
        /// Does `reconnect` work?
        can_connect: bool,
        connected: bool,
        /// The answers of `probe` per unit, in order; the last one repeats.
        probes: HashMap<String, VecDeque<Probe>>,
        exists: Option<bool>,
        seconds: u64,
        spawns: u32,
        exists_asked: u32,
        /// The units and scopes `list`, `cpu` and `show` answer from (RUY-1250).
        mgr: FakeManager,
        connects: u32,
        lists: u32,
        cpu_reads: u32,
    }

    impl Default for FakeLink {
        fn default() -> Self {
            FakeLink {
                epoch: Instant::now(),
                wakes: VecDeque::new(),
                can_connect: false,
                connected: false,
                probes: HashMap::new(),
                exists: None,
                seconds: 0,
                spawns: 0,
                exists_asked: 0,
                mgr: FakeManager::new(Vec::new()),
                connects: 0,
                lists: 0,
                cpu_reads: 0,
            }
        }
    }

    fn query(names: &[String]) -> Query {
        Query {
            user: USER.to_owned(),
            names: names.to_vec(),
        }
    }

    impl ManagerLink for FakeLink {
        fn now(&self) -> Instant {
            self.epoch + Duration::from_secs(self.seconds)
        }

        fn wait(&mut self, max: Duration) -> Wake {
            if !self.connected {
                self.seconds += max.as_secs();
                return Wake::Quiet;
            }
            match self.wakes.pop_front() {
                Some(Wake::Lost) => {
                    self.connected = false;
                    Wake::Lost
                }
                Some(wake) => wake,
                None => {
                    self.seconds += max.as_secs();
                    Wake::Quiet
                }
            }
        }

        fn reconnect(&mut self) -> bool {
            if self.can_connect && !self.connected {
                self.connects += 1;
            }
            self.connected = self.can_connect;
            self.connected
        }

        fn list(&mut self, names: &[String]) -> Option<Vec<ShowUnit>> {
            assert!(self.connected, "a bus listing needs the connection");
            self.lists += 1;
            self.mgr.show(&query(names))
        }

        fn cpu(&mut self, units: &[String]) -> Option<Vec<(String, u64)>> {
            assert!(self.connected, "a bus read needs the connection");
            self.cpu_reads += 1;
            Some(
                units
                    .iter()
                    .filter_map(|u| {
                        let show = self.mgr.units.iter().find(|s| s.id == *u)?;
                        Some((u.clone(), show.cpu_nsec?))
                    })
                    .collect(),
            )
        }

        fn show(&mut self, names: &[String]) -> Option<Vec<ShowUnit>> {
            assert!(
                !self.connected,
                "systemctl show only without the connection"
            );
            self.spawns += 1;
            self.mgr.show(&query(names))
        }

        fn probe(&mut self, unit: &str) -> Probe {
            if !self.connected {
                self.spawns += 1;
            }
            let queue = self.probes.entry(unit.to_owned()).or_default();
            if queue.len() > 1 {
                queue.pop_front().unwrap_or(Probe::Unknown)
            } else {
                queue.front().cloned().unwrap_or_else(|| alive(unit))
            }
        }

        fn exists(&mut self, _unit: &str) -> Option<bool> {
            self.exists_asked += 1;
            self.exists
        }
    }

    fn connected_link() -> FakeLink {
        FakeLink {
            can_connect: true,
            ..FakeLink::default()
        }
    }

    /// What the watch handed on, in order.
    #[derive(Default)]
    struct Recorder {
        scopes: Mutex<RunScopes>,
        sent: RefCell<Vec<UnitEvent>>,
        sweeps: RefCell<Vec<Sweep>>,
        probes: RefCell<Vec<ProbeRequest>>,
    }

    impl Sink for Recorder {
        fn scopes(&self) -> &Mutex<RunScopes> {
            &self.scopes
        }
        fn sweep(&self, sweeps: Vec<Sweep>) {
            self.sweeps.borrow_mut().extend(sweeps);
        }
        fn send(&self, event: UnitEvent) {
            self.sent.borrow_mut().push(event);
        }
        fn probe(&self, probes: Vec<ProbeRequest>) {
            self.probes.borrow_mut().extend(probes);
        }
    }

    impl Recorder {
        fn runs(&self) -> MutexGuard<'_, RunScopes> {
            self.scopes.lock().unwrap_or_else(|e| e.into_inner())
        }
    }

    /// One round of the watch; returns what it sent in that round.
    fn step(w: &mut UserWatch, link: &mut FakeLink, sink: &Recorder) -> Vec<UnitEvent> {
        let before = sink.sent.borrow().len();
        assert!(w.step(link, sink), "the watch still follows something");
        sink.sent.borrow()[before..].to_vec()
    }

    /// A watch of `USER` that follows the adopted units `names`.
    fn adopted(names: &[&str]) -> UserWatch {
        let mut w = UserWatch::new(USER);
        w.adopt(&units(names));
        w
    }

    /// A watch of the adopted unit A whose manager cannot be asked (every look fails), and that
    /// answers `exists` when asked whether A still exists.
    fn unreachable(exists: Option<bool>) -> (UserWatch, FakeLink, Recorder) {
        let mut link = FakeLink {
            exists,
            ..FakeLink::default()
        };
        link.probes
            .insert(A.to_owned(), VecDeque::from([Probe::Unknown]));
        (adopted(&[A]), link, Recorder::default())
    }

    #[test]
    fn adopted_unit_exit_is_seen_without_polling() {
        let mut link = connected_link();
        let mut f = adopted(&[A, B]);
        let sink = Recorder::default();
        assert!(
            step(&mut f, &mut link, &sink).is_empty(),
            "the first round connects"
        );
        // A non-zero status of a normal exit: the app crashed.
        link.wakes
            .push_back(changed(A, Some("deactivating"), Some(3), Some(1)));
        link.wakes
            .push_back(changed(A, Some("inactive"), None, None));
        // A clean exit, then the manager forgets the unit.
        link.wakes.push_back(changed(B, None, Some(0), Some(1)));
        link.wakes
            .push_back(Wake::Event(ManagerEvent::Removed { unit: B.to_owned() }));
        let mut ended = Vec::new();
        for _ in 0..4 {
            ended.extend(step(&mut f, &mut link, &sink));
        }
        assert_eq!(ended, [exited(A, 3, false), exited(B, 0, false)]);
        assert!(!f.adopted_left());
        assert_eq!(link.spawns, 0);
    }

    #[test]
    fn a_signal_kill_keeps_the_signal_number() {
        let mut link = connected_link();
        let mut f = adopted(&[A]);
        let sink = Recorder::default();
        step(&mut f, &mut link, &sink);
        link.wakes.push_back(changed(A, None, Some(9), Some(2)));
        link.wakes.push_back(changed(A, Some("failed"), None, None));
        step(&mut f, &mut link, &sink);
        assert_eq!(step(&mut f, &mut link, &sink), [exited(A, 9, true)]);
    }

    #[test]
    fn no_process_is_started_while_following_three_units_for_ten_seconds() {
        let mut link = connected_link();
        let mut f = adopted(&[A, B, C]);
        let sink = Recorder::default();
        while link.seconds < 10 {
            assert!(step(&mut f, &mut link, &sink).is_empty());
        }
        assert_eq!(link.spawns, 0, "events, not systemctl show");
        assert!(link.connected && f.adopted_left());
    }

    #[test]
    fn a_lost_connection_falls_back_to_polling_and_recovers() {
        let mut link = connected_link();
        let mut f = adopted(&[A, B]);
        let sink = Recorder::default();
        step(&mut f, &mut link, &sink);
        assert_eq!(link.spawns, 0);
        // The connection drops; the manager cannot be reached again for a while.
        link.can_connect = false;
        link.wakes.push_back(Wake::Lost);
        assert!(step(&mut f, &mut link, &sink).is_empty());
        // Polling: one `show` per unit per round, 2 s apart; A ends meanwhile.
        link.probes.insert(
            A.to_owned(),
            VecDeque::from([
                alive(A),
                Probe::Alive(ShowUnit {
                    active_state: "inactive".to_owned(),
                    ..ShowUnit::default()
                }),
            ]),
        );
        let t = link.seconds;
        assert!(step(&mut f, &mut link, &sink).is_empty());
        assert_eq!(link.spawns, 2);
        assert_eq!(step(&mut f, &mut link, &sink), [exited(A, 0, false)]);
        assert_eq!(link.seconds - t, 4, "two rounds, two seconds each");
        // The manager is back: connect, look once at what is left, then no more processes.
        link.can_connect = true;
        assert!(step(&mut f, &mut link, &sink).is_empty());
        let spawned = link.spawns;
        link.wakes
            .push_back(changed(B, Some("inactive"), Some(7), Some(1)));
        assert_eq!(step(&mut f, &mut link, &sink), [exited(B, 7, false)]);
        assert_eq!(link.spawns, spawned);
    }

    #[test]
    fn an_adopted_unit_is_kept_when_polls_fail_but_the_unit_exists() {
        let (mut f, mut link, sink) = unreachable(Some(true));
        for _ in 0..WATCH_MAX_MISSES * 3 {
            assert!(step(&mut f, &mut link, &sink).is_empty());
        }
        assert!(
            f.adopted_left(),
            "the unit still exists, so it is still followed"
        );
        assert!(link.exists_asked >= 3);
        // It ends for real later.
        link.probes
            .insert(A.to_owned(), VecDeque::from([Probe::Gone]));
        assert_eq!(step(&mut f, &mut link, &sink), [exited(A, 0, false)]);
    }

    #[test]
    fn a_dropped_unit_is_checked_before_it_is_forgotten() {
        let (mut f, mut link, sink) = unreachable(Some(false));
        for _ in 0..WATCH_MAX_MISSES - 1 {
            assert!(step(&mut f, &mut link, &sink).is_empty());
        }
        assert_eq!(link.exists_asked, 0);
        assert_eq!(step(&mut f, &mut link, &sink), [exited(A, 0, false)]);
        assert_eq!(link.exists_asked, 1, "asked once, then forgotten");
        // A manager that cannot tell either keeps the unit.
        let (mut f, mut link, sink) = unreachable(None);
        for _ in 0..WATCH_MAX_MISSES * 2 {
            assert!(step(&mut f, &mut link, &sink).is_empty());
        }
        assert!(f.adopted_left());
    }

    #[test]
    fn alive_between_unknowns_resets_misses() {
        // One failed look short of the threshold, a good one, again: eight failed looks in all,
        // but never WATCH_MAX_MISSES in a row, so the manager is not even asked and the unit
        // stays.
        let mut link = FakeLink {
            exists: Some(false),
            ..FakeLink::default()
        };
        let streak = || (0..WATCH_MAX_MISSES - 1).map(|_| Probe::Unknown);
        let looks: VecDeque<Probe> = streak()
            .chain([alive(A)])
            .chain(streak())
            .chain([alive(A)])
            .collect();
        let rounds = looks.len();
        link.probes.insert(A.to_owned(), looks);
        let mut f = adopted(&[A]);
        let sink = Recorder::default();
        for _ in 0..rounds {
            assert!(step(&mut f, &mut link, &sink).is_empty());
        }
        assert_eq!(
            link.exists_asked, 0,
            "the count started again at each Alive"
        );
        assert!(f.adopted_left());
        // The same looks without the Alive in between reach the threshold.
        let (mut f, mut link, sink) = unreachable(Some(false));
        for _ in 0..WATCH_MAX_MISSES - 1 {
            assert!(step(&mut f, &mut link, &sink).is_empty());
        }
        assert_eq!(step(&mut f, &mut link, &sink), [exited(A, 0, false)]);
    }

    #[test]
    fn user_link_error_is_not_user_unknown() {
        let never = || -> Option<bool> { panic!("not asked") };
        let no_state = || -> Option<String> { panic!("not asked") };
        // The user database could not be asked: the unit is kept, nothing else is asked.
        assert_eq!(existence(None, never, no_state), None);
        // A clear "no such user" ends the watch, without asking more.
        assert_eq!(existence(Some(false), never, no_state), Some(false));
        // The user exists, its manager is stopped: the unit is gone with it.
        assert_eq!(existence(Some(true), || Some(false), no_state), Some(false));
        // The user exists but logind (the manager's state) could not be asked: kept.
        assert_eq!(existence(Some(true), || None, no_state), None);
        // The manager runs: the unit's own state decides, and an unreadable one keeps it.
        let state = |s: &'static str| move || Some(s.to_owned());
        for (said, kept) in [
            ("active", Some(true)),
            ("deactivating", Some(true)),
            ("inactive", Some(false)),
            ("failed", Some(false)),
            ("", None),
            ("unknown", None),
        ] {
            assert_eq!(existence(Some(true), || Some(true), state(said)), kept);
        }
        assert_eq!(existence(Some(true), || Some(true), || None), None);
    }

    #[test]
    fn events_for_other_units_change_nothing() {
        let mut link = connected_link();
        let mut f = adopted(&[A]);
        let sink = Recorder::default();
        step(&mut f, &mut link, &sink);
        link.wakes
            .push_back(changed(B, Some("inactive"), Some(1), Some(1)));
        link.wakes
            .push_back(Wake::Event(ManagerEvent::Removed { unit: B.to_owned() }));
        assert!(step(&mut f, &mut link, &sink).is_empty());
        assert!(step(&mut f, &mut link, &sink).is_empty());
        assert!(f.adopted_left());
    }

    #[test]
    fn the_bridge_argv_is_built_from_validated_values_only() {
        // Plain values, never percent-escaped: zbus passes unixexec arguments through as given.
        assert_eq!(
            bridge_args("ruya-p1").expect("valid"),
            [
                "--machine=ruya-p1@.host",
                "--user",
                "--pipe",
                "--quiet",
                "--collect",
                "systemd-stdio-bridge",
                "--user"
            ]
        );
        assert_eq!(BRIDGE_PROGRAM, "systemd-run");
        for bad in [
            "",
            "ruya-",
            "root",
            "ruya-p1,argv9=x",
            "ruya-a b",
            "ruya-p1@.host",
            "ruya-../x",
            "ruya-p1;",
        ] {
            assert!(bridge_args(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn a_dead_bridge_is_restarted_with_a_growing_pause() {
        let mut b = Backoff::default();
        let secs: Vec<u64> = (0..8)
            .map(|_| {
                let d = b.delay().as_secs();
                b.failed();
                d
            })
            .collect();
        assert_eq!(secs, [2, 4, 8, 16, 32, 60, 60, 60]);
        b.worked();
        assert_eq!(b.delay().as_secs(), 2);
    }

    #[test]
    fn unit_paths_round_trip() {
        assert_eq!(
            unit_path("ruya-app-ruya-p1-org.ruyaos.Racer.service"),
            "/org/freedesktop/systemd1/unit/ruya_2dapp_2druya_2dp1_2dorg_2eruyaos_2eRacer_2eservice"
        );
        for unit in [A, B, "a:b.service", "x_y.service"] {
            assert_eq!(unit_of_path(&unit_path(unit)).as_deref(), Some(unit));
        }
        assert_eq!(unit_of_path("/org/freedesktop/systemd1"), None);
        assert_eq!(unit_of_path("/org/freedesktop/systemd1/unit/a_zz"), None);
        assert_eq!(unit_of_path("/org/freedesktop/systemd1/unit/"), None);
    }

    fn props_signal(
        unit: &str,
        interface: &str,
        props: HashMap<&str, zbus::zvariant::Value<'_>>,
    ) -> Message {
        Message::signal(
            unit_path(unit),
            "org.freedesktop.DBus.Properties",
            "PropertiesChanged",
        )
        .and_then(|b| b.build(&(interface, props, Vec::<&str>::new())))
        .unwrap_or_else(|e| panic!("{e}"))
    }

    #[test]
    fn the_signals_of_the_manager_are_read() {
        use zbus::zvariant::Value;
        let m = props_signal(
            A,
            "org.freedesktop.systemd1.Service",
            HashMap::from([
                ("ExecMainStatus", Value::from(3_i32)),
                ("ExecMainCode", Value::from(1_i32)),
            ]),
        );
        assert_eq!(
            parse_signal(&m),
            Some(ManagerEvent::Changed {
                unit: A.to_owned(),
                change: UnitChange {
                    active_state: None,
                    exec_main_status: Some(3),
                    exec_main_code: Some(1),
                    ..UnitChange::default()
                }
            })
        );
        let m = props_signal(
            A,
            "org.freedesktop.systemd1.Unit",
            HashMap::from([("ActiveState", Value::from("inactive"))]),
        );
        assert_eq!(
            parse_signal(&m),
            Some(ManagerEvent::Changed {
                unit: A.to_owned(),
                change: UnitChange {
                    active_state: Some("inactive".to_owned()),
                    ..UnitChange::default()
                }
            })
        );
        // Some other interface's change is not ours.
        let m = props_signal(A, "org.freedesktop.systemd1.Scope", HashMap::new());
        assert_eq!(parse_signal(&m), None);
        let m = Message::signal(
            "/org/freedesktop/systemd1",
            "org.freedesktop.systemd1.Manager",
            "UnitRemoved",
        )
        .and_then(|b| {
            b.build(&(
                A,
                zbus::zvariant::ObjectPath::try_from(unit_path(A).as_str())
                    .unwrap_or_else(|e| panic!("{e}")),
            ))
        })
        .unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(
            parse_signal(&m),
            Some(ManagerEvent::Removed { unit: A.to_owned() })
        );
        let m = Message::signal("/org/freedesktop/systemd1", "x.Y", "UnitNew")
            .and_then(|b| b.build(&()))
            .unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(parse_signal(&m), None);
    }

    #[test]
    fn a_new_unit_and_its_timestamps_are_read_from_the_signals() {
        use zbus::zvariant::{ObjectPath, Value};
        // UnitNew names the new unit (RUY-1250: a Flatpak scope is attached from it).
        let path = unit_path(SCOPE_A);
        let m = Message::signal("/org/freedesktop/systemd1", MANAGER, "UnitNew")
            .and_then(|b| {
                b.build(&(
                    SCOPE_A,
                    ObjectPath::try_from(path.as_str()).unwrap_or_else(|e| panic!("{e}")),
                ))
            })
            .unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(
            parse_signal(&m),
            Some(ManagerEvent::New {
                unit: SCOPE_A.to_owned()
            })
        );
        // The Unit interface's change carries when it became active (microseconds) and its
        // freezer state.
        let m = props_signal(
            SCOPE_A,
            "org.freedesktop.systemd1.Unit",
            HashMap::from([
                ("ActiveState", Value::from("active")),
                (
                    "ActiveEnterTimestamp",
                    Value::from(1_700_000_001_250_000_u64),
                ),
                ("FreezerState", Value::from("frozen")),
            ]),
        );
        assert_eq!(
            parse_signal(&m),
            Some(ManagerEvent::Changed {
                unit: SCOPE_A.to_owned(),
                change: UnitChange {
                    active_state: Some("active".to_owned()),
                    entered: Some(1_700_000_001),
                    freezer_state: Some("frozen".to_owned()),
                    ..UnitChange::default()
                }
            })
        );
    }

    const MANAGER: &str = "org.freedesktop.systemd1.Manager";
    const SCOPE_A: &str = "app-flatpak-org.ruyaos.Racer-77.scope";

    // RUY-1250: the scopes of launched runs follow the same connection's signals.

    use crate::scope::tests::{
        child, child_started, exited as run_exited, scope_show, unit_show, APP, ATTACHED, GAME,
        SCOPE, STEAM, STEAM_UNIT, UNIT,
    };
    use crate::scope::{CHILD_GRACE, CPU_EVERY};

    /// The manager makes `show` (it loads it and it becomes active): its `UnitNew`, then its
    /// `PropertiesChanged`.
    fn up(link: &mut FakeLink, show: ShowUnit) {
        link.mgr.set(show.clone());
        link.wakes.push_back(Wake::Event(ManagerEvent::New {
            unit: show.id.clone(),
        }));
        link.wakes.push_back(Wake::Event(ManagerEvent::Changed {
            unit: show.id.clone(),
            change: UnitChange {
                active_state: Some(show.active_state.clone()),
                entered: Some(show.entered),
                freezer_state: Some(show.freezer_state.clone()),
                ..UnitChange::default()
            },
        }));
    }

    /// The manager drops `name`: its `UnitRemoved`.
    fn removed(link: &mut FakeLink, name: &str) {
        link.mgr.gone(name);
        link.wakes.push_back(Wake::Event(ManagerEvent::Removed {
            unit: name.to_owned(),
        }));
    }

    /// Rounds until the signals queued so far are taken.
    fn drain(w: &mut UserWatch, link: &mut FakeLink, sink: &Recorder) -> Vec<UnitEvent> {
        let mut sent = Vec::new();
        while !link.wakes.is_empty() {
            sent.extend(step(w, link, sink));
        }
        sent
    }

    /// The probes the watch asked for, run and handed back as `systemd::settle_probe` does.
    fn answer_probes(link: &mut FakeLink, sink: &Recorder) {
        let asked: Vec<ProbeRequest> = sink.probes.borrow_mut().drain(..).collect();
        for r in asked {
            let verdict = link.mgr.probe(&r);
            let started = sink.runs().probed(&r.unit, &r.scope, verdict);
            if let Some(event) = started {
                sink.send(event);
            }
        }
    }

    #[test]
    fn a_launched_scope_is_attached_and_its_end_released_from_events_without_a_look() {
        let mut link = connected_link();
        let sink = Recorder::default();
        let mut w = UserWatch::new(USER);
        sink.runs().begin(UNIT, USER, APP, link.now());
        assert!(
            step(&mut w, &mut link, &sink).is_empty(),
            "connects and lists"
        );
        assert_eq!((link.connects, link.lists), (1, 1));
        assert_eq!(sink.runs().scope_of(UNIT), None, "no scope yet");
        // The unit starts, then `flatpak run` makes its scope a second later.
        link.mgr.set(unit_show(1000, None));
        link.wakes.push_back(Wake::Event(ManagerEvent::Changed {
            unit: UNIT.to_owned(),
            change: UnitChange {
                active_state: Some("active".to_owned()),
                entered: Some(1000),
                ..UnitChange::default()
            },
        }));
        up(&mut link, scope_show(SCOPE, 1001, None));
        assert!(drain(&mut w, &mut link, &sink).is_empty());
        assert_eq!(sink.runs().scope_of(UNIT).as_deref(), Some(SCOPE));
        // The front end ends first: its end is held while the game runs.
        assert!(
            deliver(&sink, run_exited(0), link.now()),
            "held for the scope"
        );
        assert!(sink.sent.borrow().is_empty());
        // The game quits: the scope's UnitRemoved hands the end on, once, with a sweep.
        removed(&mut link, SCOPE);
        assert_eq!(drain(&mut w, &mut link, &sink), [run_exited(0)]);
        assert_eq!(sink.sweeps.borrow().len(), 1);
        assert_eq!(link.spawns, 0, "no systemctl show");
        assert_eq!(link.connects, 1);
        // The listing after Subscribe and the read of the new scope: nothing else was looked at.
        assert_eq!(link.lists, 2);
        assert!(!w.step(&mut link, &sink), "nothing is left to follow");
    }

    #[test]
    fn a_scope_that_existed_before_subscribe_is_found_by_the_listing() {
        // No signal will come for a scope made before the subscription.
        let (_, link, sink) = launched(vec![unit_show(1000, None), scope_show(SCOPE, 1001, None)]);
        assert_eq!(sink.runs().scope_of(UNIT).as_deref(), Some(SCOPE));
        assert_eq!((link.lists, link.spawns), (1, 0));
    }

    /// A watch of `USER` with the run `UNIT` of `APP` begun and its manager holding `shows`, after
    /// its first round (connected and listed).
    fn launched(shows: Vec<ShowUnit>) -> (UserWatch, FakeLink, Recorder) {
        let mut link = connected_link();
        for show in shows {
            link.mgr.set(show);
        }
        let sink = Recorder::default();
        let mut w = UserWatch::new(USER);
        sink.runs().begin(UNIT, USER, APP, link.now());
        step(&mut w, &mut link, &sink);
        (w, link, sink)
    }

    /// Steam's run with its sandbox attached by the listing.
    fn steam_watch() -> (UserWatch, FakeLink, Recorder) {
        let mut link = connected_link();
        link.mgr.set(scope_show(STEAM_UNIT, 1000, None));
        link.mgr.set(scope_show(ATTACHED, 1001, None));
        let sink = Recorder::default();
        let mut w = UserWatch::new(USER);
        sink.runs().begin(STEAM_UNIT, USER, STEAM, link.now());
        sink.runs().follow_children(STEAM_UNIT);
        step(&mut w, &mut link, &sink);
        assert_eq!(sink.runs().scope_of(STEAM_UNIT).as_deref(), Some(ATTACHED));
        (w, link, sink)
    }

    #[test]
    fn a_children_run_starts_and_ends_a_child_from_events() {
        let (mut w, mut link, sink) = steam_watch();
        // A game's scope comes: it is probed and starts the child.
        link.mgr.game(scope_show(GAME, 1100, None), "70");
        up(&mut link, scope_show(GAME, 1100, None));
        drain(&mut w, &mut link, &sink);
        assert_eq!(
            sink.probes
                .borrow()
                .iter()
                .map(|r| r.scope.as_str())
                .collect::<Vec<_>>(),
            [GAME]
        );
        answer_probes(&mut link, &sink);
        assert_eq!(*sink.sent.borrow(), [child_started(1100, false)]);
        // The game quits: the child ends CHILD_GRACE after its last scope went, not before and
        // with no look in between.
        removed(&mut link, GAME);
        let gone = link.now();
        assert!(drain(&mut w, &mut link, &sink).is_empty());
        let end = loop {
            let sent = step(&mut w, &mut link, &sink);
            if !sent.is_empty() {
                break sent;
            }
            assert!(link.now() - gone < CHILD_GRACE * 2, "the child never ended");
        };
        assert_eq!(
            end,
            [UnitEvent::Exited {
                unit: child(),
                code: 0,
                signaled: false
            }]
        );
        assert_eq!(link.now() - gone, CHILD_GRACE);
        assert_eq!(sink.runs().scope_of(STEAM_UNIT).as_deref(), Some(ATTACHED));
        assert_eq!(link.spawns, 0);
    }

    #[test]
    fn an_undecided_scope_is_probed_again_a_second_later_not_at_every_signal() {
        let (mut w, mut link, sink) = steam_watch();
        link.mgr.game(scope_show(GAME, 1100, None), "70");
        link.mgr.early(GAME, 1);
        up(&mut link, scope_show(GAME, 1100, None));
        drain(&mut w, &mut link, &sink);
        answer_probes(&mut link, &sink);
        assert_eq!(link.mgr.probed, [GAME], "undecided once");
        // More signals in the same second (the sandbox starting): no second probe yet.
        let asked = link.now();
        for _ in 0..3 {
            link.wakes.push_back(Wake::Event(ManagerEvent::Changed {
                unit: GAME.to_owned(),
                change: UnitChange::default(),
            }));
        }
        drain(&mut w, &mut link, &sink);
        assert!(
            sink.probes.borrow().is_empty(),
            "not probed at every signal"
        );
        // A second after the first probe it is probed again, and the child starts.
        while sink.probes.borrow().is_empty() {
            step(&mut w, &mut link, &sink);
            assert!(
                link.now() - asked <= Duration::from_secs(1),
                "no probe again"
            );
        }
        answer_probes(&mut link, &sink);
        assert_eq!(link.mgr.probed, [GAME, GAME]);
        assert_eq!(*sink.sent.borrow(), [child_started(1100, false)]);
    }

    #[test]
    fn a_lost_link_falls_back_and_recovers_with_no_lost_end() {
        let (mut w, mut link, sink) =
            launched(vec![unit_show(1000, None), scope_show(SCOPE, 1001, None)]);
        assert!(
            deliver(&sink, run_exited(3), link.now()),
            "held for the scope"
        );
        // The connection drops and cannot be made again for a while: `systemctl show` looks.
        link.can_connect = false;
        link.wakes.push_back(Wake::Lost);
        assert!(step(&mut w, &mut link, &sink).is_empty());
        assert!(step(&mut w, &mut link, &sink).is_empty());
        assert_eq!(link.spawns, 1, "looked at once the connection was gone");
        // The scope ends while nothing signals it: the next look hands the held end on.
        link.mgr.gone(SCOPE);
        let gone = link.now();
        let mut sent = Vec::new();
        while sent.is_empty() {
            sent = step(&mut w, &mut link, &sink);
            assert!(
                link.now() - gone <= Duration::from_secs(2),
                "the look came late"
            );
        }
        assert_eq!(sent, [run_exited(3)]);
        // A second run, and the connection is back before its scope's end is looked at: the
        // listing after the new Subscribe hands it on.
        sink.runs().begin(UNIT, USER, APP, link.now());
        link.mgr.set(scope_show(SCOPE, 1001, None));
        while sink.runs().scope_of(UNIT).is_none() {
            step(&mut w, &mut link, &sink);
        }
        assert!(deliver(&sink, run_exited(0), link.now()));
        link.mgr.gone(SCOPE);
        link.can_connect = true;
        let looks = link.spawns;
        assert_eq!(step(&mut w, &mut link, &sink), [run_exited(0)]);
        assert_eq!(link.connects, 2);
        assert_eq!(link.spawns, looks, "no look once connected");
        assert_eq!(
            *sink.sent.borrow(),
            [run_exited(3), run_exited(0)],
            "no end lost or doubled"
        );
    }

    #[test]
    fn a_held_end_is_released_at_the_scopes_unit_removed_inside_launch_wait() {
        let (mut w, mut link, sink) = launched(vec![
            unit_show(1000, Some(10)),
            scope_show(SCOPE, 1001, Some(100)),
        ]);
        // A Force quit: the kill ends the unit, its end is held for the scope.
        let held = link.now();
        assert!(deliver(&sink, run_exited(137), held));
        // The hold reads the CPU at once (the last reading before the scope goes), no wait.
        link.mgr.set(scope_show(SCOPE, 1001, Some(900)));
        step(&mut w, &mut link, &sink);
        assert_eq!(link.cpu_reads, 1);
        assert_eq!(link.now(), held, "the watch did not wait for the CPU tick");
        assert_eq!(sink.runs().cpu_nsec(UNIT), Some(910));
        // The scope goes with the kill a moment later.
        removed(&mut link, SCOPE);
        assert_eq!(drain(&mut w, &mut link, &sink), [run_exited(137)]);
        assert!(link.now() - held < crate::dbus::LAUNCH_WAIT);
        assert_eq!(link.spawns, 0);
    }

    #[test]
    fn cpu_is_still_summed_over_every_scope_on_the_event_path() {
        let second = "app-flatpak-net.supertuxkart.SuperTuxKart-5000.scope";
        let sibling = "app-flatpak-net.supertuxkart.SuperTuxKart-Extra-9.scope";
        let older = "app-flatpak-net.supertuxkart.SuperTuxKart-7.scope";
        let (mut w, mut link, sink) = launched(vec![
            unit_show(1000, Some(10)),
            scope_show(SCOPE, 1001, Some(100)),
            scope_show(sibling, 1001, Some(1_000_000)),
            scope_show(older, 900, Some(1_000_000)),
        ]);
        assert_eq!(
            sink.runs().cpu_nsec(UNIT),
            Some(110),
            "the listing's readings"
        );
        // The portal's scope appears; the game's CPU grows, which no signal tells.
        up(&mut link, scope_show(second, 1010, Some(1_000)));
        drain(&mut w, &mut link, &sink);
        link.mgr.set(scope_show(SCOPE, 1001, Some(200)));
        let t = link.now();
        while link.now() - t < CPU_EVERY {
            step(&mut w, &mut link, &sink);
        }
        assert_eq!(sink.runs().cpu_nsec(UNIT), Some(10 + 200 + 1_000));
        assert!(link.cpu_reads >= 1);
        // A scope that ends keeps its last reading in the sum.
        removed(&mut link, second);
        drain(&mut w, &mut link, &sink);
        assert_eq!(sink.runs().cpu_nsec(UNIT), Some(10 + 200 + 1_000));
        assert_eq!(sink.runs().scope_of(UNIT).as_deref(), Some(SCOPE));
        assert_eq!(link.spawns, 0);
    }

    #[test]
    fn one_connection_follows_adopted_units_and_scopes_and_closes_when_nothing_is_left() {
        let mut link = connected_link();
        link.mgr.set(unit_show(1000, None));
        link.mgr.set(scope_show(SCOPE, 1001, None));
        let sink = Recorder::default();
        // A unit adopted after a restart (no scope of its app runs), and a launched run.
        sink.runs().begin(A, USER, "org.ruyaos.Racer", link.now());
        sink.runs().begin(UNIT, USER, APP, link.now());
        let mut w = adopted(&[A]);
        step(&mut w, &mut link, &sink);
        assert_eq!(sink.runs().scope_of(UNIT).as_deref(), Some(SCOPE));
        link.wakes
            .push_back(changed(A, Some("inactive"), Some(0), Some(1)));
        assert_eq!(drain(&mut w, &mut link, &sink), [exited(A, 0, false)]);
        assert!(deliver(&sink, run_exited(0), link.now()));
        removed(&mut link, SCOPE);
        assert_eq!(drain(&mut w, &mut link, &sink), [run_exited(0)]);
        assert_eq!(link.connects, 1, "one connection for both");
        assert!(
            !w.step(&mut link, &sink),
            "nothing left: the caller drops the connection"
        );
    }

    #[test]
    fn a_relaunch_never_attaches_a_scope_left_by_the_run_before() {
        // T-435: an Electron app's zygote scope outlives the scope the run followed; the end of
        // the run sweeps it, and its UnitRemoved comes when nothing follows the app any more.
        const ZYGOTE: &str = "app-flatpak-net.supertuxkart.SuperTuxKart-17.scope";
        let (mut w, mut link, sink) = launched(vec![
            unit_show(1000, None),
            scope_show(SCOPE, 1000, None),
            scope_show(ZYGOTE, 1001, None),
        ]);
        assert_eq!(sink.runs().scope_of(UNIT).as_deref(), Some(SCOPE));
        assert!(deliver(&sink, run_exited(0), link.now()));
        removed(&mut link, SCOPE);
        assert_eq!(drain(&mut w, &mut link, &sink), [run_exited(0)]);
        // The relaunch: its unit's first signal, before any scope of its own exists.
        sink.runs().begin(UNIT, USER, APP, link.now());
        link.wakes.push_back(Wake::Event(ManagerEvent::Changed {
            unit: UNIT.to_owned(),
            change: UnitChange {
                active_state: Some("activating".to_owned()),
                ..UnitChange::default()
            },
        }));
        drain(&mut w, &mut link, &sink);
        assert_eq!(
            sink.runs().scope_of(UNIT),
            None,
            "the old zygote is not the new run's"
        );
    }

    #[test]
    fn a_new_scope_is_read_at_its_unit_new_so_a_change_without_its_timestamp_still_attaches() {
        let (mut w, mut link, sink) = launched(vec![unit_show(1000, None)]);
        // The scope's UnitNew, and a change that names its state only: what the read over the
        // bus said of it (when it became active) is what places it after the unit.
        link.mgr.set(scope_show(SCOPE, 1001, None));
        link.wakes.push_back(Wake::Event(ManagerEvent::New {
            unit: SCOPE.to_owned(),
        }));
        link.wakes.push_back(Wake::Event(ManagerEvent::Changed {
            unit: SCOPE.to_owned(),
            change: UnitChange {
                active_state: Some("active".to_owned()),
                ..UnitChange::default()
            },
        }));
        drain(&mut w, &mut link, &sink);
        assert_eq!(sink.runs().scope_of(UNIT).as_deref(), Some(SCOPE));
        assert_eq!((link.lists, link.spawns), (2, 0));
    }
}
