//! /usr/libexec/ruya-platform-identify: one request of `ruya-platform` on the connection the socket
//! unit accepted (`ruya-platform-identify.socket`, `Accept=yes`, `StandardInput=socket`), the steps
//! of `serve.rs`, one journal line, exit. It runs with `CAP_SYS_PTRACE` and `CAP_DAC_READ_SEARCH`
//! and nothing else, without a bus or a network (`ruya-platform-identify@.service`).

fn main() {
    #[cfg(target_os = "linux")]
    std::process::exit(linux::run());
    #[cfg(not(target_os = "linux"))]
    {
        eprintln!("ruya-platform-identify: Linux only");
        std::process::exit(1);
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use std::fs::File;
    use std::io::{self, IoSliceMut, Read};
    use std::mem::MaybeUninit;
    use std::os::fd::{AsFd, AsRawFd, OwnedFd};
    use std::os::unix::fs::MetadataExt;
    use std::path::Path;

    use rustix::net::sockopt::socket_peercred;
    use rustix::net::{
        recvmsg, send, RecvAncillaryBuffer, RecvAncillaryMessage, RecvFlags, ReturnFlags, SendFlags,
    };
    use ruya_fs::{Dir, NotFollowed};
    use ruya_platform_identify::fdinfo::own_pidfd_pid;
    use ruya_platform_identify::serve::{
        describe, file_error, serve, Connection, Kernel, Opened, Received,
    };
    use ruya_platform_identify::wire::{FileError, REQUEST_LEN};

    /// More descriptors than a request has, so a request with two is seen (and refused).
    const MAX_FDS: usize = 4;

    pub fn run() -> i32 {
        let stdin = io::stdin();
        let mut conn = Socket {
            fd: stdin.as_fd(),
            fds: Vec::new(),
        };
        match serve(&mut conn, &Proc) {
            Ok(reply) => {
                eprintln!("ruya-platform-identify: {}", describe(&reply));
                0
            }
            Err(err) => {
                eprintln!("ruya-platform-identify: the connection failed: {err}");
                1
            }
        }
    }

    /// The accepted connection on stdin and the descriptors it brought (closed on exit).
    struct Socket<'a> {
        fd: std::os::fd::BorrowedFd<'a>,
        fds: Vec<OwnedFd>,
    }

    impl Connection for Socket<'_> {
        fn peer_uid(&self) -> Option<u32> {
            socket_peercred(self.fd).ok().map(|cred| cred.uid.as_raw())
        }

        fn receive(&mut self) -> io::Result<Received> {
            // One byte more than a request, so a longer one is seen.
            let mut data = [0u8; REQUEST_LEN + 1];
            let mut space = [MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(MAX_FDS))];
            let mut control = RecvAncillaryBuffer::new(&mut space);
            let msg = recvmsg(
                self.fd,
                &mut [IoSliceMut::new(&mut data)],
                &mut control,
                RecvFlags::CMSG_CLOEXEC,
            )?;
            let mut fds = Vec::new();
            for message in control.drain() {
                if let RecvAncillaryMessage::ScmRights(passed) = message {
                    for fd in passed {
                        fds.push(fd.as_raw_fd());
                        self.fds.push(fd);
                    }
                }
            }
            Ok(Received {
                data: data[..msg.bytes.min(data.len())].to_vec(),
                fds,
                truncated: msg
                    .flags
                    .intersects(ReturnFlags::TRUNC | ReturnFlags::CTRUNC),
            })
        }

        fn send(&mut self, reply: &[u8]) -> io::Result<()> {
            if send(self.fd, reply, SendFlags::NOSIGNAL)? != reply.len() {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "the reply was cut",
                ));
            }
            Ok(())
        }
    }

    /// A file of the caller, opened by `ruya-fs` (never through a link, regular files only).
    struct Caller(File);

    impl Read for Caller {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            self.0.read(buf)
        }
    }

    impl Opened for Caller {
        fn owner(&self) -> Result<u32, FileError> {
            self.0
                .metadata()
                .map(|m| m.uid())
                .map_err(|e| file_error(&e))
        }
    }

    /// `ruya-fs` refuses a link (`NotFollowed`) and anything but a regular file (`InvalidInput`).
    fn open_error(err: &io::Error) -> FileError {
        if NotFollowed::is(err) || err.kind() == io::ErrorKind::InvalidInput {
            FileError::NotRegular
        } else {
            file_error(err)
        }
    }

    /// The kernel's `/proc`. The folder a file is in (`/proc/<pid>`, the process's root) is the
    /// kernel's, so the path to it is followed; the file itself never is.
    struct Proc;

    impl Proc {
        fn open(folder: &str, name: &str) -> Result<Caller, FileError> {
            let dir = Dir::open(Path::new(folder)).map_err(|e| open_error(&e))?;
            let file = dir.open_file(Path::new(name)).map_err(|e| open_error(&e))?;
            Ok(Caller(file))
        }
    }

    impl Kernel for Proc {
        type File = Caller;

        fn pidfd_pid(&self, fd: i32) -> Option<i32> {
            own_pidfd_pid(fd)
        }

        fn open_info(&self, pid: u32) -> Result<Caller, FileError> {
            Proc::open(&format!("/proc/{pid}/root"), ".flatpak-info")
        }

        fn open_cgroup(&self, pid: u32) -> Result<Caller, FileError> {
            Proc::open(&format!("/proc/{pid}"), "cgroup")
        }
    }
}
