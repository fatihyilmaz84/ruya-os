//! The door: every call of a capability's interface passes [`Platform::admit`] (the caller's rate,
//! its identity from the connection, its profile, the player's permission), and the management
//! calls (`Manage`) read and set the permissions. Pure apart from the injected reads
//! (`identity.rs`) and the permission files (`store.rs`); time is passed in.

use std::collections::{BTreeSet, HashMap};
use std::time::Instant;

use ruya_flatpak::valid_app_id;
use ruya_ids::valid_profile_id;

use crate::capabilities::default_allowed;
use crate::identity::{identify, Caller, Identity, Procfs, Users};
use crate::limits::{self, Buckets, CALLER_RATE, MAX_APP_ID, MAX_CAPABILITY, MAX_PROFILE_ID};
use crate::registry::Registry;
use crate::store::Store;
use crate::Status;

/// Which profiles a call is taken from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Gate {
    /// The active (signed-in) profile only: an app of a profile that left is frozen and has no
    /// business asking for anything (api-surface.md: "a profile that is not active").
    ActiveProfile,
    /// Any existing profile: an answer to the OS (SaveDone after a Stopping, which power-off sends
    /// to every profile's apps).
    AnyProfile,
}

/// Who may call `Manage`: root and the shell's user (`shell_uid`, looked up by name; `None` when it
/// could not be found, then root only). The bus policy says the same; this is defence in depth.
pub fn may_manage(uid: u32, shell_uid: Option<u32>) -> bool {
    uid == 0 || shell_uid == Some(uid)
}

/// Who may send lifecycle events (`NotifyLifecycle`, org.ruyaos.Caller "root"): root only.
pub fn may_notify(uid: u32) -> bool {
    uid == 0
}

/// A string argument's size and characters (`limits::text`); `InvalidArgument` otherwise.
pub fn arg(s: &str, max: usize) -> Result<&str, Status> {
    limits::text(s, max).map_err(|_| Status::InvalidArgument)
}

pub struct Platform {
    procfs: Box<dyn Procfs>,
    users: Box<dyn Users>,
    /// The profiles (and guests) Profiles1 lists; `None` until it answered: then nobody is a
    /// profile and nothing is removed.
    profiles: Option<BTreeSet<String>>,
    active: String,
    store: Store,
    /// The identity of each unique name that passed the recipe, until the name leaves the bus.
    names: HashMap<String, Identity>,
    by_name: Buckets<String>,
    /// (profile, scope): one bucket per instance, whatever connections it opens.
    by_instance: Buckets<(String, String)>,
    registry: Registry,
}

impl Platform {
    pub fn new(
        procfs: Box<dyn Procfs>,
        users: Box<dyn Users>,
        store: Store,
        registry: Registry,
    ) -> Platform {
        Platform {
            procfs,
            users,
            profiles: None,
            active: String::new(),
            store,
            names: HashMap::new(),
            by_name: Buckets::new(CALLER_RATE),
            by_instance: Buckets::new(CALLER_RATE),
            registry,
        }
    }

    pub fn registry_mut(&mut self) -> &mut Registry {
        &mut self.registry
    }

    /// The gate of a call of `interface`, in this order: the connection's bucket (before any
    /// read, so a flood costs nothing), the identity (cached per unique name), the instance's
    /// bucket, the profile (`gate`), the player's permission for the interface's capability.
    pub fn admit(
        &mut self,
        caller: &Caller<'_>,
        interface: &str,
        gate: Gate,
        now: Instant,
    ) -> Result<Identity, Status> {
        let Some(key) = self.registry.key_of(interface) else {
            return Err(Status::NotAllowed);
        };
        if !self.by_name.take(&caller.name.to_owned(), now) {
            return Err(Status::RateLimited);
        }
        let id = match self.names.get(caller.name) {
            Some(id) => id.clone(),
            None => {
                let profiles = self.profiles.as_ref();
                let found = identify(&*self.procfs, &*self.users, caller, |p| {
                    profiles.is_some_and(|known| known.contains(p))
                });
                match found {
                    Ok(id) => {
                        self.names.insert(caller.name.to_owned(), id.clone());
                        id
                    }
                    Err(why) => {
                        eprintln!("ruya-platform: {} is not an app: {why:?}", caller.name);
                        return Err(Status::NotAnApp);
                    }
                }
            }
        };
        if !self
            .by_instance
            .take(&(id.profile.clone(), id.scope.clone()), now)
        {
            return Err(Status::RateLimited);
        }
        if gate == Gate::ActiveProfile && id.profile != self.active {
            return Err(Status::NotAllowed);
        }
        if !self.allowed(&id.profile, &id.app_id, key)? {
            return Err(Status::NotAllowed);
        }
        Ok(id)
    }

