//! Revocation (05 §9.2, §18 item 7; `10-stores.md` §6): the `[packages]` section of the store
//! blocklist. The image ships `/usr/share/ruyaos/store-blocklist`, authenticated by the OS update
//! itself (no signature, no `expires`). A fresher downloaded copy is used only when it is signed by
//! a pinned store key, not past its `expires` and has a higher `serial` than the image's; otherwise
//! the image's copy is used. A stale list never blocks anything on its own (Q6).
//!
//! The file, as built here:
//!
//! ```text
//! # comments and empty lines are ignored
//! serial 3
//! [stores]
//! ... (read by the store service, T-441)
//! [packages]
//! key 3f9a0c1d2e3b4a5c The signing key was stolen
//! id com.example.game 1-142 Builds up to 142 carry malware
//! content <sha256 of play.files> Known malware
//! runner <sha256 of a runner> Wine 8.0 has a sandbox escape
//! ```

use crate::envelope::{self, Domain};
use crate::error::{RevokedBy, TrustError};
use crate::keys::{is_key_id, is_sha256_hex, sha256_hex, KEY_ID_CHARS};
use crate::signing::StoreKeys;
use crate::statement::BlocklistStatement;
use crate::time::UnixSeconds;
use ruya_play_format::limits::MAX_ID_BYTES;
use ruya_play_format::problem::safe_text;

/// Where the image keeps its copy.
pub const IMAGE_BLOCKLIST_PATH: &str = "/usr/share/ruyaos/store-blocklist";
/// Most bytes of a blocklist.
pub const MAX_BLOCKLIST_BYTES: usize = 4 * 1024 * 1024;
/// Most lines of a blocklist.
pub const MAX_BLOCKLIST_LINES: usize = 100_000;
/// Most characters of an entry's reason.
pub const MAX_REASON_CHARS: usize = 200;

/// Which builds of an id a line names (inclusive).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BuildRange {
    /// First build named.
    pub from: u64,
    /// Last build named (`u64::MAX` for "and later").
    pub to: u64,
}

impl BuildRange {
    /// Read `*`, `N`, `N-M` or `N-`.
    pub fn parse(s: &str) -> Option<BuildRange> {
        let num = |t: &str| {
            (!t.is_empty() && t.bytes().all(|b| b.is_ascii_digit()))
                .then(|| t.parse::<u64>().ok())
                .flatten()
        };
        if s == "*" {
            return Some(BuildRange {
                from: 0,
                to: u64::MAX,
            });
        }
        let range = match s.split_once('-') {
            None => {
                let n = num(s)?;
                BuildRange { from: n, to: n }
            }
            Some((a, "")) => BuildRange {
                from: num(a)?,
                to: u64::MAX,
            },
            Some((a, b)) => BuildRange {
                from: num(a)?,
                to: num(b)?,
            },
        };
        (range.from <= range.to).then_some(range)
    }

    /// True when `build` is in the range.
    pub fn contains(&self, build: u64) -> bool {
        (self.from..=self.to).contains(&build)
    }
}

/// One `[packages]` entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Entry {
    /// A signing key id.
    Key(String),
    /// An id (compared case-insensitively) and its builds.
    Id(String, BuildRange),
    /// The SHA-256 of a package's `play.files` (it covers every file).
    Content(String),
    /// The hash of a runner (as runner resolution, T-239, reports it).
    Runner(String),
}

/// The `[packages]` section of a blocklist.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Blocklist {
    /// The list's number; a downloaded copy must be higher than the image's.
    pub serial: u64,
    /// Every entry with its reason.
    pub entries: Vec<(Entry, String)>,
}

fn bad(line: usize, detail: impl Into<String>) -> TrustError {
    TrustError::BlocklistMalformed {
        line,
        detail: detail.into(),
    }
}

fn reason_of(rest: &[&str], line: usize) -> Result<String, TrustError> {
    let reason = rest.join(" ");
    if reason.is_empty() {
        return Err(bad(line, "the entry has no reason"));
    }
    if reason.chars().count() > MAX_REASON_CHARS {
        return Err(bad(
            line,
            format!("the reason is longer than {MAX_REASON_CHARS} characters"),
        ));
    }
    Ok(safe_text(&reason, MAX_REASON_CHARS))
}

