//! What a console is made of and how it is doing: the collector behind the System information
//! page (T-226) and, later, the hardware part of the telemetry report (T-224).
//!
//! Pure core. Everything is parsed from text that a [`Source`] hands over (`/proc`, `/sys`, the
//! udev database, the output of a few commands), so it runs and is tested on any host with the
//! real files of real machines as fixtures (`tests/fixtures/*.dump`). No D-Bus, no I/O except through
//! the `Source`, no notion of who the report is for.
//!
//! The result is an [`Info`]: a flat map with keys `group.field` (`cpu.model`,
//! `memory.total_bytes`, ...), plus a few tables. **A value that cannot be read is absent, never
//! zero**: a machine without swap has no `memory.swap_total_bytes`, a virtual machine without a
//! GPU has no `graphics.model`. The keys are the contract (`api/dbus/org.ruyaos.Devices1.xml`,
//! `Devices1.System.GetInfo`).

pub mod collect;
pub mod cpu;
pub mod gpu;
pub mod memory;
pub mod net;
pub mod os;
pub mod source;
pub mod storage;
pub mod value;

pub use collect::{collect, collect_live, collect_static, LIVE_KEYS};
pub use source::{FakeSource, RootSource, Source};
pub use value::{Info, Value};

/// The Dell of the T-226 task as a dump (`FakeSource::from_dump`): what the service answers in
/// `--session` development, and what its tests read. Written from the task text, not captured.
pub const SAMPLE_MACHINE: &str = include_str!("../tests/fixtures/dell.dump");

/// A text from the kernel or the firmware with the padding and double blanks removed.
pub fn tidy(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Placeholders that firmware vendors leave in the DMI fields; they say nothing.
pub fn is_placeholder(text: &str) -> bool {
    let t = text.trim().to_ascii_lowercase();
    t.is_empty()
        || [
            "to be filled by o.e.m.",
            "to be filled by oem",
            "default string",
            "system product name",
            "system manufacturer",
            "system version",
            "not specified",
            "not applicable",
            "none",
            "n/a",
            "o.e.m.",
            "unknown",
            "type1productconfigid",
        ]
        .contains(&t.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tidy_collapses_blanks() {
        assert_eq!(tidy("  Intel(R)   Core(TM)\ti5  "), "Intel(R) Core(TM) i5");
    }

    #[test]
    fn placeholders_are_recognised() {
        assert!(is_placeholder("To Be Filled By O.E.M."));
        assert!(is_placeholder("  "));
        assert!(!is_placeholder("OptiPlex 3080"));
    }
}
