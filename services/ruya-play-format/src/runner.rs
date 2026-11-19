//! `runner.json` v1 (ADR-037, 05 §6.2.1): the one parser of the file every runner carries, the
//! defaults of a bundled copy without one, where `${prefix}` lives for each kind, and the runner
//! hash formula of 05 §7.3.
//!
//! `ruya-pack`, the importer and the launcher all read a `runner.json` through [`parse_runner`],
//! so a file one of them accepts is a file every one of them accepts. Everything in it is
//! untrusted data: the file is at most 64 KiB, every key is known, a key named twice is refused,
//! and a present but invalid file is refused, never replaced by the defaults. Only a bundled copy
//! *without* the file gets the defaults of its type ([`BundledRunner::defaults`]).
//!
//! ```
//! use ruya_play_format::problem::Problems;
//! use ruya_play_format::runner::{parse_runner, Entry};
//! let text = br#"{"format": 1, "family": "wine", "kind": "wine", "version": "9.20",
//!   "arch": "x86_64", "entry": {"wine": "bin/wine", "wineserver": "bin/wineserver"}}"#;
//! let mut problems = Problems::new();
//! let r = parse_runner(text, "components/wine/runner.json", &mut problems).unwrap();
//! assert_eq!(r.entry, Entry::default_for("wine"));
//! ```

use crate::json::find_duplicate_key;
use crate::limits::{
    COMPONENT_TYPES, MAX_RUNNER_FAMILY_BYTES, MAX_RUNNER_JSON_BYTES, RUNNER_ARCH,
    RUNNER_CAPABILITIES, RUNNER_ENTRY_PROTON, RUNNER_ENTRY_WINE, RUNNER_KEYS, RUNNER_REQUIRED_KEYS,
    SUPPORTED_RUNNER_FORMAT,
};
use crate::manifest::{is_spdx_like, is_version_text, Component, Manifest};
use crate::path::check_path;
use crate::problem::{codes, pointer_join, quote, Problems};
use crate::resolve::default_bundled_family;
use crate::source::Source;
use crate::table::{FileEntry, TableIndex};
use crate::text::check_https_url;
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

/// The file's name at the root of a runner's folder.
pub const FILE_NAME: &str = "runner.json";

/// The programs a runner is started through, as paths below its root folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Entry {
    /// A Wine build: `wine` runs the program, `wineserver` is `WINESERVER`.
    Wine {
        /// The `wine` loader (`WINELOADER`).
        wine: String,
        /// The `wineserver`.
        wineserver: String,
    },
    /// A Proton build: its `proton` script.
    Proton {
        /// The `proton` script (run through its shebang).
        proton: String,
    },
    /// An emulator or engine: `run.command` names `${component:<id>}` itself.
    None,
}

impl Entry {
    /// The entry of a runner of `kind` that has no `runner.json`: wine `bin/wine` and
    /// `bin/wineserver`, proton `proton`, nothing for an emulator or engine.
    pub fn default_for(kind: &str) -> Entry {
        match kind {
            "wine" => Entry::Wine {
                wine: "bin/wine".into(),
                wineserver: "bin/wineserver".into(),
            },
            "proton" => Entry::Proton {
                proton: "proton".into(),
            },
            _ => Entry::None,
        }
    }

    /// Each entry's key and path, in key order.
    pub fn paths(&self) -> Vec<(&'static str, &str)> {
        match self {
            Entry::Wine { wine, wineserver } => vec![("wine", wine), ("wineserver", wineserver)],
            Entry::Proton { proton } => vec![("proton", proton)],
            Entry::None => Vec::new(),
        }
    }
}

/// A checked `runner.json` of format 1.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunnerJson {
    /// `[a-z0-9][a-z0-9.-]{0,63}`; versions compare only inside one family.
    pub family: String,
    /// `wine`, `proton`, `emulator` or `engine`.
    pub kind: String,
    /// At most 32 characters holding a number (`resolve::compare_versions` applies).
    pub version: String,
    /// `x86_64`.
    pub arch: String,
    /// The programs it is started through (none for an emulator or engine).
    pub entry: Entry,
    /// Values of [`RUNNER_CAPABILITIES`], informational in format 1.
    pub capabilities: Vec<String>,
    /// SPDX licence of the runner.
    pub licence: Option<String>,
    /// Where its source is (https).
    pub source_url: Option<String>,
}

