//! The unpacker and the re-walk (05 §7.3 steps 4 and 5, §9.1).
//!
//! [`unpack`] writes the table's entries in table order into a staging folder through [`Dir`]
//! handles: every file is created exclusively with mode 0644 or 0755 (from `x:1`), streamed from
//! the source once while hashing, and must have exactly its listed size and SHA-256; folders are
//! 0755; links are created from the table only (the package never holds a real one). [`walk`]
//! then reads the staged tree back without following links and [`check_tree`] holds it against
//! the table: kinds, sizes, modes and link targets, and nothing else. [`runner_hashes`] gives the
//! revocation check its `runner` hashes of the bundled components.

use crate::core::codes;
use crate::core::deps::Step;
use crate::core::staging::{self, is_changed, is_no_space, Dir, Found, Kind};
use ruya_play_format::manifest::Manifest;
use ruya_play_format::runner::{runner_hash, RunnerEntry};
use ruya_play_format::table::TableIndex;
use ruya_play_format::{sha256_of_chunks, FileEntry, Problem, ReadFault, Source};
use std::collections::{BTreeMap, HashMap};
use std::io::{self, Write};

/// Mode of a plain file.
pub const FILE_MODE: u32 = 0o644;
/// Mode of a file listed with `x:1`, and of every folder.
pub const EXEC_MODE: u32 = 0o755;
/// Bytes read and written at a time.
pub const CHUNK: usize = 256 * 1024;

/// Why the unpacker stopped.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Stop {
    /// The package's fault (a hash, a size, a zip read fault): the format's code.
    Package(Problem),
    /// Staging failed: `space.not_enough`, `staging.changed` or `staging.io`.
    Staging(Problem),
    /// A cancel arrived.
    Cancelled,
}

/// What the unpacker reports to and asks of the job.
pub trait Control {
    /// True once the job is cancelled.
    fn cancelled(&self) -> bool;
    /// `done` payload bytes are written.
    fn progress(&mut self, done: u64);
    /// A step for the hooks.
    fn step(&mut self, step: &Step<'_>);
}

/// What the unpacker wrote.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Unpacked {
    /// SHA-256 of every file as it was written into staging, by package path.
    pub hashes: HashMap<String, String>,
    /// Payload bytes written.
    pub bytes: u64,
}

/// A staging failure as a problem: out of space, a changed tree, or plain I/O.
pub fn staging_problem(path: &str, e: &io::Error) -> Problem {
    if is_no_space(e) {
        Problem::new(
            codes::SPACE_NOT_ENOUGH,
            path,
            "The staging disk ran out of space while the package was copied.",
        )
    } else if is_changed(e) {
        Problem::new(codes::STAGING_CHANGED, path, e.to_string())
    } else {
        Problem::new(
            codes::STAGING_IO,
            path,
            format!("Writing into the staging folder failed ({e})."),
        )
    }
}

/// A read failure of the source, as the format crate reports it.
fn read_problem(path: &str, e: &io::Error) -> Problem {
    match ReadFault::from_io(e) {
        Some(p) => p.clone(),
        None => Problem::new(
            ruya_play_format::codes::PACKAGE_READ_FAILED,
            path,
            format!("The file could not be read ({e})."),
        ),
    }
}

/// Resolve `to` against the folder of the link at `path`, lexically (the format checked it stays
/// inside its top-level folder).
fn resolve(path: &str, to: &str) -> Option<String> {
    let mut parts: Vec<&str> = path.split('/').collect();
    parts.pop();
    for p in to.split('/') {
        match p {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            other => parts.push(other),
        }
    }
    Some(parts.join("/"))
}

