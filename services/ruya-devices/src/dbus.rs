//! org.ruyaos.Devices1.Audio, .Network, .Bluetooth, .Storage and .Batteries on D-Bus. Thin adapter: the rules live in
//! `audio.rs`, `network.rs`, `bluetooth.rs`, `storage.rs` and `battery.rs`.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use blocking::unblock;
#[cfg(target_os = "linux")]
use futures_lite::future;
use futures_lite::StreamExt;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedValue, Value};
use zbus::{interface, Connection, MatchRule, MessageStream};

use crate::audio::Audio;
#[cfg(target_os = "linux")]
use crate::audio::Changes;
use crate::battery::{Batteries, UPower};
use crate::bluetooth::{self, Bluetooth, Bluez, BtError};
use crate::debounce;
use crate::network::{self, Network, NetworkManager};
use crate::storage::{self, Storage, Udisks};
use crate::sysusage::{MonotonicClock, Refresh, SystemSource, SystemUsage};

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
        std::time::Instant::now,
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
        debounce::settle(&mut stream, debounce::QUIET, debounce::MAX_WAIT, None).await;
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

/// Chosen at runtime: UPower on Linux, a fake in `--session` development.
pub type DynUPower = Box<dyn UPower>;

impl UPower for DynUPower {
    fn devices(&self) -> Result<Vec<crate::battery::RawDevice>, String> {
        (**self).devices()
    }
}

pub type SharedBatteries = Arc<Batteries<DynUPower>>;

pub struct BatteriesIface {
    batteries: SharedBatteries,
}

impl BatteriesIface {
    pub fn new(batteries: SharedBatteries) -> Self {
        BatteriesIface { batteries }
    }
}

#[interface(name = "org.ruyaos.Devices1.Batteries")]
impl BatteriesIface {
    fn list_batteries(&self) -> Vec<HashMap<String, OwnedValue>> {
        self.batteries
            .list()
            .into_iter()
            .map(|b| {
                let own = |v: Value<'_>| OwnedValue::try_from(v).ok();
                [
                    ("id", own(Value::from(b.id.clone()))),
                    ("name", own(Value::from(b.name.clone()))),
                    ("percent", own(Value::from(b.percent))),
                    ("state", own(Value::from(b.state.as_str()))),
                ]
                .into_iter()
                .filter_map(|(k, v)| v.map(|v| (k.to_owned(), v)))
                .collect()
            })
            .collect()
    }

    #[zbus(signal)]
    async fn batteries_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

/// Follows UPower's signals (devices added or removed, any device's properties) and UPower
/// itself appearing or leaving, and after a quiet moment reads the list again and announces a
/// change. No polling. Runs forever.
#[cfg(target_os = "linux")]
pub async fn watch_batteries(connection: Connection, batteries: SharedBatteries) {
    use crate::upower::UPOWER;

    let signals = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender(UPOWER)
        .map(|b| b.build());
    let owner = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender("org.freedesktop.DBus")
        .and_then(|b| b.member("NameOwnerChanged"))
        .and_then(|b| b.arg(0, UPOWER))
        .map(|b| b.build());
    let (Ok(signals), Ok(owner)) = (signals, owner) else {
        return eprintln!("ruya-devices: cannot follow UPower");
    };
    let (signals, owner) = match (
        MessageStream::for_match_rule(signals, &connection, None).await,
        MessageStream::for_match_rule(owner, &connection, None).await,
    ) {
        (Ok(a), Ok(b)) => (a, b),
        (Err(err), _) | (_, Err(err)) => {
            return eprintln!("ruya-devices: cannot follow UPower: {err}");
        }
    };
    let mut stream = futures_lite::stream::or(signals, owner);
    while stream.next().await.is_some() {
        debounce::settle(&mut stream, debounce::QUIET, debounce::MAX_WAIT, None).await;
        let batteries = batteries.clone();
        match unblock(move || batteries.refresh()).await {
            Ok(true) => {
                if let Err(err) = announce_batteries(&connection).await {
                    eprintln!("ruya-devices: emitting battery signals failed: {err}");
                }
            }
            Ok(false) => {}
            Err(err) => eprintln!("ruya-devices: reading UPower failed: {err}"),
        }
    }
}

#[cfg(target_os = "linux")]
async fn announce_batteries(connection: &Connection) -> zbus::Result<()> {
    let iface = connection
        .object_server()
        .interface::<_, BatteriesIface>(OBJECT_PATH)
        .await?;
    BatteriesIface::batteries_changed(iface.signal_emitter()).await
}

/// Chosen at runtime: BlueZ on Linux, a fake in `--session` development.
pub type DynBluez = Box<dyn Bluez>;

impl Bluez for DynBluez {
    fn snapshot(&self) -> Result<crate::bluetooth::Raw, BtError> {
        (**self).snapshot()
    }
    fn set_powered(&self, on: bool) -> Result<(), BtError> {
        (**self).set_powered(on)
    }
    fn set_pairable(&self, on: bool) -> Result<(), BtError> {
        (**self).set_pairable(on)
    }
    fn start_discovery(&self) -> Result<(), BtError> {
        (**self).start_discovery()
    }
    fn stop_discovery(&self) -> Result<(), BtError> {
        (**self).stop_discovery()
    }
    fn pair(&self, address: &str, timeout: Duration) -> Result<(), BtError> {
        (**self).pair(address, timeout)
    }
    fn set_trusted(&self, address: &str) -> Result<(), BtError> {
        (**self).set_trusted(address)
    }
    fn connect(&self, address: &str, timeout: Duration) -> Result<(), BtError> {
        (**self).connect(address, timeout)
    }
    fn disconnect(&self, address: &str) -> Result<(), BtError> {
        (**self).disconnect(address)
    }
    fn remove(&self, address: &str) -> Result<(), BtError> {
        (**self).remove(address)
    }
}

pub type SharedBluetooth = Arc<Bluetooth<DynBluez>>;

pub struct BluetoothIface {
    bt: SharedBluetooth,
}

impl BluetoothIface {
    pub fn new(bt: SharedBluetooth) -> Self {
        BluetoothIface { bt }
    }

