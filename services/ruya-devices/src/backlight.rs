//! The screen's backlight for `org.ruyaos.Devices1.Display.GetBrightness` / `SetBrightness`
//! (T-454): the kernel's `/sys/class/backlight`, read at every call. A TV or a monitor on HDMI or
//! DisplayPort has no backlight device (DDC/CI is not used), so the answer is "unsupported" and
//! the shell shows no control.
//!
//! Reading needs nothing special. Writing `brightness` needs root, which this service is not, so
//! the D-Bus adapter asks logind (`Session.SetBrightness`) with the device and level `plan`
//! computed. `write_direct` is for fixtures and development (`RUYA_BACKLIGHT_DIR`), where the
//! level is written to the file itself.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub const SYSTEM_ROOT: &str = "/sys/class/backlight";

/// Of several devices the kernel's own kind decides: the firmware one, else the platform one, else
/// the raw one (the order systemd-backlight uses).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Kind {
    Firmware,
    Platform,
    Raw,
}

impl Kind {
    fn parse(text: &str) -> Kind {
        match text.trim() {
            "firmware" => Kind::Firmware,
            "platform" => Kind::Platform,
            _ => Kind::Raw,
        }
    }
}

/// What `GetBrightness` answers: `supported` with a level of 1..=100, else `unsupported` and 0.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Brightness {
    pub supported: bool,
    pub percent: u32,
}

impl Brightness {
    pub const UNSUPPORTED: Brightness = Brightness {
        supported: false,
        percent: 0,
    };

    pub fn state(&self) -> &'static str {
        if self.supported {
            "supported"
        } else {
            "unsupported"
        }
    }
}

/// A level to set on a device: the device's name (`intel_backlight`) and the raw value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Change {
    pub name: String,
    pub level: u32,
}

/// Why `plan` did not give a change.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    Unsupported,
    Invalid,
}

impl Refusal {
    pub fn as_str(self) -> &'static str {
        match self {
            Refusal::Unsupported => "unsupported",
            Refusal::Invalid => "invalid",
        }
    }
}

struct Device {
    name: String,
    kind: Kind,
    level: u32,
    max: u32,
}

pub struct Backlight {
    root: PathBuf,
    direct: bool,
}

fn read_number(path: &Path) -> Option<u32> {
    fs::read_to_string(path).ok()?.trim().parse().ok()
}

/// The level as a share of the maximum, 1..=100: a level of 0 (or below 1 %) shows as 1, because 0
/// is never set (a black panel the player cannot undo with a controller).
fn percent_of(level: u32, max: u32) -> u32 {
    let share = (u64::from(level) * 100 + u64::from(max) / 2) / u64::from(max);
    share.clamp(1, 100) as u32
}

impl Backlight {
    /// Reads `root` (a copy of `/sys/class/backlight` in tests). `direct`: `write_direct` is how
    /// a change is made, not logind.
    pub fn new(root: impl Into<PathBuf>, direct: bool) -> Self {
        Backlight {
            root: root.into(),
            direct,
        }
    }

    /// The kernel's directory, or `RUYA_BACKLIGHT_DIR` (a fixture; levels are then written to its files).
    pub fn system() -> Self {
        match std::env::var_os("RUYA_BACKLIGHT_DIR") {
            Some(dir) => Backlight::new(dir, true),
            None => Backlight::new(SYSTEM_ROOT, false),
        }
    }

    /// The level is written to the device's file (a fixture), not asked of logind.
    pub fn is_direct(&self) -> bool {
        self.direct
    }

    fn device(&self) -> Option<Device> {
        let mut found: Vec<Device> = fs::read_dir(&self.root)
            .ok()?
            .filter_map(|entry| {
                let entry = entry.ok()?;
                let dir = entry.path();
                let max = read_number(&dir.join("max_brightness"))?;
                if max == 0 {
                    return None;
                }
                // What the hardware says it is at, else what was asked for.
                let level = read_number(&dir.join("actual_brightness"))
                    .or_else(|| read_number(&dir.join("brightness")))?;
                let kind = fs::read_to_string(dir.join("type"))
                    .map(|t| Kind::parse(&t))
                    .unwrap_or(Kind::Raw);
                Some(Device {
                    name: entry.file_name().to_string_lossy().into_owned(),
                    kind,
                    level: level.min(max),
                    max,
                })
            })
            .collect();
        // The best kind first; the name settles a tie, so the choice never depends on the
        // order the kernel lists the directory.
        found.sort_by(|a, b| (a.kind, &a.name).cmp(&(b.kind, &b.name)));
        found.into_iter().next()
    }

    pub fn get(&self) -> Brightness {
        match self.device() {
            Some(d) => Brightness {
                supported: true,
                percent: percent_of(d.level, d.max),
            },
            None => Brightness::UNSUPPORTED,
        }
    }

    /// The device and raw level for `percent` (1..=100), at least 1 so the panel never goes dark.
    pub fn plan(&self, percent: u32) -> Result<Change, Refusal> {
        if percent == 0 || percent > 100 {
            return Err(Refusal::Invalid);
        }
        let d = self.device().ok_or(Refusal::Unsupported)?;
        let level = (u64::from(d.max) * u64::from(percent) + 50) / 100;
        Ok(Change {
            name: d.name,
            level: level.clamp(1, u64::from(d.max)) as u32,
        })
    }

