//! Whole machines through the whole collector. The fixtures are dumps (`FakeSource::from_dump`):
//! `dell.dump` is the Dell the T-226 task describes (written from the task text, not captured),
//! `stripped.dump` a bare virtual machine.

use ruya_sysinfo::{collect, collect_live, collect_static, FakeSource, Info, LIVE_KEYS};

fn dell() -> FakeSource {
    FakeSource::from_dump(include_str!("fixtures/dell.dump"))
}

fn stripped() -> FakeSource {
    FakeSource::from_dump(include_str!("fixtures/stripped.dump"))
}

#[test]
fn the_dell_is_described() {
    let info = collect(&dell());
    assert_eq!(info.get_text("console.name"), Some("RuyaOS"));
    assert_eq!(info.get_text("console.version"), Some("0.0.50"));
    assert_eq!(
        info.get_text("console.kernel"),
        Some("6.18.3-200.fc44.x86_64")
    );
    assert_eq!(info.get_text("console.arch"), Some("x86_64"));
    assert_eq!(info.get_text("console.deployment"), Some("9f3a1c7be2d4"));
    assert_eq!(info.get_text("console.installed"), Some("2025-11"));
    assert_eq!(info.get_text("console.firmware"), Some("uefi"));
    assert_eq!(info.get_flag("console.secure_boot"), Some(false));
    assert_eq!(info.get_text("console.vendor"), Some("Dell Inc."));
    assert_eq!(info.get_text("console.model"), Some("OptiPlex 3080"));
    assert_eq!(info.get_unsigned("console.uptime_s"), Some(93_784));
    assert!(
        !info.contains("console.image"),
        "bootc status is not readable here: absent"
    );

    assert_eq!(
        info.get_text("cpu.model"),
        Some("Intel(R) Core(TM) i5-10500T CPU @ 2.30GHz")
    );
    assert_eq!(info.get_unsigned("cpu.cores"), Some(6));
    assert_eq!(info.get_unsigned("cpu.threads"), Some(12));
    assert_eq!(info.get_unsigned("cpu.freq_max_mhz"), Some(3800));
    assert_eq!(
        info.get_unsigned("cpu.freq_mhz"),
        Some(3799),
        "the busiest core, in whole MHz"
    );

    assert_eq!(
        info.get_unsigned("memory.total_bytes"),
        Some(7_970_348 * 1024)
    );
    assert_eq!(
        info.get_unsigned("memory.available_bytes"),
        Some(5_214_420 * 1024)
    );
    assert_eq!(
        info.get_unsigned("memory.used_bytes"),
        Some((7_970_348 - 5_214_420) * 1024)
    );
    assert_eq!(
        info.get_unsigned("memory.swap_total_bytes"),
        Some(7_970_344 * 1024)
    );
    assert_eq!(
        info.get_unsigned("memory.swap_used_bytes"),
        Some(0),
        "swap that is there and unused is 0"
    );
    assert_eq!(info.get_unsigned("memory.zram_bytes"), Some(7_970_349_056));

    assert_eq!(info.get_text("graphics.vendor"), Some("Intel"));
    assert_eq!(info.get_text("graphics.model"), Some("UHD Graphics 630"));
    assert_eq!(info.get_text("graphics.pci_id"), Some("8086:9bc8"));
    assert_eq!(info.get_text("graphics.driver"), Some("i915"));
    assert_eq!(
        info.get_text("graphics.driver_version"),
        Some("6.18.3-200.fc44.x86_64")
    );
    assert_eq!(info.get_text("graphics.mesa_version"), Some("25.2.6"));
    assert!(!info.contains("graphics.nvidia_version"));
    assert_eq!(info.get_text("graphics.connector"), Some("HDMI-A-1"));
    assert_eq!(info.get_text("graphics.preferred_mode"), Some("1920x1080"));

    let drives = info.get_table("storage.drives").expect("drives");
    assert_eq!(drives.len(), 1);
    assert_eq!(drives[0].get_text("model"), Some("Samsung SSD 870"));
    assert_eq!(drives[0].get_text("type"), Some("ssd"));
    assert_eq!(drives[0].get_unsigned("size_bytes"), Some(500_107_862_016));

    assert_eq!(info.get_text("network.interface"), Some("eno1"));
    assert_eq!(info.get_text("network.mac"), Some("c8:4b:d6:aa:bb:cc"));
    assert_eq!(info.get_unsigned("network.link_mbps"), Some(1000));

    assert_eq!(
        info.get_text("bluetooth.chipset"),
        Some("Intel Corp. Bluetooth wireless interface")
    );
    assert_eq!(info.get_text("bluetooth.usb_id"), Some("8087:0a2b"));
    assert_eq!(
        info.get_text("bluetooth.address"),
        Some("9C:B6:D0:12:34:56")
    );
}

