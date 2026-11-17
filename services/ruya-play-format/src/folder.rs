//! A package folder on disk (05 §2). Entries are listed with `symlink_metadata`, so a link is
//! reported as a link and never followed.

use crate::limits::MAX_ZIP_ENTRIES;
use crate::problem::{codes, Problem};
use crate::source::{Entry, EntryKind, Source};
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

/// A package folder.
#[derive(Debug, Clone)]
pub struct FolderSource {
    root: PathBuf,
    max_entries: usize,
}

impl FolderSource {
    /// A package at `root` (the folder that holds `play.json`).
    pub fn new(root: impl Into<PathBuf>) -> Self {
        FolderSource {
            root: root.into(),
            max_entries: MAX_ZIP_ENTRIES,
        }
    }

    /// Refuse a folder with more than `max` entries (default [`MAX_ZIP_ENTRIES`]).
    pub fn with_max_entries(mut self, max: usize) -> Self {
        self.max_entries = max;
        self
    }

    fn kind_of(meta: &fs::Metadata) -> EntryKind {
        let ft = meta.file_type();
        if ft.is_symlink() {
            return EntryKind::Symlink;
        }
        if ft.is_dir() {
            return EntryKind::Dir;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::{FileTypeExt, MetadataExt};
            if ft.is_block_device() || ft.is_char_device() {
                return EntryKind::Device;
            }
            if ft.is_fifo() || ft.is_socket() {
                return EntryKind::Other;
            }
            if ft.is_file() && meta.nlink() > 1 {
                return EntryKind::HardLink;
            }
        }
        if ft.is_file() {
            EntryKind::File
        } else {
            EntryKind::Other
        }
    }
}

fn unreadable(path: &str, err: &io::Error) -> Vec<Problem> {
    vec![Problem::new(
        codes::FOLDER_UNREADABLE,
        path,
        format!("The folder cannot be read ({err})."),
    )]
}

impl Source for FolderSource {
    fn entries(&self) -> Result<Vec<Entry>, Vec<Problem>> {
        let mut out = Vec::new();
        let mut stack: Vec<(PathBuf, String)> = vec![(self.root.clone(), String::new())];
        while let Some((dir, rel)) = stack.pop() {
            let rd = fs::read_dir(&dir).map_err(|e| unreadable(&rel, &e))?;
            for item in rd {
                let item = item.map_err(|e| unreadable(&rel, &e))?;
                let name = item.file_name();
                let Some(name) = name.to_str() else {
                    return Err(vec![Problem::new(
                        codes::PATH_INVALID_UTF8,
                        format!("{rel}{}", name.to_string_lossy()),
                        "The name is not valid UTF-8.",
                    )]);
                };
                let path = format!("{rel}{name}");
                let meta = fs::symlink_metadata(item.path()).map_err(|e| unreadable(&path, &e))?;
                let kind = Self::kind_of(&meta);
                if out.len() >= self.max_entries {
                    return Err(vec![Problem::new(
                        codes::FOLDER_TOO_MANY_ENTRIES,
                        "",
                        format!("The folder has more than {} entries.", self.max_entries),
                    )]);
                }
                if kind == EntryKind::Dir {
                    stack.push((item.path(), format!("{path}/")));
                }
                let size = if kind == EntryKind::File {
                    meta.len()
                } else {
                    0
                };
                out.push(Entry { path, kind, size });
            }
        }
        out.sort_by(|a, b| a.path.cmp(&b.path));
        Ok(out)
    }

    fn open(&self, path: &str) -> io::Result<Box<dyn Read + '_>> {
        let full: &Path = &self.root.join(path);
        let meta = fs::symlink_metadata(full)?;
        if !meta.file_type().is_file() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "not a regular file",
            ));
        }
        Ok(Box::new(fs::File::open(full)?))
    }
}
