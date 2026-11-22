//! X11 mode for apps that cannot do Wayland (ADR-034, RUY-435).
//!
//! Wayland stays the only display path: an app runs in X11 mode only when its Flatpak metadata
//! asks for X11 and not for Wayland (`needs_x11`), or when the image's app table says
//! `display=x11` for it (`apps.rs`; the image lists Steam). Then the main process of the app's
//! unit is not `flatpak run` but this binary's `x11-run` helper, running as the profile user:
//!   1. it makes `$XDG_RUNTIME_DIR/ruya-x11/<app id>/` (0700) and writes a random
//!      MIT-MAGIC-COOKIE-1 into an Xauthority file there (0600, `xauth_record`);
//!   2. it picks the lowest free display (no `/tmp/.X11-unix/X<n>`, no `/tmp/.X<n>-lock`) and
//!      starts `xwayland-satellite :<n> -nolisten local -auth <file>` with `XDG_RUNTIME_DIR` set to
//!      that directory (so its `xwls-<n>` sockets land there) and the profile's `WAYLAND_DISPLAY`;
//!      the satellite runs Xwayland rootless and is its X window manager;
//!   3. once Xwayland is up (the satellite sent `READY=1` to the private `NOTIFY_SOCKET` it was
//!      given in the instance directory, the kernel-checked sender being the satellite itself, and
//!      the display's socket exists) the socket is made 0700; a display taken meanwhile by another launch is retried with the next
//!      number, a few times at most;
//!   4. it runs `flatpak run --device=input <app id>` with `DISPLAY`, `XAUTHORITY`, `SDL_VIDEODRIVER=x11` and
//!      `XDG_SESSION_TYPE=x11`, and without `WAYLAND_DISPLAY` (`app_env_x11`);
//!   5. when the app ends it first checks that the satellite and Xwayland still live: if one ended
//!      under the app it logs `the X11 bridge stopped: <which>` and turns an exit 0 into 1 (the app
//!      ends "crashed"); then it stops the satellite, waits for Xwayland and removes the directory and
//!      a stale X socket and lock (`cleanup`). The unit's `ExecStopPost` (`x11-cleanup`) does the
//!      same, because a Stop kills the whole unit, the helper included.
//!
//! The satellite and Xwayland live in the app unit's cgroup, so Freeze, Thaw, Close, Stop and the
//! window ↔ instance match by pid need nothing new. Isolation (ADR-034 point 5): no abstract
//! socket and no TCP (`-nolisten local`), a 0700 socket, a cookie that only the app gets (Flatpak
//! filters it into `/run/flatpak/Xauthority`).
//!
//! The steps go through `X11Os`, so the order, the retry and the cleanup are tested on every
//! host; `LinuxOs` is the real one.

use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::apps::Display;
use crate::spawner::valid_app_arg;
use ruya_flatpak::valid_session_app_id;
use ruya_keyfile::Keyfile;

/// The X server bridge (ADR-034 point 4; RUY-434 ships it patched for Qt's compositor).
pub const SATELLITE_PROGRAM: &str = "/usr/bin/xwayland-satellite";
/// Where X servers put their sockets (systemd's `tmpfiles.d/x11.conf` makes it, 1777).
pub const X11_SOCKET_DIR: &str = "/tmp/.X11-unix";
/// Display numbers tried, lowest first.
pub const DISPLAY_LIMIT: u32 = 100;
/// How many displays one launch tries when the chosen one is taken meanwhile.
pub const DISPLAY_TRIES: u32 = 3;
/// How long Xwayland may take to come up, in polls of `READY_POLL`.
pub const READY_POLL: Duration = Duration::from_millis(50);
pub const READY_POLLS: u32 = 200;
/// How long the satellite and Xwayland get to end after SIGTERM before SIGKILL.
pub const STOP_GRACE: Duration = Duration::from_secs(5);
/// The helper's exit status when the X server cannot be started. systemd names 203 `EXEC`, so
/// `systemd-run --wait` reports `status=203/EXEC` and the launch ends as `launch-failed`
/// (`spawner::parse_run_line`), as when the program itself cannot be executed.
pub const EXIT_LAUNCH_FAILED: i32 = 203;
/// The cookie's length (MIT-MAGIC-COOKIE-1 is 16 bytes).
pub const COOKIE_LEN: usize = 16;
/// Xauthority family "any address" (`FamilyWild`): Flatpak passes such an entry on into the
/// sandbox (`FamilyLocal` would have to name this host, network families are dropped).
pub const FAMILY_WILD: u16 = 65535;
/// The satellite as the journal line names it.
const SATELLITE_NAME: &str = "xwayland-satellite";
const COOKIE_NAME: &str = "MIT-MAGIC-COOKIE-1";
/// The files in the instance directory.
const AUTH_FILE: &str = "Xauthority";
const DISPLAY_FILE: &str = "display";
/// The satellite's pid, recorded so a later cleanup can tell a stale socket from a live one.
const SATELLITE_FILE: &str = "satellite";
/// The private datagram socket the satellite's `READY=1` (sd_notify) goes to.
const NOTIFY_FILE: &str = "notify";

/// The `[Context] sockets` list of a Flatpak metadata file (`a;b;!c;`); a `!` entry removes. Read
/// as GKeyFile (and so `flatpak run`) reads it: the last `sockets=` wins. A file that cannot be
/// parsed at all (over the cap, a broken line) is logged and counts as no sockets, so the app runs
/// on Wayland.
pub fn context_sockets(metadata: &str) -> Vec<String> {
    let mut sockets: Vec<String> = Vec::new();
    let file = match Keyfile::parse_lenient(metadata) {
        Ok(file) => file,
        Err(e) => {
            eprintln!("ruya-session: the Flatpak metadata cannot be parsed ({e}); no sockets");
            return sockets;
        }
    };
    let Some(value) = file.get("Context", "sockets") else {
        return sockets;
    };
    for entry in value.split(';').map(str::trim).filter(|e| !e.is_empty()) {
        if let Some(removed) = entry.strip_prefix('!') {
            sockets.retain(|s| s != removed);
        } else if !sockets.iter().any(|s| s == entry) {
            sockets.push(entry.to_owned());
        }
    }
    sockets
}

/// The rule (ADR-034 point 2): X11 mode when the metadata's sockets have `x11` or `fallback-x11`
/// and not `wayland`, unless the app table's `display` decides (`x11` is X11 mode; `wayland` and
/// `gamescope` are not, the launch refuses the latter before it gets here).
pub fn needs_x11(metadata: &str, table_display: Option<Display>) -> bool {
    if let Some(display) = table_display {
        return display == Display::X11;
    }
    let sockets = context_sockets(metadata);
    let has = |name: &str| sockets.iter().any(|s| s == name);
    (has("x11") || has("fallback-x11")) && !has("wayland")
}

/// The metadata file of an installed app in the Flatpak installation under `root`.
pub fn metadata_path(root: &Path, app_id: &str) -> PathBuf {
    root.join("app")
        .join(app_id)
        .join("current")
        .join("active")
        .join("metadata")
}

/// `needs_x11` from the files: the app's metadata under `root` and its table row's `display`. A
/// file that cannot be read counts as empty (so an app without metadata runs on Wayland).
pub fn display_mode_x11(root: &Path, app_id: &str, table_display: Option<Display>) -> bool {
    if !valid_session_app_id(app_id) {
        return false;
    }
    let metadata = std::fs::read_to_string(metadata_path(root, app_id)).unwrap_or_default();
    needs_x11(&metadata, table_display)
}

/// One Xauthority record (the layout of libXau's `XauWriteAuth`): family, then address, display
/// number, auth name and auth data, each a big-endian 16-bit length and its bytes. `FamilyWild`
/// with an empty address matches any host.
pub fn xauth_record(display: u32, cookie: &[u8; COOKIE_LEN]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&FAMILY_WILD.to_be_bytes());
    let number = display.to_string();
    for field in [
        &b""[..],
        number.as_bytes(),
        COOKIE_NAME.as_bytes(),
        &cookie[..],
    ] {
        let len = u16::try_from(field.len()).expect("every field is shorter than 64 KiB");
        out.extend_from_slice(&len.to_be_bytes());
        out.extend_from_slice(field);
    }
    out
}

