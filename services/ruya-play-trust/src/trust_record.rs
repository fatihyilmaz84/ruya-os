//! The trust record (05 §7.1, RUY-851): what the console decided about a package when it installed
//! it, written by the commit into the app as `share/ruyaos/play/trust.json` (in the deployment:
//! `files/share/ruyaos/play/trust.json`) next to the vetted art. A package cannot ship it: a
//! package with a top-level `share/` is refused, because the console writes that folder itself.
//! `ruya-library` reads it for the item's tier and signer and never verifies a signature itself.
//!
//! ```json
//! {"format":1,"tier":"developer","signer_id":"3f9a41c07be2d6058e21b4a9d0c7f312","signer_name":"Example Games","store_signed":false}
//! ```

use crate::signing::Signatures;
use crate::tier::Tier;
use ruya_play_format::manifest::Manifest;
use serde::{Deserialize, Serialize};

/// The record's format; a reader refuses another.
pub const TRUST_RECORD_FORMAT: u64 = 1;

/// The most bytes a reader takes of a record.
pub const MAX_TRUST_RECORD_BYTES: usize = 4096;

/// `trust.json`. Keys in this order; `signer_id` and `signer_name` are `null` when absent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrustRecord {
    /// [`TRUST_RECORD_FORMAT`].
    pub format: u64,
    /// `official`, `developer` or `unverified`.
    pub tier: String,
    /// The developer key's id (32 hex characters, 05 §9.2); `null` for an unsigned package.
    pub signer_id: Option<String>,
    /// The manifest's `developer.name`, which the developer's signature covers (self-asserted:
    /// the key, not the name, is what was verified); `null` for an unsigned package or one
    /// without a developer.
    pub signer_name: Option<String>,
    /// A store countersignature by a pinned store key was verified (the tier is `official`).
    pub store_signed: bool,
}

impl TrustRecord {
    /// The record of a package the console verified: its tier, from the verified signatures (never
    /// from the package's own files).
    pub fn of(tier: Tier, signatures: &Signatures, manifest: &Manifest) -> TrustRecord {
        let key = signatures.key();
        TrustRecord {
            format: TRUST_RECORD_FORMAT,
            tier: tier.as_str().to_string(),
            signer_id: key.map(|k| k.key_id()),
            signer_name: Self::signer_name(signatures, manifest),
            store_signed: signatures.store.is_some(),
        }
    }

    /// The name a verified signature stands behind: the manifest's `developer.name`, only for a
    /// package with a developer key (the signature covers the manifest; the key, not the name, is
    /// what was verified). `None` for an unsigned package or one without a `developer`. The one
    /// rule behind this record's `signer_name` and Play1's Inspect `signer_name`.
    pub fn signer_name(signatures: &Signatures, manifest: &Manifest) -> Option<String> {
        signatures
            .key()
            .and(manifest.developer.as_ref())
            .map(|d| d.name.clone())
    }

    /// The file's bytes: one line of JSON.
    pub fn to_json(&self) -> String {
        let mut s = serde_json::to_string(self).expect("a record of strings and bools serialises");
        s.push('\n');
        s
    }

    /// Read a record; `None` when it is too big, not JSON, of another format or names no tier.
    pub fn parse(bytes: &[u8]) -> Option<TrustRecord> {
        if bytes.len() > MAX_TRUST_RECORD_BYTES {
            return None;
        }
        let r: TrustRecord = serde_json::from_slice(bytes).ok()?;
        (r.format == TRUST_RECORD_FORMAT && r.tier().is_some()).then_some(r)
    }

    /// The tier the record names; `None` for a name that is not a tier.
    pub fn tier(&self) -> Option<Tier> {
        [Tier::Official, Tier::Developer, Tier::Unverified]
            .into_iter()
            .find(|t| t.as_str() == self.tier)
    }
}
