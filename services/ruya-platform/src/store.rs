//! The player's Platform permissions, one root-only file per profile (lead decision, ADR-046
//! point 4 amended by lead-44): `<root>/profiles/<profile-id>.json`, `<root>` being
//! `/var/lib/ruyaos/platform`. Not in the profile's home, so an app with home access cannot grant
//! itself anything. The folders are 0700 and the files 0600 (root's), written atomically
//! (`ruya-fs`: a temporary file, flushed and renamed). A file is removed when its profile leaves
//! Profiles1.
//!
//! It holds Platform capabilities only (keyed by app id, then capability): never a Flatpak
//! override (network, files, devices: `Store1`, RUY-744) and never a sandbox grant.
//!
//! The format, version 1: `{"version": 1, "apps": {"<app id>": {"<capability>": true|false}}}`.
//! A file that is not that (another version, bad JSON, an invalid id inside, too big) is an
//! error: reads fail closed and a write is refused, so a corrupt file is never overwritten.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::io;
use std::path::{Path, PathBuf};

use ruya_flatpak::valid_app_id;
use ruya_fs::{Dir, Kind};
use ruya_ids::valid_profile_id;
use serde::{Deserialize, Serialize};

use crate::capabilities::valid_capability;

pub const SCHEMA_VERSION: u32 = 1;
/// The largest permission file read.
pub const MAX_FILE: u64 = 1024 * 1024;
const PROFILES: &str = "profiles";
const SUFFIX: &str = ".json";

/// app id -> capability -> allowed.
pub type Choices = BTreeMap<String, BTreeMap<String, bool>>;

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct File {
    version: u32,
    apps: Choices,
}

fn invalid(path: &Path, why: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("{}: {why}", path.display()),
    )
}

pub struct Store {
    root: Dir,
}

impl Store {
    /// The store under `root`, made (0700) when it is missing; the folder above it must exist.
    pub fn open(root: &Path) -> io::Result<Store> {
        let (Some(parent), Some(name)) = (root.parent(), root.file_name()) else {
            return Err(invalid(root, "names no folder"));
        };
        let parent = if parent.as_os_str().is_empty() {
            Path::new(".")
        } else {
            parent
        };
        Ok(Store {
            root: Dir::open(parent)?.make_dirs(Path::new(name))?,
        })
    }

    fn rel(profile: &str) -> io::Result<PathBuf> {
        if !valid_profile_id(profile) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("not a profile id: {profile:?}"),
            ));
        }
        Ok(Path::new(PROFILES).join(format!("{profile}{SUFFIX}")))
    }

    /// The choices of `profile`; none when it has no file.
    pub fn load(&self, profile: &str) -> io::Result<Choices> {
        let rel = Self::rel(profile)?;
        let bytes = match self.root.read(&rel, MAX_FILE) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Choices::new()),
            r => r?,
        };
        let path = self.root.path().join(&rel);
        let file: File =
            serde_json::from_slice(&bytes).map_err(|e| invalid(&path, &e.to_string()))?;
        if file.version != SCHEMA_VERSION {
            return Err(invalid(
                &path,
                &format!("version {} is not {SCHEMA_VERSION}", file.version),
            ));
        }
        for (app, caps) in &file.apps {
            if !valid_app_id(app) {
                return Err(invalid(&path, &format!("not an app id: {app:?}")));
            }
            if let Some(cap) = caps.keys().find(|c| !valid_capability(c)) {
                return Err(invalid(&path, &format!("not a capability: {cap:?}")));
            }
        }
        Ok(file.apps)
    }

    /// The player's choice for (profile, app, capability), `None` when it was never set.
    pub fn choice(
        &self,
        profile: &str,
        app_id: &str,
        capability: &str,
    ) -> io::Result<Option<bool>> {
        Ok(self
            .load(profile)?
            .get(app_id)
            .and_then(|caps| caps.get(capability))
            .copied())
    }

    /// Sets one choice and writes the profile's file at once. A file that cannot be read is left
    /// as it is and the write refused.
    pub fn set(
        &self,
        profile: &str,
        app_id: &str,
        capability: &str,
        allowed: bool,
    ) -> io::Result<()> {
        if !valid_app_id(app_id) || !valid_capability(capability) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("not an app id and capability: {app_id:?} {capability:?}"),
            ));
        }
        let mut apps = self.load(profile)?;
        apps.entry(app_id.to_owned())
            .or_default()
            .insert(capability.to_owned(), allowed);
        let file = File {
            version: SCHEMA_VERSION,
            apps,
        };
        let mut bytes = serde_json::to_vec_pretty(&file).map_err(io::Error::other)?;
        bytes.push(b'\n');
        self.root.write(&Self::rel(profile)?, &bytes)
    }

    /// Removes `profile`'s file (and a temporary file left of it); nothing there is fine.
    pub fn remove(&self, profile: &str) -> io::Result<()> {
        let rel = Self::rel(profile)?;
        self.root.remove(&rel, 0)?;
        let tmp = ruya_fs::temp_name(rel.file_name().unwrap_or_default());
        self.root.remove(&Path::new(PROFILES).join(tmp), 0)
    }

    /// The profiles that have a file (or a temporary file), by the file names.
    pub fn profiles(&self) -> io::Result<BTreeSet<String>> {
        let entries = match self.root.entries(Path::new(PROFILES)) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(BTreeSet::new()),
            r => r?,
        };
        Ok(entries
            .into_iter()
            .filter(|(_, kind)| *kind == Kind::File)
            .filter_map(|(name, _)| profile_of_file(&name))
            .collect())
    }

    /// Removes the file of every profile that is not in `known` (a profile deleted while the
    /// service ran, or before it started). The profiles removed.
    pub fn retain(&self, known: &BTreeSet<String>) -> io::Result<Vec<String>> {
        let mut removed = Vec::new();
        for profile in self.profiles()? {
            if !known.contains(&profile) {
                self.remove(&profile)?;
                removed.push(profile);
            }
        }
        Ok(removed)
    }
}