/// The runner of one bundled component: what its `runner.json` declares, or its type's defaults.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BundledRunner {
    /// The family [`crate::resolve::resolve`] compares system runners with.
    pub family: String,
    /// The programs the launcher starts.
    pub entry: Entry,
    /// The file itself; `None` when the copy has no `runner.json`.
    pub declared: Option<RunnerJson>,
}

impl BundledRunner {
    /// The defaults of a copy without `runner.json` (lead-29): the type's own family
    /// ([`default_bundled_family`]) and [`Entry::default_for`] its type.
    pub fn defaults(c: &Component) -> Self {
        BundledRunner {
            family: default_bundled_family(c),
            entry: Entry::default_for(&c.kind),
            declared: None,
        }
    }

    fn declared(r: RunnerJson) -> Self {
        BundledRunner {
            family: r.family.clone(),
            entry: r.entry.clone(),
            declared: Some(r),
        }
    }
}

/// True for a runner family: `[a-z0-9][a-z0-9.-]{0,63}`.
pub fn is_family(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= MAX_RUNNER_FAMILY_BYTES
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, b'.' | b'-'))
}

type Obj = Map<String, Value>;

/// Reports into `problems` with locations `<file>#<JSON pointer>`.
struct Check<'a> {
    file: &'a str,
    p: &'a mut Problems,
}

impl Check<'_> {
    fn at(&self, pointer: &str) -> String {
        format!("{}#{pointer}", self.file)
    }

    fn add(&mut self, code: &str, pointer: &str, message: impl Into<String>) {
        let at = self.at(pointer);
        self.p.add(code, at, message);
    }

    /// The string at `key` of `obj`, when present and a string (another type is `runner.type`).
    fn string<'v>(&mut self, obj: &'v Obj, key: &str, base: &str) -> Option<&'v str> {
        let v = obj.get(key)?;
        let s = v.as_str();
        if s.is_none() {
            self.add(
                codes::RUNNER_TYPE,
                &pointer_join(base, key),
                format!("{} is a string.", quote(key)),
            );
        }
        s
    }

    fn keys(&mut self, obj: &Obj, known: &[&str], required: &[&str], base: &str) {
        for k in obj.keys() {
            if !known.contains(&k.as_str()) {
                self.add(
                    codes::RUNNER_UNKNOWN_KEY,
                    &pointer_join(base, k),
                    format!(
                        "{} is not a key of runner.json here; the keys are {}.",
                        quote(k),
                        known.join(", ")
                    ),
                );
            }
        }
        for k in required {
            if !obj.contains_key(*k) {
                self.add(
                    codes::RUNNER_MISSING_FIELD,
                    &pointer_join(base, k),
                    format!("{} is required.", quote(k)),
                );
            }
        }
    }

    /// `entry` for a runner of the (valid) `kind`.
    fn entry(&mut self, root: &Obj, kind: &str) -> Option<Entry> {
        let keys: &[&str] = match kind {
            "wine" => &RUNNER_ENTRY_WINE,
            "proton" => &RUNNER_ENTRY_PROTON,
            _ => {
                if root.contains_key("entry") {
                    self.add(
                        codes::RUNNER_ENTRY_INVALID,
                        "/entry",
                        "An emulator or engine runner has no entry; run.command names ${component:<id>} itself.",
                    );
                    return None;
                }
                return Some(Entry::None);
            }
        };
        let Some(v) = root.get("entry") else {
            self.add(
                codes::RUNNER_MISSING_FIELD,
                "/entry",
                format!(
                    "A {kind} runner needs \"entry\" with {}.",
                    keys.join(" and ")
                ),
            );
            return None;
        };
        let Some(obj) = v.as_object() else {
            self.add(
                codes::RUNNER_TYPE,
                "/entry",
                "\"entry\" is an object of paths.",
            );
            return None;
        };
        self.keys(obj, keys, keys, "/entry");
        let mut paths = Vec::new();
        for k in keys {
            let Some(p) = self.string(obj, k, "/entry") else {
                continue;
            };
            if let Err((_, why)) = check_path(p) {
                self.add(
                    codes::RUNNER_ENTRY_INVALID,
                    &pointer_join("/entry", k),
                    format!(
                        "{} is not a plain relative path inside the runner: {why}",
                        quote(p)
                    ),
                );
                continue;
            }
            paths.push(p.to_string());
        }
        match (kind, paths.as_slice()) {
            ("wine", [wine, wineserver]) => Some(Entry::Wine {
                wine: wine.clone(),
                wineserver: wineserver.clone(),
            }),
            ("proton", [proton]) => Some(Entry::Proton {
                proton: proton.clone(),
            }),
            _ => None,
        }
    }

    fn capabilities(&mut self, root: &Obj) -> Vec<String> {
        let Some(v) = root.get("capabilities") else {
            return Vec::new();
        };
        let Some(list) = v.as_array() else {
            self.add(
                codes::RUNNER_TYPE,
                "/capabilities",
                "\"capabilities\" is a list of strings.",
            );
            return Vec::new();
        };
        let mut out: Vec<String> = Vec::new();
        for (i, item) in list.iter().enumerate() {
            let at = format!("/capabilities/{i}");
            match item.as_str() {
                Some(s) if out.iter().any(|c| c == s) => self.add(
                    codes::RUNNER_CAPABILITY_INVALID,
                    &at,
                    format!("{} is named twice.", quote(s)),
                ),
                Some(s) if RUNNER_CAPABILITIES.contains(&s) => out.push(s.to_string()),
                Some(s) => self.add(
                    codes::RUNNER_CAPABILITY_INVALID,
                    &at,
                    format!(
                        "{} is not a capability; the list is {}.",
                        quote(s),
                        RUNNER_CAPABILITIES.join(", ")
                    ),
                ),
                None => self.add(codes::RUNNER_TYPE, &at, "A capability is a string."),
            }
        }
        out
    }
}

