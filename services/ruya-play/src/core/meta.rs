//! The service's own copy of a package's root files (RUY-828, 05 §7.3).
//!
//! The helper writes `play.json`, `play.files`, `play.sig` and `store.sig` into `<scratch>/meta/`
//! exactly as it read them. The service reads each of them back once, through a folder handle and
//! bounded by the format's limits, and wraps them in a [`MetaSource`]: a [`Source`] whose listing is
//! the root files plus what `play.files` lists (files and folders; links are data, never entries),
//! so `ruya_play_trust::inspect` and `ruya_play_format::validate` run on the service's side over
//! these bytes alone, with the service's key records, blocklist and installed builds. The package
//! itself is never opened here; the listing of the real container was the helper's to check.

use crate::core::helper::sha256_hex;
use crate::core::staging::Dir;
use crate::core::unpack::staging_problem;
use ruya_play_format::limits::{MAX_MANIFEST_BYTES, MAX_TABLE_BYTES, ROOT_FILES};
use ruya_play_format::problem::Problems;
use ruya_play_format::table::parse_table;
use ruya_play_format::{Entry, EntryKind, FileEntry, Problem, Source};
use ruya_play_trust::envelope::MAX_SIG_FILE_BYTES;
use std::collections::{BTreeMap, BTreeSet};
use std::io::{self, Cursor, Read};

fn limit(name: &str) -> u64 {
    match name {
        "play.json" => MAX_MANIFEST_BYTES,
        "play.files" => MAX_TABLE_BYTES,
        _ => MAX_SIG_FILE_BYTES as u64,
    }
}

/// The root files as the service read them, as a package source without payload.
#[derive(Debug, Clone)]
pub struct MetaSource {
    roots: BTreeMap<String, Vec<u8>>,
    entries: Vec<Entry>,
}

impl MetaSource {
    /// Read the root files in `meta` (each at most its limit plus one byte, so a file that is too
    /// big stays too big; a link or a special file is `staging.changed`).
    pub fn read(meta: &Dir) -> Result<MetaSource, Problem> {
        let mut roots = BTreeMap::new();
        for name in ROOT_FILES {
            let file = match meta.open_file(name) {
                Ok(f) => f,
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(e) => return Err(staging_problem(name, &e)),
            };
            let mut bytes = Vec::new();
            file.take(limit(name) + 1)
                .read_to_end(&mut bytes)
                .map_err(|e| staging_problem(name, &e))?;
            roots.insert(name.to_string(), bytes);
        }
        let mut entries: Vec<Entry> = roots
            .iter()
            .map(|(name, bytes)| Entry {
                path: name.clone(),
                kind: EntryKind::File,
                size: bytes.len() as u64,
            })
            .collect();
        if let Some(table) = roots.get("play.files") {
            let mut problems = Problems::new();
            let files = parse_table(table, &mut problems);
            // A table that does not parse lists nothing: `validate` reports it from the bytes.
            if problems.is_empty() {
                entries.extend(listing_of(&files));
            }
        }
        Ok(MetaSource { roots, entries })
    }

    /// The bytes of a root file.
    pub fn root(&self, name: &str) -> Option<&[u8]> {
        self.roots.get(name).map(Vec::as_slice)
    }

    /// The SHA-256 of every root file, for the install request's `expect`.
    pub fn digests(&self) -> BTreeMap<String, String> {
        self.roots
            .iter()
            .map(|(n, b)| (n.clone(), sha256_hex(b)))
            .collect()
    }
}

/// The container listing a package with exactly this table has: its files, its folders and every
/// folder on the way; no links.
fn listing_of(files: &[FileEntry]) -> Vec<Entry> {
    let mut dirs = BTreeSet::new();
    let mut out = Vec::new();
    for f in files {
        let path = f.path();
        let mut at = 0;
        while let Some(i) = path[at..].find('/') {
            dirs.insert(path[..at + i].to_string());
            at += i + 1;
        }
        match f {
            FileEntry::File { size, .. } => out.push(Entry {
                path: path.to_string(),
                kind: EntryKind::File,
                size: *size,
            }),
            FileEntry::Dir { .. } => {
                dirs.insert(path.to_string());
            }
            FileEntry::Link { .. } => {}
        }
    }
    out.extend(dirs.into_iter().map(|path| Entry {
        path,
        kind: EntryKind::Dir,
        size: 0,
    }));
    out
}

impl Source for MetaSource {
    fn entries(&self) -> Result<Vec<Entry>, Vec<Problem>> {
        Ok(self.entries.clone())
    }

    fn open(&self, path: &str) -> io::Result<Box<dyn Read + '_>> {
        match self.roots.get(path) {
            Some(bytes) => Ok(Box::new(Cursor::new(bytes.as_slice()))),
            None => Err(io::Error::new(
                io::ErrorKind::NotFound,
                "the service holds the root files only",
            )),
        }
    }
}
