//! Signing and verifying a package: `play.sig` (the developer), the rotations it carries, and
//! `store.sig` (the store's countersignature against a pinned store key). A bad signature is an
//! error, never a downgrade to `unverified` (05 §9.2).

use crate::envelope::{self, Domain, Opened};
use crate::error::TrustError;
use crate::keys::{sha256_hex, PublicKey, SecretKey};
use crate::statement::{PlayStatement, RotationStatement, StoreStatement};
use crate::time::UnixSeconds;
use ruya_play_format::Manifest;

/// The store's public keys the image pins (more than one while the store key is being rotated
/// through an OS update). Tests generate theirs; the real key arrives with the image work.
#[derive(Debug, Clone, Default)]
pub struct StoreKeys(Vec<PublicKey>);

impl StoreKeys {
    /// These keys.
    pub fn new(keys: Vec<PublicKey>) -> StoreKeys {
        StoreKeys(keys)
    }

    /// No store key: nothing can be `official`.
    pub fn none() -> StoreKeys {
        StoreKeys(Vec::new())
    }

    /// True when `key` is pinned.
    pub fn contains(&self, key: &PublicKey) -> bool {
        self.0.contains(key)
    }
}

/// The four metadata files of a package as bounded bytes (`None` when the file is absent).
#[derive(Debug, Clone, Copy)]
pub struct PackageBytes<'a> {
    /// `play.json`.
    pub play_json: &'a [u8],
    /// `play.files`.
    pub play_files: &'a [u8],
    /// `play.sig`.
    pub play_sig: Option<&'a [u8]>,
    /// `store.sig`.
    pub store_sig: Option<&'a [u8]>,
}

/// A verified developer signature.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeveloperSignature {
    /// The developer's key.
    pub key: PublicKey,
    /// What it states.
    pub statement: PlayStatement,
    /// The rotations `play.sig` carries, in file order; their order of use is the continuity
    /// rule's job.
    pub rotations: Vec<RotationStatement>,
}

/// A verified store countersignature.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoreSignature {
    /// The pinned store key that signed.
    pub key: PublicKey,
    /// What it states.
    pub statement: StoreStatement,
}

/// What the signatures of a package prove.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Signatures {
    /// `play.sig`, when present.
    pub developer: Option<DeveloperSignature>,
    /// `store.sig`, when present (only with `play.sig`).
    pub store: Option<StoreSignature>,
}

impl Signatures {
    /// The developer's key, when signed.
    pub fn key(&self) -> Option<&PublicKey> {
        self.developer.as_ref().map(|d| &d.key)
    }
}

fn rotation_of(opened: Opened, id: &str, file: &str) -> Result<RotationStatement, TrustError> {
    let statement = RotationStatement::parse(&opened.statement, file)?;
    if opened.key != statement.old_key {
        return Err(TrustError::RotationNotByOldKey {
            file: file.to_string(),
        });
    }
    if !statement.id.eq_ignore_ascii_case(id) {
        return Err(TrustError::RotationWrongId {
            file: file.to_string(),
        });
    }
    Ok(statement)
}

/// Verify the signatures of a package: `play.sig` must verify and name exactly these `play.json`
/// and `play.files` bytes; every rotation it carries must verify and be signed by its old key;
/// `store.sig` must be by a pinned store key and countersign exactly this `play.sig` for the same
/// id and build. The id and build still have to match the manifest ([`bind_to_manifest`]).
pub fn verify_signatures(
    bytes: &PackageBytes<'_>,
    store_keys: &StoreKeys,
) -> Result<Signatures, TrustError> {
    let Some(play_sig) = bytes.play_sig else {
        if bytes.store_sig.is_some() {
            return Err(TrustError::StoreSigWithoutPlaySig);
        }
        return Ok(Signatures::default());
    };
    let (outer, inner) = envelope::open_play_sig(play_sig)?;
    let statement = PlayStatement::parse(&outer.statement)?;
    if sha256_hex(bytes.play_json) != statement.play_json_sha256 {
        return Err(TrustError::PlayJsonChanged);
    }
    if sha256_hex(bytes.play_files) != statement.play_files_sha256 {
        return Err(TrustError::PlayFilesChanged);
    }
    let mut rotations = Vec::with_capacity(inner.len());
    for (i, r) in inner.into_iter().enumerate() {
        rotations.push(rotation_of(
            r,
            &statement.id,
            &format!("play.sig rotation {}", i + 1),
        )?);
    }
    let developer = DeveloperSignature {
        key: outer.key,
        statement,
        rotations,
    };

    let store = match bytes.store_sig {
        None => None,
        Some(store_sig) => Some(verify_store_sig(
            store_sig,
            play_sig,
            &developer.statement,
            store_keys,
        )?),
    };
    Ok(Signatures {
        developer: Some(developer),
        store,
    })
}

