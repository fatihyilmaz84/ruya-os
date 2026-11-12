//! Whether a keyboard or a gamepad is connected (`Devices1.Bluetooth.InputPresent`, T-203), read
//! from the kernel's input devices in sysfs (`/sys/class/input/input*/name` and
//! `capabilities/key`). USB and Bluetooth devices look the same there. The console's own virtual
//! navigation keyboard (`ruya-inputd`) does not count, nor do buttons such as the power button.
//! The same read tells which game controllers came and went (`GamepadConnected` /
//! `GamepadDisconnected`, T-260). The rules are pure; `SysfsInput` is the only part that touches
//! the disk.

use std::path::PathBuf;
use std::sync::Mutex;

use crate::families::family_of;
use crate::pairing::clean_name;

/// The longest pad name or id the service reports, in characters.
pub const MAX_NAME_CHARS: usize = 64;

/// The name of the virtual keyboard `ruya-inputd` creates (`services/ruya-inputd`).
pub const VIRTUAL_NAME: &str = "RuyaOS Navigation";

/// One input device as sysfs shows it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct InputDevice {
    pub name: String,
    /// `uniq` (a Bluetooth pad's address) and `phys` (a USB pad's port), "" when there are none.
    pub uniq: String,
    pub phys: String,
    /// `id/bustype` (3 = USB, 5 = Bluetooth), `id/vendor`, `id/product`; 0 when unreadable.
    pub bustype: u16,
    pub vendor: u16,
    pub product: u16,
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

/// A game controller, as `GamepadConnected` / `GamepadDisconnected` tell it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Gamepad {
    /// Stable per pad and port: the Bluetooth address, else the USB port, else the name.
    pub id: String,
    pub name: String,
    /// "playstation" | "xbox" | "nintendo" | "8bitdo" | "" (`families.rs`).
    pub family: &'static str,
    /// "usb" | "bluetooth" | "other"
    pub transport: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GamepadEvent {
    Connected(Gamepad),
    Disconnected(Gamepad),
}

/// Microsoft's Xbox 360 Wireless Gaming Receiver for Windows (`045e:0719`, and `045e:0291` for the
/// older revision), which clones copy. The in-kernel `xpad` driver (type "Xbox 360 wireless", no
/// firmware) registers one input device per pad that is switched on, up to four, and names it
/// after the receiver ("Xbox 360 Wireless Receiver"), so every pad would look alike and say
/// "receiver". The receiver itself is a USB device only: with no pad on, it has no input device
/// and so never counts as a pad (RUY-154). Other ids are never guessed.
pub const XBOX360_RECEIVER_IDS: [(u16, u16); 2] = [(0x045e, 0x0719), (0x045e, 0x0291)];

/// What a pad behind an Xbox 360 receiver is called.
pub const XBOX360_PAD_NAME: &str = "Xbox 360 Controller";

/// Whether an input device is a pad that talks through an Xbox 360 wireless receiver.
pub fn is_behind_xbox360_receiver(device: &InputDevice) -> bool {
    XBOX360_RECEIVER_IDS.contains(&(device.vendor, device.product))
}

