//! The game tree of `run.writable` (ADR-040, 05 §6.3): `${game}` = `${data}/.ruya-play/game/`, a
//! per-profile copy of `payload/` the game may write into where its package says so.
//!
//! * **Tree.** Every folder is a real folder. Outside the writable folders folders are 0500 and
//!   files are links to `/app/payload/<path>`, so a write there fails as it does under
//!   `${payload}`; inside them folders are 0700 and files are copies, 0700 when the table marks
//!   the file executable, else 0600. The file `run.command[0]` names is always a copy, so
//!   `/proc/self/exe` and `getcwd` stay in the tree. Copies are made with a reflink where the file
//!   system can (`ruya-fs`), into a staging file outside the tree that is renamed into place, so a
//!   file in the tree is always whole.
//! * **Record.** `${data}/.ruya-play/game-base.json` holds the `play.files` SHA-256 of every copy
//!   (known from the table: nothing is hashed when a copy is made), the status file the `build`
//!   the tree was made from (`game_build`). The game can write both: the base is read as
//!   untrusted ([`Base::parse`], with caps), and one that does not parse, or is of another build
//!   than the tree, counts as "every file changed", so player data is kept, never deleted.
//! * **Update.** When the tree is missing, `game_build` is not the package's `build`, or a rebuild
//!   was cut short (`game.new/` is there), the launcher builds `game.new/` from the table and sorts
//!   the old tree: a file whose hash equals its base hash is the old build's, removed; one the
//!   game changed or made is moved (`renameat`, never copied) to the same place in `game.new/`
//!   when that place is in a writable folder of the new build and free, else to
//!   `.ruya-play/game-kept/<old build>/` ([`Keeper`]: a kept file is never replaced, a taken name
//!   gets `~<n>`; only the newest set is kept, as with the epoch backups); a link the launcher
//!   made (to `/app/payload/<path>`) goes with the old tree, any other link is the game's and is
//!   moved like a changed file, as a link. Before anything moves, `game.new.json` records the
//!   build `game.new/` is for and its copies' hashes. Then the new tree is filled (whatever is not
//!   a link where a link or copy goes is kept aside first, never removed), its modes set, the base
//!   and the status file written and `game.new/` renamed into place. A rebuild of the same build
//!   cut short starts again from `game.new/`: the old tree's files are sorted once (a moved file is
//!   no longer there), and a file already in `game.new/` is the game's or a whole copy, so it is
//!   kept. A `game.new/` started for another build (an update arrived first) is sorted back into
//!   the old tree by its own record: its unchanged copies go, everything else returns to its path
//!   there (or is kept aside), and the rebuild starts fresh. The current files are hashed only
//!   during an update.
//!
//! Every step goes through [`LaunchOs`] (ruya-fs on Linux: no link is followed, links are kept as
//! links). An epoch rebuild of the prefix leaves the tree alone.

use crate::os::{join, Kind, LaunchOs, MAX_COPY_DEPTH};
use crate::state::{State, KEPT};
use crate::Failure;
use ruya_play_format::limits::{MAX_WRITABLE_BYTES, MAX_WRITABLE_FILES};
use ruya_play_format::manifest::Manifest;
use ruya_play_format::path::check_path;
use ruya_play_format::table::{is_sha256_hex, FileEntry, TableIndex};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::io;

/// `${game}`, below `${data}`.
pub const TREE: &str = ".ruya-play/game";
/// The tree being built, below `${data}`; renamed to [`TREE`] when it is complete.
pub const NEW: &str = ".ruya-play/game.new";
/// Where each copy is made before it is renamed into [`NEW`], below `${data}`.
pub const STAGE: &str = ".ruya-play/game.tmp";
/// The record of the copies, below `${data}`.
pub const BASE: &str = ".ruya-play/game-base.json";
/// The record of the tree being built ([`NEW`]): written before anything moves into it, so a
/// rebuild cut short knows which build `game.new/` was started for and what its copies are.
pub const NEW_BASE: &str = ".ruya-play/game.new.json";
/// The format of [`BASE`] this launcher writes and reads.
pub const BASE_FORMAT: u64 = 1;
/// The most entries [`BASE`] holds (ADR-040): one per copy, and a package has at most this many.
pub const MAX_BASE_ENTRIES: usize = MAX_WRITABLE_FILES;
/// The largest [`BASE`] read (ADR-040).
pub const MAX_BASE_BYTES: u64 = 4 * 1024 * 1024;
/// The prefix of `run.command` and `run.cwd` that names the tree.
pub const PLACEHOLDER: &str = "${game}";

