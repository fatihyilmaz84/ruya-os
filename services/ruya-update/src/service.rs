//! The rules of Update1: the status record, which call is allowed when, what a check and a
//! download make of `bootc`'s answers. No I/O except through `Bootc` and the one-file state
//! (the channel) under `/var/lib/ruya-update`. Time is passed in.

use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

use crate::bootc::{tag_of, with_tag, Bootc, HostStatus};

/// Statuses of the method replies (stable API, `api/dbus/org.ruyaos.Update1.xml`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    Busy,
    Unavailable,
    Invalid,
    Forbidden,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::Busy => "busy",
            Status::Unavailable => "unavailable",
            Status::Invalid => "invalid",
            Status::Forbidden => "forbidden",
            Status::Failed => "failed",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Idle,
    Checking,
    Downloading,
    Staged,
    UpToDate,
    Failed,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Idle => "idle",
            State::Checking => "checking",
            State::Downloading => "downloading",
            State::Staged => "staged",
            State::UpToDate => "up-to-date",
            State::Failed => "failed",
        }
    }

    fn running(self) -> bool {
        matches!(self, State::Checking | State::Downloading)
    }
}

/// The `a{sv}` record of `GetStatus`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub state: State,
    pub current: String,
    pub available: String,
    pub staged: String,
    pub channel: String,
    pub last_check: i64,
    pub progress: u32,
    pub rollback_available: bool,
    pub error: String,
}

const CHANNELS: [&str; 2] = ["stable", "beta"];
const CHANNEL_FILE: &str = "channel";

struct Inner {
    state: State,
    available: String,
    error: String,
    last_check: i64,
    progress: u32,
    /// The tag the user chose with `SetChannel`; None until then (the host's own tag is tracked).
    channel: Option<String>,
    /// Why the remembered channel could not be read; "" when it could. Shown as the error
    /// until `SetChannel` writes a good file.
    channel_problem: String,
    host: HostStatus,
}

pub struct Update<B: Bootc> {
    bootc: B,
    /// Where the channel is remembered; None in development.
    dir: Option<PathBuf>,
    inner: Mutex<Inner>,
    /// One `bootc` command at a time.
    commands: Mutex<()>,
}

