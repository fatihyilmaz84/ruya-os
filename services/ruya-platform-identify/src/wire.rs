//! The wire between the door and the helper: one `SOCK_SEQPACKET` message each way on a connection
//! the socket unit accepted (`Accept=yes`, so one helper process per request). All numbers are
//! little-endian.
//!
//! Request (exactly [`REQUEST_LEN`] bytes, with exactly one descriptor, the caller's pidfd, as
//! `SCM_RIGHTS`): `version u8 = 1`, `uid u32` (the bus's `UnixUserID` of the caller).
//!
//! Reply: `version u8 = 1`, then `kind u8`: `0` is the files, any other value is a [`Refusal`]
//! code and ends the reply. The files are `pid u32` (as the helper's own fdinfo of the pidfd named
//! it, never 0) and two parts, the `.flatpak-info` then the `cgroup`: each `code u8`, `len u32`,
//! `len` bytes. Code `0` is the bytes (at most [`MAX_INFO`] and [`MAX_CGROUP`]); any other is a
//! [`FileError`] with `len` 0. An unknown version, kind or code, a part over its cap and bytes
//! after the end are refused.

/// Where the socket unit listens (`ruya-platform-identify.socket`, `ListenSequentialPacket=`).
pub const SOCKET: &str = "/run/ruya-platform-identify.sock";
pub const VERSION: u8 = 1;
/// The largest `.flatpak-info` sent: the keyfile reader's own cap, so the door can parse anything
/// it gets.
pub const MAX_INFO: usize = ruya_keyfile::MAX_BYTES;
/// The largest `/proc/<pid>/cgroup` sent; the real file is one short line on cgroup v2.
pub const MAX_CGROUP: usize = 16 * 1024;
pub const REQUEST_LEN: usize = 5;
const PART_HEADER: usize = 5;
/// The largest reply: version, kind, pid and both parts full.
pub const MAX_REPLY: usize = 2 + 4 + 2 * PART_HEADER + MAX_INFO + MAX_CGROUP;

/// What the door asks: the files of the caller its pidfd names, for the caller's bus uid.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Request {
    pub uid: u32,
}

/// Why the helper answered no files at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// Not one request of [`REQUEST_LEN`] bytes with exactly one descriptor.
    BadRequest = 1,
    /// The peer (`SO_PEERCRED`) is not root: nothing was read, not even the request.
    NotRoot = 2,
    /// The descriptor is no pidfd (its fdinfo has no `Pid:`).
    NotAPidfd = 3,
    /// The pidfd's process is gone (`Pid: -1`).
    ProcessGone = 4,
}

/// Why one file was not sent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileError {
    /// Nothing there: an unsandboxed caller has no `/.flatpak-info`.
    Missing = 1,
    /// The kernel refused the open or the read (EACCES, EPERM).
    Denied = 2,
    /// `.flatpak-info` is not owned by the request's uid: nothing was read (ADR-022 decision 4: a
    /// file bind-mounted there by the caller is never read for it).
    NotOwned = 3,
    /// A link, a folder, a FIFO or a device.
    NotRegular = 4,
    /// Bigger than its cap.
    TooLarge = 5,
    /// Any other error.
    Failed = 6,
}

/// The two files of one caller.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Files {
    pub pid: u32,
    pub info: Result<Vec<u8>, FileError>,
    pub cgroup: Result<Vec<u8>, FileError>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reply {
    Refused(Refusal),
    Files(Files),
}

/// A reply or request that is not on the wire's grammar (for the log).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WireError(pub &'static str);

impl std::fmt::Display for WireError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

impl std::error::Error for WireError {}

impl Refusal {
    pub fn code(self) -> u8 {
        self as u8
    }

    pub fn from_code(code: u8) -> Option<Refusal> {
        [
            Refusal::BadRequest,
            Refusal::NotRoot,
            Refusal::NotAPidfd,
            Refusal::ProcessGone,
        ]
        .into_iter()
        .find(|r| r.code() == code)
    }

    /// The name in the journal.
    pub fn as_str(self) -> &'static str {
        match self {
            Refusal::BadRequest => "bad-request",
            Refusal::NotRoot => "not-root",
            Refusal::NotAPidfd => "not-a-pidfd",
            Refusal::ProcessGone => "process-gone",
        }
    }
}

impl FileError {
    pub fn code(self) -> u8 {
        self as u8
    }

