//! Unix accounts backing each profile (ADR-004: one Unix user per profile).
//!
//! ruya-profiles holds the PIN hashes and runs no program (ADR-049): a child would be dumpable
//! again after `execve` and live in its mount namespace, where the store is. Making and removing
//! a profile's user needs root, so the bus-less helper `ruya-accounts` does it: `HelperAccounts`
//! sends it one request line per account change over its socket (`ruya_accounts::wire`). Whether
//! an id is taken is asked in-process (`getpwuid_r`, `getgrgid_r` through `ruya-users`), not with
//! `getent`. What the users look like (the `useradd` arguments, the guest uid range, the passwd
//! markers) is the helper crate's (`ruya_accounts::account`).

use std::io;

pub use ruya_accounts::account::{useradd_args, AccountKind, GUEST_UIDS};

pub trait Accounts {
    fn create(&self, profile_id: &str, kind: AccountKind) -> io::Result<()>;
    /// Removes the Unix user and its home.
    fn remove(&self, profile_id: &str) -> io::Result<()>;
    /// Removes a temporary guest's user and home, but only when the user carries the guest
    /// marker (comment, home, a uid in `GUEST_UIDS` equal to `uid`); a user that does not exist
    /// is nothing to remove. Anything else is an error and nothing is deleted.
    fn remove_guest(&self, profile_id: &str, uid: u32) -> io::Result<()>;
    /// True when a user or a group already has this id.
    fn id_in_use(&self, id: u32) -> io::Result<bool>;
}

impl<T: Accounts + ?Sized> Accounts for Box<T> {
    fn create(&self, profile_id: &str, kind: AccountKind) -> io::Result<()> {
        (**self).create(profile_id, kind)
    }
    fn remove(&self, profile_id: &str) -> io::Result<()> {
        (**self).remove(profile_id)
    }
    fn remove_guest(&self, profile_id: &str, uid: u32) -> io::Result<()> {
        (**self).remove_guest(profile_id, uid)
    }
    fn id_in_use(&self, id: u32) -> io::Result<bool> {
        (**self).id_in_use(id)
    }
}

/// For tests and non-Linux development hosts.
#[derive(Debug, Default)]
pub struct NoAccounts;

impl Accounts for NoAccounts {
    fn create(&self, _profile_id: &str, _kind: AccountKind) -> io::Result<()> {
        Ok(())
    }
    fn remove(&self, _profile_id: &str) -> io::Result<()> {
        Ok(())
    }
    fn remove_guest(&self, _profile_id: &str, _uid: u32) -> io::Result<()> {
        Ok(())
    }
    fn id_in_use(&self, _id: u32) -> io::Result<bool> {
        Ok(false)
    }
}

/// The helper's reply as the result of an account change: `ok` is done, every other answer (or
/// none: the helper died, timed out or sent something else) is an error naming the request.
pub fn reply_result(request: &ruya_accounts::Request, reply: &[u8]) -> io::Result<()> {
    use ruya_accounts::Reply;
    match Reply::decode(reply) {
        Some(Reply::Ok) => Ok(()),
        Some(Reply::Error(code)) => Err(io::Error::other(format!(
            "ruya-accounts: {}: {}",
            request.line(),
            code.as_str()
        ))),
        None => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("ruya-accounts: {}: no reply", request.line()),
        )),
    }
}

/// An errno of the user database as an I/O error.
fn nss_error(errno: i32) -> io::Error {
    io::Error::from_raw_os_error(errno)
}

/// Real users, made and removed by the `ruya-accounts` helper (`/run/ruya-accounts.sock`). Homes
/// live in /var/home (persistent on bootc).
#[cfg(target_os = "linux")]
#[derive(Debug)]
pub struct HelperAccounts {
    socket: std::path::PathBuf,
}

#[cfg(target_os = "linux")]
impl Default for HelperAccounts {
    fn default() -> HelperAccounts {
        HelperAccounts {
            socket: std::path::PathBuf::from(ruya_accounts::wire::SOCKET),
        }
    }
}

#[cfg(target_os = "linux")]
impl HelperAccounts {
    /// How long one request may take: `delete` waits up to 5 s for userdel while the user's apps
    /// end (`ruya-accounts@.service` stops the helper after `RuntimeMaxSec=`, below this).
    const TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

    /// One request on a new connection, then the one reply.
    fn ask(&self, request: &ruya_accounts::Request) -> io::Result<()> {
        use rustix::net::sockopt::{set_socket_timeout, Timeout};
        use rustix::net::{
            connect, recv, send, socket_with, AddressFamily, RecvFlags, SendFlags, SocketAddrUnix,
            SocketFlags, SocketType,
        };
        let sock = socket_with(
            AddressFamily::UNIX,
            SocketType::SEQPACKET,
            SocketFlags::CLOEXEC,
            None,
        )?;
        set_socket_timeout(&sock, Timeout::Send, Some(Self::TIMEOUT))?;
        set_socket_timeout(&sock, Timeout::Recv, Some(Self::TIMEOUT))?;
        connect(&sock, &SocketAddrUnix::new(&self.socket)?)?;
        let line = request.encode();
        if send(&sock, &line, SendFlags::NOSIGNAL)? != line.len() {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "the request was cut",
            ));
        }
        // One byte more than the longest reply, so a longer one is seen (and refused).
        let mut reply = [0u8; ruya_accounts::wire::MAX_REPLY + 1];
        let (_, n) = recv(&sock, &mut reply[..], RecvFlags::empty())?;
        reply_result(request, &reply[..n.min(reply.len())])
    }
}

#[cfg(target_os = "linux")]
impl Accounts for HelperAccounts {
    fn create(&self, profile_id: &str, kind: AccountKind) -> io::Result<()> {
        self.ask(&ruya_accounts::Request::Create {
            id: profile_id.to_owned(),
            kind,
        })
    }

    fn remove(&self, profile_id: &str) -> io::Result<()> {
        self.ask(&ruya_accounts::Request::Delete {
            id: profile_id.to_owned(),
        })
    }

    fn remove_guest(&self, profile_id: &str, uid: u32) -> io::Result<()> {
        self.ask(&ruya_accounts::Request::RemoveGuest {
            id: profile_id.to_owned(),
            uid,
        })
    }

    fn id_in_use(&self, id: u32) -> io::Result<bool> {
        id_in_use(id)
    }
}

/// True when a user or a group has the id, asked in-process (no `getent`, ADR-049 point 3).
pub fn id_in_use(id: u32) -> io::Result<bool> {
    Ok(ruya_users::uid_in_use(id).map_err(nss_error)?
        || ruya_users::gid_in_use(id).map_err(nss_error)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ruya_accounts::wire::Code;
    use ruya_accounts::{Reply, Request};

    #[test]
    fn only_an_ok_reply_is_done() {
        let request = Request::Delete { id: "p3".into() };
        assert!(reply_result(&request, &Reply::Ok.encode()).is_ok());
        for code in [
            Code::NotAllowed,
            Code::BadRequest,
            Code::NotAProfileUser,
            Code::Failed,
        ] {
            let err = reply_result(&request, &Reply::Error(code).encode()).unwrap_err();
            assert_eq!(
                err.to_string(),
                format!("ruya-accounts: delete p3: {}", code.as_str())
            );
        }
        // The helper died before it answered, or answered something else.
        for bad in [&b""[..], b"ok", b"okay\n", b"ok\nok\n"] {
            let err = reply_result(&request, bad).unwrap_err();
            assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        }
    }
}
