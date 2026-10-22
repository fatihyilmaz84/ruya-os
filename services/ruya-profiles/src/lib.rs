//! Profiles service core. Everything here is platform-independent and unit-tested on any
//! host; the D-Bus front end lives in `dbus.rs` and Unix account handling in `accounts.rs`.

pub mod accounts;
pub mod dbus;
pub mod lockout;
pub mod pin;
pub mod service;
pub mod store;

pub use service::{ProfileService, Status};
pub use store::{Profile, Role};
