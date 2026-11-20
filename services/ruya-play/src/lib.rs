//! The `.play` importer (docs/specs/05-play-packages.md §7.3), as a library core.
//!
//! Everything here is pure logic behind traits ([`core::deps`]) so it runs and is tested on
//! Windows with fakes ([`core::fakes`]): the job table ([`core::jobs`], ADR-026's record), one
//! install at a time, and the pipeline split between the unprivileged helper ([`core::helper`]:
//! open, inspect, unpack, re-walk and art, behind [`Helper`]) and the root side ([`Importer`]:
//! the service's own checks over the root files, the space check, the re-walk and re-hash of what
//! the helper staged, the records, and the hand-off to a [`core::deps::Commit`]). The helper runs
//! in-process ([`InProcessHelper`]) in tests and on Windows, and as a transient systemd unit
//! ([`core::systemd_run::SystemdRunHelper`]) on the console. Around it (RUY-829): the binary
//! (`main.rs`), `org.ruyaos.Play1` ([`dbus`]), the D-Bus side's checks, the candidates on drives
//! and the Flatpak commit ([`service`]).

pub mod core;
pub mod dbus;
pub mod service;

pub use crate::core::codes;
pub use crate::core::deps::{
    ArtVetter, Blocklists, Clock, Commit, CommitError, CommitRequest, Deps, Exit, FreeSpace,
    Helper, Hooks, InstalledBuilds, OpenError, Opener, RecommitRequest, Step,
};
pub use crate::core::helper::{HelperDeps, InProcessHelper, Request};
pub use crate::core::importer::{
    Canceller, Config, Event, Importer, InspectReport, JobResult, Recommitted,
};
pub use crate::core::jobs::{JobKind, JobRecord, JobState};
pub use crate::core::status::{status_of, JobStatus, MethodStatus, Phase};
