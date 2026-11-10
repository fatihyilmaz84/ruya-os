//! How hard the console works right now (org.ruyaos.Devices1.System.GetPerformance, T-451,
//! ADR-033 point 4): processor and GPU load, memory and VRAM, temperatures and package power, each
//! with a state that says whether this console can measure it.
//!
//! Everything comes from the kernel, read through [`ruya_sysinfo::Source`] (the running system, or
//! a dump in the tests): `/proc/stat`, `/proc/meminfo`, hwmon and the thermal zones, the DRM
//! driver's sysfs (`gpu_busy_percent`, `mem_info_vram_*`), the DRM clients' `fdinfo` and the RAPL
//! energy counters in `/sys/class/powercap`. Nothing is estimated: a metric without a source is
//! [`State::Unsupported`].
//!
//! There is no timer: [`Performance::sample`] reads when the shell asks (only while a Performance
//! view is open). Rates (processor, GPU, power) are the change since the previous call, so the
//! first call, and one after a pause of more than [`MAX_AGE`], has no number yet
//! ([`State::Unavailable`]). A reading that fails after a good one keeps the good value for up to
//! [`MAX_AGE`] as [`State::Stale`]. Which files to read (the "layout") is found at the first call
//! and again every [`DISCOVER_EVERY`]. Time is passed in, so all of it is testable.
//!
//! The service runs as `ruya-shell` (ADR-010), and that decides two metrics: the RAPL counters
//! are root-only (`power_w` is unsupported), and a profile's game runs as that profile's user, so
//! its `fdinfo` is not readable and the DRM engine times (the GPU load of Intel graphics) would
//! count only the shell. They are used only when the service may read every process
//! (`all_processes`, i.e. it runs as root).

use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use ruya_sysinfo::Source;

use crate::thermal::{self, Class};

/// Calls closer together than this get the answer before (a rate over a few ms is noise).
pub const MIN_WINDOW: Duration = Duration::from_millis(250);
/// How old the previous reading of a rate, or a kept good value, may be.
pub const MAX_AGE: Duration = Duration::from_secs(10);
/// How often the files to read are looked for again (a hot-plugged GPU, renumbered hwmon).
pub const DISCOVER_EVERY: Duration = Duration::from_secs(60);

/// Every metric, in the contract's order. Each one is always in a report.
pub const METRICS: [&str; 9] = [
    "cpu_percent",
    "ram_used",
    "ram_total",
    "gpu_percent",
    "vram_used",
    "vram_total",
    "cpu_temp",
    "gpu_temp",
    "power_w",
];

/// The contract's states (stable strings).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Supported,
    Unsupported,
    Unavailable,
    Stale,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Supported => "supported",
            State::Unsupported => "unsupported",
            State::Unavailable => "unavailable",
            State::Stale => "stale",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Metric {
    pub state: State,
    /// 0 for unsupported and unavailable; the last good value for stale.
    pub value: f64,
}

pub type Report = BTreeMap<&'static str, Metric>;

/// What one reading found for one metric, before the stale rule.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Raw {
    Value(f64),
    /// There is a source but no number now (a rate's first reading, a failed read).
    Gap,
    Unsupported,
}

// ---------------------------------------------------------------------------------------------
// The layout: which files this console offers

#[derive(Debug, Clone, Default, PartialEq)]
struct Gpu {
    /// The PCI slot (`0000:00:02.0`), which DRM clients name as `drm-pdev`.
    slot: String,
    /// `gpu_busy_percent` (amdgpu).
    busy: Option<String>,
    /// `mem_info_vram_used` and `mem_info_vram_total` (amdgpu).
    vram: Option<(String, String)>,
    /// The GPU's own hwmon temperature input.
    temp: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq)]
struct Rapl {
    energy: String,
    /// The counter wraps at this many microjoules.
    range: u64,
}

#[derive(Debug, Clone, Default, PartialEq)]
struct Layout {
    /// The processor package temperature inputs; empty: unsupported.
    cpu_temps: Vec<String>,
    gpu: Option<Gpu>,
    /// The package domains, when every one of them is readable; empty: unsupported.
    rapl: Vec<Rapl>,
}

/// `(n, label)` of the `tempN_input` files of one hwmon directory, ascending.
fn temp_inputs(src: &dyn Source, dir: &str) -> Vec<(u32, String)> {
    let mut temps: Vec<(u32, String)> = src
        .list(dir)
        .iter()
        .filter_map(|f| f.strip_prefix("temp")?.strip_suffix("_input")?.parse().ok())
        .map(|n: u32| {
            let label = src
                .read_trim(&format!("{dir}/temp{n}_label"))
                .unwrap_or_else(|| format!("temp{n}"));
            (n, label)
        })
        .collect();
    temps.sort();
    temps
}

