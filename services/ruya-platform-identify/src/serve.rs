//! The helper's steps for one accepted connection, over injected reads ([`Connection`] for the
//! socket, [`Kernel`] for `/proc`), so every step is tested on any host; `main.rs` has the Linux
//! implementations.
//!
//! 1. The peer must be root (`SO_PEERCRED`); otherwise the answer is `not-root` and nothing else
//!    happens: the request is not even received.
//! 2. One request of the wire's size with exactly one descriptor, else `bad-request`.
//! 3. The pid is the helper's own fdinfo `Pid:` of that descriptor (`not-a-pidfd` without one,
//!    `process-gone` for `-1`), never a number the door sends.
//! 4. `/proc/<pid>/root/.flatpak-info`: opened never through a link, a regular file, owned by the
//!    request's uid (`not-owned` otherwise, and not one byte is read), at most `MAX_INFO` bytes.
//! 5. `/proc/<pid>/cgroup`, at most `MAX_CGROUP` bytes.
//!
//! Nothing is parsed; the door applies the rules.

use std::io::{self, Read};

use crate::wire::{
    decode_request, encode_reply, FileError, Files, Refusal, Reply, MAX_CGROUP, MAX_INFO,
};

/// One request as the socket gave it.
#[derive(Debug, Default)]
pub struct Received {
    pub data: Vec<u8>,
    /// The descriptors that came with it, as numbers of this process; the connection owns them.
    pub fds: Vec<i32>,
    /// The kernel cut the data or the descriptors short (`MSG_TRUNC`, `MSG_CTRUNC`).
    pub truncated: bool,
}

/// The accepted connection (the socket unit's `StandardInput=socket`).
pub trait Connection {
    /// The peer's uid (`SO_PEERCRED`), `None` when it cannot be read.
    fn peer_uid(&self) -> Option<u32>;
    fn receive(&mut self) -> io::Result<Received>;
    fn send(&mut self, reply: &[u8]) -> io::Result<()>;
}

/// An opened file of the caller.
pub trait Opened: Read {
    /// The owner (`st_uid`) of the opened file itself (`fstat`).
    fn owner(&self) -> Result<u32, FileError>;
}

/// The kernel's `/proc`.
pub trait Kernel {
    type File: Opened;
    /// The `Pid:` of this process's fdinfo of `fd`, `None` when it is no pidfd.
    fn pidfd_pid(&self, fd: i32) -> Option<i32>;
    /// `/proc/<pid>/root/.flatpak-info`, opened (not read): a link, or anything but a regular
    /// file, is `NotRegular`.
    fn open_info(&self, pid: u32) -> Result<Self::File, FileError>;
    /// `/proc/<pid>/cgroup`, opened (not read).
    fn open_cgroup(&self, pid: u32) -> Result<Self::File, FileError>;
}

/// The [`FileError`] of an I/O error kind (the Linux reader maps its own refusals first).
pub fn file_error(err: &io::Error) -> FileError {
    match err.kind() {
        io::ErrorKind::NotFound => FileError::Missing,
        io::ErrorKind::PermissionDenied => FileError::Denied,
        _ => FileError::Failed,
    }
}

/// At most `max` bytes of `r`; more is `TooLarge`.
pub fn read_capped(r: &mut impl Read, max: usize) -> Result<Vec<u8>, FileError> {
    let mut bytes = Vec::new();
    r.take(max as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| file_error(&e))?;
    if bytes.len() > max {
        return Err(FileError::TooLarge);
    }
    Ok(bytes)
}

/// Steps 2 to 5 for a request of a root peer.
pub fn answer(kernel: &impl Kernel, received: &Received) -> Reply {
    let (Ok(request), [fd], false) = (
        decode_request(&received.data),
        received.fds.as_slice(),
        received.truncated,
    ) else {
        return Reply::Refused(Refusal::BadRequest);
    };
    let pid = match kernel.pidfd_pid(*fd) {
        None => return Reply::Refused(Refusal::NotAPidfd),
        Some(p) if p <= 0 => return Reply::Refused(Refusal::ProcessGone),
        // A positive i32 fits a u32.
        Some(p) => p as u32,
    };
    let info = kernel.open_info(pid).and_then(|mut file| {
        if file.owner()? != request.uid {
            return Err(FileError::NotOwned);
        }
        read_capped(&mut file, MAX_INFO)
    });
    let cgroup = kernel
        .open_cgroup(pid)
        .and_then(|mut file| read_capped(&mut file, MAX_CGROUP));
    Reply::Files(Files { pid, info, cgroup })
}

/// One connection, all steps; the reply sent is returned (for the journal line).
pub fn serve(conn: &mut impl Connection, kernel: &impl Kernel) -> io::Result<Reply> {
    let reply = if conn.peer_uid() != Some(0) {
        Reply::Refused(Refusal::NotRoot)
    } else {
        answer(kernel, &conn.receive()?)
    };
    conn.send(&encode_reply(&reply))?;
    Ok(reply)
}

