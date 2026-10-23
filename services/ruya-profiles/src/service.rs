//! Profile service logic behind org.ruyaos.Profiles1 (api/dbus/org.ruyaos.Profiles1.xml).
//! Time is passed in so lockout behaviour is testable.

use std::time::{Duration, Instant};

use crate::accounts::Accounts;
use crate::lockout::{Gate, Lockout};
use crate::pin;
use crate::store::{Profile, Role, Store};

/// Stable status strings of the D-Bus API.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    WrongPin,
    LockedOut,
    PinRequired,
    UnknownProfile,
    NotAllowed,
    Invalid,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::WrongPin => "wrong-pin",
            Status::LockedOut => "locked-out",
            Status::PinRequired => "pin-required",
            Status::UnknownProfile => "unknown-profile",
            Status::NotAllowed => "not-allowed",
            Status::Invalid => "invalid",
            Status::Failed => "failed",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Outcome {
    pub status: Status,
    pub attempts_left: u32,
    pub retry_after: Duration,
}

impl Outcome {
    fn of(status: Status) -> Outcome {
        Outcome {
            status,
            attempts_left: 0,
            retry_after: Duration::ZERO,
        }
    }
}

const MAX_NAME_CHARS: usize = 32;
const AVATAR_COLOURS: [&str; 6] = [
    "#3a5bd9", "#d9483a", "#2fa37a", "#7a5bd9", "#d99a3a", "#3aa7d9",
];

pub struct ProfileService<A: Accounts> {
    store: Store,
    lockout: Lockout,
    accounts: A,
    active: Option<String>,
}

impl<A: Accounts> ProfileService<A> {
    pub fn new(store: Store, accounts: A) -> Self {
        ProfileService {
            store,
            lockout: Lockout::default(),
            accounts,
            active: None,
        }
    }

    pub fn profiles(&self) -> &[Profile] {
        self.store.profiles()
    }

    pub fn active(&self) -> Option<&str> {
        self.active.as_deref()
    }

    /// The single place PINs are checked; every failure counts towards lockout.
    fn authenticate(&mut self, id: &str, given: &str, now: Instant) -> Outcome {
        let Some(profile) = self.store.get(id) else {
            return Outcome::of(Status::UnknownProfile);
        };
        let Some(hash) = profile.pin_hash.clone() else {
            return Outcome::of(Status::Ok);
        };
        if let Gate::Locked(retry_after) = self.lockout.check(id, now) {
            return Outcome {
                status: Status::LockedOut,
                attempts_left: 0,
                retry_after,
            };
        }
        if given.is_empty() {
            return Outcome {
                status: Status::PinRequired,
                attempts_left: self.lockout.attempts_left(id),
                retry_after: Duration::ZERO,
            };
        }
        if pin::verify(given, &hash) {
            self.lockout.succeed(id);
            return Outcome::of(Status::Ok);
        }
        let attempts_left = self.lockout.fail(id, now);
        match self.lockout.check(id, now) {
            Gate::Locked(retry_after) => Outcome {
                status: Status::LockedOut,
                attempts_left: 0,
                retry_after,
            },
            Gate::Open => Outcome {
                status: Status::WrongPin,
                attempts_left,
                retry_after: Duration::ZERO,
            },
        }
    }

    pub fn switch_to(&mut self, id: &str, given_pin: &str, now: Instant) -> Outcome {
        let outcome = self.authenticate(id, given_pin, now);
        if outcome.status == Status::Ok {
            self.active = Some(id.to_owned());
        }
        outcome
    }

    pub fn lock(&mut self) {
        self.active = None;
    }

