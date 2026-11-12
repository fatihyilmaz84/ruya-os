//! The Bluetooth rules of spec 03 §2.1 (org.ruyaos.Devices1.Bluetooth, T-173): the device list
//! (paired first), the scan that ends by itself after 30 s, power-off clearing the list, the
//! mapping of BlueZ's errors to the contract's statuses, and a device's battery. No I/O except
//! through the `Bluez` trait; `bluez.rs` is the system-bus side. Time is passed in.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::families::family_of_device;
use crate::idle_pads::{IdlePads, IdleReport, Pad};
use crate::log::{self, clean};
use crate::pairing::{
    address_of_path, is_format_char, is_hid_service, is_input_device, PairingState, DEFAULT_WINDOW,
    MAX_ATTEMPTS, MAX_WINDOW,
};

/// A scan ends by itself after this long (the contract's `Discovering` text).
pub const SCAN_LIMIT: Duration = Duration::from_secs(30);

/// `Pair` and `Connect` answer `timeout` after this long. The D-Bus default call timeout is
/// 25 s and the shell's client uses it, so the service has to answer first.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(20);

/// The longest name `Rename` takes, in characters (the contract's 48).
pub const MAX_NAME_CHARS: usize = 48;

/// The error name the `Bluez` side reports when it gave up waiting for the device.
pub const LOCAL_TIMEOUT: &str = "org.ruyaos.Error.Timeout";

/// Status strings of the contract (stable API).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    UnknownDevice,
    PairingFailed,
    Timeout,
    Unavailable,
    Invalid,
    Busy,
    Refused,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::UnknownDevice => "unknown-device",
            Status::PairingFailed => "pairing-failed",
            Status::Timeout => "timeout",
            Status::Unavailable => "unavailable",
            Status::Invalid => "invalid",
            Status::Busy => "busy",
            Status::Refused => "refused",
            Status::Failed => "failed",
        }
    }
}

/// A D-Bus error name from BlueZ (or the bus), e.g. `org.bluez.Error.AuthenticationFailed`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BtError(pub String);

impl BtError {
    pub fn new(name: &str) -> Self {
        BtError(name.to_owned())
    }
}

/// The contract's status for a BlueZ error. `pairing` is true for the `Pair` call, where a
/// refused authentication is `pairing-failed`; elsewhere it is plain `failed`.
pub fn map_error(name: &str, pairing: bool) -> Status {
    match name {
        // Nothing left to do: the device is in the state that was asked for.
        "org.bluez.Error.AlreadyExists"
        | "org.bluez.Error.AlreadyConnected"
        | "org.bluez.Error.NotConnected" => Status::Ok,
        LOCAL_TIMEOUT
        | "org.bluez.Error.AuthenticationTimeout"
        | "org.freedesktop.DBus.Error.NoReply"
        | "org.freedesktop.DBus.Error.Timeout"
        | "org.freedesktop.DBus.Error.TimedOut" => Status::Timeout,
        "org.bluez.Error.NotReady"
        | "org.bluez.Error.NotAvailable"
        | "org.bluez.Error.Blocked"
        | "org.freedesktop.DBus.Error.ServiceUnknown"
        | "org.freedesktop.DBus.Error.NameHasNoOwner"
        | "org.freedesktop.DBus.Error.Spawn.ServiceNotFound"
        | "org.freedesktop.DBus.Error.Spawn.ChildExited"
        | "org.freedesktop.DBus.Error.Spawn.Failed"
        | "org.freedesktop.DBus.Error.Spawn.ExecFailed" => Status::Unavailable,
        "org.bluez.Error.DoesNotExist" | "org.freedesktop.DBus.Error.UnknownObject" => {
            Status::UnknownDevice
        }
        "org.bluez.Error.InvalidArguments" => Status::Invalid,
        "org.bluez.Error.AuthenticationFailed"
        | "org.bluez.Error.AuthenticationCanceled"
        | "org.bluez.Error.AuthenticationRejected"
        | "org.bluez.Error.ConnectionAttemptFailed"
        | "org.bluez.Error.Rejected"
        | "org.bluez.Error.Canceled"
            if pairing =>
        {
            Status::PairingFailed
        }
        _ => Status::Failed,
    }
}

/// `org.bluez.Battery1.Percentage` (a byte) as the contract's `battery`: 0-100, or -1 when the
/// device reports none.
pub fn battery_of(percentage: Option<u8>) -> i32 {
    percentage.map_or(-1, |p| i32::from(p.min(100)))
}

/// What the shell shows a device as (the contract's `kind`). From BlueZ's `Icon`, which it
/// derives from the class of device; a device with no `Icon` is "other".
pub fn kind_of(icon: &str) -> &'static str {
    match icon {
        "input-gaming" => "controller",
        "audio-headset" | "audio-headphones" => "headset",
        "audio-card" | "audio-speakers" => "speaker",
        "input-keyboard" => "keyboard",
        "input-mouse" => "mouse",
        "phone" => "phone",
        _ => "other",
    }
}

/// The contract's `family`: the controller family of a `controller`, "" for every other kind
/// (a Sony headset has Sony's vendor id and is no PlayStation pad). `families::family_of` holds
/// the table.
pub fn family_for(kind: &str, modalias: &str, device_name: &str, alias: &str) -> &'static str {
    if kind == "controller" {
        family_of_device(modalias, device_name, alias)
    } else {
        ""
    }
}

/// One `org.bluez.Device1` as read from the bus (with its `Battery1`, if any).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawDevice {
    pub address: String,
    /// `Alias`: the user's name, else the device's own, else the address with dashes.
    pub alias: String,
    /// `Name`: what the device calls itself (the model), whatever its alias; "" when it told none.
    pub name: String,
    pub icon: String,
    /// `Modalias` (`usb:v054Cp0CE6d0100`), "" when the device has none.
    pub modalias: String,
    pub paired: bool,
    /// `Bonded`: the pairing keys are kept. A device paired while the adapter was not pairable is
    /// `Paired: yes, Bonded: no`.
    pub bonded: bool,
    pub connected: bool,
    pub trusted: bool,
    pub battery: Option<u8>,
    /// `Class` (Class of Device); BlueZ has none for a device seen only over Bluetooth LE.
    pub class: Option<u32>,
    /// `Appearance` (Bluetooth LE).
    pub appearance: Option<u16>,
    /// The object path of the adapter this device was read under (`/org/bluez/hci1`). Every call
    /// for the device goes through that adapter (T-336).
    pub adapter: String,
}

/// The first adapter's object path (`HCI0`), the one a single-adapter machine has.
pub const HCI0: &str = "/org/bluez/hci0";

/// An adapter's name as the contract shows it (`hci0`) from its object path.
pub fn adapter_name(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RawAdapter {
    pub powered: bool,
    pub discovering: bool,
    pub pairable: bool,
    pub discoverable: bool,
}

/// One `org.bluez.Adapter1`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdapterInfo {
    /// `/org/bluez/hci0`.
    pub path: String,
    /// Attached over USB (the sysfs path of `/sys/class/bluetooth/hciN` contains `/usb`).
    pub usb: bool,
    /// The adapter's own Bluetooth address (`Adapter1.Address`, upper case), "" when BlueZ tells
    /// none. The System information shows the primary adapter's (T-359).
    pub address: String,
    pub state: RawAdapter,
}

/// Everything the core needs from one read of BlueZ.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Raw {
    /// Every adapter; empty: no adapter, or BlueZ is not there. Devices of all of them are in
    /// `devices`; the adapter-wide state and the pairing window are the primary one's.
    pub adapters: Vec<AdapterInfo>,
    pub devices: Vec<RawDevice>,
}

impl Raw {
    /// One adapter (`/org/bluez/hci0`, not USB) and its devices.
    pub fn single(state: RawAdapter, devices: Vec<RawDevice>) -> Raw {
        Raw {
            adapters: vec![AdapterInfo {
                path: HCI0.to_owned(),
                usb: false,
                address: String::new(),
                state,
            }],
            devices,
        }
    }

    /// The primary adapter (see `primary_index`).
    pub fn primary(&self) -> Option<&AdapterInfo> {
        primary_index(&self.adapters, &self.devices).map(|i| &self.adapters[i])
    }

    pub fn primary_mut(&mut self) -> Option<&mut AdapterInfo> {
        let i = primary_index(&self.adapters, &self.devices)?;
        self.adapters.get_mut(i)
    }

    /// The adapter-wide state as the contract shows it: the primary adapter's, except that
    /// `powered` is true when any adapter is on (a pad bonded on the second one keeps working).
    pub fn adapter(&self) -> Option<RawAdapter> {
        let mut state = self.primary()?.state;
        state.powered = self.adapters.iter().any(|a| a.state.powered);
        Some(state)
    }
}

/// The number in `hciN`; adapters named otherwise sort last.
fn hci_number(path: &str) -> u32 {
    adapter_name(path)
        .trim_start_matches(|c: char| !c.is_ascii_digit())
        .parse()
        .unwrap_or(u32::MAX)
}

/// The primary adapter (spec 03): new pairings, the scan, the pairing window and Pairable act on
/// it. It is the adapter with the most paired devices, so a pad bonded on the second adapter
/// keeps its adapter whatever order the adapters come up in; a tie goes to a USB-attached
/// adapter, then to the lowest `hciN`. T-289's adapter address uses this too.
pub fn primary_index(adapters: &[AdapterInfo], devices: &[RawDevice]) -> Option<usize> {
    (0..adapters.len()).max_by_key(|&i| {
        let a = &adapters[i];
        let paired = devices
            .iter()
            .filter(|d| d.paired && d.adapter == a.path)
            .count();
        (paired, a.usb, std::cmp::Reverse(hci_number(&a.path)))
    })
}

/// One entry per address: a device that more than one adapter has seen is listed once, under the
/// adapter that holds it (connected, then paired, then bonded, then the primary one; the first
/// read otherwise). Order of first sight is kept.
pub fn merge_devices(devices: Vec<RawDevice>, primary: &str) -> Vec<RawDevice> {
    let key = |d: &RawDevice| (d.connected, d.paired, d.bonded, d.adapter == primary);
    let mut out: Vec<RawDevice> = Vec::with_capacity(devices.len());
    for d in devices {
        match out.iter_mut().find(|o| o.address == d.address) {
            Some(o) => {
                if key(&d) > key(o) {
                    *o = d;
                }
            }
            None => out.push(d),
        }
    }
    out
}

/// A device as the journal names it: `AA:.. "Alias" (hci0)`. Names are what a remote device
/// chose, so control characters are cleaned, and so are the quote that would end the alias early
/// and the format characters that hide or reorder text (T-359).
fn label_of(d: &RawDevice) -> String {
    format!(
        "{} \"{}\" ({})",
        clean(&d.address),
        clean(&d.alias).replace('"', "").replace(is_format_char, ""),
        adapter_name(&d.adapter)
    )
}

/// A length of time for the journal: whole minutes as `35 min`, else seconds.
fn span(d: Duration) -> String {
    let s = d.as_secs();
    if s >= 60 && s % 60 == 0 {
        format!("{} min", s / 60)
    } else {
        format!("{s} s")
    }
}

/// The devices that connected or dropped between two reads and that we did not ask for, as
/// journal lines (`link`: the device or the radio did it). A request of ours that BlueZ now
/// shows is used up silently; one that never showed is dropped when the device changes anyway.
/// Only devices in both reads count, so the first read and a radio that went off and on say
/// nothing.
fn link_changes(
    before: &[RawDevice],
    after: &[RawDevice],
    on: bool,
    intents: &mut HashMap<String, bool>,
) -> Vec<String> {
    let mut lines = Vec::new();
    if !on {
        return lines;
    }
    for d in after {
        let Some(old) = before.iter().find(|o| o.address == d.address) else {
            continue;
        };
        if old.connected == d.connected {
            continue;
        }
        if intents.remove(&d.address) == Some(d.connected) {
            continue;
        }
        lines.push(format!(
            "{} {}: link",
            if d.connected {
                "connected"
            } else {
                "disconnected"
            },
            label_of(d)
        ));
    }
    lines
}

/// The adapters whose radio went on or off between two reads without our asking (`rfkill`, a
/// `bluetoothctl power`, a driver reset), as journal lines. `asked`: what `set_powered` asked
/// for, which is not news. Only an adapter in both reads counts, so the first read and an adapter
/// that was just plugged in say nothing.
fn adapter_changes(
    before: &[AdapterInfo],
    after: &[AdapterInfo],
    asked: Option<bool>,
) -> Vec<String> {
    after
        .iter()
        .filter_map(|a| {
            let old = before.iter().find(|b| b.path == a.path)?;
            if old.state.powered == a.state.powered || asked == Some(a.state.powered) {
                return None;
            }
            Some(format!(
                "{} powered {}: radio",
                adapter_name(&a.path),
                if a.state.powered { "on" } else { "off" }
            ))
        })
        .collect()
}

/// Whether a device announces a keyboard (class, appearance or BlueZ's icon).
fn announces_keyboard(d: &RawDevice) -> bool {
    kind_of(&d.icon) == "keyboard" || crate::pairing::is_keyboard_class(d.class, d.appearance)
}

/// What the controller pairing window lets through (RUY-411): an input device that is not a
/// keyboard. A keyboard types anywhere the shell can, so it pairs only from Settings > Bluetooth,
/// behind its own confirmation; inside the window it is a stranger.
fn window_accepts(d: &RawDevice) -> bool {
    is_input_device(d.class, d.appearance) && !announces_keyboard(d)
}

/// A listed device (the contract's dictionary).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    pub id: String,
    /// The alias (the user's name for it, else the device's own).
    pub name: String,
    /// BlueZ's `Name`, the model as the device advertises it; "" when it told none.
    pub device_name: String,
    pub kind: &'static str,
    /// The device announces a keyboard class (RUY-411): the shell asks a second time before pairing.
    pub keyboard: bool,
    /// "playstation" | "xbox" | "nintendo" | "" (`family_for`).
    pub family: &'static str,
    pub paired: bool,
    pub bonded: bool,
    pub connected: bool,
    pub trusted: bool,
    pub battery: i32,
    /// The name of the adapter that holds the device (`hci0`).
    pub adapter: String,
}

/// The listed devices: paired first, then by name (case-insensitive), then by id. An unpaired
/// device that never told its name (alias = its address) is noise from a scan and is left out.
pub fn list_of(raw: &[RawDevice]) -> Vec<Device> {
    let mut out: Vec<Device> = raw
        .iter()
        .filter(|d| d.paired || d.alias.replace('-', ":") != d.address)
        .map(|d| Device {
            id: d.address.clone(),
            name: d.alias.clone(),
            device_name: d.name.clone(),
            kind: kind_of(&d.icon),
            keyboard: kind_of(&d.icon) == "keyboard"
                || crate::pairing::is_keyboard_class(d.class, d.appearance),
            family: family_for(kind_of(&d.icon), &d.modalias, &d.name, &d.alias),
            paired: d.paired,
            bonded: d.bonded,
            connected: d.connected,
            trusted: d.trusted,
            battery: battery_of(d.battery),
            adapter: adapter_name(&d.adapter).to_owned(),
        })
        .collect();
    out.sort_by(|a, b| {
        b.paired
            .cmp(&a.paired)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            .then_with(|| a.id.cmp(&b.id))
    });
    out
}

/// BlueZ, as far as the core needs it. `bluez::BluezClient` talks to the bus. The calls block
/// (the service runs them off the executor); `pair` and `connect` give up after `timeout` and
/// then report `LOCAL_TIMEOUT`.
pub trait Bluez: Send + Sync {
    fn snapshot(&self) -> Result<Raw, BtError>;
    /// Every adapter (on: every one that is not rfkill-blocked; `Err` only when none could be
    /// switched).
    fn set_powered(&self, on: bool) -> Result<(), BtError>;
    /// The `Pairable` property of the adapter with this object path. BlueZ 5.87 keeps it off,
    /// and an adapter that is not pairable answers a pairing with "No Bonding": the pairing
    /// succeeds but no link key is kept (`Bonded: no`), and BlueZ's HID plugin then rejects the
    /// pad (T-162 session, Dell). So a pairing opens it on the adapter the pairing goes through,
    /// and whoever opened it closes it on that same adapter, whatever the primary one is by then.
    fn set_pairable(&self, adapter: &str, on: bool) -> Result<(), BtError>;
    /// The adapter's `Discoverable` property. Nothing turns it on; it is switched off (on every
    /// adapter) when the service starts, in case a crashed one left it on.
    fn set_discoverable(&self, adapter: &str, on: bool) -> Result<(), BtError>;
    /// Registers our agent (capability `NoInputNoOutput`) as BlueZ's default one, and takes it
    /// away again. BlueZ then asks `AgentHandler` about incoming pairings. Only while the
    /// controller pairing window is open.
    fn register_agent(&self) -> Result<(), BtError>;
    fn unregister_agent(&self) -> Result<(), BtError>;
    /// A scan on this adapter (the core asks the primary one, and stops it on the same one).
    fn start_discovery(&self, adapter: &str) -> Result<(), BtError>;
    fn stop_discovery(&self, adapter: &str) -> Result<(), BtError>;
    /// The calls for one device take the object path of the adapter that holds it
    /// (`RawDevice::adapter`), never "the first adapter" (T-336).
    fn pair(&self, adapter: &str, address: &str, timeout: Duration) -> Result<(), BtError>;
    fn set_trusted(&self, adapter: &str, address: &str) -> Result<(), BtError>;
    fn connect(&self, adapter: &str, address: &str, timeout: Duration) -> Result<(), BtError>;
    fn disconnect(&self, adapter: &str, address: &str) -> Result<(), BtError>;
    fn remove(&self, adapter: &str, address: &str) -> Result<(), BtError>;
    /// The device's `Alias` (the name the user gave it).
    fn set_alias(&self, adapter: &str, address: &str, alias: &str) -> Result<(), BtError>;
}

/// What a refresh found different (so the signals are due).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Changes {
    pub devices: bool,
    pub powered: bool,
    pub discovering: bool,
    /// `ControllerPairingState` changed.
    pub pairing: bool,
    /// The window refused a device that is not an input device (the `ControllerPairingRejected`
    /// signal).
    pub rejected: bool,
}

impl Changes {
    pub fn any(&self) -> bool {
        self.devices || self.powered || self.discovering || self.pairing || self.rejected
    }

    pub fn merge(self, other: Changes) -> Changes {
        Changes {
            devices: self.devices || other.devices,
            powered: self.powered || other.powered,
            discovering: self.discovering || other.discovering,
            pairing: self.pairing || other.pairing,
            rejected: self.rejected || other.rejected,
        }
    }
}

/// What BlueZ asks of the agent, as far as the window answers it. Anything that needs a PIN or a
/// passkey is `Pin` and is always refused (B-006 owns PIN pairing).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentCall<'a> {
    /// `RequestAuthorization` (an incoming just-works pairing) and `RequestConfirmation`.
    Authorize { device: &'a str },
    /// `AuthorizeService`.
    Service { device: &'a str, uuid: &'a str },
    /// `RequestPinCode`, `RequestPasskey`, `DisplayPinCode`, `DisplayPasskey`.
    Pin,
}