    pub fn from_code(code: u8) -> Option<FileError> {
        [
            FileError::Missing,
            FileError::Denied,
            FileError::NotOwned,
            FileError::NotRegular,
            FileError::TooLarge,
            FileError::Failed,
        ]
        .into_iter()
        .find(|e| e.code() == code)
    }

    /// The name in the journal (`not-owned` is what vm-platform-check.sh looks for).
    pub fn as_str(self) -> &'static str {
        match self {
            FileError::Missing => "missing",
            FileError::Denied => "denied",
            FileError::NotOwned => "not-owned",
            FileError::NotRegular => "not-regular",
            FileError::TooLarge => "too-large",
            FileError::Failed => "failed",
        }
    }
}

pub fn encode_request(request: &Request) -> [u8; REQUEST_LEN] {
    let uid = request.uid.to_le_bytes();
    [VERSION, uid[0], uid[1], uid[2], uid[3]]
}

pub fn decode_request(bytes: &[u8]) -> Result<Request, WireError> {
    match bytes {
        [VERSION, a, b, c, d] => Ok(Request {
            uid: u32::from_le_bytes([*a, *b, *c, *d]),
        }),
        [v, ..] if *v != VERSION => Err(WireError("unknown version")),
        _ => Err(WireError("a request is 5 bytes")),
    }
}

fn put_part(out: &mut Vec<u8>, part: &Result<Vec<u8>, FileError>, cap: usize) {
    // A part over its cap travels as too-large: the reply never carries more than the door reads.
    let part = match part {
        Ok(bytes) if bytes.len() > cap => Err(FileError::TooLarge),
        other => other.as_ref().map(Vec::as_slice).map_err(|e| *e),
    };
    match part {
        Ok(bytes) => {
            out.push(0);
            // The cap (64 KiB at most) fits a u32.
            out.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
            out.extend_from_slice(bytes);
        }
        Err(e) => {
            out.push(e.code());
            out.extend_from_slice(&0u32.to_le_bytes());
        }
    }
}

pub fn encode_reply(reply: &Reply) -> Vec<u8> {
    let mut out = vec![VERSION];
    match reply {
        Reply::Refused(r) => out.push(r.code()),
        Reply::Files(files) => {
            out.push(0);
            out.extend_from_slice(&files.pid.to_le_bytes());
            put_part(&mut out, &files.info, MAX_INFO);
            put_part(&mut out, &files.cgroup, MAX_CGROUP);
        }
    }
    out
}

