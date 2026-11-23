//! The apps' lifecycle, told to Platform1 (RUY-1099, ADR-022): the sender of the core's
//! `LifecycleNotice`s (`Session::with_lifecycle`) to `org.ruyaos.Platform1.Manage.NotifyLifecycle`,
//! one call per own scope of the instance (`Session::scope_lister`), since Platform1 knows an app
//! instance by its Flatpak scope.
//!
//! The notices are sent in the order the core made them, on a thread of their own (`run`), so a
//! slow listing or a slow Platform1 holds up neither a `Session1` call nor the event loop:
//! `Background` and `Resume` are answered at once and get `NOTIFY_SLACK`. A `Stopping` is waited
//! for on a thread of its own, and its whole wait (the scope listing, then all scopes asked at
//! once) ends by its deadline counted from the notice (`save_wait`); then the core sends the
//! SIGTERM (`Session::saved`). Platform1 missing, failing or late counts as nothing registered
//! (`not-registered`), logged once per start of this service. Every call is best effort: nothing
//! here can keep a freeze, a thaw or a stop from happening, and a stop waits at most its deadline.

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::task::Poll;
use std::time::{Duration, Instant};

use async_channel::Receiver;
use zbus::Connection;

use crate::dbus::{lock, Shared};
use crate::runner_choice::ask_within;
use crate::session::{LifecycleEvent, LifecycleNotice};
use crate::spawner::ScopeLister;

pub const PLATFORM_NAME: &str = "org.ruyaos.Platform1";
pub const PLATFORM_PATH: &str = "/org/ruyaos/Platform1";
pub const MANAGE_INTERFACE: &str = "org.ruyaos.Platform1.Manage";

/// How long a `NotifyLifecycle` of a `Background` or a `Resume` (answered at once) may take. A
/// `Stopping` has what is left of its deadline instead (round 2, lead: never beyond it).
pub const NOTIFY_SLACK: Duration = Duration::from_secs(2);

