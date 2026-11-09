//! The "Network" and "Bluetooth" groups: what the hardware is. Which connection is active, its
//! address and the Wi-Fi signal belong to `Devices1.Network`, and the adapter's power and devices to
//! `Devices1.Bluetooth`; the shell puts them next to these.

use crate::source::Source;
use crate::tidy;
use crate::value::Info;

/// The interface of the default route with the lowest metric, from `/proc/net/route`.
pub fn default_interface(route: &str) -> Option<String> {
    let mut best: Option<(u32, String)> = None;
    for line in route.lines().skip(1) {
        let f: Vec<&str> = line.split_whitespace().collect();
        // Iface Destination Gateway Flags RefCnt Use Metric Mask ...
        if f.len() < 8 || f[1] != "00000000" || f[7] != "00000000" {
            continue;
        }
        let flags = u32::from_str_radix(f[3], 16).unwrap_or(0);
        if flags & 1 == 0 {
            continue; // RTF_UP
        }
        let metric: u32 = f[6].parse().unwrap_or(u32::MAX);
        match &best {
            Some((m, _)) if *m <= metric => {}
            _ => best = Some((metric, f[0].to_owned())),
        }
    }
    best.map(|(_, name)| name)
}

pub fn collect_static(src: &dyn Source, info: &mut Info) {
    if let Some(name) = src
        .read("/proc/net/route")
        .and_then(|r| default_interface(&r))
    {
        info.text("network.interface", &name);
        let base = format!("/sys/class/net/{name}");
        if let Some(mac) = src
            .read_trim(&format!("{base}/address"))
            .filter(|m| m != "00:00:00:00:00:00")
        {
            info.text("network.mac", mac);
        }
        // -1 is what the kernel says for "no link / not known" (Wi-Fi has no fixed speed).
        if let Some(mbps) = src
            .read_trim(&format!("{base}/speed"))
            .and_then(|s| s.parse::<i64>().ok())
            .filter(|s| *s > 0)
        {
            info.unsigned("network.link_mbps", mbps as u64);
        }
    }
    bluetooth(src, info);
}

/// The adapter address in `bluetoothctl show`: "Controller AA:BB:CC:DD:EE:FF (public)".
pub fn parse_bluetoothctl_address(output: &str) -> Option<String> {
    let line = output.lines().find(|l| l.starts_with("Controller "))?;
    let address = line.split_whitespace().nth(1)?;
    let ok = address.len() == 17
        && address
            .split(':')
            .all(|p| p.len() == 2 && p.chars().all(|c| c.is_ascii_hexdigit()));
    ok.then(|| address.to_ascii_uppercase())
}

