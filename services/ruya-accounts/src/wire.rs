//! The helper's socket protocol (ADR-049): one request line per connection, one reply line back.
//!
//! A request is at most `MAX_REQUEST` bytes, printable ASCII words separated by single spaces,
//! ending in one `\n`, and exactly one of:
//!
//! ```text
//! create <id> regular          a kept profile's user (useradd picks the uid)
//! create <id> guest <uid>      a temporary guest's user with that uid and gid
//! delete <id>                  a kept profile's user and home
//! remove-guest <id> <uid>      a temporary guest's user and home, when it has that uid
//! ```
//!
//! `<id>` is a profile id (`ruya_ids::valid_profile_id`: no `/`, no `.`, so never a path), the
//! user is always `ruya-<id>`; `<uid>` is decimal without a leading zero, in `GUEST_UIDS`. Nothing
//! else is accepted: no options, no paths, no free text. The reply is `ok` or `error <code>`.

use ruya_ids::valid_profile_id;

use crate::account::{AccountKind, GUEST_UIDS};

/// Where the socket unit listens (`ruya-accounts.socket`).
pub const SOCKET: &str = "/run/ruya-accounts.sock";
/// The one user the helper answers (`SO_PEERCRED`); the socket's group is the same.
pub const PEER_USER: &str = "ruya-profiles";
/// The longest request: `remove-guest ` (13), a 32-byte id, a space, a 5-digit uid and the newline
/// are 52 bytes.
pub const MAX_REQUEST: usize = 64;
/// The longest reply (`error not-a-profile-user\n` is 25 bytes).
pub const MAX_REPLY: usize = 64;

/// One request of `ruya-profiles`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    Create { id: String, kind: AccountKind },
    Delete { id: String },
    RemoveGuest { id: String, uid: u32 },
}

/// Why a request line is refused (the helper answers `error bad-request` for every one; the
/// reason goes to its journal line).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BadRequest {
    /// More than `MAX_REQUEST` bytes, or cut by the socket.
    TooLong,
    /// Not exactly one line ending in `\n`.
    NotOneLine,
    /// A byte that is not printable ASCII or a space (a control character, a tab, NUL, UTF-8).
    NotText,
    /// Words not separated by exactly one space (an empty word).
    Spacing,
    UnknownVerb,
    BadId,
    /// `create` with a kind other than `regular` or `guest`.
    BadKind,
    BadUid,
    MissingArgument,
    ExtraArgument,
}

impl BadRequest {
    pub fn as_str(self) -> &'static str {
        match self {
            BadRequest::TooLong => "too long",
            BadRequest::NotOneLine => "not one line",
            BadRequest::NotText => "not printable ASCII",
            BadRequest::Spacing => "not single-spaced words",
            BadRequest::UnknownVerb => "unknown verb",
            BadRequest::BadId => "not a profile id",
            BadRequest::BadKind => "not regular or guest",
            BadRequest::BadUid => "not a guest uid",
            BadRequest::MissingArgument => "an argument is missing",
            BadRequest::ExtraArgument => "an extra argument",
        }
    }
}

impl Request {
    /// The request as its line, without the newline (also the helper's journal text: ids and uids
    /// only, nothing secret).
    pub fn line(&self) -> String {
        match self {
            Request::Create {
                id,
                kind: AccountKind::Regular,
            } => format!("create {id} regular"),
            Request::Create {
                id,
                kind: AccountKind::Guest { uid },
            } => format!("create {id} guest {uid}"),
            Request::Delete { id } => format!("delete {id}"),
            Request::RemoveGuest { id, uid } => format!("remove-guest {id} {uid}"),
        }
    }

    /// The bytes sent on the socket.
    pub fn encode(&self) -> Vec<u8> {
        let mut bytes = self.line().into_bytes();
        bytes.push(b'\n');
        bytes
    }

