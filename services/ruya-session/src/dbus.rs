//! org.ruyaos.Session1 on D-Bus. Thin adapter: the rules live in `session.rs`. OS events arrive
//! over a channel (`forward`) and leave as signals; a timer kills apps that ignore `Stop`.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use async_channel::Receiver;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedValue, Value};
use zbus::{interface, Connection, MatchRule, MessageStream};

use crate::directory::{profile_ids, ProfileDirectory, ProfileRow, ProfileSnapshot};
use crate::session::{ExitReason, FrozenChange, Notice, RunningApp, Session, Status};
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

/// How long a `Launch` waits for the old instance of the same app to end after a `Stop`: the
/// grace time, the kill and a moment for the unit to go (T-340).
pub const LAUNCH_WAIT: Duration = Duration::from_secs(8);

/// Waits (without holding the lock) until no instance of `app_id` of `profile` is on its way out,
/// for at most `bound`. True when it is gone: the unit name is free and a launch can go on.
pub async fn wait_while_stopping(
    session: &Shared,
    app_id: &str,
    profile: &str,
    bound: Duration,
) -> bool {
    let start = Instant::now();
    while lock(session).is_stopping(app_id, profile) {
        if start.elapsed() >= bound {
            return false;
        }
        async_io::Timer::after(Duration::from_millis(50)).await;
    }
    true
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
        ("frozen", Value::from(app.frozen)),
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
    /// Freeze and Thaw take turns in the order they arrive (T-457): each call awaits
    /// `Profiles1` before it acts, so without this a quick Thaw could be served before the
    /// Freeze sent ahead of it and leave the game frozen. The freeze of a profile that leaves
    /// (`watch_active_profile`, T-165) takes the same turns.
    freezer_turn: FreezerTurn,
}

/// The turns of the freezer, shared by `SessionIface` and `watch_active_profile`.
pub type FreezerTurn = Arc<async_lock::Mutex<()>>;

impl SessionIface {
    pub fn new(session: Shared, usage: SharedUsage, system: bool) -> Self {
        SessionIface {
            session,
            usage,
            system,
            freezer_turn: Arc::new(async_lock::Mutex::new(())),
        }
    }