    async fn emit(&self, emitter: &SignalEmitter<'_>, changes: &bluetooth::Changes) {
        let result = async {
            if changes.powered {
                self.powered_changed(emitter).await?;
            }
            if changes.discovering {
                self.discovering_changed(emitter).await?;
            }
            if changes.devices {
                Self::devices_changed(emitter).await?;
            }
            Ok::<(), zbus::Error>(())
        }
        .await;
        if let Err(err) = result {
            eprintln!("ruya-devices: emitting Bluetooth signals failed: {err}");
        }
    }

    /// Reads BlueZ again (off the executor: it blocks) and announces what changed.
    async fn settle(&self, emitter: &SignalEmitter<'_>) {
        let bt = self.bt.clone();
        match unblock(move || bt.refresh()).await {
            Ok(changes) => self.emit(emitter, &changes).await,
            Err(err) => eprintln!("ruya-devices: reading BlueZ failed: {}", err.0),
        }
    }
}

#[interface(name = "org.ruyaos.Devices1.Bluetooth")]
impl BluetoothIface {
    #[zbus(property)]
    fn powered(&self) -> bool {
        self.bt.powered()
    }

    #[zbus(property)]
    async fn set_powered(
        &mut self,
        on: bool,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        let bt = self.bt.clone();
        match unblock(move || bt.set_powered(on)).await {
            Ok(changes) => {
                // `Powered` itself is announced by zbus after a successful Set.
                let rest = bluetooth::Changes {
                    powered: false,
                    ..changes
                };
                self.emit(&emitter, &rest).await;
                Ok(())
            }
            Err(err) => Err(zbus::fdo::Error::Failed(err.0)),
        }
    }

    #[zbus(property)]
    fn discovering(&self) -> bool {
        self.bt.discovering()
    }

    fn list_devices(&self) -> Vec<HashMap<String, OwnedValue>> {
        self.bt
            .list()
            .into_iter()
            .map(|d| {
                let own = |v: Value<'_>| OwnedValue::try_from(v).ok();
                [
                    ("id", own(Value::from(d.id.clone()))),
                    ("name", own(Value::from(d.name.clone()))),
                    ("kind", own(Value::from(d.kind))),
                    ("paired", own(Value::from(d.paired))),
                    ("connected", own(Value::from(d.connected))),
                    ("trusted", own(Value::from(d.trusted))),
                    ("battery", own(Value::from(d.battery))),
                ]
                .into_iter()
                .filter_map(|(k, v)| v.map(|v| (k.to_owned(), v)))
                .collect()
            })
            .collect()
    }

    async fn start_scan(&self, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) -> String {
        let bt = self.bt.clone();
        let status = unblock(move || bt.start_scan(Instant::now())).await;
        self.settle(&emitter).await;
        status.as_str().to_owned()
    }

