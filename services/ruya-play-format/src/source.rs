//! Where a package's bytes come from: a folder, a zip or memory. The validator lists the entries
//! (names, kinds, sizes) first and reads content only when the names pass.

use crate::problem::Problem;
use std::collections::BTreeMap;
use std::fmt;
use std::io::{self, Read};

/// What an entry of a package is. Only `File` and `Dir` are valid in a package (05 §2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryKind {
    /// A regular file.
    File,
    /// A directory.
    Dir,
    /// A symbolic link (a real one; links are data in `play.files`).
    Symlink,
    /// A hard link: a second name for content that already has one.
    HardLink,
    /// A block or character device node.
    Device,
    /// A FIFO, socket or anything else that is not a file or directory.
    Other,
}

/// One entry of a package as the container reports it, before any content is read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// Path relative to the package root, `/` separated, as stored (not yet checked).
    pub path: String,
    /// What it is.
    pub kind: EntryKind,
    /// Uncompressed size in bytes as the container declares it (0 for a directory).
    pub size: u64,
}

/// A package container the validator can read.
pub trait Source {
    /// List every entry. Structural faults of the container itself (an encrypted zip entry, a zip
    /// bomb, duplicate names) come back as the error list.
    fn entries(&self) -> Result<Vec<Entry>, Vec<Problem>>;

    /// Open the content of the file at `path`. The reader yields exactly the entry's declared size;
    /// a container that finds the content disagrees fails the read with a [`ReadFault`].
    fn open(&self, path: &str) -> io::Result<Box<dyn Read + '_>>;
}

/// A read error that carries the [`Problem`] to report (so a zip's "declared size lies" survives
/// the trip through `std::io`).
#[derive(Debug)]
pub struct ReadFault(pub Problem);

impl fmt::Display for ReadFault {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl std::error::Error for ReadFault {}

impl ReadFault {
    /// Wrap `problem` in an `io::Error`.
    pub fn into_io(problem: Problem) -> io::Error {
        io::Error::new(io::ErrorKind::InvalidData, ReadFault(problem))
    }

    /// The problem inside `err`, when it carries one.
    pub fn from_io(err: &io::Error) -> Option<&Problem> {
        err.get_ref()
            .and_then(|e| e.downcast_ref::<ReadFault>())
            .map(|f| &f.0)
    }
}

/// A package held in memory: used by tests and by tools that build a package before writing it.
#[derive(Debug, Default, Clone)]
pub struct MemorySource {
    entries: Vec<Entry>,
    content: BTreeMap<String, Vec<u8>>,
}

impl MemorySource {
    /// An empty package.
    pub fn new() -> Self {
        Self::default()
    }

    /// Add a regular file.
    pub fn add_file(&mut self, path: &str, data: Vec<u8>) -> &mut Self {
        self.entries.push(Entry {
            path: path.to_string(),
            kind: EntryKind::File,
            size: data.len() as u64,
        });
        self.content.insert(path.to_string(), data);
        self
    }

    /// Add a file that reports `declared` bytes but holds `data` (a container that lies).
    pub fn add_file_declaring(&mut self, path: &str, declared: u64, data: Vec<u8>) -> &mut Self {
        self.entries.push(Entry {
            path: path.to_string(),
            kind: EntryKind::File,
            size: declared,
        });
        self.content.insert(path.to_string(), data);
        self
    }

    /// Add an entry that is not a regular file.
    pub fn add_entry(&mut self, path: &str, kind: EntryKind) -> &mut Self {
        self.entries.push(Entry {
            path: path.to_string(),
            kind,
            size: 0,
        });
        self
    }

    /// Add a directory.
    pub fn add_dir(&mut self, path: &str) -> &mut Self {
        self.add_entry(path, EntryKind::Dir)
    }
}

impl Source for MemorySource {
    fn entries(&self) -> Result<Vec<Entry>, Vec<Problem>> {
        Ok(self.entries.clone())
    }

    fn open(&self, path: &str) -> io::Result<Box<dyn Read + '_>> {
        match self.content.get(path) {
            Some(data) => Ok(Box::new(io::Cursor::new(data.as_slice()))),
            None => Err(io::Error::new(io::ErrorKind::NotFound, "no such entry")),
        }
    }
}
