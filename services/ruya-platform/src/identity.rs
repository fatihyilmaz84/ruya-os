//! Who is calling: the Flatpak app, its instance and its profile, from the connection alone
//! (ADR-022; the recipe RUY-157 step 1 proved on the VM). Never from an argument.
//!
//! The bus gives the caller's credentials (`GetConnectionCredentials`: `ProcessFD`, a pidfd of the
//! peer, `ProcessID` and `UnixUserID`). Behind `xdg-dbus-proxy` the peer is the proxy, which runs
//! in the app's sandbox and scope, so it carries the app's identity. The recipe:
//!
//! 1. the pidfd is alive and names `ProcessID` (the door's own fdinfo `Pid:`; a process that is
//!    gone shows `-1`, so a reused pid is seen);
//! 2. the identity helper (`ruya-platform-identify`, ADR-022 decision 4: the door holds no
//!    capability) answers with the pid its own fdinfo of the pidfd names, which must be
//!    `ProcessID`, the caller's `/proc/<pid>/root/.flatpak-info` (only when `UnixUserID` owns it)
//!    and `/proc/<pid>/cgroup`;
//! 3. the `.flatpak-info` names the app (`[Application] name`) and the instance
//!    (`[Instance] instance-id`);
//! 4. the cgroup ends exactly in that instance's scope
//!    (`app-flatpak-<escaped id>-<instance-id>.scope`) under `user@<UnixUserID>.service`;
//! 5. the pidfd still names `ProcessID` after the reads (the files were the caller's);
//! 6. `UnixUserID` is a profile's user (`ruya-<id>`) whose profile exists.
//!
//! Anything else is `NotAnApp`. **Trust boundary:** this holds for sandboxed callers only. Code
//! running unsandboxed as the profile's uid can make a matching scope and a fake `.flatpak-info`
//! (shown in the spike), so nothing third-party may run unsandboxed as a profile. Such code can
//! also bind-mount any file it can see onto `/.flatpak-info`; the helper reads none the caller's
//! uid does not own.
//!
//! The reads go through [`Procfs`] and the user database through [`Users`], so the whole recipe is
//! tested with fakes; `procfs.rs` has the Linux readers.

use std::fmt;
use std::io;

use ruya_flatpak::scope::{instance_scope, runs_in_scope, valid_instance_id};
use ruya_flatpak::valid_app_id;
use ruya_ids::profile_of_user;
use ruya_keyfile::Keyfile;
pub use ruya_platform_identify::{FileError, Files, Refusal, Reply};

/// What the bus said about the caller of one message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Caller<'a> {
    /// The unique bus name (`:1.42`) the message came from.
    pub name: &'a str,
    pub uid: Option<u32>,
    pub pid: Option<u32>,
    /// The `ProcessFD` of the credentials, as a descriptor number of this process; the caller of
    /// [`identify`] keeps it open until it returns.
    pub pidfd: Option<i32>,
}

/// The kernel reads of the recipe.
pub trait Procfs: Send {
    /// The `Pid:` of this process's fdinfo of the pidfd: the process's pid, `-1` once it is gone;
    /// `None` when the descriptor is no pidfd or cannot be read. Needs no privilege.
    fn pidfd_pid(&self, pidfd: i32) -> Option<i32>;
    /// The identity helper's answer for the caller the pidfd names, whose bus uid is `uid`: the
    /// pid the helper saw and the caller's `.flatpak-info` and cgroup, or why not. `Err` when the
    /// helper could not be asked or its reply is not on the wire's grammar.
    fn caller_files(&self, pidfd: i32, uid: u32) -> io::Result<Reply>;
}

/// The system's user database.
pub trait Users: Send {
    /// The name of the user `uid`, `None` when there is none.
    fn name_of(&self, uid: u32) -> Option<String>;
}

/// A caller the door serves: one instance of one app, of one profile.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Identity {
    pub app_id: String,
    pub instance_id: String,
    /// The instance's scope unit, `app-flatpak-<escaped app_id>-<instance_id>.scope`.
    pub scope: String,
    pub uid: u32,
    pub profile: String,
}

