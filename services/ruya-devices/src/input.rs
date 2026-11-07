//! Whether a keyboard or a gamepad is connected (`Devices1.Bluetooth.InputPresent`, T-203), read
//! from the kernel's input devices in sysfs (`/sys/class/input/input*/name` and
//! `capabilities/key`). USB and Bluetooth devices look the same there. The console's own virtual
//! navigation keyboard (`ruya-inputd`) does not count, nor do buttons such as the power button.
//! The rules are pure; `SysfsInput` is the only part that touches the disk.

use std::path::PathBuf;
use std::sync::Mutex;

/// The name of the virtual keyboard `ruya-inputd` creates (`services/ruya-inputd`).
pub const VIRTUAL_NAME: &str = "RuyaOS Navigation";

/// One input device as sysfs shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputDevice {
    pub name: String,
    /// `capabilities/key`: the supported key codes as hex words, most significant first, each
    /// word the size of the kernel's `long` (64 bits on x86_64).
    pub keys: String,
}

/// Bit `n` of a sysfs capability bitmap.
fn bit(words: &[u64], n: usize) -> bool {
    let word = n / 64;
    // The words are written most significant first.
    words
        .len()
        .checked_sub(1 + word)
        .and_then(|i| words.get(i))
        .is_some_and(|w| w >> (n % 64) & 1 == 1)
}

fn parse_words(keys: &str) -> Vec<u64> {
    keys.split_whitespace()
        .map(|w| u64::from_str_radix(w, 16).unwrap_or(0))
        .collect()
}

/// A keyboard has the keys 1-31 (Esc to Enter and the digit and letter rows), like udev's own
/// test; a gamepad has a button in the joystick/gamepad range (`BTN_JOYSTICK` 0x120 to
/// `BTN_THUMBR` 0x13e). A mouse (0x110...) and a power button are neither.
pub fn is_navigation_input(device: &InputDevice) -> bool {
    if device.name == VIRTUAL_NAME {
        return false;
    }
    let words = parse_words(&device.keys);
    let keyboard = (1..32).all(|n| bit(&words, n));
    let gamepad = (0x120..0x13f).any(|n| bit(&words, n));
    keyboard || gamepad
}

/// The input devices there are now.
pub trait InputSource: Send + Sync {
    fn devices(&self) -> Vec<InputDevice>;
}

/// Chosen at runtime: sysfs on Linux, a fake in `--session` development.
pub type DynInputSource = Box<dyn InputSource>;

impl InputSource for DynInputSource {
    fn devices(&self) -> Vec<InputDevice> {
        (**self).devices()
    }
}

/// `/sys/class/input` (or another root, for tests).
pub struct SysfsInput {
    root: PathBuf,
}

impl SysfsInput {
    pub fn system() -> Self {
        SysfsInput {
            root: PathBuf::from("/sys/class/input"),
        }
    }

    pub fn at(root: impl Into<PathBuf>) -> Self {
        SysfsInput { root: root.into() }
    }
}

impl InputSource for SysfsInput {
    fn devices(&self) -> Vec<InputDevice> {
        let Ok(entries) = std::fs::read_dir(&self.root) else {
            return Vec::new();
        };
        entries
            .filter_map(Result::ok)
            .filter(|e| {
                let name = e.file_name();
                let name = name.to_string_lossy();
                name.strip_prefix("input")
                    .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
            })
            .filter_map(|e| {
                let dir = e.path();
                let name = std::fs::read_to_string(dir.join("name")).ok()?;
                // A device without keys (an accelerometer) simply has no such file.
                let keys = std::fs::read_to_string(dir.join("capabilities").join("key"))
                    .unwrap_or_default();
                Some(InputDevice {
                    name: name.trim().to_owned(),
                    keys: keys.trim().to_owned(),
                })
            })
            .collect()
    }
}

/// A scripted source for tests and `--session` development.
pub struct FakeInput {
    devices: Mutex<Vec<InputDevice>>,
}

impl FakeInput {
    pub fn new(devices: Vec<InputDevice>) -> Self {
        FakeInput {
            devices: Mutex::new(devices),
        }
    }

    /// A plain keyboard.
    pub fn keyboard() -> InputDevice {
        InputDevice {
            name: "Fake Keyboard".to_owned(),
            keys: "ffffffffffffffff".to_owned(),
        }
    }

    pub fn set(&self, devices: Vec<InputDevice>) {
        *self.devices.lock().unwrap_or_else(|e| e.into_inner()) = devices;
    }
}

impl InputSource for FakeInput {
    fn devices(&self) -> Vec<InputDevice> {
        self.devices
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }
}

/// `InputPresent`: reads the source again on `refresh` and says whether the answer changed.
pub struct InputPresence<S: InputSource> {
    source: S,
    present: Mutex<Option<bool>>,
}

