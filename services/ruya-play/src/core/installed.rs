//! The build installed per id, for the downgrade rule (05 §11: `build` only increases; lead-29,
//! step 3), and the generation of the Flatpak metadata its commit generated (ADR-038: the
//! start-up reconcile re-commits an app whose generation is older than
//! `service::commit::METADATA_GENERATION`). Ids are compared by their ASCII lower case, like the
//! trust records. The file (`<state>/installed.json`) is written atomically with mode 0600; a file
//! that cannot be read as written is `installed.corrupt` and is never reset silently (the
//! `ruya-profiles` rule). An entry without `generation` (written before generations existed)
//! reads as generation 0. An entry may name the build an update replaced, `previous: {build}`
//! (RUY-1245: the build the commit keeps for a rollback); without it nothing is kept.
//!
//! **Forward-compatible (RUY-900):** a key this service does not know, at the top or on an entry,
//! is ignored, so a file written by a newer image still reads after a bootc rollback (an unknown
//! key must never make it `installed.corrupt`, which holds every install). A field may only be
//! added with a safe default for a reader that does not know it; a change an older reader must
//! not misread raises `format`, which such a reader refuses as `installed.corrupt`.

use crate::core::codes;
use crate::core::jobs::write_atomic;
use ruya_play_format::Problem;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::{self, Read};
use std::path::PathBuf;

/// The format of the file this console writes.
pub const INSTALLED_FORMAT: u64 = 1;
/// Most bytes of the file.
pub const MAX_INSTALLED_BYTES: u64 = 8 * 1024 * 1024;

/// What is recorded for one installed id.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Installed {
    /// The installed build.
    pub build: u64,
    /// The generation of the metadata its commit generated; 0 when it is not known (a record
    /// from before generations, or one the reconcile made for an app it found).
    pub generation: u32,
    /// The build an update replaced, which the commit keeps as the repo's `ruyaos/previous/play.<id>`
    /// ref
    /// for a rollback (RUY-1245); `None` when nothing is kept (never updated, rolled back, or a
    /// record from before rollbacks).
    pub previous: Option<u64>,
}

impl Installed {
    /// The kept build when it is older than the installed one: what a rollback brings back. A
    /// kept build that is not older (records restored after a failed update) is none.
    pub fn older_previous(&self) -> Option<u64> {
        self.previous.filter(|p| *p < self.build)
    }
}

/// The builds installed per id.
pub trait InstalledBuilds {
    /// What is recorded for `id`, if anything.
    fn get(&self, id: &str) -> Result<Option<Installed>, Problem>;
    /// `id` is now installed at `build`. A recorded id keeps its generation (the commit that
    /// follows stamps a new one, [`Self::stamp`]); a new one starts at generation 0.
    fn record(&mut self, id: &str, build: u64) -> Result<(), Problem>;
    /// The commit of the recorded `id` generated metadata of `generation`. Nothing happens for an
    /// id without a record.
    fn stamp(&mut self, id: &str, generation: u32) -> Result<(), Problem>;
    /// The recorded `id` keeps `previous` (RUY-1245; `None`: nothing). Nothing happens for an id
    /// without a record.
    fn set_previous(&mut self, id: &str, previous: Option<u64>) -> Result<(), Problem>;
    /// `id` was uninstalled (RUY-100's uninstall).
    fn forget(&mut self, id: &str) -> Result<(), Problem>;
    /// Every id (lower case) and its record, for the start-up reconcile (RUY-829).
    fn all(&self) -> Result<BTreeMap<String, Installed>, Problem>;

    /// The build installed for `id`, if any.
    fn build_of(&self, id: &str) -> Result<Option<u64>, Problem> {
        Ok(self.get(id)?.map(|e| e.build))
    }
}

fn fold(id: &str) -> String {
    id.to_ascii_lowercase()
}

/// `records` with `id` at `build`, keeping its generation ([`InstalledBuilds::record`]).
fn with_build(
    records: &BTreeMap<String, Installed>,
    id: &str,
    build: u64,
) -> BTreeMap<String, Installed> {
    let mut next = records.clone();
    next.entry(fold(id)).or_default().build = build;
    next
}

/// `records` with the recorded `id` at `generation`; `None` when there is nothing to change.
fn with_generation(
    records: &BTreeMap<String, Installed>,
    id: &str,
    generation: u32,
) -> Option<BTreeMap<String, Installed>> {
    let mut next = records.clone();
    let entry = next.get_mut(&fold(id))?;
    if entry.generation == generation {
        return None;
    }
    entry.generation = generation;
    Some(next)
}

