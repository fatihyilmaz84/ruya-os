//! The `.play` importer (docs/specs/05-play-packages.md §7.3), as a library core.
//!
//! Everything here is pure logic behind traits ([`core::deps`]) so it runs and is tested on
//! Windows with fakes ([`core::fakes`]): the job table ([`core::jobs`], ADR-026's record), one
//! install at a time, the inspect step that reads only data, and the install pipeline that checks
//! space, unpacks into a staging directory created exclusively and walked through directory
//! handles ([`core::staging`]), verifies, vets the art and hands the verified tree to a
//! [`core::deps::Commit`]. The binary, D-Bus, the systemd sandbox and the Flatpak commit are
//! RUY-100's.

pub mod core;

pub use crate::core::codes;
pub use crate::core::deps::{
    ArtVetter, Blocklists, Clock, Commit, CommitError, CommitRequest, Deps, FreeSpace, Hooks,
    InstalledBuilds, OpenError, Opener, Step,
};
pub use crate::core::importer::{Canceller, Config, Event, Importer, InspectReport, JobResult};
pub use crate::core::jobs::{JobKind, JobRecord, JobState};
pub use crate::core::status::{status_of, JobStatus, MethodStatus, Phase};
