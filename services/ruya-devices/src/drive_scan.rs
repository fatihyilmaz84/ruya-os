//! What RuyaOS recognises on a removable drive (org.ruyaos.Devices1.Storage.ScanVolume, T-331).
//!
//! A walk over a mounted removable volume that adds up allocated bytes per category (games,
//! backups, captures, ...) and the rest as "other". It only ever **reads names and sizes**: the
//! [`ScanSource`] trait offers `list(dir)` and `stat(path)` and nothing else, so no code that
//! walks a volume can open, read or run a file on it. That is the point: the drive is somebody
//! else's data, and nothing on it is trusted (root `CLAUDE.md`: nothing auto-runs from removable
//! media).
//!
//! The categories are **data**: [`CATEGORIES`] is the one table (key, folder convention, file
//! match). A row added there needs no other change in the service; the shell shows the keys it
//! knows and counts an unknown one with the rest. Folder names match without regard to case
//! (FAT keeps the case it was given, Windows does not care).
//!
//! The walk never follows a symlink, never enters a directory on another device (another mount),
//! counts a hard-linked file once, counts allocated blocks like `sysusage.rs`, and stops at
//! [`Limits`]: depth 6, 200 000 entries, 10 s of wall clock (a fake clock in the tests). A bound
//! that was hit, a directory that could not be read, a name that is not UTF-8 and a cancel all
//! make the result `partial` (the numbers are then "at least"). The walk uses an explicit stack
//! (a deep tree cannot overflow the thread's) and checks the cancel flag at every directory and
//! every [`CHECK_EVERY`] entries.
//!
//! [`Scans`] is the state around it: one scan at a time, the result cached per volume until the
//! volume changes or leaves, run on the blocking pool by the D-Bus adapter.

use std::collections::{HashMap, HashSet};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use crate::storage::Volume;
use crate::sysusage::Clock;

/// Directory levels below the mount point that are listed (the mount point is level 0).
pub const MAX_DEPTH: usize = 6;
/// Entries (files and directories) looked at in one scan.
pub const MAX_ENTRIES: usize = 200_000;
/// Wall clock for one scan.
pub const MAX_TIME: Duration = Duration::from_secs(10);
/// The cancel flag and the clock are looked at this often inside one big directory.
pub const CHECK_EVERY: usize = 64;

/// The bounds of one scan.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    pub depth: usize,
    pub entries: usize,
    pub time: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            depth: MAX_DEPTH,
            entries: MAX_ENTRIES,
            time: MAX_TIME,
        }
    }
}

/// How a file name is matched. Case does not matter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NameMatch {
    pub prefix: &'static str,
    pub suffix: &'static str,
    /// Only files at most this many levels down count: 1 is the root of the drive, 2 also a
    /// folder directly in it.
    pub max_level: usize,
}

/// One row of the category table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Category {
    /// The key of the contract (`GetVolumeScan`), the shell's name for it.
    pub key: &'static str,
    /// Folders (as paths from the root of the drive) whose whole content belongs here.
    pub folders: &'static [&'static [&'static str]],
    /// Files that belong here wherever they are (within their level). A folder rule of any
    /// category is stronger than a file rule.
    pub files: &'static [NameMatch],
}

/// The category table. First match wins, folders before file names. Adding a row needs no other
/// change; `03` section 2.2 shows the same table.
pub const CATEGORIES: &[Category] = &[
    // T-303 may rename the ROM folder: change it here.
    Category {
        key: "games",
        folders: &[&["RuyaOS", "ROMs"]],
        files: &[],
    },
    // T-215.
    Category {
        key: "backups",
        folders: &[&["RuyaOS-Backups"]],
        files: &[],
    },
    // T-305.
    Category {
        key: "captures",
        folders: &[&["RuyaOS", "Captures"]],
        files: &[],
    },
    // T-236: `*.play` in the top two levels.
    Category {
        key: "packages",
        folders: &[],
        files: &[NameMatch {
            prefix: "",
            suffix: ".play",
            max_level: 2,
        }],
    },
    // T-208 reads images from any drive.
    Category {
        key: "pictures",
        folders: &[&["Wallpapers"], &["Pictures"]],
        files: &[],
    },
    // T-226.
    Category {
        key: "reports",
        folders: &[],
        files: &[NameMatch {
            prefix: "RuyaOS-system-report.",
            suffix: "",
            max_level: 1,
        }],
    },
];

fn same(a: &str, b: &str) -> bool {
    a.eq_ignore_ascii_case(b)
}

fn name_matches(rule: &NameMatch, name: &str, level: usize) -> bool {
    // `get` on bytes: a name with a multi-byte character at the cut simply does not match.
    let starts = name
        .get(..rule.prefix.len())
        .is_some_and(|p| same(p, rule.prefix));
    let ends = name.len() >= rule.suffix.len()
        && name
            .get(name.len() - rule.suffix.len()..)
            .is_some_and(|s| same(s, rule.suffix));
    level <= rule.max_level && name.len() >= rule.prefix.len() + rule.suffix.len() && starts && ends
}

/// The index in `table` of the category an entry belongs to. `rel` is the path from the root of
/// the drive, the entry's own name last.
pub fn classify_in(table: &[Category], rel: &[&str], is_dir: bool) -> Option<usize> {
    let by_folder = table.iter().position(|c| {
        c.folders
            .iter()
            .any(|f| rel.len() >= f.len() && f.iter().zip(rel).all(|(a, b)| same(a, b)))
    });
    if by_folder.is_some() {
        return by_folder;
    }
    if is_dir {
        return None;
    }
    let name = rel.last()?;
    table
        .iter()
        .position(|c| c.files.iter().any(|m| name_matches(m, name, rel.len())))
}

/// [`classify_in`] over [`CATEGORIES`].
pub fn classify(rel: &[&str], is_dir: bool) -> Option<usize> {
    classify_in(CATEGORIES, rel, is_dir)
}

// ---- the source -------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    File,
    Dir,
    Symlink,
    /// A device node, a socket, a fifo: counted, never opened.
    Other,
}

/// What `stat` (no symlink followed) says about an entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Meta {
    pub kind: Kind,
    /// Allocated bytes (`st_blocks * 512`).
    pub bytes: u64,
    /// The device and inode: a directory on another device is another mount, a file with more
    /// than one link counts once.
    pub dev: u64,
    pub ino: u64,
    pub links: u64,
}

/// The names in a directory. `skipped` counts those that cannot be represented (not UTF-8).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Listing {
    pub names: Vec<String>,
    pub skipped: usize,
}

