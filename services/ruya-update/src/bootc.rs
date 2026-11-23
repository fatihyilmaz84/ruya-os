//! The `bootc` command behind a trait, the reading of its `status --json` and of its
//! `--progress-fd` events, the stopping of a running pull, and a fake for tests and `--session`
//! development.

use std::process::Command;
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex};

/// One deployment of `bootc status`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Deployment {
    /// Full reference, e.g. `registry:5000/ruyaos:stable`.
    pub image: String,
    /// The image's version label, "" when it has none.
    pub version: String,
    pub digest: String,
}

impl Deployment {
    /// The tag of `image`, "" without one.
    pub fn tag(&self) -> &str {
        tag_of(&self.image)
    }

    /// What the user sees: the version label, else the tag.
    pub fn label(&self) -> String {
        if self.version.is_empty() {
            self.tag().to_owned()
        } else {
            self.version.clone()
        }
    }
}

/// The tag of an image reference: after the last `:` that follows the last `/`.
pub fn tag_of(image: &str) -> &str {
    let name = image.rsplit('/').next().unwrap_or(image);
    // A digest reference (`name@sha256:...`) has no tag.
    if name.contains('@') {
        return "";
    }
    name.rsplit_once(':').map_or("", |(_, tag)| tag)
}

/// `image` with its tag replaced by `tag`.
pub fn with_tag(image: &str, tag: &str) -> String {
    let old = tag_of(image);
    let base = if old.is_empty() {
        image
    } else {
        &image[..image.len() - old.len() - 1]
    };
    format!("{base}:{tag}")
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HostStatus {
    /// The image the host tracks (`spec.image`).
    pub tracked: String,
    pub booted: Option<Deployment>,
    pub staged: Option<Deployment>,
    pub rollback: Option<Deployment>,
    pub rollback_queued: bool,
    /// What the last `upgrade --check` found for the booted image (`cachedUpdate`).
    pub cached_update: Option<Deployment>,
}

/// What a download runs: `bootc upgrade` (the tracked tag), or `bootc switch <image>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pull {
    Upgrade,
    Switch(String),
}

/// How a `pull` ended without an error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PullEnd {
    /// bootc finished: the image is staged (`status` says what it staged).
    Done,
    /// It was stopped through its `Stop` (SIGTERM): fully fetched layers stay in the repository.
    Stopped,
}

pub trait Bootc: Send + Sync {
    fn status(&self) -> Result<HostStatus, String>;
    /// `bootc upgrade --check`: asks the registry about the tracked tag.
    fn check(&self) -> Result<(), String>;
    /// `bootc upgrade` or `bootc switch <image>` with `--progress-fd`: stages the image, handing
    /// every progress event to `on_progress` as it arrives. `stop` ends it early (`Stopped`),
    /// also when it was requested before the command started.
    fn pull(
        &self,
        target: &Pull,
        stop: &Stop,
        on_progress: &mut dyn FnMut(Progress),
    ) -> Result<PullEnd, String>;
    /// `bootc rollback`.
    fn rollback(&self) -> Result<(), String>;
}

impl Bootc for Box<dyn Bootc> {
    fn status(&self) -> Result<HostStatus, String> {
        (**self).status()
    }
    fn check(&self) -> Result<(), String> {
        (**self).check()
    }
    fn pull(
        &self,
        target: &Pull,
        stop: &Stop,
        on_progress: &mut dyn FnMut(Progress),
    ) -> Result<PullEnd, String> {
        (**self).pull(target, stop, on_progress)
    }
    fn rollback(&self) -> Result<(), String> {
        (**self).rollback()
    }
}

// ---- stopping a running pull --------------------------------------------------------

#[derive(Debug, Default)]
struct StopState {
    requested: bool,
    /// The running bootc, while it has not been waited for (so its pid cannot be reused).
    pid: Option<u32>,
}

/// Stops one pull: shared by the job that runs it and the call that pauses or cancels it.
#[derive(Debug, Clone, Default)]
pub struct Stop(Arc<(Mutex<StopState>, Condvar)>);