/// Why a caller is not taken for an app (the reply is always `not-an-app`; this is for the log
/// and the tests).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotAnApp {
    /// The bus gave no pidfd, pid or uid (an old bus, or a peer of another kind).
    NoCredentials,
    /// The pidfd does not name the pid: the process is gone, or the pid is another process's.
    ProcessGone,
    /// The identity helper could not be asked, or its reply was malformed.
    HelperUnavailable,
    /// The identity helper refused the request.
    HelperRefused(Refusal),
    /// No `.flatpak-info` is there: not a sandbox.
    NoFlatpakInfo,
    /// A `.flatpak-info` is there but was not read: the caller's uid does not own it (a file
    /// bind-mounted there), it is no regular file or too large, or the read was refused. Kept
    /// apart from a missing file, so a permission problem is not taken for an unsandboxed caller.
    FlatpakInfoUnreadable(FileError),
    /// `.flatpak-info` names no valid app id or instance id.
    BadFlatpakInfo,
    /// The cgroup is not that instance's scope in the uid's own user manager.
    WrongScope,
    /// The helper saw another pid, or the pidfd no longer names the pid after the reads.
    ProcessChanged,
    /// The uid is no profile's user, or the profile does not exist.
    NotAProfile,
}

impl fmt::Display for NotAnApp {
    /// The journal's words (vm-platform-check.sh looks for `flatpak-info not-owned`).
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            NotAnApp::NoCredentials => f.write_str("no credentials"),
            NotAnApp::ProcessGone => f.write_str("process gone"),
            NotAnApp::HelperUnavailable => f.write_str("identity helper unavailable"),
            NotAnApp::HelperRefused(r) => write!(f, "identity helper refused: {}", r.as_str()),
            NotAnApp::NoFlatpakInfo => f.write_str("no flatpak-info"),
            NotAnApp::FlatpakInfoUnreadable(e) => write!(f, "flatpak-info {}", e.as_str()),
            NotAnApp::BadFlatpakInfo => f.write_str("bad flatpak-info"),
            NotAnApp::WrongScope => f.write_str("wrong scope"),
            NotAnApp::ProcessChanged => f.write_str("process changed"),
            NotAnApp::NotAProfile => f.write_str("not a profile"),
        }
    }
}

/// The app id and instance id of a `.flatpak-info`, or `None` (GKeyFile's own reading, as
/// `flatpak run` writes it; the app id must be valid and the instance id digits).
pub fn parse_flatpak_info(bytes: &[u8]) -> Option<(String, String)> {
    let text = std::str::from_utf8(bytes).ok()?;
    let info = Keyfile::parse_lenient(text).ok()?;
    let app = info.get("Application", "name")?;
    let instance = info.get("Instance", "instance-id")?;
    (valid_app_id(app) && valid_instance_id(instance))
        .then(|| (app.to_owned(), instance.to_owned()))
}

