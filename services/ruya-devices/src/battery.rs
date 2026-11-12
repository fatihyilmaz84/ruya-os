//! Wireless device batteries (org.ruyaos.Devices1.Batteries, T-161, T-223). UPower knows every
//! battery-like device of the machine; the rules here pick the controllers, headsets, speakers,
//! mice, keyboards and remotes (not the PC's own battery) and turn UPower's numbers into the
//! contract's strings. Pure and tested on any host; the UPower side is `upower.rs`.

use std::sync::{Mutex, MutexGuard};

use crate::bluetooth::Device;
use crate::families::family_of;

/// UPower's `UpDeviceKind` for a gamepad ("gaming input").
pub const KIND_GAMING_INPUT: u32 = 12;

/// The contract's `kind` for a UPower `UpDeviceKind`, or `None` for a device that is not listed:
/// the PC's battery (2), line power (1), a UPS (3), a monitor (4), phones and tablets and the
/// like. Listed: mouse 5 and touchpad 14 (a mouse), keyboard 6, gaming input 12, headset 17,
/// speakers 18, headphones 19, other audio 21 (BlueZ's audio classes land there: a headset),
/// remote control 22 and Bluetooth generic 28. Every other kind is dropped on purpose (a pen 13, a
/// camera, a toy: nothing the status cluster has an icon for).
pub fn kind_of(upower_kind: u32) -> Option<&'static str> {
    match upower_kind {
        KIND_GAMING_INPUT => Some("controller"),
        17 | 19 | 21 => Some("headset"),
        18 => Some("speaker"),
        5 | 14 => Some("mouse"),
        6 => Some("keyboard"),
        22 | 28 => Some("other"),
        _ => None,
    }
}

/// The power supply `xpad` creates for a pad behind an Xbox 360 wireless receiver is named
/// `xpad_battery-<port>` and has no model. UPower may file it as a plain battery (2) instead of a
/// gaming input (12): it is a controller either way (RUY-154; the real kind is unverified until a
/// receiver is tried, hw pending).
fn is_xpad_battery(d: &RawDevice) -> bool {
    d.native_path.contains("xpad_battery")
}

/// What the contract says about a controller's charge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChargeState {
    Charging,
    Discharging,
    Full,
    Unknown,
}

impl ChargeState {
    pub fn as_str(self) -> &'static str {
        match self {
            ChargeState::Charging => "charging",
            ChargeState::Discharging => "discharging",
            ChargeState::Full => "full",
            ChargeState::Unknown => "unknown",
        }
    }

    /// From UPower's `UpDeviceState`: 1 charging, 2 discharging, 3 empty, 4 fully charged,
    /// 5 pending charge, 6 pending discharge, 0 or anything else unknown.
    pub fn from_upower(state: u32) -> ChargeState {
        match state {
            1 | 5 => ChargeState::Charging,
            2 | 3 | 6 => ChargeState::Discharging,
            4 => ChargeState::Full,
            _ => ChargeState::Unknown,
        }
    }
}

/// One UPower device as read from the bus.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RawDevice {
    /// The object path.
    pub id: String,
    /// `UpDeviceKind`.
    pub kind: u32,
    pub model: String,
    /// 0.0-100.0; UPower reports 0 for a device that has no reading.
    pub percentage: f64,
    /// `UpDeviceState`.
    pub state: u32,
    /// UPower's `Serial` and `NativePath`: for a pad that BlueZ feeds the serial is its Bluetooth
    /// address, and the native path of a BlueZ or `hid-playstation` battery holds it too.
    pub serial: String,
    pub native_path: String,
    /// UPower's `Vendor`.
    pub vendor: String,
}

/// The Bluetooth address (`E4:17:D8:00:00:01`, upper case) inside a text such as a serial
/// (`e4:17:d8:00:00:01`) or a BlueZ object path (`/org/bluez/hci0/dev_E4_17_D8_00_00_01`), or
/// "".
pub fn address_in(text: &str) -> String {
    let bytes = text.as_bytes();
    let separators = [b':', b'_', b'-'];
    for start in 0..bytes.len().saturating_sub(16) {
        let window = &bytes[start..start + 17];
        let sep = window[2];
        let fits = separators.contains(&sep)
            && window.iter().enumerate().all(|(i, b)| {
                if i % 3 == 2 {
                    *b == sep
                } else {
                    b.is_ascii_hexdigit()
                }
            });
        if fits {
            return String::from_utf8_lossy(window)
                .replace(['_', '-'], ":")
                .to_uppercase();
        }
    }
    String::new()
}

