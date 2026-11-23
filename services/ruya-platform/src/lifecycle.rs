//! `org.ruyaos.Platform1.Lifecycle`, the first capability (lead-44, ADR-022): an app instance
//! `Register`s, and from then on the OS's lifecycle events for it (`NotifyLifecycle`, from
//! ruya-session) reach its registered connections alone: `Background`, `Resume(frozen_ms)`,
//! `Stopping(deadline_ms)`, answered by `SaveDone`. There is no notice before a freeze: the freeze
//! is instant and a frozen app could not act on it. Pure: the adapter sends each signal to the
//! names this returns.

use std::any::Any;
use std::collections::{BTreeMap, BTreeSet};

use std::time::Instant;

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
            "stopping" => u32::try_from(value_ms)
                .map(|deadline_ms| Event::Stopping { deadline_ms })
                .map_err(|_| Status::InvalidArgument),
            _ => Err(Status::InvalidArgument),
        }
    }
}

/// An instance's registration: (profile, scope) is its key, the scope being unique in the
/// profile's user manager.
#[derive(Debug, Default)]
struct Instance {
    app_id: String,
    names: BTreeSet<String>,
    /// A Stopping was sent and no SaveDone came yet.
    stopping: bool,
}

#[derive(Debug, Default)]
pub struct Lifecycle {
    instances: BTreeMap<(String, String), Instance>,
}

fn key(id: &Identity) -> (String, String) {
    (id.profile.clone(), id.scope.clone())
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
    /// (that instance's registered connections, nobody else's), or `NotRegistered`.
    pub fn notify(
        &mut self,
        profile: &str,
        scope: &str,
        event: Event,
    ) -> Result<Vec<String>, Status> {
        let Some(instance) = self
            .instances
            .get_mut(&(profile.to_owned(), scope.to_owned()))
        else {
            return Err(Status::NotRegistered);
        };
        match event {
            Event::Stopping { .. } => instance.stopping = true,
            // Back in front: a Stopping before it was not carried out.
            Event::Resume { .. } => instance.stopping = false,
            Event::Background => {}
        }
        Ok(instance.names.iter().cloned().collect())
    }

    /// The instance `id` has saved after a Stopping: its (profile, scope) for the `Saved` signal.
    pub fn save_done(&mut self, id: &Identity) -> Result<(String, String), Status> {
        let instance = self
            .instances
            .get_mut(&key(id))
            .ok_or(Status::NotRegistered)?;
        if !instance.stopping {
            return Err(Status::NotAllowed);
        }
        instance.stopping = false;
        Ok(key(id))
    }

    /// The registered names of the instance (for the tests and the log).
    pub fn names(&self, profile: &str, scope: &str) -> Vec<String> {
        self.instances
            .get(&(profile.to_owned(), scope.to_owned()))
            .map(|i| i.names.iter().cloned().collect())
            .unwrap_or_default()
    }
}

impl Handler for Lifecycle {
    fn name_gone(&mut self, name: &str) {
        self.instances.retain(|_, i| {
            i.names.remove(name);
            !i.names.is_empty()
        });
    }

    fn profile_gone(&mut self, profile: &str) {
        self.instances.retain(|(p, _), _| p != profile);
    }

