//! `org.ruyaos.Platform1.Lifecycle`, the first capability (lead-44, ADR-022): an app instance
//! `Register`s, and from then on the OS's lifecycle events for it (`NotifyLifecycle`, from
//! ruya-session) reach its registered connections alone: `Background`, `Resume(frozen_ms)`,
//! `Stopping(deadline_ms)`, answered by `SaveDone`. There is no notice before a freeze: the freeze
//! is instant and a frozen app could not act on it. Pure: the adapter sends each signal to the
//! names this returns and awaits the [`Wait`] of a Stopping.
//!
//! A Stopping is answered to the OS, not broadcast: `NotifyLifecycle(.., "stopping", ..)` replies
//! `saved` when the instance calls `SaveDone`, `timeout` when the deadline passed first, and
//! `not-registered` at once when nothing is registered, or when the registration ends while it
//! waits (the last connection left, the profile was removed, the player turned it off). A second
//! Stopping while one waits joins it: same deadline, same answer, no second signal.

use std::any::Any;
use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

use async_channel::{Receiver, Sender};
use ruya_ids::valid_profile_id;

use crate::door::{arg, Gate, Platform};
use crate::identity::{Caller, Identity};
use crate::limits::{MAX_EVENT, MAX_PROFILE_ID, MAX_SCOPE};
use crate::registry::Handler;
use crate::Status;

pub const INTERFACE: &str = "org.ruyaos.Platform1.Lifecycle";
pub const KEY: &str = "lifecycle";
/// The most connections one instance may register (a proxy per instance makes one or two).
pub const MAX_NAMES: usize = 8;
/// The longest deadline a Stopping may carry (RUY-1099): a `NotifyLifecycle("stopping")` blocks
/// until it settles, so an unbounded `value_ms` would hold its caller's call open without end.
/// ruya-session sends 5 000.
pub const MAX_STOPPING_MS: u64 = 60_000;

/// An event `NotifyLifecycle` carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    Background,
    Resume { frozen_ms: u64 },
    Stopping { deadline_ms: u32 },
}

impl Event {
    /// `NotifyLifecycle`'s `event` and `value_ms`, or `InvalidArgument`.
    pub fn parse(event: &str, value_ms: u64) -> Result<Event, Status> {
        match event {
            "background" if value_ms == 0 => Ok(Event::Background),
            "resume" => Ok(Event::Resume {
                frozen_ms: value_ms,
            }),
            "stopping" if value_ms <= MAX_STOPPING_MS => u32::try_from(value_ms)
                .map(|deadline_ms| Event::Stopping { deadline_ms })
                .map_err(|_| Status::InvalidArgument),
            _ => Err(Status::InvalidArgument),
        }
    }
}

/// The answer a `NotifyLifecycle` "stopping" waits for: `saved`, `timeout` or `not-registered`
/// arrives on `answer`; at `deadline` the adapter calls [`Lifecycle::expire`] and reads it again.
#[derive(Debug)]
pub struct Wait {
    pub answer: Receiver<Status>,
    pub deadline: Instant,
}

impl Wait {
    /// The answer once the deadline passed and [`Lifecycle::expire`] ran: what was sent, else
    /// `not-registered` (the waiter was dropped unanswered, which no path does).
    pub fn settled(&self) -> Status {
        self.answer.try_recv().unwrap_or(Status::NotRegistered)
    }
}

/// The waiters of one pending Stopping.
#[derive(Debug)]
struct Pending {
    deadline: Instant,
    waiters: Vec<Sender<Status>>,
}

impl Pending {
    fn answer(self, status: Status) {
        for w in self.waiters {
            // A waiter whose caller went away is simply gone.
            let _ = w.try_send(status);
        }
    }
}

/// An instance's registration: (profile, scope) is its key, the scope being unique in the
/// profile's user manager.
#[derive(Debug, Default)]
struct Instance {
    app_id: String,
    names: BTreeSet<String>,
    /// A Stopping was sent and no SaveDone came yet (also after its wait timed out: a late
    /// SaveDone is `ok` and changes nothing).
    stopping: bool,
    pending: Option<Pending>,
}

impl Instance {
    /// The registration ends: a waiting Stopping is answered `not-registered`.
    fn end(self) {
        if let Some(p) = self.pending {
            p.answer(Status::NotRegistered);
        }
    }
}

