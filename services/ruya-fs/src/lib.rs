//! File access below a trusted folder that never follows a link (RUY-911): the one way a
//! service touches a folder that someone else controls (a profile's home, a sandboxed app's
//! data).
//!
//! A [`Dir`] is an open folder. Every path below it is walked one component at a time, each
//! folder opened from the one above with `openat(dirfd, name, O_NOFOLLOW | O_DIRECTORY |
//! O_CLOEXEC)`, and every call acts on one entry of an open folder (`openat`, `mkdirat`,
//! `unlinkat`, `renameat`). So a link at any component is refused ([`NotFollowed`]), and a folder
//! swapped for a link after it was opened cannot redirect anything: the handle still names the
//! folder that was opened.
//!
//! On it:
//! - [`Dir::read`] and [`Dir::open_file`]: a regular file only, opened `O_NONBLOCK` (a FIFO or a
//!   device planted there is refused at once), [`Dir::read`] with a size cap;
//! - [`Dir::write`]: atomic, a temporary file ([`temp_name`]) created `O_CREAT | O_EXCL |
//!   O_NOFOLLOW` 0600 in the parent folder, flushed, renamed over the file (`renameat`), the folder
//!   flushed; missing folders above it are made 0700;
//! - [`Dir::kind`] and [`Dir::entries`]: what an entry is, and what a folder holds (names and
//!   kinds), a link reported as a link;
//! - [`Dir::make_dirs`]: private folders (0700);
//! - [`Dir::remove`]: a tree removed entry by entry (`unlinkat`, `AT_REMOVEDIR` for a folder), each
//!   folder made 0700 before it is emptied so a read-only one does not stop it; a link is removed,
//!   never followed;
//! - [`Dir::copy`]: a tree copied (folders and regular files with their modes, links made again as
//!   links with the same target, never followed; FIFOs, devices and sockets skipped), with a depth
//!   cap; a file's bytes are shared with a reflink (`FICLONE`) where the file system can, else
//!   copied (RUY-1019);
//! - [`Dir::rename`]: an entry moved to another folder of the same file system (`renameat`), a
//!   link as a link;
//! - [`Dir::set_mode`] and [`Dir::read_link`]: a folder's or file's mode set, a link's target
//!   read, neither through a link;
//! - [`open_file`]: [`Dir::open_file`] for a file whose folder is itself trusted;
//! - [`write_atomic`]: [`Dir::write`] for a file whose folder is itself trusted.
//!
//! The Linux part is built on `rustix` (`linux.rs`). Off Linux (host builds and tests) the same API runs on plain
//! path calls that look at each entry first (`fallback.rs`): links are refused, but a race can win
//! there, modes are not set and links cannot be made.

use std::ffi::{OsStr, OsString};
use std::fmt;
use std::fs::File;
use std::io::{self, Read as _, Write as _};
use std::path::{Component, Path, PathBuf};

#[cfg(not(target_os = "linux"))]
mod fallback;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(not(target_os = "linux"))]
use fallback as imp;
#[cfg(target_os = "linux")]
use linux as imp;

/// What an entry is, read without following a link.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A folder.
    Dir,
    /// A regular file.
    File,
    /// A symbolic link.
    Link,
    /// Anything else (a device, a FIFO, a socket).
    Other,
}

/// What an open of one entry found.
pub(crate) enum Found<T> {
    /// The folder or regular file asked for.
    It(T),
    /// A link: not followed.
    Link,
    /// Something else (a file where a folder belongs, a FIFO where a file belongs).
    Other,
}

/// The mode of every folder this crate makes.
pub const PRIVATE_DIR: u32 = 0o700;
/// The mode of every file [`Dir::write`] makes.
pub const PRIVATE_FILE: u32 = 0o600;

/// The error of a call that met a link on its path: the link is not followed, and the caller
/// decides whether that is fatal.
#[derive(Debug)]
pub struct NotFollowed(pub String);

impl fmt::Display for NotFollowed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} is a link; it is not followed", self.0)
    }
}

impl std::error::Error for NotFollowed {}

impl NotFollowed {
    /// The `io::Error` for `path`.
    pub fn error(path: &str) -> io::Error {
        io::Error::new(io::ErrorKind::InvalidInput, NotFollowed(path.to_string()))
    }

