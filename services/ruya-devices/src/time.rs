//! The console's time zone (org.ruyaos.Devices1.Time, T-213). systemd-timedated keeps the zone
//! (`/etc/localtime`) and the NTP state; the rules here are who may change it, which names are
//! valid, and when `TimezoneChanged` is due. Pure and tested on any host; the timedated side is
//! `timedate.rs`.

use std::sync::{Mutex, MutexGuard};

/// The zone reported when timedated has none (no `/etc/localtime`).
pub const DEFAULT_ZONE: &str = "UTC";

/// The contract's status strings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    Invalid,
    Forbidden,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::Invalid => "invalid",
            Status::Forbidden => "forbidden",
            Status::Failed => "failed",
        }
    }
}

/// What Profiles1 says about the active profile, as far as the zone rule cares.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProfileState {
    /// Profiles1 did not answer: fail closed.
    Unknown,
    /// No profile exists yet: the first-boot setup is running.
    NoProfiles,
    /// Profiles exist but nobody is signed in (the picker).
    NobodyActive,
    /// A profile is active.
    Active { admin: bool },
}

/// Who may set the zone: root; and the user the service runs as (the shell) while the active
/// profile is an admin, or while no profile exists yet (setup runs before any profile does). Fails
/// closed: an unknown caller or an unanswered Profiles1 is a refusal. The bus policy already lets
/// no one else call at all; this is the service's own check.
pub fn caller_may_set(caller: Option<u32>, own: Option<u32>, profiles: ProfileState) -> bool {
    match (caller, own) {
        (Some(0), _) => true,
        (Some(c), Some(o)) if c == o => match profiles {
            ProfileState::NoProfiles => true,
            ProfileState::Active { admin } => admin,
            ProfileState::Unknown | ProfileState::NobodyActive => false,
        },
        _ => false,
    }
}

/// Whether `name` can be an IANA zone name at all: 1 to 64 ASCII letters, digits and `/ _ - +`,
/// no leading slash, no `..` and no empty path part. The real test is membership in the list; this
/// keeps anything else away from timedated (and from the log) first.
pub fn plausible_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && !name.starts_with('/')
        && !name.ends_with('/')
        && !name.contains("//")
        && !name.contains("..")
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'_' | b'-' | b'+'))
}

/// systemd-timedated, or a fake.
pub trait Timedate: Send + Sync {
    /// The `Timezone` property.
    fn timezone(&self) -> Result<String, String>;
    /// The `NTPSynchronized` property.
    fn ntp_synchronised(&self) -> Result<bool, String>;
    /// `ListTimezones`.
    fn list_timezones(&self) -> Result<Vec<String>, String>;
    /// `SetTimezone(name, interactive = false)`.
    fn set_timezone(&self, name: &str) -> Result<(), String>;
}

/// What a read or a call changed, so the adapter knows which signals are due.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Changes {
    pub timezone: bool,
    pub ntp: bool,
}

#[derive(Debug)]
struct State {
    zone: String,
    ntp: bool,
    zones: Option<Vec<String>>,
}

pub struct Time<T: Timedate> {
    timedate: T,
    state: Mutex<State>,
}

impl<T: Timedate> Time<T> {
    pub fn new(timedate: T) -> Self {
        Time {
            timedate,
            state: Mutex::new(State {
                zone: DEFAULT_ZONE.to_owned(),
                ntp: false,
                zones: None,
            }),
        }
    }

    fn state(&self) -> MutexGuard<'_, State> {
        // A poisoned lock only means another call panicked; the state is plain data.
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Reads timedated again and says what differs from the last read.
    pub fn refresh(&self) -> Result<Changes, String> {
        let raw = self.timedate.timezone()?;
        let zone = if raw.trim().is_empty() || raw == "n/a" {
            DEFAULT_ZONE.to_owned()
        } else {
            raw
        };
        let ntp = self.timedate.ntp_synchronised()?;
        let mut state = self.state();
        let changes = Changes {
            timezone: state.zone != zone,
            ntp: state.ntp != ntp,
        };
        state.zone = zone;
        state.ntp = ntp;
        Ok(changes)
    }

