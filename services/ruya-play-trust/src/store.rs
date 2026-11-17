//! The trust state: per id the key that owns it, when it was first seen, the last rotation applied
//! and the retired keys; and the admin's developer-mode flag. A trait with an in-memory fake and a
//! file implementation (`/var/lib/ruya-play/trust.json`, mode 0600, written atomically). A file
//! that cannot be read as written is an error, never a silent reset (the `ruya-profiles` pattern).
//!
//! Ids that differ only in letter case are the same id (05 §9.2): records are looked up by the
//! ASCII lower-case id.

use crate::envelope::strict_json;
use crate::error::TrustError;
use crate::keys::{is_key_id, PublicKey};
use crate::time::{format_utc, parse_utc, UnixSeconds};
use ruya_play_format::limits::MAX_ID_BYTES;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

/// The state file `format` this console writes.
pub const STATE_FORMAT: u64 = 1;
/// Most bytes of the state file.
pub const MAX_STATE_BYTES: usize = 32 * 1024 * 1024;
/// Most records in the state file.
pub const MAX_RECORDS: usize = 50_000;
/// Most retired key ids one record keeps.
pub const MAX_RETIRED: usize = 64;

/// Who owns one id on this console.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IdRecord {
    /// The id as first installed.
    pub id: String,
    /// The key that owns it now.
    pub key: PublicKey,
    /// When the first key was recorded.
    pub first_seen: UnixSeconds,
    /// The `seq` of the last rotation applied (0 for none).
    pub seq: u64,
    /// Key ids that owned the id before, oldest first (shown to an admin, never accepted again).
    pub retired: Vec<String>,
}

/// The state behind key continuity and developer mode.
pub trait TrustStore {
    /// The record of `id` (compared case-insensitively).
    fn get(&self, id: &str) -> Result<Option<IdRecord>, TrustError>;
    /// Add or replace the record of its id.
    fn put(&mut self, record: IdRecord) -> Result<(), TrustError>;
    /// Drop the record of `id`; true when there was one.
    fn remove(&mut self, id: &str) -> Result<bool, TrustError>;
    /// The admin's developer mode (default off).
    fn developer_mode(&self) -> Result<bool, TrustError>;
    /// Turn developer mode on or off.
    fn set_developer_mode(&mut self, on: bool) -> Result<(), TrustError>;
}

fn fold(id: &str) -> String {
    id.to_ascii_lowercase()
}

/// The in-memory store for tests and the off-Linux mock.
#[derive(Debug, Clone, Default)]
pub struct MemoryTrustStore {
    records: BTreeMap<String, IdRecord>,
    developer_mode: bool,
}

impl MemoryTrustStore {
    /// An empty store, developer mode off.
    pub fn new() -> Self {
        Self::default()
    }

    /// Every record, by folded id.
    pub fn records(&self) -> impl Iterator<Item = &IdRecord> {
        self.records.values()
    }
}