/// What `notify` asks the adapter to do: send the signal to `names` (empty when a Stopping joined
/// one already sent), and, for a Stopping, await `wait`.
#[derive(Debug)]
pub struct Notice {
    pub event: Event,
    pub names: Vec<String>,
    pub wait: Option<Wait>,
}

#[derive(Debug, Default)]
pub struct Lifecycle {
    instances: BTreeMap<(String, String), Instance>,
}

fn key(id: &Identity) -> (String, String) {
    (id.profile.clone(), id.scope.clone())
}

fn waiter(pending: &mut Pending) -> Wait {
    let (tx, rx) = async_channel::bounded(1);
    pending.waiters.push(tx);
    Wait {
        answer: rx,
        deadline: pending.deadline,
    }
}

impl Lifecycle {
    /// The connection `name` of the instance `id` registers (the door admitted it).
    pub fn register(&mut self, id: &Identity, name: &str) -> Status {
        let instance = self.instances.entry(key(id)).or_insert_with(|| Instance {
            app_id: id.app_id.clone(),
            ..Instance::default()
        });
        if !instance.names.contains(name) && instance.names.len() >= MAX_NAMES {
            return Status::RateLimited;
        }
        instance.names.insert(name.to_owned());
        Status::Ok
    }

    /// The OS's event for the instance `scope` of `profile`: the names to send its signal to
    /// (that instance's registered connections, nobody else's) and, for a Stopping, the wait for
    /// its answer; `NotRegistered` when nothing is registered.
    pub fn notify(
        &mut self,
        profile: &str,
        scope: &str,
        event: Event,
        now: Instant,
    ) -> Result<Notice, Status> {
        let Some(instance) = self
            .instances
            .get_mut(&(profile.to_owned(), scope.to_owned()))
        else {
            return Err(Status::NotRegistered);
        };
        let names: Vec<String> = instance.names.iter().cloned().collect();
        let Event::Stopping { deadline_ms } = event else {
            return Ok(Notice {
                event,
                names,
                wait: None,
            });
        };
        instance.stopping = true;
        if let Some(pending) = instance.pending.as_mut() {
            return Ok(Notice {
                event,
                names: Vec::new(),
                wait: Some(waiter(pending)),
            });
        }
        let pending = instance.pending.insert(Pending {
            deadline: now + Duration::from_millis(u64::from(deadline_ms)),
            waiters: Vec::new(),
        });
        Ok(Notice {
            event,
            names,
            wait: Some(waiter(pending)),
        })
    }

    /// The instance `id` has saved after a Stopping: a waiting Stopping is answered `saved`. After
    /// the wait timed out it is `ok` and changes nothing more.
    pub fn save_done(&mut self, id: &Identity) -> Status {
        let Some(instance) = self.instances.get_mut(&key(id)) else {
            return Status::NotRegistered;
        };
        if !instance.stopping {
            return Status::NotAllowed;
        }
        instance.stopping = false;
        if let Some(p) = instance.pending.take() {
            p.answer(Status::Saved);
        }
        Status::Ok
    }

    /// The deadline of the instance's waiting Stopping has come (`now` at or after it): its
    /// waiters are answered `timeout`. Before the deadline, or with nothing waiting, nothing.
    pub fn expire(&mut self, profile: &str, scope: &str, now: Instant) {
        let Some(instance) = self
            .instances
            .get_mut(&(profile.to_owned(), scope.to_owned()))
        else {
            return;
        };
        if instance.pending.as_ref().is_some_and(|p| p.deadline <= now) {
            if let Some(p) = instance.pending.take() {
                p.answer(Status::Timeout);
            }
        }
    }

    /// The registered names of the instance (for the tests and the log).
    pub fn names(&self, profile: &str, scope: &str) -> Vec<String> {
        self.instances
            .get(&(profile.to_owned(), scope.to_owned()))
            .map(|i| i.names.iter().cloned().collect())
            .unwrap_or_default()
    }

    /// Ends every registration `gone` says, answering its waiting Stopping.
    fn end_where(&mut self, mut gone: impl FnMut(&(String, String), &mut Instance) -> bool) {
        let keys: Vec<(String, String)> = self
            .instances
            .iter_mut()
            .filter_map(|(k, i)| gone(k, i).then(|| k.clone()))
            .collect();
        for k in keys {
            if let Some(i) = self.instances.remove(&k) {
                i.end();
            }
        }
    }
}