    /// The player's choice, else the capability's default. A permission file that cannot be read
    /// fails closed (`Failed`).
    pub fn allowed(&self, profile: &str, app_id: &str, key: &str) -> Result<bool, Status> {
        match self.store.choice(profile, app_id, key) {
            Ok(choice) => Ok(choice.unwrap_or_else(|| default_allowed(key))),
            Err(err) => {
                eprintln!("ruya-platform: permissions of {profile} not readable: {err}");
                Err(Status::Failed)
            }
        }
    }

    /// Profiles1 said which profiles exist and which is active. Everything of a profile that is
    /// gone is dropped: its cached identities, the capabilities' state, its permission file (also a
    /// file left of a profile removed while the service was down). The profiles whose file was
    /// removed.
    pub fn follow_profiles(
        &mut self,
        known: BTreeSet<String>,
        active: &str,
        now: Instant,
    ) -> Vec<String> {
        let gone: Vec<String> = self
            .profiles
            .iter()
            .flatten()
            .filter(|p| !known.contains(*p))
            .cloned()
            .collect();
        self.names.retain(|_, id| known.contains(&id.profile));
        for profile in &gone {
            self.registry.profile_gone(profile);
        }
        self.by_instance.forget_full(now);
        let removed = match self.store.retain(&known) {
            Ok(removed) => removed,
            Err(err) => {
                eprintln!("ruya-platform: permission files not swept: {err}");
                Vec::new()
            }
        };
        self.profiles = Some(known);
        self.active = active.to_owned();
        removed
    }

    /// A unique name left the bus: its identity, its bucket and what the capabilities hold for it.
    pub fn name_gone(&mut self, name: &str, now: Instant) {
        self.names.remove(name);
        self.by_name.forget(&name.to_owned());
        self.by_instance.forget_full(now);
        self.registry.name_gone(name);
    }

    fn known_profile(&self, profile: &str) -> Result<(), Status> {
        let profile = arg(profile, MAX_PROFILE_ID)?;
        let known = self.profiles.as_ref().is_some_and(|k| k.contains(profile));
        if valid_profile_id(profile) && known {
            Ok(())
        } else {
            Err(Status::InvalidArgument)
        }
    }

    /// `Manage.ListPermissions`: every (app id, capability, allowed) the player set for `profile`.
    pub fn list_permissions(&self, profile: &str) -> Result<Vec<(String, String, bool)>, Status> {
        self.known_profile(profile)?;
        let choices = self.store.load(profile).map_err(|err| {
            eprintln!("ruya-platform: permissions of {profile} not readable: {err}");
            Status::Failed
        })?;
        Ok(choices
            .into_iter()
            .flat_map(|(app, caps)| {
                caps.into_iter()
                    .map(move |(cap, allowed)| (app.clone(), cap, allowed))
            })
            .collect())
    }

    /// `Manage.SetPermission`. Turning a capability off ends what the app holds of it.
    pub fn set_permission(
        &mut self,
        profile: &str,
        app_id: &str,
        capability: &str,
        allowed: bool,
    ) -> Status {
        if let Err(status) = self.known_profile(profile) {
            return status;
        }
        let (Ok(app_id), Ok(capability)) =
            (arg(app_id, MAX_APP_ID), arg(capability, MAX_CAPABILITY))
        else {
            return Status::InvalidArgument;
        };
        if !valid_app_id(app_id) || !self.registry.has_key(capability) {
            return Status::InvalidArgument;
        }
        if let Err(err) = self.store.set(profile, app_id, capability, allowed) {
            eprintln!("ruya-platform: permission of {profile} not written: {err}");
            return Status::Failed;
        }
        eprintln!("ruya-platform: {profile} {app_id} {capability} = {allowed}");
        if !allowed {
            self.registry.withdrawn(profile, app_id, capability);
        }
        Status::Ok
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::identity::fake::{FakeProcfs, FakeUsers, Process};
    use crate::lifecycle::{self, Lifecycle};
    use std::time::Duration;

    pub const APP: &str = "org.example.Racer";
    pub const OTHER: &str = "org.example.Chess";

    /// A caller of `app` instance `instance` as `ruya-<profile>` (uid 1000 + n of `pn`), through
    /// pidfd `fd` and pid `pid`.
    pub struct App {
        pub name: String,
        pub uid: u32,
        pub pid: u32,
        pub fd: i32,
    }

    impl App {
        pub fn caller(&self) -> Caller<'_> {
            Caller {
                name: &self.name,
                uid: Some(self.uid),
                pid: Some(self.pid),
                pidfd: Some(self.fd),
            }
        }
    }