/// What the walk reads from. **Only names and sizes**: there is no method that opens or reads a
/// file, so nothing that walks a volume can. Adding one needs a decision, not a drive-by.
pub trait ScanSource: Send + Sync {
    /// The entries of a directory (not `.` and `..`).
    fn list(&self, dir: &str) -> Result<Listing, String>;
    /// `lstat`: the entry itself, a symlink is not followed.
    fn stat(&self, path: &str) -> Result<Meta, String>;
}

impl<T: ScanSource + ?Sized> ScanSource for Box<T> {
    fn list(&self, dir: &str) -> Result<Listing, String> {
        (**self).list(dir)
    }
    fn stat(&self, path: &str) -> Result<Meta, String> {
        (**self).stat(path)
    }
}

// ---- the walk ---------------------------------------------------------------------------------

/// Bytes and files of one category.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Total {
    pub key: &'static str,
    pub bytes: u64,
    pub files: u64,
}

/// The result of a walk.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Scan {
    /// The numbers are at least this much: a bound was hit, something could not be read, or the
    /// walk was cancelled.
    pub partial: bool,
    pub cancelled: bool,
    /// Everything counted: the categories plus `other_bytes`.
    pub used_bytes: u64,
    /// Only categories with at least one entry, largest first (ties in table order).
    pub categories: Vec<Total>,
    pub other_bytes: u64,
}

/// A name for the log: control characters and bidi marks become `?`, and it is cut short. A name
/// on a drive is somebody else's text.
pub fn printable(name: &str) -> String {
    let mut out = String::new();
    for (i, c) in name.chars().enumerate() {
        if i >= 48 {
            out.push_str("...");
            break;
        }
        let bad = c.is_control()
            || matches!(c, '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{FEFF}');
        out.push(if bad { '?' } else { c });
    }
    out
}

struct Dir {
    path: String,
    rel: Vec<String>,
}

fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        format!("{dir}{name}")
    } else {
        format!("{dir}/{name}")
    }
}

/// Walks the tree under `root`. The only error is a root that cannot be read at all.
pub fn scan<S: ScanSource, C: Clock>(
    source: &S,
    clock: &C,
    root: &str,
    limits: &Limits,
    cancel: &AtomicBool,
) -> Result<Scan, String> {
    scan_with(source, clock, root, limits, cancel, CATEGORIES)
}

pub fn scan_with<S: ScanSource, C: Clock>(
    source: &S,
    clock: &C,
    root: &str,
    limits: &Limits,
    cancel: &AtomicBool,
    table: &[Category],
) -> Result<Scan, String> {
    let started = clock.now();
    let root_meta = source.stat(root)?;
    if root_meta.kind != Kind::Dir {
        return Err("the mount point is not a directory".to_owned());
    }
    let mut bytes = vec![0u64; table.len()];
    let mut files = vec![0u64; table.len()];
    let mut other = root_meta.bytes;
    let mut partial = false;
    let mut cancelled = false;
    let mut entries = 0usize;
    let mut logged = false;
    let mut seen: HashSet<(u64, u64)> = HashSet::new();
    let mut pending = vec![Dir {
        path: root.to_owned(),
        rel: Vec::new(),
    }];
    let stopped = |cancelled: &mut bool, partial: &mut bool| {
        if cancel.load(Ordering::Relaxed) {
            *cancelled = true;
            *partial = true;
            return true;
        }
        if clock.now().saturating_sub(started) >= limits.time {
            *partial = true;
            return true;
        }
        false
    };
    'dirs: while let Some(dir) = pending.pop() {
        if stopped(&mut cancelled, &mut partial) {
            break;
        }
        let listing = match source.list(&dir.path) {
            Ok(listing) => listing,
            // The root itself is the one failure that is an error.
            Err(err) if dir.rel.is_empty() => return Err(err),
            Err(err) => {
                partial = true;
                if !logged {
                    logged = true;
                    let leaf = dir.rel.last().map(|n| printable(n)).unwrap_or_default();
                    eprintln!("ruya-devices: drive scan: cannot read a directory ({leaf}): {err}");
                }
                continue;
            }
        };
        if listing.skipped > 0 {
            partial = true;
        }
        for name in &listing.names {
            if entries >= limits.entries {
                partial = true;
                break 'dirs;
            }
            entries += 1;
            if entries % CHECK_EVERY == 0 && stopped(&mut cancelled, &mut partial) {
                break 'dirs;
            }
            let path = join(&dir.path, name);
            let Ok(meta) = source.stat(&path) else {
                partial = true;
                continue;
            };
            let mut rel: Vec<&str> = dir.rel.iter().map(String::as_str).collect();
            rel.push(name);
            let is_dir = meta.kind == Kind::Dir;
            if is_dir && meta.dev != root_meta.dev {
                // Another mount is not this drive's content.
                continue;
            }
            if !is_dir && meta.links > 1 && !seen.insert((meta.dev, meta.ino)) {
                continue;
            }
            match classify_in(table, &rel, is_dir) {
                Some(i) => {
                    bytes[i] = bytes[i].saturating_add(meta.bytes);
                    if !is_dir {
                        files[i] += 1;
                    }
                }
                None => other = other.saturating_add(meta.bytes),
            }
            if is_dir {
                if dir.rel.len() >= limits.depth {
                    // Not listed: what is below is unknown.
                    partial = true;
                } else {
                    let mut below = dir.rel.clone();
                    below.push(name.clone());
                    pending.push(Dir { path, rel: below });
                }
            }
        }
    }
    let mut categories: Vec<Total> = table
        .iter()
        .enumerate()
        .filter(|(i, _)| bytes[*i] > 0 || files[*i] > 0)
        .map(|(i, c)| Total {
            key: c.key,
            bytes: bytes[i],
            files: files[i],
        })
        .collect();
    // Stable: ties stay in table order.
    categories.sort_by_key(|t| std::cmp::Reverse(t.bytes));
    let used = categories
        .iter()
        .fold(other, |sum, t| sum.saturating_add(t.bytes));
    Ok(Scan {
        partial,
        cancelled,
        used_bytes: used,
        categories,
        other_bytes: other,
    })
}

// ---- the real source --------------------------------------------------------------------------

/// `read_dir` and `symlink_metadata`.
pub struct FsSource;

#[cfg(unix)]
fn meta_of(m: &std::fs::Metadata) -> (u64, u64, u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (m.blocks().saturating_mul(512), m.dev(), m.ino(), m.nlink())
}

