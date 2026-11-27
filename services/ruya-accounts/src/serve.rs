//! The helper's steps for one accepted connection, over injected calls ([`Connection`] for the
//! socket, [`System`] for the user database and the commands), so every step is tested on any
//! host; `main.rs` has the Linux implementations.
//!
//! 1. The peer must be the `ruya-profiles` user (`SO_PEERCRED`); otherwise the answer is
//!    `not-allowed` and nothing else happens: the request is not even received. Root is refused
//!    too: it has no need of the helper.
//! 2. One request line of the grammar (`wire`), else `bad-request`.
//! 3. `create`: `useradd` with the arguments of `account::useradd_args`.
//!    `delete` and `remove-guest`: the user `ruya-<id>` is looked up; none is nothing to do
//!    (`ok`), one without the marker the request needs is `not-a-profile-user` and is never
//!    touched, else its sessions end and `userdel --remove` runs.
//! 4. One reply line; the journal line names the request and the answer.

use std::io;

use ruya_ids::user_of;
use ruya_users::Passwd;

use crate::account::{classify, useradd_args, AccountKind, UserEntry};
use crate::wire::{BadRequest, Code, Reply, Request, MAX_REQUEST};

/// One request as the socket gave it.
#[derive(Debug, Default)]
pub struct Received {
    pub data: Vec<u8>,
    /// The kernel cut the message short (it was longer than the buffer).
    pub truncated: bool,
}

/// The accepted connection (the socket unit's `StandardInput=socket`).
pub trait Connection {
    /// The peer's uid (`SO_PEERCRED`), `None` when it cannot be read.
    fn peer_uid(&self) -> Option<u32>;
    /// One message of at most `MAX_REQUEST + 1` bytes.
    fn receive(&mut self) -> io::Result<Received>;
    /// Sends one message; the number of bytes the kernel took.
    fn send(&mut self, reply: &[u8]) -> io::Result<usize>;
}

/// The user database and the account commands.
pub trait System {
    /// The uid of the `ruya-profiles` user, `None` when there is none.
    fn peer_user_uid(&self) -> Option<u32>;
    /// The passwd record of `user`; `Err` (the errno) when the database could not be asked.
    fn lookup(&self, user: &str) -> Result<Option<Passwd>, i32>;
    /// Runs `useradd` with these arguments.
    fn useradd(&self, args: &[String]) -> io::Result<()>;
    /// Ends the user's sessions and linger, then `userdel --remove` (a user that is already gone
    /// is not an error).
    fn delete_user(&self, user: &str) -> io::Result<()>;
}

/// What one connection came to: the request (when one was read) and the reply sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Served {
    pub request: Result<Request, Refused>,
    pub reply: Reply,
}

/// Why no request was carried out before it was even read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refused {
    /// The peer's uid (`None`: unreadable) is not the `ruya-profiles` user's.
    Peer(Option<u32>),
    Bad(BadRequest),
}

/// Step 3 for a request that passed steps 1 and 2.
pub fn answer(system: &impl System, request: &Request) -> Reply {
    match request {
        Request::Create { id, kind } => match system.useradd(&useradd_args(id, *kind)) {
            Ok(()) => Reply::Ok,
            Err(err) => {
                eprintln!("ruya-accounts: useradd {}: {err}", user_of(id));
                Reply::Error(Code::Failed)
            }
        },
        Request::Delete { id } => remove(system, id, AccountKind::Regular),
        Request::RemoveGuest { id, uid } => remove(system, id, AccountKind::Guest { uid: *uid }),
    }
}

fn remove(system: &impl System, id: &str, kind: AccountKind) -> Reply {
    let user = user_of(id);
    let entry = match system.lookup(&user) {
        Ok(entry) => entry,
        Err(errno) => {
            eprintln!("ruya-accounts: looking up {user} failed (errno {errno})");
            return Reply::Error(Code::Failed);
        }
    };
    match classify(entry.as_ref(), id, kind) {
        UserEntry::Missing => Reply::Ok,
        UserEntry::NotOurs => Reply::Error(Code::NotAProfileUser),
        UserEntry::Ours => match system.delete_user(&user) {
            Ok(()) => Reply::Ok,
            Err(err) => {
                eprintln!("ruya-accounts: removing {user}: {err}");
                Reply::Error(Code::Failed)
            }
        },
    }
}

/// Steps 1 and 2: the request of an allowed peer, or why there is none.
pub fn read_request(
    conn: &mut impl Connection,
    system: &impl System,
) -> io::Result<Result<Request, Refused>> {
    let peer = conn.peer_uid();
    if peer.is_none() || peer != system.peer_user_uid() {
        return Ok(Err(Refused::Peer(peer)));
    }
    let received = conn.receive()?;
    if received.truncated || received.data.len() > MAX_REQUEST {
        return Ok(Err(Refused::Bad(BadRequest::TooLong)));
    }
    Ok(Request::parse(&received.data).map_err(Refused::Bad))
}

