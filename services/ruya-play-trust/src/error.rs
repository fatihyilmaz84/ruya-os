//! Why a package, a signature, a list or the trust state is refused: one enum, each variant with a
//! stable dotted code (05 §9.2) and English text. It turns into the format crate's [`Problem`], so
//! the importer reports trust faults and format faults in one list.

use ruya_play_format::problem::{quote, Problem};

/// Stable error codes. The shell maps them to translated text; the importer's D-Bus status strings
/// are derived from them (RUY-96).
pub mod codes {
    /// A signed file (`play.sig`, `store.sig`, a rotation, the blocklist signature) is not the
    /// envelope or statement of 05 §9.2: not JSON, a missing or unknown key, bad base64, a wrong length.
    pub const SIG_MALFORMED: &str = "sig.malformed";
    /// A signed file names one JSON key twice.
    pub const SIG_DUPLICATE_KEY: &str = "sig.duplicate_key";
    /// A signed file's `format` is newer than this console knows.
    pub const SIG_FORMAT_TOO_NEW: &str = "sig.format_too_new";
    /// The Ed25519 signature does not verify: the file was changed after it was signed.
    pub const SIG_BAD_SIGNATURE: &str = "sig.bad_signature";
    /// The public key is a weak (small-order) Ed25519 point.
    pub const SIG_WEAK_KEY: &str = "sig.weak_key";
    /// `play.json` is not the one `play.sig` signed.
    pub const SIG_PLAY_JSON_CHANGED: &str = "sig.play_json_changed";
    /// `play.files` is not the one `play.sig` signed.
    pub const SIG_PLAY_FILES_CHANGED: &str = "sig.play_files_changed";
    /// The signature is for another `id`.
    pub const SIG_WRONG_ID: &str = "sig.wrong_id";
    /// The signature is for another `build`.
    pub const SIG_WRONG_BUILD: &str = "sig.wrong_build";
    /// The rotations `play.sig` carries are not the ones its statement names (`rotations_sha256`).
    pub const SIG_ROTATIONS_CHANGED: &str = "sig.rotations_changed";
    /// `store.sig` without `play.sig`.
    pub const STORE_SIG_WITHOUT_PLAY_SIG: &str = "store_sig.without_play_sig";
    /// `play.sig` is not the one `store.sig` countersigned.
    pub const STORE_SIG_PLAY_SIG_CHANGED: &str = "store_sig.play_sig_changed";
    /// A rotation statement is not signed by the key it hands over from.
    pub const ROTATION_NOT_BY_OLD_KEY: &str = "rotation.not_by_old_key";
    /// A rotation statement whose `seq` is not above the one this console applied last.
    pub const ROTATION_REPLAYED: &str = "rotation.replayed";
    /// A rotation statement for another `id`.
    pub const ROTATION_WRONG_ID: &str = "rotation.wrong_id";
    /// A rotation hands the id to a key this console retired for it.
    pub const ROTATION_TO_RETIRED_KEY: &str = "rotation.to_retired_key";
    /// An unsigned package while developer mode is off.
    pub const TRUST_NEEDS_DEVELOPER_MODE: &str = "trust.needs_developer_mode";
    /// The id is owned by another key on this console (trust on first use).
    pub const TRUST_DIFFERENT_DEVELOPER: &str = "trust.different_developer";
    /// A permission is above the ceiling of the package's tier: the package cannot be installed.
    pub const CEILING_REFUSED: &str = "ceiling.refused";
    /// Revoked: the signing key is on the blocklist.
    pub const REVOKED_KEY: &str = "revoked.key";
    /// Revoked: this id and build are on the blocklist.
    pub const REVOKED_ID: &str = "revoked.id";
    /// Revoked: the package content (its `play.files`) is on the blocklist.
    pub const REVOKED_CONTENT: &str = "revoked.content";
    /// Revoked: the runner the package uses is on the blocklist.
    pub const REVOKED_RUNNER: &str = "revoked.runner";
    /// The blocklist text breaks its grammar (05 §9.2).
    pub const BLOCKLIST_MALFORMED: &str = "blocklist.malformed";
    /// A downloaded blocklist is not signed by a pinned store key.
    pub const BLOCKLIST_NOT_STORE_KEY: &str = "blocklist.not_store_key";
    /// A downloaded blocklist is not the text its signature covers.
    pub const BLOCKLIST_CHANGED: &str = "blocklist.changed";
    /// A downloaded blocklist is past its `expires`.
    pub const BLOCKLIST_EXPIRED: &str = "blocklist.expired";
    /// A downloaded blocklist is not newer than the image's copy.
    pub const BLOCKLIST_NOT_NEWER: &str = "blocklist.not_newer";
    /// The image's blocklist is missing or cannot be read: installs are refused (fail closed).
    pub const BLOCKLIST_UNAVAILABLE: &str = "blocklist.unavailable";
    /// The trust state file cannot be read as written (never reset silently).
    pub const STATE_CORRUPT: &str = "state.corrupt";
    /// The trust state file could not be read or written.
    pub const STATE_IO: &str = "state.io";

