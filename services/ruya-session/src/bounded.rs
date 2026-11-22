//! A child process with a time limit and its stdout captured (used by `systemd`, which is
//! Linux-only; kept here so its tests run on every host).

use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// The most stdout any child may give (`systemctl show` of many units is a few hundred KiB at
/// most): more is refused, so no child makes this root service buffer without limit.
pub(crate) const MAX_OUTPUT: usize = 4 * 1024 * 1024;

/// How a bounded child ended: its exit code (`None` when a signal ended it) and its stdout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Ran {
    pub code: Option<i32>,
    pub out: String,
}

/// Runs `args` with its stdout captured, for at most `limit` (then it is killed). The output on
/// success; `None` (logged) on a failure or a timeout. The output is read while the child runs,
/// so an answer larger than the pipe buffer never blocks it; more than `MAX_OUTPUT` is refused.
pub(crate) fn run_bounded(args: &[String], limit: Duration) -> Option<String> {
    match run_bounded_status(args, limit)? {
        (true, out) => Some(out),
        (false, _) => {
            eprintln!("ruya-session: {} failed", args.join(" "));
            None
        }
    }
}

/// Like `run_bounded`, but a child that exits non-zero still gives its output: `(success,
/// stdout)`. `None` only when it could not be run or did not exit in time (both logged). A
/// non-zero exit is not logged: the caller decides what it means.
pub(crate) fn run_bounded_status(args: &[String], limit: Duration) -> Option<(bool, String)> {
    run_capped(args, limit, MAX_OUTPUT).map(|ran| (ran.code == Some(0), ran.out))
}

/// The child of `run_bounded_status` with its exit code, and with at most `cap` bytes of stdout:
/// a child that writes more is refused (`None`, logged), whatever its exit; the reader stops at
/// the cap, so a child that goes on writing ends on the closed pipe or at `limit`. A helper that
/// runs as a profile user (`steam-probe`) is read with a small cap.
pub(crate) fn run_capped(args: &[String], limit: Duration, cap: usize) -> Option<Ran> {
    let what = args.join(" ");
    let mut child = match Command::new(&args[0])
        .args(&args[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
    {
        Ok(child) => child,
        Err(err) => {
            eprintln!("ruya-session: {what}: {err}");
            return None;
        }
    };
    let reader = child.stdout.take().map(|stdout| {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            // One byte past the cap tells a full answer from one that is too long.
            let _ = stdout.take(cap as u64 + 1).read_to_end(&mut bytes);
            bytes
        })
    });
    let collect = |reader: Option<std::thread::JoinHandle<Vec<u8>>>| {
        reader.and_then(|r| r.join().ok()).unwrap_or_default()
    };
    let deadline = Instant::now() + limit;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let bytes = collect(reader);
                if bytes.len() > cap {
                    eprintln!("ruya-session: {what}: more than {cap} bytes of output, refused");
                    return None;
                }
                return Some(Ran {
                    code: status.code(),
                    out: String::from_utf8_lossy(&bytes).into_owned(),
                });
            }
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                // The output is thrown away: the reader is detached, not joined (a grandchild
                // holding the pipe open must not hold us up).
                drop(reader);
                eprintln!("ruya-session: {what}: no answer in {} s", limit.as_secs());
                return None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(err) => {
                eprintln!("ruya-session: {what}: {err}");
                let _ = child.kill();
                let _ = child.wait();
                drop(reader);
                return None;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The test binary re-invoked as the child (portable): `RUYA_BOUNDED_CHILD` picks what it does.
    #[test]
    fn child_entry() {
        // Only a re-invoked child acts; this process, which set the variable, must not.
        let parent = std::env::var("RUYA_BOUNDED_PARENT").ok();
        if parent.as_deref() == Some(std::process::id().to_string().as_str()) {
            return;
        }
        match std::env::var("RUYA_BOUNDED_CHILD").as_deref() {
            Ok("big") => {
                use std::io::Write;
                let chunk = vec![b'x'; 1024];
                let mut out = std::io::stdout().lock();
                for _ in 0..300 {
                    // A reader that stopped at its cap closes the pipe: end quietly.
                    if out.write_all(&chunk).is_err() {
                        return;
                    }
                }
                let _ = out.flush();
            }
            Ok("hang") => std::thread::sleep(Duration::from_secs(60)),
            Ok("fail") => {
                println!("inactive");
                std::process::exit(3);
            }
            _ => {}
        }
    }

    fn child(mode: &str) -> Vec<String> {
        // Not `env`: the mode rides in the environment of this process, set before the spawn.
        std::env::set_var("RUYA_BOUNDED_PARENT", std::process::id().to_string());
        std::env::set_var("RUYA_BOUNDED_CHILD", mode);
        vec![
            std::env::current_exe()
                .unwrap()
                .to_string_lossy()
                .into_owned(),
            "--exact".into(),
            "bounded::tests::child_entry".into(),
            "--nocapture".into(),
        ]
    }

    // One test, so the env var is never set by two at once.
    #[test]
    fn captures_big_output_kills_hanging_child_and_keeps_failed_output() {
        let started = Instant::now();
        let out = run_bounded(&child("big"), Duration::from_secs(20)).expect("big answer");
        assert_eq!(out.matches('x').count(), 300 * 1024);
        assert!(started.elapsed() < Duration::from_secs(15), "took too long");

        let started = Instant::now();
        assert!(run_bounded(&child("hang"), Duration::from_millis(500)).is_none());
        assert!(started.elapsed() < Duration::from_secs(10));

        let (ok, out) = run_bounded_status(&child("fail"), Duration::from_secs(20)).unwrap();
        assert!(!ok);
        assert!(out.contains("inactive"));
        assert!(run_bounded(&child("fail"), Duration::from_secs(20)).is_none());
        // The exit code comes through.
        let ran = run_capped(&child("fail"), Duration::from_secs(20), 1024).unwrap();
        assert_eq!(ran.code, Some(3));

        // An answer over the cap is refused, quickly (the reader stops at the cap).
        let started = Instant::now();
        assert!(run_capped(&child("big"), Duration::from_secs(20), 64 * 1024).is_none());
        assert!(started.elapsed() < Duration::from_secs(15), "took too long");
        let ran = run_capped(&child("big"), Duration::from_secs(20), 1024 * 1024).unwrap();
        assert_eq!(
            ran.out.matches('x').count(),
            300 * 1024,
            "under the cap is whole"
        );
    }
}