/// True when the link at `path` ends at a folder (Windows makes folder links differently).
fn ends_at_dir(index: &TableIndex<'_>, path: &str, to: &str) -> bool {
    let (mut at, mut target) = (path.to_string(), to.to_string());
    for _ in 0..=ruya_play_format::limits::MAX_LINK_HOPS {
        let Some(next) = resolve(&at, &target) else {
            return false;
        };
        match index.get(&next) {
            Some(FileEntry::Link { to, .. }) => {
                at = next;
                target = to.clone();
            }
            _ => return index.is_dir(&next),
        }
    }
    false
}

/// The open folders of the current path, below the tree root.
struct DirStack<'a> {
    root: &'a Dir,
    open: Vec<(String, Dir)>,
    /// Create a missing folder on the way (the unpacker), or fail (the re-hash).
    create: bool,
}

impl<'a> DirStack<'a> {
    /// The folder that holds `path`'s last component, created on the way when absent.
    fn parent_of<'p>(&mut self, path: &'p str) -> Result<(&Dir, &'p str), Problem> {
        let mut comps: Vec<&str> = path.split('/').collect();
        let leaf = comps.pop().unwrap_or("");
        let keep = self
            .open
            .iter()
            .zip(&comps)
            .take_while(|((name, _), c)| name == *c)
            .count();
        self.open.truncate(keep);
        for c in &comps[keep..] {
            let next = {
                let parent = self.open.last().map_or(self.root, |(_, d)| d);
                let opened = if self.create {
                    parent.dir(c, EXEC_MODE)
                } else {
                    parent.open_dir(c)
                };
                opened.map_err(|e| staging_problem(path, &e))?
            };
            self.open.push((c.to_string(), next));
        }
        let dir = self.open.last().map_or(self.root, |(_, d)| d);
        Ok((dir, leaf))
    }
}

/// Write `files` (in table order) from `source` into `tree`.
pub fn unpack(
    source: &dyn Source,
    files: &[FileEntry],
    tree: &Dir,
    ctl: &mut dyn Control,
) -> Result<Unpacked, Stop> {
    let index = TableIndex::new(files);
    let mut stack = DirStack {
        root: tree,
        open: Vec::new(),
        create: true,
    };
    let mut out = Unpacked::default();
    for entry in files {
        if ctl.cancelled() {
            return Err(Stop::Cancelled);
        }
        let path = entry.path();
        let (dir, leaf) = stack.parent_of(path).map_err(Stop::Staging)?;
        match entry {
            FileEntry::Dir { .. } => {
                dir.dir(leaf, EXEC_MODE)
                    .map_err(|e| Stop::Staging(staging_problem(path, &e)))?;
            }
            FileEntry::Link { to, .. } => {
                dir.symlink(leaf, to, ends_at_dir(&index, path, to))
                    .map_err(|e| Stop::Staging(staging_problem(path, &e)))?;
            }
            FileEntry::File {
                size,
                sha256,
                executable,
                ..
            } => {
                let mode = if *executable { EXEC_MODE } else { FILE_MODE };
                let mut file = dir
                    .create_file(leaf, mode)
                    .map_err(|e| Stop::Staging(staging_problem(path, &e)))?;
                let mut input = source
                    .open(path)
                    .map_err(|e| Stop::Package(read_problem(path, &e)))?;
                // A write failure or a cancel inside the chunk callback stops the read; `stopped`
                // keeps which, so a read error of the source stays a package fault.
                let (mut stopped, mut total) = (None, 0u64);
                let hashed = sha256_of_chunks(&mut input, *size, &mut |chunk| {
                    total += chunk.len() as u64;
                    if let Err(e) = file.write_all(chunk) {
                        stopped = Some(Stop::Staging(staging_problem(path, &e)));
                    } else {
                        out.bytes += chunk.len() as u64;
                        ctl.progress(out.bytes);
                        ctl.step(&Step::Chunk { path, done: total });
                        if ctl.cancelled() {
                            stopped = Some(Stop::Cancelled);
                        }
                    }
                    match stopped {
                        None => Ok(()),
                        Some(_) => Err(io::Error::other("stopped")),
                    }
                });
                if let Some(stop) = stopped {
                    return Err(stop);
                }
                let Some((got, _)) = hashed.map_err(|e| Stop::Package(read_problem(path, &e)))?
                else {
                    return Err(Stop::Package(Problem::new(
                        ruya_play_format::codes::PACKAGE_SIZE_MISMATCH,
                        path,
                        format!("play.files says {size} bytes; the content has more."),
                    )));
                };
                if total != *size {
                    return Err(Stop::Package(Problem::new(
                        ruya_play_format::codes::PACKAGE_SIZE_MISMATCH,
                        path,
                        format!("play.files says {size} bytes; the content has {total}."),
                    )));
                }
                if got != *sha256 {
                    return Err(Stop::Package(Problem::new(
                        ruya_play_format::codes::PACKAGE_HASH_MISMATCH,
                        path,
                        "The content does not match its SHA-256 in play.files.",
                    )));
                }
                file.flush()
                    .map_err(|e| Stop::Staging(staging_problem(path, &e)))?;
                out.hashes.insert(path.to_string(), got);
            }
        }
        ctl.step(&Step::Written { path });
    }
    Ok(out)
}

