//! org.ruyaos.Devices1.Audio and .Network on D-Bus. Thin adapter: the rules live in `audio.rs`
//! and `network.rs`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use blocking::unblock;
use futures_lite::{future, StreamExt};
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedValue, Value};
use zbus::{interface, Connection, MatchRule, MessageStream};

use crate::audio::Audio;
#[cfg(target_os = "linux")]
use crate::audio::Changes;
use crate::network::{self, Network, NetworkManager};

/// Chosen at runtime: `wpctl` on Linux, a fake in `--session` development.
pub type DynPipeWire = Box<dyn crate::audio::PipeWire>;

impl crate::audio::PipeWire for DynPipeWire {
    fn snapshot(&mut self) -> Result<crate::audio::Snapshot, String> {
        (**self).snapshot()
    }
    fn set_default(&mut self, id: &str) -> Result<(), String> {
        (**self).set_default(id)
    }
    fn set_volume(&mut self, volume: u32) -> Result<(), String> {
        (**self).set_volume(volume)
    }
    fn set_muted(&mut self, muted: bool) -> Result<(), String> {
        (**self).set_muted(muted)
    }
}

pub const BUS_NAME: &str = "org.ruyaos.Devices1";
pub const OBJECT_PATH: &str = "/org/ruyaos/Devices1";
pub type Shared = Arc<Mutex<Audio<DynPipeWire>>>;

fn lock(shared: &Shared) -> MutexGuard<'_, Audio<DynPipeWire>> {
    // A poisoned lock only means another call panicked; the state itself is plain data.
    shared.lock().unwrap_or_else(|e| e.into_inner())
}

pub struct AudioIface {
    audio: Shared,
}

impl AudioIface {
    pub fn new(audio: Shared) -> Self {
        AudioIface { audio }
    }
}

#[interface(name = "org.ruyaos.Devices1.Audio")]
impl AudioIface {
    fn list_sinks(&self) -> Vec<HashMap<String, OwnedValue>> {
        lock(&self.audio)
            .list_sinks()
            .into_iter()
            .map(|(s, is_default)| {
                let own = |v: Value<'_>| OwnedValue::try_from(v).ok();
                [
                    ("id", own(Value::from(s.id.clone()))),
                    ("name", own(Value::from(s.name.clone()))),
                    ("kind", own(Value::from(s.kind.as_str()))),
                    ("is_default", own(Value::from(is_default))),
                ]
                .into_iter()
                .filter_map(|(k, v)| v.map(|v| (k.to_owned(), v)))
                .collect()
            })
            .collect()
    }

    async fn set_default_sink(
        &self,
        id: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let (status, before, after) = {
            let mut audio = lock(&self.audio);
            let before = audio.default_sink().map(str::to_owned);
            let status = audio.set_default_sink(id);
            (status, before, audio.default_sink().map(str::to_owned))
        };
        if before != after {
            let _ = Self::sinks_changed(&emitter).await;
            let _ = Self::default_sink_changed(&emitter, after.unwrap_or_default()).await;
        }
        status.as_str().to_owned()
    }

    async fn set_channel_volume(
        &self,
        channel: &str,
        value: u32,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let status = lock(&self.audio).set_channel(channel, value);
        if status == crate::Status::Ok {
            let _ = self.channel_volumes_changed(&emitter).await;
        }
        status.as_str().to_owned()
    }

    #[zbus(property)]
    fn master_volume(&self) -> u32 {
        lock(&self.audio).volume()
    }

    #[zbus(property)]
    fn set_master_volume(&mut self, value: u32) {
        let status = lock(&self.audio).set_volume(value);
        if status != crate::Status::Ok {
            eprintln!("ruya-devices: setting the volume failed");
        }
    }

    #[zbus(property)]
    fn muted(&self) -> bool {
        lock(&self.audio).muted()
    }

    #[zbus(property)]
    fn set_muted(&mut self, value: bool) {
        let status = lock(&self.audio).set_muted(value);
        if status != crate::Status::Ok {
            eprintln!("ruya-devices: setting mute failed");
        }
    }

