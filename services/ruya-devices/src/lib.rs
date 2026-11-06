//! Devices service core (audio, network, Bluetooth, controller batteries, storage). Everything here is
//! platform-independent and unit-tested on any host; the D-Bus front end lives in `dbus.rs`, the
//! `wpctl`/`pw-dump` side in `pipewire.rs`, PipeWire's events in `events.rs`, the NetworkManager
//! side in `networkmanager.rs` and the UPower side (controller batteries, `battery.rs`) in
//! `upower.rs`; the BlueZ side (`bluetooth.rs`) in `bluez.rs`; the udisks2 side (drives and volumes,
//! `storage.rs`) in `udisks.rs`; how full the console's own storage is (`sysusage.rs`) is read from
//! `statvfs` and directory walks; the temperatures and fans (`thermal.rs`) from sysfs.

pub mod audio;
pub mod battery;
pub mod bluetooth;
#[cfg(target_os = "linux")]
pub mod bluez;
pub mod dbus;
pub mod debounce;
pub mod events;
pub mod network;
pub mod networkmanager;
pub mod pipewire;
pub mod storage;
pub mod store;
pub mod sysusage;
pub mod thermal;
#[cfg(target_os = "linux")]
pub mod udisks;
#[cfg(target_os = "linux")]
pub mod upower;

pub use audio::{Audio, Sink, Status};
