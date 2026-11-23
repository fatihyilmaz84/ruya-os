//! org.ruyaos.Platform1 on D-Bus. Thin adapter: it asks the bus who the caller is
//! (`GetConnectionCredentials`, `GetConnectionUnixUser`), calls the core and sends the signals;
//! every rule is in `door.rs` and `lifecycle.rs`. It also follows the bus (a unique name that
//! leaves) and Profiles1 (which profiles exist, which is active).

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
    let answer = with(core, |door| call(door, &caller)).unwrap_or_else(|| refused(Status::Failed));
    // The name may have left while the credentials were asked for: its NameOwnerChanged was then
    // handled before the call cached or registered it. Asked after the call, the bus settles it.
    let has_owner = match DBusProxy::new(conn).await {
        Ok(bus) => bus
            .name_has_owner(BusName::Unique(sender.clone()))
            .await
            .unwrap_or(false),
        Err(_) => false,
    };
    with(core, |door| {
        door.forget_if_gone(sender.as_str(), has_owner, Instant::now())
    });
    answer
}

/// `Lifecycle.Register` for the message's sender: the served method's whole body (also the
/// developer mock's, RUY-158, which wraps the answer).
pub async fn register(core: &Shared, header: &Header<'_>, conn: &Connection) -> Status {
    as_app(
        core,
        header,
        conn,
        |s| s,
        |door, caller| lifecycle::register(door, caller, Instant::now()),
    )
    .await
}

/// `Lifecycle.SaveDone` for the message's sender (as [`register`]).
pub async fn save_done(core: &Shared, header: &Header<'_>, conn: &Connection) -> Status {
    as_app(
        core,
        header,
        conn,
        |s| s,
        |door, caller| lifecycle::save_done(door, caller, Instant::now()),
    )
    .await
}

pub struct LifecycleIface {
    core: Shared,
}

impl LifecycleIface {
    pub fn new(core: Shared) -> Self {
        LifecycleIface { core }
    }

    /// The answer of a Lifecycle method: its status.
    fn reply(&self, _member: &str, status: Status) -> String {
        status.as_str().to_owned()
    }
}

/// Declares `org.ruyaos.Platform1.Lifecycle` on `$ty`, the one copy of the interface: a struct
/// with a `core: Shared` field and a `fn reply(&self, member: &str, status: Status) -> String`
/// that turns each method's status into its answer. The service's [`LifecycleIface`] answers the
/// status itself; the developer mock's object (`mock::MockLifecycle`, dev-mock feature) passes it
/// through the faults of its control interface. The signals are sent by [`notify_lifecycle`]
/// through the service's object. The user's module imports `interface`, `Header`, `Connection`
/// and `SignalEmitter`.
macro_rules! lifecycle_interface {
    ($(#[$attr:meta])* $ty:ident) => {
        #[interface(name = "org.ruyaos.Platform1.Lifecycle")]
        $(#[$attr])*
        impl $ty {
            async fn register(
                &self,
                #[zbus(header)] header: Header<'_>,
                #[zbus(connection)] conn: &Connection,
            ) -> String {
                let status = $crate::dbus::register(&self.core, &header, conn).await;
                self.reply("Register", status)
            }

            async fn save_done(
                &self,
                #[zbus(header)] header: Header<'_>,
                #[zbus(connection)] conn: &Connection,
            ) -> String {
                let status = $crate::dbus::save_done(&self.core, &header, conn).await;
                self.reply("SaveDone", status)
            }

            #[zbus(signal)]
            async fn background(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

            #[zbus(signal)]
            async fn resume(emitter: &SignalEmitter<'_>, frozen_ms: u64) -> zbus::Result<()>;

            #[zbus(signal)]
            async fn stopping(emitter: &SignalEmitter<'_>, deadline_ms: u32) -> zbus::Result<()>;
        }
    };
}
#[cfg(feature = "dev-mock")]
pub(crate) use lifecycle_interface;

lifecycle_interface!(LifecycleIface);

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
    async fn list_capabilities(
        &self,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] conn: &Connection,
    ) -> (String, Vec<(String, bool)>) {
        let shell = self.checks.shell_uid;
        if !self
            .caller_may(&header, conn, |uid| may_manage(uid, shell))
            .await
        {
            return (Status::NotAllowed.as_str().to_owned(), Vec::new());
        }
        match with(&self.core, |door| door.list_capabilities()) {
            Some(list) => (Status::Ok.as_str().to_owned(), list),
            None => (Status::Failed.as_str().to_owned(), Vec::new()),
        }
    }

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
        notify_lifecycle(&self.core, conn, profile_id, scope, event, value_ms)
            .await
            .as_str()
            .to_owned()
    }
}

/// `NotifyLifecycle` once its caller was checked (also the developer mock's `Fire`): the signal to
/// the instance's registered connections and, for a "stopping", its settled answer.
pub async fn notify_lifecycle(
    core: &Shared,
    conn: &Connection,
    profile_id: &str,
    scope: &str,
    event: &str,
    value_ms: u64,
) -> Status {
    let notice = with(core, |door| {
        lifecycle::notify(door, profile_id, scope, event, value_ms, Instant::now())
    })
    .unwrap_or(Err(Status::Failed));
    let notice = match notice {
        Ok(notice) => notice,
        Err(status) => return status,
    };
    send_unicast(conn, &notice.names, notice.event).await;
    let Some(wait) = notice.wait else {
        return Status::Ok;
    };
    // The core's lock is not held while this waits: SaveDone, a name leaving or a withdrawal
    // answers through the channel.
    let answered = futures_lite::future::or(async { wait.answer.recv().await.ok() }, async {
        async_io::Timer::at(wait.deadline).await;
        None
    })
    .await;
    let status = match answered {
        Some(status) => status,
        None => {
            with(core, |door| {
                lifecycle::expire(door, profile_id, scope, Instant::now())
            });
            wait.settled()
        }
    };
    eprintln!(
        "ruya-platform: {profile_id} {scope} stopping: {}",
        status.as_str()
    );
    status
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

/// Follows Profiles1 for as long as the bus is up (`ruya_profiles_client::follow`): every answer
/// goes to the core, which drops what a removed profile had. Until it first answered nobody is a
/// profile (every caller is refused).
pub async fn watch_profiles(connection: Connection, core: Shared) {
    ruya_profiles_client::follow(
        &connection,
        "ruya-platform",
        PROFILES_RETRY,
        true,
        |active, ids| {
            let removed = with(&core, |door| {
                door.follow_profiles(ids, &active, Instant::now())
            });
            for profile in removed.unwrap_or_default() {
                eprintln!("ruya-platform: permissions of {profile} removed with the profile");
            }
            std::future::ready(())
        },
    )
    .await;
}