impl Blocklist {
    /// Read a blocklist. Lines before the first section are the header (`serial N`); only the
    /// `[packages]` section is read, other sections belong to the store service. A line whose first
    /// word is unknown is skipped (a newer list may add kinds; refusing it would drop every entry);
    /// a known kind with bad fields is an error, so is a control character or a file that is not
    /// UTF-8.
    pub fn parse(bytes: &[u8]) -> Result<Blocklist, TrustError> {
        if bytes.len() > MAX_BLOCKLIST_BYTES {
            return Err(bad(
                0,
                format!("it is larger than {MAX_BLOCKLIST_BYTES} bytes"),
            ));
        }
        let text = std::str::from_utf8(bytes).map_err(|_| bad(0, "it is not UTF-8"))?;
        let mut list = Blocklist::default();
        let (mut section, mut serial_seen) = (None::<String>, false);
        for (i, raw) in text.split('\n').enumerate() {
            let n = i + 1;
            if n > MAX_BLOCKLIST_LINES {
                return Err(bad(n, format!("more than {MAX_BLOCKLIST_LINES} lines")));
            }
            let line = raw.strip_suffix('\r').unwrap_or(raw);
            if line.chars().any(|c| c.is_control() && c != '\t') {
                return Err(bad(n, "a control character"));
            }
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some(name) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
                section = Some(name.to_string());
                continue;
            }
            let words: Vec<&str> = line.split_whitespace().collect();
            match (section.as_deref(), words[0]) {
                (None, "serial") => {
                    if serial_seen || words.len() != 2 {
                        return Err(bad(n, "serial is given once, as one number"));
                    }
                    list.serial = words[1]
                        .parse()
                        .map_err(|_| bad(n, "serial is not a number"))?;
                    serial_seen = true;
                }
                (Some("packages"), "key") => {
                    let k = words.get(1).copied().unwrap_or_default();
                    if !is_key_id(k) {
                        return Err(bad(
                            n,
                            format!("a key id is {KEY_ID_CHARS} lower-case hex characters"),
                        ));
                    }
                    let reason = reason_of(&words[2..], n)?;
                    list.entries.push((Entry::Key(k.to_string()), reason));
                }
                (Some("packages"), "id") => {
                    let (Some(id), Some(range)) = (words.get(1), words.get(2)) else {
                        return Err(bad(n, "an id line is: id <id> <builds> <reason>"));
                    };
                    if id.len() > MAX_ID_BYTES || !id.is_ascii() {
                        return Err(bad(n, "the id is too long or not ASCII"));
                    }
                    let range = BuildRange::parse(range)
                        .ok_or_else(|| bad(n, "builds are *, N, N-M or N-"))?;
                    let reason = reason_of(&words[3..], n)?;
                    list.entries
                        .push((Entry::Id(id.to_ascii_lowercase(), range), reason));
                }
                (Some("packages"), kind @ ("content" | "runner")) => {
                    let h = words.get(1).copied().unwrap_or_default();
                    if !is_sha256_hex(h) {
                        return Err(bad(n, "a hash is 64 lower-case hex characters"));
                    }
                    let reason = reason_of(&words[2..], n)?;
                    let entry = if kind == "content" {
                        Entry::Content(h.to_string())
                    } else {
                        Entry::Runner(h.to_string())
                    };
                    list.entries.push((entry, reason));
                }
                _ => {}
            }
        }
        Ok(list)
    }
}

/// What the revocation check knows about a package.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackageFacts {
    /// The manifest `id`.
    pub id: String,
    /// The manifest `build`.
    pub build: u64,
    /// The key ids that vouch for it: the developer key and, for `official`, the store key.
    pub key_ids: Vec<String>,
    /// The SHA-256 of its `play.files`.
    pub play_files_sha256: String,
}

/// The first entry that revokes the package, or `None`. `runner_hashes` are the hashes of the
/// runner the package uses (bundled or system, from runner resolution).
pub fn is_revoked(
    list: &Blocklist,
    package: &PackageFacts,
    runner_hashes: &[String],
) -> Option<TrustError> {
    list.entries.iter().find_map(|(entry, reason)| {
        let by = match entry {
            Entry::Key(k) if package.key_ids.contains(k) => RevokedBy::Key,
            Entry::Id(id, range)
                if id.eq_ignore_ascii_case(&package.id) && range.contains(package.build) =>
            {
                RevokedBy::Id
            }
            Entry::Content(h) if *h == package.play_files_sha256 => RevokedBy::Content,
            Entry::Runner(h) if runner_hashes.contains(h) => RevokedBy::Runner,
            _ => return None,
        };
        Some(TrustError::Revoked {
            by,
            reason: reason.clone(),
        })
    })
}

/// The name of a downloaded copy's signature file.
pub const BLOCKLIST_SIG_FILE: &str = "store-blocklist.sig";

