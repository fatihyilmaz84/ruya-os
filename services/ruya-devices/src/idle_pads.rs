//! Idle controllers (T-202, `Devices1.Bluetooth.ReportIdle`): a bonded Bluetooth pad that nobody
//! has touched for a while is disconnected to save its battery; it reconnects by itself on its
//! next button press. The service cannot see a pad's buttons, but the shell sees every key of the
//! console, so the shell reports how long the console has been quiet and this rule decides. The
//! rule is pure (time is passed in); `Bluetooth::report_idle` applies it.
//!
//! - A pad is disconnected at most once per idle period: after the call it stays in `told` until
//!   it is seen disconnected, or until a report shows activity.
//! - A pad counts as idle only from the moment it was seen connected, so one that has just
//!   reconnected (its button press may not have been a key the shell saw) gets the whole timeout.
//! - `hold` (an app is in front, an install runs) makes nothing idle and restarts the count when
//!   it ends.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

/// What the shell reported (`ReportIdle`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IdleReport {
    pub idle: Duration,
    /// Zero: never.
    pub timeout: Duration,
    pub hold: bool,
}

impl IdleReport {
    pub fn from_seconds(idle: u32, timeout: u32, hold: bool) -> Self {
        IdleReport {
            idle: Duration::from_secs(u64::from(idle)),
            timeout: Duration::from_secs(u64::from(timeout)),
            hold,
        }
    }
}

/// A listed pad, as the rule needs it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pad {
    pub id: String,
    pub connected: bool,
}

#[derive(Debug, Default)]
pub struct IdlePads {
    /// When each connected pad was first seen connected.
    connected_since: HashMap<String, Instant>,
    /// Pads already told to disconnect in this idle period.
    told: HashSet<String>,
    /// The last time a report said "hold".
    last_hold: Option<Instant>,
}

impl IdlePads {
    pub fn new() -> Self {
        Self::default()
    }

