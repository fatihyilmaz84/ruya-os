//! Staging directories, written through directory handles (05 §9.1, §9.3).
//!
//! A [`Dir`] is one open folder. Every name it takes is a single checked path component, never a
//! joined path, and nothing it does follows a link:
//!
//! - **Linux and other Unix:** a directory file descriptor; folders are opened with
//!   `openat(O_DIRECTORY | O_NOFOLLOW)`, created with `mkdirat`, files with
//!   `openat(O_CREAT | O_EXCL | O_NOFOLLOW)`, links with `symlinkat`, modes set with `fchmod` (so
//!   the umask cannot change them and no setuid, setgid or sticky bit survives), and the re-walk
//!   reads entries with `statat(AT_SYMLINK_NOFOLLOW)`. A link planted on the way is an error, never
//!   a way out: an open folder handle keeps pointing at the folder the importer made.
//! - **Windows (development only):** a rooted path that refuses reparse points at every step and
//!   creates files with `CREATE_NEW` and `FILE_FLAG_OPEN_REPARSE_POINT`. It checks before it acts,
//!   so it is not race-free; the service only runs on Linux.

use crate::service::commit::canonical_mode;
use std::fmt;
use std::io;
use std::path::{Path, PathBuf};

/// What an entry of a staged folder is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A regular file.
    File,
    /// A folder.
    Dir,
    /// A symbolic link (or, on Windows, any reparse point).
    Link,
    /// Anything else, or a name that is not UTF-8.
    Other,
}

/// One entry of a staged folder, read without following links.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    /// The name in its folder.
    pub name: String,
    /// What it is.
    pub kind: Kind,
    /// Size in bytes (files).
    pub size: u64,
    /// Permission bits including setuid, setgid and sticky (`0o7777`); 0 on Windows.
    pub mode: u32,
    /// A link's target as stored (`/` separated).
    pub target: Option<String>,
}

/// The staged tree is not what the importer wrote (a planted name or link).
#[derive(Debug)]
struct Changed(String);

impl fmt::Display for Changed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "the staging folder changed under the importer: {}",
            self.0
        )
    }
}

impl std::error::Error for Changed {}

fn changed(what: impl Into<String>) -> io::Error {
    io::Error::other(Changed(what.into()))
}

/// True when `err` says the staged tree was changed by someone else (a name the importer was about
/// to create exists, or a folder on the way is a link), as opposed to an ordinary I/O failure.
pub fn is_changed(err: &io::Error) -> bool {
    err.get_ref().is_some_and(|e| e.is::<Changed>())
}

/// True when `err` is "no space left on the device".
pub fn is_no_space(err: &io::Error) -> bool {
    #[cfg(unix)]
    {
        err.raw_os_error() == Some(rustix::io::Errno::NOSPC.raw_os_error())
    }
    #[cfg(windows)]
    {
        // ERROR_HANDLE_DISK_FULL, ERROR_DISK_FULL
        matches!(err.raw_os_error(), Some(39) | Some(112))
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = err;
        false
    }
}

/// Check that `name` is one plain path component: not empty, not `.` or `..`, no separator, no
/// NUL or colon, at most 255 bytes. Package paths passed the format's rules already; this is the
/// second line of defence at the place names reach the filesystem.
pub fn component(name: &str) -> io::Result<&str> {
    let bad = name.is_empty()
        || name == "."
        || name == ".."
        || name.len() > 255
        || name.bytes().any(|b| matches!(b, b'/' | b'\\' | 0 | b':'));
    if bad {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{name:?} is not a single path component"),
        ));
    }
    Ok(name)
}

/// `root` plus the checked components of the package path `rel` (for the art step, which takes
/// paths; it runs after the re-walk proved there is no link on the way).
pub fn join_checked(root: &Path, rel: &str) -> io::Result<PathBuf> {
    let mut p = root.to_path_buf();
    for c in rel.split('/') {
        p.push(component(c)?);
    }
    Ok(p)
}

/// An open folder.
#[derive(Debug)]
pub struct Dir {
    path: PathBuf,
    #[cfg(unix)]
    fd: std::os::fd::OwnedFd,
}

impl Dir {
    /// The path the folder had when it was opened (for messages and for the art step).
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// A second handle on the same folder (on Unix a duplicate of the descriptor, not a reopen by
    /// path).
    pub fn try_clone(&self) -> io::Result<Dir> {
        Ok(Dir {
            path: self.path.clone(),
            #[cfg(unix)]
            fd: self.fd.try_clone()?,
        })
    }