impl Stop {
    fn state(&self) -> std::sync::MutexGuard<'_, StopState> {
        self.0 .0.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Ends the pull: SIGTERM to a running bootc (it stops at once and keeps the layers it has
    /// fully fetched); a pull that has not started yet does not start.
    pub fn request(&self) {
        let mut state = self.state();
        state.requested = true;
        if let Some(pid) = state.pid {
            terminate(pid);
        }
        self.0 .1.notify_all();
    }

    pub fn is_requested(&self) -> bool {
        self.state().requested
    }

    /// Blocks until a stop is requested (the fake host's held pull).
    pub fn wait(&self) {
        let mut state = self.state();
        while !state.requested {
            state = self.0 .1.wait(state).unwrap_or_else(|e| e.into_inner());
        }
    }

    /// `pid` is the bootc to stop from now on; stopped at once when a stop came first.
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    fn attach(&self, pid: u32) {
        let mut state = self.state();
        state.pid = Some(pid);
        if state.requested {
            terminate(pid);
        }
    }

    /// Called before the process is waited for: from then on its pid may belong to another.
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    fn detach(&self) {
        self.state().pid = None;
    }
}

#[cfg(target_os = "linux")]
fn terminate(pid: u32) {
    let Ok(pid) = libc::pid_t::try_from(pid) else {
        return;
    };
    // SAFETY: kill takes plain integers. `pid` is a child that has not been waited for (Stop
    // detaches it before the wait), so it names our bootc and no other process.
    unsafe {
        libc::kill(pid, libc::SIGTERM);
    }
}

#[cfg(not(target_os = "linux"))]
fn terminate(_pid: u32) {}

// ---- bootc --progress-fd --------------------------------------------------------------

/// One event of `bootc upgrade|switch --progress-fd` that the service uses (bootc 1.17.1; the
/// recorded run is `tests/fixtures/bootc-progress-0.0.105-to-0.0.106.jsonl`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Progress {
    /// Layers being fetched. `bytes`: fetched by this run so far; `bytes_total`: what this run
    /// has to fetch; `bytes_cached`: what the machine already has. `steps*`: the same in layers.
    Bytes {
        bytes: u64,
        bytes_total: u64,
        bytes_cached: u64,
        steps: u64,
        steps_total: u64,
        steps_cached: u64,
    },
    /// A phase without bytes (the import, the deploy): `steps` of `steps_total` done.
    Steps {
        task: String,
        steps: u64,
        steps_total: u64,
    },
}

/// One line of `--progress-fd`: `Ok(None)` for an event the service does not use ("Start", and
/// any type a later bootc adds), `Err` for a line that is not such an event (the job goes on).
pub fn parse_progress(line: &str) -> Result<Option<Progress>, String> {
    let v: serde_json::Value =
        serde_json::from_str(line).map_err(|e| format!("bootc progress: {e}"))?;
    let kind = v
        .get("type")
        .and_then(|t| t.as_str())
        .ok_or("bootc progress: an event without a type")?;
    let num = |key: &str| {
        v.get(key)
            .and_then(|n| n.as_u64())
            .ok_or_else(|| format!("bootc progress: {kind} without {key}"))
    };
    match kind {
        "ProgressBytes" => Ok(Some(Progress::Bytes {
            bytes: num("bytes")?,
            bytes_total: num("bytesTotal")?,
            bytes_cached: num("bytesCached")?,
            steps: num("steps")?,
            steps_total: num("stepsTotal")?,
            steps_cached: num("stepsCached")?,
        })),
        "ProgressSteps" => Ok(Some(Progress::Steps {
            task: v
                .get("task")
                .or_else(|| v.get("description"))
                .and_then(|t| t.as_str())
                .unwrap_or("")
                .to_owned(),
            steps: num("steps")?,
            steps_total: num("stepsTotal")?,
        })),
        _ => Ok(None),
    }
}

// ---- bootc status --json ------------------------------------------------------------

/// `v` is an image status: `{ "image": {"image": ref, "transport": ..}, "version", "imageDigest" }`.
fn image_status(v: &serde_json::Value) -> Option<Deployment> {
    Some(Deployment {
        image: v.get("image")?.get("image")?.as_str()?.to_owned(),
        version: v
            .get("version")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_owned(),
        digest: v
            .get("imageDigest")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_owned(),
    })
}

/// `v` is a boot entry: `{ "image": <image status>, "cachedUpdate": <image status>, .. }`.
fn deployment(v: &serde_json::Value) -> Option<Deployment> {
    image_status(v.get("image")?)
}

