//! Who made an input device, and who may create one (06-input.md §3 rule 1, ADR-024 amendment
//! RUY-1061 a, RUY-1063). Pure: the marker files are `marks`, the ACL writes the router's.
//!
//! - **`/dev/uinput`** belongs to `ruya-input` (mode 0600) and carries one ACL entry, for the
//!   signed-in profile's user (Steam Input makes its own pads there); none while nobody is signed in
//!   (`locked`, the picker, a logout, the shell gone from the bus).
//! - **A parentless input device** (`/devices/virtual/input/inputN`: made through uinput; nothing
//!   in sysfs or udev names its creator, and its `phys` is whatever the creator wrote) is
//!   **foreign until marked**. `ruya-inputd` marks each device it makes (`/run/ruya-input/own/inputN`,
//!   right after `UI_DEV_CREATE`, removed before `UI_DEV_DESTROY`); root vouches for one of its own
//!   (`/run/ruya-input-trusted/inputN`: the VM and Dell checks' stand-in pads and keyboards), which
//!   is then treated as hardware. The udev rules (70/71/74) test the same files at every event, so a
//!   device processed before its marker is foreign at `add` and own at the next event: an own
//!   device can be briefly foreign, never the reverse. Kernel input numbers are never reused, so a
//!   stale marker can name no other device.
//! - **A foreign device** reaches neither the shell (no `uaccess`, `LIBINPUT_IGNORE_DEVICE`, no
//!   `power-switch`) nor `ruya-inputd`'s pad reader. A **foreign device** (Steam's virtual pad) is
//!   attributed to the profile that held `/dev/uinput` when it appeared, and only that profile's
//!   user may open it, only while that profile is signed in. One that appears within `HANDOVER`
//!   of a profile change is attributed to nobody (it may be the previous profile's): closed for
//!   its life.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use crate::acl;

/// The uinput node whose ACL names the signed-in profile's user.
pub const UINPUT_NODE: &str = "/dev/uinput";
/// The markers of the devices `ruya-inputd` made (its RuntimeDirectory, 0755).
pub const OWN_DIR: &str = "/run/ruya-input/own";
/// Root's markers (tmpfiles, root 0755): a parentless device root vouches for is hardware.
pub const TRUSTED_DIR: &str = "/run/ruya-input-trusted";
/// The udev property the rules set on every parentless event node: `own`, `trusted` or `foreign`.
pub const ORIGIN_PROPERTY: &str = "RUYA_INPUT_ORIGIN";
/// Where the kernel puts an input device that has no parent.
const PARENTLESS: &str = "/devices/virtual/input/";
/// A device that appears this soon after a profile change is attributed to nobody.
pub const HANDOVER: Duration = Duration::from_secs(2);

/// The origin of an input device, as udev and the service see it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Origin {
    /// It has a parent (USB, Bluetooth, a uhid device, a platform driver): real hardware.
    Physical,
    /// Made by `ruya-inputd` (its marker).
    Own,
    /// Made by root, which vouched for it (root's marker): treated as `Physical`.
    Trusted,
    /// Parentless and unmarked: made by a profile through `/dev/uinput`, or not marked yet.
    Foreign,
}

/// `input23`: the kernel's name for an input device (`input` and a decimal number), the only
/// names a marker file may have.
pub fn valid_sysname(name: &str) -> bool {
    name.strip_prefix("input")
        .is_some_and(|n| !n.is_empty() && n.len() <= 10 && n.bytes().all(|b| b.is_ascii_digit()))
}

/// The input device of a parentless devpath (`/devices/virtual/input/input23` or its event node
/// `/devices/virtual/input/input23/event17`), `None` for a device with a parent.
pub fn parentless_input(devpath: &str) -> Option<&str> {
    let rest = devpath.strip_prefix(PARENTLESS)?;
    let name = rest.split('/').next()?;
    valid_sysname(name).then_some(name)
}

/// The one classifier: where the device sits (`devpath`), what the udev rules found
/// (`udev_origin`, the `RUYA_INPUT_ORIGIN` property; "" when the event or database has none) and
/// whether the service's own marker names it (`own`).
pub fn classify(devpath: &str, udev_origin: &str, own: impl FnOnce(&str) -> bool) -> Origin {
    let Some(sysname) = parentless_input(devpath) else {
        return Origin::Physical;
    };
    if own(sysname) {
        Origin::Own
    } else if udev_origin == "trusted" {
        Origin::Trusted
    } else {
        Origin::Foreign
    }
}

/// True when `ruya-inputd` may read the device as a physical pad: hardware, or what root vouched
/// for. Never a parentless device by its phys (a profile can write `ruya-input/pad1` too).
pub fn reads_as_physical(devpath: &str, udev_origin: &str) -> bool {
    matches!(
        classify(devpath, udev_origin, |_| false),
        Origin::Physical | Origin::Trusted
    )
}

