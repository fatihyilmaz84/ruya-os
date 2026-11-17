//! The one signature encoding (05 §9.2, decided in RUY-93): a small JSON envelope
//! `{ "format": 1, "key": "<base64 32>", "statement": "<base64>", "sig": "<base64 64>" }` whose
//! Ed25519 signature covers `domain prefix || statement bytes`. The statement is strict JSON of its
//! own, so no canonical JSON is needed: the raw bytes are what was signed.
//!
//! Every file is read as untrusted input: bounded size and depth, UTF-8, a key named twice is an
//! error (the format crate's scan), unknown keys are an error, base64 is strict.

use crate::error::TrustError;
use crate::keys::{KeyFault, PublicKey, SecretKey};
use base64ct::{Base64, Encoding};
use ruya_play_format::json::find_duplicate_key;
use ruya_play_format::manifest::json_depth_exceeds;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The envelope `format` this console reads.
pub const ENVELOPE_FORMAT: u64 = 1;
/// Most bytes of a signature file (`play.sig` with its rotations, `store.sig`, ...).
pub const MAX_SIG_FILE_BYTES: usize = 64 * 1024;
/// Most bytes of one statement.
pub const MAX_STATEMENT_BYTES: usize = 4 * 1024;
/// Deepest JSON nesting of a signature file or a statement.
pub const MAX_SIG_DEPTH: usize = 4;
/// Most rotation statements one `play.sig` carries.
pub const MAX_ROTATIONS: usize = 8;

/// What a signature is for. Each has its own prefix, so a signature made for one purpose never
/// verifies as another.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Domain {
    /// `play.sig`: the developer signs a package.
    PlaySig,
    /// `store.sig`: the store countersigns `play.sig`.
    StoreSig,
    /// A rotation statement: the old key hands an id to a new key.
    Rotation,
    /// The signature of a downloaded blocklist.
    Blocklist,
}

impl Domain {
    /// The bytes the signature covers before the statement.
    pub fn prefix(self) -> &'static [u8] {
        match self {
            Domain::PlaySig => b"ruyaos-play-sig-v1\0",
            Domain::StoreSig => b"ruyaos-store-sig-v1\0",
            Domain::Rotation => b"ruyaos-play-rotate-v1\0",
            Domain::Blocklist => b"ruyaos-blocklist-v1\0",
        }
    }
}

