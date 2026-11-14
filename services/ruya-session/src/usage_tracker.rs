//! The live accounting of the play ledger (T-247). Pure: time comes in as `Instant` (the
//! monotonic clock, so a wall-clock change never alters a duration) and unix seconds (only for
//! labels: when a session began and ended, which local day a second belongs to); files sit behind
//! `UsageStore`.
//!
//! A second counts for an app when the shell says the profile is active (not idle, locked or
//! suspended), the app is the foreground app, and the report is fresh. Ticks arrive about once a
//! second; one tick counts at most `MAX_STEP`, so a stalled process or a suspend cannot count the
//! time it missed. A profile switch pauses the old profile's runs (they stay open, uncounted,
//! until the profile is back or the app exits).

use std::collections::{BTreeMap, HashMap};
use std::time::{Duration, Instant};

use crate::spawner::valid_profile_id;
use crate::usage::{
    day_of, format_day, parse_day, DayRow, EndReason, Ledger, SessionRecord, Zone, MIN_SESSION_SECS,
};
use crate::usage_store::UsageStore;

/// A running session is saved this often; a crash loses at most this much.
pub const HEARTBEAT: Duration = Duration::from_secs(30);
/// A presence report older than this counts as "unknown" (the shell is gone or stuck).
pub const PRESENCE_TTL: Duration = Duration::from_secs(75);
/// The most one tick counts.
pub const MAX_STEP: Duration = Duration::from_secs(5);
/// Running sessions per profile; more are not tracked.
pub const MAX_OPEN_PER_PROFILE: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Attention {
    Active,
    Idle,
    Locked,
    Suspended,
}

impl Attention {
    pub fn parse(s: &str) -> Option<Attention> {
        Some(match s {
            "active" => Attention::Active,
            "idle" => Attention::Idle,
            "locked" => Attention::Locked,
            "suspended" => Attention::Suspended,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone)]
struct Presence {
    profile: String,
    foreground: Option<String>,
    attention: Attention,
    at: Instant,
}

struct Open {
    instance: String,
    profile: String,
    app_id: String,
    version: String,
    key: String,
    start: i64,
    /// Milliseconds of foreground time per local day.
    ms: BTreeMap<i32, u64>,
    last_mark: Instant,
    last_beat: Instant,
    /// Time added since the last heartbeat or the last `UsageChanged`.
    dirty: bool,
    /// Why it ends, when something other than the exit says so (T-211: time limit, bedtime).
    reason: Option<EndReason>,
}

impl Open {
    fn days(&self) -> Vec<(i32, u32)> {
        self.ms
            .iter()
            .map(|(d, ms)| (*d, u32::try_from((ms + 500) / 1000).unwrap_or(u32::MAX)))
            .filter(|(_, s)| *s > 0)
            .collect()
    }

    fn snapshot(&self, end: i64, reason: EndReason, open: bool) -> SessionRecord {
        let days = self.days();
        SessionRecord {
            app_id: self.app_id.clone(),
            app_version: self.version.clone(),
            start: self.start,
            end,
            foreground_seconds: days.iter().map(|(_, s)| *s).sum(),
            reason,
            days,
            open,
        }
    }
}

/// An app that runs already when the service starts (adopted by the session core).
#[derive(Debug, Clone)]
pub struct LiveApp {
    pub instance: String,
    pub profile: String,
    pub app_id: String,
    pub version: String,
    /// When the app started, in unix seconds.
    pub started: i64,
}

/// The instance as it appears in a file name: `[A-Za-z0-9.-]`, at most 80 characters.
fn sanitize(instance: &str) -> String {
    instance
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '-') {
                c
            } else {
                '_'
            }
        })
        .take(80)
        .collect()
}

/// The instance part of a heartbeat key (`<start>-<instance>`).
fn key_instance(key: &str) -> Option<&str> {
    key.split_once('-').map(|(_, rest)| rest)
}

pub struct Tracker<S, Z> {
    store: S,
    zone: Z,
    ledgers: HashMap<String, Ledger>,
    open: Vec<Open>,
    presence: Option<Presence>,
    maintained_day: Option<i32>,
}

impl<S: UsageStore, Z: Zone> Tracker<S, Z> {
    pub fn new(store: S, zone: Z) -> Self {
        Tracker {
            store,
            zone,
            ledgers: HashMap::new(),
            open: Vec::new(),
            presence: None,
            maintained_day: None,
        }
    }

    pub fn store(&self) -> &S {
        &self.store
    }

    fn ledger(&mut self, profile: &str, unix: i64) -> Result<&mut Ledger, String> {
        if !self.ledgers.contains_key(profile) {
            let mut ledger = self.store.load(profile)?;
            let today = day_of(unix, &self.zone);
            if ledger.roll_up(today, unix) {
                self.store.rewrite(profile, &ledger)?;
            }
            self.ledgers.insert(profile.to_owned(), ledger);
        }
        self.ledgers
            .get_mut(profile)
            .ok_or_else(|| "ledger vanished".to_owned())
    }

    /// Start-up, nothing running: runs that never ended (crash, power cut) end at their last
    /// heartbeat. Returns the profiles whose ledger changed.
    pub fn recover(&mut self, unix: i64) -> Vec<String> {
        self.recover_with(unix, &[], Instant::now())
    }

