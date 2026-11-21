//! What a `.play` app adds to its library item (RUY-852). A `.play` app is a Flatpak app whose id
//! starts with `play.`; the console wrote its art, `play.json` and `trust.json` into the
//! deployment `<root>/app/play.<id>/current/active/files/` (Flatpak does not export them, there
//! is no metainfo). Nothing here verifies a signature: the tier and the signer are what
//! `ruya-play` recorded at install time.

use std::io::Read;
use std::path::{Path, PathBuf};

use ruya_play_format::resolve::Override;

use crate::catalog::Item;
use crate::runners::{resolve_in_place, Resolution};

/// The runners the image ships; the launcher sees them as `/app/runners` (ADR-038). Read-only
/// image data, so the unit's `ProtectSystem=strict` leaves it readable.
pub const RUNNERS_DIR: &str = "/usr/lib/ruyaos/play/runners";

/// More than this in `play.json` or `trust.json` is read as garbled (05 limits `play.json` far
/// below it).
const MAX_JSON_BYTES: u64 = 1024 * 1024;
/// The vetted art, inside `files/`.
const ART_DIR: &str = "share/ruyaos/play/art";

/// The `.play` fields of a library item (Library1 keys `genres`, `players`, `controller`,
/// `age_rating`, `play_tier`, `play_signer`, `play_signer_key_id`, `play_screenshots`, and the
/// runner keys of its [`Resolution`]).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PlayInfo {
    pub genres: Vec<String>,
    pub players: Option<(u32, u32)>,
    pub controller: Option<String>,
    /// OARS attribute to value.
    pub age_rating: Vec<(String, String)>,
    /// `official`, `developer` or `unverified`; none when `trust.json` is missing or garbled.
    pub tier: Option<String>,
    /// The signer's name (else its id); none when unsigned or unknown.
    pub signer: Option<String>,
    /// The signer's key id exactly as `trust.json` holds it (`signer_id`); none with no tier or
    /// no signer. Never computed here.
    pub signer_key_id: Option<String>,
    /// The 1080p screenshots in order, at most `MAX_SCREENSHOTS`; empty when there are none.
    pub screenshots: Vec<String>,
    /// What the launch would run the game with, the package's default choice (RUY-903).
    pub resolution: Resolution,
}

fn read_json(path: &Path) -> Option<serde_json::Value> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if !meta.is_file() {
        return None;
    }
    let mut bytes = Vec::new();
    std::fs::File::open(path)
        .ok()?
        .take(MAX_JSON_BYTES + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() as u64 > MAX_JSON_BYTES {
        return None;
    }
    serde_json::from_slice(&bytes).ok()
}

/// Longest title or signer name listed (characters); longer text is cut.
const MAX_TEXT_CHARS: usize = 120;
/// At most this many genres (05 section 4).
const MAX_GENRES: usize = 4;

fn clip(s: &str) -> Option<String> {
    let s = s.trim();
    (!s.is_empty()).then(|| s.chars().take(MAX_TEXT_CHARS).collect())
}

fn text(v: &serde_json::Value, key: &str) -> Option<String> {
    v.get(key)?.as_str().and_then(clip)
}

/// The name in English, else the first language (the library has no player language).
fn title(manifest: &serde_json::Value) -> Option<String> {
    let names = manifest.get("name")?.as_object()?;
    let pick = |v: &serde_json::Value| v.as_str().and_then(clip);
    names
        .get("en")
        .and_then(pick)
        .or_else(|| names.values().find_map(pick))
}

fn players(manifest: &serde_json::Value) -> Option<(u32, u32)> {
    let p = manifest.get("players")?;
    let n = |k: &str| {
        p.get(k)
            .and_then(serde_json::Value::as_u64)
            .map(|n| u32::try_from(n).unwrap_or(u32::MAX))
    };
    Some((n("min")?, n("max")?))
}

fn age_rating(manifest: &serde_json::Value) -> Vec<(String, String)> {
    let Some(content) = manifest
        .get("age_rating")
        .and_then(|a| a.get("content"))
        .and_then(serde_json::Value::as_object)
    else {
        return Vec::new();
    };
    let mut out: Vec<(String, String)> = content
        .iter()
        .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_owned())))
        .collect();
    out.sort();
    out
}

/// The language keys of a per-language logo, in the order the importer numbers `logo-<n>`
/// (the sorted keys of the `art.logo` map); empty when the logo is one file.
fn logo_langs(manifest: &serde_json::Value) -> Vec<String> {
    let mut langs: Vec<String> = manifest
        .get("art")
        .and_then(|a| a.get("logo"))
        .and_then(serde_json::Value::as_object)
        .map(|m| m.keys().cloned().collect())
        .unwrap_or_default();
    langs.sort();
    langs
}

