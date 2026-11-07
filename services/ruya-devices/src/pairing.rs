//! The pure rules of the controller pairing window (T-203, `org.ruyaos.Devices1.Bluetooth`
//! `StartControllerPairing`): which devices count as input devices, who may open the window, the
//! window's states and lengths, and how BlueZ's object paths map to addresses. The window itself
//! is in `bluetooth.rs`, next to the state it changes.

use std::time::Duration;

/// The window's length when the caller does not say (the contract's `0`).
pub const DEFAULT_WINDOW: Duration = Duration::from_secs(120);

/// The longest window a caller may ask for.
pub const MAX_WINDOW: Duration = Duration::from_secs(300);

/// How often the window tries to pair the same gamepad found by its scan.
pub const MAX_ATTEMPTS: u32 = 3;

/// Major device class "Peripheral" (gamepad, keyboard, mouse...), bits 8-12 of the Class of Device.
const MAJOR_PERIPHERAL: u32 = 0x05;

/// Bluetooth LE appearance category "Human Interface Device" (keyboard, mouse, gamepad...), bits
/// 6-15 of the appearance value.
const APPEARANCE_HID: u16 = 0x0F;

/// The window's state as the contract's `ControllerPairingState` says it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PairingState {
    #[default]
    Idle,
    Open,
    Paired,
    Timeout,
}

impl PairingState {
    pub fn as_str(self) -> &'static str {
        match self {
            PairingState::Idle => "idle",
            PairingState::Open => "open",
            PairingState::Paired => "paired",
            PairingState::Timeout => "timeout",
        }
    }
}

/// Whether a device is an input device: its Class of Device has the major class Peripheral. A
/// device without a class (Bluetooth LE only) counts when its appearance is in the HID category.
/// Audio, phones, computers and devices that tell nothing are not.
pub fn is_input_device(class: Option<u32>, appearance: Option<u16>) -> bool {
    match class {
        Some(c) if c != 0 => (c >> 8) & 0x1F == MAJOR_PERIPHERAL,
        _ => appearance.is_some_and(|a| a >> 6 == APPEARANCE_HID),
    }
}

/// Whether a service UUID is one an input device uses: HID (classic) or HID over GATT.
pub fn is_hid_service(uuid: &str) -> bool {
    let uuid = uuid.to_ascii_lowercase();
    uuid == "00001124-0000-1000-8000-00805f9b34fb" || uuid == "00001812-0000-1000-8000-00805f9b34fb"
}

/// Who may open and close the window: root, and the user the service runs as (`ruya-shell`).
/// The bus policy already limits the callers to those two; this is the service's own check, and
/// it fails closed: an unknown caller or an unknown own user is refused.
pub fn caller_allowed(caller_uid: Option<u32>, service_uid: Option<u32>) -> bool {
    match (caller_uid, service_uid) {
        (Some(0), _) => true,
        (Some(c), Some(s)) => c == s,
        _ => false,
    }
}

/// `/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF` -> `AA:BB:CC:DD:EE:FF`.
pub fn address_of_path(path: &str) -> Option<String> {
    let tail = path.rsplit('/').next()?.strip_prefix("dev_")?;
    let parts: Vec<&str> = tail.split('_').collect();
    let valid = parts.len() == 6
        && parts
            .iter()
            .all(|p| p.len() == 2 && p.chars().all(|c| c.is_ascii_hexdigit()));
    valid.then(|| parts.join(":").to_ascii_uppercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn input_devices_are_the_peripheral_major_class() {
        assert!(is_input_device(Some(0x2508), None), "gamepad");
        assert!(is_input_device(Some(0x2540), None), "keyboard");
        assert!(is_input_device(Some(0x2580), None), "pointing device");
        assert!(
            is_input_device(Some(0x0508), None),
            "service bits do not matter"
        );
        assert!(!is_input_device(Some(0x5A020C), None), "smartphone");
        assert!(!is_input_device(Some(0x240404), None), "headset");
        assert!(!is_input_device(Some(0x200414), None), "loudspeaker");
        assert!(!is_input_device(Some(0x02010C), None), "computer");
        assert!(!is_input_device(None, None), "tells nothing");
        assert!(
            !is_input_device(Some(0), None),
            "an empty class tells nothing"
        );
    }

    #[test]
    fn an_le_device_without_a_class_counts_by_its_appearance() {
        assert!(is_input_device(None, Some(0x03C4)), "gamepad");
        assert!(is_input_device(None, Some(0x03C1)), "keyboard");
        assert!(is_input_device(Some(0), Some(0x03C4)));
        assert!(!is_input_device(None, Some(0x0040)), "phone");
        assert!(!is_input_device(None, Some(0x0941)), "headset");
        // The class wins over the appearance.
        assert!(!is_input_device(Some(0x5A020C), Some(0x03C4)));
    }

    #[test]
    fn only_hid_services_are_input_services() {
        assert!(is_hid_service("00001124-0000-1000-8000-00805f9b34fb"));
        assert!(is_hid_service("00001812-0000-1000-8000-00805F9B34FB"));
        assert!(
            !is_hid_service("0000110b-0000-1000-8000-00805f9b34fb"),
            "A2DP sink"
        );
        assert!(
            !is_hid_service("0000111e-0000-1000-8000-00805f9b34fb"),
            "handsfree"
        );
        assert!(!is_hid_service(""));
    }

    #[test]
    fn root_and_the_service_user_may_open_the_window() {
        assert!(caller_allowed(Some(0), Some(1000)));
        assert!(caller_allowed(Some(0), None));
        assert!(caller_allowed(Some(1000), Some(1000)));
        assert!(!caller_allowed(Some(1001), Some(1000)), "another user");
        assert!(!caller_allowed(Some(1000), None), "own user unknown");
        assert!(!caller_allowed(None, Some(1000)), "caller unknown");
        assert!(!caller_allowed(None, None));
    }

    #[test]
    fn a_device_path_gives_its_address() {
        assert_eq!(
            address_of_path("/org/bluez/hci0/dev_aa_BB_cc_00_11_22").as_deref(),
            Some("AA:BB:CC:00:11:22")
        );
        assert_eq!(address_of_path("/org/bluez/hci0"), None);
        assert_eq!(address_of_path("/org/bluez/hci0/dev_AA_BB"), None);
        assert_eq!(
            address_of_path("/org/bluez/hci0/dev_AA_BB_CC_00_11_ZZ"),
            None
        );
        assert_eq!(address_of_path(""), None);
    }

    #[test]
    fn the_window_lengths_hold() {
        assert_eq!(DEFAULT_WINDOW, Duration::from_secs(120));
        assert!(DEFAULT_WINDOW <= MAX_WINDOW);
        assert_eq!(PairingState::default().as_str(), "idle");
        assert_eq!(PairingState::Open.as_str(), "open");
        assert_eq!(PairingState::Paired.as_str(), "paired");
        assert_eq!(PairingState::Timeout.as_str(), "timeout");
    }
}
