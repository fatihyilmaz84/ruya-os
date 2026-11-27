//! The `flatpak` command line as the store sees it: a trait the core is written against (tests use
//! the fake), the parsers for the command's output, and the mapping of its failures to the
//! contract's job statuses. Running the real command is Linux-only (`flatpak_cli.rs`).

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use crate::app::JobStatus;

/// An app a remote offers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteApp {
    pub id: String,
    pub remote: String,
    pub branch: String,
    pub installed_size: u64,
    /// Bytes an install downloads; 0 when flatpak printed none.
    pub download_size: u64,
}

/// An app installed system-wide.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstalledApp {
    pub id: String,
    pub branch: String,
    pub remote: String,
    pub installed_size: u64,
    /// flatpak's version column; "" when the app names none.
    pub version: String,
}

/// A software source (`flatpak remotes`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteInfo {
    pub name: String,
    pub title: String,
    pub enabled: bool,
    /// Commits and metadata are verified with a GPG key.
    pub signed: bool,
}

/// The AppStream catalogue flatpak keeps for a remote.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Appstream {
    pub xml: String,
    /// The directory of the `<size>x<size>` icon folders.
    pub icon_base: String,
}

/// One transaction.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Operation {
    Install { id: String, remote: String },
    Uninstall { id: String, delete_data: bool },
    Update { id: String },
    Rollback { id: String, commit: String },
}

impl Operation {
    pub fn app(&self) -> &str {
        match self {
            Operation::Install { id, .. }
            | Operation::Uninstall { id, .. }
            | Operation::Update { id }
            | Operation::Rollback { id, .. } => id,
        }
    }