fn regular_files(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut files: Vec<PathBuf> = entries
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .map(|e| e.path())
        .collect();
    files.sort();
    files
}

/// The art roles of the vetted art folder and its screenshots: its files, and the files of each
/// `logo-<n>` folder with the language the manifest gives that number.
fn art(art_dir: &Path, manifest: &serde_json::Value) -> (Vec<(String, String)>, Vec<String>) {
    let langs = logo_langs(manifest);
    let mut slots: Vec<(Option<String>, Vec<PathBuf>)> = vec![(None, regular_files(art_dir))];
    if let Ok(entries) = std::fs::read_dir(art_dir) {
        let mut dirs: Vec<(usize, PathBuf)> = entries
            .flatten()
            .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
            .filter_map(|e| {
                let n = e
                    .file_name()
                    .to_str()?
                    .strip_prefix("logo-")?
                    .parse::<usize>()
                    .ok()?;
                Some((n, e.path()))
            })
            .collect();
        dirs.sort();
        for (n, dir) in dirs {
            slots.push((langs.get(n).cloned(), regular_files(&dir)));
        }
    }
    let (roles, screenshots) = ruya_play_art::art_roles(
        slots
            .iter()
            .map(|(lang, files)| (lang.as_deref(), files.as_slice())),
    );
    // The roles are what the shell draws on a card; the trailer's poster belongs to the store
    // page (Play1). An installed app has no Play1 record, so the game page gets its screenshots
    // from here.
    (
        roles
            .into_iter()
            .filter(|(role, _)| role != "poster")
            .collect(),
        screenshots
            .into_iter()
            .take(usize::from(ruya_play_art::MAX_SCREENSHOTS))
            .collect(),
    )
}

/// Reads the deployment of `play.<id>` below `root` into `item`: the title and the `.play`
/// fields from `play.json`, the art, the tier and signer from `trust.json`, and the runner the
/// launch would use against the image's `runners`. An app that has no
/// readable `play.json` (not deployed, missing, garbled) is left as it is: a plain item.
pub fn enrich(item: &mut Item, flatpak_id: &str, root: &Path, runners: &Path) {
    let Some(files) = deployment_files(root, flatpak_id) else {
        return;
    };
    let Some(manifest) = read_json(&files.join("play.json")).filter(serde_json::Value::is_object)
    else {
        return;
    };
    if let Some(t) = title(&manifest) {
        item.title = t;
    }
    let (roles, screenshots) = art(&files.join(ART_DIR), &manifest);
    item.art = roles;
    let trust = read_json(&files.join("share/ruyaos/play/trust.json"))
        .filter(|t| t.get("format").and_then(serde_json::Value::as_u64) == Some(1));
    let tier = trust
        .as_ref()
        .and_then(|t| text(t, "tier"))
        .filter(|t| matches!(t.as_str(), "official" | "developer" | "unverified"));
    // A tier-less item has no signer either: both come from the same file.
    let signer = tier.as_ref().and(
        trust
            .as_ref()
            .and_then(|t| text(t, "signer_name").or_else(|| text(t, "signer_id"))),
    );
    let signer_key_id = tier
        .as_ref()
        .and(trust.as_ref().and_then(|t| text(t, "signer_id")));
    let mut info = PlayInfo {
        genres: manifest
            .get("genres")
            .and_then(serde_json::Value::as_array)
            .map(|g| {
                g.iter()
                    .filter_map(|s| s.as_str().and_then(clip))
                    .take(MAX_GENRES)
                    .collect()
            })
            .unwrap_or_default(),
        players: players(&manifest),
        controller: text(&manifest, "controller"),
        age_rating: age_rating(&manifest),
        tier,
        signer,
        signer_key_id,
        screenshots,
        ..PlayInfo::default()
    };
    if let Some(resolution) = resolve_in_place(&files, runners, Override::PackageDefault) {
        info.resolution = resolution;
    }
    item.play = Some(info);
}

/// The deployed files of the `.play` app `play.<id>` below the Flatpak installation `root`
/// (`<root>/app/play.<id>/current/active/files`); none for an id that is not a `.play` one or
/// would leave the folder.
pub fn deployment_files(root: &Path, flatpak_id: &str) -> Option<PathBuf> {
    if !flatpak_id.starts_with("play.")
        || flatpak_id.len() == "play.".len()
        || flatpak_id.contains(['/', '\\'])
        || flatpak_id.chars().any(char::is_control)
    {
        return None;
    }
    Some(
        root.join("app")
            .join(flatpak_id)
            .join("current")
            .join("active")
            .join("files"),
    )
}
