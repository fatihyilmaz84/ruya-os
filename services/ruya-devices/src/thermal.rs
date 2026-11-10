//! The console's temperatures, fans and the level they add up to (org.ruyaos.Devices1.Thermal, T-200).
//!
//! The service only measures and classifies; what the console does about a warm, hot or critical
//! level (a toast, fewer effects, stopping the apps, a power-off) is the shell's policy
//! (`docs/specs/01-platform.md`, "Thermal policy"). Fans are never controlled here.
//!
//! The core is pure: [`Engine`] takes a [`Reading`] and a time and tells what changed; hysteresis,
//! the debounce and the filter for implausible readings are in it and tested on a fake clock.
//! [`Source`] is the I/O side: [`SysfsSource`] reads `/sys/class/hwmon` (and the thermal zones as a
//! fallback for the processor) read-only; [`FakeSource`] is for the tests and `--session`.
//!
//! Which sensors are listed: one for the processor package, one per graphics chip, NVMe drive and
//! SATA drive, and every fan. Cores and the board's other temperatures (`acpitz`, `pch_*`, the
//! many `dell_smm` ones) have no threshold in the policy and are left out. Sensors are keyed by
//! hwmon `name`, label and the device the hwmon belongs to, never by `hwmonN`, which renumbers
//! between boots.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use serde::Deserialize;

/// A temperature outside this range (degrees Celsius) is a broken sensor, not a measurement
/// (`dell_smm` on the Dell test machine reports 126 for a sensor that is not there).
pub const MIN_PLAUSIBLE: f64 = -20.0;
pub const MAX_PLAUSIBLE: f64 = 125.0;
/// A fan above this is a broken reading, too.
pub const MAX_RPM: f64 = 30_000.0;
/// A sensor without a plausible reading for this long is no longer listed.
pub const STALE_AFTER: Duration = Duration::from_secs(30);
/// A temperature below the warm threshold that does not change at all for this long while the
/// processor is busy the whole time is a stuck sensor and is ignored. (One at or above the warm
/// threshold is believed: a processor held at its limit under load really does stand still.)
pub const FROZEN_AFTER: Duration = Duration::from_secs(300);
/// The processor counts as busy at or above this share of non-idle time between two polls.
pub const BUSY_SHARE: f64 = 0.5;
/// How often the sensors are read, and how often while a level above normal holds.
pub const POLL: Duration = Duration::from_secs(5);
pub const POLL_FAST: Duration = Duration::from_secs(1);

pub const SYSTEM_CONFIG: &str = "/usr/lib/ruyaos/thermal.toml";
pub const LOCAL_CONFIG: &str = "/etc/ruyaos/thermal.toml";

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Normal,
    Warm,
    Hot,
    Critical,
}