    /// The phase a job of this kind reports before its output says otherwise.
    pub fn phase(&self) -> Phase {
        match self {
            Operation::Install { .. } => Phase::Install,
            Operation::Uninstall { .. } => Phase::Remove,
            Operation::Update { .. } | Operation::Rollback { .. } => Phase::Update,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Download,
    Install,
    Update,
    Remove,
}

impl Phase {
    pub fn as_str(self) -> &'static str {
        match self {
            Phase::Download => "download",
            Phase::Install => "install",
            Phase::Update => "update",
            Phase::Remove => "remove",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Progress {
    pub percent: u32,
    pub phase: Phase,
}

/// Why a transaction failed, as far as the user can act on it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FlatpakError {
    Network,
    Signature,
    MissingRuntime,
    DiskFull,
    Other(String),
}

impl FlatpakError {
    pub fn job_status(&self) -> JobStatus {
        match self {
            FlatpakError::Network => JobStatus::Network,
            FlatpakError::Signature => JobStatus::Signature,
            FlatpakError::MissingRuntime => JobStatus::MissingRuntime,
            FlatpakError::DiskFull => JobStatus::DiskFull,
            FlatpakError::Other(_) => JobStatus::Failed,
        }
    }
}

/// Everything the store does to Flatpak. Blocking; the caller keeps it off the async executor.
pub trait Flatpak: Send + Sync {
    /// The apps the enabled remotes offer.
    fn remote_apps(&self) -> Result<Vec<RemoteApp>, String>;
    fn installed(&self) -> Result<Vec<InstalledApp>, String>;
    /// Ids of the installed apps a newer commit exists for.
    fn updates(&self) -> Result<Vec<String>, String>;
    fn remotes(&self) -> Result<Vec<RemoteInfo>, String>;
    fn appstream(&self, remote: &str) -> Option<Appstream>;
    /// The Flatpak `metadata` file of an app in a remote (its permissions).
    fn metadata(&self, remote: &str, id: &str) -> Option<String>;
    /// The `metadata` file of the installed version of an app.
    fn installed_metadata(&self, id: &str) -> Option<String>;
    /// Runs a transaction, reporting progress as the command prints it.
    fn run(&self, op: &Operation, progress: &mut dyn FnMut(Progress)) -> Result<(), FlatpakError>;
    /// Adds a system-wide remote. Never without signature verification.
    fn add_remote(&self, name: &str, url: &str) -> Result<(), FlatpakError>;
    /// Fetches the remote's AppStream data again (names, summaries, icons). A failure (no
    /// network) leaves the data flatpak already has.
    fn update_appstream(&self, remote: &str) -> Result<(), String>;
    /// What `flatpak --version` prints ("Flatpak 1.18.4"); `None` when it cannot be run.
    fn version(&self) -> Option<String>;
    /// The app's system-wide override as a keyfile (`flatpak override --show`); "" without one.
    fn show_override(&self, id: &str) -> Result<String, String>;
    /// Every app's system-wide override keyfile by app id, read in one pass (the files of Flatpak's
    /// overrides directory, no process); an app without one is absent. What `show_override` prints
    /// for each of them. A file that cannot be read is left out and logged.
    fn overrides(&self) -> Result<BTreeMap<String, String>, String>;
    /// Adds `args` (`overrides::withdraw_args`) to the app's override.
    fn add_override(&self, id: &str, args: &[String]) -> Result<(), String>;
    /// Removes the app's override, whoever wrote it (`flatpak override --reset`).
    fn reset_override(&self, id: &str) -> Result<(), String>;
    /// Puts back an override `show_override` printed (a restore whose second step failed, so it
    /// never ends wider than it began); "" removes it. `flatpak override` cannot write a whole
    /// keyfile, so this writes Flatpak's file itself.
    fn write_override(&self, id: &str, keyfile: &str) -> Result<(), String>;
}

/// Maps the error text of `flatpak` to what the user can do about it. The first match wins, the
/// most specific causes first.
pub fn classify_error(stderr: &str) -> FlatpakError {
    let text = stderr.to_lowercase();
    let has = |needles: &[&str]| needles.iter().any(|n| text.contains(n));
    if has(&["no space left", "not enough disk space", "disk full"]) {
        FlatpakError::DiskFull
    } else if has(&["gpg", "signature", "untrusted"]) {
        FlatpakError::Signature
    } else if has(&[
        "unable to connect",
        "could not resolve",
        "couldn't resolve",
        "network is unreachable",
        "temporary failure in name resolution",
        "connection refused",
        "connection timed out",
        "server returned status",
        "unable to load summary",
        "failed to connect",
    ]) {
        FlatpakError::Network
    } else if (text.contains("runtime") || text.contains("sdk"))
        && has(&[
            "not found",
            "not installed",
            "nothing matches",
            "which was not found",
            "requires",
        ])
    {
        FlatpakError::MissingRuntime
    } else {
        // The last line that says something (a terminal's output can end in blank lines); never an
        // empty reason, which the journal shows as `failed: ` (RUY-679: `Remote "x" not found`).
        let line = stderr
            .lines()
            .map(|l| l.trim_matches(|c: char| c.is_control() || c.is_whitespace()))
            .rev()
            .find(|l| !l.is_empty())
            .unwrap_or("flatpak failed without saying why");
        FlatpakError::Other(line.to_owned())
    }
}

/// "12.3 MB", "512 bytes", "1.5 GB" (GLib's size format, a no-break space between number and
/// unit, powers of 1000) to bytes. Unreadable text is 0.
pub fn parse_size(text: &str) -> u64 {
    let mut parts = text.split_whitespace();
    let Some(number) = parts
        .next()
        .and_then(|n| n.replace(',', ".").parse::<f64>().ok())
    else {
        return 0;
    };
    let unit: u64 = match parts.next().unwrap_or("bytes") {
        "kB" | "KB" => 1_000,
        "MB" => 1_000_000,
        "GB" => 1_000_000_000,
        "TB" => 1_000_000_000_000,
        "KiB" => 1 << 10,
        "MiB" => 1 << 20,
        "GiB" => 1 << 30,
        _ => 1,
    };
    (number * unit as f64) as u64
}

/// Splits tab-separated rows, skipping blank lines.
fn rows(output: &str) -> impl Iterator<Item = Vec<&str>> {
    output
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| l.split('\t').map(str::trim).collect())
}

/// `flatpak remote-ls --app --columns=application,origin,branch,installed-size,download-size`. An app in several
/// branches is listed once, `stable` first.
pub fn parse_remote_ls(output: &str) -> Vec<RemoteApp> {
    let mut apps: Vec<RemoteApp> = Vec::new();
    for row in rows(output) {
        let [id, remote, branch, size, ..] = row[..] else {
            continue;
        };
        let download = row.get(4).copied().unwrap_or("");
        let app = RemoteApp {
            id: id.to_owned(),
            remote: remote.to_owned(),
            branch: branch.to_owned(),
            installed_size: parse_size(size),
            download_size: parse_size(download),
        };
        match apps.iter_mut().find(|a| a.id == app.id) {
            Some(known) if known.branch != "stable" && app.branch == "stable" => *known = app,
            Some(_) => {}
            None => apps.push(app),
        }
    }
    apps
}

/// `flatpak list --app --columns=application,branch,origin,size,version`.
pub fn parse_installed(output: &str) -> Vec<InstalledApp> {
    rows(output)
        .filter_map(|row| match row[..] {
            [id, branch, remote, size, ..] => Some(InstalledApp {
                id: id.to_owned(),
                branch: branch.to_owned(),
                remote: remote.to_owned(),
                installed_size: parse_size(size),
                version: row.get(4).copied().unwrap_or("").to_owned(),
            }),
            _ => None,
        })
        .collect()
}

/// One id per line (`--columns=application`).
pub fn parse_ids(output: &str) -> Vec<String> {
    rows(output).map(|row| row[0].to_owned()).collect()
}

/// `flatpak remotes --columns=name,title,options`; `options` is a comma list ("system",
/// "disabled", "no-gpg-verify", ...).
pub fn parse_remotes(output: &str) -> Vec<RemoteInfo> {
    rows(output)
        .filter(|row| !row[0].is_empty())
        .map(|row| {
            let options = row.get(2).copied().unwrap_or("");
            let has = |o: &str| options.split(',').any(|x| x.trim() == o);
            RemoteInfo {
                name: row[0].to_owned(),
                title: row
                    .get(1)
                    .filter(|t| !t.is_empty())
                    .unwrap_or(&row[0])
                    .to_string(),
                enabled: !has("disabled"),
                signed: !has("no-gpg-verify"),
            }
        })
        .collect()
}

/// `text` without terminal escape sequences (colours, cursor movement, window titles), which
/// flatpak writes when it believes it talks to a terminal.
pub fn strip_escapes(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            out.push(c);
            continue;
        }
        match chars.next() {
            // CSI: parameters and intermediates, then one final byte in 0x40..=0x7e.
            Some('[') => {
                for c in chars.by_ref() {
                    if ('\u{40}'..='\u{7e}').contains(&c) {
                        break;
                    }
                }
            }
            // OSC: up to BEL or ESC plus one more character.
            Some(']') => {
                while let Some(c) = chars.next() {
                    if c == '\u{7}' {
                        break;
                    }
                    if c == '\u{1b}' {
                        chars.next();
                        break;
                    }
                }
            }
            // Any other two-character sequence.
            _ => {}
        }
    }
    out
}

