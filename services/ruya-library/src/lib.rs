//! Library service. Parsing and merging are pure and unit-tested on any host; the `flatpak`
//! command is behind `AppLister` (Linux only); the D-Bus front end is `dbus.rs`. The Steam reader
//! (`steam.rs`) runs only as `ruya-library profile-scan`, as a profile's user (ADR-045); its
//! document is `profile_items.rs` and the per-profile view `view.rs`; the games its installations
//! make, with the player's links (RUY-137), are `games.rs`.

pub mod catalog;
pub mod choices;
pub mod dbus;
pub mod flatpak;
pub mod games;
pub mod play;
pub mod profile_items;
pub mod runners;
pub mod steam;
pub mod view;
pub mod watch;
