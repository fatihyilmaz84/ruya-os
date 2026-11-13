//! Plain files at the top of a removable volume (`Storage.ListFiles` and `Storage.ReadFile`,
//! RUY-42: importing a controller profile from a USB drive). The volume is not ours: a name is
//! checked before it is joined to the mount point, a file is opened without following a symlink and
//! must be a regular file, its size is compared with the caller's cap before anything is read, and
//! nothing is ever executed. The content is the caller's to check (Input1.ValidateProfile).

use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use crate::storage::{Storage, Udisks};

/// The largest `max_bytes` of `ReadFile`.
pub const MAX_READ: u32 = 1 << 20;
/// At most this many files in one `ListFiles` answer.
pub const MAX_LISTED: usize = 256;
/// At most this many directory entries are looked at.
const MAX_LOOKED_AT: usize = 4096;

/// The contract's strings (`Storage.ListFiles`, `Storage.ReadFile`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileStatus {
    Ok,
    UnknownVolume,
    Unsupported,
    Invalid,
    NotFound,
    TooLarge,
    NotText,
    Failed,
}

impl FileStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            FileStatus::Ok => "ok",
            FileStatus::UnknownVolume => "unknown-volume",
            FileStatus::Unsupported => "unsupported",
            FileStatus::Invalid => "invalid",
            FileStatus::NotFound => "not-found",
            FileStatus::TooLarge => "too-large",
            FileStatus::NotText => "not-text",
            FileStatus::Failed => "failed",
        }
    }
}

/// One row of `ListFiles`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileEntry {
    pub name: String,
    pub size_bytes: u64,
    /// Seconds since 1970-01-01 UTC, 0 when unknown.
    pub modified: i64,
}

/// "." and 1 to 8 of `a-z 0-9`.
pub fn valid_suffix(suffix: &str) -> bool {
    suffix.strip_prefix('.').is_some_and(|rest| {
        (1..=8).contains(&rest.len())
            && rest
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
    })
}

/// A plain file name: no path, nothing hidden, no control character, at most 255 bytes.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && !name.starts_with('.')
        && !name.contains(['/', '\\'])
        && !name.chars().any(char::is_control)
}

/// The mount point of a removable, mounted volume, or the status that says why not.
pub fn mount_of<U: Udisks>(storage: &Storage<U>, id: &str) -> Result<PathBuf, FileStatus> {
    if id.is_empty() {
        return Err(FileStatus::Invalid);
    }
    let volume = storage
        .list()
        .into_iter()
        .find(|v| v.id == id)
        .ok_or(FileStatus::UnknownVolume)?;
    if !volume.removable || !volume.mounted || volume.mount_point.is_empty() {
        return Err(FileStatus::Unsupported);
    }
    Ok(PathBuf::from(volume.mount_point))
}

fn seconds(meta: &fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

/// The regular files at the top of `dir` whose name ends in `suffix` (ASCII case ignored),
/// newest first. readdir and lstat only.
pub fn list_dir(dir: &Path, suffix: &str) -> Result<Vec<FileEntry>, FileStatus> {
    if !valid_suffix(suffix) {
        return Err(FileStatus::Invalid);
    }
    let entries = fs::read_dir(dir).map_err(|_| FileStatus::Failed)?;
    let mut out = Vec::new();
    for entry in entries.take(MAX_LOOKED_AT) {
        let Ok(entry) = entry else {
            continue;
        };
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        if !valid_name(&name)
            || name.len() <= suffix.len()
            || !name.to_ascii_lowercase().ends_with(suffix)
        {
            continue;
        }
        // DirEntry::file_type and ::metadata do not follow a symlink.
        if !entry.file_type().is_ok_and(|t| t.is_file()) {
            continue;
        }
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        out.push(FileEntry {
            name,
            size_bytes: meta.len(),
            modified: seconds(&meta),
        });
    }
    out.sort_by(|a, b| {
        b.modified
            .cmp(&a.modified)
            .then_with(|| a.name.cmp(&b.name))
    });
    out.truncate(MAX_LISTED);
    Ok(out)
}

fn open_no_follow(path: &Path) -> io::Result<fs::File> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // No symlink as the last component (the name has no other), and a FIFO someone put
        // there does not block the open.
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(not(target_os = "linux"))]
    {
        if fs::symlink_metadata(path)?.file_type().is_symlink() {
            return Err(io::Error::new(io::ErrorKind::NotFound, "a symlink"));
        }
    }
    options.open(path)
}

