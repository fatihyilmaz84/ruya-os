//! The importer's own problem codes (05 §7.3). They join the format's (§4.5), the trust crate's
//! (§9.2) and `ruya-play-art`'s (§5) in the one problem list a job reports; a code never changes
//! meaning.

/// The package's `build` is not above the build installed for its id (05 §11: a downgrade is never
/// an install).
pub const BUILD_NOT_NEWER: &str = "build.not_newer";
/// The staging filesystem has less free space than the installed size plus 10 %, or it ran out
/// while unpacking.
pub const SPACE_NOT_ENOUGH: &str = "space.not_enough";
/// The staged tree is not what the importer wrote: a name it was about to write exists, a folder
/// on the way is a link, or the re-walk finds an entry that is not in `play.files`.
pub const STAGING_CHANGED: &str = "staging.changed";
/// A read or write in the staging directory failed.
pub const STAGING_IO: &str = "staging.io";
/// The package could not be opened any more (the drive went away, the file was removed).
pub const SOURCE_MISSING: &str = "source.missing";
/// The installed-builds state cannot be read as written (never reset silently).
pub const INSTALLED_CORRUPT: &str = "installed.corrupt";
/// The installed-builds state could not be read or written.
pub const INSTALLED_IO: &str = "installed.io";
/// The commit step failed.
pub const COMMIT_FAILED: &str = "commit.failed";
/// The commit failed and the key record or installed build written before it could not be undone
/// (journalled in `state/journal`; the stale record can only refuse another key).
pub const ROLLBACK_FAILED: &str = "rollback.failed";
/// The service stopped while the job was queued or running.
pub const JOB_INTERRUPTED: &str = "job.interrupted";

/// The unprivileged helper broke its contract: a malformed, over-long or unexpected line, too many
/// problems, no result, a non-zero exit, or it was stopped without a cancel (05 §7.3).
pub const HELPER_FAILED: &str = "helper.failed";
/// The package answered differently when the helper opened it again for the unpack than when it
/// was inspected (a root file's SHA-256 changed).
pub const SOURCE_CHANGED: &str = "source.changed";
/// The drive that holds the package is not mounted `nosuid,nodev,noexec` (05 §7.3 step 1): it was
/// mounted by something other than `ruya-devices`, and nothing on it is read (RUY-829).
pub const SOURCE_UNSAFE_MOUNT: &str = "source.unsafe_mount";
/// A committed `play.<id>` app could not be matched with its records at start (no readable build,
/// or signed without a key record): installs of the id are refused until it is uninstalled
/// (RUY-829).
pub const INSTALLED_UNRECONCILED: &str = "installed.unreconciled";

/// Every code, for the tests that keep the list, the tests and the spec in step.
pub const ALL: &[&str] = &[
    BUILD_NOT_NEWER,
    SPACE_NOT_ENOUGH,
    STAGING_CHANGED,
    STAGING_IO,
    SOURCE_MISSING,
    INSTALLED_CORRUPT,
    INSTALLED_IO,
    COMMIT_FAILED,
    ROLLBACK_FAILED,
    JOB_INTERRUPTED,
    HELPER_FAILED,
    SOURCE_CHANGED,
    SOURCE_UNSAFE_MOUNT,
    INSTALLED_UNRECONCILED,
];