    async fn stop_scan(&self, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) -> String {
        let bt = self.bt.clone();
        let status = unblock(move || bt.stop_scan()).await;
        self.settle(&emitter).await;
        status.as_str().to_owned()
    }

    async fn pair(&self, id: &str, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) -> String {
        let (bt, id) = (self.bt.clone(), id.to_owned());
        let status = unblock(move || bt.pair(&id, Instant::now)).await;
        self.settle(&emitter).await;
        status.as_str().to_owned()
    }

    async fn forget(&self, id: &str, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) -> String {
        let (bt, id) = (self.bt.clone(), id.to_owned());
        let status = unblock(move || bt.forget(&id)).await;
        self.settle(&emitter).await;
        status.as_str().to_owned()
    }

    async fn connect(
        &self,
        id: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let (bt, id) = (self.bt.clone(), id.to_owned());
        let status = unblock(move || bt.connect(&id)).await;
        self.settle(&emitter).await;
        status.as_str().to_owned()
    }

    async fn disconnect(
        &self,
        id: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let (bt, id) = (self.bt.clone(), id.to_owned());
        let status = unblock(move || bt.disconnect(&id)).await;
        self.settle(&emitter).await;
        status.as_str().to_owned()
    }

    #[zbus(signal)]
    async fn devices_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

#[cfg(target_os = "linux")]
enum Wake {
    Signal,
    ScanOver,
    Closed,
}

/// Follows BlueZ's signals (devices and adapters added or removed, any property) and BlueZ
/// itself appearing or leaving, and after a quiet moment reads it again and announces what
/// changed. Also ends the scan when its 30 s are up. No polling. Runs forever.
#[cfg(target_os = "linux")]
pub async fn watch_bluetooth(connection: Connection, bt: SharedBluetooth) {
    use crate::bluez::BLUEZ;

    let signals = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender(BLUEZ)
        .map(|b| b.build());
    let owner = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender("org.freedesktop.DBus")
        .and_then(|b| b.member("NameOwnerChanged"))
        .and_then(|b| b.arg(0, BLUEZ))
        .map(|b| b.build());
    let (Ok(signals), Ok(owner)) = (signals, owner) else {
        return eprintln!("ruya-devices: cannot follow BlueZ");
    };
    let (signals, owner) = match (
        MessageStream::for_match_rule(signals, &connection, None).await,
        MessageStream::for_match_rule(owner, &connection, None).await,
    ) {
        (Ok(a), Ok(b)) => (a, b),
        (Err(err), _) | (_, Err(err)) => {
            return eprintln!("ruya-devices: cannot follow BlueZ: {err}");
        }
    };
    let mut stream = futures_lite::stream::or(signals, owner);
    loop {
        // Either a BlueZ signal or the end of the scan we started, whichever comes first.
        let deadline = bt.scan_deadline();
        let event = future::or(
            async {
                if stream.next().await.is_some() {
                    Wake::Signal
                } else {
                    Wake::Closed
                }
            },
            async {
                match deadline {
                    Some(at) => {
                        async_io::Timer::at(at).await;
                        Wake::ScanOver
                    }
                    None => future::pending().await,
                }
            },
        )
        .await;
        match event {
            Wake::Signal => {
                // Wait for a quiet moment, but never longer than MAX_WAIT (a scan sends a
                // signal per device every second or so) and never past the scan's deadline.
                debounce::settle(
                    &mut stream,
                    debounce::QUIET,
                    debounce::MAX_WAIT,
                    bt.scan_deadline(),
                )
                .await;
            }
            Wake::ScanOver => {}
            Wake::Closed => return,
        }
        // Ends the scan if its time is up (a no-op otherwise), whatever woke us.
        let bt2 = bt.clone();
        unblock(move || bt2.tick(Instant::now())).await;
        let bt2 = bt.clone();
        match unblock(move || bt2.refresh()).await {
            Ok(changes) if changes.any() => {
                if let Err(err) = announce_bluetooth(&connection, &changes).await {
                    eprintln!("ruya-devices: emitting Bluetooth signals failed: {err}");
                }
            }
            Ok(_) => {}
            Err(err) => eprintln!("ruya-devices: reading BlueZ failed: {}", err.0),
        }
    }
}

#[cfg(target_os = "linux")]
async fn announce_bluetooth(
    connection: &Connection,
    changes: &bluetooth::Changes,
) -> zbus::Result<()> {
    let iface = connection
        .object_server()
        .interface::<_, BluetoothIface>(OBJECT_PATH)
        .await?;
    let this = iface.get().await;
    this.emit(iface.signal_emitter(), changes).await;
    Ok(())
}

/// Chosen at runtime: udisks2 on Linux, a fake in `--session` development.
pub type DynUdisks = Box<dyn Udisks>;

impl Udisks for DynUdisks {
    fn volumes(&self) -> Result<Vec<crate::storage::RawVolume>, String> {
        (**self).volumes()
    }
    fn mount(&self, id: &str, options: &str) -> Result<(), String> {
        (**self).mount(id, options)
    }
    fn unmount(&self, id: &str) -> Result<(), crate::storage::UnmountError> {
        (**self).unmount(id)
    }
    fn power_off(&self, id: &str) -> Result<(), String> {
        (**self).power_off(id)
    }
}

pub type SharedStorage = Arc<Storage<DynUdisks>>;

/// Chosen at runtime: statvfs and directory walks on Linux, a scripted fake in `--session`.
pub type DynSource = Box<dyn SystemSource>;

pub type SharedUsage = Arc<SystemUsage<DynSource, MonotonicClock>>;

pub struct StorageIface {
    storage: SharedStorage,
    usage: SharedUsage,
}

impl StorageIface {
    pub fn new(storage: SharedStorage, usage: SharedUsage) -> Self {
        StorageIface { storage, usage }
    }

