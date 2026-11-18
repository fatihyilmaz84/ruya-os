//! The importer's side effects, as traits (the `ruya-store` `Flatpak` and `ruya-session`
//! `ProfileDirectory` pattern). Real implementations that need nothing from RUY-100 live next to
//! them ([`crate::core::opener::DiskOpener`], [`RuyaPlayArt`], [`SystemClock`],
//! [`ImageBlocklist`], [`StatvfsFreeSpace`] on Unix); the fakes are in [`crate::core::fakes`].
//! The Flatpak-backed [`Commit`] is RUY-829's. Everything that reads package bytes runs behind
//! [`Helper`] (RUY-828): [`crate::core::helper::InProcessHelper`] in tests and on Windows,
//! [`crate::core::systemd_run::SystemdRunHelper`] on the console.

use crate::core::helper::Request;
use crate::core::status::Phase;
use ruya_play_art::{Slot, SlotResult};
use ruya_play_format::manifest::Manifest;
use ruya_play_format::{Problem, Source};
use ruya_play_trust::time::UnixSeconds;
use ruya_play_trust::{Assessment, Signatures, StoreKeys, Tier, TrustStore};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

pub use crate::core::installed::InstalledBuilds;

/// Why a package path cannot be opened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpenError {
    /// Nothing is there (the drive went away): `unknown-source` for `Inspect`, `failed` with
    /// `source.missing` for a job. A path the service saw before and after the run is not
    /// missing: it is `source.unreadable` (the open was denied).
    Missing,
    /// It is there but it is not a package the format can read (`zip.not_a_zip`, ...).
    Problems(Vec<Problem>),
}

/// Opens the package at a path: a folder or a `.play.zip`.
pub trait Opener: Send + Sync {
    /// The package at `path`.
    fn open(&self, path: &Path) -> Result<Box<dyn Source + '_>, OpenError>;
}

/// Free space where the staging directory lives.
pub trait FreeSpace: Send + Sync {
    /// Bytes still available to the importer in `dir`.
    fn available(&self, dir: &Path) -> io::Result<u64>;
}

/// The art and video vetting (`ruya_play_art::vet`).
pub trait ArtVetter: Send + Sync {
    /// Vet each `(slot, path)` into `out_dir`.
    fn vet(&self, inputs: &[(Slot, PathBuf)], out_dir: &Path) -> Vec<SlotResult>;
}

/// The console's clock.
pub trait Clock: Send + Sync {
    /// Seconds since 1970 (UTC).
    fn now(&self) -> UnixSeconds;
}

/// The store blocklist (05 §9.2): the image's copy and a verified download, if any.
pub trait Blocklists: Send + Sync {
    /// The image's file, `None` when it is missing or unreadable (installs are then refused).
    fn image(&self) -> Option<Vec<u8>>;
    /// A downloaded copy and its signature, when one was fetched (later work: always `None` now).
    fn downloaded(&self) -> Option<(Vec<u8>, Vec<u8>)>;
}

/// Everything the commit step gets: a verified staged tree and what was learnt about it.
pub struct CommitRequest<'a> {
    /// The job.
    pub job: &'a str,
    /// The package tree exactly as `play.files` lists it (files 0644/0755, links recreated).
    pub tree: &'a Path,
    /// The vetted art (`ruya-play-art`'s canonical files).
    pub art: &'a Path,
    /// `play.json`, `play.files`, `play.sig` and `store.sig` as they were verified.
    pub meta: &'a Path,
    /// The validated manifest.
    pub manifest: &'a Manifest,
    /// The package's tier.
    pub tier: Tier,
    /// Its requests under the tier's ceiling (the gate RUY-102 applies).
    pub assessment: &'a Assessment,
    /// The verified signatures.
    pub signatures: &'a Signatures,
}

/// A failed commit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommitError {
    /// The target filesystem is full: `disk-full`.
    NoSpace(String),
    /// Anything else: `failed`, `commit.failed`.
    Failed(String),
}

