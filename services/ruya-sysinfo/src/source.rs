//! Where the text comes from: the running system, a directory standing in for it, or a dump of a
//! real machine (the tests).

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

/// Longest a command may take; a hung one is killed and counts as "not readable".
pub const COMMAND_TIMEOUT: Duration = Duration::from_secs(3);

/// Everything the collector reads. Paths are absolute, with `/`; every method answers `None`
/// (or an empty list) for what cannot be read, which is what keeps a value absent.
pub trait Source {
    fn read(&self, path: &str) -> Option<String>;
    fn read_bytes(&self, path: &str) -> Option<Vec<u8>>;
    /// The names inside a directory, sorted.
    fn list(&self, dir: &str) -> Vec<String>;
    fn exists(&self, path: &str) -> bool;
    /// The path with every symlink followed (`/sys/class/drm/card0/device` is the PCI device).
    fn resolve(&self, path: &str) -> Option<String>;
    /// Seconds since 1970 of the last change.
    fn modified(&self, path: &str) -> Option<u64>;
    /// The standard output of a command that exited successfully.
    fn run(&self, program: &str, args: &[&str]) -> Option<String>;

    /// The Bluetooth adapter the console uses, as its service (`ruya-devices`) picked it: its name
    /// (`hci1`) and its address, "" when not known. A source that does not know answers `None`
    /// and the collector takes the first adapter in sysfs (T-359).
    fn primary_bluetooth(&self) -> Option<(String, String)> {
        None
    }

    /// A file's text, trimmed; `None` when it is missing or empty.
    fn read_trim(&self, path: &str) -> Option<String> {
        let text = self.read(path)?;
        let text = text.trim();
        (!text.is_empty()).then(|| text.to_owned())
    }

    /// A file that holds one number.
    fn read_u64(&self, path: &str) -> Option<u64> {
        self.read_trim(path)?.parse().ok()
    }
}

/// The running system, or a directory that holds a copy of the part of it that matters (`root`).
pub struct RootSource {
    root: PathBuf,
    commands: bool,
}

impl RootSource {
    /// `/`, commands allowed.
    pub fn system() -> Self {
        RootSource {
            root: PathBuf::from("/"),
            commands: true,
        }
    }

    /// Files from under `root`; commands are not run.
    pub fn under(root: impl Into<PathBuf>) -> Self {
        RootSource {
            root: root.into(),
            commands: false,
        }
    }

    fn real(&self, path: &str) -> PathBuf {
        self.root.join(path.trim_start_matches('/'))
    }
}

impl Source for RootSource {
    fn read(&self, path: &str) -> Option<String> {
        let bytes = std::fs::read(self.real(path)).ok()?;
        Some(String::from_utf8_lossy(&bytes).into_owned())
    }

    fn read_bytes(&self, path: &str) -> Option<Vec<u8>> {
        std::fs::read(self.real(path)).ok()
    }

    fn list(&self, dir: &str) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(self.real(dir))
            .map(|entries| {
                entries
                    .filter_map(Result::ok)
                    .filter_map(|e| e.file_name().into_string().ok())
                    .collect()
            })
            .unwrap_or_default();
        names.sort();
        names
    }

    fn exists(&self, path: &str) -> bool {
        self.real(path).exists()
    }

    fn resolve(&self, path: &str) -> Option<String> {
        let found = std::fs::canonicalize(self.real(path)).ok()?;
        let root = std::fs::canonicalize(&self.root).ok()?;
        let inside = found.strip_prefix(&root).ok()?;
        let parts: Vec<String> = inside
            .components()
            .map(|c| c.as_os_str().to_string_lossy().into_owned())
            .collect();
        Some(format!("/{}", parts.join("/")))
    }

    fn modified(&self, path: &str) -> Option<u64> {
        let time = std::fs::metadata(self.real(path)).ok()?.modified().ok()?;
        Some(time.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs())
    }

    fn run(&self, program: &str, args: &[&str]) -> Option<String> {
        if !self.commands {
            return None;
        }
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let mut stdout = child.stdout.take()?;
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut out = Vec::new();
            let _ = stdout.read_to_end(&mut out);
            let _ = tx.send(out);
        });
        match rx.recv_timeout(COMMAND_TIMEOUT) {
            Ok(out) => {
                let ok = child.wait().is_ok_and(|s| s.success());
                ok.then(|| String::from_utf8_lossy(&out).into_owned())
            }
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                None
            }
        }
    }
}