/// `dir/name`, with `/` on every host (these paths are Linux paths; the tests run on Windows too).
fn file_in(dir: &Path, name: &str) -> PathBuf {
    PathBuf::from(format!("{}/{name}", dir.display()))
}

pub fn socket_path(display: u32) -> PathBuf {
    PathBuf::from(format!("{X11_SOCKET_DIR}/X{display}"))
}

pub fn lock_path(display: u32) -> PathBuf {
    PathBuf::from(format!("/tmp/.X{display}-lock"))
}

/// The instance directory of `app_id` in the profile user's runtime directory.
pub fn instance_dir(runtime_dir: &Path, app_id: &str) -> PathBuf {
    PathBuf::from(format!("{}/ruya-x11/{app_id}", runtime_dir.display()))
}

/// The satellite's argument list for `display` with the cookie file `auth`. No `-terminate`:
/// `bridge_stopped` relies on Xwayland outliving the app's end, so a normal quit never looks like a
/// dead bridge.
pub fn satellite_argv(display: u32, auth: &Path) -> Vec<String> {
    vec![
        SATELLITE_PROGRAM.to_owned(),
        format!(":{display}"),
        "-nolisten".to_owned(),
        "local".to_owned(),
        "-auth".to_owned(),
        auth.to_string_lossy().into_owned(),
    ]
}

/// What changes in the helper's environment for the satellite: its runtime directory is the
/// instance directory (its `xwls-<n>` sockets land there), its `NOTIFY_SOCKET` is our private
/// datagram socket there. `WAYLAND_DISPLAY` stays the profile's.
pub fn satellite_env(dir: &Path) -> Vec<(String, Option<String>)> {
    vec![
        (
            "XDG_RUNTIME_DIR".to_owned(),
            Some(dir.to_string_lossy().into_owned()),
        ),
        (
            "NOTIFY_SOCKET".to_owned(),
            Some(file_in(dir, NOTIFY_FILE).to_string_lossy().into_owned()),
        ),
    ]
}

/// What changes in the helper's environment for the app: the X display and its cookie, SDL and
/// the session type say X11 (`console_env` says Wayland), and there is no Wayland socket, so a
/// toolkit that would try Wayland first does not.
pub fn app_env_x11(display: u32, auth: &Path) -> Vec<(String, Option<String>)> {
    vec![
        ("DISPLAY".to_owned(), Some(format!(":{display}"))),
        (
            "XAUTHORITY".to_owned(),
            Some(auth.to_string_lossy().into_owned()),
        ),
        ("SDL_VIDEODRIVER".to_owned(), Some("x11".to_owned())),
        ("XDG_SESSION_TYPE".to_owned(), Some("x11".to_owned())),
        ("WAYLAND_DISPLAY".to_owned(), None),
    ]
}

/// What this binary was asked to do, from its argv (`main.rs`): an X11 helper of an app unit,
/// or the service itself. A malformed helper call is refused, never run as the service.
#[derive(Debug, PartialEq, Eq)]
pub enum Subcommand {
    /// `x11-run <app id> [launch args]`
    Run {
        app_id: String,
        app_args: Vec<String>,
    },
    /// `x11-cleanup <app id>`
    Cleanup { app_id: String },
    /// `x11-run` or `x11-cleanup` with the wrong arguments: exit with this message.
    Bad(String),
    /// Anything else: the service (`--session` and the env overrides are `run()`'s).
    Service,
}

/// Reads the argv (`args[0]` is the program).
pub fn subcommand(args: &[String]) -> Subcommand {
    match args {
        [_, verb, app_id, app_args @ ..] if verb == "x11-run" => Subcommand::Run {
            app_id: app_id.clone(),
            app_args: app_args.to_vec(),
        },
        [_, verb, app_id] if verb == "x11-cleanup" => Subcommand::Cleanup {
            app_id: app_id.clone(),
        },
        [_, verb, ..] if verb == "x11-run" || verb == "x11-cleanup" => Subcommand::Bad(format!(
            "usage: ruya-session x11-run <app id> [launch args] | x11-cleanup <app id> (got {} arguments)",
            args.len() - 1
        )),
        _ => Subcommand::Service,
    }
}

/// The app's argument list: `flatpak run --device=input <id>` (as in Wayland mode, RUY-837) and
/// the image's launch arguments for it.
pub fn app_argv(app_id: &str, app_args: &[String]) -> Vec<String> {
    let mut argv = vec![
        "flatpak".to_owned(),
        "run".to_owned(),
        crate::spawner::DEVICE_INPUT.to_owned(),
        app_id.to_owned(),
    ];
    argv.extend(app_args.iter().cloned());
    argv
}

/// How a process ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum End {
    Code(i32),
    Signal(i32),
}

/// The OS as the helper sees it.
pub trait X11Os {
    fn exists(&self, path: &Path) -> bool;
    fn read(&self, path: &Path) -> Option<String>;
    /// Creates the directory (and missing parents) with mode 0700, also when it exists.
    fn make_private_dir(&mut self, path: &Path) -> io::Result<()>;
    /// Writes the file with mode 0600.
    fn write_private(&mut self, path: &Path, bytes: &[u8]) -> io::Result<()>;
    fn set_private(&mut self, path: &Path) -> io::Result<()>;
    fn remove_file(&mut self, path: &Path);
    fn remove_dir_all(&mut self, path: &Path);
    fn random(&mut self, buf: &mut [u8]) -> io::Result<()>;
    /// Starts a child with these changes to the helper's environment (`None` removes); its pid.
    fn spawn(&mut self, argv: &[String], env: &[(String, Option<String>)]) -> io::Result<u32>;
    /// How the child ended (it is reaped then), `None` while it runs.
    fn child_end(&mut self, pid: u32) -> Option<End>;
    /// SIGTERM to the child, SIGKILL after `grace`, and reaps it.
    fn stop_child(&mut self, pid: u32, grace: Duration);
    /// Runs a child and waits for it.
    fn run(&mut self, argv: &[String], env: &[(String, Option<String>)]) -> io::Result<End>;
    fn alive(&self, pid: u32) -> bool;
    /// Binds the private datagram socket the satellite notifies (replacing an older one).
    fn notify_bind(&mut self, path: &Path) -> io::Result<()>;
    /// Reads what has arrived on that socket; true once a `READY=1` came whose sender (the
    /// kernel's credentials, not the message) is `sender`. A message from another pid is dropped.
    fn notify_ready(&mut self, sender: u32) -> bool;
    /// The live children of `pid`.
    fn children_of(&self, pid: u32) -> Vec<u32>;
    /// Is the file owned by the user this helper runs as?
    fn is_own(&self, path: &Path) -> bool;
    fn parent_of(&self, pid: u32) -> Option<u32>;
    /// SIGTERM (or SIGKILL with `hard`) to a process that is not our child.
    fn signal(&mut self, pid: u32, hard: bool);
    fn sleep(&mut self, d: Duration);
    fn log(&mut self, line: &str);
}

/// The pid in an X lock file (`%10d\n`); the satellite's Xwayland does not write one, another
/// X server might.
fn lock_pid(os: &dyn X11Os, display: u32) -> Option<u32> {
    os.read(&lock_path(display))?.trim().parse().ok()
}

fn taken(os: &dyn X11Os, display: u32) -> bool {
    os.exists(&socket_path(display)) || os.exists(&lock_path(display))
}

/// The lowest display from `from` with neither a socket nor a lock.
pub fn free_display(os: &dyn X11Os, from: u32) -> Option<u32> {
    (from..DISPLAY_LIMIT).find(|&n| !taken(os, n))
}

enum Start {
    /// Up; the live children of the satellite (Xwayland).
    Ready(Vec<u32>),
    Failed,
}

