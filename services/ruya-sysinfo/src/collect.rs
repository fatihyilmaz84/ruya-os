//! Puts the groups together.

use crate::source::Source;
use crate::value::Info;
use crate::{cpu, gpu, memory, net, os, storage};

/// The keys that change while the console runs and are worth reading again every few seconds. All
/// others are read once and only re-read now and then (a display plugged in, a drive added).
pub const LIVE_KEYS: &[&str] = &[
    "console.uptime_s",
    "cpu.freq_mhz",
    "memory.used_bytes",
    "memory.available_bytes",
    "memory.swap_used_bytes",
];

/// Everything that does not change by the second.
pub fn collect_static(src: &dyn Source) -> Info {
    let mut info = Info::new();
    os::collect_static(src, &mut info);
    cpu::collect_static(src, &mut info);
    memory::collect_static(src, &mut info);
    gpu::collect_static(src, &mut info);
    storage::collect_static(src, &mut info);
    net::collect_static(src, &mut info);
    info
}

/// Only the keys in [`LIVE_KEYS`]; cheap (a few small files, no commands).
pub fn collect_live(src: &dyn Source) -> Info {
    let mut info = Info::new();
    os::collect_live(src, &mut info);
    cpu::collect_live(src, &mut info);
    memory::collect_live(src, &mut info);
    info
}

/// The whole picture, the live values read now.
pub fn collect(src: &dyn Source) -> Info {
    let mut info = collect_static(src);
    info.merge(collect_live(src));
    info
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::FakeSource;

    #[test]
    fn live_collection_yields_live_keys_only() {
        let src = FakeSource::new()
            .file(
                "/proc/meminfo",
                "MemTotal: 1000 kB\nMemAvailable: 400 kB\nSwapTotal: 100 kB\nSwapFree: 60 kB\n",
            )
            .file("/proc/uptime", "50.0 10.0\n")
            .file("/proc/cpuinfo", "processor : 0\ncpu MHz : 1500.0\n");
        let live = collect_live(&src);
        for (key, _) in live.iter() {
            assert!(
                LIVE_KEYS.contains(&key.as_str()),
                "{key} is not declared live"
            );
        }
        assert_eq!(live.get_unsigned("memory.used_bytes"), Some(600 * 1024));
        assert_eq!(live.get_unsigned("memory.swap_used_bytes"), Some(40 * 1024));
        assert_eq!(live.get_unsigned("cpu.freq_mhz"), Some(1500));
        assert_eq!(live.get_unsigned("console.uptime_s"), Some(50));
    }

    #[test]
    fn static_collection_has_no_live_keys() {
        let src = FakeSource::from_dump(include_str!("../tests/fixtures/dell.dump"));
        let all = collect_static(&src);
        for key in LIVE_KEYS {
            assert!(
                !all.contains(key),
                "{key} is live and must not be in the static part"
            );
        }
    }
}
