//! Opening a package given on the command line: a folder, or a `.play.zip` file.

use crate::report::{items, Item, Stop};
use ruya_play_format::{FolderSource, Source, ZipSource};
use std::io::Read;
use std::path::{Path, PathBuf};

/// Why a package could not be opened.
pub enum OpenError {
    /// The command cannot go on (missing path, unreadable file).
    Stop(Stop),
    /// The container itself is damaged: the crates' own problems.
    Problems(Vec<Item>),
}

impl From<Stop> for OpenError {
    fn from(s: Stop) -> Self {
        OpenError::Stop(s)
    }
}

/// An opened package.
pub struct Opened {
    /// Where it was read from.
    pub path: PathBuf,
    /// True for a folder, false for a zip file.
    pub is_dir: bool,
    /// Size of the zip file (0 for a folder).
    pub file_bytes: u64,
    /// The one reader both forms share.
    pub source: Box<dyn Source>,
}

/// Open `path` as a folder or a zip file.
pub fn open(path: &str) -> Result<Opened, OpenError> {
    let p = Path::new(path);
    let meta = std::fs::metadata(p).map_err(|e| Stop::io("cannot open", p, &e))?;
    if meta.is_dir() {
        return Ok(Opened {
            path: p.to_path_buf(),
            is_dir: true,
            file_bytes: 0,
            source: Box::new(FolderSource::new(p)),
        });
    }
    let file = std::fs::File::open(p).map_err(|e| Stop::io("cannot open", p, &e))?;
    let source = ZipSource::new(file).map_err(|problems| OpenError::Problems(items(&problems)))?;
    Ok(Opened {
        path: p.to_path_buf(),
        is_dir: false,
        file_bytes: meta.len(),
        source: Box::new(source),
    })
}

/// Read a package file of at most `limit` bytes; `None` when it is absent or not readable.
pub fn read_small(source: &dyn Source, name: &str, limit: u64) -> Option<Vec<u8>> {
    let mut buf = Vec::new();
    source
        .open(name)
        .ok()?
        .take(limit + 1)
        .read_to_end(&mut buf)
        .ok()?;
    (buf.len() as u64 <= limit).then_some(buf)
}
