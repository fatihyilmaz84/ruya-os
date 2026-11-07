//! The play ledger's data (T-247): sessions, daily totals, the time zone and the calendar. Pure:
//! no files, no clock. `usage_tracker.rs` does the live accounting, `usage_store.rs` the files.

use std::collections::BTreeMap;

/// Sessions shorter than this are dropped (a launcher flash, a crash at start-up).
pub const MIN_SESSION_SECS: u32 = 10;
/// Raw sessions are kept this many days, then rolled up into daily totals.
pub const RAW_DAYS: i32 = 90;
/// Daily totals are kept this many days (24 months).
pub const ROLLUP_DAYS: i32 = 731;
/// Caps, so a runaway app or a broken clock cannot fill the disk. Over the cap the oldest raw
/// sessions are rolled up early, and the oldest daily rows dropped.
pub const MAX_RAW_SESSIONS: usize = 5000;
pub const MAX_ROWS: usize = 20_000;
/// The most `ListSessions` returns.
pub const MAX_LIST: usize = 1000;

/// Why a session ended. `Quit`, `Crashed` and `Killed` are the `AppExited` reasons;
/// `TimeLimit` and `Bedtime` come from T-211.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EndReason {
    Quit,
    Crashed,
    Killed,
    TimeLimit,
    Bedtime,
}

impl EndReason {
    pub fn as_str(self) -> &'static str {
        match self {
            EndReason::Quit => "quit",
            EndReason::Crashed => "crashed",
            EndReason::Killed => "killed",
            EndReason::TimeLimit => "time-limit",
            EndReason::Bedtime => "bedtime",
        }
    }

    pub fn parse(s: &str) -> Option<EndReason> {
        Some(match s {
            "quit" => EndReason::Quit,
            "crashed" => EndReason::Crashed,
            "killed" => EndReason::Killed,
            "time-limit" => EndReason::TimeLimit,
            "bedtime" => EndReason::Bedtime,
            _ => return None,
        })
    }
}

/// One run of one app. `days` is the foreground time per local day (day number since
/// 1970-01-01), decided when the time was spent; their sum is `foreground_seconds`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionRecord {
    pub app_id: String,
    pub app_version: String,
    pub start: i64,
    pub end: i64,
    pub foreground_seconds: u32,
    pub reason: EndReason,
    pub days: Vec<(i32, u32)>,
    /// Still running (never stored).
    pub open: bool,
}

/// The totals of one app on one local day.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DayRow {
    pub app_id: String,
    pub day: i32,
    pub seconds: u32,
    pub sessions: u32,
    pub longest: u32,
    pub first: i64,
    pub last: i64,
}

impl DayRow {
    fn merge(&mut self, other: &DayRow) {
        self.seconds = self.seconds.saturating_add(other.seconds);
        self.sessions = self.sessions.saturating_add(other.sessions);
        self.longest = self.longest.max(other.longest);
        self.first = self.first.min(other.first);
        self.last = self.last.max(other.last);
    }
}

// ---------------------------------------------------------------------------------------------
// Time zone and calendar

/// The device time zone: seconds east of UTC at a moment. Asked per moment, so a DST change is
/// honoured and a zone change (T-213) affects only what is counted afterwards.
pub trait Zone {
    fn offset_secs(&self, unix: i64) -> i64;
}

#[derive(Debug, Clone, Copy)]
pub struct FixedZone(pub i64);

impl Zone for FixedZone {
    fn offset_secs(&self, _unix: i64) -> i64 {
        self.0
    }
}

/// A zone given as a table of (from unix second, offset); the offset before the first entry is
/// the first entry's. For tests (a DST day) and as an example of the rule.
#[derive(Debug, Clone)]
pub struct TableZone(pub Vec<(i64, i64)>);

impl Zone for TableZone {
    fn offset_secs(&self, unix: i64) -> i64 {
        let mut offset = self.0.first().map_or(0, |e| e.1);
        for (from, off) in &self.0 {
            if unix >= *from {
                offset = *off;
            }
        }
        offset
    }
}