/// The `n/m` of "Installing 2/3" (the n-th of m refs), when the text before the percentage
/// has one.
fn step_of(before_percent: &str) -> Option<(u32, u32)> {
    before_percent.split_whitespace().find_map(|word| {
        let word = word.trim_matches(|c: char| !c.is_ascii_digit() && c != '/');
        let (n, m) = word.split_once('/')?;
        let (n, m): (u32, u32) = (n.parse().ok()?, m.parse().ok()?);
        (m >= 1 && (1..=m).contains(&n)).then_some((n, m))
    })
}

/// The percentage in a line of `flatpak install` output ("Installing... 45%"), and the phase
/// when the line names one. Lines without a percentage give `None`. flatpak counts every ref
/// (the app and its runtimes) from 0 to 100 on its own; with an "n/m" in the line the result
/// is the share of the whole transaction.
pub fn parse_progress(line: &str) -> Option<(u32, Option<Phase>)> {
    let line = strip_escapes(line);
    let end = line.find('%')?;
    let digits: String = line[..end]
        .chars()
        .rev()
        .take_while(char::is_ascii_digit)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    let mut percent: u32 = digits.parse::<u32>().ok()?.min(100);
    if let Some((n, m)) = step_of(&line[..end - digits.len()]) {
        percent = ((n - 1) * 100 + percent) / m;
    }
    let lower = line.to_lowercase();
    let phase = if lower.contains("download") || lower.contains("fetch") {
        Some(Phase::Download)
    } else if lower.contains("uninstall") {
        Some(Phase::Remove)
    } else if lower.contains("updating") {
        Some(Phase::Update)
    } else if lower.contains("install") {
        Some(Phase::Install)
    } else {
        None
    };
    Some((percent, phase))
}

/// Reads what a flatpak transaction prints on a terminal: lines end in a newline or, for a
/// redrawn progress bar, a carriage return. Reports every percentage and keeps the last lines
/// (without escape sequences) for `classify_error`, since a terminal merges stdout and stderr.
#[derive(Default)]
pub struct ProgressScanner {
    line: Vec<u8>,
    tail: std::collections::VecDeque<String>,
}

const TAIL_LINES: usize = 20;
const MAX_LINE: usize = 4096;

impl ProgressScanner {
    pub fn feed(&mut self, bytes: &[u8], on_progress: &mut dyn FnMut(u32, Option<Phase>)) {
        for &byte in bytes {
            if byte == b'\r' || byte == b'\n' {
                self.end_line(on_progress);
            } else if self.line.len() < MAX_LINE {
                self.line.push(byte);
            }
        }
    }

    /// The output has ended: a last line without a terminator counts too.
    pub fn finish(&mut self, on_progress: &mut dyn FnMut(u32, Option<Phase>)) {
        self.end_line(on_progress);
    }

    fn end_line(&mut self, on_progress: &mut dyn FnMut(u32, Option<Phase>)) {
        let raw = String::from_utf8_lossy(&self.line).into_owned();
        self.line.clear();
        if let Some((percent, phase)) = parse_progress(&raw) {
            on_progress(percent, phase);
        }
        let text = strip_escapes(&raw);
        if !text.trim().is_empty() {
            if self.tail.len() == TAIL_LINES {
                self.tail.pop_front();
            }
            self.tail.push_back(text);
        }
    }

    /// The last lines of output, for classifying a failure.
    pub fn tail(&self) -> String {
        self.tail.iter().cloned().collect::<Vec<_>>().join("\n")
    }
}

/// Scripted Flatpak for tests and `--session`: remotes with apps, installed apps, pending
/// updates, and an error to fail the next transaction with.
pub struct FakeFlatpak {
    state: Mutex<FakeState>,
}