    /// Remove the entry `name` of this folder (a file, a link, or a folder with everything in it),
    /// never following a link: a link is removed, not what it points at.
    pub fn remove_entry(&self, name: &str) -> io::Result<()> {
        let p = self.path.join(component(name)?);
        let meta = std::fs::symlink_metadata(&p)?;
        if meta.is_dir() {
            // std removes through open folder handles (openat/unlinkat with O_NOFOLLOW on Unix,
            // and without following reparse points on Windows, since the CVE-2022-21658 fix).
            std::fs::remove_dir_all(&p)
        } else {
            std::fs::remove_file(&p)
        }
    }

    /// Open the folder `name`, creating it with `mode` when it is absent.
    pub fn dir(&self, name: &str, mode: u32) -> io::Result<Dir> {
        match self.open_dir(name) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => self.create_dir(name, mode),
            other => other,
        }
    }
}

#[cfg(unix)]
mod imp {
    use super::{changed, component, Dir, Found, Kind};
    use rustix::fs::{self as rfs, AtFlags, FileType, Mode, OFlags};
    use rustix::io::Errno;
    use std::ffi::CStr;
    use std::io;
    use std::path::Path;

    fn dir_flags() -> OFlags {
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC
    }

    /// ELOOP, ENOTDIR and EEXIST mean a planted name or link: the tree changed.
    fn classify(e: Errno, name: &str) -> io::Error {
        if e == Errno::LOOP || e == Errno::NOTDIR || e == Errno::EXIST {
            changed(format!("{name:?} ({e})"))
        } else {
            io::Error::from(e)
        }
    }

    #[allow(clippy::unnecessary_cast)] // RawMode is u32 on Linux, u16 elsewhere
    fn mode(bits: u32) -> Mode {
        Mode::from_raw_mode(bits as rfs::RawMode)
    }

    impl Dir {
        /// Open a configured folder (the staging root). Its last component may not be a link.
        pub fn open_root(path: &Path) -> io::Result<Dir> {
            let fd = rfs::openat(rfs::CWD, path, dir_flags(), Mode::empty())?;
            Ok(Dir {
                path: path.to_path_buf(),
                fd,
            })
        }

        /// Create the folder `name` exclusively (an existing name of any kind is an error) and
        /// open it; its mode is `mode` whatever the umask.
        pub fn create_dir(&self, name: &str, bits: u32) -> io::Result<Dir> {
            let name = component(name)?;
            rfs::mkdirat(&self.fd, name, mode(bits & 0o777)).map_err(|e| classify(e, name))?;
            let fd = rfs::openat(&self.fd, name, dir_flags(), Mode::empty())
                .map_err(|e| classify(e, name))?;
            rfs::fchmod(&fd, mode(bits & 0o777))?;
            Ok(Dir {
                path: self.path.join(name),
                fd,
            })
        }

        /// Open the existing folder `name`; a link there is an error.
        pub fn open_dir(&self, name: &str) -> io::Result<Dir> {
            let name = component(name)?;
            let fd = rfs::openat(&self.fd, name, dir_flags(), Mode::empty()).map_err(|e| {
                if e == Errno::NOENT {
                    io::Error::from(e)
                } else {
                    classify(e, name)
                }
            })?;
            Ok(Dir {
                path: self.path.join(name),
                fd,
            })
        }

        /// Create the file `name` exclusively for writing, with exactly `bits` (0644 or 0755).
        pub fn create_file(&self, name: &str, bits: u32) -> io::Result<std::fs::File> {
            let name = component(name)?;
            let flags = OFlags::WRONLY
                | OFlags::CREATE
                | OFlags::EXCL
                | OFlags::NOFOLLOW
                | OFlags::CLOEXEC
                | OFlags::NOCTTY;
            let fd = rfs::openat(&self.fd, name, flags, mode(bits & 0o777))
                .map_err(|e| classify(e, name))?;
            rfs::fchmod(&fd, mode(bits & 0o777))?;
            Ok(std::fs::File::from(fd))
        }

