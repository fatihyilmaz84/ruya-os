//! The console's display (org.ruyaos.Devices1.Display, T-198): which outputs are connected and
//! which modes they offer (the kernel's DRM sysfs plus the EDID), the owner's choice of mode and
//! UI size, and the safe switch.
//!
//! The service cannot change the mode of the running shell: the shell is the compositor (Qt
//! eglfs on KMS). A choice is applied by writing the KMS config JSON that Qt reads at start
//! (`QT_QPA_EGLFS_KMS_CONFIG`) and restarting the shell. So that a TV which cannot show the mode
//! never leaves a black screen:
//!   1. `set_mode` writes a `display-pending.toml` marker (`starts = 0`) and the candidate's config;
//!   2. every compositor start runs `guard` first (`ruya-devices --display-guard`): the first start
//!      with a marker counts it (`starts = 1`), a second start with the marker still there means
//!      the shell never got to confirm, so the choice is dropped (the TV's preferred mode comes
//!      back) and a `display-fallback` note is left for the shell to tell the owner;
//!   3. `keep` stores the candidate and removes the marker; `revert` (the shell's 15 s countdown
//!      ran out, or Back) removes the marker and restores the stored choice.
//!
//! Pure over the files in the state directory and a `DrmSource`; tested on any host.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use serde::{Deserialize, Serialize};

use crate::edid::{self, Edid, Timing};

/// The shell's default is the TV's preferred mode, capped at 4K60 (spec 03 §2.4).
pub const CAP_WIDTH: u32 = 3840;
pub const CAP_HEIGHT: u32 = 2160;
pub const CAP_REFRESH_MHZ: u32 = 60_500;

/// The UI size choices in percent; 0 is "Auto" (the shell derives the size from the screen).
pub const UI_SCALES: [u32; 5] = [0, 100, 125, 150, 200];

const STORED: &str = "display.toml";
const PENDING: &str = "display-pending.toml";
const KMS: &str = "kms.json";
const FALLBACK: &str = "display-fallback";
const STARTS: &str = "display-starts";

/// The compositor unit's start limit (`StartLimitIntervalSec=` and `StartLimitBurst=` of
/// `ruya-compositor@.service`): more starts than the burst within the window and systemd gives up,
/// which is a black screen until the console is power-cycled. Every mode change and every revert is
/// a start of its own, so the guard records each start and the service refuses a change that would
/// not leave room (`REFUSE_MARGIN`: the change, its revert, and one to spare).
pub const START_WINDOW_SECS: u64 = 120;
pub const START_BURST: u32 = 10;
const REFUSE_MARGIN: u32 = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Mode {
    pub width: u32,
    pub height: u32,
    /// Frames per second times 1000; 0 when the display does not say.
    pub refresh_mhz: u32,
    pub preferred: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    /// The kernel's connector name ("HDMI-A-1"); also what Qt's KMS config calls the output.
    pub id: String,
    pub name: String,
    /// Physical size of the picture; 0 when unknown.
    pub width_mm: u32,
    pub height_mm: u32,
    /// In the kernel's order: the preferred mode first, then larger and faster ones first.
    pub modes: Vec<Mode>,
}

/// What `ListOutputs` reports: an output with the mode in use marked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutputView {
    pub output: Output,
    /// Index into `output.modes` of the mode in use (the stored choice, else the default).
    pub current: Option<usize>,
}

/// Where the outputs come from: the kernel's sysfs, or a fake.
pub trait DrmSource: Send + Sync {
    /// The connected outputs, in connector order.
    fn outputs(&self) -> Result<Vec<Output>, String>;
}

pub type DynDrm = Box<dyn DrmSource>;

impl DrmSource for DynDrm {
    fn outputs(&self) -> Result<Vec<Output>, String> {
        (**self).outputs()
    }
}

/// A fixed list (`--session` development, tests).
pub struct FakeDrm(pub Vec<Output>);

impl DrmSource for FakeDrm {
    fn outputs(&self) -> Result<Vec<Output>, String> {
        Ok(self.0.clone())
    }
}

/// `/sys/class/drm` (or a copy of it: `ruya-devices --display-list <dir>` reads a capture).
pub struct SysfsDrm {
    dir: PathBuf,
}

impl SysfsDrm {
    pub fn system() -> Self {
        SysfsDrm {
            dir: PathBuf::from("/sys/class/drm"),
        }
    }

    pub fn under(dir: impl Into<PathBuf>) -> Self {
        SysfsDrm { dir: dir.into() }
    }
}

/// "1920x1080" -> (1920, 1080); an interlaced mode ("1920x1080i") is not offered.
fn kernel_mode(line: &str) -> Option<(u32, u32)> {
    let (w, h) = line.trim().split_once('x')?;
    Some((w.parse().ok()?, h.parse().ok()?))
}

/// The modes of one connector: the kernel's `WxH` list (preferred first) with the refresh rates
/// the EDID announces for each size. The k-th line of a size gets the k-th fastest rate; a size
/// the EDID says nothing about stays once, with rate 0 (unknown); lines beyond the rates the EDID
/// knows are dropped; two rates that round to the same Hz are one mode (Qt's config cannot tell
/// them apart).
pub fn modes_from(kernel: &[(u32, u32)], edid: Option<&Edid>) -> Vec<Mode> {
    let announced: &[Timing] = edid.map_or(&[], |e| &e.timings);
    let first_size = kernel.first().copied();
    let mut sizes: Vec<((u32, u32), usize)> = Vec::new();
    for &size in kernel {
        match sizes.iter_mut().find(|(s, _)| *s == size) {
            Some((_, n)) => *n += 1,
            None => sizes.push((size, 1)),
        }
    }
    let mut out = Vec::new();
    for (size, lines) in sizes {
        let mut rates: Vec<u32> = announced
            .iter()
            .filter(|t| (t.width, t.height) == size)
            .map(|t| t.refresh_mhz)
            .collect();
        rates.sort_unstable_by(|a, b| b.cmp(a));
        // The first detailed timing is the display's preferred one: it leads its size.
        let preferred_rate = announced
            .first()
            .filter(|t| Some((t.width, t.height)) == first_size && (t.width, t.height) == size)
            .map(|t| t.refresh_mhz);
        if let Some(p) = preferred_rate {
            rates.retain(|&r| r != p);
            rates.insert(0, p);
        }
        let mut seen_hz: Vec<u32> = Vec::new();
        rates.retain(|&r| {
            let hz = (r + 500) / 1000;
            let fresh = !seen_hz.contains(&hz);
            seen_hz.push(hz);
            fresh
        });
        rates.truncate(lines);
        if rates.is_empty() {
            rates.push(0);
        }
        for rate in rates {
            out.push(Mode {
                width: size.0,
                height: size.1,
                refresh_mhz: rate,
                preferred: false,
            });
        }
    }
    if let Some(first) = out.first_mut() {
        first.preferred = true;
    }
    out
}