/// BlueZ's questions to our agent (`bluez::BluezClient` carries them over the bus). `true`
/// accepts, `false` answers `org.bluez.Error.Rejected`.
pub trait AgentHandler: Send + Sync {
    fn answer(&self, call: AgentCall<'_>) -> bool;
}

/// The window that is open: what to restore when it closes, and what it has accepted.
struct Window {
    /// Tells this window from a later one (a pairing started for one must not act in the next).
    id: u64,
    until: Instant,
    /// The adapter the window opened (object path): it is the one made pairable and scanning, the
    /// one whose pads the window pairs, and the one restored when the window closes, even if
    /// another adapter has become the primary one meanwhile.
    adapter: String,
    /// Pairable was off before: switch it off again (`false`: it was on, leave it).
    restore_pairable: bool,
    /// The scan is ours: stop it when the window closes.
    scan_ours: bool,
    /// Devices that were paired before the window opened. Anything paired that is not in here
    /// came in during the window: an input device is the point of it, anything else is removed
    /// again (the kernel accepts a just-works pairing by itself, the agent is not asked).
    paired_before: HashSet<String>,
    attempts: HashMap<String, u32>,
    in_flight: Option<String>,
}

#[derive(Default)]
struct State {
    adapter: Option<RawAdapter>,
    /// Every adapter of the last read, and the object path of the primary one among them.
    adapters: Vec<AdapterInfo>,
    primary: Option<String>,
    /// The adapter the scan we started runs on (object path).
    scan_adapter: Option<String>,
    devices: Vec<Device>,
    /// The last read, unfiltered (the window needs the classes).
    raw_devices: Vec<RawDevice>,
    window: Option<Window>,
    next_window: u64,
    /// A start is in progress (BlueZ is being asked); a second one is `busy`.
    starting: bool,
    /// Manual pairings (`pair`) in progress: they hold `Pairable` open themselves.
    manual_pairs: u32,
    /// The adapters (object paths) made not pairable and not discoverable once (after a crash in a
    /// window). One that is not in a read any more is dropped, so it is secured again when it
    /// comes back (a dongle plugged in later, BlueZ restarted).
    secured: HashSet<String>,
    /// Some adapters were secured already: a later one is "appeared", not "startup".
    secured_before: bool,
    /// What the radio was last asked for (`set_powered`), so the reads that follow do not log it as
    /// a change of the radio's own.
    power_intent: Option<bool>,
    pairing: PairingState,
    /// When the running scan has to be stopped (only for a scan we started).
    scan_until: Option<Instant>,
    /// Changes seen by reads whose caller did not announce them (a call that read on the way);
    /// the next `refresh` reports them.
    pending: Changes,
    /// Connect and disconnect requests of ours that BlueZ has not shown yet (address -> the
    /// connected state asked for): a change that matches one is not logged as `link`.
    intents: HashMap<String, bool>,
}

type Notifier = Arc<dyn Fn() + Send + Sync>;

/// Where `bluez::BluezClient` finds the core's handler once the core exists (the core owns the
/// client, so the client cannot be given the core).
pub type AgentSlot = Arc<std::sync::OnceLock<Arc<dyn AgentHandler>>>;

pub struct Bluetooth<B: Bluez> {
    bluez: B,
    state: Mutex<State>,
    /// Called when something changed outside any D-Bus call (the agent refused a device).
    notifier: Mutex<Option<Notifier>>,
    /// Which idle pads were told to disconnect (T-202).
    idle_pads: Mutex<IdlePads>,
}

impl<B: Bluez> Bluetooth<B> {
    pub fn new(bluez: B) -> Self {
        Bluetooth {
            bluez,
            state: Mutex::new(State::default()),
            notifier: Mutex::new(None),
            idle_pads: Mutex::new(IdlePads::new()),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        // A poisoned lock only means another call panicked; the state is plain data.
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn powered(&self) -> bool {
        self.lock().adapter.is_some_and(|a| a.powered)
    }

    pub fn discovering(&self) -> bool {
        self.lock()
            .adapter
            .is_some_and(|a| a.powered && a.discovering)
    }

    pub fn list(&self) -> Vec<Device> {
        self.lock().devices.clone()
    }

    /// The primary adapter of the last read: its name (`hci1`) and its address ("" when BlueZ told
    /// none). The System information describes this one (T-359).
    pub fn primary_adapter(&self) -> Option<(String, String)> {
        let st = self.lock();
        let path = st.primary.as_ref()?;
        let adapter = st.adapters.iter().find(|a| &a.path == path)?;
        Some((adapter_name(path).to_owned(), adapter.address.clone()))
    }

    /// When the scan we started has to be ended, if one runs.
    pub fn scan_deadline(&self) -> Option<Instant> {
        self.lock().scan_until
    }

    /// Reads BlueZ again and returns every change not announced yet. Powered off (or no
    /// adapter) means an empty list and no scan.
    pub fn refresh(&self) -> Result<Changes, BtError> {
        self.read()?;
        self.secure_adapter();
        Ok(std::mem::take(&mut self.lock().pending))
    }

    /// The first time an adapter is seen (and no window is open) it is made not pairable and not
    /// discoverable: a service that crashed inside a window must not leave the console open for
    /// pairing, whichever adapter that window had opened. An adapter that shows up later (a USB
    /// dongle plugged in, BlueZ restarted) gets the same treatment. The window and `pair` open
    /// `Pairable` themselves, only for as long as they need.
    fn secure_adapter(&self) {
        let (fresh, why) = {
            let mut st = self.lock();
            let present: HashSet<String> = st.adapters.iter().map(|a| a.path.clone()).collect();
            st.secured.retain(|p| present.contains(p));
            if st.window.is_some() || st.starting || st.manual_pairs > 0 {
                return;
            }
            let fresh: Vec<AdapterInfo> = st
                .adapters
                .iter()
                .filter(|a| !st.secured.contains(&a.path))
                .cloned()
                .collect();
            if fresh.is_empty() {
                return;
            }
            for a in &fresh {
                st.secured.insert(a.path.clone());
            }
            let why = if st.secured_before {
                "adapter appeared"
            } else {
                "startup"
            };
            st.secured_before = true;
            (fresh, why)
        };
        for a in fresh {
            let name = adapter_name(&a.path);
            if a.state.pairable {
                if let Err(e) = self.set_pairable(&a.path, false, why) {
                    log::info(&format!("{name} Pairable off failed: {}", e.0));
                }
            }
            if a.state.discoverable {
                match self.bluez.set_discoverable(&a.path, false) {
                    Ok(()) => log::info(&format!("{name} Discoverable off: {why}")),
                    Err(e) => log::info(&format!("{name} Discoverable off failed: {}", e.0)),
                }
            }
        }
    }

    /// Reads BlueZ and remembers what changed for the next `refresh`.
    fn read(&self) -> Result<(), BtError> {
        let raw = self.bluez.snapshot()?;
        let adapter = raw.adapter();
        let on = adapter.is_some_and(|a| a.powered);
        // A device more than one adapter has seen is one entry, under the adapter that holds it.
        let primary = raw.primary().map(|a| a.path.clone());
        let adapters = raw.adapters;
        let raw_devices = merge_devices(raw.devices, primary.as_deref().unwrap_or_default());
        let devices = if on {
            list_of(&raw_devices)
        } else {
            Vec::new()
        };
        let mut st = self.lock();
        let links = {
            let State {
                raw_devices: before,
                intents,
                ..
            } = &mut *st;
            link_changes(before, &raw_devices, on, intents)
        };
        let radio = adapter_changes(&st.adapters, &adapters, st.power_intent);
        // Pairable came on without us (someone else, or BlueZ started over from its defaults): say
        // so. It is left as it is: what another program set is its own (the window gives back
        // what it found), and an adapter that BlueZ lost and found again is secured anew.
        let ours = st.window.is_some() || st.starting || st.manual_pairs > 0;
        let opened: Vec<String> = if ours {
            Vec::new()
        } else {
            adapters
                .iter()
                .filter(|a| {
                    a.state.pairable
                        && st
                            .adapters
                            .iter()
                            .any(|b| b.path == a.path && !b.state.pairable)
                })
                .map(|a| a.path.clone())
                .collect()
        };

        let off = RawAdapter {
            powered: false,
            discovering: false,
            pairable: false,
            discoverable: false,
        };
        let before = st.adapter.unwrap_or(off);
        let after = adapter.unwrap_or(off);
        let changes = Changes {
            devices: st.devices != devices,
            powered: before.powered != after.powered,
            discovering: (before.powered && before.discovering)
                != (after.powered && after.discovering),
            ..Changes::default()
        };
        st.pending.devices |= changes.devices;
        st.pending.powered |= changes.powered;
        st.pending.discovering |= changes.discovering;
        st.adapter = adapter;
        st.adapters = adapters;
        st.primary = primary;
        st.devices = devices;
        st.raw_devices = if on { raw_devices } else { Vec::new() };
        // The scan is over when BlueZ says so after having said it runs, or the adapter went
        // off. A snapshot that still shows "not discovering" right after StartDiscovery (BlueZ
        // sets the property a moment later) must not drop the deadline.
        if !on || (before.discovering && !after.discovering) {
            st.scan_until = None;
        }
        drop(st);
        for line in links.into_iter().chain(radio) {
            log::info(&line);
        }
        for path in opened {
            log::info(&format!("{} Pairable on: not us", adapter_name(&path)));
        }
        Ok(())
    }

    /// A device as the journal names it: `AA:.. "Alias" (hci0)`; the bare address when the last
    /// read did not show it.
    fn label(&self, address: &str) -> String {
        self.lock()
            .raw_devices
            .iter()
            .find(|d| d.address == address)
            .map_or_else(|| clean(address), label_of)
    }

    /// `Pairable` on an adapter, logged when it worked (`why`: who asked).
    fn set_pairable(&self, adapter: &str, on: bool, why: &str) -> Result<(), BtError> {
        self.bluez.set_pairable(adapter, on)?;
        log::info(&format!(
            "{} Pairable {}: {why}",
            adapter_name(adapter),
            if on { "on" } else { "off" }
        ));
        Ok(())
    }

    /// Asks BlueZ to connect the device, through its own adapter. `reason`: `user`, `window`.
    fn connect_device(
        &self,
        address: &str,
        timeout: Duration,
        reason: &str,
    ) -> Result<(), BtError> {
        let label = self.label(address);
        log::info(&format!("connect {label}: {reason}"));
        self.lock().intents.insert(address.to_owned(), true);
        let result = self
            .route(address)
            .and_then(|a| self.bluez.connect(&a, address, timeout));
        if let Err(e) = &result {
            self.lock().intents.remove(address);
            log::info(&format!("connect {label} failed: {}", e.0));
        }
        result
    }

    /// Asks BlueZ to disconnect the device. `reason`: `user`, `idle-timeout (...)`.
    fn disconnect_device(&self, address: &str, reason: &str) -> Result<(), BtError> {
        let label = self.label(address);
        log::info(&format!("disconnect {label}: {reason}"));
        self.lock().intents.insert(address.to_owned(), false);
        let result = self
            .route(address)
            .and_then(|a| self.bluez.disconnect(&a, address));
        if let Err(e) = &result {
            self.lock().intents.remove(address);
            log::info(&format!("disconnect {label} failed: {}", e.0));
        }
        result
    }

    /// Removes the pairing (BlueZ then disconnects too). `reason`: `forget` (the user), `sweep`
    /// (a stranger the window found), `agent-refused`.
    fn remove_device(&self, address: &str, reason: &str) -> Result<(), BtError> {
        let label = self.label(address);
        log::info(&format!("remove {label}: {reason}"));
        let result = self
            .route(address)
            .and_then(|a| self.bluez.remove(&a, address));
        if let Err(e) = &result {
            log::info(&format!("remove {label} failed: {}", e.0));
        }
        result
    }

    /// Trusts the device (BlueZ then lets its HID connection through).
    fn trust(&self, address: &str) -> Result<(), BtError> {
        let label = self.label(address);
        let result = self
            .route(address)
            .and_then(|a| self.bluez.set_trusted(&a, address));
        match &result {
            Ok(()) => log::info(&format!("trusted {label}")),
            Err(e) => log::info(&format!("trusting {label} failed: {}", e.0)),
        }
        result
    }

    /// The adapter must be there and on for scanning, pairing and connecting.
    fn ready(&self) -> Result<(), Status> {
        match self.read() {
            Ok(()) if self.powered() => Ok(()),
            Ok(()) => Err(Status::Unavailable),
            Err(e) => Err(map_error(&e.0, false)),
        }
    }

    /// `ready`, and the primary adapter is on too: the scan, new pairings and the pairing window
    /// belong to it, so another adapter being on does not make them available (T-359).
    fn ready_primary(&self) -> Result<(), Status> {
        self.ready()?;
        let st = self.lock();
        let on = st
            .primary
            .as_ref()
            .and_then(|p| st.adapters.iter().find(|a| &a.path == p))
            .is_some_and(|a| a.state.powered);
        if on {
            Ok(())
        } else {
            Err(Status::Unavailable)
        }
    }

    /// Powers the adapter. `Err` when BlueZ refused (no adapter, rfkill blocked): the service
    /// answers a D-Bus error.
    pub fn set_powered(&self, on: bool) -> Result<Changes, BtError> {
        // Know the adapter first: BlueZ may have just come up.
        self.read()?;
        self.lock().power_intent = Some(on);
        let result = match self.bluez.set_powered(on) {
            Ok(()) => {
                log::info(&format!(
                    "adapters powered {} (user)",
                    if on { "on" } else { "off" }
                ));
                self.refresh()
            }
            Err(e) => Err(e),
        };
        self.lock().power_intent = None;
        result
    }

    pub fn start_scan(&self, now: Instant) -> Status {
        if let Err(status) = self.ready_primary() {
            return status;
        }
        let Some(path) = self.lock().primary.clone() else {
            return Status::Unavailable;
        };
        if !self.discovering() {
            if let Err(e) = self.bluez.start_discovery(&path) {
                return map_error(&e.0, false);
            }
        }
        let mut st = self.lock();
        st.scan_adapter = Some(path);
        st.scan_until = Some(now + SCAN_LIMIT);
        Status::Ok
    }

    pub fn stop_scan(&self) -> Status {
        // A scan we started is ended even before BlueZ reports Discovering (T-173 review).
        let ours = self.lock().scan_until.is_some();
        if self.lock().window.is_some() {
            // The controller pairing window needs the scan; it ends it when it closes.
            self.lock().scan_until = None;
            return Status::Ok;
        }
        if self.read().is_err() || (!self.discovering() && !ours) {
            self.lock().scan_until = None;
            return Status::Ok;
        }
        // The adapter the scan runs on, not whichever is the primary one now.
        let path = {
            let st = self.lock();
            st.scan_adapter
                .clone()
                .filter(|_| ours)
                .or_else(|| st.primary.clone())
        };
        let status = match path {
            Some(path) => match self.bluez.stop_discovery(&path) {
                Ok(()) => Status::Ok,
                Err(e) => map_error(&e.0, false),
            },
            None => Status::Ok,
        };
        self.lock().scan_until = None;
        status
    }

    /// Ends the scan and the controller pairing window once their time is up. `true` when one
    /// ended.
    pub fn tick(&self, now: Instant) -> bool {
        let mut ended = false;
        let due = self.lock().scan_until.is_some_and(|t| now >= t);
        if due {
            // The window keeps its own scan running until it closes.
            if self.lock().window.is_none() {
                let path = {
                    let st = self.lock();
                    st.scan_adapter.clone().or_else(|| st.primary.clone())
                };
                if let Some(Err(e)) = path.map(|p| self.bluez.stop_discovery(&p)) {
                    log::info(&format!("ending the scan failed: {}", e.0));
                }
            }
            self.lock().scan_until = None;
            ended = true;
        }
        if self.lock().window.as_ref().is_some_and(|w| now >= w.until) {
            self.close_window(PairingState::Timeout, None);
            ended = true;
        }
        ended
    }

    /// The object path of the adapter that holds the device: from the last read, else from a
    /// new one, else the device is unknown (BlueZ's `DoesNotExist`, the contract's
    /// `unknown-device`).
    fn route(&self, address: &str) -> Result<String, BtError> {
        let known = || {
            self.lock()
                .raw_devices
                .iter()
                .find(|d| d.address == address)
                .map(|d| d.adapter.clone())
        };
        if let Some(adapter) = known() {
            return Ok(adapter);
        }
        self.read()?;
        known().ok_or_else(|| BtError::new("org.bluez.Error.DoesNotExist"))
    }

    /// Looks the device up in a fresh read.
    fn find(&self, id: &str) -> Result<Device, Status> {
        if id.is_empty() {
            return Err(Status::Invalid);
        }
        self.read().map_err(|e| map_error(&e.0, false))?;
        self.list()
            .into_iter()
            .find(|d| d.id == id)
            .ok_or(Status::UnknownDevice)
    }

    fn ready_device(&self, id: &str) -> Result<Device, Status> {
        if id.is_empty() {
            return Err(Status::Invalid);
        }
        self.ready()?;
        self.find(id)
    }

    /// Pair (just works), trust and connect. One budget of `CALL_TIMEOUT` (counted by `clock`)
    /// covers the whole call: connecting gets what pairing left, so the answer comes before the
    /// D-Bus default timeout.
    pub fn pair(&self, id: &str, clock: impl Fn() -> Instant) -> Status {
        // While it runs, `refresh` must not close the `Pairable` it opens.
        self.lock().manual_pairs += 1;
        let status = self.pair_one(id, clock);
        let mut st = self.lock();
        st.manual_pairs = st.manual_pairs.saturating_sub(1);
        status
    }

    fn pair_one(&self, id: &str, clock: impl Fn() -> Instant) -> Status {
        if id.is_empty() {
            return Status::Invalid;
        }
        if let Err(s) = self.ready() {
            return s;
        }
        let dev = match self.find(id) {
            Ok(d) => d,
            Err(s) => return s,
        };
        let end = clock() + CALL_TIMEOUT;
        let left = || end.saturating_duration_since(clock());
        if !dev.paired {
            // A new pairing belongs to the primary adapter (T-359); a device that is paired only
            // connects, through the adapter that holds it.
            if let Err(s) = self.ready_primary() {
                return s;
            }
            // The adapter the pairing goes through (the device's own, not the primary one) has
            // to be bondable, for the pairing itself, and off again whatever it ends with. The
            // controller pairing window keeps its adapter pairable while it is open, and gives it
            // back when it closes.
            let adapter = match self.route(&dev.id) {
                Ok(a) => a,
                Err(e) => return map_error(&e.0, false),
            };
            let window = {
                // A device the user pairs by hand in the window is theirs, not a stranger.
                let mut st = self.lock();
                match st.window.as_mut() {
                    Some(w) => {
                        w.paired_before.insert(dev.id.clone());
                        w.adapter == adapter
                    }
                    None => false,
                }
            };
            if !window {
                if let Err(e) = self.set_pairable(&adapter, true, "manual pairing") {
                    return map_error(&e.0, false);
                }
            }
            let paired = self.bluez.pair(&adapter, &dev.id, left());
            if !window {
                if let Err(e) = self.set_pairable(&adapter, false, "manual pairing done") {
                    log::info(&format!("Pairable off again failed: {}", e.0));
                }
            }
            if let Err(e) = paired {
                log::info(&format!(
                    "pairing {} via manual failed: {}",
                    self.label(&dev.id),
                    e.0
                ));
                return map_error(&e.0, true);
            }
            log::info(&format!("paired {} via manual", self.label(&dev.id)));
        }
        if let Err(e) = self.trust(&dev.id) {
            return map_error(&e.0, false);
        }
        let left = left();
        if left.is_zero() {
            return Status::Timeout;
        }
        match self.connect_device(&dev.id, left, "user") {
            Ok(()) => Status::Ok,
            Err(e) => map_error(&e.0, true),
        }
    }

    pub fn connect(&self, id: &str) -> Status {
        match self.ready_device(id) {
            Ok(d) if !d.paired => Status::Failed,
            Ok(d) => match self.connect_device(&d.id, CALL_TIMEOUT, "user") {
                Ok(()) => Status::Ok,
                Err(e) => map_error(&e.0, false),
            },
            Err(s) => s,
        }
    }

    pub fn disconnect(&self, id: &str) -> Status {
        match self.find(id) {
            Ok(d) if !d.paired => Status::Failed,
            Ok(d) => match self.disconnect_device(&d.id, "user") {
                Ok(()) => Status::Ok,
                Err(e) => map_error(&e.0, false),
            },
            Err(s) => s,
        }
    }

    /// The shell's idle report (T-202): disconnects the connected, paired game controllers that
    /// have been idle for the whole timeout. Returns the ids it disconnected. Bluetooth being off
    /// or unreadable disconnects nothing.
    pub fn report_idle(&self, now: Instant, report: IdleReport) -> Vec<String> {
        if self.read().is_err() {
            return Vec::new();
        }
        let pads: Vec<Pad> = self
            .list()
            .into_iter()
            .filter(|d| d.kind == "controller" && d.paired)
            .map(|d| Pad {
                id: d.id,
                connected: d.connected,
            })
            .collect();
        let due = self
            .idle_pads
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .decide(now, report, &pads);
        let mut done = Vec::new();
        for id in due {
            let reason = format!(
                "idle-timeout (idle {} >= {})",
                span(report.idle),
                span(report.timeout)
            );
            if self.disconnect_device(&id, &reason).is_ok() {
                done.push(id);
            }
        }
        done
    }

    /// Gives a paired device the name the user typed (BlueZ's `Alias`), T-260. The name is
    /// trimmed and Unicode format characters (bidi overrides, zero-width) are dropped; empty,
    /// longer than `MAX_NAME_CHARS` or with a control character is `invalid`; a device that is
    /// not paired is `failed`.
    pub fn rename(&self, id: &str, name: &str) -> Status {
        let name: String = name.chars().filter(|c| !is_format_char(*c)).collect();
        let name = name.trim();
        if name.is_empty()
            || name.chars().count() > MAX_NAME_CHARS
            || name.chars().any(char::is_control)
        {
            return Status::Invalid;
        }
        match self.ready_device(id) {
            Ok(d) if !d.paired => Status::Failed,
            Ok(d) => match self
                .route(&d.id)
                .and_then(|a| self.bluez.set_alias(&a, &d.id, name))
            {
                Ok(()) => Status::Ok,
                Err(e) => map_error(&e.0, false),
            },
            Err(s) => s,
        }
    }

    /// Disconnects and removes the pairing (BlueZ's `RemoveDevice` does both).
    pub fn forget(&self, id: &str) -> Status {
        match self.find(id) {
            Ok(d) => match self.remove_device(&d.id, "forget") {
                Ok(()) => Status::Ok,
                Err(e) => map_error(&e.0, false),
            },
            Err(s) => s,
        }
    }
}

/// The controller pairing window (T-203).
impl<B: Bluez> Bluetooth<B> {
    /// `ControllerPairingState`.
    pub fn pairing_state(&self) -> PairingState {
        self.lock().pairing
    }

    /// When the open window has to be closed, if one is open.
    pub fn window_deadline(&self) -> Option<Instant> {
        self.lock().window.as_ref().map(|w| w.until)
    }

    /// Called when something changed that no D-Bus call announces (the agent refused a device).
    pub fn set_notifier(&self, notifier: Notifier) {
        *self.notifier.lock().unwrap_or_else(|e| e.into_inner()) = Some(notifier);
    }

    /// Changes that were seen but not announced yet.
    pub fn take_pending(&self) -> Changes {
        std::mem::take(&mut self.lock().pending)
    }

    /// Runs the notifier (the D-Bus layer reads and announces what changed).
    pub fn notify(&self) {
        let notifier = self
            .notifier
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        if let Some(notify) = notifier {
            notify();
        }
    }

    /// Opens the window for `seconds` (0: the default). `allowed` is the caller check of the
    /// D-Bus layer (`pairing::caller_allowed`); nothing happens for a caller that is not.
    pub fn start_controller_pairing(&self, now: Instant, seconds: u32, allowed: bool) -> Status {
        if !allowed {
            return Status::Refused;
        }
        let length = match seconds {
            0 => DEFAULT_WINDOW,
            n => Duration::from_secs(u64::from(n)),
        };
        if length > MAX_WINDOW {
            return Status::Invalid;
        }
        if let Err(status) = self.ready_primary() {
            return status;
        }
        let (path, adapter) = {
            let mut st = self.lock();
            if st.window.is_some() || st.starting {
                return Status::Busy;
            }
            let primary = st
                .primary
                .clone()
                .and_then(|p| st.adapters.iter().find(|a| a.path == p).cloned());
            let Some(primary) = primary else {
                return Status::Unavailable;
            };
            st.starting = true;
            (primary.path, primary.state)
        };
        let status = self.open_window(now + length, length, &path, adapter);
        self.lock().starting = false;
        status
    }

    /// BlueZ's side of opening the window. The primary adapter (`path`, in the state `adapter`) is
    /// made pairable (the pad's pairing, ours or its own, needs it) but not discoverable: a pad
    /// in pairing mode advertises and is found by our scan, and a bonded pad pages us, so nobody
    /// else needs to see the console. The window remembers the adapter.
    fn open_window(
        &self,
        until: Instant,
        length: Duration,
        path: &str,
        adapter: RawAdapter,
    ) -> Status {
        // Agent first: if BlueZ refuses it nothing else has been touched.
        if let Err(e) = self.bluez.register_agent() {
            log::info(&format!("registering the pairing agent failed: {}", e.0));
            return Status::Failed;
        }
        if let Err(e) = self.set_pairable(path, true, "window") {
            log::info(&format!("Pairable on failed: {}", e.0));
            self.drop_agent();
            return Status::Failed;
        }
        // A scan of the user's own (Settings) is left alone, and left running.
        let scan_ours = !adapter.discovering
            && match self.bluez.start_discovery(path) {
                Ok(()) => true,
                Err(e) => {
                    log::info(&format!("the window's scan failed: {}", e.0));
                    false
                }
            };
        let mut st = self.lock();
        let paired_before = st
            .raw_devices
            .iter()
            .filter(|d| d.paired)
            .map(|d| d.address.clone())
            .collect();
        st.next_window += 1;
        st.window = Some(Window {
            id: st.next_window,
            until,
            adapter: path.to_owned(),
            restore_pairable: !adapter.pairable,
            scan_ours,
            paired_before,
            attempts: HashMap::new(),
            in_flight: None,
        });
        st.pairing = PairingState::Open;
        st.pending.pairing = true;
        drop(st);
        log::info(&format!(
            "pairing window opened on {} for {}",
            adapter_name(path),
            span(length)
        ));
        Status::Ok
    }

    /// Closes the window now. Also "ok" when none is open; a finished window's outcome is then
    /// forgotten (`idle`).
    pub fn stop_controller_pairing(&self, allowed: bool) -> Status {
        if !allowed {
            return Status::Refused;
        }
        if self.lock().window.is_some() {
            self.close_window(PairingState::Idle, None);
        } else if self.lock().pairing != PairingState::Idle {
            let mut st = self.lock();
            st.pairing = PairingState::Idle;
            st.pending.pairing = true;
        }
        Status::Ok
    }

    fn drop_agent(&self) {
        if let Err(e) = self.bluez.unregister_agent() {
            log::info(&format!("unregistering the pairing agent failed: {}", e.0));
        }
    }

    /// Ends the window: the scan and Pairable as they were, the agent gone. Each
    /// step is tried whatever the others did.
    fn close_window(&self, outcome: PairingState, paired: Option<&str>) {
        let Some(window) = self.lock().window.take() else {
            return;
        };
        let how = match (outcome, paired) {
            (PairingState::Paired, Some(address)) => format!("paired {}", self.label(address)),
            (PairingState::Timeout, _) => "timeout".to_owned(),
            (PairingState::Idle, _) => "stopped".to_owned(),
            (other, _) => other.as_str().to_owned(),
        };
        log::info(&format!(
            "pairing window on {} closed: {how}",
            adapter_name(&window.adapter)
        ));
        // The user's scan keeps running only when it runs on the window's own adapter: one that
        // took over on another adapter (the primary one flipped in between) is not this scan, and
        // the window's own is still its to stop.
        let user_scan_here = {
            let st = self.lock();
            st.scan_until.is_some() && st.scan_adapter.as_deref() == Some(window.adapter.as_str())
        };
        if window.scan_ours && !user_scan_here {
            if let Err(e) = self.bluez.stop_discovery(&window.adapter) {
                log::info(&format!("ending the window's scan failed: {}", e.0));
            }
        }
        if window.restore_pairable {
            if let Err(e) = self.set_pairable(&window.adapter, false, "window closed") {
                log::info(&format!("Pairable off again failed: {}", e.0));
            }
        }
        self.drop_agent();
        let mut st = self.lock();
        st.pairing = outcome;
        st.pending.pairing = true;
    }

    /// Looks at what the last read showed.
    /// - A device that is paired now and was not when the window opened is a stranger unless it
    ///   is an input device: the kernel accepts a just-works pairing by itself with our agent's
    ///   capability, so BlueZ never asks the agent and a phone could bond. Strangers are removed
    ///   again (`RemoveDevice`) and announced as refused.
    /// - An input device that paired ends the window (trusted, closed, `paired`).
    /// - Otherwise the address of a gamepad in pairing mode that the scan found is returned, for
    ///   the window to pair itself (once at a time, `MAX_ATTEMPTS` times at most): call
    ///   `window_pair` with it, off the executor.
    pub fn pump(&self) -> Option<String> {
        let (strangers, input, candidate) = {
            let mut st = self.lock();
            let State {
                window,
                raw_devices,
                ..
            } = &mut *st;
            let window = window.as_mut()?;
            let mut strangers = Vec::new();
            let mut input = None;
            for d in raw_devices
                .iter()
                .filter(|d| d.paired && !window.paired_before.contains(&d.address))
            {
                if window.in_flight.as_deref() == Some(d.address.as_str()) {
                    continue; // `window_pair` is on it
                }
                if window_accepts(d) {
                    input.get_or_insert_with(|| d.address.clone());
                } else {
                    strangers.push(d.address.clone());
                }
            }
            let mut candidate = None;
            if input.is_none() && window.in_flight.is_none() {
                candidate = raw_devices
                    .iter()
                    .find(|d| {
                        !d.paired
                            && d.adapter == window.adapter
                            && kind_of(&d.icon) == "controller"
                            && window_accepts(d)
                            && window.attempts.get(&d.address).copied().unwrap_or(0) < MAX_ATTEMPTS
                    })
                    .map(|d| d.address.clone());
                if let Some(address) = &candidate {
                    *window.attempts.entry(address.clone()).or_insert(0) += 1;
                    window.in_flight = Some(address.clone());
                }
            }
            (strangers, input, candidate)
        };
        for address in strangers {
            self.remove_stranger(&address);
        }
        if let Some(address) = input {
            self.finish(&address);
            return None;
        }
        candidate
    }

    /// Removes a device that bonded during the window and is not an input device.
    fn remove_stranger(&self, address: &str) {
        let label = self.label(address);
        let _ = self.remove_device(address, "sweep");
        log::info(&format!("refused {label}: not an input device"));
        self.lock().pending.rejected = true;
    }

    /// A controller is paired: trust it (BlueZ then lets its HID connection through) and close.
    fn finish(&self, address: &str) {
        log::info(&format!("paired {} via window", self.label(address)));
        // A failed trust is logged by `trust`.
        let _ = self.trust(address);
        self.close_window(PairingState::Paired, Some(address));
    }

    /// Pairs the gamepad `pump` named, trusts and connects it, and ends the window. Only for the
    /// pairing `pump` handed out and only while that window is open: after a stop or a timeout
    /// nothing is called. A pairing that completes after the window ended is left untrusted.
    /// A failed attempt leaves the window open (`pump` tries again, up to `MAX_ATTEMPTS`).
    /// Blocks.
    pub fn window_pair(&self, address: &str, clock: impl Fn() -> Instant) {
        let window = {
            let st = self.lock();
            match st.window.as_ref() {
                Some(w) if w.in_flight.as_deref() == Some(address) => w.id,
                _ => return,
            }
        };
        let end = clock() + CALL_TIMEOUT;
        let result = self
            .route(address)
            .and_then(|a| self.bluez.pair(&a, address, CALL_TIMEOUT));
        let open = {
            let mut st = self.lock();
            match st.window.as_mut() {
                Some(w) if w.id == window => {
                    w.in_flight = None;
                    true
                }
                _ => false,
            }
        };
        match result {
            Ok(()) if open => {
                log::info(&format!("paired {} via window", self.label(address)));
                // A failed trust is logged by `trust`; the bond is what counts.
                let _ = self.trust(address);
                let left = end.saturating_duration_since(clock());
                if !left.is_zero() {
                    // The bond is what counts; a pad that does not connect yet connects when its
                    // button is pressed. A failure is logged by `connect_device`.
                    let _ = self.connect_device(address, left, "window");
                }
                // The window may have ended while connecting: then the outcome is its own.
                if self.lock().window.as_ref().is_some_and(|w| w.id == window) {
                    self.close_window(PairingState::Paired, Some(address));
                }
            }
            Ok(()) => {
                log::info(&format!(
                    "paired {} via window after the window ended: left untrusted",
                    self.label(address)
                ));
            }
            Err(e) => log::info(&format!("pairing {address} failed: {}", e.0)),
        }
    }

    /// The agent's answer (see `AgentCall`). Only while the window is open and only for input
    /// devices; everything else is refused, and a device that is not an input device is
    /// announced as refused.
    pub fn agent(&self, call: AgentCall<'_>, now: Instant) -> bool {
        let (device, uuid) = match call {
            AgentCall::Pin => {
                // Nothing the call carried (a PIN, a passkey) is looked at, let alone logged.
                log::info("agent refused a PIN or passkey request (not offered)");
                return false;
            }
            AgentCall::Authorize { device } => (device, None),
            AgentCall::Service { device, uuid } => (device, Some(uuid)),
        };
        if !self.lock().window.as_ref().is_some_and(|w| now < w.until) {
            return false;
        }
        let Some(address) = address_of_path(device) else {
            return false;
        };
        if self.read().is_err() {
            return false;
        }
        let input = self
            .lock()
            .raw_devices
            .iter()
            .find(|d| d.address == address)
            .is_some_and(window_accepts);
        if !input {
            // Not an input device, or BlueZ has not told us about it: refused, and if it has
            // bonded anyway (the kernel accepts some pairings itself) removed again.
            let stranger = {
                let mut st = self.lock();
                let State {
                    window,
                    raw_devices,
                    ..
                } = &mut *st;
                match window.as_mut() {
                    Some(w) => {
                        raw_devices.iter().any(|d| d.address == address && d.paired)
                            && !w.paired_before.contains(&address)
                    }
                    None => false,
                }
            };
            if stranger {
                let _ = self.remove_device(&address, "agent-refused");
            }
            log::info(&format!(
                "refused {}: not an input device",
                self.label(&address)
            ));
            self.lock().pending.rejected = true;
            self.notify();
            return false;
        }
        // An input device asking for anything but an input service is refused too.
        !uuid.is_some_and(|u| !is_hid_service(u))
    }
}

impl<B: Bluez> AgentHandler for Bluetooth<B> {
    fn answer(&self, call: AgentCall<'_>) -> bool {
        self.agent(call, Instant::now())
    }
}

/// A scripted BlueZ for tests and `--session` development.
/// What a test lets happen while a call is being made.
pub type FakeHook = Box<dyn FnMut(&str) + Send>;

pub struct FakeBluez {
    inner: Mutex<FakeInner>,
}

struct FakeInner {
    raw: Raw,
    /// Error names to answer with, next call first (any call that changes something).
    fail: Vec<String>,
    /// The calls received, for the tests.
    calls: Vec<String>,
    /// The timeouts `pair` and `connect` were given.
    timeouts: Vec<Duration>,
    /// Discovery calls do not change what a snapshot says (BlueZ sets the property later).
    sticky_discovery: bool,
    /// Time that `pair` and `connect` use up on this clock.
    spend: Option<(std::sync::Arc<Mutex<Instant>>, Duration)>,
    /// `set_pairable(true)` fails (the adapter refuses).
    pairable_fails: bool,
    /// `register_agent` fails (BlueZ refuses the agent).
    agent_fails: bool,
    /// Our agent is registered with BlueZ.
    agent: bool,
    /// Run when `register_agent` or `pair` is called (with its name), before it does anything: a
    /// test lets something happen "meanwhile".
    hook: Option<FakeHook>,
    /// Which adapter (object path) each call was made through: `"connect AA:.. /org/bluez/hci1"`.
    routes: Vec<String>,
}

impl FakeBluez {
    pub fn new(raw: Raw) -> Self {
        FakeBluez {
            inner: Mutex::new(FakeInner {
                raw,
                fail: Vec::new(),
                calls: Vec::new(),
                timeouts: Vec::new(),
                sticky_discovery: false,
                spend: None,
                pairable_fails: false,
                agent_fails: false,
                agent: false,
                hook: None,
                routes: Vec::new(),
            }),
        }
    }

    /// An adapter that is on, with one paired pad and one unpaired one in range.
    pub fn with_devices() -> Self {
        let dev = |address: &str, alias: &str, icon: &str, paired: bool| RawDevice {
            address: address.to_owned(),
            alias: alias.to_owned(),
            name: alias.to_owned(),
            icon: icon.to_owned(),
            modalias: String::new(),
            paired,
            bonded: paired,
            connected: paired,
            trusted: paired,
            battery: if paired { Some(80) } else { None },
            class: Some(0x2508),
            appearance: None,
            adapter: HCI0.to_owned(),
        };
        FakeBluez::new(Raw::single(
            RawAdapter {
                powered: true,
                discovering: false,
                pairable: false,
                discoverable: false,
            },
            vec![
                dev("AA:00:00:00:00:01", "Dev Pad", "input-gaming", true),
                dev("AA:00:00:00:00:02", "Found Pad", "input-gaming", false),
            ],
        ))
    }

    /// Two adapters, like the Dell: `hci0` (not USB) holds `Dev Pad` and sees `Found Pad`;
    /// `hci1` (USB) holds two bonded pads, `Second Pad` (not connected) and `Third Pad`, so it is
    /// the primary adapter (`--session` serves this one when `RUYA_DEVICES_FAKE_BLUETOOTH` is
    /// `two-adapters`, `vm-devices-check.sh bluetooth` reads it).
    pub fn with_two_adapters() -> Self {
        let on = RawAdapter {
            powered: true,
            discovering: false,
            pairable: false,
            discoverable: false,
        };
        let dev =
            |adapter: &str, address: &str, alias: &str, paired: bool, connected: bool| RawDevice {
                address: address.to_owned(),
                alias: alias.to_owned(),
                name: alias.to_owned(),
                icon: "input-gaming".to_owned(),
                modalias: String::new(),
                paired,
                bonded: paired,
                connected,
                trusted: paired,
                battery: None,
                class: Some(0x2508),
                appearance: None,
                adapter: adapter.to_owned(),
            };
        let (hci0, hci1) = (HCI0, "/org/bluez/hci1");
        FakeBluez::new(Raw {
            adapters: vec![
                AdapterInfo {
                    path: hci0.to_owned(),
                    usb: false,
                    address: "00:11:22:33:44:00".to_owned(),
                    state: on,
                },
                AdapterInfo {
                    path: hci1.to_owned(),
                    usb: true,
                    address: "00:11:22:33:44:01".to_owned(),
                    state: on,
                },
            ],
            devices: vec![
                dev(hci0, "AA:00:00:00:00:01", "Dev Pad", true, true),
                dev(hci0, "AA:00:00:00:00:02", "Found Pad", false, false),
                dev(hci1, "AA:00:00:00:00:11", "Second Pad", true, false),
                dev(hci1, "AA:00:00:00:00:12", "Third Pad", true, true),
            ],
        })
    }

    /// Two DualSense pads that look alike (T-334): `AA:00:00:00:00:04` is paired, bonded, trusted
    /// and connected, `AA:00:00:00:00:05` is in range in pairing mode. Same alias, same `Name`,
    /// same modalias; only the address differs. `--session` serves this one when
    /// `RUYA_DEVICES_FAKE_BLUETOOTH` is `two-pads` (`vm-devices-check.sh twopads` reads it).
    pub fn with_two_pads() -> Self {
        let pad = |address: &str, paired: bool| RawDevice {
            address: address.to_owned(),
            alias: "Wireless Controller".to_owned(),
            name: "Wireless Controller".to_owned(),
            icon: "input-gaming".to_owned(),
            modalias: "usb:v054Cp0CE6d0100".to_owned(),
            paired,
            bonded: paired,
            connected: paired,
            trusted: paired,
            battery: None,
            class: Some(0x2508),
            appearance: None,
            adapter: HCI0.to_owned(),
        };
        FakeBluez::new(Raw::single(
            RawAdapter {
                powered: true,
                discovering: false,
                pairable: false,
                discoverable: false,
            },
            vec![
                pad("AA:00:00:00:00:04", true),
                pad("AA:00:00:00:00:05", false),
            ],
        ))
    }

    /// `with_devices` and a third pad that was paired before the pairing fix (`Paired: yes,
    /// Bonded: no`) and that its user renamed: its `Name` is still the model (T-300; `--session`
    /// serves this one, `vm-devices-check.sh bluetooth` reads it).
    pub fn with_old_pad() -> Self {
        let fake = Self::with_devices();
        let mut raw = fake.inner().raw.clone();
        raw.devices.push(RawDevice {
            address: "AA:00:00:00:00:03".to_owned(),
            alias: "Living room pad".to_owned(),
            name: "DualSense Wireless Controller".to_owned(),
            icon: "input-gaming".to_owned(),
            modalias: String::new(),
            paired: true,
            bonded: false,
            connected: false,
            trusted: true,
            battery: None,
            class: Some(0x2508),
            appearance: None,
            adapter: HCI0.to_owned(),
        });
        fake.set_raw(raw);
        fake
    }

    fn inner(&self) -> MutexGuard<'_, FakeInner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn set_raw(&self, raw: Raw) {
        self.inner().raw = raw;
    }

    pub fn fail_next(&self, name: &str) {
        self.inner().fail.push(name.to_owned());
    }

    pub fn timeouts(&self) -> Vec<Duration> {
        self.inner().timeouts.clone()
    }

    pub fn fail_pairable(&self) {
        self.inner().pairable_fails = true;
    }

    pub fn set_hook(&self, hook: FakeHook) {
        self.inner().hook = Some(hook);
    }

    fn run_hook(&self, what: &str) {
        // Out of the lock: the hook calls back into the core, and so into this fake.
        let hook = self.inner().hook.take();
        if let Some(mut hook) = hook {
            hook(what);
            self.inner().hook = Some(hook);
        }
    }

    pub fn fail_agent(&self) {
        self.inner().agent_fails = true;
    }

    /// Our agent is registered with BlueZ right now.
    pub fn agent_registered(&self) -> bool {
        self.inner().agent
    }

    /// What the primary adapter says now (`Raw::adapter`).
    pub fn adapter(&self) -> Option<RawAdapter> {
        self.inner().raw.adapter()
    }

    /// What the adapter with this object path says now.
    pub fn adapter_state(&self, path: &str) -> Option<RawAdapter> {
        let i = self.inner();
        i.raw
            .adapters
            .iter()
            .find(|a| a.path == path)
            .map(|a| a.state)
    }

    /// The adapter each call went through, in order (`"connect AA:.. /org/bluez/hci1"`).
    pub fn routes(&self) -> Vec<String> {
        self.inner().routes.clone()
    }

    /// A device shows up (found by the scan, or calling in).
    pub fn add_device(&self, device: RawDevice) {
        self.inner().raw.devices.push(device);
    }

    /// The remote side finishes a pairing it started (an incoming one).
    pub fn bond(&self, address: &str) {
        let mut i = self.inner();
        if let Some(d) = i.raw.devices.iter_mut().find(|d| d.address == address) {
            d.paired = true;
        }
    }

    pub fn set_sticky_discovery(&self, on: bool) {
        self.inner().sticky_discovery = on;
    }

    /// Every `pair` and `connect` call moves `clock` forward by `each`.
    pub fn spend_time(&self, clock: std::sync::Arc<Mutex<Instant>>, each: Duration) {
        self.inner().spend = Some((clock, each));
    }

    fn took(&self, timeout: Duration) {
        let mut i = self.inner();
        i.timeouts.push(timeout);
        if let Some((clock, each)) = &i.spend {
            *clock.lock().unwrap_or_else(|e| e.into_inner()) += *each;
        }
    }

    pub fn calls(&self) -> Vec<String> {
        self.inner().calls.clone()
    }

    /// One call that changes something. `via`: the adapter it goes through (`all` for a call that
    /// goes through every adapter), noted in `routes`.
    fn act(
        &self,
        call: String,
        via: &str,
        apply: impl FnOnce(&mut Raw) -> Result<(), BtError>,
    ) -> Result<(), BtError> {
        let mut i = self.inner();
        i.routes.push(format!("{call} {via}"));
        i.calls.push(call);
        if !i.fail.is_empty() {
            return Err(BtError(i.fail.remove(0)));
        }
        apply(&mut i.raw)
    }
}

/// Like BlueZ, a device is only reachable through the adapter that holds it: its object path is
/// `<adapter>/dev_<address>`. A device the fake does not know at all is left alone (as before).
fn with_device(
    raw: &mut Raw,
    adapter: &str,
    address: &str,
    f: impl FnOnce(&mut RawDevice),
) -> Result<(), BtError> {
    if let Some(d) = raw
        .devices
        .iter_mut()
        .find(|d| d.address == address && d.adapter == adapter)
    {
        f(d);
        Ok(())
    } else if raw.devices.iter().any(|d| d.address == address) {
        Err(BtError::new("org.freedesktop.DBus.Error.UnknownObject"))
    } else {
        Ok(())
    }
}

impl Bluez for FakeBluez {
    fn snapshot(&self) -> Result<Raw, BtError> {
        Ok(self.inner().raw.clone())
    }
    fn set_powered(&self, on: bool) -> Result<(), BtError> {
        self.act(format!("power {on}"), "all", |raw| {
            for a in raw.adapters.iter_mut() {
                a.state.powered = on;
                if !on {
                    a.state.discovering = false;
                }
            }
            Ok(())
        })?;
        if self.inner().raw.adapters.is_empty() {
            return Err(BtError::new("org.bluez.Error.NotReady"));
        }
        Ok(())
    }
    fn set_pairable(&self, adapter: &str, on: bool) -> Result<(), BtError> {
        // Not through `act`: a queued `fail_next` is meant for the pairing itself.
        let mut i = self.inner();
        i.calls.push(format!("pairable {on}"));
        i.routes.push(format!("pairable {on} {adapter}"));
        if on && i.pairable_fails {
            return Err(BtError::new("org.bluez.Error.Failed"));
        }
        match i.raw.adapters.iter_mut().find(|a| a.path == adapter) {
            Some(a) => {
                a.state.pairable = on;
                Ok(())
            }
            None => Err(BtError::new("org.freedesktop.DBus.Error.UnknownObject")),
        }
    }
    fn set_discoverable(&self, adapter: &str, on: bool) -> Result<(), BtError> {
        let mut i = self.inner();
        i.calls.push(format!("discoverable {on}"));
        i.routes.push(format!("discoverable {on} {adapter}"));
        match i.raw.adapters.iter_mut().find(|a| a.path == adapter) {
            Some(a) => {
                a.state.discoverable = on;
                Ok(())
            }
            None => Err(BtError::new("org.freedesktop.DBus.Error.UnknownObject")),
        }
    }
    fn register_agent(&self) -> Result<(), BtError> {
        self.run_hook("register_agent");
        let mut i = self.inner();
        i.calls.push("agent register".to_owned());
        if i.agent_fails {
            return Err(BtError::new("org.bluez.Error.Failed"));
        }
        i.agent = true;
        Ok(())
    }
    fn unregister_agent(&self) -> Result<(), BtError> {
        let mut i = self.inner();
        i.calls.push("agent unregister".to_owned());
        i.agent = false;
        Ok(())
    }
    fn start_discovery(&self, adapter: &str) -> Result<(), BtError> {
        let sticky = self.inner().sticky_discovery;
        self.act("start".to_owned(), adapter, |raw| {
            if let (Some(a), false) = (raw.adapters.iter_mut().find(|a| a.path == adapter), sticky)
            {
                a.state.discovering = true;
            }
            Ok(())
        })
    }
    fn stop_discovery(&self, adapter: &str) -> Result<(), BtError> {
        let sticky = self.inner().sticky_discovery;
        self.act("stop".to_owned(), adapter, |raw| {
            if let (Some(a), false) = (raw.adapters.iter_mut().find(|a| a.path == adapter), sticky)
            {
                a.state.discovering = false;
            }
            Ok(())
        })
    }
    fn pair(&self, adapter: &str, address: &str, timeout: Duration) -> Result<(), BtError> {
        self.run_hook("pair");
        self.took(timeout);
        self.act(format!("pair {address}"), adapter, |raw| {
            // Like BlueZ: an adapter that is not pairable pairs without keeping the key.
            let bondable = raw
                .adapters
                .iter()
                .any(|a| a.path == adapter && a.state.pairable);
            with_device(raw, adapter, address, |d| {
                d.paired = true;
                d.bonded = bondable;
            })
        })
    }
    fn set_trusted(&self, adapter: &str, address: &str) -> Result<(), BtError> {
        self.act(format!("trust {address}"), adapter, |raw| {
            with_device(raw, adapter, address, |d| d.trusted = true)
        })
    }
    fn connect(&self, adapter: &str, address: &str, timeout: Duration) -> Result<(), BtError> {
        self.took(timeout);
        self.act(format!("connect {address}"), adapter, |raw| {
            with_device(raw, adapter, address, |d| d.connected = true)
        })
    }
    fn disconnect(&self, adapter: &str, address: &str) -> Result<(), BtError> {
        self.act(format!("disconnect {address}"), adapter, |raw| {
            with_device(raw, adapter, address, |d| d.connected = false)
        })
    }
    fn remove(&self, adapter: &str, address: &str) -> Result<(), BtError> {
        self.act(format!("remove {address}"), adapter, |raw| {
            with_device(raw, adapter, address, |_| ())?;
            raw.devices
                .retain(|d| !(d.address == address && d.adapter == adapter));
            Ok(())
        })
    }
    fn set_alias(&self, adapter: &str, address: &str, alias: &str) -> Result<(), BtError> {
        self.act(format!("alias {address} {alias}"), adapter, |raw| {
            with_device(raw, adapter, address, |d| d.alias = alias.to_owned())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw_dev(address: &str, alias: &str, icon: &str, paired: bool) -> RawDevice {
        RawDevice {
            address: address.to_owned(),
            alias: alias.to_owned(),
            name: String::new(),
            icon: icon.to_owned(),
            modalias: String::new(),
            paired,
            bonded: paired,
            connected: false,
            trusted: false,
            battery: None,
            class: None,
            appearance: None,
            adapter: HCI0.to_owned(),
        }
    }

    fn bt() -> Bluetooth<FakeBluez> {
        let bt = Bluetooth::new(FakeBluez::with_devices());
        bt.refresh().expect("fake reads");
        bt
    }

    #[test]
    fn start_stop_and_tick_are_announced_as_discovering() {
        let bt = bt();
        let t0 = Instant::now();
        assert_eq!(bt.start_scan(t0), Status::Ok);
        assert!(bt.refresh().expect("reads").discovering, "start");
        assert!(!bt.refresh().expect("reads").any());
        assert_eq!(bt.stop_scan(), Status::Ok);
        assert!(bt.refresh().expect("reads").discovering, "stop");
        bt.start_scan(t0);
        bt.refresh().expect("reads");
        assert!(bt.tick(t0 + SCAN_LIMIT));
        assert!(bt.refresh().expect("reads").discovering, "tick");
    }

    #[test]
    fn a_change_read_on_the_way_is_not_lost() {
        let bt = bt();
        // pair reads BlueZ (ready, find) after it was last announced; the change stays pending
        let t = Instant::now();
        bt.pair("AA:00:00:00:00:02", move || t);
        assert!(bt.refresh().expect("reads").devices);
    }

    #[test]
    fn the_auto_stop_survives_a_stale_snapshot() {
        let bt = bt();
        bt.bluez.set_sticky_discovery(true);
        let t0 = Instant::now();
        assert_eq!(bt.start_scan(t0), Status::Ok);
        // BlueZ still says "not discovering" for a moment
        bt.refresh().expect("reads");
        bt.refresh().expect("reads");
        assert_eq!(bt.scan_deadline(), Some(t0 + SCAN_LIMIT));
        assert!(bt.tick(t0 + SCAN_LIMIT));
        assert!(bt.bluez.calls().contains(&"stop".to_owned()));
    }

    #[test]
    fn a_stop_before_bluez_reports_discovering_still_stops() {
        let bt = bt();
        bt.bluez.set_sticky_discovery(true);
        let t0 = Instant::now();
        assert_eq!(bt.start_scan(t0), Status::Ok);
        // BlueZ has not reported Discovering yet when the stop arrives
        assert_eq!(bt.stop_scan(), Status::Ok);
        assert!(
            bt.bluez.calls().contains(&"stop".to_owned()),
            "StopDiscovery was called"
        );
        assert_eq!(bt.scan_deadline(), None);
    }

    #[test]
    fn pair_and_connect_share_one_budget_under_25_seconds() {
        let bt = bt();
        let clock = std::sync::Arc::new(Mutex::new(Instant::now()));
        bt.bluez.spend_time(clock.clone(), Duration::from_secs(15));
        let c = clock.clone();
        let status = bt.pair("AA:00:00:00:00:02", move || {
            *c.lock().unwrap_or_else(|e| e.into_inner())
        });
        // pairing used 15 s of 20; connecting got the 5 s left
        assert_eq!(status, Status::Ok);
        let given = bt.bluez.timeouts();
        assert_eq!(given, [Duration::from_secs(20), Duration::from_secs(5)]);
        // worst case: connect uses all it was given, after 15 s were spent: still 20 s in all,
        // and the 2 s undo of the client keeps it under the 25 s D-Bus default
        assert!(Duration::from_secs(15) + given[1] <= CALL_TIMEOUT);
        assert!(CALL_TIMEOUT + Duration::from_secs(2) < Duration::from_secs(25));
    }

    #[test]
    fn nothing_left_for_connect_is_a_timeout() {
        let bt = bt();
        let clock = std::sync::Arc::new(Mutex::new(Instant::now()));
        bt.bluez.spend_time(clock.clone(), Duration::from_secs(20));
        let c = clock.clone();
        let status = bt.pair("AA:00:00:00:00:02", move || {
            *c.lock().unwrap_or_else(|e| e.into_inner())
        });
        assert_eq!(status, Status::Timeout);
        assert_eq!(bt.bluez.timeouts().len(), 1, "connect was not even tried");
    }

    #[test]
    fn an_idle_report_disconnects_only_connected_controllers_once() {
        let bt = Bluetooth::new(FakeBluez::with_devices());
        bt.refresh().expect("fake reads");
        let min = Duration::from_secs(60);
        let t0 = Instant::now();
        let report = |idle: u32| IdleReport::from_seconds(idle * 60, 15 * 60, false);
        // Dev Pad is connected; Found Pad is not paired. Just seen: not idle yet.
        assert!(bt.report_idle(t0, report(20)).is_empty());
        assert_eq!(
            bt.report_idle(t0 + min * 15, report(35)),
            vec!["AA:00:00:00:00:01".to_owned()]
        );
        assert_eq!(
            bt.bluez
                .calls()
                .iter()
                .filter(|c| c.starts_with("disconnect"))
                .count(),
            1
        );
        bt.refresh().expect("fake reads");
        assert!(!bt.list()[0].connected, "the fake pad is off");
        // Reported again: nothing more to do, and no second call.
        assert!(bt.report_idle(t0 + min * 16, report(36)).is_empty());
        assert_eq!(
            bt.bluez
                .calls()
                .iter()
                .filter(|c| c.starts_with("disconnect"))
                .count(),
            1
        );
    }

    #[test]
    fn the_contract_times_hold() {
        assert_eq!(SCAN_LIMIT, Duration::from_secs(30));
        // Pair/Connect must answer before the D-Bus default call timeout of 25 s.
        assert!(CALL_TIMEOUT < Duration::from_secs(25));
    }

    #[test]
    fn paired_devices_come_first_then_by_name() {
        let list = list_of(&[
            raw_dev("00:00:00:00:00:01", "Zed Pad", "input-gaming", false),
            raw_dev("00:00:00:00:00:02", "beta", "audio-headset", true),
            raw_dev("00:00:00:00:00:03", "Alpha", "input-gaming", false),
            raw_dev("00:00:00:00:00:04", "Alpha", "input-gaming", true),
            raw_dev("00:00:00:00:00:05", "Alpha", "input-gaming", true),
        ]);
        let ids: Vec<&str> = list.iter().map(|d| d.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "00:00:00:00:00:04",
                "00:00:00:00:00:05",
                "00:00:00:00:00:02",
                "00:00:00:00:00:03",
                "00:00:00:00:00:01"
            ]
        );
    }

    #[test]
    fn an_unpaired_device_without_a_name_is_not_listed() {
        let list = list_of(&[
            raw_dev("AA:BB:CC:00:11:22", "AA-BB-CC-00-11-22", "", false),
            raw_dev("AA:BB:CC:00:11:33", "AA-BB-CC-00-11-33", "", true),
        ]);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, "AA:BB:CC:00:11:33");
    }

    #[test]
    fn the_keyboard_flag_follows_the_class_the_appearance_and_the_icon() {
        let mut combo = raw_dev("A1", "Combo", "input-mouse", false);
        combo.class = Some(0x25C0);
        let mut le = raw_dev("A2", "LE Keys", "", false);
        le.appearance = Some(0x03C1);
        let by_icon = raw_dev("A3", "Icon Keys", "input-keyboard", false);
        let mut pad = raw_dev("A4", "Pad", "input-gaming", false);
        pad.class = Some(0x2508);
        let mut mouse = raw_dev("A5", "Mouse", "input-mouse", false);
        mouse.class = Some(0x2580);
        let mut headset = raw_dev("A6", "Buds", "audio-headset", false);
        headset.class = Some(0x240404);
        let flags: Vec<(String, bool)> = list_of(&[combo, le, by_icon, pad, mouse, headset])
            .into_iter()
            .map(|d| (d.id, d.keyboard))
            .collect();
        assert_eq!(
            flags,
            [
                ("A6", false),
                ("A1", true),
                ("A3", true),
                ("A2", true),
                ("A5", false),
                ("A4", false)
            ]
            .map(|(i, k)| (i.to_owned(), k))
        );
    }

    #[test]
    fn kinds_and_batteries() {
        assert_eq!(kind_of("input-gaming"), "controller");
        assert_eq!(kind_of("audio-headset"), "headset");
        assert_eq!(kind_of("audio-headphones"), "headset");
        assert_eq!(kind_of("audio-card"), "speaker");
        assert_eq!(kind_of("audio-speakers"), "speaker");
        assert_eq!(kind_of("input-keyboard"), "keyboard");
        assert_eq!(kind_of("input-mouse"), "mouse");
        assert_eq!(kind_of("phone"), "phone");
        // Anything else BlueZ knows (a computer, a printer, a tablet) and a device with no Icon.
        assert_eq!(kind_of("computer"), "other");
        assert_eq!(kind_of("input-tablet"), "other");
        assert_eq!(kind_of(""), "other");
        assert_eq!(battery_of(None), -1);
        assert_eq!(battery_of(Some(0)), 0);
        assert_eq!(battery_of(Some(73)), 73);
        assert_eq!(battery_of(Some(200)), 100);
    }

    fn with_modalias(mut d: RawDevice, modalias: &str) -> RawDevice {
        d.modalias = modalias.to_owned();
        d
    }

    #[test]
    fn a_controller_carries_its_family_and_nothing_else_does() {
        let list = list_of(&[
            with_modalias(
                raw_dev(
                    "AA:BB:CC:00:00:01",
                    "Wireless Controller",
                    "input-gaming",
                    true,
                ),
                "usb:v054Cp0CE6d0100",
            ),
            with_modalias(
                raw_dev(
                    "AA:BB:CC:00:00:02",
                    "Xbox Wireless Controller",
                    "input-gaming",
                    true,
                ),
                "usb:v045Ep0B13d0509",
            ),
            with_modalias(
                raw_dev("AA:BB:CC:00:00:03", "Pro Controller", "input-gaming", true),
                "usb:v057Ep2009d0001",
            ),
            with_modalias(
                raw_dev("AA:BB:CC:00:00:04", "8BitDo Pro 2", "input-gaming", true),
                "usb:v2DC8p6003d0100",
            ),
            raw_dev("AA:BB:CC:00:00:05", "Ruya Pad", "input-gaming", true),
            // The same vendor, but a headset, a keyboard and a phone: no family.
            with_modalias(
                raw_dev("AA:BB:CC:00:00:06", "WH-1000XM4", "audio-headset", true),
                "usb:v054Cp0DF3d0100",
            ),
            with_modalias(
                raw_dev(
                    "AA:BB:CC:00:00:07",
                    "Microsoft Keyboard",
                    "input-keyboard",
                    true,
                ),
                "usb:v045Ep0000d0001",
            ),
            with_modalias(
                raw_dev("AA:BB:CC:00:00:08", "Xbox phone", "phone", true),
                "usb:v045Ep0000d0001",
            ),
        ]);
        let pairs: Vec<(&str, &str, &str)> = list
            .iter()
            .map(|d| (d.id.as_str(), d.kind, d.family))
            .collect();
        // Sorted by name: 8BitDo, Microsoft Keyboard, Pro Controller, Ruya Pad, WH-1000XM4,
        // Wireless Controller, Xbox phone, Xbox Wireless Controller.
        assert_eq!(
            pairs,
            [
                ("AA:BB:CC:00:00:04", "controller", "8bitdo"),
                ("AA:BB:CC:00:00:07", "keyboard", ""),
                ("AA:BB:CC:00:00:03", "controller", "nintendo"),
                ("AA:BB:CC:00:00:05", "controller", ""),
                ("AA:BB:CC:00:00:06", "headset", ""),
                ("AA:BB:CC:00:00:01", "controller", "playstation"),
                ("AA:BB:CC:00:00:08", "phone", ""),
                ("AA:BB:CC:00:00:02", "controller", "xbox"),
            ]
        );
    }

    #[test]
    fn family_for_asks_the_table_for_controllers_only() {
        assert_eq!(
            family_for(
                "controller",
                "usb:v054Cp0CE6d0100",
                "Wireless Controller",
                "Wireless Controller"
            ),
            "playstation"
        );
        assert_eq!(
            family_for("headset", "usb:v054Cp0DF3d0100", "WH-1000XM4", "WH-1000XM4"),
            ""
        );
        assert_eq!(family_for("other", "", "DualSense", "DualSense"), "");
    }

    #[test]
    fn a_paired_device_that_is_not_bonded_says_so() {
        let mut half = raw_dev("AA:BB:CC:00:00:01", "Old pad", "input-gaming", true);
        half.bonded = false;
        let whole = raw_dev("AA:BB:CC:00:00:02", "New pad", "input-gaming", true);
        let list = list_of(&[half, whole]);
        let flags: Vec<(&str, bool, bool)> = list
            .iter()
            .map(|d| (d.id.as_str(), d.paired, d.bonded))
            .collect();
        assert_eq!(
            flags,
            [
                // Sorted by name: "New pad", "Old pad".
                ("AA:BB:CC:00:00:02", true, true),
                ("AA:BB:CC:00:00:01", true, false)
            ]
        );
    }

    #[test]
    fn the_device_name_is_bluezs_name_while_the_name_stays_the_alias() {
        let mut pad = raw_dev("AA:BB:CC:00:00:01", "Living room pad", "input-gaming", true);
        pad.name = "DualSense Wireless Controller".to_owned();
        let list = list_of(&[pad]);
        assert_eq!(list[0].name, "Living room pad");
        assert_eq!(list[0].device_name, "DualSense Wireless Controller");
    }

    #[test]
    fn the_session_fake_has_a_renamed_pad_that_is_paired_but_not_bonded() {
        let bt = Bluetooth::new(FakeBluez::with_old_pad());
        bt.refresh().expect("reads");
        let list = bt.list();
        let old = list
            .iter()
            .find(|d| d.id == "AA:00:00:00:00:03")
            .expect("listed");
        assert_eq!(old.name, "Living room pad");
        assert_eq!(old.device_name, "DualSense Wireless Controller");
        assert_eq!((old.paired, old.bonded), (true, false));
        assert_eq!(old.family, "playstation");
        let dev = list
            .iter()
            .find(|d| d.id == "AA:00:00:00:00:01")
            .expect("listed");
        assert!(dev.bonded);
    }

    #[test]
    fn a_renamed_dualsense_without_a_modalias_still_gets_playstation() {
        let mut pad = raw_dev("AA:BB:CC:00:00:01", "Living room pad", "input-gaming", true);
        pad.name = "DualSense Wireless Controller".to_owned();
        assert_eq!(list_of(&[pad.clone()])[0].family, "playstation");
        // Only the alias to go on: no family (this is what a rename used to cause).
        pad.name = String::new();
        assert_eq!(list_of(&[pad])[0].family, "");
    }

    #[test]
    fn battery_reaches_the_list() {
        let bt = bt();
        let list = bt.list();
        assert_eq!(list[0].battery, 80);
        assert_eq!(list[1].battery, -1);
    }

    #[test]
    fn every_bluez_error_name_maps_to_a_status() {
        use Status::*;
        // (name, pairing, connecting etc.)
        let table: &[(&str, bool, Status)] = &[
            ("org.bluez.Error.Failed", true, Failed),
            ("org.bluez.Error.Failed", false, Failed),
            ("org.bluez.Error.NotReady", false, Unavailable),
            ("org.bluez.Error.NotAvailable", false, Unavailable),
            ("org.bluez.Error.Blocked", false, Unavailable),
            ("org.bluez.Error.NotSupported", false, Failed),
            ("org.bluez.Error.NotPermitted", false, Failed),
            ("org.bluez.Error.NotAuthorized", false, Failed),
            ("org.bluez.Error.InvalidArguments", false, Invalid),
            ("org.bluez.Error.AlreadyExists", true, Ok),
            ("org.bluez.Error.AlreadyConnected", false, Ok),
            ("org.bluez.Error.NotConnected", false, Ok),
            ("org.bluez.Error.DoesNotExist", false, UnknownDevice),
            ("org.bluez.Error.InProgress", false, Failed),
            ("org.bluez.Error.AuthenticationFailed", true, PairingFailed),
            (
                "org.bluez.Error.AuthenticationCanceled",
                true,
                PairingFailed,
            ),
            (
                "org.bluez.Error.AuthenticationRejected",
                true,
                PairingFailed,
            ),
            ("org.bluez.Error.AuthenticationFailed", false, Failed),
            ("org.bluez.Error.AuthenticationTimeout", true, Timeout),
            (
                "org.bluez.Error.ConnectionAttemptFailed",
                true,
                PairingFailed,
            ),
            ("org.bluez.Error.Rejected", true, PairingFailed),
            ("org.bluez.Error.Canceled", true, PairingFailed),
            ("org.freedesktop.DBus.Error.NoReply", false, Timeout),
            ("org.freedesktop.DBus.Error.Timeout", true, Timeout),
            (
                "org.freedesktop.DBus.Error.ServiceUnknown",
                false,
                Unavailable,
            ),
            (
                "org.freedesktop.DBus.Error.NameHasNoOwner",
                false,
                Unavailable,
            ),
            (
                "org.freedesktop.DBus.Error.UnknownObject",
                false,
                UnknownDevice,
            ),
            (LOCAL_TIMEOUT, true, Timeout),
            ("something.Unheard.Of", true, Failed),
        ];
        for (name, pairing, want) in table {
            assert_eq!(
                map_error(name, *pairing),
                *want,
                "{name} (pairing {pairing})"
            );
        }
    }

    #[test]
    fn a_scan_ends_by_itself_after_30_seconds() {
        let bt = bt();
        let t0 = Instant::now();
        assert_eq!(bt.start_scan(t0), Status::Ok);
        bt.refresh().expect("reads");
        assert!(bt.discovering());
        assert_eq!(bt.scan_deadline(), Some(t0 + SCAN_LIMIT));
        assert!(!bt.tick(t0 + Duration::from_secs(29)));
        assert!(bt.discovering(), "still scanning at 29 s");
        assert!(bt.tick(t0 + SCAN_LIMIT));
        bt.refresh().expect("reads");
        assert!(!bt.discovering());
        assert_eq!(bt.scan_deadline(), None);
        assert!(bt.bluez.calls().contains(&"stop".to_owned()));
        // Nothing left to end.
        assert!(!bt.tick(t0 + Duration::from_secs(60)));
    }

    #[test]
    fn starting_again_moves_the_deadline_and_calls_bluez_once() {
        let bt = bt();
        let t0 = Instant::now();
        bt.start_scan(t0);
        let t1 = t0 + Duration::from_secs(10);
        assert_eq!(bt.start_scan(t1), Status::Ok);
        assert_eq!(bt.scan_deadline(), Some(t1 + SCAN_LIMIT));
        let starts = bt.bluez.calls().iter().filter(|c| *c == "start").count();
        assert_eq!(starts, 1);
        assert!(
            !bt.tick(t0 + SCAN_LIMIT),
            "the first deadline no longer counts"
        );
    }

    #[test]
    fn stop_scan_ends_it_and_clears_the_deadline() {
        let bt = bt();
        bt.start_scan(Instant::now());
        bt.refresh().expect("reads");
        assert_eq!(bt.stop_scan(), Status::Ok);
        bt.refresh().expect("reads");
        assert!(!bt.discovering());
        assert_eq!(bt.scan_deadline(), None);
        // Stopping when nothing runs is fine and calls nothing.
        let n = bt.bluez.calls().len();
        assert_eq!(bt.stop_scan(), Status::Ok);
        assert_eq!(bt.bluez.calls().len(), n);
    }

    #[test]
    fn a_scan_that_ended_in_bluez_drops_the_deadline() {
        let bt = bt();
        bt.start_scan(Instant::now());
        bt.refresh().expect("fake reads");
        bt.bluez.stop_discovery(HCI0).expect("fake");
        let changes = bt.refresh().expect("fake reads");
        assert!(changes.discovering);
        assert_eq!(bt.scan_deadline(), None);
    }

    #[test]
    fn power_off_clears_the_list_and_the_scan() {
        let bt = bt();
        bt.start_scan(Instant::now());
        assert_eq!(bt.list().len(), 2);
        let changes = bt.set_powered(false).expect("fake");
        assert!(changes.powered && changes.devices && changes.discovering);
        assert!(!bt.powered());
        assert!(bt.list().is_empty());
        assert!(!bt.discovering());
        assert_eq!(bt.scan_deadline(), None);
        // BlueZ still knows the devices; they come back when it is switched on.
        let changes = bt.set_powered(true).expect("fake");
        assert!(changes.powered && changes.devices);
        assert_eq!(bt.list().len(), 2);
    }

    #[test]
    fn a_blocked_adapter_refuses_power_on() {
        let bt = bt();
        bt.set_powered(false).expect("fake");
        bt.bluez.fail_next("org.bluez.Error.Blocked");
        assert!(bt.set_powered(true).is_err());
        assert!(!bt.powered());
    }

    #[test]
    fn without_an_adapter_everything_is_unavailable() {
        let bt = Bluetooth::new(FakeBluez::new(Raw::default()));
        assert!(!bt.powered() && !bt.discovering());
        assert_eq!(bt.start_scan(Instant::now()), Status::Unavailable);
        assert_eq!(
            bt.pair("AA:00:00:00:00:02", Instant::now),
            Status::Unavailable
        );
        assert_eq!(bt.connect("AA:00:00:00:00:01"), Status::Unavailable);
        assert_eq!(bt.forget("AA:00:00:00:00:01"), Status::UnknownDevice);
        assert!(bt.list().is_empty());
        assert!(bt.set_powered(true).is_err());
    }

    #[test]
    fn pair_pairs_trusts_and_connects() {
        let bt = bt();
        assert_eq!(bt.pair("AA:00:00:00:00:02", Instant::now), Status::Ok);
        let calls = bt.bluez.calls();
        assert_eq!(
            calls,
            [
                "pairable true",
                "pair AA:00:00:00:00:02",
                "pairable false",
                "trust AA:00:00:00:00:02",
                "connect AA:00:00:00:00:02"
            ]
        );
        bt.refresh().expect("fake reads");
        let d = bt
            .list()
            .into_iter()
            .find(|d| d.id.ends_with("02"))
            .expect("listed");
        assert!(d.paired && d.trusted && d.connected);
    }

    #[test]
    fn pair_failures_map_to_their_statuses() {
        let bt = bt();
        bt.bluez.fail_next("org.bluez.Error.AuthenticationFailed");
        assert_eq!(
            bt.pair("AA:00:00:00:00:02", Instant::now),
            Status::PairingFailed
        );
        bt.bluez.fail_next(LOCAL_TIMEOUT);
        assert_eq!(bt.pair("AA:00:00:00:00:02", Instant::now), Status::Timeout);
        assert_eq!(
            bt.pair("AA:00:00:00:00:99", Instant::now),
            Status::UnknownDevice
        );
        assert_eq!(bt.pair("", Instant::now), Status::Invalid);
    }

    #[test]
    fn pair_of_a_paired_device_skips_pairing() {
        let bt = bt();
        assert_eq!(bt.pair("AA:00:00:00:00:01", Instant::now), Status::Ok);
        let calls = bt.bluez.calls();
        assert!(!calls.iter().any(|c| c.starts_with("pair ")));
        // Nothing to bond, so the adapter is not opened for it either.
        assert!(!calls.iter().any(|c| c.starts_with("pairable")));
    }

    #[test]
    fn the_adapter_is_pairable_only_while_a_pairing_runs() {
        // A failed pairing closes it again too.
        let bt = bt();
        bt.bluez.fail_next("org.bluez.Error.AuthenticationFailed");
        assert_eq!(
            bt.pair("AA:00:00:00:00:02", Instant::now),
            Status::PairingFailed
        );
        assert_eq!(
            bt.bluez.calls(),
            ["pairable true", "pair AA:00:00:00:00:02", "pairable false"]
        );
        bt.bluez.fail_next(LOCAL_TIMEOUT);
        assert_eq!(bt.pair("AA:00:00:00:00:02", Instant::now), Status::Timeout);
        let calls = bt.bluez.calls();
        assert_eq!(calls.last().map(String::as_str), Some("pairable false"));
        let on = calls.iter().filter(|c| *c == "pairable true").count();
        let off = calls.iter().filter(|c| *c == "pairable false").count();
        assert_eq!((on, off), (2, 2));
    }

    #[test]
    fn a_refused_pairable_means_no_pairing_attempt() {
        let bt = bt();
        bt.bluez.fail_pairable();
        assert_eq!(bt.pair("AA:00:00:00:00:02", Instant::now), Status::Failed);
        assert_eq!(bt.bluez.calls(), ["pairable true"]);
    }

    #[test]
    fn connect_and_disconnect_need_a_paired_device() {
        let bt = bt();
        assert_eq!(bt.connect("AA:00:00:00:00:02"), Status::Failed);
        assert_eq!(bt.disconnect("AA:00:00:00:00:02"), Status::Failed);
        assert_eq!(bt.connect("AA:00:00:00:00:01"), Status::Ok);
        assert_eq!(bt.disconnect("AA:00:00:00:00:01"), Status::Ok);
        assert_eq!(bt.connect("nowhere"), Status::UnknownDevice);
        assert_eq!(bt.disconnect("nowhere"), Status::UnknownDevice);
        bt.bluez.fail_next(LOCAL_TIMEOUT);
        assert_eq!(bt.connect("AA:00:00:00:00:01"), Status::Timeout);
    }

    #[test]
    fn forget_removes_the_device() {
        let bt = bt();
        assert_eq!(bt.forget("AA:00:00:00:00:01"), Status::Ok);
        bt.refresh().expect("fake reads");
        assert_eq!(bt.list().len(), 1);
        assert_eq!(bt.forget("AA:00:00:00:00:01"), Status::UnknownDevice);
        assert_eq!(bt.forget(""), Status::Invalid);
    }

    #[test]
    fn rename_sets_the_alias_and_the_list_shows_it() {
        let bt = bt();
        assert_eq!(bt.rename("AA:00:00:00:00:01", "  Dad's pad  "), Status::Ok);
        assert!(bt
            .bluez
            .calls()
            .contains(&"alias AA:00:00:00:00:01 Dad's pad".to_owned()));
        assert!(bt.refresh().expect("fake reads").devices);
        assert!(bt
            .list()
            .iter()
            .any(|d| d.id == "AA:00:00:00:00:01" && d.name == "Dad's pad"));
    }

    #[test]
    fn rename_refuses_what_makes_no_name() {
        let bt = bt();
        let calls_before = bt.bluez.calls().len();
        assert_eq!(bt.rename("AA:00:00:00:00:01", "   "), Status::Invalid);
        assert_eq!(
            bt.rename("AA:00:00:00:00:01", &"x".repeat(MAX_NAME_CHARS + 1)),
            Status::Invalid
        );
        assert_eq!(bt.rename("AA:00:00:00:00:01", "a\nb"), Status::Invalid);
        assert_eq!(bt.rename("", "Pad"), Status::Invalid);
        assert_eq!(bt.rename("AA:00:00:00:00:99", "Pad"), Status::UnknownDevice);
        assert_eq!(
            bt.bluez.calls().len(),
            calls_before,
            "BlueZ was never asked"
        );
        // A device that is only found, not paired, is not renamed.
        assert_eq!(bt.rename("AA:00:00:00:00:02", "Pad"), Status::Failed);
        // Format characters are dropped: a name of nothing else is empty.
        assert_eq!(
            bt.rename("AA:00:00:00:00:01", "\u{200B}\u{202E}"),
            Status::Invalid
        );
        // The longest name still passes; so does a name with Turkish letters.
        assert_eq!(
            bt.rename("AA:00:00:00:00:01", &"ş".repeat(MAX_NAME_CHARS)),
            Status::Ok
        );
    }

    #[test]
    fn rename_drops_bidi_and_zero_width_characters_from_the_name() {
        let bt = bt();
        assert_eq!(
            bt.rename("AA:00:00:00:00:01", "\u{202E}Pad\u{200B}"),
            Status::Ok
        );
        assert!(bt
            .bluez
            .calls()
            .contains(&"alias AA:00:00:00:00:01 Pad".to_owned()));
    }

    #[test]
    fn rename_with_bluetooth_off_is_unavailable_and_a_refusal_is_failed() {
        let bt = bt();
        bt.set_powered(false).expect("fake");
        assert_eq!(bt.rename("AA:00:00:00:00:01", "Pad"), Status::Unavailable);
        bt.set_powered(true).expect("fake");
        bt.bluez.fail_next("org.bluez.Error.Failed");
        assert_eq!(bt.rename("AA:00:00:00:00:01", "Pad"), Status::Failed);
    }

    #[test]
    fn refresh_reports_what_changed() {
        let bt = bt();
        assert!(!bt.refresh().expect("fake reads").any());
        let mut raw = bt.bluez.snapshot().expect("fake");
        raw.devices[1].connected = true;
        bt.bluez.set_raw(raw);
        let c = bt.refresh().expect("fake reads");
        assert!(c.devices && !c.powered && !c.discovering);
    }

    // ---- the controller pairing window (T-203) ----

    const PAD: &str = "AA:00:00:00:00:10";
    const PHONE: &str = "AA:00:00:00:00:20";
    const HEADSET: &str = "AA:00:00:00:00:30";
    const UNKNOWN: &str = "AA:00:00:00:00:40";
    const HID: &str = "00001124-0000-1000-8000-00805f9b34fb";
    const A2DP: &str = "0000110b-0000-1000-8000-00805f9b34fb";

    fn path_of(address: &str) -> String {
        format!("/org/bluez/hci0/dev_{}", address.replace(':', "_"))
    }

    fn near(address: &str, alias: &str, icon: &str, class: Option<u32>) -> RawDevice {
        RawDevice {
            address: address.to_owned(),
            alias: alias.to_owned(),
            name: alias.to_owned(),
            icon: icon.to_owned(),
            modalias: String::new(),
            paired: false,
            bonded: false,
            connected: false,
            trusted: false,
            battery: None,
            class,
            appearance: None,
            adapter: HCI0.to_owned(),
        }
    }

    /// An adapter that is on and not pairable, with a gamepad, a phone, a headset and a device
    /// that tells nothing in range.
    fn window_bt() -> Bluetooth<FakeBluez> {
        let fake = FakeBluez::new(Raw::single(
            RawAdapter {
                powered: true,
                discovering: false,
                pairable: false,
                discoverable: false,
            },
            vec![
                near(PAD, "Wireless Controller", "input-gaming", Some(0x2508)),
                near(PHONE, "Some Phone", "phone", Some(0x5A020C)),
                near(HEADSET, "Some Buds", "audio-headset", Some(0x240404)),
                near(UNKNOWN, "Mystery", "", None),
            ],
        ));
        let bt = Bluetooth::new(fake);
        bt.refresh().expect("fake reads");
        bt
    }

    fn adapter(bt: &Bluetooth<FakeBluez>) -> RawAdapter {
        bt.bluez.adapter().expect("an adapter")
    }

    fn open(bt: &Bluetooth<FakeBluez>, now: Instant) {
        assert_eq!(bt.start_controller_pairing(now, 0, true), Status::Ok);
    }

    #[test]
    fn the_window_opens_for_120_seconds_and_closes_by_timeout() {
        let bt = window_bt();
        let t0 = Instant::now();
        assert_eq!(bt.pairing_state(), PairingState::Idle);
        open(&bt, t0);
        assert_eq!(bt.pairing_state(), PairingState::Open);
        assert_eq!(bt.window_deadline(), Some(t0 + Duration::from_secs(120)));
        // open: pairable and scanning, with our agent; never discoverable
        let a = adapter(&bt);
        assert!(a.pairable && a.discovering && !a.discoverable);
        assert!(bt.bluez.agent_registered());
        assert!(
            bt.refresh().expect("reads").pairing,
            "the open state is announced"
        );

        assert!(!bt.tick(t0 + Duration::from_secs(119)));
        assert_eq!(bt.pairing_state(), PairingState::Open);
        assert!(bt.tick(t0 + Duration::from_secs(120)));
        assert_eq!(bt.pairing_state(), PairingState::Timeout);
        assert_eq!(bt.window_deadline(), None);
        assert!(
            bt.refresh().expect("reads").pairing,
            "the timeout is announced"
        );
        // closed: all as before
        let a = adapter(&bt);
        assert!(!a.pairable && !a.discoverable && !a.discovering);
        assert!(!bt.bluez.agent_registered());
    }

    #[test]
    fn stop_closes_the_window_and_forgets_the_outcome() {
        let bt = window_bt();
        open(&bt, Instant::now());
        assert_eq!(bt.stop_controller_pairing(true), Status::Ok);
        assert_eq!(bt.pairing_state(), PairingState::Idle);
        assert_eq!(bt.window_deadline(), None);
        let a = adapter(&bt);
        assert!(!a.pairable && !a.discoverable && !a.discovering);
        assert!(!bt.bluez.agent_registered());
        // stopping again is fine and changes nothing
        let n = bt.bluez.calls().len();
        assert_eq!(bt.stop_controller_pairing(true), Status::Ok);
        assert_eq!(bt.bluez.calls().len(), n);
        // a finished window's outcome goes away with a stop
        let t0 = Instant::now();
        open(&bt, t0);
        bt.tick(t0 + Duration::from_secs(120));
        assert_eq!(bt.pairing_state(), PairingState::Timeout);
        assert_eq!(bt.stop_controller_pairing(true), Status::Ok);
        assert_eq!(bt.pairing_state(), PairingState::Idle);
    }

    #[test]
    fn a_gamepad_that_pairs_with_us_is_accepted_trusted_and_ends_the_window() {
        let bt = window_bt();
        let t0 = Instant::now();
        open(&bt, t0);
        let now = t0 + Duration::from_secs(5);
        assert!(bt.agent(
            AgentCall::Authorize {
                device: &path_of(PAD)
            },
            now
        ));
        assert!(bt.agent(
            AgentCall::Service {
                device: &path_of(PAD),
                uuid: HID
            },
            now
        ));
        // the remote side finishes the pairing
        assert_eq!(bt.pairing_state(), PairingState::Open, "not paired yet");
        bt.bluez.bond(PAD);
        bt.refresh().expect("reads");
        assert_eq!(bt.pump(), None);
        assert_eq!(bt.pairing_state(), PairingState::Paired);
        assert!(bt.bluez.calls().contains(&format!("trust {PAD}")));
        // the window is shut and the adapter is as it was
        let a = adapter(&bt);
        assert!(!a.pairable && !a.discoverable && !a.discovering);
        assert!(!bt.bluez.agent_registered());
        assert_eq!(bt.window_deadline(), None);
        assert!(bt.refresh().expect("reads").pairing);
    }

    #[test]
    fn an_le_gamepad_without_a_class_is_accepted_but_a_keyboard_is_a_stranger() {
        let bt = window_bt();
        let mut keyboard = near("AA:00:00:00:00:50", "Keys", "input-keyboard", Some(0x2540));
        keyboard.paired = false;
        let mut le_keys = near("AA:00:00:00:00:52", "LE Keys", "", None);
        le_keys.appearance = Some(0x03C1);
        le_keys.paired = false;
        let mut le_pad = near("AA:00:00:00:00:51", "LE Pad", "input-gaming", None);
        le_pad.appearance = Some(0x03C4);
        bt.bluez.add_device(keyboard);
        bt.bluez.add_device(le_keys);
        bt.bluez.add_device(le_pad);
        bt.refresh().expect("reads");
        let t0 = Instant::now();
        open(&bt, t0);
        let call = |address: &str| {
            bt.agent(
                AgentCall::Authorize {
                    device: &path_of(address),
                },
                t0,
            )
        };
        assert!(call("AA:00:00:00:00:51"), "an LE gamepad without a class");
        assert!(
            !call("AA:00:00:00:00:50"),
            "a keyboard pairs from Settings only"
        );
        assert!(!call("AA:00:00:00:00:52"), "an LE keyboard too");
    }

    #[test]
    fn audio_phones_and_unknown_devices_are_rejected_and_announced() {
        for address in [PHONE, HEADSET, UNKNOWN, "AA:00:00:00:00:99"] {
            let bt = window_bt();
            let t0 = Instant::now();
            open(&bt, t0);
            bt.refresh().expect("reads");
            assert!(
                !bt.agent(
                    AgentCall::Authorize {
                        device: &path_of(address)
                    },
                    t0
                ),
                "{address} must be refused"
            );
            assert!(
                !bt.agent(
                    AgentCall::Service {
                        device: &path_of(address),
                        uuid: HID
                    },
                    t0
                ),
                "{address} may not use an input service either"
            );
            assert!(
                bt.refresh().expect("reads").rejected,
                "{address} is announced"
            );
            assert_eq!(bt.pairing_state(), PairingState::Open, "{address}");
            assert!(bt.bluez.agent_registered());
        }
    }

    #[test]
    fn a_phone_that_bonds_anyway_is_removed_again() {
        // With NoInputNoOutput the kernel accepts a just-works pairing by itself: BlueZ never
        // asks the agent, and the phone is bonded when the window next looks.
        for address in [PHONE, HEADSET, UNKNOWN] {
            let bt = window_bt();
            let t0 = Instant::now();
            open(&bt, t0);
            bt.refresh().expect("reads");
            bt.bluez.bond(address);
            bt.refresh().expect("reads");
            assert_ne!(bt.pump().as_deref(), Some(address));
            let removed = format!("remove {address}");
            assert!(
                bt.bluez.calls().contains(&removed),
                "{address}: {:?}",
                bt.bluez.calls()
            );
            assert!(
                bt.refresh().expect("reads").rejected,
                "{address} is announced"
            );
            assert_eq!(bt.pairing_state(), PairingState::Open, "the window goes on");
            assert!(bt.bluez.agent_registered());
            // once is enough
            bt.refresh().expect("reads");
            bt.pump();
            let n = bt.bluez.calls().iter().filter(|c| **c == removed).count();
            assert_eq!(n, 1, "{address}");
        }
    }

    #[test]
    fn a_phone_that_bonds_again_is_removed_again() {
        // The kernel accepts the second tap as it did the first.
        let bt = window_bt();
        open(&bt, Instant::now());
        let removed = format!("remove {PHONE}");
        for round in 1..=3 {
            bt.bluez.bond(PHONE);
            bt.refresh().expect("reads");
            bt.pump();
            let n = bt.bluez.calls().iter().filter(|c| **c == removed).count();
            assert_eq!(n, round, "removed after bond number {round}");
            assert!(
                bt.refresh().expect("reads").rejected,
                "announced again, round {round}"
            );
            // the fake drops a removed device; it comes back, paired, as it would from the phone
            bt.bluez.add_device({
                let mut phone = near(PHONE, "Some Phone", "phone", Some(0x5A020C));
                phone.paired = true;
                phone
            });
            bt.refresh().expect("reads");
        }
        assert_eq!(bt.pairing_state(), PairingState::Open);
    }

    #[test]
    fn a_manual_pairing_is_not_closed_by_the_first_look_at_the_adapter() {
        // The first sighting of the adapter comes from pair's own read; a refresh (the watcher)
        // that runs while BlueZ pairs must not switch Pairable off under it.
        let bt = Arc::new(Bluetooth::new(FakeBluez::with_devices()));
        let b = bt.clone();
        bt.bluez.set_hook(Box::new(move |what| {
            if what == "pair" {
                b.refresh().expect("reads");
            }
        }));
        assert_eq!(bt.pair("AA:00:00:00:00:02", Instant::now), Status::Ok);
        assert_eq!(
            bt.bluez.calls(),
            [
                "pairable true",
                "pair AA:00:00:00:00:02",
                "pairable false",
                "trust AA:00:00:00:00:02",
                "connect AA:00:00:00:00:02"
            ]
        );
        // afterwards the adapter is looked at (and is already closed)
        bt.refresh().expect("reads");
    }

    #[test]
    fn a_refusing_agent_also_removes_a_device_that_bonded() {
        let bt = window_bt();
        let t0 = Instant::now();
        open(&bt, t0);
        bt.bluez.bond(PHONE);
        assert!(!bt.agent(
            AgentCall::Service {
                device: &path_of(PHONE),
                uuid: HID
            },
            t0
        ));
        assert!(bt.bluez.calls().contains(&format!("remove {PHONE}")));
    }

    #[test]
    fn a_controller_that_bonds_without_asking_the_agent_ends_the_window() {
        let bt = window_bt();
        let t0 = Instant::now();
        open(&bt, t0);
        bt.bluez.bond(PAD);
        bt.refresh().expect("reads");
        assert_eq!(bt.pump(), None);
        assert_eq!(bt.pairing_state(), PairingState::Paired);
        assert!(bt.bluez.calls().contains(&format!("trust {PAD}")));
        assert!(!bt.bluez.calls().iter().any(|c| c.starts_with("remove")));
    }

    #[test]
    fn what_was_paired_before_the_window_is_not_a_stranger() {
        let bt = window_bt();
        // a headset the user paired earlier
        let mut buds = near(
            "AA:00:00:00:00:60",
            "Old Buds",
            "audio-headset",
            Some(0x240404),
        );
        buds.paired = true;
        bt.bluez.add_device(buds);
        bt.refresh().expect("reads");
        open(&bt, Instant::now());
        bt.refresh().expect("reads");
        bt.pump();
        assert!(!bt.bluez.calls().iter().any(|c| c.starts_with("remove")));
    }

    #[test]
    fn a_device_the_user_pairs_by_hand_in_the_window_is_kept() {
        let bt = window_bt();
        open(&bt, Instant::now());
        assert_eq!(bt.pair(HEADSET, Instant::now), Status::Ok);
        bt.refresh().expect("reads");
        bt.pump();
        assert!(!bt.bluez.calls().iter().any(|c| c.starts_with("remove")));
    }

    #[test]
    fn the_window_only_pairs_a_gamepad_that_claims_an_input_class() {
        // looks like a pad by name and icon, but its class is a phone's, or it tells nothing
        for class in [Some(0x5A020C), Some(0x240404), None] {
            let bt = Bluetooth::new(FakeBluez::new(Raw::single(
                RawAdapter {
                    powered: true,
                    discovering: false,
                    pairable: false,
                    discoverable: false,
                },
                vec![near(PAD, "Pad-like", "input-gaming", class)],
            )));
            bt.refresh().expect("reads");
            open(&bt, Instant::now());
            assert_eq!(bt.pump(), None, "class {class:?}");
        }
    }

    #[test]
    fn nothing_is_accepted_that_needs_a_pin_or_a_passkey() {
        let bt = window_bt();
        open(&bt, Instant::now());
        assert!(!bt.agent(AgentCall::Pin, Instant::now()));
    }

    #[test]
    fn a_gamepad_may_not_use_an_audio_service() {
        let bt = window_bt();
        let t0 = Instant::now();
        open(&bt, t0);
        assert!(!bt.agent(
            AgentCall::Service {
                device: &path_of(PAD),
                uuid: A2DP
            },
            t0
        ));
    }

    #[test]
    fn the_agent_refuses_everything_outside_the_window() {
        let bt = window_bt();
        let t0 = Instant::now();
        let ask = |now| {
            bt.agent(
                AgentCall::Authorize {
                    device: &path_of(PAD),
                },
                now,
            )
        };
        assert!(!ask(t0), "never opened");
        open(&bt, t0);
        assert!(ask(t0 + Duration::from_secs(119)));
        assert!(
            !ask(t0 + Duration::from_secs(120)),
            "time is up, even before the tick closed it"
        );
        bt.tick(t0 + Duration::from_secs(120));
        assert!(!ask(t0 + Duration::from_secs(121)), "closed");
        assert!(!bt.agent(
            AgentCall::Authorize {
                device: "/not/a/device"
            },
            t0
        ));
    }

    #[test]
    fn only_one_window_at_a_time() {
        let bt = window_bt();
        let t0 = Instant::now();
        open(&bt, t0);
        let calls = bt.bluez.calls().len();
        assert_eq!(
            bt.start_controller_pairing(t0 + Duration::from_secs(60), 300, true),
            Status::Busy
        );
        assert_eq!(
            bt.window_deadline(),
            Some(t0 + Duration::from_secs(120)),
            "unchanged"
        );
        assert_eq!(bt.bluez.calls().len(), calls, "BlueZ was not touched again");
        // after it ended, the next one opens
        bt.tick(t0 + Duration::from_secs(120));
        assert_eq!(
            bt.start_controller_pairing(t0 + Duration::from_secs(130), 30, true),
            Status::Ok
        );
        assert_eq!(bt.window_deadline(), Some(t0 + Duration::from_secs(160)));
        assert_eq!(bt.pairing_state(), PairingState::Open);
    }

    #[test]
    fn a_caller_that_is_not_allowed_is_refused_and_nothing_happens() {
        let bt = window_bt();
        let t0 = Instant::now();
        assert_eq!(bt.start_controller_pairing(t0, 0, false), Status::Refused);
        assert!(bt.bluez.calls().is_empty(), "BlueZ was not touched");
        assert_eq!(bt.pairing_state(), PairingState::Idle);
        assert!(!adapter(&bt).pairable);
        // and cannot close one that is open
        open(&bt, t0);
        assert_eq!(bt.stop_controller_pairing(false), Status::Refused);
        assert_eq!(bt.pairing_state(), PairingState::Open);
        assert!(bt.bluez.agent_registered());
        assert_eq!(Status::Refused.as_str(), "refused");
        assert_eq!(Status::Busy.as_str(), "busy");
    }

    #[test]
    fn the_length_is_checked() {
        let bt = window_bt();
        let t0 = Instant::now();
        assert_eq!(bt.start_controller_pairing(t0, 301, true), Status::Invalid);
        assert!(bt.bluez.calls().is_empty());
        assert_eq!(bt.start_controller_pairing(t0, 300, true), Status::Ok);
        assert_eq!(bt.window_deadline(), Some(t0 + Duration::from_secs(300)));
    }

    #[test]
    fn without_bluetooth_the_window_is_unavailable() {
        let bt = window_bt();
        bt.set_powered(false).expect("fake");
        let n = bt.bluez.calls().len();
        assert_eq!(
            bt.start_controller_pairing(Instant::now(), 0, true),
            Status::Unavailable
        );
        assert_eq!(bt.bluez.calls().len(), n);
        let none = Bluetooth::new(FakeBluez::new(Raw::default()));
        assert_eq!(
            none.start_controller_pairing(Instant::now(), 0, true),
            Status::Unavailable
        );
    }

    #[test]
    fn pairable_is_given_back_as_it_was_and_discoverable_is_never_touched() {
        // it was off: off again, whatever ended the window
        for end in ["timeout", "stop", "paired"] {
            let bt = window_bt();
            let t0 = Instant::now();
            open(&bt, t0);
            match end {
                "timeout" => {
                    bt.tick(t0 + Duration::from_secs(120));
                }
                "stop" => {
                    bt.stop_controller_pairing(true);
                }
                _ => {
                    bt.bluez.bond(PAD);
                    bt.refresh().expect("reads");
                    bt.pump();
                }
            }
            let a = adapter(&bt);
            assert!(!a.pairable && !a.discoverable, "{end}");
            assert!(!bt.bluez.agent_registered(), "{end}");
            assert!(
                !bt.bluez
                    .calls()
                    .iter()
                    .any(|c| c.starts_with("discoverable")),
                "{end}"
            );
        }
        // it was on: left on
        let bt = window_bt();
        bt.bluez.set_pairable(HCI0, true).expect("fake");
        bt.refresh().expect("reads");
        open(&bt, Instant::now());
        bt.stop_controller_pairing(true);
        assert!(adapter(&bt).pairable);
    }

    #[test]
    fn an_adapter_found_pairable_or_discoverable_is_closed_once() {
        // a service that crashed inside a window left it open
        let bt = Bluetooth::new(FakeBluez::new(Raw::single(
            RawAdapter {
                powered: true,
                discovering: false,
                pairable: true,
                discoverable: true,
            },
            Vec::new(),
        )));
        bt.refresh().expect("reads");
        assert_eq!(bt.bluez.calls(), ["pairable false", "discoverable false"]);
        let a = adapter(&bt);
        assert!(!a.pairable && !a.discoverable);
        // later changes (a pairing in progress, the window) are not undone behind their back
        bt.bluez.set_pairable(HCI0, true).expect("fake");
        let n = bt.bluez.calls().len();
        bt.refresh().expect("reads");
        assert_eq!(bt.bluez.calls().len(), n);
    }

    #[test]
    fn a_refused_agent_or_pairable_leaves_nothing_behind() {
        let bt = window_bt();
        bt.bluez.fail_agent();
        assert_eq!(
            bt.start_controller_pairing(Instant::now(), 0, true),
            Status::Failed
        );
        assert_eq!(bt.pairing_state(), PairingState::Idle);
        assert_eq!(
            bt.bluez.calls(),
            ["agent register"],
            "nothing else was touched"
        );

        let bt = window_bt();
        bt.bluez.fail_pairable();
        assert_eq!(
            bt.start_controller_pairing(Instant::now(), 0, true),
            Status::Failed
        );
        assert!(
            !bt.bluez.agent_registered(),
            "the agent is taken away again"
        );
        assert!(!adapter(&bt).discoverable);
        assert_eq!(bt.window_deadline(), None);
    }

    #[test]
    fn a_scan_of_the_users_own_keeps_running_after_the_window() {
        let bt = window_bt();
        let t0 = Instant::now();
        assert_eq!(bt.start_scan(t0), Status::Ok);
        bt.refresh().expect("reads");
        open(&bt, t0);
        assert!(!bt.bluez.calls().iter().any(|c| c == "stop"));
        bt.stop_controller_pairing(true);
        bt.refresh().expect("reads");
        assert!(
            bt.discovering(),
            "the user's scan was not the window's to stop"
        );
        // and the window's own scan survives a StopScan from the shell
        let bt = window_bt();
        open(&bt, t0);
        assert_eq!(bt.stop_scan(), Status::Ok);
        assert!(adapter(&bt).discovering, "the window still scans");
        bt.stop_controller_pairing(true);
        assert!(!adapter(&bt).discovering);
    }

    #[test]
    fn a_manual_pairing_does_not_close_pairable_under_the_window() {
        let bt = window_bt();
        open(&bt, Instant::now());
        assert_eq!(bt.pair(PAD, Instant::now), Status::Ok);
        assert!(adapter(&bt).pairable, "the window still holds it");
        let calls = bt.bluez.calls();
        assert_eq!(calls.iter().filter(|c| *c == "pairable false").count(), 0);
        assert_eq!(calls.iter().filter(|c| *c == "pairable true").count(), 1);
    }

    #[test]
    fn a_gamepad_found_in_pairing_mode_is_paired_by_the_window() {
        let bt = window_bt();
        let t0 = Instant::now();
        assert_eq!(bt.pump(), None, "no window, nothing to do");
        open(&bt, t0);
        // only the gamepad is a candidate: not the phone, the headset or the unknown device
        assert_eq!(bt.pump().as_deref(), Some(PAD));
        assert_eq!(bt.pump(), None, "one at a time");
        bt.window_pair(PAD, Instant::now);
        let calls = bt.bluez.calls();
        for want in [
            format!("pair {PAD}"),
            format!("trust {PAD}"),
            format!("connect {PAD}"),
        ] {
            assert!(calls.contains(&want), "{want} in {calls:?}");
        }
        assert!(!calls
            .iter()
            .any(|c| c.contains(PHONE) || c.contains(HEADSET)));
        assert_eq!(bt.pairing_state(), PairingState::Paired);
        let a = adapter(&bt);
        assert!(!a.pairable && !a.discoverable && !a.discovering);
        assert!(!bt.bluez.agent_registered());
        assert_eq!(bt.pump(), None);
    }

    #[test]
    fn a_failing_pairing_is_tried_a_few_times_and_leaves_the_window_open() {
        let bt = window_bt();
        open(&bt, Instant::now());
        for _ in 0..MAX_ATTEMPTS {
            assert_eq!(bt.pump().as_deref(), Some(PAD));
            bt.bluez.fail_next("org.bluez.Error.AuthenticationFailed");
            bt.window_pair(PAD, Instant::now);
            assert_eq!(bt.pairing_state(), PairingState::Open);
        }
        assert_eq!(bt.pump(), None, "enough");
        assert!(bt.bluez.agent_registered());
        assert!(!bt.bluez.calls().iter().any(|c| c.starts_with("trust")));
    }

    #[test]
    fn a_keyboard_in_range_is_not_paired_by_the_window_itself() {
        // Keyboards need a passkey; only gamepads are paired from our side.
        let bt = Bluetooth::new(FakeBluez::new(Raw::single(
            RawAdapter {
                powered: true,
                discovering: false,
                pairable: false,
                discoverable: false,
            },
            vec![near(PAD, "Keys", "input-keyboard", Some(0x2540))],
        )));
        bt.refresh().expect("reads");
        open(&bt, Instant::now());
        assert_eq!(bt.pump(), None);
    }

    fn no_pairing_calls(bt: &Bluetooth<FakeBluez>) {
        let calls = bt.bluez.calls();
        for what in ["pair ", "trust ", "connect "] {
            assert!(
                !calls.iter().any(|c| c.starts_with(what)),
                "no {what}call: {calls:?}"
            );
        }
    }

    #[test]
    fn a_pairing_handed_out_does_nothing_once_the_window_ended() {
        // the pump handed out the pad, then the window ended before window_pair ran
        for end in ["stop", "timeout"] {
            let bt = window_bt();
            let t0 = Instant::now();
            open(&bt, t0);
            assert_eq!(bt.pump().as_deref(), Some(PAD));
            if end == "stop" {
                bt.stop_controller_pairing(true);
            } else {
                bt.tick(t0 + Duration::from_secs(120));
            }
            bt.window_pair(PAD, Instant::now);
            no_pairing_calls(&bt);
            assert_ne!(bt.pairing_state(), PairingState::Paired, "{end}");
        }
        // an address the pump did not hand out is not paired either
        let bt = window_bt();
        open(&bt, Instant::now());
        bt.window_pair(PAD, Instant::now);
        bt.window_pair(PHONE, Instant::now);
        no_pairing_calls(&bt);
    }

    #[test]
    fn a_pairing_that_completes_after_the_window_ended_is_not_trusted() {
        let bt = Arc::new(window_bt());
        let t0 = Instant::now();
        open(&bt, t0);
        assert_eq!(bt.pump().as_deref(), Some(PAD));
        // the window is stopped while BlueZ is pairing
        let b = bt.clone();
        bt.bluez.set_hook(Box::new(move |what| {
            if what == "pair" {
                b.stop_controller_pairing(true);
            }
        }));
        bt.window_pair(PAD, Instant::now);
        let calls = bt.bluez.calls();
        assert!(calls.contains(&format!("pair {PAD}")));
        assert!(!calls.iter().any(|c| c.starts_with("trust")), "{calls:?}");
        assert!(!calls.iter().any(|c| c.starts_with("connect")), "{calls:?}");
        assert_eq!(
            bt.pairing_state(),
            PairingState::Idle,
            "the stop's outcome stays"
        );
    }

    #[test]
    fn a_second_start_while_the_first_is_opening_is_busy() {
        let bt = Arc::new(window_bt());
        let t0 = Instant::now();
        let b = bt.clone();
        let during = Arc::new(Mutex::new(None));
        let d = during.clone();
        bt.bluez.set_hook(Box::new(move |what| {
            if what == "register_agent" {
                *d.lock().unwrap_or_else(|e| e.into_inner()) =
                    Some(b.start_controller_pairing(t0, 0, true));
            }
        }));
        assert_eq!(bt.start_controller_pairing(t0, 0, true), Status::Ok);
        assert_eq!(
            *during.lock().unwrap_or_else(|e| e.into_inner()),
            Some(Status::Busy)
        );
        let registered = bt
            .bluez
            .calls()
            .iter()
            .filter(|c| *c == "agent register")
            .count();
        assert_eq!(registered, 1, "BlueZ was asked once");
        // and the flag is gone again afterwards
        bt.stop_controller_pairing(true);
        assert_eq!(bt.start_controller_pairing(t0, 0, true), Status::Ok);
    }

    #[test]
    fn the_notifier_runs_when_the_agent_refuses() {
        let bt = window_bt();
        let seen = Arc::new(Mutex::new(0));
        let s = seen.clone();
        bt.set_notifier(Arc::new(move || {
            *s.lock().unwrap_or_else(|e| e.into_inner()) += 1
        }));
        let t0 = Instant::now();
        open(&bt, t0);
        bt.agent(
            AgentCall::Authorize {
                device: &path_of(PAD),
            },
            t0,
        );
        assert_eq!(
            *seen.lock().unwrap_or_else(|e| e.into_inner()),
            0,
            "a gamepad is no news"
        );
        bt.agent(
            AgentCall::Authorize {
                device: &path_of(PHONE),
            },
            t0,
        );
        assert_eq!(*seen.lock().unwrap_or_else(|e| e.into_inner()), 1);
        // the handler seam BlueZ's agent object uses
        let handler: &dyn AgentHandler = &bt;
        assert!(handler.answer(AgentCall::Authorize {
            device: &path_of(PAD)
        }));
    }

    // T-336: more than one adapter. `FakeBluez::with_two_adapters`: hci0 (not USB) holds Dev
    // Pad and sees Found Pad, hci1 (USB) holds Second Pad and Third Pad.
    const HCI1: &str = "/org/bluez/hci1";
    const SECOND: &str = "AA:00:00:00:00:11";

    fn two() -> Bluetooth<FakeBluez> {
        let bt = Bluetooth::new(FakeBluez::with_two_adapters());
        bt.refresh().expect("fake reads");
        bt
    }

    fn adapter_info(path: &str, usb: bool) -> AdapterInfo {
        AdapterInfo {
            path: path.to_owned(),
            usb,
            address: String::new(),
            state: RawAdapter {
                powered: true,
                discovering: false,
                pairable: false,
                discoverable: false,
            },
        }
    }

    fn on(adapter: &str, address: &str, paired: bool) -> RawDevice {
        RawDevice {
            adapter: adapter.to_owned(),
            ..raw_dev(address, "Pad", "input-gaming", paired)
        }
    }

    #[test]
    fn the_list_says_which_adapter_holds_each_device() {
        let bt = two();
        let adapter_of = |id: &str| {
            bt.list()
                .into_iter()
                .find(|d| d.id == id)
                .map(|d| d.adapter)
        };
        assert_eq!(adapter_of("AA:00:00:00:00:01").as_deref(), Some("hci0"));
        assert_eq!(adapter_of(SECOND).as_deref(), Some("hci1"));
    }

    #[test]
    fn a_device_on_the_second_adapter_connects_through_the_second_adapter() {
        let bt = two();
        assert_eq!(bt.connect(SECOND), Status::Ok);
        assert!(bt
            .bluez
            .routes()
            .contains(&format!("connect {SECOND} {HCI1}")));
        bt.refresh().expect("reads");
        assert!(bt.list().iter().any(|d| d.id == SECOND && d.connected));
        // and a device of the first one through the first
        assert_eq!(bt.disconnect("AA:00:00:00:00:01"), Status::Ok);
        assert!(bt
            .bluez
            .routes()
            .contains(&format!("disconnect AA:00:00:00:00:01 {HCI0}")));
    }

    #[test]
    fn forget_removes_from_the_adapter_that_holds_the_device() {
        let bt = two();
        assert_eq!(bt.forget(SECOND), Status::Ok);
        assert!(bt
            .bluez
            .routes()
            .contains(&format!("remove {SECOND} {HCI1}")));
        let ids: Vec<_> = bt.bluez.snapshot().expect("fake").devices;
        assert!(!ids.iter().any(|d| d.address == SECOND));
        assert!(
            ids.iter().any(|d| d.address == "AA:00:00:00:00:01"),
            "the other adapter's pad stays"
        );
    }

    #[test]
    fn rename_and_trust_use_the_devices_adapter() {
        let bt = two();
        assert_eq!(bt.rename(SECOND, "Couch pad"), Status::Ok);
        assert!(bt
            .bluez
            .routes()
            .contains(&format!("alias {SECOND} Couch pad {HCI1}")));
        bt.refresh().expect("reads");
        assert!(bt
            .list()
            .iter()
            .any(|d| d.id == SECOND && d.name == "Couch pad"));
        // pairing a new pad that hci1 sees: pair, trust and connect all go through hci1
        let new = "AA:00:00:00:00:13";
        bt.bluez.add_device(on(HCI1, new, false));
        assert_eq!(bt.pair(new, Instant::now), Status::Ok);
        let routes = bt.bluez.routes();
        for call in ["pair", "trust", "connect"] {
            assert!(
                routes.contains(&format!("{call} {new} {HCI1}")),
                "{call}: {routes:?}"
            );
        }
    }

    #[test]
    fn the_primary_adapter_has_the_most_paired_devices_then_usb_then_lowest_number() {
        let a = |path: &str, usb| adapter_info(path, usb);
        // most paired devices wins over USB and over the lower number
        let adapters = [a(HCI0, true), a(HCI1, false)];
        let devices = [
            on(HCI1, "AA:00:00:00:00:21", true),
            on(HCI1, "AA:00:00:00:00:22", true),
            on(HCI0, "AA:00:00:00:00:23", true),
            on(HCI0, "AA:00:00:00:00:24", false),
        ];
        assert_eq!(primary_index(&adapters, &devices), Some(1));
        // a tie: the USB-attached one
        let adapters = [a(HCI0, false), a(HCI1, true)];
        assert_eq!(primary_index(&adapters, &[]), Some(1));
        // a tie in both: the lowest number, numerically (hci2 before hci10), in any order
        let adapters = [a("/org/bluez/hci10", true), a("/org/bluez/hci2", true)];
        assert_eq!(primary_index(&adapters, &[]), Some(1));
        let adapters = [a(HCI1, false), a(HCI0, false)];
        assert_eq!(primary_index(&adapters, &[]), Some(1));
        assert_eq!(primary_index(&[], &[]), None);
    }

    #[test]
    fn a_device_two_adapters_have_seen_is_listed_once_under_the_one_that_holds_it() {
        let seen = |adapter, paired| on(adapter, "AA:00:00:00:00:31", paired);
        let merged = merge_devices(vec![seen(HCI0, false), seen(HCI1, true)], HCI0);
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].adapter, HCI1, "paired beats primary");
        let merged = merge_devices(vec![seen(HCI1, false), seen(HCI0, false)], HCI0);
        assert_eq!(merged[0].adapter, HCI0, "else the primary adapter");
        let connected = RawDevice {
            connected: true,
            ..seen(HCI1, true)
        };
        let merged = merge_devices(vec![seen(HCI0, true), connected], HCI0);
        assert_eq!(merged[0].adapter, HCI1, "connected beats paired");
    }