/// The journal line of a reply: sizes and codes, never the bytes.
pub fn describe(reply: &Reply) -> String {
    fn part(p: &Result<Vec<u8>, FileError>) -> String {
        match p {
            Ok(b) => format!("{} bytes", b.len()),
            Err(e) => format!("{}, nothing read", e.as_str()),
        }
    }
    match reply {
        Reply::Refused(r) => format!("refused: {}", r.as_str()),
        Reply::Files(f) => format!(
            "pid {}: .flatpak-info {}; cgroup {}",
            f.pid,
            part(&f.info),
            part(&f.cgroup)
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{decode_reply, encode_request, Request};
    use std::cell::{Cell, RefCell};
    use std::collections::HashMap;

    const UID: u32 = 1001;
    const PID: u32 = 4242;
    const FD: i32 = 9;

    /// A file the fake kernel opened: its owner and bytes; counts what was read.
    struct FakeFile<'a> {
        owner: u32,
        bytes: io::Cursor<Vec<u8>>,
        read: &'a Cell<usize>,
    }

    impl Read for FakeFile<'_> {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            let n = self.bytes.read(buf)?;
            self.read.set(self.read.get() + n);
            Ok(n)
        }
    }

    impl Opened for FakeFile<'_> {
        fn owner(&self) -> Result<u32, FileError> {
            Ok(self.owner)
        }
    }

    /// pidfd -> pid; pid -> (.flatpak-info owner and bytes, cgroup).
    struct FakeKernel {
        pidfds: HashMap<i32, i32>,
        info: HashMap<u32, Result<(u32, Vec<u8>), FileError>>,
        cgroup: HashMap<u32, Vec<u8>>,
        /// Bytes read from any file, and every call made.
        read: Cell<usize>,
        calls: RefCell<Vec<&'static str>>,
    }

    impl FakeKernel {
        fn new() -> FakeKernel {
            let mut k = FakeKernel {
                pidfds: HashMap::new(),
                info: HashMap::new(),
                cgroup: HashMap::new(),
                read: Cell::new(0),
                calls: RefCell::new(Vec::new()),
            };
            k.pidfds.insert(FD, PID as i32);
            k.info
                .insert(PID, Ok((UID, b"[Application]\nname=a.b.C\n".to_vec())));
            k.cgroup.insert(PID, b"0::/user.slice\n".to_vec());
            k
        }
    }

    impl<'k> Kernel for &'k FakeKernel {
        type File = FakeFile<'k>;
        fn pidfd_pid(&self, fd: i32) -> Option<i32> {
            self.calls.borrow_mut().push("pidfd");
            self.pidfds.get(&fd).copied()
        }
        fn open_info(&self, pid: u32) -> Result<FakeFile<'k>, FileError> {
            self.calls.borrow_mut().push("info");
            let k: &'k FakeKernel = self;
            let (owner, bytes) = k.info.get(&pid).ok_or(FileError::Missing)?.clone()?;
            Ok(FakeFile {
                owner,
                bytes: io::Cursor::new(bytes),
                read: &k.read,
            })
        }
        fn open_cgroup(&self, pid: u32) -> Result<FakeFile<'k>, FileError> {
            self.calls.borrow_mut().push("cgroup");
            let k: &'k FakeKernel = self;
            let bytes = k.cgroup.get(&pid).ok_or(FileError::Missing)?.clone();
            Ok(FakeFile {
                owner: 0,
                bytes: io::Cursor::new(bytes),
                read: &k.read,
            })
        }
    }

    struct FakeConn {
        peer: Option<u32>,
        request: Received,
        received: bool,
        sent: Vec<Vec<u8>>,
    }

    impl FakeConn {
        fn from(peer: Option<u32>) -> FakeConn {
            FakeConn {
                peer,
                request: Received {
                    data: encode_request(&Request { uid: UID }).to_vec(),
                    fds: vec![FD],
                    truncated: false,
                },
                received: false,
                sent: Vec::new(),
            }
        }
    }

    impl Connection for FakeConn {
        fn peer_uid(&self) -> Option<u32> {
            self.peer
        }
        fn receive(&mut self) -> io::Result<Received> {
            self.received = true;
            Ok(std::mem::take(&mut self.request))
        }
        fn send(&mut self, reply: &[u8]) -> io::Result<()> {
            self.sent.push(reply.to_vec());
            Ok(())
        }
    }

    fn run(conn: &mut FakeConn, k: &FakeKernel) -> Reply {
        let reply = serve(conn, &k).expect("the fake socket works");
        assert_eq!(conn.sent.len(), 1, "one reply per connection");
        assert_eq!(
            decode_reply(&conn.sent[0]),
            Ok(reply.clone()),
            "sent as returned"
        );
        reply
    }

    #[test]
    fn a_root_peer_gets_the_callers_two_files() {
        let k = FakeKernel::new();
        let reply = run(&mut FakeConn::from(Some(0)), &k);
        assert_eq!(
            reply,
            Reply::Files(Files {
                pid: PID,
                info: Ok(b"[Application]\nname=a.b.C\n".to_vec()),
                cgroup: Ok(b"0::/user.slice\n".to_vec()),
            })
        );
        assert_eq!(
            describe(&reply),
            "pid 4242: .flatpak-info 25 bytes; cgroup 15 bytes"
        );
    }

    #[test]
    fn a_peer_that_is_not_root_is_refused_before_anything() {
        for peer in [Some(1001), Some(990), None] {
            let k = FakeKernel::new();
            let mut conn = FakeConn::from(peer);
            assert_eq!(
                run(&mut conn, &k),
                Reply::Refused(Refusal::NotRoot),
                "{peer:?}"
            );
            assert!(!conn.received, "the request is not even received");
            assert!(k.calls.borrow().is_empty(), "nothing is looked at");
        }
    }

    #[test]
    fn a_file_the_uid_does_not_own_is_not_read() {
        let mut k = FakeKernel::new();
        // /etc/shadow bound onto /.flatpak-info by code running as the profile (root owns it).
        k.info
            .insert(PID, Ok((0, b"root:$6$secret:...\n".to_vec())));
        let Reply::Files(files) = run(&mut FakeConn::from(Some(0)), &k) else {
            panic!("files expected");
        };
        assert_eq!(files.info, Err(FileError::NotOwned));
        assert_eq!(
            k.read.get(),
            b"0::/user.slice\n".len(),
            "only the cgroup was read"
        );
        assert_eq!(
            describe(&Reply::Files(files)),
            "pid 4242: .flatpak-info not-owned, nothing read; cgroup 15 bytes"
        );
    }

    #[test]
    fn the_pid_is_the_helpers_own_look_at_the_pidfd() {
        let mut k = FakeKernel::new();
        k.pidfds.insert(FD, -1);
        assert_eq!(
            run(&mut FakeConn::from(Some(0)), &k),
            Reply::Refused(Refusal::ProcessGone)
        );
        k.pidfds.remove(&FD);
        assert_eq!(
            run(&mut FakeConn::from(Some(0)), &k),
            Reply::Refused(Refusal::NotAPidfd)
        );
        assert_eq!(*k.calls.borrow(), ["pidfd", "pidfd"], "no file is opened");
    }

    #[test]
    fn a_malformed_request_is_refused() {
        let k = FakeKernel::new();
        let cases: [(Vec<u8>, Vec<i32>, bool); 5] = [
            (vec![1, 0, 0], vec![FD], false),
            (
                encode_request(&Request { uid: UID }).to_vec(),
                vec![],
                false,
            ),
            (
                encode_request(&Request { uid: UID }).to_vec(),
                vec![FD, FD],
                false,
            ),
            (
                encode_request(&Request { uid: UID }).to_vec(),
                vec![FD],
                true,
            ),
            (vec![2, 0, 0, 0, 0], vec![FD], false),
        ];
        for (data, fds, truncated) in cases {
            let mut conn = FakeConn::from(Some(0));
            conn.request = Received {
                data,
                fds,
                truncated,
            };
            assert_eq!(run(&mut conn, &k), Reply::Refused(Refusal::BadRequest));
        }
        assert!(k.calls.borrow().is_empty());
    }

    #[test]
    fn each_file_answers_for_itself() {
        let mut k = FakeKernel::new();
        k.info.insert(PID, Err(FileError::Denied));
        k.cgroup.remove(&PID);
        assert_eq!(
            run(&mut FakeConn::from(Some(0)), &k),
            Reply::Files(Files {
                pid: PID,
                info: Err(FileError::Denied),
                cgroup: Err(FileError::Missing),
            })
        );
        k.info.insert(PID, Ok((UID, vec![b'x'; MAX_INFO + 1])));
        let Reply::Files(files) = run(&mut FakeConn::from(Some(0)), &k) else {
            panic!("files expected");
        };
        assert_eq!(files.info, Err(FileError::TooLarge));
    }

    #[test]
    fn io_errors_map_to_codes() {
        assert_eq!(
            file_error(&io::ErrorKind::NotFound.into()),
            FileError::Missing
        );
        assert_eq!(
            file_error(&io::ErrorKind::PermissionDenied.into()),
            FileError::Denied
        );
        assert_eq!(
            file_error(&io::ErrorKind::Interrupted.into()),
            FileError::Failed
        );
        assert_eq!(read_capped(&mut &b"abc"[..], 3), Ok(b"abc".to_vec()));
        assert_eq!(read_capped(&mut &b"abcd"[..], 3), Err(FileError::TooLarge));
    }
}
