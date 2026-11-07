//! org.ruyaos.Devices1.Audio, .Network, .Bluetooth, .Storage, .Batteries, .Thermal, .Time, .Display and .System on D-Bus. Thin adapter: the rules live in
//! `audio.rs`, `network.rs`, `bluetooth.rs`, `storage.rs`, `battery.rs` and `thermal.rs`.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use blocking::unblock;
#[cfg(target_os = "linux")]
use futures_lite::future;
use futures_lite::StreamExt;
use zbus::message::Header;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{Array, Dict, OwnedValue, Signature, Value};
use zbus::{fdo, interface, Connection, MatchRule, MessageStream};

use crate::audio::Audio;
#[cfg(target_os = "linux")]
use crate::audio::Changes;
use crate::battery::{Batteries, UPower};
use crate::bluetooth::{self, Bluetooth, Bluez, BtError};
use crate::debounce;
use crate::display::{Display, DynDrm, Mode, OutputView};
#[cfg(target_os = "linux")]
use crate::input::GamepadEvent;
use crate::input::InputPresence;
use crate::network::{self, Network, NetworkManager};
use crate::report;
use crate::storage::{self, Storage, Udisks};
use crate::sysinfo::SystemInfo;
use crate::sysusage::{MonotonicClock, Refresh, SystemSource, SystemUsage};
use crate::thermal::{self, Monitor, Source};
use crate::time::{self, ProfileState, Time, Timedate};

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
    bluetooth: SharedBluetooth,
}

impl BatteriesIface {
    /// `bluetooth` is the list a controller's family is taken from, so Batteries and
    /// `Bluetooth.ListDevices` agree (T-260).
    pub fn new(batteries: SharedBatteries, bluetooth: SharedBluetooth) -> Self {
        BatteriesIface {
            batteries,
            bluetooth,
        }
    }
}