/// A machine written down in a text: the tests' fixtures, and the service's `--session` fake.
///
/// ```text
/// == file /proc/meminfo          the lines up to the next "==" are the file
/// == bytes /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
/// 06 00 00 00 01                hex bytes
/// == link /sys/class/drm/card0/device /sys/devices/pci0000:00/0000:00:02.0
/// == mtime /etc/machine-id 1730000000
/// == dir /sys/class/nvme         an existing, empty directory
/// == cmd uname -r               the output of the command
/// ```
#[derive(Debug, Clone, Default)]
pub struct FakeSource {
    files: BTreeMap<String, Vec<u8>>,
    links: BTreeMap<String, String>,
    mtimes: BTreeMap<String, u64>,
    dirs: BTreeSet<String>,
    commands: BTreeMap<String, String>,
}

impl FakeSource {
    pub fn new() -> Self {
        FakeSource::default()
    }

    pub fn file(mut self, path: &str, text: &str) -> Self {
        self.files.insert(path.to_owned(), text.as_bytes().to_vec());
        self
    }

    pub fn link(mut self, path: &str, target: &str) -> Self {
        self.links.insert(path.to_owned(), target.to_owned());
        self
    }

    pub fn dir(mut self, path: &str) -> Self {
        self.dirs.insert(path.to_owned());
        self
    }

    pub fn command(mut self, line: &str, output: &str) -> Self {
        self.commands.insert(line.to_owned(), output.to_owned());
        self
    }

    pub fn mtime(mut self, path: &str, seconds: u64) -> Self {
        self.mtimes.insert(path.to_owned(), seconds);
        self
    }

    /// Takes a file away (a machine that lacks it).
    pub fn without(mut self, path: &str) -> Self {
        self.files.remove(path);
        self
    }

    /// Takes everything under a directory away.
    pub fn without_tree(mut self, dir: &str) -> Self {
        let prefix = format!("{}/", dir.trim_end_matches('/'));
        self.files.retain(|k, _| !k.starts_with(&prefix));
        self.links.retain(|k, _| !k.starts_with(&prefix));
        self.dirs.retain(|k| !k.starts_with(&prefix));
        self
    }

    /// Reads the dump format described above. A malformed line is skipped.
    pub fn from_dump(dump: &str) -> Self {
        enum Kind {
            File,
            Bytes,
            Cmd,
            None,
        }
        let mut out = FakeSource::new();
        let mut kind = Kind::None;
        let mut name = String::new();
        let mut body = String::new();
        let finish = |out: &mut FakeSource, kind: &Kind, name: &str, body: &str| match kind {
            Kind::File => {
                out.files.insert(name.to_owned(), body.as_bytes().to_vec());
            }
            Kind::Bytes => {
                let bytes = body
                    .split_whitespace()
                    .filter_map(|h| u8::from_str_radix(h, 16).ok())
                    .collect();
                out.files.insert(name.to_owned(), bytes);
            }
            Kind::Cmd => {
                out.commands.insert(name.to_owned(), body.to_owned());
            }
            Kind::None => {}
        };
        for line in dump.lines() {
            if let Some(head) = line.strip_prefix("== ") {
                finish(&mut out, &kind, &name, &body);
                body.clear();
                kind = Kind::None;
                let (word, rest) = head.split_once(' ').unwrap_or((head, ""));
                match word {
                    "file" => {
                        kind = Kind::File;
                        name = rest.trim().to_owned();
                    }
                    "bytes" => {
                        kind = Kind::Bytes;
                        name = rest.trim().to_owned();
                    }
                    "cmd" => {
                        kind = Kind::Cmd;
                        name = rest.trim().to_owned();
                    }
                    "link" => {
                        if let Some((from, to)) = rest.split_once(' ') {
                            out.links
                                .insert(from.trim().to_owned(), to.trim().to_owned());
                        }
                    }
                    "mtime" => {
                        if let Some((path, secs)) = rest.split_once(' ') {
                            if let Ok(secs) = secs.trim().parse() {
                                out.mtimes.insert(path.trim().to_owned(), secs);
                            }
                        }
                    }
                    "dir" => {
                        out.dirs.insert(rest.trim().to_owned());
                    }
                    _ => {}
                }
            } else if !matches!(kind, Kind::None) {
                body.push_str(line);
                body.push('\n');
            }
        }
        finish(&mut out, &kind, &name, &body);
        out
    }

    /// The path with every link followed, component by component.
    fn canonical(&self, path: &str) -> String {
        let mut current = path.to_owned();
        for _ in 0..16 {
            let mut changed = false;
            let mut prefix = String::new();
            let parts: Vec<&str> = current.split('/').filter(|p| !p.is_empty()).collect();
            for (i, part) in parts.iter().enumerate() {
                prefix.push('/');
                prefix.push_str(part);
                if let Some(target) = self.links.get(&prefix) {
                    let target = if target.starts_with('/') {
                        target.clone()
                    } else {
                        // Relative to the directory that holds the link.
                        let parent = prefix.rsplit_once('/').map_or("", |(p, _)| p);
                        normalise(&format!("{parent}/{target}"))
                    };
                    current = format!(
                        "{target}{}{}",
                        if i + 1 < parts.len() { "/" } else { "" },
                        parts[i + 1..].join("/")
                    );
                    changed = true;
                    break;
                }
            }
            if !changed {
                break;
            }
        }
        current
    }
}