fn bluetooth(src: &dyn Source, info: &mut Info) {
    let adapters: Vec<String> = src
        .list("/sys/class/bluetooth")
        .into_iter()
        .filter(|n| n.starts_with("hci") && !n.contains(':'))
        .collect();
    // The adapter the service picked as the primary one (the one with the paired devices); the first
    // in sysfs only when the service says nothing or names one that is not there.
    let primary = src.primary_bluetooth();
    let matched = primary.as_ref().filter(|(name, _)| adapters.contains(name));
    let Some(adapter) = matched
        .map(|(name, _)| name)
        .or_else(|| adapters.first())
        .cloned()
    else {
        return;
    };
    // The USB device the adapter sits on: the nearest parent that has an idVendor.
    if let Some(mut path) = src.resolve(&format!("/sys/class/bluetooth/{adapter}")) {
        while let Some((parent, _)) = path.rsplit_once('/') {
            path = parent.to_owned();
            if path.is_empty() {
                break;
            }
            if let Some(vendor) = src.read_trim(&format!("{path}/idVendor")) {
                let product_id = src
                    .read_trim(&format!("{path}/idProduct"))
                    .unwrap_or_default();
                let slot = path.rsplit('/').next().unwrap_or_default();
                let udev = src
                    .read(&format!("/run/udev/data/+usb:{slot}"))
                    .unwrap_or_default();
                let maker = src
                    .read(&format!("{path}/manufacturer"))
                    .map(|m| tidy(&m))
                    .filter(|m| !m.is_empty())
                    .or_else(|| crate::gpu::udev_property(&udev, "ID_VENDOR_FROM_DATABASE"));
                let product = src
                    .read(&format!("{path}/product"))
                    .map(|m| tidy(&m))
                    .filter(|m| !m.is_empty())
                    .or_else(|| crate::gpu::udev_property(&udev, "ID_MODEL_FROM_DATABASE"));
                let chipset = match (maker, product) {
                    (Some(m), Some(p)) if p.to_lowercase().contains(&m.to_lowercase()) => Some(p),
                    (Some(m), Some(p)) => Some(format!("{m} {p}")),
                    (None, Some(p)) => Some(p),
                    (Some(m), None) => Some(m),
                    (None, None) => None,
                };
                if let Some(chipset) = chipset {
                    info.text("bluetooth.chipset", chipset);
                }
                if !product_id.is_empty() {
                    info.text("bluetooth.usb_id", format!("{vendor}:{product_id}"));
                }
                break;
            }
        }
    }
    // The service's address is that of the adapter it named: used only when that adapter was the one described
    // above, else `bluetoothctl show` (the default controller) stays the fallback.
    let known = matched
        .map(|(_, address)| address.clone())
        .filter(|address| !address.is_empty());
    if let Some(address) = known.or_else(|| {
        src.run("bluetoothctl", &["show"])
            .and_then(|o| parse_bluetoothctl_address(&o))
    }) {
        info.text("bluetooth.address", address);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::FakeSource;

    #[test]
    fn default_route_with_the_lowest_metric() {
        let route =
            "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n\
                     wlp2s0\t00000000\t0100A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n\
                     eno1\t00000000\t0100A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n\
                     eno1\t0000A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n";
        assert_eq!(default_interface(route).as_deref(), Some("eno1"));
        assert_eq!(default_interface("Iface\tDestination\n"), None);
        assert_eq!(default_interface(""), None);
    }

    #[test]
    fn an_unknown_link_speed_is_absent() {
        let src = FakeSource::new()
            .file("/proc/net/route", "Iface Destination Gateway Flags RefCnt Use Metric Mask\nwlan0 00000000 0100A8C0 0003 0 0 600 00000000\n")
            .file("/sys/class/net/wlan0/address", "aa:bb:cc:dd:ee:ff\n")
            .file("/sys/class/net/wlan0/speed", "-1\n");
        let mut info = Info::new();
        collect_static(&src, &mut info);
        assert_eq!(info.get_text("network.mac"), Some("aa:bb:cc:dd:ee:ff"));
        assert!(!info.contains("network.link_mbps"));
    }

    #[test]
    fn bluetoothctl_address() {
        let out = "Controller 9C:B6:D0:12:34:56 (public)\n\tName: dell\n\tPowered: yes\n";
        assert_eq!(
            parse_bluetoothctl_address(out).as_deref(),
            Some("9C:B6:D0:12:34:56")
        );
        assert_eq!(
            parse_bluetoothctl_address("No default controller available\n"),
            None
        );
        assert_eq!(
            parse_bluetoothctl_address("Controller nonsense (public)\n"),
            None
        );
    }

    #[test]
    fn a_usb_adapter_names_its_chipset() {
        let dev = "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-10";
        let src = FakeSource::new()
            .link("/sys/class/bluetooth/hci0", &format!("{dev}/1-10:1.0/bluetooth/hci0"))
            .file(&format!("{dev}/idVendor"), "8087\n")
            .file(&format!("{dev}/idProduct"), "0a2b\n")
            .file("/run/udev/data/+usb:1-10", "E:ID_VENDOR_FROM_DATABASE=Intel Corp.\nE:ID_MODEL_FROM_DATABASE=Bluetooth wireless interface\n")
            .dir(&format!("{dev}/1-10:1.0/bluetooth/hci0"));
        let mut info = Info::new();
        collect_static(&src, &mut info);
        assert_eq!(
            info.get_text("bluetooth.chipset"),
            Some("Intel Corp. Bluetooth wireless interface")
        );
        assert_eq!(info.get_text("bluetooth.usb_id"), Some("8087:0a2b"));
        assert!(
            !info.contains("bluetooth.address"),
            "no bluetoothctl output: absent"
        );
    }

    #[test]
    fn no_adapter_nothing_reported() {
        let mut info = Info::new();
        collect_static(&FakeSource::new().dir("/sys/class/bluetooth"), &mut info);
        assert!(info.is_empty());
    }
}
