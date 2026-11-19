//! `play.json`: the manifest (05 §4.1, §6, §8). Rules are written out by hand so every problem
//! carries a JSON pointer and a message a developer can act on; `api/play/play.schema.json` states
//! the same shape for tools that want a schema.

use crate::limits::*;
use crate::path::check_path;
use crate::problem::{codes, pointer_join, Problems};
use crate::table::{FileEntry, TableIndex};
use crate::text::{
    check_chars, check_https_url, check_plain, is_language_tag, is_reserved_app_name,
};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};

/// A text in several languages: language tag to text. `"en"` is always present.
pub type Localized = BTreeMap<String, String>;

/// A developer or publisher.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Credit {
    /// Display name.
    pub name: String,
    /// Optional https URL.
    pub url: Option<String>,
}

/// `players`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Players {
    /// Fewest players.
    pub min: u64,
    /// Most players.
    pub max: u64,
    /// `single`, `local`, `online`.
    pub modes: Vec<String>,
}

/// `age_rating`: OARS 1.1 attributes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgeRating {
    /// Always `oars-1.1`.
    pub scheme: String,
    /// Attribute id to `none`, `mild`, `moderate` or `intense`.
    pub content: BTreeMap<String, String>,
}

/// One entry of `links`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Link {
    /// A value of [`LINK_KINDS`].
    pub kind: String,
    /// An https URL.
    pub url: String,
}

/// `requirements`. (`installed_mb` is not here: it is computed from the file table.)
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Requirements {
    /// `x86_64`.
    pub arch: Option<String>,
    /// Minimum RAM in MB.
    pub min_ram_mb: Option<u64>,
    /// `vulkan` and/or `opengl`.
    pub gpu_api: Vec<String>,
}

/// A path in `art`, optionally per language (the `logo`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ArtPath {
    /// One file.
    One(String),
    /// A file per language tag.
    PerLanguage(BTreeMap<String, String>),
}

/// A screenshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Screenshot {
    /// Package path of the image.
    pub file: String,
    /// Optional caption.
    pub caption: Option<Localized>,
}

/// A trailer video and its poster.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Trailer {
    /// Package path of the video.
    pub file: String,
    /// Package path of the poster image.
    pub poster: Option<String>,
}

/// `art`: the slots (05 §5). Files are checked to exist in the table; decoding is the art vetter's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Art {
    /// Required icon.
    pub icon: String,
    /// Logo.
    pub logo: Option<ArtPath>,
    /// Hero image.
    pub hero: Option<String>,
    /// Cover image.
    pub cover: Option<String>,
    /// Screenshots.
    pub screenshots: Vec<Screenshot>,
    /// Trailer.
    pub trailer: Option<Trailer>,
    /// Muted preview loop.
    pub preview: Option<String>,
}

/// `components[].bundled`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bundled {
    /// Folder under `components/`.
    pub path: String,
    /// Version of the bundled runner.
    pub version: String,
    /// SPDX licence of the bundled code.
    pub licence: String,
    /// Where its source is.
    pub source_url: Option<String>,
}

/// One entry of `components`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Component {
    /// Local id (`run.component` and `${component:<id>}` refer to it).
    pub id: String,
    /// A value of [`COMPONENT_TYPES`].
    pub kind: String,
    /// A value of [`COMPONENT_SOURCES`].
    pub source: String,
    /// Least acceptable system version.
    pub min: Option<String>,
    /// Version the developer tested.
    pub tested: Option<String>,
    /// Highest acceptable system major version.
    pub max_major: Option<u64>,
    /// The shipped copy.
    pub bundled: Option<Bundled>,
}

/// `run.prefix`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Prefix {
    /// `win32` or `win64`.
    pub arch: Option<String>,
    /// Package folder copied to make the prefix.
    pub template: Option<String>,
    /// Raising it recreates the prefix.
    pub epoch: u64,
}

/// One `run.setup` step.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SetupStep {
    /// Step id.
    pub id: String,
    /// argv.
    pub command: Vec<String>,
    /// Run once per prefix.
    pub once: bool,
}

/// `run`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Run {
    /// A value of [`RUNNERS`].
    pub runner: String,
    /// The component that provides the runner (not for `native`).
    pub component: Option<String>,
    /// argv, never a shell string.
    pub command: Vec<String>,
    /// Working directory (starts with a placeholder).
    pub cwd: Option<String>,
    /// Extra environment, checked against the deny table.
    pub env: BTreeMap<String, String>,
    /// A value of [`LAUNCH_MODES`].
    pub launch_mode: String,
    /// Wine prefix settings.
    pub prefix: Option<Prefix>,
    /// First-run steps.
    pub setup: Vec<SetupStep>,
    /// Disc images in order; `${disc}` is the first.
    pub discs: Vec<String>,
}

/// `permissions`, with the defaults filled in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Permissions {
    /// `--share=network`.
    pub network: bool,
    /// A value of [`INPUT_MODES`].
    pub input: String,
    /// A value of [`REMOVABLE_MEDIA`].
    pub removable_media: String,
    /// 32-bit programs.
    pub multiarch: bool,
    /// GameMode.
    pub gamemode: bool,
    /// Realtime scheduling request.
    pub realtime: bool,
    /// ptrace and perf.
    pub devel: bool,
    /// Why each permission is asked, in the developer's words.
    pub reasons: BTreeMap<String, Localized>,
}

impl Default for Permissions {
    fn default() -> Self {
        Permissions {
            network: false,
            input: INPUT_MODES[0].to_string(),
            removable_media: REMOVABLE_MEDIA[0].to_string(),
            multiarch: false,
            gamemode: false,
            realtime: false,
            devel: false,
            reasons: BTreeMap::new(),
        }
    }
}

/// `data`: paths that are saves and paths that are cache.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DataPaths {
    /// `prefix:`, `data:` or `config:` paths kept as saves.
    pub saves: Vec<String>,
    /// Paths that may be deleted to free space.
    pub cache: Vec<String>,
}

/// `update`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Update {
    /// https feed URL.
    pub feed: Option<String>,
    /// Channel name.
    pub channel: Option<String>,
}

/// A validated `play.json`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    /// Format major.
    pub format: u64,
    /// Reverse-DNS id.
    pub id: String,
    /// Display name per language.
    pub name: Localized,
    /// Display version.
    pub version: String,
    /// Update ordering number.
    pub build: u64,
    /// One-line summary.
    pub summary: Option<Localized>,
    /// Long description.
    pub description: Option<Localized>,
    /// Developer.
    pub developer: Option<Credit>,
    /// Publisher.
    pub publisher: Option<Credit>,
    /// `YYYY-MM-DD`.
    pub release_date: Option<String>,
    /// Up to four genres.
    pub genres: Vec<String>,
    /// Free tags.
    pub tags: Vec<String>,
    /// Languages the game supports.
    pub languages: Vec<String>,
    /// Player counts.
    pub players: Option<Players>,
    /// `full`, `partial` or `none`.
    pub controller: Option<String>,
    /// OARS rating.
    pub age_rating: Option<AgeRating>,
    /// SPDX licence of the package contents.
    pub licence: Option<String>,
    /// URL of the licence terms.
    pub terms_url: Option<String>,
    /// Links.
    pub links: Vec<Link>,
    /// Requirements.
    pub requirements: Requirements,
    /// Art slots.
    pub art: Art,
    /// Components.
    pub components: Vec<Component>,
    /// How to run it.
    pub run: Run,
    /// What it may do.
    pub permissions: Permissions,
    /// Saves and cache.
    pub data: DataPaths,
    /// Update feed.
    pub update: Update,
}

