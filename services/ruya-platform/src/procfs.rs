//! The recipe's reads (`identity.rs` has the rules): on Linux the pidfd's fdinfo, the caller's
//! `.flatpak-info` through its root and its cgroup file ([`LinuxProcfs`]); everywhere the user
//! database ([`SystemUsers`], `ruya-users`). Off Linux there is no `/proc`: [`NoProcfs`] answers
//! nothing, so every caller is `not-an-app` (a dev host has no sandboxed apps; the developer mock,
//! `mock.rs`, reads a scenario instead).

use std::io;

use crate::identity::{Procfs, Users};

/// Nothing can be read: every caller is refused.
#[derive(Debug, Default)]
pub struct NoProcfs;

impl Procfs for NoProcfs {
    fn pidfd_pid(&self, _pidfd: i32) -> Option<i32> {
        None
    }
    fn flatpak_info(&self, _pid: u32) -> io::Result<Vec<u8>> {
        Err(io::ErrorKind::Unsupported.into())
    }
    fn cgroup(&self, _pid: u32) -> io::Result<Vec<u8>> {
        Err(io::ErrorKind::Unsupported.into())
    }
}

/// The system's user database (`ruya_users::name_of`; off Linux it knows nobody).
#[derive(Debug, Default)]
pub struct SystemUsers;

impl Users for SystemUsers {
    fn name_of(&self, uid: u32) -> Option<String> {
        ruya_users::name_of(uid)
    }
}

#[cfg(target_os = "linux")]
pub use linux::LinuxProcfs;

#[cfg(target_os = "linux")]
mod linux {
    use std::io;
    use std::path::Path;

    use ruya_fs::Dir;

    use crate::identity::{fdinfo_pid, Procfs, MAX_CGROUP, MAX_FLATPAK_INFO};

    /// The fdinfo of a pidfd is a few hundred bytes.
    const MAX_FDINFO: u64 = 4096;

    /// The kernel's `/proc`. Every file is read with a size cap and never through a link
    /// (`ruya-fs`); the folder it is in (`/proc/self/fdinfo`, `/proc/<pid>`, the process's root)
    /// is the kernel's, so the path to it is followed.
    #[derive(Debug, Default)]
    pub struct LinuxProcfs;

    impl Procfs for LinuxProcfs {
        fn pidfd_pid(&self, pidfd: i32) -> Option<i32> {
            let fdinfo = Dir::open(Path::new("/proc/self/fdinfo")).ok()?;
            let text = fdinfo
                .read(Path::new(&pidfd.to_string()), MAX_FDINFO)
                .ok()?;
            fdinfo_pid(std::str::from_utf8(&text).ok()?)
        }

        /// In a sandbox `.flatpak-info` is a read-only bind mount the app cannot change.
        fn flatpak_info(&self, pid: u32) -> io::Result<Vec<u8>> {
            Dir::open(Path::new(&format!("/proc/{pid}/root")))?
                .read(Path::new(".flatpak-info"), MAX_FLATPAK_INFO as u64)
        }

        fn cgroup(&self, pid: u32) -> io::Result<Vec<u8>> {
            Dir::open(Path::new(&format!("/proc/{pid}")))?
                .read(Path::new("cgroup"), MAX_CGROUP as u64)
        }
    }
}
