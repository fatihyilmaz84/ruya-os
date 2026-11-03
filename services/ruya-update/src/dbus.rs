//! org.ruyaos.Update1 on D-Bus. Thin adapter: the rules live in `service.rs`. A check or download
//! runs on its own thread (`bootc` blocks); every change becomes a `StatusChanged` signal through
//! a channel, in the order it happened.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_channel::{Receiver, Sender};
use zbus::message::Header;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedValue, Value};
use zbus::{fdo, interface, Connection};

use crate::bootc::Bootc;
use crate::service::{Record, Status, Update};

pub const BUS_NAME: &str = "org.ruyaos.Update1";
pub const OBJECT_PATH: &str = "/org/ruyaos/Update1";

/// Chosen at runtime: the `bootc` command on Linux, a fake in `--session` development.
pub type DynBootc = Box<dyn Bootc>;
pub type Shared = Arc<Update<DynBootc>>;

/// A job starts this long after its method returned, so the reply is on the wire before the
/// first `StatusChanged`.
const START_DELAY: Duration = Duration::from_millis(100);

pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(0))
}

pub struct UpdateIface {
    update: Shared,
    changes: Sender<()>,
    /// Development (`--session`): every caller is an admin, there is no Profiles1 to ask.
    everyone_admin: bool,
}

impl UpdateIface {
    pub fn new(update: Shared, changes: Sender<()>, everyone_admin: bool) -> Self {
        UpdateIface {
            update,
            changes,
            everyone_admin,
        }
    }

    fn changed(&self) {
        let _ = self.changes.send_blocking(());
    }

    /// root, or the shell while the active profile is an admin (the same rule as
    /// `ruya-store`'s AddRemote).
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

    /// Runs `job` on a thread shortly after the reply; its changes arrive through the channel.
    fn spawn(&self, job: impl FnOnce(&Update<DynBootc>, &mut dyn FnMut()) + Send + 'static) {
        let update = self.update.clone();
        let changes = self.changes.clone();
        std::thread::spawn(move || {
            std::thread::sleep(START_DELAY);
            job(&update, &mut || {
                let _ = changes.send_blocking(());
            });
        });
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

type Dict = HashMap<String, OwnedValue>;

fn dict(entries: Vec<(&str, Value<'_>)>) -> Dict {
    entries
        .into_iter()
        .filter_map(|(k, v)| OwnedValue::try_from(v).ok().map(|v| (k.to_owned(), v)))
        .collect()
}

fn record(r: &Record) -> Dict {
    dict(vec![
        ("state", Value::from(r.state.as_str())),
        ("current", Value::from(r.current.clone())),
        ("available", Value::from(r.available.clone())),
        ("staged", Value::from(r.staged.clone())),
        ("channel", Value::from(r.channel.clone())),
        ("auto_restart", Value::from(r.auto_restart)),
        ("last_check", Value::from(r.last_check)),
        ("restart_at", Value::from(r.restart_at)),
        ("progress", Value::from(r.progress)),
        ("rollback_available", Value::from(r.rollback_available)),
        ("error", Value::from(r.error.clone())),
    ])
}

#[interface(name = "org.ruyaos.Update1")]
impl UpdateIface {
    fn check(&self) -> String {
        let status = self.update.begin_check();
        if status == Status::Ok {
            self.changed();
            self.spawn(|update, emit| update.run_check(now(), emit));
        }
        status.as_str().to_owned()
    }

    fn download(&self) -> String {
        let status = self.update.begin_download();
        if status == Status::Ok {
            self.changed();
            self.spawn(|update, emit| update.run_download(emit));
        }
        status.as_str().to_owned()
    }

    async fn rollback(
        &self,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
    ) -> String {
        let admin = self.caller_is_admin(&header, connection).await;
        let update = self.update.clone();
        // `bootc rollback` takes a moment: not on the executor.
        let status = blocking::unblock(move || update.rollback(admin)).await;
        if status == Status::Ok {
            self.changed();
        }
        status.as_str().to_owned()
    }

    async fn set_channel(
        &self,
        channel: &str,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
    ) -> String {
        let admin = self.caller_is_admin(&header, connection).await;
        let status = self.update.set_channel(channel, admin);
        if status == Status::Ok {
            self.changed();
        }
        status.as_str().to_owned()
    }

    async fn set_auto_restart(
        &self,
        enabled: bool,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
    ) -> String {
        let admin = self.caller_is_admin(&header, connection).await;
        let status = self.update.set_auto_restart(enabled, admin);
        if status == Status::Ok {
            self.changed();
        }
        status.as_str().to_owned()
    }

    fn report_activity(&self, app_running: bool) {
        // Input calls off an announced restart, which the shell must hear about.
        if self.update.report_activity(now(), app_running) {
            self.changed();
        }
    }

    fn get_status(&self) -> Dict {
        record(&self.update.record())
    }

    #[zbus(signal)]
    async fn status_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

/// Turns the changes into signals, in order. Runs forever.
pub async fn forward(connection: Connection, changes: Receiver<()>) {
    while changes.recv().await.is_ok() {
        let sent = async {
            let iface = connection
                .object_server()
                .interface::<_, UpdateIface>(OBJECT_PATH)
                .await?;
            UpdateIface::status_changed(iface.signal_emitter()).await
        }
        .await;
        if let Err(err) = sent {
            eprintln!("ruya-update: emitting a signal failed: {err}");
        }
    }
}