/// Reads `name` from `dir`: at most `max_bytes`, UTF-8.
pub fn read_in(dir: &Path, name: &str, max_bytes: u32) -> Result<String, FileStatus> {
    if !valid_name(name) || max_bytes == 0 || max_bytes > MAX_READ {
        return Err(FileStatus::Invalid);
    }
    let file = match open_no_follow(&dir.join(name)) {
        Ok(f) => f,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Err(FileStatus::NotFound),
        // ELOOP: the name is a symlink (O_NOFOLLOW).
        Err(e) if cfg!(target_os = "linux") && e.raw_os_error() == Some(40) => {
            return Err(FileStatus::NotFound)
        }
        Err(_) => return Err(FileStatus::Failed),
    };
    let meta = file.metadata().map_err(|_| FileStatus::Failed)?;
    if !meta.is_file() {
        return Err(FileStatus::NotFound);
    }
    if meta.len() > u64::from(max_bytes) {
        return Err(FileStatus::TooLarge);
    }
    let mut bytes = Vec::new();
    file.take(u64::from(max_bytes) + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| FileStatus::Failed)?;
    // It grew between the size check and the read.
    if bytes.len() > max_bytes as usize {
        return Err(FileStatus::TooLarge);
    }
    String::from_utf8(bytes).map_err(|_| FileStatus::NotText)
}

/// The whole `ListFiles` call. Blocks: call it on the blocking pool.
pub fn list<U: Udisks>(
    storage: &Storage<U>,
    id: &str,
    suffix: &str,
) -> (FileStatus, Vec<FileEntry>) {
    if !valid_suffix(suffix) {
        return (FileStatus::Invalid, Vec::new());
    }
    match mount_of(storage, id).and_then(|dir| list_dir(&dir, suffix)) {
        Ok(files) => (FileStatus::Ok, files),
        Err(status) => (status, Vec::new()),
    }
}

