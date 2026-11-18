//! How far a `.play` package is trusted (docs/specs/05-play-packages.md §8, §9.2): the signature
//! encoding and its verifier, the tiers `official`, `developer` and `unverified`, the permission
//! ceilings by tier as data, the one permission table (vocabulary to Flatpak metadata, words and
//! risk), the trust record a commit leaves in the app, key continuity (trust on first use,
//! rotation, forget), and revocation through the store blocklist.
//!
//! Pure rules on top of `ruya-play-format`: no D-Bus, no network, no clock (the caller passes
//! `now`), state only through the [`TrustStore`] trait. The importer (RUY-99) calls [`inspect`],
//! which keeps the order of 05 §7.3: verify, then tier, then `validate` with `official` set only
//! from a verified `store.sig`.
//!
//! ```
//! use ruya_play_trust::{generate_key, sign_package, verify_signatures, PackageBytes, StoreKeys};
//! let key = generate_key().unwrap();
//! let (json, files) = (b"{}".as_slice(), b"".as_slice());
//! let sig = sign_package(&key, "com.example.game", 1, json, files, 0, &[]).unwrap();
//! let bytes = PackageBytes { play_json: json, play_files: files, play_sig: Some(&sig), store_sig: None };
//! let sigs = verify_signatures(&bytes, &StoreKeys::none()).unwrap();
//! assert_eq!(sigs.key(), Some(&key.public()));
//! ```

pub mod continuity;
pub mod envelope;
pub mod error;
pub mod inspect;
pub mod keys;
pub mod permissions;
pub mod revocation;
pub mod signing;
pub mod statement;
pub mod store;
pub mod tier;
pub mod time;
pub mod trust_record;

pub use continuity::{
    check_continuity, continuity_of, forget, record_install, record_uninstall, Continuity,
};
pub use error::{codes, RevokedBy, TrustError};
pub use inspect::{inspect, Context, Inspection, Refusal};
pub use keys::{generate_key, PublicKey, SecretKey};
pub use permissions::{
    diff, grants, metadata_sections, words, Grant, Permission, PermissionDiff, Section,
    HIGH_RISK_PAIRS, PERMISSIONS,
};
pub use revocation::{
    is_revoked, select_blocklist, sign_blocklist, verify_downloaded, Blocklist, ListCheck,
    ListSource, PackageFacts, Selected,
};
pub use signing::{
    bind_to_manifest, countersign, sign_package, sign_rotation, verify_signatures,
    DeveloperSignature, PackageBytes, Signatures, StoreKeys, StoreSignature,
};
pub use store::{FileTrustStore, IdRecord, MemoryTrustStore, TrustStore};
pub use tier::{
    assess, ceiling, check_ceiling, decide_tier, Assessment, Ceiling, Gate, Request, Risk, Tier,
    TierDecision, TierReason, CEILINGS,
};
pub use trust_record::TrustRecord;
