//! `play.files`: the file table (05 §4.2). Parsing, the per-line rules, and the rules that need the
//! whole table (sorting, links, parents).

use crate::limits::{MAX_LINK_HOPS, MAX_TABLE_ENTRIES, ROOT_FILES};
use crate::path::{check_case_collisions, check_path};
use crate::problem::{codes, Problems};
use serde::Deserialize;
use std::collections::{HashMap, HashSet};

/// One line of `play.files`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileEntry {
    /// A regular file: size, SHA-256 (lower-case hex) and the executable bit.
    File {
        /// Package path.
        path: String,
        /// Size in bytes.
        size: u64,
        /// SHA-256 as 64 lower-case hex digits.
        sha256: String,
        /// `x:1` in the table.
        executable: bool,
    },
    /// A symbolic link the importer creates; `to` is relative to the link's folder.
    Link {
        /// Package path of the link.
        path: String,
        /// Link target as written.
        to: String,
    },
    /// An empty directory the importer creates.
    Dir {
        /// Package path.
        path: String,
    },
}

impl FileEntry {
    /// The entry's package path.
    pub fn path(&self) -> &str {
        match self {
            FileEntry::File { path, .. }
            | FileEntry::Link { path, .. }
            | FileEntry::Dir { path } => path,
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Line {
    p: String,
    t: String,
    s: Option<u64>,
    h: Option<String>,
    x: Option<u8>,
    to: Option<String>,
}

fn parse_line(line: &str) -> Result<FileEntry, String> {
    let l: Line =
        serde_json::from_str(line).map_err(|e| format!("not a valid table line ({e})"))?;
    match l.t.as_str() {
        "f" => {
            if l.to.is_some() {
                return Err("a file has no \"to\"".into());
            }
            let size = l.s.ok_or("a file needs \"s\" (size in bytes)")?;
            let sha256 = l.h.ok_or("a file needs \"h\" (SHA-256 in hex)")?;
            if !is_sha256_hex(&sha256) {
                return Err("\"h\" must be 64 lower-case hex digits".into());
            }
            let executable = match l.x {
                None => false,
                Some(1) => true,
                Some(_) => return Err("\"x\" is 1 or absent".into()),
            };
            Ok(FileEntry::File {
                path: l.p,
                size,
                sha256,
                executable,
            })
        }
        "l" => {
            if l.s.is_some() || l.h.is_some() || l.x.is_some() {
                return Err("a link has only \"p\", \"t\" and \"to\"".into());
            }
            let to = l.to.ok_or("a link needs \"to\"")?;
            Ok(FileEntry::Link { path: l.p, to })
        }
        "d" => {
            if l.s.is_some() || l.h.is_some() || l.x.is_some() || l.to.is_some() {
                return Err("a directory has only \"p\" and \"t\"".into());
            }
            Ok(FileEntry::Dir { path: l.p })
        }
        other => Err(format!(
            "\"t\" is f, l or d, not {otherq}",
            otherq = crate::problem::quote(other)
        )),
    }
}

/// Parse `play.files`. Reports malformed lines, blank lines, ordering and the entry count; returns
/// the entries that did parse.
pub fn parse_table(bytes: &[u8], problems: &mut Problems) -> Vec<FileEntry> {
    let text = match std::str::from_utf8(bytes) {
        Ok(t) => t,
        Err(_) => {
            problems.add(
                codes::TABLE_NOT_UTF8,
                "play.files",
                "The file table is not valid UTF-8.",
            );
            return Vec::new();
        }
    };
    let body = text.strip_suffix('\n').unwrap_or(text);
    let mut entries: Vec<FileEntry> = Vec::new();
    if body.is_empty() {
        return entries;
    }
    for (i, line) in body.split('\n').enumerate() {
        let at = format!("play.files:{}", i + 1);
        if i >= MAX_TABLE_ENTRIES {
            problems.add(
                codes::TABLE_TOO_MANY,
                "play.files",
                format!("The file table has more than {MAX_TABLE_ENTRIES} entries."),
            );
            return entries;
        }
        if line.is_empty() {
            problems.add(
                codes::TABLE_BLANK_LINE,
                at,
                "The file table has a blank line.",
            );
            continue;
        }
        if line.contains('\r') {
            problems.add(
                codes::TABLE_LINE_INVALID,
                at,
                "Lines end with LF only, not CR LF.",
            );
            continue;
        }
        match parse_line(line) {
            Ok(e) => {
                if let Some(prev) = entries.last() {
                    use std::cmp::Ordering;
                    match prev.path().as_bytes().cmp(e.path().as_bytes()) {
                        Ordering::Equal => problems.add(
                            codes::TABLE_DUPLICATE,
                            e.path(),
                            "The path is listed twice.",
                        ),
                        Ordering::Greater => problems.add(
                            codes::TABLE_NOT_SORTED,
                            e.path(),
                            format!(
                                "The table must be sorted by path (bytewise); {} comes after {}.",
                                crate::problem::quote(e.path()),
                                crate::problem::quote(prev.path())
                            ),
                        ),
                        Ordering::Less => {}
                    }
                }
                entries.push(e);
            }
            Err(msg) => problems.add(codes::TABLE_LINE_INVALID, at, msg),
        }
    }
    entries
}

/// True when `s` is exactly `len` lower-case hex digits (upper case is refused). The one check of
/// that form: [`is_sha256_hex`] and the trust crate's key ids are built on it.
pub fn is_lower_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// True when `h` is a SHA-256 as the table writes it: 64 lower-case hex digits (the table, a
/// runner hash, the launcher's records, the trust statements).
pub fn is_sha256_hex(h: &str) -> bool {
    is_lower_hex(h, 64)
}

/// A lookup over the table: entries by path, and the folders that exist because something is in them.
pub struct TableIndex<'a> {
    entries: HashMap<&'a str, &'a FileEntry>,
    implicit_dirs: HashSet<&'a str>,
}

impl<'a> TableIndex<'a> {
    /// Index `entries`.
    pub fn new(entries: &'a [FileEntry]) -> Self {
        let mut map = HashMap::with_capacity(entries.len());
        let mut dirs = HashSet::new();
        for e in entries {
            let p = e.path();
            map.insert(p, e);
            for (i, b) in p.bytes().enumerate() {
                if b == b'/' {
                    dirs.insert(&p[..i]);
                }
            }
        }
        TableIndex {
            entries: map,
            implicit_dirs: dirs,
        }
    }

    /// The entry at `path`.
    pub fn get(&self, path: &str) -> Option<&'a FileEntry> {
        self.entries.get(path).copied()
    }

    /// True when `path` is a listed directory or holds something listed.
    pub fn is_dir(&self, path: &str) -> bool {
        matches!(self.get(path), Some(FileEntry::Dir { .. })) || self.implicit_dirs.contains(path)
    }

    /// True when the table lists a regular file at `path`.
    pub fn is_file(&self, path: &str) -> bool {
        matches!(self.get(path), Some(FileEntry::File { .. }))
    }

    /// True when `path` or something below it is listed.
    pub fn exists(&self, path: &str) -> bool {
        self.entries.contains_key(path) || self.implicit_dirs.contains(path)
    }

    /// Every path that is a folder: listed or implied.
    pub fn dirs(&self) -> impl Iterator<Item = &str> + '_ {
        self.implicit_dirs.iter().copied()
    }
}