/// Parse and check a `runner.json` of format 1. `file` is where it was read from (a package path
/// such as `components/wine/runner.json`, or a folder on disk); problems are located as
/// `<file>#<JSON pointer>`. The runner is returned only when the file added no problem.
///
/// What is checked: at most [`MAX_RUNNER_JSON_BYTES`], UTF-8, no key named twice, one JSON object;
/// `format` first (2 or more is `runner.format_too_new` and nothing else is checked); every key is
/// one of [`RUNNER_KEYS`]; `family`, `kind`, `version`, `arch` and, for `wine` and `proton`,
/// `entry` with exactly that kind's keys, each a plain relative path; an emulator or engine has
/// no `entry`; the optional `capabilities` (closed list, no repeats), `licence` (SPDX) and
/// `source_url` (https). Whether the entry files exist is the caller's question
/// ([`check_entries`] for a package).
pub fn parse_runner(bytes: &[u8], file: &str, problems: &mut Problems) -> Option<RunnerJson> {
    if bytes.len() as u64 > MAX_RUNNER_JSON_BYTES {
        too_big(file, problems);
        return None;
    }
    if std::str::from_utf8(bytes).is_err() {
        problems.add(
            codes::RUNNER_NOT_UTF8,
            file,
            "runner.json is not valid UTF-8.",
        );
        return None;
    }
    let mut c = Check { file, p: problems };
    if let Some(at) = find_duplicate_key(bytes) {
        c.add(
            codes::JSON_DUPLICATE_KEY,
            &at,
            "This object names the same key twice; keep one.",
        );
        return None;
    }
    let value: Value = match serde_json::from_slice(bytes) {
        Ok(v) => v,
        Err(e) => {
            c.p.add(
                codes::RUNNER_INVALID_JSON,
                file,
                format!("runner.json is not valid JSON ({e})."),
            );
            return None;
        }
    };
    let Some(root) = value.as_object() else {
        c.add(codes::RUNNER_TYPE, "", "runner.json is one JSON object.");
        return None;
    };
    match root.get("format") {
        None => {
            c.add(
                codes::RUNNER_MISSING_FIELD,
                "/format",
                "\"format\" is required.",
            );
            return None;
        }
        Some(Value::Number(n))
            if n.as_f64()
                .is_some_and(|f| f >= (SUPPORTED_RUNNER_FORMAT + 1) as f64) =>
        {
            c.add(
                codes::RUNNER_FORMAT_TOO_NEW,
                "/format",
                "This runner needs a newer RuyaOS.",
            );
            return None;
        }
        Some(Value::Number(n)) if n.as_u64() == Some(SUPPORTED_RUNNER_FORMAT) => {}
        Some(_) => {
            c.add(
                codes::RUNNER_FORMAT_INVALID,
                "/format",
                "\"format\" is a whole number, 1 or more.",
            );
            return None;
        }
    }
    let before = c.p.len();
    c.keys(root, &RUNNER_KEYS, &RUNNER_REQUIRED_KEYS, "");

    let family = c.string(root, "family", "");
    if let Some(f) = family {
        if !is_family(f) {
            c.add(
                codes::RUNNER_FAMILY_INVALID,
                "/family",
                format!(
                    "{} is not a family: lower-case letters, digits, . and -, starting with a letter or digit, at most {MAX_RUNNER_FAMILY_BYTES} bytes.",
                    quote(f)
                ),
            );
        }
    }
    let kind = c.string(root, "kind", "");
    let kind_ok = kind.filter(|k| COMPONENT_TYPES.contains(k));
    if let (Some(k), None) = (kind, kind_ok) {
        c.add(
            codes::RUNNER_KIND_INVALID,
            "/kind",
            format!(
                "{} is not a runner kind; use {}.",
                quote(k),
                COMPONENT_TYPES.join(", ")
            ),
        );
    }
    let version = c.string(root, "version", "");
    if let Some(v) = version {
        if !is_version_text(v) || !v.bytes().any(|b| b.is_ascii_digit()) {
            c.add(
                codes::RUNNER_VERSION_INVALID,
                "/version",
                format!(
                    "{} is not a version: at most 32 letters, digits and . _ + -, holding a number.",
                    quote(v)
                ),
            );
        }
    }
    let arch = c.string(root, "arch", "");
    if let Some(a) = arch {
        if a != RUNNER_ARCH {
            c.add(
                codes::RUNNER_ARCH_INVALID,
                "/arch",
                format!(
                    "{} is not supported; format 1 runs {RUNNER_ARCH} only.",
                    quote(a)
                ),
            );
        }
    }
    let entry = kind_ok.and_then(|k| c.entry(root, k));
    let capabilities = c.capabilities(root);
    let licence = c.string(root, "licence", "");
    if let Some(l) = licence {
        if !is_spdx_like(l) {
            c.add(
                codes::RUNNER_LICENCE_INVALID,
                "/licence",
                format!("{} is not an SPDX licence expression.", quote(l)),
            );
        }
    }
    let source_url = c.string(root, "source_url", "");
    if let Some(u) = source_url {
        if let Err((_, why)) = check_https_url(u) {
            c.add(codes::RUNNER_URL_INVALID, "/source_url", why);
        }
    }
    if c.p.len() > before || c.p.is_full() {
        return None;
    }
    Some(RunnerJson {
        family: family?.to_string(),
        kind: kind_ok?.to_string(),
        version: version?.to_string(),
        arch: arch?.to_string(),
        entry: entry?,
        capabilities,
        licence: licence.map(str::to_string),
        source_url: source_url.map(str::to_string),
    })
}