    #[test]
    fn the_window_and_scan_use_the_primary_adapter_only() {
        let bt = two();
        assert_eq!(bt.start_scan(Instant::now()), Status::Ok);
        assert_eq!(
            bt.start_controller_pairing(Instant::now(), 0, true),
            Status::Ok
        );
        let hci1 = bt.bluez.adapter_state(HCI1).expect("hci1");
        let hci0 = bt.bluez.adapter_state(HCI0).expect("hci0");
        assert!(hci1.pairable, "the window opens the primary");
        assert!(
            !hci0.pairable && !hci0.discovering && !hci0.discoverable,
            "the other adapter is left alone: {hci0:?}"
        );
        assert_eq!(bt.stop_controller_pairing(true), Status::Ok);
        assert_eq!(bt.stop_scan(), Status::Ok);
        let routes = bt.bluez.routes();
        for r in routes.iter().filter(|r| {
            r.starts_with("pairable") || r.starts_with("start") || r.starts_with("stop")
        }) {
            assert!(r.ends_with(HCI1), "{r}");
        }
        assert!(routes.iter().any(|r| r.starts_with("start ")));
        assert!(!bt.bluez.adapter_state(HCI1).expect("hci1").pairable);
    }

    #[test]
    fn the_order_of_adapters_flipping_changes_nothing_for_a_bonded_pad() {
        let fake = FakeBluez::with_two_adapters();
        let mut raw = fake.snapshot().expect("fake");
        // the order of the bus: hci1 first
        raw.adapters.reverse();
        raw.devices.reverse();
        fake.set_raw(raw.clone());
        let bt = Bluetooth::new(fake);
        bt.refresh().expect("reads");
        assert_eq!(bt.connect(SECOND), Status::Ok);
        assert!(bt
            .bluez
            .routes()
            .contains(&format!("connect {SECOND} {HCI1}")));
        // the kernel numbers the two adapters the other way round on the next boot
        let swap = |path: &str| (if path == HCI0 { HCI1 } else { HCI0 }).to_owned();
        for a in raw.adapters.iter_mut() {
            a.path = swap(&a.path);
        }
        for d in raw.devices.iter_mut() {
            d.adapter = swap(&d.adapter);
        }
        bt.bluez.set_raw(raw);
        bt.refresh().expect("reads");
        assert_eq!(bt.forget(SECOND), Status::Ok, "now it sits under hci0");
        assert!(bt
            .bluez
            .routes()
            .contains(&format!("remove {SECOND} {HCI0}")));
        assert_eq!(
            bt.bluez
                .snapshot()
                .expect("fake")
                .primary()
                .map(|a| a.path.clone()),
            Some(HCI0.to_owned()),
            "the adapter with the pads is still the primary one"
        );
    }