/// `records` with the recorded `id` keeping `previous`; `None` when there is nothing to change.
fn with_previous(
    records: &BTreeMap<String, Installed>,
    id: &str,
    previous: Option<u64>,
) -> Option<BTreeMap<String, Installed>> {
    let mut next = records.clone();
    let entry = next.get_mut(&fold(id))?;
    if entry.previous == previous {
        return None;
    }
    entry.previous = previous;
    Some(next)
}

/// In memory, for tests and the off-Linux mock.
#[derive(Debug, Default, Clone)]
pub struct MemoryInstalled {
    records: BTreeMap<String, Installed>,
}

impl MemoryInstalled {
    /// Nothing installed.
    pub fn new() -> Self {
        Self::default()
    }

    /// With `id` installed at `build`, generation 0 (recorded before generations).
    pub fn with(mut self, id: &str, build: u64) -> Self {
        self.records = with_build(&self.records, id, build);
        self
    }

    /// With the recorded `id` keeping `previous` (an update was installed over it).
    pub fn keeping(mut self, id: &str, previous: u64) -> Self {
        if let Some(next) = with_previous(&self.records, id, Some(previous)) {
            self.records = next;
        }
        self
    }
}

impl InstalledBuilds for MemoryInstalled {
    fn get(&self, id: &str) -> Result<Option<Installed>, Problem> {
        Ok(self.records.get(&fold(id)).copied())
    }
    fn record(&mut self, id: &str, build: u64) -> Result<(), Problem> {
        self.records = with_build(&self.records, id, build);
        Ok(())
    }
    fn stamp(&mut self, id: &str, generation: u32) -> Result<(), Problem> {
        if let Some(next) = with_generation(&self.records, id, generation) {
            self.records = next;
        }
        Ok(())
    }
    fn set_previous(&mut self, id: &str, previous: Option<u64>) -> Result<(), Problem> {
        if let Some(next) = with_previous(&self.records, id, previous) {
            self.records = next;
        }
        Ok(())
    }
    fn forget(&mut self, id: &str) -> Result<(), Problem> {
        self.records.remove(&fold(id));
        Ok(())
    }
    fn all(&self) -> Result<BTreeMap<String, Installed>, Problem> {
        Ok(self.records.clone())
    }
}

#[derive(Serialize, Deserialize)]
struct RawFile {
    format: u64,
    installed: Vec<RawEntry>,
}

#[derive(Serialize, Deserialize)]
struct RawEntry {
    id: String,
    build: u64,
    #[serde(default)]
    generation: u32,
    /// RUY-1245: absent for none, so an older reader (which ignores it) and this one agree.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    previous: Option<RawPrevious>,
}

/// The kept build of an entry: an object, so more facts of it can be added later.
#[derive(Serialize, Deserialize)]
struct RawPrevious {
    build: u64,
}

fn corrupt(detail: impl Into<String>) -> Problem {
    Problem::new(
        codes::INSTALLED_CORRUPT,
        "installed.json",
        format!(
            "The list of installed builds cannot be read ({}); it was not changed.",
            detail.into()
        ),
    )
}

fn io_problem(e: &io::Error) -> Problem {
    Problem::new(
        codes::INSTALLED_IO,
        "installed.json",
        format!("The list of installed builds could not be read or saved ({e})."),
    )
}

/// Decode the file's bytes.
pub fn decode(bytes: &[u8]) -> Result<BTreeMap<String, Installed>, Problem> {
    let raw: RawFile = serde_json::from_slice(bytes).map_err(|e| corrupt(e.to_string()))?;
    if raw.format != INSTALLED_FORMAT {
        return Err(corrupt(format!("format {} is not known", raw.format)));
    }
    let mut out = BTreeMap::new();
    for e in raw.installed {
        let ok = !e.id.is_empty()
            && e.id.len() <= ruya_play_format::limits::MAX_ID_BYTES
            && e.id.bytes().all(|b| b.is_ascii_graphic());
        if !ok {
            return Err(corrupt("an id is not valid"));
        }
        let entry = Installed {
            build: e.build,
            generation: e.generation,
            previous: e.previous.map(|p| p.build),
        };
        if out.insert(fold(&e.id), entry).is_some() {
            return Err(corrupt("an id is listed twice"));
        }
    }
    Ok(out)
}

