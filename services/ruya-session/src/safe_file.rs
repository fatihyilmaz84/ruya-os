//! The one way ruya-session writes a file: atomically, privately, and never through a link.
//!
//! The service's own state (`usage_store`) and the files it edits inside a profile (Steam's
//! default tool, `steam_tool`) go through here. The second kind sits in a folder that a sandboxed
//! app controls (the Steam Flatpak persists its whole `~/.var/app/com.valvesoftware.Steam`), and the
//! writer runs outside that sandbox with the profile user's rights: a link planted by the app must
//! never decide where the write lands.
//!
//! - [`write_below`] walks the folders of the path one by one below a base, refuses a link or a
//!   non-folder at any step, and creates missing folders 0700;
//! - [`write_atomic`] removes a stale temporary file without following it, creates a new one
//!   (`create_new`, `O_NOFOLLOW`, 0600), writes and flushes it, renames it over the file and
//!   flushes the folder.

use std::fs;
use std::io::{self, Write as _};
use std::path::{Component, Path};

fn refuse(path: &Path, what: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("{}: {what}", path.display()),
    )
}

/// Makes the folders `rel` below `base` (a folder that exists), one step at a time. A link or a
/// file at any step is refused: nothing is followed.
pub fn private_dirs_below(base: &Path, rel: &Path) -> io::Result<()> {
    let mut at = base.to_path_buf();
    for part in rel.components() {
        let Component::Normal(name) = part else {
            return Err(refuse(rel, "not a plain relative path"));
        };
        at.push(name);
        match fs::symlink_metadata(&at) {
            Ok(m) if m.is_dir() => {}
            Ok(m) if m.file_type().is_symlink() => return Err(refuse(&at, "is a link")),
            Ok(_) => return Err(refuse(&at, "is not a folder")),
            Err(e) if e.kind() == io::ErrorKind::NotFound => make_dir(&at)?,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

fn make_dir(path: &Path) -> io::Result<()> {
    #[cfg_attr(not(unix), allow(unused_mut))]
    let mut b = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        b.mode(0o700);
    }
    b.create(path)
}

/// Writes `data` to `base/rel`: the folders above the file are checked and made
/// ([`private_dirs_below`]), then [`write_atomic`].
pub fn write_below(base: &Path, rel: &Path, data: &[u8]) -> io::Result<()> {
    private_dirs_below(base, rel.parent().unwrap_or(Path::new("")))?;
    write_atomic(&base.join(rel), data)
}

/// Reads `base/rel` as text, refusing a link at any step (the folders and the file itself).
/// `NotFound` when nothing is there.
pub fn read_below(base: &Path, rel: &Path) -> io::Result<String> {
    let mut at = base.to_path_buf();
    for part in rel.components() {
        let Component::Normal(name) = part else {
            return Err(refuse(rel, "not a plain relative path"));
        };
        at.push(name);
        if fs::symlink_metadata(&at)?.file_type().is_symlink() {
            return Err(refuse(&at, "is a link"));
        }
    }
    let mut o = fs::OpenOptions::new();
    o.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.custom_flags(libc::O_NOFOLLOW);
    }
    io::read_to_string(o.open(&at)?)
}

fn new_private_file(path: &Path) -> io::Result<fs::File> {
    let mut o = fs::OpenOptions::new();
    o.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    o.open(path)
}

/// Writes `data` to `path` so a reader sees all of it or the old file. The temporary file is
/// `path` with the extension `tmp`; whatever is there is removed first (a link is removed, not
/// followed), and the new one is created exclusively, so nothing planted can be opened.
pub fn write_atomic(path: &Path, data: &[u8]) -> io::Result<()> {
    let tmp = path.with_extension("tmp");
    match fs::symlink_metadata(&tmp) {
        Ok(m) if m.is_dir() => return Err(refuse(&tmp, "is a folder")),
        Ok(_) => fs::remove_file(&tmp)?,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    {
        let mut f = new_private_file(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path).inspect_err(|_| {
        let _ = fs::remove_file(&tmp);
    })?;
    #[cfg(unix)]
    if let Some(folder) = path.parent() {
        fs::File::open(folder)?.sync_all()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_is_written_whole_and_replaced() {
        let tmp = tempfile::tempdir().expect("tmp");
        write_below(tmp.path(), Path::new("a/b/f.txt"), b"one").expect("write");
        write_below(tmp.path(), Path::new("a/b/f.txt"), b"two").expect("replace");
        assert_eq!(
            fs::read(tmp.path().join("a/b/f.txt")).expect("read"),
            b"two"
        );
        assert!(!tmp.path().join("a/b/f.tmp").exists());
        assert!(write_below(tmp.path(), Path::new("../x"), b"x").is_err());
        assert!(write_below(tmp.path(), Path::new("/x"), b"x").is_err());
    }

    #[cfg(unix)]
    mod unix {
        use super::*;
        use std::os::unix::fs::{symlink, PermissionsExt};

        fn mode(path: &Path) -> u32 {
            fs::metadata(path).expect("meta").permissions().mode() & 0o777
        }

        #[test]
        fn files_are_0600_and_made_folders_0700() {
            let tmp = tempfile::tempdir().expect("tmp");
            write_below(tmp.path(), Path::new("a/b/f.txt"), b"x").expect("write");
            assert_eq!(mode(&tmp.path().join("a/b/f.txt")), 0o600);
            assert_eq!(mode(&tmp.path().join("a")), 0o700);
            assert_eq!(mode(&tmp.path().join("a/b")), 0o700);
        }

        /// A link named `planted` (in `base`) to a victim file; then `f` is written. The victim
        /// is untouched and `f` is a plain file with the new bytes.
        fn writes_over_a_planted_link(planted: &str) {
            let tmp = tempfile::tempdir().expect("tmp");
            let victim = tmp.path().join("victim");
            fs::write(&victim, "keep").expect("victim");
            let base = tmp.path().join("base");
            fs::create_dir(&base).expect("base");
            symlink(&victim, base.join(planted)).expect("link");
            write_below(&base, Path::new("f"), b"new").expect("write");
            assert_eq!(fs::read_to_string(&victim).expect("read"), "keep");
            assert_eq!(fs::read(base.join("f")).expect("read"), b"new");
            assert!(!fs::symlink_metadata(base.join("f"))
                .expect("meta")
                .file_type()
                .is_symlink());
            assert!(!base.join("f.tmp").exists());
        }

        #[test]
        fn a_planted_link_as_the_temporary_file_is_not_written_through() {
            writes_over_a_planted_link("f.tmp");
        }

        #[test]
        fn a_planted_link_as_the_file_is_replaced_not_followed() {
            writes_over_a_planted_link("f");
        }

        #[test]
        fn a_linked_folder_anywhere_below_the_base_is_refused() {
            let tmp = tempfile::tempdir().expect("tmp");
            let outside = tmp.path().join("elsewhere");
            fs::create_dir(&outside).expect("outside");
            let base = tmp.path().join("base");
            fs::create_dir_all(base.join("a")).expect("base");
            symlink(&outside, base.join("a/b")).expect("link");
            let err = write_below(&base, Path::new("a/b/c/f"), b"x").expect_err("refused");
            assert!(err.to_string().contains("is a link"), "{err}");
            assert_eq!(fs::read_dir(&outside).expect("list").count(), 0);
            // A link at the first step too, and a file where a folder belongs.
            symlink(&outside, base.join("top")).expect("link");
            assert!(write_below(&base, Path::new("top/f"), b"x").is_err());
            fs::write(base.join("plain"), "x").expect("file");
            assert!(write_below(&base, Path::new("plain/f"), b"x").is_err());
            assert_eq!(fs::read_dir(&outside).expect("list").count(), 0);
        }

        #[test]
        fn reading_refuses_a_link_at_any_step() {
            let tmp = tempfile::tempdir().expect("tmp");
            let outside = tmp.path().join("elsewhere");
            fs::create_dir(&outside).expect("outside");
            fs::write(outside.join("f"), "secret").expect("file");
            let base = tmp.path().join("base");
            fs::create_dir(&base).expect("base");
            fs::write(base.join("own"), "mine").expect("own");
            symlink(&outside, base.join("dir")).expect("link");
            symlink(outside.join("f"), base.join("file")).expect("link");
            assert_eq!(read_below(&base, Path::new("own")).expect("read"), "mine");
            assert!(read_below(&base, Path::new("dir/f")).is_err());
            assert!(read_below(&base, Path::new("file")).is_err());
            let missing = read_below(&base, Path::new("none")).expect_err("missing");
            assert_eq!(missing.kind(), io::ErrorKind::NotFound);
        }

        #[test]
        fn a_folder_as_the_temporary_file_is_an_error() {
            let tmp = tempfile::tempdir().expect("tmp");
            fs::create_dir(tmp.path().join("f.tmp")).expect("dir");
            assert!(write_below(tmp.path(), Path::new("f"), b"x").is_err());
        }
    }
}
