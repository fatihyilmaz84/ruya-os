//! The per-profile store: one root-only JSON file per profile (default
//! `/var/lib/ruyaos/notifications/<profile>.json`, mode 0600, written atomically with tmp +
//! rename) holding the profile's items and settings. A file that does not parse is logged and
//! moved aside (`<profile>.json.corrupt`), never overwritten silently.

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::history::Entry;
use crate::settings::Settings;

/// What one profile's file holds.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProfileData {
    /// The highest id this profile ever had, so ids stay above it after a restart even when
    /// the item itself was cleared.
    #[serde(default)]
    pub last_id: u32,
    #[serde(default)]
    pub settings: Settings,
    /// Oldest posted first.
    #[serde(default)]
    pub items: Vec<Entry>,
}

/// Where the core keeps a profile's data. `FileStore` on the console, `MemoryStore` in tests.
pub trait Persist {
    fn save(&mut self, profile: &str, data: &ProfileData) -> io::Result<()>;
    fn remove(&mut self, profile: &str) -> io::Result<()>;
}

/// A Profiles1 id that is safe as a file name (the grammar `ruya-session` checks too).
pub fn valid_profile_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 32
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

#[derive(Debug, Clone)]
pub struct FileStore {
    dir: PathBuf,
}

impl FileStore {
    pub fn new(dir: impl Into<PathBuf>) -> FileStore {
        FileStore { dir: dir.into() }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    fn path(&self, profile: &str) -> PathBuf {
        self.dir.join(format!("{profile}.json"))
    }

    /// Every stored profile. A missing directory is an empty store. A file that cannot be parsed
    /// is moved aside to `<name>.corrupt` (`.corrupt.1`, ... when that exists) and logged; the
    /// profile starts empty.
    pub fn load_all(&self) -> io::Result<Vec<(String, ProfileData)>> {
        let entries = match fs::read_dir(&self.dir) {
            Ok(entries) => entries,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e),
        };
        let mut out = Vec::new();
        for entry in entries {
            let path = entry?.path();
            let Some(profile) = path
                .file_name()
                .and_then(|n| n.to_str())
                .and_then(|n| n.strip_suffix(".json"))
                .filter(|p| valid_profile_id(p))
                .map(str::to_owned)
            else {
                continue; // a leftover .tmp, a .corrupt, anything else
            };
            let parsed = fs::read_to_string(&path)
                .map_err(|e| e.to_string())
                .and_then(|text| {
                    serde_json::from_str::<ProfileData>(&text).map_err(|e| e.to_string())
                });
            match parsed {
                Ok(data) => out.push((profile, data)),
                Err(err) => {
                    let aside = move_aside(&path)?;
                    eprintln!(
                        "ruya-notifications: {} is corrupt ({err}); moved aside to {}, the profile starts empty",
                        path.display(),
                        aside.display()
                    );
                }
            }
        }
        out.sort_by(|a, b| a.0.cmp(&b.0));
        Ok(out)
    }
}

/// Renames `path` to the first free `<path>.corrupt`, `<path>.corrupt.1`, ...
fn move_aside(path: &Path) -> io::Result<PathBuf> {
    let base = path.as_os_str().to_os_string();
    for n in 0u32.. {
        let mut name = base.clone();
        if n == 0 {
            name.push(".corrupt");
        } else {
            name.push(format!(".corrupt.{n}"));
        }
        let aside = PathBuf::from(name);
        if !aside.exists() {
            fs::rename(path, &aside)?;
            return Ok(aside);
        }
    }
    Err(io::Error::other("no free .corrupt name"))
}

impl Persist for FileStore {
    fn save(&mut self, profile: &str, data: &ProfileData) -> io::Result<()> {
        if !valid_profile_id(profile) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "not a profile id",
            ));
        }
        let text = serde_json::to_string(data)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        create_private_dir(&self.dir)?;
        let path = self.path(profile);
        let mut tmp = path.as_os_str().to_os_string();
        tmp.push(".tmp");
        let tmp = PathBuf::from(tmp);
        {
            use std::io::Write;
            let mut file = fs::File::create(&tmp)?;
            file.write_all(text.as_bytes())?;
            // On disk before the rename, so a power cut leaves the old file or the new one,
            // never an empty one (as ruya-session's and ruya-store's stores do).
            file.sync_all()?;
        }
        restrict_permissions(&tmp)?;
        fs::rename(&tmp, &path)
    }

    /// Removes the profile's file and whatever else of it is left: a `.tmp` and every
    /// `.corrupt*` copy (a deleted profile's data is gone, 03 §1.4).
    fn remove(&mut self, profile: &str) -> io::Result<()> {
        if !valid_profile_id(profile) {
            return Ok(());
        }
        let mut prefix = self
            .path(profile)
            .file_name()
            .unwrap_or_default()
            .to_os_string();
        prefix.push(".");
        let prefix = prefix.to_string_lossy().into_owned();
        let mut doomed = vec![self.path(profile)];
        if let Ok(entries) = fs::read_dir(&self.dir) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if let Some(rest) = name.strip_prefix(&prefix) {
                    if rest == "tmp" || rest.starts_with("corrupt") {
                        doomed.push(entry.path());
                    }
                }
            }
        }
        for path in doomed {
            match fs::remove_file(&path) {
                Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
                _ => {}
            }
        }
        Ok(())
    }
}

#[cfg(unix)]
fn create_private_dir(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    if dir.is_dir() {
        return Ok(());
    }
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
}

#[cfg(not(unix))]
fn create_private_dir(dir: &Path) -> io::Result<()> {
    fs::create_dir_all(dir)
}

#[cfg(unix)]
fn restrict_permissions(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
}

