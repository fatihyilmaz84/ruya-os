//! org.ruyaos.Session1 on D-Bus. Thin adapter: the rules live in `session.rs`. OS events arrive
//! over a channel (`forward`) and leave as signals; a timer kills apps that ignore `Stop`.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use async_channel::Receiver;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedValue, Value};
use zbus::{interface, Connection};

use crate::directory::{profile_ids, ProfileDirectory, ProfileRow, ProfileSnapshot};
use crate::session::{ExitReason, Notice, RunningApp, Session};
use crate::spawner::{flatpak_app_version, valid_profile_id, Spawner, UnitEvent};
use crate::usage::{DayRow, EndReason, SessionRecord, SystemZone, MAX_LIST};
use crate::usage_store::FileStore;
use crate::usage_tracker::{clear_route, may_read, Attention, ClearRoute, LiveApp, Tracker};

pub const BUS_NAME: &str = "org.ruyaos.Session1";
pub const OBJECT_PATH: &str = "/org/ruyaos/Session1";

/// Chosen at runtime: the fake in `--session`, `systemd::SystemdSpawner` on the system bus.
pub type DynSpawner = Box<dyn Spawner + Send>;
pub type Shared = Arc<Mutex<Session<DynSpawner, ProfileSnapshot>>>;
/// The play ledger (T-247), shared by the interface and the event loop.
pub type SharedUsage = Arc<Mutex<Tracker<FileStore, SystemZone>>>;

/// Where Flatpak keeps the installed apps (for the version a session records).
pub const FLATPAK_ROOT: &str = "/var/lib/flatpak";
/// How often (seconds) the usage data of deleted profiles is looked for.
const PURGE_EVERY_SECS: u64 = 60;

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
    let rows: Vec<ProfileRow> = reply.body().deserialize()?;
    Ok(profile_ids(rows))
}

/// Start-up, before the bus name is taken: the apps that kept running through a restart of this
/// service become instances again (T-290), and the play ledger takes their open runs over
/// instead of ending them. In system mode the profile list is asked first so that the units of
/// a profile that no longer exists can be stopped; when it cannot be read nothing is stopped.
pub async fn adopt_running(
    connection: &Connection,
    session: &Shared,
    usage: &SharedUsage,
    system: bool,
) {
    let known = if system {
        match fetch_profile_ids(connection).await {
            Ok(ids) => {
                lock(session).directory_mut().set(ids);
                true
            }
            Err(err) => {
                eprintln!("ruya-session: Profiles1 not readable, no unit is stopped: {err}");
                false
            }
        }
    } else {
        true
    };
    let adopted = lock(session).adopt(unix_now(), Instant::now(), known);
    let live: Vec<LiveApp> = adopted
        .into_iter()
        .map(|a| LiveApp {
            version: flatpak_app_version(Path::new(FLATPAK_ROOT), &a.app_id),
            instance: a.instance,
            profile: a.profile,
            app_id: a.app_id,
            started: a.started,
        })
        .collect();
    if !live.is_empty() {
        eprintln!("ruya-session: {} app(s) kept running", live.len());
    }
    let recovered = usage_lock(usage).recover_with(unix_now(), &live, Instant::now());
    if !recovered.is_empty() {
        eprintln!("ruya-session: recovered play sessions of {recovered:?}");
    }
}

fn usage_lock(shared: &SharedUsage) -> MutexGuard<'_, Tracker<FileStore, SystemZone>> {
    shared.lock().unwrap_or_else(|e| e.into_inner())
}

/// The active profile id (`""` when locked), asked of `Profiles1`.
async fn fetch_active_profile(connection: &Connection) -> zbus::Result<String> {
    let proxy = zbus::Proxy::new(
        connection,
        "org.ruyaos.Profiles1",
        "/org/ruyaos/Profiles1",
        "org.ruyaos.Profiles1",
    )
    .await?;
    proxy.get_property::<String>("ActiveProfile").await
}

/// `Profiles1.VerifyAdmin`: (status, attempts left, retry after seconds).
async fn verify_admin(
    connection: &Connection,
    admin_id: &str,
    admin_pin: &str,
) -> zbus::Result<(String, u32, u32)> {
    let reply = connection
        .call_method(
            Some("org.ruyaos.Profiles1"),
            "/org/ruyaos/Profiles1",
            Some("org.ruyaos.Profiles1"),
            "VerifyAdmin",
            &(admin_id, admin_pin),
        )
        .await?;
    reply.body().deserialize()
}

