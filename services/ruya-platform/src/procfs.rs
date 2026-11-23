//! The recipe's reads on Linux (`identity.rs` has the rules): the pidfd's fdinfo, the caller's
//! `.flatpak-info` through its root and its cgroup file, and the user database. Off Linux there is
//! no `/proc` and no user database: [`NoProcfs`] and [`NoUsers`] answer nothing, so every caller
//! is `not-an-app` (a dev host has no sandboxed apps; the developer mock is RUY-158).

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

/// No user database.
#[derive(Debug, Default)]
pub struct NoUsers;

impl Users for NoUsers {
    fn name_of(&self, _uid: u32) -> Option<String> {
        None
    }
}

#[cfg(target_os = "linux")]
pub use linux::{uid_of, LinuxProcfs, SystemUsers};

/// Off Linux there are no Unix users (the shell's uid is not known; only root would pass).
#[cfg(not(target_os = "linux"))]
pub fn uid_of(_name: &str) -> Option<u32> {
    None
}

#[cfg(target_os = "linux")]
mod linux {
    use std::io::{self, Read};
    use std::path::Path;

    use crate::identity::{fdinfo_pid, Procfs, Users, MAX_CGROUP, MAX_FLATPAK_INFO};

    /// The fdinfo of a pidfd is a few hundred bytes.
    const MAX_FDINFO: u64 = 4096;

    fn read_capped(path: &Path, cap: u64) -> io::Result<Vec<u8>> {
        let mut bytes = Vec::new();
        std::fs::File::open(path)?
            .take(cap.saturating_add(1))
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 > cap {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("{} is bigger than {cap} bytes", path.display()),
            ));
        }
        Ok(bytes)
    }

    /// The kernel's `/proc`.
    #[derive(Debug, Default)]
    pub struct LinuxProcfs;

    impl Procfs for LinuxProcfs {
        fn pidfd_pid(&self, pidfd: i32) -> Option<i32> {
            let text =
                read_capped(Path::new(&format!("/proc/self/fdinfo/{pidfd}")), MAX_FDINFO).ok()?;
            fdinfo_pid(std::str::from_utf8(&text).ok()?)
        }

        /// The process's root is opened (the `root` link of `/proc/<pid>` is the kernel's, so it is
        /// followed) and `.flatpak-info` read from it as a regular file, never through a link
        /// (`ruya-fs`); in a sandbox it is a read-only bind mount the app cannot change.
        fn flatpak_info(&self, pid: u32) -> io::Result<Vec<u8>> {
            let root = ruya_fs::Dir::open(Path::new(&format!("/proc/{pid}/root")))?;
            root.read(Path::new(".flatpak-info"), MAX_FLATPAK_INFO as u64)
        }

        fn cgroup(&self, pid: u32) -> io::Result<Vec<u8>> {
            read_capped(Path::new(&format!("/proc/{pid}/cgroup")), MAX_CGROUP as u64)
        }
    }

    /// The system's user database (`getpwuid_r`, NSS).
    #[derive(Debug, Default)]
    pub struct SystemUsers;

    impl Users for SystemUsers {
        fn name_of(&self, uid: u32) -> Option<String> {
            let mut buf = vec![0 as libc::c_char; 4096];
            // SAFETY: an all-zero `passwd` is a valid value for getpwuid_r to fill in.
            let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
            let mut result: *mut libc::passwd = std::ptr::null_mut();
            // SAFETY: every pointer is valid for the call and `buf.len()` is the buffer's real size.
            let rc = unsafe {
                libc::getpwuid_r(uid, &mut pwd, buf.as_mut_ptr(), buf.len(), &mut result)
            };
            if rc != 0 || result.is_null() || pwd.pw_name.is_null() {
                return None;
            }
            // SAFETY: on success `pw_name` points to a NUL-terminated string inside `buf`, alive here.
            let name = unsafe { std::ffi::CStr::from_ptr(pwd.pw_name) };
            name.to_str().ok().map(str::to_owned)
        }
    }

    /// The uid of a Unix user (`getpwnam_r`), `None` when there is no such user.
    pub fn uid_of(name: &str) -> Option<u32> {
        let name = std::ffi::CString::new(name).ok()?;
        let mut buf = vec![0 as libc::c_char; 4096];
        // SAFETY: an all-zero `passwd` is a valid value for getpwnam_r to fill in.
        let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
        let mut result: *mut libc::passwd = std::ptr::null_mut();
        // SAFETY: every pointer is valid for the call and `buf.len()` is the buffer's real size.
        let rc = unsafe {
            libc::getpwnam_r(
                name.as_ptr(),
                &mut pwd,
                buf.as_mut_ptr(),
                buf.len(),
                &mut result,
            )
        };
        (rc == 0 && !result.is_null()).then_some(pwd.pw_uid)
    }
}