    #[zbus(property)]
    fn channel_volumes(&self) -> HashMap<String, u32> {
        lock(&self.audio).channels().into_iter().collect()
    }

    #[zbus(signal)]
    async fn sinks_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn default_sink_changed(emitter: &SignalEmitter<'_>, id: String) -> zbus::Result<()>;
}

/// Follows PipeWire by events (`pw-dump --monitor`, restarted with a back-off when it dies) and
/// turns what changed into signals. Runs forever; nothing runs while the graph is quiet.
#[cfg(target_os = "linux")]
pub async fn watch(connection: Connection, audio: Shared) {
    crate::events::follow(
        crate::events::PwMonitor::start,
        |delay| async move {
            async_io::Timer::after(delay).await;
        },
        || async {
            refresh_audio(&connection, &audio).await;
            true
        },
    )
    .await;
}

/// Reads PipeWire once and emits the signals for what changed.
#[cfg(target_os = "linux")]
async fn refresh_audio(connection: &Connection, audio: &Shared) {
    let result = lock(audio).refresh();
    match result {
        Ok(changes) if changes.any() => {
            if let Err(err) = announce(connection, &changes).await {
                eprintln!("ruya-devices: emitting signals failed: {err}");
            }
        }
        Ok(_) => {}
        Err(err) => eprintln!("ruya-devices: reading PipeWire failed: {err}"),
    }
}

#[cfg(target_os = "linux")]
async fn announce(connection: &Connection, changes: &Changes) -> zbus::Result<()> {
    let iface = connection
        .object_server()
        .interface::<_, AudioIface>(OBJECT_PATH)
        .await?;
    let emitter = iface.signal_emitter();
    if changes.sinks {
        AudioIface::sinks_changed(emitter).await?;
    }
    if let Some(id) = &changes.default {
        AudioIface::default_sink_changed(emitter, id.clone()).await?;
    }
    if changes.props {
        let this = iface.get().await;
        this.master_volume_changed(emitter).await?;
        this.muted_changed(emitter).await?;
    }
    Ok(())
}

/// Chosen at runtime: NetworkManager on Linux, a fake in `--session` development.
pub type DynNm = Box<dyn NetworkManager>;

impl NetworkManager for DynNm {
    fn snapshot(&self) -> Result<network::Raw, String> {
        (**self).snapshot()
    }
    fn scan(&self) -> Result<(), String> {
        (**self).scan()
    }
    fn connect(&self, ssid: &str, password: Option<&str>) -> Result<(), network::ConnectError> {
        (**self).connect(ssid, password)
    }
    fn forget(&self, ssid: &str) -> Result<(), String> {
        (**self).forget(ssid)
    }
}

pub type SharedNet = Arc<Network<DynNm>>;

/// Quiet time after the last NetworkManager signal before the state is read again: a scan or a
/// join is a burst of dozens of them.
const DEBOUNCE: Duration = Duration::from_millis(300);

const NM_BUS_NAME: &str = "org.freedesktop.NetworkManager";

pub struct NetworkIface {
    net: SharedNet,
}

impl NetworkIface {
    pub fn new(net: SharedNet) -> Self {
        NetworkIface { net }
    }

    async fn emit(&self, emitter: &SignalEmitter<'_>, changes: &network::Changes) {
        let result = async {
            if changes.networks {
                Self::networks_changed(emitter).await?;
            }
            if changes.state {
                self.state_changed(emitter).await?;
                self.primary_changed(emitter).await?;
            }
            Ok::<(), zbus::Error>(())
        }
        .await;
        if let Err(err) = result {
            eprintln!("ruya-devices: emitting network signals failed: {err}");
        }
    }

    /// Reads NetworkManager again (off the executor: it blocks) and announces what changed.
    async fn settle(&self, emitter: &SignalEmitter<'_>) {
        let net = self.net.clone();
        match unblock(move || net.refresh()).await {
            Ok(changes) => self.emit(emitter, &changes).await,
            Err(err) => eprintln!("ruya-devices: reading NetworkManager failed: {err}"),
        }
    }
}

#[interface(name = "org.ruyaos.Devices1.Network")]
impl NetworkIface {
    #[zbus(property)]
    fn state(&self) -> String {
        self.net.state().as_str().to_owned()
    }