/// The profile id of a file name `<id>.json` or `<id>.json.tmp`, else `None`.
fn profile_of_file(name: &OsStr) -> Option<String> {
    let name = name.to_str()?;
    let stem = name
        .strip_suffix(".tmp")
        .unwrap_or(name)
        .strip_suffix(SUFFIX)?;
    valid_profile_id(stem).then(|| stem.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    const APP: &str = "org.example.Racer";

    fn store() -> (tempfile::TempDir, Store) {
        let dir = tempfile::tempdir().expect("temp dir");
        let store = Store::open(&dir.path().join("platform")).expect("opens");
        (dir, store)
    }

    fn file(dir: &tempfile::TempDir, profile: &str) -> PathBuf {
        dir.path()
            .join("platform")
            .join(PROFILES)
            .join(format!("{profile}.json"))
    }

    #[test]
    fn a_choice_is_kept_per_profile_app_and_capability() {
        let (_dir, store) = store();
        assert_eq!(store.choice("p1", APP, "lifecycle").expect("reads"), None);
        store.set("p1", APP, "lifecycle", false).expect("writes");
        assert_eq!(
            store.choice("p1", APP, "lifecycle").expect("reads"),
            Some(false)
        );
        assert_eq!(
            store.choice("p2", APP, "lifecycle").expect("reads"),
            None,
            "another profile"
        );
        assert_eq!(
            store
                .choice("p1", "org.example.Other", "lifecycle")
                .expect("reads"),
            None
        );
        assert_eq!(store.choice("p1", APP, "captures").expect("reads"), None);
        store.set("p1", APP, "lifecycle", true).expect("writes");
        assert_eq!(
            store.choice("p1", APP, "lifecycle").expect("reads"),
            Some(true)
        );
    }

    #[test]
    fn the_file_has_a_version_and_is_replaced_whole() {
        let (dir, store) = store();
        store.set("p1", APP, "lifecycle", false).expect("writes");
        let text = std::fs::read_to_string(file(&dir, "p1")).expect("a file");
        let json: serde_json::Value = serde_json::from_str(&text).expect("json");
        assert_eq!(json["version"], 1);
        assert_eq!(json["apps"][APP]["lifecycle"], false);
        let tmp = dir
            .path()
            .join("platform")
            .join(PROFILES)
            .join("p1.json.tmp");
        assert!(!tmp.exists(), "no temporary file is left");
    }

    #[test]
    fn a_stale_temporary_file_does_not_hurt_a_write() {
        let (dir, store) = store();
        let profiles = dir.path().join("platform").join(PROFILES);
        std::fs::create_dir_all(&profiles).expect("mkdir");
        std::fs::write(profiles.join("p1.json.tmp"), b"half a wri").expect("write");
        store.set("p1", APP, "lifecycle", false).expect("writes");
        assert_eq!(
            store.choice("p1", APP, "lifecycle").expect("reads"),
            Some(false)
        );
        assert!(!profiles.join("p1.json.tmp").exists());
    }

    #[test]
    fn a_corrupt_file_fails_closed_and_is_never_overwritten() {
        let (dir, store) = store();
        store.set("p1", APP, "lifecycle", true).expect("writes");
        for bad in [
            "{\"version\":1,\"apps\":",
            "{\"version\":2,\"apps\":{}}",
            "{\"version\":1,\"apps\":{\"Racer\":{\"lifecycle\":true}}}",
            "{\"version\":1,\"apps\":{\"org.example.Racer\":{\"Bad Key\":true}}}",
            "{\"version\":1,\"apps\":{},\"extra\":1}",
            "{\"version\":1,\"apps\":{\"org.example.Racer\":{\"lifecycle\":\"yes\"}}}",
        ] {
            std::fs::write(file(&dir, "p1"), bad).expect("write");
            assert!(store.choice("p1", APP, "lifecycle").is_err(), "{bad}");
            assert!(store.set("p1", APP, "lifecycle", false).is_err(), "{bad}");
            assert_eq!(
                std::fs::read_to_string(file(&dir, "p1")).expect("read"),
                bad
            );
        }
    }

    #[test]
    fn a_file_too_big_is_an_error() {
        let (dir, store) = store();
        store.set("p1", APP, "lifecycle", true).expect("writes");
        std::fs::write(file(&dir, "p1"), vec![b' '; MAX_FILE as usize + 1]).expect("write");
        assert!(store.load("p1").is_err());
    }

    #[test]
    fn only_valid_ids_reach_a_path() {
        let (_dir, store) = store();
        for bad in ["", "../p1", "p1/x", "p 1", &"p".repeat(33)] {
            assert!(store.set(bad, APP, "lifecycle", true).is_err(), "{bad:?}");
            assert!(store.choice(bad, APP, "lifecycle").is_err(), "{bad:?}");
            assert!(store.remove(bad).is_err(), "{bad:?}");
        }
        assert!(store.set("p1", "Racer", "lifecycle", true).is_err());
        assert!(store.set("p1", APP, "Life Cycle", true).is_err());
        assert!(store.profiles().expect("lists").is_empty());
    }

    #[test]
    fn a_profile_leaving_takes_its_file() {
        let (dir, store) = store();
        for p in ["p1", "p2", "g1"] {
            store.set(p, APP, "lifecycle", false).expect("writes");
        }
        let profiles = dir.path().join("platform").join(PROFILES);
        std::fs::write(profiles.join("p3.json.tmp"), b"{").expect("a stale temporary file");
        std::fs::write(profiles.join("notes.txt"), b"x").expect("another file");
        let known: BTreeSet<String> = ["p1".to_owned()].into();
        assert_eq!(
            store.retain(&known).expect("sweeps"),
            vec!["g1", "p2", "p3"]
        );
        assert!(file(&dir, "p1").exists());
        assert!(!file(&dir, "p2").exists() && !file(&dir, "g1").exists());
        assert!(!profiles.join("p3.json.tmp").exists());
        assert!(
            profiles.join("notes.txt").exists(),
            "a file that is no profile's is left"
        );
        assert_eq!(store.choice("p2", APP, "lifecycle").expect("reads"), None);
        store.remove("p9").expect("nothing there is fine");
    }

    #[cfg(unix)]
    #[test]
    fn folders_and_files_are_root_only() {
        use std::os::unix::fs::PermissionsExt;
        let (dir, store) = store();
        store.set("p1", APP, "lifecycle", true).expect("writes");
        let mode = |p: &Path| std::fs::metadata(p).expect("stat").permissions().mode() & 0o777;
        assert_eq!(mode(&dir.path().join("platform")), 0o700);
        assert_eq!(mode(&dir.path().join("platform").join(PROFILES)), 0o700);
        assert_eq!(mode(&file(&dir, "p1")), 0o600);
    }
}
