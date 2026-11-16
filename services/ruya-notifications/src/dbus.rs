//! org.ruyaos.Notifications1 on D-Bus. Thin adapter: the rules live in `service.rs` and
//! `history.rs`. `watch_profiles` follows Profiles1 (the active profile, profiles and guests that
//! come and go) and retries while it is absent.

use std::collections::{BTreeSet, HashMap};
use std::io;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use zbus::message::Header;
use zbus::object_server::SignalEmitter;
use zbus::{fdo, interface, Connection, MatchRule, MessageStream};

use crate::caller;
use crate::history::{Event, Item, NewItem, Status};
use crate::service::{Notifications, Profiles, SetError};
use crate::settings::{Change, Property, QuietHours};
use crate::store::{valid_profile_id, Persist, ProfileData};

pub const BUS_NAME: &str = "org.ruyaos.Notifications1";
pub const OBJECT_PATH: &str = "/org/ruyaos/Notifications1";
pub const PROFILES_NAME: &str = "org.ruyaos.Profiles1";
const PROFILES_PATH: &str = "/org/ruyaos/Profiles1";

/// How often Profiles1 is asked again while it does not answer.
pub const PROFILES_RETRY: Duration = Duration::from_secs(2);

/// Chosen at runtime: `FileStore` on the console, `MemoryStore` in tests.
pub type DynStore = Box<dyn Persist + Send + Sync>;

impl<T: Persist + ?Sized> Persist for Box<T> {
    fn save(&mut self, profile: &str, data: &ProfileData) -> io::Result<()> {
        (**self).save(profile, data)
    }
    fn remove(&mut self, profile: &str) -> io::Result<()> {
        (**self).remove(profile)
    }
}

/// (ussssssa(ss)sbbx), the XML's item struct.
pub type ItemWire = (
    u32,
    String,
    String,
    String,
    String,
    String,
    String,
    Vec<(String, String)>,
    String,
    bool,
    bool,
    i64,
);

