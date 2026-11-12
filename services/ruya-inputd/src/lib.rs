//! Ruya Input (06-input.md): reads every gamepad, turns it into navigation keys for the shell
//! (Phase 0, `mapping`) and, while an app has the focus, into Xbox 360-style virtual pads of
//! the app's profile (`routing`). The rules are pure and unit-tested on any host; evdev, uinput,
//! udev and the ACLs are behind `routing::Backend` (`linux`); `dbus` serves `org.ruyaos.Input1`.

pub mod accounts;
pub mod acl;
pub mod dbus;
pub mod identity;
pub mod mapping;
pub mod notify;
pub mod pad;
pub mod routing;
pub mod udev;

#[cfg(target_os = "linux")]
pub mod linux;