/// The processor packages: coretemp / k10temp / zenpower in hwmon (the same choice as Thermal),
/// else the `x86_pkg_temp` thermal zone.
fn find_cpu_temps(src: &dyn Source) -> Vec<String> {
    let mut out = Vec::new();
    for entry in src.list("/sys/class/hwmon") {
        let dir = format!("/sys/class/hwmon/{entry}");
        let Some(name) = src.read_trim(&format!("{dir}/name")) else {
            continue;
        };
        if !matches!(name.as_str(), "coretemp" | "k10temp" | "zenpower") {
            continue;
        }
        let temps = temp_inputs(src, &dir);
        for (n, _) in thermal::pick(Class::Cpu, &temps) {
            out.push(format!("{dir}/temp{n}_input"));
        }
    }
    if out.is_empty() {
        for entry in src.list("/sys/class/thermal") {
            let dir = format!("/sys/class/thermal/{entry}");
            if entry.starts_with("thermal_zone")
                && src.read_trim(&format!("{dir}/type")).as_deref() == Some("x86_pkg_temp")
            {
                out.push(format!("{dir}/temp"));
            }
        }
    }
    out
}

/// The GPU the firmware boots with (`boot_vga`), else the first card with a PCI device.
fn find_gpu(src: &dyn Source) -> Option<Gpu> {
    let mut cards: Vec<(bool, String)> = Vec::new();
    for name in src.list("/sys/class/drm") {
        let is_card = name
            .strip_prefix("card")
            .is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()));
        if !is_card {
            continue;
        }
        let Some(device) = src.resolve(&format!("/sys/class/drm/{name}/device")) else {
            continue;
        };
        if !src.exists(&format!("{device}/vendor")) {
            continue;
        }
        let boot = src.read_trim(&format!("{device}/boot_vga")).as_deref() == Some("1");
        cards.push((boot, device));
    }
    cards.sort_by_key(|(boot, _)| !boot);
    let (_, device) = cards.into_iter().next()?;
    let slot = device.rsplit('/').next().unwrap_or_default().to_owned();
    let file = |name: &str| format!("{device}/{name}");
    let busy = src
        .exists(&file("gpu_busy_percent"))
        .then(|| file("gpu_busy_percent"));
    let vram = (src.exists(&file("mem_info_vram_used"))
        && src.exists(&file("mem_info_vram_total")))
    .then(|| (file("mem_info_vram_used"), file("mem_info_vram_total")));
    let hwmon = file("hwmon");
    let temp = src.list(&hwmon).into_iter().find_map(|entry| {
        let dir = format!("{hwmon}/{entry}");
        let temps = temp_inputs(src, &dir);
        thermal::pick(Class::Gpu, &temps)
            .first()
            .map(|(n, _)| format!("{dir}/temp{n}_input"))
    });
    Some(Gpu {
        slot,
        busy,
        vram,
        temp,
    })
}

/// The RAPL package domains (`intel-rapl:N` named `package-N`; AMD processors use the same
/// driver). All of them readable, or none counts: a sum over some packages would be too low.
fn find_rapl(src: &dyn Source) -> Vec<Rapl> {
    let mut out = Vec::new();
    for zone in src.list("/sys/class/powercap") {
        let Some(n) = zone.strip_prefix("intel-rapl:") else {
            continue;
        };
        if n.is_empty() || !n.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let dir = format!("/sys/class/powercap/{zone}");
        if !src
            .read_trim(&format!("{dir}/name"))
            .is_some_and(|name| name.starts_with("package"))
        {
            continue;
        }
        let energy = format!("{dir}/energy_uj");
        let range = src.read_u64(&format!("{dir}/max_energy_range_uj"));
        match (src.read_u64(&energy), range) {
            (Some(_), Some(range)) if range > 0 => out.push(Rapl { energy, range }),
            // Root-only (the kernel's default since 2020), or no range to unwrap with.
            _ => return Vec::new(),
        }
    }
    out
}

fn discover(src: &dyn Source) -> Layout {
    Layout {
        cpu_temps: find_cpu_temps(src),
        gpu: find_gpu(src),
        rapl: find_rapl(src),
    }
}

// ---------------------------------------------------------------------------------------------
// Counters: what a rate needs from the reading before

/// The DRM clients' engine times on one GPU, from their `fdinfo`.
#[derive(Debug, Clone, Default, PartialEq)]
struct Engines {
    /// `(drm-client-id, engine)` -> busy nanoseconds. A client open through several descriptors
    /// (or shared by processes) is one key, so it is counted once.
    busy: BTreeMap<(String, String), u64>,
    /// `drm-engine-capacity-<engine>`: how many engines of the class there are (1 when absent).
    capacity: BTreeMap<String, u64>,
}

#[derive(Debug, Clone, Default)]
struct Counters {
    cpu: Option<(u64, u64)>,
    energy: Option<Vec<u64>>,
    engines: Option<Engines>,
}

/// `MemTotal` and `MemAvailable` in bytes.
fn parse_meminfo(text: &str) -> Option<(u64, u64)> {
    let field = |key: &str| -> Option<u64> {
        let line = text.lines().find(|l| l.starts_with(key))?;
        let kib: u64 = line[key.len()..].split_whitespace().next()?.parse().ok()?;
        kib.checked_mul(1024)
    };
    Some((field("MemTotal:")?, field("MemAvailable:")?))
}