    fn withdrawn(&mut self, profile: &str, app_id: &str) {
        self.instances
            .retain(|(p, _), i| !(p == profile && i.app_id == app_id));
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

/// `Lifecycle.SaveDone` from `caller`: the (profile, scope) for `Manage.Saved`. Any profile's app
/// may answer its Stopping (power-off stops every profile's apps).
pub fn save_done(
    door: &mut Platform,
    caller: &Caller<'_>,
    now: Instant,
) -> Result<(String, String), Status> {
    let id = door.admit(caller, INTERFACE, Gate::AnyProfile, now)?;
    handler(door)?.save_done(&id)
}

/// `Manage.NotifyLifecycle` (the adapter checked the caller is root): the event and the names to
/// send its signal to.
pub fn notify(
    door: &mut Platform,
    profile: &str,
    scope: &str,
    event: &str,
    value_ms: u64,
) -> Result<(Event, Vec<String>), Status> {
    let profile = arg(profile, MAX_PROFILE_ID)?;
    let scope = arg(scope, MAX_SCOPE)?;
    let event = Event::parse(arg(event, MAX_EVENT)?, value_ms)?;
    let scope_form = scope.starts_with("app-flatpak-") && scope.ends_with(".scope");
    if !valid_profile_id(profile) || !scope_form {
        return Err(Status::InvalidArgument);
    }
    let names = handler(door)?.notify(profile, scope, event)?;
    Ok((event, names))
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
        assert_eq!(
            Event::parse("stopping", 5000),
            Ok(Event::Stopping { deadline_ms: 5000 })
        );
        assert_eq!(
            Event::parse("stopping", u64::from(u32::MAX) + 1),
            Err(Status::InvalidArgument)
        );
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
            l.notify("p1", &a.scope, Event::Background),
            Ok(vec![":1.10".to_owned(), ":1.11".to_owned()])
        );
        assert_eq!(
            l.notify("p1", &b.scope, Event::Resume { frozen_ms: 9 }),
            Ok(vec![":1.30".to_owned()])
        );
        assert_eq!(
            l.notify("p2", &a.scope, Event::Background),
            Ok(vec![":1.40".to_owned()]),
            "the same scope name in another profile"
        );
        assert_eq!(
            l.notify("p3", &a.scope, Event::Background),
            Err(Status::NotRegistered)
        );
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
    fn save_done_answers_a_stopping_once() {
        let mut l = Lifecycle::default();
        let a = id("p1", A, "1");
        assert_eq!(l.save_done(&a), Err(Status::NotRegistered));
        l.register(&a, ":1.10");
        assert_eq!(l.save_done(&a), Err(Status::NotAllowed), "no Stopping yet");
        l.notify("p1", &a.scope, Event::Stopping { deadline_ms: 5000 })
            .expect("registered");
        assert_eq!(l.save_done(&a), Ok(("p1".to_owned(), a.scope.clone())));
        assert_eq!(
            l.save_done(&a),
            Err(Status::NotAllowed),
            "once per Stopping"
        );
        l.notify("p1", &a.scope, Event::Stopping { deadline_ms: 5000 })
            .expect("registered");
        l.notify("p1", &a.scope, Event::Resume { frozen_ms: 0 })
            .expect("registered");
        assert_eq!(
            l.save_done(&a),
            Err(Status::NotAllowed),
            "a Resume ends the Stopping"
        );
    }

    #[test]
    fn app_a_cannot_save_done_for_b() {
        let mut l = Lifecycle::default();
        let a = id("p1", A, "1");
        let b = id("p1", B, "2");
        l.register(&a, ":1.10");
        l.register(&b, ":1.20");
        l.notify("p1", &b.scope, Event::Stopping { deadline_ms: 5000 })
            .expect("registered");
        assert_eq!(
            l.save_done(&a),
            Err(Status::NotAllowed),
            "A is not stopping"
        );
        // Another instance of B is another instance.
        assert_eq!(l.save_done(&id("p1", B, "9")), Err(Status::NotRegistered));
        assert_eq!(
            l.save_done(&b),
            Ok(("p1".to_owned(), b.scope.clone())),
            "B's Stopping was untouched"
        );
    }

    #[test]
    fn what_is_forgotten() {
        let mut l = Lifecycle::default();
        let a = id("p1", A, "1");
        let b = id("p1", B, "2");
        let c = id("p2", A, "1");
        l.register(&a, ":1.10");
        l.register(&a, ":1.11");
        l.register(&b, ":1.20");
        l.register(&c, ":1.30");
        l.name_gone(":1.10");
        assert_eq!(l.names("p1", &a.scope), [":1.11"]);
        l.name_gone(":1.11");
        assert_eq!(
            l.notify("p1", &a.scope, Event::Background),
            Err(Status::NotRegistered),
            "its last name left"
        );
        l.withdrawn("p1", B);
        assert_eq!(
            l.notify("p1", &b.scope, Event::Background),
            Err(Status::NotRegistered),
            "the player turned it off"
        );
        assert_eq!(l.names("p2", &c.scope), [":1.30"]);
        l.profile_gone("p2");
        assert_eq!(
            l.notify("p2", &c.scope, Event::Background),
            Err(Status::NotRegistered)
        );
    }

    mod through_the_door {
        use super::super::{notify, register, save_done, Event};
        use crate::door::tests::{known, World, APP, OTHER};
        use crate::Status;
        use ruya_flatpak::scope::instance_scope;

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
        fn turning_it_off_ends_the_registration() {
            let mut w = World::new();
            let a = w.app(1, APP, "7");
            let mut f = w.door();
            let (door, now) = (&mut f.door, f.now);
            assert_eq!(register(door, &a.caller(), now), Status::Ok);
            let scope = instance_scope(APP, "7").expect("valid");
            assert!(notify(door, "p1", &scope, "background", 0).is_ok());
            assert_eq!(
                door.set_permission("p1", APP, "lifecycle", false),
                Status::Ok
            );
            assert_eq!(
                notify(door, "p1", &scope, "background", 0),
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
            let sent = notify(door, "p2", &scope, "stopping", 5000).expect("registered");
            assert_eq!(
                sent,
                (Event::Stopping { deadline_ms: 5000 }, vec![a2.name.clone()])
            );
            assert_eq!(
                save_done(door, &a2.caller(), now),
                Ok(("p2".to_owned(), scope)),
                "power-off reaches every profile's apps"
            );
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
            let (_, names) = notify(door, "p1", &b_scope, "stopping", 5000).expect("registered");
            assert_eq!(names, vec![b.name.clone()]);
            assert_eq!(
                save_done(door, &a.caller(), now),
                Err(Status::NotAllowed),
                "A's SaveDone is A's, and A has no Stopping"
            );
            assert_eq!(
                save_done(door, &b.caller(), now),
                Ok(("p1".to_owned(), b_scope))
            );
            let (_, names) = notify(door, "p1", &a_scope, "resume", 1200).expect("registered");
            assert_eq!(names, vec![a.name.clone()]);
        }

        #[test]
        fn a_stranger_cannot_register() {
            let mut w = World::new();
            let a = w.app(1, APP, "7");
            w.procfs
                .processes
                .get_mut(&a.pid)
                .expect("set")
                .flatpak_info = None;
            let mut f = w.door();
            let (door, now) = (&mut f.door, f.now);
            assert_eq!(register(door, &a.caller(), now), Status::NotAnApp);
            assert_eq!(save_done(door, &a.caller(), now), Err(Status::NotAnApp));
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
                notify(door, "p2", &scope, "background", 0),
                Err(Status::NotRegistered)
            );
            assert_eq!(register(door, &a2.caller(), now), Status::NotAnApp);
        }

        #[test]
        fn notify_arguments_are_checked() {
            let mut f = World::new().door();
            let door = &mut f.door;
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
                    notify(door, p, s, e, 0),
                    Err(Status::InvalidArgument),
                    "{p:?} {s:?} {e:?}"
                );
            }
            assert_eq!(
                notify(door, "p1", scope, "background", 0),
                Err(Status::NotRegistered)
            );
        }
    }
}
