//! The helper as a transient systemd unit (05 §7.3, RUY-828; run for real by RUY-100 in the VM).
//!
//! Each helper run is `systemd-run --wait --collect` of the service's own binary with `--helper`
//! (never `--pipe`: under SELinux PID 1 may not use descriptors a service passes over D-Bus,
//! RUY-839). The request is a file the service wrote and the manager opens as standard input
//! (`StandardInput=file:`), the JSON Lines go to a file the manager opens as standard output
//! (`StandardOutput=file:`) that the service follows ([`Follower`]); both live in the run's own
//! folder, [`io_dir`]. The unit has:
//!
//! - **no identity:** `DynamicUser=yes` (a fresh uid per run), `NoNewPrivileges=yes`, an empty
//!   capability set, `RestrictSUIDSGID=yes`;
//! - **no network:** `PrivateNetwork=yes`, `IPAddressDeny=any`, only `AF_UNIX` sockets;
//! - **no view of the system:** `ProtectSystem=strict` (everything read-only), `ProtectHome=yes`,
//!   `PrivateTmp=yes`, `PrivateDevices=yes`, the kernel and cgroup protections, the service's
//!   `/var/lib/ruya-play` inaccessible, `SystemCallFilter=@system-service`;
//! - **limits:** `MemoryMax=2G` (above the art step's 1.25 GiB peak, 05 §7.3 item 7, with room
//!   for the unpacker's buffers), no swap, `CPUQuota=200%`, `RuntimeMaxSec` (10 minutes for an
//!   inspect, 6 hours for an install);
//! - **one way in, one way out:** the source as one read-only file descriptor that the service
//!   manager opens as root and passes in (`OpenFile=<path>:<name>:read-only,graceful`, RUY-829:
//!   a bind keeps the file's own mode, and `incoming/` is root 0600, so the dynamic uid could not
//!   read a download). The descriptor's name carries the device and inode the service saw with
//!   `lstat` (a link is refused there) and the helper checks them on the descriptor
//!   ([`passed_source`]; `crate::service::fd_source`), so a file swapped in between is refused.
//!   The helper reads a zip through the descriptor and a folder through `/proc/self/fd/3`; its
//!   request names [`SOURCE_IN_UNIT`]. And one writable folder,
//!   `StateDirectory=ruya-play-helper-<job>`: systemd creates it as
//!   `/var/lib/private/ruya-play-helper-<job>`, owned by the dynamic uid, mode 0700, on `/var`
//!   like `/var/lib/flatpak` (the reflink rule of 05 §7.1). The helper is given that real folder,
//!   never the `/var/lib/ruya-play-helper-<job>` link systemd also makes, which the helper's
//!   no-follow open refuses (ENOTDIR; RUY-866). After the unit is gone the service moves its
//!   top-level entries into the job's own folder (`rename`, links are moved, never followed) and
//!   removes the rest; then it re-walks what it got. The job's folder is under
//!   `/var/lib/private/ruya-play-work` for that (the service's `Config::with_work`): in the
//!   service's namespace `/var/lib/private` and `/var/lib/ruya-play` are separate mounts, and a
//!   rename between them is EXDEV.

use crate::core::helper::Request;
use std::path::{Path, PathBuf};

/// The source path the helper finds in its request inside the unit: it stands for the passed
/// descriptor (nothing is mounted there).
pub const SOURCE_IN_UNIT: &str = "/run/ruya-play-helper/source";
/// The first descriptor systemd passes (`SD_LISTEN_FDS_START`).
pub const LISTEN_FDS_START: i32 = 3;
/// The prefix of every helper unit and its state folder.
pub const UNIT_PREFIX: &str = "ruya-play-helper-";
/// Where systemd keeps the state folders of dynamic users.
pub const PRIVATE_STATE: &str = "/var/lib/private";
/// The memory limit of a helper unit.
pub const MEMORY_MAX: &str = "2G";
/// The CPU limit of a helper unit.
pub const CPU_QUOTA: &str = "200%";
/// The time limit of an `inspect` run, in seconds.
pub const INSPECT_MAX_SEC: u64 = 600;
/// The time limit of an `install` run, in seconds.
pub const INSTALL_MAX_SEC: u64 = 6 * 3600;
/// The request file in a run's [`io_dir`].
pub const REQUEST_FILE: &str = "in.json";
/// The output file in a run's [`io_dir`].
pub const OUTPUT_FILE: &str = "out.jsonl";
/// The most output the service follows (a helper writes a few lines; more is a runaway).
pub const MAX_OUTPUT_BYTES: u64 = 16 * 1024 * 1024;

