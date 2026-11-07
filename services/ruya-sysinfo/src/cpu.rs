//! The "Processor" group.

use std::collections::BTreeSet;

use crate::source::Source;
use crate::tidy;
use crate::value::Info;

/// What `/proc/cpuinfo` says, per machine (not per logical processor).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CpuInfo {
    pub model: Option<String>,
    /// Physical cores; `None` when the file does not say (many ARM boards).
    pub cores: Option<u32>,
    pub threads: u32,
    /// Mean of the processors' current clock, MHz.
    pub mhz: Option<u32>,
}

/// Parses `/proc/cpuinfo`: blocks of `key : value` lines, one block per logical processor.
pub fn parse_cpuinfo(text: &str) -> CpuInfo {
    let mut out = CpuInfo::default();
    let mut core_ids: BTreeSet<(String, String)> = BTreeSet::new();
    let mut cores_per_package = 0u32;
    let mut packages: BTreeSet<String> = BTreeSet::new();
    let mut mhz_sum = 0.0f64;
    let mut mhz_count = 0u32;
    let (mut package, mut core) = (String::new(), String::new());
    let mut open = false;
    let close = |package: &mut String,
                 core: &mut String,
                 open: &mut bool,
                 ids: &mut BTreeSet<(String, String)>| {
        if *open && !core.is_empty() {
            ids.insert((package.clone(), core.clone()));
        }
        package.clear();
        core.clear();
        *open = false;
    };
    for line in text.lines() {
        if line.trim().is_empty() {
            close(&mut package, &mut core, &mut open, &mut core_ids);
            continue;
        }
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let (key, value) = (key.trim(), value.trim());
        match key {
            "processor" => {
                open = true;
                out.threads += 1;
            }
            "model name" | "Model Name" | "cpu model" | "Hardware" => {
                if out.model.is_none() && !value.is_empty() {
                    out.model = Some(tidy(value));
                }
            }
            "cpu MHz" => {
                if let Ok(mhz) = value.parse::<f64>() {
                    if mhz > 0.0 {
                        mhz_sum += mhz;
                        mhz_count += 1;
                    }
                }
            }
            "physical id" => {
                package = value.to_owned();
                packages.insert(value.to_owned());
            }
            "core id" => core = value.to_owned(),
            "cpu cores" => {
                if let Ok(n) = value.parse::<u32>() {
                    cores_per_package = cores_per_package.max(n);
                }
            }
            _ => {}
        }
    }
    close(&mut package, &mut core, &mut open, &mut core_ids);
    out.cores = if !core_ids.is_empty() {
        u32::try_from(core_ids.len()).ok()
    } else if cores_per_package > 0 {
        // Garbage (a huge count) is absent, not an overflow.
        u32::try_from(packages.len().max(1))
            .ok()
            .and_then(|p| cores_per_package.checked_mul(p))
    } else {
        None
    };
    if mhz_count > 0 {
        out.mhz = Some((mhz_sum / f64::from(mhz_count)).round() as u32);
    }
    out
}

/// The clock of the busiest core from cpufreq (kHz in the files), MHz. Falls back to the mean in
/// `/proc/cpuinfo` when the machine has no cpufreq.
fn current_mhz(src: &dyn Source, fallback: Option<u32>) -> Option<u32> {
    let mut best: Option<u64> = None;
    for name in src.list("/sys/devices/system/cpu") {
        let is_cpu = name
            .strip_prefix("cpu")
            .is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()));
        if !is_cpu {
            continue;
        }
        if let Some(khz) = src.read_u64(&format!(
            "/sys/devices/system/cpu/{name}/cpufreq/scaling_cur_freq"
        )) {
            if khz > 0 {
                best = Some(best.map_or(khz, |b| b.max(khz)));
            }
        }
    }
    best.and_then(|khz| u32::try_from(khz / 1000).ok())
        .or(fallback)
}