#[cfg(not(unix))]
fn restrict_permissions(_path: &Path) -> io::Result<()> {
    Ok(())
}

/// The store of the tests: the profiles' data in memory, and an on/off switch for failures.
#[derive(Debug, Default, Clone)]
pub struct MemoryStore {
    pub files: BTreeMap<String, ProfileData>,
    pub fail: bool,
}

impl Persist for MemoryStore {
    fn save(&mut self, profile: &str, data: &ProfileData) -> io::Result<()> {
        if self.fail {
            return Err(io::Error::other("the test store fails"));
        }
        self.files.insert(profile.to_owned(), data.clone());
        Ok(())
    }

    fn remove(&mut self, profile: &str) -> io::Result<()> {
        if self.fail {
            return Err(io::Error::other("the test store fails"));
        }
        self.files.remove(profile);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::history::Item;

    fn data(id: u32) -> ProfileData {
        ProfileData {
            last_id: id,
            settings: Settings {
                quiet: true,
                ..Settings::default()
            },
            items: vec![Entry {
                key: "update-restart".into(),
                item: Item {
                    id,
                    source: "updates".into(),
                    app_id: String::new(),
                    kind: "warning".into(),
                    title: "Restart to update".into(),
                    body: String::new(),
                    icon: String::new(),
                    actions: vec![("restart".into(), "Restart now".into())],
                    urgency: "normal".into(),
                    pinned: true,
                    unread: true,
                    time: 1_800_000_000_000,
                },
            }],
        }
    }

    #[test]
    fn a_saved_profile_loads_back_the_same() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = FileStore::new(dir.path().join("notifications"));
        store.save("p1", &data(7)).unwrap();
        store.save("p2", &ProfileData::default()).unwrap();
        let loaded = FileStore::new(dir.path().join("notifications"))
            .load_all()
            .unwrap();
        assert_eq!(
            loaded,
            vec![
                ("p1".to_owned(), data(7)),
                ("p2".to_owned(), ProfileData::default())
            ]
        );
        assert!(
            !dir.path().join("notifications/p1.json.tmp").exists(),
            "the tmp file was renamed"
        );
    }

    #[test]
    fn a_missing_directory_is_an_empty_store() {
        let dir = tempfile::tempdir().unwrap();
        assert!(FileStore::new(dir.path().join("none"))
            .load_all()
            .unwrap()
            .is_empty());
    }

    #[test]
    fn a_corrupt_file_is_moved_aside_never_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = FileStore::new(dir.path());
        store.save("p1", &data(3)).unwrap();
        fs::write(dir.path().join("p2.json"), "{ not json").unwrap();
        fs::write(dir.path().join("p2.json.corrupt"), "an older corrupt file").unwrap();
        let loaded = store.load_all().unwrap();
        assert_eq!(loaded, vec![("p1".to_owned(), data(3))], "p2 starts empty");
        assert!(!dir.path().join("p2.json").exists());
        assert_eq!(
            fs::read_to_string(dir.path().join("p2.json.corrupt.1")).unwrap(),
            "{ not json",
            "the bad file is kept, next to the older one"
        );
        assert_eq!(
            fs::read_to_string(dir.path().join("p2.json.corrupt")).unwrap(),
            "an older corrupt file"
        );
    }

    #[test]
    fn other_files_and_unsafe_names_are_ignored() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("p1.json.tmp"), "half").unwrap();
        fs::write(dir.path().join("notes.txt"), "x").unwrap();
        fs::write(dir.path().join("a.b.json"), "{}").unwrap();
        assert!(FileStore::new(dir.path()).load_all().unwrap().is_empty());
        let mut store = FileStore::new(dir.path());
        assert!(store.save("../evil", &ProfileData::default()).is_err());
        assert!(!dir.path().join("../evil.json").exists());
    }

    #[test]
    fn remove_deletes_the_file_and_a_missing_one_is_fine() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = FileStore::new(dir.path());
        store.save("p4", &data(1)).unwrap();
        store.remove("p4").unwrap();
        assert!(!dir.path().join("p4.json").exists());
        store.remove("p4").unwrap();
    }

    #[test]
    fn remove_also_deletes_the_tmp_and_corrupt_copies_but_no_other_profile() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = FileStore::new(dir.path());
        store.save("p4", &data(1)).unwrap();
        store.save("p40", &data(1)).unwrap();
        fs::write(dir.path().join("p4.json.tmp"), "half").unwrap();
        fs::write(dir.path().join("p4.json.corrupt"), "old").unwrap();
        fs::write(dir.path().join("p4.json.corrupt.1"), "older").unwrap();
        store.remove("p4").unwrap();
        for left in [
            "p4.json",
            "p4.json.tmp",
            "p4.json.corrupt",
            "p4.json.corrupt.1",
        ] {
            assert!(!dir.path().join(left).exists(), "{left} is gone");
        }
        assert!(
            dir.path().join("p40.json").exists(),
            "another profile's file stays"
        );
    }

    #[cfg(unix)]
    #[test]
    fn files_are_root_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let mut store = FileStore::new(dir.path().join("n"));
        store.save("p1", &data(1)).unwrap();
        let mode = fs::metadata(dir.path().join("n/p1.json"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
        let dmode = fs::metadata(dir.path().join("n"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(dmode & 0o777, 0o700);
    }

    #[test]
    fn profile_ids_that_are_file_names() {
        for ok in ["p1", "p23", "guest_1", "a-b"] {
            assert!(valid_profile_id(ok), "{ok}");
        }
        for bad in ["", "../p1", "p1/x", "p 1", "p1.json", &"p".repeat(33)] {
            assert!(!valid_profile_id(bad), "{bad}");
        }
    }
}