/// Reads the output of `bootc status --json`.
pub fn parse_status(json: &str) -> Result<HostStatus, String> {
    let root: serde_json::Value =
        serde_json::from_str(json).map_err(|e| format!("bootc status: {e}"))?;
    let status = root
        .get("status")
        .ok_or("bootc status: no `status` object")?;
    Ok(HostStatus {
        tracked: root
            .pointer("/spec/image/image")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_owned(),
        booted: status.get("booted").and_then(deployment),
        staged: status.get("staged").and_then(deployment),
        rollback: status.get("rollback").and_then(deployment),
        rollback_queued: status
            .get("rollbackQueued")
            .and_then(|b| b.as_bool())
            .unwrap_or(false),
        cached_update: status
            .get("booted")
            .and_then(|b| b.get("cachedUpdate"))
            .and_then(image_status),
    })
}

// ---- the real command ---------------------------------------------------------------

pub struct BootcCli;

impl BootcCli {
    fn run(args: &[&str]) -> Result<String, String> {
        let out = Command::new("bootc")
            .args(args)
            .output()
            .map_err(|e| format!("bootc: {e}"))?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            Err(format!(
                "bootc {}: {}",
                args.join(" "),
                last_line(&out.stderr)
            ))
        }
    }
}

impl Bootc for BootcCli {
    fn status(&self) -> Result<HostStatus, String> {
        parse_status(&Self::run(&["status", "--json"])?)
    }
    fn check(&self) -> Result<(), String> {
        Self::run(&["upgrade", "--check"]).map(|_| ())
    }
    fn pull(
        &self,
        target: &Pull,
        stop: &Stop,
        on_progress: &mut dyn FnMut(Progress),
    ) -> Result<PullEnd, String> {
        if stop.is_requested() {
            return Ok(PullEnd::Stopped);
        }
        let mut args: Vec<&str> = match target {
            Pull::Upgrade => vec!["upgrade"],
            Pull::Switch(image) => vec!["switch", image],
        };
        args.extend(["--progress-fd", "3"]);
        pull_with_progress(&args, stop, on_progress)
    }
    fn rollback(&self) -> Result<(), String> {
        Self::run(&["rollback"]).map(|_| ())
    }
}

/// The last non-empty line of a command's stderr, for the error text.
fn last_line(stderr: &[u8]) -> String {
    let text = String::from_utf8_lossy(stderr);
    text.lines()
        .rev()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("failed")
        .to_owned()
}

/// Runs bootc with fd 3 the write end of a pipe (bootc refuses a file: "not a pipe") and reads
/// its JSON lines until it closes it.
#[cfg(target_os = "linux")]
fn pull_with_progress(
    args: &[&str],
    stop: &Stop,
    on_progress: &mut dyn FnMut(Progress),
) -> Result<PullEnd, String> {
    use std::io::{BufRead, BufReader, Read};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::process::CommandExt;
    use std::process::Stdio;

    let err = |e: std::io::Error| format!("bootc: {e}");
    let mut fds = [0 as libc::c_int; 2];
    // SAFETY: pipe2 fills the two-element array it is given; both fds are new and owned below.
    if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
        return Err(err(std::io::Error::last_os_error()));
    }
    // SAFETY: just created by pipe2 and owned by nothing else.
    let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    let w = write.as_raw_fd();
    let mut cmd = Command::new("bootc");
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    // SAFETY: runs in the child between fork and exec and calls only async-signal-safe functions
    // (dup2, fcntl) on fds it was given. dup2 makes fd 3 the pipe without close-on-exec; when the
    // pipe already is fd 3, dup2 would do nothing, so the flag is cleared instead.
    unsafe {
        cmd.pre_exec(move || {
            let ok = if w == 3 {
                libc::fcntl(3, libc::F_SETFD, 0) != -1
            } else {
                libc::dup2(w, 3) != -1
            };
            if ok {
                Ok(())
            } else {
                Err(std::io::Error::last_os_error())
            }
        });
    }
    let mut child = cmd.spawn().map_err(err)?;
    // Only bootc may hold the write end, or the read below never ends.
    drop(write);
    stop.attach(child.id());
    let mut stderr = child.stderr.take();
    let errors = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        if let Some(pipe) = stderr.as_mut() {
            let _ = pipe.read_to_end(&mut bytes);
        }
        bytes
    });
    {
        // Dropped before the wait: a bootc still writing then fails instead of blocking.
        let reader = BufReader::new(std::fs::File::from(read));
        for line in reader.split(b'\n') {
            let line = match line {
                Ok(line) => line,
                Err(e) => {
                    eprintln!("ruya-update: reading bootc's progress failed: {e}");
                    break;
                }
            };
            let text = String::from_utf8_lossy(&line);
            if text.trim().is_empty() {
                continue;
            }
            match parse_progress(&text) {
                Ok(Some(progress)) => on_progress(progress),
                Ok(None) => {}
                Err(e) => eprintln!("ruya-update: ignoring a progress line: {e}"),
            }
        }
    }
    stop.detach();
    let status = child.wait().map_err(err)?;
    let stderr = errors.join().unwrap_or_default();
    if stop.is_requested() {
        return Ok(PullEnd::Stopped);
    }
    if status.success() {
        Ok(PullEnd::Done)
    } else {
        Err(format!("bootc {}: {}", args.join(" "), last_line(&stderr)))
    }
}