/// Waits until the satellite `sat` has said `READY=1` on the notify socket and `display`'s socket
/// exists. The satellite is our own child, so its word is the proof; a socket or lock file that
/// another server could write is not.
fn wait_ready(os: &mut dyn X11Os, sat: u32, display: u32) -> Start {
    let mut said_ready = false;
    for _ in 0..READY_POLLS {
        if os.child_end(sat).is_some() {
            return Start::Failed;
        }
        said_ready = os.notify_ready(sat) || said_ready;
        if said_ready && os.exists(&socket_path(display)) {
            return Start::Ready(os.children_of(sat));
        }
        os.sleep(READY_POLL);
    }
    os.log(&format!("display :{display} did not come up in time"));
    os.stop_child(sat, STOP_GRACE);
    Start::Failed
}

/// Removes the instance directory and, when the display it recorded has no live server any more,
/// that display's socket and lock. A display that another server holds now is left alone.
pub fn cleanup(os: &mut dyn X11Os, dir: &Path) {
    let recorded = |os: &dyn X11Os, name: &str| {
        os.read(&file_in(dir, name))
            .and_then(|s| s.trim().parse::<u32>().ok())
    };
    let display = recorded(os, DISPLAY_FILE);
    let satellite = recorded(os, SATELLITE_FILE);
    if let Some(n) = display {
        clear_display(os, n, satellite);
    }
    os.remove_dir_all(dir);
}

/// Clears display `n` unless a server holds it: the satellite recorded in our instance directory
/// is still alive, or the lock names a live pid. A socket or lock goes only when it is ours (a
/// file of another user is never removed).
fn clear_display(os: &mut dyn X11Os, n: u32, satellite: Option<u32>) {
    let live = satellite.is_some_and(|pid| os.alive(pid))
        || lock_pid(os, n).is_some_and(|pid| os.alive(pid));
    if live {
        return;
    }
    for path in [socket_path(n), lock_path(n)] {
        if os.is_own(&path) {
            os.remove_file(&path);
        }
    }
}

/// Waits for a process that is not our child to end; SIGTERM, then SIGKILL after `STOP_GRACE`.
fn end_process(os: &mut dyn X11Os, pid: u32) {
    let polls = (STOP_GRACE.as_millis() / READY_POLL.as_millis()) as u32;
    for hard in [false, true] {
        if !os.alive(pid) {
            return;
        }
        os.signal(pid, hard);
        for _ in 0..polls {
            if !os.alive(pid) {
                return;
            }
            os.sleep(READY_POLL);
        }
    }
}

/// Did the bridge end while the app ran? The satellite is our child, so its status is known; its
/// Xwayland is not, we only see that it is gone. The line for the journal, `None` when both live.
fn bridge_stopped(os: &mut dyn X11Os, sat: u32, xwayland: &[u32]) -> Option<String> {
    if let Some(end) = os.child_end(sat) {
        let how = match end {
            End::Code(code) => format!("exited with status {code}"),
            End::Signal(sig) => format!("was killed by signal {sig}"),
        };
        return Some(format!("{SATELLITE_NAME} {how}"));
    }
    xwayland
        .iter()
        .any(|&pid| !os.alive(pid))
        .then(|| "Xwayland ended".to_owned())
}

/// The `x11-run` helper: starts a private X server, runs the app on it (with the launch
/// arguments `spawner::launch_command_in` put after the app id), cleans up. Returns how
/// the app ended, or `End::Code(EXIT_LAUNCH_FAILED)` when no X server came up.
pub fn run_helper(
    os: &mut dyn X11Os,
    app_id: &str,
    runtime_dir: Option<&str>,
    wayland: Option<&str>,
    app_args: &[String],
) -> End {
    let fail = End::Code(EXIT_LAUNCH_FAILED);
    if !valid_session_app_id(app_id) {
        os.log(&format!("not an application id: {app_id:?}"));
        return fail;
    }
    if let Some(bad) = app_args.iter().find(|a| !valid_app_arg(a)) {
        os.log(&format!("bad launch argument: {bad:?}"));
        return fail;
    }
    let Some(runtime) = runtime_dir.filter(|d| d.starts_with('/')) else {
        os.log("XDG_RUNTIME_DIR is not set");
        return fail;
    };
    if !wayland.is_some_and(|w| !w.is_empty()) {
        os.log("WAYLAND_DISPLAY is not set");
        return fail;
    }
    if !os.exists(Path::new(X11_SOCKET_DIR)) {
        os.log(&format!("{X11_SOCKET_DIR} does not exist"));
        return fail;
    }
    let dir = instance_dir(Path::new(runtime), app_id);
    // A directory left by a run whose cleanup never ran (power cut) goes first.
    if os.exists(&dir) {
        cleanup(os, &dir);
    }
    if let Err(err) = os.make_private_dir(&dir) {
        os.log(&format!("cannot make {}: {err}", dir.display()));
        return fail;
    }
    let mut cookie = [0u8; COOKIE_LEN];
    if let Err(err) = os.random(&mut cookie) {
        os.log(&format!("no random cookie: {err}"));
        os.remove_dir_all(&dir);
        return fail;
    }
    let auth = file_in(&dir, AUTH_FILE);
    let mut from = 0;
    let mut started = None;
    for _ in 0..DISPLAY_TRIES {
        let Some(n) = free_display(os, from) else {
            os.log("no free X display");
            break;
        };
        let written = os
            .write_private(&auth, &xauth_record(n, &cookie))
            .and_then(|()| {
                os.write_private(&file_in(&dir, DISPLAY_FILE), format!("{n}\n").as_bytes())
            });
        if let Err(err) = written {
            os.log(&format!("cannot write the X cookie: {err}"));
            break;
        }
        if let Err(err) = os.notify_bind(&file_in(&dir, NOTIFY_FILE)) {
            os.log(&format!("cannot bind the notify socket: {err}"));
            break;
        }
        let sat = match os.spawn(&satellite_argv(n, &auth), &satellite_env(&dir)) {
            Ok(pid) => pid,
            Err(err) => {
                os.log(&format!("cannot start {SATELLITE_PROGRAM}: {err}"));
                break;
            }
        };
        if let Err(err) = os.write_private(
            &file_in(&dir, SATELLITE_FILE),
            format!("{sat}\n").as_bytes(),
        ) {
            os.log(&format!("cannot record the satellite: {err}"));
            os.stop_child(sat, STOP_GRACE);
            break;
        }
        match wait_ready(os, sat, n) {
            Start::Ready(xwayland) => {
                started = Some((n, sat, xwayland));
                break;
            }
            Start::Failed if taken(os, n) => {
                os.log(&format!(
                    "display :{n} was taken meanwhile, trying the next one"
                ));
                from = n + 1;
            }
            Start::Failed => {
                os.log(&format!("the X server for display :{n} did not start"));
                break;
            }
        }
    }
    let Some((n, sat, xwayland)) = started else {
        os.log(&format!("{app_id}: launch failed, no X server"));
        cleanup(os, &dir);
        return fail;
    };
    if let Err(err) = os.set_private(&socket_path(n)) {
        os.log(&format!("cannot make the X socket private: {err}"));
        os.stop_child(sat, STOP_GRACE);
        for pid in xwayland {
            end_process(os, pid);
        }
        cleanup(os, &dir);
        return fail;
    }
    os.log(&format!("{app_id} runs on display :{n}"));
    let end = match os.run(&app_argv(app_id, app_args), &app_env_x11(n, &auth)) {
        Ok(end) => end,
        Err(err) => {
            os.log(&format!("cannot run flatpak: {err}"));
            fail
        }
    };
    // Looked at before the stop below, so only a bridge that ended by itself counts. An app that
    // lost its X server ends by itself, nonzero or not; the end is "crashed" either way.
    let stopped = bridge_stopped(os, sat, &xwayland);
    os.stop_child(sat, STOP_GRACE);
    for pid in xwayland {
        end_process(os, pid);
    }
    cleanup(os, &dir);
    match stopped {
        Some(which) => {
            os.log(&format!("the X11 bridge stopped: {which}"));
            match end {
                End::Code(0) => End::Code(1),
                other => other,
            }
        }
        None => end,
    }
}

/// The `x11-cleanup` subcommand (the unit's `ExecStopPost`).
pub fn run_cleanup(os: &mut dyn X11Os, app_id: &str, runtime_dir: Option<&str>) {
    if !valid_session_app_id(app_id) {
        return;
    }
    if let Some(runtime) = runtime_dir.filter(|d| d.starts_with('/')) {
        let dir = instance_dir(Path::new(runtime), app_id);
        if os.exists(&dir) {
            cleanup(os, &dir);
        }
    }
}