#[test]
fn a_stripped_machine_reports_only_what_it_has() {
    let info = collect(&stripped());
    assert_eq!(info.get_text("console.name"), Some("RuyaOS"));
    assert_eq!(info.get_text("console.firmware"), Some("bios"));
    assert_eq!(
        info.get_text("cpu.model"),
        Some("QEMU Virtual CPU version 2.5+")
    );
    assert_eq!(info.get_unsigned("cpu.threads"), Some(2));
    assert_eq!(
        info.get_unsigned("memory.total_bytes"),
        Some(2_018_244 * 1024)
    );
    assert_eq!(
        info.get_unsigned("memory.used_bytes"),
        Some((2_018_244 - 1_700_000) * 1024)
    );

    // No GPU, no swap, no drives, no network, no DMI, no cpufreq: absent, never zero.
    for key in [
        "console.vendor",
        "console.model",
        "console.secure_boot",
        "console.installed",
        "console.deployment",
        "console.image",
        "cpu.cores",
        "cpu.freq_max_mhz",
        "memory.swap_total_bytes",
        "memory.swap_used_bytes",
        "memory.zram_bytes",
        "graphics.vendor",
        "graphics.model",
        "graphics.driver",
        "graphics.connector",
        "storage.drives",
        "network.interface",
        "network.mac",
        "bluetooth.chipset",
        "bluetooth.address",
    ] {
        assert!(!info.contains(key), "{key} must be absent on this machine");
    }
    // A zero must never stand in for a missing value.
    for (key, value) in info.iter() {
        assert_ne!(
            value,
            &ruya_sysinfo::Value::Unsigned(0),
            "{key} is 0: absent values must not be reported as 0"
        );
    }
}

#[test]
fn an_unreadable_machine_gives_an_empty_report() {
    let info = collect(&FakeSource::new());
    assert!(info.is_empty(), "{info:?}");
}

#[test]
fn live_values_follow_the_files_and_the_rest_stays() {
    let before = collect_live(&dell());
    let changed = dell()
        .file("/proc/meminfo", "MemTotal: 7970348 kB\nMemAvailable: 1000000 kB\nSwapTotal: 7970344 kB\nSwapFree: 7000000 kB\n")
        .file("/proc/uptime", "100.0 1.0\n");
    let after = collect_live(&changed);
    assert_ne!(
        before.get_unsigned("memory.used_bytes"),
        after.get_unsigned("memory.used_bytes")
    );
    assert_eq!(
        after.get_unsigned("memory.used_bytes"),
        Some((7_970_348 - 1_000_000) * 1024)
    );
    assert_eq!(
        after.get_unsigned("memory.swap_used_bytes"),
        Some((7_970_344 - 7_000_000) * 1024)
    );
    assert_eq!(after.get_unsigned("console.uptime_s"), Some(100));
    // The static part is the same whatever the live files say.
    let a: Info = collect_static(&dell());
    let b: Info = collect_static(&changed);
    assert_eq!(a, b);
    // Every key the live read yields is declared live.
    for (key, _) in after.iter() {
        assert!(LIVE_KEYS.contains(&key.as_str()));
    }
}