    /// Returns the outcome (status plus attempts left / retry time after a failed admin PIN)
    /// and the new id on success.
    pub fn create_profile(
        &mut self,
        admin_id: &str,
        admin_pin: &str,
        name: &str,
        role: &str,
        new_pin: &str,
        now: Instant,
    ) -> (Outcome, Option<String>) {
        let first_boot = self.store.profiles().is_empty();
        let Some(role) = Role::parse(role) else {
            return (Outcome::of(Status::Invalid), None);
        };
        let name = name.trim();
        if name.is_empty()
            || name.chars().count() > MAX_NAME_CHARS
            || name.chars().any(char::is_control)
        {
            return (Outcome::of(Status::Invalid), None);
        }
        // Admins must have a PIN; guests never have one; others may.
        let pin_ok = match role {
            Role::Admin => pin::is_valid(new_pin),
            Role::Guest => new_pin.is_empty(),
            Role::Standard => new_pin.is_empty() || pin::is_valid(new_pin),
        };
        if !pin_ok {
            return (Outcome::of(Status::Invalid), None);
        }

        if first_boot {
            if role != Role::Admin {
                return (Outcome::of(Status::NotAllowed), None);
            }
        } else {
            if self.store.get(admin_id).map(|p| p.role) != Some(Role::Admin) {
                return (Outcome::of(Status::NotAllowed), None);
            }
            let auth = self.authenticate(admin_id, admin_pin, now);
            if auth.status != Status::Ok {
                return (auth, None);
            }
        }

        let pin_hash = if new_pin.is_empty() {
            None
        } else {
            match pin::hash(new_pin) {
                Ok(h) => Some(h),
                Err(_) => return (Outcome::of(Status::Failed), None),
            }
        };

        let id = self.store.peek_next_id();
        if self.accounts.create(&id).is_err() {
            return (Outcome::of(Status::Failed), None);
        }
        let avatar = AVATAR_COLOURS[self.store.profiles().len() % AVATAR_COLOURS.len()].to_owned();
        self.store.insert(Profile {
            id: String::new(),
            name: name.to_owned(),
            avatar,
            role,
            pin_hash,
        });
        if self.store.save().is_err() {
            return (Outcome::of(Status::Failed), None);
        }
        (Outcome::of(Status::Ok), Some(id))
    }

    /// Like `create_profile`, the outcome carries attempts left / retry time for a wrong old PIN.
    pub fn set_pin(&mut self, id: &str, old_pin: &str, new_pin: &str, now: Instant) -> Outcome {
        let Some(role) = self.store.get(id).map(|p| p.role) else {
            return Outcome::of(Status::UnknownProfile);
        };
        let allowed = match role {
            Role::Admin => pin::is_valid(new_pin),
            Role::Guest => false,
            Role::Standard => new_pin.is_empty() || pin::is_valid(new_pin),
        };
        if !allowed {
            return Outcome::of(Status::Invalid);
        }
        let auth = self.authenticate(id, old_pin, now);
        if auth.status != Status::Ok {
            return auth;
        }
        let hash = if new_pin.is_empty() {
            None
        } else {
            match pin::hash(new_pin) {
                Ok(h) => Some(h),
                Err(_) => return Outcome::of(Status::Failed),
            }
        };
        self.store.get_mut(id).expect("checked above").pin_hash = hash;
        match self.store.save() {
            Ok(()) => Outcome::of(Status::Ok),
            Err(_) => Outcome::of(Status::Failed),
        }
    }

    /// The actor must be an admin or the profile itself, and is authenticated with its own PIN.
    pub fn rename_profile(
        &mut self,
        actor_id: &str,
        actor_pin: &str,
        id: &str,
        name: &str,
        now: Instant,
    ) -> Outcome {
        if self.store.get(id).is_none() {
            return Outcome::of(Status::UnknownProfile);
        }
        let name = name.trim();
        if name.is_empty()
            || name.chars().count() > MAX_NAME_CHARS
            || name.chars().any(char::is_control)
        {
            return Outcome::of(Status::Invalid);
        }
        let Some(actor_role) = self.store.get(actor_id).map(|p| p.role) else {
            return Outcome::of(Status::NotAllowed);
        };
        if actor_role != Role::Admin && actor_id != id {
            return Outcome::of(Status::NotAllowed);
        }
        let auth = self.authenticate(actor_id, actor_pin, now);
        if auth.status != Status::Ok {
            return auth;
        }
        let Some(profile) = self.store.get_mut(id) else {
            return Outcome::of(Status::UnknownProfile);
        };
        let old = std::mem::replace(&mut profile.name, name.to_owned());
        if self.store.save().is_err() {
            if let Some(p) = self.store.get_mut(id) {
                p.name = old;
            }
            return Outcome::of(Status::Failed);
        }
        Outcome::of(Status::Ok)
    }