impl Level {
    pub fn as_str(self) -> &'static str {
        match self {
            Level::Normal => "normal",
            Level::Warm => "warm",
            Level::Hot => "hot",
            Level::Critical => "critical",
        }
    }

    fn from_count(n: usize) -> Level {
        match n {
            0 => Level::Normal,
            1 => Level::Warm,
            2 => Level::Hot,
            _ => Level::Critical,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Class {
    Cpu,
    Gpu,
    /// NVMe drives and SATA SSDs.
    Ssd,
    /// Spinning SATA disks.
    Hdd,
    Fan,
}

impl Class {
    pub fn as_str(self) -> &'static str {
        match self {
            Class::Cpu => "cpu",
            Class::Gpu => "gpu",
            Class::Ssd => "ssd",
            Class::Hdd => "hdd",
            Class::Fan => "fan",
        }
    }

    /// The short English name the contract's `label` carries; the shell translates by class.
    pub fn label(self) -> &'static str {
        match self {
            Class::Cpu => "Processor",
            Class::Gpu => "Graphics",
            Class::Ssd | Class::Hdd => "Drive",
            Class::Fan => "Fan",
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Configuration

/// The thresholds of one temperature class. `critical` is `None` where it comes from the sensor.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Thresholds {
    pub warm: f64,
    pub hot: f64,
    pub critical: Option<f64>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    pub hysteresis: f64,
    pub debounce: Duration,
    pub stuck_fan: Duration,
    pub critical_margin: f64,
    pub critical_fallback: f64,
    pub cpu: Thresholds,
    pub gpu: Thresholds,
    pub ssd: Thresholds,
    pub hdd: Thresholds,
}

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct ClassFile {
    warm: Option<f64>,
    hot: Option<f64>,
    critical: Option<f64>,
}

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct ConfigFile {
    hysteresis: Option<f64>,
    debounce_seconds: Option<u64>,
    stuck_fan_seconds: Option<u64>,
    critical_margin: Option<f64>,
    critical_fallback: Option<f64>,
    cpu: Option<ClassFile>,
    gpu: Option<ClassFile>,
    ssd: Option<ClassFile>,
    hdd: Option<ClassFile>,
}

impl Default for Config {
    /// The table in `docs/specs/01-platform.md`; the shipped `thermal.toml` says the same.
    fn default() -> Self {
        let both = |warm, hot| Thresholds {
            warm,
            hot,
            critical: None,
        };
        let fixed = |warm, hot, critical| Thresholds {
            warm,
            hot,
            critical: Some(critical),
        };
        Config {
            hysteresis: 5.0,
            debounce: Duration::from_secs(10),
            stuck_fan: Duration::from_secs(30),
            critical_margin: 5.0,
            critical_fallback: 100.0,
            cpu: both(80.0, 90.0),
            gpu: both(80.0, 90.0),
            ssd: fixed(70.0, 75.0, 80.0),
            hdd: fixed(50.0, 55.0, 60.0),
        }
    }
}

impl Config {
    /// The defaults, then `paths` in order; a file that is missing is skipped, one that cannot be
    /// used is skipped with a message (never half applied).
    pub fn load(paths: &[PathBuf]) -> Config {
        let mut config = Config::default();
        for path in paths {
            let text = match fs::read_to_string(path) {
                Ok(text) => text,
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => continue,
                Err(err) => {
                    eprintln!("ruya-devices: cannot read {}: {err}", path.display());
                    continue;
                }
            };
            match config.with_file(&text) {
                Ok(next) => config = next,
                Err(err) => eprintln!("ruya-devices: ignoring {}: {err}", path.display()),
            }
        }
        config
    }

    /// This configuration with the values in `text` (a `thermal.toml`) replacing its own.
    pub fn with_file(&self, text: &str) -> Result<Config, String> {
        let file: ConfigFile = toml::from_str(text).map_err(|e| e.to_string())?;
        let mut next = self.clone();
        if let Some(v) = file.hysteresis {
            next.hysteresis = v;
        }
        if let Some(v) = file.debounce_seconds {
            next.debounce = Duration::from_secs(v);
        }
        if let Some(v) = file.stuck_fan_seconds {
            next.stuck_fan = Duration::from_secs(v);
        }
        if let Some(v) = file.critical_margin {
            next.critical_margin = v;
        }
        if let Some(v) = file.critical_fallback {
            next.critical_fallback = v;
        }
        let apply = |target: &mut Thresholds, file: Option<ClassFile>| {
            if let Some(file) = file {
                target.warm = file.warm.unwrap_or(target.warm);
                target.hot = file.hot.unwrap_or(target.hot);
                target.critical = file.critical.or(target.critical);
            }
        };
        apply(&mut next.cpu, file.cpu);
        apply(&mut next.gpu, file.gpu);
        apply(&mut next.ssd, file.ssd);
        apply(&mut next.hdd, file.hdd);
        next.validate()?;
        Ok(next)
    }

    fn validate(&self) -> Result<(), String> {
        let finite = |v: f64| v.is_finite();
        if !(finite(self.hysteresis) && (0.0..=20.0).contains(&self.hysteresis)) {
            return Err("hysteresis must be between 0 and 20".to_owned());
        }
        if self.debounce > Duration::from_secs(600) || self.stuck_fan > Duration::from_secs(3600) {
            return Err("debounce_seconds or stuck_fan_seconds is too long".to_owned());
        }
        if !(finite(self.critical_margin) && (0.0..=50.0).contains(&self.critical_margin)) {
            return Err("critical_margin must be between 0 and 50".to_owned());
        }
        if !(finite(self.critical_fallback)
            && self.critical_fallback > 0.0
            && self.critical_fallback <= MAX_PLAUSIBLE)
        {
            return Err("critical_fallback is out of range".to_owned());
        }
        for (name, t) in [
            ("cpu", self.cpu),
            ("gpu", self.gpu),
            ("ssd", self.ssd),
            ("hdd", self.hdd),
        ] {
            let ordered = finite(t.warm)
                && finite(t.hot)
                && t.warm < t.hot
                && t.critical.map_or(true, |c| finite(c) && t.hot < c);
            if !ordered {
                return Err(format!("[{name}] needs warm < hot < critical"));
            }
        }
        Ok(())
    }

    fn class(&self, class: Class) -> Option<&Thresholds> {
        match class {
            Class::Cpu => Some(&self.cpu),
            Class::Gpu => Some(&self.gpu),
            Class::Ssd => Some(&self.ssd),
            Class::Hdd => Some(&self.hdd),
            Class::Fan => None,
        }
    }

    /// `[warm, hot, critical]` for a temperature of `class`. Where the class has no fixed
    /// critical, it is the sensor's own limit minus the margin (never at or under `hot`), or the
    /// fallback when the sensor reports none.
    pub fn levels(&self, class: Class, sensor_crit: Option<f64>) -> Option<[f64; 3]> {
        let t = self.class(class)?;
        let critical = t.critical.unwrap_or_else(|| {
            let from = match sensor_crit {
                Some(c) if c > 0.0 && c <= MAX_PLAUSIBLE => c - self.critical_margin,
                _ => self.critical_fallback,
            };
            from.max(t.hot + 1.0)
        });
        Some([t.warm, t.hot, critical])
    }
}

// ---------------------------------------------------------------------------------------------
// The engine

/// One sensor as a source reports it.
#[derive(Debug, Clone, PartialEq)]
pub struct RawSensor {
    pub id: String,
    pub class: Class,
    /// Degrees Celsius, or rpm for a fan.
    pub value: f64,
    /// The sensor's own critical limit (the last trip point of a thermal zone), degrees Celsius.
    pub crit: Option<f64>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Reading {
    pub sensors: Vec<RawSensor>,
    /// The processor was busy (at least [`BUSY_SHARE`]) since the last reading.
    pub cpu_busy: bool,
}

/// One listed sensor, the contract's dictionary.
#[derive(Debug, Clone, PartialEq)]
pub struct SensorInfo {
    pub id: String,
    pub label: &'static str,
    pub class: Class,
    pub value: f64,
    pub level: Level,
    pub max_seen: f64,
}

/// The worst level changed, and the sensor it is about (when it falls back to normal: the one
/// that held the level before).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LevelChange {
    pub level: Level,
    pub sensor: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Update {
    /// The list differs from the one before at the granularity it is shown in (a whole degree,
    /// 10 rpm, another level, a sensor that came or went).
    pub sensors_changed: bool,
    pub level: Option<LevelChange>,
}

struct State {
    class: Class,
    value: f64,
    max_seen: f64,
    level: Level,
    /// Since when the reading has been at or above warm, hot and critical without a break.
    above_since: [Option<Duration>; 3],
    last_valid: Duration,
    /// Since when the value has not changed; and whether the processor was idle at any time since.
    same_since: Duration,
    idle_since_change: bool,
    ignored: bool,
    /// A fan that read 0 rpm since then, while the processor was warm.
    zero_since: Option<Duration>,
}

pub struct Engine {
    config: Config,
    sensors: BTreeMap<String, State>,
    level: Level,
    level_sensor: String,
    shown: String,
}

fn plausible(class: Class, value: f64) -> bool {
    match class {
        Class::Fan => value.is_finite() && (0.0..=MAX_RPM).contains(&value),
        _ => value.is_finite() && (MIN_PLAUSIBLE..=MAX_PLAUSIBLE).contains(&value),
    }
}

impl Engine {
    pub fn new(config: Config) -> Self {
        Engine {
            config,
            sensors: BTreeMap::new(),
            level: Level::Normal,
            level_sensor: String::new(),
            shown: String::new(),
        }
    }

    /// The worst level over all listed sensors.
    pub fn level(&self) -> Level {
        self.level
    }

    /// How long to wait before the next reading.
    pub fn interval(&self) -> Duration {
        if self.level > Level::Normal {
            POLL_FAST
        } else {
            POLL
        }
    }

    /// The listed sensors: processor, graphics, drives, fans; then by id.
    pub fn list(&self) -> Vec<SensorInfo> {
        let mut out: Vec<SensorInfo> = self
            .sensors
            .iter()
            .filter(|(_, s)| !s.ignored)
            .map(|(id, s)| SensorInfo {
                id: id.clone(),
                label: s.class.label(),
                class: s.class,
                value: s.value,
                level: s.level,
                max_seen: s.max_seen,
            })
            .collect();
        out.sort_by(|a, b| (a.class, &a.id).cmp(&(b.class, &b.id)));
        out
    }

    /// Takes a reading made at `now` (any fixed start; only differences matter).
    pub fn update(&mut self, now: Duration, reading: &Reading) -> Update {
        let config = self.config.clone();
        for raw in &reading.sensors {
            if !plausible(raw.class, raw.value) {
                continue;
            }
            let state = self.sensors.entry(raw.id.clone()).or_insert_with(|| State {
                class: raw.class,
                value: raw.value,
                max_seen: raw.value,
                level: Level::Normal,
                above_since: [None; 3],
                last_valid: now,
                same_since: now,
                idle_since_change: !reading.cpu_busy,
                ignored: false,
                zero_since: None,
            });
            state.class = raw.class;
            state.last_valid = now;
            if raw.value != state.value {
                state.same_since = now;
                state.idle_since_change = !reading.cpu_busy;
            } else {
                state.idle_since_change |= !reading.cpu_busy;
            }
            state.value = raw.value;
            state.max_seen = state.max_seen.max(raw.value);
            let Some(levels) = config.levels(raw.class, raw.crit) else {
                continue;
            };
            state.ignored = !state.idle_since_change
                && now.saturating_sub(state.same_since) >= FROZEN_AFTER
                && raw.value < levels[0];
            if state.ignored {
                state.level = Level::Normal;
                state.above_since = [None; 3];
                continue;
            }
            for (since, threshold) in state.above_since.iter_mut().zip(levels) {
                if raw.value >= threshold {
                    since.get_or_insert(now);
                } else {
                    *since = None;
                }
            }
            state.level = next_level(&config, state, &levels, now);
        }
        self.sensors
            .retain(|_, s| now.saturating_sub(s.last_valid) <= STALE_AFTER);

        // A fan that was seen spinning and stands still while the processor is warm: hot.
        let cpu_warm = self
            .sensors
            .values()
            .any(|s| s.class == Class::Cpu && !s.ignored && s.level >= Level::Warm);
        for s in self.sensors.values_mut().filter(|s| s.class == Class::Fan) {
            if cpu_warm && s.value == 0.0 && s.max_seen > 0.0 {
                let since = *s.zero_since.get_or_insert(now);
                s.level = if now.saturating_sub(since) >= config.stuck_fan {
                    Level::Hot
                } else {
                    Level::Normal
                };
            } else {
                s.zero_since = None;
                s.level = Level::Normal;
            }
        }

        let worst = self.sensors.iter().filter(|(_, s)| !s.ignored).fold(
            (Level::Normal, None),
            |best: (Level, Option<&String>), (id, s)| {
                if s.level > best.0 {
                    (s.level, Some(id))
                } else {
                    best
                }
            },
        );
        let mut update = Update::default();
        if worst.0 != self.level {
            update.level = Some(LevelChange {
                level: worst.0,
                sensor: worst
                    .1
                    .cloned()
                    .unwrap_or_else(|| self.level_sensor.clone()),
            });
            self.level = worst.0;
        }
        if let Some(id) = worst.1 {
            self.level_sensor = id.clone();
        }

        let shown = self.signature();
        update.sensors_changed = shown != self.shown;
        self.shown = shown;
        update
    }

    /// What a client of the list can see: ids, levels, whole degrees, 10 rpm.
    fn signature(&self) -> String {
        let mut out = String::new();
        for s in self.list() {
            let step = if s.class == Class::Fan { 10.0 } else { 1.0 };
            let _ = write!(
                out,
                "{}|{}|{}|{};",
                s.id,
                s.level.as_str(),
                (s.value / step).round(),
                (s.max_seen / step).round()
            );
        }
        out
    }
}

/// The level a temperature has now: it falls one step at a time, each only when the reading is
/// `hysteresis` below that step's threshold, and rises to the highest step it has stayed at or
/// above for the debounce time.
fn next_level(config: &Config, state: &State, levels: &[f64; 3], now: Duration) -> Level {
    let mut level = state.level as usize;
    while level > 0
        && state.value < levels[level - 1]
        && state.value <= levels[level - 1] - config.hysteresis
    {
        level -= 1;
    }
    for (i, since) in state.above_since.iter().enumerate().rev() {
        if let Some(since) = since {
            if now.saturating_sub(*since) >= config.debounce {
                level = level.max(i + 1);
                break;
            }
        }
    }
    Level::from_count(level)
}

// ---------------------------------------------------------------------------------------------
// Sources

pub trait Source: Send + Sync {
    /// All sensors now. An error only when nothing could be read at all; a machine without
    /// sensors is an empty reading.
    fn read(&self) -> Result<Reading, String>;
}

impl<T: Source + ?Sized> Source for Box<T> {
    fn read(&self) -> Result<Reading, String> {
        (**self).read()
    }
}

/// A source the test (or `--session`) sets.
pub struct FakeSource(Mutex<Reading>);

impl FakeSource {
    pub fn new(sensors: Vec<RawSensor>) -> Self {
        FakeSource(Mutex::new(Reading {
            sensors,
            cpu_busy: false,
        }))
    }

    pub fn set(&self, sensors: Vec<RawSensor>, cpu_busy: bool) {
        *self.0.lock().unwrap_or_else(|e| e.into_inner()) = Reading { sensors, cpu_busy };
    }
}

impl Source for FakeSource {
    fn read(&self) -> Result<Reading, String> {
        Ok(self.0.lock().unwrap_or_else(|e| e.into_inner()).clone())
    }
}

/// The sensors, read from `root` (`/sys`) and `proc_stat` (`/proc/stat`), read-only.
pub struct SysfsSource {
    root: PathBuf,
    proc_stat: PathBuf,
    /// `(total, busy)` jiffies at the last reading.
    last_cpu: Mutex<Option<(u64, u64)>>,
}

impl SysfsSource {
    pub fn new(root: impl Into<PathBuf>, proc_stat: impl Into<PathBuf>) -> Self {
        SysfsSource {
            root: root.into(),
            proc_stat: proc_stat.into(),
            last_cpu: Mutex::new(None),
        }
    }

    /// The real `/sys` and `/proc/stat`.
    pub fn system() -> Self {
        Self::new("/sys", "/proc/stat")
    }

    fn cpu_busy(&self) -> bool {
        let Some(now) = fs::read_to_string(&self.proc_stat)
            .ok()
            .and_then(|text| parse_cpu_jiffies(&text))
        else {
            return false;
        };
        let mut last: MutexGuard<'_, Option<(u64, u64)>> =
            self.last_cpu.lock().unwrap_or_else(|e| e.into_inner());
        let before = last.replace(now);
        match before {
            Some((total, busy)) if now.0 > total => {
                (now.1.saturating_sub(busy)) as f64 / (now.0 - total) as f64 >= BUSY_SHARE
            }
            _ => false,
        }
    }
}

/// `(total, busy)` jiffies from the first line of `/proc/stat` (`cpu  user nice system idle
/// iowait irq softirq steal ...`); idle and iowait are not busy.
pub(crate) fn parse_cpu_jiffies(text: &str) -> Option<(u64, u64)> {
    let line = text.lines().next()?;
    let mut fields = line.split_whitespace();
    if fields.next()? != "cpu" {
        return None;
    }
    let v: Vec<u64> = fields.filter_map(|f| f.parse().ok()).collect();
    if v.len() < 4 {
        return None;
    }
    let total: u64 = v.iter().take(8).sum();
    let idle = v[3] + v.get(4).copied().unwrap_or(0);
    Some((total, total.saturating_sub(idle)))
}

fn read_trimmed(path: &Path) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_owned())
}

/// A kernel file in millidegrees (or millis of anything), as a number.
fn read_milli(path: &Path) -> Option<f64> {
    read_trimmed(path)?.parse::<f64>().ok().map(|v| v / 1000.0)
}

fn read_number(path: &Path) -> Option<f64> {
    read_trimmed(path)?.parse::<f64>().ok()
}

/// Entries of a directory whose names start with `prefix`, sorted.
fn entries(dir: &Path, prefix: &str) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .filter_map(|e| e.file_name().into_string().ok())
                .filter(|n| n.starts_with(prefix))
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

/// The numbers `N` of the files `<prefix>N<suffix>` in `dir`, ascending.
fn numbered(dir: &Path, prefix: &str, suffix: &str) -> Vec<u32> {
    let mut out: Vec<u32> = entries(dir, prefix)
        .iter()
        .filter_map(|n| n.strip_prefix(prefix)?.strip_suffix(suffix)?.parse().ok())
        .collect();
    out.sort_unstable();
    out
}

/// The temperature inputs of one hwmon that stand for the sensor of its class: the processor's
/// "Package id N" (or `Tctl`/`Tdie`), a GPU's "edge", an NVMe's "Composite"; else the first one.
pub(crate) fn pick<'a>(class: Class, temps: &'a [(u32, String)]) -> Vec<&'a (u32, String)> {
    let starting = |prefix: &str| -> Vec<&'a (u32, String)> {
        temps
            .iter()
            .filter(|(_, l)| l.starts_with(prefix))
            .collect()
    };
    let preferred: &[&str] = match class {
        Class::Cpu => &["Package id", "Tctl", "Tdie"],
        Class::Gpu => &["edge"],
        Class::Ssd => &["Composite"],
        _ => &[],
    };
    for prefix in preferred {
        let found = starting(prefix);
        if !found.is_empty() {
            // One processor package each; for the others just the first.
            return if class == Class::Cpu {
                found
            } else {
                found.into_iter().take(1).collect()
            };
        }
    }
    temps.iter().take(1).collect()
}