    /// Start-up when this service restarted but the apps did not: a leftover heartbeat of an app
    /// that is still `live` is not an ended run. It is taken over where it left off (the time it
    /// had, its start, its file, so the end writes the one row and no second one), and a live app
    /// with no heartbeat starts a run now, dated from when the app started. Every other leftover
    /// ends at its last heartbeat as in `recover`. Returns the profiles whose ledger changed.
    pub fn recover_with(&mut self, unix: i64, live: &[LiveApp], now: Instant) -> Vec<String> {
        let mut changed = Vec::new();
        let mut taken = vec![false; live.len()];
        for (profile, key, mut s) in self.store.list_open() {
            let found = live.iter().position(|l| {
                l.profile == profile
                    && l.app_id == s.app_id
                    && key_instance(&key) == Some(sanitize(&l.instance).as_str())
            });
            if let Some(at) = found.filter(|&at| !taken[at]) {
                taken[at] = true;
                if !self.open.iter().any(|o| o.instance == live[at].instance) {
                    self.open.push(Open {
                        instance: live[at].instance.clone(),
                        profile,
                        app_id: s.app_id.clone(),
                        version: s.app_version.clone(),
                        key,
                        start: s.start,
                        ms: s
                            .days
                            .iter()
                            .map(|(d, secs)| (*d, u64::from(*secs) * 1000))
                            .collect(),
                        last_mark: now,
                        last_beat: now,
                        dirty: false,
                        reason: None,
                    });
                }
                continue;
            }
            s.open = false;
            s.reason = EndReason::Crashed;
            self.store.remove_open(&profile, &key);
            if s.foreground_seconds >= MIN_SESSION_SECS && self.add_session(&profile, s, unix) {
                changed.push(profile);
            }
        }
        for (l, taken) in live.iter().zip(taken) {
            if !taken {
                self.app_started(
                    &l.instance,
                    &l.profile,
                    &l.app_id,
                    &l.version,
                    now,
                    l.started,
                );
            }
        }
        changed
    }

    fn add_session(&mut self, profile: &str, s: SessionRecord, unix: i64) -> bool {
        let store_result = match self.ledger(profile, unix) {
            Ok(ledger) => {
                let rolled = ledger.add(s.clone());
                if rolled {
                    let copy = ledger.clone();
                    self.store.rewrite(profile, &copy)
                } else {
                    self.store.append(profile, &s)
                }
            }
            Err(e) => Err(e),
        };
        match store_result {
            Ok(()) => true,
            Err(e) => {
                eprintln!("ruya-session: saving a play session of {profile} failed: {e}");
                false
            }
        }
    }

    /// An app reached `running`. The version is the one at this moment: an update while it runs
    /// does not split the session.
    pub fn app_started(
        &mut self,
        instance: &str,
        profile: &str,
        app_id: &str,
        version: &str,
        now: Instant,
        unix: i64,
    ) {
        if !valid_profile_id(profile)
            || self.open.iter().any(|o| o.instance == instance)
            || self.open.iter().filter(|o| o.profile == profile).count() >= MAX_OPEN_PER_PROFILE
        {
            return;
        }
        let sanitized = sanitize(instance);
        self.open.push(Open {
            instance: instance.to_owned(),
            profile: profile.to_owned(),
            app_id: app_id.to_owned(),
            version: version.to_owned(),
            key: format!("{unix}-{sanitized}"),
            start: unix,
            ms: BTreeMap::new(),
            last_mark: now,
            last_beat: now,
            dirty: false,
            reason: None,
        });
    }

    /// T-211 says why the next exit of this instance is not a plain `quit`.
    pub fn set_end_reason(&mut self, instance: &str, reason: EndReason) {
        if let Some(o) = self.open.iter_mut().find(|o| o.instance == instance) {
            o.reason = Some(reason);
        }
    }

    /// The instance ended. `exit` is the reason `AppExited` carried (`None` for a launch that
    /// never ran). Returns the profile whose ledger changed.
    pub fn app_exited(
        &mut self,
        instance: &str,
        exit: Option<EndReason>,
        now: Instant,
        unix: i64,
    ) -> Option<String> {
        self.accrue(now, unix);
        let at = self.open.iter().position(|o| o.instance == instance)?;
        let o = self.open.remove(at);
        let reason = o.reason.or(exit).unwrap_or(EndReason::Quit);
        self.finish(o, reason, unix)
    }

    fn finish(&mut self, o: Open, reason: EndReason, unix: i64) -> Option<String> {
        self.store.remove_open(&o.profile, &o.key);
        let s = o.snapshot(unix, reason, false);
        if s.foreground_seconds < MIN_SESSION_SECS {
            return None;
        }
        self.add_session(&o.profile, s, unix).then_some(o.profile)
    }

    /// The shell's report of who is in front. A profile switch pauses the previous profile's
    /// runs (RUY-569: a switch freezes its apps, signing back in resumes them): they stay open,
    /// do not accrue while their profile is away, and end at `app_exited` with its real reason.
    /// Returns the profiles whose ledger changed (none: nothing finishes here).
    pub fn presence(
        &mut self,
        profile: &str,
        foreground: Option<&str>,
        attention: Attention,
        now: Instant,
        unix: i64,
    ) -> Vec<String> {
        // What happened until now happened under the old state.
        self.accrue(now, unix);
        self.presence = Some(Presence {
            profile: profile.to_owned(),
            foreground: foreground.filter(|f| !f.is_empty()).map(str::to_owned),
            attention,
            at: now,
        });
        // A switch ends nothing: the old profile's runs stay open (their apps are frozen, not
        // stopped) and `counts` skips them while another profile is in front.
        Vec::new()
    }

    fn counts(&self, o: &Open, now: Instant) -> bool {
        self.presence.as_ref().is_some_and(|p| {
            p.attention == Attention::Active
                && p.profile == o.profile
                && p.foreground.as_deref() == Some(o.instance.as_str())
                && now.saturating_duration_since(p.at) <= PRESENCE_TTL
        })
    }

