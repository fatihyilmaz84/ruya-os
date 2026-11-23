//! Calendar arithmetic the services share (RUY-29): day numbers (days since 1970-01-01) and civil
//! dates in the proleptic Gregorian calendar (Howard Hinnant's algorithms), and the one written
//! form of a day, `YYYY-MM-DD`. Pure: no clock, no time zone (the caller adds its zone's offset
//! before it takes the day number).

/// The day number of a civil date.
pub fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// (year, month, day) of a day number.
pub fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

pub fn days_in_month(y: i64, m: i64) -> i64 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 => 29,
        _ => 28,
    }
}

/// The day number of a moment: unix seconds in a zone `utc_offset_secs` east of UTC.
pub fn day_of(unix: i64, utc_offset_secs: i64) -> i64 {
    (unix + utc_offset_secs).div_euclid(86_400)
}

/// `YYYY-MM-DD` of a day number.
pub fn format_day(day: i64) -> String {
    let (y, m, d) = civil_from_days(day);
    format!("{y:04}-{m:02}-{d:02}")
}

/// The value of a field of a date or time written in ASCII digits only (no sign, no space); None
/// for anything else, an empty field included.
pub fn digits(field: &[u8]) -> Option<i64> {
    if field.is_empty() || !field.iter().all(u8::is_ascii_digit) {
        return None;
    }
    Some(field.iter().fold(0i64, |n, d| n * 10 + i64::from(d - b'0')))
}

/// The day number of `YYYY-MM-DD` (years 0000 to 9999); None for any other text, a month that
/// does not exist or a day the month does not have.
pub fn parse_day(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    let (y, m, d) = (digits(&b[0..4])?, digits(&b[5..7])?, digits(&b[8..10])?);
    if !(1..=12).contains(&m) || d < 1 || d > days_in_month(y, m) {
        return None;
    }
    Some(days_from_civil(y, m, d))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_days() {
        for (text, day) in [
            ("1970-01-01", 0),
            ("2000-02-29", 11_016),
            ("2026-11-23", 20_780),
            ("1969-12-31", -1),
        ] {
            assert_eq!(format_day(day), text);
            assert_eq!(parse_day(text), Some(day), "{text}");
        }
    }

    #[test]
    fn a_moment_falls_on_its_local_day() {
        // 2026-11-23 12:00 UTC
        let noon = 1_795_435_200;
        assert_eq!(format_day(day_of(noon, 0)), "2026-11-23");
        assert_eq!(
            format_day(day_of(noon, 13 * 3600)),
            "2026-11-24",
            "east of UTC"
        );
        assert_eq!(
            format_day(day_of(noon, -13 * 3600)),
            "2026-11-22",
            "west of UTC"
        );
    }

    #[test]
    fn other_texts_are_refused() {
        for s in [
            "",
            "yesterday",
            "2026-11-2",
            "2026-11-233",
            "2026/11/23",
            "2026-13-01",
            "2026-00-01",
            "2026-02-29",
            "2026-04-31",
            "2026-11-00",
            "+026-11-23",
        ] {
            assert_eq!(parse_day(s), None, "{s:?}");
        }
    }

    #[test]
    fn leap_years() {
        assert_eq!(days_in_month(2000, 2), 29);
        assert_eq!(days_in_month(1900, 2), 28);
        assert_eq!(days_in_month(2024, 2), 29);
        assert_eq!(days_in_month(2026, 2), 28);
    }
}