/// The top-level names a package may not use, the folder itself or anything below it: the
/// console writes them into the installed app. `.ref` is Flatpak's own empty file in every
/// deployment (`flatpak run` locks it, RUY-848); `launcher` and `runners` are the mounts of the
/// launcher and the system runners (ADR-038, RUY-900) and `share` holds the console's art and
/// desktop entry (05 section 4.2). A nested `a/.ref` or `a/share` is an ordinary name. The 32-bit
/// mount of a Windows runner is not top-level: see [`crate::limits::I386_LIB_DIR`].
pub const RESERVED_TOP_LEVEL: &[&str] = &[".ref", "launcher", "runners", "share"];

/// The reserved top-level name `path` is, or is below.
pub fn reserved_top_level(path: &str) -> Option<&'static str> {
    let top = path.split('/').next()?;
    RESERVED_TOP_LEVEL.iter().copied().find(|r| *r == top)
}

/// Apply the per-path and whole-table rules to `entries` (already in table order).
pub fn check_table(entries: &[FileEntry], problems: &mut Problems) {
    for e in entries {
        let p = e.path();
        if let Err((code, msg)) = check_path(p) {
            problems.add(code, p, msg);
        } else if ROOT_FILES.contains(&p) {
            problems.add(
                codes::TABLE_RESERVED_PATH,
                p,
                "play.json, play.files, play.sig and store.sig are not listed in the table.",
            );
        } else if let Some(name) = reserved_top_level(p) {
            problems.add(
                codes::TABLE_RESERVED_TOP_LEVEL,
                p,
                format!("A top-level {name} is the console's own: move the contents below another folder."),
            );
        }
    }
    check_case_collisions(entries.iter().map(|e| e.path()), problems);

    let index = TableIndex::new(entries);
    for e in entries {
        let p = e.path();
        for (i, b) in p.bytes().enumerate() {
            if b != b'/' {
                continue;
            }
            match index.get(&p[..i]) {
                Some(FileEntry::Dir { .. }) | None => {}
                Some(FileEntry::Link { .. }) => problems.add(
                    codes::LINK_AS_PARENT,
                    p,
                    format!(
                        "{} is a link, so nothing can be stored below it.",
                        crate::problem::quote(&p[..i])
                    ),
                ),
                Some(FileEntry::File { .. }) => problems.add(
                    codes::TABLE_PARENT_NOT_DIR,
                    p,
                    format!(
                        "{} is a file, so nothing can be stored below it.",
                        crate::problem::quote(&p[..i])
                    ),
                ),
            }
        }
    }
    for e in entries {
        if let FileEntry::Link { path, to } = e {
            check_link(path, to, &index, problems);
        }
    }
}

