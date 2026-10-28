//! org.ruyaos.Session1 on D-Bus. Thin adapter: the rules live in `session.rs`. OS events arrive
//! over a channel (`forward`) and leave as signals; a timer kills apps that ignore `Stop`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use async_channel::Receiver;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedValue, Value};
use zbus::{interface, Connection};

use crate::directory::ProfileSnapshot;
use crate::session::{Notice, RunningApp, Session};
use crate::spawner::{Spawner, UnitEvent};

pub const BUS_NAME: &str = "org.ruyaos.Session1";
pub const OBJECT_PATH: &str = "/org/ruyaos/Session1";

/// Chosen at runtime: the fake in `--session`; the real spawner does not exist yet (T-139).
pub type DynSpawner = Box<dyn Spawner + Send>;
pub type Shared = Arc<Mutex<Session<DynSpawner, ProfileSnapshot>>>;

type Dict = HashMap<String, OwnedValue>;

fn lock(shared: &Shared) -> MutexGuard<'_, Session<DynSpawner, ProfileSnapshot>> {
    // A poisoned lock means a handler panicked; the registry is still consistent enough to serve.
    shared.lock().unwrap_or_else(|e| e.into_inner())
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

fn running_dict(app: RunningApp) -> Dict {
    [
        ("instance", Value::from(app.instance)),
        ("app_id", Value::from(app.app_id)),
        ("profile", Value::from(app.profile)),
        ("started", Value::from(app.started)),
        ("state", Value::from(app.state.as_str())),
    ]
    .into_iter()
    .filter_map(|(k, v)| OwnedValue::try_from(v).ok().map(|v| (k.to_owned(), v)))
    .collect()
}

/// The profile ids `Profiles1` knows. The profile store itself is root-only and holds PIN
/// hashes, so this service asks the owner of that data instead of reading it.
pub async fn fetch_profile_ids(connection: &Connection) -> zbus::Result<Vec<String>> {
    let reply = connection
        .call_method(
            Some("org.ruyaos.Profiles1"),
            "/org/ruyaos/Profiles1",
            Some("org.ruyaos.Profiles1"),
            "ListProfiles",
            &(),
        )
        .await?;
    let rows: Vec<(String, String, String, String, bool)> = reply.body().deserialize()?;
    Ok(rows.into_iter().map(|r| r.0).collect())
}

pub struct SessionIface {
    session: Shared,
    /// Ask `Profiles1` before each launch (system mode); `--session` keeps its fixed list.
    refresh_profiles: bool,
}

impl SessionIface {
    pub fn new(session: Shared, refresh_profiles: bool) -> Self {
        SessionIface {
            session,
            refresh_profiles,
        }
    }
}

#[interface(name = "org.ruyaos.Session1")]
impl SessionIface {
    async fn launch(
        &self,
        app_id: &str,
        profile: &str,
        #[zbus(connection)] connection: &Connection,
    ) -> (String, String) {
        if self.refresh_profiles {
            match fetch_profile_ids(connection).await {
                Ok(ids) => lock(&self.session).directory_mut().set(ids),
                Err(err) => {
                    eprintln!("ruya-session: Profiles1 not readable: {err}");
                    return ("failed".to_owned(), String::new());
                }
            }
        }
        let (status, instance) = lock(&self.session).launch(app_id, profile, unix_now());
        (status.as_str().to_owned(), instance)
    }

    fn stop(&self, instance: &str) -> String {
        lock(&self.session)
            .stop(instance, Instant::now())
            .as_str()
            .to_owned()
    }

    fn list_running(&self) -> Vec<Dict> {
        lock(&self.session)
            .list()
            .into_iter()
            .map(running_dict)
            .collect()
    }

    #[zbus(signal)]
    async fn app_started(
        emitter: &SignalEmitter<'_>,
        instance: String,
        app_id: String,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn app_exited(
        emitter: &SignalEmitter<'_>,
        instance: String,
        app_id: String,
        exit_code: i32,
        reason: String,
    ) -> zbus::Result<()>;
}

/// Feeds the OS events into the core and sends the resulting signals, in order; once a second it
/// lets the core kill apps that ignored `Stop`. Runs forever.
pub async fn forward(connection: Connection, session: Shared, events: Receiver<UnitEvent>) {
    let ticks = async_io::Timer::interval(Duration::from_secs(1));
    let tick_loop = async {
        let mut ticks = ticks;
        loop {
            futures_lite::StreamExt::next(&mut ticks).await;
            lock(&session).tick(Instant::now());
        }
    };
    let event_loop = async {
        while let Ok(event) = events.recv().await {
            let notice = lock(&session).on_event(event);
            let Some(notice) = notice else { continue };
            let sent = async {
                let iface = connection
                    .object_server()
                    .interface::<_, SessionIface>(OBJECT_PATH)
                    .await?;
                let emitter = iface.signal_emitter();
                match notice {
                    Notice::Started { instance, app_id } => {
                        SessionIface::app_started(emitter, instance, app_id).await
                    }
                    Notice::Exited {
                        instance,
                        app_id,
                        exit_code,
                        reason,
                    } => {
                        SessionIface::app_exited(
                            emitter,
                            instance,
                            app_id,
                            exit_code,
                            reason.as_str().to_owned(),
                        )
                        .await
                    }
                }
            }
            .await;
            if let Err(err) = sent {
                eprintln!("ruya-session: emitting a signal failed: {err}");
            }
        }
    };
    futures_lite::future::zip(tick_loop, event_loop).await;
}