impl DrmSource for SysfsDrm {
    fn outputs(&self) -> Result<Vec<Output>, String> {
        let mut names: Vec<String> = fs::read_dir(&self.dir)
            .map_err(|e| format!("{}: {e}", self.dir.display()))?
            .filter_map(|e| e.ok()?.file_name().into_string().ok())
            .collect();
        names.sort();
        let mut outputs = Vec::new();
        for name in names {
            // "card0-HDMI-A-1": the card, then the connector's name.
            let Some((card, id)) = name.split_once('-') else {
                continue;
            };
            if !card.starts_with("card") || id.is_empty() {
                continue;
            }
            let dir = self.dir.join(&name);
            let connected = fs::read_to_string(dir.join("status"))
                .map(|s| s.trim() == "connected")
                .unwrap_or(false);
            if !connected {
                continue;
            }
            let kernel: Vec<(u32, u32)> = fs::read_to_string(dir.join("modes"))
                .unwrap_or_default()
                .lines()
                .filter_map(kernel_mode)
                .collect();
            let edid = fs::read(dir.join("edid"))
                .ok()
                .and_then(|bytes| edid::parse(&bytes));
            let modes = modes_from(&kernel, edid.as_ref());
            if modes.is_empty() {
                continue;
            }
            let (name, width_mm, height_mm) = match &edid {
                Some(e) => (
                    e.name.clone().unwrap_or_else(|| id.to_owned()),
                    e.width_mm,
                    e.height_mm,
                ),
                None => (id.to_owned(), 0, 0),
            };
            outputs.push(Output {
                id: id.to_owned(),
                name,
                width_mm,
                height_mm,
                modes,
            });
        }
        Ok(outputs)
    }
}

/// The mode the shell uses when the owner chose none: the preferred one, unless it is beyond 4K60,
/// then the first mode within the cap.
pub fn default_mode(output: &Output) -> Option<usize> {
    let within = |m: &Mode| {
        m.width <= CAP_WIDTH
            && m.height <= CAP_HEIGHT
            && (m.refresh_mhz == 0 || m.refresh_mhz <= CAP_REFRESH_MHZ)
    };
    let preferred = output.modes.iter().position(|m| m.preferred)?;
    if within(&output.modes[preferred]) {
        return Some(preferred);
    }
    // Too fast only (a 1440p240 monitor, a 1280x800 at 75 Hz): the same size at the highest rate
    // within the cap, never another size (the VM showed a 75 Hz preferred mode becoming 4K).
    let (pw, ph) = (
        output.modes[preferred].width,
        output.modes[preferred].height,
    );
    if pw <= CAP_WIDTH && ph <= CAP_HEIGHT {
        let slower = output
            .modes
            .iter()
            .enumerate()
            .filter(|(_, m)| m.width == pw && m.height == ph && within(m))
            .max_by_key(|(_, m)| m.refresh_mhz);
        if let Some((at, _)) = slower {
            return Some(at);
        }
    }
    output.modes.iter().position(within).or(Some(preferred))
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Choice {
    pub output: String,
    pub width: u32,
    pub height: u32,
    pub refresh_mhz: u32,
}

impl Choice {
    fn of(output: &Output, mode: &Mode) -> Choice {
        Choice {
            output: output.id.clone(),
            width: mode.width,
            height: mode.height,
            refresh_mhz: mode.refresh_mhz,
        }
    }

    fn index_in(&self, output: &Output) -> Option<usize> {
        output.modes.iter().position(|m| {
            (m.width, m.height, m.refresh_mhz) == (self.width, self.height, self.refresh_mhz)
        })
    }
}

#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Stored {
    #[serde(default)]
    ui_scale: u32,
    // A table: keep it last, TOML wants values before tables.
    #[serde(default)]
    mode: Option<Choice>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct PendingFile {
    starts: u32,
    candidate: Choice,
}

/// A change waiting for "Keep" (what `GetPending` reports).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pending {
    pub choice: Choice,
    /// How many times the compositor has started with it (0 until the shell comes back).
    pub starts: u32,
}

/// The Qt mode string: "1920x1080@60", or "1920x1080" when the rate is unknown.
fn mode_string(c: &Choice) -> String {
    if c.refresh_mhz == 0 {
        format!("{}x{}", c.width, c.height)
    } else {
        format!("{}x{}@{}", c.width, c.height, (c.refresh_mhz + 500) / 1000)
    }
}

/// What Qt's eglfs_kms calls the screen of a connector (`nameForConnector` in qkmsdevice.cpp): a
/// short type name and the connector's number, no dash. The kernel's "HDMI-A-1" is "HDMI1", "DP-2"
/// is "DP2", "eDP-1" is "eDP1", "Virtual-1" is "Virtual1"; the HDMI and DVI variants lose their
/// letter, "SVIDEO" is "TV", "Component" is "CTV" and "9PinDIN" is "DIN".
pub fn qt_output_name(kernel: &str) -> String {
    let (kind, number) = match kernel.rsplit_once('-') {
        Some((kind, n)) if !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()) => (kind, n),
        _ => (kernel, ""),
    };
    let short = match kind {
        "HDMI-A" | "HDMI-B" => "HDMI",
        "DVI-I" | "DVI-D" | "DVI-A" => "DVI",
        "SVIDEO" => "TV",
        "Component" => "CTV",
        "9PinDIN" => "DIN",
        other => other,
    };
    format!("{short}{number}")
}

/// The JSON `QT_QPA_EGLFS_KMS_CONFIG` points at (Qt's eglfs_kms, one entry per output). The entry
/// is named the way Qt names its screens (`qt_output_name`); the kernel's own name is written as a
/// second entry when it differs, which does no harm where Qt does not know it.
pub fn kms_config(choice: &Choice) -> String {
    let mode = mode_string(choice);
    let qt = qt_output_name(&choice.output);
    let mut outputs = vec![serde_json::json!({ "name": qt, "mode": mode })];
    if qt != choice.output {
        outputs.push(serde_json::json!({ "name": choice.output, "mode": mode }));
    }
    let doc = serde_json::json!({ "outputs": outputs });
    let mut text = serde_json::to_string_pretty(&doc).unwrap_or_default();
    text.push('\n');
    text
}

/// The contract's status strings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    Unchanged,
    UnknownOutput,
    UnknownMode,
    Busy,
    NoPending,
    Invalid,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::Unchanged => "unchanged",
            Status::UnknownOutput => "unknown-output",
            Status::UnknownMode => "unknown-mode",
            Status::Busy => "busy",
            Status::NoPending => "no-pending",
            Status::Invalid => "invalid",
            Status::Failed => "failed",
        }
    }
}