    pub struct World {
        pub procfs: FakeProcfs,
        pub users: FakeUsers,
        next: u32,
    }

    impl World {
        pub fn new() -> World {
            let mut users = FakeUsers::default();
            for n in 1..=3 {
                users.0.insert(1000 + n, format!("ruya-p{n}"));
            }
            World {
                procfs: FakeProcfs::default(),
                users,
                next: 0,
            }
        }

        /// A sandboxed caller of `app` instance `instance` of profile `p<n>`.
        pub fn app(&mut self, n: u32, app: &str, instance: &str) -> App {
            self.next += 1;
            let (uid, pid, fd) = (1000 + n, 5000 + self.next, 100 + self.next as i32);
            let scope = ruya_flatpak::scope::instance_scope(app, instance).expect("valid");
            self.procfs.pidfd(fd, &[pid as i32]);
            self.procfs.processes.insert(
                pid,
                Process {
                    flatpak_info: Some(
                        format!("[Application]\nname={app}\n[Instance]\ninstance-id={instance}\n").into_bytes(),
                    ),
                    cgroup: Some(
                        format!("0::/user.slice/user-{uid}.slice/user@{uid}.service/app.slice/{scope}\n").into_bytes(),
                    ),
                },
            );
            App {
                name: format!(":1.{}", self.next),
                uid,
                pid,
                fd,
            }
        }

        /// The door over this world, with Lifecycle registered, profiles p1 and p2, p1 active.
        pub fn door(self, root: &std::path::Path, now: Instant) -> Platform {
            let mut registry = Registry::default();
            registry
                .register(
                    lifecycle::INTERFACE,
                    lifecycle::KEY,
                    Box::<Lifecycle>::default(),
                )
                .expect("registers");
            let store = Store::open(&root.join("platform")).expect("opens");
            let mut door =
                Platform::new(Box::new(self.procfs), Box::new(self.users), store, registry);
            door.follow_profiles(known(&["p1", "p2"]), "p1", now);
            door
        }
    }

    pub fn known(ids: &[&str]) -> BTreeSet<String> {
        ids.iter().map(|s| (*s).to_owned()).collect()
    }

    const L: &str = lifecycle::INTERFACE;

    #[test]
    fn a_permitted_app_is_admitted_as_itself() {
        let dir = tempfile::tempdir().expect("temp");
        let now = Instant::now();
        let mut w = World::new();
        let a = w.app(1, APP, "7");
        let mut door = w.door(dir.path(), now);
        let id = door
            .admit(&a.caller(), L, Gate::ActiveProfile, now)
            .expect("admitted");
        assert_eq!(
            (
                id.app_id.as_str(),
                id.profile.as_str(),
                id.instance_id.as_str()
            ),
            (APP, "p1", "7")
        );
    }

    #[test]
    fn permission_off_is_not_allowed() {
        let dir = tempfile::tempdir().expect("temp");
        let now = Instant::now();
        let mut w = World::new();
        let a = w.app(1, APP, "7");
        let b = w.app(1, OTHER, "8");
        let mut door = w.door(dir.path(), now);
        assert_eq!(
            door.set_permission("p1", APP, "lifecycle", false),
            Status::Ok
        );
        assert_eq!(
            door.admit(&a.caller(), L, Gate::ActiveProfile, now),
            Err(Status::NotAllowed)
        );
        assert!(
            door.admit(&b.caller(), L, Gate::ActiveProfile, now).is_ok(),
            "only that app"
        );
        assert_eq!(
            door.set_permission("p1", APP, "lifecycle", true),
            Status::Ok
        );
        assert!(door.admit(&a.caller(), L, Gate::ActiveProfile, now).is_ok());
    }

    #[test]
    fn a_choice_belongs_to_its_profile() {
        let dir = tempfile::tempdir().expect("temp");
        let now = Instant::now();
        let mut w = World::new();
        let a2 = w.app(2, APP, "7");
        let mut door = w.door(dir.path(), now);
        door.follow_profiles(known(&["p1", "p2"]), "p2", now);
        assert_eq!(
            door.set_permission("p1", APP, "lifecycle", false),
            Status::Ok
        );
        assert!(
            door.admit(&a2.caller(), L, Gate::ActiveProfile, now)
                .is_ok(),
            "p1's choice is not p2's"
        );
    }

