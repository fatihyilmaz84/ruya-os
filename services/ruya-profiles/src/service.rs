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

    pub fn create_profile(
        &mut self,
        admin_id: &str,
        admin_pin: &str,
        name: &str,
        role: &str,
        new_pin: &str,
        now: Instant,
    ) -> (Status, Option<String>) {
        let first_boot = self.store.profiles().is_empty();
        let Some(role) = Role::parse(role) else {
            return (Status::Invalid, None);
        };
        let name = name.trim();
        if name.is_empty()
            || name.chars().count() > MAX_NAME_CHARS
            || name.chars().any(char::is_control)
        {
            return (Status::Invalid, None);
        }
        // Admins must have a PIN; guests never have one; others may.
        let pin_ok = match role {
            Role::Admin => pin::is_valid(new_pin),
            Role::Guest => new_pin.is_empty(),
            Role::Standard => new_pin.is_empty() || pin::is_valid(new_pin),
        };
        if !pin_ok {
            return (Status::Invalid, None);
        }

        if first_boot {
            if role != Role::Admin {
                return (Status::NotAllowed, None);
            }
        } else {
            if self.store.get(admin_id).map(|p| p.role) != Some(Role::Admin) {
                return (Status::NotAllowed, None);
            }
            let auth = self.authenticate(admin_id, admin_pin, now);
            if auth.status != Status::Ok {
                return (auth.status, None);
            }
        }

        let pin_hash = if new_pin.is_empty() {
            None
        } else {
            match pin::hash(new_pin) {
                Ok(h) => Some(h),
                Err(_) => return (Status::Failed, None),
            }
        };

        let id = self.store.peek_next_id();
        if self.accounts.create(&id).is_err() {
            return (Status::Failed, None);
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
            return (Status::Failed, None);
        }
        (Status::Ok, Some(id))
    }

    pub fn set_pin(&mut self, id: &str, old_pin: &str, new_pin: &str, now: Instant) -> Status {
        let Some(role) = self.store.get(id).map(|p| p.role) else {
            return Status::UnknownProfile;
        };
        let allowed = match role {
            Role::Admin => pin::is_valid(new_pin),
            Role::Guest => false,
            Role::Standard => new_pin.is_empty() || pin::is_valid(new_pin),
        };
        if !allowed {
            return Status::Invalid;
        }
        let auth = self.authenticate(id, old_pin, now);
        if auth.status != Status::Ok {
            return auth.status;
        }
        let hash = if new_pin.is_empty() {
            None
        } else {
            match pin::hash(new_pin) {
                Ok(h) => Some(h),
                Err(_) => return Status::Failed,
            }
        };
        self.store.get_mut(id).expect("checked above").pin_hash = hash;
        match self.store.save() {
            Ok(()) => Status::Ok,
            Err(_) => Status::Failed,
        }
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
        assert_eq!(
            svc.create_profile("", "", "Admin", "admin", "1234", now),
            (Status::Ok, Some("p1".into()))
        );
        assert_eq!(
            svc.create_profile("p1", "1234", "Kid", "standard", "", now),
            (Status::Ok, Some("p2".into()))
        );
        Fixture { dir, svc, now }
    }

    #[test]
    fn first_profile_must_be_admin_with_pin() {
        let dir = tempfile::tempdir().unwrap();
        let mut svc =
            ProfileService::new(Store::open(dir.path().join("p.toml")).unwrap(), NoAccounts);
        let now = Instant::now();
        assert_eq!(
            svc.create_profile("", "", "Kid", "standard", "", now).0,
            Status::NotAllowed
        );
        assert_eq!(
            svc.create_profile("", "", "Admin", "admin", "", now).0,
            Status::Invalid
        );
        assert_eq!(
            svc.create_profile("", "", "Admin", "admin", "1234", now).0,
            Status::Ok
        );
    }

    #[test]
    fn creating_more_profiles_needs_admin_credentials() {
        let Fixture { mut svc, now, .. } = fixture();
        assert_eq!(
            svc.create_profile("p1", "9999", "X", "standard", "", now).0,
            Status::WrongPin
        );
        assert_eq!(
            svc.create_profile("p2", "", "X", "standard", "", now).0,
            Status::NotAllowed
        );
        assert_eq!(
            svc.create_profile("p1", "1234", "Guest", "guest", "", now)
                .0,
            Status::Ok
        );
        assert_eq!(
            svc.create_profile("p1", "1234", "G2", "guest", "1111", now)
                .0,
            Status::Invalid
        );
        assert_eq!(
            svc.create_profile("p1", "1234", "  ", "standard", "", now)
                .0,
            Status::Invalid
        );
        assert_eq!(
            svc.create_profile("p1", "1234", "X", "superuser", "", now)
                .0,
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
            svc.create_profile("p1", "1234", "X", "standard", "", now).0,
            Status::LockedOut
        );
        assert_eq!(
            svc.switch_to("p1", "1234", now + FIRST_LOCKOUT).status,
            Status::Ok
        );
    }

    #[test]
    fn pin_rules_for_set_pin() {
        let Fixture { mut svc, now, .. } = fixture();
        assert_eq!(
            svc.set_pin("p1", "1234", "", now),
            Status::Invalid,
            "admins keep a PIN"
        );
        assert_eq!(svc.set_pin("p1", "0000", "5678", now), Status::WrongPin);
        assert_eq!(svc.set_pin("p1", "1234", "5678", now), Status::Ok);
        assert_eq!(svc.switch_to("p1", "5678", now).status, Status::Ok);
        assert_eq!(svc.set_pin("p2", "", "4321", now), Status::Ok);
        assert_eq!(svc.switch_to("p2", "", now).status, Status::PinRequired);
        assert_eq!(svc.set_pin("p2", "4321", "", now), Status::Ok);
        assert_eq!(svc.switch_to("p2", "", now).status, Status::Ok);
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