#[cfg(target_os = "linux")]
extern "C" {
    /// POSIX `tzset`, which the `libc` crate does not declare (as in `ruya-update`).
    fn tzset();
}

/// The system's zone through libc (Linux). `tzset` first: `localtime_r` alone reads the zone
/// once, and T-213 changes it while we run. Elsewhere it is UTC.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemZone;

impl Zone for SystemZone {
    #[cfg(target_os = "linux")]
    fn offset_secs(&self, unix: i64) -> i64 {
        let t: libc::time_t = unix;
        // SAFETY: `tm` is plain data that localtime_r fills in; both pointers are valid for the
        // call and localtime_r keeps no static buffer. `tzset` takes no pointer.
        let mut tm: libc::tm = unsafe { std::mem::zeroed() };
        let filled = unsafe {
            tzset();
            libc::localtime_r(&t, &mut tm)
        };
        if filled.is_null() {
            0
        } else {
            // `tm_gmtoff` is a `c_long`: already an i64 on x86_64, narrower elsewhere.
            #[allow(clippy::useless_conversion)]
            i64::from(tm.tm_gmtoff)
        }
    }

    #[cfg(not(target_os = "linux"))]
    fn offset_secs(&self, _unix: i64) -> i64 {
        0
    }
}

/// The local day number (days since 1970-01-01) of a moment.
pub fn day_of(unix: i64, zone: &dyn Zone) -> i32 {
    i32::try_from((unix + zone.offset_secs(unix)).div_euclid(86_400)).unwrap_or(0)
}

/// (year, month, day) of a day number (Howard Hinnant's civil_from_days).
pub fn civil_from_days(days: i32) -> (i32, u32, u32) {
    let z = i64::from(days) + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (
        i32::try_from(y).unwrap_or(0),
        u32::try_from(m).unwrap_or(1),
        u32::try_from(d).unwrap_or(1),
    )
}

/// The day number of a calendar date (days_from_civil).
pub fn days_from_civil(y: i32, m: u32, d: u32) -> i32 {
    let y = i64::from(y) - i64::from(m <= 2);
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = (i64::from(m) + 9) % 12;
    let doy = (153 * mp + 2) / 5 + i64::from(d) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    i32::try_from(era * 146_097 + doe - 719_468).unwrap_or(0)
}

pub fn format_day(day: i32) -> String {
    let (y, m, d) = civil_from_days(day);
    format!("{y:04}-{m:02}-{d:02}")
}

