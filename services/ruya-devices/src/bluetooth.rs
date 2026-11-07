//! The Bluetooth rules of spec 03 §2.1 (org.ruyaos.Devices1.Bluetooth, T-173): the device list
//! (paired first), the scan that ends by itself after 30 s, power-off clearing the list, the
//! mapping of BlueZ's errors to the contract's statuses, and a device's battery. No I/O except
//! through the `Bluez` trait; `bluez.rs` is the system-bus side. Time is passed in.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::families::family_of;
use crate::pairing::{
    address_of_path, is_hid_service, is_input_device, PairingState, DEFAULT_WINDOW, MAX_ATTEMPTS,
    MAX_WINDOW,
};

/// A scan ends by itself after this long (the contract's `Discovering` text).
pub const SCAN_LIMIT: Duration = Duration::from_secs(30);

/// `Pair` and `Connect` answer `timeout` after this long. The D-Bus default call timeout is
/// 25 s and the shell's client uses it, so the service has to answer first.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(20);

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
pub fn family_for(kind: &str, modalias: &str, name: &str) -> &'static str {
    if kind == "controller" {
        family_of(modalias, name)
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
    pub icon: String,
    /// `Modalias` (`usb:v054Cp0CE6d0100`), "" when the device has none.
    pub modalias: String,
    pub paired: bool,
    pub connected: bool,
    pub trusted: bool,
    pub battery: Option<u8>,
    /// `Class` (Class of Device); BlueZ has none for a device seen only over Bluetooth LE.
    pub class: Option<u32>,
    /// `Appearance` (Bluetooth LE).
    pub appearance: Option<u16>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RawAdapter {
    pub powered: bool,
    pub discovering: bool,
    pub pairable: bool,
    pub discoverable: bool,
}

/// Everything the core needs from one read of BlueZ.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Raw {
    /// `None`: no adapter, or BlueZ is not there.
    pub adapter: Option<RawAdapter>,
    pub devices: Vec<RawDevice>,
}

/// A listed device (the contract's dictionary).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub kind: &'static str,
    /// "playstation" | "xbox" | "nintendo" | "" (`family_for`).
    pub family: &'static str,
    pub paired: bool,
    pub connected: bool,
    pub trusted: bool,
    pub battery: i32,
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
            kind: kind_of(&d.icon),
            family: family_for(kind_of(&d.icon), &d.modalias, &d.alias),
            paired: d.paired,
            connected: d.connected,
            trusted: d.trusted,
            battery: battery_of(d.battery),
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
    fn set_powered(&self, on: bool) -> Result<(), BtError>;
    /// The adapter's `Pairable` property. BlueZ 5.87 keeps it off, and an adapter that is not
    /// pairable answers a pairing with "No Bonding": the pairing succeeds but no link key is
    /// kept (`Bonded: no`), and BlueZ's HID plugin then rejects the pad (T-162 session, Dell).
    fn set_pairable(&self, on: bool) -> Result<(), BtError>;
    /// The adapter's `Discoverable` property. Nothing turns it on; it is switched off when the
    /// service starts, in case a crashed one left it on.
    fn set_discoverable(&self, on: bool) -> Result<(), BtError>;
    /// Registers our agent (capability `NoInputNoOutput`) as BlueZ's default one, and takes it
    /// away again. BlueZ then asks `AgentHandler` about incoming pairings. Only while the
    /// controller pairing window is open.
    fn register_agent(&self) -> Result<(), BtError>;
    fn unregister_agent(&self) -> Result<(), BtError>;
    fn start_discovery(&self) -> Result<(), BtError>;
    fn stop_discovery(&self) -> Result<(), BtError>;
    fn pair(&self, address: &str, timeout: Duration) -> Result<(), BtError>;
    fn set_trusted(&self, address: &str) -> Result<(), BtError>;
    fn connect(&self, address: &str, timeout: Duration) -> Result<(), BtError>;
    fn disconnect(&self, address: &str) -> Result<(), BtError>;
    fn remove(&self, address: &str) -> Result<(), BtError>;
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
    devices: Vec<Device>,
    /// The last read, unfiltered (the window needs the classes).
    raw_devices: Vec<RawDevice>,
    window: Option<Window>,
    next_window: u64,
    /// A start is in progress (BlueZ is being asked); a second one is `busy`.
    starting: bool,
    /// Manual pairings (`pair`) in progress: they hold `Pairable` open themselves.
    manual_pairs: u32,
    /// The adapter was made not pairable and not discoverable once (after a crash in a window).
    secured: bool,
    pairing: PairingState,
    /// When the running scan has to be stopped (only for a scan we started).
    scan_until: Option<Instant>,
    /// Changes seen by reads whose caller did not announce them (a call that read on the way);
    /// the next `refresh` reports them.
    pending: Changes,
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
}