    /// The ids to disconnect now. Call it with every report and the current pad list.
    pub fn decide(&mut self, now: Instant, report: IdleReport, pads: &[Pad]) -> Vec<String> {
        // Bookkeeping first: a pad that is not connected is forgotten (so a reconnect starts over).
        self.connected_since
            .retain(|id, _| pads.iter().any(|p| p.connected && &p.id == id));
        self.told
            .retain(|id| pads.iter().any(|p| p.connected && &p.id == id));
        for pad in pads.iter().filter(|p| p.connected) {
            self.connected_since.entry(pad.id.clone()).or_insert(now);
        }

        if report.hold {
            self.last_hold = Some(now);
        }
        if report.timeout.is_zero() || report.hold || report.idle < report.timeout {
            // Activity, a hold or "never": the next idle period starts from scratch.
            self.told.clear();
            return Vec::new();
        }
        let since_hold = self.last_hold.map(|t| now.saturating_duration_since(t));

        let mut out = Vec::new();
        for pad in pads.iter().filter(|p| p.connected) {
            if self.told.contains(&pad.id) {
                continue;
            }
            let seen = self
                .connected_since
                .get(&pad.id)
                .map_or(Duration::ZERO, |t| now.saturating_duration_since(*t));
            let mut idle = report.idle.min(seen);
            if let Some(held) = since_hold {
                idle = idle.min(held);
            }
            if idle >= report.timeout {
                self.told.insert(pad.id.clone());
                out.push(pad.id.clone());
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIN: Duration = Duration::from_secs(60);

    fn pad(id: &str, connected: bool) -> Pad {
        Pad {
            id: id.to_owned(),
            connected,
        }
    }

    fn report(idle_min: u64, timeout_min: u64) -> IdleReport {
        IdleReport {
            idle: MIN * idle_min as u32,
            timeout: MIN * timeout_min as u32,
            hold: false,
        }
    }

    #[test]
    fn a_pad_with_input_is_not_touched() {
        let mut rule = IdlePads::new();
        let t0 = Instant::now();
        let pads = [pad("A", true)];
        assert!(rule.decide(t0, report(0, 15), &pads).is_empty());
        assert!(rule.decide(t0 + MIN * 14, report(14, 15), &pads).is_empty());
        // Input again: the count starts over.
        assert!(rule.decide(t0 + MIN * 20, report(0, 15), &pads).is_empty());
        assert!(rule.decide(t0 + MIN * 34, report(14, 15), &pads).is_empty());
    }

    #[test]
    fn an_idle_pad_is_disconnected_once() {
        let mut rule = IdlePads::new();
        let t0 = Instant::now();
        let pads = [pad("A", true), pad("B", false)];
        // The first report ever: the pad was seen connected just now, so it is not idle yet.
        assert!(rule.decide(t0, report(20, 15), &pads).is_empty());
        let t1 = t0 + MIN * 15;
        assert_eq!(rule.decide(t1, report(35, 15), &pads), vec!["A".to_owned()]);
        // The disconnect has not shown in the list yet, and the shell reports again.
        assert!(rule.decide(t1 + MIN, report(36, 15), &pads).is_empty());
        assert!(rule.decide(t1 + MIN * 2, report(37, 15), &pads).is_empty());
    }

    #[test]
    fn a_reconnect_resets() {
        let mut rule = IdlePads::new();
        let t0 = Instant::now();
        rule.decide(t0, report(0, 15), &[pad("A", true)]);
        let t1 = t0 + MIN * 15;
        assert_eq!(
            rule.decide(t1, report(15, 15), &[pad("A", true)]),
            vec!["A".to_owned()]
        );
        // It is seen disconnected, then connected again (a button the shell did not see).
        assert!(rule
            .decide(t1 + MIN, report(16, 15), &[pad("A", false)])
            .is_empty());
        let t2 = t1 + MIN * 2;
        assert!(rule
            .decide(t2, report(17, 15), &[pad("A", true)])
            .is_empty());
        assert!(rule
            .decide(t2 + MIN * 14, report(31, 15), &[pad("A", true)])
            .is_empty());
        assert_eq!(
            rule.decide(t2 + MIN * 15, report(32, 15), &[pad("A", true)]),
            vec!["A".to_owned()]
        );
    }

    #[test]
    fn activity_allows_the_next_period_to_disconnect_again() {
        let mut rule = IdlePads::new();
        let t0 = Instant::now();
        let pads = [pad("A", true)];
        rule.decide(t0, report(0, 5), &pads);
        assert_eq!(
            rule.decide(t0 + MIN * 5, report(5, 5), &pads),
            vec!["A".to_owned()]
        );
        // The disconnect failed (still listed connected); the user presses a key; later idle again.
        assert!(rule.decide(t0 + MIN * 6, report(0, 5), &pads).is_empty());
        assert_eq!(
            rule.decide(t0 + MIN * 11, report(5, 5), &pads),
            vec!["A".to_owned()]
        );
    }

    #[test]
    fn never_and_hold_leave_pads_alone() {
        let mut rule = IdlePads::new();
        let t0 = Instant::now();
        let pads = [pad("A", true)];
        rule.decide(t0, report(0, 0), &pads);
        assert!(rule.decide(t0 + MIN * 60, report(60, 0), &pads).is_empty());
        let held = IdleReport {
            hold: true,
            ..report(60, 15)
        };
        assert!(rule.decide(t0 + MIN * 61, held, &pads).is_empty());
        // The hold ends (the game closed) with the console long quiet: the pad gets the whole
        // timeout from the end of the hold.
        assert!(rule.decide(t0 + MIN * 62, report(62, 15), &pads).is_empty());
        assert!(rule.decide(t0 + MIN * 75, report(75, 15), &pads).is_empty());
        assert_eq!(
            rule.decide(t0 + MIN * 76, report(76, 15), &pads),
            vec!["A".to_owned()]
        );
    }

    #[test]
    fn each_connected_pad_is_counted_from_its_own_connection() {
        let mut rule = IdlePads::new();
        let t0 = Instant::now();
        rule.decide(t0, report(10, 15), &[pad("A", true)]);
        let t1 = t0 + MIN * 10;
        // B joins at t1; A has been connected for 10 minutes.
        let both = [pad("A", true), pad("B", true)];
        assert!(rule.decide(t1, report(20, 15), &both).is_empty());
        let t2 = t0 + MIN * 15;
        assert_eq!(rule.decide(t2, report(25, 15), &both), vec!["A".to_owned()]);
        assert_eq!(
            rule.decide(t1 + MIN * 15, report(35, 15), &both),
            vec!["B".to_owned()]
        );
    }
}