impl<S: InputSource> InputPresence<S> {
    pub fn new(source: S) -> Self {
        InputPresence {
            source,
            present: Mutex::new(None),
        }
    }

    /// The answer of the last `refresh`; false before the first one.
    pub fn present(&self) -> bool {
        self.present
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .unwrap_or(false)
    }

    /// Reads the devices. `true` when `InputPresent` is now different from what was announced
    /// (the first read counts as a change only when it finds something).
    pub fn refresh(&self) -> bool {
        let now = self.source.devices().iter().any(is_navigation_input);
        let mut present = self.present.lock().unwrap_or_else(|e| e.into_inner());
        let before = present.unwrap_or(false);
        *present = Some(now);
        before != now
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEYBOARD: &str = "ffffffffffffffff ffffffffffffffff fffffffffffffffe";

    fn device(name: &str, keys: &str) -> InputDevice {
        InputDevice {
            name: name.to_owned(),
            keys: keys.to_owned(),
        }
    }

    #[test]
    fn a_keyboard_and_a_gamepad_count() {
        assert!(is_navigation_input(&device(
            "AT Translated Set 2 keyboard",
            KEYBOARD
        )));
        // BTN_SOUTH.. (0x130 and up) are in the fifth word from the right (bits 256-319)
        assert!(is_navigation_input(&device(
            "Wireless Controller",
            "7cdb000000000000 0 0 0 0"
        )));
        // BTN_JOYSTICK / BTN_TRIGGER only (0x120)
        assert!(is_navigation_input(&device(
            "Joystick",
            "100000000 0 0 0 0"
        )));
    }

    #[test]
    fn what_cannot_navigate_does_not_count() {
        assert!(!is_navigation_input(&device(
            "Power Button",
            "10000000000000 0"
        )));
        assert!(!is_navigation_input(&device("Lid Switch", "")));
        // a mouse: BTN_LEFT, BTN_RIGHT, BTN_MIDDLE (0x110-0x112)
        assert!(!is_navigation_input(&device("USB Mouse", "10000 0 0 0 0")));
        // a laptop's hotkeys: a few multimedia keys, not the letter rows
        assert!(!is_navigation_input(&device(
            "Intel HID events",
            "0 800000000000 0"
        )));
        assert!(!is_navigation_input(&device("garbage", "zz qq")));
    }

    #[test]
    fn the_consoles_own_virtual_keyboard_does_not_count() {
        assert!(!is_navigation_input(&device(VIRTUAL_NAME, KEYBOARD)));
    }

    #[test]
    fn a_bitmap_with_fewer_words_than_the_bit_is_not_set() {
        assert!(!bit(&[], 0));
        assert!(!bit(&[1], 64));
        assert!(bit(&[1], 0));
        assert!(bit(&[1, 0], 64));
        assert!(!bit(&[1, 0], 0));
    }

    #[test]
    fn presence_follows_the_source_and_reports_changes() {
        let presence = InputPresence::new(FakeInput::new(vec![device(VIRTUAL_NAME, KEYBOARD)]));
        assert!(!presence.refresh(), "nothing found, nothing to announce");
        assert!(!presence.present());
        presence.source.set(vec![FakeInput::keyboard()]);
        assert!(presence.refresh());
        assert!(presence.present());
        assert!(!presence.refresh());
        presence.source.set(Vec::new());
        assert!(presence.refresh());
        assert!(!presence.present());
    }

    #[test]
    fn sysfs_is_read_from_the_input_directories() {
        let dir = tempfile::tempdir().expect("temp dir");
        let make = |dir_name: &str, name: &str, keys: Option<&str>| {
            let d = dir.path().join(dir_name);
            std::fs::create_dir_all(d.join("capabilities")).expect("dirs");
            std::fs::write(d.join("name"), format!("{name}\n")).expect("name");
            if let Some(keys) = keys {
                std::fs::write(d.join("capabilities").join("key"), format!("{keys}\n"))
                    .expect("keys");
            }
        };
        make("input0", "Power Button", Some("10000000000000 0"));
        make(
            "input3",
            "Wireless Controller",
            Some("7cdb000000000000 0 0 0 0"),
        );
        make("input4", "Motion Sensors", None);
        make("event3", "not an input node", Some(KEYBOARD));
        let source = SysfsInput::at(dir.path());
        let mut names: Vec<String> = source.devices().into_iter().map(|d| d.name).collect();
        names.sort();
        assert_eq!(
            names,
            ["Motion Sensors", "Power Button", "Wireless Controller"]
        );
        assert!(InputPresence::new(SysfsInput::at(dir.path())).refresh());
        assert!(SysfsInput::at(dir.path().join("missing"))
            .devices()
            .is_empty());
    }
}