/// `runner.too_big` for `file`: the one message, whether the size was listed or read.
fn too_big(file: &str, problems: &mut Problems) {
    problems.add(
        codes::RUNNER_TOO_BIG,
        file,
        format!("runner.json is larger than {MAX_RUNNER_JSON_BYTES} bytes."),
    );
}

/// A declared runner's `kind` is its component's `type` (`runner.kind_mismatch`).
fn check_kind(c: &Component, file: &str, runner: &RunnerJson, problems: &mut Problems) {
    if runner.kind != c.kind {
        Check { file, p: problems }.add(
            codes::RUNNER_KIND_MISMATCH,
            "/kind",
            format!(
                "The runner's kind {} is not the component's type {}.",
                quote(&runner.kind),
                quote(&c.kind)
            ),
        );
    }
}

/// Every entry the launcher will start of the bundled copy under `root` is a regular file in the
/// table below that folder, not a link or a folder (`runner.entry_missing`), whether `runner`
/// came from its `runner.json` or is the type's defaults. A declared entry is located in the file
/// (`<root>/runner.json#/entry/<key>`); a default entry at the path that should hold it
/// (`<root>/bin/wineserver`), since there is no file to point into.
pub fn check_entries(
    root: &str,
    runner: &BundledRunner,
    table: &TableIndex<'_>,
    problems: &mut Problems,
) {
    let file = format!("{root}/{FILE_NAME}");
    for (key, rel) in runner.entry.paths() {
        let path = format!("{root}/{rel}");
        if table.is_file(&path) {
            continue;
        }
        if runner.declared.is_some() {
            Check {
                file: &file,
                p: problems,
            }
            .add(
                codes::RUNNER_ENTRY_MISSING,
                &pointer_join("/entry", key),
                format!(
                    "{} is not a regular file in the runner's folder (play.files).",
                    quote(rel)
                ),
            );
        } else {
            problems.add(
                codes::RUNNER_ENTRY_MISSING,
                &path,
                format!(
                    "The runner has no runner.json, so it is started through its default {} {}; that is not a regular file in its folder (play.files). Add the file, or a runner.json whose entry names the right one.",
                    quote(key),
                    quote(rel)
                ),
            );
        }
    }
}