#[cfg(not(unix))]
fn meta_of(m: &std::fs::Metadata) -> (u64, u64, u64, u64) {
    // No inodes here: the apparent size, no hard-link or mount handling (development hosts only).
    (m.len(), 0, 0, 1)
}

impl ScanSource for FsSource {
    fn list(&self, dir: &str) -> Result<Listing, String> {
        let mut listing = Listing::default();
        for entry in std::fs::read_dir(dir).map_err(|e| e.to_string())? {
            match entry {
                Ok(entry) => match entry.file_name().into_string() {
                    Ok(name) => listing.names.push(name),
                    Err(_) => listing.skipped += 1,
                },
                Err(_) => listing.skipped += 1,
            }
        }
        Ok(listing)
    }

    fn stat(&self, path: &str) -> Result<Meta, String> {
        let m = std::fs::symlink_metadata(path).map_err(|e| e.to_string())?;
        let (bytes, dev, ino, links) = meta_of(&m);
        let kind = if m.is_dir() {
            Kind::Dir
        } else if m.file_type().is_symlink() {
            Kind::Symlink
        } else if m.is_file() {
            Kind::File
        } else {
            Kind::Other
        };
        Ok(Meta {
            kind,
            bytes,
            dev,
            ino,
            links,
        })
    }
}

// ---- the scripted source ----------------------------------------------------------------------

type ListHook = Box<dyn Fn(&str) + Send + Sync>;

enum FakeNode {
    Dir { names: Vec<String>, readable: bool },
    Entry,
}

struct FakeInner {
    nodes: HashMap<String, (FakeNode, Meta)>,
    skipped: HashMap<String, usize>,
    lists: Vec<String>,
    stats: usize,
}

/// An in-memory tree for the tests and for `--session` development. Paths are written relative
/// to the root given to [`FakeTree::new`].
pub struct FakeTree {
    root: String,
    inner: Mutex<FakeInner>,
    on_list: Mutex<Option<ListHook>>,
}

const DIR_BYTES: u64 = 4096;

impl FakeTree {
    pub fn new(root: &str) -> Self {
        let tree = FakeTree {
            root: root.to_owned(),
            inner: Mutex::new(FakeInner {
                nodes: HashMap::new(),
                skipped: HashMap::new(),
                lists: Vec::new(),
                stats: 0,
            }),
            on_list: Mutex::new(None),
        };
        tree.inner().nodes.insert(
            root.to_owned(),
            (
                FakeNode::Dir {
                    names: Vec::new(),
                    readable: true,
                },
                Self::meta(Kind::Dir, DIR_BYTES, 1, 1),
            ),
        );
        tree
    }

    fn inner(&self) -> MutexGuard<'_, FakeInner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn meta(kind: Kind, bytes: u64, dev: u64, ino: u64) -> Meta {
        Meta {
            kind,
            bytes,
            dev,
            ino,
            links: 1,
        }
    }

    fn insert(self, rel: &str, node: FakeNode, meta: Meta) -> Self {
        {
            let mut payload = Some((node, meta));
            let mut inner = self.inner();
            let mut dir = self.root.clone();
            let parts: Vec<&str> = rel.split('/').collect();
            for (i, part) in parts.iter().enumerate() {
                let path = join(&dir, part);
                let last = i + 1 == parts.len();
                if !inner.nodes.contains_key(&path) {
                    if let Some((FakeNode::Dir { names, .. }, _)) = inner.nodes.get_mut(&dir) {
                        names.push((*part).to_owned());
                    }
                    let leaf = if last { payload.take() } else { None };
                    let (n, m) = if let Some(p) = leaf {
                        p
                    } else {
                        (
                            FakeNode::Dir {
                                names: Vec::new(),
                                readable: true,
                            },
                            Self::meta(Kind::Dir, DIR_BYTES, 1, 1),
                        )
                    };
                    inner.nodes.insert(path.clone(), (n, m));
                    if last {
                        break;
                    }
                } else if last {
                    break;
                }
                dir = path;
            }
        }
        self
    }

    /// A directory (its parents are made on the way), `DIR_BYTES` of its own.
    pub fn dir(self, rel: &str) -> Self {
        self.insert(
            rel,
            FakeNode::Dir {
                names: Vec::new(),
                readable: true,
            },
            Self::meta(Kind::Dir, DIR_BYTES, 1, 1),
        )
    }

    /// A file of `bytes` allocated bytes.
    pub fn file(self, rel: &str, bytes: u64) -> Self {
        let ino = 100 + self.inner().nodes.len() as u64;
        self.insert(rel, FakeNode::Entry, Self::meta(Kind::File, bytes, 1, ino))
    }

    /// A symlink; the tree has nothing behind it, so a walk that follows it would find nothing
    /// (the tests give it a target of its own to prove it is not followed).
    pub fn link(self, rel: &str) -> Self {
        self.insert(rel, FakeNode::Entry, Self::meta(Kind::Symlink, 0, 1, 1))
    }

    /// A directory on another device (another mount), with a file inside that must not be seen.
    pub fn mount(self, rel: &str) -> Self {
        let inside = format!("{rel}/inside.bin");
        let tree = self.insert(
            rel,
            FakeNode::Dir {
                names: Vec::new(),
                readable: true,
            },
            Self::meta(Kind::Dir, DIR_BYTES, 2, 1),
        );
        let mut meta = Self::meta(Kind::File, 777_000_000, 2, 5);
        meta.links = 1;
        tree.insert(&inside, FakeNode::Entry, meta)
    }

    /// A directory that lists with an error.
    pub fn unreadable(self, rel: &str) -> Self {
        self.insert(
            rel,
            FakeNode::Dir {
                names: Vec::new(),
                readable: false,
            },
            Self::meta(Kind::Dir, DIR_BYTES, 1, 1),
        )
    }

    /// `n` more entries in `rel` whose names are not UTF-8.
    pub fn skipped(self, rel: &str, n: usize) -> Self {
        let path = if rel.is_empty() {
            self.root.clone()
        } else {
            join(&self.root, rel)
        };
        self.inner().skipped.insert(path, n);
        self
    }

    /// A file with `links` links to one inode (two paths share `ino`).
    pub fn hard_linked(self, rel: &str, bytes: u64, ino: u64, links: u64) -> Self {
        let mut meta = Self::meta(Kind::File, bytes, 1, ino);
        meta.links = links;
        self.insert(rel, FakeNode::Entry, meta)
    }

    /// Called with the directory at the start of every `list`.
    pub fn on_list(self, hook: impl Fn(&str) + Send + Sync + 'static) -> Self {
        *self.on_list.lock().unwrap_or_else(|e| e.into_inner()) = Some(Box::new(hook));
        self
    }

    /// The directories listed so far, in order.
    pub fn lists(&self) -> Vec<String> {
        self.inner().lists.clone()
    }

    pub fn stats(&self) -> usize {
        self.inner().stats
    }

    /// A 16 GB exFAT stick as `--session` shows it: ROMs, backups, captures, a package, a report
    /// and some personal files.
    pub fn dev_stick(root: &str) -> Self {
        const MB: u64 = 1_000_000;
        FakeTree::new(root)
            .file("RuyaOS/ROMs/snes/collection.bin", 12_000 * MB)
            .file("RuyaOS-Backups/player-one/2026-11-01.tar.zst", 2_000 * MB)
            .file("RuyaOS/Captures/clip-001.mp4", 640 * MB)
            .file("RuyaOS/Captures/shot-001.png", 3 * MB)
            .file("Wallpapers/aurora.jpg", 4 * MB)
            .file("Holiday/video.mkv", 900 * MB)
            .file("notes.txt", 1)
    }
}

