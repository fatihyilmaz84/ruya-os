//! The download rate of a job (ADR-026 job record v2, `rate_bps`): byte deltas sampled at most
//! once a second, exponential smoothing with a 5 s time constant, 0 after 10 s without a byte.
//! Pure: the time is passed in as monotonic milliseconds.

/// Samples closer together than this are not taken (the record's "sampled once a second").
pub const SAMPLE_MS: u64 = 1000;
/// The smoothing's time constant.
pub const TIME_CONSTANT_MS: f64 = 5000.0;
/// No byte for this long: the rate is 0 (unknown), not a fading guess.
pub const STALL_MS: u64 = 10_000;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Rate {
    /// The last sample taken: (milliseconds, bytes).
    last: Option<(u64, u64)>,
    /// When the byte count last grew.
    last_byte_ms: Option<u64>,
    /// Bytes per second; None until the first delta.
    smoothed: Option<f64>,
}

impl Rate {
    /// `bytes`: the job's byte count at `now_ms` (never smaller than before).
    pub fn sample(&mut self, now_ms: u64, bytes: u64) {
        let Some((at, before)) = self.last else {
            self.last = Some((now_ms, bytes));
            return;
        };
        if now_ms < at + SAMPLE_MS {
            return;
        }
        let delta = bytes.saturating_sub(before);
        let dt = (now_ms - at) as f64;
        let instant = delta as f64 * 1000.0 / dt;
        self.smoothed = Some(match self.smoothed {
            // The first delta is the best guess there is: smoothing it up from 0 would show a
            // rate far too low for the first seconds.
            None => instant,
            Some(rate) => rate + (1.0 - (-dt / TIME_CONSTANT_MS).exp()) * (instant - rate),
        });
        if delta > 0 {
            self.last_byte_ms = Some(now_ms);
        }
        self.last = Some((now_ms, bytes));
    }

    /// Bytes per second at `now_ms`; 0 = unknown (no delta yet, or 10 s without a byte).
    pub fn bps(&self, now_ms: u64) -> u64 {
        match (self.smoothed, self.last_byte_ms) {
            (Some(rate), Some(at)) if now_ms.saturating_sub(at) < STALL_MS => rate.round() as u64,
            _ => 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_until_the_first_delta() {
        let mut r = Rate::default();
        assert_eq!(r.bps(0), 0);
        r.sample(0, 0);
        assert_eq!(r.bps(500), 0);
        r.sample(500, 4_000_000);
        assert_eq!(
            r.bps(500),
            0,
            "a sample within a second of the last is not taken"
        );
    }

    #[test]
    fn the_first_delta_is_the_rate() {
        let mut r = Rate::default();
        r.sample(0, 0);
        r.sample(1000, 10_000_000);
        assert_eq!(r.bps(1000), 10_000_000);
    }

    #[test]
    fn a_change_is_smoothed_over_five_seconds() {
        let mut r = Rate::default();
        r.sample(0, 0);
        r.sample(1000, 10_000_000); // 10 MB/s
        r.sample(2000, 10_000_000 + 20_000_000); // then 20 MB/s for a second
        let after_one = r.bps(2000);
        // 10 + (1 - e^-0.2) * 10 = 11.81 MB/s
        assert_eq!(after_one, 11_812_692);
        let mut bytes = 30_000_000;
        for s in 3..=30 {
            bytes += 20_000_000;
            r.sample(s * 1000, bytes);
        }
        assert!(r.bps(30_000) > 19_900_000, "settles at the new rate");
    }

    #[test]
    fn zero_after_ten_seconds_without_a_byte() {
        let mut r = Rate::default();
        r.sample(0, 0);
        r.sample(1000, 5_000_000);
        assert_eq!(r.bps(10_999), 5_000_000);
        assert_eq!(
            r.bps(11_000),
            0,
            "10 s after the last byte, without any sample"
        );
        r.sample(12_000, 5_000_000);
        assert_eq!(r.bps(12_000), 0, "samples without bytes do not revive it");
        r.sample(13_000, 6_000_000);
        assert!(r.bps(13_000) > 0, "a byte does");
    }
}