        /// Open the existing regular file `name` for reading (the service's re-hash of a tree the
        /// helper wrote): a link is `staging.changed`, and so is anything but a regular file (a
        /// FIFO is opened without blocking and refused).
        pub fn open_file(&self, name: &str) -> io::Result<std::fs::File> {
            let name = component(name)?;
            let flags = OFlags::RDONLY
                | OFlags::NOFOLLOW
                | OFlags::NONBLOCK
                | OFlags::CLOEXEC
                | OFlags::NOCTTY;
            let fd = rfs::openat(&self.fd, name, flags, Mode::empty()).map_err(|e| {
                if e == Errno::NOENT {
                    io::Error::from(e)
                } else {
                    classify(e, name)
                }
            })?;
            let st = rfs::fstat(&fd)?;
            if FileType::from_raw_mode(st.st_mode) != FileType::RegularFile {
                return Err(changed(format!("{name:?} is not a regular file")));
            }
            Ok(std::fs::File::from(fd))
        }

        /// Create the link `name` pointing at `target` (as written in `play.files`).
        pub fn symlink(&self, name: &str, target: &str, _target_is_dir: bool) -> io::Result<()> {
            let name = component(name)?;
            rfs::symlinkat(target, &self.fd, name).map_err(|e| classify(e, name))
        }

        /// Every entry of this folder, read without following links.
        pub fn entries(&self) -> io::Result<Vec<Found>> {
            let mut out = Vec::new();
            for entry in rfs::Dir::read_from(&self.fd)? {
                let entry = entry?;
                let raw: &CStr = entry.file_name();
                let bytes = raw.to_bytes();
                if bytes == b"." || bytes == b".." {
                    continue;
                }
                let Ok(name) = std::str::from_utf8(bytes) else {
                    out.push(Found {
                        name: String::from_utf8_lossy(bytes).into_owned(),
                        kind: Kind::Other,
                        size: 0,
                        mode: 0,
                        target: None,
                    });
                    continue;
                };
                let st = rfs::statat(&self.fd, raw, AtFlags::SYMLINK_NOFOLLOW)?;
                #[allow(clippy::unnecessary_cast)]
                let raw_mode = st.st_mode as u32;
                let kind = match FileType::from_raw_mode(st.st_mode) {
                    FileType::RegularFile => Kind::File,
                    FileType::Directory => Kind::Dir,
                    FileType::Symlink => Kind::Link,
                    _ => Kind::Other,
                };
                let target = if kind == Kind::Link {
                    let t = rfs::readlinkat(&self.fd, raw, Vec::new())?;
                    Some(String::from_utf8_lossy(t.as_bytes()).into_owned())
                } else {
                    None
                };
                out.push(Found {
                    name: name.to_string(),
                    kind,
                    size: u64::try_from(st.st_size).unwrap_or(0),
                    mode: raw_mode & 0o7777,
                    target,
                });
            }
            out.sort_by(|a, b| a.name.cmp(&b.name));
            Ok(out)
        }

        /// Bytes an unprivileged writer may still use on this folder's filesystem.
        pub fn free_bytes(&self) -> io::Result<u64> {
            let st = rfs::fstatvfs(&self.fd)?;
            Ok(st.f_bavail.saturating_mul(st.f_frsize))
        }

        /// Give the entry `name` of this folder (a file or a folder, never what a link points
        /// at) to the group `gid`; the owner stays.
        pub fn set_group(&self, name: &str, gid: u32) -> io::Result<()> {
            let name = component(name)?;
            rfs::chownat(
                &self.fd,
                name,
                None,
                Some(rfs::Gid::from_raw(gid)),
                AtFlags::SYMLINK_NOFOLLOW,
            )
            .map_err(|e| classify(e, name))
        }
    }
}

#[cfg(not(unix))]
mod imp {
    use super::{changed, component, Dir, Found, Kind};
    use std::fs;
    use std::io;
    use std::path::Path;

