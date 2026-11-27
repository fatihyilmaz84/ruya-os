//! Profile records persisted as one private TOML file, written atomically (mode 0600). In the
//! image it is `/var/lib/ruyaos/profiles/profiles.toml`: the store has its own directory (0700,
//! owned by the service's own user `ruya-profiles`, ADR-049), which every other root `ruya-*` unit
//! but the listed exceptions hides with `InaccessiblePaths=` (RUY-1130, `01` section 3 item 11). A
//! hidden directory holds across the store's tmp + rename; a hidden file would not (the overmount
//! stays on the old inode). `Store::open_in` moves the store of earlier images,
//! `/var/lib/ruyaos/profiles.toml`, into that directory once, and `hand_over` gives the directory
//! and its files to the service's user; both run as root before the service starts
//! (`ruya-profiles --migrate`).

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

/// The store's own directory under the state directory (RUY-1130).
pub const STORE_DIR: &str = "profiles";
/// The store file, in `STORE_DIR` (and, before RUY-1130, directly in the state directory).
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
    /// never overwritten silently.
    pub fn open(path: impl Into<PathBuf>) -> io::Result<Store> {
        let path = path.into();
        let data = match fs::read(&path) {
            Ok(bytes) => parse(&bytes)?,
            Err(e) if e.kind() == io::ErrorKind::NotFound => Data::default(),
            Err(e) => return Err(e),
        };
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

    /// Opens the store of a state directory, `<state_dir>/profiles/profiles.toml`, after making
    /// sure its directory exists with mode 0700 and moving an earlier image's store,
    /// `<state_dir>/profiles.toml`, into it (`migrate`). Returns what the move did.
    /// It needs root (the old store is root's, in root's directory), so the image runs it in the
    /// unit's `ExecStartPre=+` step (`ruya-profiles --migrate`), followed by `hand_over`; the
    /// service itself, as its own user, opens `file_in(state_dir)` with `Store::open`.
    pub fn open_in(state_dir: &Path) -> io::Result<(Store, Migration)> {
        let path = file_in(state_dir);
        if let Some(dir) = path.parent() {
            ensure_private_dir(dir)?;
        }
        let migration = migrate(&state_dir.join(STORE_FILE), &path)?;
        Ok((Store::open(path)?, migration))
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

/// The step after `migrate` (ADR-049): the service runs as its own user, so the store's directory
/// and every entry in it (the store, a tmp file a crash left, a `.rollback`) are handed to that
/// user with `chown`, which must not follow a link (`lchown` in the image). The directory goes
/// first, then its entries in name order; the paths handed over are returned. Running it again
/// changes nothing; an older image that ran as root and wrote the store again as root (a
/// rollback, then this image) is put right at the next start.
pub fn hand_over(
    dir: &Path,
    chown: &mut dyn FnMut(&Path) -> io::Result<()>,
) -> io::Result<Vec<PathBuf>> {
    let mut entries = fs::read_dir(dir)?
        .map(|e| e.map(|e| e.path()))
        .collect::<io::Result<Vec<PathBuf>>>()?;
    entries.sort();
    let mut handed = vec![dir.to_path_buf()];
    handed.extend(entries);
    for path in &handed {
        chown(path)?;
    }
    Ok(handed)
}

/// What `migrate` did with the store of an earlier image.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Migration {
    /// There was no old store: nothing to move.
    Nothing,
    /// The old store was renamed to the new path.
    Moved,
    /// Both were there with the same bytes: the old one is removed.
    OldRemoved,
    /// Both were there and differed: an older image, after a rollback, wrote a store of its own.
    /// The new one wins (changes made after the rollback are not merged) and the old one is kept,
    /// hidden, at `rollback_path(new)`.
    OldKept,
}

/// Where `migrate` keeps an old store that differs from the new one: `<new>.rollback`, in the
/// store's hidden directory (a later one replaces it).
pub fn rollback_path(new: &Path) -> PathBuf {
    let mut name = new.file_name().unwrap_or_default().to_os_string();
    name.push(".rollback");
    new.with_file_name(name)
}

/// Moves the store at `old` to `new` (in the same filesystem; `new`'s directory exists), once, by
/// `rename(2)`: at every instant exactly one of the two paths names the store, its inode and mode
/// carry over, and both directories are flushed after it. When both exist (a rollback to an older
/// image, then this one again) the new store wins: the old file is removed when its bytes are the
/// same, else renamed to `rollback_path(new)`. A store that does not parse is an error and is left
/// where it is, as `Store::open` never overwrites a corrupt store. Running it again changes nothing.
pub fn migrate(old: &Path, new: &Path) -> io::Result<Migration> {
    // An earlier image's crash between its write and its rename left the hashes in a tmp file
    // next to the old store, where every root service can read them.
    remove_if_present(&tmp_path(old))?;
    let old_bytes = match fs::read(old) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Migration::Nothing),
        Err(e) => return Err(e),
    };
    let migration = match fs::read(new) {
        Ok(new_bytes) => {
            parse(&new_bytes)?;
            if new_bytes == old_bytes {
                fs::remove_file(old)?;
                Migration::OldRemoved
            } else {
                let kept = rollback_path(new);
                fs::rename(old, &kept)?;
                restrict_permissions(&kept, 0o600)?;
                Migration::OldKept
            }
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            parse(&old_bytes)?;
            fs::rename(old, new)?;
            restrict_permissions(new, 0o600)?;
            Migration::Moved
        }
        Err(e) => return Err(e),
    };
    sync_parent(new)?;
    sync_parent(old)?;
    Ok(migration)
}

