//! org.ruyaos.Platform1 on D-Bus. Thin adapter: it asks the bus who the caller is
//! (`GetConnectionCredentials`, `GetConnectionUnixUser`), calls the core and sends the signals;
//! every rule is in `door.rs` and `lifecycle.rs`. It also follows the bus (a unique name that
//! leaves) and Profiles1 (which profiles exist, which is active).

use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use zbus::fdo::{ConnectionCredentials, DBusProxy};
use zbus::message::Header;
use zbus::names::{BusName, UniqueName};
use zbus::object_server::SignalEmitter;
use zbus::{interface, Connection, MatchRule, MessageStream};

use crate::door::{may_manage, may_notify};
use crate::identity::Caller;
use crate::lifecycle::{self, Event};
use crate::{Platform, Status};

pub const BUS_NAME: &str = "org.ruyaos.Platform1";
pub const OBJECT_PATH: &str = "/org/ruyaos/Platform1";
const PROFILES_NAME: &str = "org.ruyaos.Profiles1";
const PROFILES_PATH: &str = "/org/ruyaos/Profiles1";
/// While Profiles1 does not answer it is asked again this often.
const PROFILES_RETRY: Duration = Duration::from_secs(5);

pub type Shared = Arc<Mutex<Platform>>;

/// How `Manage` callers are checked: by uid on the system bus; not at all with `--session`
/// (development, logged at start).
#[derive(Debug, Clone, Copy)]
pub struct Checks {
    pub enforce: bool,
    /// The uid of `ruya-shell`, `None` when it could not be found (then root only).
    pub shell_uid: Option<u32>,
}

/// Runs `f` on the core; `None` if a panic poisoned the lock (the call answers `failed`).
fn with<R>(core: &Shared, f: impl FnOnce(&mut Platform) -> R) -> Option<R> {
    match core.lock() {
        Ok(mut door) => Some(f(&mut door)),
        Err(_) => {
            eprintln!("ruya-platform: the core's lock is poisoned");
            None
        }
    }
}

async fn credentials(
    conn: &Connection,
    sender: &UniqueName<'_>,
) -> zbus::Result<ConnectionCredentials> {
    let bus = DBusProxy::new(conn).await?;
    Ok(bus
        .get_connection_credentials(BusName::Unique(sender.clone()))
        .await?)
}

/// The core's view of the credentials. The pidfd stays open in `creds` while the core reads it.
fn caller_of<'a>(name: &'a str, creds: &ConnectionCredentials) -> Caller<'a> {
    #[cfg(unix)]
    let pidfd = {
        use std::os::fd::AsRawFd;
        creds.process_fd().map(|fd| fd.as_raw_fd())
    };
    #[cfg(not(unix))]
    let pidfd = None;
    Caller {
        name,
        uid: creds.unix_user_id(),
        pid: creds.process_id(),
        pidfd,
    }
}

/// Runs a Lifecycle call for the message's sender: its credentials from the bus, then `call`.
async fn as_app<R>(
    core: &Shared,
    header: &Header<'_>,
    conn: &Connection,
    refused: impl Fn(Status) -> R,
    call: impl FnOnce(&mut Platform, &Caller<'_>) -> R,
) -> R {
    let Some(sender) = header.sender() else {
        return refused(Status::NotAnApp);
    };
    let creds = match credentials(conn, sender).await {
        Ok(creds) => creds,
        Err(err) => {
            eprintln!("ruya-platform: no credentials for {sender}: {err}");
            return refused(Status::NotAnApp);
        }
    };
    let caller = caller_of(sender.as_str(), &creds);
    with(core, |door| call(door, &caller)).unwrap_or_else(|| refused(Status::Failed))
}

pub struct LifecycleIface {
    core: Shared,
}

impl LifecycleIface {
    pub fn new(core: Shared) -> Self {
        LifecycleIface { core }
    }
}

#[interface(name = "org.ruyaos.Platform1.Lifecycle")]
impl LifecycleIface {
    async fn register(
        &self,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] conn: &Connection,
    ) -> String {
        let status = as_app(
            &self.core,
            &header,
            conn,
            |s| s,
            |door, caller| lifecycle::register(door, caller, Instant::now()),
        )
        .await;
        status.as_str().to_owned()
    }

    async fn save_done(
        &self,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] conn: &Connection,
    ) -> String {
        let saved = as_app(&self.core, &header, conn, Err, |door, caller| {
            lifecycle::save_done(door, caller, Instant::now())
        })
        .await;
        match saved {
            Ok((profile, scope)) => {
                eprintln!("ruya-platform: {profile} {scope} saved");
                if let Ok(emitter) = SignalEmitter::new(conn, OBJECT_PATH) {
                    if let Err(err) = ManageIface::saved(&emitter, &profile, &scope).await {
                        eprintln!("ruya-platform: Saved not sent: {err}");
                    }
                }
                Status::Ok.as_str().to_owned()
            }
            Err(status) => status.as_str().to_owned(),
        }
    }

    #[zbus(signal)]
    async fn background(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn resume(emitter: &SignalEmitter<'_>, frozen_ms: u64) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn stopping(emitter: &SignalEmitter<'_>, deadline_ms: u32) -> zbus::Result<()>;
}

