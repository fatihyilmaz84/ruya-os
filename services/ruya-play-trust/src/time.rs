//! Times in signed statements: UTC in the one RFC 3339 form `YYYY-MM-DDTHH:MM:SSZ`, read as
//! seconds since 1970. The rules never read the clock; the caller passes `now` in.

use ruya_calendar::{digits, format_day, parse_day};

/// Seconds since 1970-01-01T00:00:00Z.
pub type UnixSeconds = i64;

/// Read `YYYY-MM-DDTHH:MM:SSZ` (years 1970 to 9999, no fractions, no offsets, no leap second).
pub fn parse_utc(s: &str) -> Option<UnixSeconds> {
    let b = s.as_bytes();
    if b.len() != 20 || b[10] != b'T' || b[13] != b':' || b[16] != b':' || b[19] != b'Z' {
        return None;
    }
    // Day 0 is 1970-01-01: no earlier year.
    let day = parse_day(s.get(..10)?).filter(|d| *d >= 0)?;
    let (h, mi, sec) = (
        digits(&b[11..13])?,
        digits(&b[14..16])?,
        digits(&b[17..19])?,
    );
    if h > 23 || mi > 59 || sec > 59 {
        return None;
    }
    Some(day * 86_400 + h * 3600 + mi * 60 + sec)
}

/// Write `t` as `YYYY-MM-DDTHH:MM:SSZ`. Times before 1970 are written as 1970-01-01T00:00:00Z.
pub fn format_utc(t: UnixSeconds) -> String {
    let t = t.max(0);
    let (days, rest) = (t.div_euclid(86_400), t.rem_euclid(86_400));
    format!(
        "{}T{:02}:{:02}:{:02}Z",
        format_day(days),
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_times_round_trip() {
        for (s, t) in [
            ("1970-01-01T00:00:00Z", 0),
            ("2000-02-29T12:34:56Z", 951_827_696),
            ("2026-11-17T00:00:00Z", 1_794_873_600),
            ("9999-12-31T23:59:59Z", 253_402_300_799),
        ] {
            assert_eq!(parse_utc(s), Some(t), "{s}");
            assert_eq!(format_utc(t), s);
        }
    }

    #[test]
    fn other_forms_are_refused() {
        for s in [
            "",
            "2026-11-17",
            "2026-11-17T00:00:00",
            "2026-11-17T00:00:00+00:00",
            "2026-11-17T00:00:00.5Z",
            "2026-11-17t00:00:00Z",
            "2026-13-01T00:00:00Z",
            "2026-02-29T00:00:00Z",
            "2026-04-31T00:00:00Z",
            "2026-11-17T24:00:00Z",
            "2026-11-17T00:60:00Z",
            "2026-11-17T00:00:60Z",
            "1969-12-31T23:59:59Z",
            "+026-11-17T00:00:00Z",
            "2026-11-17T00:00:0\u{0663}",
        ] {
            assert_eq!(parse_utc(s), None, "{s:?}");
        }
    }
}
