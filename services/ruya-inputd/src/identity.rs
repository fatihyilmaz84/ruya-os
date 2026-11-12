//! Device identity (06-input.md §4.1): the stable id, the family and the connection of a pad.

use std::fs;
use std::io::{self, Read, Write};
use std::path::Path;

use sha2::{Digest, Sha256};

/// Linux bus types (linux/input.h).
pub const BUS_USB: u16 = 0x03;
pub const BUS_BLUETOOTH: u16 = 0x05;
pub const BUS_VIRTUAL: u16 = 0x06;

pub const SALT_LEN: usize = 32;

/// What identifies one physical pad, as read from evdev and udev.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Hardware {
    pub bus: u16,
    pub vendor: u16,
    pub product: u16,
    /// `EVIOCGUNIQ`: the Bluetooth address (also on a DualSense over USB).
    pub uniq: String,
    /// udev `ID_SERIAL_SHORT`.
    pub serial: String,
    /// udev `ID_PATH`: the port the pad is plugged into.
    pub port_path: String,
    /// `EVIOCGPHYS`, the last resort.
    pub phys: String,
    /// The kernel driver of the pad's parent device (`xpad`, `playstation`, `nintendo`, ...).
    pub driver: String,
}

fn bus_name(bus: u16) -> &'static str {
    match bus {
        BUS_USB => "usb",
        BUS_BLUETOOTH => "bluetooth",
        _ => "virtual",
    }
}

/// The identifying string behind the hash: Bluetooth by address, USB by serial, else by port.
fn identifying(hw: &Hardware) -> String {
    let pick = [
        (hw.bus == BUS_BLUETOOTH, "mac", &hw.uniq),
        (true, "serial", &hw.serial),
        (true, "path", &hw.port_path),
        (true, "uniq", &hw.uniq),
        (true, "phys", &hw.phys),
    ];
    for (applies, kind, value) in pick {
        if applies && !value.trim().is_empty() {
            return format!("{kind}:{}", value.trim().to_ascii_lowercase());
        }
    }
    "none".to_owned()
}

/// `<bus>-<vid>-<pid>-<key>`: `key` is 12 hex digits of SHA-256(salt, identifying string), so a
/// MAC address or a serial never reaches the bus and the id is stable across reconnects.
pub fn stable_id(hw: &Hardware, salt: &[u8]) -> String {
    let mut hash = Sha256::new();
    hash.update(salt);
    hash.update(identifying(hw).as_bytes());
    let digest = hash.finalize();
    let key: String = digest[..6].iter().map(|b| format!("{b:02x}")).collect();
    format!(
        "{}-{:04x}-{:04x}-{key}",
        bus_name(hw.bus),
        hw.vendor,
        hw.product
    )
}

/// Xbox wireless receivers: one USB device, up to four pads behind it.
const RECEIVERS: [(u16, u16); 3] = [(0x045e, 0x0719), (0x045e, 0x0291), (0x045e, 0x02a9)];

/// "usb" | "bluetooth" | "receiver" | "virtual".
pub fn connection(hw: &Hardware) -> &'static str {
    match hw.bus {
        BUS_USB if RECEIVERS.contains(&(hw.vendor, hw.product)) => "receiver",
        BUS_USB => "usb",
        BUS_BLUETOOTH => "bluetooth",
        _ => "virtual",
    }
}

/// "xbox" | "playstation" | "nintendo" | "generic": by vendor id first, then by the kernel
/// driver (06-input.md §4.1).
pub fn family(hw: &Hardware) -> &'static str {
    match hw.vendor {
        0x045e => return "xbox",
        0x054c => return "playstation",
        0x057e => return "nintendo",
        _ => {}
    }
    match hw.driver.as_str() {
        "xpad" => "xbox",
        "playstation" | "sony" => "playstation",
        "nintendo" => "nintendo",
        _ => "generic",
    }
}