/// The recipe (module doc). `is_profile` says whether a profile id exists now (Profiles1).
pub fn identify(
    procfs: &dyn Procfs,
    users: &dyn Users,
    caller: &Caller<'_>,
    is_profile: impl Fn(&str) -> bool,
) -> Result<Identity, NotAnApp> {
    let (Some(uid), Some(pid), Some(pidfd)) = (caller.uid, caller.pid, caller.pidfd) else {
        return Err(NotAnApp::NoCredentials);
    };
    let Ok(want) = i32::try_from(pid) else {
        return Err(NotAnApp::ProcessGone);
    };
    if want <= 0 || procfs.pidfd_pid(pidfd) != Some(want) {
        return Err(NotAnApp::ProcessGone);
    }
    let files = match procfs.caller_files(pidfd, uid) {
        Err(_) => return Err(NotAnApp::HelperUnavailable),
        Ok(Reply::Refused(Refusal::ProcessGone)) => return Err(NotAnApp::ProcessGone),
        Ok(Reply::Refused(r)) => return Err(NotAnApp::HelperRefused(r)),
        Ok(Reply::Files(files)) => files,
    };
    if files.pid != pid {
        return Err(NotAnApp::ProcessChanged);
    }
    let info = files.info.map_err(|e| match e {
        FileError::Missing => NotAnApp::NoFlatpakInfo,
        e => NotAnApp::FlatpakInfoUnreadable(e),
    })?;
    let (app_id, instance_id) = parse_flatpak_info(&info).ok_or(NotAnApp::BadFlatpakInfo)?;
    let scope = instance_scope(&app_id, &instance_id).ok_or(NotAnApp::BadFlatpakInfo)?;
    let cgroup = files.cgroup.map_err(|_| NotAnApp::WrongScope)?;
    let cgroup = std::str::from_utf8(&cgroup).map_err(|_| NotAnApp::WrongScope)?;
    if !runs_in_scope(cgroup, uid, &scope) {
        return Err(NotAnApp::WrongScope);
    }
    if procfs.pidfd_pid(pidfd) != Some(want) {
        return Err(NotAnApp::ProcessChanged);
    }
    let user = users.name_of(uid).ok_or(NotAnApp::NotAProfile)?;
    let profile = profile_of_user(&user)
        .filter(|p| is_profile(p))
        .ok_or(NotAnApp::NotAProfile)?;
    Ok(Identity {
        app_id,
        instance_id,
        scope,
        uid,
        profile: profile.to_owned(),
    })
}

/// Fakes of the recipe's reads, for this crate's tests.
#[cfg(test)]
pub(crate) mod fake {
    use super::{FileError, Procfs, Reply, Users};
    use ruya_platform_identify::serve::{files_of, InMemory, Kernel};
    use std::collections::{HashMap, VecDeque};
    use std::io;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Mutex;

    /// One process as the fake helper answers for it.
    #[derive(Debug, Clone)]
    pub struct Process {
        /// The owner of its `.flatpak-info` (the profile user in a real sandbox).
        pub owner: u32,
        pub info: Result<Vec<u8>, FileError>,
        pub cgroup: Result<Vec<u8>, FileError>,
    }

    /// Pidfds and processes set by the test; a pidfd answers its queued pids one look at a time,
    /// then its last one for ever. The recipe looks three times: the door, the helper (its own
    /// copy of the pidfd), the door's re-check.
    #[derive(Debug, Default)]
    pub struct FakeProcfs {
        pub pidfds: Mutex<HashMap<i32, VecDeque<i32>>>,
        pub processes: HashMap<u32, Process>,
        /// The helper cannot be asked (not running, or a reply off the wire's grammar).
        pub helper_down: bool,
        reads: AtomicU32,
    }

    impl FakeProcfs {
        /// A pidfd `fd` that names `pid` on every read.
        pub fn pidfd(&self, fd: i32, pids: &[i32]) {
            self.pidfds
                .lock()
                .expect("not poisoned")
                .insert(fd, pids.iter().copied().collect());
        }

        /// How many times the helper was asked for the caller's files.
        pub fn reads(&self) -> u32 {
            self.reads.load(Ordering::Relaxed)
        }

        fn count(&self) {
            self.reads.fetch_add(1, Ordering::Relaxed);
        }
    }

    impl Procfs for FakeProcfs {
        fn pidfd_pid(&self, pidfd: i32) -> Option<i32> {
            let mut fds = self.pidfds.lock().expect("not poisoned");
            let queue = fds.get_mut(&pidfd)?;
            if queue.len() > 1 {
                queue.pop_front()
            } else {
                queue.front().copied()
            }
        }

        /// The helper's own rules (`serve::files_of`) on this fake kernel.
        fn caller_files(&self, pidfd: i32, uid: u32) -> io::Result<Reply> {
            self.count();
            if self.helper_down {
                return Err(io::ErrorKind::ConnectionRefused.into());
            }
            Ok(files_of(self, pidfd, uid))
        }
    }

