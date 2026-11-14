//! Profile records persisted as one root-only TOML file (default
//! `/var/lib/ruyaos/profiles.toml`, mode 0600, written atomically).

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

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
    /// never overwritten silently.
    pub fn open(path: impl Into<PathBuf>) -> io::Result<Store> {
        let path = path.into();
        let data = match fs::read_to_string(&path) {
            Ok(text) => {
                toml::from_str(&text).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => Data::default(),
            Err(e) => return Err(e),
        };
        Ok(Store { path, data })
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
        if let Some(dir) = self.path.parent() {
            fs::create_dir_all(dir)?;
        }
        let tmp = tmp_path(&self.path);
        fs::write(&tmp, text)?;
        restrict_permissions(&tmp)?;
        fs::rename(&tmp, &self.path)
    }
}

fn tmp_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".tmp");
    path.with_file_name(name)
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