/// Turns a verified staged tree into the installed app (RUY-100: the OSTree commit and the
/// Store's Flatpak transaction). It is called after the point of no return: `Cancel` answers
/// `too-late` from here on. `progress` takes the phase (`committing`, then `installing`) and a
/// fraction 0.0-1.0 of it.
pub trait Commit: Send + Sync {
    /// Commit `request`.
    fn commit(
        &self,
        request: &CommitRequest<'_>,
        progress: &mut dyn FnMut(Phase, f32),
    ) -> Result<(), CommitError>;
}

/// A point in the pipeline, for tests that act between two steps (a cancel, a planted link).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Step<'a> {
    /// The checks passed; nothing is written yet.
    BeforeUnpack,
    /// The staging directory exists (empty `tree/`).
    StagingCreated {
        /// The job's staging directory.
        dir: &'a Path,
    },
    /// Part of a file was written.
    Chunk {
        /// Package path.
        path: &'a str,
        /// Bytes of it written so far.
        done: u64,
    },
    /// One table entry is in place.
    Written {
        /// Package path.
        path: &'a str,
    },
    /// Every table entry is in place.
    Unpacked,
    /// The art slot is about to be vetted.
    ArtSlot {
        /// `icon`, `screenshot-0`, ...
        slot: String,
    },
    /// The commit step is about to start (the point of no return is passed).
    Committing,
}

/// Observes [`Step`]s. The default does nothing; tests use [`crate::core::fakes::FnHooks`].
pub trait Hooks: Send + Sync {
    /// Called at `step` of `job`.
    fn step(&self, job: &str, step: &Step<'_>);
}

/// How a helper run ended, as the service sees the process.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Exit {
    /// The helper exited with this code (0: it finished; its last line says how).
    Code(i32),
    /// The service stopped it (a cancel, or a line that broke the contract), or it was killed
    /// (memory or time limit).
    Stopped,
    /// It could not be started or waited for.
    Lost(String),
}

/// Runs the unprivileged helper for one request (05 §7.3, RUY-828): it opens the package, inspects
/// it and, for an install, unpacks, verifies and vets the art into `request.staging`, and writes
/// its JSON Lines ([`crate::core::helper::Line`]) to `on_output` as they come. `on_output` returns
/// false when the service wants the helper stopped (a line that broke the contract). `cancel` is
/// the job's cancel flag: once it is set the helper is stopped or stops itself.
pub trait Helper: Send + Sync {
    /// Run `request` to its end.
    fn run(
        &self,
        request: &Request,
        cancel: &AtomicBool,
        on_output: &mut dyn FnMut(&[u8]) -> bool,
    ) -> Exit;

    /// Stop the running helper of `job` (the default does nothing: an in-process helper reads the
    /// cancel flag itself).
    fn stop(&self, _job: &str) {}

    /// Remove what helpers of a previous run left outside the importer's folders (at start).
    fn clear(&self) -> io::Result<()> {
        Ok(())
    }
}

impl<T: Helper + ?Sized> Helper for std::sync::Arc<T> {
    fn run(
        &self,
        request: &Request,
        cancel: &AtomicBool,
        on_output: &mut dyn FnMut(&[u8]) -> bool,
    ) -> Exit {
        (**self).run(request, cancel, on_output)
    }
    fn stop(&self, job: &str) {
        (**self).stop(job)
    }
    fn clear(&self) -> io::Result<()> {
        (**self).clear()
    }
}

