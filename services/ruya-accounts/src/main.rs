//! /usr/libexec/ruya-accounts: one request of `ruya-profiles` on the connection the socket unit
//! accepted (`ruya-accounts.socket`, `Accept=yes`, `StandardInput=socket`), the steps of
//! `serve.rs`, one journal line, exit. It runs as root with the capabilities `useradd` and
//! `userdel` need and nothing else, no bus name, no network, and the PIN store hidden
//! (`ruya-accounts@.service`).

fn main() {
    #[cfg(target_os = "linux")]
    std::process::exit(linux::run());
    #[cfg(not(target_os = "linux"))]
    {
        eprintln!("ruya-accounts: Linux only");
        std::process::exit(1);
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use std::io;
    use std::os::fd::{AsFd, BorrowedFd};
    use std::process::{Command, ExitStatus, Stdio};
    use std::time::Duration;

    use rustix::net::sockopt::socket_peercred;
    use rustix::net::{recv, send, RecvFlags, SendFlags};
    use ruya_accounts::serve::{describe, serve, Connection, Received, System};
    use ruya_accounts::wire::{MAX_REQUEST, PEER_USER};
    use ruya_users::Passwd;

    pub fn run() -> i32 {
        let stdin = io::stdin();
        let mut conn = Socket { fd: stdin.as_fd() };
        match serve(&mut conn, &Unix) {
            Ok(served) => {
                eprintln!("ruya-accounts: {}", describe(&served));
                0
            }
            Err(err) => {
                eprintln!("ruya-accounts: the connection failed: {err}");
                1
            }
        }
    }

    /// The accepted connection on stdin.
    struct Socket<'a> {
        fd: BorrowedFd<'a>,
    }

    impl Connection for Socket<'_> {
        fn peer_uid(&self) -> Option<u32> {
            socket_peercred(self.fd).ok().map(|cred| cred.uid.as_raw())
        }

        fn receive(&mut self) -> io::Result<Received> {
            // One byte more than a request, and TRUNC for the message's real length, so a longer
            // one is seen.
            let mut data = [0u8; MAX_REQUEST + 1];
            let (_, len) = recv(self.fd, &mut data[..], RecvFlags::TRUNC)?;
            Ok(Received {
                data: data[..len.min(data.len())].to_vec(),
                truncated: len > data.len(),
            })
        }

        fn send(&mut self, reply: &[u8]) -> io::Result<usize> {
            Ok(send(self.fd, reply, SendFlags::NOSIGNAL)?)
        }
    }

    /// The real user database and commands.
    struct Unix;

    /// A command of the helper. Its stdin is not the request socket (`StandardInput=socket`): a
    /// command never reads or answers the peer.
    fn command(program: &str) -> Command {
        let mut command = Command::new(program);
        command.stdin(Stdio::null());
        command
    }

    fn userdel(user: &str) -> io::Result<ExitStatus> {
        command("userdel").arg("--remove").arg(user).status()
    }

    impl System for Unix {
        fn peer_user_uid(&self) -> Option<u32> {
            ruya_users::uid_of(PEER_USER)
        }

        fn lookup(&self, user: &str) -> Result<Option<Passwd>, i32> {
            ruya_users::passwd_of(user)
        }

        fn useradd(&self, args: &[String]) -> io::Result<()> {
            let status = command("useradd").args(args).status()?;
            if status.success() {
                Ok(())
            } else {
                Err(io::Error::other(format!("useradd failed: {status}")))
            }
        }

        /// Ends the user's manager and apps, drops the linger, then `userdel --remove`.
        fn delete_user(&self, user: &str) -> io::Result<()> {
            // `ruya-session` keeps a profile's systemd manager running (linger) once an app was
            // launched as it, and userdel refuses a user with processes. End the manager and its
            // apps and drop the linger first; both are no-ops for a user that never launched.
            for args in [["terminate-user", user], ["disable-linger", user]] {
                if let Err(err) = command("loginctl").args(args).status() {
                    eprintln!("ruya-accounts: loginctl {}: {err}", args[0]);
                }
            }
            // terminate-user returns before the processes are gone: userdel exits 8 until they
            // are.
            let mut status = userdel(user)?;
            for _ in 0..10 {
                if status.code() != Some(8) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(500));
                status = userdel(user)?;
            }
            // userdel exits 6 when the user does not exist: nothing left to remove.
            if status.success() || status.code() == Some(6) {
                Ok(())
            } else {
                Err(io::Error::other(format!("userdel {user} failed: {status}")))
            }
        }
    }
}
