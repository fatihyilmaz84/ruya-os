//! SMART health of the internal drives (RUY-737): the rules that turn what udisks2 says about a
//! drive (`Drive.Ata`, `Drive.NVMe.Controller`) into the `smart` keys of `storage.drives`
//! (api/dbus/org.ruyaos.Devices1.xml). Pure: the udisks2 reading is `udisks.rs`, the cache and the
//! signal are `smart_source.rs`.
//!
//! failing: ATA `SmartFailing`, or an NVMe critical warning for spare, reliability or read-only.
//! warning: bad sectors, a failed self-test, NVMe spare at or below its threshold, wear of 90 % or more.
//! unsupported: SMART off or not there (the VM's virtio disk). Otherwise ok. A drive whose SMART
//! udisks2 has not read yet (`SmartUpdated` 0) is unknown: no keys.

pub use ruya_sysinfo::DriveSmart;

/// Wear (NVMe percentage used) from which a drive is a "warning".
pub const WORN_PERCENT: u64 = 90;

/// The `Drive.Ata` properties that matter.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AtaProps {
    pub supported: bool,
    pub enabled: bool,
    /// `SmartUpdated`: seconds since 1970 of the last read, 0 = never.
    pub updated: u64,
    pub failing: bool,
    pub bad_sectors: i64,
    /// `SmartSelftestStatus`: "success", "inprogress", "fatal", "error_read", ...
    pub selftest: String,
    /// Kelvin; 0 = unknown.
    pub temperature_k: f64,
    pub power_on_seconds: u64,
}

/// The `Drive.NVMe.Controller` properties that matter, with the attributes of `SmartGetAttributes`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct NvmeProps {
    pub updated: u64,
    /// `SmartCriticalWarning`.
    pub critical: Vec<String>,
    pub power_on_hours: u64,
    /// Kelvin; 0 = unknown.
    pub temperature_k: u32,
    pub percent_used: Option<u64>,
    pub avail_spare: Option<u64>,
    pub spare_thresh: Option<u64>,
}

/// What a drive's udisks2 object offers.
#[derive(Debug, Clone, PartialEq)]
pub enum Raw {
    Ata(AtaProps),
    Nvme(NvmeProps),
    /// Neither interface: no SMART at all (virtio, eMMC, a RAID volume).
    Neither,
}

fn celsius(kelvin: f64) -> Option<i64> {
    // udisks2 gives 0 for "unknown"; anything below 1 K is not a reading.
    (kelvin >= 1.0).then(|| (kelvin - 273.15).round() as i64)
}

/// A critical warning that means the drive is failing. The names are libblockdev's
/// ("spare", "degraded", "readonly"); the longer spellings are accepted too.
fn is_fatal_warning(word: &str) -> bool {
    matches!(
        word,
        "spare" | "available_spare" | "degraded" | "device_reliability" | "readonly" | "read_only"
    )
}

fn verdict(reasons: &[&str]) -> &'static str {
    if reasons.contains(&"failing") || reasons.contains(&"critical-warning") {
        "failing"
    } else if reasons.is_empty() {
        "ok"
    } else {
        "warning"
    }
}

fn unsupported() -> DriveSmart {
    DriveSmart {
        smart: "unsupported".to_owned(),
        ..DriveSmart::default()
    }
}

fn record(reasons: Vec<&'static str>, mut base: DriveSmart) -> DriveSmart {
    base.smart = verdict(&reasons).to_owned();
    base.reasons = reasons.into_iter().map(str::to_owned).collect();
    base
}

fn ata(p: &AtaProps) -> Option<DriveSmart> {
    if !p.supported || !p.enabled {
        return Some(unsupported());
    }
    if p.updated == 0 {
        return None;
    }
    let mut reasons = Vec::new();
    if p.failing {
        reasons.push("failing");
    }
    if p.bad_sectors > 0 {
        reasons.push("bad-sectors");
    }
    if p.selftest == "fatal" || p.selftest.starts_with("error") {
        reasons.push("self-test-failed");
    }
    Some(record(
        reasons,
        DriveSmart {
            power_on_hours: Some(p.power_on_seconds / 3600),
            temperature_c: celsius(p.temperature_k),
            ..DriveSmart::default()
        },
    ))
}