    /// The fake kernel the helper's rules look at: the pidfd's next look (shared with the
    /// door's), the processes' files.
    impl Kernel for FakeProcfs {
        type File = InMemory;
        fn pidfd_pid(&self, fd: i32) -> Option<i32> {
            Procfs::pidfd_pid(self, fd)
        }
        fn open_info(&self, pid: u32) -> Result<InMemory, FileError> {
            let p = self.processes.get(&pid).ok_or(FileError::Missing)?;
            Ok(InMemory::new(p.owner, p.info.clone()?))
        }
        fn open_cgroup(&self, pid: u32) -> Result<InMemory, FileError> {
            let p = self.processes.get(&pid).ok_or(FileError::Missing)?;
            Ok(InMemory::new(p.owner, p.cgroup.clone()?))
        }
    }

    /// uid -> user name.
    #[derive(Debug, Default)]
    pub struct FakeUsers(pub HashMap<u32, String>);

    impl Users for FakeUsers {
        fn name_of(&self, uid: u32) -> Option<String> {
            self.0.get(&uid).cloned()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fake::{FakeProcfs, FakeUsers, Process};
    use super::*;

    const APP: &str = "org.example.Racer";
    const UID: u32 = 1001;
    const PID: u32 = 4242;
    const FD: i32 = 7;

    fn info(app: &str, instance: &str) -> Vec<u8> {
        format!("[Application]\nname={app}\nruntime=runtime/org.freedesktop.Platform/x86_64/24.08\n\n[Instance]\ninstance-id={instance}\napp-path=/var/lib/flatpak/app/{app}\n").into_bytes()
    }

    fn cgroup(uid: u32, app: &str, instance: &str) -> Vec<u8> {
        let scope = instance_scope(app, instance).expect("valid");
        format!("0::/user.slice/user-{uid}.slice/user@{uid}.service/app.slice/{scope}\n")
            .into_bytes()
    }

    /// A proxied caller of `APP` instance 77 as `ruya-p1` (uid 1001), every read as the recipe wants.
    fn world() -> (FakeProcfs, FakeUsers) {
        let mut procfs = FakeProcfs::default();
        procfs.pidfd(FD, &[PID as i32]);
        procfs.processes.insert(
            PID,
            Process {
                owner: UID,
                info: Ok(info(APP, "77")),
                cgroup: Ok(cgroup(UID, APP, "77")),
            },
        );
        let mut users = FakeUsers::default();
        users.0.insert(UID, "ruya-p1".into());
        users.0.insert(1002, "ruya-p2".into());
        users.0.insert(990, "ruya-shell".into());
        (procfs, users)
    }

    fn caller() -> Caller<'static> {
        Caller {
            name: ":1.42",
            uid: Some(UID),
            pid: Some(PID),
            pidfd: Some(FD),
        }
    }

    fn profiles(id: &str) -> bool {
        id == "p1" || id == "p2"
    }

    fn run(
        procfs: &FakeProcfs,
        users: &FakeUsers,
        caller: &Caller<'_>,
    ) -> Result<Identity, NotAnApp> {
        identify(procfs, users, caller, profiles)
    }

    #[test]
    fn a_sandboxed_caller_is_its_app_instance_and_profile() {
        let (procfs, users) = world();
        assert_eq!(
            run(&procfs, &users, &caller()),
            Ok(Identity {
                app_id: APP.into(),
                instance_id: "77".into(),
                scope: "app-flatpak-org.example.Racer-77.scope".into(),
                uid: UID,
                profile: "p1".into(),
            })
        );
    }

    #[test]
    fn every_credential_is_needed() {
        let (procfs, users) = world();
        for c in [
            Caller {
                uid: None,
                ..caller()
            },
            Caller {
                pid: None,
                ..caller()
            },
            Caller {
                pidfd: None,
                ..caller()
            },
        ] {
            assert_eq!(
                run(&procfs, &users, &c),
                Err(NotAnApp::NoCredentials),
                "{c:?}"
            );
        }
        assert_eq!(procfs.reads(), 0, "nothing is read without them");
    }