/// Every entry below `tree`, by package path, read without following links. Folders are opened
/// from their parent's handle; at most one handle per folder on the current path stays open.
pub fn walk(tree: &Dir) -> io::Result<BTreeMap<String, Found>> {
    use std::rc::Rc;
    let mut out = BTreeMap::new();
    let root = Rc::new(tree.try_clone()?);
    let mut pending: Vec<(String, Rc<Dir>, Option<String>)> = vec![(String::new(), root, None)];
    while let Some((prefix, parent, name)) = pending.pop() {
        let dir = match name {
            None => parent,
            Some(n) => Rc::new(parent.open_dir(&n)?),
        };
        for f in dir.entries()? {
            let path = format!("{prefix}{}", f.name);
            if f.kind == Kind::Dir {
                pending.push((format!("{path}/"), Rc::clone(&dir), Some(f.name.clone())));
            }
            out.insert(path, f);
        }
    }
    Ok(out)
}

fn changed(path: &str, what: impl Into<String>) -> Problem {
    Problem::new(codes::STAGING_CHANGED, path, what.into())
}

/// What [`check_tree`] holds a file's content to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Compare {
    /// Kind, mode (Unix) and link target only: a file's content is left to [`rehash_with`], which
    /// names a changed size or hash `package.hash_mismatch` (re-verification, 05 §7.3).
    Structure,
    /// Structure and each file's size: the staging guard right after an unpack, where a size that
    /// differs from the table is `staging.changed`.
    StructureAndSize,
}

/// Hold the walked tree against the table: every entry there with its kind, mode (Unix), link
/// target and, with [`Compare::StructureAndSize`], size, and nothing that is not listed or a folder
/// that holds something listed.
pub fn check_tree(
    files: &[FileEntry],
    found: &BTreeMap<String, Found>,
    compare: Compare,
) -> Result<(), Problem> {
    let index = TableIndex::new(files);
    let modes = cfg!(unix);
    for entry in files {
        let p = entry.path();
        let Some(f) = found.get(p) else {
            return Err(changed(
                p,
                "A listed entry is missing from the staged tree.",
            ));
        };
        let ok = match entry {
            FileEntry::File {
                size, executable, ..
            } => {
                let mode = if *executable { EXEC_MODE } else { FILE_MODE };
                f.kind == Kind::File
                    && (compare == Compare::Structure || f.size == *size)
                    && (!modes || f.mode == mode)
            }
            FileEntry::Dir { .. } => f.kind == Kind::Dir && (!modes || f.mode == EXEC_MODE),
            FileEntry::Link { to, .. } => f.kind == Kind::Link && f.target.as_deref() == Some(to),
        };
        if !ok {
            return Err(changed(
                p,
                format!(
                    "The staged entry is not what play.files lists (found {:?}, mode {:o}).",
                    f.kind, f.mode
                ),
            ));
        }
    }
    for (p, f) in found {
        if index.get(p).is_some() {
            continue;
        }
        let implied = f.kind == Kind::Dir && index.is_dir(p) && (!modes || f.mode == EXEC_MODE);
        if !implied {
            return Err(changed(
                p,
                "The staged tree holds an entry play.files does not list.",
            ));
        }
    }
    Ok(())
}

