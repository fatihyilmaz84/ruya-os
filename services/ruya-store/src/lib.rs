//! Store service. Everything here is platform-independent and unit-tested on any host, except the
//! `flatpak` command itself (`flatpak_cli.rs`, Linux); the D-Bus front end is `dbus.rs`.

pub mod app;
pub mod appstream;
pub mod dbus;
pub mod flatpak;
#[cfg(target_os = "linux")]
pub mod flatpak_cli;
pub mod queue;
pub mod service;