fn verify_store_sig(
    store_sig: &[u8],
    play_sig: &[u8],
    play: &PlayStatement,
    store_keys: &StoreKeys,
) -> Result<StoreSignature, TrustError> {
    let file = "store.sig";
    let opened = envelope::open(store_sig, Domain::StoreSig, file)?;
    if !store_keys.contains(&opened.key) {
        return Err(TrustError::StoreKeyUnknown {
            key_id: opened.key.key_id(),
        });
    }
    let statement = StoreStatement::parse(&opened.statement)?;
    if sha256_hex(play_sig) != statement.play_sig_sha256 {
        return Err(TrustError::PlaySigChanged);
    }
    if statement.id != play.id {
        return Err(TrustError::WrongId {
            file: file.into(),
            signed: statement.id,
            package: play.id.clone(),
        });
    }
    if statement.build != play.build {
        return Err(TrustError::WrongBuild {
            file: file.into(),
            signed: statement.build,
            package: play.build,
        });
    }
    Ok(StoreSignature {
        key: opened.key,
        statement,
    })
}

/// The signed id and build must be exactly the manifest's (the hashes already bind its bytes; this
/// refuses a signature made for another package that was copied in with its `play.json`).
pub fn bind_to_manifest(sigs: &Signatures, manifest: &Manifest) -> Result<(), TrustError> {
    let Some(dev) = &sigs.developer else {
        return Ok(());
    };
    if dev.statement.id != manifest.id {
        return Err(TrustError::WrongId {
            file: "play.sig".into(),
            signed: dev.statement.id.clone(),
            package: manifest.id.clone(),
        });
    }
    if dev.statement.build != manifest.build {
        return Err(TrustError::WrongBuild {
            file: "play.sig".into(),
            signed: dev.statement.build,
            package: manifest.build,
        });
    }
    Ok(())
}

/// The `play.sig` bytes for a package: `key` signs `id`, `build` and the SHA-256 of `play_json`
/// and `play_files`, carrying the sealed `rotations` ([`sign_rotation`]). For `ruya-pack` (T-233).
pub fn sign_package(
    key: &SecretKey,
    id: &str,
    build: u64,
    play_json: &[u8],
    play_files: &[u8],
    signed_at: UnixSeconds,
    rotations: &[&[u8]],
) -> Result<Vec<u8>, TrustError> {
    let statement = PlayStatement {
        id: id.to_string(),
        build,
        play_json_sha256: sha256_hex(play_json),
        play_files_sha256: sha256_hex(play_files),
        signed_at,
    };
    envelope::seal_with(key, Domain::PlaySig, &statement.to_bytes(), rotations)
}

/// The `store.sig` bytes: the store `key` countersigns exactly `play_sig` for `id` and `build`.
pub fn countersign(
    key: &SecretKey,
    id: &str,
    build: u64,
    play_sig: &[u8],
    signed_at: UnixSeconds,
) -> Vec<u8> {
    let statement = StoreStatement {
        id: id.to_string(),
        build,
        play_sig_sha256: sha256_hex(play_sig),
        signed_at,
    };
    envelope::seal(key, Domain::StoreSig, &statement.to_bytes())
}

/// A sealed rotation: `old` hands `id` to `new_key` as rotation number `seq` (at least 1).
pub fn sign_rotation(
    old: &SecretKey,
    id: &str,
    new_key: &PublicKey,
    seq: u64,
    signed_at: UnixSeconds,
) -> Vec<u8> {
    let statement = RotationStatement {
        id: id.to_string(),
        old_key: old.public(),
        new_key: new_key.clone(),
        seq,
        signed_at,
    };
    envelope::seal(old, Domain::Rotation, &statement.to_bytes())
}
