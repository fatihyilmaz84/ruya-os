//! Times in signed statements: UTC in the one RFC 3339 form `YYYY-MM-DDTHH:MM:SSZ`, read as
//! seconds since 1970. The rules never read the clock; the caller passes `now` in.

/// Seconds since 1970-01-01T00:00:00Z.
pub type UnixSeconds = i64;

/// Days from 1970-01-01 to the given civil date (proleptic Gregorian).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(z: i64) -> (i64, i64, i64) {
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

fn days_in_month(y: i64, m: i64) -> i64 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 => 29,
        _ => 28,
    }
}

/// Read `YYYY-MM-DDTHH:MM:SSZ` (years 1970 to 9999, no fractions, no offsets, no leap second).
pub fn parse_utc(s: &str) -> Option<UnixSeconds> {
    let b = s.as_bytes();
    if b.len() != 20 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' {
        return None;
    }
    if b[16] != b':' || b[19] != b'Z' {
        return None;
    }
    let num = |from: usize, to: usize| -> Option<i64> {
        let part = &b[from..to];
        if !part.iter().all(u8::is_ascii_digit) {
            return None;
        }
        Some(part.iter().fold(0i64, |n, d| n * 10 + i64::from(d - b'0')))
    };
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi, sec) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);
    if y < 1970 || !(1..=12).contains(&mo) || d < 1 || d > days_in_month(y, mo) {
        return None;
    }
    if h > 23 || mi > 59 || sec > 59 {
        return None;
    }
    Some(days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + sec)
}

/// Write `t` as `YYYY-MM-DDTHH:MM:SSZ`. Times before 1970 are written as 1970-01-01T00:00:00Z.
pub fn format_utc(t: UnixSeconds) -> String {
    let t = t.max(0);
    let (days, rest) = (t.div_euclid(86_400), t.rem_euclid(86_400));
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
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
