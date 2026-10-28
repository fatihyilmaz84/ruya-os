//! The real `flatpak` command (Linux). Everything here is system-wide (`--system`, as root) and
//! non-interactive. The text it prints is parsed in `flatpak.rs`; this file starts the processes.

use std::fs;
use std::io::Read;
use std::os::unix::fs::MetadataExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;

use crate::app::{valid_app_id, valid_remote_name};
use crate::flatpak::{
    classify_error, parse_ids, parse_installed, parse_progress, parse_remote_ls, parse_remotes,
    Appstream, Flatpak, FlatpakError, InstalledApp, Operation, Progress, RemoteApp, RemoteInfo,
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
                vec!["install", "--system", "--noninteractive", "-y", remote, id]
            }
            Operation::Uninstall { id, .. } => {
                vec!["uninstall", "--system", "--noninteractive", "-y", id]
            }
            Operation::Update { id } => vec!["update", "--system", "--noninteractive", "-y", id],
            Operation::Rollback { id, commit } => {
                commit_arg = format!("--commit={commit}");
                vec![
                    "update",
                    "--system",
                    "--noninteractive",
                    "-y",
                    &commit_arg,
                    id,
                ]
            }
        };
        if !valid_app_id(op.app()) {
            return Err(FlatpakError::Other("refused argument".to_owned()));
        }

        let mut child = command(&args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| FlatpakError::Other(format!("flatpak: {e}")))?;
        let mut stderr = child.stderr.take();
        // stderr is read on its own thread, or a full pipe would stop the command.
        let errors = thread::spawn(move || {
            let mut text = String::new();
            if let Some(pipe) = stderr.as_mut() {
                let mut bytes = Vec::new();
                let _ = pipe.read_to_end(&mut bytes);
                text = String::from_utf8_lossy(&bytes).into_owned();
            }
            text
        });

        // Progress lines end in \r (a redrawn line) or \n.
        let mut seen = String::new();
        if let Some(mut out) = child.stdout.take() {
            let mut buf = [0u8; 4096];
            let mut line = Vec::new();
            loop {
                let n = match out.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                for &byte in &buf[..n] {
                    if byte == b'\r' || byte == b'\n' {
                        let text = String::from_utf8_lossy(&line).into_owned();
                        if let Some((percent, phase)) = parse_progress(&text) {
                            progress(Progress {
                                percent,
                                phase: phase.unwrap_or_else(|| op.phase()),
                            });
                        }
                        seen = text;
                        line.clear();
                    } else if line.len() < 4096 {
                        line.push(byte);
                    }
                }
            }
        }
        let status = child
            .wait()
            .map_err(|e| FlatpakError::Other(format!("flatpak: {e}")))?;
        let stderr = errors.join().unwrap_or_default();
        if !status.success() {
            return Err(classify_error(if stderr.trim().is_empty() {
                &seen
            } else {
                &stderr
            }));
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