/// Adds one `fdinfo` text to `engines` when it is a DRM client of the GPU at `slot`.
fn parse_fdinfo(text: &str, slot: &str, engines: &mut Engines) {
    let mut pdev = None;
    let mut client = None;
    let mut busy = Vec::new();
    let mut capacity = Vec::new();
    for line in text.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let (key, value) = (key.trim(), value.trim());
        if key == "drm-pdev" {
            pdev = Some(value.to_owned());
        } else if key == "drm-client-id" {
            client = Some(value.to_owned());
        } else if let Some(engine) = key.strip_prefix("drm-engine-capacity-") {
            if let Ok(n) = value.parse::<u64>() {
                capacity.push((engine.to_owned(), n));
            }
        } else if let Some(engine) = key.strip_prefix("drm-engine-") {
            if let Some(ns) = value
                .strip_suffix("ns")
                .and_then(|v| v.trim().parse::<u64>().ok())
            {
                busy.push((engine.to_owned(), ns));
            }
        }
    }
    let Some(client) = client else {
        return;
    };
    if pdev.as_deref().is_some_and(|p| p != slot) {
        return;
    }
    for (engine, ns) in busy {
        engines.busy.insert((client.clone(), engine), ns);
    }
    for (engine, n) in capacity {
        engines.capacity.insert(engine, n.max(1));
    }
}

/// Every process's DRM descriptors on the GPU at `slot`.
fn read_engines(src: &dyn Source, slot: &str) -> Engines {
    let mut engines = Engines::default();
    for pid in src.list("/proc") {
        if pid.is_empty() || !pid.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        for fd in src.list(&format!("/proc/{pid}/fd")) {
            let is_drm = src
                .resolve(&format!("/proc/{pid}/fd/{fd}"))
                .is_some_and(|target| target.starts_with("/dev/dri/"));
            if !is_drm {
                continue;
            }
            if let Some(text) = src.read(&format!("/proc/{pid}/fdinfo/{fd}")) {
                parse_fdinfo(&text, slot, &mut engines);
            }
        }
    }
    engines
}

/// The busiest engine class between two readings, percent.
fn engines_percent(before: &Engines, now: &Engines, elapsed: Duration) -> f64 {
    let window = elapsed.as_nanos() as f64;
    if window <= 0.0 {
        return 0.0;
    }
    let mut per_engine: BTreeMap<&str, u64> = BTreeMap::new();
    for (key, ns) in &now.busy {
        // A client that is new since the reading before has no start to count from.
        if let Some(old) = before.busy.get(key) {
            *per_engine.entry(key.1.as_str()).or_insert(0) += ns.saturating_sub(*old);
        }
    }
    per_engine
        .iter()
        .map(|(engine, ns)| {
            let capacity = now.capacity.get(*engine).copied().unwrap_or(1) as f64;
            *ns as f64 / (window * capacity) * 100.0
        })
        .fold(0.0, f64::max)
        .clamp(0.0, 100.0)
}

/// A temperature in millidegrees, or `None` when unreadable or outside what Thermal believes.
fn read_temp(src: &dyn Source, path: &str) -> Option<f64> {
    let value = src.read_trim(path)?.parse::<f64>().ok()? / 1000.0;
    (value.is_finite() && (thermal::MIN_PLAUSIBLE..=thermal::MAX_PLAUSIBLE).contains(&value))
        .then_some(value)
}

// ---------------------------------------------------------------------------------------------
// The sampler

struct Inner {
    layout: Option<(Instant, Layout)>,
    /// The counters of the reading before, and when it was taken.
    prev: Option<(Instant, Counters)>,
    /// The last answer, for calls inside [`MIN_WINDOW`].
    last: Option<(Instant, Report)>,
    /// The last good value of each metric and when it was measured.
    good: BTreeMap<&'static str, (Instant, f64)>,
}

pub struct Performance {
    source: Box<dyn Source + Send + Sync>,
    all_processes: bool,
    inner: Mutex<Inner>,
}

impl Performance {
    /// `all_processes`: the service may read every process's `fdinfo` (it runs as root); only
    /// then do the DRM clients' engine times stand for the GPU's load.
    pub fn new(source: Box<dyn Source + Send + Sync>, all_processes: bool) -> Self {
        Performance {
            source,
            all_processes,
            inner: Mutex::new(Inner {
                layout: None,
                prev: None,
                last: None,
                good: BTreeMap::new(),
            }),
        }
    }