/// A SATA disk behind `drivetemp` is a solid-state one when its block device says it does not
/// rotate; unknown counts as a disk (the lower thresholds).
fn drive_class(hwmon: &Path) -> Class {
    let block = hwmon.join("device").join("block");
    for disk in entries(&block, "") {
        if read_trimmed(&block.join(disk).join("queue").join("rotational")).as_deref() == Some("0")
        {
            return Class::Ssd;
        }
    }
    Class::Hdd
}

impl SysfsSource {
    fn hwmon_sensors(&self, out: &mut Vec<RawSensor>) {
        let base = self.root.join("class").join("hwmon");
        for entry in entries(&base, "hwmon") {
            let dir = base.join(&entry);
            let Some(name) = read_trimmed(&dir.join("name")) else {
                continue;
            };
            // The device the hwmon belongs to; the target of the `device` link (coretemp.0, nvme0).
            let device = fs::read_link(dir.join("device"))
                .ok()
                .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
                .unwrap_or_default();
            let class = match name.as_str() {
                "coretemp" | "k10temp" | "zenpower" => Some(Class::Cpu),
                "amdgpu" | "nouveau" | "nvidia" => Some(Class::Gpu),
                "nvme" => Some(Class::Ssd),
                "drivetemp" => Some(drive_class(&dir)),
                _ => None,
            };
            if let Some(class) = class {
                let temps: Vec<(u32, String)> = numbered(&dir, "temp", "_input")
                    .into_iter()
                    .map(|n| {
                        let label = read_trimmed(&dir.join(format!("temp{n}_label")))
                            .unwrap_or_else(|| format!("temp{n}"));
                        (n, label)
                    })
                    .collect();
                for (n, label) in pick(class, &temps) {
                    let Some(value) = read_milli(&dir.join(format!("temp{n}_input"))) else {
                        continue;
                    };
                    out.push(RawSensor {
                        id: format!("{name}:{label}:{device}"),
                        class,
                        value,
                        crit: read_milli(&dir.join(format!("temp{n}_crit"))),
                    });
                }
            }
            for n in numbered(&dir, "fan", "_input") {
                let Some(value) = read_number(&dir.join(format!("fan{n}_input"))) else {
                    continue;
                };
                let label = read_trimmed(&dir.join(format!("fan{n}_label")))
                    .unwrap_or_else(|| format!("fan{n}"));
                out.push(RawSensor {
                    id: format!("{name}:{label}:{device}"),
                    class: Class::Fan,
                    value,
                    crit: None,
                });
            }
        }
    }

    /// The processor package from the thermal zones, for a machine without `coretemp`/`k10temp`.
    /// Its own limit is the zone's critical trip point, else its last trip point.
    fn zone_sensors(&self, out: &mut Vec<RawSensor>) {
        let base = self.root.join("class").join("thermal");
        for entry in entries(&base, "thermal_zone") {
            let dir = base.join(&entry);
            if read_trimmed(&dir.join("type")).as_deref() != Some("x86_pkg_temp") {
                continue;
            }
            let Some(value) = read_milli(&dir.join("temp")) else {
                continue;
            };
            let mut critical = None;
            let mut last = None;
            for n in numbered(&dir, "trip_point_", "_temp") {
                let temp = read_milli(&dir.join(format!("trip_point_{n}_temp")));
                if read_trimmed(&dir.join(format!("trip_point_{n}_type"))).as_deref()
                    == Some("critical")
                {
                    critical = critical.or(temp);
                }
                last = temp.or(last);
            }
            out.push(RawSensor {
                id: "thermal:x86_pkg_temp".to_owned(),
                class: Class::Cpu,
                value,
                crit: critical.or(last),
            });
        }
    }
}