#[derive(Default)]
struct FakeState {
    remotes: Vec<RemoteInfo>,
    available: Vec<RemoteApp>,
    installed: Vec<InstalledApp>,
    updates: Vec<String>,
    appstream: HashMap<String, Appstream>,
    /// What `update_appstream` fetches, per remote.
    appstream_fresh: HashMap<String, Appstream>,
    appstream_offline: bool,
    appstream_updates: Vec<String>,
    metadata: HashMap<String, String>,
    installed_metadata: HashMap<String, String>,
    fail_next: Option<FlatpakError>,
    installed_fails: bool,
    /// How many times `installed()` (`flatpak list`) was read.
    installed_reads: usize,
    /// Runs once, right after the next `installed()` read, with the state unlocked.
    after_installed: Option<Box<dyn FnOnce() + Send>>,
    progress: Vec<u32>,
    ran: Vec<Operation>,
    added: Vec<(String, String)>,
    /// `flatpak --version`; `None`: the command cannot be run.
    version: Option<String>,
    /// Override keyfiles by app id, as `flatpak override` writes them.
    overrides: HashMap<String, String>,
    /// Every `flatpak override` command line, in order (`ruya_flatpak::override_command`, ...).
    override_runs: Vec<Vec<String>>,
    override_fails: bool,
    /// The next `add_override` fails (once), the commands before it work.
    add_override_fails_once: bool,
    /// Runs once, right after the next `show_override` read, with the state unlocked.
    after_show_override: Option<Box<dyn FnOnce() + Send>>,
    /// Runs once, right after the next `reset_override`, with the state unlocked: the moment a
    /// restore has reset the override and not written the rest yet.
    after_reset_override: Option<Box<dyn FnOnce() + Send>>,
    /// Every `show_override` waits here for the other readers.
    show_meeting: Option<Arc<Meeting>>,
    /// The apps `installed_metadata` was asked for, in order.
    installed_metadata_reads: Vec<String>,
}

/// A rendezvous for reads that must be inside the fake at the same time: `arrive` returns once
/// `readers` calls are in it (or `patience` ran out, which `met` then says). A reader that waits
/// for another one under a lock never meets it.
pub struct Meeting {
    readers: usize,
    patience: Duration,
    arrived: Mutex<usize>,
    all: Condvar,
    timed_out: Mutex<bool>,
}

impl Meeting {
    fn arrive(&self) {
        let mut arrived = self.arrived.lock().unwrap_or_else(|e| e.into_inner());
        *arrived += 1;
        self.all.notify_all();
        let (arrived, wait) = self
            .all
            .wait_timeout_while(arrived, self.patience, |n| *n < self.readers)
            .unwrap_or_else(|e| e.into_inner());
        drop(arrived);
        if wait.timed_out() {
            *self.timed_out.lock().unwrap_or_else(|e| e.into_inner()) = true;
        }
    }