/// The `runner` hash of each bundled component (05 §7.3), computed from the staged copy with the
/// format's one formula ([`runner_hash`]): every table entry below the component's `bundled.path`,
/// in table order, with its path relative to that folder; a file with its hash as it was written
/// into staging, a link and an empty folder as the re-walk confirmed. T-239's runner resolution
/// reports the same value for a bundled runner.
pub fn runner_hashes(manifest: &Manifest, files: &[FileEntry], unpacked: &Unpacked) -> Vec<String> {
    let mut out = Vec::new();
    for c in &manifest.components {
        let Some(bundled) = &c.bundled else {
            continue;
        };
        let prefix = format!("{}/", bundled.path.trim_end_matches('/'));
        out.push(runner_hash(files.iter().filter_map(|e| {
            let entry = RunnerEntry::from(e).with_rel(e.path().strip_prefix(&prefix)?);
            Some(match e {
                // `rehash` hashed every file of the table it was given, and the caller passes
                // that same table: a file without a staged hash is a bug, never an empty hash.
                FileEntry::File { path, .. } => entry.with_sha256(
                    unpacked
                        .hashes
                        .get(path)
                        .expect("rehash hashed every file of the table"),
                ),
                _ => entry,
            })
        })));
    }
    out
}

/// The service's own pass over a tree the helper wrote (05 §7.3, lead-33): every file of the table
/// is opened through folder handles (a link or a special file on the way is `staging.changed`),
/// read once and must have its listed size and SHA-256, or the tree changed after the helper
/// verified it (`staging.changed`). The hashes it returns are the staged copy's, for
/// [`runner_hashes`]. Run it after [`walk`] and [`check_tree`].
pub fn rehash(tree: &Dir, files: &[FileEntry]) -> Result<Unpacked, Problem> {
    let mismatch = |path: &str| {
        changed(
            path,
            "The staged file is not the one play.files lists (its size or SHA-256 changed).",
        )
    };
    match rehash_with(tree, files, &mismatch, &mut |_, _| true) {
        Ok(u) => Ok(u),
        Err(Stop::Package(p) | Stop::Staging(p)) => Err(p),
        Err(Stop::Cancelled) => Err(changed("", "The re-hash was stopped.")),
    }
}

/// [`rehash`] with its own word for a file whose size or hash differs (`mismatch`, a
/// `Stop::Package`) and a `tick(files done, bytes read of this file and before)` after every chunk
/// and file that stops the pass (`Stop::Cancelled`) when it returns false. Re-verification of an
/// installed app (RUY-834) uses it over the deployed tree.
pub fn rehash_with(
    tree: &Dir,
    files: &[FileEntry],
    mismatch: &dyn Fn(&str) -> Problem,
    tick: &mut dyn FnMut(usize, u64) -> bool,
) -> Result<Unpacked, Stop> {
    let mut stack = DirStack {
        root: tree,
        open: Vec::new(),
        create: false,
    };
    let mut out = Unpacked::default();
    let mut done = 0usize;
    for entry in files {
        let FileEntry::File {
            path, size, sha256, ..
        } = entry
        else {
            continue;
        };
        let (dir, leaf) = stack.parent_of(path).map_err(Stop::Staging)?;
        let mut file = dir.open_file(leaf).map_err(|e| {
            if e.kind() == io::ErrorKind::NotFound {
                Stop::Staging(changed(
                    path,
                    "A listed file is missing from the staged tree.",
                ))
            } else {
                Stop::Staging(staging_problem(path, &e))
            }
        })?;
        let (mut cancelled, mut seen) = (false, 0u64);
        let hashed = sha256_of_chunks(&mut file, *size, &mut |chunk| {
            seen += chunk.len() as u64;
            cancelled = !tick(done, out.bytes + seen);
            if cancelled {
                Err(io::Error::other("cancelled"))
            } else {
                Ok(())
            }
        });
        if cancelled {
            return Err(Stop::Cancelled);
        }
        let hashed = hashed.map_err(|e| Stop::Staging(staging_problem(path, &e)))?;
        let Some((got, total)) = hashed.filter(|(got, total)| total == size && got == sha256)
        else {
            return Err(Stop::Package(mismatch(path)));
        };
        out.bytes += total;
        out.hashes.insert(path.clone(), got);
        done += 1;
        if !tick(done, out.bytes) {
            return Err(Stop::Cancelled);
        }
    }
    Ok(out)
}

