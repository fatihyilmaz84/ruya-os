//! org.ruyaos.Store1 on D-Bus. Thin adapter: the rules live in `service.rs`. Jobs run on their own
//! thread (flatpak blocks); their events come back over a channel and become signals here.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use async_channel::{Receiver, Sender};
use zbus::message::Header;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{Array, OwnedValue, Value};
use zbus::{fdo, interface, Connection};

use crate::app::App;
use crate::flatpak::{
    Appstream, Flatpak, FlatpakError, InstalledApp, Operation, Progress, RemoteApp, RemoteInfo,
};
use crate::jobs::JobInfo;
use crate::service::{Event, SearchOptions, Store};

pub const BUS_NAME: &str = "org.ruyaos.Store1";
pub const OBJECT_PATH: &str = "/org/ruyaos/Store1";

/// Chosen at runtime: the `flatpak` command on Linux, a fake in `--session` development.
pub type DynFlatpak = Box<dyn Flatpak>;

impl Flatpak for DynFlatpak {
    fn remote_apps(&self) -> Result<Vec<RemoteApp>, String> {
        (**self).remote_apps()
    }
    fn installed(&self) -> Result<Vec<InstalledApp>, String> {
        (**self).installed()
    }
    fn updates(&self) -> Result<Vec<String>, String> {
        (**self).updates()
    }
    fn remotes(&self) -> Result<Vec<RemoteInfo>, String> {
        (**self).remotes()
    }
    fn appstream(&self, remote: &str) -> Option<Appstream> {
        (**self).appstream(remote)
    }
    fn metadata(&self, remote: &str, id: &str) -> Option<String> {
        (**self).metadata(remote, id)
    }
    fn installed_metadata(&self, id: &str) -> Option<String> {
        (**self).installed_metadata(id)
    }
    fn run(&self, op: &Operation, progress: &mut dyn FnMut(Progress)) -> Result<(), FlatpakError> {
        (**self).run(op, progress)
    }
    fn add_remote(&self, name: &str, url: &str) -> Result<(), FlatpakError> {
        (**self).add_remote(name, url)
    }
    fn update_appstream(&self, remote: &str) -> Result<(), String> {
        (**self).update_appstream(remote)
    }
}

pub type Shared = Arc<Store<DynFlatpak>>;

/// A job starts this long after its method returned, so the reply is on the wire before the
/// first `JobProgress` (a client maps job ids to apps from the reply).
const START_DELAY: Duration = Duration::from_millis(100);

/// Reads the catalogue, tells the clients, then fetches the remotes' AppStream data (names,
/// summaries, icons) and tells them again. On its own thread: every step can wait for the network.
pub fn spawn_sync(store: Shared, events: Sender<Event>) {
    std::thread::spawn(move || {
        store.sync(&mut |event| {
            let _ = events.send_blocking(event);
        });
    });
}

pub struct StoreIface {
    store: Shared,
    events: Sender<Event>,
    /// Development (`--session`): every caller is an admin, there is no Profiles1 to ask.
    everyone_admin: bool,
}

impl StoreIface {
    pub fn new(store: Shared, events: Sender<Event>, everyone_admin: bool) -> Self {
        StoreIface {
            store,
            events,
            everyone_admin,
        }
    }

    /// Runs queued jobs on a thread until none is left. A second call while one thread is working
    /// finds the queue busy and ends at once; the first thread picks the new job up.
    fn kick(&self) {
        let store = self.store.clone();
        let events = self.events.clone();
        std::thread::spawn(move || {
            std::thread::sleep(START_DELAY);
            while store.run_next(&mut |event| {
                let _ = events.send_blocking(event);
            }) {}
        });
    }

    /// Runs a Store call that reads Flatpak (`flatpak list` and friends block) on a thread of
    /// the `blocking` pool, so the zbus executor keeps answering other calls and sending
    /// signals. `emit` hands the signals the call wants sent (`InstalledChanged` for a
    /// correction) to `forward`, which sends them in order.
    async fn off_executor<T: Send + 'static>(
        &self,
        call: impl FnOnce(&Store<DynFlatpak>, &mut dyn FnMut(Event)) -> T + Send + 'static,
    ) -> T {
        let store = self.store.clone();
        let events = self.events.clone();
        blocking::unblock(move || {
            call(&store, &mut |event| {
                let _ = events.send_blocking(event);
            })
        })
        .await
    }

    fn started(&self, (status, job): (crate::app::Status, String)) -> (String, String) {
        if status == crate::app::Status::Ok {
            self.kick();
        }
        (status.as_str().to_owned(), job)
    }

    /// root, or the shell while the active profile is an admin (spec 03 §4.2: adding a source is
    /// an admin's decision).
    async fn caller_is_admin(&self, header: &Header<'_>, connection: &Connection) -> bool {
        if self.everyone_admin {
            return true;
        }
        let Some(sender) = header.sender() else {
            return false;
        };
        let Ok(bus) = fdo::DBusProxy::new(connection).await else {
            return false;
        };
        match bus.get_connection_unix_user(sender.clone().into()).await {
            Ok(0) => true,
            Ok(_) => active_profile_is_admin(connection).await,
            Err(_) => false,
        }
    }
}