/// Check the nesting depth of JSON text without parsing it. The top-level value is depth 1.
pub fn json_depth_exceeds(bytes: &[u8], max: usize) -> bool {
    let (mut depth, mut in_string, mut escaped) = (0usize, false, false);
    for &b in bytes {
        if in_string {
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                in_string = false;
            }
            continue;
        }
        match b {
            b'"' => in_string = true,
            b'{' | b'[' => {
                depth += 1;
                if depth > max {
                    return true;
                }
            }
            b'}' | b']' => depth = depth.saturating_sub(1),
            _ => {}
        }
    }
    false
}

/// True when `bytes` is a `play.json` whose `format` is a number of 2 or more: a package for a newer
/// console. Nothing else of such a package is checked (05 section 15).
pub fn is_future_format(bytes: &[u8]) -> bool {
    if bytes.len() as u64 > MAX_MANIFEST_BYTES || json_depth_exceeds(bytes, MAX_JSON_DEPTH) {
        return false;
    }
    let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(bytes) else {
        return false;
    };
    matches!(root.get("format"), Some(Value::Number(n))
        if n.as_f64().is_some_and(|f| f >= (SUPPORTED_FORMAT + 1) as f64))
}

/// Check an `id` and its `play.<id>` Flatpak form. `official` allows the reserved prefixes.
pub fn check_id(id: &str, official: bool) -> Result<(), (&'static str, String)> {
    let bad = |m: String| Err((codes::ID_INVALID, m));
    if id.len() > MAX_ID_BYTES {
        return bad(format!("The id is longer than {MAX_ID_BYTES} bytes."));
    }
    let elements: Vec<&str> = id.split('.').collect();
    if elements.len() < MIN_ID_ELEMENTS {
        return bad(format!("The id needs at least {MIN_ID_ELEMENTS} parts separated by dots, like com.example.game."));
    }
    for e in &elements {
        if e.is_empty() {
            return bad("The id has an empty part between dots.".into());
        }
        if e.as_bytes()[0].is_ascii_digit() {
            return bad(format!(
                "The id part {eq} starts with a digit.",
                eq = crate::problem::quote(e)
            ));
        }
        if !e
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        {
            return bad(format!(
                "The id part {eq} may only contain letters, digits, _ and -.",
                eq = crate::problem::quote(e)
            ));
        }
    }
    let last = elements.len() - 1;
    if let Some(e) = elements[..last].iter().find(|e| e.contains('-')) {
        return Err((
            codes::ID_FLATPAK_INVALID,
            format!("The id part {eq} has a - ; Flatpak ids allow - only in the last part (the app is installed as play.<id>).", eq = crate::problem::quote(e)),
        ));
    }
    if "play.".len() + id.len() > MAX_FLATPAK_ID_BYTES {
        return Err((
            codes::ID_FLATPAK_INVALID,
            format!("play.<id> is longer than {MAX_FLATPAK_ID_BYTES} bytes."),
        ));
    }
    if !official
        && ({
            let lower = id.to_ascii_lowercase();
            lower.starts_with("org.ruyaos.") || lower.starts_with("play.")
        })
    {
        return Err((
            codes::ID_RESERVED,
            "Ids starting with org.ruyaos. or play. are reserved for RuyaOS.".into(),
        ));
    }
    Ok(())
}

/// True when the `run.env` variable name `name` is one the platform owns (05 §6.3).
pub fn env_name_denied(name: &str) -> bool {
    ENV_DENY_EXACT.contains(&name) || ENV_DENY_PREFIX.iter().any(|p| name.starts_with(p))
}

fn env_name_grammar(name: &str) -> bool {
    let b = name.as_bytes();
    !b.is_empty()
        && b.len() <= MAX_ENV_NAME_BYTES
        && b[0].is_ascii_uppercase()
        && b.iter()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || *c == b'_')
}

fn is_local_id(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= MAX_LOCAL_ID_BYTES
        && b[0].is_ascii_lowercase()
        && b.iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_' || *c == b'-')
}

pub(crate) fn is_version_text(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= MAX_COMPONENT_VERSION_BYTES
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'+' | b'-'))
}

pub(crate) fn is_spdx_like(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= MAX_LICENCE_BYTES
        && s.bytes().all(|c| {
            c.is_ascii_alphanumeric() || matches!(c, b'.' | b'+' | b'-' | b'(' | b')' | b' ' | b':')
        })
}

fn is_date(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return false;
    }
    let digits = |r: std::ops::Range<usize>| b[r].iter().all(u8::is_ascii_digit);
    if !(digits(0..4) && digits(5..7) && digits(8..10)) {
        return false;
    }
    let month: u32 = s[5..7].parse().unwrap_or(0);
    let day: u32 = s[8..10].parse().unwrap_or(0);
    (1..=12).contains(&month) && (1..=31).contains(&day)
}

/// The Wine/runner family each `run.runner` needs of its component.
fn runner_component_type(runner: &str) -> Option<&'static str> {
    match runner {
        "wine" => Some("wine"),
        "proton" => Some("proton"),
        "emulator" => Some("emulator"),
        "engine" => Some("engine"),
        _ => None,
    }
}

struct Checker<'a> {
    p: &'a mut Problems,
    table: &'a TableIndex<'a>,
    entries: &'a [FileEntry],
    official: bool,
}

type Obj = Map<String, Value>;