/// Verify a downloaded copy: `sig` is an envelope for [`Domain::Blocklist`] by a pinned store key,
/// its statement names exactly `text`, and `now` is before its `expires`.
pub fn verify_downloaded(
    text: &[u8],
    sig: &[u8],
    store_keys: &StoreKeys,
    now: UnixSeconds,
) -> Result<(Blocklist, BlocklistStatement), TrustError> {
    let opened = envelope::open(sig, Domain::Blocklist, BLOCKLIST_SIG_FILE)?;
    if !store_keys.contains(&opened.key) {
        return Err(TrustError::BlocklistNotStoreKey {
            key_id: opened.key.key_id(),
        });
    }
    let statement = BlocklistStatement::parse(&opened.statement)?;
    if sha256_hex(text) != statement.blocklist_sha256 {
        return Err(TrustError::BlocklistChanged);
    }
    if now >= statement.expires {
        return Err(TrustError::BlocklistExpired {
            expires: crate::time::format_utc(statement.expires),
        });
    }
    Ok((Blocklist::parse(text)?, statement))
}

/// The signature file of a downloaded copy, for the store's tool and the tests.
pub fn sign_blocklist(
    key: &crate::keys::SecretKey,
    text: &[u8],
    signed_at: UnixSeconds,
    expires: UnixSeconds,
) -> Vec<u8> {
    let statement = BlocklistStatement {
        blocklist_sha256: sha256_hex(text),
        signed_at,
        expires,
    };
    envelope::seal(key, Domain::Blocklist, &statement.to_bytes())
}

/// Which copy is in use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ListSource {
    /// The image's copy alone.
    Image,
    /// The image's copy together with the verified downloaded copy.
    Downloaded,
}

/// The list in use, and why a downloaded copy was not used.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Selected {
    /// The entries to check: the image's, plus the download's when it is used.
    pub list: Blocklist,
    /// Where they come from.
    pub source: ListSource,
    /// Why the downloaded copy was set aside (`blocklist.expired` makes the shell say the safety
    /// list is out of date); `None` when it is used or there is none.
    pub set_aside: Option<TrustError>,
}

impl Blocklist {
    /// Every entry of both lists (an entry in both keeps the first reason); the higher serial.
    /// A downloaded list never removes an entry of the image's.
    pub fn union(&self, other: &Blocklist) -> Blocklist {
        let mut entries = self.entries.clone();
        for (entry, reason) in &other.entries {
            if !entries.iter().any(|(e, _)| e == entry) {
                entries.push((entry.clone(), reason.clone()));
            }
        }
        Blocklist {
            serial: self.serial.max(other.serial),
            entries,
        }
    }
}

/// Choose the list (Q6). `image` is the image's file (`None` when it is missing or unreadable):
/// when it is missing or does not parse, nothing can be checked, so the result is
/// `blocklist.unavailable` and installs are refused (fail closed). Otherwise the downloaded copy
/// is added when it verifies and has a higher serial than the image's; when it does not, the
/// image's copy is used alone, with the reason. Staleness alone blocks nothing, and a download
/// never removes an entry: the checks use the union.
pub fn select_blocklist(
    image: Option<&[u8]>,
    downloaded: Option<(&[u8], &[u8])>,
    store_keys: &StoreKeys,
    now: UnixSeconds,
) -> Result<Selected, TrustError> {
    let image = match image {
        None => {
            return Err(TrustError::BlocklistUnavailable {
                detail: format!("{IMAGE_BLOCKLIST_PATH} is missing"),
            })
        }
        Some(bytes) => Blocklist::parse(bytes).map_err(|e| TrustError::BlocklistUnavailable {
            detail: e.message(),
        })?,
    };
    let image_copy = |set_aside| Selected {
        list: image.clone(),
        source: ListSource::Image,
        set_aside,
    };
    let Some((text, sig)) = downloaded else {
        return Ok(image_copy(None));
    };
    Ok(match verify_downloaded(text, sig, store_keys, now) {
        Err(e) => image_copy(Some(e)),
        Ok((list, _)) if list.serial <= image.serial => {
            image_copy(Some(TrustError::BlocklistNotNewer {
                serial: list.serial,
                image: image.serial,
            }))
        }
        Ok((list, _)) => Selected {
            list: image.union(&list),
            source: ListSource::Downloaded,
            set_aside: None,
        },
    })
}

/// What the inspect step does about revocation.
#[derive(Debug, Clone, Copy)]
pub enum ListCheck<'a> {
    /// Not checked here (the caller checks later, e.g. at launch).
    NotChecked,
    /// Check against this list.
    Use(&'a Blocklist),
    /// The image's list could not be read: refuse ([`select_blocklist`]'s error).
    Unavailable(&'a TrustError),
}

impl<'a> ListCheck<'a> {
    /// The check for the result of [`select_blocklist`].
    pub fn of(selected: &'a Result<Selected, TrustError>) -> ListCheck<'a> {
        match selected {
            Ok(s) => ListCheck::Use(&s.list),
            Err(e) => ListCheck::Unavailable(e),
        }
    }
}
