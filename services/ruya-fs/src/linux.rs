//! The primitives on a folder handle (Linux, on `rustix`, as `ruya-play`'s staging handles): every
//! call names one entry of the open folder (`openat`, `mkdirat`, `unlinkat`, `renameat`,
//! `statat`, `readlinkat`, `symlinkat`), so a folder that is swapped for a link after it was
//! opened cannot redirect anything, and an entry that is a link is never followed (`O_NOFOLLOW`,
//! `AT_SYMLINK_NOFOLLOW`).

use crate::{Found, Kind};
use rustix::fs::{self as rfs, AtFlags, FileType, Mode, OFlags};
use rustix::io::Errno;
use std::ffi::{OsStr, OsString};
use std::fs::File;
use std::io;
use std::os::fd::OwnedFd;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};

/// An open folder.
#[derive(Debug)]
pub(crate) struct Dir {
    fd: OwnedFd,
}

fn dir_flags() -> OFlags {
    OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC
}

fn mode(bits: u32) -> Mode {
    Mode::from_raw_mode(bits & 0o7777)
}

fn kind_of(st_mode: u32) -> Kind {
    match FileType::from_raw_mode(st_mode) {
        FileType::Directory => Kind::Dir,
        FileType::RegularFile => Kind::File,
        FileType::Symlink => Kind::Link,
        _ => Kind::Other,
    }
}

impl Dir {
    /// The trusted folder at `path` (links in `path` itself are the caller's to trust).
    pub(crate) fn open(path: &Path) -> io::Result<Dir> {
        let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC;
        Ok(Dir {
            fd: rfs::openat(rfs::CWD, path, flags, Mode::empty())?,
        })
    }

    pub(crate) fn try_clone(&self) -> io::Result<Dir> {
        Ok(Dir {
            fd: self.fd.try_clone()?,
        })
    }

    /// What `name` is, not following a link; `None` when nothing is there.
    pub(crate) fn kind(&self, name: &OsStr) -> io::Result<Option<Kind>> {
        match rfs::statat(&self.fd, name, AtFlags::SYMLINK_NOFOLLOW) {
            Ok(st) => Ok(Some(kind_of(st.st_mode))),
            Err(Errno::NOENT) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// The folder `name`: a link there is [`Found::Link`], anything else not a folder
    /// [`Found::Other`]; `NotFound` when nothing is there.
    pub(crate) fn open_dir(&self, name: &OsStr) -> io::Result<Found<Dir>> {
        match rfs::openat(&self.fd, name, dir_flags(), Mode::empty()) {
            Ok(fd) => Ok(Found::It(Dir { fd })),
            // The open itself refused: ELOOP for a link, ENOTDIR for a file (or a link, on a
            // kernel that checks O_DIRECTORY first). Which one it was is read without following.
            Err(Errno::LOOP | Errno::NOTDIR) => Ok(match self.kind(name)? {
                Some(Kind::Link) => Found::Link,
                _ => Found::Other,
            }),
            Err(e) => Err(e.into()),
        }
    }

    /// The regular file `name` for reading (the caller looked at its kind first).
    /// `O_NONBLOCK`, so a FIFO swapped in since is refused at once; the kind is checked again on
    /// the handle.
    pub(crate) fn open_read(&self, name: &OsStr) -> io::Result<Found<File>> {
        let flags =
            OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC | OFlags::NOCTTY;
        let fd = match rfs::openat(&self.fd, name, flags, Mode::empty()) {
            Ok(fd) => fd,
            Err(Errno::LOOP) => return Ok(Found::Link),
            Err(e) => return Err(e.into()),
        };
        if kind_of(rfs::fstat(&fd)?.st_mode) != Kind::File {
            return Ok(Found::Other);
        }
        Ok(Found::It(File::from(fd)))
    }

    /// A new file `name` (`O_CREAT | O_EXCL | O_NOFOLLOW`: nothing that is there is opened) with
    /// `bits` (less the umask, as a plain create).
    pub(crate) fn create(&self, name: &OsStr, bits: u32) -> io::Result<File> {
        let flags = OFlags::WRONLY
            | OFlags::CREATE
            | OFlags::EXCL
            | OFlags::NOFOLLOW
            | OFlags::CLOEXEC
            | OFlags::NOCTTY;
        Ok(File::from(rfs::openat(&self.fd, name, flags, mode(bits))?))
    }

    pub(crate) fn make_dir(&self, name: &OsStr, bits: u32) -> io::Result<()> {
        Ok(rfs::mkdirat(&self.fd, name, mode(bits))?)
    }

    /// Remove the entry `name` that is not a folder (a link itself, never its target).
    pub(crate) fn unlink(&self, name: &OsStr) -> io::Result<()> {
        Ok(rfs::unlinkat(&self.fd, name, AtFlags::empty())?)
    }

    /// Remove the empty folder `name`.
    pub(crate) fn remove_dir(&self, name: &OsStr) -> io::Result<()> {
        Ok(rfs::unlinkat(&self.fd, name, AtFlags::REMOVEDIR)?)
    }

    /// Rename `from` to `to`, both in this folder; `to` is replaced (a link there too, unfollowed).
    pub(crate) fn rename(&self, from: &OsStr, to: &OsStr) -> io::Result<()> {
        Ok(rfs::renameat(&self.fd, from, &self.fd, to)?)
    }

    /// The target of the link `name`, as written.
    pub(crate) fn read_link(&self, name: &OsStr) -> io::Result<PathBuf> {
        let target = rfs::readlinkat(&self.fd, name, Vec::new())?;
        Ok(PathBuf::from(OsString::from_vec(target.into_bytes())))
    }

    /// Make `name` a link to `target`.
    pub(crate) fn symlink(&self, target: &Path, name: &OsStr) -> io::Result<()> {
        Ok(rfs::symlinkat(target, &self.fd, name)?)
    }

    /// The names in this folder (`.` and `..` left out).
    pub(crate) fn entries(&self) -> io::Result<Vec<OsString>> {
        let mut names = Vec::new();
        for entry in rfs::Dir::read_from(&self.fd)? {
            let entry = entry?;
            let bytes = entry.file_name().to_bytes();
            if bytes != b"." && bytes != b".." {
                names.push(OsStr::from_bytes(bytes).to_os_string());
            }
        }
        Ok(names)
    }

    /// This folder's permission bits.
    pub(crate) fn mode(&self) -> io::Result<u32> {
        Ok(rfs::fstat(&self.fd)?.st_mode & 0o7777)
    }

    pub(crate) fn set_mode(&self, bits: u32) -> io::Result<()> {
        Ok(rfs::fchmod(&self.fd, mode(bits))?)
    }

    /// Flush the folder (a rename in it is durable after this).
    pub(crate) fn sync(&self) -> io::Result<()> {
        Ok(rfs::fsync(&self.fd)?)
    }
}

/// The permission bits of an open file.
pub(crate) fn file_mode(file: &File) -> io::Result<u32> {
    Ok(rfs::fstat(file)?.st_mode & 0o7777)
}
