//! The service around the importer core (RUY-829): the D-Bus side's checks ([`gates`]), the
//! candidates on removable drives ([`sources`]), the Flatpak commit ([`commit`]) and, on Linux,
//! the helper's opener inside its unit ([`fd_source`]). The D-Bus adapter is [`crate::dbus`].

pub mod commit;
#[cfg(target_os = "linux")]
pub mod fd_source;
pub mod gates;
pub mod sources;

use crate::core::codes;
use crate::core::deps::{Exit, Helper};
use crate::core::helper::{Finish, Line, Request};
use std::path::Path;
use std::sync::atomic::AtomicBool;

/// What the service reads from the system, so the D-Bus side runs on every host.
pub trait Environment: Send + Sync {
    /// `/proc/self/mountinfo`.
    fn mountinfo(&self) -> String;
    /// The shell's uid (`ruya-shell` in `/etc/passwd`).
    fn shell_uid(&self) -> Option<u32>;
    /// The shell's gid (`ruya-shell` in `/etc/group`): the group that reads the published art.
    fn shell_gid(&self) -> Option<u32>;
}

/// The console's own files.
#[derive(Debug, Default, Clone, Copy)]
pub struct SystemEnvironment;

impl Environment for SystemEnvironment {
    fn mountinfo(&self) -> String {
        std::fs::read_to_string("/proc/self/mountinfo").unwrap_or_default()
    }
    fn shell_uid(&self) -> Option<u32> {
        let passwd = std::fs::read_to_string("/etc/passwd").ok()?;
        gates::id_in_db(&passwd, gates::SHELL_USER)
    }
    fn shell_gid(&self) -> Option<u32> {
        let group = std::fs::read_to_string("/etc/group").ok()?;
        gates::id_in_db(&group, gates::SHELL_USER)
    }
}

/// The `problem` and `result` lines of a refusal with `code`, as a helper would write them.
pub fn refusal_lines(code: &str, message: &str) -> Vec<u8> {
    let mut out = Vec::new();
    for line in [
        Line::Problem {
            code: code.to_string(),
            path: String::new(),
            message: message.to_string(),
        },
        Line::Result {
            outcome: Finish::Refused,
            art: Vec::new(),
            art_refuses: false,
        },
    ] {
        out.extend_from_slice(serde_json::to_string(&line).unwrap_or_default().as_bytes());
        out.push(b'\n');
    }
    out
}

/// Checks the drive under the source again right before each helper run (05 §7.3 step 1: a drive
/// that was mounted again without `nosuid,nodev,noexec` since `Install` is not read): the run is
/// then refused with `source.unsafe_mount` and the helper never starts.
pub struct GatedHelper<H> {
    inner: H,
    env: std::sync::Arc<dyn Environment>,
}

impl<H: Helper> GatedHelper<H> {
    /// `inner`, gated by the mounts `env` reports.
    pub fn new(inner: H, env: std::sync::Arc<dyn Environment>) -> Self {
        GatedHelper { inner, env }
    }
}

impl<H: Helper> Helper for GatedHelper<H> {
    fn run(
        &self,
        request: &Request,
        cancel: &AtomicBool,
        on_output: &mut dyn FnMut(&[u8]) -> bool,
    ) -> Exit {
        let mounts = gates::parse_mountinfo(&self.env.mountinfo());
        if !gates::mount_is_safe_for(&mounts, Path::new(&request.source)) {
            eprintln!(
                "ruya-play: {}: the drive is not mounted nosuid,nodev,noexec; nothing on it is read",
                request.job
            );
            on_output(&refusal_lines(
                codes::SOURCE_UNSAFE_MOUNT,
                "The drive is not mounted nosuid,nodev,noexec; nothing on it is read.",
            ));
            return Exit::Code(0);
        }
        self.inner.run(request, cancel, on_output)
    }

    fn stop(&self, job: &str) {
        self.inner.stop(job)
    }

    fn clear(&self) -> std::io::Result<()> {
        self.inner.clear()
    }
}
