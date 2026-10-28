//! Devices service core (audio, network). Everything here is platform-independent and
//! unit-tested on any host; the D-Bus front end lives in `dbus.rs`, the `wpctl`/`pw-dump` side in
//! `pipewire.rs`, PipeWire's events in `events.rs` and the NetworkManager side in `networkmanager.rs`.

pub mod audio;
pub mod dbus;
pub mod events;
pub mod network;
pub mod networkmanager;
pub mod pipewire;
pub mod store;

pub use audio::{Audio, Sink, Status};