    /// Whether every reader was inside at once (nobody waited in vain).
    pub fn met(&self) -> bool {
        !*self.timed_out.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Default for FakeFlatpak {
    fn default() -> Self {
        FakeFlatpak {
            state: Mutex::new(FakeState {
                version: Some("Flatpak 1.18.4".to_owned()),
                ..FakeState::default()
            }),
        }
    }
}

impl FakeFlatpak {
    fn state(&self) -> std::sync::MutexGuard<'_, FakeState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn with_remote(self, name: &str, title: &str, signed: bool) -> Self {
        self.state().remotes.push(RemoteInfo {
            name: name.to_owned(),
            title: title.to_owned(),
            enabled: true,
            signed,
        });
        self
    }

    pub fn with_app(self, remote: &str, id: &str, size: u64) -> Self {
        self.state().available.push(RemoteApp {
            id: id.to_owned(),
            remote: remote.to_owned(),
            branch: "stable".to_owned(),
            installed_size: size,
            download_size: 0,
        });
        self
    }

    pub fn with_installed(self, remote: &str, id: &str, size: u64) -> Self {
        self.state().installed.push(InstalledApp {
            id: id.to_owned(),
            branch: "stable".to_owned(),
            remote: remote.to_owned(),
            installed_size: size,
            version: String::new(),
        });
        self
    }

    pub fn with_download_size(self, id: &str, bytes: u64) -> Self {
        for a in self.state().available.iter_mut().filter(|a| a.id == id) {
            a.download_size = bytes;
        }
        self
    }

    pub fn with_installed_version(self, id: &str, version: &str) -> Self {
        for a in self.state().installed.iter_mut().filter(|a| a.id == id) {
            a.version = version.to_owned();
        }
        self
    }

    pub fn with_update(self, id: &str) -> Self {
        self.state().updates.push(id.to_owned());
        self
    }

    pub fn with_appstream(self, remote: &str, xml: &str) -> Self {
        self.state().appstream.insert(
            remote.to_owned(),
            Appstream {
                xml: xml.to_owned(),
                icon_base: format!("/icons/{remote}"),
            },
        );
        self
    }

    /// The AppStream data a successful `update_appstream` of `remote` fetches.
    pub fn with_fresh_appstream(self, remote: &str, xml: &str) -> Self {
        self.state().appstream_fresh.insert(
            remote.to_owned(),
            Appstream {
                xml: xml.to_owned(),
                icon_base: format!("/icons/{remote}"),
            },
        );
        self
    }

    /// `update_appstream` fails, as without a network.
    pub fn offline(self) -> Self {
        self.state().appstream_offline = true;
        self
    }

    pub fn appstream_updates(&self) -> Vec<String> {
        self.state().appstream_updates.clone()
    }

    pub fn with_metadata(self, id: &str, metadata: &str) -> Self {
        self.state()
            .metadata
            .insert(id.to_owned(), metadata.to_owned());
        self
    }

    /// Replaces the remote's metadata of an app (a new version was published).
    pub fn set_metadata(&self, id: &str, metadata: &str) {
        self.state()
            .metadata
            .insert(id.to_owned(), metadata.to_owned());
    }

    /// The metadata of the installed version, when it differs from the remote's.
    pub fn with_installed_metadata(self, id: &str, metadata: &str) -> Self {
        self.state()
            .installed_metadata
            .insert(id.to_owned(), metadata.to_owned());
        self
    }

    /// The installed version's metadata written again (an app committed anew over the same
    /// deployment, as `ruya-play` does for a newer metadata generation).
    pub fn set_installed_metadata(&self, id: &str, metadata: &str) {
        self.state()
            .installed_metadata
            .insert(id.to_owned(), metadata.to_owned());
    }

    /// The percentages the next transactions report (a download that goes 10, 60, 100).
    pub fn with_progress(self, steps: &[u32]) -> Self {
        self.state().progress = steps.to_vec();
        self
    }

    /// The next transaction fails with this error (once).
    pub fn fail_next(&self, error: FlatpakError) {
        self.state().fail_next = Some(error);
    }

    /// Whether `installed()` (`flatpak list`) fails from now on.
    pub fn set_installed_fails(&self, fails: bool) {
        self.state().installed_fails = fails;
    }

    /// Runs `hook` once after the next `installed()` returned its list: lets a test play out
    /// what else happens while `flatpak list` runs.
    pub fn after_next_installed(&self, hook: impl FnOnce() + Send + 'static) {
        self.state().after_installed = Some(Box::new(hook));
    }

    /// An app installed behind the Store's back (`flatpak install` by hand).
    pub fn add_installed(&self, remote: &str, id: &str, size: u64) {
        self.state().installed.push(InstalledApp {
            id: id.to_owned(),
            branch: "stable".to_owned(),
            remote: remote.to_owned(),
            installed_size: size,
            version: String::new(),
        });
    }

    /// An app removed behind the Store's back (`flatpak uninstall` by hand).
    pub fn remove_installed(&self, id: &str) {
        let mut state = self.state();
        state.installed.retain(|a| a.id != id);
        state.updates.retain(|u| u != id);
    }

    pub fn ran(&self) -> Vec<Operation> {
        self.state().ran.clone()
    }

    pub fn added(&self) -> Vec<(String, String)> {
        self.state().added.clone()
    }

    /// What `flatpak --version` prints (`None`: it cannot be run).
    pub fn with_version(self, version: Option<&str>) -> Self {
        self.state().version = version.map(str::to_owned);
        self
    }

    /// An override that is there already (written by hand, or by an earlier run).
    pub fn with_override(self, id: &str, keyfile: &str) -> Self {
        self.state()
            .overrides
            .insert(id.to_owned(), keyfile.to_owned());
        self
    }

    /// The app's override as `flatpak override --show` prints it.
    pub fn override_of(&self, id: &str) -> String {
        self.state().overrides.get(id).cloned().unwrap_or_default()
    }

    /// The `flatpak override` command lines run so far.
    pub fn override_runs(&self) -> Vec<Vec<String>> {
        self.state().override_runs.clone()
    }

    /// Whether `flatpak override` fails from now on.
    pub fn set_override_fails(&self, fails: bool) {
        self.state().override_fails = fails;
    }

    /// The next `add_override` fails, once (a restore whose reset worked and whose second step
    /// did not).
    pub fn fail_next_add_override(&self) {
        self.state().add_override_fails_once = true;
    }

    /// Runs `hook` once after the next `show_override` returned: lets a test play out a call that
    /// comes in between a change's read of the override and its write.
    pub fn after_next_show_override(&self, hook: impl FnOnce() + Send + 'static) {
        self.state().after_show_override = Some(Box::new(hook));
    }

    /// Runs `hook` once after the next `reset_override`: a restore has reset the override and has
    /// not written the rest back yet.
    pub fn after_next_reset_override(&self, hook: impl FnOnce() + Send + 'static) {
        self.state().after_reset_override = Some(Box::new(hook));
    }

    /// Makes every `show_override` wait until `readers` of them are inside, for up to `patience`.
    /// The returned meeting says whether they all were (a read that queues behind another never
    /// meets it).
    pub fn readers_meet(&self, readers: usize, patience: Duration) -> Arc<Meeting> {
        let meeting = Arc::new(Meeting {
            readers,
            patience,
            arrived: Mutex::new(0),
            all: Condvar::new(),
            timed_out: Mutex::new(false),
        });
        self.state().show_meeting = Some(meeting.clone());
        meeting
    }

    /// How many times the installed list was read (one `flatpak list` each).
    pub fn installed_reads(&self) -> usize {
        self.state().installed_reads
    }

    /// The apps `installed_metadata` was asked for, in order (one `flatpak info` each).
    pub fn installed_metadata_reads(&self) -> Vec<String> {
        self.state().installed_metadata_reads.clone()
    }
}

/// What `flatpak override <args>` makes of an override keyfile: each option replaces the entry
/// of the same name in its `[Context]` list (`--unshare=network` writes `shared=!network;`).
/// Other groups and keys stay as they are. Enough of Flatpak for the tests.
fn fake_override(keyfile: &str, args: &[String]) -> String {
    let mut groups: Vec<(String, Vec<(String, String)>)> = Vec::new();
    for line in keyfile.lines().map(str::trim).filter(|l| !l.is_empty()) {
        if let Some(name) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            groups.push((name.to_owned(), Vec::new()));
        } else if let (Some((key, value)), Some(group)) = (line.split_once('='), groups.last_mut())
        {
            group.1.push((key.to_owned(), value.to_owned()));
        }
    }
    if !groups.iter().any(|(g, _)| g == "Context") {
        groups.insert(0, ("Context".to_owned(), Vec::new()));
    }
    for arg in args {
        let Some((option, name)) = arg.split_once('=') else {
            continue;
        };
        let (key, negated) = match option {
            "--share" => ("shared", false),
            "--unshare" => ("shared", true),
            "--socket" => ("sockets", false),
            "--nosocket" => ("sockets", true),
            "--device" => ("devices", false),
            "--nodevice" => ("devices", true),
            "--filesystem" => ("filesystems", false),
            "--nofilesystem" => ("filesystems", true),
            _ => continue,
        };
        let Some((_, context)) = groups.iter_mut().find(|(g, _)| g == "Context") else {
            continue;
        };
        if !context.iter().any(|(k, _)| k == key) {
            context.push((key.to_owned(), String::new()));
        }
        let Some((_, value)) = context.iter_mut().find(|(k, _)| k == key) else {
            continue;
        };
        let mut items: Vec<String> = value
            .split(';')
            .filter(|i| !i.is_empty() && i.trim_start_matches('!') != name)
            .map(str::to_owned)
            .collect();
        items.push(if negated {
            format!("!{name}")
        } else {
            name.to_owned()
        });
        *value = items.iter().map(|i| format!("{i};")).collect();
    }
    let mut out = String::new();
    for (name, entries) in groups.iter().filter(|(_, e)| !e.is_empty()) {
        out.push_str(&format!("[{name}]\n"));
        for (key, value) in entries {
            out.push_str(&format!("{key}={value}\n"));
        }
    }
    out
}

