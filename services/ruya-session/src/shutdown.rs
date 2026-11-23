//! The system goes down: every app quits first (RUY-888).
//!
//! A profile's user manager (`user@<uid>.service`) cannot stop a frozen app ("Cannot stop frozen
//! unit") and kills it with SIGKILL when the system goes down, so a game frozen by the Hub or by a
//! profile switch lost what it saves at quit (the Dell, 2026-11-18). This service froze it, so it
//! thaws and stops it: logind's delay inhibitor lock holds the shutdown back until every app has
//! been stopped the way `Stop` does it. That happens after `PrepareForShutdown(true)` and before
//! logind queues the shutdown, while nothing has stopped yet; once the shutdown job is queued,
//! systemd refuses new jobs ("Transaction ... is destructive"), and every call this service makes
//! to a user manager (`systemctl --machine=<user>@.host`) starts a transient bridge unit.
//!
//! The order is here, with the OS behind closures (`follow_shutdowns`); `dbus::watch_shutdown`
//! is logind's side.

use std::future::Future;
use std::time::Duration;

use futures_lite::{Stream, StreamExt};

use crate::session::STOP_GRACE;

/// How long the stop of every app may hold the shutdown back: the backstop's `STOP_GRACE`, then a
/// moment for the kill's end to be reported. A registered app's save wait (RUY-1099) is part of
/// its `STOP_GRACE` here (`Session::stop_all`), so it adds nothing. logind waits at most `InhibitDelayMaxSec`, which the
/// image sets longer (`image/rootfs/usr/lib/systemd/logind.conf.d/50-ruyaos-inhibit-delay.conf`).
pub const STOP_ALL_WAIT: Duration = Duration::from_secs(STOP_GRACE.as_secs() + 5);

/// The inhibitor lock as `systemd-inhibit --list` shows it.
pub const INHIBIT_WHO: &str = "RuyaOS session";
pub const INHIBIT_WHY: &str = "Every app is stopped (and can save) before the system goes down";

/// Holds a delay lock (`take`: `None` when logind refused it) and follows logind's
/// `PrepareForShutdown` values (`signals`). At `true` every app is stopped (`stop_all`, which
/// returns when they have ended or its bound has passed), and only then the lock is dropped,
/// which lets the shutdown go on. At `false` (the shutdown was called off) a new lock is taken,
/// so the next one is held back too. Returns when `signals` ends.
pub async fn follow_shutdowns<L, T, TF, Sig, S, SF>(take: T, signals: Sig, stop_all: S)
where
    T: Fn() -> TF,
    TF: Future<Output = Option<L>>,
    Sig: Stream<Item = bool>,
    S: Fn() -> SF,
    SF: Future<Output = ()>,
{
    let mut signals = std::pin::pin!(signals);
    let mut lock = take().await;
    while let Some(start) = signals.next().await {
        if start {
            stop_all().await;
            // Closing the lock's file descriptor tells logind to go on.
            drop(lock.take());
        } else if lock.is_none() {
            lock = take().await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// A lock that writes "release N" into the log when it is dropped.
    struct Lock<'a> {
        n: usize,
        log: &'a RefCell<Vec<String>>,
    }

    impl Drop for Lock<'_> {
        fn drop(&mut self) {
            self.log.borrow_mut().push(format!("release {}", self.n));
        }
    }

    /// Runs `follow_shutdowns` over `values`; `grant` says whether each `take` gets a lock.
    fn run(values: &[bool], grant: bool) -> Vec<String> {
        let log = RefCell::new(Vec::new());
        let taken = RefCell::new(0);
        let take = || async {
            *taken.borrow_mut() += 1;
            let n = *taken.borrow();
            log.borrow_mut().push(format!("take {n}"));
            grant.then(|| Lock { n, log: &log })
        };
        let stop_all = || async {
            log.borrow_mut().push("stop-all begins".to_owned());
            // The apps take their time to quit: the lock must still be held meanwhile.
            futures_lite::future::yield_now().await;
            log.borrow_mut().push("stop-all done".to_owned());
        };
        let signals = futures_lite::stream::iter(values.to_vec());
        futures_lite::future::block_on(follow_shutdowns(take, signals, stop_all));
        log.into_inner()
    }

    #[test]
    fn the_lock_is_released_only_after_every_app_has_ended() {
        assert_eq!(
            run(&[true], true),
            ["take 1", "stop-all begins", "stop-all done", "release 1"]
        );
    }

    #[test]
    fn a_shutdown_called_off_takes_a_new_lock_for_the_next_one() {
        assert_eq!(
            run(&[true, false, true], true),
            [
                "take 1",
                "stop-all begins",
                "stop-all done",
                "release 1",
                "take 2",
                "stop-all begins",
                "stop-all done",
                "release 2",
            ]
        );
    }

    #[test]
    fn a_false_while_the_lock_is_held_takes_no_second_lock() {
        assert_eq!(run(&[false], true), ["take 1", "release 1"]);
    }

    #[test]
    fn without_a_lock_the_apps_are_still_stopped() {
        // logind refused the lock: it will not wait, but the apps are asked to quit anyway.
        assert_eq!(
            run(&[true], false),
            ["take 1", "stop-all begins", "stop-all done"]
        );
    }

    #[test]
    fn the_wait_covers_the_backstop() {
        assert!(STOP_ALL_WAIT > STOP_GRACE);
    }
}
