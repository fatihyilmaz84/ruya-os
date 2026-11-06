//! How full the console's own storage is (org.ruyaos.Devices1.Storage.GetSystemUsage, T-196).
//!
//! The numbers: `total` and `free` of the filesystem that holds `/var` (one `statvfs`, cheap, read
//! on every call), `apps` (the system Flatpak installation) and `data` (the profile homes), which
//! are directory sizes and so slow on a full disk. Those two are computed off the D-Bus executor,
//! cached for [`TTL`], recomputed after the Store says the installed apps changed, and a call that
//! finds the cache stale answers with the old numbers at once and starts a recompute (the service
//! then sends `SystemUsageChanged`). `system` is what is left of the used space.
//!
//! A walk that could not read everything it walked is not reported: its number would count only
//! what the service may read, so the part is unknown (`-1`). That is the case for `data` today:
//! every profile is a Unix user with a 0700 home under `/var/home` and the service runs as
//! `ruya-shell`, so it sees the directories and none of their files. `system` is then everything
//! that is not free and not apps (`total - free - apps`); with `data` known it is
//! `total - free - apps - data`.
//!
//! The core is pure: [`SystemSource`] (statvfs and tree sizes) and [`Clock`] are traits, with
//! fakes for the tests; [`LinuxSource`] is the real thing. The directory walk counts allocated
//! blocks (`st_blocks * 512`, so sparse files and block rounding are right), counts a hard-linked
//! file once (a Flatpak deployment is hard links into the OSTree repository), never follows a
//! symlink and never crosses into another mount.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

/// How long computed directory sizes are reused before a call starts a recompute.
pub const TTL: Duration = Duration::from_secs(60);

/// The filesystem that holds apps, games and profile data.
pub const VAR: &str = "/var";
/// The system Flatpak installation.
pub const APPS: &str = "/var/lib/flatpak";
/// The profile homes.
pub const HOMES: &str = "/var/home";

/// The contract's numbers; an unknown part is `-1`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Usage {
    pub total_bytes: i64,
    pub free_bytes: i64,
    pub apps_bytes: i64,
    pub data_bytes: i64,
    pub system_bytes: i64,
}

impl Usage {
    pub const UNKNOWN: Usage = Usage {
        total_bytes: -1,
        free_bytes: -1,
        apps_bytes: -1,
        data_bytes: -1,
        system_bytes: -1,
    };
}

/// The size of a directory tree. `partial` is set when parts of it could not be read (another
/// user's private files): the number then counts only what was readable, and [`SystemUsage`]
/// reports the part as unknown instead.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TreeSize {
    pub bytes: u64,
    pub partial: bool,
}

/// What the numbers are read from.
pub trait SystemSource: Send + Sync {
    /// `(total, free)` bytes of the filesystem that holds `path`; free is what an unprivileged
    /// process can still use.
    fn filesystem(&self, path: &str) -> Result<(u64, u64), String>;
    /// The allocated size of the tree under `path`. An error only when `path` itself cannot be
    /// read at all.
    fn tree(&self, path: &str) -> Result<TreeSize, String>;
}

impl<T: SystemSource + ?Sized> SystemSource for Box<T> {
    fn filesystem(&self, path: &str) -> Result<(u64, u64), String> {
        (**self).filesystem(path)
    }

    fn tree(&self, path: &str) -> Result<TreeSize, String> {
        (**self).tree(path)
    }
}

pub trait Clock: Send + Sync {
    /// Time since some fixed start; only differences matter.
    fn now(&self) -> Duration;
}

/// The wall of the running process.
pub struct MonotonicClock(std::time::Instant);

impl MonotonicClock {
    pub fn new() -> Self {
        MonotonicClock(std::time::Instant::now())
    }
}

impl Default for MonotonicClock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock for MonotonicClock {
    fn now(&self) -> Duration {
        self.0.elapsed()
    }
}

/// What a refresh call did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refresh {
    /// The cache is fresh, or another thread is already computing.
    Skipped,
    /// Recomputed; `apps_bytes` and `data_bytes` are as before.
    Unchanged,
    /// Recomputed; at least one of them differs (also the first time).
    Changed,
}

#[derive(Default)]
struct Cache {
    /// The last directory sizes; `None` for a part that could not be read (or never was).
    apps: Option<u64>,
    data: Option<u64>,
    /// When they were computed; `None`: never, or invalidated.
    at: Option<Duration>,
    computing: bool,
    /// `invalidate` was called while a walk ran: that walk may have missed the change.
    dirty: bool,
    /// At least one walk finished.
    known: bool,
}