impl Flatpak for FakeFlatpak {
    fn remote_apps(&self) -> Result<Vec<RemoteApp>, String> {
        Ok(self.state().available.clone())
    }

    fn installed(&self) -> Result<Vec<InstalledApp>, String> {
        let mut state = self.state();
        state.installed_reads += 1;
        if state.installed_fails {
            return Err("flatpak list failed".to_owned());
        }
        let list = state.installed.clone();
        let hook = state.after_installed.take();
        drop(state);
        if let Some(hook) = hook {
            hook();
        }
        Ok(list)
    }

    fn updates(&self) -> Result<Vec<String>, String> {
        Ok(self.state().updates.clone())
    }

    fn remotes(&self) -> Result<Vec<RemoteInfo>, String> {
        Ok(self.state().remotes.clone())
    }

    fn appstream(&self, remote: &str) -> Option<Appstream> {
        self.state().appstream.get(remote).cloned()
    }

    fn metadata(&self, _remote: &str, id: &str) -> Option<String> {
        self.state().metadata.get(id).cloned()
    }

    fn installed_metadata(&self, id: &str) -> Option<String> {
        let mut state = self.state();
        state.installed_metadata_reads.push(id.to_owned());
        state
            .installed_metadata
            .get(id)
            .or_else(|| state.metadata.get(id))
            .cloned()
    }

    fn update_appstream(&self, remote: &str) -> Result<(), String> {
        let mut state = self.state();
        state.appstream_updates.push(remote.to_owned());
        if state.appstream_offline {
            return Err("unable to connect".to_owned());
        }
        if let Some(fresh) = state.appstream_fresh.get(remote).cloned() {
            state.appstream.insert(remote.to_owned(), fresh);
        }
        Ok(())
    }

    fn run(&self, op: &Operation, progress: &mut dyn FnMut(Progress)) -> Result<(), FlatpakError> {
        let (steps, failure) = {
            let mut state = self.state();
            state.ran.push(op.clone());
            (state.progress.clone(), state.fail_next.take())
        };
        for percent in steps {
            progress(Progress {
                percent,
                phase: op.phase(),
            });
        }
        if let Some(error) = failure {
            return Err(error);
        }
        let mut state = self.state();
        match op {
            Operation::Install { id, remote } => {
                let size = state
                    .available
                    .iter()
                    .find(|a| a.id == *id)
                    .map_or(0, |a| a.installed_size);
                state.installed.push(InstalledApp {
                    id: id.clone(),
                    branch: "stable".to_owned(),
                    remote: remote.clone(),
                    installed_size: size,
                    version: String::new(),
                });
            }
            Operation::Uninstall { id, .. } => {
                state.installed.retain(|a| a.id != *id);
                state.updates.retain(|u| u != id);
            }
            Operation::Update { id } | Operation::Rollback { id, .. } => {
                state.updates.retain(|u| u != id);
            }
        }
        Ok(())
    }

    fn version(&self) -> Option<String> {
        self.state().version.clone()
    }

    fn show_override(&self, id: &str) -> Result<String, String> {
        let (shown, hook, meeting) = {
            let mut state = self.state();
            state.override_runs.push(ruya_flatpak::show_command(id));
            if state.override_fails {
                return Err("flatpak override failed".to_owned());
            }
            let shown = state.overrides.get(id).cloned().unwrap_or_default();
            (
                shown,
                state.after_show_override.take(),
                state.show_meeting.clone(),
            )
        };
        if let Some(meeting) = meeting {
            meeting.arrive();
        }
        if let Some(hook) = hook {
            hook();
        }
        Ok(shown)
    }