impl Source for SysfsSource {
    fn read(&self) -> Result<Reading, String> {
        let mut sensors = Vec::new();
        self.hwmon_sensors(&mut sensors);
        if !sensors.iter().any(|s| s.class == Class::Cpu) {
            self.zone_sensors(&mut sensors);
        }
        // Two sensors with the same name, label and device (two identical drives behind one link):
        // told apart by their order, which is the hwmon order and so stable between reads.
        let mut seen: BTreeMap<String, usize> = BTreeMap::new();
        for sensor in &mut sensors {
            let n = seen.entry(sensor.id.clone()).or_insert(0);
            *n += 1;
            if *n > 1 {
                sensor.id = format!("{}#{}", sensor.id, n);
            }
        }
        Ok(Reading {
            sensors,
            cpu_busy: self.cpu_busy(),
        })
    }
}

// ---------------------------------------------------------------------------------------------
// The shared monitor

/// A source, the engine and the clock together: what the D-Bus adapter holds.
pub struct Monitor<S: Source> {
    source: S,
    start: Instant,
    engine: Mutex<Engine>,
}

impl<S: Source> Monitor<S> {
    pub fn new(source: S, config: Config) -> Self {
        Monitor {
            source,
            start: Instant::now(),
            engine: Mutex::new(Engine::new(config)),
        }
    }

    fn engine(&self) -> MutexGuard<'_, Engine> {
        // A poisoned lock only means another call panicked; the state is plain data.
        self.engine.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Reads the sensors (blocks: call it on the blocking pool) and returns what changed.
    pub fn poll(&self) -> Result<Update, String> {
        self.poll_at(self.start.elapsed())
    }

    pub fn poll_at(&self, now: Duration) -> Result<Update, String> {
        // The slow part, outside the lock: the list and the level stay answerable meanwhile.
        let reading = self.source.read()?;
        Ok(self.engine().update(now, &reading))
    }

    pub fn list(&self) -> Vec<SensorInfo> {
        self.engine().list()
    }

    pub fn level(&self) -> Level {
        self.engine().level()
    }

