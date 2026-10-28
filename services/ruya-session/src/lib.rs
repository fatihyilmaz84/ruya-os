//! ruya-session: launches installed apps as a profile (`org.ruyaos.Session1`).
//!
//! NOT IN THE IMAGE YET (T-139): there is no systemd unit, no D-Bus policy and no Containerfile
//! change, and the real spawner (`systemd-run`, see `spawner::launch_command`) is only a command
//! builder with tests. The service runs on a development host with `--session` and a fake
//! spawner. The unit, policy and VM check follow T-130.
//!
//! The rules (registry, state machine, exit reasons) are in `session.rs` and need no OS; the OS
//! sits behind `Spawner` (`spawner.rs`) and `ProfileDirectory` (`directory.rs`); `dbus.rs` is the
//! thin adapter.

pub mod dbus;
pub mod directory;
pub mod session;
pub mod spawner;