    /// True when `err` is a [`NotFollowed`].
    pub fn is(err: &io::Error) -> bool {
        err.get_ref()
            .is_some_and(|e| e.downcast_ref::<NotFollowed>().is_some())
    }
}

/// The error of a path where a folder should be but something else is.
pub fn not_a_folder(path: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("{path} is not a folder"),
    )
}

/// The error of a copy whose tree is deeper than `max` folders.
pub fn too_deep(path: &str, max: usize) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("{path} is more than {max} folders deep"),
    )
}

fn refuse(path: &Path, what: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("{}: {what}", path.display()),
    )
}

/// The temporary file [`Dir::write`] uses for `name`: `<name>.tmp`, next to it.
pub fn temp_name(name: &OsStr) -> OsString {
    let mut tmp = name.to_os_string();
    tmp.push(".tmp");
    tmp
}

/// The names of `rel`, each a plain name (no root, `.` or `..`).
fn names(rel: &Path) -> io::Result<Vec<&OsStr>> {
    rel.components()
        .map(|c| match c {
            Component::Normal(name) => Ok(name),
            _ => Err(refuse(rel, "not a plain relative path")),
        })
        .collect()
}

fn ignore_missing(r: io::Result<()>) -> io::Result<()> {
    match r {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        r => r,
    }
}

/// An open folder; every path given to it is below it, walked without following a link.
#[derive(Debug)]
pub struct Dir {
    inner: imp::Dir,
    /// For messages only: never opened again.
    path: PathBuf,
}

impl Dir {
    /// Open the trusted folder `path` (a link in `path` itself is followed: the base is the
    /// caller's to trust; everything below it is not).
    pub fn open(path: &Path) -> io::Result<Dir> {
        Ok(Dir {
            inner: imp::Dir::open(path)?,
            path: path.to_path_buf(),
        })
    }

    /// The path this folder was reached by (for messages).
    pub fn path(&self) -> &Path {
        &self.path
    }

    fn try_clone(&self) -> io::Result<Dir> {
        Ok(Dir {
            inner: self.inner.try_clone()?,
            path: self.path.clone(),
        })
    }

    fn shown(&self, name: &OsStr) -> String {
        self.path.join(name).display().to_string()
    }

    /// The folder `name` in this one: a link is [`NotFollowed`], a file not a folder.
    fn child(&self, name: &OsStr) -> io::Result<Dir> {
        match self.inner.open_dir(name)? {
            Found::It(inner) => Ok(Dir {
                inner,
                path: self.path.join(name),
            }),
            Found::Link => Err(NotFollowed::error(&self.shown(name))),
            Found::Other => Err(not_a_folder(&self.shown(name))),
        }
    }

    fn walk_names(&self, names: &[&OsStr]) -> io::Result<Dir> {
        let mut cur = self.try_clone()?;
        for name in names {
            cur = cur.child(name)?;
        }
        Ok(cur)
    }

    /// The folder `rel` below this one (`NotFound` when a part is missing).
    pub fn walk(&self, rel: &Path) -> io::Result<Dir> {
        self.walk_names(&names(rel)?)
    }

    fn make_names(&self, names: &[&OsStr]) -> io::Result<Dir> {
        let mut cur = self.try_clone()?;
        for name in names {
            cur = match cur.child(name) {
                Err(e) if e.kind() == io::ErrorKind::NotFound => {
                    match cur.inner.make_dir(name, PRIVATE_DIR) {
                        // Made by someone else in between: `child` checks it is a folder.
                        Err(e) if e.kind() != io::ErrorKind::AlreadyExists => return Err(e),
                        _ => cur.child(name)?,
                    }
                }
                r => r?,
            };
        }
        Ok(cur)
    }

    /// Make the folders of `rel` below this one that are missing (0700); the last one, open.
    pub fn make_dirs(&self, rel: &Path) -> io::Result<Dir> {
        self.make_names(&names(rel)?)
    }

