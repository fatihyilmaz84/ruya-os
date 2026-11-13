//! The capability descriptor (06-input.md §4.3): per device and capability four booleans,
//! `hardware` (the model has it), `driver` (the kernel exposes it here), `available` (usable now)
//! and `output` (the virtual pad the device is routed to can carry it). Pure: the Linux side
//! fills a `Probe` with what it found on this machine; the rules are here.
//!
//! Rules:
//! - Only what is detected is reported: a capability is never inferred from another (a pad with
//!   rumble has no adaptive triggers unless the device table says the model has them).
//! - `hardware` is the device table's entry for the model, or what the kernel shows for an
//!   unknown one; a part the kernel exposes counts as hardware even when the table lacks it.
//! - `driver` needs the kernel's part (a motion node, `FF_RUMBLE`, a power-supply entry).
//!   Capabilities the service has no kernel path for yet (trigger rumble, adaptive triggers,
//!   lightbar, player lights, speaker, microphone: hidraw, T-373) are never `driver`.
//! - `available` needs the part to be usable now: a node that exists but does not open, or a
//!   battery that does not report, is not available. A missing node is neither.
//! - `output`: the Xbox 360-style virtual pad (RUY-3) carries buttons, sticks, analog triggers,
//!   the D-pad and rumble; nothing else.

/// Every capability name, in descriptor order (api/dbus/org.ruyaos.Input1.xml).
pub const NAMES: [&str; 15] = [
    "buttons",
    "sticks",
    "analog_triggers",
    "dpad",
    "gyro",
    "accelerometer",
    "touchpad",
    "rumble",
    "trigger_rumble",
    "adaptive_triggers",
    "lightbar",
    "player_leds",
    "speaker",
    "microphone",
    "battery",
];

/// What the Xbox 360-style virtual pad can carry.
const VIRTUAL_OUTPUT: [&str; 5] = ["buttons", "sticks", "analog_triggers", "dpad", "rumble"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Capability {
    pub name: &'static str,
    pub hardware: bool,
    pub driver: bool,
    pub available: bool,
    pub output: bool,
}

/// A part of the pad the kernel makes its own node or entry for (the motion sensors, the
/// touchpad, the battery).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Part {
    /// No node: the kernel does not expose it here.
    #[default]
    Missing,
    /// The node exists but did not open (or the battery does not report).
    Present,
    /// The node opened (the battery reports a capacity).
    Usable,
}

/// What the Linux side found on the pad's own node and its siblings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Probe {
    pub buttons: bool,
    pub sticks: bool,
    pub analog_triggers: bool,
    pub dpad: bool,
    pub rumble: bool,
    pub motion: Part,
    pub touchpad: Part,
    pub battery: Part,
}

const DUALSENSE: &[&str] = &[
    "buttons",
    "sticks",
    "analog_triggers",
    "dpad",
    "gyro",
    "accelerometer",
    "touchpad",
    "rumble",
    "adaptive_triggers",
    "lightbar",
    "player_leds",
    "speaker",
    "microphone",
    "battery",
];
const DUALSHOCK4: &[&str] = &[
    "buttons",
    "sticks",
    "analog_triggers",
    "dpad",
    "gyro",
    "accelerometer",
    "touchpad",
    "rumble",
    "lightbar",
    "speaker",
    "battery",
];
const XBOX360: &[&str] = &[
    "buttons",
    "sticks",
    "analog_triggers",
    "dpad",
    "rumble",
    "player_leds",
];
const XBOX_ONE: &[&str] = &[
    "buttons",
    "sticks",
    "analog_triggers",
    "dpad",
    "rumble",
    "trigger_rumble",
    "battery",
];
const SWITCH_PRO: &[&str] = &[
    "buttons",
    "sticks",
    "dpad",
    "gyro",
    "accelerometer",
    "rumble",
    "player_leds",
    "battery",
];

/// The service's device table (06 §4.1): what a known model has, by USB vendor and product id.
/// `None` for a model it does not know (then only what the kernel shows counts).
pub fn model(vendor: u16, product: u16) -> Option<&'static [&'static str]> {
    Some(match (vendor, product) {
        (0x054c, 0x0ce6) | (0x054c, 0x0df2) => DUALSENSE,
        (0x054c, 0x05c4) | (0x054c, 0x09cc) | (0x054c, 0x0ba0) => DUALSHOCK4,
        (0x045e, 0x028e) | (0x045e, 0x0719) | (0x045e, 0x0291) | (0x045e, 0x02a9) => XBOX360,
        (0x045e, 0x02d1)
        | (0x045e, 0x02dd)
        | (0x045e, 0x02ea)
        | (0x045e, 0x0b12)
        | (0x045e, 0x0b13) => XBOX_ONE,
        (0x057e, 0x2009) => SWITCH_PRO,
        _ => return None,
    })
}