#[cfg(target_os = "linux")]
pub use linux::LinuxOs;

#[cfg(target_os = "linux")]
mod linux {
    use super::{End, X11Os};
    use std::collections::HashMap;
    use std::fs::{DirBuilder, OpenOptions, Permissions};
    use std::io::{self, Read, Write};
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
    use std::os::unix::io::AsRawFd;
    use std::os::unix::net::UnixDatagram;
    use std::os::unix::process::ExitStatusExt;
    use std::path::Path;
    use std::process::{Child, Command, ExitStatus, Stdio};
    use std::time::{Duration, Instant};

    #[derive(Default)]
    pub struct LinuxOs {
        children: HashMap<u32, Child>,
        notify: Option<UnixDatagram>,
    }

    fn command(argv: &[String], env: &[(String, Option<String>)]) -> Command {
        let mut cmd = Command::new(&argv[0]);
        cmd.args(&argv[1..]).stdin(Stdio::null());
        for (key, value) in env {
            match value {
                Some(v) => cmd.env(key, v),
                None => cmd.env_remove(key),
            };
        }
        cmd
    }

    fn end_of(status: ExitStatus) -> End {
        match (status.code(), status.signal()) {
            (Some(code), _) => End::Code(code),
            (None, Some(sig)) => End::Signal(sig),
            (None, None) => End::Code(1),
        }
    }

    impl X11Os for LinuxOs {
        fn exists(&self, path: &Path) -> bool {
            // The socket and the lock count even when they are dangling or unreadable.
            std::fs::symlink_metadata(path).is_ok()
        }
        fn read(&self, path: &Path) -> Option<String> {
            let mut text = String::new();
            std::fs::File::open(path)
                .ok()?
                .take(64)
                .read_to_string(&mut text)
                .ok()?;
            Some(text)
        }
        fn make_private_dir(&mut self, path: &Path) -> io::Result<()> {
            DirBuilder::new().recursive(true).mode(0o700).create(path)?;
            if let Some(parent) = path.parent() {
                std::fs::set_permissions(parent, Permissions::from_mode(0o700))?;
            }
            std::fs::set_permissions(path, Permissions::from_mode(0o700))
        }
        fn write_private(&mut self, path: &Path, bytes: &[u8]) -> io::Result<()> {
            let mut file = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(path)?;
            file.set_permissions(Permissions::from_mode(0o600))?;
            file.write_all(bytes)?;
            file.sync_all()
        }
        fn set_private(&mut self, path: &Path) -> io::Result<()> {
            std::fs::set_permissions(path, Permissions::from_mode(0o700))
        }
        fn remove_file(&mut self, path: &Path) {
            let _ = std::fs::remove_file(path);
        }
        fn remove_dir_all(&mut self, path: &Path) {
            let _ = std::fs::remove_dir_all(path);
        }
        fn random(&mut self, buf: &mut [u8]) -> io::Result<()> {
            std::fs::File::open("/dev/urandom")?.read_exact(buf)
        }
        fn spawn(&mut self, argv: &[String], env: &[(String, Option<String>)]) -> io::Result<u32> {
            let child = command(argv, env).spawn()?;
            let pid = child.id();
            self.children.insert(pid, child);
            Ok(pid)
        }
        fn child_end(&mut self, pid: u32) -> Option<End> {
            // A child that is not ours (never spawned, or stopped already) has no status to give.
            let Some(child) = self.children.get_mut(&pid) else {
                return Some(End::Code(-1));
            };
            match child.try_wait() {
                Ok(None) => None,
                Ok(Some(status)) => Some(end_of(status)),
                Err(_) => Some(End::Code(-1)),
            }
        }
        fn stop_child(&mut self, pid: u32, grace: Duration) {
            let Some(mut child) = self.children.remove(&pid) else {
                return;
            };
            if matches!(child.try_wait(), Ok(Some(_))) {
                return;
            }
            // SAFETY: plain kill(2) on our own unreaped child.
            unsafe {
                libc::kill(pid as libc::pid_t, libc::SIGTERM);
            }
            let deadline = Instant::now() + grace;
            while Instant::now() < deadline {
                if !matches!(child.try_wait(), Ok(None)) {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            let _ = child.kill();
            let _ = child.wait();
        }
        fn run(&mut self, argv: &[String], env: &[(String, Option<String>)]) -> io::Result<End> {
            Ok(end_of(command(argv, env).status()?))
        }
        fn alive(&self, pid: u32) -> bool {
            // Only a process that is not a zombie counts.
            let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else {
                return false;
            };
            let state = stat.rsplit_once(')').map(|(_, rest)| rest.trim_start());
            !state.is_some_and(|s| s.starts_with('Z') || s.starts_with('X'))
        }
        fn notify_bind(&mut self, path: &Path) -> io::Result<()> {
            let _ = std::fs::remove_file(path);
            let sock = UnixDatagram::bind(path)?;
            sock.set_nonblocking(true)?;
            let on: libc::c_int = 1;
            // SAFETY: setsockopt(2) on our own open socket with a c_int that outlives the call.
            let rc = unsafe {
                libc::setsockopt(
                    sock.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_PASSCRED,
                    &on as *const libc::c_int as *const libc::c_void,
                    std::mem::size_of::<libc::c_int>() as libc::socklen_t,
                )
            };
            if rc != 0 {
                return Err(io::Error::last_os_error());
            }
            self.notify = Some(sock);
            Ok(())
        }
        fn notify_ready(&mut self, sender: u32) -> bool {
            let Some(sock) = &self.notify else {
                return false;
            };
            let fd = sock.as_raw_fd();
            let mut ready = false;
            loop {
                let mut data = [0u8; 512];
                // 8-byte aligned room for one SCM_CREDENTIALS message.
                let mut control = [0u64; 8];
                let mut iov = libc::iovec {
                    iov_base: data.as_mut_ptr() as *mut libc::c_void,
                    iov_len: data.len(),
                };
                // SAFETY: an all-zero msghdr is a valid empty one.
                let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
                msg.msg_iov = &mut iov;
                msg.msg_iovlen = 1;
                msg.msg_control = control.as_mut_ptr() as *mut libc::c_void;
                msg.msg_controllen = std::mem::size_of_val(&control) as _;
                // SAFETY: msg points at buffers that live through the call.
                let n = unsafe { libc::recvmsg(fd, &mut msg, libc::MSG_DONTWAIT) };
                if n < 0 {
                    break;
                }
                let mut from: Option<u32> = None;
                // SAFETY: the cmsg walk stays inside `control`, as filled in by the kernel.
                unsafe {
                    let mut c = libc::CMSG_FIRSTHDR(&msg);
                    while !c.is_null() {
                        if (*c).cmsg_level == libc::SOL_SOCKET
                            && (*c).cmsg_type == libc::SCM_CREDENTIALS
                        {
                            let cred =
                                std::ptr::read_unaligned(libc::CMSG_DATA(c) as *const libc::ucred);
                            from = Some(cred.pid as u32);
                        }
                        c = libc::CMSG_NXTHDR(&msg, c);
                    }
                }
                let text = String::from_utf8_lossy(&data[..n as usize]).into_owned();
                if from == Some(sender) && text.lines().any(|l| l == "READY=1") {
                    ready = true;
                }
            }
            ready
        }
        fn children_of(&self, pid: u32) -> Vec<u32> {
            let Ok(entries) = std::fs::read_dir("/proc") else {
                return Vec::new();
            };
            entries
                .flatten()
                .filter_map(|e| e.file_name().to_str()?.parse::<u32>().ok())
                .filter(|&c| self.parent_of(c) == Some(pid) && self.alive(c))
                .collect()
        }
        fn is_own(&self, path: &Path) -> bool {
            // SAFETY: geteuid(2) cannot fail.
            let me = unsafe { libc::geteuid() };
            std::fs::symlink_metadata(path).is_ok_and(|m| m.uid() == me)
        }
        fn parent_of(&self, pid: u32) -> Option<u32> {
            let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
            // "pid (comm) state ppid ...": comm may hold spaces and parentheses.
            let (_, rest) = stat.rsplit_once(')')?;
            rest.split_whitespace().nth(1)?.parse().ok()
        }
        fn signal(&mut self, pid: u32, hard: bool) {
            let sig = if hard { libc::SIGKILL } else { libc::SIGTERM };
            // SAFETY: plain kill(2); a pid that is gone gives ESRCH, which is ignored.
            unsafe {
                libc::kill(pid as libc::pid_t, sig);
            }
        }
        fn sleep(&mut self, d: Duration) {
            std::thread::sleep(d);
        }
        fn log(&mut self, line: &str) {
            eprintln!("ruya-session x11: {line}");
        }
    }

    /// Ends this process the way the app ended: its exit code, or the same signal.
    pub fn exit_like(end: End) -> ! {
        match end {
            End::Code(code) => std::process::exit(code),
            End::Signal(sig) => {
                // SAFETY: restores the default action and raises the signal on ourselves.
                unsafe {
                    libc::signal(sig, libc::SIG_DFL);
                    libc::raise(sig);
                }
                std::process::exit(128 + sig)
            }
        }
    }
}

#[cfg(target_os = "linux")]
pub use linux::exit_like;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::apps::AppTable;
    use std::collections::{BTreeMap, BTreeSet};

