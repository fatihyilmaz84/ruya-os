//! The "Memory" group.

use crate::source::Source;
use crate::value::Info;

/// `/proc/meminfo`, in bytes. A line that is not there is `None`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MemInfo {
    pub total: Option<u64>,
    pub available: Option<u64>,
    pub swap_total: Option<u64>,
    pub swap_free: Option<u64>,
}

fn bytes_of(value: &str) -> Option<u64> {
    let mut words = value.split_whitespace();
    let n: u64 = words.next()?.parse().ok()?;
    match words.next() {
        Some("kB") | Some("KB") => n.checked_mul(1024),
        None => Some(n),
        Some(_) => None,
    }
}

pub fn parse_meminfo(text: &str) -> MemInfo {
    let mut out = MemInfo::default();
    for line in text.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let slot = match key {
            "MemTotal" => &mut out.total,
            "MemAvailable" => &mut out.available,
            "SwapTotal" => &mut out.swap_total,
            "SwapFree" => &mut out.swap_free,
            _ => continue,
        };
        *slot = bytes_of(value);
    }
    out
}

pub fn collect_static(src: &dyn Source, info: &mut Info) {
    let mem = src
        .read("/proc/meminfo")
        .map(|t| parse_meminfo(&t))
        .unwrap_or_default();
    if let Some(total) = mem.total.filter(|t| *t > 0) {
        info.unsigned("memory.total_bytes", total);
    }
    // Swap that is not there is not "0 bytes of swap".
    if let Some(total) = mem.swap_total.filter(|t| *t > 0) {
        info.unsigned("memory.swap_total_bytes", total);
    }
    // zram's `disksize` is what it may hold uncompressed.
    let zram: u64 = src
        .list("/sys/block")
        .iter()
        .filter(|n| n.starts_with("zram"))
        .filter_map(|n| src.read_u64(&format!("/sys/block/{n}/disksize")))
        .sum();
    if zram > 0 {
        info.unsigned("memory.zram_bytes", zram);
    }
}

pub fn collect_live(src: &dyn Source, info: &mut Info) {
    let mem = src
        .read("/proc/meminfo")
        .map(|t| parse_meminfo(&t))
        .unwrap_or_default();
    if let (Some(total), Some(available)) = (mem.total.filter(|t| *t > 0), mem.available) {
        info.unsigned("memory.available_bytes", available.min(total));
        info.unsigned("memory.used_bytes", total.saturating_sub(available));
    }
    if let (Some(total), Some(free)) = (mem.swap_total.filter(|t| *t > 0), mem.swap_free) {
        info.unsigned("memory.swap_used_bytes", total.saturating_sub(free));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kilobytes_become_bytes() {
        let m = parse_meminfo("MemTotal:        7970348 kB\nMemFree:          812344 kB\nMemAvailable:    5120000 kB\nSwapTotal:       4194300 kB\nSwapFree:        4194300 kB\n");
        assert_eq!(m.total, Some(7_970_348 * 1024));
        assert_eq!(m.available, Some(5_120_000 * 1024));
        assert_eq!(m.swap_total, Some(4_194_300 * 1024));
    }

    #[test]
    fn nothing_readable_is_none() {
        assert_eq!(parse_meminfo(""), MemInfo::default());
        assert_eq!(parse_meminfo("MemTotal: lots kB\n").total, None);
    }
}