/// Encode the records.
pub fn encode(records: &BTreeMap<String, Installed>) -> Vec<u8> {
    let raw = RawFile {
        format: INSTALLED_FORMAT,
        installed: records
            .iter()
            .map(|(id, e)| RawEntry {
                id: id.clone(),
                build: e.build,
                generation: e.generation,
                previous: e.previous.map(|build| RawPrevious { build }),
            })
            .collect(),
    };
    let mut bytes = serde_json::to_vec_pretty(&raw).unwrap_or_default();
    bytes.push(b'\n');
    bytes
}

/// The file implementation.
#[derive(Debug)]
pub struct FileInstalled {
    path: PathBuf,
    records: BTreeMap<String, Installed>,
}

impl FileInstalled {
    /// Open the file at `path` (absent: nothing installed).
    pub fn open(path: impl Into<PathBuf>) -> Result<FileInstalled, Problem> {
        let path = path.into();
        let records = match std::fs::File::open(&path) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => BTreeMap::new(),
            Err(e) => return Err(io_problem(&e)),
            Ok(f) => {
                let mut bytes = Vec::new();
                f.take(MAX_INSTALLED_BYTES + 1)
                    .read_to_end(&mut bytes)
                    .map_err(|e| io_problem(&e))?;
                if bytes.len() as u64 > MAX_INSTALLED_BYTES {
                    return Err(corrupt("the file is too large"));
                }
                decode(&bytes)?
            }
        };
        Ok(FileInstalled { path, records })
    }

    /// Save `next` and keep it.
    fn save(&mut self, next: BTreeMap<String, Installed>) -> Result<(), Problem> {
        write_atomic(&self.path, &encode(&next)).map_err(|e| io_problem(&e))?;
        self.records = next;
        Ok(())
    }
}