/// The state directory's files.
struct Files {
    dir: Option<PathBuf>,
}

fn write_atomic(path: &Path, text: &str) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".tmp");
    let tmp = path.with_file_name(name);
    fs::write(&tmp, text)?;
    fs::rename(&tmp, path)
}

fn remove(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

fn corrupt(e: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, e.to_string())
}

impl Files {
    fn path(&self, name: &str) -> Option<PathBuf> {
        self.dir.as_ref().map(|d| d.join(name))
    }

    /// Missing = default. Corrupt = error: a choice is never overwritten silently.
    fn stored(&self) -> io::Result<Stored> {
        let Some(path) = self.path(STORED) else {
            return Ok(Stored::default());
        };
        match fs::read_to_string(path) {
            Ok(text) => toml::from_str(&text).map_err(corrupt),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Stored::default()),
            Err(e) => Err(e),
        }
    }

    fn save_stored(&self, stored: &Stored) -> io::Result<()> {
        match self.path(STORED) {
            Some(path) => write_atomic(&path, &toml::to_string_pretty(stored).map_err(corrupt)?),
            None => Ok(()),
        }
    }

    fn pending(&self) -> io::Result<Option<PendingFile>> {
        let Some(path) = self.path(PENDING) else {
            return Ok(None);
        };
        match fs::read_to_string(path) {
            Ok(text) => toml::from_str(&text).map(Some).map_err(corrupt),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
        }
    }

    fn save_pending(&self, pending: &PendingFile) -> io::Result<()> {
        match self.path(PENDING) {
            Some(path) => write_atomic(&path, &toml::to_string_pretty(pending).map_err(corrupt)?),
            None => Ok(()),
        }
    }

    fn clear_pending(&self) -> io::Result<()> {
        self.path(PENDING).map_or(Ok(()), |p| remove(&p))
    }

    /// Writes the KMS config for `choice`, or removes it (the preferred mode is Qt's default).
    fn write_kms(&self, choice: Option<&Choice>) -> io::Result<()> {
        let Some(path) = self.path(KMS) else {
            return Ok(());
        };
        match choice {
            Some(c) => write_atomic(&path, &kms_config(c)),
            None => remove(&path),
        }
    }

    /// The unix times of the compositor starts within the window ending at `now`.
    fn recent_starts(&self, now: u64) -> Vec<u64> {
        let Some(path) = self.path(STARTS) else {
            return Vec::new();
        };
        fs::read_to_string(path)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| l.trim().parse::<u64>().ok())
            .filter(|&t| t + START_WINDOW_SECS > now && t <= now + START_WINDOW_SECS)
            .collect()
    }

    fn record_start(&self, now: u64) -> io::Result<()> {
        let Some(path) = self.path(STARTS) else {
            return Ok(());
        };
        let mut times = self.recent_starts(now);
        times.push(now);
        let text: String = times.iter().map(|t| format!("{t}\n")).collect();
        write_atomic(&path, &text)
    }

    fn note_fallback(&self) -> io::Result<()> {
        match self.path(FALLBACK) {
            Some(path) => write_atomic(
                &path,
                "the screen did not answer; the preferred mode is back\n",
            ),
            None => Ok(()),
        }
    }
}

/// The stored choice if the output is connected and still offers the mode.
fn valid_choice(stored: &Stored, outputs: &[Output]) -> Option<Choice> {
    let choice = stored.mode.as_ref()?;
    let output = outputs.iter().find(|o| o.id == choice.output)?;
    choice.index_in(output)?;
    Some(choice.clone())
}

/// What to write for the KMS config when nothing is pending: the valid stored choice; else, for
/// the first output, its default mode when that is not the preferred one (the 4K60 cap); else
/// nothing (Qt's own preferred mode).
fn config_choice(stored: &Stored, outputs: &[Output]) -> Option<Choice> {
    if let Some(c) = valid_choice(stored, outputs) {
        return Some(c);
    }
    let first = outputs.first()?;
    let at = default_mode(first)?;
    (!first.modes[at].preferred).then(|| Choice::of(first, &first.modes[at]))
}

/// What a compositor start finds out (`guard`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuardOutcome {
    /// Nothing was pending.
    Quiet,
    /// The first start with a pending change: the shell must now ask the owner.
    FirstStart,
    /// The change was never confirmed before this start: the choice is dropped.
    FellBack,
}

/// Runs before every compositor start (`ruya-devices --display-guard`, `ExecStartPre=` of the
/// compositor unit) as the user the shell runs as. Counts the starts of a pending change, drops a
/// change that was never confirmed, forgets a stored mode the screen no longer offers, and writes
/// the config for the default (capped) mode. Never fails the start: the caller ignores errors.
pub fn guard(dir: &Path, drm: &dyn DrmSource) -> io::Result<GuardOutcome> {
    guard_at(dir, drm, unix_now())
}

fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// `guard` with the time given (tests).
pub fn guard_at(dir: &Path, drm: &dyn DrmSource, now: u64) -> io::Result<GuardOutcome> {
    fs::create_dir_all(dir)?;
    let files = Files {
        dir: Some(dir.to_owned()),
    };
    // Every start counts towards the unit's start limit, whatever follows.
    if let Err(err) = files.record_start(now) {
        eprintln!("ruya-devices: recording the start failed: {err}");
    }
    let pending = match files.pending() {
        Ok(p) => p,
        // An unreadable marker is a change that cannot be trusted.
        Err(_) => Some(PendingFile {
            starts: u32::MAX,
            candidate: Choice {
                output: String::new(),
                width: 0,
                height: 0,
                refresh_mhz: 0,
            },
        }),
    };
    if let Some(mut pending) = pending {
        if pending.starts == 0 {
            pending.starts = 1;
            files.save_pending(&pending)?;
            return Ok(GuardOutcome::FirstStart);
        }
        // A corrupt choice file is not touched (the service reports it); the start goes on.
        if let Ok(mut stored) = files.stored() {
            stored.mode = None;
            files.save_stored(&stored)?;
        }
        files.clear_pending()?;
        files.note_fallback()?;
        write_default_config(&files, &Stored::default(), drm);
        return Ok(GuardOutcome::FellBack);
    }
    // A corrupt choice is left for the service to report; the start goes on with the default.
    let mut stored = files.stored().unwrap_or_default();
    if let Ok(outputs) = drm.outputs() {
        if stored.mode.is_some() && !outputs.is_empty() && valid_choice(&stored, &outputs).is_none()
        {
            stored.mode = None;
            files.save_stored(&stored)?;
        }
    }
    write_default_config(&files, &stored, drm);
    Ok(GuardOutcome::Quiet)
}