pub struct SystemUsage<S: SystemSource, C: Clock> {
    source: S,
    clock: C,
    ttl: Duration,
    cache: Mutex<Cache>,
}

impl<S: SystemSource, C: Clock> SystemUsage<S, C> {
    pub fn new(source: S, clock: C) -> Self {
        Self::with_ttl(source, clock, TTL)
    }

    pub fn with_ttl(source: S, clock: C, ttl: Duration) -> Self {
        SystemUsage {
            source,
            clock,
            ttl,
            cache: Mutex::new(Cache::default()),
        }
    }

    fn cache(&self) -> MutexGuard<'_, Cache> {
        // A poisoned lock only means another call panicked; the state is plain data.
        self.cache.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn is_stale(&self, cache: &Cache) -> bool {
        match cache.at {
            None => true,
            Some(at) => self.clock.now().saturating_sub(at) >= self.ttl,
        }
    }

    /// The numbers now: total and free freshly read (cheap), the directory sizes as cached
    /// (unknown until the first recompute has finished). Never blocks on a directory walk.
    pub fn current(&self) -> Usage {
        let (apps, data) = {
            let cache = self.cache();
            (cache.apps, cache.data)
        };
        let fs = self.source.filesystem(VAR).ok();
        let to_i64 = |v: u64| i64::try_from(v).unwrap_or(i64::MAX);
        let total = fs.map(|(t, _)| to_i64(t));
        let free = fs.map(|(t, f)| to_i64(f.min(t)));
        let apps = apps.map(to_i64);
        let data = data.map(to_i64);
        // What is used and is not apps (and not profile data, when that is known).
        let system = match (total, free, apps) {
            (Some(t), Some(f), Some(a)) => Some(
                t.saturating_sub(f)
                    .saturating_sub(a)
                    .saturating_sub(data.unwrap_or(0))
                    .max(0),
            ),
            _ => None,
        };
        Usage {
            total_bytes: total.unwrap_or(-1),
            free_bytes: free.unwrap_or(-1),
            apps_bytes: apps.unwrap_or(-1),
            data_bytes: data.unwrap_or(-1),
            system_bytes: system.unwrap_or(-1),
        }
    }

    /// A recompute is due and nobody is doing it (the cheap check before starting one).
    pub fn needs_refresh(&self) -> bool {
        let cache = self.cache();
        !cache.computing && self.is_stale(&cache)
    }

    /// The installed apps (or anything else the sizes depend on) changed: the cache is stale from
    /// now on, also when a walk is running right now.
    pub fn invalidate(&self) {
        let mut cache = self.cache();
        if cache.computing {
            cache.dirty = true;
        } else {
            cache.at = None;
        }
    }

    /// Recomputes the directory sizes if the cache is stale and nobody else is computing. Blocks
    /// for the duration of the walks: call it on the blocking pool. A walk that fails leaves that
    /// part unknown; it never fails the call.
    pub fn refresh(&self) -> Refresh {
        let before = {
            let mut cache = self.cache();
            if cache.computing || !self.is_stale(&cache) {
                return Refresh::Skipped;
            }
            cache.computing = true;
            (cache.apps, cache.data, cache.known)
        };
        let apps = self.walk(APPS);
        let data = self.walk(HOMES);
        let now = self.clock.now();
        let mut cache = self.cache();
        cache.computing = false;
        cache.apps = apps;
        cache.data = data;
        cache.known = true;
        cache.at = if cache.dirty { None } else { Some(now) };
        cache.dirty = false;
        if before == (apps, data, true) {
            Refresh::Unchanged
        } else {
            Refresh::Changed
        }
    }

    fn walk(&self, path: &str) -> Option<u64> {
        match self.source.tree(path) {
            Ok(size) if size.partial => {
                eprintln!("ruya-devices: {path} is not fully readable: its size is unknown");
                None
            }
            Ok(size) => Some(size.bytes),
            Err(err) => {
                eprintln!("ruya-devices: measuring {path} failed: {err}");
                None
            }
        }
    }
}

/// A scripted source for tests and `--session` development.
pub struct FakeSource {
    inner: Mutex<FakeInner>,
}

struct FakeInner {
    filesystem: Result<(u64, u64), String>,
    apps: Result<TreeSize, String>,
    data: Result<TreeSize, String>,
    walks: usize,
}