    #[test]
    fn power_off_switches_every_adapter() {
        let bt = two();
        bt.set_powered(false).expect("off");
        for path in [HCI0, HCI1] {
            assert!(
                !bt.bluez.adapter_state(path).expect("adapter").powered,
                "{path}"
            );
        }
        assert!(!bt.powered());
        assert!(bt.list().is_empty());
        bt.set_powered(true).expect("on");
        for path in [HCI0, HCI1] {
            assert!(
                bt.bluez.adapter_state(path).expect("adapter").powered,
                "{path}"
            );
        }
        assert!(bt.powered());
    }

    #[test]
    fn powered_is_any_adapter_on() {
        let fake = FakeBluez::with_two_adapters();
        let mut raw = fake.snapshot().expect("fake");
        raw.adapters[0].state.powered = false;
        fake.set_raw(raw);
        let bt = Bluetooth::new(fake);
        bt.refresh().expect("reads");
        assert!(bt.powered(), "the pads on hci1 work, so Bluetooth is on");
        assert!(!bt.list().is_empty());
    }

    #[test]
    fn a_device_in_the_list_is_never_unreachable() {
        let bt = two();
        let listed = bt.list();
        assert!(listed.len() >= 4);
        for d in listed {
            let status = if d.paired {
                bt.connect(&d.id)
            } else {
                bt.pair(&d.id, Instant::now)
            };
            assert_eq!(status, Status::Ok, "{} on {}", d.id, d.adapter);
        }
    }

