//! Every disk and process effect of the launcher, behind one trait: [`LaunchOs`]. The real one is
//! `linux::LinuxOs` (Linux only); [`crate::fake::FakeOs`] is an in-memory tree for the tests.
//!
//! Paths are `/`-separated text, the sandbox's view (`/app/...`, `$XDG_DATA_HOME/...`), so the
//! pure core behaves the same on every host. Methods that write take a trusted `base` (the data
//! folder, `/app`) and a `rel` below it: no folder of `rel` may be a link, so a link planted in
//! the player's data is never followed ([`NotFollowed`]).

use ruya_play_format::problem::{codes, Problem};
use ruya_play_format::Source;
use std::collections::BTreeMap;
use std::io::{self, Read};
use std::time::Duration;

/// What a path is, read without following a link at its end (ruya-fs's).
pub use ruya_fs::Kind;

/// A program to start: the whole argv, the whole environment and the working folder. No shell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    /// Program and arguments.
    pub argv: Vec<String>,
    /// The complete environment (the child gets exactly this).
    pub env: BTreeMap<String, String>,
    /// Working folder.
    pub cwd: String,
}

/// How a program run with a timeout ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Exit {
    /// It exited with this code.
    Code(i32),
    /// A signal ended it.
    Signal(i32),
    /// It ran out of time and was killed with its process group.
    TimedOut,
}

/// The error of a call that met a link where a folder should be (ruya-fs owns it, RUY-911): the
/// link is not followed, and the caller decides whether that is fatal. Also the path of a folder
/// that is a file ([`not_a_folder`]).
pub use ruya_fs::{not_a_folder, NotFollowed};

/// The deepest folder level a copy goes (a prefix template, a save); deeper is refused.
pub const MAX_COPY_DEPTH: usize = 64;

/// The error of a copy whose tree is deeper than [`MAX_COPY_DEPTH`].
pub fn too_deep(path: &str) -> io::Error {
    ruya_fs::too_deep(path, MAX_COPY_DEPTH)
}

/// The launcher's effects. Reads take `&self`, writes and runs `&mut self`.
pub trait LaunchOs {
    /// What `base/rel` is, without following a link at its end. `Ok(None)` only when nothing is
    /// there (`NotFound`, a missing folder above it included). A link among the folders of `rel`
    /// is [`NotFollowed`] and any other failure (`EACCES`, `EIO`) is its own error: neither means
    /// "missing", so a caller never treats an error as an absent file, it fails or says why it
    /// goes on.
    fn kind(&self, base: &str, rel: &str) -> io::Result<Option<Kind>>;
    /// The names and kinds in the folder `base/rel` (links not followed; a link among the folders
    /// of `rel` is [`NotFollowed`]). A name that is not UTF-8 is left out.
    fn list(&self, base: &str, rel: &str) -> io::Result<Vec<(String, Kind)>>;
    /// Open the regular file `base/rel`; a link at its end or among its folders below `base` is
    /// refused ([`NotFollowed`]), like a write.
    fn open(&self, base: &str, rel: &str) -> io::Result<Box<dyn Read + '_>>;
    /// Create the folders of `rel` below `base` that are missing.
    fn make_dirs(&mut self, base: &str, rel: &str) -> io::Result<()>;
    /// Copy `src_base/src_rel` (a file, a folder with everything in it, or a link) to
    /// `dst_base/dst_rel`, replacing what is there. Links inside are copied as links, never
    /// followed; a link among the folders of either `rel` is [`NotFollowed`]. `Ok(false)` when
    /// nothing is at the source.
    fn copy(
        &mut self,
        src_base: &str,
        src_rel: &str,
        dst_base: &str,
        dst_rel: &str,
    ) -> io::Result<bool>;
    /// Create the folders above `base/rel` that are missing ([`Self::make_dirs`]); the full path.
    fn make_parent(&mut self, base: &str, rel: &str) -> io::Result<String> {
        self.make_dirs(base, rel.rsplit_once('/').map_or("", |(p, _)| p))?;
        Ok(join(base, rel))
    }
    /// Remove `base/rel` and everything in it (a link is removed, not followed).
    fn remove(&mut self, base: &str, rel: &str) -> io::Result<()>;
    /// Make `base/rel` a link to `target`.
    fn symlink(&mut self, target: &str, base: &str, rel: &str) -> io::Result<()>;
    /// Write `base/rel` atomically: a temporary file next to it, flushed, then renamed.
    fn write_atomic(&mut self, base: &str, rel: &str, bytes: &[u8]) -> io::Result<()>;
    /// Run `cmds` one after the other while each exits 0, all of them within `timeout`; returns
    /// how the last one run ended and how long they took. Each runs in its own process group; on
    /// the timeout every group started is killed.
    fn run(&mut self, cmds: &[Command], timeout: Duration) -> io::Result<(Exit, Duration)>;
    /// One line for the journal (stderr).
    fn log(&self, line: &str);
}

/// `base/rel`, with one `/` between them.
pub fn join(base: &str, rel: &str) -> String {
    let base = base.trim_end_matches('/');
    let rel = rel.trim_start_matches('/');
    if rel.is_empty() {
        base.to_string()
    } else {
        format!("{base}/{rel}")
    }
}

/// The `/app` tree as a package [`Source`] for the format crate's readers
/// (`ruya_play_format::read_small`, `runner::bundled_runners`): it opens named files only.
pub struct AppSource<'a> {
    os: &'a dyn LaunchOs,
    root: &'a str,
}

impl<'a> AppSource<'a> {
    /// The tree at `root` (`/app`) read through `os`.
    pub fn new(os: &'a dyn LaunchOs, root: &'a str) -> Self {
        AppSource { os, root }
    }
}

impl Source for AppSource<'_> {
    fn entries(&self) -> Result<Vec<ruya_play_format::Entry>, Vec<Problem>> {
        // The launcher never lists /app: it holds OS folders next to the package, and listing a
        // game's tree at every launch would cost seconds (RUY-901). Only named files are read.
        Err(vec![Problem::new(
            codes::FOLDER_UNREADABLE,
            "",
            "The launcher reads named files only.",
        )])
    }

    fn open(&self, path: &str) -> io::Result<Box<dyn Read + '_>> {
        self.os.open(self.root, path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn join_puts_one_slash() {
        assert_eq!(join("/d/", "/x/y"), "/d/x/y");
        assert_eq!(join("/d", ""), "/d");
        assert_eq!(join("/app", "play.json"), "/app/play.json");
    }
}
