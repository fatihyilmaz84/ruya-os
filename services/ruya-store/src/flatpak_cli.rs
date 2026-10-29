//! The real `flatpak` command (Linux). Everything here is system-wide (`--system`, as root) and
//! non-interactive. The text it prints is parsed in `flatpak.rs`; this file starts the processes.

use std::fs;
use std::io::Read;
use std::os::fd::AsFd;
use std::os::unix::fs::MetadataExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::app::{valid_app_id, valid_remote_name};
use crate::flatpak::{
    classify_error, parse_ids, parse_installed, parse_remote_ls, parse_remotes, Appstream, Flatpak,
    FlatpakError, InstalledApp, Operation, Phase, Progress, ProgressScanner, RemoteApp, RemoteInfo,
};

pub struct FlatpakCli {
    /// `/var/lib/flatpak/appstream`
    appstream_root: PathBuf,
    /// `/var/home`: where the profiles' home directories are.
    homes: PathBuf,
}

impl FlatpakCli {
    pub fn system() -> Self {
        FlatpakCli {
            appstream_root: PathBuf::from("/var/lib/flatpak/appstream"),
            homes: PathBuf::from("/var/home"),
        }
    }
}

fn command(args: &[&str]) -> Command {
    let mut cmd = Command::new("flatpak");
    cmd.args(args)
        // English messages: the failures are recognised by their text.
        .env("LC_ALL", "C.UTF-8")
        .env("LANG", "C.UTF-8")
        .stdin(Stdio::null());
    cmd
}

/// Runs a command to its end; stdout on success, the error text on failure.
fn output(args: &[&str]) -> Result<String, String> {
    let out = command(args)
        .output()
        .map_err(|e| format!("flatpak: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_owned())
    }
}

fn arch() -> &'static str {
    match std::env::consts::ARCH {
        "aarch64" => "aarch64",
        _ => "x86_64",
    }
}

impl Flatpak for FlatpakCli {
    fn remote_apps(&self) -> Result<Vec<RemoteApp>, String> {
        let mut apps = Vec::new();
        for remote in self.remotes()?.into_iter().filter(|r| r.enabled) {
            if !valid_remote_name(&remote.name) {
                continue;
            }
            let columns = "--columns=application,origin,branch,installed-size";
            let args = ["remote-ls", "--system", "--app", columns, &remote.name];
            // The catalogue is useful without the network: fall back to flatpak's own cache.
            let listing = output(&args).or_else(|_| {
                output(&[
                    "remote-ls",
                    "--system",
                    "--app",
                    "--cached",
                    columns,
                    &remote.name,
                ])
            });
            match listing {
                Ok(text) => apps.extend(parse_remote_ls(&text)),
                Err(err) => eprintln!("ruya-store: remote {} unreadable: {err}", remote.name),
            }
        }
        Ok(apps)
    }

    fn installed(&self) -> Result<Vec<InstalledApp>, String> {
        output(&[
            "list",
            "--system",
            "--app",
            "--columns=application,branch,origin,size",
        ])
        .map(|text| parse_installed(&text))
    }

    fn updates(&self) -> Result<Vec<String>, String> {
        output(&[
            "remote-ls",
            "--system",
            "--app",
            "--updates",
            "--columns=application",
        ])
        .map(|text| parse_ids(&text))
    }

    fn remotes(&self) -> Result<Vec<RemoteInfo>, String> {
        output(&["remotes", "--system", "--columns=name,title,options"])
            .map(|text| parse_remotes(&text))
    }

    fn appstream(&self, remote: &str) -> Option<Appstream> {
        if !valid_remote_name(remote) {
            return None;
        }
        let active = self.appstream_root.join(remote).join(arch()).join("active");
        let xml = read_appstream(&active)?;
        Some(Appstream {
            xml,
            icon_base: active.join("icons").to_string_lossy().into_owned(),
        })
    }