/// Reads a reply front to back.
struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], WireError> {
        if self.0.len() < n {
            return Err(WireError("the reply is cut short"));
        }
        let (head, rest) = self.0.split_at(n);
        self.0 = rest;
        Ok(head)
    }

    fn u8(&mut self) -> Result<u8, WireError> {
        Ok(self.take(1)?[0])
    }

    fn u32(&mut self) -> Result<u32, WireError> {
        let b = self.take(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    fn part(&mut self, cap: usize) -> Result<Result<Vec<u8>, FileError>, WireError> {
        let code = self.u8()?;
        let len = self.u32()? as usize;
        if code != 0 {
            let e = FileError::from_code(code).ok_or(WireError("unknown file error code"))?;
            if len != 0 {
                return Err(WireError("a file error carries bytes"));
            }
            return Ok(Err(e));
        }
        if len > cap {
            return Err(WireError("a file over its cap"));
        }
        Ok(Ok(self.take(len)?.to_vec()))
    }
}

pub fn decode_reply(bytes: &[u8]) -> Result<Reply, WireError> {
    if bytes.len() > MAX_REPLY {
        return Err(WireError("the reply is over its cap"));
    }
    let mut r = Reader(bytes);
    if r.u8()? != VERSION {
        return Err(WireError("unknown version"));
    }
    let reply = match r.u8()? {
        0 => {
            let pid = r.u32()?;
            if pid == 0 {
                return Err(WireError("pid 0"));
            }
            let info = r.part(MAX_INFO)?;
            let cgroup = r.part(MAX_CGROUP)?;
            Reply::Files(Files { pid, info, cgroup })
        }
        code => Reply::Refused(Refusal::from_code(code).ok_or(WireError("unknown refusal code"))?),
    };
    if !r.0.is_empty() {
        return Err(WireError("bytes after the reply"));
    }
    Ok(reply)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn files(info: Result<Vec<u8>, FileError>, cgroup: Result<Vec<u8>, FileError>) -> Reply {
        Reply::Files(Files {
            pid: 4242,
            info,
            cgroup,
        })
    }

    #[test]
    fn a_request_round_trips_and_nothing_else_is_one() {
        for uid in [0, 1001, u32::MAX] {
            let r = Request { uid };
            assert_eq!(decode_request(&encode_request(&r)), Ok(r));
        }
        assert_eq!(
            encode_request(&Request { uid: 1001 }),
            [1, 0xe9, 0x03, 0, 0]
        );
        for bad in [
            &[][..],
            &[1, 0, 0, 0],
            &[1, 0, 0, 0, 0, 0],
            &[2, 0, 0, 0, 0],
        ] {
            assert!(decode_request(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn every_reply_round_trips() {
        let mut replies: Vec<Reply> = [
            Refusal::BadRequest,
            Refusal::NotRoot,
            Refusal::NotAPidfd,
            Refusal::ProcessGone,
        ]
        .into_iter()
        .map(Reply::Refused)
        .collect();
        replies.push(files(
            Ok(b"[Application]\n".to_vec()),
            Ok(b"0::/x\n".to_vec()),
        ));
        replies.push(files(Ok(Vec::new()), Ok(Vec::new())));
        replies.push(files(Ok(vec![b'a'; MAX_INFO]), Ok(vec![b'c'; MAX_CGROUP])));
        for e in [
            FileError::Missing,
            FileError::Denied,
            FileError::NotOwned,
            FileError::NotRegular,
            FileError::TooLarge,
            FileError::Failed,
        ] {
            replies.push(files(Err(e), Err(e)));
        }
        for r in replies {
            let bytes = encode_reply(&r);
            assert!(bytes.len() <= MAX_REPLY);
            assert_eq!(decode_reply(&bytes), Ok(r));
        }
    }

    #[test]
    fn a_file_over_its_cap_is_sent_as_too_large_and_refused_when_received() {
        let r = files(Ok(vec![b'a'; MAX_INFO + 1]), Ok(vec![b'c'; MAX_CGROUP + 1]));
        assert_eq!(
            decode_reply(&encode_reply(&r)),
            Ok(files(Err(FileError::TooLarge), Err(FileError::TooLarge)))
        );
        // A helper that sent it anyway: the door refuses the reply.
        let mut bytes = vec![VERSION, 0];
        bytes.extend_from_slice(&4242u32.to_le_bytes());
        bytes.push(0);
        bytes.extend_from_slice(&((MAX_INFO + 1) as u32).to_le_bytes());
        bytes.extend_from_slice(&vec![b'a'; MAX_INFO + 1]);
        bytes.extend_from_slice(&[0, 0, 0, 0, 0]);
        assert_eq!(decode_reply(&bytes), Err(WireError("a file over its cap")));
        let mut huge = encode_reply(&files(Ok(Vec::new()), Ok(Vec::new())));
        huge.resize(MAX_REPLY + 1, 0);
        assert_eq!(
            decode_reply(&huge),
            Err(WireError("the reply is over its cap"))
        );
    }

    #[test]
    fn unknown_codes_and_stray_bytes_are_refused() {
        let good = encode_reply(&files(Ok(b"i".to_vec()), Err(FileError::Missing)));
        assert!(decode_reply(&good).is_ok());
        let with = |at: usize, v: u8| {
            let mut b = good.clone();
            b[at] = v;
            decode_reply(&b)
        };
        assert_eq!(with(0, 2), Err(WireError("unknown version")));
        assert_eq!(with(1, 5), Err(WireError("unknown refusal code")));
        assert_eq!(with(1, 0xff), Err(WireError("unknown refusal code")));
        // The info part's code (offset 6), the cgroup part's code (6 + 5 + 1).
        assert_eq!(with(6, 7), Err(WireError("unknown file error code")));
        assert_eq!(with(12, 0xff), Err(WireError("unknown file error code")));
        // A file error with bytes, a pid of 0.
        assert_eq!(with(13, 1), Err(WireError("a file error carries bytes")));
        assert_eq!(
            decode_reply(&[VERSION, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0]),
            Err(WireError("pid 0"))
        );
        let mut extra = good.clone();
        extra.push(0);
        assert_eq!(
            decode_reply(&extra),
            Err(WireError("bytes after the reply"))
        );
        assert_eq!(
            decode_reply(&good[..good.len() - 1]),
            Err(WireError("the reply is cut short"))
        );
        assert_eq!(decode_reply(&[]), Err(WireError("the reply is cut short")));
        assert_eq!(
            decode_reply(&[VERSION, 2, 0]),
            Err(WireError("bytes after the reply"))
        );
        assert_eq!(Refusal::from_code(0), None);
        assert_eq!(FileError::from_code(0), None);
    }
}