/// The whole `ReadFile` call. Blocks: call it on the blocking pool.
pub fn read<U: Udisks>(
    storage: &Storage<U>,
    id: &str,
    name: &str,
    max_bytes: u32,
) -> (FileStatus, String) {
    // The cheap checks first, so a bad request is "invalid" whatever the volume is.
    if !valid_name(name) || max_bytes == 0 || max_bytes > MAX_READ {
        return (FileStatus::Invalid, String::new());
    }
    match mount_of(storage, id).and_then(|dir| read_in(&dir, name, max_bytes)) {
        Ok(text) => (FileStatus::Ok, text),
        Err(status) => (status, String::new()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::{FakeUdisks, RawVolume};

    fn stick(mount: &str, removable: bool) -> RawVolume {
        RawVolume {
            id: "/fake/sdb1".to_owned(),
            drive: "/fake/sdb".to_owned(),
            label: "STICK".to_owned(),
            model: "Stick".to_owned(),
            id_type: "vfat".to_owned(),
            size_bytes: 1_000_000,
            free_bytes: 500_000,
            hint_system: false,
            hint_ignore: false,
            drive_removable: removable,
            bus: if removable { "usb" } else { "sata" }.to_owned(),
            mount_points: if mount.is_empty() {
                vec![]
            } else {
                vec![mount.to_owned()]
            },
            read_only: true,
        }
    }

    fn storage_with(volume: RawVolume) -> Storage<FakeUdisks> {
        let storage = Storage::new(FakeUdisks::new(vec![volume]));
        storage.refresh().expect("refresh");
        storage
    }

    #[test]
    fn names_and_suffixes() {
        for ok in [
            "RuyaOS-controls-p1-2026-11-13.json",
            "my controls.JSON",
            "a",
        ] {
            assert!(valid_name(ok), "{ok}");
        }
        let long = "a".repeat(256);
        for bad in [
            "",
            ".hidden.json",
            "../x.json",
            "a/b.json",
            "a\\b.json",
            "a\nb",
            &long,
        ] {
            assert!(!valid_name(bad), "{bad:?}");
        }
        assert!(valid_suffix(".json"));
        for bad in ["json", ".", ".JSON", ".toolongext", "./x", ".js on"] {
            assert!(!valid_suffix(bad), "{bad:?}");
        }
    }

    #[test]
    fn only_regular_files_with_the_suffix_newest_first() {
        let dir = tempfile::tempdir().unwrap();
        let put = |name: &str, text: &str| fs::write(dir.path().join(name), text).unwrap();
        put("old.json", "{}");
        put("UPPER.JSON", "{}");
        put("notes.txt", "x");
        put(".hidden.json", "{}");
        put(".json", "{}");
        fs::create_dir(dir.path().join("folder.json")).unwrap();
        let old = fs::File::options()
            .write(true)
            .open(dir.path().join("old.json"))
            .unwrap();
        old.set_modified(UNIX_EPOCH + std::time::Duration::from_secs(1_000_000))
            .unwrap();
        let files = list_dir(dir.path(), ".json").unwrap();
        let names: Vec<&str> = files.iter().map(|f| f.name.as_str()).collect();
        assert_eq!(names, ["UPPER.JSON", "old.json"]);
        assert_eq!(files[1].modified, 1_000_000);
        assert_eq!(files[1].size_bytes, 2);
        assert_eq!(list_dir(dir.path(), "json"), Err(FileStatus::Invalid));
    }

    #[test]
    fn the_size_is_checked_before_reading() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("big.json"), "x".repeat(65537)).unwrap();
        fs::write(dir.path().join("fits.json"), "x".repeat(65536)).unwrap();
        fs::write(dir.path().join("binary.json"), [0xff, 0xfe, 0x00]).unwrap();
        fs::create_dir(dir.path().join("dir.json")).unwrap();
        assert_eq!(
            read_in(dir.path(), "big.json", 65536),
            Err(FileStatus::TooLarge)
        );
        assert_eq!(
            read_in(dir.path(), "fits.json", 65536).unwrap().len(),
            65536
        );
        assert_eq!(
            read_in(dir.path(), "binary.json", 100),
            Err(FileStatus::NotText)
        );
        assert_eq!(
            read_in(dir.path(), "missing.json", 100),
            Err(FileStatus::NotFound)
        );
        assert!(read_in(dir.path(), "dir.json", 100).is_err());
        assert_eq!(
            read_in(dir.path(), "../fits.json", 65536),
            Err(FileStatus::Invalid)
        );
        assert_eq!(
            read_in(dir.path(), "fits.json", 0),
            Err(FileStatus::Invalid)
        );
        assert_eq!(
            read_in(dir.path(), "fits.json", MAX_READ + 1),
            Err(FileStatus::Invalid)
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_is_never_followed() {
        let dir = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        fs::write(outside.path().join("secret.json"), "{}").unwrap();
        std::os::unix::fs::symlink(
            outside.path().join("secret.json"),
            dir.path().join("link.json"),
        )
        .unwrap();
        assert_eq!(
            read_in(dir.path(), "link.json", 100),
            Err(FileStatus::NotFound)
        );
        assert!(list_dir(dir.path(), ".json").unwrap().is_empty());
    }

    #[test]
    fn only_a_mounted_removable_volume_is_read() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("p.json"), "{\"a\":1}").unwrap();
        let mount = dir.path().to_string_lossy().into_owned();
        let storage = storage_with(stick(&mount, true));
        assert_eq!(
            read(&storage, "/fake/sdb1", "p.json", 100),
            (FileStatus::Ok, "{\"a\":1}".to_owned())
        );
        let (status, files) = list(&storage, "/fake/sdb1", ".json");
        assert_eq!((status, files.len()), (FileStatus::Ok, 1));
        assert_eq!(
            read(&storage, "/fake/nope", "p.json", 100).0,
            FileStatus::UnknownVolume
        );
        assert_eq!(read(&storage, "", "p.json", 100).0, FileStatus::Invalid);
        assert_eq!(
            list(&storage, "/fake/nope", ".json").0,
            FileStatus::UnknownVolume
        );
        assert_eq!(list(&storage, "/fake/sdb1", "json").0, FileStatus::Invalid);
        let internal = storage_with(stick(&mount, false));
        assert_eq!(
            read(&internal, "/fake/sdb1", "p.json", 100).0,
            FileStatus::Unsupported
        );
        // A filesystem the service does not mount: listed, never mounted.
        let mut odd = stick("", true);
        odd.id_type = "squashfs".to_owned();
        let unmounted = storage_with(odd);
        assert_eq!(
            list(&unmounted, "/fake/sdb1", ".json").0,
            FileStatus::Unsupported
        );
    }
}
