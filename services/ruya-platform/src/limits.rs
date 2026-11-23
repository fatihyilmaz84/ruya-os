//! What keeps a hostile caller small: a token bucket per caller and the checks every string
//! argument of the door passes before anything else reads it (ADR-022: "rate-limits, sanitises
//! every string and size"). Pure; time is passed in.

use std::collections::HashMap;
use std::hash::Hash;
use std::time::{Duration, Instant};

/// A burst of `capacity` calls, then one more every `refill`. A bucket that is full again is the
/// same as a new one, so it can be forgotten (`Buckets::forget_full`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rate {
    pub capacity: u32,
    pub refill: Duration,
}

/// The door's rate for each unique bus name and each app instance: a burst of 10, then 2 a second.
pub const CALLER_RATE: Rate = Rate {
    capacity: 10,
    refill: Duration::from_millis(500),
};

#[derive(Debug, Clone, Copy)]
struct Bucket {
    tokens: u32,
    /// When the last token was added (or the bucket was made).
    at: Instant,
}

impl Bucket {
    fn refill(&mut self, rate: Rate, now: Instant) {
        if self.tokens >= rate.capacity || rate.refill.is_zero() {
            self.tokens = rate.capacity;
            self.at = now;
            return;
        }
        let gone = now.saturating_duration_since(self.at);
        let earned = gone.as_nanos() / rate.refill.as_nanos();
        let earned = u32::try_from(earned).unwrap_or(u32::MAX);
        if earned > 0 {
            self.tokens = self.tokens.saturating_add(earned).min(rate.capacity);
            // The part of a token not earned yet is kept, so a steady caller is not cheated.
            self.at += rate.refill * earned.min(rate.capacity);
            if self.tokens == rate.capacity {
                self.at = now;
            }
        }
    }
}

/// One bucket per key (a unique name, an instance).
#[derive(Debug)]
pub struct Buckets<K> {
    rate: Rate,
    buckets: HashMap<K, Bucket>,
}

impl<K: Eq + Hash + Clone> Buckets<K> {
    pub fn new(rate: Rate) -> Self {
        Buckets {
            rate,
            buckets: HashMap::new(),
        }
    }

    /// Takes one token of `key`'s bucket; false (and nothing taken) when it is empty.
    pub fn take(&mut self, key: &K, now: Instant) -> bool {
        let rate = self.rate;
        let bucket = self.buckets.entry(key.clone()).or_insert(Bucket {
            tokens: rate.capacity,
            at: now,
        });
        bucket.refill(rate, now);
        if bucket.tokens == 0 {
            return false;
        }
        bucket.tokens -= 1;
        true
    }

    /// Drops `key`'s bucket (its name left the bus).
    pub fn forget(&mut self, key: &K) {
        self.buckets.remove(key);
    }

    /// Drops every bucket that is full again: it is the same as a new one, so nothing is lost and
    /// the map does not grow with keys that are gone.
    pub fn forget_full(&mut self, now: Instant) {
        let rate = self.rate;
        self.buckets.retain(|_, b| {
            b.refill(rate, now);
            b.tokens < rate.capacity
        });
    }

    pub fn len(&self) -> usize {
        self.buckets.len()
    }

    pub fn is_empty(&self) -> bool {
        self.buckets.is_empty()
    }
}

/// Why a string argument was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BadText {
    Empty,
    /// More than the argument's maximum, in bytes.
    TooLong,
    /// Not UTF-8 (a byte argument).
    NotUtf8,
    /// A control character (`char::is_control`: C0, DEL and C1).
    Control,
}

/// The checks of a string argument: not empty, at most `max` bytes, no control character. The
/// first gate of every string the door accepts; the argument's own form (an id, a key) is checked
/// after it.
pub fn text(s: &str, max: usize) -> Result<&str, BadText> {
    if s.is_empty() {
        return Err(BadText::Empty);
    }
    if s.len() > max {
        return Err(BadText::TooLong);
    }
    if s.chars().any(char::is_control) {
        return Err(BadText::Control);
    }
    Ok(s)
}

/// `text` for bytes from a file or a byte-array argument: UTF-8 first.
pub fn text_bytes(bytes: &[u8], max: usize) -> Result<&str, BadText> {
    if bytes.len() > max {
        return Err(BadText::TooLong);
    }
    let s = std::str::from_utf8(bytes).map_err(|_| BadText::NotUtf8)?;
    text(s, max)
}

