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

/// The end of the door's exchange with the helper: what is left of it for the next blocking step.
#[derive(Debug, Clone, Copy)]
pub struct Deadline(std::time::Instant);

impl Deadline {
    pub fn new(now: std::time::Instant, within: std::time::Duration) -> Deadline {
        Deadline(now + within)
    }

    /// The time left at `now`; `TimedOut` once nothing is (a zero socket timeout would mean
    /// "wait for ever").
    pub fn left(&self, now: std::time::Instant) -> io::Result<std::time::Duration> {
        let left = self.0.saturating_duration_since(now);
        if left.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "the identity helper took too long",
            ));
        }
        Ok(left)
    }
}

#[cfg(target_os = "linux")]
pub use linux::HelperProcfs;

#[cfg(target_os = "linux")]
mod linux {
    use std::io::{self, IoSlice};
    use std::mem::MaybeUninit;
    use std::os::fd::BorrowedFd;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, Instant};

    use rustix::net::sockopt::{set_socket_timeout, Timeout};
    use rustix::net::{
        connect, recv, sendmsg, socket_with, AddressFamily, RecvFlags, SendAncillaryBuffer,
        SendAncillaryMessage, SendFlags, SocketAddrUnix, SocketFlags, SocketType,
    };

    use ruya_platform_identify::fdinfo::own_pidfd_pid;
    use ruya_platform_identify::wire::{decode_reply, encode_request, Request, MAX_REPLY, SOCKET};

    use super::Deadline;
    use crate::identity::{Procfs, Reply};

    /// How long the whole exchange with the helper may take (a socket-activated process that
    /// reads two small files; about 50 ms on the Dell); the door serves one call at a time, so a
    /// stuck helper must not hold it long.
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

    /// One request on a new connection: the request bytes with the pidfd as SCM_RIGHTS, then the
    /// one reply.
    fn ask(path: &Path, pidfd: i32, uid: u32) -> io::Result<Reply> {
        let sock = socket_with(
            AddressFamily::UNIX,
            SocketType::SEQPACKET,
            SocketFlags::CLOEXEC,
            None,
        )?;
        // One deadline for connect, send and receive together: each blocking step gets only what
        // is left of it as its socket timeout, so the exchange never takes longer than TIMEOUT.
        let deadline = Deadline::new(Instant::now(), TIMEOUT);
        set_socket_timeout(&sock, Timeout::Send, Some(deadline.left(Instant::now())?))?;
        connect(&sock, &SocketAddrUnix::new(path)?)?;
        let request = encode_request(&Request { uid });
        // SAFETY: `pidfd` is the credentials' ProcessFD, which the caller of `identify` keeps open
        // until it returns (`Caller::pidfd`); it is only borrowed for this one sendmsg.
        let pidfd = unsafe { BorrowedFd::borrow_raw(pidfd) };
        let passed = [pidfd];
        let mut space = [MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(1))];
        let mut control = SendAncillaryBuffer::new(&mut space);
        if !control.push(SendAncillaryMessage::ScmRights(&passed)) {
            return Err(io::Error::other("no room for the pidfd"));
        }
        set_socket_timeout(&sock, Timeout::Send, Some(deadline.left(Instant::now())?))?;
        sendmsg(
            &sock,
            &[IoSlice::new(&request)],
            &mut control,
            SendFlags::NOSIGNAL,
        )?;
        // One byte more than the largest reply, so a longer one is seen.
        let mut reply = vec![0u8; MAX_REPLY + 1];
        set_socket_timeout(&sock, Timeout::Recv, Some(deadline.left(Instant::now())?))?;
        let (_, n) = recv(&sock, &mut reply[..], RecvFlags::empty())?;
        reply.truncate(n.min(MAX_REPLY + 1));
        decode_reply(&reply).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }
}

#[cfg(test)]
mod tests {
    use super::Deadline;
    use std::io;
    use std::time::{Duration, Instant};

    #[test]
    fn one_deadline_bounds_every_step() {
        let start = Instant::now();
        let d = Deadline::new(start, Duration::from_secs(2));
        assert_eq!(d.left(start).ok(), Some(Duration::from_secs(2)));
        // A slow connect and send leave the receive only the rest, never a fresh 2 s.
        assert_eq!(
            d.left(start + Duration::from_millis(1500)).ok(),
            Some(Duration::from_millis(500))
        );
        for late in [Duration::from_secs(2), Duration::from_secs(5)] {
            assert_eq!(
                d.left(start + late).map_err(|e| e.kind()),
                Err(io::ErrorKind::TimedOut)
            );
        }
    }
}