/// The runner of each bundled component of `manifest`, by component id (05 §6.2.1). A copy whose
/// folder holds a `runner.json` gets the checked file (read through [`crate::read_small`], at most
/// [`MAX_RUNNER_JSON_BYTES`]); a copy without one gets [`BundledRunner::defaults`]. Either way
/// every entry must be a regular file of the copy ([`check_entries`]). A `runner.json` that is not
/// a regular file, is invalid or names another kind, or an entry the package lacks, adds its
/// problems and no runner. Run it on a package whose table matched.
pub fn bundled_runners(
    source: &dyn Source,
    manifest: &Manifest,
    table: &TableIndex<'_>,
    problems: &mut Problems,
) -> BTreeMap<String, BundledRunner> {
    let mut out = BTreeMap::new();
    for c in &manifest.components {
        let Some(b) = &c.bundled else { continue };
        let root = b.path.trim_end_matches('/');
        let file = format!("{root}/{FILE_NAME}");
        let before = problems.len();
        let runner = match table.get(&file) {
            None => BundledRunner::defaults(c),
            Some(FileEntry::File { size, .. }) => {
                if *size > MAX_RUNNER_JSON_BYTES {
                    too_big(&file, problems);
                    continue;
                }
                let bytes = match crate::read_small(source, &file, MAX_RUNNER_JSON_BYTES) {
                    Ok(b) => b,
                    Err(p) => {
                        problems.add(&p.code, p.path, p.message);
                        continue;
                    }
                };
                let Some(r) = parse_runner(&bytes, &file, problems) else {
                    continue;
                };
                check_kind(c, &file, &r, problems);
                BundledRunner::declared(r)
            }
            Some(FileEntry::Link { .. } | FileEntry::Dir { .. }) => {
                problems.add(
                    codes::RUNNER_NOT_A_FILE,
                    &file,
                    "runner.json must be a regular file, not a link or a folder.",
                );
                continue;
            }
        };
        check_entries(root, &runner, table, problems);
        if problems.len() == before && !problems.is_full() {
            out.insert(c.id.clone(), runner);
        }
    }
    out
}

/// The family of each bundled copy, by component id: what [`crate::resolve::resolve`] takes as
/// `bundled_families`, from the result of [`bundled_runners`] (the validator's
/// `Package::bundled_families` and the launcher both ask this).
pub fn bundled_families(runners: &BTreeMap<String, BundledRunner>) -> BTreeMap<String, String> {
    runners
        .iter()
        .map(|(id, r)| (id.clone(), r.family.clone()))
        .collect()
}

/// Where `${prefix}` is for a runner of `kind`, below the game's data folder `data` (ADR-037):
/// wine `<data>/prefix`, proton `<data>/proton/pfx`; `None` for a kind without a prefix. The
/// launcher, ruya-library and the saves of `prefix:` paths all ask this one function. Pure string
/// work; `data` may be a placeholder such as `${data}`.
pub fn prefix_dir(kind: &str, data: &str) -> Option<String> {
    let data = data.trim_end_matches('/');
    match kind {
        "wine" => Some(format!("{data}/prefix")),
        "proton" => Some(format!("{data}/proton/pfx")),
        _ => None,
    }
}

