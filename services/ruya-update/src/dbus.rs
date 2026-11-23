//! org.ruyaos.Update1 on D-Bus. Thin adapter: the rules live in `service.rs`. A check or download
//! runs on its own thread (`bootc` blocks); every change becomes a `StatusChanged` signal through
//! a channel, in the order it happened, and a `JobChanged` when the image job's record changed.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_channel::{Receiver, Sender};
use zbus::message::Header;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedValue, Value};
use zbus::{fdo, interface, Connection};

use crate::bootc::Bootc;
use crate::job::JobRecord;
use crate::schedule::{Clock, SystemClock};
use crate::service::{Record, Status, Update};
use ruya_jobs::ledger::Day;

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

/// The Job record of the contract (GetDownloadJob, JobChanged).
pub fn job_dict(j: &JobRecord) -> Dict {
    dict(vec![
        ("id", Value::from(j.id.clone())),
        ("source", Value::from(j.source)),
        ("kind", Value::from(j.kind)),
        ("app", Value::from(j.app.clone())),
        ("title", Value::from(j.title.clone())),
        ("state", Value::from(j.state)),
        ("status", Value::from(j.status.clone())),
        ("reason", Value::from(j.reason.clone())),
        ("phase", Value::from(j.phase)),
        ("percent", Value::from(j.percent)),
        ("bytes_done", Value::from(j.bytes_done)),
        ("bytes_total", Value::from(j.bytes_total)),
        ("rate_bps", Value::from(j.rate_bps)),
        ("eta_s", Value::from(j.eta_s)),
        ("position", Value::from(j.position)),
        ("resumable", Value::from(j.resumable)),
        ("started", Value::from(j.started)),
        ("finished", Value::from(j.finished)),
    ])
}

/// One entry of GetDownloadStats.
pub fn day_dict(d: &Day) -> Dict {
    dict(vec![
        ("day", Value::from(d.day.clone())),
        ("bytes", Value::from(d.bytes)),
        ("jobs", Value::from(d.jobs)),
        ("failed", Value::from(d.failed)),
    ])
}

pub fn record(r: &Record) -> Dict {
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
        let status = self.update.begin_download(now());
        if status == Status::Ok {
            self.changed();
            self.spawn(|update, emit| update.run_download(&SystemClock, emit));
        }
        status.as_str().to_owned()
    }

    fn pause_download(&self) -> String {
        let status = self.update.pause_download();
        // The job thread reports the pause once bootc has stopped.
        status.as_str().to_owned()
    }

    fn resume_download(&self) -> String {
        let status = self.update.resume_download(now());
        if status == Status::Ok {
            self.changed();
            self.spawn(|update, emit| update.run_download(&SystemClock, emit));
        }
        status.as_str().to_owned()
    }

    fn cancel_download(&self) -> String {
        let status = self.update.cancel_download(&SystemClock);
        // A paused job ends here; a running one when bootc has stopped (the job thread reports it).
        if status == Status::Ok {
            self.changed();
        }
        status.as_str().to_owned()
    }

    fn get_download_job(&self) -> (String, Dict) {
        let job = self
            .update
            .job_record(SystemClock.monotonic_ms())
            .map(|j| job_dict(&j))
            .unwrap_or_default();
        (Status::Ok.as_str().to_owned(), job)
    }

    fn get_download_stats(&self, days: u32) -> (String, Vec<Dict>) {
        let (status, stats) = self.update.download_stats(days, &SystemClock);
        (
            status.as_str().to_owned(),
            stats.iter().map(day_dict).collect(),
        )
    }

    async fn rollback(
        &self,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
    ) -> String {
        let admin = self.caller_is_admin(&header, connection).await;
        let update = self.update.clone();
        // `bootc rollback` takes a moment: not on the executor.
        let status = blocking::unblock(move || update.rollback(admin, &SystemClock)).await;
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
        let status = self.update.set_channel(channel, admin, &SystemClock);
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

    #[zbus(signal)]
    async fn job_changed(emitter: &SignalEmitter<'_>, job: Dict) -> zbus::Result<()>;
}

/// Turns the changes into signals, in order: StatusChanged for each, JobChanged when the job's
/// record differs from the one sent last. Runs forever.
pub async fn forward(connection: Connection, update: Shared, changes: Receiver<()>) {
    let mut sent_job: Option<JobRecord> = None;
    while changes.recv().await.is_ok() {
        let job = update.job_record(SystemClock.monotonic_ms());
        let new_job = job.filter(|j| sent_job.as_ref() != Some(j));
        let sent = async {
            let iface = connection
                .object_server()
                .interface::<_, UpdateIface>(OBJECT_PATH)
                .await?;
            UpdateIface::status_changed(iface.signal_emitter()).await?;
            if let Some(job) = &new_job {
                UpdateIface::job_changed(iface.signal_emitter(), job_dict(job)).await?;
            }
            Ok::<(), zbus::Error>(())
        }
        .await;
        match sent {
            Ok(()) => {
                if new_job.is_some() {
                    sent_job = new_job;
                }
            }
            Err(err) => eprintln!("ruya-update: emitting a signal failed: {err}"),
        }
    }
}