/// The controller family of a battery: the Bluetooth device with the same address decides (it is
/// the same table, `families.rs`, over the Modalias BlueZ has, so the status cluster and Settings
/// agree); a pad BlueZ does not know (wired, a dongle) is guessed from its model and vendor.
/// "" for every other kind.
pub fn family_of_battery(
    kind: &str,
    address: &str,
    vendor: &str,
    model: &str,
    bluetooth: &[Device],
) -> &'static str {
    if kind != "controller" {
        return "";
    }
    if !address.is_empty() {
        if let Some(d) = bluetooth
            .iter()
            .find(|d| d.kind == "controller" && d.id.eq_ignore_ascii_case(address))
        {
            return d.family;
        }
    }
    let by_model = family_of("", model);
    if by_model.is_empty() {
        family_of("", &format!("{vendor} {model}"))
    } else {
        by_model
    }
}

/// A listed battery.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Battery {
    pub id: String,
    pub name: String,
    /// "controller" | "headset" | "speaker" | "mouse" | "keyboard" | "other" (`kind_of`).
    pub kind: &'static str,
    pub percent: u32,
    pub state: ChargeState,
    /// The controller family (`family_of_battery`), "" for every other kind and for a pad whose
    /// family cannot be told. `peripherals` sets the guess from the name; `Batteries::list_with`
    /// replaces it by what Bluetooth knows.
    pub family: &'static str,
    /// The Bluetooth address UPower's serial or native path holds, "" for none.
    pub address: String,
    vendor: String,
    model: String,
}

/// The listed batteries: the kinds `kind_of` knows, sorted by id (a stable order). A device
/// whose state is unknown and whose percentage is 0 has no reading at all and is not listed.
pub fn peripherals(devices: &[RawDevice]) -> Vec<Battery> {
    let mut out: Vec<Battery> = devices
        .iter()
        .filter_map(|d| {
            let xpad = is_xpad_battery(d);
            let kind = if xpad { "controller" } else { kind_of(d.kind)? };
            let state = ChargeState::from_upower(d.state);
            let percent = if d.percentage.is_finite() {
                d.percentage.round().clamp(0.0, 100.0) as u32
            } else {
                0
            };
            if state == ChargeState::Unknown && percent == 0 {
                return None;
            }
            let model = if xpad && d.model.trim().is_empty() {
                crate::input::XBOX360_PAD_NAME
            } else {
                &d.model
            };
            let name = model.trim();
            Some(Battery {
                id: d.id.clone(),
                name: if name.is_empty() {
                    default_name(kind)
                } else {
                    name
                }
                .to_owned(),
                kind,
                percent,
                state,
                family: family_of_battery(kind, "", &d.vendor, model, &[]),
                address: {
                    let found = address_in(&d.serial);
                    if found.is_empty() {
                        address_in(&d.native_path)
                    } else {
                        found
                    }
                },
                vendor: d.vendor.clone(),
                model: model.to_owned(),
            })
        })
        .collect();
    out.sort_by(|a, b| a.id.cmp(&b.id));
    out
}

fn default_name(kind: &str) -> &'static str {
    match kind {
        "controller" => "Controller",
        "headset" => "Headset",
        "speaker" => "Speaker",
        "mouse" => "Mouse",
        "keyboard" => "Keyboard",
        _ => "Device",
    }
}

/// UPower, as far as the core needs it. `upower::UPowerClient` talks to the bus; an absent
/// UPower is an empty list, not an error.
pub trait UPower: Send + Sync {
    fn devices(&self) -> Result<Vec<RawDevice>, String>;
}

pub struct Batteries<U: UPower> {
    upower: U,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    /// The last UPower read, families guessed from the model alone.
    read: Vec<Battery>,
    /// What clients were last told (`ListBatteries`): `read` with each controller's family taken
    /// from Bluetooth. A change in either source is announced when this changes.
    shown: Vec<Battery>,
}