    #[zbus(property)]
    fn primary(&self) -> HashMap<String, OwnedValue> {
        let Some(p) = self.net.primary() else {
            return HashMap::new();
        };
        let own = |v: Value<'_>| OwnedValue::try_from(v).ok();
        [
            ("kind", own(Value::from(p.kind.as_str()))),
            ("name", own(Value::from(p.name.clone()))),
            ("ip", own(Value::from(p.ip.clone()))),
            ("signal", p.signal.and_then(|s| own(Value::from(s)))),
        ]
        .into_iter()
        .filter_map(|(k, v)| v.map(|v| (k.to_owned(), v)))
        .collect()
    }

    fn list_wifi(&self) -> Vec<HashMap<String, OwnedValue>> {
        self.net
            .list_wifi()
            .into_iter()
            .map(|w| {
                let own = |v: Value<'_>| OwnedValue::try_from(v).ok();
                [
                    ("id", own(Value::from(w.id().to_owned()))),
                    ("ssid", own(Value::from(w.ssid.clone()))),
                    ("signal", own(Value::from(w.signal))),
                    ("security", own(Value::from(w.security.as_str()))),
                    ("known", own(Value::from(w.known))),
                    ("active", own(Value::from(w.active))),
                ]
                .into_iter()
                .filter_map(|(k, v)| v.map(|v| (k.to_owned(), v)))
                .collect()
            })
            .collect()
    }

    async fn scan(&self) -> String {
        let net = self.net.clone();
        unblock(move || net.scan()).await.as_str().to_owned()
    }

    async fn connect(
        &self,
        id: &str,
        password: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let (net, id, password) = (self.net.clone(), id.to_owned(), password.to_owned());
        let status = unblock(move || net.connect(&id, &password)).await;
        self.settle(&emitter).await;
        status.as_str().to_owned()
    }

    async fn forget(&self, id: &str, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) -> String {
        let (net, id) = (self.net.clone(), id.to_owned());
        let status = unblock(move || net.forget(&id)).await;
        self.settle(&emitter).await;
        status.as_str().to_owned()
    }

    #[zbus(signal)]
    async fn networks_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

/// Follows NetworkManager's signals (any of them: state, devices, access points, connections)
/// and, after a quiet moment, reads the state again and announces what changed. No polling.
/// Runs forever.
pub async fn watch_network(connection: Connection, net: SharedNet) {
    let rule = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender(NM_BUS_NAME)
        .map(|b| b.build());
    let mut stream = match rule {
        Ok(rule) => match MessageStream::for_match_rule(rule, &connection, None).await {
            Ok(stream) => stream,
            Err(err) => return eprintln!("ruya-devices: cannot follow NetworkManager: {err}"),
        },
        Err(err) => return eprintln!("ruya-devices: cannot follow NetworkManager: {err}"),
    };
    while stream.next().await.is_some() {
        while future::or(async { stream.next().await.is_some() }, async {
            async_io::Timer::after(DEBOUNCE).await;
            false
        })
        .await
        {}
        let net = net.clone();
        match unblock(move || net.refresh()).await {
            Ok(changes) if changes.any() => {
                if let Err(err) = announce_network(&connection, &changes).await {
                    eprintln!("ruya-devices: emitting network signals failed: {err}");
                }
            }
            Ok(_) => {}
            Err(err) => eprintln!("ruya-devices: reading NetworkManager failed: {err}"),
        }
    }
}

async fn announce_network(connection: &Connection, changes: &network::Changes) -> zbus::Result<()> {
    let iface = connection
        .object_server()
        .interface::<_, NetworkIface>(OBJECT_PATH)
        .await?;
    let this = iface.get().await;
    this.emit(iface.signal_emitter(), changes).await;
    Ok(())
}