    pub fn interval(&self) -> Duration {
        self.engine().interval()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secs(n: u64) -> Duration {
        Duration::from_secs(n)
    }

    fn sensor(id: &str, class: Class, value: f64) -> RawSensor {
        RawSensor {
            id: id.to_owned(),
            class,
            value,
            crit: None,
        }
    }

    fn reading(sensors: Vec<RawSensor>) -> Reading {
        Reading {
            sensors,
            cpu_busy: false,
        }
    }

    /// An engine and a clock that moves in 5 s polls.
    struct Rig {
        engine: Engine,
        now: Duration,
    }

    impl Rig {
        fn new() -> Rig {
            Rig::with(Config::default())
        }

        fn with(config: Config) -> Rig {
            Rig {
                engine: Engine::new(config),
                now: Duration::ZERO,
            }
        }

        fn poll(&mut self, sensors: Vec<RawSensor>) -> Update {
            self.engine.update(self.now, &reading(sensors))
        }

        /// Reads the same sensors every 5 s for `seconds`, returns the last update's level change.
        fn hold(&mut self, sensors: &[RawSensor], seconds: u64) {
            let end = self.now + secs(seconds);
            self.poll(sensors.to_vec());
            while self.now < end {
                self.now += secs(5);
                self.poll(sensors.to_vec());
            }
        }

        fn level_of(&self, id: &str) -> Level {
            self.engine
                .list()
                .iter()
                .find(|s| s.id == id)
                .map(|s| s.level)
                .unwrap_or(Level::Normal)
        }
    }

    fn cpu(value: f64) -> RawSensor {
        RawSensor {
            crit: Some(100.0),
            ..sensor("cpu", Class::Cpu, value)
        }
    }

    // --- classification: each class at, below and above each threshold

    fn settled(class: Class, value: f64, crit: Option<f64>) -> Level {
        let mut rig = Rig::new();
        let s = RawSensor {
            crit,
            ..sensor("s", class, value)
        };
        rig.hold(&[s], 20);
        rig.level_of("s")
    }

    #[test]
    fn cpu_levels_at_below_and_above_each_threshold() {
        let level = |v| settled(Class::Cpu, v, Some(100.0));
        assert_eq!(level(79.9), Level::Normal);
        assert_eq!(level(80.0), Level::Warm);
        assert_eq!(level(89.9), Level::Warm);
        assert_eq!(level(90.0), Level::Hot);
        // Critical is the sensor's own limit minus 5: 95.
        assert_eq!(level(94.9), Level::Hot);
        assert_eq!(level(95.0), Level::Critical);
        assert_eq!(level(110.0), Level::Critical);
    }

    #[test]
    fn gpu_levels_follow_the_cpu_table_and_the_sensors_own_limit() {
        let level = |v, crit| settled(Class::Gpu, v, crit);
        assert_eq!(level(79.0, Some(105.0)), Level::Normal);
        assert_eq!(level(80.0, Some(105.0)), Level::Warm);
        assert_eq!(level(90.0, Some(105.0)), Level::Hot);
        assert_eq!(level(99.9, Some(105.0)), Level::Hot);
        assert_eq!(level(100.0, Some(105.0)), Level::Critical);
    }

    #[test]
    fn without_a_limit_critical_is_100() {
        let level = |v| settled(Class::Cpu, v, None);
        assert_eq!(level(99.9), Level::Hot);
        assert_eq!(level(100.0), Level::Critical);
        // A nonsense limit is no limit.
        assert_eq!(settled(Class::Cpu, 99.9, Some(0.0)), Level::Hot);
        assert_eq!(settled(Class::Cpu, 100.0, Some(300.0)), Level::Critical);
    }

    #[test]
    fn a_low_limit_never_puts_critical_under_hot() {
        // crit 92 minus 5 is under hot (90): critical is 91, still above hot.
        let level = |v| settled(Class::Cpu, v, Some(92.0));
        assert_eq!(level(90.0), Level::Hot);
        assert_eq!(level(91.0), Level::Critical);
    }

    #[test]
    fn ssd_levels_are_fixed() {
        // The sensor's own limit does not matter for drives.
        let level = |v| settled(Class::Ssd, v, Some(84.0));
        assert_eq!(level(69.9), Level::Normal);
        assert_eq!(level(70.0), Level::Warm);
        assert_eq!(level(74.9), Level::Warm);
        assert_eq!(level(75.0), Level::Hot);
        assert_eq!(level(79.9), Level::Hot);
        assert_eq!(level(80.0), Level::Critical);
    }

    #[test]
    fn hdd_levels_are_fixed() {
        let level = |v| settled(Class::Hdd, v, None);
        assert_eq!(level(49.9), Level::Normal);
        assert_eq!(level(50.0), Level::Warm);
        assert_eq!(level(55.0), Level::Hot);
        assert_eq!(level(59.9), Level::Hot);
        assert_eq!(level(60.0), Level::Critical);
    }

    #[test]
    fn a_fan_at_any_speed_is_normal_by_itself() {
        assert_eq!(settled(Class::Fan, 0.0, None), Level::Normal);
        assert_eq!(settled(Class::Fan, 5000.0, None), Level::Normal);
    }

    // --- hysteresis

    #[test]
    fn a_level_clears_only_five_degrees_lower() {
        let mut rig = Rig::new();
        rig.hold(&[cpu(91.0)], 15);
        assert_eq!(rig.level_of("cpu"), Level::Hot);
        // 86 is under hot (90) but not 5 under it: still hot.
        rig.hold(&[cpu(86.0)], 30);
        assert_eq!(rig.level_of("cpu"), Level::Hot);
        assert_eq!(rig.engine.level(), Level::Hot);
        // 85 is 5 under 90: hot clears; warm (80) holds until 75.
        rig.hold(&[cpu(85.0)], 5);
        assert_eq!(rig.level_of("cpu"), Level::Warm);
        rig.hold(&[cpu(76.0)], 30);
        assert_eq!(rig.level_of("cpu"), Level::Warm);
        rig.hold(&[cpu(75.0)], 5);
        assert_eq!(rig.level_of("cpu"), Level::Normal);
        assert_eq!(rig.engine.level(), Level::Normal);
    }

    #[test]
    fn a_big_drop_clears_several_levels_at_once() {
        let mut rig = Rig::new();
        rig.hold(&[cpu(97.0)], 15);
        assert_eq!(rig.level_of("cpu"), Level::Critical);
        rig.hold(&[cpu(60.0)], 5);
        assert_eq!(rig.level_of("cpu"), Level::Normal);
    }

    #[test]
    fn a_reading_that_wobbles_around_a_threshold_does_not_flap() {
        let mut rig = Rig::new();
        rig.hold(&[cpu(80.0)], 15);
        assert_eq!(rig.level_of("cpu"), Level::Warm);
        let mut changes = 0;
        for v in [79.0, 80.0, 78.0, 81.0, 77.0, 80.0, 79.0] {
            rig.now += secs(5);
            if rig.poll(vec![cpu(v)]).level.is_some() {
                changes += 1;
            }
        }
        assert_eq!(changes, 0);
        assert_eq!(rig.level_of("cpu"), Level::Warm);
    }

    // --- the 10 s debounce

    #[test]
    fn a_level_needs_ten_seconds_above_its_threshold() {
        let mut rig = Rig::new();
        rig.poll(vec![cpu(85.0)]);
        rig.now = secs(9);
        let update = rig.poll(vec![cpu(85.0)]);
        assert_eq!(update.level, None);
        assert_eq!(rig.level_of("cpu"), Level::Normal);
        rig.now = secs(10);
        let update = rig.poll(vec![cpu(85.0)]);
        assert_eq!(
            update.level,
            Some(LevelChange {
                level: Level::Warm,
                sensor: "cpu".to_owned()
            })
        );
    }

    #[test]
    fn a_dip_below_the_threshold_restarts_the_ten_seconds() {
        let mut rig = Rig::new();
        rig.poll(vec![cpu(85.0)]);
        rig.now = secs(8);
        rig.poll(vec![cpu(85.0)]);
        rig.now = secs(9);
        rig.poll(vec![cpu(70.0)]);
        rig.now = secs(12);
        rig.poll(vec![cpu(85.0)]);
        rig.now = secs(21);
        rig.poll(vec![cpu(85.0)]);
        assert_eq!(rig.level_of("cpu"), Level::Normal, "9 s since the dip");
        rig.now = secs(22);
        rig.poll(vec![cpu(85.0)]);
        assert_eq!(rig.level_of("cpu"), Level::Warm);
    }

    #[test]
    fn each_level_has_its_own_ten_seconds() {
        let mut rig = Rig::new();
        rig.hold(&[cpu(85.0)], 10);
        assert_eq!(rig.level_of("cpu"), Level::Warm);
        // Hot starts counting when the reading reaches 90, not when it reached warm.
        rig.now += secs(5);
        rig.poll(vec![cpu(92.0)]);
        rig.now += secs(5);
        rig.poll(vec![cpu(92.0)]);
        assert_eq!(rig.level_of("cpu"), Level::Warm);
        rig.now += secs(5);
        rig.poll(vec![cpu(92.0)]);
        assert_eq!(rig.level_of("cpu"), Level::Hot);
    }

    #[test]
    fn the_debounce_time_comes_from_the_configuration() {
        let config = Config::default()
            .with_file("debounce_seconds = 30")
            .unwrap();
        let mut rig = Rig::with(config);
        rig.hold(&[cpu(85.0)], 25);
        assert_eq!(rig.level_of("cpu"), Level::Normal);
        rig.hold(&[cpu(85.0)], 10);
        assert_eq!(rig.level_of("cpu"), Level::Warm);
    }

    // --- implausible readings

    #[test]
    fn readings_outside_the_plausible_range_are_ignored() {
        let mut rig = Rig::new();
        for bogus in [126.0, 125.1, -50.0, -20.1, f64::NAN, f64::INFINITY] {
            rig.now += secs(5);
            rig.poll(vec![cpu(bogus)]);
        }
        rig.hold(&[cpu(126.0)], 60);
        assert!(rig.engine.list().is_empty(), "never had a valid reading");
        assert_eq!(rig.engine.level(), Level::Normal);
    }

    #[test]
    fn a_bogus_spike_neither_raises_the_level_nor_the_maximum() {
        let mut rig = Rig::new();
        rig.hold(&[cpu(40.0)], 15);
        rig.now += secs(5);
        let update = rig.poll(vec![cpu(126.0)]);
        assert_eq!(update, Update::default());
        rig.now += secs(5);
        rig.poll(vec![cpu(-50.0)]);
        let list = rig.engine.list();
        assert_eq!((list[0].value, list[0].max_seen), (40.0, 40.0));
        assert_eq!(rig.engine.level(), Level::Normal);
    }

    #[test]
    fn the_plausible_limits_themselves_are_readings() {
        let mut rig = Rig::new();
        rig.hold(&[cpu(125.0)], 15);
        assert_eq!(rig.level_of("cpu"), Level::Critical);
        let mut rig = Rig::new();
        rig.hold(&[cpu(-20.0)], 15);
        assert_eq!(rig.level_of("cpu"), Level::Normal);
        assert_eq!(rig.engine.list().len(), 1);
    }

    #[test]
    fn a_sensor_that_keeps_failing_leaves_the_list_after_thirty_seconds() {
        let mut rig = Rig::new();
        rig.hold(&[cpu(90.0)], 15);
        assert_eq!(rig.engine.level(), Level::Hot);
        rig.now += secs(30);
        rig.poll(vec![cpu(126.0)]);
        assert_eq!(rig.engine.list().len(), 1, "30 s is not yet more than 30 s");
        rig.now += secs(5);
        let update = rig.poll(vec![]);
        assert!(rig.engine.list().is_empty());
        assert!(update.sensors_changed);
        assert_eq!(
            update.level,
            Some(LevelChange {
                level: Level::Normal,
                sensor: "cpu".to_owned()
            })
        );
    }

    #[test]
    fn a_sensor_stuck_at_one_value_while_the_cpu_is_busy_is_ignored() {
        let mut rig = Rig::new();
        let busy = |value| Reading {
            sensors: vec![sensor("ssd", Class::Ssd, value)],
            cpu_busy: true,
        };
        let mut t = Duration::ZERO;
        while t <= FROZEN_AFTER - secs(5) {
            rig.engine.update(t, &busy(41.0));
            t += secs(5);
        }
        assert_eq!(rig.engine.list().len(), 1, "not long enough");
        rig.engine.update(FROZEN_AFTER, &busy(41.0));
        assert!(rig.engine.list().is_empty(), "ignored: no row, no level");
        // It moves again: believed again.
        let update = rig.engine.update(FROZEN_AFTER + secs(5), &busy(42.0));
        assert!(update.sensors_changed);
        assert_eq!(rig.engine.list().len(), 1);
    }

    #[test]
    fn a_steady_sensor_is_believed_when_the_cpu_was_idle_at_some_point() {
        let mut rig = Rig::new();
        let at = |busy| Reading {
            sensors: vec![sensor("ssd", Class::Ssd, 41.0)],
            cpu_busy: busy,
        };
        let mut t = Duration::ZERO;
        while t < FROZEN_AFTER + secs(60) {
            rig.engine.update(t, &at(t != secs(100)));
            t += secs(5);
        }
        assert_eq!(rig.engine.list().len(), 1);
    }

    #[test]
    fn a_processor_held_at_its_limit_under_load_is_believed() {
        let mut rig = Rig::new();
        let busy = Reading {
            sensors: vec![cpu(100.0)],
            cpu_busy: true,
        };
        let mut t = Duration::ZERO;
        while t <= FROZEN_AFTER + secs(60) {
            rig.engine.update(t, &busy);
            t += secs(5);
        }
        assert_eq!(rig.engine.list().len(), 1);
        assert_eq!(rig.engine.level(), Level::Critical);
    }

    // --- the level, the sensor and the signals

    #[test]
    fn the_level_is_the_worst_and_names_its_sensor() {
        let mut rig = Rig::new();
        let drive = sensor("nvme", Class::Ssd, 76.0);
        rig.hold(&[cpu(50.0), drive.clone()], 15);
        assert_eq!(rig.engine.level(), Level::Hot);
        rig.hold(&[cpu(97.0), drive.clone()], 15);
        assert_eq!(rig.engine.level(), Level::Critical);
        let update = rig.poll(vec![cpu(97.0), sensor("nvme", Class::Ssd, 85.0)]);
        assert_eq!(update.level, None, "same worst level, nothing to say");
    }

    #[test]
    fn a_repeat_of_the_same_level_is_not_announced_again() {
        let mut rig = Rig::new();
        let mut announced = 0;
        for _ in 0..12 {
            rig.now += secs(5);
            if rig.poll(vec![cpu(92.0)]).level.is_some() {
                announced += 1;
            }
        }
        // Normal -> hot once (warm is skipped: the reading was at 92 for 10 s).
        assert_eq!(announced, 1);
    }

    #[test]
    fn falling_back_to_normal_names_the_sensor_that_held_the_level() {
        let mut rig = Rig::new();
        rig.hold(&[cpu(92.0)], 15);
        rig.now += secs(5);
        let update = rig.poll(vec![cpu(50.0)]);
        assert_eq!(
            update.level,
            Some(LevelChange {
                level: Level::Normal,
                sensor: "cpu".to_owned()
            })
        );
    }

    #[test]
    fn the_list_changes_only_when_something_shown_changes() {
        let mut rig = Rig::new();
        assert!(rig.poll(vec![cpu(33.0)]).sensors_changed, "first sensor");
        rig.now += secs(5);
        assert!(!rig.poll(vec![cpu(33.2)]).sensors_changed, "under a degree");
        rig.now += secs(5);
        assert!(rig.poll(vec![cpu(34.0)]).sensors_changed);
        let fan = |rpm| sensor("fan", Class::Fan, rpm);
        rig.now += secs(5);
        assert!(rig.poll(vec![cpu(34.0), fan(1820.0)]).sensors_changed);
        rig.now += secs(5);
        assert!(!rig.poll(vec![cpu(34.0), fan(1823.0)]).sensors_changed);
        rig.now += secs(5);
        assert!(rig.poll(vec![cpu(34.0), fan(1850.0)]).sensors_changed);
    }

    #[test]
    fn max_seen_is_the_highest_valid_reading() {
        let mut rig = Rig::new();
        for v in [40.0, 71.0, 55.0] {
            rig.now += secs(5);
            rig.poll(vec![cpu(v)]);
        }
        let list = rig.engine.list();
        assert_eq!((list[0].value, list[0].max_seen), (55.0, 71.0));
    }

    #[test]
    fn the_list_is_ordered_by_class_then_id() {
        let mut rig = Rig::new();
        rig.poll(vec![
            sensor("z-fan", Class::Fan, 900.0),
            sensor("b", Class::Ssd, 40.0),
            sensor("a", Class::Ssd, 41.0),
            cpu(35.0),
            sensor("gpu", Class::Gpu, 50.0),
        ]);
        let ids: Vec<String> = rig.engine.list().into_iter().map(|s| s.id).collect();
        assert_eq!(ids, ["cpu", "gpu", "a", "b", "z-fan"]);
        let labels: Vec<&str> = rig.engine.list().iter().map(|s| s.label).collect();
        assert_eq!(labels, ["Processor", "Graphics", "Drive", "Drive", "Fan"]);
    }

    #[test]
    fn polling_is_fast_while_a_level_above_normal_holds() {
        let mut rig = Rig::new();
        assert_eq!(rig.engine.interval(), POLL);
        rig.hold(&[cpu(85.0)], 15);
        assert_eq!(rig.engine.interval(), POLL_FAST);
        rig.hold(&[cpu(40.0)], 5);
        assert_eq!(rig.engine.interval(), POLL);
    }

    // --- a stuck fan

    #[test]
    fn a_fan_that_stops_while_the_cpu_is_warm_counts_as_hot() {
        let mut rig = Rig::new();
        let fan = |rpm| sensor("fan", Class::Fan, rpm);
        rig.hold(&[cpu(50.0), fan(1800.0)], 10);
        // Warm for 10 s, then the fan stops.
        rig.hold(&[cpu(85.0), fan(0.0)], 10);
        assert_eq!(rig.level_of("cpu"), Level::Warm);
        assert_eq!(rig.level_of("fan"), Level::Normal, "not yet 30 s");
        rig.hold(&[cpu(85.0), fan(0.0)], 25);
        assert_eq!(rig.level_of("fan"), Level::Normal, "30 s are over only now");
        rig.now += secs(5);
        let update = rig.poll(vec![cpu(85.0), fan(0.0)]);
        assert_eq!(rig.level_of("fan"), Level::Hot);
        assert_eq!(
            update.level,
            Some(LevelChange {
                level: Level::Hot,
                sensor: "fan".to_owned()
            })
        );
        // The fan spins again: back to normal.
        rig.now += secs(5);
        rig.poll(vec![cpu(85.0), fan(1500.0)]);
        assert_eq!(rig.level_of("fan"), Level::Normal);
    }

    #[test]
    fn a_fan_that_is_stopped_while_the_cpu_is_cool_is_fine() {
        let mut rig = Rig::new();
        let fan = |rpm| sensor("fan", Class::Fan, rpm);
        rig.hold(&[cpu(40.0), fan(1800.0)], 10);
        rig.hold(&[cpu(40.0), fan(0.0)], 120);
        assert_eq!(rig.engine.level(), Level::Normal);
    }

    #[test]
    fn a_fan_that_never_turned_is_an_unused_header_not_a_fault() {
        let mut rig = Rig::new();
        rig.hold(&[cpu(85.0), sensor("fan", Class::Fan, 0.0)], 120);
        assert_eq!(rig.level_of("cpu"), Level::Warm);
        assert_eq!(rig.level_of("fan"), Level::Normal);
        assert_eq!(rig.engine.level(), Level::Warm);
    }

    #[test]
    fn the_fan_timer_restarts_when_the_cpu_cools_down() {
        let mut rig = Rig::new();
        let fan = |rpm| sensor("fan", Class::Fan, rpm);
        rig.hold(&[cpu(85.0), fan(1800.0)], 10);
        rig.hold(&[cpu(85.0), fan(0.0)], 25);
        rig.hold(&[cpu(40.0), fan(0.0)], 10);
        rig.hold(&[cpu(85.0), fan(0.0)], 25);
        assert_eq!(rig.level_of("fan"), Level::Normal);
    }

    // --- the configuration

    const OVERRIDE: &str = r#"
        hysteresis = 3
        [cpu]
        warm = 70
        [ssd]
        critical = 85
    "#;

    #[test]
    fn an_override_replaces_a_threshold_and_keeps_the_others() {
        let config = Config::default().with_file(OVERRIDE).unwrap();
        assert_eq!(config.cpu.warm, 70.0);
        assert_eq!(config.cpu.hot, 90.0);
        assert_eq!(config.ssd.critical, Some(85.0));
        assert_eq!(config.ssd.warm, 70.0);
        assert_eq!(config.hysteresis, 3.0);
        assert_eq!(config.gpu, Config::default().gpu);
        let mut rig = Rig::with(config);
        rig.hold(&[cpu(72.0)], 15);
        assert_eq!(
            rig.level_of("cpu"),
            Level::Warm,
            "70 is the warm threshold now"
        );
        // 3 degrees of hysteresis: 67 clears, 68 does not.
        rig.hold(&[cpu(68.0)], 5);
        assert_eq!(rig.level_of("cpu"), Level::Warm);
        rig.hold(&[cpu(67.0)], 5);
        assert_eq!(rig.level_of("cpu"), Level::Normal);
    }

    #[test]
    fn a_fixed_critical_for_the_cpu_wins_over_the_sensors_limit() {
        let config = Config::default().with_file("[cpu]\ncritical = 96").unwrap();
        let levels = config.levels(Class::Cpu, Some(100.0)).unwrap();
        assert_eq!(levels, [80.0, 90.0, 96.0]);
    }

    #[test]
    fn thresholds_may_be_written_as_integers_or_decimals() {
        let config = Config::default()
            .with_file("[hdd]\nwarm = 45\nhot = 52.5")
            .unwrap();
        assert_eq!((config.hdd.warm, config.hdd.hot), (45.0, 52.5));
    }

    #[test]
    fn a_file_with_a_mistake_is_refused_whole() {
        let base = Config::default();
        for bad in [
            "[cpu]\nwarm = 95",                  // above hot
            "[cpu]\nwarm = 90",                  // equal to hot
            "[ssd]\ncritical = 70",              // under hot
            "[cpu]\nwarmm = 70",                 // a typo
            "unknown = 1",                       // a key we do not know
            "[cpu]\nwarm = \"hot\"",             // not a number
            "hysteresis = -1",                   // negative
            "hysteresis = 50",                   // absurd
            "debounce_seconds = 100000",         // absurd
            "critical_fallback = 400",           // above the plausible range
            "[cpu]\nwarm = 70\n[gpu]\nhot = 70", // the first part is fine, the second not
            "this is not toml",
        ] {
            assert!(base.with_file(bad).is_err(), "accepted: {bad}");
        }
    }

    #[test]
    fn the_shipped_file_says_what_the_built_in_defaults_say() {
        let text = include_str!("../../../image/rootfs/usr/lib/ruyaos/thermal.toml");
        let shipped = Config::default().with_file(text).unwrap();
        assert_eq!(shipped, Config::default());
        // And the values really are in the file, not merely absent from it.
        let other = Config::default()
            .with_file("[cpu]\nwarm = 1\nhot = 2")
            .unwrap();
        assert_ne!(other, shipped);
        for needle in ["warm = 80", "hot = 90", "critical = 80", "critical = 60"] {
            assert!(text.contains(needle), "{needle}");
        }
    }

    #[test]
    fn load_layers_the_files_and_skips_a_bad_or_missing_one() {
        let dir = tempfile::tempdir().unwrap();
        let system = dir.path().join("system.toml");
        let local = dir.path().join("local.toml");
        let broken = dir.path().join("broken.toml");
        fs::write(&system, "[gpu]\nwarm = 75\nhot = 85").unwrap();
        fs::write(&local, "[gpu]\nhot = 88").unwrap();
        fs::write(&broken, "[cpu]\nwarm = 99").unwrap();
        let config = Config::load(&[
            system.clone(),
            dir.path().join("missing.toml"),
            broken,
            local,
        ]);
        assert_eq!((config.gpu.warm, config.gpu.hot), (75.0, 88.0));
        assert_eq!(
            config.cpu,
            Config::default().cpu,
            "the broken file did nothing"
        );
        assert_eq!(Config::load(&[dir.path().join("none")]), Config::default());
    }

    // --- /proc/stat

    #[test]
    fn cpu_jiffies_from_proc_stat() {
        let text = "cpu  100 0 50 800 40 5 5 0 0 0\ncpu0 1 2 3 4\n";
        // total = 100+0+50+800+40+5+5+0 = 1000; idle = 800 + 40.
        assert_eq!(parse_cpu_jiffies(text), Some((1000, 160)));
        assert_eq!(parse_cpu_jiffies("intr 1 2 3"), None);
        assert_eq!(parse_cpu_jiffies("cpu 1 2"), None);
        assert_eq!(parse_cpu_jiffies(""), None);
    }

    #[test]
    fn the_cpu_is_busy_when_half_of_the_time_since_the_last_reading_was_not_idle() {
        let dir = tempfile::tempdir().unwrap();
        let stat = dir.path().join("stat");
        let source = SysfsSource::new(dir.path(), &stat);
        assert!(!source.cpu_busy(), "no file");
        fs::write(&stat, "cpu  0 0 0 1000 0 0 0 0\n").unwrap();
        assert!(
            !source.cpu_busy(),
            "the first reading has nothing to compare with"
        );
        fs::write(&stat, "cpu  400 0 100 1100 0 0 0 0\n").unwrap();
        assert!(source.cpu_busy(), "500 of 600 jiffies busy");
        fs::write(&stat, "cpu  400 0 100 1500 0 0 0 0\n").unwrap();
        assert!(!source.cpu_busy(), "0 of 400 busy");
        fs::write(&stat, "cpu  600 0 100 1700 0 0 0 0\n").unwrap();
        assert!(source.cpu_busy(), "exactly half counts");
    }

    // --- discovery against a fake /sys

    fn put(root: &Path, file: &str, text: &str) {
        let path = root.join(file);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, format!("{text}\n")).unwrap();
    }