impl<'a> Checker<'a> {
    fn obj<'v>(&mut self, v: &'v Value, at: &str) -> Option<&'v Obj> {
        match v.as_object() {
            Some(o) => Some(o),
            None => {
                self.p
                    .add(codes::MANIFEST_TYPE, at, "This must be an object.");
                None
            }
        }
    }

    fn required<'v>(&mut self, o: &'v Obj, key: &str, at: &str) -> Option<&'v Value> {
        let v = o.get(key);
        if v.is_none() {
            self.p.add(
                codes::MANIFEST_MISSING,
                pointer_join(at, key),
                format!("\"{key}\" is required."),
            );
        }
        v
    }

    fn strict_keys(&mut self, o: &Obj, allowed: &[&str], at: &str, code: &str, what: &str) {
        for k in o.keys() {
            if !allowed.contains(&k.as_str()) {
                self.p.add(
                    code,
                    pointer_join(at, k),
                    format!("{kq} is not a key of {what}; a key this console does not know is refused, not ignored.", kq = crate::problem::quote(k)),
                );
            }
        }
    }

    fn string<'v>(&mut self, v: &'v Value, at: &str) -> Option<&'v str> {
        match v.as_str() {
            Some(s) => Some(s),
            None => {
                self.p
                    .add(codes::MANIFEST_TYPE, at, "This must be a string.");
                None
            }
        }
    }

    fn array<'v>(&mut self, v: &'v Value, at: &str, max: usize) -> Option<&'v Vec<Value>> {
        let Some(a) = v.as_array() else {
            self.p.add(codes::MANIFEST_TYPE, at, "This must be a list.");
            return None;
        };
        if a.len() > max {
            self.p.add(
                codes::LIST_TOO_LONG,
                at,
                format!("The list has {} items; at most {max}.", a.len()),
            );
            return None;
        }
        Some(a)
    }

    fn boolean(&mut self, v: &Value, at: &str) -> Option<bool> {
        match v.as_bool() {
            Some(b) => Some(b),
            None => {
                self.p
                    .add(codes::MANIFEST_TYPE, at, "This must be true or false.");
                None
            }
        }
    }

    fn uint(&mut self, v: &Value, at: &str, min: u64, max: u64) -> Option<u64> {
        let Some(n) = v.as_u64() else {
            self.p.add(
                codes::MANIFEST_TYPE,
                at,
                "This must be a whole number, zero or more.",
            );
            return None;
        };
        if n < min || n > max {
            self.p.add(
                codes::VALUE_RANGE,
                at,
                format!("The number must be between {min} and {max}."),
            );
            return None;
        }
        Some(n)
    }

    fn vocab(&mut self, v: &Value, at: &str, allowed: &[&str]) -> Option<String> {
        let s = self.string(v, at)?;
        if allowed.contains(&s) {
            Some(s.to_string())
        } else {
            self.p.add(
                codes::VALUE_UNKNOWN,
                at,
                format!(
                    "{sq} is not one of: {}.",
                    allowed.join(", "),
                    sq = crate::problem::quote(s)
                ),
            );
            None
        }
    }

    fn text(&mut self, v: &Value, at: &str, max: usize, multiline: bool) -> Option<String> {
        let s = self.string(v, at)?;
        if let Err((code, msg)) = check_chars(s, max).and_then(|_| check_plain(s, multiline)) {
            self.p.add(code, at, msg);
            return None;
        }
        Some(s.to_string())
    }

    fn url(&mut self, v: &Value, at: &str) -> Option<String> {
        let s = self.string(v, at)?;
        match check_https_url(s) {
            Ok(()) => Some(s.to_string()),
            Err((code, msg)) => {
                self.p.add(code, at, msg);
                None
            }
        }
    }

    fn localized(&mut self, v: &Value, at: &str, max: usize, multiline: bool) -> Option<Localized> {
        let o = self.obj(v, at)?;
        if o.len() > MAX_LANGUAGES {
            self.p.add(
                codes::LANG_TOO_MANY,
                at,
                format!("At most {MAX_LANGUAGES} languages."),
            );
            return None;
        }
        let mut out = Localized::new();
        let mut ok = true;
        for (lang, val) in o {
            let here = pointer_join(at, lang);
            if !is_language_tag(lang) {
                self.p.add(
                    codes::LANG_INVALID,
                    &here,
                    format!(
                        "{langq} is not a language tag like en or pt-BR.",
                        langq = crate::problem::quote(lang)
                    ),
                );
                ok = false;
                continue;
            }
            match self.text(val, &here, max, multiline) {
                Some(t) => {
                    out.insert(lang.clone(), t);
                }
                None => ok = false,
            }
        }
        if !self.case_distinct(o.keys(), at) {
            ok = false;
        }
        if !o.contains_key("en") {
            self.p.add(
                codes::LANG_MISSING_EN,
                at,
                "An English (\"en\") text is required.",
            );
            ok = false;
        }
        ok.then_some(out)
    }

    fn string_list(
        &mut self,
        v: &Value,
        at: &str,
        max: usize,
        f: &mut dyn FnMut(&mut Self, &Value, &str) -> Option<String>,
    ) -> Vec<String> {
        let mut out = Vec::new();
        if let Some(a) = self.array(v, at, max) {
            for (i, item) in a.iter().enumerate() {
                if let Some(s) = f(self, item, &format!("{at}/{i}")) {
                    out.push(s);
                }
            }
        }
        out
    }

    /// Language tags are the same tag when they differ only in case (`EN` and `en`).
    fn case_distinct<'k>(&mut self, keys: impl Iterator<Item = &'k String>, at: &str) -> bool {
        let mut seen = BTreeSet::new();
        let mut ok = true;
        for k in keys {
            if !seen.insert(k.to_ascii_lowercase()) {
                self.p.add(
                    codes::LIST_DUPLICATE,
                    pointer_join(at, k),
                    format!(
                        "The language tag {} repeats another that differs only in letter case.",
                        crate::problem::quote(k)
                    ),
                );
                ok = false;
            }
        }
        ok
    }

    fn no_duplicates(&mut self, items: &[String], at: &str, code: &str) {
        let mut seen = BTreeSet::new();
        for s in items {
            if !seen.insert(s) {
                self.p.add(
                    code,
                    at,
                    format!("{sq} appears twice.", sq = crate::problem::quote(s)),
                );
            }
        }
    }

    /// A package path that must exist in the table as a file, under `must_start`.
    fn file_path(
        &mut self,
        v: &Value,
        at: &str,
        must_start: &str,
        exts: &[&str],
        code_path: &str,
        code_missing: &str,
    ) -> Option<String> {
        let s = self.string(v, at)?;
        if let Err((_, msg)) = check_path(s) {
            self.p.add(code_path, at, msg);
            return None;
        }
        if !s.starts_with(must_start) {
            self.p.add(
                code_path,
                at,
                format!("The file must be inside {must_start}."),
            );
            return None;
        }
        if !exts.is_empty() {
            let ext = s.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
            if !s.contains('.') || !exts.contains(&ext.as_str()) {
                self.p.add(
                    codes::ART_EXTENSION,
                    at,
                    format!("The file must be one of: {}.", exts.join(", ")),
                );
                return None;
            }
        }
        if !self.table.is_file(s) {
            self.p.add(
                code_missing,
                at,
                format!("{sq} is not in play.files.", sq = crate::problem::quote(s)),
            );
            return None;
        }
        Some(s.to_string())
    }

    fn credit(&mut self, v: &Value, at: &str) -> Option<Credit> {
        let o = self.obj(v, at)?;
        let name = match o.get("name") {
            Some(n) => self.text(n, &pointer_join(at, "name"), MAX_CREDIT_NAME_CHARS, false),
            None => {
                self.required(o, "name", at);
                None
            }
        };
        let url = o
            .get("url")
            .and_then(|u| self.url(u, &pointer_join(at, "url")));
        Some(Credit { name: name?, url })
    }

    // ----- sections ---------------------------------------------------------------------------

    fn identity(&mut self, o: &Obj) -> Option<(String, Localized, String, u64)> {
        let id = self.required(o, "id", "").and_then(|v| {
            let s = self.string(v, "/id")?;
            match check_id(s, self.official) {
                Ok(()) => Some(s.to_string()),
                Err((code, msg)) => {
                    self.p.add(code, "/id", msg);
                    None
                }
            }
        });
        let name = self.required(o, "name", "").and_then(|v| {
            let n = self.localized(v, "/name", MAX_NAME_CHARS, false)?;
            if !self.official {
                for (lang, text) in &n {
                    if is_reserved_app_name(text) {
                        self.p.add(
                            codes::NAME_RESERVED,
                            pointer_join("/name", lang),
                            format!(
                                "{textq} looks like a RuyaOS system name; pick another name.",
                                textq = crate::problem::quote(text)
                            ),
                        );
                        return None;
                    }
                }
            }
            Some(n)
        });
        let version = self
            .required(o, "version", "")
            .and_then(|v| self.text(v, "/version", MAX_VERSION_CHARS, false));
        let build = self
            .required(o, "build", "")
            .and_then(|v| self.uint(v, "/build", 1, 1 << 53));
        Some((id?, name?, version?, build?))
    }

    fn descriptive(&mut self, o: &Obj, m: &mut PartialManifest) {
        m.summary = o
            .get("summary")
            .and_then(|v| self.localized(v, "/summary", MAX_SUMMARY_CHARS, false));
        m.description = o
            .get("description")
            .and_then(|v| self.localized(v, "/description", MAX_DESCRIPTION_CHARS, true));
        m.developer = o
            .get("developer")
            .and_then(|v| self.credit(v, "/developer"));
        m.publisher = o
            .get("publisher")
            .and_then(|v| self.credit(v, "/publisher"));
        if let Some(v) = o.get("release_date") {
            if let Some(s) = self.string(v, "/release_date") {
                if is_date(s) {
                    m.release_date = Some(s.to_string());
                } else {
                    self.p.add(
                        codes::VALUE_RANGE,
                        "/release_date",
                        "The date is written YYYY-MM-DD.",
                    );
                }
            }
        }
        if let Some(v) = o.get("genres") {
            m.genres = self.string_list(v, "/genres", MAX_GENRES, &mut |s, item, at| {
                s.vocab(item, at, &GENRES)
            });
            let g = m.genres.clone();
            self.no_duplicates(&g, "/genres", codes::LIST_DUPLICATE);
        }
        if let Some(v) = o.get("tags") {
            m.tags = self.string_list(v, "/tags", MAX_TAGS, &mut |s, item, at| {
                s.text(item, at, MAX_TAG_CHARS, false)
            });
        }
        if let Some(v) = o.get("languages") {
            m.languages = self.string_list(v, "/languages", MAX_LANGUAGES, &mut |s, item, at| {
                let t = s.string(item, at)?;
                if is_language_tag(t) {
                    Some(t.to_string())
                } else {
                    s.p.add(
                        codes::LANG_INVALID,
                        at,
                        format!(
                            "{tq} is not a language tag like en or pt-BR.",
                            tq = crate::problem::quote(t)
                        ),
                    );
                    None
                }
            });
        }
        if let Some(v) = o.get("players") {
            m.players = self.players(v);
        }
        if let Some(v) = o.get("controller") {
            m.controller = self.vocab(v, "/controller", &CONTROLLER);
        }
        if let Some(v) = o.get("age_rating") {
            m.age_rating = self.age_rating(v);
        }
        if let Some(v) = o.get("licence") {
            if let Some(l) = self.obj(v, "/licence") {
                if let Some(p) = l.get("package") {
                    if let Some(s) = self.string(p, "/licence/package") {
                        if is_spdx_like(s) {
                            m.licence = Some(s.to_string());
                        } else {
                            self.p.add(
                                codes::VALUE_UNKNOWN,
                                "/licence/package",
                                "Write an SPDX licence id or LicenseRef-proprietary.",
                            );
                        }
                    }
                }
                m.terms_url = l
                    .get("terms_url")
                    .and_then(|u| self.url(u, "/licence/terms_url"));
            }
        }
        if let Some(v) = o.get("links") {
            if let Some(a) = self.array(v, "/links", MAX_LINKS) {
                for (i, item) in a.iter().enumerate() {
                    let at = format!("/links/{i}");
                    let Some(l) = self.obj(item, &at) else {
                        continue;
                    };
                    let kind = self
                        .required(l, "kind", &at)
                        .and_then(|k| self.vocab(k, &format!("{at}/kind"), &LINK_KINDS));
                    let url = self
                        .required(l, "url", &at)
                        .and_then(|u| self.url(u, &format!("{at}/url")));
                    if let (Some(kind), Some(url)) = (kind, url) {
                        m.links.push(Link { kind, url });
                    }
                }
            }
        }
        if let Some(v) = o.get("requirements") {
            if let Some(r) = self.obj(v, "/requirements") {
                if let Some(a) = r.get("arch") {
                    if let Some(s) = self.string(a, "/requirements/arch") {
                        if s == "x86_64" {
                            m.requirements.arch = Some(s.to_string());
                        } else {
                            self.p.add(
                                codes::REQUIREMENTS_ARCH,
                                "/requirements/arch",
                                format!(
                                    "{sq} is not supported; version 1 runs x86_64 only.",
                                    sq = crate::problem::quote(s)
                                ),
                            );
                        }
                    }
                }
                m.requirements.min_ram_mb = r
                    .get("min_ram_mb")
                    .and_then(|n| self.uint(n, "/requirements/min_ram_mb", 1, 1 << 20));
                if let Some(g) = r.get("gpu_api") {
                    m.requirements.gpu_api = self.string_list(
                        g,
                        "/requirements/gpu_api",
                        GPU_APIS.len(),
                        &mut |s, item, at| s.vocab(item, at, &GPU_APIS),
                    );
                }
            }
        }
        if let Some(v) = o.get("data") {
            if let Some(d) = self.obj(v, "/data") {
                if let Some(s) = d.get("saves") {
                    m.data.saves =
                        self.string_list(s, "/data/saves", MAX_DATA_PATHS, &mut |s, item, at| {
                            s.data_path(item, at)
                        });
                }
                if let Some(c) = d.get("cache") {
                    m.data.cache =
                        self.string_list(c, "/data/cache", MAX_DATA_PATHS, &mut |s, item, at| {
                            s.data_path(item, at)
                        });
                }
            }
        }
        if let Some(v) = o.get("update") {
            if let Some(u) = self.obj(v, "/update") {
                m.update.feed = u.get("feed").and_then(|f| self.url(f, "/update/feed"));
                if let Some(c) = u.get("channel") {
                    if let Some(s) = self.string(c, "/update/channel") {
                        if !s.is_empty()
                            && s.len() <= 32
                            && s.bytes().all(|b| {
                                b.is_ascii_lowercase()
                                    || b.is_ascii_digit()
                                    || matches!(b, b'.' | b'_' | b'-')
                            })
                        {
                            m.update.channel = Some(s.to_string());
                        } else {
                            self.p.add(
                                codes::VALUE_UNKNOWN,
                                "/update/channel",
                                "A channel is 1 to 32 characters of a-z, 0-9, . _ -.",
                            );
                        }
                    }
                }
            }
        }
    }

    fn data_path(&mut self, v: &Value, at: &str) -> Option<String> {
        let s = self.string(v, at)?;
        let rest = ["prefix:", "data:", "config:"]
            .iter()
            .find_map(|p| s.strip_prefix(p));
        let ok = rest.is_some_and(|r| {
            !r.is_empty()
                && r.len() <= MAX_PATH_BYTES
                && !r.starts_with('/')
                && !r.contains('\\')
                && !r.chars().any(char::is_control)
                && r.split('/').all(|c| !c.is_empty() && c != "." && c != "..")
        });
        if ok {
            Some(s.to_string())
        } else {
            self.p.add(
                codes::DATA_PATH,
                at,
                "Write the path as prefix:..., data:... or config:... followed by a relative path.",
            );
            None
        }
    }

    fn players(&mut self, v: &Value) -> Option<Players> {
        let o = self.obj(v, "/players")?;
        let min = o
            .get("min")
            .and_then(|n| self.uint(n, "/players/min", 1, MAX_PLAYERS));
        let max = o
            .get("max")
            .and_then(|n| self.uint(n, "/players/max", 1, MAX_PLAYERS));
        let modes = o
            .get("modes")
            .map(|m| {
                self.string_list(
                    m,
                    "/players/modes",
                    PLAYER_MODES.len(),
                    &mut |s, item, at| s.vocab(item, at, &PLAYER_MODES),
                )
            })
            .unwrap_or_default();
        self.no_duplicates(&modes, "/players/modes", codes::LIST_DUPLICATE);
        let (min, max) = (min?, max?);
        if min > max {
            self.p.add(
                codes::VALUE_RANGE,
                "/players/min",
                "min must not be more than max.",
            );
            return None;
        }
        Some(Players { min, max, modes })
    }

    fn age_rating(&mut self, v: &Value) -> Option<AgeRating> {
        let o = self.obj(v, "/age_rating")?;
        let scheme = self
            .required(o, "scheme", "/age_rating")
            .and_then(|s| self.vocab(s, "/age_rating/scheme", &["oars-1.1"]));
        let mut content = BTreeMap::new();
        if let Some(c) = o.get("content") {
            if let Some(co) = self.obj(c, "/age_rating/content") {
                if co.len() > MAX_AGE_ATTRIBUTES {
                    self.p.add(
                        codes::LIST_TOO_LONG,
                        "/age_rating/content",
                        format!("At most {MAX_AGE_ATTRIBUTES} attributes."),
                    );
                }
                for (k, val) in co {
                    let at = pointer_join("/age_rating/content", k);
                    if k.is_empty()
                        || k.len() > 40
                        || !k
                            .bytes()
                            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
                    {
                        self.p.add(
                            codes::VALUE_UNKNOWN,
                            &at,
                            "OARS attribute ids are lower-case letters, digits and -.",
                        );
                        continue;
                    }
                    if let Some(level) = self.vocab(val, &at, &OARS_VALUES) {
                        content.insert(k.clone(), level);
                    }
                }
            }
        }
        Some(AgeRating {
            scheme: scheme?,
            content,
        })
    }

    fn art(&mut self, o: &Obj) -> Option<Art> {
        let at = "/art";
        let a = match o.get("art") {
            Some(v) => self.obj(v, at)?,
            None => {
                self.p.add(
                    codes::MANIFEST_MISSING,
                    at,
                    "\"art\" with an \"icon\" is required.",
                );
                return None;
            }
        };
        const IMG_SMALL: [&str; 2] = ["png", "webp"];
        const IMG: [&str; 4] = ["webp", "jpg", "jpeg", "png"];
        const VIDEO: [&str; 2] = ["webm", "mp4"];
        let icon = self.required(a, "icon", at).and_then(|v| {
            self.file_path(
                v,
                "/art/icon",
                "art/",
                &IMG_SMALL,
                codes::ART_PATH,
                codes::ART_MISSING,
            )
        });
        let logo = a.get("logo").and_then(|v| match v {
            Value::String(_) => self
                .file_path(
                    v,
                    "/art/logo",
                    "art/",
                    &IMG_SMALL,
                    codes::ART_PATH,
                    codes::ART_MISSING,
                )
                .map(ArtPath::One),
            Value::Object(map) => {
                let mut out = BTreeMap::new();
                if map.len() > MAX_LANGUAGES {
                    self.p.add(
                        codes::LANG_TOO_MANY,
                        "/art/logo",
                        format!("At most {MAX_LANGUAGES} languages."),
                    );
                    return None;
                }
                let _ = self.case_distinct(map.keys(), "/art/logo");
                for (lang, p) in map {
                    let here = pointer_join("/art/logo", lang);
                    if !is_language_tag(lang) {
                        self.p.add(
                            codes::LANG_INVALID,
                            &here,
                            format!(
                                "{langq} is not a language tag.",
                                langq = crate::problem::quote(lang)
                            ),
                        );
                        continue;
                    }
                    if let Some(s) = self.file_path(
                        p,
                        &here,
                        "art/",
                        &IMG_SMALL,
                        codes::ART_PATH,
                        codes::ART_MISSING,
                    ) {
                        out.insert(lang.clone(), s);
                    }
                }
                Some(ArtPath::PerLanguage(out))
            }
            _ => {
                self.p.add(
                    codes::MANIFEST_TYPE,
                    "/art/logo",
                    "This must be a file path or a map of language to file path.",
                );
                None
            }
        });
        let hero = a.get("hero").and_then(|v| {
            self.file_path(
                v,
                "/art/hero",
                "art/",
                &IMG,
                codes::ART_PATH,
                codes::ART_MISSING,
            )
        });
        let cover = a.get("cover").and_then(|v| {
            self.file_path(
                v,
                "/art/cover",
                "art/",
                &IMG,
                codes::ART_PATH,
                codes::ART_MISSING,
            )
        });
        let preview = a.get("preview").and_then(|v| {
            self.file_path(
                v,
                "/art/preview",
                "art/",
                &VIDEO,
                codes::ART_PATH,
                codes::ART_MISSING,
            )
        });
        let mut screenshots = Vec::new();
        if let Some(v) = a.get("screenshots") {
            if let Some(list) = self.array(v, "/art/screenshots", MAX_SCREENSHOTS) {
                if list.is_empty() {
                    self.p.add(
                        codes::ART_NO_SCREENSHOTS,
                        "/art/screenshots",
                        "Give at least one screenshot, or leave the list out.",
                    );
                }
                for (i, item) in list.iter().enumerate() {
                    let here = format!("/art/screenshots/{i}");
                    let Some(s) = self.obj(item, &here) else {
                        continue;
                    };
                    let file = self.required(s, "file", &here).and_then(|f| {
                        self.file_path(
                            f,
                            &format!("{here}/file"),
                            "art/",
                            &IMG,
                            codes::ART_PATH,
                            codes::ART_MISSING,
                        )
                    });
                    let caption = s.get("caption").and_then(|c| {
                        self.localized(c, &format!("{here}/caption"), MAX_CAPTION_CHARS, false)
                    });
                    if let Some(file) = file {
                        screenshots.push(Screenshot { file, caption });
                    }
                }
            }
        }
        let trailer = a.get("trailer").and_then(|v| {
            let t = self.obj(v, "/art/trailer")?;
            let file = self.required(t, "file", "/art/trailer").and_then(|f| {
                self.file_path(
                    f,
                    "/art/trailer/file",
                    "art/",
                    &VIDEO,
                    codes::ART_PATH,
                    codes::ART_MISSING,
                )
            })?;
            let poster = t.get("poster").and_then(|p| {
                self.file_path(
                    p,
                    "/art/trailer/poster",
                    "art/",
                    &IMG,
                    codes::ART_PATH,
                    codes::ART_MISSING,
                )
            });
            Some(Trailer { file, poster })
        });
        Some(Art {
            icon: icon?,
            logo,
            hero,
            cover,
            screenshots,
            trailer,
            preview,
        })
    }

    fn components(&mut self, o: &Obj) -> Vec<Component> {
        let mut out: Vec<Component> = Vec::new();
        let Some(v) = o.get("components") else {
            return out;
        };
        let Some(list) = self.array(v, "/components", MAX_COMPONENTS) else {
            return out;
        };
        for (i, item) in list.iter().enumerate() {
            let at = format!("/components/{i}");
            let Some(c) = self.obj(item, &at) else {
                continue;
            };
            self.strict_keys(
                c,
                &COMPONENT_KEYS,
                &at,
                codes::COMPONENT_UNKNOWN_KEY,
                "a component",
            );
            let id = self.required(c, "id", &at).and_then(|v| {
                let s = self.string(v, &format!("{at}/id"))?;
                if is_local_id(s) {
                    Some(s.to_string())
                } else {
                    self.p.add(codes::VALUE_UNKNOWN, format!("{at}/id"), "A component id is a-z, 0-9, _ and -, starting with a letter, at most 32 characters.");
                    None
                }
            });
            let kind = self
                .required(c, "type", &at)
                .and_then(|v| self.vocab(v, &format!("{at}/type"), &COMPONENT_TYPES));
            let source = self
                .required(c, "source", &at)
                .and_then(|v| self.vocab(v, &format!("{at}/source"), &COMPONENT_SOURCES));
            let version = |s: &mut Self, key: &str| -> Option<String> {
                let v = c.get(key)?;
                let t = s.string(v, &format!("{at}/{key}"))?;
                if is_version_text(t) {
                    Some(t.to_string())
                } else {
                    s.p.add(
                        codes::VALUE_UNKNOWN,
                        format!("{at}/{key}"),
                        "A version is letters, digits and . _ + -, at most 32 characters.",
                    );
                    None
                }
            };
            let min = version(self, "min");
            let tested = version(self, "tested");
            let max_major = c
                .get("max_major")
                .and_then(|n| self.uint(n, &format!("{at}/max_major"), 0, 100_000));
            let bundled = c
                .get("bundled")
                .and_then(|b| self.bundled(b, &format!("{at}/bundled")));
            if let Some(src) = &source {
                if matches!(src.as_str(), "system" | "prefer-system" | "newest")
                    && min.is_none()
                    && c.get("min").is_none()
                {
                    self.p.add(
                        codes::COMPONENT_MISSING_FIELD,
                        &at,
                        format!(
                            "Source \"{src}\" needs \"min\", the least system version that works."
                        ),
                    );
                }
                if matches!(
                    src.as_str(),
                    "bundled" | "prefer-system" | "prefer-bundled" | "newest"
                ) && c.get("bundled").is_none()
                {
                    self.p.add(
                        codes::COMPONENT_MISSING_FIELD,
                        &at,
                        format!("Source \"{src}\" needs a \"bundled\" copy."),
                    );
                }
            }
            if let Some(id) = &id {
                if out.iter().any(|x| &x.id == id) {
                    self.p.add(
                        codes::COMPONENT_DUPLICATE,
                        format!("{at}/id"),
                        format!(
                            "There are two components with id {idq}.",
                            idq = crate::problem::quote(id)
                        ),
                    );
                }
            }
            if let (Some(id), Some(kind), Some(source)) = (id, kind, source) {
                out.push(Component {
                    id,
                    kind,
                    source,
                    min,
                    tested,
                    max_major,
                    bundled,
                });
            }
        }
        out
    }

    fn bundled(&mut self, v: &Value, at: &str) -> Option<Bundled> {
        let b = self.obj(v, at)?;
        self.strict_keys(
            b,
            &BUNDLED_KEYS,
            at,
            codes::COMPONENT_UNKNOWN_KEY,
            "a bundled runner",
        );
        let path = self.required(b, "path", at).and_then(|p| {
            let here = format!("{at}/path");
            let s = self.string(p, &here)?;
            if check_path(s).is_err() || !s.starts_with("components/") {
                self.p.add(
                    codes::COMPONENT_PATH,
                    &here,
                    "The path must be a folder inside components/.",
                );
                return None;
            }
            if !self.table.is_dir(s) {
                self.p.add(
                    codes::COMPONENT_BUNDLED_MISSING,
                    &here,
                    format!(
                        "The folder {sq} is not in play.files.",
                        sq = crate::problem::quote(s)
                    ),
                );
                return None;
            }
            Some(s.to_string())
        });
        let version = self.required(b, "version", at).and_then(|x| {
            let s = self.string(x, &format!("{at}/version"))?;
            if is_version_text(s) {
                Some(s.to_string())
            } else {
                self.p.add(
                    codes::VALUE_UNKNOWN,
                    format!("{at}/version"),
                    "A version is letters, digits and . _ + -, at most 32 characters.",
                );
                None
            }
        });
        let licence = self.required(b, "licence", at).and_then(|x| {
            let s = self.string(x, &format!("{at}/licence"))?;
            if is_spdx_like(s) {
                Some(s.to_string())
            } else {
                self.p.add(
                    codes::VALUE_UNKNOWN,
                    format!("{at}/licence"),
                    "Write an SPDX licence id.",
                );
                None
            }
        });
        let source_url = b
            .get("source_url")
            .and_then(|u| self.url(u, &format!("{at}/source_url")));
        Some(Bundled {
            path: path?,
            version: version?,
            licence: licence?,
            source_url,
        })
    }

    fn permissions(&mut self, o: &Obj) -> Permissions {
        let mut out = Permissions::default();
        let Some(v) = o.get("permissions") else {
            return out;
        };
        let Some(p) = self.obj(v, "/permissions") else {
            return out;
        };
        self.strict_keys(
            p,
            &PERMISSION_KEYS,
            "/permissions",
            codes::PERMISSIONS_UNKNOWN_KEY,
            "permissions",
        );
        for key in BOOL_PERMISSIONS {
            if let Some(v) = p.get(key) {
                if let Some(b) = self.boolean(v, &format!("/permissions/{key}")) {
                    match key {
                        "network" => out.network = b,
                        "multiarch" => out.multiarch = b,
                        "gamemode" => out.gamemode = b,
                        "realtime" => out.realtime = b,
                        _ => out.devel = b,
                    }
                }
            }
        }
        if let Some(v) = p.get("input") {
            if let Some(s) = self.vocab(v, "/permissions/input", &INPUT_MODES) {
                out.input = s;
            }
        }
        if let Some(v) = p.get("removable_media") {
            if let Some(s) = self.vocab(v, "/permissions/removable_media", &REMOVABLE_MEDIA) {
                out.removable_media = s;
            }
        }
        if let Some(v) = p.get("reasons") {
            if let Some(r) = self.obj(v, "/permissions/reasons") {
                for (k, val) in r {
                    let at = pointer_join("/permissions/reasons", k);
                    if !PERMISSION_KEYS.contains(&k.as_str()) || k == "reasons" {
                        self.p.add(codes::PERMISSIONS_REASON_KEY, &at, format!("{kq} is not a permission, so there is nothing to give a reason for.", kq = crate::problem::quote(k)));
                        continue;
                    }
                    if let Some(t) = self.localized(val, &at, MAX_REASON_CHARS, false) {
                        out.reasons.insert(k.clone(), t);
                    }
                }
            }
        }
        out
    }

    fn command(&mut self, v: &Value, at: &str) -> Option<Vec<String>> {
        let a = self.array(v, at, MAX_COMMAND_ARGS)?;
        if a.is_empty() {
            self.p.add(
                codes::TEXT_EMPTY,
                at,
                "The command needs at least the program to run.",
            );
            return None;
        }
        let mut out = Vec::new();
        let mut ok = true;
        for (i, item) in a.iter().enumerate() {
            let here = format!("{at}/{i}");
            let Some(s) = self.string(item, &here) else {
                ok = false;
                continue;
            };
            if s.len() > MAX_ARG_BYTES {
                self.p.add(
                    codes::TEXT_TOO_LONG,
                    &here,
                    format!("An argument is at most {MAX_ARG_BYTES} bytes."),
                );
                ok = false;
            } else if s.chars().any(char::is_control) {
                self.p.add(
                    codes::TEXT_CONTROL,
                    &here,
                    "An argument contains a control character.",
                );
                ok = false;
            } else if i == 0 && s.is_empty() {
                self.p
                    .add(codes::TEXT_EMPTY, &here, "The program to run is empty.");
                ok = false;
            } else {
                out.push(s.to_string());
            }
        }
        ok.then_some(out)
    }

    /// Check the placeholders in `s`, and that the program path exists when `program` is set.
    fn placeholders(&mut self, s: &str, at: &str, components: &[Component], has_discs: bool) {
        let mut rest = s;
        while let Some(i) = rest.find("${") {
            let after = &rest[i + 2..];
            let Some(end) = after.find('}') else { break };
            let name = &after[..end];
            if name == "disc" && !has_discs {
                self.p.add(
                    codes::RUN_DISC_PLACEHOLDER_WITHOUT_DISCS,
                    at,
                    "${disc} is used but run.discs is missing.",
                );
            } else if let Some(id) = name.strip_prefix("component:") {
                if !components.iter().any(|c| c.id == id) {
                    self.p.add(
                        codes::RUN_PLACEHOLDER_COMPONENT,
                        at,
                        format!(
                            "${{component:{idq}}} names a component that is not declared.",
                            idq = crate::problem::quote(id)
                        ),
                    );
                }
            }
            rest = &after[end + 1..];
        }
    }

    /// A `${placeholder}/...` argument has no `..` part (the same rule as `data.*`).
    fn argument_path(&mut self, arg: &str, at: &str) {
        let rest = arg
            .strip_prefix("${")
            .and_then(|t| t.split_once('}'))
            .map(|(_, r)| r);
        if rest.is_some_and(|r| r.split('/').any(|c| c == "..")) {
            self.p.add(
                codes::RUN_ARGUMENT_PATH,
                at,
                "A path that starts with a ${...} placeholder has no .. part.",
            );
        }
    }

    fn program_exists(&mut self, arg: &str, at: &str) {
        if let Some(rel) = arg.strip_prefix("${payload}/") {
            let full = format!("payload/{rel}");
            if !self.table.is_file(&full)
                && !matches!(self.table.get(&full), Some(FileEntry::Link { .. }))
            {
                self.p.add(
                    codes::RUN_COMMAND_MISSING,
                    at,
                    format!(
                        "The program {fullq} is not in play.files.",
                        fullq = crate::problem::quote(&full)
                    ),
                );
            }
        }
    }

    fn env(&mut self, v: &Value) -> BTreeMap<String, String> {
        let mut out = BTreeMap::new();
        let Some(e) = self.obj(v, "/run/env") else {
            return out;
        };
        if e.len() > MAX_ENV_ENTRIES {
            self.p.add(
                codes::LIST_TOO_LONG,
                "/run/env",
                format!("At most {MAX_ENV_ENTRIES} variables."),
            );
            return out;
        }
        for (k, val) in e {
            let at = pointer_join("/run/env", k);
            if !env_name_grammar(k) {
                self.p.add(codes::ENV_BAD_NAME, &at, format!("{kq} is not a variable name: use capital letters, digits and _, starting with a letter.", kq = crate::problem::quote(k)));
                continue;
            }
            if env_name_denied(k) {
                self.p.add(
                    codes::ENV_RESERVED,
                    &at,
                    format!(
                        "{kq} is set by the platform and cannot be set by a package.",
                        kq = crate::problem::quote(k)
                    ),
                );
                continue;
            }
            let Some(s) = self.string(val, &at) else {
                continue;
            };
            if s.len() > MAX_ENV_VALUE_BYTES || s.chars().any(char::is_control) {
                self.p.add(
                    codes::ENV_BAD_VALUE,
                    &at,
                    format!("A value is plain text of at most {MAX_ENV_VALUE_BYTES} bytes."),
                );
                continue;
            }
            out.insert(k.clone(), s.to_string());
        }
        out
    }

    fn prefix(&mut self, v: &Value) -> Option<Prefix> {
        let p = self.obj(v, "/run/prefix")?;
        self.strict_keys(
            p,
            &PREFIX_KEYS,
            "/run/prefix",
            codes::RUN_UNKNOWN_KEY,
            "run.prefix",
        );
        let arch = p
            .get("arch")
            .and_then(|a| self.vocab(a, "/run/prefix/arch", &PREFIX_ARCHES));
        let epoch = p
            .get("epoch")
            .and_then(|e| self.uint(e, "/run/prefix/epoch", 0, 1 << 31))
            .unwrap_or(0);
        let template = p.get("template").and_then(|t| {
            let s = self.string(t, "/run/prefix/template")?;
            if let Err((_, msg)) = check_path(s) {
                self.p
                    .add(codes::PREFIX_TEMPLATE_MISSING, "/run/prefix/template", msg);
                return None;
            }
            if !self.table.is_dir(s) {
                self.p.add(
                    codes::PREFIX_TEMPLATE_MISSING,
                    "/run/prefix/template",
                    format!(
                        "The folder {sq} is not in play.files.",
                        sq = crate::problem::quote(s)
                    ),
                );
                return None;
            }
            let under = format!("{s}/");
            for e in self.entries {
                if let Some(rest) = e.path().strip_prefix(&under) {
                    if rest
                        .split('/')
                        .any(|c| c.eq_ignore_ascii_case("dosdevices"))
                    {
                        self.p.add(
                            codes::PREFIX_DOSDEVICES,
                            e.path(),
                            "A prefix template never contains dosdevices; the launcher creates it.",
                        );
                        return None;
                    }
                }
            }
            Some(s.to_string())
        });
        Some(Prefix {
            arch,
            template,
            epoch,
        })
    }

    fn run(&mut self, o: &Obj, components: &[Component]) -> Option<Run> {
        let r = match o.get("run") {
            Some(v) => self.obj(v, "/run")?,
            None => {
                self.p.add(
                    codes::MANIFEST_MISSING,
                    "/run",
                    "\"run\" is required: a package has exactly one way to start.",
                );
                return None;
            }
        };
        self.strict_keys(r, &RUN_KEYS, "/run", codes::RUN_UNKNOWN_KEY, "run");
        let runner = self
            .required(r, "runner", "/run")
            .and_then(|v| self.vocab(v, "/run/runner", &RUNNERS));
        let component = r
            .get("component")
            .and_then(|v| self.string(v, "/run/component").map(str::to_string));
        if let Some(runner) = &runner {
            match (runner_component_type(runner), &component) {
                (None, Some(_)) => self.p.add(
                    codes::RUN_COMPONENT_UNEXPECTED,
                    "/run/component",
                    "A native program has no runner component.",
                ),
                (Some(_), None) => self.p.add(
                    codes::RUN_COMPONENT_MISSING,
                    "/run",
                    format!(
                        "Runner \"{runner}\" needs \"component\", the id of a components entry."
                    ),
                ),
                (Some(want), Some(id)) => match components.iter().find(|c| &c.id == id) {
                    None => self.p.add(
                        codes::RUN_COMPONENT_UNKNOWN,
                        "/run/component",
                        format!(
                            "There is no component {idq}.",
                            idq = crate::problem::quote(id)
                        ),
                    ),
                    Some(c) if c.kind != want => self.p.add(
                        codes::RUN_COMPONENT_TYPE,
                        "/run/component",
                        format!(
                            "Runner \"{runner}\" needs a component of type \"{want}\", not \"{}\".",
                            c.kind
                        ),
                    ),
                    Some(_) => {}
                },
                (None, None) => {}
            }
        }
        // Discs first: the placeholder checks need to know whether there are any.
        let mut discs: Vec<String> = Vec::new();
        if let Some(v) = r.get("discs") {
            discs = self.string_list(v, "/run/discs", MAX_DISCS, &mut |s, item, at| {
                let p = s.string(item, at)?;
                if check_path(p).is_err() || !p.starts_with("payload/") {
                    s.p.add(
                        codes::RUN_DISC_PATH,
                        at,
                        "A disc is a file inside payload/.",
                    );
                    return None;
                }
                if !s.table.is_file(p) {
                    s.p.add(
                        codes::RUN_DISC_NOT_IN_TABLE,
                        at,
                        format!(
                            "The disc {pq} is not in play.files.",
                            pq = crate::problem::quote(p)
                        ),
                    );
                    return None;
                }
                Some(p.to_string())
            });
            let d = discs.clone();
            self.no_duplicates(&d, "/run/discs", codes::RUN_DISC_DUPLICATE);
        }
        let has_discs = !discs.is_empty();
        let command = self
            .required(r, "command", "/run")
            .and_then(|v| self.command(v, "/run/command"));
        if let Some(cmd) = &command {
            for (i, a) in cmd.iter().enumerate() {
                self.placeholders(a, &format!("/run/command/{i}"), components, has_discs);
                self.argument_path(a, &format!("/run/command/{i}"));
            }
            self.program_exists(&cmd[0], "/run/command/0");
        }
        let cwd = r.get("cwd").and_then(|v| {
            let s = self.string(v, "/run/cwd")?;
            self.placeholders(s, "/run/cwd", components, has_discs);
            let known = s.strip_prefix("${").and_then(|t| t.split_once('}')).is_some_and(|(name, rest)| {
                (["payload", "data", "config", "prefix"].contains(&name) || name.strip_prefix("component:").is_some_and(|id| components.iter().any(|c| c.id == id)))
                    && (rest.is_empty() || rest.starts_with('/'))
                    && !rest.split('/').any(|c| c == "..")
            });
            if known {
                Some(s.to_string())
            } else {
                self.p.add(codes::RUN_CWD, "/run/cwd", "The working directory starts with ${payload}, ${data}, ${config}, ${prefix} or ${component:<id>} and has no .. part.");
                None
            }
        });
        let env = r.get("env").map(|v| self.env(v)).unwrap_or_default();
        let launch_mode = r
            .get("launch_mode")
            .and_then(|v| self.vocab(v, "/run/launch_mode", &LAUNCH_MODES))
            .unwrap_or_else(|| LAUNCH_MODES[0].to_string());
        let prefix = r.get("prefix").and_then(|v| self.prefix(v));
        let mut setup = Vec::new();
        if let Some(v) = r.get("setup") {
            if let Some(list) = self.array(v, "/run/setup", MAX_SETUP_STEPS) {
                for (i, item) in list.iter().enumerate() {
                    let at = format!("/run/setup/{i}");
                    let Some(st) = self.obj(item, &at) else {
                        continue;
                    };
                    self.strict_keys(st, &SETUP_KEYS, &at, codes::RUN_UNKNOWN_KEY, "a setup step");
                    let id = self.required(st, "id", &at).and_then(|x| {
                        let s = self.string(x, &format!("{at}/id"))?;
                        if is_local_id(s) {
                            Some(s.to_string())
                        } else {
                            self.p.add(
                                codes::VALUE_UNKNOWN,
                                format!("{at}/id"),
                                "A step id is a-z, 0-9, _ and -, starting with a letter.",
                            );
                            None
                        }
                    });
                    let cmd = self
                        .required(st, "command", &at)
                        .and_then(|x| self.command(x, &format!("{at}/command")));
                    let once = st
                        .get("once")
                        .and_then(|x| self.boolean(x, &format!("{at}/once")))
                        .unwrap_or(false);
                    if let Some(cmd) = &cmd {
                        for (j, a) in cmd.iter().enumerate() {
                            self.placeholders(
                                a,
                                &format!("{at}/command/{j}"),
                                components,
                                has_discs,
                            );
                            self.argument_path(a, &format!("{at}/command/{j}"));
                        }
                        self.program_exists(&cmd[0], &format!("{at}/command/0"));
                    }
                    if let (Some(id), Some(command)) = (id, cmd) {
                        if setup.iter().any(|s: &SetupStep| s.id == id) {
                            self.p.add(
                                codes::LIST_DUPLICATE,
                                format!("{at}/id"),
                                format!(
                                    "There are two setup steps with id {idq}.",
                                    idq = crate::problem::quote(&id)
                                ),
                            );
                        }
                        setup.push(SetupStep { id, command, once });
                    }
                }
            }
        }
        Some(Run {
            runner: runner?,
            component,
            command: command?,
            cwd,
            env,
            launch_mode,
            prefix,
            setup,
            discs,
        })
    }
}