    fn overrides(&self) -> Result<BTreeMap<String, String>, String> {
        let state = self.state();
        if state.override_fails {
            return Err("the overrides cannot be read".to_owned());
        }
        Ok(state
            .overrides
            .iter()
            .map(|(id, keyfile)| (id.clone(), keyfile.clone()))
            .collect())
    }

    fn add_override(&self, id: &str, args: &[String]) -> Result<(), String> {
        let mut state = self.state();
        state
            .override_runs
            .push(ruya_flatpak::override_command(id, args));
        if state.override_fails || std::mem::take(&mut state.add_override_fails_once) {
            return Err("flatpak override failed".to_owned());
        }
        let now = fake_override(state.overrides.get(id).map_or("", String::as_str), args);
        state.overrides.insert(id.to_owned(), now);
        Ok(())
    }

    fn reset_override(&self, id: &str) -> Result<(), String> {
        let hook = {
            let mut state = self.state();
            state.override_runs.push(ruya_flatpak::reset_command(id));
            if state.override_fails {
                return Err("flatpak override failed".to_owned());
            }
            state.overrides.remove(id);
            state.after_reset_override.take()
        };
        if let Some(hook) = hook {
            hook();
        }
        Ok(())
    }

    fn write_override(&self, id: &str, keyfile: &str) -> Result<(), String> {
        let mut state = self.state();
        if state.override_fails {
            return Err("writing the override failed".to_owned());
        }
        if keyfile.is_empty() {
            state.overrides.remove(id);
        } else {
            state.overrides.insert(id.to_owned(), keyfile.to_owned());
        }
        Ok(())
    }