impl FakeSource {
    pub fn new(total: u64, free: u64, apps: u64, data: u64) -> Self {
        let tree = |bytes| {
            Ok(TreeSize {
                bytes,
                partial: false,
            })
        };
        FakeSource {
            inner: Mutex::new(FakeInner {
                filesystem: Ok((total, free)),
                apps: tree(apps),
                data: tree(data),
                walks: 0,
            }),
        }
    }

    fn inner(&self) -> MutexGuard<'_, FakeInner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn set_filesystem(&self, filesystem: Result<(u64, u64), String>) {
        self.inner().filesystem = filesystem;
    }

    pub fn set_apps(&self, apps: Result<TreeSize, String>) {
        self.inner().apps = apps;
    }

    pub fn set_data(&self, data: Result<TreeSize, String>) {
        self.inner().data = data;
    }

    /// How many trees were walked (two per recompute).
    pub fn walks(&self) -> usize {
        self.inner().walks
    }
}

impl SystemSource for FakeSource {
    fn filesystem(&self, _path: &str) -> Result<(u64, u64), String> {
        self.inner().filesystem.clone()
    }

    fn tree(&self, path: &str) -> Result<TreeSize, String> {
        let mut inner = self.inner();
        inner.walks += 1;
        if path == HOMES {
            inner.data.clone()
        } else {
            inner.apps.clone()
        }
    }
}

/// A clock the test moves.
#[derive(Default)]
pub struct FakeClock(Mutex<Duration>);

impl FakeClock {
    pub fn advance(&self, by: Duration) {
        *self.0.lock().unwrap_or_else(|e| e.into_inner()) += by;
    }
}