pub fn collect_static(src: &dyn Source, info: &mut Info) {
    let parsed = src
        .read("/proc/cpuinfo")
        .map(|t| parse_cpuinfo(&t))
        .unwrap_or_default();
    if let Some(model) = &parsed.model {
        info.text("cpu.model", model);
    }
    if let Some(cores) = parsed.cores {
        info.unsigned("cpu.cores", u64::from(cores));
    }
    if parsed.threads > 0 {
        info.unsigned("cpu.threads", u64::from(parsed.threads));
    }
    // The highest clock any core may reach (kHz in cpufreq).
    let max = src
        .list("/sys/devices/system/cpu")
        .iter()
        .filter(|n| {
            n.starts_with("cpu") && n[3..].chars().all(|c| c.is_ascii_digit()) && n.len() > 3
        })
        .filter_map(|n| {
            src.read_u64(&format!(
                "/sys/devices/system/cpu/{n}/cpufreq/cpuinfo_max_freq"
            ))
        })
        .max();
    if let Some(khz) = max.filter(|k| *k >= 1000) {
        info.unsigned("cpu.freq_max_mhz", khz / 1000);
    }
}

pub fn collect_live(src: &dyn Source, info: &mut Info) {
    let fallback = src
        .read("/proc/cpuinfo")
        .and_then(|t| parse_cpuinfo(&t).mhz);
    if let Some(mhz) = current_mhz(src, fallback) {
        info.unsigned("cpu.freq_mhz", u64::from(mhz));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block(n: u32, core: u32, mhz: &str) -> String {
        format!(
            "processor\t: {n}\nvendor_id\t: GenuineIntel\nmodel name\t: Intel(R) Core(TM) i5-10500T CPU @ 2.30GHz\ncpu MHz\t\t: {mhz}\nphysical id\t: 0\nsiblings\t: 4\ncore id\t\t: {core}\ncpu cores\t: 2\n\n"
        )
    }

    #[test]
    fn hyperthreads_share_a_core() {
        // 4 logical processors on 2 cores.
        let text = [
            block(0, 0, "1000.000"),
            block(1, 1, "2000.000"),
            block(2, 0, "3000.000"),
            block(3, 1, "2000.000"),
        ]
        .concat();
        let cpu = parse_cpuinfo(&text);
        assert_eq!(cpu.threads, 4);
        assert_eq!(cpu.cores, Some(2));
        assert_eq!(cpu.mhz, Some(2000));
        assert_eq!(
            cpu.model.as_deref(),
            Some("Intel(R) Core(TM) i5-10500T CPU @ 2.30GHz")
        );
    }

    #[test]
    fn cores_come_from_cpu_cores_without_core_ids() {
        let cpu = parse_cpuinfo("processor : 0\nmodel name : X\ncpu cores : 4\nphysical id : 0\n\nprocessor : 1\nmodel name : X\ncpu cores : 4\nphysical id : 0\n");
        assert_eq!(cpu.cores, Some(4));
        assert_eq!(cpu.threads, 2);
    }

    #[test]
    fn garbage_core_counts_are_absent_not_an_overflow() {
        let cpu = parse_cpuinfo(
            "processor : 0
cpu cores : 4294967295
physical id : 0

processor : 1
cpu cores : 4294967295
physical id : 1
",
        );
        assert_eq!(cpu.cores, None);
        assert_eq!(cpu.threads, 2);
        // The edge that fits still counts.
        let ok = parse_cpuinfo(
            "processor : 0
cpu cores : 2147483647
physical id : 0

processor : 1
cpu cores : 2147483647
physical id : 1
",
        );
        assert_eq!(ok.cores, Some(4294967294));
    }

    #[test]
    fn a_board_that_tells_little_gives_threads_only() {
        let cpu =
            parse_cpuinfo("processor : 0\nBogoMIPS : 38.40\n\nprocessor : 1\nBogoMIPS : 38.40\n");
        assert_eq!(cpu.threads, 2);
        assert_eq!(cpu.cores, None, "unknown cores are absent, not zero");
        assert_eq!(cpu.model, None);
        assert_eq!(cpu.mhz, None);
        assert_eq!(parse_cpuinfo(""), CpuInfo::default());
    }
}