/// A folder inside a writable folder.
const OPEN: u32 = 0o700;
/// A folder outside them.
const SHUT: u32 = 0o500;
/// A copied file.
const COPY: u32 = 0o600;
/// A copied file the table marks executable.
const PROGRAM: u32 = 0o700;

/// What `game-base.json` says: the build its tree was made from and the `play.files` SHA-256 of
/// each copy in it, by path below `${game}`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Base {
    /// The package `build` of the copies.
    pub build: u64,
    /// Path below `${game}` to SHA-256 (64 lower-case hex digits).
    pub files: BTreeMap<String, String>,
}

impl Base {
    /// Parse the file; `None` for anything that is not a base of [`BASE_FORMAT`] within the caps
    /// (at most [`MAX_BASE_BYTES`], [`MAX_BASE_ENTRIES`] entries, each a plain path and a hash).
    pub fn parse(bytes: &[u8]) -> Option<Base> {
        if bytes.len() as u64 > MAX_BASE_BYTES {
            return None;
        }
        let v: Value = serde_json::from_slice(bytes).ok()?;
        let o = v.as_object()?;
        if o.get("format")?.as_u64()? != BASE_FORMAT {
            return None;
        }
        let build = o.get("build")?.as_u64()?;
        let list = o.get("files")?.as_object()?;
        if list.len() > MAX_BASE_ENTRIES {
            return None;
        }
        let mut files = BTreeMap::new();
        for (path, hash) in list {
            let hash = hash.as_str()?;
            // A path as the table writes one (every copy is a table path), a hash as it does.
            if check_path(path).is_err() || !is_sha256_hex(hash) {
                return None;
            }
            files.insert(path.clone(), hash.to_string());
        }
        Some(Base { build, files })
    }

    /// The file's bytes (one JSON object and a newline).
    pub fn to_bytes(&self) -> Vec<u8> {
        let files: Map<String, Value> = self
            .files
            .iter()
            .map(|(p, h)| (p.clone(), Value::String(h.clone())))
            .collect();
        let mut o = Map::new();
        o.insert("format".into(), BASE_FORMAT.into());
        o.insert("build".into(), self.build.into());
        o.insert("files".into(), Value::Object(files));
        let mut out = Value::Object(o).to_string().into_bytes();
        out.push(b'\n');
        out
    }

    /// The base of `build` for `copies` (path, hash), in path order and within the caps the
    /// reader holds it to; the number of copies left out (they count as changed at the next
    /// update, so what the game wrote there is kept).
    fn of(build: u64, copies: &[(&str, &str)]) -> (Base, usize) {
        let mut base = Base {
            build,
            files: BTreeMap::new(),
        };
        // The fixed part with room to spare, then each entry as JSON writes it.
        let mut bytes = 64u64;
        let mut sorted: Vec<&(&str, &str)> = copies.iter().collect();
        sorted.sort();
        for (path, hash) in &sorted {
            let entry = serde_json::to_string(path).map_or(u64::MAX, |s| s.len() as u64) + 68;
            if base.files.len() == MAX_BASE_ENTRIES || bytes + entry > MAX_BASE_BYTES {
                break;
            }
            bytes += entry;
            base.files.insert(path.to_string(), hash.to_string());
        }
        let left = sorted.len() - base.files.len();
        (base, left)
    }