    const APP: &str = "io.github.divVerent.aaaaxy";
    const RUNTIME: &str = "/run/user/1001";
    const WAYLAND: &str = "/run/ruya-wayland/ruya-p1";

    fn dir() -> PathBuf {
        instance_dir(Path::new(RUNTIME), APP)
    }

    #[test]
    fn x11_mode_follows_the_metadata_sockets_and_the_override_list() {
        let meta = |sockets: &str| {
            format!("[Application]\nname={APP}\n\n[Context]\nshared=network;ipc;\nsockets={sockets}\ndevices=all;\n")
        };
        // x11 only, fallback-x11 only: X11 mode.
        assert!(needs_x11(&meta("x11;pulseaudio;"), None));
        assert!(needs_x11(&meta("fallback-x11;pulseaudio;"), None));
        // Wayland offered: Wayland, also next to x11 or fallback-x11.
        assert!(!needs_x11(&meta("wayland;x11;pulseaudio;"), None));
        assert!(!needs_x11(&meta("wayland;fallback-x11;"), None));
        assert!(!needs_x11(&meta("wayland;pulseaudio;"), None));
        // No display socket at all, or no metadata: Wayland (the default).
        assert!(!needs_x11(&meta("pulseaudio;"), None));
        assert!(!needs_x11("", None));
        // A removed entry does not count.
        assert!(!needs_x11(&meta("x11;!x11;"), None));
        assert!(needs_x11(&meta("wayland;!wayland;x11;"), None));
        // `sockets` outside [Context] does not count.
        assert!(!needs_x11("[Application]\nsockets=x11;\n", None));
        // The app table's display decides over the sockets, both ways.
        assert!(needs_x11(&meta("wayland;"), Some(Display::X11)));
        assert!(!needs_x11(&meta("x11;"), Some(Display::Wayland)));
        assert!(!needs_x11(&meta("x11;"), Some(Display::Gamescope)));
        // Read as GKeyFile reads it: the last `sockets=` wins, a repeated group merges.
        assert!(needs_x11(
            "[Context]\nsockets=wayland;\nsockets=x11;\n",
            None
        ));
        assert!(!needs_x11(
            "[Context]\nsockets=x11;\nsockets=wayland;\n",
            None
        ));
        assert!(needs_x11(
            "[Context]\nshared=ipc;\n[Application]\nname=a\n[Context]\nsockets=x11;\n",
            None
        ));
        // Metadata that cannot be parsed at all (a broken line, over the cap) counts as no sockets.
        assert!(!needs_x11("[Context]\nsockets=x11;\nnonsense\n", None));
        let huge = format!("[Context]\nsockets={}\n", "x11;".repeat(20_000));
        assert!(context_sockets(&huge).is_empty());
    }

    #[test]
    fn the_image_runs_steam_in_x11_mode() {
        // The shipped table, against the Steam Flatpak's real sockets (Flathub, 2026-11-17): it
        // lists wayland too, so without the table's display Steam would start without a DISPLAY.
        let table = AppTable::load(&crate::apps::tests::image_dir());
        let steam = "[Context]\nshared=ipc;network;\nsockets=pulseaudio;wayland;x11;\n";
        let id = "com.valvesoftware.Steam";
        assert!(!needs_x11(steam, None));
        assert!(needs_x11(steam, table.display(id)));
        assert!(!needs_x11(
            "[Context]\nsockets=wayland;\n",
            table.display(APP)
        ));
    }