impl Clock for FakeClock {
    fn now(&self) -> Duration {
        *self.0.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl<T: Clock + ?Sized> Clock for std::sync::Arc<T> {
    fn now(&self) -> Duration {
        (**self).now()
    }
}

/// The real source: `statvfs` and a directory walk.
pub struct LinuxSource;

impl SystemSource for LinuxSource {
    fn filesystem(&self, path: &str) -> Result<(u64, u64), String> {
        filesystem_of(path)
    }

    fn tree(&self, path: &str) -> Result<TreeSize, String> {
        tree_size(Path::new(path))
    }
}

#[cfg(target_os = "linux")]
fn filesystem_of(path: &str) -> Result<(u64, u64), String> {
    use std::ffi::CString;
    let c = CString::new(path).map_err(|e| e.to_string())?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c` is a valid NUL-terminated path and `st` a writable statvfs.
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    #[allow(clippy::unnecessary_cast)]
    let unit = st.f_frsize as u64;
    Ok((
        (st.f_blocks as u64).saturating_mul(unit),
        (st.f_bavail as u64).saturating_mul(unit),
    ))
}

#[cfg(not(target_os = "linux"))]
fn filesystem_of(_path: &str) -> Result<(u64, u64), String> {
    Err("statvfs is only available on Linux".to_owned())
}

/// `(device, inode, links, allocated bytes)` of an entry.
#[cfg(unix)]
fn identity(meta: &fs::Metadata) -> (u64, u64, u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (
        meta.dev(),
        meta.ino(),
        meta.nlink(),
        meta.blocks().saturating_mul(512),
    )
}

#[cfg(not(unix))]
fn identity(meta: &fs::Metadata) -> (u64, u64, u64, u64) {
    // No inodes here: the apparent size, no hard-link or mount handling (development hosts only).
    (0, 0, 1, meta.len())
}

/// The allocated size of everything under `root` (the entry itself included). Symlinks are
/// counted as the link they are and never followed; a directory on another device is skipped;
/// a hard-linked file counts once; what cannot be read is skipped and sets `partial`. Only an
/// unreadable `root` is an error. An explicit stack: a deep tree cannot overflow the thread's.
pub fn tree_size(root: &Path) -> Result<TreeSize, String> {
    let root_meta = fs::symlink_metadata(root).map_err(|e| format!("{}: {e}", root.display()))?;
    let (root_dev, _, _, root_bytes) = identity(&root_meta);
    let mut bytes = root_bytes;
    let mut partial = false;
    if !root_meta.is_dir() {
        return Ok(TreeSize { bytes, partial });
    }
    let mut seen: HashSet<(u64, u64)> = HashSet::new();
    let mut pending: Vec<PathBuf> = vec![root.to_owned()];
    let mut first = true;
    while let Some(dir) = pending.pop() {
        let entries = match fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(err) if first => return Err(format!("{}: {err}", dir.display())),
            Err(_) => {
                partial = true;
                continue;
            }
        };
        first = false;
        for entry in entries {
            let Ok(entry) = entry else {
                partial = true;
                continue;
            };
            let path = entry.path();
            let Ok(meta) = fs::symlink_metadata(&path) else {
                partial = true;
                continue;
            };
            let (dev, ino, links, size) = identity(&meta);
            if meta.is_dir() {
                // Another mount (a second disk, a tmpfs): not part of this filesystem's use.
                if dev == root_dev {
                    bytes = bytes.saturating_add(size);
                    pending.push(path);
                }
            } else if links > 1 && !seen.insert((dev, ino)) {
                continue;
            } else {
                bytes = bytes.saturating_add(size);
            }
        }
    }
    Ok(TreeSize { bytes, partial })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    const GB: u64 = 1_000_000_000;

    fn partial(bytes: u64) -> Result<TreeSize, String> {
        Ok(TreeSize {
            bytes,
            partial: true,
        })
    }

    fn tree(bytes: u64) -> Result<TreeSize, String> {
        Ok(TreeSize {
            bytes,
            partial: false,
        })
    }

    fn core(source: FakeSource) -> (Arc<FakeClock>, SystemUsage<FakeSource, Arc<FakeClock>>) {
        let clock = Arc::new(FakeClock::default());
        (clock.clone(), SystemUsage::new(source, clock))
    }

    #[test]
    fn maps_statvfs_and_tree_sizes_to_the_five_keys() {
        let (_, usage) = core(FakeSource::new(464 * GB, 450 * GB, 8 * GB, 2 * GB));
        assert_eq!(usage.refresh(), Refresh::Changed);
        assert_eq!(
            usage.current(),
            Usage {
                total_bytes: (464 * GB) as i64,
                free_bytes: (450 * GB) as i64,
                apps_bytes: (8 * GB) as i64,
                data_bytes: (2 * GB) as i64,
                // 464 - 450 - 8 - 2
                system_bytes: (4 * GB) as i64,
            }
        );
    }

    #[test]
    fn before_the_first_walk_only_total_and_free_are_known() {
        let (_, usage) = core(FakeSource::new(100, 60, 10, 10));
        let now = usage.current();
        assert_eq!((now.total_bytes, now.free_bytes), (100, 60));
        assert_eq!(
            (now.apps_bytes, now.data_bytes, now.system_bytes),
            (-1, -1, -1)
        );
    }

    #[test]
    fn system_is_the_remainder_and_never_negative() {
        // The trees add up to more than what the filesystem reports as used (a quota, files
        // counted before they were deleted, a race): zero, not a negative number.
        let (_, usage) = core(FakeSource::new(100, 60, 30, 30));
        usage.refresh();
        assert_eq!(usage.current().system_bytes, 0);
    }

    #[test]
    fn free_is_never_more_than_total() {
        let (_, usage) = core(FakeSource::new(100, 150, 0, 0));
        usage.refresh();
        let now = usage.current();
        assert_eq!((now.free_bytes, now.system_bytes), (100, 0));
    }

    #[test]
    fn a_failing_walk_is_unknown_not_an_error() {
        let source = FakeSource::new(100, 60, 10, 10);
        source.set_apps(Err("permission denied".to_owned()));
        let (_, usage) = core(source);
        assert_eq!(usage.refresh(), Refresh::Changed);
        let now = usage.current();
        assert_eq!((now.total_bytes, now.free_bytes), (100, 60));
        assert_eq!((now.apps_bytes, now.data_bytes), (-1, 10));
        // System cannot be told without the apps.
        assert_eq!(now.system_bytes, -1);
    }

    // The profile homes are 0700 users' directories: the walk sees them and nothing in them, so
    // the number would be a few kB and say nothing. It is unknown, and the rest is not hidden.
    #[test]
    fn a_partly_unreadable_data_walk_is_unknown_and_system_is_the_rest() {
        let source = FakeSource::new(464 * GB, 450 * GB, 8 * GB, 0);
        source.set_data(partial(8_192));
        let (_, usage) = core(source);
        assert_eq!(usage.refresh(), Refresh::Changed);
        assert_eq!(
            usage.current(),
            Usage {
                total_bytes: (464 * GB) as i64,
                free_bytes: (450 * GB) as i64,
                apps_bytes: (8 * GB) as i64,
                data_bytes: -1,
                // 464 - 450 - 8: everything used that is not apps
                system_bytes: (6 * GB) as i64,
            }
        );
    }

    #[test]
    fn a_fully_readable_data_walk_is_a_number_and_system_is_the_remainder() {
        let source = FakeSource::new(464 * GB, 450 * GB, 8 * GB, 2 * GB);
        source.set_data(tree(2 * GB));
        let (_, usage) = core(source);
        usage.refresh();
        let now = usage.current();
        assert_eq!(
            (now.data_bytes, now.system_bytes),
            ((2 * GB) as i64, (4 * GB) as i64)
        );
    }

    #[test]
    fn a_partly_unreadable_apps_walk_is_unknown_too() {
        let source = FakeSource::new(100, 60, 10, 10);
        source.set_apps(partial(3));
        let (_, usage) = core(source);
        usage.refresh();
        let now = usage.current();
        assert_eq!(
            (now.apps_bytes, now.data_bytes, now.system_bytes),
            (-1, 10, -1)
        );
    }

    #[test]
    fn system_without_data_is_never_negative() {
        let source = FakeSource::new(100, 60, 50, 0);
        source.set_data(partial(1));
        let (_, usage) = core(source);
        usage.refresh();
        assert_eq!(usage.current().system_bytes, 0);
    }

    #[test]
    fn a_failing_statvfs_leaves_the_walks_alone() {
        let source = FakeSource::new(100, 60, 10, 10);
        source.set_filesystem(Err("no such file".to_owned()));
        let (_, usage) = core(source);
        usage.refresh();
        let now = usage.current();
        assert_eq!(
            (now.total_bytes, now.free_bytes, now.system_bytes),
            (-1, -1, -1)
        );
        assert_eq!((now.apps_bytes, now.data_bytes), (10, 10));
    }

    #[test]
    fn a_failed_walk_is_recovered_by_the_next_one() {
        let source = FakeSource::new(100, 60, 10, 10);
        source.set_apps(Err("busy".to_owned()));
        let (clock, usage) = core(source);
        usage.refresh();
        usage.source.set_apps(tree(12));
        clock.advance(TTL);
        assert_eq!(usage.refresh(), Refresh::Changed);
        assert_eq!(usage.current().apps_bytes, 12);
    }

    #[test]
    fn the_cache_is_reused_within_its_time_and_recomputed_after() {
        let (clock, usage) = core(FakeSource::new(100, 60, 10, 10));
        assert!(usage.needs_refresh());
        assert_eq!(usage.refresh(), Refresh::Changed);
        assert_eq!(usage.source.walks(), 2);

        clock.advance(TTL - Duration::from_secs(1));
        assert!(!usage.needs_refresh());
        assert_eq!(usage.refresh(), Refresh::Skipped);
        assert_eq!(usage.source.walks(), 2, "within the time nothing is walked");

        // The disk changed meanwhile: not seen until the cache expires.
        usage.source.set_apps(tree(20));
        assert_eq!(usage.current().apps_bytes, 10);

        clock.advance(Duration::from_secs(1));
        assert!(usage.needs_refresh());
        assert_eq!(usage.refresh(), Refresh::Changed);
        assert_eq!(usage.source.walks(), 4);
        assert_eq!(usage.current().apps_bytes, 20);

        clock.advance(TTL);
        assert_eq!(usage.refresh(), Refresh::Unchanged, "same sizes again");
    }

    #[test]
    fn a_change_signal_makes_the_cache_stale_at_once() {
        let (_, usage) = core(FakeSource::new(100, 60, 10, 10));
        usage.refresh();
        assert_eq!(usage.refresh(), Refresh::Skipped);

        usage.source.set_apps(tree(15));
        usage.invalidate();
        assert!(usage.needs_refresh());
        assert_eq!(usage.refresh(), Refresh::Changed);
        assert_eq!(usage.current().apps_bytes, 15);
        assert!(!usage.needs_refresh());
    }

    type Rc = Arc<SystemUsage<SignalDuringWalk, Arc<FakeClock>>>;

    /// A source that, while it walks, reports a change signal (an install finishing).
    struct SignalDuringWalk {
        inner: FakeSource,
        usage: Mutex<Option<Rc>>,
    }

    impl SystemSource for SignalDuringWalk {
        fn filesystem(&self, path: &str) -> Result<(u64, u64), String> {
            self.inner.filesystem(path)
        }

        fn tree(&self, path: &str) -> Result<TreeSize, String> {
            let usage = self.usage.lock().unwrap().take();
            if let Some(usage) = usage {
                usage.invalidate();
            }
            self.inner.tree(path)
        }
    }

    #[test]
    fn a_change_signal_during_a_walk_is_not_lost() {
        let clock = Arc::new(FakeClock::default());
        let usage = Arc::new(SystemUsage::new(
            SignalDuringWalk {
                inner: FakeSource::new(100, 60, 10, 10),
                usage: Mutex::new(None),
            },
            clock,
        ));
        *usage.source.usage.lock().unwrap() = Some(usage.clone());
        assert_eq!(usage.refresh(), Refresh::Changed);
        assert!(
            usage.needs_refresh(),
            "the walk may have missed the change, so the result is already stale"
        );
        assert_eq!(usage.refresh(), Refresh::Unchanged);
        assert!(!usage.needs_refresh());
    }

    #[test]
    fn only_one_walk_runs_at_a_time() {
        let (_, usage) = core(FakeSource::new(100, 60, 10, 10));
        usage.cache().computing = true;
        assert!(!usage.needs_refresh());
        assert_eq!(usage.refresh(), Refresh::Skipped);
        assert_eq!(usage.source.walks(), 0);
    }

    // The real walk, on a scratch tree.

    fn write(path: &Path, len: usize) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, vec![7u8; len]).unwrap();
    }

    #[test]
    fn the_walk_adds_up_files_in_nested_directories() {
        let dir = tempfile::tempdir().unwrap();
        write(&dir.path().join("a/one"), 100_000);
        write(&dir.path().join("a/b/two"), 200_000);
        write(&dir.path().join("three"), 50_000);
        let size = tree_size(dir.path()).unwrap();
        assert!(!size.partial);
        // Allocated blocks, so at least the content; and not wildly more on any filesystem.
        assert!(size.bytes >= 350_000, "{}", size.bytes);
        assert!(size.bytes < 350_000 + 1_000_000, "{}", size.bytes);
    }

    #[test]
    fn a_missing_root_is_an_error_and_a_file_is_its_own_size() {
        let dir = tempfile::tempdir().unwrap();
        assert!(tree_size(&dir.path().join("nope")).is_err());
        write(&dir.path().join("f"), 10_000);
        assert!(tree_size(&dir.path().join("f")).unwrap().bytes >= 10_000);
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_is_not_followed() {
        let dir = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        write(&outside.path().join("big"), 5_000_000);
        write(&dir.path().join("small"), 1_000);
        std::os::unix::fs::symlink(outside.path(), dir.path().join("link-to-dir")).unwrap();
        std::os::unix::fs::symlink(outside.path().join("big"), dir.path().join("link-to-file"))
            .unwrap();
        let size = tree_size(dir.path()).unwrap();
        assert!(
            size.bytes < 1_000_000,
            "followed a link out of the tree: {}",
            size.bytes
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_hard_linked_file_counts_once() {
        let dir = tempfile::tempdir().unwrap();
        write(&dir.path().join("repo/object"), 1_000_000);
        fs::create_dir_all(dir.path().join("deploy")).unwrap();
        fs::hard_link(
            dir.path().join("repo/object"),
            dir.path().join("deploy/file"),
        )
        .unwrap();
        let size = tree_size(dir.path()).unwrap();
        assert!(size.bytes >= 1_000_000, "{}", size.bytes);
        assert!(size.bytes < 1_500_000, "counted twice: {}", size.bytes);
    }

    #[cfg(unix)]
    #[test]
    fn an_unreadable_directory_is_skipped_and_marks_the_size_partial() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        write(&dir.path().join("mine"), 10_000);
        write(&dir.path().join("ada/secret"), 1_000_000);
        let private = dir.path().join("ada");
        fs::set_permissions(&private, fs::Permissions::from_mode(0o000)).unwrap();
        let size = tree_size(dir.path());
        fs::set_permissions(&private, fs::Permissions::from_mode(0o700)).unwrap();
        let size = size.unwrap();
        // Running as root reads everything; otherwise the private tree is left out.
        if size.bytes < 1_000_000 {
            assert!(size.partial);
        }
    }
}