    /// The Dell test machine (Core i5-10500T): coretemp with the package and six cores, acpitz,
    /// pch_cometlake and dell_smm with a bogus 126 degree sensor and one fan; names, labels and
    /// values only.
    fn dell(root: &Path) {
        put(root, "class/hwmon/hwmon0/name", "acpitz");
        put(root, "class/hwmon/hwmon0/temp1_input", "27800");
        put(root, "class/hwmon/hwmon0/temp1_crit", "119000");
        put(root, "class/hwmon/hwmon1/name", "pch_cometlake");
        put(root, "class/hwmon/hwmon1/temp1_input", "31000");
        put(root, "class/hwmon/hwmon2/name", "coretemp");
        put(root, "class/hwmon/hwmon2/temp1_label", "Package id 0");
        put(root, "class/hwmon/hwmon2/temp1_input", "33000");
        put(root, "class/hwmon/hwmon2/temp1_max", "100000");
        put(root, "class/hwmon/hwmon2/temp1_crit", "100000");
        for core in 0..6 {
            let n = core + 2;
            put(
                root,
                &format!("class/hwmon/hwmon2/temp{n}_label"),
                &format!("Core {core}"),
            );
            put(
                root,
                &format!("class/hwmon/hwmon2/temp{n}_input"),
                &format!("{}", 30000 + core * 1000),
            );
            put(root, &format!("class/hwmon/hwmon2/temp{n}_max"), "100000");
            put(root, &format!("class/hwmon/hwmon2/temp{n}_crit"), "100000");
        }
        put(root, "class/hwmon/hwmon3/name", "dell_smm");
        for (n, milli) in [
            (1, 33000),
            (2, 31000),
            (3, 29000),
            (4, 30000),
            (5, 32000),
            (6, 28000),
            (7, 35000),
            (8, 126000),
        ] {
            put(
                root,
                &format!("class/hwmon/hwmon3/temp{n}_input"),
                &milli.to_string(),
            );
        }
        put(root, "class/hwmon/hwmon3/fan1_input", "1820");
        put(root, "class/hwmon/hwmon3/fan1_label", "Processor Fan");
        put(root, "class/thermal/thermal_zone0/type", "acpitz");
        put(root, "class/thermal/thermal_zone0/temp", "27800");
        put(
            root,
            "class/thermal/thermal_zone0/trip_point_0_type",
            "critical",
        );
        put(
            root,
            "class/thermal/thermal_zone0/trip_point_0_temp",
            "119000",
        );
        put(root, "class/thermal/thermal_zone1/type", "x86_pkg_temp");
        put(root, "class/thermal/thermal_zone1/temp", "33000");
        put(
            root,
            "class/thermal/thermal_zone1/trip_point_0_type",
            "passive",
        );
        put(
            root,
            "class/thermal/thermal_zone1/trip_point_0_temp",
            "98000",
        );
    }