/// Starts the helper with `systemd-run` (Linux only; [`argv`] builds its command line everywhere).
#[derive(Debug, Clone)]
pub struct SystemdRunHelper {
    /// The service's own binary (RUY-829), started with `--helper`.
    pub exe: PathBuf,
}

/// The unit (and state folder) name of `job`'s helper, when the job name is plain.
pub fn unit_name(job: &str) -> Option<String> {
    let plain = !job.is_empty()
        && job.len() <= 64
        && job
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
    plain.then(|| format!("{UNIT_PREFIX}{job}"))
}

/// The folder the helper writes into, as the service sees it after the run.
pub fn private_dir(job: &str) -> Option<PathBuf> {
    unit_name(job).map(|u| Path::new(PRIVATE_STATE).join(u))
}

/// The folder of a run's request and output files: next to the helper's state folder (same
/// filesystem, in the service's `ReadWritePaths`, removed with the other `ruya-play-helper-*`
/// entries at start). The manager opens both files itself, as root, so no descriptor of the
/// service is passed to it; the helper's own state folder is not used because the manager sets
/// it up after it opens the standard streams.
pub fn io_dir(job: &str) -> Option<PathBuf> {
    unit_name(job).map(|u| PathBuf::from(format!("{PRIVATE_STATE}/{u}.io")))
}

/// Follows a file that another process (the manager, for the unit's standard output) appends to:
/// each [`poll`](Follower::poll) hands the bytes written since the last one to the parser, whole
/// lines or not (the parser keeps a partial line).
#[derive(Debug)]
pub struct Follower {
    path: PathBuf,
    offset: u64,
    cap: u64,
}

impl Follower {
    /// Follows `path`, which may not exist yet.
    pub fn new(path: PathBuf) -> Follower {
        Follower::with_cap(path, MAX_OUTPUT_BYTES)
    }

    /// As [`Follower::new`], refusing more than `cap` bytes in all.
    pub fn with_cap(path: PathBuf, cap: u64) -> Follower {
        Follower {
            path,
            offset: 0,
            cap,
        }
    }

    /// Hand the new bytes to `on_output`. `Ok(false)` when it refused them or the file grew past
    /// the cap (the run is then stopped); a missing file is nothing yet.
    pub fn poll(&mut self, on_output: &mut dyn FnMut(&[u8]) -> bool) -> std::io::Result<bool> {
        use std::io::{Read, Seek, SeekFrom};
        let mut file = match std::fs::File::open(&self.path) {
            Ok(f) => f,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(true),
            Err(e) => return Err(e),
        };
        file.seek(SeekFrom::Start(self.offset))?;
        let mut buf = [0u8; 8192];
        loop {
            let n = match file.read(&mut buf) {
                Ok(0) => return Ok(true),
                Ok(n) => n,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            };
            self.offset += n as u64;
            if self.offset > self.cap || !on_output(&buf[..n]) {
                return Ok(false);
            }
        }
    }
}

/// `request` as the helper inside the unit sees it: the source at [`SOURCE_IN_UNIT`] and its state
/// folder as the staging folder.
pub fn inner_request(request: &Request) -> Option<Request> {
    let unit = unit_name(&request.job)?;
    let mut inner = request.clone();
    inner.source = SOURCE_IN_UNIT.to_string();
    inner.staging = format!("{PRIVATE_STATE}/{unit}");
    Some(inner)
}

/// A path for an `OpenFile=` value: absolute, with no control character and none of the
/// characters its parser takes as a separator or an escape (`:`, `\`). A drive's own names never
/// need them (FAT and exFAT forbid both); a path that has one refuses the run.
fn open_file_path(path: &str) -> Option<&str> {
    let plain = path.starts_with('/')
        && !path
            .chars()
            .any(|c| c.is_control() || c == ':' || c == '\\');
    plain.then_some(path)
}