    fn metadata(&self, remote: &str, id: &str) -> Option<String> {
        if !valid_remote_name(remote) || !valid_app_id(id) {
            return None;
        }
        // The remote's copy; an installed app whose remote cannot be reached has its own.
        output(&["remote-info", "--system", "--show-metadata", remote, id])
            .or_else(|_| output(&["info", "--system", "--show-metadata", id]))
            .ok()
    }

    fn run(&self, op: &Operation, progress: &mut dyn FnMut(Progress)) -> Result<(), FlatpakError> {
        let commit_arg;
        let args: Vec<&str> = match op {
            Operation::Install { id, remote } => {
                if !valid_app_id(id) || !valid_remote_name(remote) {
                    return Err(FlatpakError::Other("refused argument".to_owned()));
                }
                // No --noninteractive: flatpak then draws no progress bar. -y answers its questions
                // and stdin is /dev/null, so nothing can wait for a person.
                vec!["install", "--system", "-y", remote, id]
            }
            Operation::Uninstall { id, .. } => {
                vec!["uninstall", "--system", "--noninteractive", "-y", id]
            }
            Operation::Update { id } => vec!["update", "--system", "-y", id],
            Operation::Rollback { id, commit } => {
                commit_arg = format!("--commit={commit}");
                vec!["update", "--system", "-y", &commit_arg, id]
            }
        };
        if !valid_app_id(op.app()) {
            return Err(FlatpakError::Other("refused argument".to_owned()));
        }

        let (status, output) = run_on_terminal(&args, &mut |percent, phase| {
            progress(Progress {
                percent,
                phase: phase.unwrap_or_else(|| op.phase()),
            });
        })
        .map_err(|e| FlatpakError::Other(format!("flatpak: {e}")))?;
        if !status.success() {
            return Err(classify_error(&output));
        }
        if let Operation::Uninstall {
            id,
            delete_data: true,
        } = op
        {
            self.delete_user_data(id);
        }
        Ok(())
    }

    fn update_appstream(&self, remote: &str) -> Result<(), String> {
        if !valid_remote_name(remote) {
            return Err("refused argument".to_owned());
        }
        output(&[
            "update",
            "--appstream",
            "--system",
            "--noninteractive",
            remote,
        ])
        .map(|_| ())
    }

    fn add_remote(&self, name: &str, url: &str) -> Result<(), FlatpakError> {
        // No --no-gpg-verify, ever: a remote without a key fails here.
        output(&["remote-add", "--system", "--if-not-exists", name, url])
            .map_err(|err| classify_error(&err))?;
        // Belt and braces: whatever flatpak accepted must verify signatures, or it goes again.
        let signed = self
            .remotes()
            .map_err(FlatpakError::Other)?
            .iter()
            .any(|r| r.name == name && r.signed);
        if !signed {
            let _ = output(&["remote-delete", "--system", "--force", name]);
            return Err(FlatpakError::Signature);
        }
        Ok(())
    }
}

impl FlatpakCli {
    /// Removes `~/.var/app/<id>` of every profile. Done as the owner of each home, so a
    /// symlink a profile planted can only lead to what that profile may delete anyway.
    fn delete_user_data(&self, id: &str) {
        let Ok(entries) = fs::read_dir(&self.homes) else {
            return;
        };
        for entry in entries.flatten() {
            let Ok(meta) = entry.metadata() else { continue };
            if !meta.is_dir() || meta.uid() == 0 {
                continue;
            }
            let data: PathBuf = entry.path().join(".var").join("app").join(id);
            if fs::symlink_metadata(&data).is_err() {
                continue;
            }
            remove_as(&data, meta.uid(), meta.gid());
        }
    }
}

fn remove_as(path: &Path, uid: u32, gid: u32) {
    let result = Command::new("rm")
        .arg("-rf")
        .arg("--")
        .arg(path)
        .uid(uid)
        .gid(gid)
        .stdin(Stdio::null())
        .status();
    match result {
        Ok(status) if status.success() => {}
        Ok(status) => eprintln!("ruya-store: removing {} failed ({status})", path.display()),
        Err(err) => eprintln!("ruya-store: removing {} failed: {err}", path.display()),
    }
}