/// A verified envelope: the key that signed, and the statement bytes it signed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Opened {
    /// The signing key.
    pub key: PublicKey,
    /// The raw statement bytes (still to be parsed by the caller).
    pub statement: Vec<u8>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawEnvelope {
    format: Value,
    key: String,
    statement: String,
    sig: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    rotations: Option<Vec<RawInner>>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawInner {
    format: Value,
    key: String,
    statement: String,
    sig: String,
}

/// Parse strict JSON of at most `max` bytes into `T` (`deny_unknown_fields` on `T`).
pub(crate) fn strict_json<T: DeserializeOwned>(
    bytes: &[u8],
    max: usize,
    depth: usize,
    file: &str,
) -> Result<T, TrustError> {
    let malformed = |detail: String| TrustError::Malformed {
        file: file.to_string(),
        detail,
    };
    if bytes.len() > max {
        return Err(malformed(format!("it is larger than {max} bytes")));
    }
    if std::str::from_utf8(bytes).is_err() {
        return Err(malformed("it is not UTF-8".into()));
    }
    if json_depth_exceeds(bytes, depth) {
        return Err(malformed(format!("it nests deeper than {depth} levels")));
    }
    if let Some(pointer) = find_duplicate_key(bytes) {
        return Err(TrustError::DuplicateKey {
            file: file.to_string(),
            pointer,
        });
    }
    serde_json::from_slice(bytes).map_err(|e| {
        // serde's text names the key or the type, never the value: safe to repeat.
        let mut text = e.to_string();
        text.truncate(160);
        malformed(text)
    })
}

fn check_format(format: &Value, file: &str) -> Result<(), TrustError> {
    match format.as_u64() {
        Some(ENVELOPE_FORMAT) => Ok(()),
        _ if format
            .as_f64()
            .is_some_and(|f| f >= (ENVELOPE_FORMAT + 1) as f64) =>
        {
            Err(TrustError::FormatTooNew {
                file: file.to_string(),
            })
        }
        _ => Err(TrustError::Malformed {
            file: file.to_string(),
            detail: "format must be 1".into(),
        }),
    }
}

fn decode(
    text: &str,
    len: Option<usize>,
    max: usize,
    what: &str,
    file: &str,
) -> Result<Vec<u8>, TrustError> {
    let malformed = |detail: String| TrustError::Malformed {
        file: file.to_string(),
        detail,
    };
    if text.len() > max.div_ceil(3) * 4 {
        return Err(malformed(format!("{what} is too long")));
    }
    let bytes = Base64::decode_vec(text).map_err(|_| malformed(format!("{what} is not base64")))?;
    match len {
        Some(n) if bytes.len() != n => Err(malformed(format!("{what} is not {n} bytes"))),
        _ => Ok(bytes),
    }
}

fn open_inner(
    format: &Value,
    key: &str,
    statement: &str,
    sig: &str,
    domain: Domain,
    file: &str,
) -> Result<Opened, TrustError> {
    check_format(format, file)?;
    let key_bytes = decode(key, Some(32), 32, "key", file)?;
    let statement = decode(statement, None, MAX_STATEMENT_BYTES, "statement", file)?;
    let sig_bytes = decode(sig, Some(64), 64, "sig", file)?;
    if statement.len() > MAX_STATEMENT_BYTES {
        return Err(TrustError::Malformed {
            file: file.to_string(),
            detail: format!("the statement is larger than {MAX_STATEMENT_BYTES} bytes"),
        });
    }
    let key = PublicKey::from_bytes(&key_bytes).map_err(|f| match f {
        KeyFault::Weak => TrustError::WeakKey {
            file: file.to_string(),
        },
        KeyFault::Invalid => TrustError::Malformed {
            file: file.to_string(),
            detail: "key is not an Ed25519 public key".into(),
        },
    })?;
    let sig: [u8; 64] = sig_bytes
        .as_slice()
        .try_into()
        .expect("decode checked the length");
    let mut message = domain.prefix().to_vec();
    message.extend_from_slice(&statement);
    if !key.verify(&message, &sig) {
        return Err(TrustError::BadSignature {
            file: file.to_string(),
        });
    }
    Ok(Opened { key, statement })
}

/// Read and verify an envelope for `domain`. `rotations` are refused here: only `play.sig` carries
/// them ([`open_play_sig`]).
pub fn open(bytes: &[u8], domain: Domain, file: &str) -> Result<Opened, TrustError> {
    let raw: RawInner = strict_json(bytes, MAX_SIG_FILE_BYTES, MAX_SIG_DEPTH, file)?;
    open_inner(
        &raw.format,
        &raw.key,
        &raw.statement,
        &raw.sig,
        domain,
        file,
    )
}

/// Read and verify `play.sig`: the developer's envelope plus the rotation envelopes it carries
/// (each verified for [`Domain::Rotation`]; their meaning is checked by the caller).
pub fn open_play_sig(bytes: &[u8]) -> Result<(Opened, Vec<Opened>), TrustError> {
    let file = "play.sig";
    let raw: RawEnvelope = strict_json(bytes, MAX_SIG_FILE_BYTES, MAX_SIG_DEPTH, file)?;
    let outer = open_inner(
        &raw.format,
        &raw.key,
        &raw.statement,
        &raw.sig,
        Domain::PlaySig,
        file,
    )?;
    let inner = raw.rotations.unwrap_or_default();
    if inner.len() > MAX_ROTATIONS {
        return Err(TrustError::Malformed {
            file: file.to_string(),
            detail: format!("it carries more than {MAX_ROTATIONS} rotations"),
        });
    }
    let mut rotations = Vec::with_capacity(inner.len());
    for (i, r) in inner.iter().enumerate() {
        let name = format!("play.sig rotation {}", i + 1);
        rotations.push(open_inner(
            &r.format,
            &r.key,
            &r.statement,
            &r.sig,
            Domain::Rotation,
            &name,
        )?);
    }
    Ok((outer, rotations))
}

/// The envelope bytes of `statement` signed by `key` for `domain`.
pub fn seal(key: &SecretKey, domain: Domain, statement: &[u8]) -> Vec<u8> {
    seal_with(key, domain, statement, &[]).expect("no rotations to read")
}

/// The envelope bytes of `statement` signed by `key`, carrying the already sealed `rotations`
/// (each the output of [`seal`] for [`Domain::Rotation`]). Only `play.sig` uses this; a rotation
/// that is not an envelope is refused.
pub fn seal_with(
    key: &SecretKey,
    domain: Domain,
    statement: &[u8],
    rotations: &[&[u8]],
) -> Result<Vec<u8>, TrustError> {
    let mut inner = Vec::with_capacity(rotations.len());
    for r in rotations {
        inner.push(strict_json::<RawInner>(
            r,
            MAX_SIG_FILE_BYTES,
            MAX_SIG_DEPTH,
            "rotation",
        )?);
    }
    let mut message = domain.prefix().to_vec();
    message.extend_from_slice(statement);
    let sig = key.sign_raw(&message);
    let env = RawEnvelope {
        format: Value::from(ENVELOPE_FORMAT),
        key: key.public().to_base64(),
        statement: Base64::encode_string(statement),
        sig: Base64::encode_string(&sig),
        rotations: (!inner.is_empty()).then_some(inner),
    };
    let mut out = serde_json::to_vec_pretty(&env).expect("an envelope is always JSON");
    out.push(b'\n');
    Ok(out)
}
