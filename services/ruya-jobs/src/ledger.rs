//! The per-day download totals of `GetDownloadStats` (ADR-026 "Stats"): the bytes a service
//! fetched each local day, and the jobs that finished. The service keeps it in a root-only file of
//! its own (its path and how many days are kept are the caller's); pure apart from `load`.

use std::collections::BTreeMap;
use std::path::Path;

use ruya_calendar::{day_of, format_day, parse_day};

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Day {
    /// "YYYY-MM-DD", local time.
    pub day: String,
    pub bytes: u64,
    /// Jobs that finished that day, whatever their status.
    pub jobs: u32,
    /// Of those, the ones that failed.
    pub failed: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Ledger {
    days: BTreeMap<String, Day>,
}

/// The local date of `unix` seconds in a zone `utc_offset_secs` east of UTC, "YYYY-MM-DD".
pub fn local_day(unix: i64, utc_offset_secs: i64) -> String {
    format_day(day_of(unix, utc_offset_secs))
}

/// The oldest day still kept at `now` when `keep_days` days are kept, today included.
pub fn oldest_kept(now: i64, utc_offset_secs: i64, keep_days: i64) -> String {
    local_day(now - (keep_days - 1) * 86_400, utc_offset_secs)
}

impl Ledger {
    /// `bytes` fetched on `day`; `finished`: a job ended that day (`Some(failed)`).
    pub fn add(&mut self, day: &str, bytes: u64, finished: Option<bool>) {
        if bytes == 0 && finished.is_none() {
            return;
        }
        let entry = self.days.entry(day.to_owned()).or_insert_with(|| Day {
            day: day.to_owned(),
            ..Day::default()
        });
        entry.bytes += bytes;
        if let Some(failed) = finished {
            entry.jobs += 1;
            if failed {
                entry.failed += 1;
            }
        }
    }

    /// Forgets the days before `oldest`.
    pub fn prune(&mut self, oldest: &str) {
        self.days.retain(|day, _| day.as_str() >= oldest);
    }

    /// Newest first, at most `days` entries, days without bytes and days before `oldest` left out.
    pub fn stats(&self, days: u32, oldest: &str) -> Vec<Day> {
        self.days
            .values()
            .rev()
            .filter(|d| d.bytes > 0 && d.day.as_str() >= oldest)
            .take(days as usize)
            .cloned()
            .collect()
    }

    pub fn to_json(&self) -> String {
        let days: Vec<_> = self
            .days
            .values()
            .map(|d| {
                serde_json::json!({"day": d.day, "bytes": d.bytes, "jobs": d.jobs, "failed": d.failed})
            })
            .collect();
        serde_json::json!({ "days": days }).to_string()
    }

    pub fn from_json(text: &str) -> Result<Ledger, String> {
        let v: serde_json::Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
        let list = v.get("days").and_then(|d| d.as_array()).ok_or("no days")?;
        let mut ledger = Ledger::default();
        for entry in list {
            let day = entry
                .get("day")
                .and_then(|d| d.as_str())
                .filter(|d| parse_day(d).is_some())
                .ok_or("a day without a YYYY-MM-DD date")?;
            let number = |key: &str| {
                entry
                    .get(key)
                    .and_then(|n| n.as_u64())
                    .ok_or_else(|| format!("{day}: no {key}"))
            };
            let count = |key: &str| {
                number(key).and_then(|n| u32::try_from(n).map_err(|e| format!("{day}: {e}")))
            };
            let d = Day {
                day: day.to_owned(),
                bytes: number("bytes")?,
                jobs: count("jobs")?,
                failed: count("failed")?,
            };
            if ledger.days.insert(day.to_owned(), d).is_some() {
                return Err(format!("{day} is written twice"));
            }
        }
        Ok(ledger)
    }
}

/// The kept ledger: empty when there is none, an error naming the file when it cannot be used
/// (it is then left as it is: never overwritten).
pub fn load(path: &Path) -> Result<Ledger, String> {
    match std::fs::read_to_string(path) {
        Ok(text) => Ledger::from_json(&text).map_err(|e| format!("{}: {e}", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Ledger::default()),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_days() {
        assert_eq!(local_day(0, 0), "1970-01-01");
        // 2026-11-23 12:00 UTC
        assert_eq!(local_day(1_795_435_200, 0), "2026-11-23");
        assert_eq!(
            local_day(1_795_435_200, 13 * 3600),
            "2026-11-24",
            "east of UTC"
        );
        assert_eq!(
            local_day(1_795_435_200, -13 * 3600),
            "2026-11-22",
            "west of UTC"
        );
        assert_eq!(local_day(951_782_400, 0), "2000-02-29", "a leap day");
        assert_eq!(oldest_kept(1_795_435_200, 0, 90), "2026-08-26");
    }

    #[test]
    fn days_add_up_and_come_newest_first() {
        let mut l = Ledger::default();
        l.add("2026-11-21", 100, None);
        l.add("2026-11-22", 0, Some(true));
        l.add("2026-11-23", 50, None);
        l.add("2026-11-23", 25, Some(false));
        l.add("2026-11-23", 0, None);
        let s = l.stats(90, "2026-08-26");
        assert_eq!(
            s,
            [
                Day {
                    day: "2026-11-23".into(),
                    bytes: 75,
                    jobs: 1,
                    failed: 0
                },
                Day {
                    day: "2026-11-21".into(),
                    bytes: 100,
                    jobs: 0,
                    failed: 0
                },
            ],
            "the day without bytes is left out"
        );
        assert_eq!(l.stats(1, "2026-08-26").len(), 1, "at most `days`");
        assert_eq!(
            l.stats(90, "2026-11-22").len(),
            1,
            "older days are not reported"
        );
    }

    #[test]
    fn ninety_days_are_kept() {
        let mut l = Ledger::default();
        l.add("2026-08-25", 1, None);
        l.add("2026-08-26", 1, None);
        l.prune(&oldest_kept(1_795_435_200, 0, 90));
        assert_eq!(l.stats(90, "0000-00-00").len(), 1);
    }

    #[test]
    fn the_file_round_trips_and_a_bad_one_is_an_error() {
        let mut l = Ledger::default();
        l.add("2026-11-23", 75, Some(true));
        assert_eq!(Ledger::from_json(&l.to_json()), Ok(l));
        for bad in [
            "",
            "{}",
            r#"{"days":[{"day":"yesterday","bytes":1,"jobs":0,"failed":0}]}"#,
            r#"{"days":[{"day":"2026-11-23","bytes":-1,"jobs":0,"failed":0}]}"#,
            r#"{"days":[{"day":"2026-11-23","bytes":1,"jobs":0,"failed":0},{"day":"2026-11-23","bytes":1,"jobs":0,"failed":0}]}"#,
        ] {
            assert!(Ledger::from_json(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn a_missing_file_is_an_empty_ledger_and_a_corrupt_one_an_error() {
        let dir = tempfile::tempdir().expect("tmp");
        let path = dir.path().join("downloads.json");
        assert_eq!(load(&path), Ok(Ledger::default()));
        std::fs::write(&path, "garbage").expect("write");
        assert!(load(&path).is_err());
    }
}