    /// Writes the level to the device's file. Fixtures and development only.
    pub fn write_direct(&self, change: &Change) -> io::Result<()> {
        fs::write(
            self.root.join(&change.name).join("brightness"),
            format!("{}\n", change.level),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One backlight device as the kernel lays it out.
    fn device(root: &Path, name: &str, kind: &str, level: u32, max: u32) {
        let dir = root.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("type"), format!("{kind}\n")).unwrap();
        fs::write(dir.join("brightness"), format!("{level}\n")).unwrap();
        fs::write(dir.join("max_brightness"), format!("{max}\n")).unwrap();
    }

    #[test]
    fn a_screen_without_a_backlight_is_unsupported() {
        // A TV or a monitor on HDMI: the directory is there (or not at all) and holds no device.
        let dir = tempfile::tempdir().unwrap();
        let backlight = Backlight::new(dir.path(), true);
        assert_eq!(backlight.get(), Brightness::UNSUPPORTED);
        assert_eq!(backlight.get().state(), "unsupported");
        assert_eq!(backlight.plan(50), Err(Refusal::Unsupported));
        let missing = Backlight::new(dir.path().join("nowhere"), true);
        assert_eq!(missing.get(), Brightness::UNSUPPORTED);
        assert_eq!(missing.plan(50), Err(Refusal::Unsupported));
    }

    #[test]
    fn a_backlight_reports_its_level_as_a_percentage() {
        let dir = tempfile::tempdir().unwrap();
        device(dir.path(), "intel_backlight", "raw", 48_000, 96_000);
        let got = Backlight::new(dir.path(), true).get();
        assert!(got.supported);
        assert_eq!(got.state(), "supported");
        assert_eq!(got.percent, 50);
    }

    #[test]
    fn the_hardware_reading_wins_over_the_requested_level() {
        let dir = tempfile::tempdir().unwrap();
        device(dir.path(), "panel", "raw", 100, 100);
        fs::write(dir.path().join("panel/actual_brightness"), "30\n").unwrap();
        assert_eq!(Backlight::new(dir.path(), true).get().percent, 30);
    }

    #[test]
    fn the_percentage_stays_between_1_and_100() {
        let dir = tempfile::tempdir().unwrap();
        device(dir.path(), "panel", "raw", 0, 255);
        // Off is shown as the lowest level the player can set, never 0.
        assert_eq!(Backlight::new(dir.path(), true).get().percent, 1);
        fs::write(dir.path().join("panel/brightness"), "999\n").unwrap();
        assert_eq!(Backlight::new(dir.path(), true).get().percent, 100);
    }

    #[test]
    fn a_device_with_no_range_is_not_a_backlight() {
        let dir = tempfile::tempdir().unwrap();
        device(dir.path(), "stub", "raw", 0, 0);
        assert_eq!(
            Backlight::new(dir.path(), true).get(),
            Brightness::UNSUPPORTED
        );
    }

    #[test]
    fn firmware_beats_platform_beats_raw() {
        let dir = tempfile::tempdir().unwrap();
        device(dir.path(), "a_raw", "raw", 10, 100);
        device(dir.path(), "b_platform", "platform", 20, 100);
        device(dir.path(), "c_firmware", "firmware", 30, 100);
        let backlight = Backlight::new(dir.path(), true);
        assert_eq!(backlight.get().percent, 30);
        assert_eq!(backlight.plan(80).unwrap().name, "c_firmware");
        fs::remove_dir_all(dir.path().join("c_firmware")).unwrap();
        assert_eq!(backlight.plan(80).unwrap().name, "b_platform");
        fs::remove_dir_all(dir.path().join("b_platform")).unwrap();
        assert_eq!(backlight.plan(80).unwrap().name, "a_raw");
    }

    #[test]
    fn a_plan_scales_the_percentage_to_the_device() {
        let dir = tempfile::tempdir().unwrap();
        device(dir.path(), "intel_backlight", "raw", 1000, 96_000);
        let backlight = Backlight::new(dir.path(), true);
        assert_eq!(
            backlight.plan(50),
            Ok(Change {
                name: "intel_backlight".to_owned(),
                level: 48_000
            })
        );
        assert_eq!(backlight.plan(100).unwrap().level, 96_000);
    }

    #[test]
    fn a_plan_never_goes_dark_and_refuses_what_is_out_of_range() {
        let dir = tempfile::tempdir().unwrap();
        device(dir.path(), "tiny", "raw", 1, 10);
        let backlight = Backlight::new(dir.path(), true);
        // 1 % of 10 steps rounds to 0: the lowest level that lights the panel is 1.
        assert_eq!(backlight.plan(1).unwrap().level, 1);
        assert_eq!(backlight.plan(0), Err(Refusal::Invalid));
        assert_eq!(backlight.plan(101), Err(Refusal::Invalid));
        assert_eq!(Refusal::Invalid.as_str(), "invalid");
        assert_eq!(Refusal::Unsupported.as_str(), "unsupported");
    }

    #[test]
    fn invalid_wins_over_unsupported_only_for_a_screen_that_has_a_backlight() {
        // Without a device the answer is "unsupported" whatever the number is, but a number out of
        // range is asked about first: the request is wrong whichever screen is there.
        let dir = tempfile::tempdir().unwrap();
        let backlight = Backlight::new(dir.path(), true);
        assert_eq!(backlight.plan(0), Err(Refusal::Invalid));
    }

    #[test]
    fn a_direct_write_lands_in_the_device_file_and_reads_back() {
        let dir = tempfile::tempdir().unwrap();
        device(dir.path(), "intel_backlight", "raw", 96_000, 96_000);
        let backlight = Backlight::new(dir.path(), true);
        assert!(backlight.is_direct());
        let change = backlight.plan(25).unwrap();
        backlight.write_direct(&change).unwrap();
        assert_eq!(
            fs::read_to_string(dir.path().join("intel_backlight/brightness"))
                .unwrap()
                .trim(),
            "24000"
        );
        assert_eq!(backlight.get().percent, 25);
    }
}