async fn active_profile_is_admin(connection: &Connection) -> bool {
    let Ok(proxy) = zbus::Proxy::new(
        connection,
        "org.ruyaos.Profiles1",
        "/org/ruyaos/Profiles1",
        "org.ruyaos.Profiles1",
    )
    .await
    else {
        return false;
    };
    let Ok(active) = proxy.get_property::<String>("ActiveProfile").await else {
        return false;
    };
    let Ok(profiles) = proxy
        .call::<_, _, Vec<(String, String, String, String, bool)>>("ListProfiles", &())
        .await
    else {
        return false;
    };
    profiles.iter().any(|p| p.0 == active && p.3 == "admin")
}

// Sorted keys: the replies (and busctl output, logs) read the same every time. Clients must not
// rely on it - a{sv} has no order.
type Dict = BTreeMap<String, OwnedValue>;

fn dict(entries: Vec<(&str, Value<'_>)>) -> Dict {
    entries
        .into_iter()
        .filter_map(|(k, v)| OwnedValue::try_from(v).ok().map(|v| (k.to_owned(), v)))
        .collect()
}

fn record(app: &App) -> Dict {
    let mut entries = vec![
        ("id", Value::from(app.id.clone())),
        ("name", Value::from(app.name.clone())),
        ("summary", Value::from(app.summary.clone())),
        ("description", Value::from(app.description.clone())),
        ("developer", Value::from(app.developer.clone())),
        ("source", Value::from(app.source.clone())),
        ("controller", Value::from(app.controller.clone())),
        (
            "permissions",
            Value::Array(Array::from(app.permissions.clone())),
        ),
        (
            "new_permissions",
            Value::Array(Array::from(app.new_permissions.clone())),
        ),
        ("installed_size", Value::from(app.installed_size)),
        ("icon", Value::from(app.icon.clone())),
        ("tile", Value::from(app.tile.clone())),
        ("hero", Value::from(app.hero.clone())),
        ("installed", Value::from(app.installed)),
        ("update_available", Value::from(app.update_available)),
    ];
    // An unknown rating is left out: the client keeps its own default.
    if !app.age_rating.is_empty() {
        entries.push(("age_rating", Value::from(app.age_rating.clone())));
    }
    dict(entries)
}

fn job_record(job: &JobInfo) -> Dict {
    dict(vec![
        ("id", Value::from(job.id.clone())),
        ("app", Value::from(job.app.clone())),
        ("kind", Value::from(job.kind.as_str())),
        ("state", Value::from(job.state.as_str())),
        ("status", Value::from(job.status.map_or("", |s| s.as_str()))),
        ("reason", Value::from(job.reason())),
        ("percent", Value::from(job.percent)),
        ("phase", Value::from(job.phase.as_str())),
    ])
}

#[interface(name = "org.ruyaos.Store1")]
impl StoreIface {
    fn search(&self, query: &str, options: Dict) -> fdo::Result<Vec<Dict>> {
        let controller = match options.get("controller") {
            Some(v) => Some(
                <&str>::try_from(v)
                    .map_err(|_| fdo::Error::InvalidArgs("controller must be a string".into()))?,
            ),
            None => None,
        };
        let limit = match options.get("limit") {
            Some(v) => Some(
                u32::try_from(v)
                    .map_err(|_| fdo::Error::InvalidArgs("limit must be a uint32".into()))?,
            ),
            None => None,
        };
        let options = SearchOptions::parse(controller, limit)
            .ok_or_else(|| fdo::Error::InvalidArgs("controller: any or gamepad".into()))?;
        Ok(self
            .store
            .search(query, &options)
            .iter()
            .map(record)
            .collect())
    }

    async fn get_app(&self, id: &str) -> (String, Dict) {
        let store = self.store.clone();
        let id = id.to_owned();
        // The first call for an app reads its permissions with flatpak: not on the executor.
        let (status, app) = blocking::unblock(move || store.get_app(&id)).await;
        let app = if status == crate::app::Status::Ok {
            record(&app)
        } else {
            Dict::new()
        };
        (status.as_str().to_owned(), app)
    }

    async fn list_installed(&self) -> Vec<Dict> {
        // `flatpak list` runs here, and a correction it finds is announced.
        let apps = self
            .off_executor(|store, emit| store.list_installed(emit))
            .await;
        apps.iter().map(record).collect()
    }

    async fn list_jobs(&self) -> Vec<Dict> {
        let store = self.store.clone();
        // The first call after a restart settles the jobs of the last run with `flatpak list`.
        let jobs = blocking::unblock(move || store.list_jobs()).await;
        jobs.iter().map(job_record).collect()
    }

    async fn install(&self, id: &str) -> (String, String) {
        let id = id.to_owned();
        let started = self
            .off_executor(move |store, emit| store.install(&id, emit))
            .await;
        self.started(started)
    }

    async fn uninstall(&self, id: &str, delete_data: bool) -> (String, String) {
        let id = id.to_owned();
        let started = self
            .off_executor(move |store, emit| store.uninstall(&id, delete_data, emit))
            .await;
        self.started(started)
    }

    async fn update(&self, id: &str) -> (String, String) {
        let id = id.to_owned();
        let started = self
            .off_executor(move |store, emit| store.update(&id, emit))
            .await;
        self.started(started)
    }

    async fn rollback(&self, id: &str, commit: &str) -> (String, String) {
        let (id, commit) = (id.to_owned(), commit.to_owned());
        let started = self
            .off_executor(move |store, emit| store.rollback(&id, &commit, emit))
            .await;
        self.started(started)
    }

    async fn list_remotes(&self) -> Vec<Dict> {
        let remotes = self.off_executor(|store, _| store.list_remotes()).await;
        remotes
            .into_iter()
            .map(|(remote, trust)| {
                dict(vec![
                    ("name", Value::from(remote.name)),
                    ("title", Value::from(remote.title)),
                    ("trust", Value::from(trust)),
                    ("enabled", Value::from(remote.enabled)),
                ])
            })
            .collect()
    }

    async fn add_remote(
        &self,
        name: &str,
        url: &str,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
    ) -> String {
        let admin = self.caller_is_admin(&header, connection).await;
        let store = self.store.clone();
        let (name, url) = (name.to_owned(), url.to_owned());
        // flatpak fetches the remote's description: not on the executor.
        let status = blocking::unblock(move || store.add_remote(&name, &url, admin)).await;
        if status == crate::app::Status::Ok {
            // The catalogue gets the new source's apps: read again (remotes can be slow, the
            // reply does not wait) and tell the clients.
            spawn_sync(self.store.clone(), self.events.clone());
        }
        status.as_str().to_owned()
    }

    #[zbus(signal)]
    async fn job_progress(
        emitter: &SignalEmitter<'_>,
        job: String,
        percent: u32,
        phase: String,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn job_finished(
        emitter: &SignalEmitter<'_>,
        job: String,
        status: String,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn installed_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn catalog_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

/// Turns the events of the job thread into signals, in the order they happened. Runs forever.
pub async fn forward(connection: Connection, events: Receiver<Event>) {
    while let Ok(event) = events.recv().await {
        let sent = async {
            let iface = connection
                .object_server()
                .interface::<_, StoreIface>(OBJECT_PATH)
                .await?;
            let emitter = iface.signal_emitter();
            match event {
                Event::Progress {
                    job,
                    percent,
                    phase,
                } => {
                    StoreIface::job_progress(emitter, job, percent, phase.as_str().to_owned()).await
                }
                Event::InstalledChanged => StoreIface::installed_changed(emitter).await,
                Event::CatalogChanged => StoreIface::catalog_changed(emitter).await,
                Event::Finished { job, status } => {
                    StoreIface::job_finished(emitter, job, status.as_str().to_owned()).await
                }
            }
        }
        .await;
        if let Err(err) = sent {
            eprintln!("ruya-store: emitting a signal failed: {err}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::flatpak::FakeFlatpak;
    use futures_lite::future::{block_on, poll_once};
    use std::sync::mpsc;

    /// The test keeps a handle on the fake (to block it, to change what it lists) while the
    /// Store owns a boxed one.
    struct Handle(Arc<FakeFlatpak>);

    impl Flatpak for Handle {
        fn remote_apps(&self) -> Result<Vec<RemoteApp>, String> {
            self.0.remote_apps()
        }
        fn installed(&self) -> Result<Vec<InstalledApp>, String> {
            self.0.installed()
        }
        fn updates(&self) -> Result<Vec<String>, String> {
            self.0.updates()
        }
        fn remotes(&self) -> Result<Vec<RemoteInfo>, String> {
            self.0.remotes()
        }
        fn appstream(&self, remote: &str) -> Option<Appstream> {
            self.0.appstream(remote)
        }
        fn metadata(&self, remote: &str, id: &str) -> Option<String> {
            self.0.metadata(remote, id)
        }
        fn installed_metadata(&self, id: &str) -> Option<String> {
            self.0.installed_metadata(id)
        }
        fn run(
            &self,
            op: &Operation,
            progress: &mut dyn FnMut(Progress),
        ) -> Result<(), FlatpakError> {
            self.0.run(op, progress)
        }
        fn add_remote(&self, name: &str, url: &str) -> Result<(), FlatpakError> {
            self.0.add_remote(name, url)
        }
        fn update_appstream(&self, remote: &str) -> Result<(), String> {
            self.0.update_appstream(remote)
        }
    }

    const RACER: &str = "org.ruya.Racer";

    fn setup() -> (Arc<FakeFlatpak>, StoreIface, Receiver<Event>) {
        let fake = Arc::new(
            FakeFlatpak::default()
                .with_remote("ruyaos", "RuyaOS", true)
                .with_app("ruyaos", RACER, 5_000_000)
                .with_installed("ruyaos", RACER, 5_000_000),
        );
        let boxed: DynFlatpak = Box::new(Handle(fake.clone()));
        let store: Shared = Arc::new(Store::new(boxed));
        store.refresh().unwrap();
        let (events, receiver) = async_channel::unbounded();
        (fake.clone(), StoreIface::new(store, events, true), receiver)
    }

    /// The handler path of the blocking calls: a `flatpak list` that does not return must leave
    /// the executor free for other calls (it is what every client and every signal waits on).
    #[test]
    fn a_flatpak_call_that_blocks_does_not_stop_another_call_from_being_answered() {
        let (fake, iface, events) = setup();
        let (reached_tx, reached_rx) = mpsc::channel::<()>();
        let (release_tx, release_rx) = mpsc::channel::<()>();
        // `flatpak list` hangs until the test lets it go (a safety timeout ends a broken run).
        fake.remove_installed(RACER);
        fake.after_next_installed(move || {
            let _ = reached_tx.send(());
            let _ = release_rx.recv_timeout(Duration::from_secs(3));
        });

        // One thread plays the executor. The slow call must give it back at its first poll.
        let mut slow = Box::pin(iface.list_installed());
        assert!(
            block_on(poll_once(&mut slow)).is_none(),
            "the call is still waiting for flatpak, the executor is free"
        );
        reached_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("flatpak is being read now");

        // Other calls are answered while it hangs.
        let (status, app) = block_on(iface.get_app(RACER));
        assert_eq!(status, "ok");
        assert!(app.contains_key("name"));
        assert_eq!(block_on(iface.list_remotes()).len(), 1);
        assert!(events.try_recv().is_err(), "nothing was announced yet");

        // Released, the slow call ends with its answer, and the correction it found is announced.
        release_tx.send(()).unwrap();
        assert!(block_on(slow).is_empty());
        assert_eq!(events.try_recv(), Ok(Event::InstalledChanged));
        assert!(events.try_recv().is_err(), "once");
    }

    #[test]
    fn install_does_not_hold_the_executor_and_a_correction_reaches_the_signals() {
        let (fake, iface, events) = setup();
        let (reached_tx, reached_rx) = mpsc::channel::<()>();
        let (release_tx, release_rx) = mpsc::channel::<()>();
        fake.remove_installed(RACER);
        fake.after_next_installed(move || {
            let _ = reached_tx.send(());
            let _ = release_rx.recv_timeout(Duration::from_secs(3));
        });
        let mut slow = Box::pin(iface.install(RACER));
        assert!(block_on(poll_once(&mut slow)).is_none());
        reached_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        assert_eq!(block_on(iface.list_remotes()).len(), 1);
        release_tx.send(()).unwrap();
        let (status, job) = block_on(slow);
        assert_eq!((status.as_str(), job.is_empty()), ("ok", false));
        // The removal was corrected before the request was checked: announced, once.
        // (The job thread starts 100 ms later; its progress events follow, so only the first
        // event is looked at.)
        assert_eq!(events.try_recv(), Ok(Event::InstalledChanged));
    }
}