enum Resolved {
    To(String),
    Fault(&'static str, String),
}

fn resolve_link(path: &str, to: &str) -> Resolved {
    use Resolved::{Fault, To};
    let bytes = to.as_bytes();
    if to.starts_with('/')
        || (bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':')
    {
        return Fault(
            codes::LINK_ABSOLUTE,
            format!(
                "The link target {toq} is absolute; targets are relative to the link.",
                toq = crate::problem::quote(to)
            ),
        );
    }
    if to.is_empty()
        || to.contains('\\')
        || to.contains(':')
        || to.chars().any(char::is_control)
        || to.len() > crate::limits::MAX_PATH_BYTES
    {
        return Fault(
            codes::LINK_TARGET_INVALID,
            format!(
                "The link target {toq} is not a plain relative path.",
                toq = crate::problem::quote(to)
            ),
        );
    }
    let mut comps: Vec<&str> = path.split('/').collect();
    comps.pop();
    if comps.is_empty() {
        return Fault(
            codes::LINK_AT_ROOT,
            "A link must be inside a top-level folder, not at the package root.".to_string(),
        );
    }
    for part in to.split('/') {
        match part {
            "" => {
                return Fault(
                    codes::LINK_TARGET_INVALID,
                    format!(
                        "The link target {toq} has an empty part.",
                        toq = crate::problem::quote(to)
                    ),
                )
            }
            "." => {}
            ".." => {
                if comps.pop().is_none() {
                    return Fault(
                        codes::LINK_ESCAPES_TREE,
                        format!(
                            "The link target {toq} goes above the package root.",
                            toq = crate::problem::quote(to)
                        ),
                    );
                }
            }
            other => comps.push(other),
        }
    }
    let top = path.split('/').next().unwrap_or("");
    if comps.first().copied() != Some(top) {
        return Fault(
            codes::LINK_LEAVES_TOP_DIR,
            format!(
                "The link target {toq} leaves the top-level folder {topq}; links stay inside it.",
                toq = crate::problem::quote(to),
                topq = crate::problem::quote(top)
            ),
        );
    }
    To(comps.join("/"))
}

fn check_link(path: &str, to: &str, index: &TableIndex<'_>, problems: &mut Problems) {
    let mut target = match resolve_link(path, to) {
        Resolved::To(t) => t,
        Resolved::Fault(code, msg) => {
            problems.add(code, path, msg);
            return;
        }
    };
    let mut hops = 1;
    let mut visited: HashSet<String> = HashSet::new();
    visited.insert(path.to_string());
    loop {
        match index.get(&target) {
            Some(FileEntry::Link {
                path: next_path,
                to: next_to,
            }) => {
                if !visited.insert(next_path.clone()) {
                    problems.add(codes::LINK_LOOP, path, "The link leads back to itself.");
                    return;
                }
                hops += 1;
                if hops > MAX_LINK_HOPS {
                    problems.add(
                        codes::LINK_CHAIN_TOO_LONG,
                        path,
                        format!("The link passes through more than {MAX_LINK_HOPS} other links; point it at the final target."),
                    );
                    return;
                }
                target = match resolve_link(next_path, next_to) {
                    Resolved::To(t) => t,
                    // The next link is reported on its own line.
                    Resolved::Fault(..) => return,
                };
            }
            Some(_) => return,
            None => {
                if !index.exists(&target) {
                    problems.add(
                        codes::LINK_DANGLING,
                        path,
                        format!(
                            "The link target {targetq} is not in the package.",
                            targetq = crate::problem::quote(&target)
                        ),
                    );
                }
                return;
            }
        }
    }
}