#[cfg(not(target_os = "linux"))]
fn pull_with_progress(
    args: &[&str],
    _stop: &Stop,
    _on_progress: &mut dyn FnMut(Progress),
) -> Result<PullEnd, String> {
    Err(format!("bootc {}: runs only on Linux", args.join(" ")))
}

// ---- a fake host --------------------------------------------------------------------

/// How a scripted fake pull ends after its events.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FakeEnd {
    /// Staged, as an unscripted pull.
    Done,
    /// Fails with this message; nothing staged.
    Fail(String),
    /// Waits (after telling `pull_holds`) until it is stopped; nothing staged.
    HoldForStop,
}

/// One scripted run of `pull`: its progress events, then its end.
#[derive(Debug, Clone)]
pub struct FakeRun {
    pub events: Vec<Progress>,
    pub end: FakeEnd,
}

/// A host in memory: `check` changes nothing (the cached update is set up front), a pull of the
/// tracked tag stages it, a pull of another tag stages that, `rollback` queues the previous
/// deployment. Pulls follow the runs given to `script_pulls`, one per pull; an unscripted pull
/// sends no events and stages.
#[derive(Default)]
pub struct FakeBootc {
    host: Mutex<HostStatus>,
    fail: Mutex<Option<String>>,
    /// Set by `fail_next_call`: the next call with this name fails with this message.
    fail_named: Mutex<Option<(String, String)>>,
    calls: Mutex<Vec<String>>,
    /// Set by `hold_next_rollback`.
    gate: Mutex<Option<(Sender<()>, Receiver<()>)>>,
    /// The scripted pulls still to come.
    runs: Mutex<std::collections::VecDeque<FakeRun>>,
    /// Told whenever a `HoldForStop` run has sent its events and waits.
    holds: Mutex<Option<Sender<()>>>,
}

impl FakeBootc {
    pub fn new(host: HostStatus) -> Self {
        FakeBootc {
            host: Mutex::new(host),
            ..Default::default()
        }
    }

    /// The next command fails with this message.
    pub fn fail_next(&self, message: &str) {
        *self.fail.lock().expect("fake lock") = Some(message.to_owned());
    }

    /// The next call of this command (`"upgrade"`, `"check"`, ...) fails with this message.
    pub fn fail_next_call(&self, call: &str, message: &str) {
        *self.fail_named.lock().expect("fake lock") = Some((call.to_owned(), message.to_owned()));
    }

    /// The commands run so far, e.g. `["check", "switch x:beta"]`.
    pub fn calls(&self) -> Vec<String> {
        self.calls.lock().expect("fake lock").clone()
    }

    /// The next `rollback` stops inside the command: the first channel fires when it has
    /// started, it goes on when the second is sent to (or dropped). For tests of racing calls.
    pub fn hold_next_rollback(&self) -> (Receiver<()>, Sender<()>) {
        let (entered, started) = std::sync::mpsc::channel();
        let (release, wait) = std::sync::mpsc::channel();
        *self.gate.lock().expect("fake lock") = Some((entered, wait));
        (started, release)
    }

    /// The next pulls, in order.
    pub fn script_pulls(&self, runs: Vec<FakeRun>) {
        self.runs.lock().expect("fake lock").extend(runs);
    }

