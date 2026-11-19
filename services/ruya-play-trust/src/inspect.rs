//! The importer's inspect step in the order of 05 §7.3: read `play.json`, `play.files`, `play.sig`
//! and `store.sig` as bounded bytes; verify the signatures; decide the tier; run the full format
//! validation with `official` set only from a verified `store.sig`; then the id and build binding,
//! key continuity, the tier's permission ceiling and revocation.

use crate::continuity::{continuity_of, Continuity};
use crate::envelope::MAX_SIG_FILE_BYTES;
use crate::error::TrustError;
use crate::keys::sha256_hex;
use crate::revocation::{is_revoked, ListCheck, PackageFacts};
use crate::signing::{bind_to_manifest, verify_signatures, PackageBytes, Signatures, StoreKeys};
use crate::store::TrustStore;
use crate::tier::{check_ceiling, decide_tier, Assessment, TierDecision};
use ruya_play_format::limits::{MAX_MANIFEST_BYTES, MAX_TABLE_BYTES};
use ruya_play_format::{validate, EntryKind, Package, Problem, Source, ValidateOptions};

/// What the inspect step needs besides the package.
pub struct Context<'a> {
    /// The pinned store keys.
    pub store_keys: &'a StoreKeys,
    /// Key records and the developer-mode flag (read only here).
    pub trust: &'a dyn TrustStore,
    /// The blocklist check ([`ListCheck::of`] the result of
    /// [`crate::revocation::select_blocklist`]); an unavailable list refuses every package.
    pub blocklist: ListCheck<'a>,
    /// Hashes of the runner the package will use, when known.
    pub runner_hashes: &'a [String],
    /// Hash every file against `play.files` (the format crate's `verify_content`).
    pub verify_content: bool,
}

/// A package that may be installed, and everything the confirm page and the commit step need.
#[derive(Debug, Clone)]
pub struct Inspection {
    /// The validated package.
    pub package: Package,
    /// The verified signatures.
    pub signatures: Signatures,
    /// Its tier.
    pub tier: TierDecision,
    /// How its key relates to the id's record (recorded after the commit).
    pub continuity: Continuity,
    /// Its requests under the tier's ceiling; `gate` is what the admin flow applies.
    pub assessment: Assessment,
    /// SHA-256 of `play.files`.
    pub play_files_sha256: String,
}

impl Inspection {
    /// The facts the revocation check uses.
    pub fn facts(&self) -> PackageFacts {
        let mut key_ids: Vec<String> = self
            .signatures
            .key()
            .map(|k| k.key_id())
            .into_iter()
            .collect();
        if let Some(s) = &self.signatures.store {
            key_ids.push(s.key.key_id());
        }
        PackageFacts {
            id: self.package.manifest.id.clone(),
            build: self.package.manifest.build,
            key_ids,
            play_files_sha256: self.play_files_sha256.clone(),
        }
    }
}

/// Why a package is refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// A trust rule.
    Trust(TrustError),
    /// The format's rules (05 §4).
    Format(Vec<Problem>),
}

impl Refusal {
    /// The refusal as the one problem list the importer reports.
    pub fn problems(&self) -> Vec<Problem> {
        match self {
            Refusal::Trust(e) => vec![e.to_problem()],
            Refusal::Format(p) => p.clone(),
        }
    }

    /// The trust error, if it is one.
    pub fn trust(&self) -> Option<&TrustError> {
        match self {
            Refusal::Trust(e) => Some(e),
            Refusal::Format(_) => None,
        }
    }
}

impl From<TrustError> for Refusal {
    fn from(e: TrustError) -> Self {
        Refusal::Trust(e)
    }
}

/// Read a root file that is listed as a regular file of at most `limit` bytes. `Ok(None)` when it
/// is absent or not such a file: the format validation reports that.
fn read_root(
    source: &dyn Source,
    entries: &[ruya_play_format::Entry],
    name: &str,
    limit: u64,
) -> Result<Option<Vec<u8>>, Refusal> {
    let Some(e) = entries.iter().find(|e| e.path == name) else {
        return Ok(None);
    };
    if e.kind != EntryKind::File || e.size > limit {
        return Ok(None);
    }
    match ruya_play_format::read_small(source, name, limit) {
        Ok(buf) if buf.len() as u64 <= limit => Ok(Some(buf)),
        Ok(_) => Ok(None),
        Err(p) => Err(Refusal::Format(vec![p])),
    }
}

/// Inspect a package. See the module text for the order.
pub fn inspect(source: &dyn Source, ctx: &Context<'_>) -> Result<Inspection, Refusal> {
    if let ListCheck::Unavailable(e) = ctx.blocklist {
        return Err(Refusal::Trust(e.clone()));
    }
    let entries = source.entries().map_err(Refusal::Format)?;
    let sig_limit = MAX_SIG_FILE_BYTES as u64;
    let too_big = |name: &str| TrustError::Malformed {
        file: name.to_string(),
        detail: format!("it is larger than {MAX_SIG_FILE_BYTES} bytes or not a regular file"),
    };
    let listed = |name: &str| entries.iter().any(|e| e.path == name);
    let play_sig = read_root(source, &entries, "play.sig", sig_limit)?;
    if play_sig.is_none() && listed("play.sig") {
        return Err(too_big("play.sig").into());
    }
    let store_sig = read_root(source, &entries, "store.sig", sig_limit)?;
    if store_sig.is_none() && listed("store.sig") {
        return Err(too_big("store.sig").into());
    }
    let play_json = read_root(source, &entries, "play.json", MAX_MANIFEST_BYTES)?;
    let play_files = read_root(source, &entries, "play.files", MAX_TABLE_BYTES)?;

    let opts = |official: bool| ValidateOptions {
        verify_content: ctx.verify_content,
        official,
    };
    let (Some(play_json), Some(play_files)) = (play_json, play_files) else {
        // Nothing to verify against: the format names what is missing or wrong.
        return Err(match validate(source, &opts(false)) {
            Err(p) => Refusal::Format(p),
            Ok(_) => Refusal::Format(vec![Problem::new(
                ruya_play_format::codes::PACKAGE_READ_FAILED,
                "",
                "play.json or play.files could not be read.",
            )]),
        });
    };

    let signatures = verify_signatures(
        &PackageBytes {
            play_json: &play_json,
            play_files: &play_files,
            play_sig: play_sig.as_deref(),
            store_sig: store_sig.as_deref(),
        },
        ctx.store_keys,
    )?;
    let tier = decide_tier(&signatures, ctx.trust.developer_mode()?)?;
    let official = tier.tier == crate::tier::Tier::Official;
    let package = validate(source, &opts(official)).map_err(Refusal::Format)?;
    bind_to_manifest(&signatures, &package.manifest)?;
    let continuity = continuity_of(ctx.trust, &package.manifest.id, &signatures)?;
    let assessment = check_ceiling(tier.tier, &package.manifest.permissions)?;
    let inspection = Inspection {
        package,
        signatures,
        tier,
        continuity,
        assessment,
        play_files_sha256: sha256_hex(&play_files),
    };
    if let ListCheck::Use(list) = ctx.blocklist {
        if let Some(revoked) = is_revoked(list, &inspection.facts(), ctx.runner_hashes) {
            return Err(revoked.into());
        }
    }
    Ok(inspection)
}
