//! The Bluetooth rules of spec 03 §2.1 (org.ruyaos.Devices1.Bluetooth, T-173): the device list
//! (paired first), the scan that ends by itself after 30 s, power-off clearing the list, the
//! mapping of BlueZ's errors to the contract's statuses, and a device's battery. No I/O except
//! through the `Bluez` trait; `bluez.rs` is the system-bus side. Time is passed in.

use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

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

/// What the shell shows a device as. From BlueZ's `Icon` (derived from the class of device).
pub fn kind_of(icon: &str) -> &'static str {
    match icon {
        "input-gaming" => "controller",
        "audio-headset" | "audio-headphones" => "headset",
        "audio-card" | "audio-speakers" => "audio",
        _ => "other",
    }
}

/// One `org.bluez.Device1` as read from the bus (with its `Battery1`, if any).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawDevice {
    pub address: String,
    /// `Alias`: the user's name, else the device's own, else the address with dashes.
    pub alias: String,
    pub icon: String,
    pub paired: bool,
    pub connected: bool,
    pub trusted: bool,
    pub battery: Option<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RawAdapter {
    pub powered: bool,
    pub discovering: bool,
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
}

impl Changes {
    pub fn any(&self) -> bool {
        self.devices || self.powered || self.discovering
    }
}

#[derive(Default)]
struct State {
    adapter: Option<RawAdapter>,
    devices: Vec<Device>,
    /// When the running scan has to be stopped (only for a scan we started).
    scan_until: Option<Instant>,
}

pub struct Bluetooth<B: Bluez> {
    bluez: B,
    state: Mutex<State>,
}

