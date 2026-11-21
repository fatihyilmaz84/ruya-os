//! Library service. Parsing and merging are pure and unit-tested on any host; the `flatpak`
//! command is behind `AppLister` (Linux only); the D-Bus front end is `dbus.rs`.

pub mod catalog;
pub mod choices;
pub mod dbus;
pub mod flatpak;
pub mod play;
pub mod runners;
pub mod steam;
pub mod vdf;
pub mod watch;
