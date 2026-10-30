//! Update service. The rules (`service.rs`) and the reading of `bootc status --json`
//! (`bootc.rs`) are platform-independent and unit-tested on any host; the D-Bus front end is
//! `dbus.rs`.

pub mod bootc;
pub mod dbus;
pub mod service;