/// `a/b/../c` -> `/a/c`.
fn normalise(path: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            p => out.push(p),
        }
    }
    format!("/{}", out.join("/"))
}

impl Source for FakeSource {
    fn read(&self, path: &str) -> Option<String> {
        let bytes = self.files.get(&self.canonical(path))?;
        Some(String::from_utf8_lossy(bytes).into_owned())
    }

    fn read_bytes(&self, path: &str) -> Option<Vec<u8>> {
        self.files.get(&self.canonical(path)).cloned()
    }

    fn list(&self, dir: &str) -> Vec<String> {
        let dir = self.canonical(dir);
        let prefix = format!("{}/", dir.trim_end_matches('/'));
        let mut names = BTreeSet::new();
        let paths = self
            .files
            .keys()
            .chain(self.links.keys())
            .chain(self.dirs.iter());
        for path in paths {
            if let Some(rest) = path.strip_prefix(&prefix) {
                if let Some(first) = rest.split('/').next() {
                    if !first.is_empty() {
                        names.insert(first.to_owned());
                    }
                }
            }
        }
        names.into_iter().collect()
    }

    fn exists(&self, path: &str) -> bool {
        let path = self.canonical(path);
        let prefix = format!("{}/", path.trim_end_matches('/'));
        self.files.contains_key(&path)
            || self.dirs.contains(&path)
            || self.files.keys().any(|k| k.starts_with(&prefix))
            || self.dirs.iter().any(|k| k.starts_with(&prefix))
            || self.links.keys().any(|k| k.starts_with(&prefix))
    }

    fn resolve(&self, path: &str) -> Option<String> {
        self.exists(path).then(|| self.canonical(path))
    }

    fn modified(&self, path: &str) -> Option<u64> {
        self.mtimes.get(&self.canonical(path)).copied()
    }

    fn run(&self, program: &str, args: &[&str]) -> Option<String> {
        let line = std::iter::once(program)
            .chain(args.iter().copied())
            .collect::<Vec<_>>()
            .join(" ");
        self.commands.get(&line).cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dump_files_links_and_commands() {
        let src = FakeSource::from_dump(
            "== file /proc/uptime\n1234.56 4000.00\n== link /sys/class/x/device /sys/devices/pci/0000:00:02.0\n== file /sys/devices/pci/0000:00:02.0/vendor\n0x8086\n== bytes /b\n06 00 01\n== cmd uname -r\n6.12.0\n== dir /sys/class/nvme\n",
        );
        assert_eq!(
            src.read_trim("/proc/uptime").as_deref(),
            Some("1234.56 4000.00")
        );
        assert_eq!(
            src.read_trim("/sys/class/x/device/vendor").as_deref(),
            Some("0x8086")
        );
        assert_eq!(
            src.resolve("/sys/class/x/device").as_deref(),
            Some("/sys/devices/pci/0000:00:02.0")
        );
        assert_eq!(src.read_bytes("/b"), Some(vec![6, 0, 1]));
        assert_eq!(src.run("uname", &["-r"]).as_deref(), Some("6.12.0\n"));
        assert!(src.exists("/sys/class/nvme"));
        assert!(src.list("/sys/class/nvme").is_empty());
        assert!(!src.exists("/sys/class/missing"));
    }

    #[test]
    fn relative_links_resolve_against_their_directory() {
        let src = FakeSource::new()
            .link("/a/b/c/lnk", "../../d")
            .dir("/a/d")
            .file("/a/d/x", "1");
        assert_eq!(src.resolve("/a/b/c/lnk").as_deref(), Some("/a/d"));
        assert_eq!(src.read_trim("/a/b/c/lnk/x").as_deref(), Some("1"));
    }

    #[test]
    fn root_source_reads_a_directory() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::create_dir_all(dir.path().join("proc")).expect("mkdir");
        std::fs::write(dir.path().join("proc/uptime"), "10.5 20.0\n").expect("write");
        let src = RootSource::under(dir.path());
        assert_eq!(src.read_trim("/proc/uptime").as_deref(), Some("10.5 20.0"));
        assert_eq!(src.list("/proc"), vec!["uptime".to_owned()]);
        assert!(src.read("/proc/missing").is_none());
        assert_eq!(src.resolve("/proc/uptime").as_deref(), Some("/proc/uptime"));
        assert!(
            src.run("uname", &["-r"]).is_none(),
            "commands are not run under a test root"
        );
    }
}
