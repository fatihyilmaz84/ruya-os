//! The `flatpak` command line as the store sees it: a trait the core is written against (tests use
//! the fake), the parsers for the command's output, and the mapping of its failures to the
//! contract's job statuses. Running the real command is Linux-only (`flatpak_cli.rs`).

use std::collections::HashMap;
use std::sync::Mutex;

use crate::app::JobStatus;

/// An app a remote offers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteApp {
    pub id: String,
    pub remote: String,
    pub branch: String,
    pub installed_size: u64,
}

/// An app installed system-wide.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstalledApp {
    pub id: String,
    pub branch: String,
    pub remote: String,
    pub installed_size: u64,
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
    /// Runs a transaction, reporting progress as the command prints it.
    fn run(&self, op: &Operation, progress: &mut dyn FnMut(Progress)) -> Result<(), FlatpakError>;
    /// Adds a system-wide remote. Never without signature verification.
    fn add_remote(&self, name: &str, url: &str) -> Result<(), FlatpakError>;
    /// Fetches the remote's AppStream data again (names, summaries, icons). A failure (no
    /// network) leaves the data flatpak already has.
    fn update_appstream(&self, remote: &str) -> Result<(), String>;
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
        FlatpakError::Other(stderr.trim().lines().last().unwrap_or("").to_owned())
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

/// `flatpak remote-ls --app --columns=application,origin,branch,installed-size`. An app in several
/// branches is listed once, `stable` first.
pub fn parse_remote_ls(output: &str) -> Vec<RemoteApp> {
    let mut apps: Vec<RemoteApp> = Vec::new();
    for row in rows(output) {
        let [id, remote, branch, size, ..] = row[..] else {
            continue;
        };
        let app = RemoteApp {
            id: id.to_owned(),
            remote: remote.to_owned(),
            branch: branch.to_owned(),
            installed_size: parse_size(size),
        };
        match apps.iter_mut().find(|a| a.id == app.id) {
            Some(known) if known.branch != "stable" && app.branch == "stable" => *known = app,
            Some(_) => {}
            None => apps.push(app),
        }
    }
    apps
}

/// `flatpak list --app --columns=application,branch,origin,size`.
pub fn parse_installed(output: &str) -> Vec<InstalledApp> {
    rows(output)
        .filter_map(|row| match row[..] {
            [id, branch, remote, size, ..] => Some(InstalledApp {
                id: id.to_owned(),
                branch: branch.to_owned(),
                remote: remote.to_owned(),
                installed_size: parse_size(size),
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
    fail_next: Option<FlatpakError>,
    progress: Vec<u32>,
    ran: Vec<Operation>,
    added: Vec<(String, String)>,
}

impl Default for FakeFlatpak {
    fn default() -> Self {
        FakeFlatpak {
            state: Mutex::new(FakeState::default()),
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
        });
        self
    }

    pub fn with_installed(self, remote: &str, id: &str, size: u64) -> Self {
        self.state().installed.push(InstalledApp {
            id: id.to_owned(),
            branch: "stable".to_owned(),
            remote: remote.to_owned(),
            installed_size: size,
        });
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

    /// The percentages the next transactions report (a download that goes 10, 60, 100).
    pub fn with_progress(self, steps: &[u32]) -> Self {
        self.state().progress = steps.to_vec();
        self
    }

    /// The next transaction fails with this error (once).
    pub fn fail_next(&self, error: FlatpakError) {
        self.state().fail_next = Some(error);
    }

    pub fn ran(&self) -> Vec<Operation> {
        self.state().ran.clone()
    }

    pub fn added(&self) -> Vec<(String, String)> {
        self.state().added.clone()
    }
}

impl Flatpak for FakeFlatpak {
    fn remote_apps(&self) -> Result<Vec<RemoteApp>, String> {
        Ok(self.state().available.clone())
    }

    fn installed(&self) -> Result<Vec<InstalledApp>, String> {
        Ok(self.state().installed.clone())
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