impl<B: Bluez> Bluetooth<B> {
    pub fn new(bluez: B) -> Self {
        Bluetooth {
            bluez,
            state: Mutex::new(State::default()),
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

    /// Reads BlueZ again. Powered off (or no adapter) means an empty list and no scan.
    pub fn refresh(&self) -> Result<Changes, BtError> {
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
        };
        let before = st.adapter.unwrap_or(off);
        let after = adapter.unwrap_or(off);
        let changes = Changes {
            devices: st.devices != devices,
            powered: before.powered != after.powered,
            discovering: (before.powered && before.discovering)
                != (after.powered && after.discovering),
        };
        st.adapter = adapter;
        st.devices = devices;
        if !(on && after.discovering) {
            st.scan_until = None;
        }
        Ok(changes)
    }

    /// The adapter must be there and on for scanning, pairing and connecting.
    fn ready(&self) -> Result<(), Status> {
        match self.refresh() {
            Ok(_) if self.powered() => Ok(()),
            Ok(_) => Err(Status::Unavailable),
            Err(e) => Err(map_error(&e.0, false)),
        }
    }

    /// Powers the adapter. `Err` when BlueZ refused (no adapter, rfkill blocked): the service
    /// answers a D-Bus error.
    pub fn set_powered(&self, on: bool) -> Result<Changes, BtError> {
        // Know the adapter first: BlueZ may have just come up.
        self.refresh()?;
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
        let mut st = self.lock();
        if let Some(a) = st.adapter.as_mut() {
            a.discovering = true;
        }
        st.scan_until = Some(now + SCAN_LIMIT);
        Status::Ok
    }

    pub fn stop_scan(&self) -> Status {
        if self.refresh().is_err() || !self.discovering() {
            self.lock().scan_until = None;
            return Status::Ok;
        }
        let status = match self.bluez.stop_discovery() {
            Ok(()) => Status::Ok,
            Err(e) => map_error(&e.0, false),
        };
        let mut st = self.lock();
        st.scan_until = None;
        if status == Status::Ok {
            if let Some(a) = st.adapter.as_mut() {
                a.discovering = false;
            }
        }
        status
    }

    /// Ends the scan once its time is up. `true` when it did.
    pub fn tick(&self, now: Instant) -> bool {
        let due = self.lock().scan_until.is_some_and(|t| now >= t);
        if !due {
            return false;
        }
        if let Err(e) = self.bluez.stop_discovery() {
            eprintln!("ruya-devices: ending the scan failed: {}", e.0);
        }
        let mut st = self.lock();
        st.scan_until = None;
        if let Some(a) = st.adapter.as_mut() {
            a.discovering = false;
        }
        true
    }

    /// Looks the device up in a fresh read.
    fn find(&self, id: &str) -> Result<Device, Status> {
        if id.is_empty() {
            return Err(Status::Invalid);
        }
        self.refresh().map_err(|e| map_error(&e.0, false))?;
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

    /// Pair (just works), trust and connect.
    pub fn pair(&self, id: &str) -> Status {
        let dev = match self.ready_device(id) {
            Ok(d) => d,
            Err(s) => return s,
        };
        if !dev.paired {
            if let Err(e) = self.bluez.pair(&dev.id, CALL_TIMEOUT) {
                return map_error(&e.0, true);
            }
        }
        if let Err(e) = self.bluez.set_trusted(&dev.id) {
            return map_error(&e.0, false);
        }
        match self.bluez.connect(&dev.id, CALL_TIMEOUT) {
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

/// A scripted BlueZ for tests and `--session` development.
pub struct FakeBluez {
    inner: Mutex<FakeInner>,
}

struct FakeInner {
    raw: Raw,
    /// Error names to answer with, next call first (any call that changes something).
    fail: Vec<String>,
    /// The calls received, for the tests.
    calls: Vec<String>,
}

impl FakeBluez {
    pub fn new(raw: Raw) -> Self {
        FakeBluez {
            inner: Mutex::new(FakeInner {
                raw,
                fail: Vec::new(),
                calls: Vec::new(),
            }),
        }
    }

    /// An adapter that is on, with one paired pad and one unpaired one in range.
    pub fn with_devices() -> Self {
        let dev = |address: &str, alias: &str, icon: &str, paired: bool| RawDevice {
            address: address.to_owned(),
            alias: alias.to_owned(),
            icon: icon.to_owned(),
            paired,
            connected: paired,
            trusted: paired,
            battery: if paired { Some(80) } else { None },
        };
        FakeBluez::new(Raw {
            adapter: Some(RawAdapter {
                powered: true,
                discovering: false,
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
    fn start_discovery(&self) -> Result<(), BtError> {
        self.act("start".to_owned(), |raw| {
            if let Some(a) = raw.adapter.as_mut() {
                a.discovering = true;
            }
        })
    }
    fn stop_discovery(&self) -> Result<(), BtError> {
        self.act("stop".to_owned(), |raw| {
            if let Some(a) = raw.adapter.as_mut() {
                a.discovering = false;
            }
        })
    }
    fn pair(&self, address: &str, _timeout: Duration) -> Result<(), BtError> {
        self.act(format!("pair {address}"), |raw| {
            with_device(raw, address, |d| d.paired = true);
        })
    }
    fn set_trusted(&self, address: &str) -> Result<(), BtError> {
        self.act(format!("trust {address}"), |raw| {
            with_device(raw, address, |d| d.trusted = true);
        })
    }
    fn connect(&self, address: &str, _timeout: Duration) -> Result<(), BtError> {
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
            paired,
            connected: false,
            trusted: false,
            battery: None,
        }
    }

    fn bt() -> Bluetooth<FakeBluez> {
        let bt = Bluetooth::new(FakeBluez::with_devices());
        bt.refresh().expect("fake reads");
        bt
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
        assert_eq!(kind_of("audio-card"), "audio");
        assert_eq!(kind_of("input-keyboard"), "other");
        assert_eq!(kind_of(""), "other");
        assert_eq!(battery_of(None), -1);
        assert_eq!(battery_of(Some(0)), 0);
        assert_eq!(battery_of(Some(73)), 73);
        assert_eq!(battery_of(Some(200)), 100);
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
        assert!(bt.discovering());
        assert_eq!(bt.scan_deadline(), Some(t0 + SCAN_LIMIT));
        assert!(!bt.tick(t0 + Duration::from_secs(29)));
        assert!(bt.discovering(), "still scanning at 29 s");
        assert!(bt.tick(t0 + SCAN_LIMIT));
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
        assert_eq!(bt.stop_scan(), Status::Ok);
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
        assert_eq!(bt.pair("AA:00:00:00:00:02"), Status::Unavailable);
        assert_eq!(bt.connect("AA:00:00:00:00:01"), Status::Unavailable);
        assert_eq!(bt.forget("AA:00:00:00:00:01"), Status::UnknownDevice);
        assert!(bt.list().is_empty());
        assert!(bt.set_powered(true).is_err());
    }

    #[test]
    fn pair_pairs_trusts_and_connects() {
        let bt = bt();
        assert_eq!(bt.pair("AA:00:00:00:00:02"), Status::Ok);
        let calls = bt.bluez.calls();
        assert_eq!(
            calls,
            [
                "pair AA:00:00:00:00:02",
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
        assert_eq!(bt.pair("AA:00:00:00:00:02"), Status::PairingFailed);
        bt.bluez.fail_next(LOCAL_TIMEOUT);
        assert_eq!(bt.pair("AA:00:00:00:00:02"), Status::Timeout);
        assert_eq!(bt.pair("AA:00:00:00:00:99"), Status::UnknownDevice);
        assert_eq!(bt.pair(""), Status::Invalid);
    }

    #[test]
    fn pair_of_a_paired_device_skips_pairing() {
        let bt = bt();
        assert_eq!(bt.pair("AA:00:00:00:00:01"), Status::Ok);
        assert!(!bt.bluez.calls().iter().any(|c| c.starts_with("pair ")));
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
}
