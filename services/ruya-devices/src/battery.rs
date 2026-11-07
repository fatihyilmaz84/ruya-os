//! Wireless device batteries (org.ruyaos.Devices1.Batteries, T-161, T-223). UPower knows every
//! battery-like device of the machine; the rules here pick the controllers, headsets, speakers,
//! mice, keyboards and remotes (not the PC's own battery) and turn UPower's numbers into the
//! contract's strings. Pure and tested on any host; the UPower side is `upower.rs`.

use std::sync::{Mutex, MutexGuard};

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
#[derive(Debug, Clone, PartialEq)]
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
}

/// The listed batteries: the kinds `kind_of` knows, sorted by id (a stable order). A device
/// whose state is unknown and whose percentage is 0 has no reading at all and is not listed.
pub fn peripherals(devices: &[RawDevice]) -> Vec<Battery> {
    let mut out: Vec<Battery> = devices
        .iter()
        .filter_map(|d| {
            let kind = kind_of(d.kind)?;
            let state = ChargeState::from_upower(d.state);
            let percent = if d.percentage.is_finite() {
                d.percentage.round().clamp(0.0, 100.0) as u32
            } else {
                0
            };
            if state == ChargeState::Unknown && percent == 0 {
                return None;
            }
            let name = d.model.trim();
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
    list: Mutex<Vec<Battery>>,
}

impl<U: UPower> Batteries<U> {
    pub fn new(upower: U) -> Self {
        Batteries {
            upower,
            list: Mutex::new(Vec::new()),
        }
    }

    fn list_lock(&self) -> MutexGuard<'_, Vec<Battery>> {
        // A poisoned lock only means another call panicked; the list is plain data.
        self.list.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Reads UPower again. `true` when the list changed (so `BatteriesChanged` is due).
    pub fn refresh(&self) -> Result<bool, String> {
        let now = peripherals(&self.upower.devices()?);
        let mut list = self.list_lock();
        let changed = *list != now;
        *list = now;
        Ok(changed)
    }

    pub fn list(&self) -> Vec<Battery> {
        self.list_lock().clone()
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
            }]
        );
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