    fn accrue(&mut self, now: Instant, unix: i64) {
        // The time being counted is the second that just ended, not the next one.
        let day = day_of(unix - 1, &self.zone);
        for i in 0..self.open.len() {
            let dt = now.saturating_duration_since(self.open[i].last_mark);
            self.open[i].last_mark = now.max(self.open[i].last_mark);
            if dt.is_zero() || !self.counts(&self.open[i], now) {
                continue;
            }
            let ms = u64::try_from(dt.min(MAX_STEP).as_millis()).unwrap_or(0);
            let o = &mut self.open[i];
            *o.ms.entry(day).or_insert(0) += ms;
            o.dirty = true;
        }
    }

    /// About once a second. Counts, saves heartbeats, and does the daily upkeep. Returns the
    /// profiles whose open sessions grew since the last heartbeat (for `UsageChanged`).
    pub fn tick(&mut self, now: Instant, unix: i64) -> Vec<String> {
        self.accrue(now, unix);
        let mut changed = Vec::new();
        for i in 0..self.open.len() {
            if now.saturating_duration_since(self.open[i].last_beat) < HEARTBEAT {
                continue;
            }
            let o = &mut self.open[i];
            o.last_beat = now;
            if !o.dirty {
                continue;
            }
            o.dirty = false;
            let snap = o.snapshot(unix, EndReason::Crashed, true);
            let (profile, key) = (o.profile.clone(), o.key.clone());
            if snap.foreground_seconds >= MIN_SESSION_SECS {
                if let Err(e) = self.store.write_open(&profile, &key, &snap) {
                    eprintln!("ruya-session: saving a heartbeat for {profile} failed: {e}");
                }
            }
            if !changed.contains(&profile) {
                changed.push(profile);
            }
        }
        let today = day_of(unix, &self.zone);
        if self.maintained_day != Some(today) {
            self.maintained_day = Some(today);
            let profiles: Vec<String> = self.ledgers.keys().cloned().collect();
            for p in profiles {
                let Some(ledger) = self.ledgers.get_mut(&p) else {
                    continue;
                };
                if ledger.roll_up(today, unix) {
                    let copy = ledger.clone();
                    if let Err(e) = self.store.rewrite(&p, &copy) {
                        eprintln!("ruya-session: rolling up the ledger of {p} failed: {e}");
                    }
                    changed.push(p);
                }
            }
        }
        changed
    }

    fn open_records(&self, profile: &str, unix: i64) -> Vec<SessionRecord> {
        self.open
            .iter()
            .filter(|o| o.profile == profile)
            .map(|o| o.snapshot(unix, EndReason::Quit, true))
            .filter(|s| s.foreground_seconds >= MIN_SESSION_SECS)
            .collect()
    }

    /// `ListSessions`: newest first, running ones included.
    pub fn list(
        &mut self,
        profile: &str,
        since: i64,
        limit: usize,
        unix: i64,
    ) -> Result<Vec<SessionRecord>, String> {
        let open = self.open_records(profile, unix);
        Ok(self.ledger(profile, unix)?.list(since, limit, &open))
    }

    /// `GetTotals`: `from`/`to` are "YYYY-MM-DD" or "" (unbounded / today). Returns today's date
    /// and the rows; `Err("invalid")` for a bad date.
    pub fn totals(
        &mut self,
        profile: &str,
        from: &str,
        to: &str,
        unix: i64,
    ) -> Result<(String, Vec<DayRow>), String> {
        let from = if from.is_empty() {
            None
        } else {
            Some(parse_day(from).ok_or("invalid")?)
        };
        let to = if to.is_empty() {
            None
        } else {
            Some(parse_day(to).ok_or("invalid")?)
        };
        let today = day_of(unix, &self.zone);
        let open = self.open_records(profile, unix);
        let rows = self.ledger(profile, unix)?.totals(from, to, &open);
        Ok((format_day(today), rows))
    }

    /// `ClearHistory`: the ledger and the saved heartbeats go; running sessions start again
    /// from zero (what was already counted belongs to the history that was just cleared).
    pub fn clear(&mut self, profile: &str, unix: i64) {
        self.ledgers.remove(profile);
        self.store.remove_profile(profile);
        for o in self.open.iter_mut().filter(|o| o.profile == profile) {
            o.ms.clear();
            o.start = unix;
            o.dirty = false;
        }
    }

    /// Deletes the usage data of profiles that no longer exist.
    pub fn purge_except(&mut self, keep: &[String]) -> Vec<String> {
        let mut gone = Vec::new();
        for p in self.store.profiles() {
            if !keep.contains(&p) {
                self.store.remove_profile(&p);
                gone.push(p);
            }
        }
        self.ledgers.retain(|p, _| keep.contains(p));
        self.open.retain(|o| keep.contains(&o.profile));
        gone
    }
}

/// May the caller read this profile's history? Only the active profile's: an admin does not
/// browse another profile's play (`active` is `None` where there is no `Profiles1` to ask: the
/// development mode).
pub fn may_read(profile: &str, active: Option<&str>) -> bool {
    valid_profile_id(profile) && active.map_or(true, |a| a == profile)
}

/// How a `ClearHistory` call is authorised.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClearRoute {
    /// The profile is the active one: its own PIN was checked when it signed in.
    Own,
    /// Another profile's history: the admin PIN is checked with `Profiles1.VerifyAdmin`.
    Admin,
    NotAllowed,
}