    /// The base at `rel` ([`BASE`] or [`NEW_BASE`]) below `data`; `None` when it is absent or
    /// cannot be read as one (logged).
    pub fn read(os: &dyn LaunchOs, data: &str, rel: &str) -> Option<Base> {
        match os.kind(data, rel) {
            Ok(None) => return None,
            Ok(Some(_)) => {}
            Err(e) => {
                os.log(&format!(
                    "the game folder's record cannot be checked ({e}); every file counts as changed"
                ));
                return None;
            }
        }
        let src = crate::os::AppSource::new(os, data);
        match ruya_play_format::read_within(&src, rel, MAX_BASE_BYTES) {
            Ok(Some(bytes)) => {
                let base = Base::parse(&bytes);
                if base.is_none() {
                    os.log("the game folder's record is not one this launcher reads; every file counts as changed");
                }
                base
            }
            Ok(None) => {
                os.log("the game folder's record is too big; every file counts as changed");
                None
            }
            // ADR-040: a base that is missing, unreadable or damaged keeps the game's data, so
            // an I/O error here (unlike for the status file) only means "every file changed".
            Err(e) => {
                os.log(&format!(
                    "the game folder's record cannot be read ({}); every file counts as changed",
                    e.into_problem(rel).message
                ));
                None
            }
        }
    }
}

/// `rel/name`, or `name` at the top.
fn below(rel: &str, name: &str) -> String {
    if rel.is_empty() {
        name.to_string()
    } else {
        format!("{rel}/{name}")
    }
}

/// Every folder above `rel` (`a`, `a/b` for `a/b/c`).
fn parents(rel: &str) -> impl Iterator<Item = &str> {
    rel.match_indices('/').map(move |(i, _)| &rel[..i])
}

/// What the new build's tree is made of, from the manifest and the table.
struct Layout<'a> {
    /// `/app`.
    app: &'a str,
    /// `run.writable`, below `payload/`.
    writable: &'a [String],
    /// The file `run.command[0]` names, below `payload/`.
    entry: Option<&'a str>,
    /// The table entries below `payload/`, by their path there, in table order.
    items: Vec<(&'a str, &'a FileEntry)>,
    index: TableIndex<'a>,
    /// Every folder of the tree (the root aside): the table's, the ones its paths imply, the
    /// writable folders and the working folder, with every folder above them.
    folders: BTreeSet<String>,
}

impl<'a> Layout<'a> {
    fn new(app: &'a str, m: &'a Manifest, files: &'a [FileEntry]) -> Layout<'a> {
        let items: Vec<(&str, &FileEntry)> = files
            .iter()
            .filter_map(|e| Some((e.path().strip_prefix("payload/")?, e)))
            .collect();
        let tree_path = |s: &'a str| {
            s.strip_prefix(PLACEHOLDER)
                .map(|r| r.trim_start_matches('/'))
        };
        let entry = m.run.command.first().and_then(|c| tree_path(c));
        let mut folders = BTreeSet::new();
        let mut add = |rel: &str, itself: bool| {
            folders.extend(parents(rel).map(str::to_string));
            if itself && !rel.is_empty() {
                folders.insert(rel.to_string());
            }
        };
        for (rel, e) in &items {
            add(rel, matches!(e, FileEntry::Dir { .. }));
        }
        for w in &m.run.writable {
            add(w, true);
        }
        if let Some(cwd) = m.run.cwd.as_deref().and_then(tree_path) {
            add(cwd, true);
        }
        Layout {
            app,
            writable: &m.run.writable,
            entry,
            items,
            index: TableIndex::new(files),
            folders,
        }
    }

    /// True when `rel` is a writable folder or below one.
    fn writable(&self, rel: &str) -> bool {
        self.writable.iter().any(|w| {
            rel.strip_prefix(w.as_str())
                .is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
        })
    }

    /// True when the new tree has a copy at `rel`, not a link.
    fn copied(&self, rel: &str) -> bool {
        self.writable(rel) || self.entry == Some(rel)
    }

    /// True when what the game keeps at `rel` stays at `rel` in the new tree: in a writable
    /// folder, not where the new tree has a folder, and with no table file or link above it.
    fn in_place(&self, rel: &str) -> bool {
        self.writable(rel)
            && !self.folders.contains(rel)
            && !parents(rel).any(|p| {
                matches!(
                    self.index.get(&format!("payload/{p}")),
                    Some(FileEntry::File { .. } | FileEntry::Link { .. })
                )
            })
    }

    /// The target of the link the tree has at `rel`: the original in `/app/payload`.
    fn link_target(&self, rel: &str) -> String {
        join(self.app, &format!("payload/{rel}"))
    }
}

