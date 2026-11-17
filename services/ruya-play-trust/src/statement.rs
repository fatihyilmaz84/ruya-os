//! The statements inside the envelopes (05 §9.2). Each is strict JSON with exactly its keys.

use crate::envelope::{strict_json, MAX_SIG_DEPTH, MAX_STATEMENT_BYTES};
use crate::error::TrustError;
use crate::keys::{is_sha256_hex, KeyFault, PublicKey};
use crate::time::{format_utc, parse_utc, UnixSeconds};
use ruya_play_format::limits::MAX_ID_BYTES;
use serde::{Deserialize, Serialize};

fn malformed(file: &str, detail: impl Into<String>) -> TrustError {
    TrustError::Malformed {
        file: file.to_string(),
        detail: detail.into(),
    }
}

fn check_id(id: &str, file: &str) -> Result<(), TrustError> {
    if id.is_empty() || id.len() > MAX_ID_BYTES || !id.is_ascii() {
        return Err(malformed(file, "id is empty, too long or not ASCII"));
    }
    Ok(())
}

fn check_sha(value: &str, what: &str, file: &str) -> Result<(), TrustError> {
    if !is_sha256_hex(value) {
        return Err(malformed(
            file,
            format!("{what} is not a lower-case hex SHA-256"),
        ));
    }
    Ok(())
}

fn time(value: &str, what: &str, file: &str) -> Result<UnixSeconds, TrustError> {
    parse_utc(value).ok_or_else(|| malformed(file, format!("{what} is not YYYY-MM-DDTHH:MM:SSZ")))
}

fn key(value: &str, what: &str, file: &str) -> Result<PublicKey, TrustError> {
    PublicKey::from_base64(value).map_err(|f| match f {
        KeyFault::Weak => TrustError::WeakKey {
            file: file.to_string(),
        },
        KeyFault::Invalid => malformed(file, format!("{what} is not an Ed25519 public key")),
    })
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawPlay {
    id: String,
    build: u64,
    play_json_sha256: String,
    play_files_sha256: String,
    signed_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    rotations_sha256: Option<String>,
}

/// What `play.sig` states: this id and build, with exactly this `play.json` and `play.files`.
/// `play.files` lists every other file's SHA-256, so one signature covers the whole package.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlayStatement {
    /// The package `id`.
    pub id: String,
    /// The package `build`.
    pub build: u64,
    /// SHA-256 of the `play.json` bytes.
    pub play_json_sha256: String,
    /// SHA-256 of the `play.files` bytes.
    pub play_files_sha256: String,
    /// When it was signed (the developer's claim; never used to decide trust).
    pub signed_at: UnixSeconds,
    /// The digest of the rotations `play.sig` carries ([`crate::envelope::rotations_digest`]);
    /// present exactly when it carries some, so only the package key decides what it carries.
    pub rotations_sha256: Option<String>,
}

impl PlayStatement {
    /// Read the statement bytes of `play.sig`.
    pub fn parse(bytes: &[u8]) -> Result<PlayStatement, TrustError> {
        let file = "play.sig";
        let raw: RawPlay = strict_json(bytes, MAX_STATEMENT_BYTES, MAX_SIG_DEPTH, file)?;
        check_id(&raw.id, file)?;
        check_sha(&raw.play_json_sha256, "play_json_sha256", file)?;
        check_sha(&raw.play_files_sha256, "play_files_sha256", file)?;
        if let Some(r) = &raw.rotations_sha256 {
            check_sha(r, "rotations_sha256", file)?;
        }
        Ok(PlayStatement {
            signed_at: time(&raw.signed_at, "signed_at", file)?,
            id: raw.id,
            build: raw.build,
            play_json_sha256: raw.play_json_sha256,
            play_files_sha256: raw.play_files_sha256,
            rotations_sha256: raw.rotations_sha256,
        })
    }

    /// The statement bytes.
    pub fn to_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(&RawPlay {
            id: self.id.clone(),
            build: self.build,
            play_json_sha256: self.play_json_sha256.clone(),
            play_files_sha256: self.play_files_sha256.clone(),
            signed_at: format_utc(self.signed_at),
            rotations_sha256: self.rotations_sha256.clone(),
        })
        .expect("a statement is always JSON")
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawStore {
    id: String,
    build: u64,
    play_sig_sha256: String,
    signed_at: String,
}

/// What `store.sig` states: the store reviewed this id and build, signed by exactly this `play.sig`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoreStatement {
    /// The package `id`.
    pub id: String,
    /// The package `build`.
    pub build: u64,
    /// SHA-256 of the `play.sig` bytes.
    pub play_sig_sha256: String,
    /// When the store signed it.
    pub signed_at: UnixSeconds,
}