/// `appstream.xml.gz`, else `appstream.xml`, in flatpak's `active` directory.
fn read_appstream(active: &Path) -> Option<String> {
    if let Ok(file) = fs::File::open(active.join("appstream.xml.gz")) {
        let mut xml = String::new();
        flate2::read::GzDecoder::new(file)
            .take(256 << 20)
            .read_to_string(&mut xml)
            .ok()?;
        return Some(xml);
    }
    fs::read_to_string(active.join("appstream.xml")).ok()
}

/// Runs `flatpak` with a pseudo-terminal as stdout and stderr: it prints its progress bar only
/// to a terminal. Returns the exit status and the last lines it printed (stdout and stderr are
/// one stream on a terminal). Without a terminal available it runs on pipes, without progress.
fn run_on_terminal(
    args: &[&str],
    on_progress: &mut dyn FnMut(u32, Option<Phase>),
) -> std::io::Result<(std::process::ExitStatus, String)> {
    let mut scanner = ProgressScanner::default();
    let (mut child, master) = match open_terminal() {
        Ok((master, slave)) => {
            let mut cmd = command(args);
            cmd.env("TERM", "xterm")
                .env("NO_COLOR", "1")
                .stdout(Stdio::from(slave.try_clone()?))
                .stderr(Stdio::from(slave));
            // `cmd` (and with it the last copy of the slave) is dropped before reading, or the
            // master would never see the end of the output.
            (cmd.spawn()?, Some(master))
        }
        Err(err) => {
            eprintln!("ruya-store: no pseudo-terminal ({err}), no install progress");
            let mut cmd = command(args);
            cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
            (cmd.spawn()?, None)
        }
    };
    let mut buf = [0u8; 4096];
    if let Some(mut master) = master {
        // EIO when the child has closed the terminal: the end of the output.
        while let Ok(n) = master.read(&mut buf) {
            if n == 0 {
                break;
            }
            scanner.feed(&buf[..n], on_progress);
        }
    } else {
        let mut stderr = child.stderr.take();
        let errors = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            if let Some(pipe) = stderr.as_mut() {
                let _ = pipe.read_to_end(&mut bytes);
            }
            bytes
        });
        if let Some(mut out) = child.stdout.take() {
            while let Ok(n) = out.read(&mut buf) {
                if n == 0 {
                    break;
                }
                scanner.feed(&buf[..n], on_progress);
            }
        }
        let bytes = errors.join().unwrap_or_default();
        scanner.feed(&bytes, on_progress);
    }
    scanner.finish(on_progress);
    let status = child.wait()?;
    Ok((status, scanner.tail()))
}

/// A new pseudo-terminal: the master to read from and the slave to give the child. 200 columns
/// wide, so the progress bar is not squeezed into a default of zero.
fn open_terminal() -> std::io::Result<(fs::File, fs::File)> {
    use rustix::pty::{grantpt, openpt, ptsname, unlockpt, OpenptFlags};
    use rustix::termios::{tcsetwinsize, Winsize};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::OpenOptionsExt;

    let master = openpt(OpenptFlags::RDWR | OpenptFlags::NOCTTY | OpenptFlags::CLOEXEC)?;
    grantpt(&master)?;
    unlockpt(&master)?;
    let name = ptsname(&master, Vec::new())?;
    let slave = fs::OpenOptions::new()
        .read(true)
        .write(true)
        // The service is a session leader: without O_NOCTTY the terminal would become its
        // controlling terminal and closing it would send the service SIGHUP.
        .custom_flags(rustix::fs::OFlags::NOCTTY.bits() as i32)
        .open(std::ffi::OsStr::from_bytes(name.as_bytes()))?;
    tcsetwinsize(
        slave.as_fd(),
        Winsize {
            ws_row: 24,
            ws_col: 200,
            ws_xpixel: 0,
            ws_ypixel: 0,
        },
    )?;
    Ok((fs::File::from(master), slave))
}
