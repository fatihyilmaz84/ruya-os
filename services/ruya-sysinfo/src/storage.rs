//! The "Storage" group: the machine's internal drives, as hardware. How full the console's own
//! storage is stays with `Devices1.Storage.GetSystemUsage` (T-196), and temperatures with
//! `Devices1.Thermal` (T-200); neither is read here.

use crate::source::Source;
use crate::tidy;
use crate::value::{Info, Value};

/// Block devices that are not drives.
const NOT_DRIVES: &[&str] = &[
    "loop", "ram", "zram", "dm-", "md", "sr", "fd", "nbd", "nullb",
];

/// "nvme", "ssd", "hdd" or "emmc".
fn drive_type(name: &str, rotational: Option<bool>) -> &'static str {
    if name.starts_with("nvme") {
        "nvme"
    } else if name.starts_with("mmcblk") {
        "emmc"
    } else if rotational == Some(true) {
        "hdd"
    } else {
        "ssd"
    }
}

/// An NVMe controller's `state` as health: "live" is fine, "dead" and "deleting" are not; the
/// transient states say nothing yet. There is no SMART data in sysfs, so nothing else is claimed.
pub fn nvme_health(state: &str) -> Option<&'static str> {
    match state.trim() {
        "live" => Some("ok"),
        "dead" | "deleting" | "deleting (no IO)" => Some("failed"),
        _ => None,
    }
}

pub fn collect_static(src: &dyn Source, info: &mut Info) {
    let mut drives = Vec::new();
    for name in src.list("/sys/block") {
        if NOT_DRIVES.iter().any(|p| name.starts_with(p)) || name.contains("boot") {
            continue;
        }
        let dir = format!("/sys/block/{name}");
        if src.read_trim(&format!("{dir}/removable")).as_deref() == Some("1") {
            continue;
        }
        // An external disk on a USB cable is not part of the machine.
        if src.resolve(&dir).is_some_and(|p| p.contains("/usb")) {
            continue;
        }
        // 512-byte sectors, whatever the drive's own sector size.
        let Some(size) = src.read_u64(&format!("{dir}/size")).filter(|s| *s > 0) else {
            continue;
        };
        let rotational = src
            .read_trim(&format!("{dir}/queue/rotational"))
            .map(|r| r == "1");
        let kind = drive_type(&name, rotational);
        let mut row = Info::new();
        if let Some(model) = src.read(&format!("{dir}/device/model")).map(|m| tidy(&m)) {
            row.text("model", model);
        }
        row.text("type", kind);
        row.unsigned("size_bytes", size.saturating_mul(512));
        if kind == "nvme" {
            if let Some(health) = src
                .read(&format!("{dir}/device/state"))
                .and_then(|s| nvme_health(&s))
            {
                row.text("health", health);
            }
        }
        drives.push(row);
    }
    if !drives.is_empty() {
        info.set("storage.drives", Value::Table(drives));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::FakeSource;

    #[test]
    fn types_by_name_and_rotation() {
        assert_eq!(drive_type("nvme0n1", Some(false)), "nvme");
        assert_eq!(drive_type("sda", Some(true)), "hdd");
        assert_eq!(drive_type("sda", Some(false)), "ssd");
        assert_eq!(drive_type("sda", None), "ssd");
        assert_eq!(drive_type("mmcblk0", Some(false)), "emmc");
    }

    #[test]
    fn nvme_state_is_the_only_health() {
        assert_eq!(nvme_health("live\n"), Some("ok"));
        assert_eq!(nvme_health("dead"), Some("failed"));
        assert_eq!(nvme_health("resetting"), None);
    }

    #[test]
    fn only_internal_drives_are_listed() {
        let src = FakeSource::new()
            .file("/sys/block/sda/size", "976773168\n")
            .file("/sys/block/sda/queue/rotational", "0\n")
            .file("/sys/block/sda/removable", "0\n")
            .file("/sys/block/sda/device/model", "Samsung SSD 870    \n")
            .file("/sys/block/sdb/size", "30031872\n")
            .file("/sys/block/sdb/removable", "1\n")
            .file("/sys/block/loop0/size", "2048\n")
            .file("/sys/block/zram0/size", "2048\n")
            .file("/sys/block/sdc/size", "1953525168\n")
            .file("/sys/block/sdc/removable", "0\n")
            .link("/sys/block/sdc", "/sys/devices/pci0000:00/0000:00:14.0/usb2/2-1/2-1:1.0/host6/target6:0:0/6:0:0:0/block/sdc")
            .dir("/sys/devices/pci0000:00/0000:00:14.0/usb2/2-1/2-1:1.0/host6/target6:0:0/6:0:0:0/block/sdc");
        let mut info = Info::new();
        collect_static(&src, &mut info);
        let rows = info.get_table("storage.drives").expect("a table");
        assert_eq!(
            rows.len(),
            1,
            "removable, loop, zram and USB-attached disks are not drives: {rows:?}"
        );
        assert_eq!(rows[0].get_text("model"), Some("Samsung SSD 870"));
        assert_eq!(rows[0].get_unsigned("size_bytes"), Some(976_773_168 * 512));
        assert_eq!(rows[0].get_text("type"), Some("ssd"));
        assert!(!rows[0].contains("health"), "no health for a SATA drive");
    }

    #[test]
    fn no_drives_no_table() {
        let mut info = Info::new();
        collect_static(&FakeSource::new(), &mut info);
        assert!(!info.contains("storage.drives"));
    }
}