/// The profile that holds `/dev/uinput`, since when.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Holder {
    profile: String,
    uid: u32,
    since: Instant,
}

/// `/dev/uinput`'s holder and the foreign devices, by input device: the profile each is attributed
/// to (`None`: nobody, closed for its life).
#[derive(Debug, Default)]
pub struct Foreign {
    holder: Option<Holder>,
    devices: BTreeMap<String, Option<String>>,
}

impl Foreign {
    /// The signed-in profile changed (`""` and `None`: nobody). The ACLs to write follow from
    /// `uinput_acl` and `acls`.
    pub fn profile_changed(&mut self, profile: &str, uid: Option<u32>, now: Instant) {
        self.holder = match uid {
            Some(uid) if !profile.is_empty() => Some(Holder {
                profile: profile.to_owned(),
                uid,
                since: now,
            }),
            _ => None,
        };
    }

    /// The profile that holds `/dev/uinput` now ("" for nobody).
    pub fn holder(&self) -> &str {
        self.holder.as_ref().map_or("", |h| h.profile.as_str())
    }

    /// `/dev/uinput`'s ACL: the holder's user, or nobody but `ruya-input`.
    pub fn uinput_acl(&self) -> Vec<u8> {
        self.holder
            .as_ref()
            .map_or_else(acl::closed, |h| acl::only_user(h.uid))
    }

    /// A udev event on a foreign device: a new one is attributed to the holder unless the holder
    /// changed less than `HANDOVER` ago. The ACL it must have now.
    pub fn seen(&mut self, sysname: &str, now: Instant) -> Vec<u8> {
        if !self.devices.contains_key(sysname) {
            let to = self
                .holder
                .as_ref()
                .filter(|h| now.saturating_duration_since(h.since) >= HANDOVER)
                .map(|h| h.profile.clone());
            self.devices.insert(sysname.to_owned(), to);
        }
        self.acl_of(sysname)
    }

    /// A foreign device that was there before the service started: nobody's (who held
    /// `/dev/uinput` when it appeared is not known), closed for its life.
    pub fn found_at_start(&mut self, sysname: &str) {
        self.devices.insert(sysname.to_owned(), None);
    }

    /// A udev event of this foreign device was seen.
    pub fn knows(&self, sysname: &str) -> bool {
        self.devices.contains_key(sysname)
    }

    /// The profile a foreign device is attributed to (`None`: unknown or nobody's).
    pub fn attributed(&self, sysname: &str) -> Option<&str> {
        self.devices.get(sysname)?.as_deref()
    }

    /// The device is gone (udev `remove`), or it turned out to be ours or root's.
    pub fn forget(&mut self, sysname: &str) {
        self.devices.remove(sysname);
    }

    /// The ACL of one foreign device: its profile's user while that profile holds `/dev/uinput`.
    fn acl_of(&self, sysname: &str) -> Vec<u8> {
        match (&self.holder, self.attributed(sysname)) {
            (Some(h), Some(p)) if h.profile == p => acl::only_user(h.uid),
            _ => acl::closed(),
        }
    }