    #[test]
    fn a_dead_pidfd_is_refused_before_any_read() {
        let (procfs, users) = world();
        procfs.pidfd(FD, &[-1]);
        assert_eq!(run(&procfs, &users, &caller()), Err(NotAnApp::ProcessGone));
        assert_eq!(procfs.reads(), 0);
        // A descriptor that is no pidfd at all.
        let c = Caller {
            pidfd: Some(99),
            ..caller()
        };
        assert_eq!(run(&procfs, &users, &c), Err(NotAnApp::ProcessGone));
    }

    #[test]
    fn a_reused_pid_is_refused() {
        let (procfs, users) = world();
        // The bus's ProcessID is now another process's pid: the pidfd names its own process.
        procfs.pidfd(FD, &[5151]);
        assert_eq!(run(&procfs, &users, &caller()), Err(NotAnApp::ProcessGone));
        assert_eq!(procfs.reads(), 0, "the helper is not asked");
        // The process died before the helper looked at its pidfd.
        procfs.pidfd(FD, &[PID as i32, -1]);
        assert_eq!(run(&procfs, &users, &caller()), Err(NotAnApp::ProcessGone));
        // The helper's own look names another process than the door's: its files are not used.
        procfs.pidfd(FD, &[PID as i32, 5151, PID as i32]);
        assert_eq!(
            run(&procfs, &users, &caller()),
            Err(NotAnApp::ProcessChanged)
        );
        // The process died and its pid was reused while the files were read: the re-check sees it.
        procfs.pidfd(FD, &[PID as i32, PID as i32, -1]);
        assert_eq!(
            run(&procfs, &users, &caller()),
            Err(NotAnApp::ProcessChanged)
        );
    }

    #[test]
    fn without_the_helper_nobody_is_an_app() {
        let (mut procfs, users) = world();
        procfs.helper_down = true;
        assert_eq!(
            run(&procfs, &users, &caller()),
            Err(NotAnApp::HelperUnavailable)
        );
        procfs.helper_down = false;
        assert!(
            run(&procfs, &users, &caller()).is_ok(),
            "the helper is back"
        );
    }

    #[test]
    fn a_helper_refusal_is_not_an_app() {
        struct Refusing(FakeProcfs, Refusal);
        impl Procfs for Refusing {
            fn pidfd_pid(&self, pidfd: i32) -> Option<i32> {
                self.0.pidfd_pid(pidfd)
            }
            fn caller_files(&self, _pidfd: i32, _uid: u32) -> io::Result<Reply> {
                Ok(Reply::Refused(self.1))
            }
        }
        for r in [Refusal::BadRequest, Refusal::NotRoot, Refusal::NotAPidfd] {
            let (procfs, users) = world();
            assert_eq!(
                identify(&Refusing(procfs, r), &users, &caller(), profiles),
                Err(NotAnApp::HelperRefused(r))
            );
        }
        let (procfs, users) = world();
        assert_eq!(
            identify(
                &Refusing(procfs, Refusal::ProcessGone),
                &users,
                &caller(),
                profiles
            ),
            Err(NotAnApp::ProcessGone)
        );
    }

    #[test]
    fn an_unsandboxed_caller_is_not_an_app() {
        let (mut procfs, users) = world();
        procfs.processes.get_mut(&PID).expect("set").info = Err(FileError::Missing);
        assert_eq!(
            run(&procfs, &users, &caller()),
            Err(NotAnApp::NoFlatpakInfo)
        );
    }

