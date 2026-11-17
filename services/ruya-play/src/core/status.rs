//! The status words of `org.ruyaos.Play1` (RUY-96) and the map from a problem list to the one
//! status a job finishes with (05 §7.3, lead-29).

use crate::core::codes;
use ruya_play_format::Problem;
use ruya_play_trust::codes as trust;

/// How a job ends: `JobFinished`'s status.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobStatus {
    /// Installed.
    Ok,
    /// A rule of 05 §4 was broken, a hash did not match, a tier ceiling refused a permission, the
    /// build is not newer than the installed one, or the icon or hero is malformed.
    InvalidPackage,
    /// The package was changed after it was signed (never downgraded to unverified).
    BadSignature,
    /// The id belongs to another key on this console.
    DifferentDeveloper,
    /// Unsigned, and developer mode is off.
    NeedsDeveloperMode,
    /// On the blocklist.
    Revoked,
    /// `format.too_new`, a newer signature format, or another architecture.
    Unsupported,
    /// Not enough space.
    DiskFull,
    /// `Cancel` reached the job in time.
    Cancelled,
    /// Internal error (including an unreadable image blocklist: `blocklist.unavailable`).
    Failed,
}

impl JobStatus {
    /// Every status, in the order of the contract.
    pub const ALL: [JobStatus; 10] = [
        JobStatus::Ok,
        JobStatus::InvalidPackage,
        JobStatus::BadSignature,
        JobStatus::DifferentDeveloper,
        JobStatus::NeedsDeveloperMode,
        JobStatus::Revoked,
        JobStatus::Unsupported,
        JobStatus::DiskFull,
        JobStatus::Cancelled,
        JobStatus::Failed,
    ];

    /// The contract's word.
    pub fn as_str(self) -> &'static str {
        match self {
            JobStatus::Ok => "ok",
            JobStatus::InvalidPackage => "invalid-package",
            JobStatus::BadSignature => "bad-signature",
            JobStatus::DifferentDeveloper => "different-developer",
            JobStatus::NeedsDeveloperMode => "needs-developer-mode",
            JobStatus::Revoked => "revoked",
            JobStatus::Unsupported => "unsupported",
            JobStatus::DiskFull => "disk-full",
            JobStatus::Cancelled => "cancelled",
            JobStatus::Failed => "failed",
        }
    }

    /// The status named `word`.
    pub fn parse(word: &str) -> Option<JobStatus> {
        JobStatus::ALL.into_iter().find(|s| s.as_str() == word)
    }
}

/// What a method call answers (the job's own result arrives with `JobFinished`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MethodStatus {
    /// Done, or queued.
    Ok,
    /// The path is not a package the importer can open.
    UnknownSource,
    /// No such job.
    UnknownJob,
    /// The job passed the point of no return (phase `committing`) or is finished.
    TooLate,
    /// A job for that package is already queued or running.
    Busy,
    /// Install without `admin_approved`.
    Forbidden,
    /// A malformed argument (a relative path).
    Invalid,
    /// Internal error.
    Failed,
}

impl MethodStatus {
    /// The contract's word.
    pub fn as_str(self) -> &'static str {
        match self {
            MethodStatus::Ok => "ok",
            MethodStatus::UnknownSource => "unknown-source",
            MethodStatus::UnknownJob => "unknown-job",
            MethodStatus::TooLate => "too-late",
            MethodStatus::Busy => "busy",
            MethodStatus::Forbidden => "forbidden",
            MethodStatus::Invalid => "invalid",
            MethodStatus::Failed => "failed",
        }
    }
}

/// A job's phase, in the contract's order (a phase may be skipped, never repeated).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Phase {
    /// Queued: no phase yet.
    None,
    /// Checks, then copying into staging while hashing.
    Staging,
    /// The re-walk of the staged tree and the second revocation check.
    Verifying,
    /// Art and video.
    VettingArt,
    /// The commit step builds the app (the point of no return).
    Committing,
    /// The Store's Flatpak transaction.
    Installing,
}

impl Phase {
    /// The contract's word (`""` while queued).
    pub fn as_str(self) -> &'static str {
        match self {
            Phase::None => "",
            Phase::Staging => "staging",
            Phase::Verifying => "verifying",
            Phase::VettingArt => "vetting-art",
            Phase::Committing => "committing",
            Phase::Installing => "installing",
        }
    }

    /// The phase named `word`.
    pub fn parse(word: &str) -> Option<Phase> {
        [
            Phase::None,
            Phase::Staging,
            Phase::Verifying,
            Phase::VettingArt,
            Phase::Committing,
            Phase::Installing,
        ]
        .into_iter()
        .find(|p| p.as_str() == word)
    }
}