impl TrustStore for MemoryTrustStore {
    fn get(&self, id: &str) -> Result<Option<IdRecord>, TrustError> {
        Ok(self.records.get(&fold(id)).cloned())
    }
    fn put(&mut self, record: IdRecord) -> Result<(), TrustError> {
        self.records.insert(fold(&record.id), record);
        Ok(())
    }
    fn remove(&mut self, id: &str) -> Result<bool, TrustError> {
        Ok(self.records.remove(&fold(id)).is_some())
    }
    fn developer_mode(&self) -> Result<bool, TrustError> {
        Ok(self.developer_mode)
    }
    fn set_developer_mode(&mut self, on: bool) -> Result<(), TrustError> {
        self.developer_mode = on;
        Ok(())
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawState {
    format: u64,
    developer_mode: bool,
    records: Vec<RawRecord>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawRecord {
    id: String,
    key: String,
    key_id: String,
    first_seen: String,
    seq: u64,
    retired: Vec<String>,
}

fn corrupt(detail: impl Into<String>) -> TrustError {
    TrustError::StateCorrupt {
        detail: detail.into(),
    }
}

fn io_err(e: &io::Error) -> TrustError {
    TrustError::StateIo {
        detail: e.to_string(),
    }
}

/// Read the state file's bytes. Every fault is `state.corrupt`.
pub fn decode_state(bytes: &[u8]) -> Result<MemoryTrustStore, TrustError> {
    let raw: RawState =
        strict_json(bytes, MAX_STATE_BYTES, 4, "trust.json").map_err(|e| corrupt(e.message()))?;
    if raw.format != STATE_FORMAT {
        return Err(corrupt(format!(
            "format {} is not {STATE_FORMAT}",
            raw.format
        )));
    }
    if raw.records.len() > MAX_RECORDS {
        return Err(corrupt(format!("more than {MAX_RECORDS} records")));
    }
    let mut store = MemoryTrustStore {
        records: BTreeMap::new(),
        developer_mode: raw.developer_mode,
    };
    for (i, r) in raw.records.into_iter().enumerate() {
        let n = i + 1;
        if r.id.is_empty() || r.id.len() > MAX_ID_BYTES || !r.id.is_ascii() {
            return Err(corrupt(format!("record {n} has a bad id")));
        }
        let key = PublicKey::from_base64(&r.key)
            .map_err(|_| corrupt(format!("record {n} has a bad key")))?;
        if key.key_id() != r.key_id {
            return Err(corrupt(format!("record {n}: key_id does not match key")));
        }
        let first_seen = parse_utc(&r.first_seen)
            .ok_or_else(|| corrupt(format!("record {n} has a bad first_seen")))?;
        if r.retired.len() > MAX_RETIRED || !r.retired.iter().all(|k| is_key_id(k)) {
            return Err(corrupt(format!("record {n} has bad retired keys")));
        }
        let folded = fold(&r.id);
        if store.records.contains_key(&folded) {
            return Err(corrupt(format!("record {n} repeats an id")));
        }
        store.records.insert(
            folded,
            IdRecord {
                id: r.id,
                key,
                first_seen,
                seq: r.seq,
                retired: r.retired,
            },
        );
    }
    Ok(store)
}

/// The state file's bytes.
pub fn encode_state(store: &MemoryTrustStore) -> Vec<u8> {
    let raw = RawState {
        format: STATE_FORMAT,
        developer_mode: store.developer_mode,
        records: store
            .records
            .values()
            .map(|r| RawRecord {
                id: r.id.clone(),
                key: r.key.to_base64(),
                key_id: r.key.key_id(),
                first_seen: format_utc(r.first_seen),
                seq: r.seq,
                retired: r.retired.clone(),
            })
            .collect(),
    };
    let mut out = serde_json::to_vec_pretty(&raw).expect("the state is always JSON");
    out.push(b'\n');
    out
}

/// The file-backed store. Every change is written before it returns: a temporary file next to the
/// state, created with mode 0600, flushed to disk, renamed over it, and the folder flushed. A failed write leaves the old state in
/// the file and in memory.
#[derive(Debug)]
pub struct FileTrustStore {
    path: PathBuf,
    state: MemoryTrustStore,
}

impl FileTrustStore {
    /// Open the state at `path`; a missing file is an empty state, anything unreadable an error.
    pub fn open(path: impl Into<PathBuf>) -> Result<FileTrustStore, TrustError> {
        let path = path.into();
        let state = match fs::metadata(&path) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => MemoryTrustStore::new(),
            Err(e) => return Err(io_err(&e)),
            Ok(m) if m.len() > MAX_STATE_BYTES as u64 => {
                return Err(corrupt(format!("larger than {MAX_STATE_BYTES} bytes")))
            }
            Ok(_) => decode_state(&fs::read(&path).map_err(|e| io_err(&e))?)?,
        };
        Ok(FileTrustStore { path, state })
    }

    fn save(&self, state: &MemoryTrustStore) -> Result<(), TrustError> {
        write_atomic(&self.path, &encode_state(state)).map_err(|e| io_err(&e))
    }

    fn change(&mut self, f: impl FnOnce(&mut MemoryTrustStore)) -> Result<(), TrustError> {
        let mut next = self.state.clone();
        f(&mut next);
        self.save(&next)?;
        self.state = next;
        Ok(())
    }
}

fn tmp_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".tmp");
    path.with_file_name(name)
}

fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let dir = match path.parent() {
        Some(d) if !d.as_os_str().is_empty() => d.to_path_buf(),
        _ => PathBuf::from("."),
    };
    fs::create_dir_all(&dir)?;
    let tmp = tmp_path(path);
    // A temporary file left by a write that failed before its rename is not ours to trust: it is
    // replaced, never read.
    match fs::remove_file(&tmp) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
        _ => {}
    }
    {
        let mut f = create_private(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    sync_dir(&dir)
}

/// Create `path` new, mode 0600 from the start (never wider, not even while it is empty).
#[cfg(unix)]
fn create_private(path: &Path) -> io::Result<fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
}

#[cfg(not(unix))]
fn create_private(path: &Path) -> io::Result<fs::File> {
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
}

/// Flush the directory entry of the rename, so the new state survives a power cut.
#[cfg(unix)]
fn sync_dir(dir: &Path) -> io::Result<()> {
    fs::File::open(dir)?.sync_all()
}

#[cfg(not(unix))]
fn sync_dir(_dir: &Path) -> io::Result<()> {
    Ok(())
}

impl TrustStore for FileTrustStore {
    fn get(&self, id: &str) -> Result<Option<IdRecord>, TrustError> {
        self.state.get(id)
    }
    fn put(&mut self, record: IdRecord) -> Result<(), TrustError> {
        if record.retired.len() > MAX_RETIRED {
            return Err(TrustError::StateIo {
                detail: format!("more than {MAX_RETIRED} retired keys"),
            });
        }
        let folded = fold(&record.id);
        if !self.state.records.contains_key(&folded) && self.state.records.len() >= MAX_RECORDS {
            return Err(TrustError::StateIo {
                detail: format!("more than {MAX_RECORDS} records"),
            });
        }
        self.change(|s| {
            s.records.insert(folded, record);
        })
    }
    fn remove(&mut self, id: &str) -> Result<bool, TrustError> {
        if self.state.records.contains_key(&fold(id)) {
            self.change(|s| {
                s.records.remove(&fold(id));
            })?;
            return Ok(true);
        }
        Ok(false)
    }
    fn developer_mode(&self) -> Result<bool, TrustError> {
        Ok(self.state.developer_mode)
    }
    fn set_developer_mode(&mut self, on: bool) -> Result<(), TrustError> {
        self.change(|s| s.developer_mode = on)
    }
}
