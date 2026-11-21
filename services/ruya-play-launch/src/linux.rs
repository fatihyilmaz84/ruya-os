//! The real [`LaunchOs`] (Linux): file calls through ruya-fs, which walks every path below its
//! trusted base with one folder handle per step and never follows a link (RUY-911), and child
//! processes in their own process group, so a setup step that runs out of time is killed with
//! everything it started.

use crate::os::{Command, Exit, Kind, LaunchOs, MAX_COPY_DEPTH};
use ruya_fs::Dir;
use std::io::{self, Read};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::thread;
use std::time::{Duration, Instant};

/// How often a running setup step is checked.
const POLL: Duration = Duration::from_millis(100);

/// The sandbox's file system and processes.
#[derive(Debug, Default)]
pub struct LinuxOs;

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

/// `rel` as a path for ruya-fs ([`parts`]: `.` and `..` refused, empty parts dropped).
fn rel_path(rel: &str) -> io::Result<PathBuf> {
    Ok(parts(rel)?.into_iter().collect())
}

/// The trusted folder `base` (the data folder, `/app`); everything below it is walked by ruya-fs,
/// one folder handle per step, so no link below it is followed (RUY-911).
fn base_dir(base: &str) -> io::Result<Dir> {
    Dir::open(Path::new(base))
}

fn missing(e: &io::Error) -> bool {
    e.kind() == io::ErrorKind::NotFound
}

impl LaunchOs for LinuxOs {
    fn kind(&self, base: &str, rel: &str) -> Option<Kind> {
        base_dir(base)
            .and_then(|d| d.kind(&rel_path(rel)?))
            .ok()
            .flatten()
    }

    fn list(&self, base: &str, rel: &str) -> io::Result<Vec<(String, Kind)>> {
        let entries = base_dir(base)?.entries(&rel_path(rel)?)?;
        Ok(entries
            .into_iter()
            .filter_map(|(name, kind)| Some((name.into_string().ok()?, kind)))
            .collect())
    }

    fn open(&self, base: &str, rel: &str) -> io::Result<Box<dyn Read + '_>> {
        Ok(Box::new(base_dir(base)?.open_file(&rel_path(rel)?)?))
    }

    fn make_dirs(&mut self, base: &str, rel: &str) -> io::Result<()> {
        base_dir(base)?.make_dirs(&rel_path(rel)?).map(drop)
    }

    fn copy(
        &mut self,
        src_base: &str,
        src_rel: &str,
        dst_base: &str,
        dst_rel: &str,
    ) -> io::Result<bool> {
        let src = match base_dir(src_base) {
            Err(e) if missing(&e) => return Ok(false),
            r => r?,
        };
        src.copy(
            &rel_path(src_rel)?,
            &base_dir(dst_base)?,
            &rel_path(dst_rel)?,
            MAX_COPY_DEPTH,
        )
    }

    fn remove(&mut self, base: &str, rel: &str) -> io::Result<()> {
        match base_dir(base) {
            Err(e) if missing(&e) => Ok(()),
            r => r?.remove(&rel_path(rel)?, MAX_COPY_DEPTH),
        }
    }

    fn symlink(&mut self, target: &str, base: &str, rel: &str) -> io::Result<()> {
        base_dir(base)?.symlink(Path::new(target), &rel_path(rel)?, MAX_COPY_DEPTH)
    }

    fn write_atomic(&mut self, base: &str, rel: &str, bytes: &[u8]) -> io::Result<()> {
        base_dir(base)?.write(&rel_path(rel)?, bytes)
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
    use crate::os::{AppSource, NotFollowed};
    use ruya_play_format::Source;
    use std::fs;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

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
        // A later rebuild removes the copy, read-only folder and all; so does the source.
        os.remove(&base, "c").unwrap();
        os.remove(&base, "t").unwrap();
        assert!(!Path::new(&format!("{base}/c")).exists());
        assert!(!Path::new(&format!("{base}/t")).exists());
    }

    #[test]
    fn remove_takes_a_link_away_not_its_target() {
        let (_d, base) = tmp();
        let mut os = LinuxOs;
        fs::create_dir_all(format!("{base}/keep/ro")).unwrap();
        fs::write(format!("{base}/keep/ro/f"), "x").unwrap();
        fs::set_permissions(format!("{base}/keep/ro"), fs::Permissions::from_mode(0o555)).unwrap();
        fs::create_dir_all(format!("{base}/p")).unwrap();
        std::os::unix::fs::symlink(format!("{base}/keep"), format!("{base}/p/l")).unwrap();
        os.remove(&base, "p").unwrap();
        assert!(!Path::new(&format!("{base}/p")).exists());
        assert_eq!(
            fs::read_to_string(format!("{base}/keep/ro/f")).unwrap(),
            "x"
        );
        let mode = fs::metadata(format!("{base}/keep/ro")).unwrap().mode() & 0o777;
        assert_eq!(mode, 0o555, "the target's mode is untouched");
        fs::set_permissions(format!("{base}/keep/ro"), fs::Permissions::from_mode(0o755)).unwrap();
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