impl<U: UPower> Batteries<U> {
    pub fn new(upower: U) -> Self {
        Batteries {
            upower,
            state: Mutex::new(State::default()),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        // A poisoned lock only means another call panicked; the state is plain data.
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Reads UPower again, resolving families against `bluetooth`. `true` when what clients see
    /// changed (so `BatteriesChanged` is due).
    pub fn refresh_with(&self, bluetooth: &[Device]) -> Result<bool, String> {
        let now = peripherals(&self.upower.devices()?);
        let mut state = self.lock();
        state.read = now;
        Ok(Self::settle(&mut state, bluetooth))
    }

    /// `refresh_with` for a caller that knows no Bluetooth devices.
    pub fn refresh(&self) -> Result<bool, String> {
        self.refresh_with(&[])
    }

    /// Looks again at the last UPower read against the current Bluetooth devices, without asking
    /// UPower: a pad that bonded or connected after UPower listed its battery has a family now
    /// (or the other way round, a forgotten one has lost it). `true` when clients must be told.
    pub fn recheck(&self, bluetooth: &[Device]) -> bool {
        Self::settle(&mut self.lock(), bluetooth)
    }

    fn settle(state: &mut State, bluetooth: &[Device]) -> bool {
        let now = Self::resolved(&state.read, bluetooth);
        let changed = state.shown != now;
        state.shown = now;
        changed
    }

    fn resolved(read: &[Battery], bluetooth: &[Device]) -> Vec<Battery> {
        let mut list = read.to_vec();
        for b in &mut list {
            b.family = family_of_battery(b.kind, &b.address, &b.vendor, &b.model, bluetooth);
        }
        list
    }

    /// The last UPower read, as `peripherals` made it (no Bluetooth knowledge).
    pub fn list(&self) -> Vec<Battery> {
        self.lock().read.clone()
    }

    /// The list with each controller's family taken from the Bluetooth device that has its
    /// address (`family_of_battery`), so a pad is the same family here as in `ListDevices`.
    pub fn list_with(&self, bluetooth: &[Device]) -> Vec<Battery> {
        Self::resolved(&self.lock().read, bluetooth)
    }
}

/// A scripted UPower for tests and `--session` development.
#[derive(Default)]
pub struct FakeUPower {
    devices: Mutex<Vec<RawDevice>>,
}

impl FakeUPower {
    pub fn new(devices: Vec<RawDevice>) -> Self {
        FakeUPower {
            devices: Mutex::new(devices),
        }
    }

    pub fn set(&self, devices: Vec<RawDevice>) {
        *self.devices.lock().unwrap_or_else(|e| e.into_inner()) = devices;
    }
}

impl UPower for FakeUPower {
    fn devices(&self) -> Result<Vec<RawDevice>, String> {
        Ok(self
            .devices
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dev(id: &str, kind: u32, model: &str, percentage: f64, state: u32) -> RawDevice {
        RawDevice {
            id: id.to_owned(),
            kind,
            model: model.to_owned(),
            percentage,
            state,
            ..RawDevice::default()
        }
    }

    fn pad(id: &str, percentage: f64, state: u32) -> RawDevice {
        dev(id, KIND_GAMING_INPUT, "Ruya Pad", percentage, state)
    }

    #[test]
    fn a_gamepad_discharging_is_listed() {
        let list = peripherals(&[pad("/pad1", 40.0, 2)]);
        assert_eq!(
            list,
            vec![Battery {
                id: "/pad1".to_owned(),
                name: "Ruya Pad".to_owned(),
                kind: "controller",
                percent: 40,
                state: ChargeState::Discharging,
                family: "",
                address: String::new(),
                vendor: String::new(),
                model: "Ruya Pad".to_owned(),
            }]
        );
    }

    #[test]
    fn an_xbox_360_pad_behind_the_receiver_has_its_battery_and_family() {
        // xpad's power supply: no model, and UPower may call it a plain battery (2) or a gaming
        // input (12). Both list as an Xbox controller; a laptop battery stays out.
        for kind in [2, KIND_GAMING_INPUT] {
            let mut d = dev("/xpad1", kind, "", 55.0, 2);
            d.native_path =
                "/sys/devices/pci0000:00/usb1/1-2/power_supply/xpad_battery-1-2".to_owned();
            let list = peripherals(&[d]);
            assert_eq!(list.len(), 1, "kind {kind}");
            assert_eq!(list[0].kind, "controller");
            assert_eq!(list[0].name, "Xbox 360 Controller");
            assert_eq!(list[0].family, "xbox");
            assert_eq!(
                (list[0].percent, list[0].state),
                (55, ChargeState::Discharging)
            );
        }
        let mut laptop = dev("/bat", 2, "", 80.0, 2);
        laptop.native_path = "/sys/devices/LNXSYSTM:00/power_supply/BAT0".to_owned();
        assert!(peripherals(&[laptop]).is_empty());
    }

    fn bt(id: &str, name: &str, kind: &'static str, family: &'static str) -> Device {
        Device {
            id: id.to_owned(),
            name: name.to_owned(),
            device_name: name.to_owned(),
            kind,
            family,
            paired: true,
            bonded: true,
            connected: true,
            trusted: true,
            battery: 50,
            adapter: "hci0".to_owned(),
        }
    }

    fn with(mut d: RawDevice, serial: &str, native: &str, vendor: &str) -> RawDevice {
        d.serial = serial.to_owned();
        d.native_path = native.to_owned();
        d.vendor = vendor.to_owned();
        d
    }

    #[test]
    fn addresses_are_found_in_serials_and_bluez_paths() {
        assert_eq!(address_in("e4:17:d8:00:00:01"), "E4:17:D8:00:00:01");
        assert_eq!(
            address_in("/org/bluez/hci0/dev_E4_17_D8_00_00_0a"),
            "E4:17:D8:00:00:0A"
        );
        assert_eq!(
            address_in("/sys/class/power_supply/ps-controller-battery-e4:17:d8:00:00:01"),
            "E4:17:D8:00:00:01"
        );
        assert_eq!(address_in("1234"), "");
        assert_eq!(address_in("zz:17:d8:00:00:01"), "");
        assert_eq!(address_in(""), "");
    }

    #[test]
    fn a_dualsense_battery_has_the_family_of_the_bluetooth_device_with_its_serial() {
        let b = Batteries::new(FakeUPower::new(vec![with(
            dev("/p1", KIND_GAMING_INPUT, "Wireless Controller", 62.0, 2),
            "e4:17:d8:00:00:01",
            "",
            "",
        )]));
        b.refresh().expect("reads");
        let list = [bt(
            "E4:17:D8:00:00:01",
            "DualSense",
            "controller",
            "playstation",
        )];
        assert_eq!(b.list_with(&list)[0].family, "playstation");
        // The Bluetooth device decides, even against what the name alone would say.
        let other = [bt("E4:17:D8:00:00:01", "Renamed", "controller", "xbox")];
        assert_eq!(b.list_with(&other)[0].family, "xbox");
        // Another address is not this pad: the name guess stands.
        let stranger = [bt("AA:00:00:00:00:09", "Pad", "controller", "nintendo")];
        assert_eq!(b.list_with(&stranger)[0].family, "playstation");
    }

    #[test]
    fn the_address_can_come_from_the_native_path() {
        let b = Batteries::new(FakeUPower::new(vec![with(
            dev("/p1", KIND_GAMING_INPUT, "Pad", 62.0, 2),
            "",
            "/org/bluez/hci0/dev_E4_17_D8_00_00_01",
            "",
        )]));
        b.refresh().expect("reads");
        let list = [bt("E4:17:D8:00:00:01", "Pad", "controller", "xbox")];
        assert_eq!(b.list_with(&list)[0].family, "xbox");
    }

    #[test]
    fn a_pad_bluez_does_not_know_falls_back_to_vendor_model_and_name() {
        let family = |model: &str, vendor: &str| {
            let b = Batteries::new(FakeUPower::new(vec![with(
                dev("/p1", KIND_GAMING_INPUT, model, 62.0, 2),
                "",
                "",
                vendor,
            )]));
            b.refresh().expect("reads");
            b.list_with(&[])[0].family
        };
        assert_eq!(family("DualSense Wireless Controller", ""), "playstation");
        assert_eq!(family("Xbox Wireless Controller", "Microsoft"), "xbox");
        assert_eq!(family("Pro Controller", ""), "nintendo");
        assert_eq!(family("SN30 Pro", "8BitDo"), "8bitdo");
        assert_eq!(family("Ruya Pad", "Ruya"), "");
        assert_eq!(family("", ""), "");
    }

    fn shown(b: &Batteries<FakeUPower>) -> Vec<(String, &'static str)> {
        b.lock()
            .shown
            .iter()
            .map(|x| (x.id.clone(), x.family))
            .collect()
    }

    /// What hid-playstation gives UPower for a DualSense on Bluetooth: no model, no vendor, no
    /// serial, the address in the power supply's name (`ps-controller-battery-<uniq>`).
    fn dualsense_upower(address_in_name: &str) -> RawDevice {
        with(
            dev(
                "/org/freedesktop/UPower/devices/gaming_input_ps_controller_battery_x",
                12,
                "",
                62.0,
                2,
            ),
            "",
            &format!("ps-controller-battery-{address_in_name}"),
            "",
        )
    }

    #[test]
    fn a_pad_that_bonds_after_upower_listed_it_is_announced_with_its_family() {
        let b = Batteries::new(FakeUPower::new(vec![dualsense_upower("e4:17:d8:12:34:56")]));
        // UPower first: Bluetooth knows no such pad yet.
        assert_eq!(b.refresh_with(&[]), Ok(true));
        assert_eq!(shown(&b)[0].1, "");
        assert!(!b.recheck(&[]), "nothing new: no signal");
        // Then the pad bonds: same UPower list, a family now.
        let pads = [bt(
            "E4:17:D8:12:34:56",
            "Living room pad",
            "controller",
            "playstation",
        )];
        assert!(b.recheck(&pads), "the family appeared: BatteriesChanged");
        assert_eq!(shown(&b)[0].1, "playstation");
        assert!(!b.recheck(&pads), "announced once");
        assert_eq!(b.refresh_with(&pads), Ok(false), "UPower said nothing new");
        // The pad is forgotten: it falls back to what the model says (nothing here).
        assert!(b.recheck(&[]));
        assert_eq!(shown(&b)[0].1, "");
    }

    #[test]
    fn a_battery_upower_lists_after_the_pad_bonded_has_the_family_at_once() {
        let pads = [bt(
            "E4:17:D8:12:34:56",
            "Living room pad",
            "controller",
            "playstation",
        )];
        let b = Batteries::new(FakeUPower::new(vec![]));
        assert_eq!(b.refresh_with(&pads), Ok(false), "no batteries, no news");
        b.upower.set(vec![dualsense_upower("e4:17:d8:12:34:56")]);
        assert_eq!(b.refresh_with(&pads), Ok(true), "a new battery");
        assert_eq!(shown(&b)[0].1, "playstation");
        assert!(!b.recheck(&pads), "no second signal for the same family");
    }

    #[test]
    fn real_looking_upower_records_map_to_the_bluetooth_address() {
        // (UPower Serial, NativePath, the address expected)
        let table = [
            (
                "",
                "ps-controller-battery-e4:17:d8:12:34:56",
                "E4:17:D8:12:34:56",
            ),
            ("E4:17:D8:12:34:56", "", "E4:17:D8:12:34:56"),
            (
                "",
                "/org/bluez/hci0/dev_E4_17_D8_12_34_56",
                "E4:17:D8:12:34:56",
            ),
            ("", "hidpp_battery_0", ""),
            ("0123456789", "BAT1", ""),
        ];
        let pads = [bt(
            "E4:17:D8:12:34:56",
            "Living room pad",
            "controller",
            "playstation",
        )];
        for (serial, native, want) in table {
            let mut d = dev("/p", KIND_GAMING_INPUT, "", 62.0, 2);
            d.serial = serial.to_owned();
            d.native_path = native.to_owned();
            let b = Batteries::new(FakeUPower::new(vec![d]));
            b.refresh_with(&pads).expect("reads");
            let battery = &b.list_with(&pads)[0];
            assert_eq!(battery.address, want, "{serial:?} {native:?}");
            // The chip, Settings and the picker agree: the same family as ListDevices says.
            let family = if want.is_empty() { "" } else { "playstation" };
            assert_eq!(battery.family, family, "{serial:?} {native:?}");
        }
    }

    #[test]
    fn only_controllers_have_a_family() {
        let b = Batteries::new(FakeUPower::new(vec![with(
            dev("/h", 17, "DualSense headset", 50.0, 2),
            "e4:17:d8:00:00:01",
            "",
            "Sony",
        )]));
        b.refresh().expect("reads");
        let list = [bt(
            "E4:17:D8:00:00:01",
            "DualSense",
            "controller",
            "playstation",
        )];
        assert_eq!(b.list_with(&list)[0].family, "");
    }

    #[test]
    fn the_pcs_battery_power_supplies_and_phones_are_not_listed() {
        let list = peripherals(&[
            dev("/bat0", 2, "Internal", 80.0, 2),
            dev("/line", 1, "", 0.0, 0),
            dev("/ups", 3, "UPS", 90.0, 2),
            dev("/monitor", 4, "Monitor", 90.0, 2),
            dev("/phone", 8, "Phone", 30.0, 2),
            dev("/tablet", 10, "Tablet", 30.0, 2),
            dev("/pen", 13, "Pen", 30.0, 2),
            dev("/camera", 25, "Camera", 30.0, 2),
            pad("/pad1", 40.0, 2),
        ]);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, "/pad1");
    }

    #[test]
    fn controllers_headsets_speakers_mice_keyboards_and_remotes_are_listed_with_their_kind() {
        let list = peripherals(&[
            dev("/a", 12, "Pad", 40.0, 2),
            dev("/b", 17, "Headset", 30.0, 2),
            dev("/c", 19, "Headphones", 30.0, 2),
            dev("/d", 18, "Speaker", 30.0, 1),
            dev("/e", 5, "Mouse", 55.0, 2),
            dev("/f", 6, "Keyboard", 70.0, 2),
            dev("/g", 22, "Remote", 70.0, 2),
            dev("/h", 28, "Thing", 70.0, 2),
            dev("/i", 21, "Other audio", 70.0, 2),
            dev("/j", 14, "Touchpad", 70.0, 2),
        ]);
        let kinds: Vec<&str> = list.iter().map(|b| b.kind).collect();
        assert_eq!(
            kinds,
            [
                "controller",
                "headset",
                "headset",
                "speaker",
                "mouse",
                "keyboard",
                "other",
                "other",
                "headset",
                "mouse"
            ]
        );
    }

    #[test]
    fn upower_states_map_to_the_contract() {
        let state = |s| ChargeState::from_upower(s).as_str();
        assert_eq!(state(1), "charging");
        assert_eq!(state(5), "charging");
        assert_eq!(state(2), "discharging");
        assert_eq!(state(3), "discharging", "empty");
        assert_eq!(state(6), "discharging");
        assert_eq!(state(4), "full");
        assert_eq!(state(0), "unknown");
        assert_eq!(state(99), "unknown");
    }

    #[test]
    fn percentages_are_rounded_and_clamped() {
        let percent = |p: f64| peripherals(&[pad("/p", p, 2)])[0].percent;
        assert_eq!(percent(39.6), 40);
        assert_eq!(percent(14.4), 14);
        assert_eq!(percent(100.0), 100);
        assert_eq!(percent(140.0), 100);
        assert_eq!(percent(-5.0), 0);
        assert_eq!(percent(f64::NAN), 0);
    }

    #[test]
    fn a_pad_without_any_reading_is_not_listed() {
        assert!(peripherals(&[pad("/p", 0.0, 0)]).is_empty());
        // ... but an empty, discharging one is (0 % is a reading).
        assert_eq!(peripherals(&[pad("/p", 0.0, 3)]).len(), 1);
    }

    #[test]
    fn the_name_falls_back_and_the_order_is_by_id() {
        let list = peripherals(&[
            dev("/b", KIND_GAMING_INPUT, "  ", 50.0, 1),
            dev("/a", KIND_GAMING_INPUT, "Zed Pad", 60.0, 4),
        ]);
        assert_eq!(list[0].id, "/a");
        assert_eq!(list[0].name, "Zed Pad");
        assert_eq!(list[1].name, "Controller");
        let named = peripherals(&[
            dev("/h", 17, "", 50.0, 2),
            dev("/m", 5, "", 50.0, 2),
            dev("/x", 28, "", 50.0, 2),
        ]);
        let names: Vec<&str> = named.iter().map(|b| b.name.as_str()).collect();
        assert_eq!(names, ["Headset", "Mouse", "Device"]);
    }

    #[test]
    fn refresh_reports_changes_and_a_removed_device_leaves_the_list() {
        let fake = FakeUPower::new(vec![pad("/pad1", 40.0, 2)]);
        let b = Batteries::new(fake);
        assert!(b.list().is_empty(), "nothing before the first read");
        assert_eq!(b.refresh(), Ok(true));
        assert_eq!(b.list().len(), 1);
        assert_eq!(b.refresh(), Ok(false), "same state: no signal");
        b.upower.set(vec![pad("/pad1", 39.0, 2)]);
        assert_eq!(b.refresh(), Ok(true), "the level changed");
        assert_eq!(b.list()[0].percent, 39);
        b.upower.set(vec![]);
        assert_eq!(b.refresh(), Ok(true), "the device was removed");
        assert!(b.list().is_empty());
    }

    #[test]
    fn an_unreadable_upower_is_an_error_and_nothing_is_listed() {
        struct Broken;
        impl UPower for Broken {
            fn devices(&self) -> Result<Vec<RawDevice>, String> {
                Err("boom".to_owned())
            }
        }
        let b = Batteries::new(Broken);
        assert!(b.refresh().is_err());
        assert!(b.list().is_empty());
    }
}