    #[test]
    fn a_device_that_came_after_the_last_read_is_looked_up_again() {
        let bt = two();
        let late = "AA:00:00:00:00:41";
        bt.bluez.add_device(on(HCI1, late, true));
        assert!(!bt.list().iter().any(|d| d.id == late));
        assert_eq!(bt.route(late), Ok(HCI1.to_owned()));
        assert_eq!(
            bt.route("AA:00:00:00:00:99"),
            Err(BtError::new("org.bluez.Error.DoesNotExist"))
        );
        assert_eq!(bt.forget("AA:00:00:00:00:99"), Status::UnknownDevice);
    }

    /// hci0 gets the most paired devices, so it becomes the primary adapter (a pad forgotten
    /// elsewhere, or a dongle with more bonds plugged in).
    fn flip_primary_to_hci0(bt: &Bluetooth<FakeBluez>) {
        let mut raw = bt.bluez.snapshot().expect("fake");
        for d in raw.devices.iter_mut().filter(|d| d.adapter == HCI1) {
            d.paired = false;
            d.bonded = false;
        }
        bt.bluez.set_raw(raw);
        bt.refresh().expect("reads");
        assert_eq!(
            bt.bluez
                .snapshot()
                .expect("fake")
                .primary()
                .map(|a| a.path.clone()),
            Some(HCI0.to_owned()),
            "the primary adapter flipped"
        );
    }