    /// A message arrives each time a `HoldForStop` run waits for its stop.
    pub fn pull_holds(&self) -> Receiver<()> {
        let (tell, holds) = std::sync::mpsc::channel();
        *self.holds.lock().expect("fake lock") = Some(tell);
        holds
    }

    pub fn set_cached_update(&self, update: Option<Deployment>) {
        self.host.lock().expect("fake lock").cached_update = update;
    }

    fn enter(&self, call: &str) -> Result<(), String> {
        self.calls.lock().expect("fake lock").push(call.to_owned());
        {
            let mut named = self.fail_named.lock().expect("fake lock");
            if named.as_ref().is_some_and(|(name, _)| name == call) {
                if let Some((_, message)) = named.take() {
                    return Err(message);
                }
            }
        }
        match self.fail.lock().expect("fake lock").take() {
            Some(message) => Err(message),
            None => Ok(()),
        }
    }
}

impl Bootc for FakeBootc {
    fn status(&self) -> Result<HostStatus, String> {
        self.enter("status")?;
        Ok(self.host.lock().expect("fake lock").clone())
    }
    fn check(&self) -> Result<(), String> {
        self.enter("check")
    }
    fn pull(
        &self,
        target: &Pull,
        stop: &Stop,
        on_progress: &mut dyn FnMut(Progress),
    ) -> Result<PullEnd, String> {
        match target {
            Pull::Upgrade => self.enter("upgrade")?,
            Pull::Switch(image) => self.enter(&format!("switch {image}"))?,
        }
        if stop.is_requested() {
            return Ok(PullEnd::Stopped);
        }
        let run = self.runs.lock().expect("fake lock").pop_front();
        let end = match run {
            Some(run) => {
                for event in run.events {
                    if stop.is_requested() {
                        return Ok(PullEnd::Stopped);
                    }
                    on_progress(event);
                }
                run.end
            }
            None => FakeEnd::Done,
        };
        match end {
            FakeEnd::Fail(message) => return Err(message),
            FakeEnd::HoldForStop => {
                if let Some(tell) = self.holds.lock().expect("fake lock").as_ref() {
                    let _ = tell.send(());
                }
                stop.wait();
                return Ok(PullEnd::Stopped);
            }
            FakeEnd::Done => {}
        }
        let mut host = self.host.lock().expect("fake lock");
        match target {
            Pull::Upgrade => {
                if let Some(update) = host.cached_update.take() {
                    host.staged = Some(update);
                }
            }
            Pull::Switch(image) => {
                host.tracked = image.clone();
                host.cached_update = None;
                host.staged = Some(Deployment {
                    image: image.clone(),
                    version: String::new(),
                    digest: format!("sha256:{image}"),
                });
            }
        }
        Ok(PullEnd::Done)
    }
    fn rollback(&self) -> Result<(), String> {
        self.enter("rollback")?;
        let gate = self.gate.lock().expect("fake lock").take();
        if let Some((entered, wait)) = gate {
            let _ = entered.send(());
            let _ = wait.recv();
        }
        self.host.lock().expect("fake lock").rollback_queued = true;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags() {
        assert_eq!(tag_of("host:5000/ruyaos:stable"), "stable");
        assert_eq!(tag_of("host:5000/ruyaos"), "");
        assert_eq!(tag_of("host/ruyaos@sha256:abc"), "");
        assert_eq!(
            with_tag("host:5000/ruyaos:stable", "beta"),
            "host:5000/ruyaos:beta"
        );
        assert_eq!(
            with_tag("host:5000/ruyaos", "beta"),
            "host:5000/ruyaos:beta"
        );
    }

    const SAMPLE: &str = r#"{
      "apiVersion": "org.containers.bootc/v1", "kind": "BootcHost",
      "metadata": {"name": "host"},
      "spec": {"image": {"image": "10.0.0.2:5000/ruyaos:stable", "transport": "registry"}, "bootOrder": "default"},
      "status": {
        "staged": null,
        "booted": {"image": {"image": {"image": "10.0.0.2:5000/ruyaos:stable", "transport": "registry"},
                             "version": "0.0.19", "timestamp": null, "imageDigest": "sha256:aaa"},
                   "cachedUpdate": {"image": {"image": "10.0.0.2:5000/ruyaos:stable", "transport": "registry"},
                             "version": "0.0.20", "timestamp": null, "imageDigest": "sha256:bbb"},
                   "incompatible": false, "pinned": false},
        "rollback": {"image": {"image": {"image": "10.0.0.2:5000/ruyaos:old", "transport": "registry"},
                             "version": null, "imageDigest": "sha256:ccc"}},
        "rollbackQueued": false, "type": "bootcHost"}
    }"#;

