//! Following the app units that were already running when the service started (T-290, T-340).
//!
//! One `Follower` per profile user's manager. It listens to the manager's signals on one
//! long-lived connection (`ManagerLink::wait`): `PropertiesChanged` of a unit (`ActiveState`,
//! `ExecMainStatus`, `ExecMainCode`) and `UnitRemoved`, which keep the real exit status that a
//! `--collect`ed unit takes with it. No process is started while the connection lives. When the
//! connection is lost the follower falls back to looking at each unit every two seconds
//! (`ManagerLink::probe`), tries to connect again each round, and looks at every unit once when
//! it has.
//!
//! A unit is never given up on a failed look: after `WATCH_MAX_MISSES` of them in a row the
//! manager is asked whether the unit still exists (`ManagerLink::exists`), and only a "no" ends
//! the watch. The OS is behind `ManagerLink` (`systemd.rs`), so all of this runs on every host
//! against a fake manager.

use std::time::Duration;

use zbus::message::{Message, Type};

use crate::spawner::{ShowUnit, UnitChange, UnitEvent, UnitWatch};

/// How often a unit is looked at while the connection is down.
pub const WATCH_POLL: Duration = Duration::from_secs(2);
/// How long one wait for a signal lasts when nothing arrives (an idle round, no work).
pub const EVENT_WAIT: Duration = Duration::from_secs(30);
/// Consecutive failed looks after which the manager is asked whether the unit still exists.
pub const WATCH_MAX_MISSES: u32 = 5;

/// What the manager's connection delivered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ManagerEvent {
    Changed { unit: String, change: UnitChange },
    Removed { unit: String },
}

/// The outcome of waiting for the manager.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Wake {
    Event(ManagerEvent),
    /// Nothing came within the time.
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

/// The manager of one profile user, as the follower needs it.
pub trait ManagerLink {
    /// Blocks up to `max` for the next event of a unit.
    fn wait(&mut self, max: Duration) -> Wake;
    /// Waits `pause`, then tries to (re)connect and subscribe; true when it worked.
    fn reconnect(&mut self, pause: Duration) -> bool;
    /// Looks at one unit (a bus call when connected, a `systemctl show` otherwise).
    fn probe(&mut self, unit: &str) -> Probe;
    /// Does the unit still exist? `None` when that cannot be told either (then it is kept).
    fn exists(&mut self, unit: &str) -> Option<bool>;
}

struct Watched {
    watch: UnitWatch,
    unit: String,
    misses: u32,
}

pub struct Follower {
    watched: Vec<Watched>,
    /// Is the connection down (or not made yet)?
    polling: bool,
    first: bool,
}

impl Follower {
    pub fn new(units: &[String]) -> Self {
        Follower {
            watched: units
                .iter()
                .map(|u| Watched {
                    watch: UnitWatch::new(u),
                    unit: u.clone(),
                    misses: 0,
                })
                .collect(),
            // The first round connects and looks at every unit once, so that an end between the
            // listing and the subscription is not missed.
            polling: true,
            first: true,
        }
    }

    pub fn is_done(&self) -> bool {
        self.watched.is_empty()
    }

    /// One round: waits for the manager (or sleeps and looks, while it is unreachable) and
    /// returns the units that ended.
    pub fn step(&mut self, link: &mut dyn ManagerLink) -> Vec<UnitEvent> {
        if !self.polling {
            return match link.wait(EVENT_WAIT) {
                Wake::Event(event) => self.on_event(&event).into_iter().collect(),
                Wake::Quiet => Vec::new(),
                Wake::Lost => {
                    eprintln!("ruya-session: lost a user manager, looking at its apps every 2 s");
                    self.polling = true;
                    Vec::new()
                }
            };
        }
        let pause = if std::mem::take(&mut self.first) {
            Duration::ZERO
        } else {
            WATCH_POLL
        };
        let connected = link.reconnect(pause);
        let ended = self.look_at_all(link);
        if connected {
            self.polling = false;
        }
        ended
    }