    /// Reads one request; everything that is not exactly the grammar is refused.
    pub fn parse(bytes: &[u8]) -> Result<Request, BadRequest> {
        if bytes.len() > MAX_REQUEST {
            return Err(BadRequest::TooLong);
        }
        let Some(body) = bytes.strip_suffix(b"\n") else {
            return Err(BadRequest::NotOneLine);
        };
        if body.contains(&b'\n') {
            return Err(BadRequest::NotOneLine);
        }
        if !body.iter().all(|b| b.is_ascii_graphic() || *b == b' ') {
            return Err(BadRequest::NotText);
        }
        // Only printable ASCII is left, so this is UTF-8.
        let text = std::str::from_utf8(body).map_err(|_| BadRequest::NotText)?;
        let words: Vec<&str> = text.split(' ').collect();
        if words.iter().any(|w| w.is_empty()) {
            return Err(BadRequest::Spacing);
        }
        let (verb, args) = words.split_first().ok_or(BadRequest::Spacing)?;
        let arity = |n: usize| match args.len().cmp(&n) {
            std::cmp::Ordering::Less => Err(BadRequest::MissingArgument),
            std::cmp::Ordering::Greater => Err(BadRequest::ExtraArgument),
            std::cmp::Ordering::Equal => Ok(()),
        };
        match *verb {
            "create" => {
                if args.len() < 2 {
                    return Err(BadRequest::MissingArgument);
                }
                let id = profile_id(args[0])?;
                let kind = match args[1] {
                    "regular" => {
                        arity(2)?;
                        AccountKind::Regular
                    }
                    "guest" => {
                        arity(3)?;
                        AccountKind::Guest {
                            uid: guest_uid(args[2])?,
                        }
                    }
                    _ => return Err(BadRequest::BadKind),
                };
                Ok(Request::Create { id, kind })
            }
            "delete" => {
                arity(1)?;
                Ok(Request::Delete {
                    id: profile_id(args[0])?,
                })
            }
            "remove-guest" => {
                arity(2)?;
                Ok(Request::RemoveGuest {
                    id: profile_id(args[0])?,
                    uid: guest_uid(args[1])?,
                })
            }
            _ => Err(BadRequest::UnknownVerb),
        }
    }
}

fn profile_id(word: &str) -> Result<String, BadRequest> {
    if valid_profile_id(word) {
        Ok(word.to_owned())
    } else {
        Err(BadRequest::BadId)
    }
}

/// A guest uid: at most five decimal digits, no sign, in `GUEST_UIDS` (every uid there has five
/// digits, so a leading zero never fits).
fn guest_uid(word: &str) -> Result<u32, BadRequest> {
    let digits = !word.is_empty() && word.len() <= 5 && word.bytes().all(|b| b.is_ascii_digit());
    if !digits {
        return Err(BadRequest::BadUid);
    }
    match word.parse::<u32>() {
        Ok(uid) if GUEST_UIDS.contains(&uid) => Ok(uid),
        _ => Err(BadRequest::BadUid),
    }
}

/// Why a request was not done.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Code {
    /// The peer is not the `ruya-profiles` user; the request was not read.
    NotAllowed,
    /// The line is not the grammar.
    BadRequest,
    /// `delete` or `remove-guest` named a user without the profile marker it needs.
    NotAProfileUser,
    /// The command failed or the user database could not be asked.
    Failed,
}

impl Code {
    pub fn as_str(self) -> &'static str {
        match self {
            Code::NotAllowed => "not-allowed",
            Code::BadRequest => "bad-request",
            Code::NotAProfileUser => "not-a-profile-user",
            Code::Failed => "failed",
        }
    }

    fn parse(s: &str) -> Option<Code> {
        [
            Code::NotAllowed,
            Code::BadRequest,
            Code::NotAProfileUser,
            Code::Failed,
        ]
        .into_iter()
        .find(|c| c.as_str() == s)
    }
}

/// The helper's answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reply {
    Ok,
    Error(Code),
}

impl Reply {
    pub fn encode(self) -> Vec<u8> {
        match self {
            Reply::Ok => b"ok\n".to_vec(),
            Reply::Error(code) => format!("error {}\n", code.as_str()).into_bytes(),
        }
    }