    /// Every code, for the tests that keep the list, the tests and the spec in step.
    pub const ALL: &[&str] = &[
        SIG_MALFORMED,
        SIG_DUPLICATE_KEY,
        SIG_FORMAT_TOO_NEW,
        SIG_BAD_SIGNATURE,
        SIG_WEAK_KEY,
        SIG_PLAY_JSON_CHANGED,
        SIG_PLAY_FILES_CHANGED,
        SIG_WRONG_ID,
        SIG_WRONG_BUILD,
        SIG_ROTATIONS_CHANGED,
        STORE_SIG_WITHOUT_PLAY_SIG,
        STORE_SIG_PLAY_SIG_CHANGED,
        ROTATION_NOT_BY_OLD_KEY,
        ROTATION_REPLAYED,
        ROTATION_WRONG_ID,
        ROTATION_TO_RETIRED_KEY,
        TRUST_NEEDS_DEVELOPER_MODE,
        TRUST_DIFFERENT_DEVELOPER,
        CEILING_REFUSED,
        REVOKED_KEY,
        REVOKED_ID,
        REVOKED_CONTENT,
        REVOKED_RUNNER,
        BLOCKLIST_MALFORMED,
        BLOCKLIST_NOT_STORE_KEY,
        BLOCKLIST_CHANGED,
        BLOCKLIST_EXPIRED,
        BLOCKLIST_NOT_NEWER,
        BLOCKLIST_UNAVAILABLE,
        STATE_CORRUPT,
        STATE_IO,
    ];
}

/// Which kind of revocation entry matched.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RevokedBy {
    /// A `key` line: the signing key id.
    Key,
    /// An `id` line: the id and a build range.
    Id,
    /// A `content` line: the SHA-256 of `play.files`.
    Content,
    /// A `runner` line: the hash of the runner the package uses.
    Runner,
}

/// Why something is refused. `file` is the file the fault is in (`play.sig`, `store.sig`,
/// `play.sig rotation 2`, `store-blocklist.sig`, ...): it becomes the problem's `path`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TrustError {
    /// See [`codes::SIG_MALFORMED`].
    Malformed { file: String, detail: String },
    /// See [`codes::SIG_DUPLICATE_KEY`]; `pointer` is the object's JSON pointer.
    DuplicateKey { file: String, pointer: String },
    /// See [`codes::SIG_FORMAT_TOO_NEW`].
    FormatTooNew { file: String },
    /// See [`codes::SIG_BAD_SIGNATURE`].
    BadSignature { file: String },
    /// See [`codes::SIG_WEAK_KEY`].
    WeakKey { file: String },
    /// See [`codes::SIG_PLAY_JSON_CHANGED`].
    PlayJsonChanged,
    /// See [`codes::SIG_PLAY_FILES_CHANGED`].
    PlayFilesChanged,
    /// See [`codes::SIG_WRONG_ID`].
    WrongId {
        file: String,
        signed: String,
        package: String,
    },
    /// See [`codes::SIG_WRONG_BUILD`].
    WrongBuild {
        file: String,
        signed: u64,
        package: u64,
    },
    /// See [`codes::SIG_ROTATIONS_CHANGED`].
    RotationsChanged,
    /// See [`codes::STORE_SIG_WITHOUT_PLAY_SIG`].
    StoreSigWithoutPlaySig,
    /// See [`codes::STORE_SIG_PLAY_SIG_CHANGED`].
    PlaySigChanged,
    /// See [`codes::ROTATION_NOT_BY_OLD_KEY`].
    RotationNotByOldKey { file: String },
    /// See [`codes::ROTATION_REPLAYED`].
    RotationReplayed { seq: u64, applied: u64 },
    /// See [`codes::ROTATION_WRONG_ID`].
    RotationWrongId { file: String },
    /// See [`codes::ROTATION_TO_RETIRED_KEY`].
    RotationToRetiredKey { key_id: String },
    /// See [`codes::TRUST_NEEDS_DEVELOPER_MODE`].
    NeedsDeveloperMode,
    /// See [`codes::TRUST_DIFFERENT_DEVELOPER`]. `found` is `None` for an unsigned package.
    DifferentDeveloper {
        id: String,
        known: String,
        found: Option<String>,
    },
    /// See [`codes::CEILING_REFUSED`]; `permission` is the high-risk request.
    CeilingRefused { tier: String, permission: String },
    /// One of the `revoked.*` codes; `reason` is the blocklist's text.
    Revoked { by: RevokedBy, reason: String },
    /// See [`codes::BLOCKLIST_MALFORMED`]; `line` is 1-based, 0 for the whole file.
    BlocklistMalformed { line: usize, detail: String },
    /// See [`codes::BLOCKLIST_NOT_STORE_KEY`].
    BlocklistNotStoreKey { key_id: String },
    /// See [`codes::BLOCKLIST_CHANGED`].
    BlocklistChanged,
    /// See [`codes::BLOCKLIST_EXPIRED`].
    BlocklistExpired { expires: String },
    /// See [`codes::BLOCKLIST_NOT_NEWER`].
    BlocklistNotNewer { serial: u64, image: u64 },
    /// See [`codes::BLOCKLIST_UNAVAILABLE`].
    BlocklistUnavailable { detail: String },
    /// See [`codes::STATE_CORRUPT`].
    StateCorrupt { detail: String },
    /// See [`codes::STATE_IO`].
    StateIo { detail: String },
}