/// The pad behind an input device, or `None` for anything that is not one (a keyboard, a mouse,
/// a motion sensor, a touchpad, the console's own virtual keyboard).
pub fn gamepad_of(device: &InputDevice) -> Option<Gamepad> {
    if device.name == VIRTUAL_NAME {
        return None;
    }
    let words = parse_words(&device.keys);
    if !(0x120..0x13f).any(|n| bit(&words, n)) {
        return None;
    }
    // A pad names itself: control and format characters are dropped and the length is capped
    // before the name goes anywhere (T-260).
    let name = clean_name(&device.name, MAX_NAME_CHARS);
    let name = if is_behind_xbox360_receiver(device) {
        XBOX360_PAD_NAME.to_owned()
    } else if name.is_empty() {
        "Controller".to_owned()
    } else {
        name
    };
    // The vendor id a pad reports is the USB-IF one over USB and over Bluetooth alike.
    let family = if device.vendor != 0 {
        family_of(
            &format!("usb:v{:04X}p{:04X}d0000", device.vendor, device.product),
            &name,
        )
    } else {
        family_of("", &name)
    };
    let id = [
        clean_name(&device.uniq, MAX_NAME_CHARS),
        clean_name(&device.phys, MAX_NAME_CHARS),
        name.clone(),
    ]
    .into_iter()
    .find(|s| !s.is_empty())
    .unwrap_or_default();
    Some(Gamepad {
        id,
        name,
        family,
        transport: match device.bustype {
            3 => "usb",
            5 => "bluetooth",
            _ => "other",
        },
    })
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
                let text = |file: &str| {
                    std::fs::read_to_string(dir.join(file))
                        .map(|t| t.trim().to_owned())
                        .unwrap_or_default()
                };
                let number =
                    |file: &str| u16::from_str_radix(&text(&format!("id/{file}")), 16).unwrap_or(0);
                Some(InputDevice {
                    name: name.trim().to_owned(),
                    keys: keys.trim().to_owned(),
                    uniq: text("uniq"),
                    phys: text("phys"),
                    bustype: number("bustype"),
                    vendor: number("vendor"),
                    product: number("product"),
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
            ..InputDevice::default()
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
    pads: Mutex<Option<Vec<Gamepad>>>,
    events: Mutex<Vec<GamepadEvent>>,
}

impl<S: InputSource> InputPresence<S> {
    pub fn new(source: S) -> Self {
        InputPresence {
            source,
            present: Mutex::new(None),
            pads: Mutex::new(None),
            events: Mutex::new(Vec::new()),
        }
    }

    /// The controllers that appeared or went away since the last call, oldest first. The first
    /// read only sets the baseline: pads that are already there are not news.
    pub fn take_gamepad_events(&self) -> Vec<GamepadEvent> {
        std::mem::take(&mut *self.events.lock().unwrap_or_else(|e| e.into_inner()))
    }

    /// The controllers present at the last `refresh` (`ListGamepads`), one per pad, in the order
    /// the kernel lists them. Empty before the first read.
    pub fn pads(&self) -> Vec<Gamepad> {
        self.pads
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
            .unwrap_or_default()
    }

    fn follow_gamepads(&self, devices: &[InputDevice]) {
        let mut pads: Vec<Gamepad> = Vec::new();
        for pad in devices.iter().filter_map(gamepad_of) {
            if !pads.iter().any(|p| p.id == pad.id) {
                pads.push(pad);
            }
        }
        let mut known = self.pads.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(before) = known.as_ref() {
            let mut events = self.events.lock().unwrap_or_else(|e| e.into_inner());
            for gone in before.iter().filter(|b| !pads.iter().any(|p| p.id == b.id)) {
                events.push(GamepadEvent::Disconnected(gone.clone()));
            }
            for new in pads.iter().filter(|p| !before.iter().any(|b| b.id == p.id)) {
                events.push(GamepadEvent::Connected(new.clone()));
            }
        }
        *known = Some(pads);
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
        let devices = self.source.devices();
        self.follow_gamepads(&devices);
        let now = devices.iter().any(is_navigation_input);
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
            ..InputDevice::default()
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

    const PAD_KEYS: &str = "7cdb000000000000 0 0 0 0";

    fn pad(name: &str, phys: &str, uniq: &str, bustype: u16, vendor: u16) -> InputDevice {
        InputDevice {
            name: name.to_owned(),
            keys: PAD_KEYS.to_owned(),
            phys: phys.to_owned(),
            uniq: uniq.to_owned(),
            bustype,
            vendor,
            product: 0x0ce6,
        }
    }

    #[test]
    fn a_pad_is_told_by_family_transport_and_a_stable_id() {
        let usb = gamepad_of(&pad(
            "Wireless Controller",
            "usb-0000:00:14.0-2/input0",
            "",
            3,
            0x054c,
        ))
        .expect("a pad");
        assert_eq!(usb.family, "playstation");
        assert_eq!(usb.transport, "usb");
        assert_eq!(usb.id, "usb-0000:00:14.0-2/input0");
        let bt = gamepad_of(&pad(
            "Xbox Wireless Controller",
            "AA:BB:CC:00:00:01",
            "e4:17:d8:00:00:01",
            5,
            0x045e,
        ))
        .expect("a pad");
        assert_eq!((bt.family, bt.transport), ("xbox", "bluetooth"));
        assert_eq!(bt.id, "e4:17:d8:00:00:01", "the address wins over the port");
        let eightbit = gamepad_of(&pad("8BitDo Pro 2", "", "", 3, 0x2dc8)).expect("a pad");
        assert_eq!(eightbit.family, "8bitdo");
        assert_eq!(eightbit.id, "8BitDo Pro 2", "no port, no address: the name");
        // An unknown vendor is no family whatever it calls itself; no vendor at all is guessed.
        let clone = gamepad_of(&pad("Xbox clone", "p", "", 3, 0x1234)).expect("pad");
        assert_eq!(clone.family, "");
        let guessed = gamepad_of(&pad("DualSense", "p", "", 0, 0)).expect("pad");
        assert_eq!(guessed.family, "playstation");
    }

    /// What `xpad` registers for a pad behind the receiver: named after the receiver, the
    /// receiver's USB ids, one input device per pad (the port ends in the interface: input0, 2, 4, 6).
    fn pad360(port: &str, product: u16) -> InputDevice {
        InputDevice {
            product,
            ..pad("Xbox 360 Wireless Receiver", port, "", 3, 0x045e)
        }
    }

    #[test]
    fn the_xbox_360_receiver_itself_is_no_pad() {
        // With no pad switched on the receiver has no input device at all; if a node with the
        // receiver's name and ids shows up without any button, it is still not a pad.
        for product in [0x0719, 0x0291] {
            let receiver = InputDevice {
                name: "Xbox 360 Wireless Receiver".to_owned(),
                bustype: 3,
                vendor: 0x045e,
                product,
                keys: "0 0 0 0 0".to_owned(),
                ..InputDevice::default()
            };
            assert!(gamepad_of(&receiver).is_none());
            assert!(!is_navigation_input(&receiver));
        }
    }

    #[test]
    fn a_pad_behind_the_xbox_360_receiver_is_an_xbox_controller_over_usb() {
        // Both receiver revisions, and a clone with the same ids, are told alike.
        for product in [0x0719, 0x0291] {
            let p = gamepad_of(&pad360("usb-0000:00:14.0-2/input0", product)).expect("a pad");
            assert_eq!(p.name, "Xbox 360 Controller", "not the receiver's name");
            assert_eq!((p.family, p.transport), ("xbox", "usb"));
            assert_eq!(p.id, "usb-0000:00:14.0-2/input0");
        }
    }

    #[test]
    fn an_unknown_dongle_with_a_similar_name_is_not_matched() {
        // The name alone never makes a receiver pad: another vendor's "Xbox 360 Wireless
        // Receiver" keeps its own name and has no family. Same vendor, other product: no rename.
        let other = InputDevice {
            vendor: 0x1234,
            ..pad360("usb-1/input0", 0x0719)
        };
        let p = gamepad_of(&other).expect("a pad");
        assert_eq!(p.name, "Xbox 360 Wireless Receiver");
        assert_eq!(p.family, "");
        let sibling = pad360("usb-1/input0", 0x0b13);
        assert!(!is_behind_xbox360_receiver(&sibling));
        assert_eq!(
            gamepad_of(&sibling).expect("a pad").name,
            "Xbox 360 Wireless Receiver"
        );
    }

    #[test]
    fn pads_behind_a_receiver_come_and_go_and_unplugging_it_removes_them_all() {
        let input = InputPresence::new(FakeInput::new(vec![FakeInput::keyboard()]));
        input.refresh();
        let a = pad360("usb-1/input0", 0x0719);
        let b = pad360("usb-1/input2", 0x0719);
        input.source.set(vec![FakeInput::keyboard(), a.clone()]);
        input.refresh();
        input
            .source
            .set(vec![FakeInput::keyboard(), a.clone(), b.clone()]);
        input.refresh();
        let names: Vec<_> = input
            .take_gamepad_events()
            .into_iter()
            .map(|e| match e {
                GamepadEvent::Connected(p) => format!("+{}:{}", p.id, p.name),
                GamepadEvent::Disconnected(p) => format!("-{}", p.id),
            })
            .collect();
        assert_eq!(
            names,
            [
                "+usb-1/input0:Xbox 360 Controller",
                "+usb-1/input2:Xbox 360 Controller"
            ]
        );
        // One pad switched off: only it goes. The receiver unplugged: the rest, one event each,
        // and nothing for the receiver itself.
        input.source.set(vec![FakeInput::keyboard(), a.clone()]);
        input.refresh();
        input.source.set(vec![FakeInput::keyboard()]);
        input.refresh();
        let gone: Vec<_> = input
            .take_gamepad_events()
            .into_iter()
            .map(|e| match e {
                GamepadEvent::Disconnected(p) => p.id,
                GamepadEvent::Connected(_) => "unexpected".to_owned(),
            })
            .collect();
        assert_eq!(gone, ["usb-1/input2", "usb-1/input0"]);
        assert!(input.pads().is_empty());
    }

    #[test]
    fn a_name_a_pad_gives_itself_is_cleaned_and_capped() {
        let nasty = "<img src=\"http://x/y\">\n\u{202E}Pad\u{200B}\u{0007}";
        let p = gamepad_of(&pad(nasty, "usb-1", "", 3, 0x1234)).expect("a pad");
        assert_eq!(p.name, "<img src=\"http://x/y\">Pad");
        assert!(!p.name.chars().any(|c| c.is_control() || c == '\u{202E}'));
        let long = gamepad_of(&pad(&"x".repeat(500), "usb-1", "", 3, 0x1234)).expect("a pad");
        assert_eq!(long.name.chars().count(), MAX_NAME_CHARS);
        // Nothing left of the name: a plain word, and the id still works.
        let empty = gamepad_of(&pad("\n\u{200B}", "", "", 3, 0x1234)).expect("a pad");
        assert_eq!(empty.name, "Controller");
        assert_eq!(empty.id, "Controller");
        // The id from the port or the address is cleaned too.
        let ported = gamepad_of(&pad("Pad", "usb-1\n/input0", "", 3, 0x1234)).expect("a pad");
        assert_eq!(ported.id, "usb-1/input0");
    }

    #[test]
    fn only_a_pad_is_a_pad() {
        assert!(gamepad_of(&device("AT keyboard", KEYBOARD)).is_none());
        assert!(gamepad_of(&device("USB Mouse", "10000 0 0 0 0")).is_none());
        assert!(gamepad_of(&device("Wireless Controller Motion Sensors", "")).is_none());
        assert!(gamepad_of(&device(VIRTUAL_NAME, PAD_KEYS)).is_none());
    }

    #[test]
    fn pads_that_come_and_go_are_announced_once_after_the_baseline() {
        let presence = InputPresence::new(FakeInput::new(vec![pad(
            "Wireless Controller",
            "usb-1",
            "",
            3,
            0x054c,
        )]));
        presence.refresh();
        assert!(
            presence.take_gamepad_events().is_empty(),
            "a pad that was there at the start is the baseline, not news"
        );
        presence.refresh();
        assert!(presence.take_gamepad_events().is_empty(), "nothing changed");
        presence.source.set(vec![
            pad("Wireless Controller", "usb-1", "", 3, 0x054c),
            pad("Xbox Wireless Controller", "usb-2", "", 3, 0x045e),
            FakeInput::keyboard(),
        ]);
        presence.refresh();
        let events = presence.take_gamepad_events();
        assert_eq!(events.len(), 1, "the keyboard is no pad: {events:?}");
        assert!(matches!(&events[0], GamepadEvent::Connected(p) if p.family == "xbox"));
        assert!(presence.take_gamepad_events().is_empty(), "taken once");
        presence.source.set(vec![pad(
            "Xbox Wireless Controller",
            "usb-2",
            "",
            3,
            0x045e,
        )]);
        presence.refresh();
        let events = presence.take_gamepad_events();
        assert!(
            matches!(events.as_slice(), [GamepadEvent::Disconnected(p)] if p.family == "playstation"),
            "{events:?}"
        );
    }

    #[test]
    fn pads_lists_what_is_there_now_baseline_included() {
        let presence = InputPresence::new(FakeInput::new(vec![
            pad("Wireless Controller", "usb-1", "", 3, 0x054c),
            FakeInput::keyboard(),
            pad(
                "Xbox Wireless Controller",
                "bt-phys",
                "e4:17:d8:00:00:01",
                5,
                0x045e,
            ),
        ]));
        assert!(presence.pads().is_empty(), "nothing before the first read");
        presence.refresh();
        let pads = presence.pads();
        assert_eq!(pads.len(), 2, "the keyboard is no pad: {pads:?}");
        assert_eq!(
            (pads[0].id.as_str(), pads[0].family, pads[0].transport),
            ("usb-1", "playstation", "usb")
        );
        assert_eq!(
            (pads[1].id.as_str(), pads[1].family, pads[1].transport),
            ("e4:17:d8:00:00:01", "xbox", "bluetooth")
        );
        assert!(
            presence.take_gamepad_events().is_empty(),
            "the baseline is not news, but the list has it"
        );
        presence.source.set(vec![pad(
            "Xbox Wireless Controller",
            "usb-2",
            "",
            3,
            0x045e,
        )]);
        presence.refresh();
        assert_eq!(presence.pads().len(), 1, "a pad that left is gone");
    }

    #[test]
    fn a_pad_with_several_input_nodes_is_one_pad() {
        let node = pad("Wireless Controller", "usb-1", "", 3, 0x054c);
        let presence = InputPresence::new(FakeInput::new(Vec::new()));
        presence.refresh();
        presence.source.set(vec![node.clone(), node]);
        presence.refresh();
        assert_eq!(presence.take_gamepad_events().len(), 1);
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
        // The ids a pad reports (T-260): vendor and bus in hex, the port, no address over USB.
        let pad_dir = dir.path().join("input3");
        std::fs::create_dir_all(pad_dir.join("id")).expect("id dir");
        for (file, text) in [
            ("id/vendor", "054c"),
            ("id/product", "0ce6"),
            ("id/bustype", "0003"),
        ] {
            std::fs::write(pad_dir.join(file), format!("{text}\n")).expect("id");
        }
        std::fs::write(pad_dir.join("phys"), "usb-0000:00:14.0-2/input0\n").expect("phys");
        make("event3", "not an input node", Some(KEYBOARD));
        let source = SysfsInput::at(dir.path());
        let mut names: Vec<String> = source.devices().into_iter().map(|d| d.name).collect();
        names.sort();
        assert_eq!(
            names,
            ["Motion Sensors", "Power Button", "Wireless Controller"]
        );
        let pad = source
            .devices()
            .into_iter()
            .find(|d| d.name == "Wireless Controller")
            .and_then(|d| gamepad_of(&d))
            .expect("the pad is found with its ids");
        assert_eq!(
            (pad.family, pad.transport, pad.id.as_str()),
            ("playstation", "usb", "usb-0000:00:14.0-2/input0")
        );
        assert!(InputPresence::new(SysfsInput::at(dir.path())).refresh());
        assert!(SysfsInput::at(dir.path().join("missing"))
            .devices()
            .is_empty());
    }
}
