//! The real [`LaunchOs`] (Linux): std file calls that never follow a link, and child processes in
//! their own process group, so a setup step that runs out of time is killed with everything it
//! started.

use crate::os::{join, not_a_folder, Command, Exit, Kind, LaunchOs, NotFollowed};
use ruya_play_format::{FolderSource, Source};
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::Path;
use std::process::Stdio;
use std::thread;
use std::time::{Duration, Instant};

/// How often a running setup step is checked.
const POLL: Duration = Duration::from_millis(100);

/// The sandbox's file system and processes.
pub struct LinuxOs {
    // Opens a regular file without following a link at its end (the format crate's reader).
    files: FolderSource,
}

impl Default for LinuxOs {
    fn default() -> Self {
        LinuxOs {
            files: FolderSource::new("/"),
        }
    }
}

fn kind_of(ft: fs::FileType) -> Kind {
    if ft.is_symlink() {
        Kind::Link
    } else if ft.is_dir() {
        Kind::Dir
    } else if ft.is_file() {
        Kind::File
    } else {
        Kind::Other
    }
}

/// The parts of `rel`; `.` and `..` are refused.
fn parts(rel: &str) -> io::Result<Vec<&str>> {
    let p: Vec<&str> = rel.split('/').filter(|c| !c.is_empty()).collect();
    if p.iter().any(|c| *c == "." || *c == "..") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{rel} is not a plain path"),
        ));
    }
    Ok(p)
}

/// Every folder of `base/rel` below `base` (the last part too when `last`) is a folder, not a link.
fn check(base: &str, rel: &str, last: bool) -> io::Result<()> {
    let p = parts(rel)?;
    let n = if last {
        p.len()
    } else {
        p.len().saturating_sub(1)
    };
    let mut cur = base.to_string();
    for part in &p[..n] {
        cur = join(&cur, part);
        if !is_folder(&cur)? {
            return Ok(());
        }
    }
    Ok(())
}

/// True for a folder, false when nothing is there; a link is [`NotFollowed`], a file an error.
fn is_folder(path: &str) -> io::Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(m) if m.file_type().is_dir() => Ok(true),
        Ok(m) if m.file_type().is_symlink() => Err(NotFollowed::error(path)),
        Ok(_) => Err(not_a_folder(path)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

/// Remove whatever is at `path` (a link itself, never its target).
fn clear(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(m) if m.file_type().is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

/// Copy one node: a link as a link, a folder with its content, a file's bytes and mode. Devices,
/// FIFOs and sockets are skipped.
fn copy_node(src: &Path, dst: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(src)?;
    let ft = meta.file_type();
    if ft.is_symlink() {
        let target = fs::read_link(src)?;
        clear(dst)?;
        std::os::unix::fs::symlink(target, dst)
    } else if ft.is_dir() {
        match fs::symlink_metadata(dst) {
            Ok(m) if m.file_type().is_dir() => {}
            _ => {
                clear(dst)?;
                fs::create_dir(dst)?;
            }
        }
        fs::set_permissions(dst, fs::Permissions::from_mode(meta.mode() & 0o7777))?;
        for item in fs::read_dir(src)? {
            let item = item?;
            copy_node(&item.path(), &dst.join(item.file_name()))?;
        }
        Ok(())
    } else if ft.is_file() {
        let mut from = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(src)?;
        clear(dst)?;
        let mut to = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(meta.mode() & 0o777)
            .open(dst)?;
        io::copy(&mut from, &mut to)?;
        Ok(())
    } else {
        Ok(())
    }
}

impl LaunchOs for LinuxOs {
    fn kind(&self, path: &str) -> Option<Kind> {
        fs::symlink_metadata(path)
            .ok()
            .map(|m| kind_of(m.file_type()))
    }

    fn list(&self, path: &str) -> io::Result<Vec<(String, Kind)>> {
        let mut out = Vec::new();
        for item in fs::read_dir(path)? {
            let item = item?;
            let Ok(name) = item.file_name().into_string() else {
                continue;
            };
            out.push((name, kind_of(item.file_type()?)));
        }
        Ok(out)
    }

    fn open(&self, path: &str) -> io::Result<Box<dyn Read + '_>> {
        self.files.open(path)
    }

    fn make_dirs(&mut self, base: &str, rel: &str) -> io::Result<()> {
        let mut cur = base.to_string();
        for part in parts(rel)? {
            cur = join(&cur, part);
            if is_folder(&cur)? {
                continue;
            }
            match fs::create_dir(&cur) {
                Ok(()) => {}
                // Made by someone else in between: it must still be a folder.
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                    is_folder(&cur)?;
                }
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }

    fn copy(
        &mut self,
        src_base: &str,
        src_rel: &str,
        dst_base: &str,
        dst_rel: &str,
    ) -> io::Result<bool> {
        check(src_base, src_rel, false)?;
        let src = join(src_base, src_rel);
        match fs::symlink_metadata(&src) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(false),
            Err(e) => return Err(e),
            Ok(_) => {}
        }
        let dst = self.make_parent(dst_base, dst_rel)?;
        copy_node(Path::new(&src), Path::new(&dst))?;
        Ok(true)
    }

    fn remove(&mut self, base: &str, rel: &str) -> io::Result<()> {
        check(base, rel, false)?;
        clear(Path::new(&join(base, rel)))
    }

    fn symlink(&mut self, target: &str, base: &str, rel: &str) -> io::Result<()> {
        let path = self.make_parent(base, rel)?;
        clear(Path::new(&path))?;
        std::os::unix::fs::symlink(target, path)
    }

    fn write_atomic(&mut self, base: &str, rel: &str, bytes: &[u8]) -> io::Result<()> {
        let path = self.make_parent(base, rel)?;
        let tmp = format!("{path}.tmp");
        clear(Path::new(&tmp))?;
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        fs::rename(&tmp, &path)
    }

    fn run(&mut self, cmd: &Command, timeout: Duration) -> io::Result<(Exit, Duration)> {
        let Some((program, args)) = cmd.argv.split_first() else {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "empty command"));
        };
        let start = Instant::now();
        let mut child = std::process::Command::new(program)
            .args(args)
            .env_clear()
            .envs(&cmd.env)
            .current_dir(&cmd.cwd)
            .stdin(Stdio::null())
            .process_group(0)
            .spawn()?;
        loop {
            if let Some(status) = child.try_wait()? {
                let exit = match (status.code(), status.signal()) {
                    (Some(c), _) => Exit::Code(c),
                    (None, Some(s)) => Exit::Signal(s),
                    (None, None) => Exit::Code(-1),
                };
                return Ok((exit, start.elapsed()));
            }
            if start.elapsed() >= timeout {
                // The child leads its own group: the kill reaches what it started too.
                if let Ok(pgid) = libc::pid_t::try_from(child.id()) {
                    // SAFETY: kill(2) takes plain integers; a negative pid names the group.
                    unsafe { libc::kill(-pgid, libc::SIGKILL) };
                }
                let _ = child.wait();
                return Ok((Exit::TimedOut, start.elapsed()));
            }
            thread::sleep(POLL);
        }
    }

    fn log(&self, line: &str) {
        eprintln!("ruya-play-launch: {line}");
    }
}

/// Replace this process with `cmd` (no shell). Returns only when that fails.
pub fn exec(cmd: &Command) -> io::Error {
    let Some((program, args)) = cmd.argv.split_first() else {
        return io::Error::new(io::ErrorKind::InvalidInput, "empty command");
    };
    std::process::Command::new(program)
        .args(args)
        .env_clear()
        .envs(&cmd.env)
        .current_dir(&cmd.cwd)
        .exec()
}
