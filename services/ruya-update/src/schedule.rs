//! When the service acts on its own: the daily check, and the restart into a staged image at a
//! quiet hour. Pure rules; the time comes from a `Clock` and the restart goes through `Reboot`,
//! so tests use a fake clock and a fake reboot.

use std::process::Command;
use std::sync::Mutex;

/// A scheduled check when the last finished one is at least this old.
pub const CHECK_INTERVAL_SECS: i64 = 24 * 60 * 60;
/// A scheduled check that failed (offline, registry down) is tried again after this long.
pub const RETRY_SECS: i64 = 60 * 60;
/// No input for this long counts as idle.
pub const IDLE_SECS: i64 = 30 * 60;
/// The local-time window in which the console restarts by itself: [03:00, 05:00).
pub const WINDOW_START_MINUTE: u32 = 3 * 60;
pub const WINDOW_END_MINUTE: u32 = 5 * 60;
/// The notice before an automatic restart: the restart waits this long after it was announced.
pub const GRACE_SECS: i64 = 120;
/// How often the service looks at the schedule.
pub const TICK_SECS: u64 = 60;

pub trait Clock: Send + Sync {
    /// Unix seconds.
    fn now(&self) -> i64;
    /// Minutes since local midnight, 0..1440.
    fn minute_of_day(&self) -> u32;
}

/// Restarts the console.
pub trait Reboot: Send + Sync {
    fn reboot(&self) -> Result<(), String>;
}

/// The wall clock and the local time zone.
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(0))
    }

    #[cfg(target_os = "linux")]
    fn minute_of_day(&self) -> u32 {
        let now: libc::time_t = self.now();
        // SAFETY: `tm` is plain data that localtime_r fills in; both pointers are valid for the
        // call, and localtime_r (unlike localtime) keeps no static buffer.
        let mut tm: libc::tm = unsafe { std::mem::zeroed() };
        let filled = unsafe { libc::localtime_r(&now, &mut tm) };
        if filled.is_null() {
            return utc_minute_of_day(self.now());
        }
        u32::try_from(tm.tm_hour * 60 + tm.tm_min).unwrap_or(0)
    }

    #[cfg(not(target_os = "linux"))]
    fn minute_of_day(&self) -> u32 {
        utc_minute_of_day(self.now())
    }
}

fn utc_minute_of_day(now: i64) -> u32 {
    u32::try_from(now.rem_euclid(86_400) / 60).unwrap_or(0)
}

/// `systemctl reboot`: systemd stops the services and boots the staged deployment.
pub struct SystemctlReboot;

