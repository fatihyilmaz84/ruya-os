//! Notifications service core (org.ruyaos.Notifications1): the notification centre's history
//! and settings, per profile. Everything but `dbus.rs` and the store's files is
//! platform-independent and unit-tested on any host.

pub mod caller;
pub mod dbus;
pub mod history;
pub mod service;
pub mod settings;
pub mod store;

pub use history::{Event, Item, NewItem, Reason, Status};
pub use service::{Notifications, Profiles};