/// The descriptor's name for a source with device `dev` and inode `ino` (as `lstat` saw them).
pub fn fd_name(dev: u64, ino: u64) -> String {
    format!("source-{dev}-{ino}")
}

/// The device and inode in a name from [`fd_name`].
pub fn parse_fd_name(name: &str) -> Option<(u64, u64)> {
    let (dev, ino) = name.strip_prefix("source-")?.split_once('-')?;
    let num = |t: &str| -> Option<u64> {
        if t.is_empty() || !t.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        t.parse().ok()
    };
    Some((num(dev)?, num(ino)?))
}

/// The source descriptor of a helper inside its unit, from `LISTEN_PID`, `LISTEN_FDS` and
/// `LISTEN_FDNAMES` as systemd sets them (`pid` is the helper's own): exactly one descriptor, for
/// this process, named by [`fd_name`]. Returns the descriptor number and the expected device and
/// inode; `None` when no source was passed (`graceful`: the path was gone).
pub fn passed_source(
    pid: u32,
    listen_pid: Option<&str>,
    listen_fds: Option<&str>,
    names: Option<&str>,
) -> Option<(i32, u64, u64)> {
    if listen_pid?.parse::<u32>().ok()? != pid || listen_fds? != "1" {
        return None;
    }
    let (dev, ino) = parse_fd_name(names?)?;
    Some((LISTEN_FDS_START, dev, ino))
}

