//! The primitives off Linux (host builds and tests): plain path calls that look at each entry
//! with `symlink_metadata` first. A link is still refused at every step, but a link swapped in
//! between the look and the call can win; only the Linux handles ([`crate`] on Linux) close that.
//! Modes and folder flushes are Unix notions and do nothing here; links cannot be made.

use crate::{Found, Kind};
use std::ffi::{OsStr, OsString};
use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};

/// A folder, by its path.
#[derive(Debug)]
pub(crate) struct Dir {
    path: PathBuf,
}

fn kind_of(ft: fs::FileType) -> Kind {
    if ft.is_symlink() {
        Kind::Link
    } else if ft.is_dir() {
        Kind::Dir
    } else if ft.is_file() {
        Kind::File
    } else {
        Kind::Other
    }
}

impl Dir {
    pub(crate) fn open(path: &Path) -> io::Result<Dir> {
        if !fs::metadata(path)?.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{} is not a folder", path.display()),
            ));
        }
        Ok(Dir {
            path: path.to_path_buf(),
        })
    }

    pub(crate) fn try_clone(&self) -> io::Result<Dir> {
        Ok(Dir {
            path: self.path.clone(),
        })
    }

    pub(crate) fn kind(&self, name: &OsStr) -> io::Result<Option<Kind>> {
        match fs::symlink_metadata(self.path.join(name)) {
            Ok(m) => Ok(Some(kind_of(m.file_type()))),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
        }
    }

    pub(crate) fn open_dir(&self, name: &OsStr) -> io::Result<Found<Dir>> {
        match self.kind(name)? {
            Some(Kind::Dir) => Ok(Found::It(Dir {
                path: self.path.join(name),
            })),
            Some(Kind::Link) => Ok(Found::Link),
            Some(_) => Ok(Found::Other),
            None => Err(io::ErrorKind::NotFound.into()),
        }
    }

    /// [`Self::open_dir`]: there is no mode to open around here.
    pub(crate) fn open_dir_for_removal(&self, name: &OsStr) -> io::Result<Found<Dir>> {
        self.open_dir(name)
    }

    /// The regular file `name` for reading (the caller looked at its kind first).
    pub(crate) fn open_read(&self, name: &OsStr) -> io::Result<Found<File>> {
        let file = File::open(self.path.join(name))?;
        if !file.metadata()?.is_file() {
            return Ok(Found::Other);
        }
        Ok(Found::It(file))
    }

    pub(crate) fn create(&self, name: &OsStr, _mode: u32) -> io::Result<File> {
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(self.path.join(name))
    }

    pub(crate) fn make_dir(&self, name: &OsStr, _mode: u32) -> io::Result<()> {
        fs::create_dir(self.path.join(name))
    }

    pub(crate) fn unlink(&self, name: &OsStr) -> io::Result<()> {
        fs::remove_file(self.path.join(name))
    }

    pub(crate) fn remove_dir(&self, name: &OsStr) -> io::Result<()> {
        fs::remove_dir(self.path.join(name))
    }

    pub(crate) fn rename(&self, from: &OsStr, to_dir: &Dir, to: &OsStr) -> io::Result<()> {
        fs::rename(self.path.join(from), to_dir.path.join(to))
    }

    pub(crate) fn read_link(&self, name: &OsStr) -> io::Result<PathBuf> {
        fs::read_link(self.path.join(name))
    }

    pub(crate) fn symlink(&self, _target: &Path, _name: &OsStr) -> io::Result<()> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "links are made on Linux only",
        ))
    }

    pub(crate) fn entries(&self) -> io::Result<Vec<OsString>> {
        fs::read_dir(&self.path)?
            .map(|e| e.map(|e| e.file_name()))
            .collect()
    }

    pub(crate) fn mode(&self) -> io::Result<u32> {
        Ok(0o700)
    }

    pub(crate) fn set_mode(&self, _mode: u32) -> io::Result<()> {
        Ok(())
    }

    pub(crate) fn sync(&self) -> io::Result<()> {
        Ok(())
    }
}

/// Files carry no Unix mode here: a copy is private.
pub(crate) fn file_mode(_file: &File) -> io::Result<u32> {
    Ok(0o600)
}

/// Modes are a Unix notion: nothing to set here.
pub(crate) fn set_file_mode(_file: &File, _bits: u32) -> io::Result<()> {
    Ok(())
}

/// A byte copy: there is no reflink here.
pub(crate) fn copy_bytes(from: &mut File, to: &mut File) -> io::Result<()> {
    io::copy(from, to).map(drop)
}