/// The machine salt in `dir/salt`: read it, or create it from `random` when there is none. A
/// salt of the wrong size is an error and is never overwritten (services/CLAUDE.md).
pub fn load_or_create_salt(dir: &Path, random: &mut dyn Read) -> io::Result<Vec<u8>> {
    let path = dir.join("salt");
    match fs::read(&path) {
        Ok(salt) if salt.len() == SALT_LEN => return Ok(salt),
        Ok(salt) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "{}: {} bytes, expected {SALT_LEN}",
                    path.display(),
                    salt.len()
                ),
            ))
        }
        Err(err) if err.kind() == io::ErrorKind::NotFound => {}
        Err(err) => return Err(err),
    }
    let mut salt = vec![0u8; SALT_LEN];
    random.read_exact(&mut salt)?;
    let tmp = dir.join("salt.tmp");
    {
        let mut file = fs::File::create(&tmp)?;
        file.write_all(&salt)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, &path)?;
    Ok(salt)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dualsense_bt() -> Hardware {
        Hardware {
            bus: BUS_BLUETOOTH,
            vendor: 0x054c,
            product: 0x0ce6,
            uniq: "a0:ab:51:12:34:56".into(),
            ..Hardware::default()
        }
    }

    #[test]
    fn the_id_has_bus_vid_pid_and_a_12_digit_key_without_the_mac() {
        let id = stable_id(&dualsense_bt(), b"salt");
        assert!(id.starts_with("bluetooth-054c-0ce6-"), "{id}");
        let key = id.rsplit('-').next().unwrap_or_default();
        assert_eq!(key.len(), 12);
        assert!(key.chars().all(|c| c.is_ascii_hexdigit()));
        assert!(!id.contains("a0:ab") && !id.contains("a0ab51"));
    }

    #[test]
    fn the_id_is_stable_and_depends_on_the_salt_and_the_address() {
        let a = stable_id(&dualsense_bt(), b"salt");
        assert_eq!(a, stable_id(&dualsense_bt(), b"salt"));
        assert_ne!(a, stable_id(&dualsense_bt(), b"other salt"));
        let mut other = dualsense_bt();
        other.uniq = "a0:ab:51:12:34:57".into();
        assert_ne!(a, stable_id(&other, b"salt"));
    }

    #[test]
    fn usb_pads_go_by_serial_then_by_port() {
        let base = Hardware {
            bus: BUS_USB,
            vendor: 0x045e,
            product: 0x028e,
            port_path: "pci-0000:00:14.0-usb-0:2:1.0".into(),
            ..Hardware::default()
        };
        let mut other_port = base.clone();
        other_port.port_path = "pci-0000:00:14.0-usb-0:3:1.0".into();
        // Two identical serial-less pads in two sockets are two ids.
        assert_ne!(stable_id(&base, b"s"), stable_id(&other_port, b"s"));
        // With a serial, the socket does not matter.
        let mut a = base.clone();
        a.serial = "ABC123".into();
        let mut b = other_port.clone();
        b.serial = "ABC123".into();
        assert_eq!(stable_id(&a, b"s"), stable_id(&b, b"s"));
    }

    #[test]
    fn family_by_vendor_then_driver() {
        assert_eq!(family(&dualsense_bt()), "playstation");
        let mut hw = Hardware {
            vendor: 0x2dc8,
            driver: "xpad".into(),
            ..Hardware::default()
        };
        assert_eq!(family(&hw), "xbox");
        hw.driver = "hid-generic".into();
        assert_eq!(family(&hw), "generic");
    }

    #[test]
    fn connection_names_receivers() {
        let mut hw = Hardware {
            bus: BUS_USB,
            vendor: 0x045e,
            product: 0x0719,
            ..Hardware::default()
        };
        assert_eq!(connection(&hw), "receiver");
        hw.product = 0x028e;
        assert_eq!(connection(&hw), "usb");
        assert_eq!(connection(&dualsense_bt()), "bluetooth");
        hw.bus = BUS_VIRTUAL;
        assert_eq!(connection(&hw), "virtual");
    }

    #[test]
    fn the_salt_is_created_once_and_a_bad_one_is_kept() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut random: &[u8] = &[7u8; 64];
        let salt = load_or_create_salt(dir.path(), &mut random).expect("created");
        assert_eq!(salt, vec![7u8; SALT_LEN]);
        let mut other: &[u8] = &[9u8; 64];
        assert_eq!(
            load_or_create_salt(dir.path(), &mut other).expect("read"),
            salt
        );
        fs::write(dir.path().join("salt"), b"short").expect("write");
        assert!(load_or_create_salt(dir.path(), &mut other).is_err());
        assert_eq!(
            fs::read(dir.path().join("salt")).expect("kept"),
            b"short".to_vec()
        );
    }
}