    #[test]
    fn reads_a_status() {
        let host = parse_status(SAMPLE).expect("parses");
        assert_eq!(host.tracked, "10.0.0.2:5000/ruyaos:stable");
        let booted = host.booted.expect("booted");
        assert_eq!(booted.label(), "0.0.19");
        assert_eq!(booted.digest, "sha256:aaa");
        assert!(host.staged.is_none());
        assert_eq!(host.cached_update.expect("update").label(), "0.0.20");
        let rollback = host.rollback.expect("rollback");
        assert_eq!(rollback.label(), "old", "no version label: the tag");
        assert!(!host.rollback_queued);
    }

    /// The Dell's 0.0.105 -> 0.0.106 run from an oci-archive (RUY-27's probe, bootc 1.17.1): every
    /// event the probe kept, one ProgressBytes a second. The probe cut its lines at 400 bytes:
    /// the ProgressBytes lines keep their fields up to stepsTotal (their per-layer `subtasks` and
    /// `task` were cut off and their `type` is restored); Start and ProgressSteps are whole.
    const DELL_RUN: &str =
        include_str!("../tests/fixtures/bootc-progress-0.0.105-to-0.0.106.jsonl");

    fn dell_events() -> Vec<Progress> {
        DELL_RUN
            .lines()
            .filter_map(|l| parse_progress(l).expect("every recorded line parses"))
            .collect()
    }

    #[test]
    fn reads_the_recorded_progress_events() {
        assert_eq!(
            parse_progress(DELL_RUN.lines().next().expect("a line")),
            Ok(None),
            "Start"
        );
        let events = dell_events();
        let bytes: Vec<_> = events
            .iter()
            .filter_map(|e| match e {
                Progress::Bytes { bytes, .. } => Some(*bytes),
                _ => None,
            })
            .collect();
        assert_eq!(bytes.len(), 113);
        assert!(
            bytes.windows(2).all(|w| w[0] <= w[1]),
            "bytes of a run only grow"
        );
        assert_eq!(
            events[0],
            Progress::Bytes {
                bytes: 8193,
                bytes_total: 2_381_035_309,
                bytes_cached: 1_067_414_334,
                steps: 0,
                steps_total: 10,
                steps_cached: 68,
            },
            "a run after a stopped one: 68 layers cached, 10 to fetch"
        );
        assert_eq!(bytes.last(), Some(&2_381_035_309), "ends with all of it");
        let steps: Vec<_> = events
            .iter()
            .filter(|e| matches!(e, Progress::Steps { .. }))
            .collect();
        assert_eq!(
            steps,
            [
                &Progress::Steps {
                    task: "importing".to_owned(),
                    steps: 0,
                    steps_total: 1
                },
                &Progress::Steps {
                    task: "importing".to_owned(),
                    steps: 1,
                    steps_total: 1
                },
            ]
        );
    }

    #[test]
    fn an_unknown_event_is_ignored_and_a_garbled_line_is_an_error() {
        assert_eq!(
            parse_progress(r#"{"type":"ProgressSomethingNew","bytes":5}"#),
            Ok(None)
        );
        // A real line cut in the middle (the probe's 400-byte limit).
        let cut = r#"{"bytes": 2007041, "bytesCached": 1067414334, "bytesTotal": 2381035309, "description": "Pulling Image: sha256:a2241"#;
        assert!(parse_progress(cut).is_err());
        assert!(parse_progress("Deploying...done").is_err());
        assert!(parse_progress(r#"{"bytes":1}"#).is_err(), "no type");
        assert!(
            parse_progress(r#"{"type":"ProgressBytes","bytes":1}"#).is_err(),
            "fields missing"
        );
    }

    #[test]
    fn bad_json_is_an_error() {
        assert!(parse_status("not json").is_err());
        assert!(parse_status("{}").is_err());
    }
}