    /// Reads the metrics at `now`. Blocking file reads: call it off the D-Bus executor.
    pub fn sample(&self, now: Instant) -> Report {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((at, report)) = &inner.last {
            if now >= *at && now.duration_since(*at) < MIN_WINDOW {
                return report.clone();
            }
        }
        let src: &dyn Source = &*self.source;
        let rediscover = match &inner.layout {
            Some((at, _)) => now
                .checked_duration_since(*at)
                .map_or(true, |d| d >= DISCOVER_EVERY),
            None => true,
        };
        if rediscover {
            inner.layout = Some((now, discover(src)));
        }
        let layout = inner
            .layout
            .as_ref()
            .map(|(_, l)| l.clone())
            .unwrap_or_default();

        let engines_count =
            self.all_processes && layout.gpu.as_ref().is_some_and(|g| g.busy.is_none());
        let counters = Counters {
            cpu: src
                .read("/proc/stat")
                .and_then(|t| thermal::parse_cpu_jiffies(&t)),
            energy: (!layout.rapl.is_empty())
                .then(|| {
                    layout
                        .rapl
                        .iter()
                        .map(|r| src.read_u64(&r.energy))
                        .collect()
                })
                .flatten(),
            engines: match (&layout.gpu, engines_count) {
                (Some(gpu), true) => Some(read_engines(src, &gpu.slot)),
                _ => None,
            },
        };
        // The reading before counts only when it is recent; else every rate starts again.
        let prev = inner
            .prev
            .take()
            .filter(|(at, _)| now > *at && now.duration_since(*at) <= MAX_AGE);
        let elapsed = prev.as_ref().map(|(at, _)| now.duration_since(*at));
        let before = prev.as_ref().map(|(_, c)| c);

        let mut raw: Vec<(&'static str, Raw)> = Vec::with_capacity(METRICS.len());

        // Processor load.
        raw.push((
            "cpu_percent",
            match (before.and_then(|b| b.cpu), counters.cpu) {
                (Some((total0, busy0)), Some((total1, busy1))) if total1 > total0 => {
                    let share = busy1.saturating_sub(busy0) as f64 / (total1 - total0) as f64;
                    Raw::Value((share * 100.0).clamp(0.0, 100.0))
                }
                _ => Raw::Gap,
            },
        ));

        // Memory.
        match src.read("/proc/meminfo").and_then(|t| parse_meminfo(&t)) {
            Some((total, available)) => {
                raw.push((
                    "ram_used",
                    Raw::Value(total.saturating_sub(available) as f64),
                ));
                raw.push(("ram_total", Raw::Value(total as f64)));
            }
            None => {
                raw.push(("ram_used", Raw::Gap));
                raw.push(("ram_total", Raw::Gap));
            }
        }

        // GPU load: the driver's own number, else the DRM clients' engine times.
        raw.push((
            "gpu_percent",
            match &layout.gpu {
                None => Raw::Unsupported,
                Some(gpu) => match &gpu.busy {
                    Some(path) => match src.read_trim(path).and_then(|v| v.parse::<f64>().ok()) {
                        Some(v) if v.is_finite() => Raw::Value(v.clamp(0.0, 100.0)),
                        _ => Raw::Gap,
                    },
                    None => match &counters.engines {
                        // The driver gives no engine times (no client has any): nothing to count.
                        Some(now_engines) if !now_engines.busy.is_empty() => {
                            match (before.and_then(|b| b.engines.as_ref()), elapsed) {
                                (Some(old), Some(elapsed)) => {
                                    Raw::Value(engines_percent(old, now_engines, elapsed))
                                }
                                _ => Raw::Gap,
                            }
                        }
                        _ => Raw::Unsupported,
                    },
                },
            },
        ));

        // VRAM.
        match layout.gpu.as_ref().and_then(|g| g.vram.as_ref()) {
            Some((used, total)) => {
                for (name, path) in [("vram_used", used), ("vram_total", total)] {
                    raw.push((
                        name,
                        src.read_u64(path)
                            .map_or(Raw::Gap, |v| Raw::Value(v as f64)),
                    ));
                }
            }
            None => {
                raw.push(("vram_used", Raw::Unsupported));
                raw.push(("vram_total", Raw::Unsupported));
            }
        }

        // Temperatures: the hottest package; the GPU's own sensor.
        raw.push((
            "cpu_temp",
            if layout.cpu_temps.is_empty() {
                Raw::Unsupported
            } else {
                layout
                    .cpu_temps
                    .iter()
                    .filter_map(|p| read_temp(src, p))
                    .reduce(f64::max)
                    .map_or(Raw::Gap, Raw::Value)
            },
        ));
        raw.push((
            "gpu_temp",
            match layout.gpu.as_ref().and_then(|g| g.temp.as_ref()) {
                None => Raw::Unsupported,
                Some(path) => read_temp(src, path).map_or(Raw::Gap, Raw::Value),
            },
        ));

        // Package power: energy since the reading before, unwrapped at each counter's range.
        raw.push((
            "power_w",
            if layout.rapl.is_empty() {
                Raw::Unsupported
            } else {
                match (
                    before.and_then(|b| b.energy.as_ref()),
                    counters.energy.as_ref(),
                    elapsed,
                ) {
                    (Some(old), Some(new), Some(elapsed))
                        if old.len() == new.len() && new.len() == layout.rapl.len() =>
                    {
                        // A counter that wrapped adds range - old + new; a reading above
                        // the counter's own range is nonsense and gives no value (T-451 review).
                        let joules: Option<f64> = old
                            .iter()
                            .zip(new)
                            .zip(&layout.rapl)
                            .map(|((a, b), r)| {
                                let delta = if b >= a {
                                    Some(b - a)
                                } else {
                                    r.range.checked_sub(*a).and_then(|d| d.checked_add(*b))
                                };
                                delta.map(|d| d as f64 / 1e6)
                            })
                            .sum();
                        match joules {
                            Some(j) => Raw::Value(j / elapsed.as_secs_f64()),
                            None => Raw::Gap,
                        }
                    }
                    _ => Raw::Gap,
                }
            },
        ));

        let mut report = Report::new();
        for (name, raw) in raw {
            let metric = match raw {
                Raw::Value(value) => {
                    inner.good.insert(name, (now, value));
                    Metric {
                        state: State::Supported,
                        value,
                    }
                }
                Raw::Gap => match inner.good.get(name) {
                    Some((at, value)) if now.duration_since(*at) <= MAX_AGE => Metric {
                        state: State::Stale,
                        value: *value,
                    },
                    _ => Metric {
                        state: State::Unavailable,
                        value: 0.0,
                    },
                },
                Raw::Unsupported => Metric {
                    state: State::Unsupported,
                    value: 0.0,
                },
            };
            report.insert(name, metric);
        }
        inner.prev = Some((now, counters));
        inner.last = Some((now, report.clone()));
        report
    }
}

/// Whether this process may read every other process's `fdinfo` (it runs as root).
pub fn reads_all_processes() -> bool {
    #[cfg(target_os = "linux")]
    {
        // SAFETY: geteuid has no preconditions and cannot fail.
        unsafe { libc::geteuid() == 0 }
    }
    #[cfg(not(target_os = "linux"))]
    {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ruya_sysinfo::FakeSource;

    const DELL: &str = include_str!("../tests/fixtures/performance-dell.dump");
    const AMD: &str = include_str!("../tests/fixtures/performance-amd.dump");

    /// A dump whose files a test may change between two readings (the sampler holds a clone).
    #[derive(Clone)]
    struct Live(std::sync::Arc<Mutex<FakeSource>>);

    impl Live {
        fn change(&self, f: impl FnOnce(FakeSource) -> FakeSource) {
            let mut guard = self.0.lock().unwrap();
            let old = std::mem::take(&mut *guard);
            *guard = f(old);
        }
    }

    impl Source for Live {
        fn read(&self, p: &str) -> Option<String> {
            self.0.lock().unwrap().read(p)
        }
        fn read_bytes(&self, p: &str) -> Option<Vec<u8>> {
            self.0.lock().unwrap().read_bytes(p)
        }
        fn list(&self, p: &str) -> Vec<String> {
            self.0.lock().unwrap().list(p)
        }
        fn exists(&self, p: &str) -> bool {
            self.0.lock().unwrap().exists(p)
        }
        fn resolve(&self, p: &str) -> Option<String> {
            self.0.lock().unwrap().resolve(p)
        }
        fn modified(&self, p: &str) -> Option<u64> {
            self.0.lock().unwrap().modified(p)
        }
        fn run(&self, p: &str, a: &[&str]) -> Option<String> {
            self.0.lock().unwrap().run(p, a)
        }
    }

    fn sampler(dump: FakeSource, root: bool) -> (Live, Performance) {
        let live = Live(std::sync::Arc::new(Mutex::new(dump)));
        (live.clone(), Performance::new(Box::new(live), root))
    }

    fn state(report: &Report, name: &str) -> State {
        report[name].state
    }

    fn value(report: &Report, name: &str) -> f64 {
        report[name].value
    }

    const SHELL_FD: &str = "/proc/2133/fdinfo/10";

    /// The shell's fdinfo with a new render time.
    fn render_ns(text: &str, ns: u64) -> String {
        text.lines()
            .map(|l| {
                if l.starts_with("drm-engine-render:") {
                    format!("drm-engine-render: {ns} ns")
                } else {
                    l.to_owned()
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn every_metric_is_in_every_report() {
        for (dump, root) in [(DELL, false), (DELL, true), (AMD, true), ("", false)] {
            let (_, perf) = sampler(FakeSource::from_dump(dump), root);
            let report = perf.sample(Instant::now());
            for name in METRICS {
                assert!(report.contains_key(name), "{name} missing");
            }
            assert_eq!(report.len(), METRICS.len());
        }
    }

    #[test]
    fn an_empty_machine_offers_nothing_but_temporarily_missing_proc_files() {
        let (_, perf) = sampler(FakeSource::new(), false);
        let report = perf.sample(Instant::now());
        // /proc always exists on Linux: a failed read is a gap, not a missing source.
        for name in ["cpu_percent", "ram_used", "ram_total"] {
            assert_eq!(state(&report, name), State::Unavailable, "{name}");
        }
        for name in [
            "gpu_percent",
            "vram_used",
            "vram_total",
            "cpu_temp",
            "gpu_temp",
            "power_w",
        ] {
            assert_eq!(state(&report, name), State::Unsupported, "{name}");
            assert_eq!(value(&report, name), 0.0);
        }
    }

    // --- /proc/stat

    #[test]
    fn processor_load_is_the_busy_share_between_two_readings() {
        let (live, perf) = sampler(FakeSource::from_dump(DELL), false);
        let t0 = Instant::now();
        let first = perf.sample(t0);
        assert_eq!(
            state(&first, "cpu_percent"),
            State::Unavailable,
            "a rate needs two readings"
        );
        assert_eq!(value(&first, "cpu_percent"), 0.0);
        // Captured: cpu  124442 4269 66875 10254164 137739 31387 25417 0 ...
        // One second later: 300 busy jiffies (user + system) and 700 idle.
        live.change(|s| {
            s.file(
                "/proc/stat",
                "cpu  124642 4269 66975 10254864 137739 31387 25417 0 0 0\n",
            )
        });
        let second = perf.sample(t0 + Duration::from_secs(1));
        assert_eq!(state(&second, "cpu_percent"), State::Supported);
        assert!((value(&second, "cpu_percent") - 30.0).abs() < 1e-9);
    }

    #[test]
    fn a_rate_after_a_long_pause_starts_again() {
        let (live, perf) = sampler(FakeSource::from_dump(DELL), false);
        let t0 = Instant::now();
        perf.sample(t0);
        live.change(|s| {
            s.file(
                "/proc/stat",
                "cpu  124642 4269 66975 10254864 137739 31387 25417 0 0 0\n",
            )
        });
        // The panel was closed for a minute: a load averaged over that minute is not "now".
        let later = perf.sample(t0 + Duration::from_secs(60));
        assert_eq!(state(&later, "cpu_percent"), State::Unavailable);
    }

    #[test]
    fn calls_inside_the_minimum_window_get_the_answer_before() {
        let (live, perf) = sampler(FakeSource::from_dump(DELL), false);
        let t0 = Instant::now();
        perf.sample(t0);
        live.change(|s| {
            s.file(
                "/proc/stat",
                "cpu  124642 4269 66975 10254864 137739 31387 25417 0 0 0\n",
            )
        });
        let soon = perf.sample(t0 + Duration::from_millis(100));
        assert_eq!(
            state(&soon, "cpu_percent"),
            State::Unavailable,
            "same answer as before"
        );
        let later = perf.sample(t0 + Duration::from_millis(400));
        assert_eq!(state(&later, "cpu_percent"), State::Supported);
    }

    // --- /proc/meminfo

    #[test]
    fn memory_is_total_minus_available() {
        let (_, perf) = sampler(FakeSource::from_dump(DELL), false);
        let report = perf.sample(Instant::now());
        // Captured: MemTotal 7820536 kB, MemAvailable 6452428 kB.
        assert_eq!(state(&report, "ram_total"), State::Supported);
        assert_eq!(value(&report, "ram_total"), 7820536.0 * 1024.0);
        assert_eq!(value(&report, "ram_used"), (7820536.0 - 6452428.0) * 1024.0);
    }

    #[test]
    fn a_failed_reading_keeps_the_good_value_for_ten_seconds_as_stale() {
        let (live, perf) = sampler(FakeSource::from_dump(DELL), false);
        let t0 = Instant::now();
        let good = value(&perf.sample(t0), "ram_used");
        live.change(|s| s.without("/proc/meminfo"));
        let stale = perf.sample(t0 + Duration::from_secs(5));
        assert_eq!(state(&stale, "ram_used"), State::Stale);
        assert_eq!(value(&stale, "ram_used"), good);
        let gone = perf.sample(t0 + Duration::from_secs(11));
        assert_eq!(state(&gone, "ram_used"), State::Unavailable);
        assert_eq!(value(&gone, "ram_used"), 0.0);
    }

    // --- hwmon and the thermal zones

    #[test]
    fn the_dell_processor_temperature_is_its_package_sensor() {
        let (_, perf) = sampler(FakeSource::from_dump(DELL), false);
        let report = perf.sample(Instant::now());
        // coretemp "Package id 0" (temp1) was 29 degrees when captured; dell_smm's 126 is ignored.
        assert_eq!(state(&report, "cpu_temp"), State::Supported);
        assert_eq!(value(&report, "cpu_temp"), 29.0);
    }

    #[test]
    fn without_a_processor_hwmon_the_package_thermal_zone_counts() {
        let dump = FakeSource::from_dump(DELL).without_tree("/sys/class/hwmon");
        let (_, perf) = sampler(dump, false);
        let report = perf.sample(Instant::now());
        // thermal_zone2 is x86_pkg_temp, 26 degrees when captured.
        assert_eq!(state(&report, "cpu_temp"), State::Supported);
        assert_eq!(value(&report, "cpu_temp"), 26.0);
    }

    #[test]
    fn a_machine_without_hwmon_or_a_package_zone_has_no_processor_temperature() {
        let dump = FakeSource::from_dump(DELL)
            .without_tree("/sys/class/hwmon")
            .without_tree("/sys/class/thermal");
        let (_, perf) = sampler(dump, false);
        let report = perf.sample(Instant::now());
        assert_eq!(state(&report, "cpu_temp"), State::Unsupported);
        assert_eq!(state(&report, "gpu_temp"), State::Unsupported);
    }

    #[test]
    fn an_implausible_temperature_is_a_failed_reading() {
        let (live, perf) = sampler(FakeSource::from_dump(DELL), false);
        let t0 = Instant::now();
        perf.sample(t0);
        live.change(|s| s.file("/sys/class/hwmon/hwmon3/temp1_input", "126000\n"));
        let report = perf.sample(t0 + Duration::from_secs(1));
        assert_eq!(state(&report, "cpu_temp"), State::Stale);
        assert_eq!(value(&report, "cpu_temp"), 29.0);
    }

    #[test]
    fn an_amd_gpu_has_its_own_temperature_and_the_processor_its_tctl() {
        let (_, perf) = sampler(FakeSource::from_dump(AMD), false);
        let report = perf.sample(Instant::now());
        assert_eq!(state(&report, "gpu_temp"), State::Supported);
        assert_eq!(value(&report, "gpu_temp"), 48.0, "the edge sensor");
        assert_eq!(state(&report, "cpu_temp"), State::Supported);
        assert_eq!(value(&report, "cpu_temp"), 61.5, "k10temp Tctl");
    }

    #[test]
    fn an_integrated_intel_gpu_has_no_temperature_of_its_own() {
        let (_, perf) = sampler(FakeSource::from_dump(DELL), false);
        let report = perf.sample(Instant::now());
        assert_eq!(state(&report, "gpu_temp"), State::Unsupported);
    }

    // --- the DRM driver's sysfs

    #[test]
    fn amdgpu_reports_its_load_and_vram_in_sysfs() {
        let (_, perf) = sampler(FakeSource::from_dump(AMD), false);
        let report = perf.sample(Instant::now());
        assert_eq!(state(&report, "gpu_percent"), State::Supported);
        assert_eq!(value(&report, "gpu_percent"), 37.0);
        assert_eq!(state(&report, "vram_used"), State::Supported);
        assert_eq!(value(&report, "vram_used"), 1_073_741_824.0);
        assert_eq!(value(&report, "vram_total"), 8_573_157_376.0);
    }

    #[test]
    fn a_driver_without_vram_numbers_is_unsupported() {
        // i915 on the Dell: an integrated GPU, no mem_info_vram_* files.
        let (_, perf) = sampler(FakeSource::from_dump(DELL), true);
        let report = perf.sample(Instant::now());
        assert_eq!(state(&report, "vram_used"), State::Unsupported);
        assert_eq!(state(&report, "vram_total"), State::Unsupported);
        // And an amdgpu card whose driver leaves them out.
        let amd = FakeSource::from_dump(AMD)
            .without("/sys/devices/pci0000:00/0000:00:01.1/0000:03:00.0/mem_info_vram_used")
            .without("/sys/devices/pci0000:00/0000:00:01.1/0000:03:00.0/mem_info_vram_total");
        let (_, perf) = sampler(amd, false);
        let report = perf.sample(Instant::now());
        assert_eq!(state(&report, "vram_used"), State::Unsupported);
        assert_eq!(state(&report, "gpu_percent"), State::Supported);
    }

    #[test]
    fn the_boot_gpu_is_measured_when_there_are_two() {
        // The AMD fixture has the APU's own graphics (card0, not the boot GPU) and the card (card1).
        let (_, perf) = sampler(FakeSource::from_dump(AMD), false);
        let report = perf.sample(Instant::now());
        assert_eq!(
            value(&report, "gpu_percent"),
            37.0,
            "card1's number, not card0's 3"
        );
    }

    // --- fdinfo

    #[test]
    fn engine_times_are_not_used_unless_every_process_is_readable() {
        let (_, perf) = sampler(FakeSource::from_dump(DELL), false);
        assert_eq!(
            state(&perf.sample(Instant::now()), "gpu_percent"),
            State::Unsupported
        );
    }

    #[test]
    fn gpu_load_from_engine_times_counts_each_client_once() {
        let dump = FakeSource::from_dump(DELL);
        let shell = dump.read(SHELL_FD).expect("fixture has the shell's fdinfo");
        // A game's client (another process, two engines) and a descriptor of another GPU.
        let game = "drm-driver: i915\ndrm-client-id: 9\ndrm-pdev: 0000:00:02.0\ndrm-engine-render: 1000000000 ns\ndrm-engine-video: 0 ns\n";
        let other =
            "drm-driver: amdgpu\ndrm-client-id: 3\ndrm-pdev: 0000:03:00.0\ndrm-engine-gfx: 0 ns\n";
        let dump = dump
            .link("/proc/4000/fd/5", "/dev/dri/renderD128")
            .dir("/dev/dri/renderD128")
            .file("/proc/4000/fdinfo/5", game)
            .link("/proc/4000/fd/6", "/dev/dri/renderD129")
            .dir("/dev/dri/renderD129")
            .file("/proc/4000/fdinfo/6", other)
            .link("/proc/4000/fd/0", "/dev/null")
            .dir("/dev/null");
        let (live, perf) = sampler(dump, true);
        let t0 = Instant::now();
        let first = perf.sample(t0);
        assert_eq!(state(&first, "gpu_percent"), State::Unavailable);
        // One second: the shell's render engine 100 ms busy (seen through two descriptors, fds 6
        // and 10, the same client 5), the game's 400 ms; video idle. Render 50 %.
        let shell_ns: u64 = 855_231_470_045;
        live.change(|s| {
            s.file(SHELL_FD, &render_ns(&shell, shell_ns + 100_000_000))
                .file(
                    "/proc/2133/fdinfo/6",
                    &render_ns(&shell, shell_ns + 100_000_000),
                )
                .file(
                    "/proc/4000/fdinfo/5",
                    &game.replace("1000000000 ns", "1400000000 ns"),
                )
                .file(
                    "/proc/4000/fdinfo/6",
                    &other.replace("drm-engine-gfx: 0 ns", "drm-engine-gfx: 900000000 ns"),
                )
        });
        let second = perf.sample(t0 + Duration::from_secs(1));
        assert_eq!(state(&second, "gpu_percent"), State::Supported);
        assert!(
            (value(&second, "gpu_percent") - 50.0).abs() < 1e-6,
            "{}",
            value(&second, "gpu_percent")
        );
    }

    #[test]
    fn an_engine_class_with_several_engines_is_shared_by_its_capacity() {
        let text = |ns: u64| {
            format!("drm-client-id: 1\ndrm-pdev: 0000:00:02.0\ndrm-engine-video: {ns} ns\ndrm-engine-capacity-video: 2\n")
        };
        let dump = FakeSource::from_dump(DELL)
            .without(SHELL_FD)
            .without("/proc/2133/fdinfo/6")
            .file(SHELL_FD, &text(0));
        let (live, perf) = sampler(dump, true);
        let t0 = Instant::now();
        perf.sample(t0);
        live.change(|s| s.file(SHELL_FD, &text(1_000_000_000)));
        let report = perf.sample(t0 + Duration::from_secs(1));
        assert!((value(&report, "gpu_percent") - 50.0).abs() < 1e-6);
    }

    #[test]
    fn a_driver_without_engine_times_has_no_gpu_load() {
        // xe counts cycles, not nanoseconds: no drm-engine-* keys at all.
        let xe = "drm-driver: xe\ndrm-client-id: 1\ndrm-pdev: 0000:00:02.0\ndrm-cycles-rcs: 100\ndrm-total-cycles-rcs: 1000\n";
        let dump = FakeSource::from_dump(DELL)
            .file(SHELL_FD, xe)
            .file("/proc/2133/fdinfo/6", xe);
        let (_, perf) = sampler(dump, true);
        assert_eq!(
            state(&perf.sample(Instant::now()), "gpu_percent"),
            State::Unsupported
        );
    }

    // --- RAPL

    #[test]
    fn root_only_energy_counters_mean_no_power() {
        let (_, perf) = sampler(FakeSource::from_dump(DELL), false);
        assert_eq!(
            state(&perf.sample(Instant::now()), "power_w"),
            State::Unsupported
        );
    }

    #[test]
    fn package_power_is_the_energy_since_the_reading_before() {
        let (live, perf) = sampler(FakeSource::from_dump(AMD), true);
        let t0 = Instant::now();
        assert_eq!(state(&perf.sample(t0), "power_w"), State::Unavailable);
        // 25 J in two seconds; the core domain (intel-rapl:0:0) is not added.
        live.change(|s| {
            s.file("/sys/class/powercap/intel-rapl:0/energy_uj", "1025000000\n")
                .file(
                    "/sys/class/powercap/intel-rapl:0:0/energy_uj",
                    "9999999999\n",
                )
        });
        let report = perf.sample(t0 + Duration::from_secs(2));
        assert_eq!(state(&report, "power_w"), State::Supported);
        assert!((value(&report, "power_w") - 12.5).abs() < 1e-9);
    }

    #[test]
    fn a_wrapped_energy_counter_is_unwrapped_at_its_range() {
        let (live, perf) = sampler(FakeSource::from_dump(AMD), true);
        let t0 = Instant::now();
        live.change(|s| {
            s.file(
                "/sys/class/powercap/intel-rapl:0/energy_uj",
                "65532610000\n",
            )
        });
        perf.sample(t0);
        // The range is 65532610987 uJ: 987 + 9_999_013 uJ = 10 J in one second.
        live.change(|s| s.file("/sys/class/powercap/intel-rapl:0/energy_uj", "9999013\n"));
        let report = perf.sample(t0 + Duration::from_secs(1));
        assert!(
            (value(&report, "power_w") - 10.0).abs() < 1e-9,
            "{}",
            value(&report, "power_w")
        );
    }

    #[test]
    fn a_reading_above_the_counters_range_gives_no_power() {
        let (live, perf) = sampler(FakeSource::from_dump(AMD), true);
        let t0 = Instant::now();
        // Above the range of 65532610987 uJ: a later, lower reading is not a wrap
        // (unwrapping would underflow, T-451 review), so no value is reported.
        live.change(|s| {
            s.file(
                "/sys/class/powercap/intel-rapl:0/energy_uj",
                "70000000000\n",
            )
        });
        perf.sample(t0);
        live.change(|s| s.file("/sys/class/powercap/intel-rapl:0/energy_uj", "1000\n"));
        let report = perf.sample(t0 + Duration::from_secs(1));
        assert_ne!(state(&report, "power_w"), State::Supported);
    }

    #[test]
    fn the_layout_is_found_again_after_a_minute() {
        let (live, perf) = sampler(FakeSource::from_dump(DELL), false);
        let t0 = Instant::now();
        assert_eq!(state(&perf.sample(t0), "gpu_temp"), State::Unsupported);
        // A GPU hwmon appears (a driver loaded late): not before the next discovery.
        live.change(|s| {
            s.file(
                "/sys/devices/pci0000:00/0000:00:02.0/hwmon/hwmon9/temp1_input",
                "40000\n",
            )
        });
        assert_eq!(
            state(&perf.sample(t0 + Duration::from_secs(1)), "gpu_temp"),
            State::Unsupported
        );
        let later = perf.sample(t0 + DISCOVER_EVERY + Duration::from_secs(1));
        assert_eq!(state(&later, "gpu_temp"), State::Supported);
        assert_eq!(value(&later, "gpu_temp"), 40.0);
    }
}
