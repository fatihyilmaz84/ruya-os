//! The helper as a transient systemd unit (05 §7.3, RUY-828; run for real by RUY-100 in the VM).
//!
//! Each helper run is `systemd-run --wait --pipe --collect` of the service's own binary with
//! `--helper`: the request goes in on standard input, the JSON Lines come back on standard output,
//! and the unit has:
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
//! - **one way in, one way out:** the source path bound read-only at [`SOURCE_IN_UNIT`], and one
//!   writable folder, `StateDirectory=ruya-play-helper-<job>`: systemd creates it as
//!   `/var/lib/private/ruya-play-helper-<job>`, owned by the dynamic uid, mode 0700, on `/var`
//!   like `/var/lib/flatpak` (the reflink rule of 05 §7.1). After the unit is gone the service
//!   moves its top-level entries into the job's own folder (`rename`, same filesystem, links are
//!   moved, never followed) and removes the rest; then it re-walks what it got.

use crate::core::helper::Request;
use std::path::{Path, PathBuf};

/// Where the helper sees the package.
pub const SOURCE_IN_UNIT: &str = "/run/ruya-play-helper/source";
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

/// `request` as the helper inside the unit sees it: the source at [`SOURCE_IN_UNIT`] and its state
/// folder as the staging folder.
pub fn inner_request(request: &Request) -> Option<Request> {
    let unit = unit_name(&request.job)?;
    let mut inner = request.clone();
    inner.source = SOURCE_IN_UNIT.to_string();
    inner.staging = format!("/var/lib/{unit}");
    Some(inner)
}

