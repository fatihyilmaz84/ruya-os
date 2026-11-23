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
    use std::io::{self, Read};
    use std::os::fd::{FromRawFd, OwnedFd};
    use std::os::unix::fs::MetadataExt;
    use std::path::Path;

    use ruya_fs::{Dir, NotFollowed};
    use ruya_platform_identify::fdinfo::own_pidfd_pid;
    use ruya_platform_identify::serve::{
        describe, file_error, serve, Connection, Kernel, Opened, Received,
    };
    use ruya_platform_identify::wire::{FileError, REQUEST_LEN};

    /// More descriptors than a request has, so a request with two is seen (and refused).
    const MAX_FDS: usize = 4;

    pub fn run() -> i32 {
        let mut conn = Socket {
            fd: 0,
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
    struct Socket {
        fd: i32,
        fds: Vec<OwnedFd>,
    }

    impl Connection for Socket {
        fn peer_uid(&self) -> Option<u32> {
            // SAFETY: an all-zero ucred is valid; getsockopt writes at most `len` bytes into it.
            let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
            let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
            // SAFETY: getsockopt(2) on our own descriptor with a buffer that outlives the call.
            let rc = unsafe {
                libc::getsockopt(
                    self.fd,
                    libc::SOL_SOCKET,
                    libc::SO_PEERCRED,
                    &mut cred as *mut libc::ucred as *mut libc::c_void,
                    &mut len,
                )
            };
            (rc == 0 && len as usize == std::mem::size_of::<libc::ucred>()).then_some(cred.uid)
        }

        fn receive(&mut self) -> io::Result<Received> {
            // One byte more than a request, so a longer one is seen.
            let mut data = [0u8; REQUEST_LEN + 1];
            // 8-byte aligned room for MAX_FDS descriptors (CMSG_SPACE of 16 bytes is 32).
            let mut control = [0u64; 8];
            // SAFETY: CMSG_SPACE is a pure size computation.
            let space = unsafe { libc::CMSG_SPACE((MAX_FDS * std::mem::size_of::<i32>()) as u32) };
            debug_assert!(space as usize <= std::mem::size_of_val(&control));
            let mut iov = libc::iovec {
                iov_base: data.as_mut_ptr() as *mut libc::c_void,
                iov_len: data.len(),
            };
            // SAFETY: an all-zero msghdr is a valid empty one.
            let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
            msg.msg_iov = &mut iov;
            msg.msg_iovlen = 1;
            msg.msg_control = control.as_mut_ptr() as *mut libc::c_void;
            msg.msg_controllen = space as _;
            // SAFETY: msg points at buffers that live through the call.
            let n = unsafe { libc::recvmsg(self.fd, &mut msg, libc::MSG_CMSG_CLOEXEC) };
            if n < 0 {
                return Err(io::Error::last_os_error());
            }
            let mut fds = Vec::new();
            // SAFETY: the cmsg walk stays inside `control`, as filled in by the kernel; each
            // descriptor it passed is new to this process and owned from here on.
            unsafe {
                let mut c = libc::CMSG_FIRSTHDR(&msg);
                while !c.is_null() {
                    if (*c).cmsg_level == libc::SOL_SOCKET && (*c).cmsg_type == libc::SCM_RIGHTS {
                        let bytes = (*c).cmsg_len as usize - libc::CMSG_LEN(0) as usize;
                        let data = libc::CMSG_DATA(c) as *const i32;
                        for i in 0..bytes / std::mem::size_of::<i32>() {
                            let fd = std::ptr::read_unaligned(data.add(i));
                            self.fds.push(OwnedFd::from_raw_fd(fd));
                            fds.push(fd);
                        }
                    }
                    c = libc::CMSG_NXTHDR(&msg, c);
                }
            }
            Ok(Received {
                data: data[..n as usize].to_vec(),
                fds,
                truncated: msg.msg_flags & (libc::MSG_TRUNC | libc::MSG_CTRUNC) != 0,
            })
        }

        fn send(&mut self, reply: &[u8]) -> io::Result<()> {
            // SAFETY: send(2) of a buffer that lives through the call.
            let n = unsafe {
                libc::send(
                    self.fd,
                    reply.as_ptr() as *const libc::c_void,
                    reply.len(),
                    libc::MSG_NOSIGNAL,
                )
            };
            if n < 0 {
                return Err(io::Error::last_os_error());
            }
            if n as usize != reply.len() {
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