    #[test]
    fn the_mode_is_read_from_the_installed_metadata() {
        let root = std::env::temp_dir().join(format!("ruya-x11-meta-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let meta = metadata_path(&root, APP);
        std::fs::create_dir_all(meta.parent().expect("parent")).expect("dirs");
        std::fs::write(&meta, "[Context]\nsockets=x11;\n").expect("write");
        assert!(display_mode_x11(&root, APP, None));
        std::fs::write(&meta, "[Context]\nsockets=wayland;\n").expect("write");
        assert!(!display_mode_x11(&root, APP, None));
        assert!(display_mode_x11(&root, APP, Some(Display::X11)));
        assert!(!display_mode_x11(&root, "org.ruyaos.Racer", None));
        assert!(!display_mode_x11(&root, "../x", Some(Display::X11)));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_cookie_record_has_the_libxau_layout() {
        let cookie: [u8; 16] = std::array::from_fn(|i| i as u8 + 1);
        let record = xauth_record(12, &cookie);
        let mut want = vec![0xff, 0xff]; // FamilyWild
        want.extend([0, 0]); // empty address
        want.extend([0, 2, b'1', b'2']); // display number "12"
        want.extend([0, 18]);
        want.extend(b"MIT-MAGIC-COOKIE-1");
        want.extend([0, 16]);
        want.extend(1..=16u8);
        assert_eq!(record, want);
        assert_eq!(xauth_record(0, &cookie)[4..7], [0, 1, b'0']);
    }

    #[test]
    fn the_satellite_and_the_app_get_their_arguments_and_environment() {
        let auth = file_in(&dir(), "Xauthority");
        assert_eq!(
            satellite_argv(3, &auth),
            [
                "/usr/bin/xwayland-satellite",
                ":3",
                "-nolisten",
                "local",
                "-auth",
                "/run/user/1001/ruya-x11/io.github.divVerent.aaaaxy/Xauthority",
            ]
        );
        assert_eq!(
            satellite_env(&dir()),
            [
                (
                    "XDG_RUNTIME_DIR".to_owned(),
                    Some("/run/user/1001/ruya-x11/io.github.divVerent.aaaaxy".to_owned())
                ),
                (
                    "NOTIFY_SOCKET".to_owned(),
                    Some("/run/user/1001/ruya-x11/io.github.divVerent.aaaaxy/notify".to_owned())
                ),
            ]
        );
        let s = |v: &str| Some(v.to_owned());
        assert_eq!(
            app_env_x11(3, &auth),
            [
                ("DISPLAY".to_owned(), s(":3")),
                (
                    "XAUTHORITY".to_owned(),
                    s("/run/user/1001/ruya-x11/io.github.divVerent.aaaaxy/Xauthority")
                ),
                ("SDL_VIDEODRIVER".to_owned(), s("x11")),
                ("XDG_SESSION_TYPE".to_owned(), s("x11")),
                ("WAYLAND_DISPLAY".to_owned(), None),
            ]
        );
        assert_eq!(
            app_argv(APP, &[]),
            ["flatpak", "run", "--device=input", APP]
        );
        let argv = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            subcommand(&argv(&["rs", "x11-run", APP, "-gamepadui"])),
            Subcommand::Run {
                app_id: APP.to_owned(),
                app_args: vec!["-gamepadui".to_owned()]
            }
        );
        assert_eq!(
            subcommand(&argv(&["rs", "x11-cleanup", APP])),
            Subcommand::Cleanup {
                app_id: APP.to_owned()
            }
        );
        // A malformed helper call is refused, never the service (RUY-801 review).
        assert!(matches!(
            subcommand(&argv(&["rs", "x11-cleanup", APP, "x"])),
            Subcommand::Bad(_)
        ));
        assert!(matches!(
            subcommand(&argv(&["rs", "x11-run"])),
            Subcommand::Bad(_)
        ));
        assert_eq!(subcommand(&argv(&["rs"])), Subcommand::Service);
        assert_eq!(subcommand(&argv(&["rs", "--session"])), Subcommand::Service);
        assert_eq!(
            app_argv(APP, &["-gamepadui".to_owned()]),
            ["flatpak", "run", "--device=input", APP, "-gamepadui"]
        );
        assert_eq!(socket_path(3), Path::new("/tmp/.X11-unix/X3"));
        assert_eq!(lock_path(3), Path::new("/tmp/.X3-lock"));
    }

    /// A fake OS: files with their modes, an X server per satellite that comes up (or does not).
    #[derive(Default)]
    struct Fake {
        files: BTreeMap<PathBuf, (Vec<u8>, u32)>,
        dirs: BTreeMap<PathBuf, u32>,
        procs: BTreeMap<u32, u32>, // live pid -> parent
        next_pid: u32,
        /// Displays a racing launch takes between our choice and our satellite's start.
        stolen: BTreeSet<u32>,
        /// Satellites that die without serving.
        broken: bool,
        /// A satellite that ends after so many more polls.
        dying: Option<(u32, u32)>,
        /// Satellites that never come up.
        hang: bool,
        /// Satellites that serve the socket but never say READY=1.
        mute: bool,
        /// Satellites whose READY=1 comes from another pid.
        spoof: bool,
        /// Satellites that say READY=1 but never make the socket.
        no_socket: bool,
        /// READY=1 messages waiting on the notify socket (sender pids).
        notes: Vec<u32>,
        /// Paths of the notify socket binds.
        bound: Vec<PathBuf>,
        /// Files owned by another user.
        foreign: BTreeSet<PathBuf>,
        /// How the app ends.
        app_end: Option<End>,
        /// While the app runs the satellite ends this way (its Xwayland with it).
        sat_dies_in_run: Option<End>,
        /// While the app runs the satellite's Xwayland ends, the satellite lives.
        xwl_dies_in_run: bool,
        /// How the satellite ended, once it has.
        sat_end: Option<End>,
        /// What happened, in order.
        log: Vec<String>,
        app_env: Vec<(String, Option<String>)>,
        app_saw_socket_mode: Option<u32>,
        auth_at_run: Option<(Vec<u8>, u32)>,
        dir_mode_at_run: Option<u32>,
        sat_at_run: Option<Vec<u8>>,
    }

    impl Fake {
        fn new() -> Self {
            let mut f = Fake {
                next_pid: 100,
                app_end: Some(End::Code(0)),
                ..Fake::default()
            };
            f.dirs.insert(PathBuf::from(X11_SOCKET_DIR), 0o1777);
            f
        }
        /// Another server already holds `n`.
        fn occupy(&mut self, n: u32) {
            self.next_pid += 1;
            let pid = self.next_pid;
            self.procs.insert(pid, 1);
            self.files
                .insert(lock_path(n), (format!("{pid:>10}\n").into_bytes(), 0o444));
            self.files.insert(socket_path(n), (Vec::new(), 0o777));
        }
        fn events(&self, prefix: &str) -> Vec<String> {
            self.log
                .iter()
                .filter(|l| l.starts_with(prefix))
                .cloned()
                .collect()
        }
    }

    impl X11Os for Fake {
        fn exists(&self, path: &Path) -> bool {
            self.files.contains_key(path) || self.dirs.contains_key(path)
        }
        fn read(&self, path: &Path) -> Option<String> {
            self.files
                .get(path)
                .map(|(b, _)| String::from_utf8_lossy(b).into_owned())
        }
        fn make_private_dir(&mut self, path: &Path) -> io::Result<()> {
            self.dirs.insert(path.to_path_buf(), 0o700);
            if let Some(p) = path.parent() {
                self.dirs.insert(p.to_path_buf(), 0o700);
            }
            Ok(())
        }
        fn write_private(&mut self, path: &Path, bytes: &[u8]) -> io::Result<()> {
            self.files
                .insert(path.to_path_buf(), (bytes.to_vec(), 0o600));
            Ok(())
        }
        fn set_private(&mut self, path: &Path) -> io::Result<()> {
            let file = self
                .files
                .get_mut(path)
                .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?;
            file.1 = 0o700;
            Ok(())
        }
        fn remove_file(&mut self, path: &Path) {
            if self.files.remove(path).is_some() {
                self.log.push(format!("rm {}", path.display()));
            }
        }
        fn remove_dir_all(&mut self, path: &Path) {
            self.files.retain(|p, _| !p.starts_with(path));
            self.dirs.retain(|p, _| !p.starts_with(path));
            self.log.push(format!("rmdir {}", path.display()));
        }
        fn random(&mut self, buf: &mut [u8]) -> io::Result<()> {
            buf.fill(0xab);
            Ok(())
        }
        fn spawn(&mut self, argv: &[String], env: &[(String, Option<String>)]) -> io::Result<u32> {
            self.log.push(format!("spawn {}", argv.join(" ")));
            assert_eq!(env, satellite_env(&dir()));
            self.next_pid += 1;
            let sat = self.next_pid;
            let n: u32 = argv[1][1..].parse().expect("display");
            if self.stolen.remove(&n) {
                // The racing launch wins: its server holds n, ours fails on the lock, and our
                // satellite lives on a few polls before it ends (its Xwayland exited early).
                self.occupy(n);
                self.procs.insert(sat, 1);
                self.dying = Some((sat, 3));
                return Ok(sat);
            }
            self.procs.insert(sat, 1);
            if self.broken || self.hang {
                return Ok(sat);
            }
            self.next_pid += 1;
            let xwl = self.next_pid;
            self.procs.insert(xwl, sat);
            // The satellite writes no lock file; it makes the socket itself and says READY=1.
            if !self.no_socket {
                self.files.insert(socket_path(n), (Vec::new(), 0o777));
            }
            if self.spoof {
                self.notes.push(9999);
            } else if !self.mute {
                self.notes.push(sat);
            }
            // The xwls sockets of the satellite land in its runtime directory.
            self.files
                .insert(file_in(&dir(), &format!("xwls-{n}")), (Vec::new(), 0o755));
            Ok(sat)
        }
        fn child_end(&mut self, pid: u32) -> Option<End> {
            if let Some((sat, polls)) = self.dying {
                if sat == pid {
                    if polls == 0 {
                        self.procs.remove(&pid);
                        self.dying = None;
                    } else {
                        self.dying = Some((sat, polls - 1));
                    }
                }
            }
            if self.broken {
                self.procs.remove(&pid);
            }
            if self.procs.contains_key(&pid) {
                None
            } else {
                Some(self.sat_end.unwrap_or(End::Code(0)))
            }
        }
        fn stop_child(&mut self, pid: u32, _grace: Duration) {
            if self.procs.remove(&pid).is_some() {
                self.log.push(format!("stop {pid}"));
            }
            // Xwayland ends with its satellite (EOF on its Wayland connection), without removing
            // its socket and lock when it is killed.
            let orphans: Vec<u32> = self
                .procs
                .iter()
                .filter(|(_, &p)| p == pid)
                .map(|(&c, _)| c)
                .collect();
            for c in orphans {
                self.procs.remove(&c);
            }
        }
        fn run(&mut self, argv: &[String], env: &[(String, Option<String>)]) -> io::Result<End> {
            self.log.push(format!("run {}", argv.join(" ")));
            self.app_env = env.to_vec();
            let display = env
                .iter()
                .find(|(k, _)| k == "DISPLAY")
                .and_then(|(_, v)| v.as_ref())
                .and_then(|v| v[1..].parse::<u32>().ok())
                .expect("DISPLAY");
            self.app_saw_socket_mode = self.files.get(&socket_path(display)).map(|f| f.1);
            self.auth_at_run = self.files.get(&file_in(&dir(), "Xauthority")).cloned();
            self.dir_mode_at_run = self.dirs.get(&dir()).copied();
            self.sat_at_run = self
                .files
                .get(&file_in(&dir(), "satellite"))
                .map(|f| f.0.clone());
            if let Some(end) = self.sat_dies_in_run {
                let sat = *self
                    .procs
                    .iter()
                    .find(|(_, &p)| p == 1)
                    .expect("satellite")
                    .0;
                self.procs.retain(|&c, &mut p| c != sat && p != sat);
                self.sat_end = Some(end);
            }
            if self.xwl_dies_in_run {
                self.procs.retain(|_, &mut p| p == 1);
            }
            self.app_end
                .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
        }
        fn alive(&self, pid: u32) -> bool {
            self.procs.contains_key(&pid)
        }
        fn notify_bind(&mut self, path: &Path) -> io::Result<()> {
            self.bound.push(path.to_path_buf());
            self.notes.clear();
            Ok(())
        }
        fn notify_ready(&mut self, sender: u32) -> bool {
            let got = self.notes.contains(&sender);
            self.notes.clear();
            got
        }
        fn children_of(&self, pid: u32) -> Vec<u32> {
            self.procs
                .iter()
                .filter(|(_, &p)| p == pid)
                .map(|(&c, _)| c)
                .collect()
        }
        fn is_own(&self, path: &Path) -> bool {
            !self.foreign.contains(path)
        }
        fn parent_of(&self, pid: u32) -> Option<u32> {
            self.procs.get(&pid).copied()
        }
        fn signal(&mut self, pid: u32, hard: bool) {
            self.log.push(format!("signal {pid} {hard}"));
            self.procs.remove(&pid);
        }
        fn sleep(&mut self, _d: Duration) {}
        fn log(&mut self, line: &str) {
            self.log.push(format!("log {line}"));
        }
    }

    fn helper(os: &mut Fake) -> End {
        run_helper(os, APP, Some(RUNTIME), Some(WAYLAND), &[])
    }

    #[test]
    fn the_helper_starts_a_private_server_runs_the_app_and_cleans_up() {
        let mut os = Fake::new();
        os.occupy(0); // another instance runs on :0
        os.app_end = Some(End::Code(7));
        assert_eq!(helper(&mut os), End::Code(7));
        // The lowest free display, with the cookie file.
        assert_eq!(
            os.events("spawn"),
            [format!(
                "spawn /usr/bin/xwayland-satellite :1 -nolisten local -auth {}",
                file_in(&dir(), "Xauthority").display()
            )]
        );
        assert_eq!(
            os.events("run"),
            [format!("run flatpak run --device=input {APP}")]
        );
        assert!(os.log.contains(&format!("log {APP} runs on display :1")));
        assert_eq!(os.app_env, app_env_x11(1, &file_in(&dir(), "Xauthority")));
        // The socket was made 0700 before the app started.
        assert_eq!(os.app_saw_socket_mode, Some(0o700));
        // Cleanup: the directory (cookie, xwls sockets), our socket and lock; not :0's.
        assert!(!os.exists(&dir()));
        assert!(!os.exists(&socket_path(1)) && !os.exists(&lock_path(1)));
        assert!(os.exists(&socket_path(0)) && os.exists(&lock_path(0)));
        assert_eq!(
            os.dirs.get(&dir().parent().expect("p").to_path_buf()),
            Some(&0o700)
        );
    }

    #[test]
    fn the_cookie_file_is_private_and_holds_the_record_of_the_display() {
        let mut os = Fake::new();
        assert_eq!(helper(&mut os), End::Code(0));
        // While the app ran: the 0700 directory and the 0600 cookie for :0.
        assert_eq!(os.dir_mode_at_run, Some(0o700));
        assert_eq!(
            os.auth_at_run,
            Some((xauth_record(0, &[0xab; COOKIE_LEN]), 0o600))
        );
        assert!(!os.exists(&file_in(&dir(), "Xauthority")));
    }

    #[test]
    fn a_display_taken_meanwhile_is_retried_with_the_next_one() {
        let mut os = Fake::new();
        os.stolen.insert(0);
        assert_eq!(helper(&mut os), End::Code(0));
        let spawns = os.events("spawn");
        assert_eq!(spawns.len(), 2, "{:?}", os.log);
        assert!(spawns[0].contains(" :0 ") && spawns[1].contains(" :1 "));
        assert!(os
            .log
            .contains(&"log display :0 was taken meanwhile, trying the next one".to_owned()));
        assert_eq!(os.app_env[0], ("DISPLAY".to_owned(), Some(":1".to_owned())));
        // The cookie was rewritten for :1 before the second satellite.
        assert_eq!(
            os.auth_at_run.as_ref().map(|a| a.0.clone()),
            Some(xauth_record(1, &[0xab; COOKIE_LEN]))
        );
        // The winner's :0 stays.
        assert!(os.exists(&socket_path(0)));
    }

    #[test]
    fn the_launch_fails_after_a_few_taken_displays() {
        let mut os = Fake::new();
        os.stolen.extend(0..DISPLAY_TRIES + 2);
        assert_eq!(helper(&mut os), End::Code(EXIT_LAUNCH_FAILED));
        assert_eq!(os.events("spawn").len(), DISPLAY_TRIES as usize);
        assert!(os.events("run").is_empty());
        assert!(os
            .log
            .contains(&format!("log {APP}: launch failed, no X server")));
        assert!(!os.exists(&dir()));
    }

    #[test]
    fn a_satellite_that_dies_or_hangs_fails_the_launch_without_retry() {
        for (broken, hang) in [(true, false), (false, true)] {
            let mut os = Fake::new();
            os.broken = broken;
            os.hang = hang;
            assert_eq!(helper(&mut os), End::Code(EXIT_LAUNCH_FAILED));
            assert_eq!(os.events("spawn").len(), 1, "{:?}", os.log);
            assert!(os.events("run").is_empty());
            assert!(!os.exists(&dir()));
            if hang {
                assert!(os
                    .log
                    .contains(&"log display :0 did not come up in time".to_owned()));
                assert!(os.procs.is_empty(), "the hanging satellite is stopped");
            }
        }
    }

    #[test]
    fn ready_needs_the_satellites_own_ready_and_the_socket() {
        // The socket without READY, READY from another pid, READY without the socket: none counts.
        for mode in ["mute", "spoof", "no_socket"] {
            let mut os = Fake::new();
            match mode {
                "mute" => os.mute = true,
                "spoof" => os.spoof = true,
                _ => os.no_socket = true,
            }
            assert_eq!(helper(&mut os), End::Code(EXIT_LAUNCH_FAILED), "{mode}");
            assert!(os.events("run").is_empty(), "{mode}");
            assert!(
                os.log
                    .contains(&"log display :0 did not come up in time".to_owned()),
                "{mode}"
            );
            assert!(os.procs.is_empty(), "{mode}: the satellite is stopped");
        }
        // READY from the satellite plus the socket: up, no lock file needed.
        let mut os = Fake::new();
        assert_eq!(helper(&mut os), End::Code(0));
        assert_eq!(os.events("run").len(), 1);
        assert_eq!(os.bound, [file_in(&dir(), "notify")]);
    }

    #[test]
    fn a_satellite_that_ends_before_ready_fails_the_launch() {
        let mut os = Fake::new();
        os.broken = true;
        assert_eq!(helper(&mut os), End::Code(EXIT_LAUNCH_FAILED));
        assert!(os.events("run").is_empty());
    }

    #[test]
    fn a_bridge_that_ends_while_the_app_runs_is_logged_once() {
        let line = |os: &Fake| os.events("log the X11 bridge stopped");
        // The satellite exits mid-run; the app ends with an error of its own.
        let mut os = Fake::new();
        os.sat_dies_in_run = Some(End::Code(3));
        os.app_end = Some(End::Code(1));
        assert_eq!(helper(&mut os), End::Code(1));
        assert_eq!(
            line(&os),
            ["log the X11 bridge stopped: xwayland-satellite exited with status 3"]
        );
        // Killed by a signal.
        let mut os = Fake::new();
        os.sat_dies_in_run = Some(End::Signal(9));
        os.app_end = Some(End::Code(1));
        helper(&mut os);
        assert_eq!(
            line(&os),
            ["log the X11 bridge stopped: xwayland-satellite was killed by signal 9"]
        );
        // Xwayland exits, the satellite lives on; an app that ends 0 anyway is not a clean end.
        let mut os = Fake::new();
        os.xwl_dies_in_run = true;
        assert_eq!(helper(&mut os), End::Code(1));
        assert_eq!(line(&os), ["log the X11 bridge stopped: Xwayland ended"]);
        assert!(!os.exists(&dir()), "the cleanup still runs");
    }

    #[test]
    fn a_normal_app_end_logs_no_bridge_line() {
        for app_end in [End::Code(0), End::Code(7), End::Signal(15)] {
            let mut os = Fake::new();
            os.app_end = Some(app_end);
            assert_eq!(helper(&mut os), app_end);
            assert!(os.events("log the X11 bridge").is_empty(), "{:?}", os.log);
        }
    }

    #[test]
    fn the_satellite_is_recorded_while_the_app_runs() {
        let mut os = Fake::new();
        assert_eq!(helper(&mut os), End::Code(0));
        assert_eq!(os.events("spawn").len(), 1);
        // The first pid the fake hands out is 101.
        assert_eq!(os.sat_at_run, Some(b"101\n".to_vec()));
    }

    #[test]
    fn cleanup_removes_only_our_own_stale_socket() {
        let d = dir();
        let leftover = |os: &mut Fake, sat: &[u8]| {
            os.make_private_dir(&d).expect("dir");
            os.write_private(&file_in(&d, "display"), b"4\n")
                .expect("w");
            os.write_private(&file_in(&d, "satellite"), sat).expect("w");
            os.files.insert(socket_path(4), (Vec::new(), 0o700));
        };
        // A dead satellite of ours, a socket and no lock at all: the socket goes.
        let mut os = Fake::new();
        leftover(&mut os, b"555\n");
        cleanup(&mut os, &d);
        assert!(!os.exists(&socket_path(4)) && !os.exists(&d));
        // The socket belongs to another user: it stays, our directory goes.
        let mut os = Fake::new();
        leftover(&mut os, b"555\n");
        os.foreign.insert(socket_path(4));
        cleanup(&mut os, &d);
        assert!(os.exists(&socket_path(4)) && !os.exists(&d));
        // The satellite is alive: nothing of :4 is touched.
        let mut os = Fake::new();
        leftover(&mut os, b"555\n");
        os.procs.insert(555, 1);
        cleanup(&mut os, &d);
        assert!(os.exists(&socket_path(4)) && !os.exists(&d));
        // Another display's socket is never touched.
        let mut os = Fake::new();
        leftover(&mut os, b"555\n");
        os.occupy(5);
        cleanup(&mut os, &d);
        assert!(os.exists(&socket_path(5)) && os.exists(&lock_path(5)));
    }

    #[test]
    fn a_socket_without_a_lock_is_a_taken_display() {
        let mut os = Fake::new();
        os.files.insert(socket_path(0), (Vec::new(), 0o777));
        os.files.insert(socket_path(1), (Vec::new(), 0o777));
        assert_eq!(free_display(&os, 0), Some(2));
        assert_eq!(helper(&mut os), End::Code(0));
        assert!(os.events("spawn")[0].contains(" :2 "));
        assert!(os.exists(&socket_path(0)) && os.exists(&socket_path(1)));
    }

    #[test]
    fn the_helper_refuses_a_broken_environment() {
        let mut os = Fake::new();
        assert_eq!(
            run_helper(&mut os, "../x", Some(RUNTIME), Some(WAYLAND), &[]),
            End::Code(EXIT_LAUNCH_FAILED)
        );
        assert_eq!(
            run_helper(
                &mut os,
                APP,
                Some(RUNTIME),
                Some(WAYLAND),
                &["a;b".to_owned()]
            ),
            End::Code(EXIT_LAUNCH_FAILED)
        );
        assert_eq!(
            run_helper(&mut os, APP, None, Some(WAYLAND), &[]),
            End::Code(EXIT_LAUNCH_FAILED)
        );
        assert_eq!(
            run_helper(&mut os, APP, Some("run/user"), Some(WAYLAND), &[]),
            End::Code(EXIT_LAUNCH_FAILED)
        );
        assert_eq!(
            run_helper(&mut os, APP, Some(RUNTIME), None, &[]),
            End::Code(EXIT_LAUNCH_FAILED)
        );
        os.dirs.remove(Path::new(X11_SOCKET_DIR));
        assert_eq!(helper(&mut os), End::Code(EXIT_LAUNCH_FAILED));
        assert!(os
            .log
            .contains(&"log /tmp/.X11-unix does not exist".to_owned()));
        assert!(os.events("spawn").is_empty());
    }

    #[test]
    fn a_signal_that_ended_the_app_is_handed_on_after_the_cleanup() {
        let mut os = Fake::new();
        os.app_end = Some(End::Signal(11));
        assert_eq!(helper(&mut os), End::Signal(11));
        assert!(!os.exists(&dir()));
        assert!(os.procs.is_empty());
    }

    #[test]
    fn the_stop_post_cleanup_removes_what_a_killed_run_left() {
        // A Stop killed the unit: the files of :2 are left (Xwayland died by SIGKILL).
        let mut os = Fake::new();
        let d = dir();
        os.make_private_dir(&d).expect("dir");
        os.write_private(&file_in(&d, "display"), b"2\n")
            .expect("w");
        os.write_private(&file_in(&d, "Xauthority"), b"x")
            .expect("w");
        os.files.insert(file_in(&d, "xwls-2"), (Vec::new(), 0o755));
        os.files
            .insert(lock_path(2), (b"      4242\n".to_vec(), 0o444));
        os.files.insert(socket_path(2), (Vec::new(), 0o700));
        os.occupy(3);
        run_cleanup(&mut os, APP, Some(RUNTIME));
        assert!(!os.exists(&d));
        assert!(!os.exists(&socket_path(2)) && !os.exists(&lock_path(2)));
        assert!(os.exists(&socket_path(3)));

        // The display was taken by a live server since: its files stay, the directory goes.
        let mut os = Fake::new();
        os.make_private_dir(&d).expect("dir");
        os.write_private(&file_in(&d, "display"), b"3\n")
            .expect("w");
        os.occupy(3);
        run_cleanup(&mut os, APP, Some(RUNTIME));
        assert!(!os.exists(&d));
        assert!(os.exists(&socket_path(3)) && os.exists(&lock_path(3)));

        // Nothing to do, or a bad id: nothing happens.
        let mut os = Fake::new();
        run_cleanup(&mut os, APP, Some(RUNTIME));
        run_cleanup(&mut os, "../..", Some(RUNTIME));
        run_cleanup(&mut os, APP, None);
        assert!(os.log.is_empty());
    }

    #[test]
    fn a_directory_left_by_an_earlier_run_is_cleaned_first() {
        let mut os = Fake::new();
        let d = dir();
        os.make_private_dir(&d).expect("dir");
        os.write_private(&file_in(&d, "display"), b"0\n")
            .expect("w");
        os.files.insert(socket_path(0), (Vec::new(), 0o700));
        assert_eq!(helper(&mut os), End::Code(0));
        // The stale :0 was removed, so the new server got :0 again.
        assert!(os.events("spawn")[0].contains(" :0 "));
    }

    #[test]
    fn the_free_display_is_the_lowest_without_socket_or_lock() {
        let mut os = Fake::new();
        assert_eq!(free_display(&os, 0), Some(0));
        os.occupy(0);
        os.files.insert(lock_path(1), (b"1\n".to_vec(), 0o444));
        os.files.insert(socket_path(2), (Vec::new(), 0o777));
        assert_eq!(free_display(&os, 0), Some(3));
        assert_eq!(free_display(&os, 5), Some(5));
        assert_eq!(free_display(&os, DISPLAY_LIMIT), None);
    }
}