/// A path for a `BindReadOnlyPaths=` value: absolute, no control characters, quoted, with `\`,
/// `"` and the `:` separator escaped.
fn bind_path(path: &str) -> Option<String> {
    if !path.starts_with('/') || path.chars().any(char::is_control) {
        return None;
    }
    let mut out = String::with_capacity(path.len() + 2);
    out.push('"');
    for c in path.chars() {
        if matches!(c, '\\' | '"' | ':') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    Some(out)
}

/// The command line that runs `request` in a transient unit, or `None` when the job name or the
/// source path cannot be passed safely (the run then fails with `helper.failed`).
pub fn argv(exe: &Path, request: &Request) -> Option<Vec<String>> {
    use crate::core::helper::Mode;
    let unit = unit_name(&request.job)?;
    let source = bind_path(&request.source)?;
    let exe = exe.to_str()?.to_string();
    let runtime = match request.mode {
        Mode::Inspect => INSPECT_MAX_SEC,
        Mode::Install => INSTALL_MAX_SEC,
    };
    let mut v: Vec<String> = [
        "systemd-run",
        "--wait",
        "--pipe",
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
        format!("BindReadOnlyPaths={source}:{SOURCE_IN_UNIT}"),
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
    use super::{argv, inner_request, private_dir, unit_name, SystemdRunHelper, PRIVATE_STATE};
    use crate::core::deps::{Exit, Helper};
    use crate::core::helper::Request;
    use std::io::{self, Read, Write};
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

    impl Helper for SystemdRunHelper {
        fn run(
            &self,
            request: &Request,
            cancel: &AtomicBool,
            on_output: &mut dyn FnMut(&[u8]) -> bool,
        ) -> Exit {
            let (Some(args), Some(inner)) = (argv(&self.exe, request), inner_request(request))
            else {
                return Exit::Lost("the job or the source path cannot be passed to systemd".into());
            };
            let mut child = match Command::new(&args[0])
                .args(&args[1..])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit())
                .spawn()
            {
                Ok(c) => c,
                Err(e) => return Exit::Lost(format!("systemd-run could not start ({e})")),
            };
            if let Some(mut stdin) = child.stdin.take() {
                // A helper that does not read its request ends without a result.
                let _ = stdin.write_all(inner.to_json().as_bytes());
            }
            let stopped = AtomicBool::new(false);
            let done = AtomicBool::new(false);
            let stdout = child.stdout.take();
            std::thread::scope(|s| {
                s.spawn(|| {
                    while !done.load(Ordering::SeqCst) {
                        if cancel.load(Ordering::SeqCst) && !stopped.swap(true, Ordering::SeqCst) {
                            self.stop(&request.job);
                        }
                        std::thread::sleep(Duration::from_millis(100));
                    }
                });
                if let Some(mut out) = stdout {
                    let mut buf = [0u8; 8192];
                    loop {
                        match out.read(&mut buf) {
                            Ok(0) => break,
                            Ok(n) => {
                                if !on_output(&buf[..n]) {
                                    if !stopped.swap(true, Ordering::SeqCst) {
                                        self.stop(&request.job);
                                    }
                                    break;
                                }
                            }
                            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                            Err(_) => break,
                        }
                    }
                }
                done.store(true, Ordering::SeqCst);
            });
            let status = child.wait();
            if let Err(e) = take_output(request) {
                return Exit::Lost(format!("the helper's folder could not be taken over ({e})"));
            }
            if stopped.load(Ordering::SeqCst) {
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
        )
        .unwrap();
        assert_eq!(
            &v[..7],
            &[
                "systemd-run",
                "--wait",
                "--pipe",
                "--collect",
                "--quiet",
                "--service-type=exec",
                "--unit=ruya-play-helper-job-7"
            ]
        );
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
            "BindReadOnlyPaths=\"/run/media/ruya-shell/USB/game.play.zip\":/run/ruya-play-helper/source",
        ] {
            assert!(p.contains(&want), "missing {want}: {p:?}");
        }
        // The state folder is the only writable path, and the source is bound read-only only.
        for prop in &p {
            assert!(!prop.starts_with("ReadWritePaths"), "{prop}");
            assert!(!prop.starts_with("BindPaths"), "{prop}");
            assert!(!prop.starts_with("ProtectSystem=") || *prop == "ProtectSystem=strict");
            if prop.contains("game.play.zip") {
                assert!(prop.starts_with("BindReadOnlyPaths="), "{prop}");
            }
        }
        // No network setting but the one that takes it away.
        assert!(!p
            .iter()
            .any(|x| x.starts_with("PrivateNetwork=") && *x != "PrivateNetwork=yes"));
        // An inspect gets the short time limit.
        let v = argv(exe, &request(Mode::Inspect, "/run/media/x")).unwrap();
        assert!(props(&v).contains(&"RuntimeMaxSec=600"));
    }

    #[test]
    fn the_source_path_is_escaped_or_refused() {
        let exe = Path::new("/usr/libexec/ruya-play");
        let v = argv(
            exe,
            &request(Mode::Install, "/run/media/u/MY STICK/a:b\\\"c.play.zip"),
        )
        .unwrap();
        assert!(props(&v).contains(
            &"BindReadOnlyPaths=\"/run/media/u/MY STICK/a\\:b\\\\\\\"c.play.zip\":/run/ruya-play-helper/source"
        ));
        assert_eq!(
            argv(exe, &request(Mode::Install, "relative/game.play")),
            None
        );
        assert_eq!(argv(exe, &request(Mode::Install, "/run/media/a\nb")), None);
        let mut r = request(Mode::Install, "/run/media/x");
        r.job = "../../etc".into();
        assert_eq!(argv(exe, &r), None);
        assert_eq!(
            unit_name("job-12").as_deref(),
            Some("ruya-play-helper-job-12")
        );
        assert_eq!(unit_name(""), None);
    }

    #[test]
    fn the_helper_inside_sees_its_bind_and_its_state_folder() {
        let inner = inner_request(&request(Mode::Install, "/run/media/x")).unwrap();
        assert_eq!(inner.source, SOURCE_IN_UNIT);
        assert_eq!(inner.staging, "/var/lib/ruya-play-helper-job-7");
        assert_eq!(
            private_dir("job-7").unwrap(),
            Path::new("/var/lib/private/ruya-play-helper-job-7")
        );
    }
}
