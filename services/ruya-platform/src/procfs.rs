//! The recipe's reads (`identity.rs` has the rules): on Linux the door's own fdinfo of the pidfd
//! and the identity helper's answer ([`HelperProcfs`]: ADR-022 decision 4, the door holds no
//! capability and asks `ruya-platform-identify` over its root-only socket); everywhere the user
//! database ([`SystemUsers`], `ruya-users`). Off Linux there is no `/proc`: [`NoProcfs`] answers
//! nothing, so every caller is `not-an-app` (a dev host has no sandboxed apps; the developer mock,
//! `mock.rs`, reads a scenario instead).

use std::io;

use crate::identity::{Procfs, Reply, Users};

/// Nothing can be read: every caller is refused.
#[derive(Debug, Default)]
pub struct NoProcfs;

impl Procfs for NoProcfs {
    fn pidfd_pid(&self, _pidfd: i32) -> Option<i32> {
        None
    }
    fn caller_files(&self, _pidfd: i32, _uid: u32) -> io::Result<Reply> {
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
pub use linux::HelperProcfs;

#[cfg(target_os = "linux")]
mod linux {
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    use ruya_platform_identify::fdinfo::own_pidfd_pid;
    use ruya_platform_identify::wire::{decode_reply, encode_request, Request, MAX_REPLY, SOCKET};

    use crate::identity::{Procfs, Reply};

    /// How long the door waits for the helper (a socket-activated process that reads two small
    /// files); the door serves one call at a time, so a stuck helper must not hold it long.
    const TIMEOUT: Duration = Duration::from_secs(2);

    /// The door's own fdinfo for the pidfd, the helper for the caller's files. Every failure to
    /// reach the helper is logged here (the recipe only says "helper unavailable").
    #[derive(Debug)]
    pub struct HelperProcfs {
        socket: PathBuf,
    }

    impl Default for HelperProcfs {
        fn default() -> HelperProcfs {
            HelperProcfs {
                socket: PathBuf::from(SOCKET),
            }
        }
    }

    impl Procfs for HelperProcfs {
        fn pidfd_pid(&self, pidfd: i32) -> Option<i32> {
            own_pidfd_pid(pidfd)
        }

        fn caller_files(&self, pidfd: i32, uid: u32) -> io::Result<Reply> {
            ask(&self.socket, pidfd, uid).inspect_err(|e| {
                eprintln!(
                    "ruya-platform: identity helper {}: {e}",
                    self.socket.display()
                )
            })
        }
    }

    fn check(rc: libc::c_int) -> io::Result<libc::c_int> {
        if rc < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(rc)
        }
    }

    fn set_timeout(fd: &OwnedFd, option: libc::c_int) -> io::Result<()> {
        let tv = libc::timeval {
            tv_sec: TIMEOUT.as_secs() as libc::time_t,
            tv_usec: 0,
        };
        // SAFETY: setsockopt(2) on our own socket with a timeval that outlives the call.
        check(unsafe {
            libc::setsockopt(
                fd.as_raw_fd(),
                libc::SOL_SOCKET,
                option,
                &tv as *const libc::timeval as *const libc::c_void,
                std::mem::size_of::<libc::timeval>() as libc::socklen_t,
            )
        })
        .map(drop)
    }

    fn connect(path: &Path) -> io::Result<OwnedFd> {
        // SAFETY: socket(2) with constant arguments; the descriptor is owned from here on.
        let fd = unsafe {
            OwnedFd::from_raw_fd(check(libc::socket(
                libc::AF_UNIX,
                libc::SOCK_SEQPACKET | libc::SOCK_CLOEXEC,
                0,
            ))?)
        };
        set_timeout(&fd, libc::SO_SNDTIMEO)?;
        set_timeout(&fd, libc::SO_RCVTIMEO)?;
        // SAFETY: an all-zero sockaddr_un is a valid empty one.
        let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
        addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
        let bytes = path.as_os_str().as_bytes();
        if bytes.len() >= addr.sun_path.len() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "socket path too long",
            ));
        }
        for (dst, src) in addr.sun_path.iter_mut().zip(bytes) {
            *dst = *src as libc::c_char;
        }
        // SAFETY: connect(2) with an address that lives through the call.
        check(unsafe {
            libc::connect(
                fd.as_raw_fd(),
                &addr as *const libc::sockaddr_un as *const libc::sockaddr,
                std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t,
            )
        })?;
        Ok(fd)
    }

    /// One request on a new connection: the request bytes with the pidfd as SCM_RIGHTS, then the
    /// one reply.
    fn ask(path: &Path, pidfd: i32, uid: u32) -> io::Result<Reply> {
        let sock = connect(path)?;
        let mut request = encode_request(&Request { uid });
        let mut iov = libc::iovec {
            iov_base: request.as_mut_ptr() as *mut libc::c_void,
            iov_len: request.len(),
        };
        // 8-byte aligned room for one descriptor (CMSG_SPACE of 4 bytes is 24).
        let mut control = [0u64; 4];
        // SAFETY: CMSG_SPACE is a pure size computation.
        let space = unsafe { libc::CMSG_SPACE(std::mem::size_of::<i32>() as u32) } as usize;
        // SAFETY: an all-zero msghdr is a valid empty one.
        let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control.as_mut_ptr() as *mut libc::c_void;
        msg.msg_controllen = space as _;
        // SAFETY: the one cmsg header and its descriptor are written inside `control`, which
        // `space` (at most its size) covers; sendmsg reads buffers that live through the call.
        let sent = unsafe {
            let c = libc::CMSG_FIRSTHDR(&msg);
            (*c).cmsg_level = libc::SOL_SOCKET;
            (*c).cmsg_type = libc::SCM_RIGHTS;
            (*c).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<i32>() as u32) as _;
            std::ptr::write_unaligned(libc::CMSG_DATA(c) as *mut i32, pidfd);
            libc::sendmsg(sock.as_raw_fd(), &msg, libc::MSG_NOSIGNAL)
        };
        if sent < 0 {
            return Err(io::Error::last_os_error());
        }
        // One byte more than the largest reply, so a longer one is seen.
        let mut reply = vec![0u8; MAX_REPLY + 1];
        // SAFETY: recv(2) into a buffer that lives through the call.
        let n = unsafe {
            libc::recv(
                sock.as_raw_fd(),
                reply.as_mut_ptr() as *mut libc::c_void,
                reply.len(),
                0,
            )
        };
        if n < 0 {
            return Err(io::Error::last_os_error());
        }
        reply.truncate(n as usize);
        decode_reply(&reply).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }
}