    /// `VolumeAdded` first, then `VolumesChanged` (the contract's order).
    async fn emit(emitter: &SignalEmitter<'_>, changes: &storage::Changes) {
        for id in &changes.added {
            if let Err(err) = Self::volume_added(emitter, id.clone()).await {
                eprintln!("ruya-devices: emitting VolumeAdded failed: {err}");
            }
        }
        if changes.changed {
            if let Err(err) = Self::volumes_changed(emitter).await {
                eprintln!("ruya-devices: emitting VolumesChanged failed: {err}");
            }
        }
    }
}

#[interface(name = "org.ruyaos.Devices1.Storage")]
impl StorageIface {
    fn list_volumes(&self) -> Vec<BTreeMap<String, OwnedValue>> {
        self.storage
            .list()
            .into_iter()
            .map(|v| {
                let own = |v: Value<'_>| OwnedValue::try_from(v).ok();
                [
                    ("id", own(Value::from(v.id.clone()))),
                    ("drive", own(Value::from(v.drive.clone()))),
                    ("label", own(Value::from(v.label.clone()))),
                    ("filesystem", own(Value::from(v.filesystem))),
                    ("size_bytes", own(Value::from(v.size_bytes))),
                    ("free_bytes", own(Value::from(v.free_bytes))),
                    ("removable", own(Value::from(v.removable))),
                    ("mounted", own(Value::from(v.mounted))),
                    ("mount_point", own(Value::from(v.mount_point.clone()))),
                    ("read_only", own(Value::from(v.read_only))),
                ]
                .into_iter()
                .filter_map(|(k, v)| v.map(|v| (k.to_owned(), v)))
                .collect()
            })
            .collect()
    }