    /// A folder or file that is not a reparse point.
    fn plain(meta: &fs::Metadata) -> bool {
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
            !meta.file_type().is_symlink()
                && meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0
        }
        #[cfg(not(windows))]
        {
            !meta.file_type().is_symlink()
        }
    }

    fn plain_dir(path: &Path, name: &str) -> io::Result<()> {
        let meta = fs::symlink_metadata(path)?;
        if meta.is_dir() && plain(&meta) {
            Ok(())
        } else {
            Err(changed(format!("{name:?} is not a plain folder")))
        }
    }

    impl Dir {
        /// Open a configured folder (the staging root). It may not be a link.
        pub fn open_root(path: &Path) -> io::Result<Dir> {
            plain_dir(path, &path.display().to_string())?;
            Ok(Dir {
                path: path.to_path_buf(),
            })
        }

        /// Create the folder `name` exclusively (an existing name of any kind is an error).
        pub fn create_dir(&self, name: &str, _bits: u32) -> io::Result<Dir> {
            let name = component(name)?;
            let p = self.path.join(name);
            fs::create_dir(&p).map_err(|e| {
                if e.kind() == io::ErrorKind::AlreadyExists {
                    changed(format!("{name:?} exists"))
                } else {
                    e
                }
            })?;
            plain_dir(&p, name)?;
            Ok(Dir { path: p })
        }

        /// Open the existing folder `name`; a reparse point there is an error.
        pub fn open_dir(&self, name: &str) -> io::Result<Dir> {
            let name = component(name)?;
            let p = self.path.join(name);
            plain_dir(&p, name)?;
            Ok(Dir { path: p })
        }

        /// Create the file `name` exclusively for writing (modes do not exist here).
        pub fn create_file(&self, name: &str, _bits: u32) -> io::Result<fs::File> {
            let name = component(name)?;
            plain_dir(&self.path, name)?;
            let mut o = fs::OpenOptions::new();
            o.write(true).create_new(true);
            #[cfg(windows)]
            {
                use std::os::windows::fs::OpenOptionsExt;
                const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
                o.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
            }
            o.open(self.path.join(name)).map_err(|e| {
                if e.kind() == io::ErrorKind::AlreadyExists {
                    changed(format!("{name:?} exists"))
                } else {
                    e
                }
            })
        }

        /// Open the existing regular file `name` for reading; a reparse point is an error.
        pub fn open_file(&self, name: &str) -> io::Result<fs::File> {
            let name = component(name)?;
            plain_dir(&self.path, name)?;
            let p = self.path.join(name);
            let meta = fs::symlink_metadata(&p)?;
            if !(meta.is_file() && plain(&meta)) {
                return Err(changed(format!("{name:?} is not a regular file")));
            }
            fs::File::open(p)
        }

        /// Create the link `name` pointing at `target` (`/` separated, as in `play.files`).
        pub fn symlink(&self, name: &str, target: &str, target_is_dir: bool) -> io::Result<()> {
            let name = component(name)?;
            plain_dir(&self.path, name)?;
            let p = self.path.join(name);
            #[cfg(windows)]
            {
                let t = target.replace('/', "\\");
                if target_is_dir {
                    std::os::windows::fs::symlink_dir(t, p)
                } else {
                    std::os::windows::fs::symlink_file(t, p)
                }
            }
            #[cfg(not(windows))]
            {
                let _ = (p, target, target_is_dir);
                Err(io::Error::new(
                    io::ErrorKind::Unsupported,
                    "links need Unix or Windows",
                ))
            }
        }

        /// Every entry of this folder, read without following links.
        pub fn entries(&self) -> io::Result<Vec<Found>> {
            let mut out = Vec::new();
            for entry in fs::read_dir(&self.path)? {
                let entry = entry?;
                let name = entry.file_name();
                let Some(name) = name.to_str() else {
                    out.push(Found {
                        name: name.to_string_lossy().into_owned(),
                        kind: Kind::Other,
                        size: 0,
                        mode: 0,
                        target: None,
                    });
                    continue;
                };
                let meta = fs::symlink_metadata(entry.path())?;
                let kind = if !plain(&meta) {
                    Kind::Link
                } else if meta.is_dir() {
                    Kind::Dir
                } else if meta.is_file() {
                    Kind::File
                } else {
                    Kind::Other
                };
                let target = if kind == Kind::Link {
                    fs::read_link(entry.path())
                        .ok()
                        .map(|t| t.to_string_lossy().replace('\\', "/"))
                } else {
                    None
                };
                out.push(Found {
                    name: name.to_string(),
                    kind,
                    size: if kind == Kind::File { meta.len() } else { 0 },
                    mode: 0,
                    target,
                });
            }
            out.sort_by(|a, b| a.name.cmp(&b.name));
            Ok(out)
        }

        /// Groups do not exist here; the service only gives one on Linux.
        pub fn set_group(&self, name: &str, _gid: u32) -> io::Result<()> {
            component(name).map(|_| ())
        }

        /// Not available here: the free-space check takes a [`crate::core::deps::FreeSpace`].
        pub fn free_bytes(&self) -> io::Result<u64> {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "free space is read on Linux only",
            ))
        }
    }
}

/// Remove every entry of the staging root: what a crash or a power cut left behind. Returns how
/// many entries were removed. Links are removed, never followed.
pub fn clear(root: &Dir) -> io::Result<usize> {
    let mut n = 0;
    for f in root.entries()? {
        root.remove_entry(&f.name)?;
        n += 1;
    }
    Ok(n)
}

