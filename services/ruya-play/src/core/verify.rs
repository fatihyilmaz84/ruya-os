//! Re-verification of an installed app (05 §7.3 "Re-verification", RUY-834): the deployed
//! `files/` folder held against the `play.files` the commit stored in it. It is the install-time
//! re-walk ([`unpack::walk`], [`unpack::check_tree`], [`unpack::rehash_with`]) over the deployment.
//!
//! What the console itself writes into `/app` is not in `play.files` and is left out of the
//! comparison: the root files ([`ROOT_FILES`]) and the reserved top-level names
//! ([`RESERVED_TOP_LEVEL`]: the launcher mount and `share/`, art and desktop entry; Flatpak's own
//! empty `.ref` too).
//!
//! Nothing here writes. The tree is read without following links (a link is compared as a link).

use crate::core::codes;
use crate::core::staging::{Dir, Found, Kind};
use crate::core::unpack::{self, staging_problem, Stop};
use ruya_play_format::limits::{MAX_TABLE_BYTES, ROOT_FILES};
use ruya_play_format::problem::{codes as format_codes, Problems};
use ruya_play_format::table::parse_table;
use ruya_play_format::table::RESERVED_TOP_LEVEL;
use ruya_play_format::{FileEntry, Problem};
use std::collections::BTreeMap;
use std::io::{self, Read};

/// How a verification ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// Every listed entry is there as listed and nothing else is.
    Match,
    /// What differs, first problem first. A `staging.io` code is an internal fault, the rest the
    /// payload no longer matching.
    Differs(Vec<Problem>),
    /// The caller's `tick` asked to stop.
    Stopped,
}

/// Progress of a pass: files hashed so far of all, and the bytes of all.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Tick {
    /// Files fully hashed.
    pub files_done: usize,
    /// Files in the table.
    pub files_total: usize,
    /// Bytes read so far.
    pub bytes_done: u64,
    /// Bytes of all listed files.
    pub bytes_total: u64,
}

/// Flatpak's deploy writes an empty regular `.ref` at the top of `files/` (`flatpak run` locks
/// it); it is the only entry of Flatpak's own that is left out. A non-empty or nested one is
/// compared like any other entry.
fn flatpak_ref(path: &str, f: &Found) -> bool {
    path == ".ref" && f.kind == Kind::File && f.size == 0
}

fn console_written(path: &str, f: &Found) -> bool {
    let top = path.split('/').next().unwrap_or("");
    // `.ref` is in the format's list too, but only Flatpak's own empty file is left out (below):
    // a `.ref` that is not that is compared like any other entry.
    (top != ".ref" && RESERVED_TOP_LEVEL.contains(&top))
        || ROOT_FILES.contains(&path)
        || flatpak_ref(path, f)
}

fn read_table(files: &Dir) -> Result<Vec<FileEntry>, Problem> {
    let missing = |what: &str| Problem::new(codes::STAGING_CHANGED, "play.files", what);
    let mut file = files.open_file("play.files").map_err(|e| {
        if e.kind() == io::ErrorKind::NotFound {
            missing("The installed app has no play.files.")
        } else {
            staging_problem("play.files", &e)
        }
    })?;
    let mut bytes = Vec::new();
    file.by_ref()
        .take(MAX_TABLE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| staging_problem("play.files", &e))?;
    if bytes.len() as u64 > MAX_TABLE_BYTES {
        return Err(Problem::new(
            format_codes::TABLE_TOO_BIG,
            "play.files",
            "The stored play.files is larger than the format allows.",
        ));
    }
    let mut problems = Problems::new();
    let table = parse_table(&bytes, &mut problems);
    match problems.finish().into_iter().next() {
        Some(p) => Err(p),
        None => Ok(table),
    }
}

/// Hold the deployed `files/` folder against its own `play.files`. `tick` is called as files are
/// hashed and returns false to stop (the result is [`Verdict::Stopped`]).
pub fn verify_files(files: &Dir, tick: &mut dyn FnMut(Tick) -> bool) -> Verdict {
    let table = match read_table(files) {
        Ok(t) => t,
        Err(p) => return Verdict::Differs(vec![p]),
    };
    let found: BTreeMap<String, Found> = match unpack::walk(files) {
        Ok(f) => f
            .into_iter()
            .filter(|(p, f)| !console_written(p, f))
            .collect(),
        Err(e) => return Verdict::Differs(vec![staging_problem("", &e)]),
    };
    if let Err(p) = unpack::check_tree(&table, &found) {
        return Verdict::Differs(vec![p]);
    }
    let (mut files_total, mut bytes_total) = (0usize, 0u64);
    for e in &table {
        if let FileEntry::File { size, .. } = e {
            files_total += 1;
            bytes_total = bytes_total.saturating_add(*size);
        }
    }
    let mismatch = |path: &str| {
        Problem::new(
            format_codes::PACKAGE_HASH_MISMATCH,
            path,
            "The installed file is not the one play.files lists (its size or SHA-256 changed).",
        )
    };
    let mut step = |files_done: usize, bytes_done: u64| {
        tick(Tick {
            files_done,
            files_total,
            bytes_done,
            bytes_total,
        })
    };
    match unpack::rehash_with(files, &table, &mismatch, &mut step) {
        Ok(_) => Verdict::Match,
        Err(Stop::Package(p) | Stop::Staging(p)) => Verdict::Differs(vec![p]),
        Err(Stop::Cancelled) => Verdict::Stopped,
    }
}
