//! The "Graphics" group: the GPU the kernel drives, its driver, and the connected display.
//!
//! The model comes from the udev database (`/run/udev/data/+pci:<slot>`, filled from the hwdb with
//! the PCI ids), the driver from the `driver` link, the Mesa version from the package database and
//! the NVIDIA version from `/proc/driver/nvidia/version`. What a session renders with (the OpenGL
//! or Vulkan renderer string, the mode in use) is only known to the shell and is not read here.

use crate::source::Source;
use crate::tidy;
use crate::value::Info;

/// Drivers that live in the kernel tree: they are versioned with the kernel.
const IN_TREE: &[&str] = &[
    "i915",
    "xe",
    "amdgpu",
    "radeon",
    "nouveau",
    "virtio-pci",
    "virtio_gpu",
    "bochs-drm",
    "bochs",
    "vmwgfx",
    "qxl",
    "simpledrm",
    "ast",
];

/// The maker's short name for the PCI vendor ids that matter.
pub fn vendor_name(id: &str) -> Option<&'static str> {
    match id.trim_start_matches("0x").to_ascii_lowercase().as_str() {
        "8086" => Some("Intel"),
        "1002" | "1022" => Some("AMD"),
        "10de" => Some("NVIDIA"),
        "1af4" | "1b36" => Some("Red Hat (virtual)"),
        "15ad" => Some("VMware"),
        "1234" => Some("QEMU (virtual)"),
        _ => None,
    }
}

/// `E:KEY=value` of a udev database file.
pub fn udev_property(text: &str, key: &str) -> Option<String> {
    let prefix = format!("E:{key}=");
    text.lines()
        .find_map(|l| l.strip_prefix(&prefix))
        .map(tidy)
        .filter(|v| !v.is_empty())
}

/// The marketing name in brackets when the database has one: "CometLake-S GT2 [UHD Graphics 630]"
/// is a "UHD Graphics 630".
pub fn model_name(database: &str) -> String {
    let database = tidy(database);
    match (database.rfind('['), database.rfind(']')) {
        (Some(open), Some(close)) if open < close && close > open + 1 => {
            database[open + 1..close].trim().to_owned()
        }
        _ => database,
    }
}

/// "NVRM version: NVIDIA UNIX x86_64 Kernel Module  550.54.14  Thu Mar ..." -> "550.54.14".
pub fn parse_nvidia_version(text: &str) -> Option<String> {
    let line = text.lines().find(|l| l.contains("Kernel Module"))?;
    let after = line.split("Kernel Module").nth(1)?;
    let version = after.split_whitespace().next()?;
    version
        .chars()
        .all(|c| c.is_ascii_digit() || c == '.')
        .then(|| version.to_owned())
}

struct Gpu {
    slot: String,
    device: String,
    vendor_id: String,
    boot: bool,
}

fn gpus(src: &dyn Source) -> Vec<Gpu> {
    let mut found = Vec::new();
    for name in src.list("/sys/class/drm") {
        let is_card = name
            .strip_prefix("card")
            .is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()));
        if !is_card {
            continue;
        }
        let link = format!("/sys/class/drm/{name}/device");
        let Some(device) = src.resolve(&link) else {
            continue;
        };
        let Some(vendor_id) = src.read_trim(&format!("{device}/vendor")) else {
            continue;
        };
        let slot = device.rsplit('/').next().unwrap_or_default().to_owned();
        let boot = src.read_trim(&format!("{device}/boot_vga")).as_deref() == Some("1");
        found.push(Gpu {
            slot,
            device,
            vendor_id,
            boot,
        });
    }
    // The one the firmware boots with first, the others in card order.
    found.sort_by_key(|g| !g.boot);
    found
}

/// The connected connector and its preferred (first listed) mode.
fn display(src: &dyn Source, info: &mut Info) {
    for name in src.list("/sys/class/drm") {
        let Some((card, connector)) = name.split_once('-') else {
            continue;
        };
        if !card.starts_with("card") || connector.is_empty() {
            continue;
        }
        if src
            .read_trim(&format!("/sys/class/drm/{name}/status"))
            .as_deref()
            != Some("connected")
        {
            continue;
        }
        info.text("graphics.connector", connector);
        if let Some(mode) = src
            .read(&format!("/sys/class/drm/{name}/modes"))
            .and_then(|m| m.lines().next().map(|l| l.trim().to_owned()))
        {
            info.text("graphics.preferred_mode", mode);
        }
        return;
    }
}

