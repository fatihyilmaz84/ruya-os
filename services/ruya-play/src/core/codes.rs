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
];
