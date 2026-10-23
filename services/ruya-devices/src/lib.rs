//! Audio service core. Everything here is platform-independent and unit-tested on any host;
//! the D-Bus front end lives in `dbus.rs` and the `wpctl`/`pw-dump` side in `pipewire.rs`.

pub mod audio;
pub mod dbus;
pub mod pipewire;
pub mod store;

pub use audio::{Audio, Sink, Status};
