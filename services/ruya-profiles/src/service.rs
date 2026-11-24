//! Profile service logic behind org.ruyaos.Profiles1 (api/dbus/org.ruyaos.Profiles1.xml).
//! Time is passed in so lockout behaviour is testable.

use std::time::{Duration, Instant};

use crate::accounts::{AccountKind, Accounts, GUEST_UIDS};
use crate::lockout::{Gate, Lockout};
use crate::pin;
use crate::store::{Guest, Profile, Role, Store};

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
    /// CreateGuest: every guest uid has been handed out once.
    Full,
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
            Status::Full => "full",
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

/// The answer of `create_guest`: id and number are set on `Ok` only.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GuestOutcome {
    pub status: Status,
    pub id: String,
    pub number: u32,
}

impl GuestOutcome {
    fn of(status: Status) -> GuestOutcome {
        GuestOutcome {
            status,
            id: String::new(),
            number: 0,
        }
    }
}

/// Temporary guests at once: four seats (RUY-121), and player 1 is a profile.
pub const MAX_GUESTS: u32 = 3;

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
    /// Starts the service on a store. Temporary guests left by an earlier run (a crash, a power
    /// cut) belong to no session any more: they are wiped here.
    pub fn new(store: Store, accounts: A) -> Self {
        let mut svc = ProfileService {
            store,
            lockout: Lockout::default(),
            accounts,
            active: None,
        };
        svc.wipe_guests();
        svc
    }

    /// The kept profiles; temporary guests are never among them (`guests`).
    pub fn profiles(&self) -> &[Profile] {
        self.store.profiles()
    }

    /// The live temporary guests, by number.
    pub fn guests(&self) -> Vec<&Guest> {
        let mut guests: Vec<&Guest> = self.store.guests().iter().collect();
        guests.sort_by_key(|g| g.number);
        guests
    }

    fn is_guest(&self, id: &str) -> bool {
        self.store.guest(id).is_some()
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

    /// A temporary guest only joins (ADR-017 point 7): it never becomes the active profile.
    /// A switch to another profile ends the session, and with it every temporary guest.
    pub fn switch_to(&mut self, id: &str, given_pin: &str, now: Instant) -> Outcome {
        if self.is_guest(id) {
            return Outcome::of(Status::NotAllowed);
        }
        let outcome = self.authenticate(id, given_pin, now);
        if outcome.status == Status::Ok {
            if self.active.as_deref() != Some(id) {
                // A guest whose wipe fails stays recorded into the new session; the next Lock
                // (or start-up) wipes it again.
                self.wipe_guests();
            }
            self.active = Some(id.to_owned());
        }
        outcome
    }

    /// Checks a profile's PIN like `switch_to` (the same lockout) and changes nothing: a player
    /// who joins the session is signed in without becoming the active profile.
    pub fn verify_pin(&mut self, id: &str, given_pin: &str, now: Instant) -> Outcome {
        if self.is_guest(id) {
            return Outcome::of(Status::NotAllowed);
        }
        self.authenticate(id, given_pin, now)
    }

    /// Back to the picker: the session ends, and every temporary guest is wiped.
    pub fn lock(&mut self) {
        self.active = None;
        self.wipe_guests();
    }

    /// Makes a temporary guest for the signed-in session. Its uid is the lowest one in
    /// `GUEST_UIDS` never handed out before and not in use; the counter is saved before the
    /// user is made, so a uid is never handed out twice, even after a failure.
    pub fn create_guest(&mut self) -> GuestOutcome {
        let live = self.store.guests();
        if self.active.is_none() || live.len() >= MAX_GUESTS as usize {
            return GuestOutcome::of(Status::NotAllowed);
        }
        let Some(number) = (1..=MAX_GUESTS).find(|n| live.iter().all(|g| g.number != *n)) else {
            return GuestOutcome::of(Status::NotAllowed);
        };
        let mut uid = self.store.next_guest_uid(*GUEST_UIDS.start());
        loop {
            if !GUEST_UIDS.contains(&uid) {
                eprintln!(
                    "ruya-profiles: CreateGuest -> full (guest uids {}-{} are used up)",
                    GUEST_UIDS.start(),
                    GUEST_UIDS.end()
                );
                return GuestOutcome::of(Status::Full);
            }
            match self.accounts.id_in_use(uid) {
                Ok(false) => break,
                Ok(true) => uid += 1,
                Err(err) => {
                    eprintln!("ruya-profiles: CreateGuest -> failed (uid {uid}: {err})");
                    return GuestOutcome::of(Status::Failed);
                }
            }
        }
        // The id, the uid and the guest record are saved before the user exists: a crash between
        // the two leaves a record the start-up wipe finds (a missing user counts as wiped).
        let id = self.store.reserve_id();
        self.store.set_next_guest_uid(uid + 1);
        let colour = (self.store.profiles().len() + number as usize - 1) % AVATAR_COLOURS.len();
        self.store.insert_guest(Guest {
            id: id.clone(),
            avatar: AVATAR_COLOURS[colour].to_owned(),
            number,
            uid,
        });
        if let Err(err) = self.store.save() {
            eprintln!("ruya-profiles: CreateGuest -> failed (store: {err})");
            self.store.remove_guest(&id);
            return GuestOutcome::of(Status::Failed);
        }
        if let Err(err) = self.accounts.create(&id, AccountKind::Guest { uid }) {
            eprintln!("ruya-profiles: CreateGuest {id} uid {uid} -> failed ({err})");
            // Wipes the half-made user and the record; if that fails too the record stays and
            // the next wipe tries again.
            if self.remove_guest(&id) != Status::Ok {
                eprintln!(
                    "ruya-profiles: the half-made guest {id} stays recorded for the next wipe"
                );
            }
            return GuestOutcome::of(Status::Failed);
        }
        eprintln!("ruya-profiles: CreateGuest {id} uid {uid} number {number} -> ok");
        GuestOutcome {
            status: Status::Ok,
            id,
            number,
        }
    }

    /// Wipes one temporary guest: its record, its Unix user and its home. A regular profile is
    /// never removed here (`unknown-profile`). Like `delete_profile`, the store is saved first
    /// and a failed removal of the user puts the guest back.
    pub fn remove_guest(&mut self, id: &str) -> Status {
        let Some((index, guest)) = self.store.remove_guest(id) else {
            return Status::UnknownProfile;
        };
        if self.store.save().is_err() {
            self.store.restore_guest(index, guest);
            return Status::Failed;
        }
        if let Err(err) = self.accounts.remove_guest(id, guest.uid) {
            eprintln!("ruya-profiles: removing guest {id}: {err}");
            self.store.restore_guest(index, guest);
            let _ = self.store.save();
            return Status::Failed;
        }
        Status::Ok
    }

    /// Wipes every temporary guest (session end, service start). A guest whose user cannot be
    /// removed stays listed, so the next wipe tries again.
    fn wipe_guests(&mut self) {
        let ids: Vec<String> = self.store.guests().iter().map(|g| g.id.clone()).collect();
        for id in ids {
            let status = self.remove_guest(&id);
            eprintln!("ruya-profiles: wipe guest {id} -> {}", status.as_str());
        }
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
        // RUY-716: no new kept guests; temporary guests come from "Who's playing?". Guest-role
        // profiles stored before this still load, rename and delete.
        if role == Role::Guest {
            return (Outcome::of(Status::NotAllowed), None);
        }
        let name = name.trim();
        if name.is_empty()
            || name.chars().count() > MAX_NAME_CHARS
            || name.chars().any(char::is_control)
        {
            return (Outcome::of(Status::Invalid), None);
        }
        // Admins must have a PIN; others may.
        let pin_ok = match role {
            Role::Admin => pin::is_valid(new_pin),
            Role::Guest => false,
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
        if self.accounts.create(&id, AccountKind::Regular).is_err() {
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
        if self.is_guest(id) {
            return Outcome::of(Status::NotAllowed);
        }
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
        if self.is_guest(id) || self.is_guest(actor_id) {
            return Outcome::of(Status::NotAllowed);
        }
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

    /// Checks that `admin_id` is an admin and the PIN is right, and changes nothing. The shell
    /// asks before it starts an action of its own that needs an admin (a system rollback).
    /// Counts towards the shared lockout like every other PIN check.
    pub fn verify_admin(&mut self, admin_id: &str, admin_pin: &str, now: Instant) -> Outcome {
        if self.store.get(admin_id).map(|p| p.role) != Some(Role::Admin) {
            return Outcome::of(Status::NotAllowed);
        }
        self.authenticate(admin_id, admin_pin, now)
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
        if self.is_guest(id) {
            return Outcome::of(Status::NotAllowed);
        }
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

/// The journal line of one profile call (`method` names it): the profile id and the status the
/// reply carries. It takes no PIN, so no PIN (nor its length) can reach the log. The id is the
/// caller's string: control characters are replaced so a call cannot forge a log line.
pub fn call_line(method: &str, id: &str, outcome: &Outcome) -> String {
    let id: String = id
        .chars()
        .map(|c| if c.is_control() { '?' } else { c })
        .collect();
    format!("ruya-profiles: {method} {id} -> {}", outcome.status.as_str())
}

/// The journal line of one `SwitchTo` call (RUY-547).
pub fn switch_line(id: &str, outcome: &Outcome) -> String {
    call_line("SwitchTo", id, outcome)
}

/// The journal line of one `VerifyPin` call: like `switch_line`, never the PIN.
pub fn verify_line(id: &str, outcome: &Outcome) -> String {
    call_line("VerifyPin", id, outcome)
}

/// The journal line of one `DeleteProfile` call (RUY-717): the deleted profile's id, no PIN.
pub fn delete_line(id: &str, outcome: &Outcome) -> String {
    call_line("DeleteProfile", id, outcome)
}

/// The journal line of one `Lock` call.
pub fn lock_line() -> &'static str {
    "ruya-profiles: Lock -> ok"
}

/// Whether `CreateGuest` changed the guest list the shell shows: on `ok`, and also when a failed
/// `useradd` and its failed cleanup left the half-made guest recorded and listed.
pub fn create_guest_changed(status: Status, before: &[String], after: &[String]) -> bool {
    status == Status::Ok || before != after
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::accounts::NoAccounts;
    use crate::lockout::{FIRST_LOCKOUT, FREE_ATTEMPTS};

    #[test]
    fn delete_line_names_the_profile_and_status_and_cannot_be_forged() {
        let ok = Outcome::of(Status::Ok);
        assert_eq!(delete_line("p2", &ok), "ruya-profiles: DeleteProfile p2 -> ok");
        let failed = Outcome::of(Status::Failed);
        assert_eq!(
            delete_line("p2", &failed),
            "ruya-profiles: DeleteProfile p2 -> failed"
        );
        let forged = delete_line("p2
ruya-profiles: Lock -> ok", &ok);
        assert!(!forged.contains('
'));
    }

    #[test]
    fn journal_lines_name_the_profile_and_status_and_never_the_pin() {
        let mut f = fixture();
        let wrong = f.svc.switch_to("p1", "9876", f.now);
        let line = switch_line("p1", &wrong);
        assert_eq!(line, "ruya-profiles: SwitchTo p1 -> wrong-pin");
        let right = f.svc.switch_to("p1", "1234", f.now);
        let line = switch_line("p1", &right);
        assert_eq!(line, "ruya-profiles: SwitchTo p1 -> ok");
        assert!(!line.contains("1234") && !line.contains("9876"));
        assert_eq!(
            switch_line("a\nb", &wrong),
            "ruya-profiles: SwitchTo a?b -> wrong-pin"
        );
        assert_eq!(lock_line(), "ruya-profiles: Lock -> ok");
    }

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
            Status::NotAllowed
        );
        assert_eq!(
            svc.create_profile("p1", "1234", "G2", "guest", "1111", now)
                .0
                .status,
            Status::NotAllowed
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
    fn stored_guest_role_profile_still_loads_renames_and_deletes() {
        // RUY-716: CreateProfile refuses guests, but one stored earlier keeps working.
        let Fixture { mut svc, now, .. } = fixture();
        svc.store.insert(Profile {
            id: String::new(),
            name: "Old guest".to_owned(),
            avatar: "#5a6478".to_owned(),
            role: Role::Guest,
            pin_hash: None,
        });
        svc.store.save().unwrap();
        let id = svc
            .profiles()
            .iter()
            .find(|p| p.role == Role::Guest)
            .unwrap()
            .id
            .clone();
        assert_eq!(svc.switch_to(&id, "", now).status, Status::Ok);
        assert_eq!(
            svc.rename_profile("p1", "1234", &id, "Visitor", now).status,
            Status::Ok
        );
        assert_eq!(
            svc.profiles().iter().find(|p| p.id == id).unwrap().name,
            "Visitor"
        );
        assert_eq!(svc.switch_to("p1", "1234", now).status, Status::Ok);
        assert_eq!(
            svc.delete_profile("p1", "1234", &id, now).status,
            Status::Ok
        );
        assert!(svc.profiles().iter().all(|p| p.id != id));
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

    type Shared<T> = std::sync::Arc<std::sync::Mutex<T>>;

    /// Fake accounts: records the useradd arguments of every create, every removal, and answers
    /// `id_in_use` from a set of taken ids.
    #[derive(Clone, Default)]
    struct Recording {
        removed: Shared<Vec<String>>,
        /// (id, uid) of every guest removal asked for.
        removed_guests: Shared<Vec<(String, u32)>>,
        /// `useradd_args` of every create.
        created: Shared<Vec<Vec<String>>>,
        in_use: Shared<Vec<u32>>,
        fail: bool,
        fail_create: Shared<bool>,
        fail_remove_guest: Shared<bool>,
        /// When set, every create reads this store file and notes whether it already lists the
        /// new user's id as a guest.
        probe: Shared<Option<std::path::PathBuf>>,
        recorded_at_create: Shared<Vec<bool>>,
    }

    impl Recording {
        fn guest_uids(&self) -> Vec<u32> {
            self.created
                .lock()
                .unwrap()
                .iter()
                .filter_map(|args| {
                    let at = args.iter().position(|a| a == "--uid")?;
                    args[at + 1].parse().ok()
                })
                .collect()
        }
    }

    impl Accounts for Recording {
        fn create(&self, profile_id: &str, kind: AccountKind) -> std::io::Result<()> {
            self.created
                .lock()
                .unwrap()
                .push(crate::accounts::useradd_args(profile_id, kind));
            if let Some(path) = self.probe.lock().unwrap().clone() {
                let store = Store::open(path).unwrap();
                let listed = store.guests().iter().any(|g| g.id == profile_id);
                self.recorded_at_create.lock().unwrap().push(listed);
            }
            if *self.fail_create.lock().unwrap() {
                return Err(std::io::Error::other("useradd failed"));
            }
            Ok(())
        }
        fn remove(&self, profile_id: &str) -> std::io::Result<()> {
            if self.fail {
                return Err(std::io::Error::other("userdel failed"));
            }
            self.removed.lock().unwrap().push(profile_id.to_owned());
            Ok(())
        }
        fn remove_guest(&self, profile_id: &str, uid: u32) -> std::io::Result<()> {
            if *self.fail_remove_guest.lock().unwrap() {
                return Err(std::io::Error::other("userdel failed"));
            }
            self.removed_guests
                .lock()
                .unwrap()
                .push((profile_id.to_owned(), uid));
            Ok(())
        }
        fn id_in_use(&self, id: u32) -> std::io::Result<bool> {
            Ok(self.in_use.lock().unwrap().contains(&id))
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
    fn verify_admin_rules() {
        let accounts = Recording::default();
        let (_dir, mut svc, now) = recording_fixture(accounts);
        assert_eq!(svc.verify_admin("p1", "1234", now).status, Status::Ok);
        assert_eq!(
            svc.verify_admin("p2", "", now).status,
            Status::NotAllowed,
            "a standard profile is not an admin"
        );
        assert_eq!(
            svc.verify_admin("nope", "1234", now).status,
            Status::NotAllowed
        );
        let o = svc.verify_admin("p1", "0000", now);
        assert_eq!(
            (o.status, o.attempts_left),
            (Status::WrongPin, FREE_ATTEMPTS - 1)
        );
        assert_eq!(svc.verify_admin("p1", "1234", now).status, Status::Ok);
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

    // ---- RUY-125: VerifyPin and temporary guests ----

    /// The recording fixture with p1 (admin, PIN 1234) signed in.
    fn signed_in(accounts: Recording) -> (tempfile::TempDir, ProfileService<Recording>, Instant) {
        let (dir, mut svc, now) = recording_fixture(accounts);
        assert_eq!(svc.switch_to("p1", "1234", now).status, Status::Ok);
        (dir, svc, now)
    }

    fn guest_numbers(svc: &ProfileService<Recording>) -> Vec<u32> {
        svc.guests().iter().map(|g| g.number).collect()
    }

    #[test]
    fn verify_pin_checks_and_never_signs_in() {
        let (_dir, mut svc, now) = recording_fixture(Recording::default());
        assert_eq!(svc.switch_to("p2", "", now).status, Status::Ok);
        let o = svc.verify_pin("p1", "1234", now);
        assert_eq!((o.status, o.attempts_left), (Status::Ok, 0));
        assert_eq!(svc.active(), Some("p2"), "the right PIN does not switch");
        let o = svc.verify_pin("p1", "0000", now);
        assert_eq!(
            (o.status, o.attempts_left),
            (Status::WrongPin, FREE_ATTEMPTS - 1)
        );
        let o = svc.verify_pin("p1", "", now);
        assert_eq!(
            (o.status, o.attempts_left),
            (Status::PinRequired, FREE_ATTEMPTS - 1)
        );
        assert_eq!(svc.verify_pin("p2", "", now).status, Status::Ok, "no PIN");
        assert_eq!(
            svc.verify_pin("nope", "", now).status,
            Status::UnknownProfile
        );
        assert_eq!(svc.active(), Some("p2"), "VerifyPin never switches");
    }

    #[test]
    fn verify_pin_shares_the_lockout_with_switch_to() {
        let (_dir, mut svc, now) = recording_fixture(Recording::default());
        for _ in 1..FREE_ATTEMPTS {
            assert_eq!(svc.verify_pin("p1", "0000", now).status, Status::WrongPin);
        }
        let o = svc.verify_pin("p1", "0000", now);
        assert_eq!(
            (o.status, o.retry_after),
            (Status::LockedOut, FIRST_LOCKOUT)
        );
        assert_eq!(svc.switch_to("p1", "1234", now).status, Status::LockedOut);
        assert_eq!(svc.verify_pin("p1", "1234", now).status, Status::LockedOut);
        assert_eq!(svc.active(), None);
    }

    #[test]
    fn guests_are_numbered_lowest_free_and_capped_at_three() {
        let (_dir, mut svc, _now) = signed_in(Recording::default());
        let mut ids = Vec::new();
        for expected in 1..=MAX_GUESTS {
            let g = svc.create_guest();
            assert_eq!((g.status, g.number), (Status::Ok, expected));
            ids.push(g.id);
        }
        assert_eq!(ids, ["p3", "p4", "p5"], "ids come from the profile counter");
        assert_eq!(svc.create_guest(), GuestOutcome::of(Status::NotAllowed));
        assert_eq!(svc.remove_guest("p3"), Status::Ok);
        assert_eq!(guest_numbers(&svc), [2, 3]);
        let g = svc.create_guest();
        assert_eq!((g.status, g.id.as_str(), g.number), (Status::Ok, "p6", 1));
        assert_eq!(guest_numbers(&svc), [1, 2, 3]);
        // Avatars come from the CreateProfile palette.
        assert!(svc
            .guests()
            .iter()
            .all(|g| AVATAR_COLOURS.contains(&g.avatar.as_str())));
    }

    #[test]
    fn a_guest_needs_a_signed_in_profile() {
        let (_dir, mut svc, _now) = recording_fixture(Recording::default());
        assert_eq!(svc.create_guest(), GuestOutcome::of(Status::NotAllowed));
        assert!(svc.guests().is_empty());
    }

    #[test]
    fn guests_are_not_profiles_and_only_join() {
        let (_dir, mut svc, now) = signed_in(Recording::default());
        let g = svc.create_guest();
        assert_eq!(g.status, Status::Ok);
        let ids: Vec<_> = svc.profiles().iter().map(|p| p.id.as_str()).collect();
        assert_eq!(ids, ["p1", "p2"], "ListProfiles never shows a guest");
        let id = g.id.as_str();
        assert_eq!(svc.switch_to(id, "", now).status, Status::NotAllowed);
        assert_eq!(svc.verify_pin(id, "", now).status, Status::NotAllowed);
        assert_eq!(svc.set_pin(id, "", "4321", now).status, Status::NotAllowed);
        assert_eq!(
            svc.rename_profile("p1", "1234", id, "Bob", now).status,
            Status::NotAllowed
        );
        assert_eq!(
            svc.rename_profile(id, "", id, "Bob", now).status,
            Status::NotAllowed
        );
        assert_eq!(
            svc.delete_profile("p1", "1234", id, now).status,
            Status::NotAllowed
        );
        assert_eq!(svc.active(), Some("p1"));
        assert_eq!(svc.guests().len(), 1, "nothing removed the guest");
    }

    #[test]
    fn remove_guest_never_removes_a_profile() {
        let accounts = Recording::default();
        let (_dir, mut svc, _now) = signed_in(accounts.clone());
        assert_eq!(svc.remove_guest("p2"), Status::UnknownProfile);
        assert_eq!(svc.remove_guest("nope"), Status::UnknownProfile);
        assert_eq!(svc.profiles().len(), 2);
        assert!(accounts.removed.lock().unwrap().is_empty());
        assert!(accounts.removed_guests.lock().unwrap().is_empty());
    }

    #[test]
    fn remove_guest_wipes_the_user_and_a_failure_keeps_the_guest() {
        let accounts = Recording::default();
        let (dir, mut svc, _now) = signed_in(accounts.clone());
        let g = svc.create_guest();
        *accounts.fail_remove_guest.lock().unwrap() = true;
        assert_eq!(svc.remove_guest(&g.id), Status::Failed);
        assert_eq!(svc.guests().len(), 1);
        *accounts.fail_remove_guest.lock().unwrap() = false;
        assert_eq!(svc.remove_guest(&g.id), Status::Ok);
        assert_eq!(
            *accounts.removed_guests.lock().unwrap(),
            vec![(g.id.clone(), 50000)]
        );
        assert!(svc.guests().is_empty());
        let store = Store::open(dir.path().join("profiles.toml")).unwrap();
        assert!(store.guests().is_empty(), "the removal is saved");
    }

    #[test]
    fn lock_and_a_profile_change_wipe_every_guest() {
        let accounts = Recording::default();
        let (dir, mut svc, now) = signed_in(accounts.clone());
        svc.create_guest();
        svc.create_guest();
        // Signing the same profile in again is not a session change.
        assert_eq!(svc.switch_to("p1", "1234", now).status, Status::Ok);
        assert_eq!(svc.guests().len(), 2);
        // A failed switch changes nothing either.
        assert_eq!(svc.switch_to("p1", "0000", now).status, Status::WrongPin);
        assert_eq!(svc.guests().len(), 2);
        assert_eq!(svc.switch_to("p2", "", now).status, Status::Ok);
        assert!(svc.guests().is_empty(), "a switch ends the session");
        assert_eq!(accounts.removed_guests.lock().unwrap().len(), 2);

        svc.create_guest();
        svc.lock();
        assert!(svc.guests().is_empty(), "Lock ends the session");
        assert_eq!(accounts.removed_guests.lock().unwrap().len(), 3);
        let store = Store::open(dir.path().join("profiles.toml")).unwrap();
        assert!(store.guests().is_empty());
    }

    #[test]
    fn a_restart_wipes_every_guest() {
        let accounts = Recording::default();
        let (dir, mut svc, _now) = signed_in(accounts.clone());
        svc.create_guest();
        svc.create_guest();
        drop(svc); // a crash: no Lock
        let store = Store::open(dir.path().join("profiles.toml")).unwrap();
        assert_eq!(store.guests().len(), 2, "the guests were persisted");
        let again = ProfileService::new(store, accounts.clone());
        assert!(again.guests().is_empty());
        let removed: Vec<_> = accounts
            .removed_guests
            .lock()
            .unwrap()
            .iter()
            .map(|(id, _)| id.clone())
            .collect();
        assert_eq!(removed, ["p3", "p4"]);
        let store = Store::open(dir.path().join("profiles.toml")).unwrap();
        assert!(store.guests().is_empty());
    }

    #[test]
    fn guest_uids_go_up_and_are_never_reused() {
        let accounts = Recording::default();
        let (dir, mut svc, now) = signed_in(accounts.clone());
        let a = svc.create_guest();
        let b = svc.create_guest();
        assert_eq!(svc.remove_guest(&b.id), Status::Ok);
        assert_eq!(svc.remove_guest(&a.id), Status::Ok);
        svc.create_guest();
        svc.lock();
        // A restart reads the counter back.
        drop(svc);
        let store = Store::open(dir.path().join("profiles.toml")).unwrap();
        let mut svc = ProfileService::new(store, accounts.clone());
        assert_eq!(svc.switch_to("p1", "1234", now).status, Status::Ok);
        svc.create_guest();
        assert_eq!(accounts.guest_uids(), [50000, 50001, 50002, 50003]);
    }

    #[test]
    fn a_uid_in_use_is_skipped_and_a_failed_create_burns_its_uid() {
        let accounts = Recording::default();
        accounts
            .in_use
            .lock()
            .unwrap()
            .extend([50000, 50001, 50003]);
        let (_dir, mut svc, _now) = signed_in(accounts.clone());
        let g = svc.create_guest();
        assert_eq!(g.status, Status::Ok);
        assert_eq!(svc.guests()[0].uid, 50002);
        *accounts.fail_create.lock().unwrap() = true;
        let failed = svc.create_guest();
        assert_eq!(failed, GuestOutcome::of(Status::Failed));
        assert_eq!(svc.guests().len(), 1, "no record of a failed guest");
        assert_eq!(
            accounts.removed_guests.lock().unwrap().last(),
            Some(&("p4".to_owned(), 50004)),
            "the half-made user is removed"
        );
        *accounts.fail_create.lock().unwrap() = false;
        let g = svc.create_guest();
        assert_eq!((g.status, g.id.as_str()), (Status::Ok, "p5"));
        assert_eq!(accounts.guest_uids(), [50002, 50004, 50005]);
    }

    #[test]
    fn the_guest_record_is_saved_before_useradd_and_a_restart_wipes_a_half_made_user() {
        let accounts = Recording::default();
        let (dir, mut svc, _now) = signed_in(accounts.clone());
        *accounts.probe.lock().unwrap() = Some(dir.path().join("profiles.toml"));
        // useradd fails and the cleanup fails too: as after a crash, only the record is left.
        *accounts.fail_create.lock().unwrap() = true;
        *accounts.fail_remove_guest.lock().unwrap() = true;
        let before: Vec<String> = svc.guests().iter().map(|g| g.id.clone()).collect();
        assert_eq!(svc.create_guest(), GuestOutcome::of(Status::Failed));
        assert_eq!(*accounts.recorded_at_create.lock().unwrap(), [true]);
        // RUY-652: the guest stays listed, so the D-Bus adapter must signal the change.
        let after: Vec<String> = svc.guests().iter().map(|g| g.id.clone()).collect();
        assert_eq!(after.len(), 1, "the half-made guest is listed");
        assert!(create_guest_changed(Status::Failed, &before, &after));
        assert!(!create_guest_changed(Status::Failed, &before, &before));
        drop(svc);
        let store = Store::open(dir.path().join("profiles.toml")).unwrap();
        assert_eq!(store.guests().len(), 1, "the record survived the failure");
        *accounts.fail_create.lock().unwrap() = false;
        *accounts.fail_remove_guest.lock().unwrap() = false;
        let again = ProfileService::new(store, accounts.clone());
        assert!(again.guests().is_empty());
        assert_eq!(
            *accounts.removed_guests.lock().unwrap(),
            vec![("p3".to_owned(), 50000)],
            "the start-up wipe removes the half-made user"
        );
    }

    #[test]
    fn a_wipe_that_failed_during_a_switch_is_retried_at_the_next_lock() {
        let accounts = Recording::default();
        let (_dir, mut svc, now) = signed_in(accounts.clone());
        svc.create_guest();
        *accounts.fail_remove_guest.lock().unwrap() = true;
        assert_eq!(svc.switch_to("p2", "", now).status, Status::Ok);
        assert_eq!(svc.guests().len(), 1, "the guest could not be wiped yet");
        assert!(accounts.removed_guests.lock().unwrap().is_empty());
        *accounts.fail_remove_guest.lock().unwrap() = false;
        svc.lock();
        assert!(svc.guests().is_empty());
        assert_eq!(accounts.removed_guests.lock().unwrap().len(), 1);
    }

    #[test]
    fn the_guest_range_runs_out() {
        let accounts = Recording::default();
        let (dir, svc, now) = signed_in(accounts.clone());
        drop(svc);
        // A store whose counter is at the last guest uid.
        let path = dir.path().join("profiles.toml");
        let text = std::fs::read_to_string(&path).unwrap();
        std::fs::write(&path, format!("next_guest_uid = 59999\n{text}")).unwrap();
        let store = Store::open(&path).unwrap();
        let mut svc = ProfileService::new(store, accounts.clone());
        svc.switch_to("p1", "1234", now);
        assert_eq!(svc.create_guest().status, Status::Ok);
        assert_eq!(svc.create_guest(), GuestOutcome::of(Status::Full));
        assert_eq!(accounts.guest_uids(), [59999]);
    }

    #[test]
    fn useradd_gets_a_guest_uid_for_a_guest_and_a_cap_for_a_profile() {
        let accounts = Recording::default();
        let (_dir, mut svc, now) = signed_in(accounts.clone());
        svc.create_guest();
        svc.create_profile("p1", "1234", "Bo", "standard", "", now);
        let created = accounts.created.lock().unwrap().clone();
        // p1 and p2 (the fixture), the guest p3, the profile p4.
        assert_eq!(created.len(), 4);
        for args in [&created[0], &created[1], &created[3]] {
            let joined = args.join(" ");
            assert!(joined.contains("-K UID_MAX=49999"), "{joined}");
            assert!(!joined.contains("--uid"), "{joined}");
        }
        let guest = created[2].join(" ");
        assert!(guest.contains("--uid 50000"), "{guest}");
        assert!(guest.contains("RuyaOS profile (guest)"), "{guest}");
        assert!(!guest.contains("UID_MAX"), "{guest}");
        assert!(
            guest.contains("-K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0"),
            "{guest}"
        );
        for args in [&created[0], &created[3]] {
            assert!(
                !args.join(" ").contains("SUB_"),
                "profiles keep their subid range"
            );
        }
    }

    #[test]
    fn verify_pin_journal_line_never_has_the_pin() {
        let (_dir, mut svc, now) = recording_fixture(Recording::default());
        let o = svc.verify_pin("p1", "9876", now);
        let line = verify_line("p1", &o);
        assert_eq!(line, "ruya-profiles: VerifyPin p1 -> wrong-pin");
        assert!(!line.contains("9876"));
    }
}