impl TrustError {
    /// The stable code.
    pub fn code(&self) -> &'static str {
        use TrustError::*;
        match self {
            Malformed { .. } => codes::SIG_MALFORMED,
            DuplicateKey { .. } => codes::SIG_DUPLICATE_KEY,
            FormatTooNew { .. } => codes::SIG_FORMAT_TOO_NEW,
            BadSignature { .. } => codes::SIG_BAD_SIGNATURE,
            WeakKey { .. } => codes::SIG_WEAK_KEY,
            PlayJsonChanged => codes::SIG_PLAY_JSON_CHANGED,
            PlayFilesChanged => codes::SIG_PLAY_FILES_CHANGED,
            WrongId { .. } => codes::SIG_WRONG_ID,
            WrongBuild { .. } => codes::SIG_WRONG_BUILD,
            RotationsChanged => codes::SIG_ROTATIONS_CHANGED,
            StoreSigWithoutPlaySig => codes::STORE_SIG_WITHOUT_PLAY_SIG,
            PlaySigChanged => codes::STORE_SIG_PLAY_SIG_CHANGED,
            RotationNotByOldKey { .. } => codes::ROTATION_NOT_BY_OLD_KEY,
            RotationReplayed { .. } => codes::ROTATION_REPLAYED,
            RotationWrongId { .. } => codes::ROTATION_WRONG_ID,
            RotationToRetiredKey { .. } => codes::ROTATION_TO_RETIRED_KEY,
            NeedsDeveloperMode => codes::TRUST_NEEDS_DEVELOPER_MODE,
            DifferentDeveloper { .. } => codes::TRUST_DIFFERENT_DEVELOPER,
            CeilingRefused { .. } => codes::CEILING_REFUSED,
            Revoked { by, .. } => match by {
                RevokedBy::Key => codes::REVOKED_KEY,
                RevokedBy::Id => codes::REVOKED_ID,
                RevokedBy::Content => codes::REVOKED_CONTENT,
                RevokedBy::Runner => codes::REVOKED_RUNNER,
            },
            BlocklistMalformed { .. } => codes::BLOCKLIST_MALFORMED,
            BlocklistNotStoreKey { .. } => codes::BLOCKLIST_NOT_STORE_KEY,
            BlocklistChanged => codes::BLOCKLIST_CHANGED,
            BlocklistExpired { .. } => codes::BLOCKLIST_EXPIRED,
            BlocklistNotNewer { .. } => codes::BLOCKLIST_NOT_NEWER,
            BlocklistUnavailable { .. } => codes::BLOCKLIST_UNAVAILABLE,
            StateCorrupt { .. } => codes::STATE_CORRUPT,
            StateIo { .. } => codes::STATE_IO,
        }
    }

    /// Where the fault is: a file name, a blocklist line, or empty for the whole package.
    pub fn path(&self) -> String {
        use TrustError::*;
        match self {
            Malformed { file, .. }
            | DuplicateKey { file, .. }
            | FormatTooNew { file }
            | BadSignature { file }
            | WeakKey { file }
            | WrongId { file, .. }
            | WrongBuild { file, .. }
            | RotationNotByOldKey { file }
            | RotationWrongId { file } => file.clone(),
            PlayJsonChanged => "play.json".into(),
            PlayFilesChanged => "play.files".into(),
            StoreSigWithoutPlaySig | PlaySigChanged => "store.sig".into(),
            RotationsChanged | RotationToRetiredKey { .. } => "play.sig".into(),
            BlocklistUnavailable { .. } => "store-blocklist".into(),
            RotationReplayed { .. } => "play.sig".into(),
            CeilingRefused { permission, .. } => format!("/permissions/{permission}"),
            BlocklistMalformed { line, .. } if *line > 0 => format!("store-blocklist:{line}"),
            BlocklistMalformed { .. } => "store-blocklist".into(),
            BlocklistNotStoreKey { .. }
            | BlocklistChanged
            | BlocklistExpired { .. }
            | BlocklistNotNewer { .. } => "store-blocklist.sig".into(),
            NeedsDeveloperMode
            | DifferentDeveloper { .. }
            | Revoked { .. }
            | StateCorrupt { .. }
            | StateIo { .. } => String::new(),
        }
    }

    /// English text a developer or an admin can act on. Package-controlled text is quoted.
    pub fn message(&self) -> String {
        use TrustError::*;
        match self {
            Malformed { file, detail } => format!("{file} is not a valid signature file: {detail}."),
            DuplicateKey { file, pointer } => format!(
                "{file} names a key twice in the object at {}.",
                quote(pointer)
            ),
            FormatTooNew { file } => format!("{file} needs a newer RuyaOS."),
            BadSignature { file } => format!(
                "The signature in {file} does not match: this was changed after it was signed."
            ),
            WeakKey { file } => format!("{file} uses a key that cannot sign anything (a weak key)."),
            PlayJsonChanged => {
                "play.json was changed after the package was signed.".into()
            }
            PlayFilesChanged => {
                "play.files was changed after the package was signed.".into()
            }
            WrongId { file, signed, package } => format!(
                "{file} was signed for {}, but the package is {}.",
                quote(signed),
                quote(package)
            ),
            WrongBuild { file, signed, package } => format!(
                "{file} was signed for build {signed}, but the package is build {package}."
            ),
            RotationsChanged => {
                "The key changes play.sig carries are not the ones its developer signed.".into()
            }
            StoreSigWithoutPlaySig => {
                "store.sig countersigns play.sig, but the package has no play.sig.".into()
            }
            PlaySigChanged => {
                "play.sig was changed after the store countersigned it.".into()
            }
            RotationNotByOldKey { file } => format!(
                "{file} must be signed by the key it hands the game over from."
            ),
            RotationReplayed { seq, applied } => format!(
                "The key change number {seq} is not newer than the last one this console applied ({applied})."
            ),
            RotationWrongId { file } => format!("{file} hands over another game."),
            RotationToRetiredKey { key_id } => format!(
                "A key change hands the game back to key {key_id}, which this console retired for it; a retired key is never accepted again."
            ),
            NeedsDeveloperMode => {
                "This package is not signed. An admin must turn on developer mode to install it."
                    .into()
            }
            DifferentDeveloper { id, known, found } => format!(
                "This isn't the same developer: {} belongs to key {known} on this console, and this package is {}. If the key was lost or another package took the id first, an admin can choose \"Forget this game's data and key\" to free it.",
                quote(id),
                match found {
                    Some(k) => format!("signed by key {k}"),
                    None => "not signed".into(),
                }
            ),
            CeilingRefused { tier, permission } => format!(
                "A package of the {tier} tier may not ask for {}: it cannot be installed.",
                quote(permission)
            ),
            Revoked { reason, .. } => format!("Removed for safety: {}", quote(reason)),
            BlocklistMalformed { line, detail } => {
                format!("The blocklist is not valid at line {line}: {detail}.")
            }
            BlocklistNotStoreKey { key_id } => format!(
                "The downloaded blocklist is signed by key {key_id}, which is not the RuyaOS store key."
            ),
            BlocklistChanged => "The downloaded blocklist is not the one that was signed.".into(),
            BlocklistExpired { expires } => {
                format!("The downloaded blocklist expired at {expires}.")
            }
            BlocklistNotNewer { serial, image } => format!(
                "The downloaded blocklist (serial {serial}) is not newer than the system's (serial {image})."
            ),
            BlocklistUnavailable { detail } => format!(
                "The system's safety list cannot be read ({detail}), so nothing can be installed until an OS update repairs it."
            ),
            StateCorrupt { detail } => {
                format!("The trust records cannot be read ({detail}); they were not changed.")
            }
            StateIo { detail } => format!("The trust records could not be saved or read ({detail})."),
        }
    }

    /// The fault as a format-crate [`Problem`].
    pub fn to_problem(&self) -> Problem {
        Problem::new(self.code(), self.path(), self.message())
    }
}

impl std::fmt::Display for TrustError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code(), self.message())
    }
}

impl std::error::Error for TrustError {}