impl ScanSource for FakeTree {
    fn list(&self, dir: &str) -> Result<Listing, String> {
        if let Some(hook) = self
            .on_list
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
        {
            hook(dir);
        }
        let mut inner = self.inner();
        inner.lists.push(dir.to_owned());
        let skipped = inner.skipped.get(dir).copied().unwrap_or(0);
        match inner.nodes.get(dir) {
            Some((FakeNode::Dir { names, readable }, _)) if *readable => Ok(Listing {
                names: names.clone(),
                skipped,
            }),
            Some((FakeNode::Dir { .. }, _)) => Err("Permission denied (os error 13)".to_owned()),
            _ => Err("No such file or directory (os error 2)".to_owned()),
        }
    }

    fn stat(&self, path: &str) -> Result<Meta, String> {
        let mut inner = self.inner();
        inner.stats += 1;
        inner
            .nodes
            .get(path)
            .map(|(_, m)| *m)
            .ok_or_else(|| "No such file or directory (os error 2)".to_owned())
    }
}

// ---- the state around the walk ----------------------------------------------------------------

/// The contract's states.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Idle,
    Running,
    Done,
    Cancelled,
    Failed,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Idle => "idle",
            State::Running => "running",
            State::Done => "done",
            State::Cancelled => "cancelled",
            State::Failed => "failed",
        }
    }
}

/// The status strings of `ScanVolume`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    UnknownVolume,
    Unsupported,
    Busy,
    Invalid,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::UnknownVolume => "unknown-volume",
            Status::Unsupported => "unsupported",
            Status::Busy => "busy",
            Status::Invalid => "invalid",
            Status::Failed => "failed",
        }
    }
}

/// `GetVolumeScan`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VolumeScan {
    pub state: State,
    pub scan: Scan,
}

/// What `request` decided.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Begin {
    /// A fresh result is cached, or this volume is being scanned already: nothing to start.
    Nothing,
    /// The caller must call [`Scans::run`] with this, on the blocking pool.
    Run(Job),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Job {
    pub id: String,
    pub root: String,
    token: u64,
}

/// What a result is valid for: if any of this changes, the volume is not the one that was
/// scanned.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Fingerprint {
    mount_point: String,
    size_bytes: i64,
    free_bytes: i64,
    read_only: bool,
}

impl Fingerprint {
    fn of(v: &Volume) -> Self {
        Fingerprint {
            mount_point: v.mount_point.clone(),
            size_bytes: v.size_bytes,
            free_bytes: v.free_bytes,
            read_only: v.read_only,
        }
    }
}

struct Entry {
    fingerprint: Fingerprint,
    token: u64,
    state: State,
    scan: Scan,
    cancel: Arc<AtomicBool>,
}

#[derive(Default)]
struct Inner {
    entries: HashMap<String, Entry>,
    /// The volume whose walk is on a thread right now (also when its entry was dropped and the
    /// walk is winding down).
    running: Option<String>,
    next_token: u64,
}

pub struct Scans<S: ScanSource, C: Clock> {
    source: S,
    clock: C,
    limits: Limits,
    inner: Mutex<Inner>,
}

impl<S: ScanSource, C: Clock> Scans<S, C> {
    pub fn new(source: S, clock: C) -> Self {
        Self::with_limits(source, clock, Limits::default())
    }

