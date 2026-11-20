//! The real [`LaunchOs`] (Linux): std file calls that never follow a link, and child processes in
//! their own process group, so a setup step that runs out of time is killed with everything it
//! started.

use crate::os::{
    join, not_a_folder, too_deep, Command, Exit, Kind, LaunchOs, NotFollowed, MAX_COPY_DEPTH,
};
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
#[derive(Debug, Default)]
pub struct LinuxOs;

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
/// FIFOs and sockets are skipped. `depth` is the folder level of `src` below the copy's root; a
/// tree deeper than [`MAX_COPY_DEPTH`] is refused.
fn copy_node(src: &Path, dst: &Path, depth: usize) -> io::Result<()> {
    if depth > MAX_COPY_DEPTH {
        return Err(too_deep(&src.to_string_lossy()));
    }
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
        // Writable while it fills; the source's mode (a read-only folder too) once it is full.
        fs::set_permissions(dst, fs::Permissions::from_mode(0o700))?;
        for item in fs::read_dir(src)? {
            let item = item?;
            copy_node(&item.path(), &dst.join(item.file_name()), depth + 1)?;
        }
        fs::set_permissions(dst, fs::Permissions::from_mode(meta.mode() & 0o7777))
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

    fn open(&self, base: &str, rel: &str) -> io::Result<Box<dyn Read + '_>> {
        check(base, rel, false)?;
        let path = join(base, rel);
        // A link at the end fails the open itself (ELOOP); the kind is checked on the handle.
        let file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)
            .map_err(|e| match e.raw_os_error() {
                Some(libc::ELOOP) => NotFollowed::error(&path),
                _ => e,
            })?;
        if !file.metadata()?.is_file() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{path} is not a regular file"),
            ));
        }
        Ok(Box::new(file))
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
        copy_node(Path::new(&src), Path::new(&dst), 0)?;
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
        fs::rename(&tmp, &path)?;
        // The rename is durable once its folder is flushed.
        let folder = Path::new(&path).parent().unwrap_or(Path::new(base));
        fs::File::open(folder)?.sync_all()
    }

    fn run(&mut self, cmds: &[Command], timeout: Duration) -> io::Result<(Exit, Duration)> {
        let start = Instant::now();
        let mut groups: Vec<libc::pid_t> = Vec::new();
        let mut last = Exit::Code(0);
        for cmd in cmds {
            let Some((program, args)) = cmd.argv.split_first() else {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, "empty command"));
            };
            let mut child = std::process::Command::new(program)
                .args(args)
                .env_clear()
                .envs(&cmd.env)
                .current_dir(&cmd.cwd)
                .stdin(Stdio::null())
                .process_group(0)
                .spawn()?;
            groups.extend(libc::pid_t::try_from(child.id()).ok());
            last = loop {
                if let Some(status) = child.try_wait()? {
                    break match (status.code(), status.signal()) {
                        (Some(c), _) => Exit::Code(c),
                        (None, Some(s)) => Exit::Signal(s),
                        (None, None) => Exit::Code(-1),
                    };
                }
                if start.elapsed() >= timeout {
                    // Each command leads its own group: the kill reaches what any of them
                    // started (the step's programs while a later wait runs, too).
                    for pgid in &groups {
                        // SAFETY: kill(2) takes plain integers; a negative pid names the group.
                        unsafe { libc::kill(-pgid, libc::SIGKILL) };
                    }
                    let _ = child.wait();
                    return Ok((Exit::TimedOut, start.elapsed()));
                }
                thread::sleep(POLL);
            };
            if last != Exit::Code(0) {
                break;
            }
        }
        Ok((last, start.elapsed()))
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::os::AppSource;
    use ruya_play_format::Source;

    fn tmp() -> (tempfile::TempDir, String) {
        let d = tempfile::tempdir().expect("a temporary folder");
        let p = d.path().to_str().expect("UTF-8 temp path").to_string();
        (d, p)
    }

    #[test]
    fn a_read_only_folder_is_copied_with_its_mode() {
        let (_d, base) = tmp();
        let mut os = LinuxOs;
        fs::create_dir_all(format!("{base}/t/ro")).unwrap();
        fs::write(format!("{base}/t/ro/f"), "x").unwrap();
        fs::set_permissions(format!("{base}/t/ro"), fs::Permissions::from_mode(0o555)).unwrap();
        assert!(os.copy(&base, "t", &base, "c").unwrap());
        assert_eq!(fs::read_to_string(format!("{base}/c/ro/f")).unwrap(), "x");
        let mode = fs::metadata(format!("{base}/c/ro")).unwrap().mode() & 0o777;
        assert_eq!(mode, 0o555);
        // Let the temporary folder be removed.
        for p in ["t/ro", "c/ro"] {
            fs::set_permissions(format!("{base}/{p}"), fs::Permissions::from_mode(0o755)).unwrap();
        }
    }

    #[test]
    fn a_tree_deeper_than_the_cap_is_refused() {
        let (_d, base) = tmp();
        let mut os = LinuxOs;
        let deep = vec!["d"; MAX_COPY_DEPTH + 1].join("/");
        fs::create_dir_all(format!("{base}/t/{deep}")).unwrap();
        let e = os.copy(&base, "t", &base, "c").unwrap_err();
        assert!(e.to_string().contains("folders deep"), "{e}");
        let ok = vec!["d"; MAX_COPY_DEPTH].join("/");
        fs::create_dir_all(format!("{base}/u/{ok}")).unwrap();
        assert!(os.copy(&base, "u", &base, "v").unwrap());
    }

    #[test]
    fn reads_and_writes_refuse_a_linked_folder() {
        let (_d, base) = tmp();
        let mut os = LinuxOs;
        fs::create_dir_all(format!("{base}/elsewhere")).unwrap();
        fs::write(format!("{base}/elsewhere/state.json"), "{}").unwrap();
        std::os::unix::fs::symlink(format!("{base}/elsewhere"), format!("{base}/.ruya-play"))
            .unwrap();
        let e = AppSource::new(&os, &base)
            .open(".ruya-play/state.json")
            .err()
            .expect("refused");
        assert!(NotFollowed::is(&e), "{e}");
        let e = os
            .write_atomic(&base, ".ruya-play/state.json", b"x")
            .unwrap_err();
        assert!(NotFollowed::is(&e), "{e}");
        // A link at the end is refused too.
        std::os::unix::fs::symlink(format!("{base}/elsewhere/state.json"), format!("{base}/s"))
            .unwrap();
        let e = os.open(&base, "s").err().expect("refused");
        assert!(NotFollowed::is(&e), "{e}");
        assert_eq!(
            fs::read_to_string(format!("{base}/elsewhere/state.json")).unwrap(),
            "{}"
        );
    }

    #[test]
    fn a_timed_out_wait_kills_the_steps_group_too() {
        let (_d, base) = tmp();
        let mut os = LinuxOs;
        let pidfile = format!("{base}/pid");
        let env: std::collections::BTreeMap<String, String> =
            [("PATH".to_string(), "/usr/bin:/bin".to_string())].into();
        let sh = |script: &str| Command {
            argv: vec!["/bin/sh".into(), "-c".into(), script.into()],
            env: env.clone(),
            cwd: base.clone(),
        };
        // The step leaves a child behind in its group and exits 0; the wait hangs.
        let step = sh(&format!("sleep 30 & echo $! > {pidfile}"));
        let wait = sh("sleep 30");
        let (exit, took) = os.run(&[step, wait], Duration::from_millis(500)).unwrap();
        assert_eq!(exit, Exit::TimedOut);
        assert!(took < Duration::from_secs(10));
        let pid: libc::pid_t = fs::read_to_string(&pidfile)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        thread::sleep(Duration::from_millis(200));
        // SAFETY: signal 0 only asks whether the process exists.
        let alive = unsafe { libc::kill(pid, 0) } == 0;
        let zombie = fs::read_to_string(format!("/proc/{pid}/stat"))
            .map(|s| s.contains(") Z "))
            .unwrap_or(true);
        assert!(!alive || zombie, "the step's child {pid} still runs");
    }
}