fn failure(what: &str) -> impl Fn(io::Error) -> Failure + '_ {
    move |e| {
        Failure::new(
            "launch.game",
            format!("The game's own folder cannot be {what} ({e})."),
        )
    }
}

/// Make or update the game tree when the package has `run.writable` (see the module docs);
/// `app` is the package tree (`/app`), `files` its table. Saves the status file with the new
/// `game_build` before the new tree takes the old one's place.
pub fn ensure(
    os: &mut dyn LaunchOs,
    app: &str,
    m: &Manifest,
    files: &[FileEntry],
    data: &str,
    state: &mut State,
) -> Result<(), Failure> {
    if m.run.writable.is_empty() {
        return Ok(());
    }
    let mut tree = os.kind(data, TREE).map_err(failure("checked"))?;
    let mut new = os.kind(data, NEW).map_err(failure("checked"))?;
    if state.game_build == Some(m.build) && tree == Some(Kind::Dir) && new.is_none() {
        return Ok(());
    }
    let layout = Layout::new(app, m, files);
    let old = state.game_build.unwrap_or(0);
    // `game.new/` is this build's when its record says so; one started for another build (an
    // update came before the rebuild could finish) is an old tree of its own.
    let started = (new == Some(Kind::Dir))
        .then(|| Base::read(os, data, NEW_BASE))
        .flatten();
    let resume = started.as_ref().is_some_and(|b| b.build == m.build);
    os.log(&format!(
        "making the game folder for build {}{}",
        m.build,
        match (resume, new, state.game_build) {
            (true, _, _) => " (going on with the one cut short)".to_string(),
            (false, Some(Kind::Dir), _) => {
                " (the one cut short was for another build; what it holds goes back first)"
                    .to_string()
            }
            (false, _, Some(b)) => format!(" (it was build {b})"),
            (false, _, None) => String::new(),
        }
    ));
    if tree.is_some_and(|k| k != Kind::Dir) {
        os.log("the game folder is not a folder; it is replaced");
        os.remove(data, TREE).map_err(failure("made"))?;
        tree = None;
    }
    let mut keeper = Keeper {
        aside: KEPT.path(old),
        kept: 0,
    };
    if new == Some(Kind::Dir) && !resume {
        os.make_dirs(data, TREE).map_err(failure("updated"))?;
        let mut back = Sort {
            os: &mut *os,
            data,
            layout: &layout,
            base: started.as_ref(),
            from: NEW,
            into: TREE,
            back: true,
            keeper: &mut keeper,
        };
        back.folder("", 0).map_err(failure("updated"))?;
        // What is left is the launcher's: its links, folders and the copies nobody changed.
        os.remove(data, NEW).map_err(failure("updated"))?;
        tree = Some(Kind::Dir);
        new = None;
    }
    let copies: Vec<(&str, &str)> = layout
        .items
        .iter()
        .filter_map(|(rel, e)| match e {
            FileEntry::File { sha256, .. } if layout.copied(rel) => Some((*rel, sha256.as_str())),
            _ => None,
        })
        .collect();
    let (base, left) = Base::of(m.build, &copies);
    if left > 0 {
        os.log(&format!(
            "the game folder's record holds {} copies; {left} more count as changed at the next update",
            base.files.len()
        ));
    }
    if !resume {
        // Before anything moves into `game.new/`: the build it is for, and its copies' hashes.
        os.write_atomic(data, NEW_BASE, &base.to_bytes())
            .map_err(failure("recorded"))?;
    }
    start(os, data, &layout, new).map_err(failure("made"))?;
    if tree == Some(Kind::Dir) {
        let old_base = Base::read(os, data, BASE).filter(|b| state.game_build == Some(b.build));
        let mut sort = Sort {
            os: &mut *os,
            data,
            layout: &layout,
            base: old_base.as_ref(),
            from: TREE,
            into: NEW,
            back: false,
            keeper: &mut keeper,
        };
        sort.folder("", 0).map_err(failure("updated"))?;
    }
    fill(os, data, &layout, &mut keeper).map_err(failure("made"))?;
    close(os, data, &layout).map_err(failure("made"))?;
    os.write_atomic(data, BASE, &base.to_bytes())
        .map_err(failure("recorded"))?;
    state.game_build = Some(m.build);
    crate::save(os, data, state)?;
    os.remove(data, TREE).map_err(failure("replaced"))?;
    os.rename(data, NEW, data, TREE)
        .map_err(failure("replaced"))?;
    os.remove(data, NEW_BASE).map_err(failure("replaced"))?;
    if keeper.kept > 0 {
        os.log(&format!(
            "{} files the game wrote have no writable place in build {}; they are in {}/",
            keeper.kept, m.build, keeper.aside
        ));
        crate::prune_sets(os, data, &KEPT, old);
    }
    Ok(())
}