/// Sends `event` to each of `names` alone (a unicast signal: the message carries the destination,
/// so the bus delivers it to that connection only).
async fn send_unicast(conn: &Connection, names: &[String], event: Event) {
    for name in names {
        let Ok(dest) = BusName::try_from(name.as_str()) else {
            continue;
        };
        let Ok(emitter) = SignalEmitter::new(conn, OBJECT_PATH) else {
            continue;
        };
        let emitter = emitter.set_destination(dest);
        let sent = match event {
            Event::Background => LifecycleIface::background(&emitter).await,
            Event::Resume { frozen_ms } => LifecycleIface::resume(&emitter, frozen_ms).await,
            Event::Stopping { deadline_ms } => {
                LifecycleIface::stopping(&emitter, deadline_ms).await
            }
        };
        if let Err(err) = sent {
            eprintln!("ruya-platform: {event:?} not sent to {name}: {err}");
        }
    }
}

pub struct ManageIface {
    core: Shared,
    checks: Checks,
}

impl ManageIface {
    pub fn new(core: Shared, checks: Checks) -> Self {
        ManageIface { core, checks }
    }

    /// Is the message's sender allowed by `rule` (its uid from the bus)? Always with `--session`.
    async fn caller_may(
        &self,
        header: &Header<'_>,
        conn: &Connection,
        rule: impl Fn(u32) -> bool,
    ) -> bool {
        if !self.checks.enforce {
            return true;
        }
        let Some(sender) = header.sender() else {
            return false;
        };
        let uid = match DBusProxy::new(conn).await {
            Ok(bus) => bus
                .get_connection_unix_user(BusName::Unique(sender.clone()))
                .await
                .ok(),
            Err(_) => None,
        };
        uid.is_some_and(rule)
    }
}

#[interface(name = "org.ruyaos.Platform1.Manage")]
impl ManageIface {
    async fn list_permissions(
        &self,
        profile_id: &str,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] conn: &Connection,
    ) -> (String, Vec<(String, String, bool)>) {
        let shell = self.checks.shell_uid;
        if !self
            .caller_may(&header, conn, |uid| may_manage(uid, shell))
            .await
        {
            return (Status::NotAllowed.as_str().to_owned(), Vec::new());
        }
        match with(&self.core, |door| door.list_permissions(profile_id)) {
            Some(Ok(list)) => (Status::Ok.as_str().to_owned(), list),
            Some(Err(status)) => (status.as_str().to_owned(), Vec::new()),
            None => (Status::Failed.as_str().to_owned(), Vec::new()),
        }
    }

    async fn set_permission(
        &self,
        profile_id: &str,
        app_id: &str,
        capability: &str,
        allowed: bool,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] conn: &Connection,
    ) -> String {
        let shell = self.checks.shell_uid;
        if !self
            .caller_may(&header, conn, |uid| may_manage(uid, shell))
            .await
        {
            return Status::NotAllowed.as_str().to_owned();
        }
        with(&self.core, |door| {
            door.set_permission(profile_id, app_id, capability, allowed)
        })
        .unwrap_or(Status::Failed)
        .as_str()
        .to_owned()
    }

    async fn notify_lifecycle(
        &self,
        profile_id: &str,
        scope: &str,
        event: &str,
        value_ms: u64,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] conn: &Connection,
    ) -> String {
        if !self.caller_may(&header, conn, may_notify).await {
            return Status::NotAllowed.as_str().to_owned();
        }
        let sent = with(&self.core, |door| {
            lifecycle::notify(door, profile_id, scope, event, value_ms)
        })
        .unwrap_or(Err(Status::Failed));
        match sent {
            Ok((event, names)) => {
                send_unicast(conn, &names, event).await;
                Status::Ok.as_str().to_owned()
            }
            Err(status) => status.as_str().to_owned(),
        }
    }

    #[zbus(signal)]
    async fn saved(emitter: &SignalEmitter<'_>, profile_id: &str, scope: &str) -> zbus::Result<()>;
}