/// The descriptor of one device: every name of `NAMES`, in that order.
pub fn describe(model: Option<&[&str]>, probe: &Probe) -> Vec<Capability> {
    NAMES
        .iter()
        .map(|&name| {
            let (driver, usable) = match name {
                "buttons" => (probe.buttons, true),
                "sticks" => (probe.sticks, true),
                "analog_triggers" => (probe.analog_triggers, true),
                "dpad" => (probe.dpad, true),
                "rumble" => (probe.rumble, true),
                "gyro" | "accelerometer" => part(probe.motion),
                "touchpad" => part(probe.touchpad),
                "battery" => part(probe.battery),
                _ => (false, false),
            };
            let hardware = driver || model.is_some_and(|m| m.contains(&name));
            let available = driver && usable;
            Capability {
                name,
                hardware,
                driver,
                available,
                output: available && VIRTUAL_OUTPUT.contains(&name),
            }
        })
        .collect()
}

/// (driver, usable) of a part.
fn part(p: Part) -> (bool, bool) {
    match p {
        Part::Missing => (false, false),
        Part::Present => (true, false),
        Part::Usable => (true, true),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cap(caps: &[Capability], name: &str) -> Capability {
        *caps
            .iter()
            .find(|c| c.name == name)
            .expect("every name is listed")
    }

    fn full_pad() -> Probe {
        Probe {
            buttons: true,
            sticks: true,
            analog_triggers: true,
            dpad: true,
            rumble: true,
            motion: Part::Usable,
            touchpad: Part::Usable,
            battery: Part::Usable,
        }
    }

    #[test]
    fn every_name_is_listed_once_in_descriptor_order() {
        let caps = describe(None, &Probe::default());
        let names: Vec<&str> = caps.iter().map(|c| c.name).collect();
        assert_eq!(names, NAMES.to_vec());
    }

    #[test]
    fn rumble_never_implies_adaptive_triggers() {
        // An unknown pad with rumble: no trigger effects of any kind.
        let caps = describe(None, &full_pad());
        assert!(cap(&caps, "rumble").available);
        for name in ["adaptive_triggers", "trigger_rumble", "lightbar", "speaker"] {
            let c = cap(&caps, name);
            assert!(
                !c.hardware && !c.driver && !c.available && !c.output,
                "{name}: {c:?}"
            );
        }
        // A DualShock 4 has rumble but no adaptive triggers in the table.
        let ds4 = describe(model(0x054c, 0x05c4), &full_pad());
        assert!(!cap(&ds4, "adaptive_triggers").hardware);
        // A DualSense has them, but the service has no kernel path for them yet (T-373).
        let ds = describe(model(0x054c, 0x0ce6), &full_pad());
        let adaptive = cap(&ds, "adaptive_triggers");
        assert!(adaptive.hardware && !adaptive.driver && !adaptive.available);
    }

    #[test]
    fn a_missing_node_means_not_available() {
        let probe = Probe {
            motion: Part::Missing,
            touchpad: Part::Missing,
            battery: Part::Missing,
            ..full_pad()
        };
        let ds = describe(model(0x054c, 0x0ce6), &probe);
        for name in ["gyro", "accelerometer", "touchpad", "battery"] {
            let c = cap(&ds, name);
            assert!(c.hardware, "{name}: the model has it");
            assert!(!c.driver && !c.available && !c.output, "{name}: {c:?}");
        }
    }

    #[test]
    fn a_node_that_does_not_open_is_there_but_not_available() {
        let probe = Probe {
            motion: Part::Present,
            battery: Part::Present,
            ..full_pad()
        };
        let ds = describe(model(0x054c, 0x0ce6), &probe);
        for name in ["gyro", "battery"] {
            let c = cap(&ds, name);
            assert!(c.hardware && c.driver && !c.available, "{name}: {c:?}");
        }
        assert!(cap(&ds, "touchpad").available);
    }

    #[test]
    fn only_the_virtual_pads_parts_are_passed_to_games() {
        let ds = describe(model(0x054c, 0x0ce6), &full_pad());
        for name in ["buttons", "sticks", "analog_triggers", "dpad", "rumble"] {
            assert!(cap(&ds, name).output, "{name}");
        }
        for name in ["gyro", "accelerometer", "touchpad", "battery"] {
            let c = cap(&ds, name);
            assert!(c.available && !c.output, "{name}: {c:?}");
        }
    }

    #[test]
    fn an_unknown_pad_has_only_what_the_kernel_shows() {
        let probe = Probe {
            buttons: true,
            sticks: true,
            dpad: true,
            ..Probe::default()
        };
        let caps = describe(model(0x2dc8, 0x6001), &probe);
        let had: Vec<&str> = caps.iter().filter(|c| c.hardware).map(|c| c.name).collect();
        assert_eq!(had, vec!["buttons", "sticks", "dpad"]);
    }

    #[test]
    fn a_part_the_kernel_shows_counts_even_when_the_table_lacks_it() {
        // A Switch Pro controller has digital triggers in the table; a driver that reports an
        // analog axis is believed.
        let probe = Probe {
            analog_triggers: true,
            ..full_pad()
        };
        let caps = describe(model(0x057e, 0x2009), &probe);
        assert!(cap(&caps, "analog_triggers").hardware);
        assert!(cap(&caps, "touchpad").hardware);
        assert!(!cap(&caps, "lightbar").hardware);
    }
}