impl Reboot for SystemctlReboot {
    fn reboot(&self) -> Result<(), String> {
        let out = Command::new("systemctl")
            .arg("reboot")
            .output()
            .map_err(|e| format!("cannot run systemctl: {e}"))?;
        if out.status.success() {
            Ok(())
        } else {
            Err(format!(
                "systemctl reboot failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ))
        }
    }
}

/// Development (`--session`): says what it would have done.
pub struct LogReboot;

impl Reboot for LogReboot {
    fn reboot(&self) -> Result<(), String> {
        eprintln!("ruya-update: would reboot now (development)");
        Ok(())
    }
}

/// What the service knows about the console's activity, and when it last tried to check.
#[derive(Debug, Default)]
pub struct Schedule {
    /// Unix seconds of the last input report; None until the first tick (then the service's
    /// start counts as activity).
    last_activity: Option<i64>,
    app_running: bool,
    /// Unix seconds of the last scheduled check that began; 0 = none.
    last_attempt: i64,
    /// Unix seconds at which the announced restart happens; None = nothing announced.
    pending_restart: Option<i64>,
    /// Unix seconds at which a scheduled download failed; None = no download to retry. Manual
    /// downloads never set it.
    failed_download: Option<i64>,
}

impl Schedule {
    /// The first thing a tick does: the service's start is the first activity. A time after
    /// `now` (the clock was set back) restarts the idle count instead of holding it off.
    pub fn seen(&mut self, now: i64) {
        if self.last_activity.map_or(true, |t| t > now) {
            self.last_activity = Some(now);
        }
    }

    /// Input arrived. Calls off an announced restart; returns whether there was one.
    pub fn activity(&mut self, now: i64, app_running: bool) -> bool {
        self.last_activity = Some(now);
        self.app_running = app_running;
        self.pending_restart.take().is_some()
    }

    pub fn attempted(&mut self, now: i64) {
        self.last_attempt = now;
    }

    /// A scheduled check is due: the last finished check is a day old (0 = never), and the last
    /// attempt, finished or not, is at least `RETRY_SECS` ago. A time after `now` was taken with
    /// a wrong clock (a bad RTC before NTP) and counts as long ago; otherwise the console would
    /// not check again until the clock caught up with it.
    pub fn check_due(&self, last_check: i64, now: i64) -> bool {
        let since = |t: i64| if t > now { i64::MAX } else { now - t };
        since(last_check) >= CHECK_INTERVAL_SECS
            && (self.last_attempt == 0 || since(self.last_attempt) >= RETRY_SECS)
    }

    /// Unix seconds of the announced restart.
    pub fn pending_restart(&self) -> Option<i64> {
        self.pending_restart
    }

    /// The announcement is off (the setting was turned off). Returns whether there was one.
    pub fn cancel_restart(&mut self) -> bool {
        self.pending_restart.take().is_some()
    }

    /// One look at the restart rules. `can` is what the service knows (an image is staged and
    /// the setting is on); the rest is `quiet`. The first look at which everything holds
    /// announces the restart for `now + GRACE_SECS`; a look at or after that time returns true
    /// ("restart now") if everything still holds; a look at which something does not hold clears
    /// the announcement, so the idle time starts over. A time further ahead than the grace
    /// (the clock was set back) is replaced.
    pub fn restart_step(&mut self, now: i64, minute_of_day: u32, can: bool) -> bool {
        if !(can && self.quiet(now, minute_of_day)) {
            self.pending_restart = None;
            return false;
        }
        match self.pending_restart {
            Some(at) if at <= now + GRACE_SECS => now >= at,
            _ => {
                self.pending_restart = Some(now + GRACE_SECS);
                false
            }
        }
    }

    /// A scheduled download failed at `now`.
    pub fn download_failed(&mut self, now: i64) {
        self.failed_download = Some(now);
    }

    /// Whatever was to be retried is settled or taken over (a download began).
    pub fn download_begun(&mut self) {
        self.failed_download = None;
    }

    /// A failed scheduled download is due again: `RETRY_SECS` have passed (a failure time after
    /// `now` counts as long ago, like the other times).
    pub fn download_retry_due(&self, now: i64) -> bool {
        self.failed_download
            .is_some_and(|t| t > now || now - t >= RETRY_SECS)
    }

    /// The console may restart by itself: inside the window, idle long enough, no app.
    pub fn quiet(&self, now: i64, minute_of_day: u32) -> bool {
        let Some(last) = self.last_activity else {
            return false;
        };
        (WINDOW_START_MINUTE..WINDOW_END_MINUTE).contains(&minute_of_day)
            && now - last >= IDLE_SECS
            && !self.app_running
    }
}

/// The remembered `last_check` (unix seconds). A missing or unreadable file means "never".
pub(crate) fn parse_seconds(text: &str) -> i64 {
    text.trim().parse::<i64>().unwrap_or(0).max(0)
}

/// For tests: a settable clock.
#[derive(Default)]
pub struct FakeClock {
    state: Mutex<(i64, u32)>,
}

impl FakeClock {
    pub fn new(now: i64, minute_of_day: u32) -> Self {
        FakeClock {
            state: Mutex::new((now, minute_of_day)),
        }
    }

    pub fn set(&self, now: i64, minute_of_day: u32) {
        *self.state.lock().expect("fake lock") = (now, minute_of_day);
    }
}

impl Clock for FakeClock {
    fn now(&self) -> i64 {
        self.state.lock().expect("fake lock").0
    }
    fn minute_of_day(&self) -> u32 {
        self.state.lock().expect("fake lock").1
    }
}

/// For tests: counts the restarts it was asked for.
#[derive(Default)]
pub struct FakeReboot {
    count: Mutex<u32>,
    fail: Mutex<bool>,
}

impl FakeReboot {
    pub fn count(&self) -> u32 {
        *self.count.lock().expect("fake lock")
    }

    pub fn fail_next(&self) {
        *self.fail.lock().expect("fake lock") = true;
    }
}

impl Reboot for FakeReboot {
    fn reboot(&self) -> Result<(), String> {
        if std::mem::take(&mut *self.fail.lock().expect("fake lock")) {
            return Err("no".to_owned());
        }
        *self.count.lock().expect("fake lock") += 1;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: i64 = CHECK_INTERVAL_SECS;

    #[test]
    fn a_check_is_due_after_a_day_or_never() {
        let s = Schedule::default();
        assert!(s.check_due(0, 1_000_000), "never checked");
        assert!(!s.check_due(1_000_000 - DAY + 1, 1_000_000));
        assert!(s.check_due(1_000_000 - DAY, 1_000_000));
    }

    #[test]
    fn a_failed_attempt_waits_an_hour() {
        let mut s = Schedule::default();
        s.attempted(1_000_000);
        assert!(!s.check_due(0, 1_000_000 + RETRY_SECS - 1));
        assert!(s.check_due(0, 1_000_000 + RETRY_SECS));
    }

    #[test]
    fn quiet_needs_the_window_idle_time_and_no_app() {
        let mut s = Schedule::default();
        let t0 = 1_000_000;
        assert!(!s.quiet(t0 + IDLE_SECS, 200), "nothing seen yet");
        s.seen(t0);
        let late = t0 + IDLE_SECS;
        assert!(s.quiet(late, 200));
        assert!(!s.quiet(late - 1, 200), "29:59 idle");
        assert!(!s.quiet(late, WINDOW_START_MINUTE - 1), "02:59");
        assert!(s.quiet(late, WINDOW_START_MINUTE), "03:00");
        assert!(s.quiet(late, WINDOW_END_MINUTE - 1), "04:59");
        assert!(!s.quiet(late, WINDOW_END_MINUTE), "05:00");
        s.activity(t0, true);
        assert!(!s.quiet(late, 200), "an app runs");
        s.activity(t0, false);
        assert!(s.quiet(late, 200));
        s.activity(late - 1, false);
        assert!(!s.quiet(late, 200), "activity resets the idle time");
    }

    #[test]
    fn seen_keeps_the_first_activity() {
        let mut s = Schedule::default();
        s.seen(10);
        s.seen(99_999);
        assert!(s.quiet(10 + IDLE_SECS, 200));
    }

    #[test]
    fn times_after_now_do_not_stop_the_schedule() {
        let now = 1_000_000;
        let mut s = Schedule::default();
        // A check remembered with a clock that ran a year ahead.
        assert!(s.check_due(now + 365 * DAY, now));
        s.attempted(now + DAY);
        assert!(s.check_due(0, now), "an attempt in the future");
        // Activity reported before the clock was set back: idle counts from now.
        s.activity(now + DAY, false);
        s.seen(now);
        assert!(!s.quiet(now + IDLE_SECS - 1, 200));
        assert!(s.quiet(now + IDLE_SECS, 200));
    }

    #[test]
    fn the_restart_is_announced_then_done_after_the_grace() {
        let mut s = Schedule::default();
        let t0 = 1_000_000;
        s.seen(t0);
        let now = t0 + IDLE_SECS;
        assert!(!s.restart_step(now, 200, true), "announced, not done");
        assert_eq!(s.pending_restart(), Some(now + GRACE_SECS));
        assert!(!s.restart_step(now + GRACE_SECS - 1, 200, true));
        assert_eq!(s.pending_restart(), Some(now + GRACE_SECS), "does not move");
        assert!(s.restart_step(now + GRACE_SECS, 200, true));
        assert!(
            s.restart_step(now + GRACE_SECS + 60, 200, true),
            "a failed reboot is tried at the next look"
        );
    }

    #[test]
    fn anything_that_stops_holding_clears_the_announcement() {
        let announced = || {
            let mut s = Schedule::default();
            s.seen(0);
            assert!(!s.restart_step(IDLE_SECS, 200, true));
            assert!(s.pending_restart().is_some());
            s
        };
        let mut s = announced();
        assert!(
            !s.restart_step(IDLE_SECS + 5, 200, false),
            "nothing staged / setting off"
        );
        assert_eq!(s.pending_restart(), None);
        let mut s = announced();
        assert!(
            !s.restart_step(IDLE_SECS + 5, WINDOW_END_MINUTE, true),
            "left the window"
        );
        assert_eq!(s.pending_restart(), None);
        let mut s = announced();
        assert!(s.activity(IDLE_SECS + 5, false), "activity calls it off");
        assert!(!s.activity(IDLE_SECS + 6, false), "and says so once");
        assert!(
            !s.restart_step(IDLE_SECS + GRACE_SECS, 200, true),
            "idle starts over"
        );
        let mut s = announced();
        assert!(s.cancel_restart());
        assert!(!s.cancel_restart());
    }

    #[test]
    fn an_announcement_too_far_ahead_is_replaced() {
        let mut s = Schedule::default();
        s.seen(0);
        assert!(!s.restart_step(IDLE_SECS, 200, true));
        // The clock moved back by an hour (idle time was restarted by `seen`).
        s.seen(IDLE_SECS - 3600);
        assert!(!s.restart_step(IDLE_SECS - 3600 + IDLE_SECS, 200, true));
        assert_eq!(
            s.pending_restart(),
            Some(IDLE_SECS - 3600 + IDLE_SECS + GRACE_SECS)
        );
    }

    #[test]
    fn a_failed_scheduled_download_is_due_after_an_hour() {
        let mut s = Schedule::default();
        assert!(!s.download_retry_due(5_000_000), "nothing failed");
        s.download_failed(1_000_000);
        assert!(!s.download_retry_due(1_000_000 + RETRY_SECS - 1));
        assert!(s.download_retry_due(1_000_000 + RETRY_SECS));
        assert!(
            s.download_retry_due(500_000),
            "a failure in the future counts as long ago"
        );
        s.download_begun();
        assert!(!s.download_retry_due(5_000_000));
    }

    #[test]
    fn seconds_files() {
        assert_eq!(parse_seconds("1700000000\n"), 1_700_000_000);
        assert_eq!(parse_seconds("junk"), 0);
        assert_eq!(parse_seconds("-5"), 0);
    }

    #[test]
    fn the_utc_fallback_counts_minutes() {
        assert_eq!(utc_minute_of_day(0), 0);
        assert_eq!(utc_minute_of_day(3 * 3600 + 120), 182);
        assert_eq!(utc_minute_of_day(86_400 + 59), 0);
    }

    #[test]
    fn the_system_clock_is_sane() {
        let c = SystemClock;
        assert!(c.now() > 1_700_000_000);
        assert!(c.minute_of_day() < 1440);
    }
}