pub fn collect_static(src: &dyn Source, info: &mut Info) {
    if let Some(gpu) = gpus(src).first() {
        let udev = src
            .read(&format!("/run/udev/data/+pci:{}", gpu.slot))
            .unwrap_or_default();
        let device_id = src.read_trim(&format!("{}/device", gpu.device));
        let vendor = vendor_name(&gpu.vendor_id)
            .map(str::to_owned)
            .or_else(|| udev_property(&udev, "ID_VENDOR_FROM_DATABASE"));
        if let Some(vendor) = vendor {
            info.text("graphics.vendor", vendor);
        }
        if let Some(model) = udev_property(&udev, "ID_MODEL_FROM_DATABASE") {
            info.text("graphics.model", model_name(&model));
        }
        if let Some(device_id) = device_id {
            info.text(
                "graphics.pci_id",
                format!(
                    "{}:{}",
                    gpu.vendor_id.trim_start_matches("0x"),
                    device_id.trim_start_matches("0x")
                ),
            );
        }
        let driver = src
            .resolve(&format!("{}/driver", gpu.device))
            .and_then(|p| p.rsplit('/').next().map(str::to_owned));
        if let Some(driver) = &driver {
            info.text("graphics.driver", driver);
            let module = driver.replace('-', "_");
            let version = src
                .read_trim(&format!("/sys/module/{module}/version"))
                .or_else(|| {
                    IN_TREE
                        .contains(&driver.as_str())
                        .then(|| src.read_trim("/proc/sys/kernel/osrelease"))
                        .flatten()
                });
            if let Some(version) = version {
                info.text("graphics.driver_version", version);
            }
        }
        let nvidia = driver.as_deref() == Some("nvidia");
        if nvidia {
            if let Some(v) = src
                .read("/proc/driver/nvidia/version")
                .and_then(|t| parse_nvidia_version(&t))
            {
                info.text("graphics.nvidia_version", v);
            }
        } else if let Some(mesa) = src.run("rpm", &["-q", "--qf", "%{VERSION}", "mesa-dri-drivers"])
        {
            let mesa = mesa.trim();
            if !mesa.is_empty() && mesa.chars().all(|c| c.is_ascii_digit() || c == '.') {
                info.text("graphics.mesa_version", mesa);
            }
        }
    }
    display(src, info);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::FakeSource;

    #[test]
    fn model_in_brackets_is_the_marketing_name() {
        assert_eq!(
            model_name("CometLake-S GT2 [UHD Graphics 630]"),
            "UHD Graphics 630"
        );
        assert_eq!(model_name("GA104 [GeForce RTX 3070]"), "GeForce RTX 3070");
        assert_eq!(model_name("Virtio 1.0 GPU"), "Virtio 1.0 GPU");
        assert_eq!(model_name("Odd [] name"), "Odd [] name");
    }

    #[test]
    fn nvidia_version_line() {
        let text = "NVRM version: NVIDIA UNIX x86_64 Kernel Module  550.54.14  Thu Feb 22 01:44:30 UTC 2024\nGCC version:  gcc version 14.0\n";
        assert_eq!(parse_nvidia_version(text).as_deref(), Some("550.54.14"));
        assert_eq!(parse_nvidia_version("nothing"), None);
    }

    #[test]
    fn udev_property_lines() {
        let text = "S:foo\nE:ID_VENDOR_FROM_DATABASE=Intel Corporation\nE:ID_MODEL_FROM_DATABASE=CometLake-S GT2 [UHD Graphics 630]\n";
        assert_eq!(
            udev_property(text, "ID_VENDOR_FROM_DATABASE").as_deref(),
            Some("Intel Corporation")
        );
        assert_eq!(udev_property(text, "ID_MISSING"), None);
    }

    #[test]
    fn a_machine_without_a_gpu_reports_none_of_it() {
        let mut info = Info::new();
        collect_static(&FakeSource::new().dir("/sys/class/drm"), &mut info);
        assert!(info.is_empty());
    }

    #[test]
    fn an_unknown_vendor_falls_back_to_the_database() {
        let src = FakeSource::new()
            .link(
                "/sys/class/drm/card0/device",
                "/sys/devices/pci0000:00/0000:00:03.0",
            )
            .file("/sys/devices/pci0000:00/0000:00:03.0/vendor", "0x1ae0\n")
            .file(
                "/run/udev/data/+pci:0000:00:03.0",
                "E:ID_VENDOR_FROM_DATABASE=Google, Inc.\nE:ID_MODEL_FROM_DATABASE=Virtio GPU\n",
            );
        let mut info = Info::new();
        collect_static(&src, &mut info);
        assert_eq!(info.get_text("graphics.vendor"), Some("Google, Inc."));
        assert_eq!(info.get_text("graphics.model"), Some("Virtio GPU"));
        assert!(!info.contains("graphics.driver"), "no driver link: absent");
    }
}