/// The status of one problem code.
fn status_of_code(code: &str) -> JobStatus {
    let group = code.split('.').next().unwrap_or("");
    match code {
        ruya_play_format::codes::FORMAT_TOO_NEW
        | ruya_play_format::codes::REQUIREMENTS_ARCH
        | trust::SIG_FORMAT_TOO_NEW => JobStatus::Unsupported,
        trust::TRUST_NEEDS_DEVELOPER_MODE => JobStatus::NeedsDeveloperMode,
        trust::TRUST_DIFFERENT_DEVELOPER
        | trust::ROTATION_REPLAYED
        | trust::ROTATION_TO_RETIRED_KEY => JobStatus::DifferentDeveloper,
        trust::ROTATION_NOT_BY_OLD_KEY | trust::ROTATION_WRONG_ID => JobStatus::BadSignature,
        codes::SPACE_NOT_ENOUGH => JobStatus::DiskFull,
        codes::STAGING_CHANGED
        | codes::STAGING_IO
        | codes::SOURCE_MISSING
        | codes::INSTALLED_CORRUPT
        | codes::INSTALLED_IO
        | codes::COMMIT_FAILED
        | codes::ROLLBACK_FAILED
        | codes::JOB_INTERRUPTED => JobStatus::Failed,
        _ => match group {
            "sig" | "store_sig" => JobStatus::BadSignature,
            "revoked" => JobStatus::Revoked,
            "blocklist" | "state" => JobStatus::Failed,
            // The format's rules, `ceiling.refused`, `build.not_newer`, art and video.
            _ => JobStatus::InvalidPackage,
        },
    }
}

/// The one status a refusal finishes with. With several problems the most specific wins, in this
/// order: an internal fault (`failed`), `revoked`, `unsupported` (a package for another console
/// is that whatever else is wrong with it), then the signature and key statuses, `disk-full`, and
/// `invalid-package` for the rest. An empty list is `failed`: a refusal always names its reason.
pub fn status_of(problems: &[Problem]) -> JobStatus {
    const ORDER: [JobStatus; 8] = [
        JobStatus::Failed,
        JobStatus::Revoked,
        JobStatus::Unsupported,
        JobStatus::BadSignature,
        JobStatus::DifferentDeveloper,
        JobStatus::NeedsDeveloperMode,
        JobStatus::DiskFull,
        JobStatus::InvalidPackage,
    ];
    if problems.is_empty() {
        return JobStatus::Failed;
    }
    let found: Vec<JobStatus> = problems.iter().map(|p| status_of_code(&p.code)).collect();
    ORDER
        .into_iter()
        .find(|s| found.contains(s))
        .unwrap_or(JobStatus::InvalidPackage)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(code: &str) -> Problem {
        Problem::new(code, "", "")
    }

    #[test]
    fn each_group_maps_to_its_status() {
        let cases = [
            ("path.traversal", JobStatus::InvalidPackage),
            ("package.hash_mismatch", JobStatus::InvalidPackage),
            ("ceiling.refused", JobStatus::InvalidPackage),
            ("build.not_newer", JobStatus::InvalidPackage),
            ("art.corrupt", JobStatus::InvalidPackage),
            ("sig.bad_signature", JobStatus::BadSignature),
            ("store_sig.play_sig_changed", JobStatus::BadSignature),
            ("rotation.not_by_old_key", JobStatus::BadSignature),
            ("rotation.wrong_id", JobStatus::BadSignature),
            ("trust.different_developer", JobStatus::DifferentDeveloper),
            ("rotation.replayed", JobStatus::DifferentDeveloper),
            ("rotation.to_retired_key", JobStatus::DifferentDeveloper),
            ("trust.needs_developer_mode", JobStatus::NeedsDeveloperMode),
            ("revoked.key", JobStatus::Revoked),
            ("revoked.runner", JobStatus::Revoked),
            ("format.too_new", JobStatus::Unsupported),
            ("requirements.arch", JobStatus::Unsupported),
            ("sig.format_too_new", JobStatus::Unsupported),
            ("space.not_enough", JobStatus::DiskFull),
            ("blocklist.unavailable", JobStatus::Failed),
            ("state.corrupt", JobStatus::Failed),
            ("staging.changed", JobStatus::Failed),
            ("commit.failed", JobStatus::Failed),
            ("rollback.failed", JobStatus::Failed),
        ];
        for (code, status) in cases {
            assert_eq!(status_of(&[p(code)]), status, "{code}");
        }
    }

    #[test]
    fn the_most_specific_status_wins() {
        assert_eq!(
            status_of(&[p("path.traversal"), p("requirements.arch")]),
            JobStatus::Unsupported
        );
        assert_eq!(
            status_of(&[p("art.corrupt"), p("staging.io")]),
            JobStatus::Failed
        );
        assert_eq!(status_of(&[]), JobStatus::Failed);
    }

    #[test]
    fn words_round_trip() {
        for s in JobStatus::ALL {
            assert_eq!(JobStatus::parse(s.as_str()), Some(s));
        }
        for w in [
            "",
            "staging",
            "verifying",
            "vetting-art",
            "committing",
            "installing",
        ] {
            assert_eq!(Phase::parse(w).map(Phase::as_str), Some(w));
        }
        assert_eq!(JobStatus::parse("done"), None);
        assert_eq!(Phase::parse("unpacking"), None);
    }
}