    /// The folder above `rel`'s last name (made when `make`), and that name.
    fn parent_of<'a>(&self, rel: &'a Path, make: bool) -> io::Result<(Dir, &'a OsStr)> {
        let names = names(rel)?;
        let Some((last, parents)) = names.split_last() else {
            return Err(refuse(rel, "names nothing below the folder"));
        };
        let parent = if make {
            self.make_names(parents)?
        } else {
            self.walk_names(parents)?
        };
        Ok((parent, last))
    }

    /// What `rel` is (a link at its end is [`Kind::Link`], not followed); `None` when nothing is
    /// there or a folder above it is missing. A link among the folders above it is
    /// [`NotFollowed`]. An empty `rel` is this folder: [`Kind::Dir`].
    pub fn kind(&self, rel: &Path) -> io::Result<Option<Kind>> {
        let names = names(rel)?;
        let Some((last, parents)) = names.split_last() else {
            return Ok(Some(Kind::Dir));
        };
        match self.walk_names(parents) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
            Ok(dir) => dir.inner.kind(last),
        }
    }

    /// The names and kinds of what is in the folder `rel` (this folder when `rel` is empty), in
    /// no order; a link is [`Kind::Link`], never followed. A link among the folders of `rel` is
    /// [`NotFollowed`], `NotFound` when it is missing. An entry removed while listing is left out.
    pub fn entries(&self, rel: &Path) -> io::Result<Vec<(OsString, Kind)>> {
        let dir = self.walk(rel)?;
        let mut out = Vec::new();
        for name in dir.inner.entries()? {
            if let Some(kind) = dir.inner.kind(&name)? {
                out.push((name, kind));
            }
        }
        Ok(out)
    }

    /// Open the regular file `rel` for reading. A link at any step is [`NotFollowed`]; a FIFO, a
    /// device or a folder is refused without blocking; `NotFound` when nothing is there.
    pub fn open_file(&self, rel: &Path) -> io::Result<File> {
        let (dir, name) = self.parent_of(rel, false)?;
        dir.open_name(name)
    }

    /// The kind is read first, so a FIFO or a device is not even opened; the open itself refuses
    /// a link (`O_NOFOLLOW`) and the kind is checked again on the handle.
    fn open_name(&self, name: &OsStr) -> io::Result<File> {
        let found = match self.inner.kind(name)? {
            None => return Err(io::ErrorKind::NotFound.into()),
            Some(Kind::File) => self.inner.open_read(name)?,
            Some(Kind::Link) => Found::Link,
            Some(_) => Found::Other,
        };
        match found {
            Found::It(file) => Ok(file),
            Found::Link => Err(NotFollowed::error(&self.shown(name))),
            Found::Other => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{} is not a regular file", self.shown(name)),
            )),
        }
    }

    /// The bytes of the regular file `rel` ([`Self::open_file`]); a file bigger than `limit`
    /// bytes is an error (`InvalidData`).
    pub fn read(&self, rel: &Path, limit: u64) -> io::Result<Vec<u8>> {
        let file = self.open_file(rel)?;
        let mut bytes = Vec::new();
        file.take(limit.saturating_add(1)).read_to_end(&mut bytes)?;
        if bytes.len() as u64 > limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "{} is bigger than {limit} bytes",
                    self.path.join(rel).display()
                ),
            ));
        }
        Ok(bytes)
    }

    /// Write `data` to `rel` atomically (a reader sees the old file or all of the new one): the
    /// folders above it are made when missing (0700), a stale [`temp_name`] is removed without
    /// following it, the new one is created exclusively 0600, flushed and renamed over `rel`
    /// (a link there is replaced, not followed), then the folder is flushed.
    pub fn write(&self, rel: &Path, data: &[u8]) -> io::Result<()> {
        let (dir, name) = self.parent_of(rel, true)?;
        dir.write_name(name, data)
    }

    fn write_name(&self, name: &OsStr, data: &[u8]) -> io::Result<()> {
        let tmp = temp_name(name);
        match self.inner.kind(&tmp)? {
            Some(Kind::Dir) => return Err(refuse(&self.path.join(&tmp), "is a folder")),
            Some(_) => ignore_missing(self.inner.unlink(&tmp))?,
            None => {}
        }
        {
            let mut f = self.inner.create(&tmp, PRIVATE_FILE)?;
            f.write_all(data)?;
            f.sync_all()?;
        }
        self.inner
            .rename(&tmp, &self.inner, name)
            .inspect_err(|_| {
                let _ = self.inner.unlink(&tmp);
            })?;
        self.inner.sync()
    }

    /// Remove `rel` and everything in it; a link is removed, never followed. Nothing there (or a
    /// folder above it missing) is not an error. A folder the owner closed to itself (any mode)
    /// is opened up first; one deeper than `max_depth` folders (counted as in [`Self::copy`]) is
    /// refused ([`too_deep`]) with what was emptied before it already gone.
    pub fn remove(&self, rel: &Path, max_depth: usize) -> io::Result<()> {
        let (dir, name) = match self.parent_of(rel, false) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
            r => r?,
        };
        dir.remove_name(name, 0, max_depth)
    }

    /// `depth` is the level of `name` (0 for the root of the removal), checked before it is opened.
    fn remove_name(&self, name: &OsStr, depth: usize, max: usize) -> io::Result<()> {
        if depth > max {
            return Err(too_deep(&self.shown(name), max));
        }
        match self.inner.kind(name)? {
            None => Ok(()),
            Some(Kind::Dir) => match self.inner.open_dir_for_removal(name) {
                Ok(Found::It(inner)) => {
                    let sub = Dir {
                        inner,
                        path: self.path.join(name),
                    };
                    // Writable before it is emptied: a read-only folder (a template's, a save's)
                    // would stop the removal otherwise.
                    sub.inner.set_mode(PRIVATE_DIR)?;
                    for entry in sub.inner.entries()? {
                        sub.remove_name(&entry, depth + 1, max)?;
                    }
                    ignore_missing(self.inner.remove_dir(name))
                }
                // Swapped for a link or a file since it was looked at: removed as that.
                Ok(_) => ignore_missing(self.inner.unlink(name)),
                Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e),
            },
            Some(_) => ignore_missing(self.inner.unlink(name)),
        }
    }

    /// Copy `rel` (a file, a folder with everything in it, or a link; this folder itself when
    /// `rel` is empty) to `to_rel` below `to`, replacing what is there; the folders above `to_rel`
    /// are made when missing. Inside the tree folders and regular files keep their modes (a
    /// folder is 0700 while it fills), links are made again with the same target and never
    /// followed, FIFOs, devices and sockets are skipped. A link among the folders of either path
    /// is [`NotFollowed`]; a tree deeper than `max_depth` folders is refused ([`too_deep`]).
    /// `Ok(false)` when nothing is at `rel`.
    pub fn copy(&self, rel: &Path, to: &Dir, to_rel: &Path, max_depth: usize) -> io::Result<bool> {
        let names = names(rel)?;
        let Some((last, parents)) = names.split_last() else {
            let (dst, dst_name) = to.parent_of(to_rel, true)?;
            self.copy_dir_into(&dst, dst_name, 0, max_depth)?;
            return Ok(true);
        };
        let src = match self.walk_names(parents) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(false),
            r => r?,
        };
        if src.inner.kind(last)?.is_none() {
            return Ok(false);
        }
        let (dst, dst_name) = to.parent_of(to_rel, true)?;
        src.copy_name(last, &dst, dst_name, 0, max_depth)?;
        Ok(true)
    }

    fn copy_name(
        &self,
        name: &OsStr,
        dst: &Dir,
        dst_name: &OsStr,
        depth: usize,
        max: usize,
    ) -> io::Result<()> {
        if depth > max {
            return Err(too_deep(&self.shown(name), max));
        }
        match self.inner.kind(name)? {
            None => Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("{} went away during the copy", self.shown(name)),
            )),
            Some(Kind::Link) => {
                let target = self.inner.read_link(name)?;
                dst.remove_name(dst_name, 0, max)?;
                dst.inner.symlink(&target, dst_name)
            }
            Some(Kind::Dir) => self.child(name)?.copy_dir_into(dst, dst_name, depth, max),
            Some(Kind::File) => {
                let mut from = self.open_name(name)?;
                let mode = imp::file_mode(&from)? & 0o777;
                dst.remove_name(dst_name, 0, max)?;
                let mut to = dst.inner.create(dst_name, mode)?;
                imp::copy_bytes(&mut from, &mut to)
            }
            Some(Kind::Other) => Ok(()),
        }
    }

    /// This folder's content into `dst/dst_name` (a folder there is kept, anything else replaced).
    /// `depth` is this folder's level, already checked by [`Self::copy_name`] (0 for the root).
    fn copy_dir_into(
        &self,
        dst: &Dir,
        dst_name: &OsStr,
        depth: usize,
        max: usize,
    ) -> io::Result<()> {
        if dst.inner.kind(dst_name)? != Some(Kind::Dir) {
            dst.remove_name(dst_name, 0, max)?;
            dst.inner.make_dir(dst_name, PRIVATE_DIR)?;
        }
        let to = dst.child(dst_name)?;
        // Writable while it fills; the source's mode (a read-only folder too) once it is full.
        to.inner.set_mode(PRIVATE_DIR)?;
        for entry in self.inner.entries()? {
            self.copy_name(&entry, &to, &entry, depth + 1, max)?;
        }
        to.inner.set_mode(self.inner.mode()?)
    }

    /// Move `rel` (a file, a folder with everything in it, or a link, moved as the link) to
    /// `to_rel` below `to`, which must be on the same file system (`renameat`: nothing is
    /// copied). The folders above `to_rel` are made when missing (0700); a file or a link at
    /// `to_rel` is replaced, never followed, an empty folder by a folder only. A link among the
    /// folders of either path is [`NotFollowed`]; `NotFound` when nothing is at `rel`.
    pub fn rename(&self, rel: &Path, to: &Dir, to_rel: &Path) -> io::Result<()> {
        let (src, name) = self.parent_of(rel, false)?;
        if src.inner.kind(name)?.is_none() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("{} is not there", src.shown(name)),
            ));
        }
        let (dst, dst_name) = to.parent_of(to_rel, true)?;
        src.inner.rename(name, &dst.inner, dst_name)
    }

    /// Set the permission bits of the folder or regular file `rel` (an empty `rel` is this
    /// folder). A link at its end or among its folders is [`NotFollowed`]; a folder its owner
    /// closed to itself is opened up first, as [`Self::remove`] does. Nothing off Linux.
    pub fn set_mode(&self, rel: &Path, mode: u32) -> io::Result<()> {
        let names = names(rel)?;
        let Some((last, parents)) = names.split_last() else {
            return self.inner.set_mode(mode);
        };
        let dir = self.walk_names(parents)?;
        match dir.inner.kind(last)? {
            None => Err(io::ErrorKind::NotFound.into()),
            Some(Kind::Dir) => match dir.inner.open_dir_for_removal(last)? {
                Found::It(inner) => inner.set_mode(mode),
                Found::Link => Err(NotFollowed::error(&dir.shown(last))),
                Found::Other => Err(not_a_folder(&dir.shown(last))),
            },
            Some(_) => imp::set_file_mode(&dir.open_name(last)?, mode),
        }
    }

    /// The target of the link `rel`, as written (never followed). A link among its folders is
    /// [`NotFollowed`]; something that is not a link is refused.
    pub fn read_link(&self, rel: &Path) -> io::Result<PathBuf> {
        let (dir, name) = self.parent_of(rel, false)?;
        match dir.inner.kind(name)? {
            None => Err(io::ErrorKind::NotFound.into()),
            Some(Kind::Link) => dir.inner.read_link(name),
            Some(_) => Err(refuse(&dir.path.join(name), "is not a link")),
        }
    }

    /// Make `rel` a link to `target` (the folders above it made when missing, whatever is at
    /// `rel` removed first, not followed, with the depth cap of [`Self::remove`]).
    pub fn symlink(&self, target: &Path, rel: &Path, max_depth: usize) -> io::Result<()> {
        let (dir, name) = self.parent_of(rel, true)?;
        dir.remove_name(name, 0, max_depth)?;
        dir.inner.symlink(target, name)
    }
}

/// Open the regular file `path` for reading ([`Dir::open_file`]) when the caller has only a path:
/// the folder above it is the caller's to trust, a link as the file itself is [`NotFollowed`].
pub fn open_file(path: &Path) -> io::Result<File> {
    let Some(name) = path.file_name() else {
        return Err(refuse(path, "names no file"));
    };
    let folder = match path.parent() {
        Some(p) if !p.as_os_str().is_empty() => p,
        _ => Path::new("."),
    };
    Dir::open(folder)?.open_name(name)
}

/// [`Dir::write`] for `path` in a folder that is itself trusted (a service's own state folder):
/// only the file and its temporary file are protected from links.
pub fn write_atomic(path: &Path, data: &[u8]) -> io::Result<()> {
    let Some(name) = path.file_name() else {
        return Err(refuse(path, "names no file"));
    };
    let folder = match path.parent() {
        Some(p) if !p.as_os_str().is_empty() => p,
        _ => Path::new("."),
    };
    Dir::open(folder)?.write_name(name, data)
}

#[cfg(test)]
mod tests;