    pub fn with_limits(source: S, clock: C, limits: Limits) -> Self {
        Scans {
            source,
            clock,
            limits,
            inner: Mutex::new(Inner::default()),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        // A poisoned lock only means another call panicked; the state is plain data.
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Drops what no longer matches the list of volumes: a volume that left, or whose mount
    /// point, size, free space or read-only flag changed (`VolumesChanged`). A walk of such a
    /// volume is told to stop and its result is discarded.
    fn sync(inner: &mut Inner, volumes: &[Volume]) {
        inner.entries.retain(|id, entry| {
            let keep = volumes
                .iter()
                .any(|v| &v.id == id && Fingerprint::of(v) == entry.fingerprint);
            if !keep {
                entry.cancel.store(true, Ordering::Relaxed);
            }
            keep
        });
    }

    /// Decides what `ScanVolume` does. Cheap: no walking here.
    pub fn request(&self, volumes: &[Volume], id: &str) -> Result<Begin, Status> {
        if id.is_empty() {
            return Err(Status::Invalid);
        }
        let volume = volumes
            .iter()
            .find(|v| v.id == id)
            .ok_or(Status::UnknownVolume)?;
        if !volume.removable || !volume.mounted || volume.mount_point.is_empty() {
            return Err(Status::Unsupported);
        }
        let mut inner = self.lock();
        Self::sync(&mut inner, volumes);
        match inner.entries.get(id).map(|e| e.state) {
            Some(State::Running | State::Done) => return Ok(Begin::Nothing),
            // Not a fresh result: walk again.
            Some(_) => {
                inner.entries.remove(id);
            }
            None => {}
        }
        if inner.running.is_some() {
            return Err(Status::Busy);
        }
        inner.next_token += 1;
        let token = inner.next_token;
        inner.running = Some(id.to_owned());
        inner.entries.insert(
            id.to_owned(),
            Entry {
                fingerprint: Fingerprint::of(volume),
                token,
                state: State::Running,
                scan: Scan::default(),
                cancel: Arc::new(AtomicBool::new(false)),
            },
        );
        Ok(Begin::Run(Job {
            id: id.to_owned(),
            root: volume.mount_point.clone(),
            token,
        }))
    }

    /// The walk. Blocks: call it on the blocking pool. Returns whether the volume's result
    /// changed (the adapter then sends `VolumeScanChanged`); `false` when the volume changed
    /// or left meanwhile and the result was thrown away.
    pub fn run(&self, job: &Job) -> bool {
        let cancel = {
            let mut inner = self.lock();
            match inner.entries.get(&job.id) {
                Some(e) if e.token == job.token => e.cancel.clone(),
                _ => {
                    // The volume changed or left before the walk began: nothing to walk.
                    if inner.running.as_deref() == Some(job.id.as_str()) {
                        inner.running = None;
                    }
                    return false;
                }
            }
        };
        // A source that panics must not leave the scanner stuck on "running".
        let result = catch_unwind(AssertUnwindSafe(|| {
            scan(&self.source, &self.clock, &job.root, &self.limits, &cancel)
        }));
        let mut inner = self.lock();
        if inner.running.as_deref() == Some(job.id.as_str()) {
            inner.running = None;
        }
        let Some(entry) = inner.entries.get_mut(&job.id) else {
            return false;
        };
        if entry.token != job.token {
            return false;
        }
        match result {
            Ok(Ok(scan)) => {
                entry.state = if scan.cancelled {
                    State::Cancelled
                } else {
                    State::Done
                };
                entry.scan = scan;
            }
            Ok(Err(err)) => {
                eprintln!("ruya-devices: drive scan failed: {err}");
                entry.state = State::Failed;
                entry.scan = Scan::default();
            }
            Err(_) => {
                eprintln!("ruya-devices: drive scan failed unexpectedly");
                entry.state = State::Failed;
                entry.scan = Scan::default();
            }
        }
        true
    }

    /// `GetVolumeScan`: never starts or waits for a walk.
    pub fn get(&self, volumes: &[Volume], id: &str) -> VolumeScan {
        let mut inner = self.lock();
        Self::sync(&mut inner, volumes);
        match inner.entries.get(id) {
            Some(e) => VolumeScan {
                state: e.state,
                scan: if e.state == State::Running {
                    Scan::default()
                } else {
                    e.scan.clone()
                },
            },
            None => VolumeScan {
                state: State::Idle,
                scan: Scan::default(),
            },
        }
    }

    /// `CancelScan`: the walk stops within one directory. Nothing happens if this volume is not
    /// being scanned.
    pub fn cancel(&self, id: &str) {
        if let Some(e) = self.lock().entries.get(id) {
            if e.state == State::Running {
                e.cancel.store(true, Ordering::Relaxed);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sysusage::FakeClock;

    const MB: u64 = 1_000_000;

    fn run(tree: &FakeTree) -> Scan {
        scan_at(tree, Limits::default())
    }

    fn scan_at(tree: &FakeTree, limits: Limits) -> Scan {
        let clock = FakeClock::default();
        scan(tree, &clock, "/m", &limits, &AtomicBool::new(false)).expect("the root is readable")
    }

    fn bytes_of(scan: &Scan, key: &str) -> Option<u64> {
        scan.categories
            .iter()
            .find(|t| t.key == key)
            .map(|t| t.bytes)
    }

    #[test]
    fn every_table_row_maps_its_folder_or_match_to_its_key() {
        let tree = FakeTree::new("/m")
            .file("RuyaOS/ROMs/snes/a.bin", 3 * MB)
            .file("RuyaOS-Backups/p/b.tar.zst", 2 * MB)
            .file("RuyaOS/Captures/c.mp4", 5 * MB)
            .file("game.play", 7 * MB)
            .file("Wallpapers/w.jpg", 11 * MB)
            .file("Pictures/deep/p.jpg", 13 * MB)
            .file("RuyaOS-system-report.txt", 17 * MB)
            .file("RuyaOS-system-report.json", 19 * MB);
        let scan = run(&tree);
        assert_eq!(bytes_of(&scan, "games"), Some(3 * MB + 2 * DIR_BYTES));
        // Directories belong to the folder they are in: ROMs/ and snes/ (RuyaOS/ itself is
        // "other"), so the folders' own blocks are in the category too.
        assert!(bytes_of(&scan, "backups").unwrap() >= 2 * MB);
        assert!(bytes_of(&scan, "captures").unwrap() >= 5 * MB);
        assert_eq!(bytes_of(&scan, "packages"), Some(7 * MB));
        assert!(bytes_of(&scan, "pictures").unwrap() >= 24 * MB);
        assert_eq!(bytes_of(&scan, "reports"), Some(36 * MB));
        let keys: Vec<&str> = scan.categories.iter().map(|t| t.key).collect();
        for row in CATEGORIES {
            assert!(keys.contains(&row.key), "{} has no entry", row.key);
        }
        assert!(!scan.partial);
    }

    #[test]
    fn classify_follows_the_table_and_ignores_case() {
        let key = |rel: &[&str], dir| classify(rel, dir).map(|i| CATEGORIES[i].key);
        assert_eq!(key(&["RuyaOS", "ROMs", "x.sfc"], false), Some("games"));
        assert_eq!(key(&["ruyaos", "roms"], true), Some("games"));
        assert_eq!(key(&["RuyaOS"], true), None);
        assert_eq!(key(&["RuyaOS", "other.bin"], false), None);
        assert_eq!(key(&["RuyaOS", "Captures", "a"], false), Some("captures"));
        assert_eq!(key(&["X.PLAY"], false), Some("packages"));
        assert_eq!(key(&["Folder", "x.play"], false), Some("packages"));
        // Level 3 is too deep for a package; a directory is never a package.
        assert_eq!(key(&["A", "B", "x.play"], false), None);
        assert_eq!(key(&["x.play"], true), None);
        // A folder rule beats a file rule.
        assert_eq!(key(&["Pictures", "x.play"], false), Some("pictures"));
        assert_eq!(key(&["RuyaOS-system-report.txt"], false), Some("reports"));
        assert_eq!(key(&["Sub", "RuyaOS-system-report.txt"], false), None);
        // The prefix alone is not the file (and a cut inside a character does not panic).
        assert_eq!(key(&["RuyaOS-system-report."], false), Some("reports"));
        assert_eq!(key(&["\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}"], false), None);
    }

    #[test]
    fn a_new_table_row_needs_no_other_change() {
        const EXTRA: &[Category] = &[Category {
            key: "saves",
            folders: &[&["Saves"]],
            files: &[],
        }];
        let tree = FakeTree::new("/m")
            .file("Saves/a.sav", 9 * MB)
            .file("b", MB);
        let clock = FakeClock::default();
        let scan = scan_with(
            &tree,
            &clock,
            "/m",
            &Limits::default(),
            &AtomicBool::new(false),
            EXTRA,
        )
        .unwrap();
        assert_eq!(scan.categories.len(), 1);
        assert_eq!(scan.categories[0].key, "saves");
        assert_eq!(scan.categories[0].files, 1);
    }

    #[test]
    fn the_rest_is_other_and_the_parts_add_up_to_used() {
        let tree = FakeTree::new("/m")
            .file("RuyaOS/ROMs/a.bin", 3 * MB)
            .file("RuyaOS-Backups/b", 2 * MB)
            .file("stray.bin", MB)
            .file("Holiday/video.mkv", 40 * MB);
        let scan = run(&tree);
        let parts: u64 = scan.categories.iter().map(|t| t.bytes).sum();
        assert_eq!(scan.used_bytes, parts + scan.other_bytes);
        // The root, RuyaOS/, Holiday/ (directories) plus the two loose files.
        assert_eq!(scan.other_bytes, 3 * DIR_BYTES + MB + 40 * MB);
        assert_eq!(scan.used_bytes, scan.other_bytes + parts);
        // Largest first.
        let sizes: Vec<u64> = scan.categories.iter().map(|t| t.bytes).collect();
        assert!(sizes.windows(2).all(|w| w[0] >= w[1]));
        // Files are counted, directories are not.
        assert_eq!(
            scan.categories
                .iter()
                .find(|t| t.key == "games")
                .map(|t| t.files),
            Some(1)
        );
    }

    #[test]
    fn an_empty_drive_has_no_categories() {
        let scan = run(&FakeTree::new("/m"));
        assert!(scan.categories.is_empty());
        assert_eq!(scan.used_bytes, DIR_BYTES);
        assert_eq!(scan.other_bytes, DIR_BYTES);
        assert!(!scan.partial);
    }

    #[test]
    fn the_depth_bound_gives_partial() {
        // Directories a/b/c/d/e/f/g: the one at level 7 is never listed.
        let tree = FakeTree::new("/m").file("a/b/c/d/e/f/g/h/deep.bin", MB);
        let scan = run(&tree);
        assert!(scan.partial);
        assert!(scan.used_bytes < MB, "the deep file must not be counted");
        // Within the bound is complete.
        let shallow = FakeTree::new("/m").file("a/b/c/d/e/f/ok.bin", MB);
        let scan = run(&shallow);
        assert!(!scan.partial);
        assert!(scan.used_bytes >= MB);
    }

    #[test]
    fn the_entry_bound_gives_partial() {
        let mut tree = FakeTree::new("/m");
        for i in 0..10 {
            tree = tree.file(&format!("f{i}"), MB);
        }
        let limits = Limits {
            entries: 5,
            ..Limits::default()
        };
        let scan = scan_at(&tree, limits);
        assert!(scan.partial);
        assert!(scan.used_bytes <= 5 * MB + DIR_BYTES);
        let all = scan_at(
            &tree,
            Limits {
                entries: 10,
                ..Limits::default()
            },
        );
        assert!(!all.partial);
        assert_eq!(all.used_bytes, 10 * MB + DIR_BYTES);
    }

    #[test]
    fn the_clock_bound_gives_partial() {
        let clock = Arc::new(FakeClock::default());
        let ticking = clock.clone();
        // Every directory takes 4 s: the third one is past 10 s.
        let tree = FakeTree::new("/m")
            .file("a/x", MB)
            .file("b/x", MB)
            .file("c/x", MB)
            .on_list(move |_| ticking.advance(Duration::from_secs(4)));
        let scan = scan(
            &tree,
            &clock,
            "/m",
            &Limits::default(),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert!(scan.partial);
        assert!(!scan.cancelled);
        assert!(tree.lists().len() < 4, "{:?}", tree.lists());
        // A fast walk is complete.
        let quiet = FakeClock::default();
        let tree = FakeTree::new("/m").file("a/x", MB);
        let scan = super::scan(
            &tree,
            &quiet,
            "/m",
            &Limits::default(),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert!(!scan.partial);
    }

    #[test]
    fn a_symlink_and_another_mount_are_not_followed() {
        let tree = FakeTree::new("/m")
            .file("RuyaOS/ROMs/a.bin", 3 * MB)
            .link("shortcut")
            .mount("usb-inside");
        let scan = run(&tree);
        assert!(!scan.partial);
        // The mounted directory's 777 MB file is not there.
        assert!(scan.used_bytes < 10 * MB, "{}", scan.used_bytes);
        assert!(
            !tree.lists().iter().any(|d| d.ends_with("usb-inside")),
            "entered another mount: {:?}",
            tree.lists()
        );
        assert!(
            !tree.lists().iter().any(|d| d.ends_with("shortcut")),
            "followed a symlink"
        );
    }

    #[test]
    fn a_hard_linked_file_counts_once() {
        let tree = FakeTree::new("/m")
            .hard_linked("a.bin", 5 * MB, 42, 2)
            .hard_linked("b.bin", 5 * MB, 42, 2);
        assert_eq!(run(&tree).used_bytes, 5 * MB + DIR_BYTES);
    }

    #[test]
    fn an_unreadable_directory_gives_partial_not_an_error() {
        let tree = FakeTree::new("/m")
            .file("ok.bin", MB)
            .unreadable("private")
            .file("RuyaOS/ROMs/a.bin", 2 * MB);
        let scan = run(&tree);
        assert!(scan.partial);
        assert!(bytes_of(&scan, "games").unwrap() >= 2 * MB);
        assert!(scan.used_bytes >= 3 * MB);
    }

    #[test]
    fn an_unreadable_root_is_an_error() {
        let tree = FakeTree::new("/m").file("a", 1);
        let clock = FakeClock::default();
        assert!(scan(
            &tree,
            &clock,
            "/nothing",
            &Limits::default(),
            &AtomicBool::new(false)
        )
        .is_err());
    }

    #[test]
    fn names_that_cannot_be_represented_give_partial() {
        let tree = FakeTree::new("/m").file("a", MB).skipped("", 2);
        let scan = run(&tree);
        assert!(scan.partial);
        assert_eq!(scan.used_bytes, MB + DIR_BYTES);
    }

    #[test]
    fn cancel_stops_a_walk_in_progress_within_one_directory() {
        let cancel = Arc::new(AtomicBool::new(false));
        let flag = cancel.clone();
        let tree = FakeTree::new("/m")
            .file("a/x", MB)
            .file("b/x", MB)
            .file("c/x", MB)
            .on_list(move |dir| {
                // The user cancels while the second directory is being read.
                if dir.ends_with("/b") || dir.ends_with("/a") || dir.ends_with("/c") {
                    flag.store(true, Ordering::Relaxed);
                }
            });
        let clock = FakeClock::default();
        let scan = scan(&tree, &clock, "/m", &Limits::default(), &cancel).unwrap();
        assert!(scan.cancelled);
        assert!(scan.partial);
        // Root, then one directory; the other two were never listed.
        assert_eq!(tree.lists().len(), 2, "{:?}", tree.lists());
    }

    #[test]
    fn cancel_is_noticed_inside_a_big_directory() {
        let cancel = Arc::new(AtomicBool::new(true));
        let mut tree = FakeTree::new("/m");
        for i in 0..1000 {
            tree = tree.file(&format!("f{i}"), 1);
        }
        let clock = FakeClock::default();
        // Cancelled before the first directory: nothing is read.
        let scan = scan(&tree, &clock, "/m", &Limits::default(), &cancel).unwrap();
        assert!(scan.cancelled);
        assert!(tree.lists().is_empty());
        // Set during the first listing: stops after CHECK_EVERY entries, not 1000.
        let cancel = Arc::new(AtomicBool::new(false));
        let flag = cancel.clone();
        let mut tree = FakeTree::new("/m").on_list(move |_| flag.store(true, Ordering::Relaxed));
        for i in 0..1000 {
            tree = tree.file(&format!("f{i}"), 1);
        }
        let scan = super::scan(&tree, &clock, "/m", &Limits::default(), &cancel);
        // The flag was raised by the very first list call, which is already the first check
        // passed; the entries loop stops at the next look.
        let scan = scan.unwrap();
        assert!(scan.cancelled);
        assert!(tree.stats() <= CHECK_EVERY + 1, "{}", tree.stats());
    }

    #[test]
    fn a_hostile_name_never_fails_and_is_not_echoed() {
        let long = "x".repeat(4000);
        let tree = FakeTree::new("/m")
            .file("evil\u{1b}[31m\u{7}\n.bin", MB)
            .file("\u{202e}gpj.exe", MB)
            .file(&long, MB)
            .dir("\u{202e}dir\u{0}")
            .unreadable("bad\u{1}dir");
        let scan = run(&tree);
        assert!(scan.partial, "the unreadable directory");
        assert!(scan.used_bytes >= 3 * MB);
        for t in &scan.categories {
            assert!(CATEGORIES.iter().any(|c| c.key == t.key));
        }
        // What goes to the log is cleaned and short.
        let shown = printable("evil\u{1b}[31m\u{7}\n\u{202e}x");
        assert!(!shown.chars().any(|c| c.is_control() || c == '\u{202e}'));
        let shown = printable(&long);
        assert!(shown.chars().count() <= 51, "{}", shown.len());
        assert_eq!(printable("plain name.txt"), "plain name.txt");
    }

    /// The trait has two methods and a source with only those two is a complete source: there is
    /// no way for the walk to open or read a file. (A third required method would stop this
    /// from compiling; a provided one would show in the list below.)
    struct OnlyListAndStat;

    impl ScanSource for OnlyListAndStat {
        fn list(&self, dir: &str) -> Result<Listing, String> {
            assert!(dir == "/m" || dir == "/m/d", "listed {dir}");
            Ok(Listing {
                names: if dir == "/m" {
                    vec!["d".into(), "f".into()]
                } else {
                    vec![]
                },
                skipped: 0,
            })
        }
        fn stat(&self, path: &str) -> Result<Meta, String> {
            let kind = if path == "/m/f" {
                Kind::File
            } else {
                Kind::Dir
            };
            Ok(Meta {
                kind,
                bytes: 10,
                dev: 1,
                ino: 1,
                links: 1,
            })
        }
    }

    #[test]
    fn the_source_can_only_list_and_stat() {
        let clock = FakeClock::default();
        let scan = scan(
            &OnlyListAndStat,
            &clock,
            "/m",
            &Limits::default(),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(scan.used_bytes, 30);
        // The production source file never mentions an open or a read of volume content.
        let code = include_str!("drive_scan.rs");
        let production = code.split("#[cfg(test)]").next().unwrap_or("");
        for banned in [
            "File::open",
            "fs::read(",
            "read_to_string",
            "OpenOptions",
            "Command::new",
            "exec(",
        ] {
            assert!(!production.contains(banned), "drive_scan.rs uses {banned}");
        }
    }

    // ---- Scans --------------------------------------------------------------------------------

    fn volume(id: &str) -> Volume {
        Volume {
            id: id.to_owned(),
            drive: "/d".to_owned(),
            label: "STICK".to_owned(),
            filesystem: "exfat",
            size_bytes: 16_000_000_000,
            free_bytes: 8_000_000_000,
            removable: true,
            mounted: true,
            mount_point: "/m".to_owned(),
            read_only: false,
        }
    }

    fn scans(tree: FakeTree) -> Scans<FakeTree, Arc<FakeClock>> {
        Scans::new(tree, Arc::new(FakeClock::default()))
    }

    fn started(scans: &Scans<FakeTree, Arc<FakeClock>>, volumes: &[Volume], id: &str) -> Job {
        match scans.request(volumes, id) {
            Ok(Begin::Run(job)) => job,
            other => panic!("expected a job, got {other:?}"),
        }
    }

    #[test]
    fn a_scan_is_idle_running_done() {
        let s = scans(FakeTree::new("/m").file("RuyaOS/ROMs/a", 3 * MB));
        let vols = [volume("v1")];
        assert_eq!(s.get(&vols, "v1").state, State::Idle);
        let job = started(&s, &vols, "v1");
        assert_eq!(s.get(&vols, "v1").state, State::Running);
        assert!(s.run(&job));
        let got = s.get(&vols, "v1");
        assert_eq!(got.state, State::Done);
        assert!(got.scan.categories.iter().any(|t| t.key == "games"));
    }

    #[test]
    fn requests_are_checked() {
        let s = scans(FakeTree::new("/m"));
        let mut internal = volume("i");
        internal.removable = false;
        let mut unmounted = volume("u");
        unmounted.mounted = false;
        unmounted.mount_point.clear();
        let vols = [volume("v1"), internal, unmounted];
        assert_eq!(s.request(&vols, ""), Err(Status::Invalid));
        assert_eq!(s.request(&vols, "nope"), Err(Status::UnknownVolume));
        assert_eq!(s.request(&vols, "i"), Err(Status::Unsupported));
        assert_eq!(s.request(&vols, "u"), Err(Status::Unsupported));
    }

    #[test]
    fn one_scan_at_a_time() {
        let s = scans(FakeTree::new("/m"));
        let vols = [volume("v1"), volume("v2")];
        let job = started(&s, &vols, "v1");
        assert_eq!(s.request(&vols, "v2"), Err(Status::Busy));
        // The same volume again is the scan that already runs.
        assert_eq!(s.request(&vols, "v1"), Ok(Begin::Nothing));
        assert!(s.run(&job));
        assert!(matches!(s.request(&vols, "v2"), Ok(Begin::Run(_))));
    }

    #[test]
    fn the_result_is_cached_and_dropped_when_the_volume_changes_or_leaves() {
        let tree = FakeTree::new("/m").file("a", MB);
        let s = scans(tree);
        let mut vols = vec![volume("v1")];
        let job = started(&s, &vols, "v1");
        s.run(&job);
        // Fresh: no new walk.
        let lists = s.source.lists().len();
        assert_eq!(s.request(&vols, "v1"), Ok(Begin::Nothing));
        assert_eq!(s.source.lists().len(), lists);
        assert_eq!(s.get(&vols, "v1").state, State::Done);
        // VolumesChanged with the same volume keeps it; a changed one drops it.
        vols[0].label = "Renamed".to_owned();
        assert_eq!(s.get(&vols, "v1").state, State::Done);
        vols[0].free_bytes -= 1;
        assert_eq!(s.get(&vols, "v1").state, State::Idle);
        let job = started(&s, &vols, "v1");
        s.run(&job);
        assert_eq!(s.get(&vols, "v1").state, State::Done);
        // Unplugged.
        assert_eq!(s.get(&[], "v1").state, State::Idle);
        assert_eq!(s.request(&[], "v1"), Err(Status::UnknownVolume));
    }

    #[test]
    fn cancel_ends_as_cancelled_and_the_next_call_walks_again() {
        let tree = FakeTree::new("/m").file("a/x", MB).file("b/x", MB);
        let s = scans(tree);
        let vols = [volume("v1")];
        let job = started(&s, &vols, "v1");
        s.cancel("v1");
        s.cancel("nothing-here");
        assert!(s.run(&job));
        let got = s.get(&vols, "v1");
        assert_eq!(got.state, State::Cancelled);
        assert!(got.scan.partial);
        assert!(matches!(s.request(&vols, "v1"), Ok(Begin::Run(_))));
        // Cancelling something that is not running changes nothing.
        let s = scans(FakeTree::new("/m"));
        let job = started(&s, &vols, "v1");
        s.run(&job);
        s.cancel("v1");
        assert_eq!(s.get(&vols, "v1").state, State::Done);
    }

    #[test]
    fn a_volume_that_changes_during_the_walk_discards_the_result() {
        let s = scans(FakeTree::new("/m").file("a", MB));
        let mut vols = vec![volume("v1")];
        let job = started(&s, &vols, "v1");
        // VolumesChanged arrives while the walk runs.
        vols[0].mount_point = "/m2".to_owned();
        assert_eq!(s.get(&vols, "v1").state, State::Idle);
        assert!(!s.run(&job), "a stale walk reports no change");
        assert_eq!(s.get(&vols, "v1").state, State::Idle);
        // And the scanner is free again.
        assert!(matches!(s.request(&vols, "v1"), Ok(Begin::Run(_))));
    }

    #[test]
    fn an_unreadable_mount_point_is_failed_and_not_cached() {
        let s = scans(FakeTree::new("/other"));
        let vols = [volume("v1")];
        let job = started(&s, &vols, "v1");
        assert!(s.run(&job));
        assert_eq!(s.get(&vols, "v1").state, State::Failed);
        assert!(matches!(s.request(&vols, "v1"), Ok(Begin::Run(_))));
    }

    struct Panics;

    impl ScanSource for Panics {
        fn list(&self, _dir: &str) -> Result<Listing, String> {
            panic!("a source that fails badly");
        }
        fn stat(&self, _path: &str) -> Result<Meta, String> {
            Ok(Meta {
                kind: Kind::Dir,
                bytes: 0,
                dev: 1,
                ino: 1,
                links: 1,
            })
        }
    }

    #[test]
    fn a_panicking_source_does_not_leave_the_scanner_stuck() {
        let s = Scans::new(Panics, FakeClock::default());
        let vols = [volume("v1"), volume("v2")];
        let Ok(Begin::Run(job)) = s.request(&vols, "v1") else {
            panic!("expected a job");
        };
        assert!(s.run(&job));
        assert_eq!(s.get(&vols, "v1").state, State::Failed);
        assert!(matches!(s.request(&vols, "v2"), Ok(Begin::Run(_))));
    }

    #[test]
    fn status_strings_match_the_contract() {
        let all = [
            (Status::Ok, "ok"),
            (Status::UnknownVolume, "unknown-volume"),
            (Status::Unsupported, "unsupported"),
            (Status::Busy, "busy"),
            (Status::Invalid, "invalid"),
            (Status::Failed, "failed"),
        ];
        for (status, text) in all {
            assert_eq!(status.as_str(), text);
        }
        assert_eq!(State::Cancelled.as_str(), "cancelled");
    }

    #[cfg(unix)]
    #[test]
    fn the_real_source_walks_a_directory_and_does_not_follow_links() {
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("RuyaOS/ROMs/snes")).unwrap();
        std::fs::write(root.join("RuyaOS/ROMs/snes/a.bin"), vec![1u8; 3 << 20]).unwrap();
        std::fs::write(root.join("stray.bin"), vec![1u8; 1 << 20]).unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("big.bin"), vec![1u8; 8 << 20]).unwrap();
        symlink(outside.path(), root.join("link")).unwrap();
        let clock = FakeClock::default();
        let scan = scan(
            &FsSource,
            &clock,
            root.to_str().unwrap(),
            &Limits::default(),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert!(!scan.partial);
        let games = bytes_of(&scan, "games").unwrap();
        assert!((3 << 20..4 << 20).contains(&games), "{games}");
        assert!(scan.used_bytes < 6 << 20, "{}", scan.used_bytes);
    }
}
