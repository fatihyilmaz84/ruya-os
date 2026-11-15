//! A child process with a time limit and its stdout captured (used by `systemd`, which is
//! Linux-only; kept here so its tests run on every host).

use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Runs `args` with its stdout captured, for at most `limit` (then it is killed). The output on
/// success; `None` (logged) on a failure or a timeout. The output is read while the child runs,
/// so an answer larger than the pipe buffer never blocks it.
pub(crate) fn run_bounded(args: &[String], limit: Duration) -> Option<String> {
    match run_bounded_status(args, limit)? {
        (true, out) => Some(out),
        (false, _) => None,
    }
}

/// Like `run_bounded`, but a child that exits non-zero still gives its output: `(success,
/// stdout)`. `None` only when it could not be run or did not exit in time.
pub(crate) fn run_bounded_status(args: &[String], limit: Duration) -> Option<(bool, String)> {
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
    let reader = child.stdout.take().map(|mut stdout| {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = stdout.read_to_end(&mut bytes);
            String::from_utf8_lossy(&bytes).into_owned()
        })
    });
    let collect = |reader: Option<std::thread::JoinHandle<String>>| {
        reader.and_then(|r| r.join().ok()).unwrap_or_default()
    };
    let deadline = Instant::now() + limit;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let out = collect(reader);
                if !status.success() {
                    eprintln!("ruya-session: {what} failed: {status}");
                }
                return Some((status.success(), out));
            }
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = collect(reader);
                eprintln!("ruya-session: {what}: no answer in {} s", limit.as_secs());
                return None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(err) => {
                eprintln!("ruya-session: {what}: {err}");
                let _ = child.kill();
                let _ = child.wait();
                let _ = collect(reader);
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
                    out.write_all(&chunk).unwrap();
                }
                out.flush().unwrap();
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
            std::env::current_exe().unwrap().to_string_lossy().into_owned(),
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
    }
}