fn nvme(p: &NvmeProps) -> Option<DriveSmart> {
    if p.updated == 0 {
        return None;
    }
    let mut reasons = Vec::new();
    if p.critical.iter().any(|w| is_fatal_warning(w)) {
        reasons.push("critical-warning");
    }
    if let (Some(spare), Some(thresh)) = (p.avail_spare, p.spare_thresh) {
        if spare <= thresh {
            reasons.push("spare-low");
        }
    }
    if p.percent_used.is_some_and(|w| w >= WORN_PERCENT) {
        reasons.push("worn");
    }
    Some(record(
        reasons,
        DriveSmart {
            power_on_hours: Some(p.power_on_hours),
            wear_percent: p.percent_used,
            temperature_c: celsius(f64::from(p.temperature_k)),
            ..DriveSmart::default()
        },
    ))
}

/// The record for a drive; `None` while udisks2 has not read its SMART yet (every key absent).
pub fn assess(raw: &Raw) -> Option<DriveSmart> {
    match raw {
        Raw::Ata(p) => ata(p),
        Raw::Nvme(p) => nvme(p),
        Raw::Neither => Some(unsupported()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn good_ata() -> AtaProps {
        AtaProps {
            supported: true,
            enabled: true,
            updated: 1_700_000_000,
            failing: false,
            bad_sectors: 0,
            selftest: "success".into(),
            temperature_k: 314.15,
            power_on_seconds: 36_000 * 3600 + 59,
        }
    }

    fn good_nvme() -> NvmeProps {
        NvmeProps {
            updated: 1_700_000_000,
            critical: Vec::new(),
            power_on_hours: 812,
            temperature_k: 313,
            percent_used: Some(4),
            avail_spare: Some(100),
            spare_thresh: Some(10),
        }
    }

    fn ata_of(p: AtaProps) -> DriveSmart {
        assess(&Raw::Ata(p)).expect("a record")
    }

    fn nvme_of(p: NvmeProps) -> DriveSmart {
        assess(&Raw::Nvme(p)).expect("a record")
    }

    #[test]
    fn a_healthy_ata_drive_is_ok_with_hours_and_temperature() {
        let r = ata_of(good_ata());
        assert_eq!(r.smart, "ok");
        assert!(r.reasons.is_empty());
        assert_eq!(
            r.power_on_hours,
            Some(36_000),
            "seconds / 3600, rounded down"
        );
        assert_eq!(r.temperature_c, Some(41));
        assert_eq!(r.wear_percent, None);
    }

    #[test]
    fn bad_sectors_are_a_warning() {
        let r = ata_of(AtaProps {
            bad_sectors: 3,
            ..good_ata()
        });
        assert_eq!(
            (r.smart.as_str(), r.reasons),
            ("warning", vec!["bad-sectors".to_owned()])
        );
    }

    #[test]
    fn smart_failing_is_failing_even_with_bad_sectors() {
        let r = ata_of(AtaProps {
            failing: true,
            bad_sectors: 9,
            ..good_ata()
        });
        assert_eq!(r.smart, "failing");
        assert_eq!(r.reasons, ["failing", "bad-sectors"]);
    }

    #[test]
    fn a_failed_self_test_is_a_warning_a_running_or_passed_one_is_not() {
        for status in ["fatal", "error_read", "error_unknown"] {
            let r = ata_of(AtaProps {
                selftest: status.into(),
                ..good_ata()
            });
            assert_eq!(r.smart, "warning", "{status}");
            assert_eq!(r.reasons, ["self-test-failed"]);
        }
        for status in ["success", "inprogress", "aborted", ""] {
            let r = ata_of(AtaProps {
                selftest: status.into(),
                ..good_ata()
            });
            assert_eq!(r.smart, "ok", "{status}");
        }
    }

    #[test]
    fn smart_off_or_unsupported_is_unsupported_without_numbers() {
        for (supported, enabled) in [(false, false), (true, false), (false, true)] {
            let r = ata_of(AtaProps {
                supported,
                enabled,
                ..good_ata()
            });
            assert_eq!(r.smart, "unsupported");
            assert!(r.reasons.is_empty());
            assert_eq!(r.power_on_hours, None);
            assert_eq!(r.temperature_c, None);
        }
        let r = assess(&Raw::Neither).expect("a record");
        assert_eq!(
            r.smart, "unsupported",
            "the VM's virtio disk has neither interface"
        );
    }

    #[test]
    fn a_drive_udisks_has_not_read_yet_is_unknown() {
        assert_eq!(
            assess(&Raw::Ata(AtaProps {
                updated: 0,
                ..good_ata()
            })),
            None
        );
        assert_eq!(
            assess(&Raw::Nvme(NvmeProps {
                updated: 0,
                ..good_nvme()
            })),
            None
        );
    }

    #[test]
    fn an_unknown_temperature_is_absent_not_minus_273() {
        let r = ata_of(AtaProps {
            temperature_k: 0.0,
            ..good_ata()
        });
        assert_eq!(r.temperature_c, None);
        assert_eq!(
            nvme_of(NvmeProps {
                temperature_k: 0,
                ..good_nvme()
            })
            .temperature_c,
            None
        );
    }

    #[test]
    fn a_healthy_nvme_drive_is_ok_with_wear_and_hours() {
        let r = nvme_of(good_nvme());
        assert_eq!(r.smart, "ok");
        assert_eq!(r.power_on_hours, Some(812));
        assert_eq!(r.wear_percent, Some(4));
        assert_eq!(r.temperature_c, Some(40));
    }

    #[test]
    fn an_nvme_critical_warning_for_spare_reliability_or_read_only_is_failing() {
        for word in [
            "spare",
            "degraded",
            "readonly",
            "available_spare",
            "device_reliability",
            "read_only",
        ] {
            let r = nvme_of(NvmeProps {
                critical: vec![word.into()],
                ..good_nvme()
            });
            assert_eq!(r.smart, "failing", "{word}");
            assert_eq!(r.reasons, ["critical-warning"]);
        }
    }

    #[test]
    fn other_nvme_warnings_do_not_fail_the_drive() {
        // Heat has its own policy (Thermal); memory backup is not the data's health.
        let r = nvme_of(NvmeProps {
            critical: vec!["temperature".into(), "volatile_mem".into()],
            ..good_nvme()
        });
        assert_eq!(r.smart, "ok");
    }

    #[test]
    fn spare_at_or_below_its_threshold_is_a_warning() {
        let r = nvme_of(NvmeProps {
            avail_spare: Some(10),
            spare_thresh: Some(10),
            ..good_nvme()
        });
        assert_eq!(
            (r.smart.as_str(), r.reasons),
            ("warning", vec!["spare-low".to_owned()])
        );
        let r = nvme_of(NvmeProps {
            avail_spare: Some(11),
            spare_thresh: Some(10),
            ..good_nvme()
        });
        assert_eq!(r.smart, "ok", "one above the threshold");
        // The attributes could not be read: no claim about the spare.
        let r = nvme_of(NvmeProps {
            avail_spare: None,
            spare_thresh: None,
            percent_used: None,
            ..good_nvme()
        });
        assert_eq!(r.smart, "ok");
        assert_eq!(r.wear_percent, None);
    }

    #[test]
    fn wear_of_ninety_percent_is_a_warning_and_may_pass_a_hundred() {
        let r = nvme_of(NvmeProps {
            percent_used: Some(89),
            ..good_nvme()
        });
        assert_eq!(r.smart, "ok");
        let r = nvme_of(NvmeProps {
            percent_used: Some(90),
            ..good_nvme()
        });
        assert_eq!(
            (r.smart.as_str(), r.reasons),
            ("warning", vec!["worn".to_owned()])
        );
        let r = nvme_of(NvmeProps {
            percent_used: Some(120),
            ..good_nvme()
        });
        assert_eq!(r.wear_percent, Some(120));
    }

    #[test]
    fn failing_wins_over_warnings_and_all_reasons_are_kept() {
        let r = nvme_of(NvmeProps {
            critical: vec!["readonly".into()],
            percent_used: Some(100),
            avail_spare: Some(0),
            spare_thresh: Some(10),
            ..good_nvme()
        });
        assert_eq!(r.smart, "failing");
        assert_eq!(r.reasons, ["critical-warning", "spare-low", "worn"]);
    }
}
