//! Debounce for the signal watchers: wait for a quiet moment after a burst, but never longer than
//! a maximum, so a stream of signals (busy Wi-Fi, a PipeWire burst, a room of BLE devices) cannot
//! hold a refresh off forever.

use std::time::{Duration, Instant};

use futures_lite::{future, Stream, StreamExt};

/// Quiet time after the last signal before the state is read again.
pub const QUIET: Duration = Duration::from_millis(300);

/// A burst is read after this long at most, however busy the bus stays.
pub const MAX_WAIT: Duration = Duration::from_secs(1);

/// The clock-free rule: pure, so a test drives it with a fake clock.
#[derive(Debug, Clone, Copy)]
pub struct Debounce {
    quiet: Duration,
    cap: Instant,
}

impl Debounce {
    /// A burst that started at `start`; `limit` is an earlier hard stop (e.g. a scan's deadline).
    pub fn new(start: Instant, quiet: Duration, max: Duration, limit: Option<Instant>) -> Self {
        let cap = start + max;
        Debounce {
            quiet,
            cap: limit.map_or(cap, |l| l.min(cap)),
        }
    }

    /// Until when to wait for the next signal, given that the last one came at `last`.
    pub fn deadline(&self, last: Instant) -> Instant {
        (last + self.quiet).min(self.cap)
    }

    /// True once the maximum wait has run out: read now, whatever still arrives.
    pub fn exhausted(&self, now: Instant) -> bool {
        now >= self.cap
    }
}

/// Swallows the rest of a burst: returns after `quiet` without a signal, after `max` at most, or
/// when the stream ends.
pub async fn settle<S>(stream: &mut S, quiet: Duration, max: Duration, limit: Option<Instant>)
where
    S: Stream + Unpin,
{
    let rule = Debounce::new(Instant::now(), quiet, max, limit);
    let mut last = Instant::now();
    loop {
        let deadline = rule.deadline(last);
        let got = future::or(async { stream.next().await.is_some() }, async {
            async_io::Timer::at(deadline).await;
            false
        })
        .await;
        let now = Instant::now();
        if !got || rule.exhausted(now) {
            return;
        }
        last = now;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Plays a signal every `gap` on a fake clock and returns when the refresh would fire.
    fn fire_time(rule: Debounce, start: Instant, gap: Duration, signals: u32) -> Duration {
        let mut now = start;
        let mut left = signals;
        loop {
            let deadline = rule.deadline(now);
            let next = now + gap;
            if left > 0 && next < deadline {
                left -= 1;
                now = next;
                if rule.exhausted(now) {
                    return now - start;
                }
            } else {
                return deadline - start;
            }
        }
    }

    #[test]
    fn a_signal_every_100ms_fires_within_the_cap() {
        let start = Instant::now();
        let rule = Debounce::new(start, QUIET, MAX_WAIT, None);
        let at = fire_time(rule, start, Duration::from_millis(100), 10_000);
        assert!(at <= Duration::from_secs(1), "fired after {at:?}");
    }

    #[test]
    fn a_quiet_bus_fires_after_the_quiet_time() {
        let start = Instant::now();
        let rule = Debounce::new(start, QUIET, MAX_WAIT, None);
        assert_eq!(
            fire_time(rule, start, Duration::from_millis(100), 2),
            Duration::from_millis(500)
        );
    }

    #[test]
    fn a_nearer_limit_wins() {
        let start = Instant::now();
        let limit = start + Duration::from_millis(400);
        let rule = Debounce::new(start, QUIET, MAX_WAIT, Some(limit));
        let at = fire_time(rule, start, Duration::from_millis(100), 10_000);
        assert!(at <= Duration::from_millis(400), "fired after {at:?}");
    }

    #[test]
    fn settle_returns_when_the_stream_stays_busy() {
        // Real clock, a short cap: a stream that never goes quiet still lets settle return.
        let mut busy = Box::pin(futures_lite::stream::unfold((), |()| async {
            async_io::Timer::after(Duration::from_millis(20)).await;
            Some(((), ()))
        }));
        let started = Instant::now();
        future::block_on(settle(
            &mut busy,
            Duration::from_millis(100),
            Duration::from_millis(300),
            None,
        ));
        assert!(started.elapsed() < Duration::from_millis(1500));
    }
}