    #[test]
    fn a_manual_pairing_opens_pairable_on_the_adapter_it_pairs_through() {
        // Found Pad is in range of hci0, which is not the primary adapter.
        let bt = two();
        let found = "AA:00:00:00:00:02";
        assert_eq!(bt.pair(found, Instant::now), Status::Ok);
        let routes = bt.bluez.routes();
        let at = |what: String| routes.iter().position(|r| *r == what);
        let open = at(format!("pairable true {HCI0}")).expect("opened on hci0");
        let pair = at(format!("pair {found} {HCI0}")).expect("paired on hci0");
        let shut = at(format!("pairable false {HCI0}")).expect("closed on hci0");
        assert!(open < pair && pair < shut, "{routes:?}");
        assert!(
            !routes.iter().any(|r| r == &format!("pairable true {HCI1}")),
            "the primary adapter is not touched: {routes:?}"
        );
        let raw = bt.bluez.snapshot().expect("fake");
        let pad = raw
            .devices
            .iter()
            .find(|d| d.address == found)
            .expect("pad");
        assert!(
            pad.paired && pad.bonded,
            "the keys are kept (not 'No Bonding')"
        );
    }

    #[test]
    fn a_primary_flip_mid_window_still_closes_the_adapter_that_was_opened() {
        let bt = two();
        assert_eq!(bt.start_scan(Instant::now()), Status::Ok);
        bt.stop_scan();
        assert_eq!(
            bt.start_controller_pairing(Instant::now(), 0, true),
            Status::Ok
        );
        assert!(bt.bluez.adapter_state(HCI1).expect("hci1").pairable);
        flip_primary_to_hci0(&bt);
        assert_eq!(bt.stop_controller_pairing(true), Status::Ok);
        for path in [HCI0, HCI1] {
            let a = bt.bluez.adapter_state(path).expect("adapter");
            assert!(!a.pairable, "{path} is not left pairable");
            assert!(!a.discovering, "{path} is not left scanning");
        }
        let routes = bt.bluez.routes();
        assert!(
            routes.contains(&format!("pairable false {HCI1}")),
            "{routes:?}"
        );
        assert!(
            !routes.contains(&format!("pairable false {HCI0}")),
            "{routes:?}"
        );
    }