/// The longest profile id, app id, capability key, scope and event name the door takes.
pub const MAX_PROFILE_ID: usize = ruya_ids::MAX_PROFILE_ID;
pub const MAX_APP_ID: usize = 255;
pub const MAX_CAPABILITY: usize = 32;
/// `app-flatpak-` + an escaped app id (each `-` four bytes) + `-` + an instance id + `.scope`,
/// bounded by systemd's unit-name limit.
pub const MAX_SCOPE: usize = 255;
pub const MAX_EVENT: usize = 16;

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: Rate = Rate {
        capacity: 3,
        refill: Duration::from_secs(1),
    };

    #[test]
    fn a_burst_then_one_per_refill() {
        let t0 = Instant::now();
        let mut b = Buckets::new(RATE);
        let k = ":1.5".to_owned();
        assert!(b.take(&k, t0) && b.take(&k, t0) && b.take(&k, t0));
        assert!(!b.take(&k, t0), "the burst is spent");
        assert!(!b.take(&k, t0 + Duration::from_millis(999)));
        assert!(b.take(&k, t0 + Duration::from_secs(1)), "one token back");
        assert!(!b.take(&k, t0 + Duration::from_millis(1500)));
        // Never more than the capacity, however long it waited.
        let later = t0 + Duration::from_secs(3600);
        assert!(b.take(&k, later) && b.take(&k, later) && b.take(&k, later));
        assert!(!b.take(&k, later));
    }

    #[test]
    fn each_key_has_its_own_bucket() {
        let t0 = Instant::now();
        let mut b = Buckets::new(RATE);
        let (a, c) = (":1.5".to_owned(), ":1.6".to_owned());
        for _ in 0..3 {
            assert!(b.take(&a, t0));
        }
        assert!(!b.take(&a, t0));
        assert!(b.take(&c, t0), "another caller is not slowed by the first");
    }

    #[test]
    fn a_refused_call_takes_nothing() {
        let t0 = Instant::now();
        let mut b = Buckets::new(RATE);
        let k = 1u32;
        for _ in 0..3 {
            assert!(b.take(&k, t0));
        }
        for _ in 0..100 {
            assert!(!b.take(&k, t0 + Duration::from_millis(500)));
        }
        assert!(
            b.take(&k, t0 + Duration::from_secs(1)),
            "the flood did not push it back"
        );
    }

    #[test]
    fn forgetting_keeps_a_spent_bucket() {
        let t0 = Instant::now();
        let mut b = Buckets::new(RATE);
        let (spent, used) = (1u32, 2u32);
        for _ in 0..3 {
            assert!(b.take(&spent, t0));
        }
        assert!(b.take(&used, t0));
        b.forget_full(t0);
        assert_eq!(b.len(), 2, "neither is full yet");
        assert!(!b.take(&spent, t0), "a forgotten-full pass is no refill");
        b.forget_full(t0 + Duration::from_secs(1));
        assert_eq!(b.len(), 1, "the used one is full again");
        b.forget(&spent);
        assert!(b.is_empty());
    }

    #[test]
    fn text_arguments() {
        assert_eq!(text("org.example.Racer", 255), Ok("org.example.Racer"));
        assert_eq!(text("", 10), Err(BadText::Empty));
        assert_eq!(text(&"x".repeat(11), 10), Err(BadText::TooLong));
        assert_eq!(text(&"x".repeat(10), 10), Ok("xxxxxxxxxx"));
        assert_eq!(text("é", 1), Err(BadText::TooLong), "bytes, not characters");
        for bad in ["a\nb", "a\u{0}b", "a\u{7f}", "a\u{85}b", "tab\t"] {
            assert_eq!(text(bad, 10), Err(BadText::Control), "{bad:?}");
        }
        assert_eq!(text("名前", 10), Ok("名前"));
    }

    #[test]
    fn byte_arguments() {
        assert_eq!(text_bytes(b"abc", 3), Ok("abc"));
        assert_eq!(text_bytes(&[0xff, 0xfe], 3), Err(BadText::NotUtf8));
        assert_eq!(text_bytes(b"abcd", 3), Err(BadText::TooLong));
        assert_eq!(text_bytes(b"a\x1bb", 3), Err(BadText::Control));
    }
}