impl<B: Bluez> Bluetooth<B> {
    pub fn new(bluez: B) -> Self {
        Bluetooth {
            bluez,
            state: Mutex::new(State::default()),
            notifier: Mutex::new(None),
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
    /// pairing. The window and `pair` open `Pairable` themselves, only for as long as they need.
    fn secure_adapter(&self) {
        let adapter = {
            let mut st = self.lock();
            if st.secured || st.window.is_some() || st.starting || st.manual_pairs > 0 {
                return;
            }
            let Some(adapter) = st.adapter else {
                return;
            };
            st.secured = true;
            adapter
        };
        if adapter.pairable {
            if let Err(e) = self.bluez.set_pairable(false) {
                eprintln!("ruya-devices: Pairable off failed: {}", e.0);
            }
        }
        if adapter.discoverable {
            if let Err(e) = self.bluez.set_discoverable(false) {
                eprintln!("ruya-devices: Discoverable off failed: {}", e.0);
            }
        }
    }

    /// Reads BlueZ and remembers what changed for the next `refresh`.
    fn read(&self) -> Result<(), BtError> {
        let raw = self.bluez.snapshot()?;
        let adapter = raw.adapter;
        let on = adapter.is_some_and(|a| a.powered);
        let devices = if on {
            list_of(&raw.devices)
        } else {
            Vec::new()
        };
        let mut st = self.lock();
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
        st.devices = devices;
        st.raw_devices = if on { raw.devices } else { Vec::new() };
        // The scan is over when BlueZ says so after having said it runs, or the adapter went
        // off. A snapshot that still shows "not discovering" right after StartDiscovery (BlueZ
        // sets the property a moment later) must not drop the deadline.
        if !on || (before.discovering && !after.discovering) {
            st.scan_until = None;
        }
        Ok(())
    }

    /// The adapter must be there and on for scanning, pairing and connecting.
    fn ready(&self) -> Result<(), Status> {
        match self.read() {
            Ok(()) if self.powered() => Ok(()),
            Ok(()) => Err(Status::Unavailable),
            Err(e) => Err(map_error(&e.0, false)),
        }
    }

    /// Powers the adapter. `Err` when BlueZ refused (no adapter, rfkill blocked): the service
    /// answers a D-Bus error.
    pub fn set_powered(&self, on: bool) -> Result<Changes, BtError> {
        // Know the adapter first: BlueZ may have just come up.
        self.read()?;
        self.bluez.set_powered(on)?;
        self.refresh()
    }

    pub fn start_scan(&self, now: Instant) -> Status {
        if let Err(status) = self.ready() {
            return status;
        }
        if !self.discovering() {
            if let Err(e) = self.bluez.start_discovery() {
                return map_error(&e.0, false);
            }
        }
        self.lock().scan_until = Some(now + SCAN_LIMIT);
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
        let status = match self.bluez.stop_discovery() {
            Ok(()) => Status::Ok,
            Err(e) => map_error(&e.0, false),
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
                if let Err(e) = self.bluez.stop_discovery() {
                    eprintln!("ruya-devices: ending the scan failed: {}", e.0);
                }
            }
            self.lock().scan_until = None;
            ended = true;
        }
        if self.lock().window.as_ref().is_some_and(|w| now >= w.until) {
            self.close_window(PairingState::Timeout);
            ended = true;
        }
        ended
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
        let dev = match self.ready_device(id) {
            Ok(d) => d,
            Err(s) => return s,
        };
        let end = clock() + CALL_TIMEOUT;
        let left = || end.saturating_duration_since(clock());
        if !dev.paired {
            // Bondable only for the pairing itself, and off again whatever it ends with. The
            // controller pairing window keeps the adapter pairable while it is open, and gives
            // it back when it closes.
            let window = {
                // A device the user pairs by hand in the window is theirs, not a stranger.
                let mut st = self.lock();
                match st.window.as_mut() {
                    Some(w) => {
                        w.paired_before.insert(dev.id.clone());
                        true
                    }
                    None => false,
                }
            };
            if !window {
                if let Err(e) = self.bluez.set_pairable(true) {
                    return map_error(&e.0, false);
                }
            }
            let paired = self.bluez.pair(&dev.id, left());
            if !window {
                if let Err(e) = self.bluez.set_pairable(false) {
                    eprintln!("ruya-devices: Pairable off again failed: {}", e.0);
                }
            }
            if let Err(e) = paired {
                return map_error(&e.0, true);
            }
        }
        if let Err(e) = self.bluez.set_trusted(&dev.id) {
            return map_error(&e.0, false);
        }
        let left = left();
        if left.is_zero() {
            return Status::Timeout;
        }
        match self.bluez.connect(&dev.id, left) {
            Ok(()) => Status::Ok,
            Err(e) => map_error(&e.0, true),
        }
    }

    pub fn connect(&self, id: &str) -> Status {
        match self.ready_device(id) {
            Ok(d) if !d.paired => Status::Failed,
            Ok(d) => match self.bluez.connect(&d.id, CALL_TIMEOUT) {
                Ok(()) => Status::Ok,
                Err(e) => map_error(&e.0, false),
            },
            Err(s) => s,
        }
    }

    pub fn disconnect(&self, id: &str) -> Status {
        match self.find(id) {
            Ok(d) if !d.paired => Status::Failed,
            Ok(d) => match self.bluez.disconnect(&d.id) {
                Ok(()) => Status::Ok,
                Err(e) => map_error(&e.0, false),
            },
            Err(s) => s,
        }
    }

    /// Disconnects and removes the pairing (BlueZ's `RemoveDevice` does both).
    pub fn forget(&self, id: &str) -> Status {
        match self.find(id) {
            Ok(d) => match self.bluez.remove(&d.id) {
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
        if let Err(status) = self.ready() {
            return status;
        }
        let adapter = {
            let mut st = self.lock();
            if st.window.is_some() || st.starting {
                return Status::Busy;
            }
            let Some(adapter) = st.adapter else {
                return Status::Unavailable;
            };
            st.starting = true;
            adapter
        };
        let status = self.open_window(now + length, adapter);
        self.lock().starting = false;
        status
    }

    /// BlueZ's side of opening the window. The adapter is made pairable (the pad's pairing, ours
    /// or its own, needs it) but not discoverable: a pad in pairing mode advertises and is found
    /// by our scan, and a bonded pad pages us, so nobody else needs to see the console.
    fn open_window(&self, until: Instant, adapter: RawAdapter) -> Status {
        // Agent first: if BlueZ refuses it nothing else has been touched.
        if let Err(e) = self.bluez.register_agent() {
            eprintln!(
                "ruya-devices: registering the pairing agent failed: {}",
                e.0
            );
            return Status::Failed;
        }
        if let Err(e) = self.bluez.set_pairable(true) {
            eprintln!("ruya-devices: Pairable on failed: {}", e.0);
            self.drop_agent();
            return Status::Failed;
        }
        // A scan of the user's own (Settings) is left alone, and left running.
        let scan_ours = !adapter.discovering
            && match self.bluez.start_discovery() {
                Ok(()) => true,
                Err(e) => {
                    eprintln!("ruya-devices: the window's scan failed: {}", e.0);
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
            restore_pairable: !adapter.pairable,
            scan_ours,
            paired_before,
            attempts: HashMap::new(),
            in_flight: None,
        });
        st.pairing = PairingState::Open;
        st.pending.pairing = true;
        Status::Ok
    }

    /// Closes the window now. Also "ok" when none is open; a finished window's outcome is then
    /// forgotten (`idle`).
    pub fn stop_controller_pairing(&self, allowed: bool) -> Status {
        if !allowed {
            return Status::Refused;
        }
        if self.lock().window.is_some() {
            self.close_window(PairingState::Idle);
        } else if self.lock().pairing != PairingState::Idle {
            let mut st = self.lock();
            st.pairing = PairingState::Idle;
            st.pending.pairing = true;
        }
        Status::Ok
    }

    fn drop_agent(&self) {
        if let Err(e) = self.bluez.unregister_agent() {
            eprintln!(
                "ruya-devices: unregistering the pairing agent failed: {}",
                e.0
            );
        }
    }

    /// Ends the window: the scan and Pairable as they were, the agent gone. Each
    /// step is tried whatever the others did.
    fn close_window(&self, outcome: PairingState) {
        let Some(window) = self.lock().window.take() else {
            return;
        };
        let user_scan = self.lock().scan_until.is_some();
        if window.scan_ours && !user_scan {
            if let Err(e) = self.bluez.stop_discovery() {
                eprintln!("ruya-devices: ending the window's scan failed: {}", e.0);
            }
        }
        if window.restore_pairable {
            if let Err(e) = self.bluez.set_pairable(false) {
                eprintln!("ruya-devices: Pairable off again failed: {}", e.0);
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
                if is_input_device(d.class, d.appearance) {
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
                            && kind_of(&d.icon) == "controller"
                            && is_input_device(d.class, d.appearance)
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
        if let Err(e) = self.bluez.remove(address) {
            eprintln!("ruya-devices: removing {address} failed: {}", e.0);
        }
        self.lock().pending.rejected = true;
    }

    /// A controller is paired: trust it (BlueZ then lets its HID connection through) and close.
    fn finish(&self, address: &str) {
        if let Err(e) = self.bluez.set_trusted(address) {
            eprintln!("ruya-devices: trusting {address} failed: {}", e.0);
        }
        self.close_window(PairingState::Paired);
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
        let result = self.bluez.pair(address, CALL_TIMEOUT);
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
                if let Err(e) = self.bluez.set_trusted(address) {
                    eprintln!("ruya-devices: trusting {address} failed: {}", e.0);
                }
                let left = end.saturating_duration_since(clock());
                if !left.is_zero() {
                    // The bond is what counts; a pad that does not connect yet connects when its
                    // button is pressed.
                    if let Err(e) = self.bluez.connect(address, left) {
                        eprintln!("ruya-devices: connecting {address} failed: {}", e.0);
                    }
                }
                // The window may have ended while connecting: then the outcome is its own.
                if self.lock().window.as_ref().is_some_and(|w| w.id == window) {
                    self.close_window(PairingState::Paired);
                }
            }
            Ok(()) => {
                eprintln!("ruya-devices: {address} paired after the window ended: not trusted")
            }
            Err(e) => eprintln!("ruya-devices: pairing {address} failed: {}", e.0),
        }
    }

    /// The agent's answer (see `AgentCall`). Only while the window is open and only for input
    /// devices; everything else is refused, and a device that is not an input device is
    /// announced as refused.
    pub fn agent(&self, call: AgentCall<'_>, now: Instant) -> bool {
        let (device, uuid) = match call {
            AgentCall::Pin => return false,
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
            .is_some_and(|d| is_input_device(d.class, d.appearance));
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
                if let Err(e) = self.bluez.remove(&address) {
                    eprintln!("ruya-devices: removing {address} failed: {}", e.0);
                }
            }
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
            }),
        }
    }

    /// An adapter that is on, with one paired pad and one unpaired one in range.
    pub fn with_devices() -> Self {
        let dev = |address: &str, alias: &str, icon: &str, paired: bool| RawDevice {
            address: address.to_owned(),
            alias: alias.to_owned(),
            icon: icon.to_owned(),
            modalias: String::new(),
            paired,
            connected: paired,
            trusted: paired,
            battery: if paired { Some(80) } else { None },
            class: Some(0x2508),
            appearance: None,
        };
        FakeBluez::new(Raw {
            adapter: Some(RawAdapter {
                powered: true,
                discovering: false,
                pairable: false,
                discoverable: false,
            }),
            devices: vec![
                dev("AA:00:00:00:00:01", "Dev Pad", "input-gaming", true),
                dev("AA:00:00:00:00:02", "Found Pad", "input-gaming", false),
            ],
        })
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

    /// What the adapter says now.
    pub fn adapter(&self) -> Option<RawAdapter> {
        self.inner().raw.adapter
    }

    /// A device shows up (found by the scan, or calling in).
    pub fn add_device(&self, device: RawDevice) {
        self.inner().raw.devices.push(device);
    }

    /// The remote side finishes a pairing it started (an incoming one).
    pub fn bond(&self, address: &str) {
        with_device(&mut self.inner().raw, address, |d| d.paired = true);
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

    fn act(&self, call: String, apply: impl FnOnce(&mut Raw)) -> Result<(), BtError> {
        let mut i = self.inner();
        i.calls.push(call);
        if !i.fail.is_empty() {
            return Err(BtError(i.fail.remove(0)));
        }
        apply(&mut i.raw);
        Ok(())
    }
}

fn with_device(raw: &mut Raw, address: &str, f: impl FnOnce(&mut RawDevice)) {
    if let Some(d) = raw.devices.iter_mut().find(|d| d.address == address) {
        f(d);
    }
}

impl Bluez for FakeBluez {
    fn snapshot(&self) -> Result<Raw, BtError> {
        Ok(self.inner().raw.clone())
    }
    fn set_powered(&self, on: bool) -> Result<(), BtError> {
        self.act(format!("power {on}"), |raw| {
            if let Some(a) = raw.adapter.as_mut() {
                a.powered = on;
                if !on {
                    a.discovering = false;
                }
            }
        })?;
        if self.inner().raw.adapter.is_none() {
            return Err(BtError::new("org.bluez.Error.NotReady"));
        }
        Ok(())
    }
    fn set_pairable(&self, on: bool) -> Result<(), BtError> {
        // Not through `act`: a queued `fail_next` is meant for the pairing itself.
        let mut i = self.inner();
        i.calls.push(format!("pairable {on}"));
        if on && i.pairable_fails {
            return Err(BtError::new("org.bluez.Error.Failed"));
        }
        if let Some(a) = i.raw.adapter.as_mut() {
            a.pairable = on;
        }
        Ok(())
    }
    fn set_discoverable(&self, on: bool) -> Result<(), BtError> {
        let mut i = self.inner();
        i.calls.push(format!("discoverable {on}"));
        if let Some(a) = i.raw.adapter.as_mut() {
            a.discoverable = on;
        }
        Ok(())
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
    fn start_discovery(&self) -> Result<(), BtError> {
        let sticky = self.inner().sticky_discovery;
        self.act("start".to_owned(), |raw| {
            if let (Some(a), false) = (raw.adapter.as_mut(), sticky) {
                a.discovering = true;
            }
        })
    }
    fn stop_discovery(&self) -> Result<(), BtError> {
        let sticky = self.inner().sticky_discovery;
        self.act("stop".to_owned(), |raw| {
            if let (Some(a), false) = (raw.adapter.as_mut(), sticky) {
                a.discovering = false;
            }
        })
    }
    fn pair(&self, address: &str, timeout: Duration) -> Result<(), BtError> {
        self.run_hook("pair");
        self.took(timeout);
        self.act(format!("pair {address}"), |raw| {
            with_device(raw, address, |d| d.paired = true);
        })
    }
    fn set_trusted(&self, address: &str) -> Result<(), BtError> {
        self.act(format!("trust {address}"), |raw| {
            with_device(raw, address, |d| d.trusted = true);
        })
    }
    fn connect(&self, address: &str, timeout: Duration) -> Result<(), BtError> {
        self.took(timeout);
        self.act(format!("connect {address}"), |raw| {
            with_device(raw, address, |d| d.connected = true);
        })
    }
    fn disconnect(&self, address: &str) -> Result<(), BtError> {
        self.act(format!("disconnect {address}"), |raw| {
            with_device(raw, address, |d| d.connected = false);
        })
    }
    fn remove(&self, address: &str) -> Result<(), BtError> {
        self.act(format!("remove {address}"), |raw| {
            raw.devices.retain(|d| d.address != address);
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
            icon: icon.to_owned(),
            modalias: String::new(),
            paired,
            connected: false,
            trusted: false,
            battery: None,
            class: None,
            appearance: None,
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
                ("AA:BB:CC:00:00:04", "controller", ""),
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
            family_for("controller", "usb:v054Cp0CE6d0100", "Wireless Controller"),
            "playstation"
        );
        assert_eq!(
            family_for("headset", "usb:v054Cp0DF3d0100", "WH-1000XM4"),
            ""
        );
        assert_eq!(family_for("other", "", "DualSense"), "");
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
        bt.bluez.stop_discovery().expect("fake");
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
            icon: icon.to_owned(),
            modalias: String::new(),
            paired: false,
            connected: false,
            trusted: false,
            battery: None,
            class,
            appearance: None,
        }
    }

    /// An adapter that is on and not pairable, with a gamepad, a phone, a headset and a device
    /// that tells nothing in range.
    fn window_bt() -> Bluetooth<FakeBluez> {
        let fake = FakeBluez::new(Raw {
            adapter: Some(RawAdapter {
                powered: true,
                discovering: false,
                pairable: false,
                discoverable: false,
            }),
            devices: vec![
                near(PAD, "Wireless Controller", "input-gaming", Some(0x2508)),
                near(PHONE, "Some Phone", "phone", Some(0x5A020C)),
                near(HEADSET, "Some Buds", "audio-headset", Some(0x240404)),
                near(UNKNOWN, "Mystery", "", None),
            ],
        });
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
    fn a_keyboard_or_an_le_gamepad_without_a_class_is_accepted_too() {
        let bt = window_bt();
        let mut keyboard = near("AA:00:00:00:00:50", "Keys", "input-keyboard", Some(0x2540));
        keyboard.paired = false;
        let mut le_pad = near("AA:00:00:00:00:51", "LE Pad", "input-gaming", None);
        le_pad.appearance = Some(0x03C4);
        bt.bluez.add_device(keyboard);
        bt.bluez.add_device(le_pad);
        bt.refresh().expect("reads");
        let t0 = Instant::now();
        open(&bt, t0);
        for address in ["AA:00:00:00:00:50", "AA:00:00:00:00:51"] {
            assert!(
                bt.agent(
                    AgentCall::Authorize {
                        device: &path_of(address)
                    },
                    t0
                ),
                "{address}"
            );
        }
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
            let bt = Bluetooth::new(FakeBluez::new(Raw {
                adapter: Some(RawAdapter {
                    powered: true,
                    discovering: false,
                    pairable: false,
                    discoverable: false,
                }),
                devices: vec![near(PAD, "Pad-like", "input-gaming", class)],
            }));
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
        bt.bluez.set_pairable(true).expect("fake");
        bt.refresh().expect("reads");
        open(&bt, Instant::now());
        bt.stop_controller_pairing(true);
        assert!(adapter(&bt).pairable);
    }

    #[test]
    fn an_adapter_found_pairable_or_discoverable_is_closed_once() {
        // a service that crashed inside a window left it open
        let bt = Bluetooth::new(FakeBluez::new(Raw {
            adapter: Some(RawAdapter {
                powered: true,
                discovering: false,
                pairable: true,
                discoverable: true,
            }),
            devices: Vec::new(),
        }));
        bt.refresh().expect("reads");
        assert_eq!(bt.bluez.calls(), ["pairable false", "discoverable false"]);
        let a = adapter(&bt);
        assert!(!a.pairable && !a.discoverable);
        // later changes (a pairing in progress, the window) are not undone behind their back
        bt.bluez.set_pairable(true).expect("fake");
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
        let bt = Bluetooth::new(FakeBluez::new(Raw {
            adapter: Some(RawAdapter {
                powered: true,
                discovering: false,
                pairable: false,
                discoverable: false,
            }),
            devices: vec![near(PAD, "Keys", "input-keyboard", Some(0x2540))],
        }));
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
}