impl Handler for Lifecycle {
    /// An instance whose last registered connection left ends (a waiting Stopping is answered
    /// `not-registered`); one with another connection left keeps waiting for its SaveDone.
    fn name_gone(&mut self, name: &str) {
        self.end_where(|_, i| {
            i.names.remove(name);
            i.names.is_empty()
        });
    }

    fn profile_gone(&mut self, profile: &str) {
        self.end_where(|(p, _), _| p == profile);
    }

    fn withdrawn(&mut self, profile: &str, app_id: &str) {
        self.end_where(|(p, _), i| p == profile && i.app_id == app_id);
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}

fn handler(door: &mut Platform) -> Result<&mut Lifecycle, Status> {
    door.registry_mut()
        .handler_mut::<Lifecycle>(INTERFACE)
        .ok_or(Status::Failed)
}

/// `Lifecycle.Register` from `caller`: the active profile's apps only, with the capability on.
pub fn register(door: &mut Platform, caller: &Caller<'_>, now: Instant) -> Status {
    match door.admit(caller, INTERFACE, Gate::ActiveProfile, now) {
        Ok(id) => match handler(door) {
            Ok(l) => l.register(&id, caller.name),
            Err(status) => status,
        },
        Err(status) => status,
    }
}

/// `Lifecycle.SaveDone` from `caller`. Any profile's app may answer its Stopping (power-off stops
/// every profile's apps).
pub fn save_done(door: &mut Platform, caller: &Caller<'_>, now: Instant) -> Status {
    match door.admit(caller, INTERFACE, Gate::AnyProfile, now) {
        Ok(id) => match handler(door) {
            Ok(l) => l.save_done(&id),
            Err(status) => status,
        },
        Err(status) => status,
    }
}

/// `Manage.NotifyLifecycle` (the adapter checked the caller is root): what to send and, for a
/// Stopping, what to wait for.
pub fn notify(
    door: &mut Platform,
    profile: &str,
    scope: &str,
    event: &str,
    value_ms: u64,
    now: Instant,
) -> Result<Notice, Status> {
    let profile = arg(profile, MAX_PROFILE_ID)?;
    let scope = arg(scope, MAX_SCOPE)?;
    let event = Event::parse(arg(event, MAX_EVENT)?, value_ms)?;
    let scope_form = scope.starts_with("app-flatpak-") && scope.ends_with(".scope");
    if !valid_profile_id(profile) || !scope_form {
        return Err(Status::InvalidArgument);
    }
    handler(door)?.notify(profile, scope, event, now)
}

/// `Lifecycle::expire` through the door, for the adapter when a wait's deadline came.
pub fn expire(door: &mut Platform, profile: &str, scope: &str, now: Instant) {
    if let Ok(l) = handler(door) {
        l.expire(profile, scope, now);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(profile: &str, app: &str, instance: &str) -> Identity {
        Identity {
            app_id: app.into(),
            instance_id: instance.into(),
            scope: ruya_flatpak::scope::instance_scope(app, instance).expect("valid"),
            uid: 1001,
            profile: profile.into(),
        }
    }

    const A: &str = "org.example.Racer";
    const B: &str = "org.example.Chess";
    const STOP: Event = Event::Stopping { deadline_ms: 5000 };

    /// The names a non-Stopping event goes to.
    fn sent(l: &mut Lifecycle, i: &Identity, event: Event) -> Result<Vec<String>, Status> {
        l.notify(&i.profile, &i.scope, event, Instant::now())
            .map(|n| n.names)
    }

    /// A Stopping at `now`: its names and its wait.
    fn stop(l: &mut Lifecycle, i: &Identity, now: Instant) -> (Vec<String>, Wait) {
        let n = l
            .notify(&i.profile, &i.scope, STOP, now)
            .expect("registered");
        (n.names, n.wait.expect("a Stopping waits"))
    }

    /// A of p1 (connections :1.10 and :1.11), B of p1 (:1.20) and A of p2 (:1.30), registered.
    fn three_instances() -> (Lifecycle, Identity, Identity, Identity) {
        let mut l = Lifecycle::default();
        let a = id("p1", A, "1");
        let b = id("p1", B, "2");
        let c = id("p2", A, "1");
        l.register(&a, ":1.10");
        l.register(&a, ":1.11");
        l.register(&b, ":1.20");
        l.register(&c, ":1.30");
        (l, a, b, c)
    }

    fn pending(w: &Wait) -> bool {
        w.answer.is_empty() && !w.answer.is_closed()
    }

    #[test]
    fn events_from_the_session() {
        assert_eq!(Event::parse("background", 0), Ok(Event::Background));
        assert_eq!(Event::parse("background", 5), Err(Status::InvalidArgument));
        assert_eq!(
            Event::parse("resume", 0),
            Ok(Event::Resume { frozen_ms: 0 })
        );
        assert_eq!(
            Event::parse("resume", u64::MAX),
            Ok(Event::Resume {
                frozen_ms: u64::MAX
            })
        );
        assert_eq!(Event::parse("stopping", 5000), Ok(STOP));
        assert_eq!(
            Event::parse("stopping", MAX_STOPPING_MS),
            Ok(Event::Stopping {
                deadline_ms: 60_000
            })
        );
        // RUY-1099: a Stopping holds its caller's call open, so its deadline is capped.
        for over in [MAX_STOPPING_MS + 1, u64::from(u32::MAX) + 1] {
            assert_eq!(
                Event::parse("stopping", over),
                Err(Status::InvalidArgument),
                "{over}"
            );
        }
        for bad in ["", "Stopping", "suspend", "freeze"] {
            assert_eq!(Event::parse(bad, 0), Err(Status::InvalidArgument), "{bad}");
        }
    }

    #[test]
    fn signals_go_to_the_instances_own_names_only() {
        let mut l = Lifecycle::default();
        let a = id("p1", A, "1");
        let a2 = id("p1", A, "2");
        let b = id("p1", B, "3");
        let other_profile = id("p2", A, "1");
        assert_eq!(l.register(&a, ":1.10"), Status::Ok);
        assert_eq!(l.register(&a, ":1.11"), Status::Ok);
        assert_eq!(l.register(&a2, ":1.20"), Status::Ok);
        assert_eq!(l.register(&b, ":1.30"), Status::Ok);
        assert_eq!(l.register(&other_profile, ":1.40"), Status::Ok);
        assert_eq!(
            sent(&mut l, &a, Event::Background),
            Ok(vec![":1.10".to_owned(), ":1.11".to_owned()])
        );
        assert_eq!(
            sent(&mut l, &b, Event::Resume { frozen_ms: 9 }),
            Ok(vec![":1.30".to_owned()])
        );
        assert_eq!(
            sent(&mut l, &other_profile, Event::Background),
            Ok(vec![":1.40".to_owned()]),
            "the same scope name in another profile"
        );
        assert_eq!(
            sent(&mut l, &id("p3", A, "1"), Event::Background),
            Err(Status::NotRegistered)
        );
        let (names, _) = stop(&mut l, &a, Instant::now());
        assert_eq!(names, [":1.10", ":1.11"]);
    }

    #[test]
    fn registering_twice_is_one_registration() {
        let mut l = Lifecycle::default();
        let a = id("p1", A, "1");
        assert_eq!(l.register(&a, ":1.10"), Status::Ok);
        assert_eq!(l.register(&a, ":1.10"), Status::Ok);
        assert_eq!(l.names("p1", &a.scope), [":1.10"]);
    }

    #[test]
    fn an_instance_has_at_most_eight_names() {
        let mut l = Lifecycle::default();
        let a = id("p1", A, "1");
        for n in 0..MAX_NAMES {
            assert_eq!(l.register(&a, &format!(":1.{n}")), Status::Ok);
        }
        assert_eq!(l.register(&a, ":1.99"), Status::RateLimited);
        assert_eq!(l.register(&a, ":1.0"), Status::Ok, "a name it has already");
        assert_eq!(l.names("p1", &a.scope).len(), MAX_NAMES);
    }

    #[test]
    fn other_events_wait_for_nothing() {
        let mut l = Lifecycle::default();
        let a = id("p1", A, "1");
        l.register(&a, ":1.10");
        for event in [Event::Background, Event::Resume { frozen_ms: 3 }] {
            let n = l
                .notify("p1", &a.scope, event, Instant::now())
                .expect("registered");
            assert!(n.wait.is_none(), "{event:?}");
        }
    }

    #[test]
    fn a_stopping_is_answered_saved_by_save_done() {
        let mut l = Lifecycle::default();
        let a = id("p1", A, "1");
        l.register(&a, ":1.10");
        assert_eq!(l.save_done(&a), Status::NotAllowed, "no Stopping yet");
        let (_, wait) = stop(&mut l, &a, Instant::now());
        assert!(pending(&wait));
        assert_eq!(l.save_done(&a), Status::Ok);
        assert_eq!(wait.answer.try_recv(), Ok(Status::Saved));
        assert_eq!(l.save_done(&a), Status::NotAllowed, "once per Stopping");
    }

    #[test]
    fn a_stopping_times_out_at_its_deadline_and_a_late_save_done_is_ignored() {
        let mut l = Lifecycle::default();
        let a = id("p1", A, "1");
        l.register(&a, ":1.10");
        let t0 = Instant::now();
        let (_, wait) = stop(&mut l, &a, t0);
        assert_eq!(wait.deadline, t0 + Duration::from_millis(5000));
        l.expire("p1", &a.scope, t0 + Duration::from_millis(4999));
        assert!(pending(&wait), "not before the deadline");
        l.expire("p1", &a.scope, wait.deadline);
        assert_eq!(wait.settled(), Status::Timeout);
        assert_eq!(l.save_done(&a), Status::Ok, "late: ok, and nobody waits");
        assert_eq!(l.save_done(&a), Status::NotAllowed);
        // A new Stopping waits again.
        let (_, again) = stop(&mut l, &a, wait.deadline);
        assert!(pending(&again));
    }

    #[test]
    fn a_second_stopping_joins_the_waiting_one() {
        let mut l = Lifecycle::default();
        let a = id("p1", A, "1");
        l.register(&a, ":1.10");
        let t0 = Instant::now();
        let (_, first) = stop(&mut l, &a, t0);
        let (names, second) = stop(&mut l, &a, t0 + Duration::from_secs(3));
        assert!(names.is_empty(), "no second signal");
        assert_eq!(second.deadline, first.deadline, "the same deadline");
        assert_eq!(l.save_done(&a), Status::Ok);
        assert_eq!(first.answer.try_recv(), Ok(Status::Saved));
        assert_eq!(
            second.answer.try_recv(),
            Ok(Status::Saved),
            "the same answer"
        );
    }

    #[test]
    fn app_a_cannot_save_done_for_b() {
        let mut l = Lifecycle::default();
        let a = id("p1", A, "1");
        let b = id("p1", B, "2");
        l.register(&a, ":1.10");
        l.register(&b, ":1.20");
        let (_, a_wait) = stop(&mut l, &a, Instant::now());
        assert_eq!(l.save_done(&b), Status::NotAllowed, "B is not stopping");
        assert!(pending(&a_wait), "B's SaveDone does not complete A's wait");
        // Another instance of A is another instance.
        assert_eq!(l.save_done(&id("p1", A, "9")), Status::NotRegistered);
        assert!(pending(&a_wait));
        assert_eq!(l.save_done(&a), Status::Ok);
        assert_eq!(a_wait.answer.try_recv(), Ok(Status::Saved));
    }

    #[test]
    fn a_wait_ends_not_registered_with_its_registration() {
        let (mut l, a, b, c) = three_instances();
        let now = Instant::now();
        let (_, wa) = stop(&mut l, &a, now);
        let (_, wb) = stop(&mut l, &b, now);
        let (_, wc) = stop(&mut l, &c, now);
        l.name_gone(":1.10");
        assert!(pending(&wa), "another connection of A is still there");
        l.name_gone(":1.11");
        assert_eq!(
            wa.answer.try_recv(),
            Ok(Status::NotRegistered),
            "its last name left"
        );
        l.withdrawn("p1", B);
        assert_eq!(
            wb.answer.try_recv(),
            Ok(Status::NotRegistered),
            "turned off"
        );
        l.profile_gone("p2");
        assert_eq!(
            wc.answer.try_recv(),
            Ok(Status::NotRegistered),
            "profile removed"
        );
    }

    #[test]
    fn what_is_forgotten() {
        let (mut l, a, b, c) = three_instances();
        l.name_gone(":1.10");
        assert_eq!(l.names("p1", &a.scope), [":1.11"]);
        l.name_gone(":1.11");
        assert_eq!(
            sent(&mut l, &a, Event::Background),
            Err(Status::NotRegistered),
            "its last name left"
        );
        l.withdrawn("p1", B);
        assert_eq!(
            sent(&mut l, &b, Event::Background),
            Err(Status::NotRegistered),
            "the player turned it off"
        );
        assert_eq!(l.names("p2", &c.scope), [":1.30"]);
        l.profile_gone("p2");
        assert_eq!(
            sent(&mut l, &c, Event::Background),
            Err(Status::NotRegistered)
        );
    }

    mod through_the_door {
        use super::super::{notify, register, save_done, Event};
        use crate::door::tests::{known, App, Fixture, World, APP, OTHER};
        use crate::Status;
        use ruya_flatpak::scope::instance_scope;

        /// APP instance 7 of p1, registered: the door, the caller and its scope.
        fn registered_app() -> (Fixture, App, String) {
            let mut w = World::new();
            let a = w.app(1, APP, "7");
            let mut f = w.door();
            assert_eq!(register(&mut f.door, &a.caller(), f.now), Status::Ok);
            (f, a, instance_scope(APP, "7").expect("valid"))
        }

        #[test]
        fn register_needs_the_capability() {
            let mut w = World::new();
            let a = w.app(1, APP, "7");
            let mut f = w.door();
            let (door, now) = (&mut f.door, f.now);
            assert_eq!(
                door.set_permission("p1", APP, "lifecycle", false),
                Status::Ok
            );
            assert_eq!(register(door, &a.caller(), now), Status::NotAllowed);
            assert_eq!(
                door.set_permission("p1", APP, "lifecycle", true),
                Status::Ok
            );
            assert_eq!(register(door, &a.caller(), now), Status::Ok);
        }

        #[test]
        fn turning_it_off_ends_the_registration_and_its_wait() {
            let (mut f, _a, scope) = registered_app();
            let (door, now) = (&mut f.door, f.now);
            let n = notify(door, "p1", &scope, "stopping", 5000, now).expect("registered");
            let wait = n.wait.expect("waits");
            assert_eq!(
                door.set_permission("p1", APP, "lifecycle", false),
                Status::Ok
            );
            assert_eq!(wait.answer.try_recv(), Ok(Status::NotRegistered));
            assert_eq!(
                notify(door, "p1", &scope, "background", 0, now).map(|n| n.names),
                Err(Status::NotRegistered)
            );
        }

        #[test]
        fn register_needs_the_active_profile_and_save_done_does_not() {
            let mut w = World::new();
            let a2 = w.app(2, APP, "7");
            let mut f = w.door();
            let (door, now) = (&mut f.door, f.now);
            assert_eq!(
                register(door, &a2.caller(), now),
                Status::NotAllowed,
                "p2 is not signed in"
            );
            door.follow_profiles(known(&["p1", "p2"]), "p2", now);
            assert_eq!(register(door, &a2.caller(), now), Status::Ok);
            door.follow_profiles(known(&["p1", "p2"]), "p1", now);
            let scope = instance_scope(APP, "7").expect("valid");
            let n = notify(door, "p2", &scope, "stopping", 5000, now).expect("registered");
            assert_eq!(
                (n.event, n.names),
                (Event::Stopping { deadline_ms: 5000 }, vec![a2.name.clone()])
            );
            assert_eq!(
                save_done(door, &a2.caller(), now),
                Status::Ok,
                "power-off reaches every profile's apps"
            );
            assert_eq!(n.wait.expect("waits").answer.try_recv(), Ok(Status::Saved));
        }

        #[test]
        fn app_a_cannot_register_or_save_done_as_b() {
            let mut w = World::new();
            let a = w.app(1, APP, "7");
            let b = w.app(1, OTHER, "8");
            let mut f = w.door();
            let (door, now) = (&mut f.door, f.now);
            assert_eq!(register(door, &a.caller(), now), Status::Ok);
            assert_eq!(register(door, &b.caller(), now), Status::Ok);
            let a_scope = instance_scope(APP, "7").expect("valid");
            let b_scope = instance_scope(OTHER, "8").expect("valid");
            // B's signals reach B's connection alone.
            let n = notify(door, "p1", &b_scope, "stopping", 5000, now).expect("registered");
            assert_eq!(n.names, vec![b.name.clone()]);
            let wait = n.wait.expect("waits");
            assert_eq!(
                save_done(door, &a.caller(), now),
                Status::NotAllowed,
                "A's SaveDone is A's, and A has no Stopping"
            );
            assert!(wait.answer.is_empty(), "B still waits");
            assert_eq!(save_done(door, &b.caller(), now), Status::Ok);
            assert_eq!(wait.answer.try_recv(), Ok(Status::Saved));
            let n = notify(door, "p1", &a_scope, "resume", 1200, now).expect("registered");
            assert_eq!(n.names, vec![a.name.clone()]);
        }

        #[test]
        fn a_stopping_for_nobody_is_answered_at_once() {
            let mut f = World::new().door();
            let (door, now) = (&mut f.door, f.now);
            let scope = instance_scope(APP, "7").expect("valid");
            assert_eq!(
                notify(door, "p1", &scope, "stopping", 5000, now).map(|n| n.names),
                Err(Status::NotRegistered)
            );
        }

        #[test]
        fn a_stranger_cannot_register() {
            let mut w = World::new();
            let a = w.app(1, APP, "7");
            w.procfs.processes.get_mut(&a.pid).expect("set").info =
                Err(crate::identity::FileError::Missing);
            let mut f = w.door();
            let (door, now) = (&mut f.door, f.now);
            assert_eq!(register(door, &a.caller(), now), Status::NotAnApp);
            assert_eq!(save_done(door, &a.caller(), now), Status::NotAnApp);
        }

        #[test]
        fn a_deleted_profiles_registrations_go() {
            let mut w = World::new();
            let a2 = w.app(2, APP, "7");
            let mut f = w.door();
            let (door, now) = (&mut f.door, f.now);
            door.follow_profiles(known(&["p1", "p2"]), "p2", now);
            assert_eq!(register(door, &a2.caller(), now), Status::Ok);
            door.follow_profiles(known(&["p1"]), "p1", now);
            let scope = instance_scope(APP, "7").expect("valid");
            assert_eq!(
                notify(door, "p2", &scope, "background", 0, now).map(|n| n.names),
                Err(Status::NotRegistered)
            );
            assert_eq!(register(door, &a2.caller(), now), Status::NotAnApp);
        }

        #[test]
        fn a_name_gone_before_its_register_is_not_kept() {
            // NameOwnerChanged was handled while the call asked for the credentials; the adapter
            // asks the bus after the call, and the name has no owner.
            let (mut f, a, scope) = registered_app();
            let (door, now) = (&mut f.door, f.now);
            door.forget_if_gone(&a.name, false, now);
            assert_eq!(
                notify(door, "p1", &scope, "background", 0, now).map(|n| n.names),
                Err(Status::NotRegistered)
            );
            assert!(!door.knows(&a.name), "no identity is cached for it");
            // A name still on the bus is kept.
            assert_eq!(register(door, &a.caller(), now), Status::Ok);
            door.forget_if_gone(&a.name, true, now);
            assert!(door.knows(&a.name));
        }

        #[test]
        fn notify_arguments_are_checked() {
            let mut f = World::new().door();
            let (door, now) = (&mut f.door, f.now);
            let scope = "app-flatpak-org.example.Racer-7.scope";
            let long_scope = format!("app-flatpak-{}.scope", "x".repeat(300));
            let long_event = "stopping".repeat(10);
            for (p, s, e) in [
                ("../p1", scope, "background"),
                ("", scope, "background"),
                (
                    "p1",
                    "ruya-app-ruya-p1-org.example.Racer.service",
                    "background",
                ),
                ("p1", "app-flatpak-x\n.scope", "background"),
                ("p1", long_scope.as_str(), "background"),
                ("p1", scope, "freeze"),
                ("p1", scope, long_event.as_str()),
            ] {
                assert_eq!(
                    notify(door, p, s, e, 0, now).map(|n| n.names),
                    Err(Status::InvalidArgument),
                    "{p:?} {s:?} {e:?}"
                );
            }
            assert_eq!(
                notify(door, "p1", scope, "background", 0, now).map(|n| n.names),
                Err(Status::NotRegistered)
            );
        }
    }
}
