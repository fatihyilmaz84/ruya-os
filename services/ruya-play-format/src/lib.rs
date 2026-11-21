//! The `.play` package format (docs/specs/05-play-packages.md): the one parser and validator of
//! `play.json`, `play.files` and the folder and zip forms.
//!
//! Pure Rust, no D-Bus, no Flatpak, no network. Everything inside a package is untrusted data
//! (05 §9.3): [`validate`] lists the entries, reads only a small regular `play.json` for its
//! `format` (a newer major stops there), applies every path rule to the names and kinds, and opens
//! nothing else until they pass. It returns the [`Package`] or the full list of [`Problem`]s.
//!
//! ```
//! use ruya_play_format::{validate, MemorySource, ValidateOptions};
//! let empty = MemorySource::new();
//! let problems = validate(&empty, &ValidateOptions::default()).unwrap_err();
//! assert_eq!(problems[0].code, "package.no_manifest");
//! ```

pub mod folder;
pub mod json;
pub mod limits;
pub mod manifest;
pub mod path;
pub mod problem;
pub mod resolve;
pub mod runner;
pub mod source;
pub mod table;
pub mod text;
pub mod zip;

pub use folder::FolderSource;
pub use manifest::Manifest;
pub use problem::{codes, Problem};
pub use runner::BundledRunner;
pub use source::{Entry, EntryKind, MemorySource, ReadFault, Source};
pub use table::FileEntry;
pub use zip::ZipSource;

use problem::Problems;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::io::{self, Read};
use table::TableIndex;

/// What [`validate`] does besides the format rules.
#[derive(Debug, Clone)]
pub struct ValidateOptions {
    /// Read every file and check its size and SHA-256 against the table (default true). Without
    /// it only names, kinds, listed sizes, the two metadata files and each bundled copy's
    /// `runner.json` are checked.
    pub verify_content: bool,
    /// The package is for the Official tier: ids under `org.ruyaos.` or `play.` and system-like
    /// names are allowed (default false).
    pub official: bool,
}

impl Default for ValidateOptions {
    fn default() -> Self {
        ValidateOptions {
            verify_content: true,
            official: false,
        }
    }
}

/// A package that passed every rule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Package {
    /// The checked `play.json`.
    pub manifest: Manifest,
    /// The checked file table, in table order.
    pub files: Vec<FileEntry>,
    /// Sum of all file sizes: what the package takes once installed. `requirements.installed_mb`
    /// is this, never a declared value.
    pub installed_bytes: u64,
    /// The runner of each bundled component, by component id: its checked `runner.json`, or the
    /// defaults of its type when the copy has none (05 §6.2.1).
    pub runners: BTreeMap<String, BundledRunner>,
}

impl Package {
    /// [`Self::installed_bytes`] in MB (10^6 bytes), rounded up.
    pub fn installed_mb(&self) -> u64 {
        self.installed_bytes.div_ceil(1_000_000)
    }

    /// The family of each bundled copy, by component id: what [`resolve::resolve`] takes as
    /// `bundled_families`.
    pub fn bundled_families(&self) -> BTreeMap<String, String> {
        runner::bundled_families(&self.runners)
    }
}

