//! The build installed per id, for the downgrade rule (05 §11: `build` only increases; lead-29,
//! step 3). Ids are compared by their ASCII lower case, like the trust records. The file
//! (`<state>/installed.json`) is written atomically with mode 0600; a file that cannot be read as
//! written is `installed.corrupt` and is never reset silently (the `ruya-profiles` rule).

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

/// The builds installed per id.
pub trait InstalledBuilds {
    /// The build installed for `id`, if any.
    fn build_of(&self, id: &str) -> Result<Option<u64>, Problem>;
    /// `id` is now installed at `build`.
    fn record(&mut self, id: &str, build: u64) -> Result<(), Problem>;
    /// `id` was uninstalled (RUY-100's uninstall).
    fn forget(&mut self, id: &str) -> Result<(), Problem>;
}

fn fold(id: &str) -> String {
    id.to_ascii_lowercase()
}

/// In memory, for tests and the off-Linux mock.
#[derive(Debug, Default, Clone)]
pub struct MemoryInstalled {
    builds: BTreeMap<String, u64>,
}

impl MemoryInstalled {
    /// Nothing installed.
    pub fn new() -> Self {
        Self::default()
    }

    /// With `id` installed at `build`.
    pub fn with(mut self, id: &str, build: u64) -> Self {
        self.builds.insert(fold(id), build);
        self
    }
}

impl InstalledBuilds for MemoryInstalled {
    fn build_of(&self, id: &str) -> Result<Option<u64>, Problem> {
        Ok(self.builds.get(&fold(id)).copied())
    }
    fn record(&mut self, id: &str, build: u64) -> Result<(), Problem> {
        self.builds.insert(fold(id), build);
        Ok(())
    }
    fn forget(&mut self, id: &str) -> Result<(), Problem> {
        self.builds.remove(&fold(id));
        Ok(())
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawFile {
    format: u64,
    installed: Vec<RawEntry>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawEntry {
    id: String,
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
pub fn decode(bytes: &[u8]) -> Result<BTreeMap<String, u64>, Problem> {
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
        if out.insert(fold(&e.id), e.build).is_some() {
            return Err(corrupt("an id is listed twice"));
        }
    }
    Ok(out)
}

/// Encode the builds.
pub fn encode(builds: &BTreeMap<String, u64>) -> Vec<u8> {
    let raw = RawFile {
        format: INSTALLED_FORMAT,
        installed: builds
            .iter()
            .map(|(id, build)| RawEntry {
                id: id.clone(),
                build: *build,
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
    builds: BTreeMap<String, u64>,
}

impl FileInstalled {
    /// Open the file at `path` (absent: nothing installed).
    pub fn open(path: impl Into<PathBuf>) -> Result<FileInstalled, Problem> {
        let path = path.into();
        let builds = match std::fs::File::open(&path) {
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
        Ok(FileInstalled { path, builds })
    }

    fn save(&self, builds: &BTreeMap<String, u64>) -> Result<(), Problem> {
        write_atomic(&self.path, &encode(builds)).map_err(|e| io_problem(&e))
    }
}

impl InstalledBuilds for FileInstalled {
    fn build_of(&self, id: &str) -> Result<Option<u64>, Problem> {
        Ok(self.builds.get(&fold(id)).copied())
    }
    fn record(&mut self, id: &str, build: u64) -> Result<(), Problem> {
        let mut next = self.builds.clone();
        next.insert(fold(id), build);
        self.save(&next)?;
        self.builds = next;
        Ok(())
    }
    fn forget(&mut self, id: &str) -> Result<(), Problem> {
        let mut next = self.builds.clone();
        if next.remove(&fold(id)).is_none() {
            return Ok(());
        }
        self.save(&next)?;
        self.builds = next;
        Ok(())
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
            br#"{"format":1,"installed":[],"extra":1}"#,
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
}