pub fn clear_route(profile: &str, active: Option<&str>, admin_id: &str) -> ClearRoute {
    if admin_id.is_empty() {
        if may_read(profile, active) {
            ClearRoute::Own
        } else {
            ClearRoute::NotAllowed
        }
    } else {
        ClearRoute::Admin
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::usage::{days_from_civil, FixedZone, TableZone};
    use crate::usage_store::MemStore;

    const A: &str = "org.ruyaos.Racer";
    const B: &str = "org.ruyaos.Puzzle";
    const IA: &str = "unit-a";
    const IB: &str = "unit-b";
    /// 2026-11-07 12:00 UTC.
    fn t0() -> i64 {
        i64::from(days_from_civil(2026, 11, 7)) * 86_400 + 12 * 3600
    }

    /// A fake clock: the monotonic and the wall clock move together unless a test moves the wall.
    struct Clock {
        base: Instant,
        mono: u64,
        wall: i64,
    }

    impl Clock {
        fn new() -> Clock {
            Clock {
                base: Instant::now(),
                mono: 0,
                wall: t0(),
            }
        }
        fn now(&self) -> Instant {
            self.base + Duration::from_secs(self.mono)
        }
    }

    type T = Tracker<MemStore, FixedZone>;

    fn tracker() -> T {
        Tracker::new(MemStore::default(), FixedZone(0))
    }

    /// Runs `secs` seconds in one-second ticks; the shell re-reports every 20 s like the real one.
    fn run<Z: Zone>(
        t: &mut Tracker<MemStore, Z>,
        c: &mut Clock,
        secs: u64,
        profile: &str,
        fg: Option<&str>,
        att: Attention,
    ) {
        for i in 0..secs {
            if i % 20 == 0 {
                t.presence(profile, fg, att, c.now(), c.wall);
            }
            c.mono += 1;
            c.wall += 1;
            t.tick(c.now(), c.wall);
        }
    }

    fn start(t: &mut T, c: &Clock, instance: &str, profile: &str, app: &str) {
        t.app_started(instance, profile, app, "1.0", c.now(), c.wall);
    }

    fn quit(t: &mut T, c: &Clock, instance: &str) -> Option<String> {
        t.app_exited(instance, Some(EndReason::Quit), c.now(), c.wall)
    }

    fn sessions(t: &mut T, profile: &str, c: &Clock) -> Vec<SessionRecord> {
        t.list(profile, 0, 100, c.wall).unwrap_or_default()
    }

    #[test]
    fn only_the_foreground_app_counts_while_active() {
        let mut t = tracker();
        let mut c = Clock::new();
        start(&mut t, &c, IA, "p1", A);
        start(&mut t, &c, IB, "p1", B);
        run(&mut t, &mut c, 60, "p1", Some(IA), Attention::Active);
        run(&mut t, &mut c, 40, "p1", Some(IB), Attention::Active);
        run(&mut t, &mut c, 30, "p1", None, Attention::Active); // the shell itself in front
        assert_eq!(quit(&mut t, &c, IA).as_deref(), Some("p1"));
        assert_eq!(quit(&mut t, &c, IB).as_deref(), Some("p1"));
        let s = sessions(&mut t, "p1", &c);
        let by = |app: &str| {
            s.iter()
                .find(|x| x.app_id == app)
                .map(|x| x.foreground_seconds)
        };
        assert_eq!(by(A), Some(60));
        assert_eq!(by(B), Some(40));
    }

    #[test]
    fn idle_locked_and_suspended_time_is_not_counted() {
        let mut t = tracker();
        let mut c = Clock::new();
        start(&mut t, &c, IA, "p1", A);
        run(&mut t, &mut c, 100, "p1", Some(IA), Attention::Active);
        run(&mut t, &mut c, 600, "p1", Some(IA), Attention::Idle);
        run(&mut t, &mut c, 50, "p1", Some(IA), Attention::Locked);
        run(&mut t, &mut c, 70, "p1", Some(IA), Attention::Suspended);
        run(&mut t, &mut c, 20, "p1", Some(IA), Attention::Active);
        quit(&mut t, &c, IA);
        assert_eq!(sessions(&mut t, "p1", &c)[0].foreground_seconds, 120);
    }

    #[test]
    fn a_stale_report_counts_nothing_and_a_stall_counts_at_most_a_step() {
        let mut t = tracker();
        let mut c = Clock::new();
        start(&mut t, &c, IA, "p1", A);
        t.presence("p1", Some(IA), Attention::Active, c.now(), c.wall);
        // The shell dies: no more reports. 75 s are still believed, the rest is not.
        for _ in 0..200 {
            c.mono += 1;
            c.wall += 1;
            t.tick(c.now(), c.wall);
        }
        // The shell is back, then the process stalls for 40 s: that tick counts one step only.
        t.presence("p1", Some(IA), Attention::Active, c.now(), c.wall);
        c.mono += 40;
        c.wall += 40;
        t.tick(c.now(), c.wall);
        quit(&mut t, &c, IA);
        let s = sessions(&mut t, "p1", &c);
        assert_eq!(s[0].foreground_seconds, 75 + 5, "{s:?}");
    }

    #[test]
    fn a_wall_clock_jump_does_not_change_a_duration() {
        let mut t = tracker();
        let mut c = Clock::new();
        start(&mut t, &c, IA, "p1", A);
        run(&mut t, &mut c, 60, "p1", Some(IA), Attention::Active);
        c.wall -= 7200; // NTP sets the clock back two hours
        run(&mut t, &mut c, 60, "p1", Some(IA), Attention::Active);
        c.wall += 86_400 * 3;
        run(&mut t, &mut c, 60, "p1", Some(IA), Attention::Active);
        quit(&mut t, &c, IA);
        assert_eq!(sessions(&mut t, "p1", &c)[0].foreground_seconds, 180);
    }

    #[test]
    fn sessions_under_ten_seconds_are_dropped() {
        let mut t = tracker();
        let mut c = Clock::new();
        start(&mut t, &c, IA, "p1", A);
        run(&mut t, &mut c, 9, "p1", Some(IA), Attention::Active);
        assert_eq!(quit(&mut t, &c, IA), None);
        assert!(sessions(&mut t, "p1", &c).is_empty());
        start(&mut t, &c, IA, "p1", A);
        run(&mut t, &mut c, 10, "p1", Some(IA), Attention::Active);
        assert_eq!(quit(&mut t, &c, IA).as_deref(), Some("p1"));
        assert_eq!(sessions(&mut t, "p1", &c).len(), 1);
    }

    #[test]
    fn the_heartbeat_is_saved_every_thirty_seconds_and_a_crash_ends_there() {
        let mut t = tracker();
        let mut c = Clock::new();
        start(&mut t, &c, IA, "p1", A);
        run(&mut t, &mut c, 29, "p1", Some(IA), Attention::Active);
        assert!(t.store().opens.is_empty(), "not before 30 s");
        run(&mut t, &mut c, 1, "p1", Some(IA), Attention::Active);
        assert_eq!(t.store().opens.len(), 1);
        run(&mut t, &mut c, 45, "p1", Some(IA), Attention::Active); // the heartbeat at 60 s
        let beat_wall = c.wall - 15;
        // The service dies here (power cut): a new one reads what was saved.
        let store = std::mem::take(&mut t.store);
        let mut t2 = Tracker::new(store, FixedZone(0));
        let changed = t2.recover(c.wall);
        assert_eq!(changed, ["p1"]);
        assert!(t2.store().opens.is_empty());
        let s = sessions(&mut t2, "p1", &c);
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].foreground_seconds, 60);
        assert_eq!(s[0].end, beat_wall);
        assert_eq!(s[0].reason, EndReason::Crashed);
    }

    fn live(instance: &str, profile: &str, app: &str, started: i64) -> LiveApp {
        LiveApp {
            instance: instance.to_owned(),
            profile: profile.to_owned(),
            app_id: app.to_owned(),
            version: "1.0".to_owned(),
            started,
        }
    }

    /// A service that dies after 60 counted seconds and a new one that takes the store over.
    fn restarted_after_60s() -> (T, Clock, i64) {
        let mut t = tracker();
        let mut c = Clock::new();
        let started = c.wall;
        start(&mut t, &c, IA, "p1", A);
        run(&mut t, &mut c, 60, "p1", Some(IA), Attention::Active);
        assert_eq!(t.store().opens.len(), 1);
        let store = std::mem::take(&mut t.store);
        (Tracker::new(store, FixedZone(0)), c, started)
    }

    #[test]
    fn a_restart_mid_session_keeps_counting_and_writes_one_row() {
        let (mut t2, mut c, started) = restarted_after_60s();
        let changed = t2.recover_with(c.wall, &[live(IA, "p1", A, started)], c.now());
        assert!(changed.is_empty(), "the run did not end");
        assert_eq!(t2.store().opens.len(), 1, "its heartbeat file is kept");
        // What was counted before the restart shows, as a running session.
        let running = sessions(&mut t2, "p1", &c);
        assert_eq!(running.len(), 1);
        assert!(running[0].open);
        assert_eq!(running[0].foreground_seconds, 60);
        // It goes on counting from there ...
        run(&mut t2, &mut c, 40, "p1", Some(IA), Attention::Active);
        assert_eq!(quit(&mut t2, &c, IA).as_deref(), Some("p1"));
        // ... and ends as ONE row of the whole run: no crashed row, no second row.
        let s = sessions(&mut t2, "p1", &c);
        assert_eq!(s.len(), 1, "{s:?}");
        assert_eq!(s[0].foreground_seconds, 100);
        assert_eq!(s[0].start, started);
        assert_eq!(s[0].reason, EndReason::Quit);
        assert!(!s[0].open);
        assert!(t2.store().opens.is_empty(), "the heartbeat file is gone");
    }

    #[test]
    fn without_adoption_the_same_restart_splits_the_run() {
        // The behaviour this task removes: recover() ends the run as crashed at the heartbeat,
        // and the app that goes on starts a second one.
        let (mut t2, mut c, started) = restarted_after_60s();
        assert_eq!(t2.recover(c.wall), ["p1"]);
        t2.app_started(IA, "p1", A, "1.0", c.now(), started);
        run(&mut t2, &mut c, 40, "p1", Some(IA), Attention::Active);
        quit(&mut t2, &c, IA);
        assert_eq!(sessions(&mut t2, "p1", &c).len(), 2);
    }

    #[test]
    fn a_live_app_without_a_heartbeat_starts_a_run_dated_from_its_start() {
        let mut t = tracker();
        let mut c = Clock::new();
        let started = c.wall - 300;
        let changed = t.recover_with(c.wall, &[live(IA, "p1", A, started)], c.now());
        assert!(changed.is_empty());
        run(&mut t, &mut c, 30, "p1", Some(IA), Attention::Active);
        quit(&mut t, &c, IA);
        let s = sessions(&mut t, "p1", &c);
        assert_eq!(
            (s.len(), s[0].foreground_seconds, s[0].start),
            (1, 30, started)
        );
    }

    #[test]
    fn leftovers_of_apps_that_are_not_live_still_end_as_crashed() {
        let mut t = tracker();
        let mut c = Clock::new();
        start(&mut t, &c, IA, "p1", A);
        start(&mut t, &c, IB, "p1", B);
        run(&mut t, &mut c, 60, "p1", Some(IA), Attention::Active);
        run(&mut t, &mut c, 60, "p1", Some(IB), Attention::Active);
        assert_eq!(t.store().opens.len(), 2);
        let store = std::mem::take(&mut t.store);
        let mut t2 = Tracker::new(store, FixedZone(0));
        // Only B is still running; A is not.
        let changed = t2.recover_with(c.wall, &[live(IB, "p1", B, c.wall - 120)], c.now());
        assert_eq!(changed, ["p1"]);
        assert_eq!(t2.store().opens.len(), 1);
        let s = sessions(&mut t2, "p1", &c);
        let ended: Vec<_> = s.iter().filter(|x| !x.open).collect();
        assert_eq!(ended.len(), 1);
        assert_eq!(
            (ended[0].app_id.as_str(), ended[0].reason),
            (A, EndReason::Crashed)
        );
        assert!(s.iter().any(|x| x.open && x.app_id == B));
    }

    #[test]
    fn a_leftover_is_not_taken_by_an_app_of_another_profile() {
        let (mut t2, c, started) = restarted_after_60s();
        let changed = t2.recover_with(c.wall, &[live(IA, "p2", A, started)], c.now());
        assert_eq!(changed, ["p1"], "p1's run ended at its heartbeat");
        assert!(sessions(&mut t2, "p1", &c).iter().all(|x| !x.open));
    }

    #[test]
    fn a_heartbeat_with_nothing_new_writes_nothing() {
        let mut t = tracker();
        let mut c = Clock::new();
        start(&mut t, &c, IA, "p1", A);
        run(&mut t, &mut c, 40, "p1", Some(IA), Attention::Active);
        let writes = t.store().writes;
        run(&mut t, &mut c, 120, "p1", Some(IA), Attention::Idle);
        assert!(
            t.store().writes <= writes + 1,
            "at most the beat after the last second"
        );
        assert_eq!(t.store().opens.len(), 1);
    }

    #[test]
    fn a_short_leftover_is_not_recovered_as_a_session() {
        let mut store = MemStore::default();
        let mut s = crate::usage::testing::rec(A, 1_000, 5, 0);
        s.open = true;
        store.opens.insert(("p1".into(), "k".into()), s);
        let mut t = Tracker::new(store, FixedZone(0));
        assert!(t.recover(2_000).is_empty());
        assert!(t.store().opens.is_empty());
        assert!(sessions(&mut t, "p1", &Clock::new()).is_empty());
    }

    #[test]
    fn a_profile_switch_pauses_the_old_profiles_runs() {
        let mut t = tracker();
        let mut c = Clock::new();
        start(&mut t, &c, IA, "p1", A);
        run(&mut t, &mut c, 60, "p1", Some(IA), Attention::Active);
        run(&mut t, &mut c, 30, "p1", Some(IA), Attention::Locked); // the picker
        let changed = t.presence("p2", None, Attention::Active, c.now(), c.wall);
        assert!(changed.is_empty());
        // Nothing finished: p1's run is still open.
        assert_eq!(t.open.len(), 1);
        run(&mut t, &mut c, 120, "p2", None, Attention::Active);
        run(&mut t, &mut c, 30, "p1", Some(IA), Attention::Active);
        assert_eq!(quit(&mut t, &c, IA), Some("p1".to_owned()));
        let s = sessions(&mut t, "p1", &c);
        assert_eq!(
            (s.len(), s[0].foreground_seconds, s[0].reason),
            (1, 90, EndReason::Quit)
        );
        assert!(sessions(&mut t, "p2", &c).is_empty());
        // Locking and unlocking the same profile does not end anything.
        start(&mut t, &c, IB, "p2", B);
        run(&mut t, &mut c, 30, "p2", Some(IB), Attention::Active);
        run(&mut t, &mut c, 30, "p2", Some(IB), Attention::Locked);
        run(&mut t, &mut c, 30, "p2", Some(IB), Attention::Active);
        quit(&mut t, &c, IB);
        assert_eq!(sessions(&mut t, "p2", &c)[0].foreground_seconds, 60);
    }

    #[test]
    fn an_app_that_exits_while_its_profile_is_away_ends_with_its_reason() {
        let mut t = tracker();
        let mut c = Clock::new();
        start(&mut t, &c, IA, "p1", A);
        run(&mut t, &mut c, 60, "p1", Some(IA), Attention::Active);
        run(&mut t, &mut c, 20, "p1", Some(IA), Attention::Locked);
        run(&mut t, &mut c, 100, "p2", None, Attention::Active);
        let ended = t.app_exited(IA, Some(EndReason::Crashed), c.now(), c.wall);
        assert_eq!(ended, Some("p1".to_owned()));
        let s = sessions(&mut t, "p1", &c);
        assert_eq!(
            (s.len(), s[0].foreground_seconds, s[0].reason),
            (1, 60, EndReason::Crashed)
        );
        assert!(sessions(&mut t, "p2", &c).is_empty());
    }

    #[test]
    fn another_profile_cannot_read_a_ledger() {
        let mut t = tracker();
        let mut c = Clock::new();
        start(&mut t, &c, IA, "p1", A);
        run(&mut t, &mut c, 60, "p1", Some(IA), Attention::Active);
        quit(&mut t, &c, IA);
        assert!(t
            .totals("p2", "", "", c.wall)
            .map(|r| r.1.is_empty())
            .unwrap_or(false));
        assert!(sessions(&mut t, "p2", &c).is_empty());
        assert!(t
            .list("p1", 0, 10, c.wall)
            .map(|s| s.len() == 1)
            .unwrap_or(false));
    }

    #[test]
    fn an_update_in_the_middle_continues_the_session() {
        let mut t = tracker();
        let mut c = Clock::new();
        start(&mut t, &c, IA, "p1", A);
        run(&mut t, &mut c, 40, "p1", Some(IA), Attention::Active);
        // The app is updated on disk; the running instance and its name stay. A second
        // "started" for the same instance (a duplicate report) changes nothing.
        t.app_started(IA, "p1", A, "2.0", c.now(), c.wall);
        run(&mut t, &mut c, 40, "p1", Some(IA), Attention::Active);
        quit(&mut t, &c, IA);
        let s = sessions(&mut t, "p1", &c);
        assert_eq!(
            (s.len(), s[0].foreground_seconds, s[0].app_version.as_str()),
            (1, 80, "1.0")
        );
    }

    #[test]
    fn a_time_limit_ending_is_recorded_as_such() {
        let mut t = tracker();
        let mut c = Clock::new();
        start(&mut t, &c, IA, "p1", A);
        run(&mut t, &mut c, 60, "p1", Some(IA), Attention::Active);
        t.set_end_reason(IA, EndReason::TimeLimit);
        t.app_exited(IA, Some(EndReason::Quit), c.now(), c.wall);
        assert_eq!(sessions(&mut t, "p1", &c)[0].reason, EndReason::TimeLimit);
        start(&mut t, &c, IA, "p1", A);
        run(&mut t, &mut c, 60, "p1", Some(IA), Attention::Active);
        t.app_exited(IA, Some(EndReason::Crashed), c.now(), c.wall);
        let s = sessions(&mut t, "p1", &c);
        assert_eq!(s[0].reason, EndReason::Crashed);
    }

    #[test]
    fn a_launch_that_never_ran_leaves_nothing() {
        let mut t = tracker();
        let c = Clock::new();
        assert_eq!(t.app_exited("never-started", None, c.now(), c.wall), None);
        assert!(t.store().ledgers.is_empty());
    }

    #[test]
    fn totals_in_a_non_utc_zone_follow_the_local_day() {
        // Istanbul, UTC+3: 22:00 UTC is 01:00 the next local day.
        let mut t = Tracker::new(MemStore::default(), FixedZone(3 * 3600));
        let mut c = Clock::new();
        c.wall = i64::from(days_from_civil(2026, 11, 7)) * 86_400 + 21 * 3600 + 30 * 60; // 21:30 UTC
        t.app_started(IA, "p1", A, "1.0", c.now(), c.wall);
        run(&mut t, &mut c, 3600, "p1", Some(IA), Attention::Active); // to 22:30 UTC = 01:30 local
        t.app_exited(IA, Some(EndReason::Quit), c.now(), c.wall);
        let (today, rows) = t.totals("p1", "", "", c.wall).unwrap_or_default();
        assert_eq!(today, "2026-11-08");
        let got: Vec<_> = rows
            .iter()
            .map(|r| (format_day(r.day), r.seconds, r.sessions))
            .collect();
        assert_eq!(
            got,
            [("2026-11-08".to_owned(), 3600, 1)],
            "all of it after local midnight"
        );
        // 20:30 UTC to 22:30 UTC is 23:30 to 01:30 local: it straddles local midnight.
        let mut t = Tracker::new(MemStore::default(), FixedZone(3 * 3600));
        let mut c = Clock::new();
        c.wall = i64::from(days_from_civil(2026, 11, 7)) * 86_400 + 20 * 3600 + 30 * 60;
        t.app_started(IA, "p1", A, "1.0", c.now(), c.wall);
        run(&mut t, &mut c, 7200, "p1", Some(IA), Attention::Active);
        t.app_exited(IA, Some(EndReason::Quit), c.now(), c.wall);
        let (_, rows) = t
            .totals("p1", "2026-11-07", "2026-11-08", c.wall)
            .unwrap_or_default();
        let got: Vec<_> = rows
            .iter()
            .map(|r| (format_day(r.day), r.seconds, r.sessions))
            .collect();
        assert_eq!(
            got,
            [
                ("2026-11-07".to_owned(), 1800, 1),
                ("2026-11-08".to_owned(), 5400, 0)
            ]
        );
    }

    #[test]
    fn a_dst_day_has_its_own_length_and_the_totals_follow() {
        // Berlin, 2026-03-29: at 01:00 UTC the clocks jump from +1 to +2 (a 23 hour day).
        let change = i64::from(days_from_civil(2026, 3, 29)) * 86_400 + 3600;
        let zone = TableZone(vec![(0, 3600), (change, 7200)]);
        let mut t = Tracker::new(MemStore::default(), zone);
        let mut c = Clock::new();
        c.wall = change - 1800; // 00:30 UTC = 01:30 CET
        t.app_started(IA, "p1", A, "1.0", c.now(), c.wall);
        run(&mut t, &mut c, 3600, "p1", Some(IA), Attention::Active); // to 01:30 UTC = 03:30 CEST
        t.app_exited(IA, Some(EndReason::Quit), c.now(), c.wall);
        let (today, rows) = t
            .totals("p1", "2026-03-28", "2026-03-30", c.wall)
            .unwrap_or_default();
        assert_eq!(today, "2026-03-29");
        assert_eq!(rows.len(), 1, "one local day: {rows:?}");
        assert_eq!(
            (format_day(rows[0].day), rows[0].seconds),
            ("2026-03-29".to_owned(), 3600)
        );
        // The next local day starts at 22:00 UTC (00:00 CEST), not 23:00.
        let before = change + 21 * 3600 - 1; // 21:59:59 UTC = 23:59:59 CEST
        let day_start = change - 3600 - 3600; // 2026-03-28 23:00 UTC = 00:00 CET
        assert_eq!(format_day(day_of(day_start - 1, &t.zone)), "2026-03-28");
        assert_eq!(format_day(day_of(day_start, &t.zone)), "2026-03-29");
        assert_eq!(format_day(day_of(before, &t.zone)), "2026-03-29");
        assert_eq!(format_day(day_of(before + 1, &t.zone)), "2026-03-30");
    }

    #[test]
    fn totals_reject_a_bad_date_and_include_the_running_session() {
        let mut t = tracker();
        let mut c = Clock::new();
        assert_eq!(
            t.totals("p1", "yesterday", "", c.wall).err().as_deref(),
            Some("invalid")
        );
        assert_eq!(
            t.totals("p1", "", "2026-02-30", c.wall).err().as_deref(),
            Some("invalid")
        );
        start(&mut t, &c, IA, "p1", A);
        run(&mut t, &mut c, 45, "p1", Some(IA), Attention::Active);
        let (_, rows) = t.totals("p1", "", "", c.wall).unwrap_or_default();
        assert_eq!(rows.iter().map(|r| r.seconds).sum::<u32>(), 45, "live");
        assert!(sessions(&mut t, "p1", &c)[0].open);
    }

    #[test]
    fn clear_history_empties_everything_and_restarts_running_sessions() {
        let mut t = tracker();
        let mut c = Clock::new();
        start(&mut t, &c, IA, "p1", A);
        run(&mut t, &mut c, 60, "p1", Some(IA), Attention::Active);
        quit(&mut t, &c, IA);
        start(&mut t, &c, IB, "p1", B);
        run(&mut t, &mut c, 60, "p1", Some(IB), Attention::Active);
        t.clear("p1", c.wall);
        assert!(t.store().ledgers.is_empty());
        assert!(t.store().opens.is_empty());
        assert!(sessions(&mut t, "p1", &c).is_empty());
        run(&mut t, &mut c, 30, "p1", Some(IB), Attention::Active);
        quit(&mut t, &c, IB);
        let s = sessions(&mut t, "p1", &c);
        assert_eq!(
            (s.len(), s[0].foreground_seconds),
            (1, 30),
            "only what came after"
        );
    }

    #[test]
    fn deleting_a_profile_deletes_its_data() {
        let mut t = tracker();
        let mut c = Clock::new();
        for (inst, p) in [(IA, "p1"), (IB, "p2")] {
            start(&mut t, &c, inst, p, A);
            run(&mut t, &mut c, 60, p, Some(inst), Attention::Active);
            quit(&mut t, &c, inst);
        }
        let gone = t.purge_except(&["p2".to_owned()]);
        assert_eq!(gone, ["p1"]);
        assert!(sessions(&mut t, "p1", &c).is_empty());
        assert_eq!(sessions(&mut t, "p2", &c).len(), 1);
        assert_eq!(t.store.profiles(), ["p2"]);
    }

    #[test]
    fn old_sessions_roll_up_when_the_ledger_is_loaded_and_each_new_day() {
        let mut store = MemStore::default();
        let mut l = Ledger::default();
        let old_day = days_from_civil(2026, 11, 7) - 100;
        l.sessions.push(crate::usage::testing::rec(
            A,
            i64::from(old_day) * 86_400,
            600,
            old_day,
        ));
        store.ledgers.insert("p1".into(), l);
        let mut t = Tracker::new(store, FixedZone(0));
        let c = Clock::new();
        let (_, rows) = t.totals("p1", "", "", c.wall).unwrap_or_default();
        assert_eq!(rows.iter().map(|r| r.seconds).sum::<u32>(), 600);
        let kept = t
            .store()
            .ledgers
            .get("p1")
            .map(|l| (l.sessions.len(), l.rows.len()));
        assert_eq!(kept, Some((0, 1)), "rolled up and saved");

        // A day later a loaded ledger is rolled again by the tick.
        let mut l = Ledger::default();
        let edge = c.wall - 89 * 86_400;
        l.sessions.push(crate::usage::testing::rec(
            B,
            edge,
            100,
            day_of(edge, &FixedZone(0)),
        ));
        t.ledgers.insert("p2".into(), l);
        let mut c = c;
        c.mono += 1;
        t.tick(c.now(), c.wall);
        assert_eq!(t.ledgers.get("p2").map(|l| l.sessions.len()), Some(1));
        c.mono += 1;
        c.wall += 3 * 86_400;
        let changed = t.tick(c.now(), c.wall);
        assert!(changed.contains(&"p2".to_owned()));
        assert_eq!(
            t.ledgers
                .get("p2")
                .map(|l| (l.sessions.len(), l.rows.len())),
            Some((0, 1))
        );
    }

    #[test]
    fn only_the_active_profile_reads_its_history() {
        assert!(may_read("p1", Some("p1")));
        assert!(!may_read("p1", Some("p2")));
        assert!(!may_read("p1", Some("")), "locked: nobody is active");
        assert!(!may_read("", Some("")));
        assert!(!may_read("../p1", None));
        assert!(may_read("p1", None), "development mode has no Profiles1");
    }

    #[test]
    fn clearing_needs_the_profile_to_be_active_or_an_admin() {
        assert_eq!(clear_route("p1", Some("p1"), ""), ClearRoute::Own);
        assert_eq!(clear_route("p1", Some("p2"), ""), ClearRoute::NotAllowed);
        assert_eq!(clear_route("p1", Some(""), ""), ClearRoute::NotAllowed);
        assert_eq!(clear_route("p1", Some("p2"), "p2"), ClearRoute::Admin);
        assert_eq!(clear_route("p1", None, ""), ClearRoute::Own);
    }

    #[test]
    fn the_number_of_tracked_sessions_per_profile_is_capped() {
        let mut t = tracker();
        let c = Clock::new();
        for i in 0..(MAX_OPEN_PER_PROFILE + 5) {
            t.app_started(&format!("unit-{i}"), "p1", A, "1.0", c.now(), c.wall);
        }
        assert_eq!(t.open.len(), MAX_OPEN_PER_PROFILE);
        t.app_started("x", "../bad", A, "1.0", c.now(), c.wall);
        assert_eq!(
            t.open.len(),
            MAX_OPEN_PER_PROFILE,
            "a bad profile id is not tracked"
        );
    }
}
