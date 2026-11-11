//! Devices service core (audio, network, Bluetooth, controller batteries, storage). Everything here is
//! platform-independent and unit-tested on any host; the D-Bus front end lives in `dbus.rs`, the
//! `wpctl`/`pw-dump` side in `pipewire.rs`, PipeWire's events in `events.rs`, the NetworkManager
//! side in `networkmanager.rs` and the UPower side (controller batteries, `battery.rs`) in
//! `upower.rs`; the BlueZ side (`bluetooth.rs`) in `bluez.rs`; the udisks2 side (drives and volumes,
//! `storage.rs`) in `udisks.rs`; how full the console's own storage is (`sysusage.rs`) is read from
//! `statvfs` and directory walks; the temperatures and fans (`thermal.rs`) from sysfs; the time zone
//! (`time.rs`) is kept by systemd-timedated (`timedate.rs`); what the console is made of (`sysinfo.rs`,
//! over the `ruya-sysinfo` crate) is read from `/proc` and `/sys`; a report is saved to a USB drive by
//! `report.rs`; the display's outputs and modes (`display.rs`, with the EDID parser `edid.rs`) are read
//! from `/sys/class/drm`, and a chosen mode reaches the next compositor start as a KMS config file.

pub mod audio;
pub mod backlight;
pub mod battery;
pub mod bluetooth;
#[cfg(target_os = "linux")]
pub mod bluez;
pub mod dbus;
pub mod debounce;
pub mod display;
pub mod drive_scan;
pub mod edid;
pub mod events;
pub mod families;
pub mod idle_pads;
pub mod input;
pub mod log;
pub mod network;
pub mod networkmanager;
pub mod output_policy;
pub mod pairing;
pub mod performance;
pub mod pipewire;
pub mod report;
pub mod storage;
pub mod store;
pub mod sysinfo;
pub mod sysusage;
pub mod thermal;
pub mod time;
#[cfg(target_os = "linux")]
pub mod timedate;
#[cfg(target_os = "linux")]
pub mod udisks;
#[cfg(target_os = "linux")]
pub mod upower;

pub use audio::{Audio, Sink, Status};