    pub fn timezone(&self) -> String {
        self.state().zone.clone()
    }

    pub fn ntp_synchronised(&self) -> bool {
        self.state().ntp
    }

    /// The zone names, read once from timedated and kept (the tzdata of a running image does not
    /// change). An error is not cached.
    pub fn list(&self) -> Result<Vec<String>, String> {
        if let Some(zones) = &self.state().zones {
            return Ok(zones.clone());
        }
        let mut zones: Vec<String> = self
            .timedate
            .list_timezones()?
            .into_iter()
            .filter(|z| plausible_name(z))
            .collect();
        zones.sort();
        zones.dedup();
        self.state().zones = Some(zones.clone());
        Ok(zones)
    }

    /// Sets the zone. `allowed` is the caller rule's verdict (`caller_may_set`, decided by the
    /// adapter). The order is fixed: a refused caller learns nothing about names.
    pub fn set(&self, name: &str, allowed: bool) -> (Status, Changes) {
        let nothing = Changes::default();
        if !allowed {
            return (Status::Forbidden, nothing);
        }
        if !plausible_name(name) {
            return (Status::Invalid, nothing);
        }
        match self.list() {
            Ok(zones) if zones.iter().any(|z| z == name) => {}
            Ok(_) => return (Status::Invalid, nothing),
            Err(err) => {
                eprintln!("ruya-devices: reading the time zones failed: {err}");
                return (Status::Failed, nothing);
            }
        }
        if self.timezone() == name {
            return (Status::Ok, nothing);
        }
        if let Err(err) = self.timedate.set_timezone(name) {
            eprintln!("ruya-devices: setting the time zone failed: {err}");
            return (Status::Failed, nothing);
        }
        match self.refresh() {
            Ok(changes) => (Status::Ok, changes),
            Err(err) => {
                eprintln!("ruya-devices: reading the time zone failed: {err}");
                // The call went through; take it over so the answer matches what happened.
                self.state().zone = name.to_owned();
                (
                    Status::Ok,
                    Changes {
                        timezone: true,
                        ntp: false,
                    },
                )
            }
        }
    }
}

/// A scripted timedated for tests and `--session` development.
pub struct FakeTimedate {
    zone: Mutex<String>,
    ntp: Mutex<bool>,
    zones: Vec<String>,
    refuse: Mutex<bool>,
    calls: Mutex<Vec<String>>,
}

impl FakeTimedate {
    pub fn new(zone: &str, zones: &[&str]) -> Self {
        FakeTimedate {
            zone: Mutex::new(zone.to_owned()),
            ntp: Mutex::new(true),
            zones: zones.iter().map(|z| (*z).to_owned()).collect(),
            refuse: Mutex::new(false),
            calls: Mutex::new(Vec::new()),
        }
    }

    /// A believable list for `--session`.
    pub fn with_zones() -> Self {
        FakeTimedate::new(
            DEFAULT_ZONE,
            &[
                "Africa/Cairo",
                "America/Argentina/Buenos_Aires",
                "America/New_York",
                "Asia/Tokyo",
                "Europe/Istanbul",
                "Europe/London",
                "Pacific/Auckland",
                "UTC",
            ],
        )
    }

    /// Someone else (timedatectl) changed the zone.
    pub fn set_outside(&self, zone: &str) {
        *self.zone.lock().unwrap_or_else(|e| e.into_inner()) = zone.to_owned();
    }

    pub fn set_ntp(&self, synchronised: bool) {
        *self.ntp.lock().unwrap_or_else(|e| e.into_inner()) = synchronised;
    }

    /// timedated (or polkit) refuses the next calls.
    pub fn refuse(&self, refuse: bool) {
        *self.refuse.lock().unwrap_or_else(|e| e.into_inner()) = refuse;
    }