    /// Every foreign device with the ACL it must have now (after a profile change).
    pub fn acls(&self) -> Vec<(String, Vec<u8>)> {
        self.devices
            .keys()
            .map(|s| (s.clone(), self.acl_of(s)))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const P1: u32 = 1001;
    const P2: u32 = 1002;

    #[test]
    fn a_sysname_is_input_and_digits_only() {
        assert!(valid_sysname("input23"));
        assert!(!valid_sysname("input"));
        assert!(!valid_sysname("input2x"));
        assert!(!valid_sysname("../input2"));
        assert!(!valid_sysname("event17"));
        assert!(!valid_sysname("input12345678901"));
    }

    #[test]
    fn only_a_device_under_virtual_input_is_parentless() {
        assert_eq!(
            parentless_input("/devices/virtual/input/input23/event17"),
            Some("input23")
        );
        assert_eq!(
            parentless_input("/devices/virtual/input/input23"),
            Some("input23")
        );
        // USB, and a uhid device (a Bluetooth LE pad through BlueZ): they have a parent.
        assert_eq!(
            parentless_input(
                "/devices/pci0000:00/0000:00:14.0/usb1/1-2/1-2:1.0/input/input5/event4"
            ),
            None
        );
        assert_eq!(
            parentless_input(
                "/devices/virtual/misc/uhid/0005:045E:0B13.0001/input/input30/event20"
            ),
            None
        );
        assert_eq!(parentless_input("/devices/virtual/input/mice"), None);
    }

    #[test]
    fn the_classifier_names_own_trusted_foreign_and_physical() {
        let pad = "/devices/virtual/input/input23/event17";
        assert_eq!(classify(pad, "", |s| s == "input23"), Origin::Own);
        // The service's marker decides "own", not what udev said at the add.
        assert_eq!(classify(pad, "foreign", |s| s == "input23"), Origin::Own);
        assert_eq!(classify(pad, "trusted", |_| false), Origin::Trusted);
        assert_eq!(classify(pad, "", |_| false), Origin::Foreign);
        assert_eq!(classify(pad, "own", |_| false), Origin::Foreign);
        let usb = "/devices/pci0000:00/usb1/1-2/1-2:1.0/input/input5/event4";
        assert_eq!(classify(usb, "", |_| false), Origin::Physical);
    }

    #[test]
    fn a_foreign_device_becomes_own_once_it_is_marked() {
        // Processed before the marker (the add), then marked: the next event's answer is own.
        let pad = "/devices/virtual/input/input23/event17";
        let mut marked = false;
        assert_eq!(classify(pad, "foreign", |_| marked), Origin::Foreign);
        marked = true;
        assert_eq!(classify(pad, "foreign", |_| marked), Origin::Own);
    }

    #[test]
    fn a_parentless_device_is_never_read_as_a_physical_pad_whatever_its_phys() {
        // The phys is not part of the question at all: `ruya-input/pad1` from a profile is foreign.
        let pad = "/devices/virtual/input/input40/event30";
        assert!(!reads_as_physical(pad, ""));
        assert!(!reads_as_physical(pad, "foreign"));
        assert!(!reads_as_physical(pad, "own"));
        assert!(reads_as_physical(pad, "trusted"));
        assert!(reads_as_physical(
            "/devices/pci0000:00/usb1/1-2/1-2:1.0/input/input5/event4",
            ""
        ));
    }

    #[test]
    fn uinput_names_the_signed_in_profile_only() {
        let t = Instant::now();
        let mut f = Foreign::default();
        assert_eq!(f.uinput_acl(), acl::closed(), "nobody signed in at start");
        f.profile_changed("p1", Some(P1), t);
        assert!(acl::is_only_user(&f.uinput_acl(), P1));
        assert_eq!(f.holder(), "p1");
        f.profile_changed("p2", Some(P2), t);
        assert!(acl::is_only_user(&f.uinput_acl(), P2));
        f.profile_changed("", None, t);
        assert_eq!(f.uinput_acl(), acl::closed());
        assert_eq!(f.holder(), "");
    }

    #[test]
    fn a_foreign_pad_opens_for_its_profile_only_while_that_profile_is_signed_in() {
        let t = Instant::now();
        let mut f = Foreign::default();
        f.profile_changed("p1", Some(P1), t);
        let acl = f.seen("input40", t + HANDOVER);
        assert!(acl::is_only_user(&acl, P1));
        assert_eq!(f.attributed("input40"), Some("p1"));
        // A switch to p2: p1's device closes; it stays p1's.
        f.profile_changed("p2", Some(P2), t + HANDOVER * 2);
        assert_eq!(f.acls(), vec![("input40".to_owned(), acl::closed())]);
        assert_eq!(f.seen("input40", t + HANDOVER * 3), acl::closed());
        // Locked, then p1 again: open for p1 again.
        f.profile_changed("", None, t + HANDOVER * 4);
        assert_eq!(f.acls(), vec![("input40".to_owned(), acl::closed())]);
        f.profile_changed("p1", Some(P1), t + HANDOVER * 5);
        assert!(acl::is_only_user(&f.acls()[0].1, P1));
        f.forget("input40");
        assert!(f.acls().is_empty());
    }

    #[test]
    fn a_device_that_appears_within_the_handover_is_nobodys_for_its_life() {
        let t = Instant::now();
        let mut f = Foreign::default();
        f.profile_changed("p1", Some(P1), t);
        f.profile_changed("p2", Some(P2), t + HANDOVER * 3);
        // 1.9 s after the switch: it may be p1's, made just before it.
        let acl = f.seen("input41", t + HANDOVER * 3 + Duration::from_millis(1900));
        assert_eq!(acl, acl::closed());
        assert_eq!(f.attributed("input41"), None);
        // Later events and profile changes never attribute it.
        assert_eq!(f.seen("input41", t + HANDOVER * 9), acl::closed());
        f.profile_changed("p1", Some(P1), t + HANDOVER * 10);
        assert_eq!(f.acls(), vec![("input41".to_owned(), acl::closed())]);
        // At 2 s it is the holder's.
        let acl = f.seen("input42", t + HANDOVER * 11);
        assert!(acl::is_only_user(&acl, P1));
    }

    #[test]
    fn a_device_made_while_nobody_holds_uinput_is_nobodys() {
        let t = Instant::now();
        let mut f = Foreign::default();
        assert_eq!(f.seen("input43", t + HANDOVER), acl::closed());
        f.profile_changed("p1", Some(P1), t + HANDOVER);
        assert_eq!(f.acls(), vec![("input43".to_owned(), acl::closed())]);
    }
}