    #[test]
    fn an_unregistered_interface_admits_nobody() {
        let dir = tempfile::tempdir().expect("temp");
        let now = Instant::now();
        let mut w = World::new();
        let a = w.app(1, APP, "7");
        let mut door = w.door(dir.path(), now);
        assert_eq!(
            door.admit(
                &a.caller(),
                "org.ruyaos.Platform1.Captures",
                Gate::ActiveProfile,
                now
            ),
            Err(Status::NotAllowed)
        );
    }

    #[test]
    fn an_app_of_an_inactive_profile_is_refused_where_the_gate_says_so() {
        let dir = tempfile::tempdir().expect("temp");
        let now = Instant::now();
        let mut w = World::new();
        let a2 = w.app(2, APP, "7");
        let mut door = w.door(dir.path(), now);
        assert_eq!(
            door.admit(&a2.caller(), L, Gate::ActiveProfile, now),
            Err(Status::NotAllowed)
        );
        assert!(
            door.admit(&a2.caller(), L, Gate::AnyProfile, now).is_ok(),
            "an answer to the OS"
        );
        // Nobody signed in (locked): no profile is active.
        door.follow_profiles(known(&["p1", "p2"]), "", now);
        assert_eq!(
            door.admit(&a2.caller(), L, Gate::ActiveProfile, now),
            Err(Status::NotAllowed)
        );
        door.follow_profiles(known(&["p1", "p2"]), "p2", now);
        assert!(
            door.admit(&a2.caller(), L, Gate::ActiveProfile, now)
                .is_ok(),
            "signed in again"
        );
    }

    #[test]
    fn nobody_is_an_app_before_profiles1_answered() {
        let dir = tempfile::tempdir().expect("temp");
        let now = Instant::now();
        let mut w = World::new();
        let a = w.app(1, APP, "7");
        let mut registry = Registry::default();
        registry
            .register(L, lifecycle::KEY, Box::<Lifecycle>::default())
            .expect("registers");
        let store = Store::open(&dir.path().join("platform")).expect("opens");
        let mut door = Platform::new(Box::new(w.procfs), Box::new(w.users), store, registry);
        assert_eq!(
            door.admit(&a.caller(), L, Gate::AnyProfile, now),
            Err(Status::NotAnApp)
        );
        assert_eq!(
            door.set_permission("p1", APP, "lifecycle", false),
            Status::InvalidArgument
        );
    }

    #[test]
    fn a_deleted_profile_loses_its_apps_and_its_file() {
        let dir = tempfile::tempdir().expect("temp");
        let now = Instant::now();
        let mut w = World::new();
        let a2 = w.app(2, APP, "7");
        let mut door = w.door(dir.path(), now);
        assert_eq!(
            door.set_permission("p2", APP, "lifecycle", true),
            Status::Ok
        );
        assert!(
            door.admit(&a2.caller(), L, Gate::AnyProfile, now).is_ok(),
            "cached now"
        );
        let file = dir.path().join("platform").join("profiles").join("p2.json");
        assert!(file.exists());
        assert_eq!(door.follow_profiles(known(&["p1"]), "p1", now), ["p2"]);
        assert!(!file.exists(), "the file went with the profile");
        assert_eq!(
            door.admit(
                &a2.caller(),
                L,
                Gate::AnyProfile,
                now + Duration::from_secs(60)
            ),
            Err(Status::NotAnApp),
            "the cached identity went too"
        );
        assert_eq!(door.list_permissions("p2"), Err(Status::InvalidArgument));
    }

    #[test]
    fn a_flood_is_cut_per_connection_before_any_read() {
        let dir = tempfile::tempdir().expect("temp");
        let now = Instant::now();
        let mut w = World::new();
        let a = w.app(1, APP, "7");
        let mut door = w.door(dir.path(), now);
        // Not an app at all: refused by the bucket from the 11th call on, with no read.
        let stranger = Caller {
            name: ":1.999",
            uid: Some(1001),
            pid: Some(1),
            pidfd: Some(1),
        };
        for _ in 0..CALLER_RATE.capacity {
            assert_eq!(
                door.admit(&stranger, L, Gate::ActiveProfile, now),
                Err(Status::NotAnApp)
            );
        }
        assert_eq!(
            door.admit(&stranger, L, Gate::ActiveProfile, now),
            Err(Status::RateLimited)
        );
        for _ in 0..CALLER_RATE.capacity {
            assert!(door.admit(&a.caller(), L, Gate::ActiveProfile, now).is_ok());
        }
        assert_eq!(
            door.admit(&a.caller(), L, Gate::ActiveProfile, now),
            Err(Status::RateLimited)
        );
        assert!(
            door.admit(
                &a.caller(),
                L,
                Gate::ActiveProfile,
                now + CALLER_RATE.refill
            )
            .is_ok(),
            "refilled"
        );
    }