fn wire(item: Item) -> ItemWire {
    (
        item.id,
        item.source,
        item.app_id,
        item.kind,
        item.title,
        item.body,
        item.icon,
        item.actions,
        item.urgency,
        item.pinned,
        item.unread,
        item.time,
    )
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

pub struct NotificationsIface {
    core: Notifications<DynStore>,
    /// Development (`--session`): every caller may post.
    everyone: bool,
    shell_uid: Option<u32>,
}

impl NotificationsIface {
    pub fn new(core: Notifications<DynStore>, everyone: bool) -> Self {
        NotificationsIface {
            core,
            everyone,
            shell_uid: None,
        }
    }

    pub fn core(&self) -> &Notifications<DynStore> {
        &self.core
    }

    /// root or ruya-shell (the caller's uid from the bus, as `ruya-store` asks it).
    async fn caller_may_post(&mut self, header: &Header<'_>, connection: &Connection) -> bool {
        if self.everyone {
            return true;
        }
        let Some(sender) = header.sender() else {
            return false;
        };
        let Ok(bus) = fdo::DBusProxy::new(connection).await else {
            return false;
        };
        let Ok(uid) = bus.get_connection_unix_user(sender.clone().into()).await else {
            return false;
        };
        if self.shell_uid.is_none() {
            self.shell_uid = caller::uid_of(caller::SHELL_USER);
        }
        let ok = caller::allowed(uid, self.shell_uid);
        if !ok {
            eprintln!(
                "ruya-notifications: refused a call from uid {uid} (only root and ruya-shell)"
            );
        }
        ok
    }

    /// Takes over what Profiles1 says, and announces every property whose value the change of
    /// the active profile (or a wiped profile) changed.
    pub async fn follow(&mut self, emitter: &SignalEmitter<'_>, profiles: Profiles, active: &str) {
        let before = self.core.active_settings();
        if self.core.active() != active {
            eprintln!("ruya-notifications: the active profile is now \"{active}\"");
        }
        self.core.set_profiles(profiles);
        self.core.set_active(active);
        let after = self.core.active_settings();
        for property in before.differing(&after) {
            let _ = match property {
                Property::Quiet => self.quiet_changed(emitter).await,
                Property::DontInterruptGames => self.dont_interrupt_games_changed(emitter).await,
                Property::QuietHours => self.quiet_hours_changed(emitter).await,
                Property::ToastSeconds => self.toast_seconds_changed(emitter).await,
                Property::Sounds => self.sounds_changed(emitter).await,
                Property::SourcesEnabled => self.sources_enabled_changed(emitter).await,
            };
        }
    }

    fn write(&mut self, change: Change) -> fdo::Result<()> {
        self.core.set(change).map_err(|e| match e {
            SetError::NoProfile => {
                fdo::Error::Failed("nobody is signed in: there are no settings to write".into())
            }
            SetError::Invalid(why) => fdo::Error::InvalidArgs(why.into()),
        })
    }
}

async fn send(emitter: &SignalEmitter<'_>, events: Vec<Event>) {
    for event in events {
        let _ = match event {
            Event::Added(profile, item) => {
                NotificationsIface::added(emitter, &profile, wire(item)).await
            }
            Event::Removed(profile, ids, reason) => {
                NotificationsIface::removed(emitter, &profile, ids, reason.as_str()).await
            }
            Event::Changed(profile) => NotificationsIface::changed(emitter, &profile).await,
        };
    }
}

#[interface(name = "org.ruyaos.Notifications1")]
impl NotificationsIface {
    async fn list(
        &mut self,
        profile: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> Vec<ItemWire> {
        let (items, events) = self.core.list(profile, now_ms());
        send(&emitter, events).await;
        items.into_iter().map(wire).collect()
    }

    async fn dismiss(
        &mut self,
        id: u32,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let (status, events) = self.core.dismiss(id);
        send(&emitter, events).await;
        status.as_str().to_owned()
    }

    async fn dismiss_all(
        &mut self,
        profile: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let (status, events) = self.core.dismiss_all(profile);
        send(&emitter, events).await;
        status.as_str().to_owned()
    }

    async fn invoke(
        &mut self,
        id: u32,
        action: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let (status, events) = self.core.invoke(id, action);
        send(&emitter, events).await;
        status.as_str().to_owned()
    }

    async fn mark_read(
        &mut self,
        profile: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let (status, events) = self.core.mark_read(profile);
        send(&emitter, events).await;
        status.as_str().to_owned()
    }

    #[allow(clippy::too_many_arguments)] // the contract's argument list
    async fn post(
        &mut self,
        profile: &str,
        key: &str,
        source: &str,
        app_id: &str,
        kind: &str,
        title: &str,
        body: &str,
        icon: &str,
        actions: Vec<(String, String)>,
        urgency: &str,
        pinned: bool,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> (String, u32) {
        if !self.caller_may_post(&header, connection).await {
            return (Status::Forbidden.as_str().to_owned(), 0);
        }
        // A guest made a moment ago may not have reached us yet: ask Profiles1 once more.
        if valid_profile_id(profile) && self.core.knows(profile) != Some(true) {
            if let Ok((active, ids)) = fetch_profiles(connection).await {
                self.follow(&emitter, Profiles::Known(ids), &active).await;
            }
        }
        let new = NewItem {
            key: key.to_owned(),
            source: source.to_owned(),
            app_id: app_id.to_owned(),
            kind: kind.to_owned(),
            title: title.to_owned(),
            body: body.to_owned(),
            icon: icon.to_owned(),
            actions,
            urgency: urgency.to_owned(),
            pinned,
        };
        let posted = self.core.post(profile, new, now_ms());
        if posted.status != Status::Ok {
            eprintln!(
                "ruya-notifications: Post for \"{profile}\" (source {source}) answered {}",
                posted.status.as_str()
            );
        }
        send(&emitter, posted.events).await;
        (posted.status.as_str().to_owned(), posted.id)
    }

    async fn withdraw(
        &mut self,
        key: &str,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        if !self.caller_may_post(&header, connection).await {
            return Status::Forbidden.as_str().to_owned();
        }
        let (status, events) = self.core.withdraw(key);
        send(&emitter, events).await;
        status.as_str().to_owned()
    }

    #[zbus(property)]
    fn quiet(&self) -> bool {
        self.core.active_settings().quiet
    }

    #[zbus(property)]
    fn set_quiet(&mut self, value: bool) -> fdo::Result<()> {
        self.write(Change::Quiet(value))
    }

    #[zbus(property)]
    fn dont_interrupt_games(&self) -> bool {
        self.core.active_settings().dont_interrupt_games
    }

    #[zbus(property)]
    fn set_dont_interrupt_games(&mut self, value: bool) -> fdo::Result<()> {
        self.write(Change::DontInterruptGames(value))
    }

    #[zbus(property)]
    fn quiet_hours(&self) -> (bool, String, String) {
        let q = self.core.active_settings().quiet_hours;
        (q.enabled, q.from, q.to)
    }

    #[zbus(property)]
    fn set_quiet_hours(&mut self, value: (bool, String, String)) -> fdo::Result<()> {
        let (enabled, from, to) = value;
        self.write(Change::QuietHours(QuietHours { enabled, from, to }))
    }

    #[zbus(property)]
    fn toast_seconds(&self) -> u32 {
        self.core.active_settings().toast_seconds
    }

    #[zbus(property)]
    fn set_toast_seconds(&mut self, value: u32) -> fdo::Result<()> {
        self.write(Change::ToastSeconds(value))
    }

    #[zbus(property)]
    fn sounds(&self) -> bool {
        self.core.active_settings().sounds
    }

    #[zbus(property)]
    fn set_sounds(&mut self, value: bool) -> fdo::Result<()> {
        self.write(Change::Sounds(value))
    }

    #[zbus(property)]
    fn sources_enabled(&self) -> HashMap<String, bool> {
        self.core
            .active_settings()
            .sources_enabled
            .into_iter()
            .collect()
    }

    #[zbus(property)]
    fn set_sources_enabled(&mut self, value: HashMap<String, bool>) -> fdo::Result<()> {
        self.write(Change::SourcesEnabled(value.into_iter().collect()))
    }

    #[zbus(signal)]
    async fn added(emitter: &SignalEmitter<'_>, profile: &str, item: ItemWire) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn removed(
        emitter: &SignalEmitter<'_>,
        profile: &str,
        ids: Vec<u32>,
        reason: &str,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn changed(emitter: &SignalEmitter<'_>, profile: &str) -> zbus::Result<()>;
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

async fn apply(connection: &Connection, profiles: Profiles, active: &str) {
    let Ok(iface) = connection
        .object_server()
        .interface::<_, NotificationsIface>(OBJECT_PATH)
        .await
    else {
        return;
    };
    let emitter = iface.signal_emitter().clone();
    iface
        .get_mut()
        .await
        .follow(&emitter, profiles, active)
        .await;
}

/// Reads Profiles1 once (start-up, before the name is taken). False when it did not answer.
pub async fn follow_profiles_once(connection: &Connection) -> bool {
    match fetch_profiles(connection).await {
        Ok((active, ids)) => {
            eprintln!(
                "ruya-notifications: {} profile(s) and guest(s) exist, active \"{active}\"",
                ids.len()
            );
            apply(connection, Profiles::Known(ids), &active).await;
            true
        }
        Err(err) => {
            eprintln!(
                "ruya-notifications: Profiles1 not readable, asking again every {} s: {err}",
                PROFILES_RETRY.as_secs()
            );
            false
        }
    }
}

/// Follows Profiles1 for as long as the bus is up: on its ActiveProfile change, ProfilesChanged
/// (profiles and guests made or removed) and on its name coming back, the active profile and the
/// profile list are read again. While Profiles1 does not answer it is asked every
/// `PROFILES_RETRY`; the service never exits for it.
pub async fn watch_profiles(connection: Connection, mut answering: bool) {
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
        return eprintln!("ruya-notifications: cannot follow Profiles1");
    };
    let streams = (
        MessageStream::for_match_rule(props, &connection, None).await,
        MessageStream::for_match_rule(changed, &connection, None).await,
        MessageStream::for_match_rule(owner, &connection, None).await,
    );
    let (Ok(a), Ok(b), Ok(c)) = streams else {
        return eprintln!("ruya-notifications: cannot follow Profiles1");
    };
    let mut stream = futures_lite::stream::or(futures_lite::stream::or(a, b), c);
    loop {
        // Read after the streams are set up, so no change is missed in between.
        match fetch_profiles(&connection).await {
            Ok((active, ids)) => {
                if !answering {
                    eprintln!("ruya-notifications: Profiles1 answers again");
                }
                answering = true;
                apply(&connection, Profiles::Known(ids), &active).await;
            }
            Err(err) => {
                if answering {
                    eprintln!(
                        "ruya-notifications: Profiles1 not readable, asking again every {} s: {err}",
                        PROFILES_RETRY.as_secs()
                    );
                }
                answering = false;
            }
        }
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
            return eprintln!("ruya-notifications: the bus closed, Profiles1 is not followed");
        }
    }
}