/// The command line that runs `request` in a transient unit, its source passed as the descriptor
/// named `fd_name` ([`fd_name`]), or `None` when the job name or the source path cannot be passed
/// safely (the run then fails with `helper.failed`).
pub fn argv(exe: &Path, request: &Request, fd_name: &str) -> Option<Vec<String>> {
    use crate::core::helper::Mode;
    let unit = unit_name(&request.job)?;
    let source = open_file_path(&request.source)?;
    parse_fd_name(fd_name)?;
    let exe = exe.to_str()?.to_string();
    let io = io_dir(&request.job)?;
    let io = io.to_str()?;
    let runtime = match request.mode {
        Mode::Inspect => INSPECT_MAX_SEC,
        Mode::Install => INSTALL_MAX_SEC,
    };
    let mut v: Vec<String> = [
        "systemd-run",
        "--wait",
        "--collect",
        "--quiet",
        "--service-type=exec",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    v.push(format!("--unit={unit}"));
    let props = [
        "DynamicUser=yes".to_string(),
        "NoNewPrivileges=yes".to_string(),
        "CapabilityBoundingSet=".to_string(),
        "RestrictSUIDSGID=yes".to_string(),
        "PrivateNetwork=yes".to_string(),
        "IPAddressDeny=any".to_string(),
        "RestrictAddressFamilies=AF_UNIX".to_string(),
        "ProtectSystem=strict".to_string(),
        "ProtectHome=yes".to_string(),
        "PrivateTmp=yes".to_string(),
        "PrivateDevices=yes".to_string(),
        "ProtectKernelTunables=yes".to_string(),
        "ProtectKernelModules=yes".to_string(),
        "ProtectKernelLogs=yes".to_string(),
        "ProtectControlGroups=yes".to_string(),
        "ProtectClock=yes".to_string(),
        "ProtectHostname=yes".to_string(),
        "RestrictNamespaces=yes".to_string(),
        "LockPersonality=yes".to_string(),
        "SystemCallArchitectures=native".to_string(),
        "SystemCallFilter=@system-service".to_string(),
        "InaccessiblePaths=-/var/lib/ruya-play".to_string(),
        format!("MemoryMax={MEMORY_MAX}"),
        "MemorySwapMax=0".to_string(),
        format!("CPUQuota={CPU_QUOTA}"),
        format!("RuntimeMaxSec={runtime}"),
        "UMask=0077".to_string(),
        format!("StateDirectory={unit}"),
        "StateDirectoryMode=0700".to_string(),
        format!("OpenFile={source}:{fd_name}:read-only,graceful"),
        format!("StandardInput=file:{io}/{REQUEST_FILE}"),
        format!("StandardOutput=file:{io}/{OUTPUT_FILE}"),
        "StandardError=journal".to_string(),
    ];
    for p in props {
        v.push("-p".into());
        v.push(p);
    }
    v.push("--".into());
    v.push(exe);
    v.push("--helper".into());
    Some(v)
}

#[cfg(target_os = "linux")]
mod imp {
    use super::UNIT_PREFIX;
    use super::{
        argv, fd_name, inner_request, io_dir, private_dir, unit_name, Follower, SystemdRunHelper,
        OUTPUT_FILE, PRIVATE_STATE, REQUEST_FILE,
    };
    use crate::core::deps::{Exit, Helper};
    use crate::core::helper::Request;
    use std::io::{self, Write};
    use std::path::Path;
    use std::process::{Command, Stdio};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;

    /// The most top-level entries taken over from a helper's folder (it writes `meta`, `src`,
    /// `tree` and `art`; anything more is refused by the service's check anyway).
    const MAX_TAKEN: usize = 16;

    /// Move the helper's output into the service's folder for the request, then remove the rest.
    fn take_output(request: &Request) -> io::Result<()> {
        let Some(private) = private_dir(&request.job) else {
            return Ok(());
        };
        let entries = match std::fs::read_dir(&private) {
            Ok(e) => e,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(e) => return Err(e),
        };
        let target = Path::new(&request.staging);
        let mut taken = 0;
        for entry in entries {
            let entry = entry?;
            taken += 1;
            if taken > MAX_TAKEN {
                break;
            }
            // rename does not follow the last component: a link is moved as a link.
            std::fs::rename(entry.path(), target.join(entry.file_name()))?;
        }
        std::fs::remove_dir_all(&private)
    }

    /// Make the run's folder (root only) and write the request the unit reads as standard input.
    fn prepare_io(io: &Path, inner: &Request) -> io::Result<()> {
        use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
        let _ = std::fs::remove_dir_all(io);
        std::fs::DirBuilder::new().mode(0o700).create(io)?;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(io.join(REQUEST_FILE))?;
        f.write_all(inner.to_json().as_bytes())
    }

    impl Helper for SystemdRunHelper {
        fn run(
            &self,
            request: &Request,
            cancel: &AtomicBool,
            on_output: &mut dyn FnMut(&[u8]) -> bool,
        ) -> Exit {
            use std::os::unix::fs::MetadataExt;
            // The identity the helper checks on the descriptor. A missing path still runs: the
            // manager passes nothing (`graceful`) and the helper reports it as missing.
            let name = match std::fs::symlink_metadata(&request.source) {
                Ok(m) if m.file_type().is_symlink() => {
                    return Exit::Lost("the source is a link, not a package".into())
                }
                Ok(m) => fd_name(m.dev(), m.ino()),
                Err(e) if e.kind() == io::ErrorKind::NotFound => fd_name(0, 0),
                Err(e) => return Exit::Lost(format!("the source cannot be looked at ({e})")),
            };
            let (Some(args), Some(inner)) =
                (argv(&self.exe, request, &name), inner_request(request))
            else {
                return Exit::Lost("the job or the source path cannot be passed to systemd".into());
            };
            let Some(io) = io_dir(&request.job) else {
                return Exit::Lost("the job cannot be passed to systemd".into());
            };
            if let Err(e) = prepare_io(&io, &inner) {
                let _ = std::fs::remove_dir_all(&io);
                return Exit::Lost(format!("the helper's request could not be written ({e})"));
            }
            let mut child = match Command::new(&args[0])
                .args(&args[1..])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::inherit())
                .spawn()
            {
                Ok(c) => c,
                Err(e) => {
                    let _ = std::fs::remove_dir_all(&io);
                    return Exit::Lost(format!("systemd-run could not start ({e})"));
                }
            };
            let mut follower = Follower::new(io.join(OUTPUT_FILE));
            let mut stopped = false;
            let mut lost: Option<String> = None;
            let status = loop {
                let mut stop_now = cancel.load(Ordering::SeqCst);
                match follower.poll(on_output) {
                    Ok(true) => {}
                    Ok(false) => stop_now = true,
                    Err(e) => {
                        lost = Some(format!("the helper's output could not be read ({e})"));
                        stop_now = true;
                    }
                }
                if stop_now && !stopped {
                    stopped = true;
                    self.stop(&request.job);
                }
                match child.try_wait() {
                    Ok(Some(s)) => {
                        // The unit is over: read what was written since the last look.
                        if !stopped {
                            match follower.poll(on_output) {
                                Ok(true) => {}
                                Ok(false) => stopped = true,
                                Err(e) => {
                                    lost =
                                        Some(format!("the helper's output could not be read ({e})"))
                                }
                            }
                        }
                        break Ok(s);
                    }
                    Ok(None) => std::thread::sleep(Duration::from_millis(50)),
                    Err(e) => break Err(e),
                }
            };
            let _ = std::fs::remove_dir_all(&io);
            if let Err(e) = take_output(request) {
                return Exit::Lost(format!("the helper's folder could not be taken over ({e})"));
            }
            if let Some(why) = lost {
                return Exit::Lost(why);
            }
            if stopped {
                return Exit::Stopped;
            }
            match status {
                Ok(s) => s.code().map_or(Exit::Stopped, Exit::Code),
                Err(e) => Exit::Lost(format!("systemd-run could not be waited for ({e})")),
            }
        }

        fn stop(&self, job: &str) {
            if let Some(unit) = unit_name(job) {
                let _ = Command::new("systemctl")
                    .args(["stop", "--no-block", &format!("{unit}.service")])
                    .status();
            }
        }

        fn clear(&self) -> io::Result<()> {
            let entries = match std::fs::read_dir(PRIVATE_STATE) {
                Ok(e) => e,
                Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
                Err(e) => return Err(e),
            };
            for entry in entries {
                let entry = entry?;
                if entry.file_name().to_string_lossy().starts_with(UNIT_PREFIX) {
                    std::fs::remove_dir_all(entry.path())?;
                }
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::helper::Mode;

    fn request(mode: Mode, source: &str) -> Request {
        Request {
            mode,
            job: "job-7".into(),
            source: source.into(),
            staging: "/var/lib/ruya-play/staging/job-7".into(),
            now: 0,
            developer_mode: false,
            blocklist: None,
            art: false,
            official: false,
            expect: Default::default(),
        }
    }

    fn props(v: &[String]) -> Vec<&str> {
        v.windows(2)
            .filter(|w| w[0] == "-p")
            .map(|w| w[1].as_str())
            .collect()
    }

    #[test]
    fn the_unit_has_every_property_of_the_sandbox() {
        let exe = Path::new("/usr/libexec/ruya-play");
        let v = argv(
            exe,
            &request(Mode::Install, "/run/media/ruya-shell/USB/game.play.zip"),
            NAME,
        )
        .unwrap();
        assert_eq!(
            &v[..6],
            &[
                "systemd-run",
                "--wait",
                "--collect",
                "--quiet",
                "--service-type=exec",
                "--unit=ruya-play-helper-job-7"
            ]
        );
        // RUY-839: no --pipe (PID 1 may not use the service's descriptors); the manager opens
        // the request and the output files itself, in the run's folder.
        assert!(!v.iter().any(|a| a.contains("pipe")), "{v:?}");
        assert_eq!(
            &v[v.len() - 3..],
            &["--", "/usr/libexec/ruya-play", "--helper"]
        );
        let p = props(&v);
        for want in [
            "DynamicUser=yes",
            "PrivateNetwork=yes",
            "IPAddressDeny=any",
            "RestrictAddressFamilies=AF_UNIX",
            "ProtectSystem=strict",
            "ProtectHome=yes",
            "NoNewPrivileges=yes",
            "PrivateTmp=yes",
            "PrivateDevices=yes",
            "CapabilityBoundingSet=",
            "SystemCallFilter=@system-service",
            "MemoryMax=2G",
            "MemorySwapMax=0",
            "CPUQuota=200%",
            "RuntimeMaxSec=21600",
            "InaccessiblePaths=-/var/lib/ruya-play",
            "StateDirectory=ruya-play-helper-job-7",
            "StateDirectoryMode=0700",
            "OpenFile=/run/media/ruya-shell/USB/game.play.zip:source-2049-77:read-only,graceful",
            "StandardInput=file:/var/lib/private/ruya-play-helper-job-7.io/in.json",
            "StandardOutput=file:/var/lib/private/ruya-play-helper-job-7.io/out.jsonl",
            "StandardError=journal",
        ] {
            assert!(p.contains(&want), "missing {want}: {p:?}");
        }
        // The state folder is the only writable path, and the source is passed read-only only.
        for prop in &p {
            assert!(!prop.starts_with("ReadWritePaths"), "{prop}");
            assert!(!prop.starts_with("BindPaths"), "{prop}");
            assert!(!prop.starts_with("BindReadOnlyPaths"), "{prop}");
            assert!(!prop.starts_with("ProtectSystem=") || *prop == "ProtectSystem=strict");
            if prop.contains("game.play.zip") {
                assert!(prop.starts_with("OpenFile="), "{prop}");
                assert!(prop.ends_with(":read-only,graceful"), "{prop}");
            }
        }
        // No network setting but the one that takes it away.
        assert!(!p
            .iter()
            .any(|x| x.starts_with("PrivateNetwork=") && *x != "PrivateNetwork=yes"));
        // An inspect gets the short time limit.
        let v = argv(exe, &request(Mode::Inspect, "/run/media/x"), NAME).unwrap();
        assert!(props(&v).contains(&"RuntimeMaxSec=600"));
    }

    const NAME: &str = "source-2049-77";

    #[test]
    fn the_source_path_is_passed_plain_or_refused() {
        let exe = Path::new("/usr/libexec/ruya-play");
        let v = argv(
            exe,
            &request(Mode::Install, "/run/media/u/MY STICK/game.play.zip"),
            NAME,
        )
        .unwrap();
        assert!(props(&v).contains(
            &"OpenFile=/run/media/u/MY STICK/game.play.zip:source-2049-77:read-only,graceful"
        ));
        for bad in [
            "relative/game.play",
            "/run/media/a\nb",
            "/run/media/u/a:b.play.zip",
            "/run/media/u/a\\b.play.zip",
        ] {
            assert_eq!(argv(exe, &request(Mode::Install, bad), NAME), None, "{bad}");
        }
        let mut r = request(Mode::Install, "/run/media/x");
        r.job = "../../etc".into();
        assert_eq!(argv(exe, &r, NAME), None);
        // A descriptor name that is not the service's own is refused too.
        assert_eq!(
            argv(exe, &request(Mode::Install, "/run/media/x"), "source:x"),
            None
        );
        assert_eq!(
            unit_name("job-12").as_deref(),
            Some("ruya-play-helper-job-12")
        );
        assert_eq!(unit_name(""), None);
    }

    #[test]
    fn the_descriptor_carries_the_identity_the_service_saw() {
        assert_eq!(fd_name(2049, 77), NAME);
        assert_eq!(parse_fd_name(NAME), Some((2049, 77)));
        for bad in [
            "source-1",
            "source--1",
            "source-a-1",
            "src-1-2",
            "source-1-2-3",
            "",
        ] {
            assert_eq!(parse_fd_name(bad), None, "{bad}");
        }
        assert_eq!(
            passed_source(42, Some("42"), Some("1"), Some(NAME)),
            Some((3, 2049, 77))
        );
        // Another process's descriptors, two of them, none, or a foreign name: no source.
        assert_eq!(passed_source(42, Some("41"), Some("1"), Some(NAME)), None);
        assert_eq!(passed_source(42, Some("42"), Some("2"), Some(NAME)), None);
        assert_eq!(passed_source(42, None, None, None), None);
        assert_eq!(
            passed_source(42, Some("42"), Some("1"), Some("other")),
            None
        );
    }

    #[test]
    fn the_helper_inside_sees_its_source_and_its_state_folder() {
        let inner = inner_request(&request(Mode::Install, "/run/media/x")).unwrap();
        assert_eq!(inner.source, SOURCE_IN_UNIT);
        // The real folder, not systemd's /var/lib/<unit> link (RUY-866).
        assert_eq!(inner.staging, "/var/lib/private/ruya-play-helper-job-7");
        assert_eq!(Path::new(&inner.staging), private_dir("job-7").unwrap());
        assert_eq!(
            private_dir("job-7").unwrap(),
            Path::new("/var/lib/private/ruya-play-helper-job-7")
        );
    }

    // --- the follower (RUY-839) ---

    use crate::core::codes;
    use crate::core::deps::Exit;
    use crate::core::helper::{Ending, Session, MAX_LINE_BYTES};
    use std::io::Write;

    fn append(path: &Path, bytes: &[u8]) {
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .unwrap();
        f.write_all(bytes).unwrap();
    }

    const PROGRESS: &str = r#"{"type":"progress","phase":"staging","done":1,"total":2}"#;
    const RESULT: &str = r#"{"type":"result","outcome":"ok"}"#;

    /// Poll `f` once into `session`; returns what `poll` said and the progress lines seen.
    fn poll_into(f: &mut Follower, session: &mut Session, seen: &mut usize) -> bool {
        f.poll(&mut |b| session.feed(b, &mut |_| *seen += 1))
            .unwrap()
    }

    #[test]
    fn the_follower_reads_a_file_that_grows_and_a_line_in_pieces() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("out.jsonl");
        let mut f = Follower::new(path.clone());
        let (mut s, mut seen) = (Session::new(), 0usize);
        // The manager has not made the file yet: nothing, not an error.
        assert!(poll_into(&mut f, &mut s, &mut seen));
        // A line in two pieces: nothing is a line until its newline.
        let (a, b) = PROGRESS.split_at(20);
        append(&path, a.as_bytes());
        assert!(poll_into(&mut f, &mut s, &mut seen));
        assert_eq!(seen, 0);
        append(
            &path,
            format!(
                "{b}
{PROGRESS}
"
            )
            .as_bytes(),
        );
        assert!(poll_into(&mut f, &mut s, &mut seen));
        assert_eq!(seen, 2);
        // Nothing new: nothing more (the offset holds), then the result as the unit ends.
        assert!(poll_into(&mut f, &mut s, &mut seen));
        assert_eq!(seen, 2);
        append(
            &path,
            format!(
                "{RESULT}
"
            )
            .as_bytes(),
        );
        assert!(poll_into(&mut f, &mut s, &mut seen));
        assert!(matches!(s.finish(&Exit::Code(0), false), Ending::Ok { .. }));
    }

    #[test]
    fn the_follower_ends_a_run_with_garbage_or_a_long_line_as_helper_failed() {
        let dir = tempfile::tempdir().unwrap();
        for (name, bytes) in [
            (
                "garbage",
                b"this is not json
"
                .to_vec(),
            ),
            ("long", vec![b' '; MAX_LINE_BYTES + 1]),
        ] {
            let path = dir.path().join(name);
            append(&path, &bytes);
            let mut f = Follower::new(path);
            let (mut s, mut seen) = (Session::new(), 0usize);
            assert!(!poll_into(&mut f, &mut s, &mut seen), "{name}");
            assert!(
                matches!(s.finish(&Exit::Code(0), false), Ending::Failed(p) if p.code == codes::HELPER_FAILED),
                "{name}"
            );
        }
    }

    #[test]
    fn the_follower_stops_a_runaway_and_a_refusal() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("out.jsonl");
        append(&path, &[b'x'; 100]);
        let mut f = Follower::with_cap(path.clone(), 99);
        assert!(!f.poll(&mut |_| true).unwrap());
        let mut f = Follower::new(path);
        assert!(!f.poll(&mut |_| false).unwrap());
    }

    #[test]
    fn the_run_folder_is_next_to_the_state_folder_and_cleared_with_it() {
        let io = io_dir("job-7").unwrap();
        assert_eq!(io, Path::new("/var/lib/private/ruya-play-helper-job-7.io"));
        assert!(io
            .to_str()
            .unwrap()
            .starts_with(&format!("{PRIVATE_STATE}/{UNIT_PREFIX}")));
        assert_eq!(io_dir("../x"), None);
    }
}