/// `game.new/` with every folder of the new tree, each open (0700) while the tree fills: one cut
/// short is kept (what the game had is in it), anything else there is replaced.
fn start(os: &mut dyn LaunchOs, data: &str, layout: &Layout, new: Option<Kind>) -> io::Result<()> {
    if new.is_some_and(|k| k != Kind::Dir) {
        os.remove(data, NEW)?;
    }
    os.make_dirs(data, NEW)?;
    os.set_mode(data, NEW, OPEN)?;
    // In path order, so a folder is open before one below it is made.
    for f in &layout.folders {
        let at = join(NEW, f);
        os.make_dirs(data, &at)?;
        os.set_mode(data, &at, OPEN)?;
    }
    Ok(())
}

/// The most `~<n>` names tried for one kept file before the update gives up.
const MAX_KEPT_NAMES: u32 = 1000;

/// What the game wrote that has no place in the new tree goes into `game-kept/<old build>/` at
/// its path there; a kept file is never replaced: when the name is taken (a second update from the
/// same build, a rebuild cut short), the file gets the first free `<name>~1`, `<name>~2`, ...
struct Keeper {
    /// `game-kept/<old build>`.
    aside: String,
    /// How many entries went there.
    kept: usize,
}

impl Keeper {
    /// Move `from/rel` into the set, under a name nothing has yet.
    fn keep(&mut self, os: &mut dyn LaunchOs, data: &str, from: &str, rel: &str) -> io::Result<()> {
        let at = join(&self.aside, rel);
        let mut to = at.clone();
        let mut n = 0;
        while os.kind(data, &to)?.is_some() {
            n += 1;
            if n > MAX_KEPT_NAMES {
                return Err(io::Error::other(format!(
                    "{at} and {MAX_KEPT_NAMES} more names for it are taken"
                )));
            }
            to = format!("{at}~{n}");
        }
        os.rename(data, &join(from, rel), data, &to)?;
        self.kept += 1;
        Ok(())
    }
}

/// The walk of a tree being replaced that decides where each file the game may have written goes:
/// the old tree into `game.new/`, or a `game.new/` started for another build back into the old
/// tree (`back`).
struct Sort<'a, 'b> {
    os: &'b mut dyn LaunchOs,
    data: &'b str,
    layout: &'b Layout<'a>,
    /// The record of the tree walked, when it is that tree's and could be read.
    base: Option<&'b Base>,
    /// The tree walked.
    from: &'static str,
    /// Where what the game wrote stays when it may.
    into: &'static str,
    /// Going back into the old tree: anything may stay at its path there when it is free.
    back: bool,
    keeper: &'b mut Keeper,
}

impl Sort<'_, '_> {
    /// Sort the folder `rel` (`depth` folders below the root), opened first: a folder outside the
    /// writable ones is 0500, and the game may have closed one of its own.
    fn folder(&mut self, rel: &str, depth: usize) -> io::Result<()> {
        let at = join(self.from, rel);
        self.os.set_mode(self.data, &at, OPEN)?;
        for (name, kind) in self.os.list(self.data, &at)? {
            let p = below(rel, &name);
            match kind {
                Kind::Dir if depth < MAX_COPY_DEPTH => self.folder(&p, depth + 1)?,
                // Deeper than any copy goes: kept whole, not walked.
                Kind::Dir => self.keeper.keep(self.os, self.data, self.from, &p)?,
                Kind::File if self.unchanged(&p) => {
                    self.os.remove(self.data, &join(self.from, &p))?
                }
                Kind::File => self.keep(&p)?,
                Kind::Link => {
                    let target = self.os.read_link(self.data, &join(self.from, &p))?;
                    if target != self.layout.link_target(&p) {
                        self.keep(&p)?;
                    }
                }
                // A FIFO or a socket is no data: it goes with the old tree.
                Kind::Other => {}
            }
        }
        Ok(())
    }