/// "YYYY-MM-DD" to a day number; `None` for anything else (including 2026-02-31).
pub fn parse_day(s: &str) -> Option<i32> {
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    let num = |r: std::ops::Range<usize>| -> Option<u32> {
        let part = s.get(r)?;
        if !part.bytes().all(|c| c.is_ascii_digit()) {
            return None;
        }
        part.parse().ok()
    };
    let (y, m, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    if !(1..=12).contains(&m) || d == 0 {
        return None;
    }
    let y = i32::try_from(y).ok()?;
    let day = days_from_civil(y, m, d);
    (civil_from_days(day) == (y, m, d)).then_some(day)
}

// ---------------------------------------------------------------------------------------------
// The ledger of one profile

#[derive(Debug, Default, Clone)]
pub struct Ledger {
    /// Raw sessions, oldest first.
    pub sessions: Vec<SessionRecord>,
    /// Daily totals of sessions that left the raw window, sorted by (day, app).
    pub rows: Vec<DayRow>,
}

/// The rows a finished session adds: one per day it touched. The session counts on the day it
/// began; `first` and `last` are its start and end on every day it touches.
fn rows_of(s: &SessionRecord) -> Vec<DayRow> {
    s.days
        .iter()
        .enumerate()
        .map(|(i, (day, secs))| DayRow {
            app_id: s.app_id.clone(),
            day: *day,
            seconds: *secs,
            sessions: u32::from(i == 0),
            longest: if i == 0 { s.foreground_seconds } else { 0 },
            first: s.start,
            last: s.end,
        })
        .collect()
}

impl Ledger {
    /// Adds a finished session. Returns true when the cap rolled older ones up, so the store
    /// has to rewrite its file instead of appending one line.
    pub fn add(&mut self, s: SessionRecord) -> bool {
        self.sessions.push(s);
        let mut rewritten = false;
        while self.sessions.len() > MAX_RAW_SESSIONS {
            let oldest = self.sessions.remove(0);
            self.fold(&oldest);
            rewritten = true;
        }
        rewritten
    }

    fn fold(&mut self, s: &SessionRecord) {
        let mut map: BTreeMap<(i32, String), DayRow> = std::mem::take(&mut self.rows)
            .into_iter()
            .map(|r| ((r.day, r.app_id.clone()), r))
            .collect();
        for row in rows_of(s) {
            match map.get_mut(&(row.day, row.app_id.clone())) {
                Some(have) => have.merge(&row),
                None => {
                    map.insert((row.day, row.app_id.clone()), row);
                }
            }
        }
        self.rows = map.into_values().collect();
        if self.rows.len() > MAX_ROWS {
            let excess = self.rows.len() - MAX_ROWS;
            self.rows.drain(..excess);
        }
    }

    /// Rolls sessions that ended more than `RAW_DAYS` ago into daily totals and drops totals
    /// older than `ROLLUP_DAYS`. `today` is the local day number, `now` unix seconds. Returns
    /// whether anything changed.
    pub fn roll_up(&mut self, today: i32, now: i64) -> bool {
        let cutoff = now - i64::from(RAW_DAYS) * 86_400;
        let (old, keep): (Vec<_>, Vec<_>) = std::mem::take(&mut self.sessions)
            .into_iter()
            .partition(|s| s.end < cutoff);
        self.sessions = keep;
        let mut changed = !old.is_empty();
        for s in &old {
            self.fold(s);
        }
        let before = self.rows.len();
        self.rows.retain(|r| r.day > today - ROLLUP_DAYS);
        changed |= self.rows.len() != before;
        changed
    }

    /// Totals per app and day in `from..=to` (day numbers, `None` = unbounded), from the daily
    /// rows, the raw sessions and the sessions still running (`open`).
    pub fn totals(
        &self,
        from: Option<i32>,
        to: Option<i32>,
        open: &[SessionRecord],
    ) -> Vec<DayRow> {
        let mut map: BTreeMap<(i32, String), DayRow> = BTreeMap::new();
        let mut put = |row: DayRow| {
            if from.is_some_and(|f| row.day < f) || to.is_some_and(|t| row.day > t) {
                return;
            }
            match map.get_mut(&(row.day, row.app_id.clone())) {
                Some(have) => have.merge(&row),
                None => {
                    map.insert((row.day, row.app_id.clone()), row);
                }
            }
        };
        for row in &self.rows {
            put(row.clone());
        }
        for s in self.sessions.iter().chain(open) {
            for row in rows_of(s) {
                put(row);
            }
        }
        map.into_values().collect()
    }

    /// Sessions that ended at or after `since`, newest first (by start), at most `limit`.
    pub fn list(&self, since: i64, limit: usize, open: &[SessionRecord]) -> Vec<SessionRecord> {
        let mut all: Vec<SessionRecord> = self
            .sessions
            .iter()
            .chain(open)
            .filter(|s| s.end >= since)
            .cloned()
            .collect();
        all.sort_by(|a, b| b.start.cmp(&a.start).then_with(|| a.app_id.cmp(&b.app_id)));
        all.truncate(limit.min(MAX_LIST));
        all
    }
}

#[cfg(test)]
pub(crate) mod testing {
    use super::*;

    pub fn rec(app: &str, start: i64, fg: u32, day: i32) -> SessionRecord {
        SessionRecord {
            app_id: app.to_owned(),
            app_version: "1.0".to_owned(),
            start,
            end: start + i64::from(fg),
            foreground_seconds: fg,
            reason: EndReason::Quit,
            days: vec![(day, fg)],
            open: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testing::rec;
    use super::*;

    const A: &str = "org.ruyaos.Racer";
    const B: &str = "org.ruyaos.Puzzle";

    #[test]
    fn calendar_round_trips() {
        assert_eq!(format_day(0), "1970-01-01");
        assert_eq!(parse_day("1970-01-01"), Some(0));
        assert_eq!(parse_day("2026-11-07"), Some(days_from_civil(2026, 11, 7)));
        assert_eq!(
            format_day(parse_day("2024-02-29").unwrap_or(0)),
            "2024-02-29"
        );
        for day in [-800, 0, 59, 60, 19_000, 20_400, 40_000] {
            assert_eq!(parse_day(&format_day(day)), Some(day));
        }
        for bad in [
            "",
            "2026-2-3",
            "2026-02-30",
            "2026-13-01",
            "2026/02/03",
            "20260203",
            "2026-02-0x",
        ] {
            assert_eq!(parse_day(bad), None, "{bad}");
        }
    }

    #[test]
    fn a_moment_belongs_to_the_local_day() {
        let istanbul = FixedZone(3 * 3600);
        let t = 20_400 * 86_400 + 22 * 3600; // 22:00 UTC
        assert_eq!(day_of(t, &FixedZone(0)), 20_400);
        assert_eq!(day_of(t, &istanbul), 20_401); // 01:00 the next day
        assert_eq!(day_of(t, &FixedZone(-5 * 3600)), 20_400);
        assert_eq!(day_of(-1, &FixedZone(0)), -1); // before 1970
    }

    #[test]
    fn a_table_zone_follows_dst() {
        // Berlin, 2026-03-29: 01:00 UTC the clocks go from +1 to +2.
        let change = days_from_civil(2026, 3, 29) as i64 * 86_400 + 3600;
        let berlin = TableZone(vec![(0, 3600), (change, 7200)]);
        assert_eq!(berlin.offset_secs(change - 1), 3600);
        assert_eq!(berlin.offset_secs(change), 7200);
        assert_eq!(TableZone(vec![]).offset_secs(5), 0);
    }

    #[test]
    fn the_system_zone_answers() {
        // Whatever the host's zone is, the answer is a plausible offset.
        assert!(SystemZone.offset_secs(1_700_000_000).abs() <= 15 * 3600);
    }

    #[test]
    fn totals_merge_raw_rolled_and_open_sessions() {
        let mut l = Ledger::default();
        l.add(rec(A, 20_400 * 86_400 + 100, 600, 20_400));
        l.add(rec(A, 20_400 * 86_400 + 2000, 300, 20_400));
        l.add(rec(B, 20_401 * 86_400, 120, 20_401));
        l.rows.push(DayRow {
            app_id: A.to_owned(),
            day: 20_300,
            seconds: 1000,
            sessions: 2,
            longest: 700,
            first: 5,
            last: 6,
        });
        let open = rec(B, 20_401 * 86_400 + 500, 60, 20_401);
        let t = l.totals(None, None, &[open]);
        let got: Vec<_> = t
            .iter()
            .map(|r| (r.day, r.app_id.as_str(), r.seconds, r.sessions, r.longest))
            .collect();
        assert_eq!(
            got,
            [
                (20_300, A, 1000, 2, 700),
                (20_400, A, 900, 2, 600),
                (20_401, B, 180, 2, 120),
            ]
        );
        assert_eq!(l.totals(Some(20_400), Some(20_400), &[]).len(), 1);
        assert_eq!(l.totals(Some(20_402), None, &[]).len(), 0);
    }

    #[test]
    fn a_session_across_midnight_counts_once_and_splits_its_time() {
        let mut l = Ledger::default();
        let mut s = rec(A, 20_400 * 86_400 + 86_000, 500, 20_400);
        s.days = vec![(20_400, 300), (20_401, 200)];
        l.add(s);
        let t = l.totals(None, None, &[]);
        assert_eq!(
            (t[0].day, t[0].seconds, t[0].sessions, t[0].longest),
            (20_400, 300, 1, 500)
        );
        assert_eq!(
            (t[1].day, t[1].seconds, t[1].sessions, t[1].longest),
            (20_401, 200, 0, 0)
        );
    }

    #[test]
    fn list_is_newest_first_filtered_and_limited() {
        let mut l = Ledger::default();
        for i in 0..5 {
            l.add(rec(A, 1_000 * (i + 1), 100, 0));
        }
        let all = l.list(0, 10, &[]);
        assert_eq!(
            all.iter().map(|s| s.start).collect::<Vec<_>>(),
            [5000, 4000, 3000, 2000, 1000]
        );
        assert_eq!(l.list(0, 2, &[]).len(), 2);
        assert_eq!(l.list(3_050, 10, &[]).len(), 3); // ended at or after 3050: 2100 is out
        assert_eq!(l.list(0, 100_000, &[]).len(), 5);
    }

    #[test]
    fn roll_up_at_ninety_days() {
        let now = 20_500 * 86_400 + 40_000;
        let day = |n: i32| now - i64::from(n) * 86_400;
        let mut l = Ledger::default();
        l.add(rec(A, day(95), 600, 20_405));
        l.add(rec(A, day(95) + 4000, 400, 20_405));
        l.add(rec(B, day(89), 300, 20_411));
        let changed = l.roll_up(20_500, now);
        assert!(changed);
        assert_eq!(l.sessions.len(), 1);
        assert_eq!(l.sessions[0].app_id, B);
        assert_eq!(l.rows.len(), 1);
        let r = &l.rows[0];
        assert_eq!(
            (r.app_id.as_str(), r.day, r.seconds, r.sessions, r.longest),
            (A, 20_405, 1000, 2, 600)
        );
        // The totals are the same before and after (no double counting).
        let t = l.totals(None, None, &[]);
        assert_eq!(t.iter().map(|r| r.seconds).sum::<u32>(), 1300);
        assert!(!l.roll_up(20_500, now), "nothing more to roll");
    }

    #[test]
    fn rolled_up_rows_are_dropped_after_24_months() {
        let mut l = Ledger::default();
        for day in [20_500 - ROLLUP_DAYS, 20_500 - ROLLUP_DAYS + 1, 20_000] {
            l.rows.push(DayRow {
                app_id: A.to_owned(),
                day,
                seconds: 60,
                sessions: 1,
                longest: 60,
                first: 0,
                last: 0,
            });
        }
        assert!(l.roll_up(20_500, 20_500 * 86_400));
        let days: Vec<i32> = l.rows.iter().map(|r| r.day).collect();
        assert_eq!(days, [20_500 - ROLLUP_DAYS + 1, 20_000]);
    }

    #[test]
    fn the_caps_roll_up_early_and_drop_the_oldest() {
        let mut l = Ledger::default();
        let mut rewrote = false;
        for i in 0..(MAX_RAW_SESSIONS + 3) {
            rewrote |= l.add(rec(
                A,
                1_000_000 + i as i64 * 100,
                60,
                20_000 + (i % 7) as i32,
            ));
        }
        assert!(rewrote);
        assert_eq!(l.sessions.len(), MAX_RAW_SESSIONS);
        let total: u32 = l.totals(None, None, &[]).iter().map(|r| r.seconds).sum();
        assert_eq!(
            total,
            60 * (MAX_RAW_SESSIONS as u32 + 3),
            "rolled up, not lost"
        );

        let mut l = Ledger::default();
        for i in 0..(MAX_ROWS + 10) {
            l.rows.push(DayRow {
                app_id: A.to_owned(),
                day: i as i32,
                seconds: 1,
                sessions: 1,
                longest: 1,
                first: 0,
                last: 0,
            });
        }
        l.fold(&rec(B, 0, 60, MAX_ROWS as i32 + 100));
        assert_eq!(l.rows.len(), MAX_ROWS);
        assert_eq!(l.rows.last().map(|r| r.app_id.as_str()), Some(B));
    }

    #[test]
    fn end_reasons_round_trip() {
        for r in [
            EndReason::Quit,
            EndReason::Crashed,
            EndReason::Killed,
            EndReason::TimeLimit,
            EndReason::Bedtime,
        ] {
            assert_eq!(EndReason::parse(r.as_str()), Some(r));
        }
        assert_eq!(EndReason::parse("launch-failed"), None);
        assert_eq!(EndReason::parse(""), None);
    }
}