    #[test]
    fn a_scan_is_stopped_on_the_adapter_it_started_on() {
        let bt = two();
        assert_eq!(bt.start_scan(Instant::now()), Status::Ok);
        assert!(bt.bluez.adapter_state(HCI1).expect("hci1").discovering);
        flip_primary_to_hci0(&bt);
        assert_eq!(bt.stop_scan(), Status::Ok);
        assert!(!bt.bluez.adapter_state(HCI1).expect("hci1").discovering);
        assert!(bt.bluez.routes().contains(&format!("stop {HCI1}")));
    }

    #[test]
    fn the_window_pairs_only_a_pad_under_its_own_adapter() {
        let bt = two();
        assert_eq!(
            bt.start_controller_pairing(Instant::now(), 0, true),
            Status::Ok
        );
        // the pad in range of hci0 is not offered: hci0 is not pairable
        assert_eq!(bt.pump(), None);
        let mut pad = on(HCI1, "AA:00:00:00:00:51", false);
        pad.class = Some(0x2508);
        pad.alias = "Wireless Controller".to_owned();
        bt.bluez.add_device(pad);
        bt.refresh().expect("reads");
        assert_eq!(bt.pump(), Some("AA:00:00:00:00:51".to_owned()));
    }

    #[test]
    fn every_adapter_found_pairable_is_closed_once() {
        let fake = FakeBluez::with_two_adapters();
        let mut raw = fake.snapshot().expect("fake");
        for a in raw.adapters.iter_mut() {
            a.state.pairable = true;
            a.state.discoverable = true;
        }
        fake.set_raw(raw);
        let bt = Bluetooth::new(fake);
        bt.refresh().expect("reads");
        for path in [HCI0, HCI1] {
            let a = bt.bluez.adapter_state(path).expect("adapter");
            assert!(!a.pairable && !a.discoverable, "{path}");
        }
        assert_eq!(bt.bluez.calls().len(), 4);
    }

    // ---- T-359: late adapters, scan ownership, one primary ----

    /// hci0 alone first; hci1 (USB, with its pads) joins later, as a dongle plugged in would.
    fn with_late_second_adapter(second_is_open: bool) -> Bluetooth<FakeBluez> {
        let fake = FakeBluez::with_two_adapters();
        let full = fake.snapshot().expect("fake");
        let mut first = full.clone();
        first.adapters.truncate(1);
        first.devices.retain(|d| d.adapter == HCI0);
        fake.set_raw(first);
        let bt = Bluetooth::new(fake);
        bt.refresh().expect("reads");
        let mut raw = full;
        for a in raw.adapters.iter_mut().skip(1) {
            a.state.pairable = second_is_open;
            a.state.discoverable = second_is_open;
        }
        bt.bluez.set_raw(raw);
        bt
    }

    #[test]
    fn a_late_adapter_gets_the_secure_pairable_setup() {
        let bt = with_late_second_adapter(true);
        log::take();
        bt.refresh().expect("reads");
        let late = bt.bluez.adapter_state(HCI1).expect("hci1");
        assert!(
            !late.pairable && !late.discoverable,
            "the adapter that came later is closed too: {late:?}"
        );
        let lines = log::take();
        assert!(
            has(&lines, &["hci1 Pairable off", "adapter appeared"]),
            "{lines:?}"
        );
        // and it is done once: nothing more to close on the next look
        let calls = bt.bluez.calls().len();
        bt.refresh().expect("reads");
        assert_eq!(bt.bluez.calls().len(), calls);
    }

    #[test]
    fn an_adapter_that_left_and_came_back_is_secured_again() {
        let bt = two();
        let mut raw = bt.bluez.snapshot().expect("fake");
        let mut back = raw.clone();
        raw.adapters.clear();
        raw.devices.clear();
        bt.bluez.set_raw(raw);
        bt.refresh().expect("reads");
        // BlueZ came back with its defaults: pairable
        for a in back.adapters.iter_mut() {
            a.state.pairable = true;
        }
        bt.bluez.set_raw(back);
        bt.refresh().expect("reads");
        for path in [HCI0, HCI1] {
            assert!(!bt.bluez.adapter_state(path).expect("adapter").pairable);
        }
    }

    #[test]
    fn the_window_scan_stops_on_its_own_adapter_after_a_primary_flip() {
        let bt = two();
        // the user's scan runs on hci1, then hci0 becomes the primary adapter and the window
        // opens there with a scan of its own
        assert_eq!(bt.start_scan(Instant::now()), Status::Ok);
        assert!(bt.bluez.adapter_state(HCI1).expect("hci1").discovering);
        flip_primary_to_hci0(&bt);
        assert_eq!(
            bt.start_controller_pairing(Instant::now(), 0, true),
            Status::Ok
        );
        assert!(
            bt.bluez.adapter_state(HCI0).expect("hci0").discovering,
            "the window scans on its own adapter"
        );
        assert_eq!(bt.stop_controller_pairing(true), Status::Ok);
        assert!(
            !bt.bluez.adapter_state(HCI0).expect("hci0").discovering,
            "the window's scan is stopped on hci0 although a scan of the user's runs"
        );
        assert!(
            bt.bluez.adapter_state(HCI1).expect("hci1").discovering,
            "the user's scan on hci1 goes on"
        );
        assert!(bt.scan_deadline().is_some());
    }

    #[test]
    fn a_users_scan_on_the_windows_adapter_outlives_the_window() {
        let bt = two();
        assert_eq!(
            bt.start_controller_pairing(Instant::now(), 0, true),
            Status::Ok
        );
        assert_eq!(bt.start_scan(Instant::now()), Status::Ok);
        assert_eq!(bt.stop_controller_pairing(true), Status::Ok);
        assert!(
            bt.bluez.adapter_state(HCI1).expect("hci1").discovering,
            "the user asked for this scan on the same adapter"
        );
    }

    /// hci1 (the primary: it holds the most pads) is off, hci0 is on.
    fn primary_off_other_on() -> Bluetooth<FakeBluez> {
        let fake = FakeBluez::with_two_adapters();
        let mut raw = fake.snapshot().expect("fake");
        raw.adapters[1].state.powered = false;
        fake.set_raw(raw);
        let bt = Bluetooth::new(fake);
        bt.refresh().expect("reads");
        assert!(bt.powered(), "hci0 is on");
        bt
    }

    #[test]
    fn start_scan_is_unavailable_when_only_a_non_primary_adapter_is_on() {
        let bt = primary_off_other_on();
        assert_eq!(bt.start_scan(Instant::now()), Status::Unavailable);
        assert!(!bt.bluez.calls().iter().any(|c| c.starts_with("start")));
        assert_eq!(bt.scan_deadline(), None);
        // the others that start something on the primary adapter say the same
        assert_eq!(
            bt.start_controller_pairing(Instant::now(), 0, true),
            Status::Unavailable
        );
        assert_eq!(
            bt.pair("AA:00:00:00:00:02", Instant::now),
            Status::Unavailable
        );
        assert!(!bt.bluez.calls().iter().any(|c| c.starts_with("pairable")));
        // a pad that is paired on the adapter that is on still connects
        assert_eq!(bt.connect("AA:00:00:00:00:01"), Status::Ok);
    }

    // ---- what the journal says (T-335, T-359) ----

    #[test]
    fn journal_label_strips_quotes_and_format_chars() {
        let mut d = raw_dev("AA:00:00:00:00:77", "Pad", "input-gaming", true);
        d.alias = "Pa\"d\u{202E}\u{200B}x\n".to_owned();
        d.adapter = HCI0.to_owned();
        assert_eq!(label_of(&d), "AA:00:00:00:00:77 \"Padx?\" (hci0)");
        // and in a real line
        let bt = Bluetooth::new(FakeBluez::with_devices());
        let mut raw = bt.bluez.snapshot().expect("fake");
        raw.devices[0].alias = "Evil\" (hci9)\u{202E}".to_owned();
        bt.bluez.set_raw(raw);
        bt.refresh().expect("reads");
        log::take();
        assert_eq!(bt.disconnect("AA:00:00:00:00:01"), Status::Ok);
        let lines = log::take();
        assert!(
            has(&lines, &["\"Evil (hci9)\" (hci0)"]),
            "one pair of quotes around the alias: {lines:?}"
        );
        assert!(!lines.iter().any(|l| l.contains('\u{202E}')), "{lines:?}");
    }

    #[test]
    fn a_radio_change_we_did_not_cause_is_logged_and_ours_is_not() {
        let bt = Bluetooth::new(FakeBluez::with_devices());
        bt.refresh().expect("reads");
        log::take();
        // rfkill (or a bluetoothctl): not us
        let mut raw = bt.bluez.snapshot().expect("fake");
        raw.adapters[0].state.powered = false;
        bt.bluez.set_raw(raw);
        bt.refresh().expect("reads");
        let lines = log::take();
        assert!(has(&lines, &["hci0 powered off", "radio"]), "{lines:?}");
        // the user switches it on: the line is "(user)", not a radio change
        bt.set_powered(true).expect("on");
        let lines = log::take();
        assert!(has(&lines, &["adapters powered on (user)"]), "{lines:?}");
        assert!(!has(&lines, &["radio"]), "{lines:?}");
    }

    #[test]
    fn pairable_that_comes_on_by_itself_is_logged() {
        let bt = Bluetooth::new(FakeBluez::with_devices());
        bt.refresh().expect("reads");
        log::take();
        // someone (or a BlueZ that started over) switched Pairable on
        let mut raw = bt.bluez.snapshot().expect("fake");
        raw.adapters[0].state.pairable = true;
        bt.bluez.set_raw(raw);
        bt.refresh().expect("reads");
        let lines = log::take();
        assert!(has(&lines, &["hci0 Pairable on: not us"]), "{lines:?}");
        bt.refresh().expect("reads");
        assert!(log::take().is_empty(), "said once, not at every read");
    }

    // ---- what the journal says (T-335) ----

    /// The lines that mention `what`.
    fn lines_with(lines: &[String], what: &str) -> Vec<String> {
        lines.iter().filter(|l| l.contains(what)).cloned().collect()
    }

    /// Some line holds every one of `parts`.
    fn has(lines: &[String], parts: &[&str]) -> bool {
        lines.iter().any(|l| parts.iter().all(|p| l.contains(p)))
    }

    #[test]
    fn window_open_and_close_are_logged_with_the_outcome() {
        let bt = window_bt();
        let t0 = Instant::now();
        log::take();
        open(&bt, t0);
        let lines = log::take();
        assert!(
            has(&lines, &["pairing window opened on hci0 for 2 min"]),
            "{lines:?}"
        );
        assert!(has(&lines, &["hci0 Pairable on: window"]), "{lines:?}");

        bt.stop_controller_pairing(true);
        let lines = log::take();
        assert!(
            has(&lines, &["pairing window on hci0 closed: stopped"]),
            "{lines:?}"
        );

        open(&bt, t0);
        log::take();
        assert!(bt.tick(t0 + Duration::from_secs(120)));
        let lines = log::take();
        assert!(
            has(&lines, &["pairing window on hci0 closed: timeout"]),
            "{lines:?}"
        );

        open(&bt, t0);
        assert_eq!(bt.pump().as_deref(), Some(PAD));
        bt.window_pair(PAD, Instant::now);
        let lines = log::take();
        assert!(
            has(
                &lines,
                &["closed: paired", PAD, "Wireless Controller", "hci0"]
            ),
            "{lines:?}"
        );
        // a length that is not whole minutes is told in seconds
        let bt = window_bt();
        log::take();
        assert_eq!(bt.start_controller_pairing(t0, 45, true), Status::Ok);
        assert!(has(&log::take(), &["opened on hci0 for 45 s"]));
    }

    #[test]
    fn a_pairing_in_the_window_logs_its_path() {
        let bt = window_bt();
        let t0 = Instant::now();
        open(&bt, t0);
        assert_eq!(bt.pump().as_deref(), Some(PAD));
        log::take();
        bt.window_pair(PAD, Instant::now);
        let lines = log::take();
        assert!(
            has(&lines, &["paired", PAD, "(hci0) via window"]),
            "{lines:?}"
        );
        assert!(has(&lines, &["trusted", PAD]), "{lines:?}");
        assert!(has(&lines, &["connect", PAD, ": window"]), "{lines:?}");

        // a pad that bonds by itself while the window is open is the window's too
        let bt = window_bt();
        open(&bt, t0);
        bt.bluez.bond(PAD);
        bt.refresh().expect("reads");
        log::take();
        assert_eq!(bt.pump(), None);
        let lines = log::take();
        assert!(has(&lines, &["paired", PAD, "via window"]), "{lines:?}");
        assert!(has(&lines, &["trusted", PAD]), "{lines:?}");

        // and the user's own pairing is "manual"
        let bt = window_bt();
        log::take();
        let t = Instant::now();
        assert_eq!(bt.pair(PAD, move || t), Status::Ok);
        let lines = log::take();
        assert!(has(&lines, &["paired", PAD, "via manual"]), "{lines:?}");
        assert!(has(&lines, &["trusted", PAD]), "{lines:?}");
        assert!(
            has(&lines, &["hci0 Pairable on: manual pairing"]),
            "{lines:?}"
        );
        assert!(has(&lines, &["connect", PAD, ": user"]), "{lines:?}");
        assert!(!has(&lines, &["via window"]), "{lines:?}");
    }

    #[test]
    fn a_pairing_that_ends_after_its_window_says_so() {
        let bt = Arc::new(window_bt());
        let t0 = Instant::now();
        open(&bt, t0);
        assert_eq!(bt.pump().as_deref(), Some(PAD));
        let b = bt.clone();
        bt.bluez.set_hook(Box::new(move |what| {
            if what == "pair" {
                b.stop_controller_pairing(true);
            }
        }));
        log::take();
        bt.window_pair(PAD, Instant::now);
        let lines = log::take();
        assert!(
            has(
                &lines,
                &["paired", PAD, "after the window ended: left untrusted"]
            ),
            "{lines:?}"
        );
        assert!(lines_with(&lines, "trusted ").is_empty(), "{lines:?}");
    }