struct PartialManifest {
    summary: Option<Localized>,
    description: Option<Localized>,
    developer: Option<Credit>,
    publisher: Option<Credit>,
    release_date: Option<String>,
    genres: Vec<String>,
    tags: Vec<String>,
    languages: Vec<String>,
    players: Option<Players>,
    controller: Option<String>,
    age_rating: Option<AgeRating>,
    licence: Option<String>,
    terms_url: Option<String>,
    links: Vec<Link>,
    requirements: Requirements,
    data: DataPaths,
    update: Update,
}

/// Parse and check `play.json`. Problems are added to `problems`; the manifest is returned only when
/// there are none from it. `table` and `entries` are the package's file table (the manifest must
/// agree with it); `official` lifts the reserved-id and reserved-name rules.
pub fn parse_manifest(
    bytes: &[u8],
    entries: &[FileEntry],
    table: &TableIndex<'_>,
    official: bool,
    problems: &mut Problems,
) -> Option<Manifest> {
    if bytes.len() as u64 > MAX_MANIFEST_BYTES {
        problems.add(
            codes::MANIFEST_TOO_BIG,
            "play.json",
            format!("play.json is larger than {MAX_MANIFEST_BYTES} bytes."),
        );
        return None;
    }
    if std::str::from_utf8(bytes).is_err() {
        problems.add(
            codes::MANIFEST_NOT_UTF8,
            "play.json",
            "play.json is not valid UTF-8.",
        );
        return None;
    }
    if json_depth_exceeds(bytes, MAX_JSON_DEPTH) {
        problems.add(
            codes::MANIFEST_TOO_DEEP,
            "play.json",
            format!("play.json nests deeper than {MAX_JSON_DEPTH} levels."),
        );
        return None;
    }
    if let Some(at) = crate::json::find_duplicate_key(bytes) {
        problems.add(
            codes::JSON_DUPLICATE_KEY,
            at,
            "This object names the same key twice; keep one.",
        );
        return None;
    }
    let value: Value = match serde_json::from_slice(bytes) {
        Ok(v) => v,
        Err(e) => {
            problems.add(
                codes::MANIFEST_INVALID_JSON,
                "play.json",
                format!("play.json is not valid JSON ({e})."),
            );
            return None;
        }
    };
    let before = problems.len();
    let mut c = Checker {
        p: problems,
        table,
        entries,
        official,
    };
    let root = c.obj(&value, "")?;
    let format = match root.get("format") {
        None => {
            c.p.add(
                codes::MANIFEST_MISSING,
                "/format",
                "\"format\" is required.",
            );
            return None;
        }
        Some(v) => match v {
            Value::Number(n)
                if n.as_f64()
                    .is_some_and(|f| f >= (SUPPORTED_FORMAT + 1) as f64) =>
            {
                c.p.add(
                    codes::FORMAT_TOO_NEW,
                    "/format",
                    "This package needs a newer RuyaOS.",
                );
                return None;
            }
            Value::Number(n) if n.as_u64() == Some(1) => 1,
            _ => {
                c.p.add(
                    codes::FORMAT_INVALID,
                    "/format",
                    "\"format\" is a whole number, 1 or more.",
                );
                return None;
            }
        },
    };
    let ident = c.identity(root);
    let mut m = PartialManifest {
        summary: None,
        description: None,
        developer: None,
        publisher: None,
        release_date: None,
        genres: Vec::new(),
        tags: Vec::new(),
        languages: Vec::new(),
        players: None,
        controller: None,
        age_rating: None,
        licence: None,
        terms_url: None,
        links: Vec::new(),
        requirements: Requirements::default(),
        data: DataPaths::default(),
        update: Update::default(),
    };
    c.descriptive(root, &mut m);
    let art = c.art(root);
    let components = c.components(root);
    let run = c.run(root, &components);
    let permissions = c.permissions(root);
    if c.p.len() > before {
        return None;
    }
    let (id, name, version, build) = ident?;
    Some(Manifest {
        format,
        id,
        name,
        version,
        build,
        summary: m.summary,
        description: m.description,
        developer: m.developer,
        publisher: m.publisher,
        release_date: m.release_date,
        genres: m.genres,
        tags: m.tags,
        languages: m.languages,
        players: m.players,
        controller: m.controller,
        age_rating: m.age_rating,
        licence: m.licence,
        terms_url: m.terms_url,
        links: m.links,
        requirements: m.requirements,
        art: art?,
        components,
        run: run?,
        permissions,
        data: m.data,
        update: m.update,
    })
}
