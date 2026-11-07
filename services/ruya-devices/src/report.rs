//! Saving a report onto a USB drive (`Storage.SaveReport`, T-226): plain files with names this
//! service knows, onto a removable volume that is mounted and writable, and nothing else. The
//! content is the caller's; what it left out of it (addresses) never gets here.

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::storage::{Storage, Udisks};

/// At most this many files in one call.
pub const MAX_FILES: usize = 4;
/// At most this many bytes of content in all.
pub const MAX_BYTES: usize = 1 << 20;

const PREFIX: &str = "RuyaOS-";
const EXTENSIONS: &[&str] = &[".txt", ".json"];

/// The contract's strings (`Storage.SaveReport`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SaveStatus {
    Ok,
    UnknownVolume,
    Unsupported,
    ReadOnly,
    Full,
    Invalid,
    Failed,
}

impl SaveStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            SaveStatus::Ok => "ok",
            SaveStatus::UnknownVolume => "unknown-volume",
            SaveStatus::Unsupported => "unsupported",
            SaveStatus::ReadOnly => "read-only",
            SaveStatus::Full => "full",
            SaveStatus::Invalid => "invalid",
            SaveStatus::Failed => "failed",
        }
    }
}

/// `RuyaOS-` + 1 to 64 of `A-Za-z0-9._-` + `.txt` or `.json`: no path, nothing hidden.
pub fn valid_name(name: &str) -> bool {
    let Some(rest) = name.strip_prefix(PREFIX) else {
        return false;
    };
    let Some(stem) = EXTENSIONS.iter().find_map(|e| rest.strip_suffix(e)) else {
        return false;
    };
    (1..=64).contains(&stem.len())
        && stem
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// Everything that can be checked before touching the volume.
pub fn check(files: &BTreeMap<String, String>) -> Result<(), SaveStatus> {
    if files.is_empty() || files.len() > MAX_FILES {
        return Err(SaveStatus::Invalid);
    }
    if !files.keys().all(|n| valid_name(n)) {
        return Err(SaveStatus::Invalid);
    }
    let total: usize = files.values().map(String::len).sum();
    if total > MAX_BYTES {
        return Err(SaveStatus::Invalid);
    }
    Ok(())
}

fn status_of(err: &std::io::Error) -> SaveStatus {
    // ENOSPC (Linux) / ERROR_DISK_FULL (Windows); EROFS.
    match err.raw_os_error() {
        Some(28) | Some(112) => SaveStatus::Full,
        Some(30) if cfg!(unix) => SaveStatus::ReadOnly,
        _ => SaveStatus::Failed,
    }
}

fn write_one(dir: &Path, name: &str, text: &str) -> Result<(), SaveStatus> {
    let tmp = dir.join(format!(".{name}.tmp"));
    let result = (|| {
        // A leftover (or a link someone put there: the volume is not ours) is removed, never
        // followed: the file is created exclusively, so nothing outside the volume is written.
        let _ = fs::remove_file(&tmp);
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        fs::rename(&tmp, dir.join(name))
    })();
    if let Err(err) = result {
        let _ = fs::remove_file(&tmp);
        return Err(status_of(&err));
    }
    Ok(())
}

/// Checks, then writes every file into `dir`. Nothing is written when a name or the size is wrong.
/// Blocks: call it on the blocking pool.
pub fn write_files(dir: &Path, files: &BTreeMap<String, String>) -> SaveStatus {
    if let Err(status) = check(files) {
        return status;
    }
    for (name, text) in files {
        if let Err(status) = write_one(dir, name, text) {
            return status;
        }
    }
    SaveStatus::Ok
}

/// The mount point of a volume that may be written to, or the status that says why not.
pub fn target<U: Udisks>(storage: &Storage<U>, id: &str) -> Result<PathBuf, SaveStatus> {
    let volume = storage
        .list()
        .into_iter()
        .find(|v| v.id == id)
        .ok_or(SaveStatus::UnknownVolume)?;
    if !volume.removable || !volume.mounted || volume.mount_point.is_empty() {
        return Err(SaveStatus::Unsupported);
    }
    if volume.read_only {
        return Err(SaveStatus::ReadOnly);
    }
    Ok(PathBuf::from(volume.mount_point))
}

/// The whole call: the status and, when it is "ok", where the files went. Blocks.
pub fn save<U: Udisks>(
    storage: &Storage<U>,
    id: &str,
    files: &BTreeMap<String, String>,
) -> (SaveStatus, String) {
    if id.is_empty() {
        return (SaveStatus::Invalid, String::new());
    }
    // The cheap checks first, so a bad request is "invalid" whatever the volume is.
    if let Err(status) = check(files) {
        return (status, String::new());
    }
    match target(storage, id) {
        Ok(dir) => match write_files(&dir, files) {
            SaveStatus::Ok => (SaveStatus::Ok, dir.to_string_lossy().into_owned()),
            status => (status, String::new()),
        },
        Err(status) => (status, String::new()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::{FakeUdisks, RawVolume};

    fn files(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect()
    }

    fn stick(mount: &str, read_only: bool) -> RawVolume {
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
            drive_removable: true,
            bus: "usb".to_owned(),
            mount_points: if mount.is_empty() {
                vec![]
            } else {
                vec![mount.to_owned()]
            },
            read_only,
        }
    }

    fn storage_with(volume: RawVolume) -> Storage<FakeUdisks> {
        let storage = Storage::new(FakeUdisks::new(vec![volume]));
        storage.refresh().expect("refresh");
        storage
    }

    #[test]
    fn names_are_ours_and_flat() {
        for ok in [
            "RuyaOS-system-report.txt",
            "RuyaOS-system-report.json",
            "RuyaOS-a.b_c-1.txt",
        ] {
            assert!(valid_name(ok), "{ok}");
        }
        for bad in [
            "system-report.txt",
            "RuyaOS-.txt",
            "RuyaOS-x.sh",
            "RuyaOS-x.txt.exe",
            "RuyaOS-../x.txt",
            "RuyaOS-a/b.txt",
            "RuyaOS-a\\b.txt",
            ".RuyaOS-x.txt",
            "RuyaOS-x y.txt",
            "autorun.inf",
            "",
        ] {
            assert!(!valid_name(bad), "{bad}");
        }
        assert!(valid_name(&format!("RuyaOS-{}.txt", "a".repeat(64))));
        assert!(!valid_name(&format!("RuyaOS-{}.txt", "a".repeat(65))));
    }

    #[test]
    fn limits_on_count_and_size() {
        assert_eq!(check(&files(&[])), Err(SaveStatus::Invalid));
        let five: BTreeMap<String, String> = (0..5)
            .map(|i| (format!("RuyaOS-{i}.txt"), "x".to_owned()))
            .collect();
        assert_eq!(check(&five), Err(SaveStatus::Invalid));
        let big = files(&[("RuyaOS-a.txt", &"x".repeat(MAX_BYTES + 1))]);
        assert_eq!(check(&big), Err(SaveStatus::Invalid));
        let edge = files(&[("RuyaOS-a.txt", &"x".repeat(MAX_BYTES))]);
        assert_eq!(check(&edge), Ok(()));
    }

    #[test]
    fn files_land_on_the_volume_and_replace_the_old_ones() {
        let dir = tempfile::tempdir().expect("tempdir");
        let storage = storage_with(stick(dir.path().to_str().expect("utf-8 path"), false));
        let both = files(&[
            ("RuyaOS-system-report.txt", "hello"),
            ("RuyaOS-system-report.json", "{}"),
        ]);
        let (status, path) = save(&storage, "/fake/sdb1", &both);
        assert_eq!(status, SaveStatus::Ok);
        assert_eq!(PathBuf::from(&path), dir.path());
        assert_eq!(
            fs::read_to_string(dir.path().join("RuyaOS-system-report.txt")).expect("txt"),
            "hello"
        );
        assert_eq!(
            fs::read_to_string(dir.path().join("RuyaOS-system-report.json")).expect("json"),
            "{}"
        );
        // Again, with other text: replaced, and no temporary file is left.
        let (again, _) = save(
            &storage,
            "/fake/sdb1",
            &files(&[("RuyaOS-system-report.txt", "second")]),
        );
        assert_eq!(again, SaveStatus::Ok);
        assert_eq!(
            fs::read_to_string(dir.path().join("RuyaOS-system-report.txt")).expect("txt"),
            "second"
        );
        let names: Vec<String> = fs::read_dir(dir.path())
            .expect("dir")
            .map(|e| e.expect("entry").file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names.len(), 2, "no leftovers: {names:?}");
    }

    #[test]
    fn a_leftover_temporary_file_is_replaced() {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join(".RuyaOS-a.txt.tmp"), "stale").expect("stale");
        assert_eq!(
            write_files(dir.path(), &files(&[("RuyaOS-a.txt", "fresh")])),
            SaveStatus::Ok
        );
        assert_eq!(
            fs::read_to_string(dir.path().join("RuyaOS-a.txt")).expect("file"),
            "fresh"
        );
        assert!(!dir.path().join(".RuyaOS-a.txt.tmp").exists());
    }

    // A volume is someone else's: a link where the temporary file goes must not make us write
    // through it to a file elsewhere.
    #[cfg(unix)]
    #[test]
    fn a_link_in_the_way_is_not_followed() {
        let dir = tempfile::tempdir().expect("tempdir");
        let outside = tempfile::tempdir().expect("tempdir");
        let victim = outside.path().join("victim");
        fs::write(&victim, "precious").expect("victim");
        std::os::unix::fs::symlink(&victim, dir.path().join(".RuyaOS-a.txt.tmp")).expect("link");
        assert_eq!(
            write_files(dir.path(), &files(&[("RuyaOS-a.txt", "fresh")])),
            SaveStatus::Ok
        );
        assert_eq!(fs::read_to_string(&victim).expect("victim"), "precious");
        assert_eq!(
            fs::read_to_string(dir.path().join("RuyaOS-a.txt")).expect("file"),
            "fresh"
        );
    }

    #[test]
    fn a_bad_request_writes_nothing() {
        let dir = tempfile::tempdir().expect("tempdir");
        let storage = storage_with(stick(dir.path().to_str().expect("utf-8 path"), false));
        let mixed = files(&[("RuyaOS-a.txt", "fine"), ("../evil.txt", "no")]);
        assert_eq!(save(&storage, "/fake/sdb1", &mixed).0, SaveStatus::Invalid);
        assert_eq!(fs::read_dir(dir.path()).expect("dir").count(), 0);
        assert_eq!(save(&storage, "", &mixed).0, SaveStatus::Invalid);
    }

    #[test]
    fn only_a_mounted_writable_removable_volume_is_accepted() {
        let one = files(&[("RuyaOS-a.txt", "x")]);
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().to_str().expect("utf-8 path");
        assert_eq!(
            save(&storage_with(stick(path, false)), "/fake/nothing", &one).0,
            SaveStatus::UnknownVolume
        );
        assert_eq!(
            save(&storage_with(stick(path, true)), "/fake/sdb1", &one).0,
            SaveStatus::ReadOnly
        );
        // Not mounted: a filesystem we do not mount stays listed and unmounted.
        let mut odd = stick("", false);
        odd.id_type = "f2fs".to_owned();
        assert_eq!(
            save(&storage_with(odd), "/fake/sdb1", &one).0,
            SaveStatus::Unsupported
        );
        let mut internal = stick(path, false);
        internal.drive_removable = false;
        internal.bus = "sata".to_owned();
        internal.mount_points = vec![path.to_owned()];
        assert_eq!(
            save(&storage_with(internal), "/fake/sdb1", &one).0,
            SaveStatus::Unsupported
        );
        assert_eq!(
            fs::read_dir(dir.path()).expect("dir").count(),
            0,
            "nothing written in any of these"
        );
    }

    #[test]
    fn a_missing_mount_point_is_a_failure() {
        let storage = storage_with(stick("/this/path/does/not/exist", false));
        let (status, path) = save(&storage, "/fake/sdb1", &files(&[("RuyaOS-a.txt", "x")]));
        assert_eq!(status, SaveStatus::Failed);
        assert_eq!(path, "");
    }
}