/// The SHA-256 of what `reader` gives, as the 64 lower-case hex digits `play.files` writes, and
/// how many bytes that was; `None` once it gives more than `limit` bytes (the rest is not read).
/// The one streaming hasher of the format (a 256 KiB buffer): the content pass of [`validate`]
/// and the launcher's update of a game tree (ADR-040) both use it.
pub fn sha256_of(reader: &mut dyn Read, limit: u64) -> io::Result<Option<(String, u64)>> {
    let mut buf = vec![0u8; 256 * 1024];
    let (mut hasher, mut total) = (Sha256::new(), 0u64);
    loop {
        match reader.read(&mut buf) {
            Ok(0) => return Ok(Some((hex(&hasher.finalize()), total))),
            Ok(n) => {
                total += n as u64;
                if total > limit {
                    return Ok(None);
                }
                hasher.update(&buf[..n]);
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes
        .iter()
        .fold(String::with_capacity(bytes.len() * 2), |mut s, b| {
            let _ = write!(s, "{b:02x}");
            s
        })
}

/// Why a small file of the package could not be read: the operating system failed
/// ([`ReadError::Io`]: `EACCES`, `EIO`, or the file is not there) or the container found the
/// content wrong ([`ReadError::Content`]: a zip whose declared size lies). A caller that must not
/// mistake an unreadable file for a damaged one (the launcher's status file) matches on it; the
/// validator turns either into a [`Problem`] ([`ReadError::into_problem`]).
#[derive(Debug)]
pub enum ReadError {
    /// The read failed in the operating system.
    Io(io::Error),
    /// The container reported the content as wrong.
    Content(Problem),
}

impl ReadError {
    fn from_io(err: io::Error) -> ReadError {
        match ReadFault::from_io(&err) {
            Some(p) => ReadError::Content(p.clone()),
            None => ReadError::Io(err),
        }
    }

    /// The problem to report for the file at `path`.
    pub fn into_problem(self, path: &str) -> Problem {
        match self {
            ReadError::Content(p) => p,
            ReadError::Io(err) => Problem::new(
                codes::PACKAGE_READ_FAILED,
                path,
                format!("The file could not be read ({err})."),
            ),
        }
    }
}

/// Read a whole small file of the package (a metadata file, a `runner.json`): at most `limit + 1`
/// bytes, so a caller sees that a file is longer than `limit` without reading it all (the caller
/// reports that). The one bounded reader of package files outside the content pass.
pub fn read_small(source: &dyn Source, path: &str, limit: u64) -> Result<Vec<u8>, ReadError> {
    let reader = source.open(path).map_err(ReadError::from_io)?;
    let mut buf = Vec::new();
    reader
        .take(limit + 1)
        .read_to_end(&mut buf)
        .map_err(ReadError::from_io)?;
    Ok(buf)
}

/// [`read_small`] for a caller that treats a longer file like an absent one: `Ok(None)` when the
/// file is longer than `limit`, the error when it cannot be read.
pub fn read_within(
    source: &dyn Source,
    path: &str,
    limit: u64,
) -> Result<Option<Vec<u8>>, ReadError> {
    let buf = read_small(source, path, limit)?;
    Ok((buf.len() as u64 <= limit).then_some(buf))
}

/// Validate the package in `source`: the `format` of a small regular `play.json` (step 0, the only
/// read before the names pass), then the names and kinds, then `play.files`, then
/// `play.json`, then how the table matches the entries, then each bundled copy's `runner.json`,
/// then (unless disabled) every file's size and hash. A package that fails an earlier step is not read further.
pub fn validate(source: &dyn Source, opts: &ValidateOptions) -> Result<Package, Vec<Problem>> {
    let entries = source.entries()?;
    let mut problems = Problems::new();

    // 0. A package for a newer console is told so and nothing else: its rules are not ours.
    let manifest_listed = entries.iter().find(|e| {
        e.path == "play.json" && e.kind == EntryKind::File && e.size <= limits::MAX_MANIFEST_BYTES
    });
    if manifest_listed.is_some() {
        if let Ok(bytes) = read_small(source, "play.json", limits::MAX_MANIFEST_BYTES) {
            if manifest::is_future_format(&bytes) {
                return Err(vec![Problem::new(
                    codes::FORMAT_TOO_NEW,
                    "/format",
                    "This package needs a newer RuyaOS.",
                )]);
            }
        }
    }

    // 1. Names and kinds. Nothing but step 0's play.json is read before this passes.
    for e in &entries {
        if let Err((code, msg)) = path::check_path(&e.path) {
            problems.add(code, &e.path, msg);
            continue;
        }
        let (code, what) = match e.kind {
            EntryKind::File | EntryKind::Dir => continue,
            EntryKind::Symlink => (codes::ENTRY_SYMLINK, "a symbolic link"),
            EntryKind::HardLink => (codes::ENTRY_HARDLINK, "a hard link"),
            EntryKind::Device => (codes::ENTRY_DEVICE, "a device file"),
            EntryKind::Other => (codes::ENTRY_SPECIAL, "a special file"),
        };
        problems.add(code, &e.path, format!("This is {what}; a package holds only regular files and folders (links go in play.files)."));
    }
    path::check_case_collisions(entries.iter().map(|e| e.path.as_str()), &mut problems);

    let by_path: HashMap<&str, &Entry> = entries.iter().map(|e| (e.path.as_str(), e)).collect();
    for root in limits::ROOT_FILES {
        if let Some(e) = by_path.get(root) {
            if e.kind != EntryKind::File {
                problems.add(
                    codes::PACKAGE_ROOT_KIND,
                    root,
                    format!("{root} must be a regular file."),
                );
            }
        }
    }
    let manifest_entry = by_path
        .get("play.json")
        .filter(|e| e.kind == EntryKind::File);
    let table_entry = by_path
        .get("play.files")
        .filter(|e| e.kind == EntryKind::File);
    if manifest_entry.is_none() && !by_path.contains_key("play.json") {
        problems.add(
            codes::PACKAGE_NO_MANIFEST,
            "play.json",
            "The package has no play.json at its root.",
        );
    }
    if table_entry.is_none() && !by_path.contains_key("play.files") {
        problems.add(
            codes::PACKAGE_NO_TABLE,
            "play.files",
            "The package has no play.files at its root.",
        );
    }
    if let Some(e) = manifest_entry {
        if e.size > limits::MAX_MANIFEST_BYTES {
            problems.add(
                codes::MANIFEST_TOO_BIG,
                "play.json",
                format!(
                    "play.json is larger than {} bytes.",
                    limits::MAX_MANIFEST_BYTES
                ),
            );
        }
    }
    if let Some(e) = table_entry {
        if e.size > limits::MAX_TABLE_BYTES {
            problems.add(
                codes::TABLE_TOO_BIG,
                "play.files",
                format!(
                    "play.files is larger than {} bytes.",
                    limits::MAX_TABLE_BYTES
                ),
            );
        }
    }
    if !problems.is_empty() {
        return Err(problems.finish());
    }
    let (Some(_), Some(_)) = (manifest_entry, table_entry) else {
        return Err(problems.finish());
    };

    // 2. The file table.
    let table_bytes = match read_small(source, "play.files", limits::MAX_TABLE_BYTES) {
        Ok(b) => b,
        Err(e) => return Err(vec![e.into_problem("play.files")]),
    };
    if table_bytes.len() as u64 > limits::MAX_TABLE_BYTES {
        problems.add(
            codes::TABLE_TOO_BIG,
            "play.files",
            format!(
                "play.files is larger than {} bytes.",
                limits::MAX_TABLE_BYTES
            ),
        );
        return Err(problems.finish());
    }
    let files = table::parse_table(&table_bytes, &mut problems);
    drop(table_bytes);
    let table_ok = problems.is_empty();
    table::check_table(&files, &mut problems);
    let table_ok = table_ok && problems.is_empty();
    let index = TableIndex::new(&files);

    // 3. The manifest.
    let manifest_bytes = match read_small(source, "play.json", limits::MAX_MANIFEST_BYTES) {
        Ok(b) => b,
        Err(e) => {
            let p = e.into_problem("play.json");
            problems.add(&p.code, p.path, p.message);
            return Err(problems.finish());
        }
    };
    let manifest = manifest::parse_manifest(
        &manifest_bytes,
        &files,
        &index,
        opts.official,
        &mut problems,
    );

    // 4. The table against the package.
    if table_ok {
        match_table(&entries, &files, &index, &mut problems);
    }
    if !problems.is_empty() {
        return Err(problems.finish());
    }
    let Some(manifest) = manifest else {
        return Err(problems.finish());
    };

    // 4b. The runner.json of each bundled copy (ADR-037): a present file must be valid.
    let runners = runner::bundled_runners(source, &manifest, &index, &mut problems);
    if !problems.is_empty() {
        return Err(problems.finish());
    }

    // 5. Content.
    if opts.verify_content {
        verify_content(source, &files, &mut problems);
        if !problems.is_empty() {
            return Err(problems.finish());
        }
    }
    let installed_bytes = files
        .iter()
        .map(|f| {
            if let FileEntry::File { size, .. } = f {
                *size
            } else {
                0
            }
        })
        .fold(0u64, u64::saturating_add);
    Ok(Package {
        manifest,
        files,
        installed_bytes,
        runners,
    })
}

/// Everything in the package is in the table and the other way round, with the same kinds and sizes.
fn match_table(
    entries: &[Entry],
    files: &[FileEntry],
    index: &TableIndex<'_>,
    problems: &mut Problems,
) {
    let present: HashMap<&str, &Entry> = entries.iter().map(|e| (e.path.as_str(), e)).collect();
    for f in files {
        let p = f.path();
        match (f, present.get(p)) {
            (FileEntry::File { .. }, None) => problems.add(codes::PACKAGE_MISSING_FILE, p, "The file is in play.files but not in the package."),
            (FileEntry::Dir { .. }, None) => problems.add(codes::PACKAGE_MISSING_DIR, p, "The folder is in play.files but not in the package."),
            (FileEntry::Link { .. }, Some(_)) => problems.add(
                codes::PACKAGE_KIND_MISMATCH,
                p,
                "play.files lists this as a link, but the package holds a real file or folder there.",
            ),
            (FileEntry::Link { .. }, None) => {}
            (FileEntry::File { size, .. }, Some(e)) => {
                if e.kind != EntryKind::File {
                    problems.add(codes::PACKAGE_KIND_MISMATCH, p, "play.files lists a file; the package has a folder here.");
                } else if e.size != *size {
                    problems.add(
                        codes::PACKAGE_SIZE_MISMATCH,
                        p,
                        format!("play.files says {size} bytes; the package says {}.", e.size),
                    );
                }
            }
            (FileEntry::Dir { .. }, Some(e)) => {
                if e.kind != EntryKind::Dir {
                    problems.add(codes::PACKAGE_KIND_MISMATCH, p, "play.files lists a folder; the package has a file here.");
                }
            }
        }
    }
    for e in entries {
        if limits::ROOT_FILES.contains(&e.path.as_str()) || index.get(&e.path).is_some() {
            continue;
        }
        match e.kind {
            EntryKind::Dir if index.is_dir(&e.path) => {}
            EntryKind::Dir => problems.add(
                codes::PACKAGE_EXTRA_DIR,
                &e.path,
                "This folder is not listed in play.files.",
            ),
            _ => problems.add(
                codes::PACKAGE_EXTRA_FILE,
                &e.path,
                "This file is not listed in play.files.",
            ),
        }
    }
}

fn verify_content(source: &dyn Source, files: &[FileEntry], problems: &mut Problems) {
    for f in files {
        let FileEntry::File {
            path, size, sha256, ..
        } = f
        else {
            continue;
        };
        if problems.is_full() {
            return;
        }
        let mut reader = match source.open(path) {
            Ok(r) => r,
            Err(e) => {
                let p = ReadError::from_io(e).into_problem(path);
                problems.add(&p.code, p.path, p.message);
                continue;
            }
        };
        match sha256_of(&mut reader, u64::MAX) {
            Err(e) => {
                let p = ReadError::from_io(e).into_problem(path);
                problems.add(&p.code, p.path, p.message);
            }
            Ok(Some((_, total))) if total != *size => problems.add(
                codes::PACKAGE_SIZE_MISMATCH,
                path,
                format!("play.files says {size} bytes; the content has {total}."),
            ),
            Ok(Some((hash, _))) if hash != *sha256 => problems.add(
                codes::PACKAGE_HASH_MISMATCH,
                path,
                "The content does not match its SHA-256 in play.files.",
            ),
            Ok(_) => {}
        }
    }
}

/// Validate the package folder at `root`.
pub fn validate_folder(
    root: impl Into<std::path::PathBuf>,
    opts: &ValidateOptions,
) -> Result<Package, Vec<Problem>> {
    validate(&FolderSource::new(root), opts)
}

/// Validate the `.play.zip` read from `reader`.
pub fn validate_zip<R: Read + io::Seek>(
    reader: R,
    opts: &ValidateOptions,
) -> Result<Package, Vec<Problem>> {
    validate(&ZipSource::new(reader)?, opts)
}

/// Validate the `.play.zip` file at `path`.
pub fn validate_zip_file(
    path: impl AsRef<std::path::Path>,
    opts: &ValidateOptions,
) -> Result<Package, Vec<Problem>> {
    let file = std::fs::File::open(path.as_ref()).map_err(|e| {
        vec![Problem::new(
            codes::PACKAGE_READ_FAILED,
            "",
            format!("The file could not be opened ({e})."),
        )]
    })?;
    validate_zip(file, opts)
}