/// The answer of one `NotifyLifecycle`.
pub type Reply = Pin<Box<dyn Future<Output = zbus::Result<String>> + Send>>;
/// `NotifyLifecycle(profile_id, scope, event, value_ms)`: Platform1 (`platform_notify`) or a fake.
pub type Notify = Arc<dyn Fn(String, String, &'static str, u64) -> Reply + Send + Sync>;

/// `Manage.NotifyLifecycle` over `connection` (root-only in Platform1; this service is root).
pub fn platform_notify(connection: Connection) -> Notify {
    Arc::new(move |profile, scope, event, value_ms| {
        let connection = connection.clone();
        Box::pin(async move {
            connection
                .call_method(
                    Some(PLATFORM_NAME),
                    PLATFORM_PATH,
                    Some(MANAGE_INTERFACE),
                    "NotifyLifecycle",
                    &(profile.as_str(), scope.as_str(), event, value_ms),
                )
                .await?
                .body()
                .deserialize::<String>()
        })
    })
}

/// The way to Platform1: the call, its slack, and whether its failure was logged yet.
#[derive(Clone)]
pub struct Link {
    notify: Notify,
    slack: Duration,
    warned: Arc<AtomicBool>,
}

impl Link {
    pub fn new(notify: Notify, slack: Duration) -> Self {
        Link {
            notify,
            slack,
            warned: Arc::new(AtomicBool::new(false)),
        }
    }

    /// One `NotifyLifecycle` for `scope` of `profile`, for at most `limit`: Platform1's status, or
    /// `not-registered` when it did not answer in time or the call failed (no Platform1 on the
    /// bus, its policy refused it), logged once per start of this service.
    async fn tell(
        &self,
        profile: &str,
        scope: &str,
        event: LifecycleEvent,
        limit: Duration,
    ) -> String {
        let (name, value_ms) = event.as_call();
        let call = (self.notify)(profile.to_owned(), scope.to_owned(), name, value_ms);
        match ask_within(limit, call).await {
            Ok(status) => status,
            Err(why) => {
                if !self.warned.swap(true, Ordering::Relaxed) {
                    eprintln!(
                        "ruya-session: Platform1 NotifyLifecycle failed ({why}): no app is told its lifecycle while it fails, a stop does not wait"
                    );
                }
                "not-registered".to_owned()
            }
        }
    }
}

/// Sends every notice from `notices`, in order, until the core drops its outbox. Blocks in the
/// scope listing: run it on its own thread (`run`).
pub async fn send_notices(session: Shared, notices: Receiver<LifecycleNotice>, link: Link) {
    while let Ok(notice) = notices.recv().await {
        let lister = lock(&session).scope_lister(&notice.instance);
        if let LifecycleEvent::Stopping { .. } = notice.event {
            // Waited for apart, so the next notices (another app's Resume) do not wait for it.
            let (waiting, link) = (session.clone(), link.clone());
            let instance = notice.instance.clone();
            let spawned = std::thread::Builder::new()
                .name("save-wait".to_owned())
                .spawn(move || {
                    futures_lite::future::block_on(save_wait(&waiting, &link, &notice, lister))
                });
            if let Err(err) = spawned {
                eprintln!("ruya-session: cannot wait for {instance} to save: {err}");
                lock(&session).saved(&instance, Instant::now);
            }
            continue;
        }
        for scope in lister() {
            let status = link
                .tell(&notice.profile, &scope, notice.event, link.slack)
                .await;
            if status != "ok" && status != "not-registered" {
                eprintln!(
                    "ruya-session: Platform1 answered {status} to {} of {scope}",
                    notice.event.as_call().0
                );
            }
        }
    }
}

/// The save wait of `notice` (a `Stopping`), all of it within its deadline from `notice.at`: the
/// instance's scopes are listed (`lister`, on a thread of its own: a listing past the deadline
/// counts as none), each is told `Stopping` with what is left of the deadline and asked for at
/// most that long, all at once; then the stop (`Session::saved`).
async fn save_wait(session: &Shared, link: &Link, notice: &LifecycleNotice, lister: ScopeLister) {
    let LifecycleEvent::Stopping { deadline_ms } = notice.event else {
        return;
    };
    let end = notice.at + Duration::from_millis(deadline_ms);
    let started = Instant::now();
    let scopes = list_by(lister, end).await.unwrap_or_else(|| {
        eprintln!(
            "ruya-session: the scopes of {} were not listed in time: it is stopped without a Stopping",
            notice.instance
        );
        Vec::new()
    });
    let left = end.saturating_duration_since(Instant::now());
    let event = LifecycleEvent::Stopping {
        deadline_ms: u64::try_from(left.as_millis()).unwrap_or(u64::MAX),
    };
    let answers = join_all(
        scopes
            .iter()
            .map(|scope| link.tell(&notice.profile, scope, event, left))
            .collect(),
    )
    .await;
    if !answers.iter().all(|a| a == "not-registered") {
        eprintln!(
            "ruya-session: {} answered Stopping with {} in {} ms",
            notice.instance,
            answers.join(","),
            started.elapsed().as_millis()
        );
    }
    lock(session).saved(&notice.instance, Instant::now);
}

/// `lister`'s scopes, listed on a thread of its own; `None` when they are not there by `end` (or
/// the thread cannot start).
async fn list_by(lister: ScopeLister, end: Instant) -> Option<Vec<String>> {
    let (tx, rx) = async_channel::bounded(1);
    std::thread::Builder::new()
        .name("scope-list".to_owned())
        .spawn(move || {
            let _ = tx.send_blocking(lister());
        })
        .ok()?;
    futures_lite::future::or(async { rx.recv().await.ok() }, async {
        async_io::Timer::at(end).await;
        None
    })
    .await
}

/// Every future of `futures` to its end, side by side; the outputs in their order.
async fn join_all<F: Future>(futures: Vec<F>) -> Vec<F::Output> {
    let mut futures: Vec<Pin<Box<F>>> = futures.into_iter().map(Box::pin).collect();
    let mut outputs: Vec<Option<F::Output>> = futures.iter().map(|_| None).collect();
    futures_lite::future::poll_fn(|cx| {
        let mut pending = false;
        for (future, output) in futures.iter_mut().zip(outputs.iter_mut()) {
            if output.is_none() {
                match future.as_mut().poll(cx) {
                    Poll::Ready(value) => *output = Some(value),
                    Poll::Pending => pending = true,
                }
            }
        }
        if pending {
            Poll::Pending
        } else {
            Poll::Ready(())
        }
    })
    .await;
    outputs.into_iter().flatten().collect()
}

/// Starts `send_notices` on a thread of its own. When it cannot start, the outbox closes with
/// the receiver, and the core tells nothing and stops at once.
pub fn run(session: Shared, notices: Receiver<LifecycleNotice>, link: Link) {
    if let Err(err) = std::thread::Builder::new()
        .name("lifecycle".to_owned())
        .spawn(move || futures_lite::future::block_on(send_notices(session, notices, link)))
    {
        eprintln!("ruya-session: cannot tell Platform1 the apps' lifecycle: {err}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dbus::DynSpawner;
    use crate::directory::ProfileSnapshot;
    use crate::session::{Session, Status, SAVE_WAIT};
    use crate::spawner::{unit_name, FakeSpawner, UnitEvent};
    use std::sync::Mutex;

    const APP: &str = "org.ruyaos.Racer";
    const SCOPE_A: &str = "app-flatpak-org.ruyaos.Racer-11.scope";
    const SCOPE_B: &str = "app-flatpak-org.ruyaos.Racer-12.scope";

    /// One `NotifyLifecycle` the fake got: profile, scope, event, value.
    type Call = (String, String, &'static str, u64);

    /// A fake Platform1: records each call, then answers with `answer(event)`.
    fn fake(
        answer: impl Fn(&'static str) -> Reply + Send + Sync + 'static,
    ) -> (Notify, Arc<Mutex<Vec<Call>>>) {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let log = calls.clone();
        let notify: Notify = Arc::new(move |profile, scope, event, value| {
            log.lock().unwrap().push((profile, scope, event, value));
            answer(event)
        });
        (notify, calls)
    }

    fn reply(status: &'static str) -> Reply {
        Box::pin(async move { Ok(status.to_owned()) })
    }

    /// APP running for p1 with two own scopes, its lifecycle sent through `notify` (save wait
    /// `wait`, slack `slack`); the spawner's observer for its calls.
    fn running(notify: Notify, wait: Duration, slack: Duration) -> (Shared, String, FakeSpawner) {
        running_listed_in(notify, wait, slack, Duration::ZERO)
    }

    /// `running`, with a scope listing that takes `listing`.
    fn running_listed_in(
        notify: Notify,
        wait: Duration,
        slack: Duration,
        listing: Duration,
    ) -> (Shared, String, FakeSpawner) {
        let unit = unit_name("ruya-p1", APP);
        let fake = FakeSpawner::new()
            .with_app(APP)
            .with_freeze_never(APP)
            .with_scopes(&unit, &[SCOPE_A, SCOPE_B])
            .with_scope_delay(listing);
        let spy = fake.observer();
        let spawner: DynSpawner = Box::new(fake);
        let (outbox, notices) = async_channel::unbounded();
        let session = Session::new(spawner, ProfileSnapshot::new(["p1".to_owned()]), vec![])
            .with_lifecycle(outbox, wait);
        let shared: Shared = Arc::new(Mutex::new(session));
        let (status, launched) = lock(&shared).launch(APP, "p1", 1, &[]);
        assert_eq!((status, launched.as_str()), (Status::Ok, unit.as_str()));
        lock(&shared).on_event(UnitEvent::Started { unit: unit.clone() });
        run(shared.clone(), notices, Link::new(notify, slack));
        (shared, unit, spy)
    }

    /// How long after `start` the spawner was told to stop `unit` (within 10 s).
    fn stopped_after(spy: &FakeSpawner, unit: &str, start: Instant) -> Duration {
        let stop = format!("stop {unit}");
        while !spy.calls().contains(&stop) {
            assert!(start.elapsed() < Duration::from_secs(10), "never stopped");
            std::thread::sleep(Duration::from_millis(5));
        }
        start.elapsed()
    }

    fn wait_for_calls(calls: &Mutex<Vec<Call>>, n: usize) -> Vec<Call> {
        let start = Instant::now();
        loop {
            let now = calls.lock().unwrap().clone();
            if now.len() >= n {
                return now;
            }
            assert!(start.elapsed() < Duration::from_secs(10), "{now:?}");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn a_hold_and_its_end_reach_every_own_scope_in_order() {
        let (notify, calls) = fake(|_| reply("ok"));
        let (shared, unit, _) = running(notify, SAVE_WAIT, NOTIFY_SLACK);
        let t0 = Instant::now();
        assert_eq!(lock(&shared).freeze(&unit, Some("p1"), t0), Status::Ok);
        assert_eq!(
            lock(&shared).thaw(&unit, Some("p1"), t0 + Duration::from_millis(40)),
            Status::Ok
        );
        let p = |scope: &str, event, value| ("p1".to_owned(), scope.to_owned(), event, value);
        assert_eq!(
            wait_for_calls(&calls, 4),
            [
                p(SCOPE_A, "background", 0),
                p(SCOPE_B, "background", 0),
                p(SCOPE_A, "resume", 40),
                p(SCOPE_B, "resume", 40),
            ]
        );
    }

    #[test]
    fn an_absent_or_unregistered_platform_delays_no_stop() {
        let absent: fn(&'static str) -> Reply =
            |_| Box::pin(async { Err(zbus::Error::Failure("ServiceUnknown".into())) });
        let unregistered: fn(&'static str) -> Reply = |_| reply("not-registered");
        // Close game and power off alike: the SIGTERM at once.
        for (answer, power_off) in [
            (absent, false),
            (unregistered, false),
            (absent, true),
            (unregistered, true),
        ] {
            let (notify, calls) = fake(answer);
            let (shared, unit, spy) = running(notify, SAVE_WAIT, NOTIFY_SLACK);
            let start = Instant::now();
            if power_off {
                assert_eq!(lock(&shared).stop_all(Instant::now).len(), 1);
            } else {
                assert_eq!(lock(&shared).stop(&unit, Instant::now()), Status::Ok);
            }
            assert!(stopped_after(&spy, &unit, start) < Duration::from_secs(1));
            // Each scope is told what is left of the 5 s.
            for call in wait_for_calls(&calls, 2) {
                assert_eq!(call.2, "stopping");
                assert!((4000..=5000).contains(&call.3), "{call:?}");
            }
        }
    }

    #[test]
    fn the_sigterm_waits_for_the_save_of_a_registered_app() {
        let (saved_tx, saved_rx) = async_channel::bounded::<()>(1);
        // Each scope's Stopping is answered "saved" once the test lets one save.
        let (notify, _) = fake(move |event| {
            let saved = saved_rx.clone();
            match event {
                "stopping" => Box::pin(async move {
                    saved
                        .recv()
                        .await
                        .map(|()| "saved".to_owned())
                        .map_err(|_| zbus::Error::Failure("closed".into()))
                }),
                _ => reply("ok"),
            }
        });
        let (shared, unit, spy) = running(notify, SAVE_WAIT, NOTIFY_SLACK);
        assert_eq!(lock(&shared).stop(&unit, Instant::now()), Status::Ok);
        std::thread::sleep(Duration::from_millis(300));
        assert!(!spy.calls().contains(&format!("stop {unit}")), "saving");
        let start = Instant::now();
        // The stop waits for both scopes' answers.
        saved_tx.send_blocking(()).unwrap();
        std::thread::sleep(Duration::from_millis(100));
        assert!(
            !spy.calls().contains(&format!("stop {unit}")),
            "one scope saving"
        );
        saved_tx.send_blocking(()).unwrap();
        assert!(stopped_after(&spy, &unit, start) < Duration::from_secs(1));
    }

    #[test]
    fn a_slow_scope_listing_does_not_push_the_stop_past_the_deadline() {
        let (notify, calls) = fake(|_| reply("saved"));
        let wait = Duration::from_millis(300);
        let (shared, unit, spy) =
            running_listed_in(notify, wait, NOTIFY_SLACK, Duration::from_secs(3));
        let start = Instant::now();
        assert_eq!(lock(&shared).stop_all(Instant::now).len(), 1);
        let after = stopped_after(&spy, &unit, start);
        assert!(after >= wait, "{after:?}");
        assert!(after < wait + Duration::from_millis(300), "{after:?}");
        assert!(
            calls.lock().unwrap().is_empty(),
            "listed too late: no Stopping"
        );
    }

    #[test]
    fn a_platform_that_never_answers_holds_the_stop_for_the_deadline_only() {
        let (notify, _) = fake(|_| Box::pin(futures_lite::future::pending()));
        let wait = Duration::from_millis(300);
        let slack = Duration::from_millis(400);
        let (shared, unit, spy) = running(notify, wait, slack);
        let start = Instant::now();
        assert_eq!(lock(&shared).stop(&unit, Instant::now()), Status::Ok);
        let after = stopped_after(&spy, &unit, start);
        assert!(after >= wait, "{after:?}");
        // The slack never adds to a Stopping's deadline (it is longer than the margin here).
        assert!(after < wait + Duration::from_millis(300), "{after:?}");
        // A freeze and a thaw never wait for Platform1: the core answers at once, the notices go
        // from the sender's thread.
        let (notify, _) = fake(|_| Box::pin(futures_lite::future::pending()));
        let (shared, unit, _) = running(notify, wait, slack);
        let start = Instant::now();
        assert_eq!(lock(&shared).freeze(&unit, Some("p1"), start), Status::Ok);
        assert_eq!(lock(&shared).thaw(&unit, Some("p1"), start), Status::Ok);
        assert!(start.elapsed() < Duration::from_millis(100));
    }
}
