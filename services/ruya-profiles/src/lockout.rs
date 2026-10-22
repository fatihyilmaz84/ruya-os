//! Failed-PIN rate limiting: a few free attempts, then exponential back-off.
//! State is in memory only; restarting the service (root-only) resets it.

use std::collections::HashMap;
use std::time::{Duration, Instant};

pub const FREE_ATTEMPTS: u32 = 5;
pub const FIRST_LOCKOUT: Duration = Duration::from_secs(30);
pub const MAX_LOCKOUT: Duration = Duration::from_secs(3600);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Gate {
    /// Attempt may proceed.
    Open,
    /// Attempts are refused until this much time has passed.
    Locked(Duration),
}

#[derive(Debug, Default)]
struct Entry {
    failures: u32,
    locked_until: Option<Instant>,
}

#[derive(Debug, Default)]
pub struct Lockout {
    entries: HashMap<String, Entry>,
}

impl Lockout {
    pub fn check(&self, id: &str, now: Instant) -> Gate {
        match self.entries.get(id).and_then(|e| e.locked_until) {
            Some(until) if until > now => Gate::Locked(until - now),
            _ => Gate::Open,
        }
    }

    /// Records a failure. Returns how many attempts remain before the next lockout
    /// (0 means this failure triggered one).
    pub fn fail(&mut self, id: &str, now: Instant) -> u32 {
        let entry = self.entries.entry(id.to_owned()).or_default();
        entry.failures += 1;
        if entry.failures < FREE_ATTEMPTS {
            return FREE_ATTEMPTS - entry.failures;
        }
        // 5th failure -> 30 s, 6th -> 60 s, 7th -> 120 s ... capped at an hour.
        let doublings = (entry.failures - FREE_ATTEMPTS).min(16);
        let delay = FIRST_LOCKOUT
            .saturating_mul(1 << doublings)
            .min(MAX_LOCKOUT);
        entry.locked_until = Some(now + delay);
        0
    }

    pub fn attempts_left(&self, id: &str) -> u32 {
        let failures = self.entries.get(id).map_or(0, |e| e.failures);
        FREE_ATTEMPTS.saturating_sub(failures)
    }

    pub fn succeed(&mut self, id: &str) {
        self.entries.remove(id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn free_attempts_then_lock() {
        let mut l = Lockout::default();
        let t0 = Instant::now();
        for left in (1..FREE_ATTEMPTS).rev() {
            assert_eq!(l.check("p1", t0), Gate::Open);
            assert_eq!(l.fail("p1", t0), left);
        }
        assert_eq!(l.fail("p1", t0), 0);
        assert_eq!(l.check("p1", t0), Gate::Locked(FIRST_LOCKOUT));
        assert_eq!(l.check("p1", t0 + FIRST_LOCKOUT), Gate::Open);
    }

    #[test]
    fn backoff_doubles_and_caps() {
        let mut l = Lockout::default();
        let mut now = Instant::now();
        for _ in 0..FREE_ATTEMPTS {
            l.fail("p1", now);
        }
        let mut expected = FIRST_LOCKOUT;
        for _ in 0..12 {
            assert_eq!(l.check("p1", now), Gate::Locked(expected));
            now += expected;
            l.fail("p1", now);
            expected = (expected * 2).min(MAX_LOCKOUT);
        }
        assert_eq!(l.check("p1", now), Gate::Locked(MAX_LOCKOUT));
    }

    #[test]
    fn success_resets_and_profiles_are_independent() {
        let mut l = Lockout::default();
        let t0 = Instant::now();
        for _ in 0..FREE_ATTEMPTS {
            l.fail("p1", t0);
        }
        assert_eq!(l.check("p2", t0), Gate::Open);
        l.succeed("p1");
        assert_eq!(l.check("p1", t0), Gate::Open);
        assert_eq!(l.attempts_left("p1"), FREE_ATTEMPTS);
    }
}