/// One entry of a runner's tree for [`RunnerHasher`]; `rel` is the path below the runner's root
/// folder.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunnerEntry<'a> {
    /// A regular file with its SHA-256 (lower-case hex) and executable bit.
    File {
        /// Path below the runner's root.
        rel: &'a str,
        /// SHA-256 of the content, 64 lower-case hex digits.
        sha256: &'a str,
        /// Executable.
        exec: bool,
    },
    /// A symbolic link and its target as written.
    Link {
        /// Path below the runner's root.
        rel: &'a str,
        /// The link's target.
        to: &'a str,
    },
    /// An empty folder.
    Dir {
        /// Path below the runner's root.
        rel: &'a str,
    },
}

/// The runner hash of 05 §7.3, fed one entry at a time: the SHA-256 of one line per entry, `f NUL
/// rel NUL sha256 NUL x-or-dash LF` for a file, `l NUL rel NUL target LF` for a link and `d NUL rel
/// LF` for an empty folder (a folder that holds something has no line). Feed the entries in the
/// byte order of their paths, which is `play.files` order; a tree walk sorts first. The importer
/// (from the staged copy), `ruya-pack` and the image build's `.ruya-runner-hash` all use this.
#[derive(Default)]
pub struct RunnerHasher {
    h: Sha256,
}

impl RunnerHasher {
    /// An empty hash.
    pub fn new() -> Self {
        Self::default()
    }

    /// Add the line of `e`.
    pub fn add(&mut self, e: &RunnerEntry<'_>) {
        let h = &mut self.h;
        match e {
            RunnerEntry::File { rel, sha256, exec } => {
                h.update(b"f\0");
                h.update(rel.as_bytes());
                h.update(b"\0");
                h.update(sha256.as_bytes());
                h.update(if *exec { b"\0x\n" } else { b"\0-\n" });
            }
            RunnerEntry::Link { rel, to } => {
                h.update(b"l\0");
                h.update(rel.as_bytes());
                h.update(b"\0");
                h.update(to.as_bytes());
                h.update(b"\n");
            }
            RunnerEntry::Dir { rel } => {
                h.update(b"d\0");
                h.update(rel.as_bytes());
                h.update(b"\n");
            }
        }
    }

    /// The hash as 64 lower-case hex digits.
    pub fn finish(self) -> String {
        crate::hex(&self.h.finalize())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hash_formula_is_fixed() {
        // A change of the line format changes every runner hash on every blocklist: it must fail
        // here. The value was computed independently (Python hashlib over the same lines).
        let sha = "ab".repeat(32);
        let mut h = RunnerHasher::new();
        h.add(&RunnerEntry::File {
            rel: "bin/wine",
            sha256: &sha,
            exec: true,
        });
        h.add(&RunnerEntry::Link {
            rel: "lib/a.so",
            to: "a.so.1",
        });
        h.add(&RunnerEntry::File {
            rel: "lib/a.so.1",
            sha256: &sha,
            exec: false,
        });
        h.add(&RunnerEntry::Dir { rel: "share/empty" });
        assert_eq!(h.finish(), GOLDEN);
        assert_eq!(RunnerHasher::new().finish(), EMPTY);
    }

    const GOLDEN: &str = "93550e6c08bce193358acedf36127f3b1bbe7a74b1ddabbcf4d7f536caf68b7c";
    const EMPTY: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    #[test]
    fn prefix_dir_per_kind() {
        assert_eq!(
            prefix_dir("wine", "/home/a/.var/app/play.x/data").as_deref(),
            Some("/home/a/.var/app/play.x/data/prefix")
        );
        assert_eq!(
            prefix_dir("proton", "${data}/").as_deref(),
            Some("${data}/proton/pfx")
        );
        for k in ["native", "emulator", "engine", ""] {
            assert_eq!(prefix_dir(k, "/d"), None, "{k}");
        }
    }

    #[test]
    fn family_grammar() {
        for ok in ["wine", "proton-ge", "0ad", "a", "dosbox.x", &"a".repeat(64)] {
            assert!(is_family(ok), "{ok}");
        }
        for bad in [
            "",
            "-wine",
            ".x",
            "Wine",
            "wine_ge",
            "w ine",
            &"a".repeat(65),
        ] {
            assert!(!is_family(bad), "{bad}");
        }
    }
}