    /// The freezer's turns, for `watch_active_profile`.
    pub fn freezer_turn(&self) -> FreezerTurn {
        self.freezer_turn.clone()
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

    /// Freeze or Thaw (T-457): the signed-in profile is asked of `Profiles1` (system mode), then the
    /// core decides, and the `frozen` changes are announced.
    async fn freezer(
        &self,
        instance: &str,
        freeze: bool,
        connection: &Connection,
        emitter: &SignalEmitter<'_>,
    ) -> String {
        // Taken before the first await: a call that arrived first gets its turn first.
        let _turn = self.freezer_turn.lock().await;
        let Ok(active) = self.active(connection).await else {
            return "failed".to_owned();
        };
        let (status, changes) = {
            let mut session = lock(&self.session);
            let status = if freeze {
                session.freeze(instance, active.as_deref(), Instant::now())
            } else {
                session.thaw(instance, active.as_deref())
            };
            (status, session.take_frozen_changes())
        };
        emit_frozen(emitter, changes).await;
        status.as_str().to_owned()
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
        // A launch right after a `Stop` waits for the old unit instead of failing on its name.
        wait_while_stopping(&self.session, app_id, profile, LAUNCH_WAIT).await;
        let (status, instance) = lock(&self.session).launch(app_id, profile, unix_now());
        (status.as_str().to_owned(), instance)
    }

    async fn stop(
        &self,
        instance: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let (status, changes): (Status, Vec<FrozenChange>) = {
            let mut session = lock(&self.session);
            let status = session.stop(instance, Instant::now);
            (status, session.take_frozen_changes())
        };
        emit_frozen(&emitter, changes).await;
        status.as_str().to_owned()
    }

    async fn freeze(
        &self,
        instance: &str,
        #[zbus(connection)] connection: &Connection,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        self.freezer(instance, true, connection, &emitter).await
    }

    async fn thaw(
        &self,
        instance: &str,
        #[zbus(connection)] connection: &Connection,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        self.freezer(instance, false, connection, &emitter).await
    }

    fn instance_of_pid(&self, pid: u32) -> (String, String) {
        let (status, instance) = lock(&self.session).instance_of_pid(pid);
        (status.as_str().to_owned(), instance)
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
    async fn frozen_changed(
        emitter: &SignalEmitter<'_>,
        instance: String,
        frozen: bool,
    ) -> zbus::Result<()>;

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

/// Sends `FrozenChanged` for each change, in order.
async fn emit_frozen(emitter: &SignalEmitter<'_>, changes: Vec<FrozenChange>) {
    for c in changes {
        if let Err(err) = SessionIface::frozen_changed(emitter, c.instance, c.frozen).await {
            eprintln!("ruya-session: emitting FrozenChanged failed: {err}");
        }
    }
}

const PROFILES_NAME: &str = "org.ruyaos.Profiles1";

/// Follows the signed-in profile (T-165, ADR-004): on every `PropertiesChanged` of `Profiles1` and
/// every change of its owner (a restart of that service), `ActiveProfile` is read again and, when
/// it changed, the apps of the profile that left are frozen (`Session::profile_changed`) and
/// announced (`FrozenChanged`). This covers a switch from the Hub or the picker, a sign-out and
/// the idle lock alike. The signal is only the trigger: the value is read in the freezer's turn
/// (`follow_active`). Runs forever.
pub async fn watch_active_profile(connection: Connection, session: Shared, turn: FreezerTurn) {
    let signals = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender(PROFILES_NAME)
        .and_then(|b| b.path("/org/ruyaos/Profiles1"))
        .and_then(|b| b.interface("org.freedesktop.DBus.Properties"))
        .and_then(|b| b.member("PropertiesChanged"))
        .map(|b| b.build());
    let owner = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender("org.freedesktop.DBus")
        .and_then(|b| b.member("NameOwnerChanged"))
        .and_then(|b| b.arg(0, PROFILES_NAME))
        .map(|b| b.build());
    let (Ok(signals), Ok(owner)) = (signals, owner) else {
        return eprintln!("ruya-session: cannot follow the signed-in profile");
    };
    let (signals, owner) = match (
        MessageStream::for_match_rule(signals, &connection, None).await,
        MessageStream::for_match_rule(owner, &connection, None).await,
    ) {
        (Ok(a), Ok(b)) => (a, b),
        (Err(err), _) | (_, Err(err)) => {
            return eprintln!("ruya-session: cannot follow the signed-in profile: {err}");
        }
    };
    let mut stream = futures_lite::stream::or(signals, owner);
    // The first value is read once the streams are set up, so no change is missed in between.
    let mut last: Option<String> = None;
    loop {
        let read = || async {
            fetch_active_profile(&connection)
                .await
                .map_err(|err| {
                    eprintln!("ruya-session: Profiles1 ActiveProfile not readable: {err}")
                })
                .ok()
        };
        let changes = follow_active(&session, &turn, &mut last, read).await;
        if !changes.is_empty() {
            if let Ok(iface) = connection
                .object_server()
                .interface::<_, SessionIface>(OBJECT_PATH)
                .await
            {
                emit_frozen(iface.signal_emitter(), changes).await;
            }
        }
        if futures_lite::StreamExt::next(&mut stream).await.is_none() {
            return eprintln!(
                "ruya-session: the bus closed, the signed-in profile is not followed"
            );
        }
    }
}

/// One step of `watch_active_profile`: in the freezer's turn (after any Freeze or Thaw that came
/// first), the signed-in profile is read (`read`, `None` when it cannot be) and, when it is not
/// `last`, the apps of `last` are frozen (all but the new profile's when `last` is not known yet).
/// Reading the value in the turn, not taking it from the signal, means that a Thaw sent just before
/// the change (the Hub closing as Switch profile locks) is served first and the game ends frozen,
/// and that a profile that left and came back before its turn has nothing frozen. Returns the
/// `frozen` changes to announce.
async fn follow_active<F, Fut>(
    session: &Shared,
    turn: &FreezerTurn,
    last: &mut Option<String>,
    read: F,
) -> Vec<FrozenChange>
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Option<String>>,
{
    let _turn = turn.lock().await;
    let Some(active) = read().await else {
        return Vec::new();
    };
    if last.as_deref() == Some(active.as_str()) {
        return Vec::new();
    }
    let mut session = lock(session);
    for (unit, status) in session.profile_changed(last.as_deref(), &active, Instant::now()) {
        if status == Status::Ok {
            eprintln!(
                "ruya-session: froze {unit}: its profile is not signed in (now \"{active}\")"
            );
        }
    }
    *last = Some(active);
    session.take_frozen_changes()
}

/// RUY-568: an app that reached running is frozen at once when its profile is not the signed-in
/// one, so a game that was still starting when its profile left does not run on hidden. Like
/// `follow_active`, the profile is read (`read`, `None` when it cannot be) in the freezer's turn,
/// so a profile that signed in again before the turn has nothing frozen. When it cannot be read,
/// the profile the watcher saw last (`Session::last_active`) decides; with none known, nothing is
/// frozen. Returns the `frozen` changes to announce.
async fn freeze_started<F, Fut>(
    session: &Shared,
    turn: &FreezerTurn,
    instance: &str,
    read: F,
) -> Vec<FrozenChange>
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Option<String>>,
{
    let _turn = turn.lock().await;
    let read = read().await;
    let mut session = lock(session);
    let Some(active) = read.or_else(|| session.last_active().map(str::to_owned)) else {
        return Vec::new();
    };
    if session.freeze_if_away(instance, &active, Instant::now()) == Some(Status::Ok) {
        eprintln!(
            "ruya-session: froze {instance}: its profile is not signed in (now \"{active}\")"
        );
    }
    session.take_frozen_changes()
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
    turn: FreezerTurn,
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
            let started = match &notice {
                Notice::Started { instance, .. } => Some(instance.clone()),
                Notice::Exited { .. } => None,
            };
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
            // System mode only: `--session` has no signed-in profile to compare with.
            if let (true, Some(instance)) = (system, started) {
                let changes = freeze_started(&session, &turn, &instance, || async {
                    // Bounded: a hung ruya-profiles must not stall the event pump.
                    let read = async {
                        fetch_active_profile(&connection)
                            .await
                            .map_err(|err| {
                                eprintln!(
                                    "ruya-session: Profiles1 ActiveProfile not readable: {err}"
                                )
                            })
                            .ok()
                    };
                    let timeout = async {
                        async_io::Timer::after(Duration::from_secs(2)).await;
                        eprintln!("ruya-session: Profiles1 ActiveProfile read timed out");
                        None
                    };
                    futures_lite::future::or(read, timeout).await
                })
                .await;
                if !changes.is_empty() {
                    if let Ok(iface) = connection
                        .object_server()
                        .interface::<_, SessionIface>(OBJECT_PATH)
                        .await
                    {
                        emit_frozen(iface.signal_emitter(), changes).await;
                    }
                }
            }
        }
    };
    futures_lite::future::zip(tick_loop, event_loop).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::Status;
    use crate::spawner::{unit_name, FakeSpawner};

    const APP: &str = "org.ruyaos.Racer";

    fn stopping_session() -> (Shared, String) {
        let spawner: DynSpawner = Box::new(FakeSpawner::new().with_app(APP));
        let dir = ProfileSnapshot::new(["p1".to_owned()]);
        let shared: Shared = Arc::new(Mutex::new(Session::new(spawner, dir, Vec::new())));
        let (status, unit) = lock(&shared).launch(APP, "p1", 1);
        assert_eq!(
            (status, unit.as_str()),
            (Status::Ok, unit_name("ruya-p1", APP).as_str())
        );
        lock(&shared).on_event(UnitEvent::Started { unit: unit.clone() });
        assert_eq!(lock(&shared).stop(&unit, Instant::now()), Status::Ok);
        (shared, unit)
    }

    #[test]
    fn launch_into_a_taken_unit_name_waits_or_renames() {
        // The old unit ends 200 ms after the Stop: the wait sees it go and the launch works.
        let (shared, unit) = stopping_session();
        let ender = shared.clone();
        let old = unit.clone();
        let t = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(200));
            lock(&ender).on_event(UnitEvent::Exited {
                unit: old,
                code: 0,
                signaled: false,
            });
        });
        let t0 = Instant::now();
        assert!(futures_lite::future::block_on(wait_while_stopping(
            &shared,
            APP,
            "p1",
            Duration::from_secs(5)
        )));
        assert!(
            t0.elapsed() < Duration::from_secs(4),
            "it did not wait the whole bound"
        );
        t.join().unwrap_or_else(|_| panic!("ender"));
        assert_eq!(lock(&shared).launch(APP, "p1", 2).0, Status::Ok);

        // The old unit never ends: the wait stops at its bound and the launch is not
        // `already-running` but a plain failure, and it does not start a second unit.
        let (shared, _unit) = stopping_session();
        assert!(!futures_lite::future::block_on(wait_while_stopping(
            &shared,
            APP,
            "p1",
            Duration::from_millis(120)
        )));
        let (status, instance) = lock(&shared).launch(APP, "p1", 2);
        assert_eq!((status, instance.as_str()), (Status::Failed, ""));
    }

    // ---- The freeze of a profile that leaves (T-165) -----------------------------------------

    /// p1 runs Racer, and the watcher has seen p1 signed in.
    fn signed_in_session() -> (Shared, String, Option<String>) {
        let spawner: DynSpawner = Box::new(FakeSpawner::new().with_app(APP));
        let dir = ProfileSnapshot::new(["p1".to_owned(), "p2".to_owned()]);
        let shared: Shared = Arc::new(Mutex::new(Session::new(spawner, dir, Vec::new())));
        let (_, unit) = lock(&shared).launch(APP, "p1", 1);
        lock(&shared).on_event(UnitEvent::Started { unit: unit.clone() });
        (shared, unit, Some("p1".to_owned()))
    }

    fn is_frozen(shared: &Shared, unit: &str) -> bool {
        lock(shared)
            .list()
            .into_iter()
            .any(|a| a.instance == unit && a.frozen)
    }

    #[test]
    fn a_change_waits_for_the_thaw_ahead_of_it_and_the_game_ends_frozen() {
        // Switch profile from the Hub: the Hub closes (a Thaw), then the profile locks. The Thaw
        // came first and holds the turn while it reads Profiles1; the change waits for it.
        let (shared, unit, mut last) = signed_in_session();
        assert_eq!(
            lock(&shared).freeze(&unit, Some("p1"), Instant::now()),
            Status::Ok
        );
        let turn: FreezerTurn = Arc::new(async_lock::Mutex::new(()));
        futures_lite::future::block_on(async {
            let thaw_turn = turn.lock().await;
            let mut change = Box::pin(follow_active(&shared, &turn, &mut last, || async {
                Some(String::new())
            }));
            assert!(
                futures_lite::future::poll_once(&mut change).await.is_none(),
                "the change waits for the Thaw's turn"
            );
            assert_eq!(lock(&shared).thaw(&unit, Some("p1")), Status::Ok);
            lock(&shared).take_frozen_changes(); // the Hub's freeze and thaw, announced by them
            drop(thaw_turn);
            let changes = change.await;
            assert_eq!(
                changes,
                [FrozenChange {
                    instance: unit.clone(),
                    frozen: true
                }]
            );
        });
        assert!(is_frozen(&shared, &unit), "the final state is frozen");
        assert_eq!(last.as_deref(), Some(""));
    }

    #[test]
    fn a_profile_that_left_and_came_back_before_its_turn_has_nothing_frozen() {
        // The value is read in the turn, not taken from the signal: p1 locked and signed in again
        // before the watcher's turn came, so it reads "p1" and nothing changes.
        let (shared, unit, mut last) = signed_in_session();
        let turn: FreezerTurn = Arc::new(async_lock::Mutex::new(()));
        let changes =
            futures_lite::future::block_on(follow_active(&shared, &turn, &mut last, || async {
                Some("p1".to_owned())
            }));
        assert!(changes.is_empty());
        assert!(!is_frozen(&shared, &unit));
        // An unreadable Profiles1 changes nothing either, and the last value is kept.
        let changes =
            futures_lite::future::block_on(follow_active(&shared, &turn, &mut last, || async {
                None
            }));
        assert!(changes.is_empty());
        assert_eq!(last.as_deref(), Some("p1"));
        // Then p2 signs in: p1's game is frozen.
        let changes =
            futures_lite::future::block_on(follow_active(&shared, &turn, &mut last, || async {
                Some("p2".to_owned())
            }));
        assert_eq!(changes.len(), 1);
        assert!(is_frozen(&shared, &unit));
    }

    #[test]
    fn the_first_value_freezes_the_apps_of_every_profile_that_is_not_signed_in() {
        // After a restart of this service (`last` unknown) while the console is locked.
        let (shared, unit, _) = signed_in_session();
        let mut last = None;
        let turn: FreezerTurn = Arc::new(async_lock::Mutex::new(()));
        let changes =
            futures_lite::future::block_on(follow_active(&shared, &turn, &mut last, || async {
                Some(String::new())
            }));
        assert_eq!(changes.len(), 1);
        assert!(is_frozen(&shared, &unit));
    }

    #[test]
    fn an_app_that_starts_after_its_profile_left_is_frozen_in_the_freezers_turn() {
        // RUY-568: launched for p1, still starting when p2 signs in, running afterwards.
        let spawner: DynSpawner = Box::new(FakeSpawner::new().with_app(APP));
        let dir = ProfileSnapshot::new(["p1".to_owned(), "p2".to_owned()]);
        let shared: Shared = Arc::new(Mutex::new(Session::new(spawner, dir, Vec::new())));
        let (_, unit) = lock(&shared).launch(APP, "p1", 1);
        let mut last = Some("p1".to_owned());
        let turn: FreezerTurn = Arc::new(async_lock::Mutex::new(()));
        futures_lite::future::block_on(async {
            let changes = follow_active(&shared, &turn, &mut last, || async {
                Some("p2".to_owned())
            })
            .await;
            assert!(changes.is_empty(), "nothing runs yet");
            lock(&shared).on_event(UnitEvent::Started { unit: unit.clone() });
            // The check waits for a turn held by a Thaw or Freeze that came first.
            let held = turn.lock().await;
            let mut check = Box::pin(freeze_started(&shared, &turn, &unit, || async {
                Some("p2".to_owned())
            }));
            assert!(futures_lite::future::poll_once(&mut check).await.is_none());
            assert!(!is_frozen(&shared, &unit));
            drop(held);
            let changes = check.await;
            assert_eq!(
                changes,
                [FrozenChange {
                    instance: unit.clone(),
                    frozen: true
                }]
            );
        });
        assert!(is_frozen(&shared, &unit));
    }

    #[test]
    fn the_start_check_reads_the_profile_in_the_turn_and_keeps_a_signed_in_app_running() {
        let (shared, unit, _) = signed_in_session(); // Racer of p1 is running
        let turn: FreezerTurn = Arc::new(async_lock::Mutex::new(()));
        // p1 is signed in (again): nothing is frozen.
        let changes =
            futures_lite::future::block_on(freeze_started(&shared, &turn, &unit, || async {
                Some("p1".to_owned())
            }));
        assert!(changes.is_empty());
        assert!(!is_frozen(&shared, &unit));
        // Profiles1 not readable and no value seen yet: nothing is frozen.
        let changes =
            futures_lite::future::block_on(freeze_started(&shared, &turn, &unit, || async {
                None
            }));
        assert!(changes.is_empty());
        assert!(!is_frozen(&shared, &unit));
    }

    #[test]
    fn the_start_check_reads_the_profile_after_the_turn_comes_not_before() {
        // The value is read once the turn is ours: a read made while waiting would see "p2",
        // but p1 signed in again meanwhile.
        let (shared, unit, _) = signed_in_session();
        let turn: FreezerTurn = Arc::new(async_lock::Mutex::new(()));
        let cell = Arc::new(Mutex::new("p2".to_owned()));
        futures_lite::future::block_on(async {
            let held = turn.lock().await;
            let mut check = Box::pin(freeze_started(&shared, &turn, &unit, || {
                let cell = cell.clone();
                async move { Some(lock_cell(&cell)) }
            }));
            assert!(futures_lite::future::poll_once(&mut check).await.is_none());
            *cell.lock().unwrap_or_else(|e| e.into_inner()) = "p1".to_owned();
            drop(held);
            assert!(check.await.is_empty());
        });
        assert!(!is_frozen(&shared, &unit));
    }

    fn lock_cell(cell: &Arc<Mutex<String>>) -> String {
        cell.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    #[test]
    fn an_unreadable_profiles1_falls_back_to_the_profile_the_watcher_saw_last() {
        let turn: FreezerTurn = Arc::new(async_lock::Mutex::new(()));
        // The watcher saw p2 sign in while p1's app was still starting: it is frozen when it runs.
        let spawner: DynSpawner = Box::new(FakeSpawner::new().with_app(APP));
        let dir = ProfileSnapshot::new(["p1".to_owned(), "p2".to_owned()]);
        let shared: Shared = Arc::new(Mutex::new(Session::new(spawner, dir, Vec::new())));
        let (_, unit) = lock(&shared).launch(APP, "p1", 1);
        let mut last = Some("p1".to_owned());
        futures_lite::future::block_on(follow_active(&shared, &turn, &mut last, || async {
            Some("p2".to_owned())
        }));
        lock(&shared).on_event(UnitEvent::Started { unit: unit.clone() });
        let changes =
            futures_lite::future::block_on(freeze_started(&shared, &turn, &unit, || async {
                None
            }));
        assert_eq!(changes.len(), 1);
        assert!(is_frozen(&shared, &unit));
        // The watcher saw p1: nothing is frozen.
        let (shared, unit, mut last) = signed_in_session();
        futures_lite::future::block_on(follow_active(&shared, &turn, &mut last, || async {
            Some("p1".to_owned())
        }));
        let changes =
            futures_lite::future::block_on(freeze_started(&shared, &turn, &unit, || async {
                None
            }));
        assert!(changes.is_empty());
        assert!(!is_frozen(&shared, &unit));
    }
}