/// Sets the config for the stored choice or the default. With no output to look at it stays as it is.
fn write_default_config(files: &Files, stored: &Stored, drm: &dyn DrmSource) {
    match drm.outputs() {
        Ok(outputs) if !outputs.is_empty() => {
            if let Err(err) = files.write_kms(config_choice(stored, &outputs).as_ref()) {
                eprintln!("ruya-devices: writing the KMS config failed: {err}");
            }
        }
        _ => {}
    }
}

pub struct Display<D: DrmSource> {
    drm: D,
    files: Files,
    lock: Mutex<()>,
    /// Unix seconds now; a field so that tests can move time.
    clock: Box<dyn Fn() -> u64 + Send + Sync>,
}

impl<D: DrmSource> Display<D> {
    /// `dir` is the state directory; `None` keeps nothing (tests that don't need files).
    pub fn new(drm: D, dir: Option<PathBuf>) -> Self {
        Self::with_clock(drm, dir, Box::new(unix_now))
    }

    pub fn with_clock(
        drm: D,
        dir: Option<PathBuf>,
        clock: Box<dyn Fn() -> u64 + Send + Sync>,
    ) -> Self {
        Display {
            drm,
            files: Files { dir },
            lock: Mutex::new(()),
            clock,
        }
    }

    /// True when another compositor start now (and the one to put it back) could trip the unit's
    /// start limit.
    fn restarts_crowded(&self) -> bool {
        let recent = self.files.recent_starts((self.clock)()).len() as u32;
        recent + REFUSE_MARGIN > START_BURST
    }

    fn lock(&self) -> MutexGuard<'_, ()> {
        // A poisoned lock only means another call panicked; the guarded state is on disk.
        self.lock.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The connected outputs with the mode in use marked.
    pub fn list(&self) -> Result<Vec<OutputView>, String> {
        let _guard = self.lock();
        let outputs = self.drm.outputs()?;
        let stored = self.files.stored().map_err(|e| e.to_string())?;
        let valid = valid_choice(&stored, &outputs);
        Ok(outputs
            .into_iter()
            .map(|output| {
                let current = match &valid {
                    Some(c) if c.output == output.id => c.index_in(&output),
                    _ => default_mode(&output),
                };
                OutputView { output, current }
            })
            .collect())
    }

    pub fn set_mode(&self, output: &str, width: u32, height: u32, refresh_mhz: u32) -> Status {
        let views = match self.list() {
            Ok(v) => v,
            Err(err) => {
                eprintln!("ruya-devices: reading the outputs failed: {err}");
                return Status::Failed;
            }
        };
        let _guard = self.lock();
        let Some(view) = views.iter().find(|v| v.output.id == output) else {
            return Status::UnknownOutput;
        };
        let candidate = Choice {
            output: output.to_owned(),
            width,
            height,
            refresh_mhz,
        };
        let Some(at) = candidate.index_in(&view.output) else {
            return Status::UnknownMode;
        };
        match self.files.pending() {
            Ok(None) => {}
            Ok(Some(_)) => return Status::Busy,
            Err(_) => return Status::Failed,
        }
        if view.current == Some(at) {
            return Status::Unchanged;
        }
        // A deliberate restart must never be the one that trips the start limit.
        if self.restarts_crowded() {
            return Status::Busy;
        }
        // The marker first: a config without it could never be taken back.
        let marker = PendingFile {
            starts: 0,
            candidate: candidate.clone(),
        };
        if self.files.save_pending(&marker).is_err() {
            return Status::Failed;
        }
        if let Err(err) = self.files.write_kms(Some(&candidate)) {
            eprintln!("ruya-devices: writing the KMS config failed: {err}");
            let _ = self.files.clear_pending();
            return Status::Failed;
        }
        Status::Ok
    }

    pub fn pending(&self) -> Option<Pending> {
        let _guard = self.lock();
        self.files.pending().ok().flatten().map(|p| Pending {
            choice: p.candidate,
            starts: p.starts,
        })
    }

    /// The owner confirmed the new mode: it becomes the stored choice.
    pub fn keep(&self) -> Status {
        let _guard = self.lock();
        let pending = match self.files.pending() {
            Ok(Some(p)) => p,
            Ok(None) => return Status::NoPending,
            Err(_) => return Status::Failed,
        };
        let mut stored = self.files.stored().unwrap_or_default();
        stored.mode = Some(pending.candidate);
        if self.files.save_stored(&stored).is_err() || self.files.clear_pending().is_err() {
            return Status::Failed;
        }
        Status::Ok
    }

    /// Back to what was stored before the change (or the default); the shell restarts after it.
    pub fn revert(&self) -> Status {
        let _guard = self.lock();
        match self.files.pending() {
            Ok(Some(_)) => {}
            Ok(None) => return Status::NoPending,
            Err(_) => {}
        }
        let stored = self.files.stored().unwrap_or_default();
        if self.files.clear_pending().is_err() {
            return Status::Failed;
        }
        let outputs = self.drm.outputs().unwrap_or_default();
        if let Err(err) = self
            .files
            .write_kms(config_choice(&stored, &outputs).as_ref())
        {
            eprintln!("ruya-devices: writing the KMS config failed: {err}");
            return Status::Failed;
        }
        Status::Ok
    }

    /// Back to the defaults: no stored mode (the preferred one, capped at 4K60) and UI size Auto.
    /// Works on a corrupt choice file too (it is replaced). Returns the status and whether the UI
    /// size changed. "ok": the mode will change at the next compositor start, so the shell restarts;
    /// "unchanged": only the stored values were reset; "busy": a change is pending, or restarting
    /// now could trip the start limit.
    pub fn reset(&self) -> (Status, bool) {
        let _guard = self.lock();
        match self.files.pending() {
            Ok(None) => {}
            _ => return (Status::Busy, false),
        }
        let stored = self.files.stored().unwrap_or_default();
        let outputs = self.drm.outputs().unwrap_or_default();
        let default = config_choice(&Stored::default(), &outputs);
        let changes_mode = match valid_choice(&stored, &outputs) {
            Some(c) => !self.is_default_choice(&c, &outputs),
            None => false,
        };
        if changes_mode && self.restarts_crowded() {
            return (Status::Busy, false);
        }
        let ui_changed = stored.ui_scale != 0;
        if self.files.save_stored(&Stored::default()).is_err() {
            return (Status::Failed, false);
        }
        if !outputs.is_empty() {
            if let Err(err) = self.files.write_kms(default.as_ref()) {
                eprintln!("ruya-devices: writing the KMS config failed: {err}");
                return (Status::Failed, ui_changed);
            }
        }
        (
            if changes_mode {
                Status::Ok
            } else {
                Status::Unchanged
            },
            ui_changed,
        )
    }