/// Forgets every unique name that leaves the bus (NameOwnerChanged with no new owner), for as long
/// as the bus is up.
pub async fn watch_names(connection: Connection, core: Shared) {
    let rule = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender("org.freedesktop.DBus")
        .and_then(|b| b.interface("org.freedesktop.DBus"))
        .and_then(|b| b.member("NameOwnerChanged"))
        .map(|b| b.build());
    let Ok(rule) = rule else {
        return eprintln!("ruya-platform: cannot follow the bus's names");
    };
    let Ok(mut stream) = MessageStream::for_match_rule(rule, &connection, None).await else {
        return eprintln!("ruya-platform: cannot follow the bus's names");
    };
    while let Some(msg) = futures_lite::StreamExt::next(&mut stream).await {
        let Ok(msg) = msg else { continue };
        let Ok((name, _old, new)) = msg.body().deserialize::<(String, String, String)>() else {
            continue;
        };
        if name.starts_with(':') && new.is_empty() {
            with(&core, |door| door.name_gone(&name, Instant::now()));
        }
    }
    eprintln!("ruya-platform: the bus closed, names are not followed");
}

/// Profiles1's active profile and every profile id that exists: ListProfiles (kept profiles)
/// with ListGuests (live temporary guests).
pub async fn fetch_profiles(connection: &Connection) -> zbus::Result<(String, BTreeSet<String>)> {
    let proxy = zbus::Proxy::new(connection, PROFILES_NAME, PROFILES_PATH, PROFILES_NAME).await?;
    let active: String = proxy.get_property("ActiveProfile").await?;
    let profiles: Vec<(String, String, String, String, bool)> =
        proxy.call("ListProfiles", &()).await?;
    let guests: Vec<(String, String, u32)> = proxy.call("ListGuests", &()).await?;
    let ids = profiles
        .into_iter()
        .map(|p| p.0)
        .chain(guests.into_iter().map(|g| g.0))
        .collect();
    Ok((active, ids))
}

/// Reads Profiles1 into the core; false when it did not answer (logged when `answering` was
/// true, so a Profiles1 that stays away is logged once).
async fn follow_once(connection: &Connection, core: &Shared, answering: bool) -> bool {
    match fetch_profiles(connection).await {
        Ok((active, ids)) => {
            if !answering {
                eprintln!(
                    "ruya-platform: Profiles1 answers: {} profile(s) and guest(s)",
                    ids.len()
                );
            }
            let removed = with(core, |door| {
                door.follow_profiles(ids, &active, Instant::now())
            });
            for profile in removed.unwrap_or_default() {
                eprintln!("ruya-platform: permissions of {profile} removed with the profile");
            }
            true
        }
        Err(err) => {
            if answering {
                eprintln!(
                    "ruya-platform: Profiles1 not readable, asking again every {} s: {err}",
                    PROFILES_RETRY.as_secs()
                );
            }
            false
        }
    }
}

/// Follows Profiles1 for as long as the bus is up (the pattern of ruya-notifications'
/// `watch_profiles`): on its ActiveProfile change, ProfilesChanged and its name coming back the
/// profiles are read again; while it does not answer it is asked every `PROFILES_RETRY`. Until it
/// first answered nobody is a profile (every caller is refused).
pub async fn watch_profiles(connection: Connection, core: Shared) {
    let rule = |interface: &'static str, member: &'static str| {
        MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .sender(PROFILES_NAME)
            .and_then(|b| b.path(PROFILES_PATH))
            .and_then(|b| b.interface(interface))
            .and_then(|b| b.member(member))
            .map(|b| b.build())
    };
    let owner = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender("org.freedesktop.DBus")
        .and_then(|b| b.member("NameOwnerChanged"))
        .and_then(|b| b.arg(0, PROFILES_NAME))
        .map(|b| b.build());
    let (Ok(props), Ok(changed), Ok(owner)) = (
        rule("org.freedesktop.DBus.Properties", "PropertiesChanged"),
        rule(PROFILES_NAME, "ProfilesChanged"),
        owner,
    ) else {
        return eprintln!("ruya-platform: cannot follow Profiles1");
    };
    let streams = (
        MessageStream::for_match_rule(props, &connection, None).await,
        MessageStream::for_match_rule(changed, &connection, None).await,
        MessageStream::for_match_rule(owner, &connection, None).await,
    );
    let (Ok(a), Ok(b), Ok(c)) = streams else {
        return eprintln!("ruya-platform: cannot follow Profiles1");
    };
    let mut stream = futures_lite::stream::or(futures_lite::stream::or(a, b), c);
    let mut answering = true;
    loop {
        // Read after the streams are set up, so no change is missed in between.
        answering = follow_once(&connection, &core, answering).await;
        let next = async { futures_lite::StreamExt::next(&mut stream).await.is_some() };
        let up = if answering {
            next.await
        } else {
            futures_lite::future::or(next, async {
                async_io::Timer::after(PROFILES_RETRY).await;
                true
            })
            .await
        };
        if !up {
            return eprintln!("ruya-platform: the bus closed, Profiles1 is not followed");
        }
    }
}
