//! Profile records persisted as one private TOML file, written atomically (mode 0600). In the
//! image it is `/var/lib/ruyaos/profiles/profiles.toml`: the store has its own directory (0700,
//! owned by the service's own user `ruya-profiles`, ADR-049), which every other root `ruya-*` unit
//! but the listed exceptions hides with `InaccessiblePaths=` (RUY-1130, `01` section 3 item 11). A
//! hidden directory holds across the store's tmp + rename; a hidden file would not (the overmount
//! stays on the old inode). The directory is the unit's `StateDirectory` (and a tmpfiles line);
//! nothing moves an older image's store (owner, 2026-11-27: there are no installs to migrate).

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

/// The store's own directory under the state directory (RUY-1130).
pub const STORE_DIR: &str = "profiles";
/// The store file, in `STORE_DIR`.
pub const STORE_FILE: &str = "profiles.toml";

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Admin,
    Standard,
    Guest,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Admin => "admin",
            Role::Standard => "standard",
            Role::Guest => "guest",
        }
    }

    pub fn parse(s: &str) -> Option<Role> {
        match s {
            "admin" => Some(Role::Admin),
            "standard" => Some(Role::Standard),
            "guest" => Some(Role::Guest),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Profile {
    pub id: String,
    pub name: String,
    /// Avatar colour as "#rrggbb" until real avatar images exist.
    pub avatar: String,
    pub role: Role,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pin_hash: Option<String>,
}

impl Profile {
    pub fn has_pin(&self) -> bool {
        self.pin_hash.is_some()
    }
}

/// A temporary guest (RUY-125): a profile user with no name and no PIN, wiped on Lock, on a
/// session change and at service start. Kept apart from `profiles`, so nothing that lists or
/// changes profiles can reach it by accident.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Guest {
    pub id: String,
    pub avatar: String,
    /// 1, 2 or 3: the shell names it "Guest", "Guest 2", "Guest 3".
    pub number: u32,
    pub uid: u32,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Data {
    #[serde(default)]
    next_id: u32,
    /// The lowest guest uid not handed out yet; only goes up (0 = none handed out so far).
    #[serde(default, skip_serializing_if = "is_zero")]
    next_guest_uid: u32,
    #[serde(default, rename = "profile")]
    profiles: Vec<Profile>,
    #[serde(default, rename = "guest", skip_serializing_if = "Vec::is_empty")]
    guests: Vec<Guest>,
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

#[derive(Debug)]
pub struct Store {
    path: PathBuf,
    data: Data,
}

impl Store {
    /// Opens the store; a missing file is an empty store. A corrupt file is an error and is
    /// never overwritten silently, and so is a file that cannot be read (`data_of`).
    pub fn open(path: impl Into<PathBuf>) -> io::Result<Store> {
        let path = path.into();
        let data = data_of(fs::read(&path))?;
        Ok(Store { path, data })
    }

    /// The store file.
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn profiles(&self) -> &[Profile] {
        &self.data.profiles
    }

    pub fn get(&self, id: &str) -> Option<&Profile> {
        self.data.profiles.iter().find(|p| p.id == id)
    }

    pub fn get_mut(&mut self, id: &str) -> Option<&mut Profile> {
        self.data.profiles.iter_mut().find(|p| p.id == id)
    }

    /// The id the next inserted profile will get.
    pub fn peek_next_id(&self) -> String {
        format!("p{}", self.data.next_id + 1)
    }

    pub fn insert(&mut self, mut profile: Profile) -> &Profile {
        self.data.next_id += 1;
        profile.id = format!("p{}", self.data.next_id);
        self.data.profiles.push(profile);
        self.data.profiles.last().unwrap()
    }

    /// Takes the next profile id for a guest: `next_id` goes up now, so the id is never handed out
    /// again even when making the guest fails.
    pub fn reserve_id(&mut self) -> String {
        self.data.next_id += 1;
        format!("p{}", self.data.next_id)
    }

    pub fn guests(&self) -> &[Guest] {
        &self.data.guests
    }

    pub fn guest(&self, id: &str) -> Option<&Guest> {
        self.data.guests.iter().find(|g| g.id == id)
    }

    pub fn insert_guest(&mut self, guest: Guest) {
        self.data.guests.push(guest);
    }

    pub fn remove_guest(&mut self, id: &str) -> Option<(usize, Guest)> {
        let index = self.data.guests.iter().position(|g| g.id == id)?;
        Some((index, self.data.guests.remove(index)))
    }

    pub fn restore_guest(&mut self, index: usize, guest: Guest) {
        self.data
            .guests
            .insert(index.min(self.data.guests.len()), guest);
    }

    /// The lowest guest uid not handed out yet (`first` when none was).
    pub fn next_guest_uid(&self, first: u32) -> u32 {
        self.data.next_guest_uid.max(first)
    }

    /// Moves the guest uid counter on; it never goes back.
    pub fn set_next_guest_uid(&mut self, uid: u32) {
        self.data.next_guest_uid = self.data.next_guest_uid.max(uid);
    }

    /// Removes a profile from memory; `next_id` is untouched so ids are never reused.
    pub fn remove(&mut self, id: &str) -> Option<(usize, Profile)> {
        let index = self.data.profiles.iter().position(|p| p.id == id)?;
        Some((index, self.data.profiles.remove(index)))
    }

    /// Puts a profile taken out with `remove` back (used when saving failed).
    pub fn restore(&mut self, index: usize, profile: Profile) {
        self.data
            .profiles
            .insert(index.min(self.data.profiles.len()), profile);
    }

    pub fn save(&self) -> io::Result<()> {
        let text = toml::to_string_pretty(&self.data)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        write_atomic(&self.path, text.as_bytes())
    }
}

/// The store file of a state directory: `<state_dir>/profiles/profiles.toml`.
pub fn file_in(state_dir: &Path) -> PathBuf {
    state_dir.join(STORE_DIR).join(STORE_FILE)
}

/// The store's data from the read of its file: only a missing file is an empty store. Any other
/// failure is an error, never an empty store: in the image a store this user cannot read
/// (`PermissionDenied`: an older image, running as root, wrote it as root) stops the service, so
/// nobody is handed the first-run setup and its unguarded first admin (01 section 4).
fn data_of(read: io::Result<Vec<u8>>) -> io::Result<Data> {
    match read {
        Ok(bytes) => parse(&bytes),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Data::default()),
        Err(e) => Err(e),
    }
}

fn parse(bytes: &[u8]) -> io::Result<Data> {
    let text =
        std::str::from_utf8(bytes).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    toml::from_str(text).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

fn tmp_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".tmp");
    path.with_file_name(name)
}

/// The store's one write: a 0600 tmp file next to `path`, flushed to disk, renamed over `path`,
/// and the directory flushed, so a crash leaves the old or the new content, never a part. A
/// missing directory is made 0700.
fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        if !dir.as_os_str().is_empty() && !dir.exists() {
            create_private_dir_all(dir)?;
        }
    }
    let tmp = tmp_path(path);
    let mut file = private_file_options().open(&tmp)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);
    // The tmp file may be left from a crash with another mode: the open did not set it then.
    restrict_permissions(&tmp, 0o600)?;
    fs::rename(&tmp, path)?;
    sync_parent(path)
}