#[interface(name = "org.ruyaos.Devices1.Batteries")]
impl BatteriesIface {
    fn list_batteries(&self) -> Vec<HashMap<String, OwnedValue>> {
        self.batteries
            .list_with(&self.bluetooth.list())
            .into_iter()
            .map(|b| {
                let own = |v: Value<'_>| OwnedValue::try_from(v).ok();
                [
                    ("id", own(Value::from(b.id.clone()))),
                    ("name", own(Value::from(b.name.clone()))),
                    ("kind", own(Value::from(b.kind))),
                    ("percent", own(Value::from(b.percent))),
                    ("state", own(Value::from(b.state.as_str()))),
                    ("family", own(Value::from(b.family))),
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
    fn set_discoverable(&self, on: bool) -> Result<(), BtError> {
        (**self).set_discoverable(on)
    }
    fn register_agent(&self) -> Result<(), BtError> {
        (**self).register_agent()
    }
    fn unregister_agent(&self) -> Result<(), BtError> {
        (**self).unregister_agent()
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
    fn set_alias(&self, address: &str, alias: &str) -> Result<(), BtError> {
        (**self).set_alias(address, alias)
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

/// Whether a keyboard or a gamepad is connected (`InputPresent`).
pub type SharedInput = Arc<InputPresence<crate::input::DynInputSource>>;

/// How often the kernel's input devices are looked at. `ruya-inputd` rescans at the same pace.
#[cfg(target_os = "linux")]
const INPUT_POLL: Duration = Duration::from_secs(2);

pub struct BluetoothIface {
    bt: SharedBluetooth,
    input: SharedInput,
}

/// Root and the user the service runs as may open the controller pairing window (the bus policy
/// lets no one else call at all; this is the service's own check). Fails closed.
async fn caller_may_pair(header: &Header<'_>, connection: &Connection) -> bool {
    let Some(sender) = header.sender() else {
        return false;
    };
    let Ok(bus) = fdo::DBusProxy::new(connection).await else {
        return false;
    };
    let caller = bus
        .get_connection_unix_user(sender.clone().into())
        .await
        .ok();
    let own = match connection.unique_name() {
        Some(name) => bus
            .get_connection_unix_user(name.inner().clone().into())
            .await
            .ok(),
        None => None,
    };
    crate::pairing::caller_allowed(caller, own)
}

impl BluetoothIface {
    pub fn new(bt: SharedBluetooth, input: SharedInput) -> Self {
        BluetoothIface { bt, input }
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
            if changes.pairing {
                self.controller_pairing_state_changed(emitter).await?;
            }
            if changes.rejected {
                Self::controller_pairing_rejected(emitter).await?;
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
                    ("family", own(Value::from(d.family))),
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

    async fn rename(
        &self,
        id: &str,
        name: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let (bt, id, name) = (self.bt.clone(), id.to_owned(), name.to_owned());
        let status = unblock(move || bt.rename(&id, &name)).await;
        self.settle(&emitter).await;
        status.as_str().to_owned()
    }

    #[zbus(signal)]
    async fn devices_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    /// A game controller appeared (T-260). See `Devices1.xml`.
    #[zbus(signal)]
    async fn gamepad_connected(
        emitter: &SignalEmitter<'_>,
        id: &str,
        name: &str,
        family: &str,
        transport: &str,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn gamepad_disconnected(
        emitter: &SignalEmitter<'_>,
        id: &str,
        name: &str,
        family: &str,
        transport: &str,
    ) -> zbus::Result<()>;

    #[zbus(property)]
    fn controller_pairing_state(&self) -> String {
        self.bt.pairing_state().as_str().to_owned()
    }

    #[zbus(property)]
    fn input_present(&self) -> bool {
        self.input.present()
    }

    async fn start_controller_pairing(
        &self,
        seconds: u32,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let allowed = caller_may_pair(&header, connection).await;
        let bt = self.bt.clone();
        let status =
            unblock(move || bt.start_controller_pairing(Instant::now(), seconds, allowed)).await;
        self.settle(&emitter).await;
        status.as_str().to_owned()
    }

    async fn stop_controller_pairing(
        &self,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let allowed = caller_may_pair(&header, connection).await;
        let bt = self.bt.clone();
        let status = unblock(move || bt.stop_controller_pairing(allowed)).await;
        self.settle(&emitter).await;
        status.as_str().to_owned()
    }

    #[zbus(signal)]
    async fn controller_pairing_rejected(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
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
    // Things that happen outside any call (the agent refuses a device, the window pairs a pad
    // by itself) are announced from here.
    {
        let (bt, connection) = (bt.clone(), connection.clone());
        bt.clone()
            .set_notifier(Arc::new(move || match bt.refresh() {
                Ok(changes) if changes.any() => {
                    if let Err(err) = future::block_on(announce_bluetooth(&connection, &changes)) {
                        eprintln!("ruya-devices: emitting Bluetooth signals failed: {err}");
                    }
                }
                Ok(_) => {}
                Err(err) => eprintln!("ruya-devices: reading BlueZ failed: {}", err.0),
            }));
    }
    loop {
        // A BlueZ signal, the end of the scan we started, or the end of the pairing window,
        // whichever comes first.
        let deadline = next_deadline(&bt);
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
                    next_deadline(&bt),
                )
                .await;
            }
            Wake::ScanOver => {}
            Wake::Closed => return,
        }
        // Ends the scan and the window if their time is up (a no-op otherwise), whatever woke us.
        let bt2 = bt.clone();
        unblock(move || bt2.tick(Instant::now())).await;
        let bt2 = bt.clone();
        // Read, then let the window look at what was read (a controller paired, a gamepad in
        // pairing mode); what that changed is announced with the rest.
        let read = unblock(move || {
            let changes = bt2.refresh();
            let next = bt2.pump();
            (changes.map(|c| c.merge(bt2.take_pending())), bt2, next)
        })
        .await;
        let (changes, bt2, next) = read;
        if let Some(address) = next {
            // Pairing takes seconds: not in this loop. It announces its result itself.
            unblock(move || {
                bt2.window_pair(&address, Instant::now);
                bt2.notify();
            })
            .detach();
        }
        match changes {
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

/// The earlier of the end of the scan we started and the end of the pairing window.
#[cfg(target_os = "linux")]
fn next_deadline(bt: &SharedBluetooth) -> Option<Instant> {
    [bt.scan_deadline(), bt.window_deadline()]
        .into_iter()
        .flatten()
        .min()
}

/// Looks at the kernel's input devices every `INPUT_POLL` and announces `InputPresent` when it
/// changed. Runs forever.
#[cfg(target_os = "linux")]
pub async fn watch_input(connection: Connection, input: SharedInput) {
    loop {
        async_io::Timer::after(INPUT_POLL).await;
        let input2 = input.clone();
        let (changed, pads) =
            unblock(move || (input2.refresh(), input2.take_gamepad_events())).await;
        if !changed && pads.is_empty() {
            continue;
        }
        let iface = match connection
            .object_server()
            .interface::<_, BluetoothIface>(OBJECT_PATH)
            .await
        {
            Ok(iface) => iface,
            Err(err) => {
                eprintln!("ruya-devices: the input changes cannot be announced: {err}");
                continue;
            }
        };
        let emitter = iface.signal_emitter();
        // One signal that fails to go out must not take the rest of this tick's pads with it.
        if changed {
            let this = iface.get().await;
            if let Err(err) = this.input_present_changed(emitter).await {
                eprintln!("ruya-devices: emitting InputPresent failed: {err}");
            }
        }
        for event in &pads {
            let sent = match event {
                GamepadEvent::Connected(p) => {
                    BluetoothIface::gamepad_connected(
                        emitter,
                        &p.id,
                        &p.name,
                        p.family,
                        p.transport,
                    )
                    .await
                }
                GamepadEvent::Disconnected(p) => {
                    BluetoothIface::gamepad_disconnected(
                        emitter,
                        &p.id,
                        &p.name,
                        p.family,
                        p.transport,
                    )
                    .await
                }
            };
            if let Err(err) = sent {
                eprintln!("ruya-devices: emitting a gamepad change failed: {err}");
            }
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

    /// Plain report files onto a mounted removable volume (`report.rs` checks and writes, on the
    /// blocking pool; the content is the caller's).
    #[zbus(out_args("status", "path"))]
    async fn save_report(&self, id: &str, files: BTreeMap<String, String>) -> (String, String) {
        let (storage, id) = (self.storage.clone(), id.to_owned());
        let (status, path) = unblock(move || report::save(&storage, &id, &files)).await;
        (status.as_str().to_owned(), path)
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

/// Chosen at runtime: sysfs on Linux, a fixed fake in `--session` development.
pub type DynThermal = Box<dyn Source>;

pub type SharedThermal = Arc<Monitor<DynThermal>>;

pub struct ThermalIface {
    monitor: SharedThermal,
}

impl ThermalIface {
    pub fn new(monitor: SharedThermal) -> Self {
        ThermalIface { monitor }
    }
}

#[interface(name = "org.ruyaos.Devices1.Thermal")]
impl ThermalIface {
    /// From the last reading: a short lock, no sysfs access, so it never holds up the executor.
    fn list_sensors(&self) -> Vec<BTreeMap<String, OwnedValue>> {
        self.monitor
            .list()
            .into_iter()
            .map(|s| {
                let own = |v: Value<'_>| OwnedValue::try_from(v).ok();
                [
                    ("id", own(Value::from(s.id.clone()))),
                    ("label", own(Value::from(s.label))),
                    ("class", own(Value::from(s.class.as_str()))),
                    ("value", own(Value::from(s.value))),
                    ("level", own(Value::from(s.level.as_str()))),
                    ("max_seen", own(Value::from(s.max_seen))),
                ]
                .into_iter()
                .filter_map(|(k, v)| v.map(|v| (k.to_owned(), v)))
                .collect()
            })
            .collect()
    }

    #[zbus(property)]
    fn level(&self) -> String {
        self.monitor.level().as_str().to_owned()
    }

    // Not `level_changed`: that is the generated name of the property's change notification.
    #[zbus(signal, name = "LevelChanged")]
    async fn level_change(
        emitter: &SignalEmitter<'_>,
        level: String,
        sensor_id: String,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn sensors_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

/// Reads the sensors on the blocking pool, now and then (every 5 s, every 1 s while the level is
/// above normal), and sends what changed: `SensorsChanged`, then `LevelChanged` and the `Level`
/// property. Runs forever.
pub async fn watch_thermal(connection: Connection, monitor: SharedThermal) {
    loop {
        let polling = monitor.clone();
        match unblock(move || polling.poll()).await {
            Ok(update) => {
                if let Err(err) = announce_thermal(&connection, &update).await {
                    eprintln!("ruya-devices: emitting thermal signals failed: {err}");
                }
            }
            Err(err) => eprintln!("ruya-devices: reading the sensors failed: {err}"),
        }
        async_io::Timer::after(monitor.interval()).await;
    }
}

async fn announce_thermal(connection: &Connection, update: &thermal::Update) -> zbus::Result<()> {
    if !update.sensors_changed && update.level.is_none() {
        return Ok(());
    }
    let iface = connection
        .object_server()
        .interface::<_, ThermalIface>(OBJECT_PATH)
        .await?;
    let emitter = iface.signal_emitter();
    if update.sensors_changed {
        ThermalIface::sensors_changed(emitter).await?;
    }
    if let Some(change) = &update.level {
        ThermalIface::level_change(
            emitter,
            change.level.as_str().to_owned(),
            change.sensor.clone(),
        )
        .await?;
        iface.get().await.level_changed(emitter).await?;
    }
    Ok(())
}

/// Chosen at runtime: systemd-timedated on Linux, a fake in `--session` development.
pub type DynTimedate = Box<dyn Timedate>;

pub type SharedTime = Arc<Time<DynTimedate>>;

pub struct TimeIface {
    time: SharedTime,
    /// Development (`--session`): every caller may set the zone, there is no Profiles1 to ask.
    everyone_admin: bool,
}

impl TimeIface {
    pub fn new(time: SharedTime, everyone_admin: bool) -> Self {
        TimeIface {
            time,
            everyone_admin,
        }
    }

    /// The caller rule (`time::caller_may_set`): root; the shell while the active profile is an
    /// admin, or while no profile exists (first-boot setup). Fails closed.
    async fn caller_may_set(&self, header: &Header<'_>, connection: &Connection) -> bool {
        if self.everyone_admin {
            return true;
        }
        let Some(sender) = header.sender() else {
            return false;
        };
        let Ok(bus) = fdo::DBusProxy::new(connection).await else {
            return false;
        };
        let caller = bus
            .get_connection_unix_user(sender.clone().into())
            .await
            .ok();
        let own = match connection.unique_name() {
            Some(name) => bus
                .get_connection_unix_user(name.inner().clone().into())
                .await
                .ok(),
            None => None,
        };
        // Profiles1 is only asked for a caller that needs it.
        let profiles = if caller.is_some() && caller == own {
            profile_state(connection).await
        } else {
            ProfileState::Unknown
        };
        time::caller_may_set(caller, own, profiles)
    }

    async fn emit(&self, emitter: &SignalEmitter<'_>, changes: &time::Changes) {
        let result = async {
            if changes.timezone {
                Self::timezone_changed(emitter).await?;
            }
            if changes.ntp {
                self.ntp_synchronised_changed(emitter).await?;
            }
            Ok::<(), zbus::Error>(())
        }
        .await;
        if let Err(err) = result {
            eprintln!("ruya-devices: emitting time signals failed: {err}");
        }
    }
}

/// What Profiles1 says about who is signed in (the same questions `ruya-update` asks).
async fn profile_state(connection: &Connection) -> ProfileState {
    let Ok(proxy) = zbus::Proxy::new(
        connection,
        "org.ruyaos.Profiles1",
        "/org/ruyaos/Profiles1",
        "org.ruyaos.Profiles1",
    )
    .await
    else {
        return ProfileState::Unknown;
    };
    let Ok(profiles) = proxy
        .call::<_, _, Vec<(String, String, String, String, bool)>>("ListProfiles", &())
        .await
    else {
        return ProfileState::Unknown;
    };
    if profiles.is_empty() {
        return ProfileState::NoProfiles;
    }
    let Ok(active) = proxy.get_property::<String>("ActiveProfile").await else {
        return ProfileState::Unknown;
    };
    if active.is_empty() {
        return ProfileState::NobodyActive;
    }
    ProfileState::Active {
        admin: profiles.iter().any(|p| p.0 == active && p.3 == "admin"),
    }
}

#[interface(name = "org.ruyaos.Devices1.Time")]
impl TimeIface {
    /// From the last read: no timedated call, so it never holds up the executor.
    fn get_timezone(&self) -> String {
        self.time.timezone()
    }

    async fn list_timezones(&self) -> Vec<String> {
        let time = self.time.clone();
        match unblock(move || time.list()).await {
            Ok(list) => list,
            Err(err) => {
                eprintln!("ruya-devices: reading the time zones failed: {err}");
                Vec::new()
            }
        }
    }

    async fn set_timezone(
        &self,
        name: &str,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let allowed = self.caller_may_set(&header, connection).await;
        let (time, name) = (self.time.clone(), name.to_owned());
        let (status, changes) = unblock(move || time.set(&name, allowed)).await;
        self.emit(&emitter, &changes).await;
        status.as_str().to_owned()
    }

    #[zbus(property)]
    fn ntp_synchronised(&self) -> bool {
        self.time.ntp_synchronised()
    }

    #[zbus(signal)]
    async fn timezone_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

/// Follows timedated's `PropertiesChanged` (a zone set by anyone, NTP found or lost), and
/// timedated itself appearing, and after a quiet moment reads it again and announces what changed.
/// No polling. Runs forever.
#[cfg(target_os = "linux")]
pub async fn watch_time(connection: Connection, time: SharedTime) {
    use crate::timedate::TIMEDATE;

    let signals = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender(TIMEDATE)
        .map(|b| b.build());
    let owner = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender("org.freedesktop.DBus")
        .and_then(|b| b.member("NameOwnerChanged"))
        .and_then(|b| b.arg(0, TIMEDATE))
        .map(|b| b.build());
    let (Ok(signals), Ok(owner)) = (signals, owner) else {
        return eprintln!("ruya-devices: cannot follow timedated");
    };
    let (signals, owner) = match (
        MessageStream::for_match_rule(signals, &connection, None).await,
        MessageStream::for_match_rule(owner, &connection, None).await,
    ) {
        (Ok(a), Ok(b)) => (a, b),
        (Err(err), _) | (_, Err(err)) => {
            return eprintln!("ruya-devices: cannot follow timedated: {err}");
        }
    };
    let mut stream = futures_lite::stream::or(signals, owner);
    while stream.next().await.is_some() {
        debounce::settle(&mut stream, debounce::QUIET, debounce::MAX_WAIT, None).await;
        let refreshing = time.clone();
        match unblock(move || refreshing.refresh()).await {
            Ok(changes) => announce_time(&connection, &changes).await,
            Err(err) => eprintln!("ruya-devices: reading timedated failed: {err}"),
        }
    }
}

#[cfg(target_os = "linux")]
async fn announce_time(connection: &Connection, changes: &time::Changes) {
    let Ok(iface) = connection
        .object_server()
        .interface::<_, TimeIface>(OBJECT_PATH)
        .await
    else {
        return;
    };
    iface
        .get()
        .await
        .emit(iface.signal_emitter(), changes)
        .await;
}

pub type SharedDisplay = Arc<Display<DynDrm>>;

pub struct DisplayIface {
    display: SharedDisplay,
}

impl DisplayIface {
    pub fn new(display: SharedDisplay) -> Self {
        DisplayIface { display }
    }
}

fn dict(pairs: Vec<(&str, Value<'static>)>) -> BTreeMap<String, OwnedValue> {
    pairs
        .into_iter()
        .filter_map(|(k, v)| OwnedValue::try_from(v).ok().map(|v| (k.to_owned(), v)))
        .collect()
}

/// `modes` of one output as `aa{sv}`.
fn mode_rows(modes: &[Mode], current: Option<usize>) -> Option<Value<'static>> {
    let row_type = Signature::dict(Signature::Str, Signature::Variant);
    let mut array = Array::new(&row_type);
    for (i, m) in modes.iter().enumerate() {
        let mut row = Dict::new(&Signature::Str, &Signature::Variant);
        let fields: [(&str, Value<'static>); 5] = [
            ("width", Value::from(m.width)),
            ("height", Value::from(m.height)),
            ("refresh_mhz", Value::from(m.refresh_mhz)),
            ("preferred", Value::from(m.preferred)),
            ("current", Value::from(current == Some(i))),
        ];
        for (k, v) in fields {
            row.append(Value::from(k), Value::Value(Box::new(v))).ok()?;
        }
        array.append(Value::Dict(row)).ok()?;
    }
    Some(Value::Array(array))
}

fn output_row(view: &OutputView) -> BTreeMap<String, OwnedValue> {
    let o = &view.output;
    let mut pairs = vec![
        ("id", Value::from(o.id.clone())),
        ("name", Value::from(o.name.clone())),
        ("width_mm", Value::from(o.width_mm)),
        ("height_mm", Value::from(o.height_mm)),
    ];
    if let Some(modes) = mode_rows(&o.modes, view.current) {
        pairs.push(("modes", modes));
    }
    dict(pairs)
}

#[interface(name = "org.ruyaos.Devices1.Display")]
impl DisplayIface {
    /// Reads the kernel's files now, off the executor.
    async fn list_outputs(&self) -> Vec<BTreeMap<String, OwnedValue>> {
        let display = self.display.clone();
        match unblock(move || display.list()).await {
            Ok(views) => views.iter().map(output_row).collect(),
            Err(err) => {
                eprintln!("ruya-devices: reading the outputs failed: {err}");
                Vec::new()
            }
        }
    }

    async fn set_mode(&self, output: &str, width: u32, height: u32, refresh_mhz: u32) -> String {
        let (display, output) = (self.display.clone(), output.to_owned());
        unblock(move || display.set_mode(&output, width, height, refresh_mhz))
            .await
            .as_str()
            .to_owned()
    }

    async fn get_pending(&self) -> BTreeMap<String, OwnedValue> {
        let display = self.display.clone();
        match unblock(move || display.pending()).await {
            Some(p) => dict(vec![
                ("output", Value::from(p.choice.output)),
                ("width", Value::from(p.choice.width)),
                ("height", Value::from(p.choice.height)),
                ("refresh_mhz", Value::from(p.choice.refresh_mhz)),
                ("starts", Value::from(p.starts)),
            ]),
            None => BTreeMap::new(),
        }
    }

    async fn keep(&self) -> String {
        let display = self.display.clone();
        unblock(move || display.keep()).await.as_str().to_owned()
    }

    async fn revert(&self) -> String {
        let display = self.display.clone();
        unblock(move || display.revert()).await.as_str().to_owned()
    }

    async fn take_fallback_notice(&self) -> bool {
        let display = self.display.clone();
        unblock(move || display.take_fallback()).await
    }

    async fn set_ui_scale(
        &self,
        percent: u32,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let display = self.display.clone();
        let (status, changed) = unblock(move || display.set_ui_scale(percent)).await;
        if changed {
            if let Err(err) = self.ui_scale_changed(&emitter).await {
                eprintln!("ruya-devices: emitting UiScale failed: {err}");
            }
        }
        status.as_str().to_owned()
    }

    /// Back to the defaults: the preferred mode (capped at 4K60) and UI size Auto.
    async fn reset(&self, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) -> String {
        let display = self.display.clone();
        let (status, ui_changed) = unblock(move || display.reset()).await;
        if ui_changed {
            if let Err(err) = self.ui_scale_changed(&emitter).await {
                eprintln!("ruya-devices: emitting UiScale failed: {err}");
            }
        }
        status.as_str().to_owned()
    }

    #[zbus(property)]
    fn ui_scale(&self) -> u32 {
        // A small file read; the service's own state, never the kernel's.
        self.display.ui_scale()
    }
}

pub type SharedSystem = Arc<SystemInfo>;

pub struct SystemIface {
    system: SharedSystem,
}

impl SystemIface {
    pub fn new(system: SharedSystem) -> Self {
        SystemIface { system }
    }
}

/// One value of the collector as D-Bus knows it: text `s`, numbers `t`, flags `b`, a table `aa{sv}`.
fn system_value(value: &ruya_sysinfo::Value) -> Option<Value<'static>> {
    match value {
        ruya_sysinfo::Value::Text(t) => Some(Value::from(t.clone())),
        ruya_sysinfo::Value::Unsigned(n) => Some(Value::from(*n)),
        ruya_sysinfo::Value::Bool(b) => Some(Value::from(*b)),
        ruya_sysinfo::Value::Table(rows) => {
            let row_type = Signature::dict(Signature::Str, Signature::Variant);
            let mut array = Array::new(&row_type);
            for row in rows {
                let mut dict = Dict::new(&Signature::Str, &Signature::Variant);
                for (k, v) in row.iter() {
                    let inner = system_value(v)?;
                    dict.append(Value::from(k.clone()), Value::Value(Box::new(inner)))
                        .ok()?;
                }
                array.append(Value::Dict(dict)).ok()?;
            }
            Some(Value::Array(array))
        }
    }
}

/// A value that cannot be converted is left out, like one that cannot be read.
pub fn system_dict(info: &ruya_sysinfo::Info) -> BTreeMap<String, OwnedValue> {
    info.iter()
        .filter_map(|(k, v)| {
            let value = system_value(v)?;
            OwnedValue::try_from(value).ok().map(|v| (k.clone(), v))
        })
        .collect()
}

#[interface(name = "org.ruyaos.Devices1.System")]
impl SystemIface {
    /// The live keys are read now; the rest comes from the cache. The reading happens on the
    /// blocking pool, and a cache older than 30 s is renewed in the background
    /// (`SystemInfoChanged` when it differs).
    async fn get_info(
        &self,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> BTreeMap<String, OwnedValue> {
        let system = self.system.clone();
        let info = unblock(move || system.current(Instant::now())).await;
        if self.system.is_stale(Instant::now()) {
            emitter
                .connection()
                .executor()
                .spawn(
                    refresh_system(emitter.connection().clone(), self.system.clone()),
                    "ruya-devices system info",
                )
                .detach();
        }
        system_dict(&info)
    }

    #[zbus(signal)]
    async fn system_info_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

/// Reads the slow part of the system information again on the blocking pool and sends
/// `SystemInfoChanged` when it differs.
pub async fn refresh_system(connection: Connection, system: SharedSystem) {
    let reading = system.clone();
    if unblock(move || reading.refresh_if_stale(Instant::now())).await != Some(true) {
        return;
    }
    match connection
        .object_server()
        .interface::<_, SystemIface>(OBJECT_PATH)
        .await
    {
        Ok(iface) => {
            if let Err(err) = SystemIface::system_info_changed(iface.signal_emitter()).await {
                eprintln!("ruya-devices: emitting SystemInfoChanged failed: {err}");
            }
        }
        Err(err) => eprintln!("ruya-devices: emitting SystemInfoChanged failed: {err}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ruya_sysinfo::{collect, FakeSource};

    #[test]
    fn the_collector_result_has_the_contracts_types() {
        let dict = system_dict(&collect(&FakeSource::from_dump(
            ruya_sysinfo::SAMPLE_MACHINE,
        )));
        let signature = |key: &str| dict.get(key).map(|v| v.value_signature().to_string());
        assert_eq!(signature("cpu.model").as_deref(), Some("s"));
        assert_eq!(signature("cpu.threads").as_deref(), Some("t"));
        assert_eq!(signature("memory.total_bytes").as_deref(), Some("t"));
        assert_eq!(signature("console.secure_boot").as_deref(), Some("b"));
        assert_eq!(signature("storage.drives").as_deref(), Some("aa{sv}"));
    }

    #[test]
    fn a_display_output_has_the_contracts_types() {
        use crate::display::Output;
        let view = OutputView {
            output: Output {
                id: "HDMI-A-1".to_owned(),
                name: "TV".to_owned(),
                width_mm: 1220,
                height_mm: 690,
                modes: vec![Mode {
                    width: 1920,
                    height: 1080,
                    refresh_mhz: 60_000,
                    preferred: true,
                }],
            },
            current: Some(0),
        };
        let row = output_row(&view);
        let signature = |key: &str| row.get(key).map(|v| v.value_signature().to_string());
        assert_eq!(signature("id").as_deref(), Some("s"));
        assert_eq!(signature("name").as_deref(), Some("s"));
        assert_eq!(signature("width_mm").as_deref(), Some("u"));
        assert_eq!(signature("height_mm").as_deref(), Some("u"));
        assert_eq!(signature("modes").as_deref(), Some("aa{sv}"));
    }

    #[test]
    fn what_cannot_be_read_is_not_in_the_dictionary() {
        let dict = system_dict(&collect(&FakeSource::new()));
        assert!(dict.is_empty());
    }
}