impl InstalledBuilds for FileInstalled {
    fn get(&self, id: &str) -> Result<Option<Installed>, Problem> {
        Ok(self.records.get(&fold(id)).copied())
    }
    fn all(&self) -> Result<BTreeMap<String, Installed>, Problem> {
        Ok(self.records.clone())
    }
    fn record(&mut self, id: &str, build: u64) -> Result<(), Problem> {
        self.save(with_build(&self.records, id, build))
    }
    fn stamp(&mut self, id: &str, generation: u32) -> Result<(), Problem> {
        match with_generation(&self.records, id, generation) {
            Some(next) => self.save(next),
            None => Ok(()),
        }
    }
    fn set_previous(&mut self, id: &str, previous: Option<u64>) -> Result<(), Problem> {
        match with_previous(&self.records, id, previous) {
            Some(next) => self.save(next),
            None => Ok(()),
        }
    }
    fn forget(&mut self, id: &str) -> Result<(), Problem> {
        let mut next = self.records.clone();
        if next.remove(&fold(id)).is_none() {
            return Ok(());
        }
        self.save(next)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_file_keeps_builds_and_ids_fold_case() {
        let t = tempfile::tempdir().unwrap();
        let path = t.path().join("installed.json");
        let mut f = FileInstalled::open(&path).unwrap();
        assert_eq!(f.build_of("com.example.game").unwrap(), None);
        f.record("com.Example.Game", 7).unwrap();
        let f = FileInstalled::open(&path).unwrap();
        assert_eq!(f.build_of("com.example.game").unwrap(), Some(7));
        let mut f = f;
        f.forget("COM.EXAMPLE.GAME").unwrap();
        assert_eq!(
            FileInstalled::open(&path)
                .unwrap()
                .build_of("com.example.game")
                .unwrap(),
            None
        );
    }

    #[test]
    fn the_generation_is_stamped_kept_by_an_update_and_absent_reads_zero() {
        let t = tempfile::tempdir().unwrap();
        let path = t.path().join("installed.json");
        // A file written before generations: no `generation` key.
        std::fs::write(
            &path,
            br#"{"format":1,"installed":[{"id":"com.example.old","build":3}]}"#,
        )
        .unwrap();
        let mut f = FileInstalled::open(&path).unwrap();
        let old = Installed {
            build: 3,
            generation: 0,
            previous: None,
        };
        assert_eq!(f.get("com.example.old").unwrap(), Some(old));
        f.stamp("COM.EXAMPLE.OLD", 4).unwrap();
        // Stamping an id without a record writes nothing.
        f.stamp("com.example.none", 4).unwrap();
        let mut f = FileInstalled::open(&path).unwrap();
        assert_eq!(f.get("com.example.old").unwrap().unwrap().generation, 4);
        assert_eq!(f.get("com.example.none").unwrap(), None);
        // An update keeps the generation until its own commit stamps one; a new id starts at 0.
        f.record("com.example.old", 5).unwrap();
        f.record("com.example.new", 1).unwrap();
        let all = FileInstalled::open(&path).unwrap().all().unwrap();
        assert_eq!(
            all.get("com.example.old"),
            Some(&Installed {
                build: 5,
                generation: 4,
                previous: None
            })
        );
        assert_eq!(all.get("com.example.new").unwrap().generation, 0);
        // The memory implementation follows the same rules.
        let mut m = MemoryInstalled::new().with("a", 1);
        m.stamp("a", 2).unwrap();
        m.record("a", 2).unwrap();
        assert_eq!(
            m.get("A").unwrap(),
            Some(Installed {
                build: 2,
                generation: 2,
                previous: None
            })
        );
    }

    #[test]
    fn the_kept_build_is_written_kept_by_a_record_and_absent_reads_none() {
        let t = tempfile::tempdir().unwrap();
        let path = t.path().join("installed.json");
        // A file written before rollbacks: no `previous` key.
        std::fs::write(
            &path,
            br#"{"format":1,"installed":[{"id":"a","build":3,"generation":2}]}"#,
        )
        .unwrap();
        let mut f = FileInstalled::open(&path).unwrap();
        assert_eq!(f.get("a").unwrap().unwrap().previous, None);
        // An update keeps the build it replaced; the file says so and reads it back.
        f.record("a", 4).unwrap();
        f.set_previous("A", Some(3)).unwrap();
        f.set_previous("none", Some(1)).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains(r#""previous": {"#), "{text}");
        let mut f = FileInstalled::open(&path).unwrap();
        let a = f.get("a").unwrap().unwrap();
        assert_eq!((a.build, a.generation, a.previous), (4, 2, Some(3)));
        assert_eq!(a.older_previous(), Some(3));
        assert_eq!(f.get("none").unwrap(), None);
        // A record of the build keeps it; one that is not older is no rollback; none writes no key.
        f.record("a", 3).unwrap();
        assert_eq!(f.get("a").unwrap().unwrap().older_previous(), None);
        f.set_previous("a", None).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(!text.contains("previous"), "{text}");
        // The memory implementation follows the same rules.
        let mut m = MemoryInstalled::new().with("b", 5).keeping("b", 4);
        m.record("b", 6).unwrap();
        assert_eq!(m.get("B").unwrap().unwrap().previous, Some(4));
        m.set_previous("b", None).unwrap();
        assert_eq!(m.get("b").unwrap().unwrap().previous, None);
    }

    #[test]
    fn a_file_that_cannot_be_read_is_an_io_problem() {
        let t = tempfile::tempdir().unwrap();
        // A folder where the file should be: opening or reading it fails.
        let e = FileInstalled::open(t.path()).unwrap_err();
        assert_eq!(e.code, "installed.io");
    }

    #[test]
    fn a_damaged_file_is_an_error_and_stays() {
        let t = tempfile::tempdir().unwrap();
        let path = t.path().join("installed.json");
        for bad in [
            &b"{not json"[..],
            br#"{"format":2,"installed":[]}"#,
            br#"{"format":1,"installed":[{"id":"a b","build":1}]}"#,
            br#"{"format":1,"installed":[{"id":"a","build":1},{"id":"A","build":2}]}"#,
        ] {
            std::fs::write(&path, bad).unwrap();
            let e = FileInstalled::open(&path).unwrap_err();
            assert_eq!(
                e.code,
                "installed.corrupt",
                "{}",
                String::from_utf8_lossy(bad)
            );
            assert_eq!(std::fs::read(&path).unwrap(), bad);
        }
    }

    #[test]
    fn a_file_from_a_newer_image_reads_after_a_rollback() {
        // Unknown keys at the top and on an entry are ignored, never `installed.corrupt` (which
        // would hold every install after a bootc rollback).
        let t = tempfile::tempdir().unwrap();
        let path = t.path().join("installed.json");
        std::fs::write(
            &path,
            br#"{"format":1,"installed":[{"id":"a","build":4,"generation":2,"later":"x"}],"extra":1}"#,
        )
        .unwrap();
        let mut f = FileInstalled::open(&path).unwrap();
        assert_eq!(
            f.get("a").unwrap(),
            Some(Installed {
                build: 4,
                generation: 2,
                previous: None
            })
        );
        // Writing it again keeps what this reader knows.
        f.record("a", 5).unwrap();
        assert_eq!(
            FileInstalled::open(&path).unwrap().build_of("a").unwrap(),
            Some(5)
        );
    }
}