    fn read_tree(root: &Path) -> Reading {
        SysfsSource::new(root, root.join("no-proc-stat"))
            .read()
            .unwrap()
    }

    #[test]
    fn the_dell_shows_the_package_and_the_fan_and_nothing_else() {
        let dir = tempfile::tempdir().unwrap();
        dell(dir.path());
        let reading = read_tree(dir.path());
        assert_eq!(
            reading.sensors,
            vec![
                RawSensor {
                    id: "coretemp:Package id 0:".to_owned(),
                    class: Class::Cpu,
                    value: 33.0,
                    crit: Some(100.0),
                },
                RawSensor {
                    id: "dell_smm:Processor Fan:".to_owned(),
                    class: Class::Fan,
                    value: 1820.0,
                    crit: None,
                },
            ],
            "the cores, acpitz, pch_cometlake, the other dell_smm temperatures (and so the bogus \
             126 degrees) and the thermal zones (a coretemp is there) are not listed"
        );
    }

    #[test]
    fn the_dell_is_normal_through_the_engine_with_its_critical_at_95() {
        let dir = tempfile::tempdir().unwrap();
        dell(dir.path());
        let mut rig = Rig::new();
        rig.hold(&read_tree(dir.path()).sensors, 20);
        assert_eq!(rig.engine.level(), Level::Normal);
        let list = rig.engine.list();
        assert_eq!(list.len(), 2);
        assert_eq!((list[0].label, list[0].value), ("Processor", 33.0));
        assert_eq!((list[1].label, list[1].value), ("Fan", 1820.0));
        let levels = Config::default().levels(Class::Cpu, Some(100.0)).unwrap();
        assert_eq!(levels, [80.0, 90.0, 95.0]);
    }

    #[test]
    fn a_hot_package_in_the_fixture_is_seen_after_the_debounce() {
        let dir = tempfile::tempdir().unwrap();
        dell(dir.path());
        put(dir.path(), "class/hwmon/hwmon2/temp1_input", "96000");
        let mut rig = Rig::new();
        rig.hold(&read_tree(dir.path()).sensors, 15);
        assert_eq!(rig.engine.level(), Level::Critical);
    }

    #[test]
    fn a_machine_without_sensors_is_an_empty_list() {
        let dir = tempfile::tempdir().unwrap();
        let reading = read_tree(dir.path());
        assert!(reading.sensors.is_empty());
        let mut rig = Rig::new();
        rig.poll(reading.sensors);
        assert!(rig.engine.list().is_empty());
        assert_eq!(rig.engine.level(), Level::Normal);
    }