    /// Admin only. Refused for the last admin and for the active profile. The Unix user goes
    /// first: if that fails the store is untouched.
    pub fn delete_profile(
        &mut self,
        admin_id: &str,
        admin_pin: &str,
        id: &str,
        now: Instant,
    ) -> Outcome {
        let Some(target_role) = self.store.get(id).map(|p| p.role) else {
            return Outcome::of(Status::UnknownProfile);
        };
        if self.store.get(admin_id).map(|p| p.role) != Some(Role::Admin) {
            return Outcome::of(Status::NotAllowed);
        }
        let auth = self.authenticate(admin_id, admin_pin, now);
        if auth.status != Status::Ok {
            return auth;
        }
        let admins = self
            .store
            .profiles()
            .iter()
            .filter(|p| p.role == Role::Admin)
            .count();
        if self.active.as_deref() == Some(id) || (target_role == Role::Admin && admins <= 1) {
            return Outcome::of(Status::NotAllowed);
        }
        // The store is saved before `userdel`: if saving fails nothing has changed; if `userdel`
        // fails the profile is put back. A Unix user left over after a double failure is harmless
        // (ids are never reused, its shell is nologin).
        let Some((index, profile)) = self.store.remove(id) else {
            return Outcome::of(Status::UnknownProfile);
        };
        if self.store.save().is_err() {
            self.store.restore(index, profile);
            return Outcome::of(Status::Failed);
        }
        if self.accounts.remove(id).is_err() {
            self.store.restore(index, profile);
            let _ = self.store.save();
            return Outcome::of(Status::Failed);
        }
        self.lockout.succeed(id);
        Outcome::of(Status::Ok)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::accounts::NoAccounts;
    use crate::lockout::{FIRST_LOCKOUT, FREE_ATTEMPTS};

    struct Fixture {
        dir: tempfile::TempDir,
        svc: ProfileService<NoAccounts>,
        now: Instant,
    }

    /// Admin "p1" (PIN 1234) and standard "p2" without PIN.
    fn fixture() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path().join("profiles.toml")).unwrap();
        let mut svc = ProfileService::new(store, NoAccounts);
        let now = Instant::now();
        let (o, id) = svc.create_profile("", "", "Admin", "admin", "1234", now);
        assert_eq!((o.status, id), (Status::Ok, Some("p1".into())));
        let (o, id) = svc.create_profile("p1", "1234", "Kid", "standard", "", now);
        assert_eq!((o.status, id), (Status::Ok, Some("p2".into())));
        Fixture { dir, svc, now }
    }

    #[test]
    fn first_profile_must_be_admin_with_pin() {
        let dir = tempfile::tempdir().unwrap();
        let mut svc =
            ProfileService::new(Store::open(dir.path().join("p.toml")).unwrap(), NoAccounts);
        let now = Instant::now();
        assert_eq!(
            svc.create_profile("", "", "Kid", "standard", "", now)
                .0
                .status,
            Status::NotAllowed
        );
        assert_eq!(
            svc.create_profile("", "", "Admin", "admin", "", now)
                .0
                .status,
            Status::Invalid
        );
        assert_eq!(
            svc.create_profile("", "", "Admin", "admin", "1234", now)
                .0
                .status,
            Status::Ok
        );
    }

    #[test]
    fn creating_more_profiles_needs_admin_credentials() {
        let Fixture { mut svc, now, .. } = fixture();
        assert_eq!(
            svc.create_profile("p1", "9999", "X", "standard", "", now)
                .0
                .status,
            Status::WrongPin
        );
        assert_eq!(
            svc.create_profile("p2", "", "X", "standard", "", now)
                .0
                .status,
            Status::NotAllowed
        );
        assert_eq!(
            svc.create_profile("p1", "1234", "Guest", "guest", "", now)
                .0
                .status,
            Status::Ok
        );
        assert_eq!(
            svc.create_profile("p1", "1234", "G2", "guest", "1111", now)
                .0
                .status,
            Status::Invalid
        );
        assert_eq!(
            svc.create_profile("p1", "1234", "  ", "standard", "", now)
                .0
                .status,
            Status::Invalid
        );
        assert_eq!(
            svc.create_profile("p1", "1234", "X", "superuser", "", now)
                .0
                .status,
            Status::Invalid
        );
    }

    #[test]
    fn switching_checks_pin_only_when_set() {
        let Fixture { mut svc, now, .. } = fixture();
        assert_eq!(svc.switch_to("p2", "", now).status, Status::Ok);
        assert_eq!(svc.active(), Some("p2"));
        assert_eq!(svc.switch_to("p1", "", now).status, Status::PinRequired);
        assert_eq!(
            svc.active(),
            Some("p2"),
            "failed switch keeps the current profile"
        );
        assert_eq!(svc.switch_to("p1", "1234", now).status, Status::Ok);
        assert_eq!(svc.active(), Some("p1"));
        assert_eq!(
            svc.switch_to("nope", "", now).status,
            Status::UnknownProfile
        );
        svc.lock();
        assert_eq!(svc.active(), None);
    }

    #[test]
    fn wrong_pins_lead_to_lockout_shared_across_operations() {
        let Fixture { mut svc, now, .. } = fixture();
        for left in (1..FREE_ATTEMPTS).rev() {
            let o = svc.switch_to("p1", "0000", now);
            assert_eq!((o.status, o.attempts_left), (Status::WrongPin, left));
        }
        let o = svc.switch_to("p1", "0000", now);
        assert_eq!(
            (o.status, o.retry_after),
            (Status::LockedOut, FIRST_LOCKOUT)
        );
        // Even the right PIN and admin actions are refused while locked out.
        assert_eq!(svc.switch_to("p1", "1234", now).status, Status::LockedOut);
        assert_eq!(
            svc.create_profile("p1", "1234", "X", "standard", "", now)
                .0
                .status,
            Status::LockedOut
        );
        assert_eq!(
            svc.switch_to("p1", "1234", now + FIRST_LOCKOUT).status,
            Status::Ok
        );
    }

    #[test]
    fn create_profile_reports_attempts_and_retry_time() {
        let Fixture { mut svc, now, .. } = fixture();
        for expected in (1..FREE_ATTEMPTS).rev() {
            let (o, id) = svc.create_profile("p1", "0000", "X", "standard", "", now);
            assert_eq!((o.status, o.attempts_left), (Status::WrongPin, expected));
            assert_eq!(o.retry_after, Duration::ZERO);
            assert_eq!(id, None);
        }
        let (o, id) = svc.create_profile("p1", "0000", "X", "standard", "", now);
        assert_eq!(
            (o.status, o.attempts_left, o.retry_after),
            (Status::LockedOut, 0, FIRST_LOCKOUT)
        );
        assert_eq!(id, None);
        // Still locked: the right PIN reports the remaining time, not success.
        let (o, _) = svc.create_profile("p1", "1234", "X", "standard", "", now);
        assert_eq!(
            (o.status, o.retry_after),
            (Status::LockedOut, FIRST_LOCKOUT)
        );
        // Success carries zeros.
        let later = now + FIRST_LOCKOUT;
        let (o, id) = svc.create_profile("p1", "1234", "X", "standard", "", later);
        assert_eq!(
            (o.status, o.attempts_left, o.retry_after),
            (Status::Ok, 0, Duration::ZERO)
        );
        assert_eq!(id.as_deref(), Some("p3"));
    }

    #[test]
    fn set_pin_reports_attempts_and_retry_time() {
        let Fixture { mut svc, now, .. } = fixture();
        for expected in (1..FREE_ATTEMPTS).rev() {
            let o = svc.set_pin("p1", "0000", "5678", now);
            assert_eq!((o.status, o.attempts_left), (Status::WrongPin, expected));
            assert_eq!(o.retry_after, Duration::ZERO);
        }
        let o = svc.set_pin("p1", "0000", "5678", now);
        assert_eq!(
            (o.status, o.attempts_left, o.retry_after),
            (Status::LockedOut, 0, FIRST_LOCKOUT)
        );
        let o = svc.set_pin("p1", "1234", "5678", now + FIRST_LOCKOUT);
        assert_eq!(
            (o.status, o.attempts_left, o.retry_after),
            (Status::Ok, 0, Duration::ZERO)
        );
        // Rule failures are not PIN failures: no counts, and they do not touch the counter.
        let o = svc.set_pin("p1", "5678", "", now + FIRST_LOCKOUT);
        assert_eq!((o.status, o.attempts_left), (Status::Invalid, 0));
        let o = svc.set_pin("nope", "", "1234", now);
        assert_eq!(o.status, Status::UnknownProfile);
    }

    #[test]
    fn pin_rules_for_set_pin() {
        let Fixture { mut svc, now, .. } = fixture();
        assert_eq!(
            svc.set_pin("p1", "1234", "", now).status,
            Status::Invalid,
            "admins keep a PIN"
        );
        assert_eq!(
            svc.set_pin("p1", "0000", "5678", now).status,
            Status::WrongPin
        );
        assert_eq!(svc.set_pin("p1", "1234", "5678", now).status, Status::Ok);
        assert_eq!(svc.switch_to("p1", "5678", now).status, Status::Ok);
        assert_eq!(svc.set_pin("p2", "", "4321", now).status, Status::Ok);
        assert_eq!(svc.switch_to("p2", "", now).status, Status::PinRequired);
        assert_eq!(svc.set_pin("p2", "4321", "", now).status, Status::Ok);
        assert_eq!(svc.switch_to("p2", "", now).status, Status::Ok);
    }

    #[test]
    fn rename_rules() {
        let Fixture { mut svc, now, .. } = fixture();
        for bad in ["", "   ", "a\tb", &"x".repeat(33)] {
            assert_eq!(
                svc.rename_profile("p1", "1234", "p2", bad, now).status,
                Status::Invalid,
                "{bad:?}"
            );
        }
        assert_eq!(
            svc.rename_profile("p1", "1234", "nope", "X", now).status,
            Status::UnknownProfile
        );
        assert_eq!(
            svc.rename_profile("p2", "", "p1", "Boss", now).status,
            Status::NotAllowed,
            "a non-admin renames only itself"
        );
        assert_eq!(
            svc.rename_profile("nope", "", "p2", "X", now).status,
            Status::NotAllowed
        );
        let o = svc.rename_profile("p1", "0000", "p2", "X", now);
        assert_eq!(
            (o.status, o.attempts_left),
            (Status::WrongPin, FREE_ATTEMPTS - 1)
        );
        // Yourself, no PIN needed for a profile without one; the name is stored trimmed.
        assert_eq!(
            svc.rename_profile("p2", "", "p2", "  Ada  ", now).status,
            Status::Ok
        );
        assert_eq!(svc.profiles()[1].name, "Ada");
        // An admin renames anyone, and yourself needs your own PIN.
        assert_eq!(
            svc.rename_profile("p1", "1234", "p2", "Bo", now).status,
            Status::Ok
        );
        assert_eq!(
            svc.rename_profile("p1", "", "p1", "Root", now).status,
            Status::PinRequired
        );
        assert_eq!(
            svc.rename_profile("p1", "1234", "p1", "Root", now).status,
            Status::Ok
        );
    }

    #[test]
    fn rename_counts_towards_lockout() {
        let Fixture { mut svc, now, .. } = fixture();
        for _ in 0..FREE_ATTEMPTS {
            svc.rename_profile("p1", "0000", "p2", "X", now);
        }
        let o = svc.rename_profile("p1", "1234", "p2", "X", now);
        assert_eq!(
            (o.status, o.retry_after),
            (Status::LockedOut, FIRST_LOCKOUT)
        );
    }

    #[derive(Clone, Default)]
    struct Recording {
        removed: std::sync::Arc<std::sync::Mutex<Vec<String>>>,
        fail: bool,
    }

    impl Accounts for Recording {
        fn create(&self, _profile_id: &str) -> std::io::Result<()> {
            Ok(())
        }
        fn remove(&self, profile_id: &str) -> std::io::Result<()> {
            if self.fail {
                return Err(std::io::Error::other("userdel failed"));
            }
            self.removed.lock().unwrap().push(profile_id.to_owned());
            Ok(())
        }
    }

    fn recording_fixture(
        accounts: Recording,
    ) -> (tempfile::TempDir, ProfileService<Recording>, Instant) {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path().join("profiles.toml")).unwrap();
        let mut svc = ProfileService::new(store, accounts);
        let now = Instant::now();
        svc.create_profile("", "", "Admin", "admin", "1234", now);
        svc.create_profile("p1", "1234", "Kid", "standard", "", now);
        (dir, svc, now)
    }

    #[test]
    fn delete_rules_and_effects() {
        let accounts = Recording::default();
        let (dir, mut svc, now) = recording_fixture(accounts.clone());
        assert_eq!(
            svc.delete_profile("p1", "1234", "nope", now).status,
            Status::UnknownProfile
        );
        assert_eq!(
            svc.delete_profile("p2", "", "p1", now).status,
            Status::NotAllowed,
            "only admins delete"
        );
        assert_eq!(
            svc.delete_profile("p1", "1234", "p1", now).status,
            Status::NotAllowed,
            "the last admin stays"
        );
        assert_eq!(svc.switch_to("p2", "", now).status, Status::Ok);
        assert_eq!(
            svc.delete_profile("p1", "1234", "p2", now).status,
            Status::NotAllowed,
            "the active profile stays"
        );
        svc.lock();
        let o = svc.delete_profile("p1", "0000", "p2", now);
        assert_eq!(
            (o.status, o.attempts_left),
            (Status::WrongPin, FREE_ATTEMPTS - 1)
        );
        assert!(accounts.removed.lock().unwrap().is_empty());
        assert_eq!(
            svc.delete_profile("p1", "1234", "p2", now).status,
            Status::Ok
        );
        assert_eq!(*accounts.removed.lock().unwrap(), vec!["p2".to_owned()]);
        assert_eq!(svc.profiles().len(), 1);
        // Ids are never reused.
        let (o, id) = svc.create_profile("p1", "1234", "Again", "standard", "", now);
        assert_eq!((o.status, id.as_deref()), (Status::Ok, Some("p3")));
        // The change survives a restart.
        drop(svc);
        let store = Store::open(dir.path().join("profiles.toml")).unwrap();
        let ids: Vec<_> = store.profiles().iter().map(|p| p.id.as_str()).collect();
        assert_eq!(ids, ["p1", "p3"]);
    }

    #[test]
    fn delete_counts_towards_lockout_and_drops_it_with_the_profile() {
        let (_dir, mut svc, now) = recording_fixture(Recording::default());
        for _ in 0..FREE_ATTEMPTS {
            svc.delete_profile("p1", "0000", "p2", now);
        }
        let o = svc.delete_profile("p1", "1234", "p2", now);
        assert_eq!(o.status, Status::LockedOut);
    }

    #[test]
    fn a_second_admin_can_be_deleted() {
        let (_dir, mut svc, now) = recording_fixture(Recording::default());
        svc.create_profile("p1", "1234", "Admin2", "admin", "4321", now);
        assert_eq!(
            svc.delete_profile("p1", "1234", "p3", now).status,
            Status::Ok
        );
    }

    #[test]
    fn failing_account_removal_leaves_the_profile() {
        let accounts = Recording {
            fail: true,
            ..Recording::default()
        };
        let (dir, mut svc, now) = recording_fixture(accounts);
        assert_eq!(
            svc.delete_profile("p1", "1234", "p2", now).status,
            Status::Failed
        );
        assert_eq!(svc.profiles().len(), 2);
        let store = Store::open(dir.path().join("profiles.toml")).unwrap();
        assert_eq!(store.profiles().len(), 2);
    }

    #[test]
    fn failing_store_write_keeps_the_unix_user() {
        let accounts = Recording::default();
        let (dir, mut svc, now) = recording_fixture(accounts.clone());
        // A directory where the file should be makes the atomic rename fail.
        let path = dir.path().join("profiles.toml");
        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(&path).unwrap();
        assert_eq!(
            svc.delete_profile("p1", "1234", "p2", now).status,
            Status::Failed
        );
        assert_eq!(svc.profiles().len(), 2);
        assert!(accounts.removed.lock().unwrap().is_empty());
    }

    #[test]
    fn state_survives_restart() {
        let Fixture { dir, svc, now } = fixture();
        drop(svc);
        let store = Store::open(dir.path().join("profiles.toml")).unwrap();
        let mut again = ProfileService::new(store, NoAccounts);
        assert_eq!(again.profiles().len(), 2);
        assert_eq!(again.switch_to("p1", "1234", now).status, Status::Ok);
    }
}