    fn on_event(&mut self, event: &ManagerEvent) -> Option<UnitEvent> {
        let (unit, ended) = match event {
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

    fn look_at_all(&mut self, link: &mut dyn ManagerLink) -> Vec<UnitEvent> {
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

/// The event a signal from the manager means for the units we follow, or `None` for any other
/// message.
pub fn parse_signal(message: &Message) -> Option<ManagerEvent> {
    let header = message.header();
    if header.message_type() != Type::Signal {
        return None;
    }
    let member = header.member()?.as_str();
    match member {
        "UnitRemoved" => {
            let (unit, _path): (String, zbus::zvariant::OwnedObjectPath) =
                message.body().deserialize().ok()?;
            Some(ManagerEvent::Removed { unit })
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
            let change = UnitChange {
                active_state: changed
                    .get("ActiveState")
                    .and_then(|v| String::try_from(v.clone()).ok()),
                exec_main_status: int("ExecMainStatus"),
                exec_main_code: int("ExecMainCode"),
            };
            Some(ManagerEvent::Changed { unit, change })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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

    /// A manager that says what it is told, with a clock that only moves when the follower
    /// waits, and counts the `systemctl show` processes a real one would have started.
    #[derive(Default)]
    struct FakeLink {
        /// What `wait` returns, in order; `Quiet` when empty (the whole time passes).
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
    }

    impl ManagerLink for FakeLink {
        fn wait(&mut self, max: Duration) -> Wake {
            if !self.connected {
                return Wake::Lost;
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

        fn reconnect(&mut self, pause: Duration) -> bool {
            self.seconds += pause.as_secs();
            self.connected = self.can_connect;
            self.connected
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

    #[test]
    fn adopted_unit_exit_is_seen_without_polling() {
        let mut link = connected_link();
        let mut f = Follower::new(&units(&[A, B]));
        assert!(f.step(&mut link).is_empty(), "the first round connects");
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
            ended.extend(f.step(&mut link));
        }
        assert_eq!(ended, [exited(A, 3, false), exited(B, 0, false)]);
        assert!(f.is_done());
        assert_eq!(link.spawns, 0);
    }

    #[test]
    fn a_signal_kill_keeps_the_signal_number() {
        let mut link = connected_link();
        let mut f = Follower::new(&units(&[A]));
        f.step(&mut link);
        link.wakes.push_back(changed(A, None, Some(9), Some(2)));
        link.wakes.push_back(changed(A, Some("failed"), None, None));
        f.step(&mut link);
        assert_eq!(f.step(&mut link), [exited(A, 9, true)]);
    }

    #[test]
    fn no_process_is_started_while_following_three_units_for_ten_seconds() {
        let mut link = connected_link();
        let mut f = Follower::new(&units(&[A, B, C]));
        while link.seconds < 10 {
            assert!(f.step(&mut link).is_empty());
        }
        assert_eq!(link.spawns, 0, "events, not systemctl show");
        assert!(link.connected && !f.is_done());
    }

    #[test]
    fn a_lost_connection_falls_back_to_polling_and_recovers() {
        let mut link = connected_link();
        let mut f = Follower::new(&units(&[A, B]));
        f.step(&mut link);
        assert_eq!(link.spawns, 0);
        // The connection drops; the manager cannot be reached again for a while.
        link.can_connect = false;
        link.wakes.push_back(Wake::Lost);
        assert!(f.step(&mut link).is_empty());
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
        assert!(f.step(&mut link).is_empty());
        assert_eq!(link.spawns, 2);
        assert_eq!(f.step(&mut link), [exited(A, 0, false)]);
        assert_eq!(link.seconds - t, 4, "two rounds, two seconds each");
        // The manager is back: connect, look once at what is left, then no more processes.
        link.can_connect = true;
        assert!(f.step(&mut link).is_empty());
        let spawned = link.spawns;
        link.wakes
            .push_back(changed(B, Some("inactive"), Some(7), Some(1)));
        assert_eq!(f.step(&mut link), [exited(B, 7, false)]);
        assert_eq!(link.spawns, spawned);
    }

    #[test]
    fn an_adopted_unit_is_kept_when_polls_fail_but_the_unit_exists() {
        let mut link = FakeLink {
            exists: Some(true),
            ..FakeLink::default()
        };
        link.probes
            .insert(A.to_owned(), VecDeque::from([Probe::Unknown]));
        let mut f = Follower::new(&units(&[A]));
        for _ in 0..WATCH_MAX_MISSES * 3 {
            assert!(f.step(&mut link).is_empty());
        }
        assert!(
            !f.is_done(),
            "the unit still exists, so it is still followed"
        );
        assert!(link.exists_asked >= 3);
        // It ends for real later.
        link.probes
            .insert(A.to_owned(), VecDeque::from([Probe::Gone]));
        assert_eq!(f.step(&mut link), [exited(A, 0, false)]);
    }

    #[test]
    fn a_dropped_unit_is_checked_before_it_is_forgotten() {
        let mut link = FakeLink {
            exists: Some(false),
            ..FakeLink::default()
        };
        link.probes
            .insert(A.to_owned(), VecDeque::from([Probe::Unknown]));
        let mut f = Follower::new(&units(&[A]));
        for _ in 0..WATCH_MAX_MISSES - 1 {
            assert!(f.step(&mut link).is_empty());
        }
        assert_eq!(link.exists_asked, 0);
        assert_eq!(f.step(&mut link), [exited(A, 0, false)]);
        assert_eq!(link.exists_asked, 1, "asked once, then forgotten");
        // A manager that cannot tell either keeps the unit.
        let mut link = FakeLink {
            exists: None,
            ..FakeLink::default()
        };
        link.probes
            .insert(A.to_owned(), VecDeque::from([Probe::Unknown]));
        let mut f = Follower::new(&units(&[A]));
        for _ in 0..WATCH_MAX_MISSES * 2 {
            assert!(f.step(&mut link).is_empty());
        }
        assert!(!f.is_done());
    }

    #[test]
    fn events_for_other_units_change_nothing() {
        let mut link = connected_link();
        let mut f = Follower::new(&units(&[A]));
        f.step(&mut link);
        link.wakes
            .push_back(changed(B, Some("inactive"), Some(1), Some(1)));
        link.wakes
            .push_back(Wake::Event(ManagerEvent::Removed { unit: B.to_owned() }));
        assert!(f.step(&mut link).is_empty());
        assert!(f.step(&mut link).is_empty());
        assert!(!f.is_done());
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
}