fn dict_of<const N: usize>(pairs: [(&str, Value<'_>); N]) -> Dict {
    pairs
        .into_iter()
        .filter_map(|(k, v)| OwnedValue::try_from(v).ok().map(|v| (k.to_owned(), v)))
        .collect()
}

fn session_dict(s: SessionRecord) -> Dict {
    // The local day it began on, for the shell's grouping by day.
    let day = s
        .days
        .first()
        .map_or_else(String::new, |d| crate::usage::format_day(d.0));
    dict_of([
        ("day", Value::from(day)),
        ("app_id", Value::from(s.app_id)),
        ("app_version", Value::from(s.app_version)),
        ("start", Value::from(s.start)),
        ("end", Value::from(s.end)),
        ("foreground_seconds", Value::from(s.foreground_seconds)),
        ("exit_reason", Value::from(s.reason.as_str())),
        ("open", Value::from(s.open)),
    ])
}

fn row_dict(r: DayRow) -> Dict {
    dict_of([
        ("app_id", Value::from(r.app_id)),
        ("day", Value::from(crate::usage::format_day(r.day))),
        ("seconds", Value::from(r.seconds)),
        ("sessions", Value::from(r.sessions)),
        ("longest", Value::from(r.longest)),
        ("first", Value::from(r.first)),
        ("last", Value::from(r.last)),
    ])
}

pub struct SessionIface {
    session: Shared,
    usage: SharedUsage,
    /// System mode: ask `Profiles1` before each launch and who is active before a read or a
    /// clear; `--session` keeps its fixed list and trusts the caller.
    system: bool,
}

impl SessionIface {
    pub fn new(session: Shared, usage: SharedUsage, system: bool) -> Self {
        SessionIface {
            session,
            usage,
            system,
        }
    }

    /// `Ok(None)` in development mode (no check), `Ok(Some(active))` otherwise.
    async fn active(&self, connection: &Connection) -> Result<Option<String>, ()> {
        if !self.system {
            return Ok(None);
        }
        match fetch_active_profile(connection).await {
            Ok(a) => Ok(Some(a)),
            Err(err) => {
                eprintln!("ruya-session: Profiles1 ActiveProfile not readable: {err}");
                Err(())
            }
        }
    }

    /// The status for a read of `profile`'s history, or `None` when it is allowed.
    async fn read_gate(&self, profile: &str, connection: &Connection) -> Option<&'static str> {
        if !valid_profile_id(profile) {
            return Some("invalid");
        }
        match self.active(connection).await {
            Err(()) => Some("failed"),
            Ok(active) if !may_read(profile, active.as_deref()) => Some("not-allowed"),
            Ok(_) => None,
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
        if self.system {
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

    async fn report_presence(
        &self,
        profile: &str,
        instance: &str,
        attention: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let Some(attention) = Attention::parse(attention) else {
            return "invalid".to_owned();
        };
        if !profile.is_empty() && !valid_profile_id(profile) {
            return "invalid".to_owned();
        }
        let changed = usage_lock(&self.usage).presence(
            profile,
            Some(instance),
            attention,
            Instant::now(),
            unix_now(),
        );
        for p in changed {
            let _ = Self::usage_changed(&emitter, p).await;
        }
        "ok".to_owned()
    }

    async fn list_sessions(
        &self,
        profile: &str,
        since: i64,
        limit: u32,
        #[zbus(connection)] connection: &Connection,
    ) -> (String, Vec<Dict>) {
        if let Some(status) = self.read_gate(profile, connection).await {
            return (status.to_owned(), Vec::new());
        }
        let limit = usize::try_from(limit).unwrap_or(MAX_LIST);
        match usage_lock(&self.usage).list(profile, since, limit, unix_now()) {
            Ok(list) => (
                "ok".to_owned(),
                list.into_iter().map(session_dict).collect(),
            ),
            Err(_) => ("failed".to_owned(), Vec::new()),
        }
    }

    async fn get_totals(
        &self,
        profile: &str,
        from: &str,
        to: &str,
        #[zbus(connection)] connection: &Connection,
    ) -> (String, String, Vec<Dict>) {
        if let Some(status) = self.read_gate(profile, connection).await {
            return (status.to_owned(), String::new(), Vec::new());
        }
        match usage_lock(&self.usage).totals(profile, from, to, unix_now()) {
            Ok((today, rows)) => (
                "ok".to_owned(),
                today,
                rows.into_iter().map(row_dict).collect(),
            ),
            Err(e) if e == "invalid" => ("invalid".to_owned(), String::new(), Vec::new()),
            Err(_) => ("failed".to_owned(), String::new(), Vec::new()),
        }
    }

    async fn clear_history(
        &self,
        profile: &str,
        admin_id: &str,
        admin_pin: &str,
        #[zbus(connection)] connection: &Connection,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> (String, u32, u32) {
        let refuse = |status: &str| (status.to_owned(), 0, 0);
        if !valid_profile_id(profile) {
            return refuse("invalid");
        }
        let Ok(active) = self.active(connection).await else {
            return refuse("failed");
        };
        match clear_route(profile, active.as_deref(), admin_id) {
            ClearRoute::NotAllowed => return refuse("not-allowed"),
            ClearRoute::Own => {}
            ClearRoute::Admin => {
                if !valid_profile_id(admin_id) {
                    return refuse("invalid");
                }
                if self.system {
                    match fetch_profile_ids(connection).await {
                        Ok(ids) => lock(&self.session).directory_mut().set(ids),
                        Err(_) => return refuse("failed"),
                    }
                }
                if lock(&self.session)
                    .directory_mut()
                    .unix_user(profile)
                    .is_none()
                {
                    return refuse("unknown-profile");
                }
                match verify_admin(connection, admin_id, admin_pin).await {
                    Ok((status, _, _)) if status == "ok" => {}
                    Ok((status, left, retry)) => {
                        return match status.as_str() {
                            "wrong-pin" | "locked-out" | "not-allowed" | "invalid" => {
                                (status, left, retry)
                            }
                            _ => refuse("failed"),
                        };
                    }
                    Err(err) => {
                        eprintln!("ruya-session: VerifyAdmin failed: {err}");
                        return refuse("failed");
                    }
                }
            }
        }
        usage_lock(&self.usage).clear(profile, unix_now());
        let _ = Self::usage_changed(&emitter, profile.to_owned()).await;
        ("ok".to_owned(), 0, 0)
    }

    #[zbus(signal)]
    async fn usage_changed(emitter: &SignalEmitter<'_>, profile: String) -> zbus::Result<()>;

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

fn end_reason_of(reason: ExitReason) -> Option<EndReason> {
    match reason {
        ExitReason::Quit => Some(EndReason::Quit),
        ExitReason::Crashed => Some(EndReason::Crashed),
        ExitReason::Killed => Some(EndReason::Killed),
        ExitReason::LaunchFailed => None,
    }
}

async fn send_usage_changed(connection: &Connection, profiles: Vec<String>) {
    if profiles.is_empty() {
        return;
    }
    let Ok(iface) = connection
        .object_server()
        .interface::<_, SessionIface>(OBJECT_PATH)
        .await
    else {
        return;
    };
    for p in profiles {
        if let Err(err) = SessionIface::usage_changed(iface.signal_emitter(), p).await {
            eprintln!("ruya-session: emitting UsageChanged failed: {err}");
        }
    }
}

/// Feeds the OS events into the core and sends the resulting signals, in order; once a second it
/// lets the core kill apps that ignored `Stop` and counts play time (`usage`); once a minute, in
/// system mode, it deletes the usage data of profiles that no longer exist. Runs forever.
pub async fn forward(
    connection: Connection,
    session: Shared,
    usage: SharedUsage,
    system: bool,
    events: Receiver<UnitEvent>,
) {
    let ticks = async_io::Timer::interval(Duration::from_secs(1));
    let tick_loop = async {
        let mut ticks = ticks;
        let mut seconds = 0_u64;
        loop {
            futures_lite::StreamExt::next(&mut ticks).await;
            lock(&session).tick(Instant::now());
            let changed = usage_lock(&usage).tick(Instant::now(), unix_now());
            send_usage_changed(&connection, changed).await;
            seconds += 1;
            if system && seconds % PURGE_EVERY_SECS == 0 {
                // A failed read must not look like "no profiles".
                if let Ok(ids) = fetch_profile_ids(&connection).await {
                    let gone = usage_lock(&usage).purge_except(&ids);
                    if !gone.is_empty() {
                        eprintln!("ruya-session: deleted the play history of {gone:?}");
                    }
                }
            }
        }
    };
    let event_loop = async {
        while let Ok(event) = events.recv().await {
            let notice = lock(&session).on_event(event);
            let Some(notice) = notice else { continue };
            let changed = match &notice {
                Notice::Started { instance, app_id } => {
                    let profile = lock(&session)
                        .list()
                        .into_iter()
                        .find(|a| &a.instance == instance)
                        .map(|a| a.profile);
                    if let Some(profile) = profile {
                        let version = flatpak_app_version(Path::new(FLATPAK_ROOT), app_id);
                        usage_lock(&usage).app_started(
                            instance,
                            &profile,
                            app_id,
                            &version,
                            Instant::now(),
                            unix_now(),
                        );
                    }
                    None
                }
                Notice::Exited {
                    instance, reason, ..
                } => usage_lock(&usage).app_exited(
                    instance,
                    end_reason_of(*reason),
                    Instant::now(),
                    unix_now(),
                ),
            };
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
            send_usage_changed(&connection, changed.into_iter().collect()).await;
        }
    };
    futures_lite::future::zip(tick_loop, event_loop).await;
}