    #[test]
    fn an_unreadable_flatpak_info_is_not_a_missing_one() {
        for e in [
            FileError::NotOwned,
            FileError::Denied,
            FileError::NotRegular,
            FileError::TooLarge,
            FileError::Failed,
        ] {
            let (mut procfs, users) = world();
            procfs.processes.get_mut(&PID).expect("set").info = Err(e);
            assert_eq!(
                run(&procfs, &users, &caller()),
                Err(NotAnApp::FlatpakInfoUnreadable(e))
            );
        }
        // A file there that the caller's uid does not own (root's, bound there): the helper's
        // own rule refuses it, nothing is parsed.
        let (mut procfs, users) = world();
        procfs.processes.get_mut(&PID).expect("set").owner = 0;
        assert_eq!(
            run(&procfs, &users, &caller()),
            Err(NotAnApp::FlatpakInfoUnreadable(FileError::NotOwned))
        );
        // The journal says which (vm-platform-check.sh looks for the first).
        assert_eq!(
            NotAnApp::FlatpakInfoUnreadable(FileError::NotOwned).to_string(),
            "flatpak-info not-owned"
        );
        assert_eq!(
            NotAnApp::FlatpakInfoUnreadable(FileError::Denied).to_string(),
            "flatpak-info denied"
        );
        assert_eq!(NotAnApp::NoFlatpakInfo.to_string(), "no flatpak-info");
    }

    #[test]
    fn a_malformed_flatpak_info_is_refused() {
        for bad in [
            info("Racer", "77"),
            info(APP, "7x"),
            info(APP, ""),
            b"[Application]\nname=org.example.Racer\n".to_vec(),
            b"[Instance]\ninstance-id=77\n".to_vec(),
            b"not a keyfile".to_vec(),
            vec![0xff, 0xfe],
        ] {
            let (mut procfs, users) = world();
            procfs.processes.get_mut(&PID).expect("set").info = Ok(bad.clone());
            assert_eq!(
                run(&procfs, &users, &caller()),
                Err(NotAnApp::BadFlatpakInfo),
                "{}",
                String::from_utf8_lossy(&bad)
            );
        }
    }

    #[test]
    fn the_cgroup_must_be_that_apps_scope() {
        let (mut procfs, users) = world();
        procfs.processes.get_mut(&PID).expect("set").cgroup =
            Ok(cgroup(UID, "org.example.Other", "77"));
        assert_eq!(run(&procfs, &users, &caller()), Err(NotAnApp::WrongScope));
    }

    #[test]
    fn the_instance_id_must_match_the_scope() {
        let (mut procfs, users) = world();
        procfs.processes.get_mut(&PID).expect("set").cgroup = Ok(cgroup(UID, APP, "78"));
        assert_eq!(run(&procfs, &users, &caller()), Err(NotAnApp::WrongScope));
    }

    #[test]
    fn a_scope_in_another_uids_manager_is_refused() {
        let (mut procfs, users) = world();
        // The right scope name, but under user@1002: another profile's manager.
        procfs.processes.get_mut(&PID).expect("set").cgroup = Ok(cgroup(1002, APP, "77"));
        assert_eq!(run(&procfs, &users, &caller()), Err(NotAnApp::WrongScope));
        // Outside every user manager, or unreadable.
        procfs.processes.get_mut(&PID).expect("set").cgroup =
            Ok(b"0::/system.slice/app-flatpak-org.example.Racer-77.scope\n".to_vec());
        assert_eq!(run(&procfs, &users, &caller()), Err(NotAnApp::WrongScope));
        procfs.processes.get_mut(&PID).expect("set").cgroup = Err(FileError::Missing);
        assert_eq!(run(&procfs, &users, &caller()), Err(NotAnApp::WrongScope));
    }

    #[test]
    fn a_uid_that_is_no_profile_is_refused() {
        let (mut procfs, users) = world();
        for (uid, why) in [
            (990, "ruya-shell"),
            (0, "root, no user entry here"),
            (1003, "no user"),
        ] {
            let p = procfs.processes.get_mut(&PID).expect("set");
            p.cgroup = Ok(cgroup(uid, APP, "77"));
            p.owner = uid;
            let c = Caller {
                uid: Some(uid),
                ..caller()
            };
            assert_eq!(
                run(&procfs, &users, &c),
                Err(NotAnApp::NotAProfile),
                "{why}"
            );
        }
    }

    #[test]
    fn a_deleted_profile_is_refused() {
        let (procfs, users) = world();
        assert_eq!(
            identify(&procfs, &users, &caller(), |p| p == "p2"),
            Err(NotAnApp::NotAProfile)
        );
    }
}