/// Copy everything in the folder `from` into the folder `to`, through both handles and without
/// following a link: the commit's modes ([`canonical_mode`]: folders 0755, files 0755 when any
/// execute bit is set and 0644 otherwise), links recreated with their targets as stored. An entry of another kind is an error. `skip`
/// gets each entry's path below `from` (`/` separated) and leaves it out (a folder with everything
/// in it). The bytes go through `std::io::copy`, which on Linux uses `copy_file_range`: a reflink
/// where the filesystem has them (XFS, 05 §7.1). Returns the bytes copied.
pub fn copy_tree(from: &Dir, to: &Dir, skip: &dyn Fn(&str, &Found) -> bool) -> io::Result<u64> {
    let mut bytes = 0u64;
    let mut pending = vec![(String::new(), from.try_clone()?, to.try_clone()?)];
    while let Some((prefix, src, dst)) = pending.pop() {
        for f in src.entries()? {
            let path = format!("{prefix}{}", f.name);
            if skip(&path, &f) {
                continue;
            }
            match f.kind {
                Kind::Dir => {
                    let inner = dst.create_dir(&f.name, canonical_mode(true, f.mode))?;
                    pending.push((format!("{path}/"), src.open_dir(&f.name)?, inner));
                }
                Kind::File => {
                    let mut out = dst.create_file(&f.name, canonical_mode(false, f.mode))?;
                    bytes += io::copy(&mut src.open_file(&f.name)?, &mut out)?;
                }
                Kind::Link => {
                    let target = f.target.as_deref().unwrap_or_default();
                    dst.symlink(&f.name, target, false)?;
                }
                Kind::Other => return Err(changed(format!("{path:?} cannot be copied"))),
            }
        }
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tree_is_copied_with_canonical_modes_and_skips() {
        let t = tempfile::tempdir().unwrap();
        let root = Dir::open_root(t.path()).unwrap();
        let from = root.create_dir("from", 0o755).unwrap();
        let sub = from.create_dir("sub", 0o700).unwrap();
        io::Write::write_all(&mut sub.create_file("a", 0o600).unwrap(), b"abc").unwrap();
        io::Write::write_all(&mut from.create_file("run", 0o700).unwrap(), b"x").unwrap();
        drop(from.create_file(".ref", 0o644).unwrap());
        let to = root.create_dir("to", 0o755).unwrap();
        let skip = |p: &str, _: &Found| p == ".ref";
        assert_eq!(copy_tree(&from, &to, &skip).unwrap(), 4);
        let names: Vec<String> = to.entries().unwrap().into_iter().map(|f| f.name).collect();
        assert_eq!(names, ["run", "sub"]);
        let inner = to.open_dir("sub").unwrap().entries().unwrap();
        assert_eq!((inner[0].name.as_str(), inner[0].size), ("a", 3));
        #[cfg(unix)]
        {
            assert_eq!(inner[0].mode, 0o644);
            let run = to.entries().unwrap();
            assert_eq!((run[0].mode, run[1].mode), (0o755, 0o755));
        }
    }

    #[test]
    fn a_component_is_one_plain_name() {
        for ok in ["a", "game.exe", "..x", "x..", "a b"] {
            assert!(component(ok).is_ok(), "{ok}");
        }
        let long = "x".repeat(256);
        for bad in ["", ".", "..", "a/b", "a\\b", "a:b", "a\0b", long.as_str()] {
            assert!(component(bad).is_err(), "{bad:?}");
        }
        assert!(join_checked(Path::new("r"), "a/../b").is_err());
        assert_eq!(
            join_checked(Path::new("r"), "a/b").unwrap(),
            Path::new("r").join("a").join("b")
        );
    }

    #[test]
    fn a_folder_is_created_exclusively_and_files_never_overwrite() {
        let t = tempfile::tempdir().unwrap();
        let root = Dir::open_root(t.path()).unwrap();
        let d = root.create_dir("job-1", 0o700).unwrap();
        let e = root.create_dir("job-1", 0o700).unwrap_err();
        assert!(is_changed(&e), "{e}");
        drop(d.create_file("f", 0o644).unwrap());
        let e = d.create_file("f", 0o644).unwrap_err();
        assert!(is_changed(&e), "{e}");
        let found = d.entries().unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!((found[0].name.as_str(), found[0].kind), ("f", Kind::File));
        assert_eq!(clear(&root).unwrap(), 1);
        assert!(root.entries().unwrap().is_empty());
    }
}