/// Everything the importer needs from outside. The service side never opens a package: the
/// opener and the art step belong to the helper ([`crate::core::helper::HelperDeps`]).
pub struct Deps {
    /// Runs the unprivileged helper.
    pub helper: Box<dyn Helper>,
    /// Free space in staging.
    pub free_space: Box<dyn FreeSpace>,
    /// The commit step.
    pub commit: Box<dyn Commit>,
    /// The clock.
    pub clock: Box<dyn Clock>,
    /// The blocklist.
    pub blocklists: Box<dyn Blocklists>,
    /// The pinned store keys.
    pub store_keys: StoreKeys,
    /// Key records and developer mode (`/var/lib/ruya-play/trust.json`).
    pub trust: Box<dyn TrustStore + Send>,
    /// The builds installed per id.
    pub installed: Box<dyn InstalledBuilds + Send>,
    /// Step observers.
    pub hooks: Box<dyn Hooks>,
}

/// The real art step: `ruya_play_art::vet`.
#[derive(Debug, Default, Clone, Copy)]
pub struct RuyaPlayArt;

impl ArtVetter for RuyaPlayArt {
    fn vet(&self, inputs: &[(Slot, PathBuf)], out_dir: &Path) -> Vec<SlotResult> {
        ruya_play_art::vet(inputs, out_dir)
    }
}

/// The system clock.
#[derive(Debug, Default, Clone, Copy)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> UnixSeconds {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
    }
}

/// The image's blocklist file, read with a size bound (no download yet).
#[derive(Debug, Clone)]
pub struct ImageBlocklist {
    /// Normally [`ruya_play_trust::revocation::IMAGE_BLOCKLIST_PATH`].
    pub path: PathBuf,
}

impl Blocklists for ImageBlocklist {
    fn image(&self) -> Option<Vec<u8>> {
        use std::io::Read;
        let limit = ruya_play_trust::revocation::MAX_BLOCKLIST_BYTES as u64;
        let mut bytes = Vec::new();
        std::fs::File::open(&self.path)
            .ok()?
            .take(limit + 1)
            .read_to_end(&mut bytes)
            .ok()?;
        // One byte over the limit makes the parser refuse it: fail closed.
        Some(bytes)
    }

    fn downloaded(&self) -> Option<(Vec<u8>, Vec<u8>)> {
        None
    }
}

/// Free space from `statvfs` of the staging directory.
#[cfg(unix)]
#[derive(Debug, Default, Clone, Copy)]
pub struct StatvfsFreeSpace;

#[cfg(unix)]
impl FreeSpace for StatvfsFreeSpace {
    fn available(&self, dir: &Path) -> io::Result<u64> {
        crate::core::staging::Dir::open_root(dir)?.free_bytes()
    }
}

/// No observer.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoHooks;

impl Hooks for NoHooks {
    fn step(&self, _job: &str, _step: &Step<'_>) {}
}

// A shared handle works wherever the thing does (tests keep one to look at a fake afterwards).
impl<T: Opener + ?Sized> Opener for std::sync::Arc<T> {
    fn open(&self, path: &Path) -> Result<Box<dyn Source + '_>, OpenError> {
        (**self).open(path)
    }
}

impl<T: FreeSpace + ?Sized> FreeSpace for std::sync::Arc<T> {
    fn available(&self, dir: &Path) -> io::Result<u64> {
        (**self).available(dir)
    }
}

impl<T: ArtVetter + ?Sized> ArtVetter for std::sync::Arc<T> {
    fn vet(&self, inputs: &[(Slot, PathBuf)], out_dir: &Path) -> Vec<SlotResult> {
        (**self).vet(inputs, out_dir)
    }
}

impl<T: Commit + ?Sized> Commit for std::sync::Arc<T> {
    fn commit(
        &self,
        request: &CommitRequest<'_>,
        progress: &mut dyn FnMut(Phase, f32),
    ) -> Result<(), CommitError> {
        (**self).commit(request, progress)
    }
}

impl<T: Clock + ?Sized> Clock for std::sync::Arc<T> {
    fn now(&self) -> UnixSeconds {
        (**self).now()
    }
}

impl<T: Hooks + ?Sized> Hooks for std::sync::Arc<T> {
    fn step(&self, job: &str, step: &Step<'_>) {
        (**self).step(job, step)
    }
}
