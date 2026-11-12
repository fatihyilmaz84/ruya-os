//! ruya-session: launches installed apps as a profile (`org.ruyaos.Session1`).
//!
//! In the image (T-162) it runs as root on the system bus over `systemd::SystemdSpawner`; on a
//! development host `--session` serves the session bus over a fake spawner (T-139).
//!
//! The rules (registry, state machine, exit reasons) are in `session.rs` and need no OS; the OS
//! sits behind `Spawner` (`spawner.rs`) and `ProfileDirectory` (`directory.rs`); `dbus.rs` is the
//! thin adapter.

pub mod dbus;
pub mod directory;
pub mod follow;
pub mod scope;
pub mod session;
pub mod spawner;
#[cfg(target_os = "linux")]
pub mod systemd;
pub mod usage;
pub mod usage_store;
pub mod usage_tracker;
pub mod x11;
