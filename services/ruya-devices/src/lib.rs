//! Devices service core (audio, network, controller batteries). Everything here is
//! platform-independent and unit-tested on any host; the D-Bus front end lives in `dbus.rs`, the
//! `wpctl`/`pw-dump` side in `pipewire.rs`, PipeWire's events in `events.rs`, the NetworkManager
//! side in `networkmanager.rs` and the UPower side (controller batteries, `battery.rs`) in
//! `upower.rs`.

pub mod audio;
pub mod battery;
pub mod dbus;
pub mod events;
pub mod network;
pub mod networkmanager;
pub mod pipewire;
pub mod store;
#[cfg(target_os = "linux")]
pub mod upower;

pub use audio::{Audio, Sink, Status};