    /// Reads a reply; anything else (an empty read when the helper died, a cut line) is `None`.
    pub fn decode(bytes: &[u8]) -> Option<Reply> {
        let text = std::str::from_utf8(bytes.strip_suffix(b"\n")?).ok()?;
        if text == "ok" {
            return Some(Reply::Ok);
        }
        Code::parse(text.strip_prefix("error ")?).map(Reply::Error)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create(id: &str, kind: AccountKind) -> Request {
        Request::Create {
            id: id.into(),
            kind,
        }
    }

    #[test]
    fn every_request_reads_back_as_itself() {
        let longest_id = "a".repeat(32);
        for request in [
            create("p3", AccountKind::Regular),
            create("p7", AccountKind::Guest { uid: 50000 }),
            create("p7", AccountKind::Guest { uid: 59999 }),
            Request::Delete { id: "p3".into() },
            Request::RemoveGuest {
                id: longest_id.clone(),
                uid: 59999,
            },
            create(&longest_id, AccountKind::Guest { uid: 59999 }),
        ] {
            let bytes = request.encode();
            assert!(bytes.len() <= MAX_REQUEST, "{}", request.line());
            assert_eq!(Request::parse(&bytes), Ok(request));
        }
        assert_eq!(
            Request::parse(b"create p3 regular\n"),
            Ok(create("p3", AccountKind::Regular))
        );
        assert_eq!(
            Request::parse(b"remove-guest p9 50012\n"),
            Ok(Request::RemoveGuest {
                id: "p9".into(),
                uid: 50012
            })
        );
    }

    /// The hostile-input table: each line is refused, and for its own rule.
    #[test]
    fn every_other_line_is_refused_for_its_rule() {
        let long = format!("delete {}\n", "a".repeat(MAX_REQUEST));
        let cases: &[(&[u8], BadRequest)] = &[
            (long.as_bytes(), BadRequest::TooLong),
            // One line, ending in a newline.
            (b"delete p3", BadRequest::NotOneLine),
            (b"", BadRequest::NotOneLine),
            (b"delete p3\ndelete p4\n", BadRequest::NotOneLine),
            (b"delete p3\n\n", BadRequest::NotOneLine),
            (b"delete p3\r\n", BadRequest::NotText),
            // Printable ASCII and spaces only.
            (b"delete\tp3\n", BadRequest::NotText),
            (b"delete p3\0\n", BadRequest::NotText),
            (b"delete p\xc3\xa9\n", BadRequest::NotText),
            (b"delete \x1b[2Jp3\n", BadRequest::NotText),
            // Single-spaced words.
            (b"delete  p3\n", BadRequest::Spacing),
            (b" delete p3\n", BadRequest::Spacing),
            (b"delete p3 \n", BadRequest::Spacing),
            (b"\n", BadRequest::Spacing),
            // The verbs, exactly.
            (b"Delete p3\n", BadRequest::UnknownVerb),
            (b"userdel p3\n", BadRequest::UnknownVerb),
            (b"--remove p3\n", BadRequest::UnknownVerb),
            (b"remove p3\n", BadRequest::UnknownVerb),
            // A profile id, never a path or a user name of another shape.
            (b"delete ../../etc\n", BadRequest::BadId),
            (b"delete /root\n", BadRequest::BadId),
            (b"delete p3.bak\n", BadRequest::BadId),
            (b"delete ruya:p3\n", BadRequest::BadId),
            (
                b"delete aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
                BadRequest::BadId,
            ),
            (b"create ~p3 regular\n", BadRequest::BadId),
            (b"remove-guest p$3 50000\n", BadRequest::BadId),
            // The kinds.
            (b"create p3 admin\n", BadRequest::BadKind),
            (b"create p3 Regular\n", BadRequest::BadKind),
            (b"create p3 --uid=0\n", BadRequest::BadKind),
            // Guest uids: decimal, no sign or leading zero, in the guest range.
            (b"create p3 guest 0\n", BadRequest::BadUid),
            (b"create p3 guest 1000\n", BadRequest::BadUid),
            (b"create p3 guest 49999\n", BadRequest::BadUid),
            (b"create p3 guest 60000\n", BadRequest::BadUid),
            (b"create p3 guest 050000\n", BadRequest::BadUid),
            (b"create p3 guest +50000\n", BadRequest::BadUid),
            (b"create p3 guest 5e4\n", BadRequest::BadUid),
            (b"remove-guest p3 4294967296\n", BadRequest::BadUid),
            (b"remove-guest p3 -1\n", BadRequest::BadUid),
            // Arity.
            (b"delete\n", BadRequest::MissingArgument),
            (b"create p3\n", BadRequest::MissingArgument),
            (b"create p3 guest\n", BadRequest::MissingArgument),
            (b"remove-guest p3\n", BadRequest::MissingArgument),
            (b"delete p3 p4\n", BadRequest::ExtraArgument),
            (b"delete p3 --force\n", BadRequest::ExtraArgument),
            (b"create p3 regular 50000\n", BadRequest::ExtraArgument),
            (
                b"create p3 guest 50000 --non-unique\n",
                BadRequest::ExtraArgument,
            ),
            (b"remove-guest p3 50000 x\n", BadRequest::ExtraArgument),
        ];
        for (line, want) in cases {
            assert_eq!(
                Request::parse(line),
                Err(*want),
                "{:?}",
                String::from_utf8_lossy(line)
            );
        }
    }

    #[test]
    fn replies_read_back_and_nothing_else_does() {
        for reply in [
            Reply::Ok,
            Reply::Error(Code::NotAllowed),
            Reply::Error(Code::BadRequest),
            Reply::Error(Code::NotAProfileUser),
            Reply::Error(Code::Failed),
        ] {
            let bytes = reply.encode();
            assert!(bytes.len() <= MAX_REPLY);
            assert_eq!(Reply::decode(&bytes), Some(reply));
        }
        for bad in [
            &b""[..],
            b"ok",
            b"OK\n",
            b"error\n",
            b"error nope\n",
            b"ok\nok\n",
        ] {
            assert_eq!(
                Reply::decode(bad),
                None,
                "{:?}",
                String::from_utf8_lossy(bad)
            );
        }
    }
}
