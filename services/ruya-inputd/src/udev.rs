//! udev without libudev: the monitor messages udevd broadcasts after it processed an event
//! (netlink group 2, the "libudev" framing) and the database files in `/run/udev/data`. Pure
//! parsers here; the Linux backend owns the socket.

use std::collections::HashMap;

/// One processed udev event, the properties the service uses.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UdevEvent {
    pub action: String,
    pub subsystem: String,
    /// `/devices/virtual/input/input23/event17`
    pub devpath: String,
    /// `/dev/input/event17` (absent on the input device itself)
    pub devname: String,
}

impl UdevEvent {
    /// The input device (`input23`) this node belongs to: the last but one path component.
    pub fn parent_sysname(&self) -> Option<&str> {
        let mut parts = self.devpath.rsplit('/');
        parts.next()?;
        parts.next()
    }

    pub fn is_event_node(&self) -> bool {
        self.subsystem == "input"
            && !self.devname.is_empty()
            && self
                .devpath
                .rsplit('/')
                .next()
                .is_some_and(|n| n.starts_with("event"))
    }
}

const PREFIX: &[u8; 8] = b"libudev\0";
const MAGIC: [u8; 4] = [0xfe, 0xed, 0xca, 0xfe];

fn u32_at(buf: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_ne_bytes(buf.get(at..at + 4)?.try_into().ok()?))
}

/// Parses one monitor message (`struct udev_monitor_netlink_header` and the NUL-separated
/// `KEY=value` properties). `None` for a kernel uevent or anything malformed.
pub fn parse_monitor_message(buf: &[u8]) -> Option<UdevEvent> {
    if buf.get(0..8)? != PREFIX || buf.get(8..12)? != MAGIC {
        return None;
    }
    let off = u32_at(buf, 16)? as usize;
    let len = u32_at(buf, 20)? as usize;
    let props = buf.get(off..off.checked_add(len)?)?;
    let map: HashMap<&str, &str> = props
        .split(|&b| b == 0)
        .filter_map(|kv| std::str::from_utf8(kv).ok())
        .filter_map(|kv| kv.split_once('='))
        .collect();
    let get = |k: &str| map.get(k).map(|v| v.to_string()).unwrap_or_default();
    Some(UdevEvent {
        action: get("ACTION"),
        subsystem: get("SUBSYSTEM"),
        devpath: get("DEVPATH"),
        devname: get("DEVNAME"),
    })
}

/// The `E:KEY=value` properties of a udev database file (`/run/udev/data/c13:65`).
pub fn database_properties(text: &str) -> HashMap<String, String> {
    text.lines()
        .filter_map(|l| l.strip_prefix("E:"))
        .filter_map(|kv| kv.split_once('='))
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect()
}

#[cfg(test)]
pub fn monitor_message(props: &[(&str, &str)]) -> Vec<u8> {
    let mut body = Vec::new();
    for (k, v) in props {
        body.extend_from_slice(format!("{k}={v}").as_bytes());
        body.push(0);
    }
    let header_size: u32 = 40;
    let mut out = PREFIX.to_vec();
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(&header_size.to_ne_bytes());
    out.extend_from_slice(&header_size.to_ne_bytes()); // properties_off
    out.extend_from_slice(&(body.len() as u32).to_ne_bytes());
    out.resize(header_size as usize, 0); // filter hashes and bloom
    out.extend_from_slice(&body);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_monitor_message_is_parsed() {
        let msg = monitor_message(&[
            ("ACTION", "change"),
            ("DEVPATH", "/devices/virtual/input/input23/event17"),
            ("SUBSYSTEM", "input"),
            ("DEVNAME", "/dev/input/event17"),
            ("ID_INPUT_JOYSTICK", "1"),
        ]);
        let ev = parse_monitor_message(&msg).expect("parsed");
        assert_eq!(ev.action, "change");
        assert_eq!(ev.devname, "/dev/input/event17");
        assert_eq!(ev.parent_sysname(), Some("input23"));
        assert!(ev.is_event_node());
    }

    #[test]
    fn the_input_device_itself_is_not_an_event_node() {
        let msg = monitor_message(&[
            ("ACTION", "add"),
            ("DEVPATH", "/devices/virtual/input/input23"),
            ("SUBSYSTEM", "input"),
        ]);
        assert!(!parse_monitor_message(&msg).expect("parsed").is_event_node());
    }

    #[test]
    fn kernel_uevents_and_garbage_are_refused() {
        assert_eq!(parse_monitor_message(b"add@/devices/x\0ACTION=add\0"), None);
        assert_eq!(parse_monitor_message(b"libudev\0\0\0\0\0"), None);
        let mut msg = monitor_message(&[("ACTION", "add")]);
        msg[20] = 0xff; // properties_len past the end
        assert_eq!(parse_monitor_message(&msg), None);
    }

    #[test]
    fn database_properties_are_read() {
        let props = database_properties(
            "I:123\nE:ID_SERIAL_SHORT=ABC123\nE:ID_PATH=pci-0000:00:14.0-usb-0:2:1.0\nG:seat\n",
        );
        assert_eq!(
            props.get("ID_SERIAL_SHORT").map(String::as_str),
            Some("ABC123")
        );
        assert_eq!(props.len(), 2);
    }
}