impl StoreStatement {
    /// Read the statement bytes of `store.sig`.
    pub fn parse(bytes: &[u8]) -> Result<StoreStatement, TrustError> {
        let file = "store.sig";
        let raw: RawStore = strict_json(bytes, MAX_STATEMENT_BYTES, MAX_SIG_DEPTH, file)?;
        check_id(&raw.id, file)?;
        check_sha(&raw.play_sig_sha256, "play_sig_sha256", file)?;
        Ok(StoreStatement {
            signed_at: time(&raw.signed_at, "signed_at", file)?,
            id: raw.id,
            build: raw.build,
            play_sig_sha256: raw.play_sig_sha256,
        })
    }

    /// The statement bytes.
    pub fn to_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(&RawStore {
            id: self.id.clone(),
            build: self.build,
            play_sig_sha256: self.play_sig_sha256.clone(),
            signed_at: format_utc(self.signed_at),
        })
        .expect("a statement is always JSON")
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawRotation {
    id: String,
    old_key: String,
    new_key: String,
    seq: u64,
    signed_at: String,
}

/// A key rotation: `old_key` hands `id` over to `new_key`. Signed by the old key; `seq` strictly
/// increases per id, so an older statement cannot be replayed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RotationStatement {
    /// The id handed over.
    pub id: String,
    /// The key that owned it.
    pub old_key: PublicKey,
    /// The key that owns it now.
    pub new_key: PublicKey,
    /// The rotation's number for this id, at least 1.
    pub seq: u64,
    /// When the old key signed it.
    pub signed_at: UnixSeconds,
}

impl RotationStatement {
    /// Read the statement bytes of a rotation; `file` names it in errors.
    pub fn parse(bytes: &[u8], file: &str) -> Result<RotationStatement, TrustError> {
        let raw: RawRotation = strict_json(bytes, MAX_STATEMENT_BYTES, MAX_SIG_DEPTH, file)?;
        check_id(&raw.id, file)?;
        let old_key = key(&raw.old_key, "old_key", file)?;
        let new_key = key(&raw.new_key, "new_key", file)?;
        if old_key == new_key {
            return Err(malformed(file, "old_key and new_key are the same key"));
        }
        if raw.seq == 0 {
            return Err(malformed(file, "seq starts at 1"));
        }
        Ok(RotationStatement {
            signed_at: time(&raw.signed_at, "signed_at", file)?,
            id: raw.id,
            old_key,
            new_key,
            seq: raw.seq,
        })
    }

    /// The statement bytes.
    pub fn to_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(&RawRotation {
            id: self.id.clone(),
            old_key: self.old_key.to_base64(),
            new_key: self.new_key.to_base64(),
            seq: self.seq,
            signed_at: format_utc(self.signed_at),
        })
        .expect("a statement is always JSON")
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawBlocklist {
    blocklist_sha256: String,
    signed_at: String,
    expires: String,
}

/// What the signature of a downloaded blocklist states: exactly this text, valid until `expires`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlocklistStatement {
    /// SHA-256 of the blocklist bytes.
    pub blocklist_sha256: String,
    /// When the store signed it.
    pub signed_at: UnixSeconds,
    /// After this the copy is stale and the image's copy is used (05 §9.2, Q6).
    pub expires: UnixSeconds,
}

impl BlocklistStatement {
    /// Read the statement bytes of `store-blocklist.sig`.
    pub fn parse(bytes: &[u8]) -> Result<BlocklistStatement, TrustError> {
        let file = "store-blocklist.sig";
        let raw: RawBlocklist = strict_json(bytes, MAX_STATEMENT_BYTES, MAX_SIG_DEPTH, file)?;
        check_sha(&raw.blocklist_sha256, "blocklist_sha256", file)?;
        let signed_at = time(&raw.signed_at, "signed_at", file)?;
        let expires = time(&raw.expires, "expires", file)?;
        if expires <= signed_at {
            return Err(malformed(file, "expires is not after signed_at"));
        }
        Ok(BlocklistStatement {
            blocklist_sha256: raw.blocklist_sha256,
            signed_at,
            expires,
        })
    }

    /// The statement bytes.
    pub fn to_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(&RawBlocklist {
            blocklist_sha256: self.blocklist_sha256.clone(),
            signed_at: format_utc(self.signed_at),
            expires: format_utc(self.expires),
        })
        .expect("a statement is always JSON")
    }
}