    #[test]
    fn a_removal_logs_its_reason_sweep_and_forget() {
        // sweep: a phone bonded in the window
        let bt = window_bt();
        let t0 = Instant::now();
        open(&bt, t0);
        bt.bluez.bond(PHONE);
        bt.refresh().expect("reads");
        log::take();
        bt.pump();
        let lines = log::take();
        assert!(
            has(&lines, &["remove", PHONE, "Some Phone", ": sweep"]),
            "{lines:?}"
        );
        assert!(has(&lines, &["refused", PHONE]), "{lines:?}");

        // agent-refused: the same, found by the agent first
        let bt = window_bt();
        open(&bt, t0);
        bt.bluez.bond(PHONE);
        log::take();
        assert!(!bt.agent(
            AgentCall::Service {
                device: &path_of(PHONE),
                uuid: HID
            },
            t0
        ));
        let lines = log::take();
        assert!(
            has(&lines, &["remove", PHONE, ": agent-refused"]),
            "{lines:?}"
        );

        // forget: the user's
        let bt = Bluetooth::new(FakeBluez::with_devices());
        bt.refresh().expect("fake reads");
        log::take();
        assert_eq!(bt.forget("AA:00:00:00:00:01"), Status::Ok);
        let lines = log::take();
        assert!(
            has(
                &lines,
                &[
                    "remove",
                    "AA:00:00:00:00:01",
                    "Dev Pad",
                    "(hci0)",
                    ": forget"
                ]
            ),
            "{lines:?}"
        );
        // a removal BlueZ refuses is logged as failed, after the line with its reason
        bt.bluez.fail_next("org.bluez.Error.Failed");
        bt.forget("AA:00:00:00:00:02");
        let lines = log::take();
        assert!(has(&lines, &["remove", ": forget"]), "{lines:?}");
        assert!(
            has(&lines, &["remove", "failed: org.bluez.Error.Failed"]),
            "{lines:?}"
        );
    }

    #[test]
    fn connect_and_disconnect_log_who_asked() {
        let bt = Bluetooth::new(FakeBluez::with_devices());
        bt.refresh().expect("fake reads");
        let dev = "AA:00:00:00:00:01";
        log::take();
        assert_eq!(bt.disconnect(dev), Status::Ok);
        let lines = log::take();
        assert!(
            has(&lines, &["disconnect", dev, "Dev Pad", ": user"]),
            "{lines:?}"
        );
        bt.refresh().expect("reads");
        assert_eq!(bt.connect(dev), Status::Ok);
        let lines = log::take();
        assert!(
            has(&lines, &["connect", dev, "Dev Pad", ": user"]),
            "{lines:?}"
        );
        // a connect BlueZ refuses says why
        bt.bluez
            .fail_next("org.bluez.Error.ConnectionAttemptFailed");
        bt.connect(dev);
        let lines = log::take();
        assert!(
            has(
                &lines,
                &[
                    "connect",
                    dev,
                    "failed: org.bluez.Error.ConnectionAttemptFailed"
                ]
            ),
            "{lines:?}"
        );
        // the window's own connect says "window" (a_pairing_in_the_window_logs_its_path), the
        // idle one "idle-timeout" (idle_disconnect_logs_once_per_pad)
    }

    #[test]
    fn a_drop_we_did_not_cause_logs_link() {
        let bt = Bluetooth::new(FakeBluez::with_devices());
        bt.refresh().expect("fake reads");
        let dev = "AA:00:00:00:00:01";
        // our own disconnect and reconnect are not "link"
        assert_eq!(bt.disconnect(dev), Status::Ok);
        bt.refresh().expect("reads");
        assert_eq!(bt.connect(dev), Status::Ok);
        bt.refresh().expect("reads");
        let lines = log::take();
        assert!(!has(&lines, &["link"]), "{lines:?}");

        // the pad drops by itself (battery, range) and comes back by its button
        let mut raw = bt.bluez.snapshot().expect("reads");
        raw.devices[0].connected = false;
        bt.bluez.set_raw(raw.clone());
        bt.refresh().expect("reads");
        let lines = log::take();
        assert!(
            has(&lines, &["disconnected", dev, "Dev Pad", "(hci0): link"]),
            "{lines:?}"
        );
        raw.devices[0].connected = true;
        bt.bluez.set_raw(raw);
        bt.refresh().expect("reads");
        let lines = log::take();
        assert!(
            has(&lines, &["connected", dev, "Dev Pad", ": link"]),
            "{lines:?}"
        );
        assert!(!has(&lines, &["disconnected"]), "{lines:?}");
        // a request that changed nothing does not hide a later drop
        assert_eq!(bt.connect(dev), Status::Ok);
        let mut raw = bt.bluez.snapshot().expect("reads");
        raw.devices[0].connected = false;
        bt.bluez.set_raw(raw);
        bt.refresh().expect("reads");
        assert!(has(&log::take(), &["disconnected", dev, ": link"]));
    }

    #[test]
    fn idle_disconnect_logs_once_per_pad() {
        let bt = Bluetooth::new(FakeBluez::with_devices());
        bt.refresh().expect("fake reads");
        let min = Duration::from_secs(60);
        let t0 = Instant::now();
        let report = |idle: u32| IdleReport::from_seconds(idle * 60, 15 * 60, false);
        log::take();
        bt.report_idle(t0, report(20));
        assert!(
            log::take().is_empty(),
            "not idle long enough: nothing to say"
        );
        bt.report_idle(t0 + min * 15, report(35));
        let lines = log::take();
        let idle = lines_with(&lines, "idle-timeout");
        assert_eq!(idle.len(), 1, "{lines:?}");
        assert!(
            has(
                &idle,
                &[
                    "disconnect",
                    "AA:00:00:00:00:01",
                    "Dev Pad",
                    "idle 35 min >= 15 min"
                ]
            ),
            "{idle:?}"
        );
        bt.refresh().expect("reads");
        bt.report_idle(t0 + min * 16, report(36));
        bt.report_idle(t0 + min * 17, report(37));
        let lines = log::take();
        assert!(lines_with(&lines, "idle").is_empty(), "{lines:?}");
    }

    #[test]
    fn an_unchanged_world_logs_nothing() {
        let bt = window_bt();
        log::take();
        for _ in 0..100 {
            bt.refresh().expect("reads");
            bt.pump();
        }
        assert!(log::take().is_empty());
        // also with a window open: reading again says nothing
        let t0 = Instant::now();
        open(&bt, t0);
        log::take();
        for _ in 0..100 {
            bt.refresh().expect("reads");
            bt.tick(t0);
        }
        let lines = log::take();
        assert!(lines.is_empty(), "{lines:?}");
    }

    #[test]
    fn no_log_line_contains_a_pin_or_passkey() {
        let bt = window_bt();
        let t0 = Instant::now();
        log::take();
        open(&bt, t0);
        // BlueZ asks for a passkey (what the call carries never reaches the core), a
        // confirmation and a service; the phone bonds and is removed; the pad pairs
        assert!(!bt.agent(AgentCall::Pin, t0));
        let phone = path_of(PHONE);
        assert!(!bt.agent(AgentCall::Authorize { device: &phone }, t0));
        bt.bluez.bond(PHONE);
        assert!(!bt.agent(
            AgentCall::Service {
                device: &phone,
                uuid: A2DP
            },
            t0
        ));
        assert!(bt.agent(
            AgentCall::Authorize {
                device: &path_of(PAD)
            },
            t0
        ));
        assert_eq!(bt.pump().as_deref(), Some(PAD));
        bt.window_pair(PAD, Instant::now);
        let lines = log::take();
        assert!(has(&lines, &["agent refused a PIN or passkey request"]));
        for line in &lines {
            let l = line.to_lowercase();
            if l.contains("pin") || l.contains("passkey") || l.contains("passcode") {
                assert_eq!(
                    line, "agent refused a PIN or passkey request (not offered)",
                    "only the fixed refusal may name a PIN"
                );
            }
            assert!(!l.contains("link key") && !l.contains("linkkey"), "{line}");
        }
    }

    // ---- two controllers at once (T-334) ----
    // `FakeBluez::with_two_pads`: pad A is paired, bonded, trusted and connected; pad B is in
    // range in pairing mode. Same alias, same `Name`, same modalias; only the address differs.

    const PAD_A: &str = "AA:00:00:00:00:04";
    const PAD_B: &str = "AA:00:00:00:00:05";

    fn two_pads() -> Bluetooth<FakeBluez> {
        let bt = Bluetooth::new(FakeBluez::with_two_pads());
        bt.refresh().expect("fake reads");
        bt
    }

    fn device(bt: &Bluetooth<FakeBluez>, address: &str) -> Device {
        bt.list()
            .into_iter()
            .find(|d| d.id == address)
            .unwrap_or_else(|| panic!("{address} is not listed: {:?}", bt.list()))
    }

    fn calls_with(bt: &Bluetooth<FakeBluez>, verb: &str) -> Vec<String> {
        bt.bluez
            .calls()
            .into_iter()
            .filter(|c| c.starts_with(verb))
            .collect()
    }

    /// Pad A is as it was: paired, bonded, trusted and connected, and nothing was asked of it.
    fn assert_a_untouched(bt: &Bluetooth<FakeBluez>, since: usize) {
        bt.refresh().expect("reads");
        let a = device(bt, PAD_A);
        assert!(a.paired && a.bonded && a.connected && a.trusted, "{a:?}");
        let calls = bt.bluez.calls();
        let on_a: Vec<&String> = calls[since..]
            .iter()
            .filter(|c| c.contains(PAD_A))
            .collect();
        assert!(on_a.is_empty(), "calls that named pad A: {on_a:?}");
    }

    #[test]
    fn two_pads_with_identical_alias_and_modalias_have_two_ids() {
        let bt = two_pads();
        // Before: A is listed first (paired), B is the one in range.
        let ids: Vec<String> = bt.list().into_iter().map(|d| d.id).collect();
        assert_eq!(ids, [PAD_A, PAD_B]);
        let (a, b) = (device(&bt, PAD_A), device(&bt, PAD_B));
        assert_eq!(
            (a.name.as_str(), a.device_name.as_str(), a.family),
            ("Wireless Controller", "Wireless Controller", "playstation")
        );
        assert_eq!(
            (a.name.clone(), a.device_name.clone(), a.family),
            (b.name.clone(), b.device_name.clone(), b.family)
        );
        assert!(a.paired && !b.paired);
        // After B pairs: still two entries, still two ids, A first (paired, then name, then id).
        assert_eq!(bt.pair(PAD_B, Instant::now), Status::Ok);
        bt.refresh().expect("reads");
        let list = bt.list();
        let ids: Vec<&str> = list.iter().map(|d| d.id.as_str()).collect();
        assert_eq!(ids, [PAD_A, PAD_B]);
        assert!(list.iter().all(|d| d.paired && d.connected && d.bonded));
        assert_ne!(list[0].id, list[1].id);
    }

    #[test]
    fn two_pads_a_second_pairing_never_removes_the_first() {
        // The window pairs B by itself (pad in pairing mode), and B calling in by itself.
        for by_itself in [true, false] {
            let bt = two_pads();
            log::take();
            let t0 = Instant::now();
            open(&bt, t0);
            assert_eq!(bt.pairing_state(), PairingState::Open);
            let since = bt.bluez.calls().len();
            if by_itself {
                // A is paired: it is not a candidate, B is.
                assert_eq!(bt.pump().as_deref(), Some(PAD_B));
                bt.window_pair(PAD_B, Instant::now);
            } else {
                let b = path_of(PAD_B);
                assert!(bt.agent(AgentCall::Authorize { device: &b }, t0));
                bt.bluez.bond(PAD_B);
                bt.refresh().expect("reads");
                assert_eq!(bt.pump(), None);
            }
            assert_eq!(bt.pairing_state(), PairingState::Paired, "{by_itself}");
            assert!(
                calls_with(&bt, "remove").is_empty(),
                "{by_itself}: {:?}",
                bt.bluez.calls()
            );
            let lines = log::take();
            assert!(
                lines_with(&lines, "remove").is_empty(),
                "{by_itself}: {lines:?}"
            );
            assert!(calls_with(&bt, "disconnect").is_empty());
            // A is left as it was and was never named in a call.
            assert_a_untouched(&bt, since);
            // B ends the window paired and trusted, and there are two pads.
            let b = device(&bt, PAD_B);
            assert!(b.paired && b.trusted, "{by_itself}: {b:?}");
            assert!(calls_with(&bt, "trust").contains(&format!("trust {PAD_B}")));
            assert_eq!(bt.list().len(), 2);
            // The window is shut and the adapter as it was.
            let a = adapter(&bt);
            assert!(!a.pairable && !a.discoverable && !a.discovering);
            assert!(has(&lines, &["paired", PAD_B, "window"]), "{lines:?}");
        }
    }

    #[test]
    fn manual_pair_of_a_second_pad_leaves_the_first() {
        let bt = two_pads();
        let since = bt.bluez.calls().len();
        assert_eq!(bt.pair(PAD_B, Instant::now), Status::Ok);
        // Every pad call is about B; A is never named, removed or disconnected.
        let calls = bt.bluez.calls();
        for want in [
            format!("pair {PAD_B}"),
            format!("trust {PAD_B}"),
            format!("connect {PAD_B}"),
        ] {
            assert!(calls.contains(&want), "{want} in {calls:?}");
        }
        assert!(calls_with(&bt, "remove").is_empty() && calls_with(&bt, "disconnect").is_empty());
        assert_a_untouched(&bt, since);
        // Through the adapter that holds it, which stays closed afterwards.
        assert!(bt.bluez.routes().iter().all(|r| r.ends_with(HCI0)));
        assert!(!adapter(&bt).pairable);
        let b = device(&bt, PAD_B);
        assert!(b.paired && b.bonded && b.trusted && b.connected, "{b:?}");
    }

    #[test]
    fn forget_removes_only_the_chosen_pad() {
        // B is forgotten: A stays connected.
        let bt = two_pads();
        assert_eq!(bt.pair(PAD_B, Instant::now), Status::Ok);
        let since = bt.bluez.calls().len();
        assert_eq!(bt.forget(PAD_B), Status::Ok);
        assert_eq!(
            bt.bluez.calls()[since..],
            [format!("remove {PAD_B}")],
            "one call, about B"
        );
        assert_a_untouched(&bt, since);
        assert_eq!(
            bt.list().iter().map(|d| d.id.as_str()).collect::<Vec<_>>(),
            [PAD_A]
        );
        // And the other way round: A is forgotten, B stays.
        let bt = two_pads();
        assert_eq!(bt.pair(PAD_B, Instant::now), Status::Ok);
        let since = bt.bluez.calls().len();
        assert_eq!(bt.forget(PAD_A), Status::Ok);
        assert_eq!(bt.bluez.calls()[since..], [format!("remove {PAD_A}")]);
        bt.refresh().expect("reads");
        let b = device(&bt, PAD_B);
        assert!(b.paired && b.connected && b.trusted, "{b:?}");
        assert_eq!(bt.list().len(), 1);
    }

    #[test]
    fn connect_and_disconnect_touch_only_their_pad() {
        let bt = two_pads();
        assert_eq!(bt.pair(PAD_B, Instant::now), Status::Ok);
        let step = |bt: &Bluetooth<FakeBluez>, status: Status, call: &dyn Fn() -> Status| {
            let since = bt.bluez.calls().len();
            assert_eq!(call(), status);
            bt.refresh().expect("reads");
            bt.bluez.calls()[since..].to_vec()
        };
        // disconnect B: one call, about B; A stays connected
        let calls = step(&bt, Status::Ok, &|| bt.disconnect(PAD_B));
        assert_eq!(calls, [format!("disconnect {PAD_B}")]);
        assert!(device(&bt, PAD_A).connected && !device(&bt, PAD_B).connected);
        // connect B again: one call, about B
        let calls = step(&bt, Status::Ok, &|| bt.connect(PAD_B));
        assert_eq!(calls, [format!("connect {PAD_B}")]);
        assert!(device(&bt, PAD_A).connected && device(&bt, PAD_B).connected);
        // disconnect A: B stays connected; connect A: A only
        let calls = step(&bt, Status::Ok, &|| bt.disconnect(PAD_A));
        assert_eq!(calls, [format!("disconnect {PAD_A}")]);
        assert!(!device(&bt, PAD_A).connected && device(&bt, PAD_B).connected);
        let calls = step(&bt, Status::Ok, &|| bt.connect(PAD_A));
        assert_eq!(calls, [format!("connect {PAD_A}")]);
        assert!(device(&bt, PAD_A).connected && device(&bt, PAD_B).connected);
        // The journal says which pad each time.
        log::take();
        bt.disconnect(PAD_B);
        let lines = log::take();
        assert!(has(&lines, &["disconnect", PAD_B, ": user"]), "{lines:?}");
        assert!(!lines.iter().any(|l| l.contains(PAD_A)), "{lines:?}");
    }

    #[test]
    fn a_second_pad_paired_by_hand_in_the_window_is_bonded_and_the_first_is_left() {
        // The sequence `vm-devices-check.sh twopads` runs over D-Bus: open the window, Pair B,
        // close the window.
        let bt = two_pads();
        open(&bt, Instant::now());
        let since = bt.bluez.calls().len();
        assert_eq!(bt.pair(PAD_B, Instant::now), Status::Ok);
        assert_eq!(bt.stop_controller_pairing(true), Status::Ok);
        bt.refresh().expect("reads");
        let b = device(&bt, PAD_B);
        assert!(b.paired && b.bonded && b.trusted && b.connected, "{b:?}");
        assert_a_untouched(&bt, since);
        assert!(calls_with(&bt, "remove").is_empty());
        assert!(!adapter(&bt).pairable, "the window gave the adapter back");
    }

    /// Both pads and a phone in range, an adapter that is on and not pairable.
    fn two_pads_and_a_phone() -> Bluetooth<FakeBluez> {
        let bt = two_pads();
        bt.bluez
            .add_device(near(PHONE, "Some Phone", "phone", Some(0x5A020C)));
        bt.refresh().expect("reads");
        bt
    }

    #[test]
    fn the_sweep_spares_both_pads() {
        // 1. A paired before the window, B pairs in it, a phone bonds: only the phone goes.
        let bt = two_pads_and_a_phone();
        let t0 = Instant::now();
        open(&bt, t0);
        bt.bluez.bond(PHONE);
        bt.refresh().expect("reads");
        assert_eq!(
            bt.pump().as_deref(),
            Some(PAD_B),
            "the pad in range is next"
        );
        assert_eq!(
            calls_with(&bt, "remove"),
            [format!("remove {PHONE}")],
            "only the phone is a stranger"
        );
        assert_eq!(bt.pairing_state(), PairingState::Open, "A did not end it");
        bt.window_pair(PAD_B, Instant::now);
        assert_eq!(bt.pairing_state(), PairingState::Paired);
        assert_eq!(calls_with(&bt, "remove"), [format!("remove {PHONE}")]);
        bt.refresh().expect("reads");
        assert!(device(&bt, PAD_A).connected && device(&bt, PAD_B).paired);

        // 2. Both pads paired before the window opened: a phone bonds, a sweep runs: no pad goes.
        let bt = two_pads();
        assert_eq!(bt.pair(PAD_B, Instant::now), Status::Ok);
        bt.bluez
            .add_device(near(PHONE, "Some Phone", "phone", Some(0x5A020C)));
        bt.refresh().expect("reads");
        open(&bt, t0);
        bt.bluez.bond(PHONE);
        bt.refresh().expect("reads");
        assert_eq!(bt.pump(), None);
        for _ in 0..3 {
            bt.refresh().expect("reads");
            bt.pump();
        }
        assert_eq!(calls_with(&bt, "remove"), [format!("remove {PHONE}")]);
        assert_eq!(bt.pairing_state(), PairingState::Open, "both were known");
        let (a, b) = (device(&bt, PAD_A), device(&bt, PAD_B));
        assert!(a.paired && a.connected && b.paired && b.connected);

        // 3. Neither pad paired before the window: both bond in it. They are input devices, so
        // neither is a stranger.
        let bt = two_pads();
        bt.bluez.set_raw({
            let mut raw = bt.bluez.snapshot().expect("fake");
            let a = raw.devices.iter_mut().find(|d| d.address == PAD_A);
            let a = a.expect("pad A");
            (a.paired, a.bonded, a.connected, a.trusted) = (false, false, false, false);
            raw
        });
        bt.refresh().expect("reads");
        open(&bt, t0);
        bt.bluez.bond(PAD_A);
        bt.bluez.bond(PAD_B);
        bt.refresh().expect("reads");
        bt.pump();
        assert!(
            calls_with(&bt, "remove").is_empty(),
            "{:?}",
            bt.bluez.calls()
        );
        assert_eq!(bt.pairing_state(), PairingState::Paired);
        assert_eq!(bt.list().len(), 2);
    }

    #[test]
    fn idle_policy_counts_each_pad_from_its_own_connection_through_the_service() {
        let bt = two_pads();
        let min = Duration::from_secs(60);
        let t0 = Instant::now();
        let report = |idle: u32| IdleReport::from_seconds(idle * 60, 15 * 60, false);
        log::take();
        // t0: A is connected and just seen: nothing is due.
        assert!(bt.report_idle(t0, report(35)).is_empty());
        // 21 s before A's timeout, B connects (its pairing may be the pad's first sign of life).
        let b_at = t0 + min * 15 - Duration::from_secs(21);
        assert_eq!(bt.pair(PAD_B, Instant::now), Status::Ok);
        assert!(
            bt.report_idle(b_at, report(35)).is_empty(),
            "A has 21 s left"
        );
        // A's 15 minutes are up; B has been here for 21 s: only A is disconnected.
        let due = t0 + min * 15;
        assert_eq!(bt.report_idle(due, report(35)), [PAD_A.to_owned()]);
        assert_eq!(
            calls_with(&bt, "disconnect"),
            [format!("disconnect {PAD_A}")]
        );
        assert!(device(&bt, PAD_B).connected, "B was not touched");
        // Again, a minute later: A is gone and B is still young; nothing more, no second call.
        assert!(bt.report_idle(due + min, report(36)).is_empty());
        assert_eq!(calls_with(&bt, "disconnect").len(), 1);
        // B's own 15 minutes are up: B alone is disconnected, once.
        let b_due = b_at + min * 15;
        assert_eq!(bt.report_idle(b_due, report(50)), [PAD_B.to_owned()]);
        assert!(bt.report_idle(b_due + min, report(51)).is_empty());
        assert_eq!(
            calls_with(&bt, "disconnect"),
            [format!("disconnect {PAD_A}"), format!("disconnect {PAD_B}")]
        );
        // The journal names each pad once.
        let lines = log::take();
        let idle = lines_with(&lines, "idle-timeout");
        assert_eq!(idle.len(), 2, "{idle:?}");
        assert!(has(&idle, &["disconnect", PAD_A]) && has(&idle, &["disconnect", PAD_B]));
    }
}