fn parse(bytes: &[u8]) -> io::Result<Data> {
    let text =
        std::str::from_utf8(bytes).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    toml::from_str(text).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

fn remove_if_present(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
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

/// Makes the store's directory if needed and sets it to 0700 (also when it was there with
/// another mode, made by hand or by an older tmpfiles line).
fn ensure_private_dir(dir: &Path) -> io::Result<()> {
    create_private_dir_all(dir)?;
    restrict_permissions(dir, 0o700)
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

    /// A store file with one profile named `name` (with a PIN hash), saved at `path`.
    fn saved_store(path: &Path, name: &str) -> Vec<u8> {
        let mut store = Store::open(path).unwrap();
        let id = store.insert(profile(name, Role::Admin)).id.clone();
        store.get_mut(&id).unwrap().pin_hash = Some("$argon2id$x".into());
        store.save().unwrap();
        fs::read(path).unwrap()
    }

    fn names(store: &Store) -> Vec<&str> {
        store.profiles().iter().map(|p| p.name.as_str()).collect()
    }

    #[test]
    fn a_fresh_state_dir_gets_the_store_directory_and_nothing_to_move() {
        let state = tempfile::tempdir().unwrap();
        let (mut store, migration) = Store::open_in(state.path()).unwrap();
        assert_eq!(migration, Migration::Nothing);
        assert!(store.profiles().is_empty());
        assert!(state.path().join(STORE_DIR).is_dir());
        assert!(!state.path().join(STORE_FILE).exists());

        store.insert(profile("Ada", Role::Admin));
        store.save().unwrap();
        assert!(state.path().join(STORE_DIR).join(STORE_FILE).is_file());
        assert!(!state.path().join(STORE_FILE).exists());
        let (reopened, again) = Store::open_in(state.path()).unwrap();
        assert_eq!((names(&reopened), again), (vec!["Ada"], Migration::Nothing));
    }

    #[test]
    fn an_old_store_alone_is_renamed_into_the_directory() {
        let state = tempfile::tempdir().unwrap();
        let old = state.path().join(STORE_FILE);
        let bytes = saved_store(&old, "Ada");
        // An earlier image's crash before its rename left this next to the old store.
        fs::write(state.path().join("profiles.toml.tmp"), "half").unwrap();

        let (store, migration) = Store::open_in(state.path()).unwrap();
        assert_eq!(migration, Migration::Moved);
        assert_eq!(names(&store), vec!["Ada"]);
        assert!(store.profiles()[0].has_pin());
        let new = state.path().join(STORE_DIR).join(STORE_FILE);
        assert_eq!(fs::read(&new).unwrap(), bytes);
        assert!(!old.exists(), "the old store is renamed away");
        assert!(!state.path().join("profiles.toml.tmp").exists());

        // Idempotent: the next start finds nothing to move and the same store.
        let (again, migration) = Store::open_in(state.path()).unwrap();
        assert_eq!(
            (names(&again), migration),
            (vec!["Ada"], Migration::Nothing)
        );
        assert_eq!(fs::read(&new).unwrap(), bytes);
    }

    #[test]
    fn after_the_move_the_directory_and_every_file_in_it_are_handed_over() {
        let state = tempfile::tempdir().unwrap();
        let old = state.path().join(STORE_FILE);
        saved_store(&old, "Ada");
        let (store, migration) = Store::open_in(state.path()).unwrap();
        assert_eq!(migration, Migration::Moved);
        let dir = state.path().join(STORE_DIR);
        // What a crash and a rollback leave next to the store.
        fs::write(dir.join("profiles.toml.tmp"), "half").unwrap();
        fs::write(rollback_path(store.path()), "old").unwrap();

        let mut chowned = Vec::new();
        let handed = hand_over(&dir, &mut |p| {
            chowned.push(p.to_path_buf());
            Ok(())
        })
        .unwrap();
        let want = vec![
            dir.clone(),
            dir.join("profiles.toml"),
            dir.join("profiles.toml.rollback"),
            dir.join("profiles.toml.tmp"),
        ];
        assert_eq!((&handed, &chowned), (&want, &want));
        assert_eq!(store.path(), file_in(state.path()));
        assert!(!old.exists());

        // Idempotent: the next start hands over the same paths again.
        let mut again = Vec::new();
        hand_over(&dir, &mut |p| {
            again.push(p.to_path_buf());
            Ok(())
        })
        .unwrap();
        assert_eq!(again, want);
        // A failed chown stops the start (the service could not read its store).
        let err = hand_over(&dir, &mut |_| Err(io::Error::other("EPERM"))).unwrap_err();
        assert_eq!(err.to_string(), "EPERM");
    }

    #[test]
    fn with_both_stores_the_new_one_wins_and_a_different_old_one_is_kept_hidden() {
        // A rollback to an older image, which wrote a store at the old path, then this image again.
        let state = tempfile::tempdir().unwrap();
        let old = state.path().join(STORE_FILE);
        let old_bytes = saved_store(&old, "Old");
        fs::create_dir(state.path().join(STORE_DIR)).unwrap();
        let new = state.path().join(STORE_DIR).join(STORE_FILE);
        let new_bytes = saved_store(&new, "New");

        let (store, migration) = Store::open_in(state.path()).unwrap();
        assert_eq!(migration, Migration::OldKept);
        assert_eq!(
            names(&store),
            vec!["New"],
            "changes after a rollback are not merged"
        );
        assert!(!old.exists(), "nothing is left at the old, unhidden path");
        assert_eq!(fs::read(&new).unwrap(), new_bytes);
        assert_eq!(fs::read(rollback_path(&new)).unwrap(), old_bytes);
        assert_eq!(
            rollback_path(&new),
            state.path().join(STORE_DIR).join("profiles.toml.rollback")
        );

        let (_, again) = Store::open_in(state.path()).unwrap();
        assert_eq!(again, Migration::Nothing);
        assert_eq!(fs::read(rollback_path(&new)).unwrap(), old_bytes);
    }

    #[test]
    fn with_both_stores_the_same_the_old_one_is_removed() {
        let state = tempfile::tempdir().unwrap();
        let old = state.path().join(STORE_FILE);
        let bytes = saved_store(&old, "Ada");
        fs::create_dir(state.path().join(STORE_DIR)).unwrap();
        let new = state.path().join(STORE_DIR).join(STORE_FILE);
        fs::write(&new, &bytes).unwrap();

        let (store, migration) = Store::open_in(state.path()).unwrap();
        assert_eq!(migration, Migration::OldRemoved);
        assert_eq!(names(&store), vec!["Ada"]);
        assert!(!old.exists());
        assert!(!rollback_path(&new).exists());
        assert_eq!(fs::read(&new).unwrap(), bytes);
    }

    #[test]
    fn a_corrupt_store_stops_the_move_and_both_files_stay() {
        // A corrupt old store is not copied: the error is the service's, as for Store::open.
        let state = tempfile::tempdir().unwrap();
        let old = state.path().join(STORE_FILE);
        fs::write(&old, "this is = = not toml").unwrap();
        let err = Store::open_in(state.path()).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert!(old.exists());
        assert!(!state.path().join(STORE_DIR).join(STORE_FILE).exists());

        // A corrupt new store does not win: the old one is kept for a person to look at.
        let state = tempfile::tempdir().unwrap();
        let old = state.path().join(STORE_FILE);
        saved_store(&old, "Ada");
        fs::create_dir(state.path().join(STORE_DIR)).unwrap();
        fs::write(state.path().join(STORE_DIR).join(STORE_FILE), "= nope").unwrap();
        let err = Store::open_in(state.path()).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert!(old.exists());
    }

    #[cfg(unix)]
    #[test]
    fn the_store_directory_is_0700_and_the_moved_file_0600() {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        let state = tempfile::tempdir().unwrap();
        let old = state.path().join(STORE_FILE);
        saved_store(&old, "Ada");
        // An old store with a looser mode (set by hand) is 0600 once moved.
        fs::set_permissions(&old, fs::Permissions::from_mode(0o644)).unwrap();
        // A directory that was there with another mode is set to 0700 too.
        fs::create_dir(state.path().join(STORE_DIR)).unwrap();
        fs::set_permissions(
            state.path().join(STORE_DIR),
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        let (_, migration) = Store::open_in(state.path()).unwrap();
        assert_eq!(migration, Migration::Moved);
        assert_eq!(mode(&state.path().join(STORE_DIR)), 0o700);
        assert_eq!(mode(&state.path().join(STORE_DIR).join(STORE_FILE)), 0o600);

        let fresh = tempfile::tempdir().unwrap();
        Store::open_in(fresh.path()).unwrap();
        assert_eq!(mode(&fresh.path().join(STORE_DIR)), 0o700);
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