    /// True when the file `rel` is the copy the base records, unchanged. Not known (no base, no
    /// entry, a file that cannot be read or is bigger than any copy) is changed.
    fn unchanged(&self, rel: &str) -> bool {
        let Some(want) = self.base.and_then(|b| b.files.get(rel)) else {
            return false;
        };
        let Ok(mut file) = self.os.open(self.data, &join(self.from, rel)) else {
            return false;
        };
        matches!(
            ruya_play_format::sha256_of(&mut file, MAX_WRITABLE_BYTES),
            Ok(Some((hash, _))) if &hash == want
        )
    }

    /// Move `rel` (the game's) out of the tree walked: to the same path in [`Self::into`] when it
    /// may stay there and nothing is at that path, else into `game-kept/<old build>/`. Nothing at
    /// the destination is ever replaced.
    fn keep(&mut self, rel: &str) -> io::Result<()> {
        let stays = self.back || self.layout.in_place(rel);
        let to = join(self.into, rel);
        if stays && matches!(self.os.kind(self.data, &to), Ok(None)) {
            return self
                .os
                .rename(self.data, &join(self.from, rel), self.data, &to);
        }
        self.keeper.keep(self.os, self.data, self.from, rel)
    }
}

/// Every table entry of `payload/` into `game.new/`: a copy (made in [`STAGE`], its mode set,
/// renamed into place) or a link to the original. What is already there is kept when it is the
/// game's (moved in) or a whole copy from a rebuild of this build cut short; anything else that is
/// not a link is kept aside before the entry takes its place, so nothing the game wrote is
/// removed.
fn fill(os: &mut dyn LaunchOs, data: &str, layout: &Layout, keeper: &mut Keeper) -> io::Result<()> {
    for (rel, e) in &layout.items {
        let at = join(NEW, rel);
        let there = os.kind(data, &at)?;
        match e {
            FileEntry::File { executable, .. } if layout.copied(rel) => {
                match there {
                    Some(Kind::File) => continue,
                    // The game's link in a writable folder is its data.
                    Some(Kind::Link) if layout.writable(rel) => continue,
                    Some(Kind::Link) | None => {}
                    Some(_) => keeper.keep(os, data, NEW, rel)?,
                }
                if !os.copy(layout.app, &format!("payload/{rel}"), data, STAGE)? {
                    return Err(io::Error::new(
                        io::ErrorKind::NotFound,
                        format!("payload/{rel} is missing from the package; reinstall it"),
                    ));
                }
                os.set_mode(data, STAGE, if *executable { PROGRAM } else { COPY })?;
                os.rename(data, STAGE, data, &at)?;
            }
            FileEntry::File { .. } | FileEntry::Link { .. } => {
                let target = layout.link_target(rel);
                match there {
                    Some(Kind::Link) if os.read_link(data, &at)? == target => continue,
                    Some(Kind::Link) | None => {}
                    Some(_) => keeper.keep(os, data, NEW, rel)?,
                }
                os.symlink(&target, data, &at)?;
            }
            FileEntry::Dir { .. } => {}
        }
    }
    Ok(())
}

/// The modes of the full tree: 0700 inside the writable folders, 0500 outside them and at the
/// root.
fn close(os: &mut dyn LaunchOs, data: &str, layout: &Layout) -> io::Result<()> {
    for f in &layout.folders {
        let mode = if layout.writable(f) { OPEN } else { SHUT };
        os.set_mode(data, &join(NEW, f), mode)?;
    }
    os.set_mode(data, NEW, SHUT)
}

#[cfg(test)]
mod tests {
    use super::*;