    /// The names `set_timezone` was called with.
    pub fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

impl Timedate for FakeTimedate {
    fn timezone(&self) -> Result<String, String> {
        Ok(self.zone.lock().unwrap_or_else(|e| e.into_inner()).clone())
    }

    fn ntp_synchronised(&self) -> Result<bool, String> {
        Ok(*self.ntp.lock().unwrap_or_else(|e| e.into_inner()))
    }

    fn list_timezones(&self) -> Result<Vec<String>, String> {
        Ok(self.zones.clone())
    }

    fn set_timezone(&self, name: &str) -> Result<(), String> {
        self.calls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(name.to_owned());
        if *self.refuse.lock().unwrap_or_else(|e| e.into_inner()) {
            return Err("Access denied".to_owned());
        }
        *self.zone.lock().unwrap_or_else(|e| e.into_inner()) = name.to_owned();
        Ok(())
    }
}

impl<T: Timedate + ?Sized> Timedate for Box<T> {
    fn timezone(&self) -> Result<String, String> {
        (**self).timezone()
    }
    fn ntp_synchronised(&self) -> Result<bool, String> {
        (**self).ntp_synchronised()
    }
    fn list_timezones(&self) -> Result<Vec<String>, String> {
        (**self).list_timezones()
    }
    fn set_timezone(&self, name: &str) -> Result<(), String> {
        (**self).set_timezone(name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROOT: Option<u32> = Some(0);
    const SHELL: Option<u32> = Some(1000);
    const OTHER: Option<u32> = Some(1001);

    fn time() -> Time<FakeTimedate> {
        Time::new(FakeTimedate::with_zones())
    }

    #[test]
    fn root_may_always_set() {
        for p in [
            ProfileState::Unknown,
            ProfileState::NoProfiles,
            ProfileState::NobodyActive,
            ProfileState::Active { admin: false },
        ] {
            assert!(caller_may_set(ROOT, SHELL, p), "root with {p:?}");
        }
    }

    #[test]
    fn the_shell_may_set_for_an_admin_or_before_any_profile_exists() {
        assert!(caller_may_set(
            SHELL,
            SHELL,
            ProfileState::Active { admin: true }
        ));
        assert!(caller_may_set(SHELL, SHELL, ProfileState::NoProfiles));
    }

    #[test]
    fn the_shell_may_not_set_for_anyone_else() {
        assert!(!caller_may_set(
            SHELL,
            SHELL,
            ProfileState::Active { admin: false }
        ));
        assert!(!caller_may_set(SHELL, SHELL, ProfileState::NobodyActive));
        assert!(
            !caller_may_set(SHELL, SHELL, ProfileState::Unknown),
            "fails closed when Profiles1 does not answer"
        );
    }

    #[test]
    fn another_user_or_an_unknown_caller_may_not_set() {
        for p in [
            ProfileState::NoProfiles,
            ProfileState::Active { admin: true },
        ] {
            assert!(!caller_may_set(OTHER, SHELL, p), "another user, {p:?}");
            assert!(!caller_may_set(None, SHELL, p), "unknown caller, {p:?}");
            assert!(!caller_may_set(SHELL, None, p), "unknown own user, {p:?}");
        }
    }

    #[test]
    fn names_that_cannot_be_zones_are_not_plausible() {
        for good in [
            "UTC",
            "Europe/Istanbul",
            "America/Argentina/Buenos_Aires",
            "Etc/GMT+3",
        ] {
            assert!(plausible_name(good), "{good}");
        }
        for bad in [
            "",
            "/etc/passwd",
            "../../etc/passwd",
            "Europe/",
            "Europe//Istanbul",
            "Europe/Istanbul\n",
            "Europe/Is tanbul",
            "Europe/İstanbul",
            &"a".repeat(65),
        ] {
            assert!(!plausible_name(bad), "{bad:?}");
        }
    }

    #[test]
    fn a_fresh_service_says_utc_until_it_has_read_timedated() {
        let t = time();
        assert_eq!(t.timezone(), "UTC");
        assert!(!t.ntp_synchronised());
        let changes = t.refresh().expect("fake reads");
        assert_eq!(
            changes,
            Changes {
                timezone: false,
                ntp: true
            }
        );
        assert!(t.ntp_synchronised());
    }

    #[test]
    fn no_zone_in_timedated_reads_as_utc() {
        let t = Time::new(FakeTimedate::new("", &["UTC"]));
        t.refresh().expect("fake reads");
        assert_eq!(t.timezone(), "UTC");
        let t = Time::new(FakeTimedate::new("n/a", &["UTC"]));
        t.refresh().expect("fake reads");
        assert_eq!(t.timezone(), "UTC");
    }

    #[test]
    fn the_list_is_sorted_and_keeps_only_plausible_names() {
        let t = Time::new(FakeTimedate::new(
            "UTC",
            &["Europe/London", "../x", "Asia/Tokyo", "UTC", "Asia/Tokyo"],
        ));
        assert_eq!(
            t.list().expect("fake lists"),
            ["Asia/Tokyo", "Europe/London", "UTC"]
        );
    }

    #[test]
    fn set_changes_the_zone_and_announces_it_once() {
        let t = time();
        t.refresh().expect("fake reads");
        let (status, changes) = t.set("Europe/Istanbul", true);
        assert_eq!(status, Status::Ok);
        assert!(changes.timezone);
        assert_eq!(t.timezone(), "Europe/Istanbul");
        assert_eq!(t.timedate.calls(), ["Europe/Istanbul"]);
        // The watcher reads the same change again: nothing new to announce.
        assert_eq!(t.refresh().expect("fake reads"), Changes::default());
    }

    #[test]
    fn setting_the_current_zone_is_ok_and_calls_nothing() {
        let t = time();
        t.set("Asia/Tokyo", true);
        let (status, changes) = t.set("Asia/Tokyo", true);
        assert_eq!(status, Status::Ok);
        assert_eq!(changes, Changes::default());
        assert_eq!(t.timedate.calls(), ["Asia/Tokyo"], "one call only");
    }

    #[test]
    fn an_unknown_or_malformed_name_is_invalid_and_never_reaches_timedated() {
        let t = time();
        for name in [
            "Mars/Olympus_Mons",
            "",
            "/etc/localtime",
            "europe/istanbul",
            "../UTC",
        ] {
            assert_eq!(t.set(name, true).0, Status::Invalid, "{name:?}");
        }
        assert!(t.timedate.calls().is_empty());
        assert_eq!(t.timezone(), "UTC");
    }

    #[test]
    fn a_refused_caller_is_forbidden_before_the_name_is_looked_at() {
        let t = time();
        assert_eq!(t.set("Asia/Tokyo", false).0, Status::Forbidden);
        assert_eq!(t.set("Mars/Olympus_Mons", false).0, Status::Forbidden);
        assert!(t.timedate.calls().is_empty());
        assert_eq!(t.timezone(), "UTC");
    }

    #[test]
    fn a_refusal_by_timedated_is_failed_and_changes_nothing() {
        let t = time();
        t.timedate.refuse(true);
        let (status, changes) = t.set("Asia/Tokyo", true);
        assert_eq!(status, Status::Failed);
        assert_eq!(changes, Changes::default());
        assert_eq!(t.timezone(), "UTC");
    }

    #[test]
    fn a_zone_set_from_outside_is_found_by_the_next_read() {
        let t = time();
        t.refresh().expect("fake reads");
        t.timedate.set_outside("Pacific/Auckland");
        assert_eq!(
            t.refresh().expect("fake reads"),
            Changes {
                timezone: true,
                ntp: false
            }
        );
        assert_eq!(t.timezone(), "Pacific/Auckland");
    }

    #[test]
    fn ntp_changes_are_announced() {
        let t = time();
        t.refresh().expect("fake reads");
        t.timedate.set_ntp(false);
        assert_eq!(
            t.refresh().expect("fake reads"),
            Changes {
                timezone: false,
                ntp: true
            }
        );
        assert!(!t.ntp_synchronised());
    }
}