    #[test]
    fn without_coretemp_the_thermal_zone_is_the_processor() {
        let dir = tempfile::tempdir().unwrap();
        dell(dir.path());
        fs::remove_dir_all(dir.path().join("class/hwmon/hwmon2")).unwrap();
        let reading = read_tree(dir.path());
        let cpu = reading
            .sensors
            .iter()
            .find(|s| s.class == Class::Cpu)
            .expect("the x86_pkg_temp zone");
        assert_eq!(cpu.id, "thermal:x86_pkg_temp");
        assert_eq!(cpu.value, 33.0);
        // No critical trip point: the last trip point is the limit.
        assert_eq!(cpu.crit, Some(98.0));
        // The acpitz zone is not the processor.
        assert_eq!(
            reading
                .sensors
                .iter()
                .filter(|s| s.class == Class::Cpu)
                .count(),
            1
        );
    }

    #[test]
    fn a_critical_trip_point_beats_the_last_one() {
        let dir = tempfile::tempdir().unwrap();
        put(
            dir.path(),
            "class/thermal/thermal_zone3/type",
            "x86_pkg_temp",
        );
        put(dir.path(), "class/thermal/thermal_zone3/temp", "40000");
        put(
            dir.path(),
            "class/thermal/thermal_zone3/trip_point_0_type",
            "critical",
        );
        put(
            dir.path(),
            "class/thermal/thermal_zone3/trip_point_0_temp",
            "105000",
        );
        put(
            dir.path(),
            "class/thermal/thermal_zone3/trip_point_1_type",
            "passive",
        );
        put(
            dir.path(),
            "class/thermal/thermal_zone3/trip_point_1_temp",
            "99000",
        );
        assert_eq!(read_tree(dir.path()).sensors[0].crit, Some(105.0));
    }

    #[test]
    fn the_other_classes_are_found_by_hwmon_name() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        put(root, "class/hwmon/hwmon0/name", "k10temp");
        put(root, "class/hwmon/hwmon0/temp1_label", "Tctl");
        put(root, "class/hwmon/hwmon0/temp1_input", "45000");
        put(root, "class/hwmon/hwmon0/temp3_label", "Tccd1");
        put(root, "class/hwmon/hwmon0/temp3_input", "44000");
        put(root, "class/hwmon/hwmon1/name", "amdgpu");
        put(root, "class/hwmon/hwmon1/temp1_label", "edge");
        put(root, "class/hwmon/hwmon1/temp1_input", "52000");
        put(root, "class/hwmon/hwmon1/temp1_crit", "100000");
        put(root, "class/hwmon/hwmon1/temp2_label", "junction");
        put(root, "class/hwmon/hwmon1/temp2_input", "60000");
        put(root, "class/hwmon/hwmon2/name", "nvme");
        put(root, "class/hwmon/hwmon2/temp1_label", "Composite");
        put(root, "class/hwmon/hwmon2/temp1_input", "41850");
        put(root, "class/hwmon/hwmon2/temp2_label", "Sensor 1");
        put(root, "class/hwmon/hwmon2/temp2_input", "47000");
        put(root, "class/hwmon/hwmon3/name", "drivetemp");
        put(root, "class/hwmon/hwmon3/temp1_input", "36000");
        // A sensor chip nobody monitors, with a fan of its own.
        put(root, "class/hwmon/hwmon4/name", "nct6798");
        put(root, "class/hwmon/hwmon4/temp1_input", "30000");
        put(root, "class/hwmon/hwmon4/fan2_input", "640");
        put(root, "class/hwmon/hwmon4/fan3_input", "0");
        // A directory without a name is skipped.
        put(root, "class/hwmon/hwmon5/temp1_input", "99000");
        let mut got: Vec<(String, Class, f64)> = read_tree(root)
            .sensors
            .into_iter()
            .map(|s| (s.id, s.class, s.value))
            .collect();
        got.sort_by(|a, b| a.0.cmp(&b.0));
        assert_eq!(
            got,
            vec![
                ("amdgpu:edge:".to_owned(), Class::Gpu, 52.0),
                ("drivetemp:temp1:".to_owned(), Class::Hdd, 36.0),
                ("k10temp:Tctl:".to_owned(), Class::Cpu, 45.0),
                ("nct6798:fan2:".to_owned(), Class::Fan, 640.0),
                ("nct6798:fan3:".to_owned(), Class::Fan, 0.0),
                ("nvme:Composite:".to_owned(), Class::Ssd, 41.85),
            ]
        );
    }

    #[test]
    fn a_sata_ssd_behind_drivetemp_gets_the_drive_thresholds_not_the_disk_ones() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        put(root, "class/hwmon/hwmon0/name", "drivetemp");
        put(root, "class/hwmon/hwmon0/temp1_input", "52000");
        put(
            root,
            "class/hwmon/hwmon0/device/block/sda/queue/rotational",
            "0",
        );
        put(root, "class/hwmon/hwmon1/name", "drivetemp");
        put(root, "class/hwmon/hwmon1/temp1_input", "52000");
        put(
            root,
            "class/hwmon/hwmon1/device/block/sdb/queue/rotational",
            "1",
        );
        let classes: Vec<Class> = read_tree(root).sensors.iter().map(|s| s.class).collect();
        assert_eq!(classes, [Class::Ssd, Class::Hdd]);
    }

    #[test]
    fn two_sensors_with_the_same_name_label_and_device_get_different_ids() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        for n in 0..2 {
            put(root, &format!("class/hwmon/hwmon{n}/name"), "nvme");
            put(
                root,
                &format!("class/hwmon/hwmon{n}/temp1_label"),
                "Composite",
            );
            put(
                root,
                &format!("class/hwmon/hwmon{n}/temp1_input"),
                &format!("{}", 40000 + n * 1000),
            );
        }
        let ids: Vec<String> = read_tree(root).sensors.into_iter().map(|s| s.id).collect();
        assert_eq!(ids, ["nvme:Composite:", "nvme:Composite:#2"]);
    }

    #[cfg(unix)]
    #[test]
    fn the_id_follows_the_device_not_the_hwmon_number() {
        let build = |root: &Path, number: u32, device: &str| {
            let dir = root.join(format!("class/hwmon/hwmon{number}"));
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("name"), "nvme\n").unwrap();
            fs::write(dir.join("temp1_label"), "Composite\n").unwrap();
            fs::write(dir.join("temp1_input"), "40000\n").unwrap();
            std::os::unix::fs::symlink(format!("../../{device}"), dir.join("device")).unwrap();
        };
        let first = tempfile::tempdir().unwrap();
        build(first.path(), 1, "nvme0");
        let second = tempfile::tempdir().unwrap();
        build(second.path(), 7, "nvme0");
        let a = read_tree(first.path()).sensors[0].id.clone();
        let b = read_tree(second.path()).sensors[0].id.clone();
        assert_eq!(a, "nvme:Composite:nvme0");
        assert_eq!(a, b, "hwmon1 became hwmon7: same sensor");
    }

    #[test]
    fn a_file_that_cannot_be_parsed_leaves_that_sensor_out() {
        let dir = tempfile::tempdir().unwrap();
        dell(dir.path());
        put(dir.path(), "class/hwmon/hwmon3/fan1_input", "not a number");
        let reading = read_tree(dir.path());
        assert_eq!(reading.sensors.len(), 1);
    }

    // --- the monitor

    #[test]
    fn the_monitor_reads_the_source_and_keeps_the_engines_answers() {
        let source = FakeSource::new(vec![cpu(40.0)]);
        let monitor = Monitor::new(source, Config::default());
        assert_eq!(monitor.level(), Level::Normal);
        assert!(monitor.poll_at(secs(0)).unwrap().sensors_changed);
        assert_eq!(monitor.list().len(), 1);
        monitor.source.set(vec![cpu(92.0)], false);
        monitor.poll_at(secs(5)).unwrap();
        let update = monitor.poll_at(secs(15)).unwrap();
        assert_eq!(update.level.map(|c| c.level), Some(Level::Hot));
        assert_eq!(monitor.level(), Level::Hot);
        assert_eq!(monitor.interval(), POLL_FAST);
    }

    #[test]
    fn a_source_that_fails_changes_nothing() {
        struct Broken;
        impl Source for Broken {
            fn read(&self) -> Result<Reading, String> {
                Err("no".to_owned())
            }
        }
        let monitor = Monitor::new(Broken, Config::default());
        assert!(monitor.poll_at(secs(0)).is_err());
        assert!(monitor.list().is_empty());
    }
}