/// One connection, all steps; what happened is returned (for the journal line).
pub fn serve(conn: &mut impl Connection, system: &impl System) -> io::Result<Served> {
    let request = read_request(conn, system)?;
    let reply = match &request {
        Ok(request) => answer(system, request),
        Err(Refused::Peer(_)) => Reply::Error(Code::NotAllowed),
        Err(Refused::Bad(_)) => Reply::Error(Code::BadRequest),
    };
    let bytes = reply.encode();
    if conn.send(&bytes)? != bytes.len() {
        return Err(io::Error::new(
            io::ErrorKind::WriteZero,
            "the reply was cut",
        ));
    }
    Ok(Served { request, reply })
}

/// The journal line of a connection: the request line (ids and uids only) and the answer.
pub fn describe(served: &Served) -> String {
    let answer = match served.reply {
        Reply::Ok => "ok".to_owned(),
        Reply::Error(code) => code.as_str().to_owned(),
    };
    match &served.request {
        Ok(request) => format!("{}: {answer}", request.line()),
        Err(Refused::Peer(Some(uid))) => format!("refused the peer uid {uid}: {answer}"),
        Err(Refused::Peer(None)) => format!("refused a peer without credentials: {answer}"),
        Err(Refused::Bad(why)) => format!("refused a request ({}): {answer}", why.as_str()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account::{GUEST_COMMENT, PROFILE_COMMENT};
    use std::cell::RefCell;

    const PROFILES_UID: u32 = 977;

    struct Fake {
        peer: Option<u32>,
        data: Vec<u8>,
        truncated: bool,
        received: bool,
        sent: Vec<u8>,
        /// How many bytes short of the reply the send falls.
        cut: usize,
    }

    impl Fake {
        fn new(peer: Option<u32>, data: &[u8]) -> Fake {
            Fake {
                peer,
                data: data.to_vec(),
                truncated: false,
                received: false,
                sent: Vec::new(),
                cut: 0,
            }
        }
    }

    impl Connection for Fake {
        fn peer_uid(&self) -> Option<u32> {
            self.peer
        }
        fn receive(&mut self) -> io::Result<Received> {
            self.received = true;
            Ok(Received {
                data: self.data.clone(),
                truncated: self.truncated,
            })
        }
        fn send(&mut self, reply: &[u8]) -> io::Result<usize> {
            self.sent = reply.to_vec();
            Ok(reply.len() - self.cut)
        }
    }

    /// The system: its users, and every command it was asked to run.
    #[derive(Default)]
    struct Users {
        users: Vec<Passwd>,
        lookup_fails: bool,
        command_fails: bool,
        ran: RefCell<Vec<String>>,
    }

    impl Users {
        fn with(users: Vec<Passwd>) -> Users {
            Users {
                users,
                ..Users::default()
            }
        }
    }

    impl System for Users {
        fn peer_user_uid(&self) -> Option<u32> {
            Some(PROFILES_UID)
        }
        fn lookup(&self, user: &str) -> Result<Option<Passwd>, i32> {
            if self.lookup_fails {
                return Err(5);
            }
            Ok(self.users.iter().find(|u| u.name == user).cloned())
        }
        fn useradd(&self, args: &[String]) -> io::Result<()> {
            self.ran
                .borrow_mut()
                .push(format!("useradd {}", args.join(" ")));
            if self.command_fails {
                return Err(io::Error::other("exit 9"));
            }
            Ok(())
        }
        fn delete_user(&self, user: &str) -> io::Result<()> {
            self.ran.borrow_mut().push(format!("userdel {user}"));
            if self.command_fails {
                return Err(io::Error::other("exit 1"));
            }
            Ok(())
        }
    }

    fn passwd(name: &str, uid: u32, gecos: &str) -> Passwd {
        Passwd {
            name: name.into(),
            uid,
            gid: uid,
            gecos: gecos.into(),
            home: format!("/var/home/{name}"),
        }
    }

    fn run(peer: Option<u32>, line: &[u8], system: &Users) -> (Served, Fake) {
        let mut conn = Fake::new(peer, line);
        let served = serve(&mut conn, system).unwrap();
        (served, conn)
    }

    #[test]
    fn only_the_profiles_user_is_answered_and_its_request_not_even_read() {
        let system = Users::default();
        for peer in [Some(0), Some(1001), Some(PROFILES_UID + 1), None] {
            let (served, conn) = run(peer, b"create p3 regular\n", &system);
            assert_eq!(served.reply, Reply::Error(Code::NotAllowed), "{peer:?}");
            assert_eq!(served.request, Err(Refused::Peer(peer)));
            assert!(!conn.received, "the request of {peer:?} was read");
            assert_eq!(conn.sent, b"error not-allowed\n");
        }
        assert!(system.ran.borrow().is_empty());
    }

    #[test]
    fn without_a_profiles_user_nobody_is_answered() {
        struct NoPeerUser;
        impl System for NoPeerUser {
            fn peer_user_uid(&self) -> Option<u32> {
                None
            }
            fn lookup(&self, _: &str) -> Result<Option<Passwd>, i32> {
                Ok(None)
            }
            fn useradd(&self, _: &[String]) -> io::Result<()> {
                panic!("useradd ran")
            }
            fn delete_user(&self, _: &str) -> io::Result<()> {
                panic!("userdel ran")
            }
        }
        let mut conn = Fake::new(None, b"create p3 regular\n");
        let served = serve(&mut conn, &NoPeerUser).unwrap();
        assert_eq!(served.reply, Reply::Error(Code::NotAllowed));
    }

    #[test]
    fn a_bad_line_runs_nothing() {
        let system = Users::with(vec![passwd("ruya-p3", 1003, PROFILE_COMMENT)]);
        for line in [
            &b"delete ../p3\n"[..],
            b"delete p3 --force\n",
            b"userdel p3\n",
        ] {
            let (served, conn) = run(Some(PROFILES_UID), line, &system);
            assert_eq!(served.reply, Reply::Error(Code::BadRequest));
            assert_eq!(conn.sent, b"error bad-request\n");
        }
        let mut conn = Fake::new(Some(PROFILES_UID), b"delete p3\n");
        conn.truncated = true;
        let served = serve(&mut conn, &system).unwrap();
        assert_eq!(served.request, Err(Refused::Bad(BadRequest::TooLong)));
        assert!(system.ran.borrow().is_empty());
    }

    #[test]
    fn create_runs_useradd_with_the_profile_arguments() {
        let system = Users::default();
        let (served, conn) = run(Some(PROFILES_UID), b"create p7 guest 50004\n", &system);
        assert_eq!(served.reply, Reply::Ok);
        assert_eq!(conn.sent, b"ok\n");
        let ran = system.ran.borrow();
        assert_eq!(ran.len(), 1);
        assert!(ran[0].contains("--uid 50004"), "{}", ran[0]);
        assert!(ran[0].ends_with(" ruya-p7"), "{}", ran[0]);
        assert_eq!(describe(&served), "create p7 guest 50004: ok");
    }

    #[test]
    fn a_failed_command_is_failed() {
        let system = Users {
            command_fails: true,
            ..Users::with(vec![passwd("ruya-p3", 1003, PROFILE_COMMENT)])
        };
        for line in [&b"create p4 regular\n"[..], b"delete p3\n"] {
            let (served, _) = run(Some(PROFILES_UID), line, &system);
            assert_eq!(served.reply, Reply::Error(Code::Failed));
        }
        let system = Users {
            lookup_fails: true,
            ..Users::default()
        };
        let (served, _) = run(Some(PROFILES_UID), b"delete p3\n", &system);
        assert_eq!(served.reply, Reply::Error(Code::Failed));
        assert!(system.ran.borrow().is_empty());
    }

    #[test]
    fn delete_removes_only_a_marked_profile_user() {
        let system = Users::with(vec![
            passwd("ruya-p3", 1003, PROFILE_COMMENT),
            passwd("ruya-p7", 50004, GUEST_COMMENT),
            Passwd {
                home: "/var/lib/ruya-shell".into(),
                ..passwd("ruya-shell", 989, "RuyaOS shell")
            },
        ]);
        let (served, _) = run(Some(PROFILES_UID), b"delete p3\n", &system);
        assert_eq!(served.reply, Reply::Ok);
        // The shell's user, a guest through delete, a regular user through remove-guest, a
        // guest with another uid: never touched.
        for line in [
            &b"delete shell\n"[..],
            b"delete p7\n",
            b"remove-guest p3 50003\n",
            b"remove-guest p7 50005\n",
        ] {
            let (served, conn) = run(Some(PROFILES_UID), line, &system);
            assert_eq!(
                served.reply,
                Reply::Error(Code::NotAProfileUser),
                "{}",
                String::from_utf8_lossy(line)
            );
            assert_eq!(conn.sent, b"error not-a-profile-user\n");
        }
        let (served, _) = run(Some(PROFILES_UID), b"remove-guest p7 50004\n", &system);
        assert_eq!(served.reply, Reply::Ok);
        assert_eq!(*system.ran.borrow(), ["userdel ruya-p3", "userdel ruya-p7"]);
        // A user that is gone already: nothing to do.
        let (served, _) = run(Some(PROFILES_UID), b"delete p9\n", &system);
        assert_eq!(served.reply, Reply::Ok);
        assert_eq!(system.ran.borrow().len(), 2);
    }

    #[test]
    fn a_cut_reply_fails_the_connection() {
        let mut conn = Fake::new(Some(PROFILES_UID), b"delete p9\n");
        conn.cut = 1;
        let err = serve(&mut conn, &Users::default()).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::WriteZero);
    }

    #[test]
    fn the_journal_line_says_what_was_refused() {
        let system = Users::default();
        let (served, _) = run(Some(0), b"delete p3\n", &system);
        assert_eq!(describe(&served), "refused the peer uid 0: not-allowed");
        let (served, _) = run(Some(PROFILES_UID), b"delete /etc\n", &system);
        assert_eq!(
            describe(&served),
            "refused a request (not a profile id): bad-request"
        );
    }
}