/// `staging::join_checked`, as a problem.
pub fn staged_path(tree: &Dir, rel: &str) -> Result<std::path::PathBuf, Problem> {
    staging::join_checked(tree.path(), rel).map_err(|e| staging_problem(rel, &e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn links_resolve_lexically() {
        assert_eq!(resolve("a/b/l", "c").as_deref(), Some("a/b/c"));
        assert_eq!(resolve("a/b/l", "../c/d").as_deref(), Some("a/c/d"));
        assert_eq!(resolve("a/l", "../../x"), None);
    }

    #[test]
    fn a_link_chain_ends_at_a_folder_or_a_file() {
        let files = vec![
            FileEntry::Link {
                path: "c/l1".into(),
                to: "l2".into(),
            },
            FileEntry::Link {
                path: "c/l2".into(),
                to: "lib".into(),
            },
            FileEntry::File {
                path: "c/lib/x.so".into(),
                size: 0,
                sha256: String::new(),
                executable: false,
            },
            FileEntry::Link {
                path: "c/l3".into(),
                to: "lib/x.so".into(),
            },
        ];
        let index = TableIndex::new(&files);
        assert!(ends_at_dir(&index, "c/l1", "l2"));
        assert!(!ends_at_dir(&index, "c/l3", "lib/x.so"));
    }

    /// `runner_hashes` expects a staged hash for every file it hashes: `rehash` gives one for every
    /// file of the table, so a file without one cannot reach it.
    #[test]
    fn rehash_hashes_every_file_of_the_table() {
        let tmp = tempfile::tempdir().expect("a temp folder");
        std::fs::create_dir(tmp.path().join("c")).unwrap();
        std::fs::write(tmp.path().join("c/a"), b"abc").unwrap();
        std::fs::write(tmp.path().join("c/b"), b"").unwrap();
        let sha = |bytes: &[u8]| {
            ruya_play_format::sha256_of_chunks(&mut &bytes[..], bytes.len() as u64, &mut |_| Ok(()))
                .unwrap()
                .unwrap()
                .0
        };
        let files = vec![
            FileEntry::Dir { path: "c".into() },
            FileEntry::File {
                path: "c/a".into(),
                size: 3,
                sha256: sha(b"abc"),
                executable: false,
            },
            FileEntry::File {
                path: "c/b".into(),
                size: 0,
                sha256: sha(b""),
                executable: true,
            },
            FileEntry::Link {
                path: "c/l".into(),
                to: "a".into(),
            },
        ];
        let tree = Dir::open_root(tmp.path()).unwrap();
        let unpacked = rehash(&tree, &files).expect("rehash");
        let mut hashed: Vec<&str> = unpacked.hashes.keys().map(String::as_str).collect();
        hashed.sort_unstable();
        assert_eq!(hashed, ["c/a", "c/b"]);
        for f in &files {
            if let FileEntry::File { path, sha256, .. } = f {
                assert_eq!(&unpacked.hashes[path], sha256);
            }
        }
    }
}