/// The remembered channel. A file that cannot be used is an `Err` naming it; it stays as it is
/// until `SetChannel` replaces it.
fn load_channel(dir: &std::path::Path) -> Result<Option<String>, String> {
    let path = dir.join(CHANNEL_FILE);
    match fs::read_to_string(&path) {
        Ok(text) => {
            let text = text.trim();
            if CHANNELS.contains(&text) {
                Ok(Some(text.to_owned()))
            } else {
                Err(format!("{}: unknown channel {text:?}", path.display()))
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

fn save_channel(dir: &std::path::Path, channel: &str) -> std::io::Result<()> {
    fs::create_dir_all(dir)?;
    let tmp = dir.join(format!("{CHANNEL_FILE}.tmp"));
    fs::write(&tmp, format!("{channel}\n"))?;
    fs::rename(tmp, dir.join(CHANNEL_FILE))
}

impl<B: Bootc> Update<B> {
    /// `dir`: where the channel is remembered. A corrupt state file does not stop the service
    /// (`/var` survives an image rollback, so a fatal start would fail every boot): the host's
    /// own tag is followed and the problem is the status error until `SetChannel`.
    pub fn new(bootc: B, dir: Option<PathBuf>) -> Self {
        let (channel, channel_problem) = match dir.as_deref().map(load_channel) {
            Some(Ok(channel)) => (channel, String::new()),
            Some(Err(problem)) => {
                eprintln!("ruya-update: ignoring the remembered channel: {problem}");
                (None, problem)
            }
            None => (None, String::new()),
        };
        Update {
            bootc,
            dir,
            inner: Mutex::new(Inner {
                state: State::Idle,
                available: String::new(),
                error: String::new(),
                last_check: 0,
                progress: 0,
                channel,
                channel_problem,
                host: HostStatus::default(),
            }),
            commands: Mutex::new(()),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn command_lock(&self) -> std::sync::MutexGuard<'_, ()> {
        self.commands.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Reads the host's deployments (at start, and after every job). A staged image or a queued
    /// rollback means "restart to finish".
    pub fn refresh(&self) -> Result<(), String> {
        let _cmd = self.command_lock();
        let host = self.bootc.status()?;
        let mut inner = self.lock();
        if inner.state == State::Idle && staged_label(&host).is_some() {
            inner.state = State::Staged;
        }
        inner.host = host;
        Ok(())
    }

    pub fn record(&self) -> Record {
        let inner = self.lock();
        // A staged image or a running job matters more than the bad file.
        let problem = !inner.channel_problem.is_empty()
            && matches!(inner.state, State::Idle | State::UpToDate | State::Failed);
        Record {
            state: if problem { State::Failed } else { inner.state },
            current: inner
                .host
                .booted
                .as_ref()
                .map(|d| d.label())
                .unwrap_or_default(),
            available: inner.available.clone(),
            staged: staged_label(&inner.host).unwrap_or_default(),
            channel: effective_channel(&inner),
            last_check: inner.last_check,
            progress: inner.progress,
            rollback_available: inner.host.rollback.is_some() && !inner.host.rollback_queued,
            error: if problem && inner.error.is_empty() {
                inner.channel_problem.clone()
            } else {
                inner.error.clone()
            },
        }
    }

    // ---- check -----------------------------------------------------------------------

    /// Starts a check; `run_check` does the work (on a thread).
    pub fn begin_check(&self) -> Status {
        let mut inner = self.lock();
        if inner.state.running() {
            return Status::Busy;
        }
        inner.state = State::Checking;
        inner.error.clear();
        Status::Ok
    }

    /// Asks the registry about the tracked tag. With a channel other than the host's tag there is
    /// nothing to ask (`bootc` cannot look at another tag without staging it): the channel
    /// itself is "available", and `run_download` switches to it.
    pub fn run_check(&self, now: i64, emit: &mut dyn FnMut()) {
        let result = {
            let _cmd = self.command_lock();
            self.check_locked()
        };
        {
            let mut inner = self.lock();
            match result {
                Err(e) => {
                    inner.state = State::Failed;
                    inner.error = e;
                }
                Ok((host, switching)) => {
                    inner.last_check = now;
                    inner.available = available_version(&host, switching, &inner);
                    inner.host = host;
                    inner.state = if staged_label(&inner.host).is_some() {
                        inner.available.clear();
                        State::Staged
                    } else if inner.available.is_empty() {
                        State::UpToDate
                    } else {
                        State::Idle
                    };
                }
            }
        }
        emit();
    }

    /// The `bootc` part of a check, with `commands` held: the host's answer and whether the
    /// chosen channel differs from the tracked tag.
    fn check_locked(&self) -> Result<(HostStatus, bool), String> {
        // The start-up reading may not have finished (or failed): learn the tracked image now.
        if self.lock().host.tracked.is_empty() {
            let host = self.bootc.status()?;
            self.lock().host = host;
        }
        if self.lock().host.tracked.is_empty() {
            return Err("bootc does not say which image this console follows".to_owned());
        }
        if self.switch_target().is_some() {
            return Ok((self.bootc.status()?, true));
        }
        self.bootc.check()?;
        Ok((self.bootc.status()?, false))
    }

    // ---- download --------------------------------------------------------------------

    pub fn begin_download(&self) -> Status {
        let mut inner = self.lock();
        if inner.state.running() {
            return Status::Busy;
        }
        if inner.available.is_empty() {
            return Status::Unavailable;
        }
        inner.state = State::Downloading;
        inner.progress = 0;
        inner.error.clear();
        Status::Ok
    }

    /// Stages the image. `bootc` reports no progress we read: 0 while it works, 100 when done.
    pub fn run_download(&self, emit: &mut dyn FnMut()) {
        let result = {
            let _cmd = self.command_lock();
            match self.switch_target() {
                Some(image) => self.bootc.switch(&image),
                None => self.bootc.upgrade(),
            }
            .and_then(|()| self.bootc.status())
        };
        {
            let mut inner = self.lock();
            match result {
                Err(e) => {
                    inner.state = State::Failed;
                    inner.error = e;
                }
                Ok(host) if staged_label(&host).is_none() => {
                    inner.host = host;
                    inner.state = State::Failed;
                    inner.error = "bootc staged nothing".to_owned();
                }
                Ok(host) => {
                    inner.host = host;
                    inner.progress = 100;
                    inner.available.clear();
                    inner.state = State::Staged;
                }
            }
        }
        emit();
    }

    // ---- admin calls -----------------------------------------------------------------

    /// `admin`: the caller is root, or the shell while the active profile is an admin.
    pub fn rollback(&self, admin: bool) -> Status {
        if !admin {
            return Status::Forbidden;
        }
        // Busy at once rather than after a download that holds `commands`.
        if self.lock().state.running() {
            return Status::Busy;
        }
        // `commands` is held to the end: a check begun meanwhile waits for it and then sees the
        // rolled-back host. (`inner` is never held while waiting: status reads take it.) The
        // rules are asked again under it, because the host may have changed while waiting.
        let _cmd = self.command_lock();
        {
            let inner = self.lock();
            if inner.state.running() {
                return Status::Busy;
            }
            if inner.host.rollback.is_none() || inner.host.rollback_queued {
                return Status::Unavailable;
            }
        }
        let result = self.bootc.rollback().and_then(|()| self.bootc.status());
        let mut inner = self.lock();
        match result {
            Err(e) => {
                inner.error = e;
                Status::Failed
            }
            Ok(host) => {
                inner.host = host;
                inner.available.clear();
                inner.error.clear();
                // A job that began while `bootc` worked settles the state itself.
                if !inner.state.running() {
                    inner.state = State::Staged;
                }
                Status::Ok
            }
        }
    }

    pub fn set_channel(&self, channel: &str, admin: bool) -> Status {
        if !admin {
            return Status::Forbidden;
        }
        if !CHANNELS.contains(&channel) {
            return Status::Invalid;
        }
        let mut inner = self.lock();
        if inner.state.running() {
            return Status::Busy;
        }
        if let Some(dir) = &self.dir {
            if save_channel(dir, channel).is_err() {
                return Status::Failed;
            }
        }
        inner.channel = Some(channel.to_owned());
        inner.channel_problem.clear();
        inner.available.clear();
        if matches!(inner.state, State::UpToDate | State::Failed) {
            inner.state = State::Idle;
        }
        Status::Ok
    }

    /// The image reference to `bootc switch` to, when the chosen channel is not the tag the host
    /// tracks.
    fn switch_target(&self) -> Option<String> {
        let inner = self.lock();
        let channel = inner.channel.as_deref()?;
        // Not read yet: a reference like ":beta" would be a switch to nowhere.
        if inner.host.tracked.is_empty() {
            return None;
        }
        (tag_of(&inner.host.tracked) != channel).then(|| with_tag(&inner.host.tracked, channel))
    }
}

fn staged_label(host: &HostStatus) -> Option<String> {
    if let Some(staged) = &host.staged {
        return Some(staged.label());
    }
    if host.rollback_queued {
        return host.rollback.as_ref().map(|d| d.label());
    }
    None
}

/// The channel shown: the one chosen, else the host's tag when it is a channel, else "stable".
fn effective_channel(inner: &Inner) -> String {
    if let Some(channel) = &inner.channel {
        return channel.clone();
    }
    let tag = tag_of(&inner.host.tracked);
    if CHANNELS.contains(&tag) {
        tag.to_owned()
    } else {
        CHANNELS[0].to_owned()
    }
}

/// What a finished check found: "" for nothing.
fn available_version(host: &HostStatus, switching: bool, inner: &Inner) -> String {
    if switching {
        return inner.channel.clone().unwrap_or_default();
    }
    let Some(update) = &host.cached_update else {
        return String::new();
    };
    let known = |digest: &str| {
        host.booted.as_ref().is_some_and(|d| d.digest == digest)
            || host.staged.as_ref().is_some_and(|d| d.digest == digest)
    };
    if update.digest.is_empty() || known(&update.digest) {
        String::new()
    } else {
        update.label()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bootc::{Deployment, FakeBootc};

    fn dep(image: &str, version: &str, digest: &str) -> Deployment {
        Deployment {
            image: image.to_owned(),
            version: version.to_owned(),
            digest: digest.to_owned(),
        }
    }

    fn host() -> HostStatus {
        HostStatus {
            tracked: "reg:5000/ruyaos:stable".to_owned(),
            booted: Some(dep("reg:5000/ruyaos:stable", "0.0.19", "sha256:a")),
            staged: None,
            rollback: Some(dep("reg:5000/ruyaos:stable", "0.0.18", "sha256:z")),
            rollback_queued: false,
            cached_update: Some(dep("reg:5000/ruyaos:stable", "0.0.20", "sha256:b")),
        }
    }

    fn service(host: HostStatus) -> Update<FakeBootc> {
        let u = Update::new(FakeBootc::new(host), None);
        u.refresh().expect("refresh");
        u
    }

    fn check(u: &Update<FakeBootc>) {
        assert_eq!(u.begin_check(), Status::Ok);
        u.run_check(1000, &mut || {});
    }

    #[test]
    fn status_strings_are_the_contract() {
        let all = [
            (Status::Ok, "ok"),
            (Status::Busy, "busy"),
            (Status::Unavailable, "unavailable"),
            (Status::Invalid, "invalid"),
            (Status::Forbidden, "forbidden"),
            (Status::Failed, "failed"),
        ];
        for (s, text) in all {
            assert_eq!(s.as_str(), text);
        }
        let states = [
            (State::Idle, "idle"),
            (State::Checking, "checking"),
            (State::Downloading, "downloading"),
            (State::Staged, "staged"),
            (State::UpToDate, "up-to-date"),
            (State::Failed, "failed"),
        ];
        for (s, text) in states {
            assert_eq!(s.as_str(), text);
        }
    }

    #[test]
    fn the_record_comes_from_bootc() {
        let r = service(host()).record();
        assert_eq!(r.state, State::Idle);
        assert_eq!(r.current, "0.0.19");
        assert_eq!(r.channel, "stable");
        assert_eq!(r.available, "");
        assert_eq!(r.staged, "");
        assert_eq!(r.last_check, 0);
        assert!(r.rollback_available);
    }

    #[test]
    fn a_dev_tag_is_stable_until_a_channel_is_chosen() {
        let mut h = host();
        h.tracked = "reg:5000/ruyaos:0.0.19".to_owned();
        assert_eq!(service(h).record().channel, "stable");
    }

    #[test]
    fn check_finds_a_newer_image() {
        let u = service(host());
        assert_eq!(u.begin_check(), Status::Ok);
        assert_eq!(u.record().state, State::Checking);
        u.run_check(1234, &mut || {});
        let r = u.record();
        assert_eq!(r.state, State::Idle);
        assert_eq!(r.available, "0.0.20");
        assert_eq!(r.last_check, 1234);
        assert_eq!(u.bootc.calls(), ["status", "check", "status"]);
    }

    #[test]
    fn check_without_news_is_up_to_date() {
        let mut h = host();
        h.cached_update = None;
        let u = service(h);
        check(&u);
        assert_eq!(u.record().state, State::UpToDate);
    }

    #[test]
    fn a_cached_update_equal_to_the_booted_image_is_no_news() {
        let mut h = host();
        h.cached_update = Some(dep("reg:5000/ruyaos:stable", "0.0.19", "sha256:a"));
        let u = service(h);
        check(&u);
        assert_eq!(u.record().state, State::UpToDate);
    }

    #[test]
    fn a_failed_check_says_why() {
        let u = service(host());
        assert_eq!(u.begin_check(), Status::Ok);
        u.bootc.fail_next("registry unreachable");
        u.run_check(5, &mut || {});
        let r = u.record();
        assert_eq!(r.state, State::Failed);
        assert_eq!(r.error, "registry unreachable");
        assert_eq!(r.last_check, 0, "a failed check is not a finished check");
        assert_eq!(u.begin_check(), Status::Ok, "and can be retried");
        assert_eq!(u.record().error, "");
    }

    #[test]
    fn busy_while_a_check_runs() {
        let u = service(host());
        assert_eq!(u.begin_check(), Status::Ok);
        assert_eq!(u.begin_check(), Status::Busy);
        assert_eq!(u.begin_download(), Status::Busy);
        assert_eq!(u.rollback(true), Status::Busy);
        assert_eq!(u.set_channel("beta", true), Status::Busy);
    }

    #[test]
    fn download_needs_a_found_update() {
        let u = service(host());
        assert_eq!(u.begin_download(), Status::Unavailable);
    }

    #[test]
    fn download_stages_the_image() {
        let u = service(host());
        check(&u);
        assert_eq!(u.begin_download(), Status::Ok);
        let r = u.record();
        assert_eq!((r.state, r.progress), (State::Downloading, 0));
        assert_eq!(u.begin_check(), Status::Busy);
        assert_eq!(u.begin_download(), Status::Busy);
        let mut changes = 0;
        u.run_download(&mut || changes += 1);
        let r = u.record();
        assert_eq!(r.state, State::Staged);
        assert_eq!(r.staged, "0.0.20");
        assert_eq!(r.available, "");
        assert_eq!(r.progress, 100);
        assert_eq!(changes, 1);
        assert!(u.bootc.calls().contains(&"upgrade".to_owned()));
        assert_eq!(u.begin_download(), Status::Unavailable);
    }

    #[test]
    fn a_failed_download_keeps_the_found_update() {
        let u = service(host());
        check(&u);
        assert_eq!(u.begin_download(), Status::Ok);
        u.bootc.fail_next("disk full");
        u.run_download(&mut || {});
        let r = u.record();
        assert_eq!(r.state, State::Failed);
        assert_eq!(r.error, "disk full");
        assert_eq!(r.available, "0.0.20");
        assert_eq!(u.begin_download(), Status::Ok, "retry");
    }

    #[test]
    fn a_staged_image_is_found_again_by_a_check() {
        let u = service(host());
        check(&u);
        assert_eq!(u.begin_download(), Status::Ok);
        u.run_download(&mut || {});
        check(&u);
        assert_eq!(u.record().state, State::Staged);
    }

    #[test]
    fn a_staged_image_at_start_offers_the_restart() {
        let mut h = host();
        h.staged = Some(dep("reg:5000/ruyaos:stable", "0.0.20", "sha256:b"));
        let r = service(h).record();
        assert_eq!((r.state, r.staged.as_str()), (State::Staged, "0.0.20"));
    }

    #[test]
    fn rollback_is_for_admins() {
        let u = service(host());
        assert_eq!(u.rollback(false), Status::Forbidden);
        assert!(!u.bootc.calls().contains(&"rollback".to_owned()));
        assert!(u.record().rollback_available);
    }

    #[test]
    fn rollback_stages_the_previous_image_once() {
        let u = service(host());
        assert_eq!(u.rollback(true), Status::Ok);
        let r = u.record();
        assert_eq!((r.state, r.staged.as_str()), (State::Staged, "0.0.18"));
        assert!(!r.rollback_available);
        assert_eq!(u.rollback(true), Status::Unavailable);
    }

    #[test]
    fn rollback_without_a_previous_image_is_unavailable() {
        let mut h = host();
        h.rollback = None;
        assert_eq!(service(h).rollback(true), Status::Unavailable);
    }

    #[test]
    fn a_failing_rollback_is_failed_and_changes_nothing() {
        let u = service(host());
        u.bootc.fail_next("no");
        assert_eq!(u.rollback(true), Status::Failed);
        let r = u.record();
        assert_eq!(r.state, State::Idle);
        assert!(r.rollback_available);
    }

    #[test]
    fn set_channel_rules() {
        let u = service(host());
        assert_eq!(u.set_channel("beta", false), Status::Forbidden);
        assert_eq!(u.set_channel("nightly", true), Status::Invalid);
        assert_eq!(u.record().channel, "stable");
        check(&u);
        assert_eq!(u.record().available, "0.0.20");
        assert_eq!(u.set_channel("beta", true), Status::Ok);
        let r = u.record();
        assert_eq!((r.channel.as_str(), r.available.as_str()), ("beta", ""));
        assert_eq!(u.begin_download(), Status::Unavailable);
    }

    #[test]
    fn set_channel_leaves_up_to_date_and_failed() {
        let mut h = host();
        h.cached_update = None;
        let u = service(h);
        check(&u);
        assert_eq!(u.record().state, State::UpToDate);
        assert_eq!(u.set_channel("beta", true), Status::Ok);
        assert_eq!(u.record().state, State::Idle);
    }

    #[test]
    fn a_new_channel_is_switched_to_on_download() {
        let u = service(host());
        assert_eq!(u.set_channel("beta", true), Status::Ok);
        check(&u);
        let r = u.record();
        assert_eq!((r.state, r.available.as_str()), (State::Idle, "beta"));
        assert!(!u.bootc.calls().contains(&"check".to_owned()));
        assert_eq!(u.begin_download(), Status::Ok);
        u.run_download(&mut || {});
        assert!(u
            .bootc
            .calls()
            .contains(&"switch reg:5000/ruyaos:beta".to_owned()));
        let r = u.record();
        assert_eq!((r.state, r.staged.as_str()), (State::Staged, "beta"));
        assert_eq!(r.channel, "beta");
    }

    #[test]
    fn the_channel_survives_a_restart() {
        let dir = tempfile::tempdir().expect("tempdir");
        let u = Update::new(FakeBootc::new(host()), Some(dir.path().join("state")));
        assert_eq!(u.set_channel("beta", true), Status::Ok);
        let u = Update::new(FakeBootc::new(host()), Some(dir.path().join("state")));
        assert_eq!(u.record().channel, "beta");
    }

    #[test]
    fn a_corrupt_state_file_does_not_stop_the_service() {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join(CHANNEL_FILE), "nightly").expect("write");
        let u = Update::new(FakeBootc::new(host()), Some(dir.path().to_owned()));
        u.refresh().expect("refresh");
        let r = u.record();
        assert_eq!(r.state, State::Failed);
        assert!(r.error.contains(CHANNEL_FILE), "{}", r.error);
        assert!(r.error.contains("nightly"), "{}", r.error);
        assert_eq!(r.channel, "stable", "the host's own tag is followed");

        // A check still works, and the file is still reported afterwards.
        check(&u);
        let r = u.record();
        assert_eq!((r.state, r.available.as_str()), (State::Failed, "0.0.20"));
        assert!(r.error.contains(CHANNEL_FILE));
        assert!(!u.bootc.calls().iter().any(|c| c.starts_with("switch")));

        // SetChannel replaces the file and clears the report.
        assert_eq!(u.set_channel("stable", true), Status::Ok);
        let r = u.record();
        assert_eq!((r.state, r.error.as_str()), (State::Idle, ""));
        let dir_text = fs::read_to_string(dir.path().join(CHANNEL_FILE)).expect("read");
        assert_eq!(dir_text, "stable\n");
    }

    #[test]
    fn an_unreadable_state_file_does_not_stop_the_service_either() {
        let dir = tempfile::tempdir().expect("tempdir");
        // A directory where the file belongs: reading it fails with something other than NotFound.
        fs::create_dir(dir.path().join(CHANNEL_FILE)).expect("mkdir");
        let u = Update::new(FakeBootc::new(host()), Some(dir.path().to_owned()));
        assert_eq!(u.record().state, State::Failed);
        assert!(u.record().error.contains(CHANNEL_FILE));
    }

    #[test]
    fn a_staged_image_is_not_hidden_by_the_bad_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join(CHANNEL_FILE), "nightly").expect("write");
        let mut h = host();
        h.staged = Some(dep("reg:5000/ruyaos:stable", "0.0.20", "sha256:b"));
        let u = Update::new(FakeBootc::new(h), Some(dir.path().to_owned()));
        u.refresh().expect("refresh");
        assert_eq!(u.record().state, State::Staged);
    }

    #[test]
    fn without_a_known_tracked_image_a_check_fails_before_any_switch() {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join(CHANNEL_FILE), "beta\n").expect("write");
        let mut h = host();
        h.tracked = String::new();
        let u = Update::new(FakeBootc::new(h), Some(dir.path().to_owned()));
        // The start-up reading has not finished: nothing is known about the host.
        assert_eq!(u.begin_check(), Status::Ok);
        u.run_check(5, &mut || {});
        let r = u.record();
        assert_eq!(r.state, State::Failed);
        assert!(r.error.contains("which image"), "{}", r.error);
        assert!(!u.bootc.calls().iter().any(|c| c.starts_with("switch")));
        assert!(!u.bootc.calls().contains(&"check".to_owned()));
        assert_eq!(u.begin_download(), Status::Unavailable);
    }

    #[test]
    fn a_check_learns_the_tracked_image_when_the_first_reading_failed() {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join(CHANNEL_FILE), "beta\n").expect("write");
        let u = Update::new(FakeBootc::new(host()), Some(dir.path().to_owned()));
        // No refresh() yet: the check reads the host itself and finds a channel to switch to.
        check(&u);
        let r = u.record();
        assert_eq!((r.state, r.available.as_str()), (State::Idle, "beta"));
        assert!(!u.bootc.calls().iter().any(|c| c.starts_with("switch")));
    }

    #[test]
    fn a_download_that_staged_nothing_is_a_failure() {
        let u = service(host());
        check(&u);
        assert_eq!(u.begin_download(), Status::Ok);
        // The image vanished from the registry between the check and the download.
        u.bootc.set_cached_update(None);
        u.run_download(&mut || {});
        let r = u.record();
        assert_eq!(r.state, State::Failed);
        assert_eq!(r.error, "bootc staged nothing");
        assert_eq!(r.progress, 0);
        assert_eq!(r.staged, "");
    }

    #[test]
    fn a_check_begun_during_a_rollback_ends_staged_with_the_rollback() {
        let u = service(host());
        let (started, release) = u.bootc.hold_next_rollback();
        std::thread::scope(|scope| {
            let rollback = scope.spawn(|| u.rollback(true));
            // `bootc rollback` is running, with `commands` held.
            started.recv().expect("rollback started");
            assert_eq!(
                u.begin_check(),
                Status::Ok,
                "no job runs yet: a check may begin"
            );
            let check = scope.spawn(|| u.run_check(7, &mut || {}));
            std::thread::sleep(std::time::Duration::from_millis(50));
            assert_eq!(u.record().state, State::Checking, "it waits for bootc");
            release.send(()).expect("release");
            assert_eq!(rollback.join().expect("rollback thread"), Status::Ok);
            check.join().expect("check thread");
        });
        let r = u.record();
        assert_eq!((r.state, r.staged.as_str()), (State::Staged, "0.0.18"));
        assert!(!r.rollback_available);
        assert_eq!(r.available, "");
        assert_eq!(r.last_check, 7);
        // The check read the host after the rollback, never before.
        let calls = u.bootc.calls();
        let at = |name: &str| calls.iter().position(|c| c == name).expect("call");
        assert!(at("rollback") < at("check"), "{calls:?}");
    }

    #[test]
    fn a_rollback_does_not_wait_for_a_download() {
        let u = service(host());
        check(&u);
        assert_eq!(u.begin_download(), Status::Ok);
        assert_eq!(u.rollback(true), Status::Busy);
    }
}