    /// Total and free are read on every call (one syscall, still off the executor); apps and
    /// profile data are the cached directory sizes, unknown (-1) until the first walk finishes.
    /// When the cache is stale the call answers with what it has and starts the walk, which ends
    /// in `SystemUsageChanged`; the walk never runs on the executor.
    async fn get_system_usage(
        &self,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> BTreeMap<String, OwnedValue> {
        let usage = self.usage.clone();
        let now = unblock(move || usage.current()).await;
        if self.usage.needs_refresh() {
            let connection = emitter.connection().clone();
            let usage = self.usage.clone();
            emitter
                .connection()
                .executor()
                .spawn(
                    refresh_usage(connection, usage),
                    "ruya-devices system usage",
                )
                .detach();
        }
        [
            ("total_bytes", now.total_bytes),
            ("free_bytes", now.free_bytes),
            ("apps_bytes", now.apps_bytes),
            ("data_bytes", now.data_bytes),
            ("system_bytes", now.system_bytes),
        ]
        .into_iter()
        .filter_map(|(k, v)| {
            OwnedValue::try_from(Value::from(v))
                .ok()
                .map(|v| (k.to_owned(), v))
        })
        .collect()
    }

    async fn eject(&self, id: &str, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) -> String {
        let (storage, id) = (self.storage.clone(), id.to_owned());
        let status = unblock(move || storage.eject(&id)).await;
        // Do not wait for udisks' signals: the volume should leave the list as the call returns.
        let storage = self.storage.clone();
        match unblock(move || storage.refresh()).await {
            Ok(changes) => Self::emit(&emitter, &changes).await,
            Err(err) => eprintln!("ruya-devices: reading udisks2 failed: {err}"),
        }
        status.as_str().to_owned()
    }

    #[zbus(signal)]
    async fn volumes_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn volume_added(emitter: &SignalEmitter<'_>, id: String) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn system_usage_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

/// Recomputes the directory sizes on the blocking pool if they are stale and sends
/// `SystemUsageChanged` when they differ. A change signal that came in during a walk leaves the
/// result stale, so it goes round again (a few times at most).
pub async fn refresh_usage(connection: Connection, usage: SharedUsage) {
    for _ in 0..3 {
        let walking = usage.clone();
        let result = unblock(move || walking.refresh()).await;
        if result == Refresh::Changed {
            match connection
                .object_server()
                .interface::<_, StorageIface>(OBJECT_PATH)
                .await
            {
                Ok(iface) => {
                    if let Err(err) =
                        StorageIface::system_usage_changed(iface.signal_emitter()).await
                    {
                        eprintln!("ruya-devices: emitting SystemUsageChanged failed: {err}");
                    }
                }
                Err(err) => eprintln!("ruya-devices: emitting SystemUsageChanged failed: {err}"),
            }
        }
        if result == Refresh::Skipped || !usage.needs_refresh() {
            return;
        }
    }
}

/// The Store sends `InstalledChanged` after an install, update or uninstall: the app sizes are
/// stale. Measures once at start so the first reader finds numbers, then follows the Store's
/// signal (no polling). Runs forever.
#[cfg(target_os = "linux")]
pub async fn watch_installed(connection: Connection, usage: SharedUsage) {
    let rule = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender("org.ruyaos.Store1")
        .and_then(|b| b.member("InstalledChanged"))
        .map(|b| b.build());
    let Ok(rule) = rule else {
        return eprintln!("ruya-devices: cannot follow the Store");
    };
    let mut stream = match MessageStream::for_match_rule(rule, &connection, None).await {
        Ok(stream) => stream,
        Err(err) => return eprintln!("ruya-devices: cannot follow the Store: {err}"),
    };
    refresh_usage(connection.clone(), usage.clone()).await;
    while stream.next().await.is_some() {
        debounce::settle(&mut stream, debounce::QUIET, debounce::MAX_WAIT, None).await;
        usage.invalidate();
        refresh_usage(connection.clone(), usage.clone()).await;
    }
}

/// Follows udisks2's signals (objects added or removed, properties changed) and udisks2 itself
/// appearing or leaving, and after a quiet moment reads the list again (mounting new removable
/// volumes) and announces what changed. No polling. Runs forever.
#[cfg(target_os = "linux")]
pub async fn watch_storage(connection: Connection, storage: SharedStorage) {
    use crate::udisks::UDISKS;

    let signals = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender(UDISKS)
        .map(|b| b.build());
    let owner = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender("org.freedesktop.DBus")
        .and_then(|b| b.member("NameOwnerChanged"))
        .and_then(|b| b.arg(0, UDISKS))
        .map(|b| b.build());
    let (Ok(signals), Ok(owner)) = (signals, owner) else {
        return eprintln!("ruya-devices: cannot follow udisks2");
    };
    let (signals, owner) = match (
        MessageStream::for_match_rule(signals, &connection, None).await,
        MessageStream::for_match_rule(owner, &connection, None).await,
    ) {
        (Ok(a), Ok(b)) => (a, b),
        (Err(err), _) | (_, Err(err)) => {
            return eprintln!("ruya-devices: cannot follow udisks2: {err}");
        }
    };
    let mut stream = futures_lite::stream::or(signals, owner);
    while stream.next().await.is_some() {
        debounce::settle(&mut stream, debounce::QUIET, debounce::MAX_WAIT, None).await;
        let storage = storage.clone();
        match unblock(move || storage.refresh()).await {
            Ok(changes) if changes.any() => {
                if let Err(err) = announce_storage(&connection, &changes).await {
                    eprintln!("ruya-devices: emitting storage signals failed: {err}");
                }
            }
            Ok(_) => {}
            Err(err) => eprintln!("ruya-devices: reading udisks2 failed: {err}"),
        }
    }
}

#[cfg(target_os = "linux")]
async fn announce_storage(connection: &Connection, changes: &storage::Changes) -> zbus::Result<()> {
    let iface = connection
        .object_server()
        .interface::<_, StorageIface>(OBJECT_PATH)
        .await?;
    StorageIface::emit(iface.signal_emitter(), changes).await;
    Ok(())
}