    fn add_remote(&self, name: &str, url: &str) -> Result<(), FlatpakError> {
        let mut state = self.state();
        if url.contains("unsigned") {
            return Err(FlatpakError::Signature);
        }
        state.added.push((name.to_owned(), url.to_owned()));
        state.remotes.push(RemoteInfo {
            name: name.to_owned(),
            title: name.to_owned(),
            enabled: true,
            signed: true,
        });
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_error_kind_maps_to_its_job_status() {
        let cases = [
            ("error: No space left on device", JobStatus::DiskFull),
            ("error: GPG verification enabled, but no signatures found", JobStatus::Signature),
            ("error: Commit has no requested ref; signature invalid", JobStatus::Signature),
            ("error: Unable to connect to example.org: Could not resolve hostname", JobStatus::Network),
            ("error: Server returned status 503: Service Unavailable", JobStatus::Network),
            (
                "error: The application org.x.App requires the runtime org.x.Platform/x86_64/1 which was not found",
                JobStatus::MissingRuntime,
            ),
            ("error: Something odd happened", JobStatus::Failed),
            ("", JobStatus::Failed),
        ];
        for (text, want) in cases {
            assert_eq!(classify_error(text).job_status(), want, "{text:?}");
        }
    }

    #[test]
    fn other_errors_keep_the_last_line_only() {
        let FlatpakError::Other(line) = classify_error("warning: x\nerror: it broke\n") else {
            panic!("not Other");
        };
        assert_eq!(line, "error: it broke");
    }

    #[test]
    fn an_unmapped_error_always_has_a_readable_reason() {
        // RUY-679: a missing remote has no mapping and must not end as reason="".
        let FlatpakError::Other(line) =
            classify_error("error: Remote \"ruyaos-session-test\" not found\n\n  \n")
        else {
            panic!("not Other");
        };
        assert_eq!(line, "error: Remote \"ruyaos-session-test\" not found");
        for silent in ["", "\n\n", "  \r\n\x1b\n"] {
            let FlatpakError::Other(line) = classify_error(silent) else {
                panic!("not Other");
            };
            assert!(!line.is_empty(), "{silent:?} gave an empty reason");
        }
    }

    #[test]
    fn sizes() {
        assert_eq!(parse_size("12.3\u{a0}MB"), 12_300_000);
        assert_eq!(parse_size("512 bytes"), 512);
        assert_eq!(parse_size("1.5 GB"), 1_500_000_000);
        assert_eq!(parse_size("3 kB"), 3000);
        assert_eq!(parse_size("2,5 MB"), 2_500_000);
        assert_eq!(parse_size(""), 0);
        assert_eq!(parse_size("many"), 0);
    }

    #[test]
    fn remote_ls_dedupes_branches_preferring_stable() {
        let out = "org.a.One\truya\tbeta\t1 MB\norg.a.One\truya\tstable\t2 MB\norg.a.Two\truya\tstable\t5 kB\n\nshort\n";
        let apps = parse_remote_ls(out);
        assert_eq!(apps.len(), 2);
        assert_eq!(apps[0].branch, "stable");
        assert_eq!(apps[0].installed_size, 2_000_000);
        assert_eq!(apps[1].id, "org.a.Two");
    }

    #[test]
    fn remote_ls_reads_the_download_size_column() {
        let out = "org.a.One\truya\tstable\t2 MB\t1.5 MB\norg.a.Two\truya\tstable\t5 kB\t\norg.a.Three\truya\tstable\t5 kB\n";
        let apps = parse_remote_ls(out);
        assert_eq!(apps[0].download_size, 1_500_000);
        assert_eq!(apps[1].download_size, 0, "empty column: unknown");
        assert_eq!(apps[2].download_size, 0, "no column: unknown");
    }

    #[test]
    fn installed_reads_the_version_column() {
        let apps = parse_installed(
            "org.a.One\tstable\truya\t3 MB\t1.4.2\norg.a.Two\tstable\truya\t3 MB\t\norg.a.Three\tstable\truya\t3 MB\n",
        );
        assert_eq!(apps[0].version, "1.4.2");
        assert_eq!(apps[1].version, "");
        assert_eq!(apps[2].version, "");
    }

    #[test]
    fn installed_ids_and_remotes() {
        let apps = parse_installed("org.a.One\tstable\truya\t3 MB\n");
        assert_eq!(apps[0].remote, "ruya");
        assert_eq!(
            parse_ids("org.a.One\norg.a.Two\n\n"),
            ["org.a.One", "org.a.Two"]
        );
        let remotes = parse_remotes(
            "ruya\tRuyaOS\tsystem\nflathub\t\tsystem,disabled\nraw\tRaw\tsystem,no-gpg-verify\n",
        );
        assert_eq!(
            remotes[0],
            RemoteInfo {
                name: "ruya".into(),
                title: "RuyaOS".into(),
                enabled: true,
                signed: true
            }
        );
        assert_eq!(remotes[1].title, "flathub", "no title: the name");
        assert!(!remotes[1].enabled);
        assert!(!remotes[2].signed);
    }

    #[test]
    fn progress_lines() {
        assert_eq!(
            parse_progress("Installing... 45%"),
            Some((45, Some(Phase::Install)))
        );
        assert_eq!(
            parse_progress("Downloading 100%"),
            Some((100, Some(Phase::Download)))
        );
        assert_eq!(
            parse_progress("Updating  7% 1.2 MB/s"),
            Some((7, Some(Phase::Update)))
        );
        assert_eq!(
            parse_progress("Uninstalling 50%"),
            Some((50, Some(Phase::Remove)))
        );
        assert_eq!(parse_progress("  12%"), Some((12, None)));
        assert_eq!(
            parse_progress("Installing 2/4...  50%"),
            Some((37, Some(Phase::Install)))
        );
        assert_eq!(
            parse_progress("Installing 4/4...  100%"),
            Some((100, Some(Phase::Install)))
        );
        assert_eq!(
            parse_progress("Installing 5/4  50%"),
            Some((50, Some(Phase::Install)))
        );
        assert_eq!(parse_progress("Installing org.a.One"), None);
        assert_eq!(
            parse_progress("% done"),
            None,
            "no digits before the percent sign"
        );
    }

    #[test]
    fn escape_codes_are_stripped() {
        assert_eq!(
            strip_escapes("\x1b[?25l\x1b[1mHello\x1b[0m \x1b[2K"),
            "Hello "
        );
        assert_eq!(strip_escapes("a\x1b]0;title\x07b"), "ab");
        assert_eq!(
            parse_progress("\x1b[1mInstalling\x1b[0m 1/1... \x1b[32m####\x1b[0m 45%\x1b[K"),
            Some((45, Some(Phase::Install)))
        );
    }

    /// Output as a terminal gets it: redrawn lines end in `\r`, colours around, a failure at the end.
    const CAPTURE: &str = "\x1b[?25lInstalling 1/2...  \u{2588}        0%\r\
        Installing 1/2... \u{2588}\u{2588}\u{2588}\u{2588}    50%\r\
        Installing 1/2... \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588} 100%\r\n\
        Installing 2/2...  \u{2588}        0%\r\
        Installing 2/2... \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}   60%\r\
        Installing 2/2... \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588} 100%\r\n\x1b[?25h";

    #[test]
    fn scanner_reads_redraws_and_never_decreases_once_filtered() {
        let mut scanner = ProgressScanner::default();
        let mut seen = Vec::new();
        // Fed in awkward pieces: a sequence split in the middle must not matter.
        for chunk in CAPTURE.as_bytes().chunks(7) {
            scanner.feed(chunk, &mut |p, _| seen.push(p));
        }
        scanner.finish(&mut |p, _| seen.push(p));
        assert_eq!(seen, [0, 25, 50, 50, 80, 100]);
        let mut monotone = crate::queue::Monotone::default();
        let shown: Vec<_> = seen
            .iter()
            .filter_map(|&p| monotone.next(p, Phase::Install))
            .collect();
        assert_eq!(shown, [0, 25, 50, 80, 100]);
    }

    #[test]
    fn scanner_keeps_the_last_lines_for_the_error() {
        let mut scanner = ProgressScanner::default();
        scanner.feed(
            b"Installing 1/1...  10%\rerror: Unable to connect to dl.flathub.org\r\n",
            &mut |_, _| {},
        );
        scanner.finish(&mut |_, _| {});
        assert_eq!(classify_error(&scanner.tail()), FlatpakError::Network);
        let mut long = ProgressScanner::default();
        for i in 0..100 {
            long.feed(format!("line {i}\n").as_bytes(), &mut |_, _| {});
        }
        assert_eq!(long.tail().lines().count(), TAIL_LINES);
        assert!(long.tail().ends_with("line 99"));
    }
}