    #[test]
    fn an_instance_has_one_bucket_whatever_its_connections() {
        let dir = tempfile::tempdir().expect("temp");
        let now = Instant::now();
        let mut w = World::new();
        let conns: Vec<App> = (0..CALLER_RATE.capacity + 1)
            .map(|_| w.app(1, APP, "7"))
            .collect();
        let mut door = w.door(dir.path(), now);
        for c in &conns[..CALLER_RATE.capacity as usize] {
            assert!(door.admit(&c.caller(), L, Gate::ActiveProfile, now).is_ok());
        }
        assert_eq!(
            door.admit(
                &conns[CALLER_RATE.capacity as usize].caller(),
                L,
                Gate::ActiveProfile,
                now
            ),
            Err(Status::RateLimited),
            "a new connection of the same instance shares its bucket"
        );
    }

    #[test]
    fn the_identity_is_kept_per_connection_until_it_leaves() {
        let dir = tempfile::tempdir().expect("temp");
        let now = Instant::now();
        let mut w = World::new();
        let a = w.app(1, APP, "7");
        // The pidfd names the process for the recipe's two looks, then the process is gone.
        w.procfs.pidfd(a.fd, &[a.pid as i32, a.pid as i32, -1]);
        let mut door = w.door(dir.path(), now);
        door.admit(&a.caller(), L, Gate::ActiveProfile, now)
            .expect("admitted");
        // The connection is the same peer: its identity is not read again.
        door.admit(&a.caller(), L, Gate::ActiveProfile, now)
            .expect("still itself");
        // When the name leaves the bus it is forgotten; the recipe runs again and sees the end.
        door.name_gone(&a.name, now);
        assert_eq!(
            door.admit(&a.caller(), L, Gate::ActiveProfile, now),
            Err(Status::NotAnApp)
        );
    }

    #[test]
    fn manage_arguments_are_checked() {
        let dir = tempfile::tempdir().expect("temp");
        let now = Instant::now();
        let mut door = World::new().door(dir.path(), now);
        for (p, app, cap) in [
            ("p9", APP, "lifecycle"),
            ("../p1", APP, "lifecycle"),
            ("p1\n", APP, "lifecycle"),
            ("p1", "Racer", "lifecycle"),
            ("p1", "org.example.Racer\u{0}", "lifecycle"),
            ("p1", &"a.b.".repeat(100), "lifecycle"),
            ("p1", APP, "captures"),
            ("p1", APP, ""),
            ("p1", APP, &"x".repeat(1000)),
        ] {
            assert_eq!(
                door.set_permission(p, app, cap, false),
                Status::InvalidArgument,
                "{p:?} {app:?} {cap:?}"
            );
        }
        assert_eq!(door.list_permissions("p1"), Ok(vec![]));
        assert_eq!(
            door.set_permission("p1", APP, "lifecycle", false),
            Status::Ok
        );
        assert_eq!(
            door.list_permissions("p1"),
            Ok(vec![(APP.to_owned(), "lifecycle".to_owned(), false)])
        );
        assert_eq!(
            door.list_permissions(&"p".repeat(10_000)),
            Err(Status::InvalidArgument)
        );
    }

    #[test]
    fn a_corrupt_permission_file_fails_closed() {
        let dir = tempfile::tempdir().expect("temp");
        let now = Instant::now();
        let mut w = World::new();
        let a = w.app(1, APP, "7");
        let mut door = w.door(dir.path(), now);
        assert_eq!(
            door.set_permission("p1", OTHER, "lifecycle", true),
            Status::Ok
        );
        let file = dir.path().join("platform").join("profiles").join("p1.json");
        std::fs::write(&file, "{").expect("write");
        assert_eq!(
            door.admit(&a.caller(), L, Gate::ActiveProfile, now),
            Err(Status::Failed)
        );
        assert_eq!(
            door.set_permission("p1", APP, "lifecycle", true),
            Status::Failed
        );
        assert_eq!(door.list_permissions("p1"), Err(Status::Failed));
        assert_eq!(
            std::fs::read_to_string(&file).expect("read"),
            "{",
            "never overwritten"
        );
    }

    #[test]
    fn who_may_manage() {
        assert!(may_manage(0, Some(990)) && may_manage(990, Some(990)));
        assert!(!may_manage(1001, Some(990)), "a profile user");
        assert!(may_manage(0, None) && !may_manage(990, None));
        assert!(may_notify(0));
        assert!(!may_notify(990), "the shell may not send lifecycle events");
    }
}