    /// Whether `choice` is the mode the default would use for its output.
    fn is_default_choice(&self, choice: &Choice, outputs: &[Output]) -> bool {
        outputs
            .iter()
            .find(|o| o.id == choice.output)
            .and_then(|o| default_mode(o).map(|at| Choice::of(o, &o.modes[at])))
            .as_ref()
            == Some(choice)
    }

    pub fn ui_scale(&self) -> u32 {
        let _guard = self.lock();
        self.files.stored().map(|s| s.ui_scale).unwrap_or(0)
    }

    /// `percent` must be one of `UI_SCALES`. Returns the status and whether the value changed.
    pub fn set_ui_scale(&self, percent: u32) -> (Status, bool) {
        let _guard = self.lock();
        if !UI_SCALES.contains(&percent) {
            return (Status::Invalid, false);
        }
        let mut stored = match self.files.stored() {
            Ok(s) => s,
            Err(_) => return (Status::Failed, false),
        };
        if stored.ui_scale == percent {
            return (Status::Ok, false);
        }
        stored.ui_scale = percent;
        match self.files.save_stored(&stored) {
            Ok(()) => (Status::Ok, true),
            Err(_) => (Status::Failed, false),
        }
    }

    /// True once after the guard dropped a choice that was never confirmed.
    pub fn take_fallback(&self) -> bool {
        let _guard = self.lock();
        let Some(path) = self.files.path(FALLBACK) else {
            return false;
        };
        let existed = path.exists();
        let _ = remove(&path);
        existed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::edid::testing::*;

    fn mode(width: u32, height: u32, refresh_mhz: u32, preferred: bool) -> Mode {
        Mode {
            width,
            height,
            refresh_mhz,
            preferred,
        }
    }

    fn tv() -> Output {
        Output {
            id: "HDMI-A-1".to_owned(),
            name: "Living room TV".to_owned(),
            width_mm: 1220,
            height_mm: 690,
            modes: vec![
                mode(3840, 2160, 60_000, true),
                mode(3840, 2160, 30_000, false),
                mode(1920, 1080, 60_000, false),
                mode(1280, 720, 60_000, false),
            ],
        }
    }

    fn choice(width: u32, height: u32, refresh_mhz: u32) -> Choice {
        Choice {
            output: "HDMI-A-1".to_owned(),
            width,
            height,
            refresh_mhz,
        }
    }

    fn service(dir: &Path) -> Display<FakeDrm> {
        Display::new(FakeDrm(vec![tv()]), Some(dir.to_owned()))
    }

    // --- the sysfs layout and the EDID ---

    /// A `/sys/class/drm` tree: `card0-HDMI-A-1` connected with an EDID, `card0-DP-1` not.
    fn sysfs_tree(root: &Path, modes: &str, edid_bytes: Option<&[u8]>) {
        let hdmi = root.join("card0-HDMI-A-1");
        fs::create_dir_all(&hdmi).unwrap();
        fs::write(hdmi.join("status"), "connected\n").unwrap();
        fs::write(hdmi.join("modes"), modes).unwrap();
        if let Some(bytes) = edid_bytes {
            fs::write(hdmi.join("edid"), bytes).unwrap();
        }
        let dp = root.join("card0-DP-1");
        fs::create_dir_all(&dp).unwrap();
        fs::write(dp.join("status"), "disconnected\n").unwrap();
        fs::write(dp.join("modes"), "").unwrap();
        // Not connectors at all.
        fs::create_dir_all(root.join("card0")).unwrap();
        fs::write(root.join("version"), "drm 1.1.0\n").unwrap();
    }

    fn tv_edid() -> Vec<u8> {
        let mut bytes = crate::edid::testing::base(
            (122, 69),
            &[dtd_2160p60((1220, 690)), name_descriptor("Ruya TV")],
            &[],
            1,
        );
        bytes.extend(cta(
            &[0x80 | 97, 95, 16, 32, 31, 4],
            &[dtd(297_000, (3840, 560), (2160, 90), (0, 0), false)],
        ));
        bytes
    }

    #[test]
    fn sysfs_gives_connected_outputs_with_modes_name_and_size() {
        let dir = tempfile::tempdir().unwrap();
        sysfs_tree(
            dir.path(),
            "3840x2160\n3840x2160\n1920x1080i\n1920x1080\n1920x1080\n1920x1080\n1280x720\n",
            Some(&tv_edid()),
        );
        let outputs = SysfsDrm::under(dir.path()).outputs().unwrap();
        assert_eq!(
            outputs.len(),
            1,
            "the disconnected DP-1 and the non-connectors are skipped"
        );
        let out = &outputs[0];
        assert_eq!(out.id, "HDMI-A-1");
        assert_eq!(out.name, "Ruya TV");
        assert_eq!((out.width_mm, out.height_mm), (1220, 690));
        let list: Vec<(u32, u32, u32, bool)> = out
            .modes
            .iter()
            .map(|m| (m.width, m.height, m.refresh_mhz, m.preferred))
            .collect();
        assert_eq!(
            list,
            vec![
                // 4K: two kernel lines, the EDID has 60 and 30 Hz; the preferred one leads.
                (3840, 2160, 60_000, true),
                (3840, 2160, 30_000, false),
                // 1080p: the interlaced line is dropped; three lines but only 60, 50 and 24 Hz announced.
                (1920, 1080, 60_000, false),
                (1920, 1080, 50_000, false),
                (1920, 1080, 24_000, false),
                // 720p: one line, one rate.
                (1280, 720, 60_000, false),
            ]
        );
    }

    #[test]
    fn a_size_the_edid_does_not_know_stays_once_with_an_unknown_rate() {
        let kernel = [(1024, 768), (1024, 768), (800, 600)];
        let modes = modes_from(&kernel, None);
        assert_eq!(
            modes,
            vec![mode(1024, 768, 0, true), mode(800, 600, 0, false)]
        );
    }

    #[test]
    fn rates_that_round_to_the_same_hz_are_one_mode() {
        let edid = Edid {
            timings: vec![
                Timing {
                    width: 1920,
                    height: 1080,
                    refresh_mhz: 59_940,
                },
                Timing {
                    width: 1920,
                    height: 1080,
                    refresh_mhz: 60_000,
                },
            ],
            ..Edid::default()
        };
        let modes = modes_from(&[(1920, 1080), (1920, 1080)], Some(&edid));
        // The display's own preferred timing (the first one) leads, the other rounds to the same 60 Hz.
        assert_eq!(modes, vec![mode(1920, 1080, 59_940, true)]);
    }

    #[test]
    fn no_edid_and_no_modes_file_is_still_an_output_only_with_modes() {
        let dir = tempfile::tempdir().unwrap();
        sysfs_tree(dir.path(), "", None);
        assert!(SysfsDrm::under(dir.path()).outputs().unwrap().is_empty());
        sysfs_tree(dir.path(), "1920x1080\n", None);
        let outputs = SysfsDrm::under(dir.path()).outputs().unwrap();
        assert_eq!(outputs[0].name, "HDMI-A-1");
        assert_eq!((outputs[0].width_mm, outputs[0].height_mm), (0, 0));
    }

    #[test]
    fn a_directory_that_is_not_there_is_an_error_not_an_empty_list() {
        let dir = tempfile::tempdir().unwrap();
        assert!(SysfsDrm::under(dir.path().join("nope")).outputs().is_err());
    }

    // --- the default and the config JSON ---

    #[test]
    fn the_default_is_the_preferred_mode_capped_at_4k60() {
        let mut out = tv();
        assert_eq!(default_mode(&out), Some(0));
        // A preferred 4K120: the first mode within 4K60 is the default.
        out.modes = vec![
            mode(3840, 2160, 120_000, true),
            mode(3840, 2160, 60_000, false),
            mode(1920, 1080, 60_000, false),
        ];
        assert_eq!(default_mode(&out), Some(1));
        // Too fast only: the same size at the highest rate within the cap, not another size.
        out.modes = vec![
            mode(2560, 1440, 240_000, true),
            mode(3840, 2160, 60_000, false),
            mode(2560, 1440, 144_000, false),
            mode(2560, 1440, 60_000, false),
        ];
        assert_eq!(default_mode(&out), Some(3));
        // A preferred mode beyond the cap in size, at a low rate: still skipped.
        out.modes = vec![
            mode(7680, 4320, 30_000, true),
            mode(3840, 2160, 30_000, false),
        ];
        assert_eq!(default_mode(&out), Some(1));
        // Too tall only (16:10): skipped as well.
        out.modes = vec![
            mode(3840, 2400, 60_000, true),
            mode(3840, 2160, 60_000, false),
        ];
        assert_eq!(default_mode(&out), Some(1));
        // Only modes beyond the cap: the preferred stays.
        out.modes = vec![
            mode(7680, 4320, 60_000, true),
            mode(5120, 2880, 60_000, false),
        ];
        assert_eq!(default_mode(&out), Some(0));
        out.modes.clear();
        assert_eq!(default_mode(&out), None);
    }

    #[test]
    fn qt_names_its_screens_without_the_dash() {
        for (kernel, qt) in [
            ("HDMI-A-1", "HDMI1"),
            ("HDMI-A-2", "HDMI2"),
            ("HDMI-B-1", "HDMI1"),
            ("DP-1", "DP1"),
            ("eDP-1", "eDP1"),
            ("VGA-1", "VGA1"),
            ("DVI-I-1", "DVI1"),
            ("DVI-D-2", "DVI2"),
            ("DVI-A-1", "DVI1"),
            ("Virtual-1", "Virtual1"),
            ("LVDS-1", "LVDS1"),
            ("SVIDEO-1", "TV1"),
            ("Component-1", "CTV1"),
            ("9PinDIN-1", "DIN1"),
            ("DSI-1", "DSI1"),
            ("Composite-1", "Composite1"),
            ("HDMI-A-12", "HDMI12"),
            // Not in the kernel's form: left as it is.
            ("weird", "weird"),
        ] {
            assert_eq!(qt_output_name(kernel), qt, "{kernel}");
        }
    }

    #[test]
    fn the_kms_config_matches_the_golden_file() {
        let golden = include_str!("../tests/fixtures/kms-hdmi-1080p60.json");
        assert_eq!(kms_config(&choice(1920, 1080, 60_000)), golden);
        // An unknown rate gives the bare size; 59.94 Hz rounds to 60.
        assert!(kms_config(&choice(1024, 768, 0)).contains("\"1024x768\""));
        // A name that is the same in both forms is written once.
        let mut dp = choice(1920, 1080, 60_000);
        dp.output = "weird".to_owned();
        assert_eq!(kms_config(&dp).matches("\"name\"").count(), 1);
        assert!(kms_config(&choice(1920, 1080, 59_940)).contains("\"1920x1080@60\""));
    }

    // --- choices, the pending change, keep and revert ---

    #[test]
    fn list_marks_the_default_mode_current() {
        let dir = tempfile::tempdir().unwrap();
        let views = service(dir.path()).list().unwrap();
        assert_eq!(views[0].current, Some(0));
    }

    #[test]
    fn set_mode_writes_the_marker_and_the_config_and_keep_stores_it() {
        let dir = tempfile::tempdir().unwrap();
        let d = service(dir.path());
        assert_eq!(d.set_mode("HDMI-A-1", 1920, 1080, 60_000), Status::Ok);
        let pending = d.pending().unwrap();
        assert_eq!(pending.choice, choice(1920, 1080, 60_000));
        assert_eq!(pending.starts, 0);
        assert_eq!(
            fs::read_to_string(dir.path().join(KMS)).unwrap(),
            kms_config(&choice(1920, 1080, 60_000))
        );
        // Nothing is stored before the owner confirms.
        assert_eq!(d.list().unwrap()[0].current, Some(0));
        assert_eq!(d.keep(), Status::Ok);
        assert!(d.pending().is_none());
        assert_eq!(d.list().unwrap()[0].current, Some(2));
        // A new Display over the same directory (a restart of the service) sees the choice.
        assert_eq!(service(dir.path()).list().unwrap()[0].current, Some(2));
        assert_eq!(d.keep(), Status::NoPending);
    }

    #[test]
    fn revert_restores_the_stored_choice_or_the_default() {
        let dir = tempfile::tempdir().unwrap();
        let d = service(dir.path());
        // First change kept: 1080p.
        assert_eq!(d.set_mode("HDMI-A-1", 1920, 1080, 60_000), Status::Ok);
        assert_eq!(d.keep(), Status::Ok);
        // Second change reverted: the config is 1080p again.
        assert_eq!(d.set_mode("HDMI-A-1", 1280, 720, 60_000), Status::Ok);
        assert_eq!(d.revert(), Status::Ok);
        assert!(d.pending().is_none());
        assert_eq!(
            fs::read_to_string(dir.path().join(KMS)).unwrap(),
            kms_config(&choice(1920, 1080, 60_000))
        );
        assert_eq!(d.list().unwrap()[0].current, Some(2));
        assert_eq!(d.revert(), Status::NoPending);
        // With nothing stored, reverting removes the config: Qt's preferred mode.
        let other = tempfile::tempdir().unwrap();
        let d = service(other.path());
        assert_eq!(d.set_mode("HDMI-A-1", 1280, 720, 60_000), Status::Ok);
        assert!(other.path().join(KMS).exists());
        assert_eq!(d.revert(), Status::Ok);
        assert!(!other.path().join(KMS).exists());
    }

    #[test]
    fn set_mode_refuses_what_it_cannot_apply() {
        let dir = tempfile::tempdir().unwrap();
        let d = service(dir.path());
        assert_eq!(
            d.set_mode("DP-9", 1920, 1080, 60_000),
            Status::UnknownOutput
        );
        assert_eq!(
            d.set_mode("HDMI-A-1", 1920, 1080, 61_000),
            Status::UnknownMode
        );
        assert_eq!(
            d.set_mode("HDMI-A-1", 640, 480, 60_000),
            Status::UnknownMode
        );
        // The mode in use is "unchanged": no marker, no restart.
        assert_eq!(
            d.set_mode("HDMI-A-1", 3840, 2160, 60_000),
            Status::Unchanged
        );
        assert!(d.pending().is_none());
        assert!(!dir.path().join(KMS).exists());
        // One change at a time.
        assert_eq!(d.set_mode("HDMI-A-1", 1920, 1080, 60_000), Status::Ok);
        assert_eq!(d.set_mode("HDMI-A-1", 1280, 720, 60_000), Status::Busy);
        assert_eq!(d.pending().unwrap().choice, choice(1920, 1080, 60_000));
    }

    #[test]
    fn ui_scale_accepts_only_the_listed_values_and_is_stored() {
        let dir = tempfile::tempdir().unwrap();
        let d = service(dir.path());
        assert_eq!(d.ui_scale(), 0);
        assert_eq!(d.set_ui_scale(130), (Status::Invalid, false));
        assert_eq!(d.set_ui_scale(150), (Status::Ok, true));
        assert_eq!(d.set_ui_scale(150), (Status::Ok, false));
        assert_eq!(service(dir.path()).ui_scale(), 150);
        // The scale and the mode live in one file and do not disturb each other.
        assert_eq!(d.set_mode("HDMI-A-1", 1920, 1080, 60_000), Status::Ok);
        assert_eq!(d.keep(), Status::Ok);
        assert_eq!(d.ui_scale(), 150);
    }

    #[test]
    fn a_corrupt_choice_is_an_error_and_is_not_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(STORED), "mode = 7").unwrap();
        let d = service(dir.path());
        assert!(d.list().is_err());
        assert_eq!(d.set_ui_scale(100), (Status::Failed, false));
        assert_eq!(
            fs::read_to_string(dir.path().join(STORED)).unwrap(),
            "mode = 7"
        );
    }

    // --- the guard at every compositor start ---

    #[test]
    fn the_first_start_with_a_pending_change_counts_it_and_the_second_falls_back() {
        let dir = tempfile::tempdir().unwrap();
        let drm = FakeDrm(vec![tv()]);
        let d = service(dir.path());
        assert_eq!(d.set_mode("HDMI-A-1", 1920, 1080, 60_000), Status::Ok);
        assert_eq!(d.keep(), Status::Ok);
        assert_eq!(d.set_mode("HDMI-A-1", 1280, 720, 60_000), Status::Ok);

        assert_eq!(guard(dir.path(), &drm).unwrap(), GuardOutcome::FirstStart);
        assert_eq!(d.pending().unwrap().starts, 1);
        // The candidate's config is untouched while it is on trial.
        assert_eq!(
            fs::read_to_string(dir.path().join(KMS)).unwrap(),
            kms_config(&choice(1280, 720, 60_000))
        );

        // The shell never confirmed (it crashed, or the screen stayed black and the console was
        // power-cycled): the next start drops the choice and goes to the preferred mode.
        assert_eq!(guard(dir.path(), &drm).unwrap(), GuardOutcome::FellBack);
        assert!(d.pending().is_none());
        assert!(!dir.path().join(KMS).exists(), "preferred mode: no config");
        assert_eq!(d.list().unwrap()[0].current, Some(0));
        assert!(d.take_fallback());
        assert!(!d.take_fallback(), "the note is for one telling");
        assert_eq!(guard(dir.path(), &drm).unwrap(), GuardOutcome::Quiet);
    }

    #[test]
    fn a_confirmed_change_survives_the_next_starts() {
        let dir = tempfile::tempdir().unwrap();
        let drm = FakeDrm(vec![tv()]);
        let d = service(dir.path());
        assert_eq!(d.set_mode("HDMI-A-1", 1920, 1080, 60_000), Status::Ok);
        assert_eq!(guard(dir.path(), &drm).unwrap(), GuardOutcome::FirstStart);
        assert_eq!(d.keep(), Status::Ok);
        assert_eq!(guard(dir.path(), &drm).unwrap(), GuardOutcome::Quiet);
        assert_eq!(guard(dir.path(), &drm).unwrap(), GuardOutcome::Quiet);
        assert_eq!(
            fs::read_to_string(dir.path().join(KMS)).unwrap(),
            kms_config(&choice(1920, 1080, 60_000))
        );
        assert!(!d.take_fallback());
    }

    #[test]
    fn an_unreadable_marker_falls_back_at_once() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(PENDING), "starts = [").unwrap();
        fs::write(dir.path().join(KMS), "{}").unwrap();
        let drm = FakeDrm(vec![tv()]);
        assert_eq!(guard(dir.path(), &drm).unwrap(), GuardOutcome::FellBack);
        assert!(!dir.path().join(PENDING).exists());
        assert!(!dir.path().join(KMS).exists());
    }

    #[test]
    fn a_stored_mode_the_screen_no_longer_offers_is_forgotten() {
        let dir = tempfile::tempdir().unwrap();
        // A previous TV took 1024x768; this one does not offer it.
        fs::write(
            dir.path().join(STORED),
            "ui_scale = 125\n\n[mode]\noutput = \"HDMI-A-1\"\nwidth = 1024\nheight = 768\nrefresh_mhz = 60000\n",
        )
        .unwrap();
        fs::write(dir.path().join(KMS), kms_config(&choice(1024, 768, 60_000))).unwrap();
        let drm = FakeDrm(vec![tv()]);
        assert_eq!(guard(dir.path(), &drm).unwrap(), GuardOutcome::Quiet);
        assert!(!dir.path().join(KMS).exists());
        let d = service(dir.path());
        assert_eq!(d.list().unwrap()[0].current, Some(0));
        assert_eq!(d.ui_scale(), 125, "the UI size stays");
    }

    #[test]
    fn the_guard_writes_the_capped_default_when_the_preferred_mode_is_beyond_4k60() {
        let dir = tempfile::tempdir().unwrap();
        let mut out = tv();
        out.modes = vec![
            mode(3840, 2160, 120_000, true),
            mode(3840, 2160, 60_000, false),
            mode(1920, 1080, 60_000, false),
        ];
        let drm = FakeDrm(vec![out]);
        assert_eq!(guard(dir.path(), &drm).unwrap(), GuardOutcome::Quiet);
        assert_eq!(
            fs::read_to_string(dir.path().join(KMS)).unwrap(),
            kms_config(&choice(3840, 2160, 60_000))
        );
    }

    // --- the compositor unit's start limit ---

    fn service_at(dir: &Path, now: u64) -> Display<FakeDrm> {
        Display::with_clock(
            FakeDrm(vec![tv()]),
            Some(dir.to_owned()),
            Box::new(move || now),
        )
    }

    /// `n` compositor starts, one a second from `from`, recorded as the guard records them.
    fn starts(dir: &Path, from: u64, n: u64) {
        let files = Files {
            dir: Some(dir.to_owned()),
        };
        for t in from..from + n {
            files.record_start(t).unwrap();
        }
    }

    #[test]
    fn the_guard_records_every_start_and_forgets_old_ones() {
        let dir = tempfile::tempdir().unwrap();
        let drm = FakeDrm(vec![tv()]);
        for t in 1000..1003 {
            guard_at(dir.path(), &drm, t).unwrap();
        }
        let files = Files {
            dir: Some(dir.path().to_owned()),
        };
        assert_eq!(files.recent_starts(1003), vec![1000, 1001, 1002]);
        // Two minutes on, the first ones are out of the window.
        assert_eq!(
            files.recent_starts(1000 + START_WINDOW_SECS),
            vec![1001, 1002]
        );
        guard_at(dir.path(), &drm, 2000).unwrap();
        assert_eq!(
            files.recent_starts(2001),
            vec![2000],
            "the file is pruned as it is written"
        );
        assert_eq!(
            fs::read_to_string(dir.path().join(STARTS)).unwrap(),
            "2000\n"
        );
    }

    #[test]
    fn a_change_that_could_trip_the_start_limit_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        // Seven starts in the last minute: the change, its revert and one to spare would be ten.
        starts(dir.path(), 1000, u64::from(START_BURST - REFUSE_MARGIN));
        let d = service_at(dir.path(), 1020);
        assert_eq!(d.set_mode("HDMI-A-1", 1920, 1080, 60_000), Status::Ok);
        assert_eq!(d.revert(), Status::Ok, "a revert is never refused");
        // One more start in the window and there is no room.
        starts(dir.path(), 1010, 1);
        let d = service_at(dir.path(), 1020);
        assert_eq!(d.set_mode("HDMI-A-1", 1920, 1080, 60_000), Status::Busy);
        assert!(d.pending().is_none(), "nothing was written");
        assert!(!dir.path().join(KMS).exists());
        // The mode in use is still just "unchanged": nothing would restart.
        assert_eq!(
            d.set_mode("HDMI-A-1", 3840, 2160, 60_000),
            Status::Unchanged
        );
        // Once the starts are out of the window the change goes through.
        let later = service_at(dir.path(), 1011 + START_WINDOW_SECS);
        assert_eq!(later.set_mode("HDMI-A-1", 1920, 1080, 60_000), Status::Ok);
    }

    #[test]
    fn keep_and_revert_work_whatever_the_crowd() {
        let dir = tempfile::tempdir().unwrap();
        let d = service_at(dir.path(), 1000);
        assert_eq!(d.set_mode("HDMI-A-1", 1920, 1080, 60_000), Status::Ok);
        starts(dir.path(), 990, 20);
        let d = service_at(dir.path(), 1000);
        assert_eq!(d.keep(), Status::Ok);
        assert_eq!(d.set_mode("HDMI-A-1", 1280, 720, 60_000), Status::Busy);
    }

    // --- Reset ---

    #[test]
    fn reset_returns_mode_and_ui_size_to_the_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let d = service_at(dir.path(), 1000);
        assert_eq!(d.set_mode("HDMI-A-1", 1280, 720, 60_000), Status::Ok);
        assert_eq!(d.keep(), Status::Ok);
        assert_eq!(d.set_ui_scale(200), (Status::Ok, true));
        assert!(dir.path().join(KMS).exists());
        // The mode changes at the next start: "ok" (the shell restarts); the UI size reported changed.
        assert_eq!(d.reset(), (Status::Ok, true));
        assert!(
            !dir.path().join(KMS).exists(),
            "the preferred mode is Qt's default"
        );
        assert_eq!(d.ui_scale(), 0);
        assert_eq!(d.list().unwrap()[0].current, Some(0));
        // Nothing left to reset: "unchanged".
        assert_eq!(d.reset(), (Status::Unchanged, false));
    }

    #[test]
    fn reset_with_only_the_ui_size_set_restarts_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let d = service_at(dir.path(), 1000);
        assert_eq!(d.set_ui_scale(150), (Status::Ok, true));
        assert_eq!(d.reset(), (Status::Unchanged, true));
        assert_eq!(d.ui_scale(), 0);
    }

    #[test]
    fn reset_works_with_no_output_and_on_a_corrupt_file_and_waits_for_a_pending_change() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(STORED), "mode = 7").unwrap();
        let none = Display::with_clock(
            FakeDrm(Vec::new()),
            Some(dir.path().to_owned()),
            Box::new(|| 1000),
        );
        assert_eq!(none.reset(), (Status::Unchanged, false));
        assert_eq!(none.ui_scale(), 0, "the corrupt file was replaced");

        let dir = tempfile::tempdir().unwrap();
        let d = service_at(dir.path(), 1000);
        assert_eq!(d.set_mode("HDMI-A-1", 1920, 1080, 60_000), Status::Ok);
        assert_eq!(
            d.reset(),
            (Status::Busy, false),
            "the owner is still deciding"
        );
        assert!(d.pending().is_some());
    }

    #[test]
    fn reset_that_would_restart_is_refused_when_restarts_are_crowded() {
        let dir = tempfile::tempdir().unwrap();
        let d = service_at(dir.path(), 1000);
        assert_eq!(d.set_mode("HDMI-A-1", 1920, 1080, 60_000), Status::Ok);
        assert_eq!(d.keep(), Status::Ok);
        assert_eq!(d.set_ui_scale(125), (Status::Ok, true));
        starts(dir.path(), 990, 9);
        let d = service_at(dir.path(), 1000);
        assert_eq!(d.reset(), (Status::Busy, false));
        assert_eq!(d.ui_scale(), 125, "nothing was reset");
        assert_eq!(d.list().unwrap()[0].current, Some(2));
    }

    #[test]
    fn with_no_connected_output_the_guard_leaves_the_config_alone() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(KMS), "{}").unwrap();
        assert_eq!(
            guard(dir.path(), &FakeDrm(Vec::new())).unwrap(),
            GuardOutcome::Quiet
        );
        assert_eq!(fs::read_to_string(dir.path().join(KMS)).unwrap(), "{}");
    }
}