    const H: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    #[test]
    fn a_base_that_cannot_be_read_counts_as_none_so_every_file_changed() {
        let mut os = crate::fake::FakeOs::new();
        os.file("/d/.ruya-play/game-base.json", Base::default().to_bytes());
        os.fail_open(
            "/d/.ruya-play/game-base.json",
            io::ErrorKind::PermissionDenied,
        );
        assert_eq!(Base::read(&os, "/d", BASE), None);
        let lines = os.lines.borrow();
        assert!(
            lines.iter().any(|l| l.contains("cannot be read")),
            "{lines:?}"
        );
    }

    #[test]
    fn a_base_round_trips() {
        let base = Base {
            build: 3,
            files: [("System/UT.ini".to_string(), H.to_string())].into(),
        };
        assert_eq!(Base::parse(&base.to_bytes()), Some(base));
    }

    #[test]
    fn a_base_the_game_could_have_written_is_held_to_its_rules() {
        let line = |files: &str| format!(r#"{{"format":1,"build":2,"files":{files}}}"#);
        for bad in [
            "not json".to_string(),
            r#"{"format":2,"build":2,"files":{}}"#.to_string(),
            r#"{"format":1,"files":{}}"#.to_string(),
            r#"{"format":1,"build":-1,"files":{}}"#.to_string(),
            line("[]"),
            line(&format!(r#"{{"../x":"{H}"}}"#)),
            line(&format!(r#"{{"/abs":"{H}"}}"#)),
            line(&format!(r#"{{"a//b":"{H}"}}"#)),
            line(&format!(r#"{{"a/./b":"{H}"}}"#)),
            line(&format!(r#"{{"":"{H}"}}"#)),
            line(&format!(r#"{{"a\u0007":"{H}"}}"#)),
            line(r#"{"a":"ABC"}"#),
            line(&format!(r#"{{"a":"{}"}}"#, H.to_uppercase())),
            line(r#"{"a":1}"#),
            line(&format!(
                r#"{{"{}":"{H}"}}"#,
                "a".repeat(ruya_play_format::limits::MAX_PATH_BYTES + 1)
            )),
        ] {
            assert_eq!(Base::parse(bad.as_bytes()), None, "{bad}");
        }
        // One entry over the cap, and a file over the byte cap.
        let many: Vec<String> = (0..=MAX_BASE_ENTRIES)
            .map(|i| format!(r#""f{i}":"{H}""#))
            .collect();
        assert_eq!(
            Base::parse(line(&format!("{{{}}}", many.join(","))).as_bytes()),
            None
        );
        let mut big = line("{}").into_bytes();
        big.resize(MAX_BASE_BYTES as usize + 1, b' ');
        assert_eq!(Base::parse(&big), None);
    }

    #[test]
    fn the_written_base_stays_within_what_the_reader_takes() {
        let paths: Vec<String> = (0..MAX_BASE_ENTRIES + 5)
            .map(|i| format!("S/f{i}"))
            .collect();
        let copies: Vec<(&str, &str)> = paths.iter().map(|p| (p.as_str(), H)).collect();
        let (base, left) = Base::of(1, &copies);
        assert_eq!(base.files.len(), MAX_BASE_ENTRIES);
        assert_eq!(left, 5);
        assert!(Base::parse(&base.to_bytes()).is_some());
        // Long paths (each a valid table path, parts of at most 255 bytes): the byte cap stops
        // it first.
        let part = "d".repeat(250);
        let long: Vec<String> = (0..8000)
            .map(|i| format!("{part}/{part}/{part}/{i}"))
            .collect();
        let copies: Vec<(&str, &str)> = long.iter().map(|p| (p.as_str(), H)).collect();
        let (base, left) = Base::of(1, &copies);
        assert!(left > 0);
        let bytes = base.to_bytes();
        assert!(bytes.len() as u64 <= MAX_BASE_BYTES, "{}", bytes.len());
        assert_eq!(
            Base::parse(&bytes).map(|b| b.files.len()),
            Some(base.files.len())
        );
    }

    #[test]
    fn parents_are_every_folder_above() {
        assert_eq!(parents("a/b/c").collect::<Vec<_>>(), ["a", "a/b"]);
        assert_eq!(parents("a").count(), 0);
        assert_eq!(below("", "x"), "x");
        assert_eq!(below("a", "x"), "a/x");
    }
}