#[cfg(unix)]
fn create_private_dir_all(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
}

#[cfg(not(unix))]
fn create_private_dir_all(dir: &Path) -> io::Result<()> {
    fs::create_dir_all(dir)
}

#[cfg(unix)]
fn private_file_options() -> fs::OpenOptions {
    use std::os::unix::fs::OpenOptionsExt;
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true).mode(0o600);
    options
}

#[cfg(not(unix))]
fn private_file_options() -> fs::OpenOptions {
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    options
}

#[cfg(unix)]
fn restrict_permissions(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn restrict_permissions(_path: &Path, _mode: u32) -> io::Result<()> {
    Ok(())
}

/// Flushes the directory entry of `path` (a rename or a remove in it) to disk.
#[cfg(unix)]
fn sync_parent(path: &Path) -> io::Result<()> {
    match path.parent() {
        Some(dir) if !dir.as_os_str().is_empty() => fs::File::open(dir)?.sync_all(),
        _ => fs::File::open(".")?.sync_all(),
    }
}

/// Windows cannot open a directory as a file; the host tests do not need the flush.
#[cfg(not(unix))]
fn sync_parent(_path: &Path) -> io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(name: &str, role: Role) -> Profile {
        Profile {
            id: String::new(),
            name: name.into(),
            avatar: "#3a5bd9".into(),
            role,
            pin_hash: None,
        }
    }

    #[test]
    fn missing_file_is_empty_and_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub/profiles.toml");
        let mut store = Store::open(&path).unwrap();
        assert!(store.profiles().is_empty());
        assert_eq!(store.peek_next_id(), "p1");

        let id = store.insert(profile("Ada", Role::Admin)).id.clone();
        store.get_mut(&id).unwrap().pin_hash = Some("$argon2id$x".into());
        store.insert(profile("Bo", Role::Standard));
        store.save().unwrap();

        let reopened = Store::open(&path).unwrap();
        assert_eq!(reopened.profiles(), store.profiles());
        assert_eq!(reopened.peek_next_id(), "p3");
        assert!(!dir.path().join("sub/profiles.toml.tmp").exists());
    }

    #[test]
    fn ids_are_never_reused() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path().join("p.toml")).unwrap();
        store.insert(profile("A", Role::Admin));
        store.data.profiles.clear(); // simulate deletion
        assert_eq!(store.insert(profile("B", Role::Standard)).id, "p2");
    }

    #[test]
    fn guests_and_the_guest_uid_counter_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("profiles.toml");
        let mut store = Store::open(&path).unwrap();
        assert_eq!(store.next_guest_uid(50000), 50000);
        store.insert(profile("Ada", Role::Admin));
        let id = store.reserve_id();
        assert_eq!(id, "p2");
        store.insert_guest(Guest {
            id: id.clone(),
            avatar: "#d9483a".into(),
            number: 1,
            uid: 50000,
        });
        store.set_next_guest_uid(50001);
        store.set_next_guest_uid(40000); // never goes back
        store.save().unwrap();

        let reopened = Store::open(&path).unwrap();
        assert_eq!(reopened.guests(), store.guests());
        assert_eq!(reopened.profiles().len(), 1, "a guest is not a profile");
        assert_eq!(reopened.next_guest_uid(50000), 50001);
        assert_eq!(
            reopened.peek_next_id(),
            "p3",
            "a guest's id is never reused"
        );
    }

    #[test]
    fn corrupt_file_is_an_error_not_an_empty_store() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("profiles.toml");
        fs::write(&path, "this is = = not toml").unwrap();
        assert_eq!(
            Store::open(&path).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn only_a_missing_file_is_an_empty_store() {
        assert!(data_of(Err(io::ErrorKind::NotFound.into()))
            .unwrap()
            .profiles
            .is_empty());
        // A store the service user cannot read (an older image wrote it as root) is an error,
        // never an empty store; so is any other failed read.
        for kind in [
            io::ErrorKind::PermissionDenied,
            io::ErrorKind::Interrupted,
            io::ErrorKind::Other,
        ] {
            assert_eq!(data_of(Err(kind.into())).unwrap_err().kind(), kind);
        }
    }

    /// A store file with one profile named `name` (with a PIN hash), saved at `path`.
    #[cfg(unix)]
    fn saved_store(path: &Path, name: &str) -> Vec<u8> {
        let mut store = Store::open(path).unwrap();
        let id = store.insert(profile(name, Role::Admin)).id.clone();
        store.get_mut(&id).unwrap().pin_hash = Some("$argon2id$x".into());
        store.save().unwrap();
        fs::read(path).unwrap()
    }

    #[cfg(unix)]
    #[test]
    fn save_makes_a_missing_directory_0700() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        saved_store(&dir.path().join("sub/profiles.toml"), "Ada");
        assert_eq!(
            fs::metadata(dir.path().join("sub"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
    }

    #[cfg(unix)]
    #[test]
    fn file_is_root_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("profiles.toml");
        let mut store = Store::open(&path).unwrap();
        store.insert(profile("A", Role::Admin));
        store.save().unwrap();
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
