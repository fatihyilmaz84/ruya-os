//! The real spawner (Linux): every app is one transient service in the profile user's systemd
//! manager, started with `systemd-run --machine=<user>@.host --wait` (`spawner::launch_command`).
//! That process lives as long as the app and prints its start and end, which `RunFollower` turns
//! into `UnitEvent`s; `Stop` and the kill go to the same unit through `systemctl --machine=`.
//!
//! Why this and not the manager's D-Bus API: `--machine=<user>@.host` is the supported way for
//! root to reach another user's manager (it needs no access to `/run/user/<uid>`), and
//! `--wait` hands over the unit's end, which the manager forgets the moment a `--collect`ed unit
//! ends. The cost is one small process per running app.
//!
//! A profile user's manager has to outlive the session that `systemd-run` opens for its call
//! (logind stops an idle manager after ten seconds, taking the app with it), so the account is
//! made to linger before its first launch (`loginctl enable-linger`, idempotent). `ruya-profiles`
//! ends the manager and the linger when it deletes the profile.
//!
//! A restart of this service leaves the apps running (they belong to the users' managers), but
//! ends the `systemd-run --wait` processes that told us when they ended. `adopt_running` finds the
//! `ruya-app-*` units again and follows the ones of each profile user over one long-lived bus
//! connection to that user's manager (`UserLink`, `follow::Follower`, T-340). The connection goes
//! the way `systemctl --machine=<user>@.host --user` goes, which works under this unit's
//! hardening: zbus starts `systemd-run ... systemd-stdio-bridge --user` (`follow::bridge_address`,
//! a `unixexec:` address) and talks over its pipes; `Subscribe` and the `PropertiesChanged` /
//! `UnitRemoved` signals give the real exit status. Only while the bridge is dead are the units
//! looked at with `systemctl show` every two seconds; the bridge is restarted with a growing pause.
//!
//! `flatpak run` puts the game in its own `app-flatpak-<id>-<n>.scope`, outside the unit (T-363).
//! Every event goes through `Gate`: `scope::RunScopes` attaches the scope to its run, reads its
//! CPU, and holds the unit's end until the scope is gone (a watcher thread asks each manager
//! with one `systemctl show` per second at most); `Stop` and the kill name every scope of the app.
//! When a run's end is handed on, the app's leftover scopes are stopped and their `failed` state
//! cleared first (`RunScopes::take_sweeps`, `spawner::sweep_commands`, T-435).

use std::collections::HashMap;
use std::fs::File;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_channel::Sender;
use futures_lite::{future, StreamExt};
use zbus::connection::Builder;
use zbus::zvariant::{OwnedObjectPath, OwnedValue};
use zbus::{Connection, MatchRule, MessageStream};

use crate::bounded::{run_bounded, run_bounded_status};
use crate::follow::{
    bridge_args, existence, parse_signal, Backoff, Follower, ManagerLink, Probe, Wake,
    BRIDGE_PROGRAM,
};
use crate::runner_choice::runner_args_from_library;
use crate::scope::{RunScopes, Sweep};
use crate::spawner::{
    active_app_scopes, any_swap, app_args_from, app_scopes, cancel_reclaim_command,
    control_command, control_groups_command, flatpak_app_installed, kill_command,
    launch_command_in, list_scopes_command, park_audio_command, parse_control_groups,
    parse_profile_users, parse_show, pulse_start_command, reclaim_amount, reclaim_command,
    sweep_commands, unit_app_id, unit_name, LineTail, RunFollower, RunningUnit, ShowUnit, APP_ARGS,
    KILL_VERB, SHOW_PROPERTIES, SWAP_COMMAND,
};
use crate::spawner::{
    AdoptLister, AudioJob, AudioQueue, DisplayMode, Listing, ReclaimLedger, Spawner, UnitEvent,
    PARK_RETRY,
};
use crate::x11::{display_mode_x11, X11_OVERRIDES};
use std::ffi::OsString;
use zbus::address::transport::{Transport, Unixexec};
use zbus::Address;

const FLATPAK_ROOT: &str = "/var/lib/flatpak";
/// `RuntimeDirectory=ruya-session` of the unit: where each app's `systemd-run` writes its status.
const LOG_DIR: &str = "/run/ruya-session";
/// How often the status file of a running `systemd-run` is read.
const POLL: Duration = Duration::from_millis(100);

/// How often the scope watcher wakes (what is due is decided by `RunScopes::plan`).
const SCOPE_TICK: Duration = Duration::from_secs(1);

type Registry = Arc<Mutex<HashMap<String, (String, String)>>>;

/// The way every unit event takes to the core (T-363): the end of a unit whose Flatpak scope still
/// lives is held back by `RunScopes` until the scope is gone, and a unit leaves the registry (so
/// `Stop` and the kill stop reaching it) only when its end is handed on.
#[derive(Clone)]
struct Gate {
    events: Sender<UnitEvent>,
    /// unit -> (Unix user, app id), for the units that run: `Stop` and the kill need the user's
    /// manager and the app's scope.
    units: Registry,
    scopes: Arc<Mutex<RunScopes>>,
}

impl Gate {
    fn deliver(&self, event: UnitEvent) {
        let (passed, sweeps) = {
            let mut scopes = self.scopes.lock().unwrap_or_else(|e| e.into_inner());
            let passed = scopes.on_unit_event(event, Instant::now());
            (passed, scopes.take_sweeps())
        };
        sweep(sweeps);
        if let Some(event) = passed {
            self.send(event);
        }
    }

    fn send(&self, event: UnitEvent) {
        if let UnitEvent::Exited { unit, .. } | UnitEvent::ExecFailed { unit } = &event {
            self.units
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(unit);
        }
        let _ = self.events.send_blocking(event);
    }
}

/// Looks at the Flatpak scopes of the runs, one `systemctl show` per profile manager and round
/// (`RunScopes::plan` / `apply`), and hands on the unit ends that waited for a scope.
fn watch_scopes(gate: Gate) {
    loop {
        std::thread::sleep(SCOPE_TICK);
        let queries = gate
            .scopes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .plan(Instant::now());
        for query in queries {
            let shows = show_many(&query.user, &query.names).map(|text| parse_show(&text));
            let (ended, sweeps) = {
                let mut scopes = gate.scopes.lock().unwrap_or_else(|e| e.into_inner());
                let ended = scopes.apply(&query.user, shows.as_deref(), Instant::now());
                (ended, scopes.take_sweeps())
            };
            sweep(sweeps);
            for event in ended {
                gate.send(event);
            }
        }
    }
}

/// How long one `systemctl` of `Stop`, the kill or a sweep may take: a manager that does not
/// answer must not hold up the scope watcher (every profile's runs) or a `Stop` for long.
const SYSTEMCTL_LIMIT: Duration = Duration::from_secs(5);

/// The scopes of `app_id` loaded in `user`'s manager (any state), by exact name: the glob
/// listing filtered by `app_scopes`, so a sibling app whose id starts with `<app_id>-` is never
/// among them (T-435). `None` when the manager could not be asked.
fn app_scopes_of(user: &str, app_id: &str) -> Option<Vec<String>> {
    let args = list_scopes_command(user, app_id)
        .map_err(|err| eprintln!("ruya-session: {err}"))
        .ok()?;
    run_bounded(&args, SYSTEMCTL_LIMIT).map(|out| app_scopes(app_id, &out))
}

/// Clears what is left of the runs that ended (`spawner::sweep_commands`, on the app's own
/// scopes as listed now): each `systemctl` is bounded (the stop is `--no-block`, so this is
/// quick), and all of it is over before their ends are handed on.
fn sweep(sweeps: Vec<Sweep>) {
    for Sweep { user, app_id } in sweeps {
        let Some(scopes) = app_scopes_of(&user, &app_id) else {
            continue;
        };
        match sweep_commands(&user, &app_id, &scopes) {
            Ok(commands) => {
                for args in commands {
                    run_bounded(&args, SYSTEMCTL_LIMIT);
                }
            }
            Err(err) => eprintln!("ruya-session: no sweep for {app_id} of {user}: {err}"),
        }
    }
}

/// How long one `ruya-devices --park-audio` run may take (its unit has `RuntimeMaxSec=15`).
const PARK_LIMIT: Duration = Duration::from_secs(20);
/// How long one reclaim may take (its unit has `RuntimeMaxSec=30`).
const RECLAIM_LIMIT: Duration = Duration::from_secs(40);
/// How often the swap state is read again (`swap_active` answers from the last reading).
const SWAP_EVERY: Duration = Duration::from_secs(60);

/// Runs the sound requests one after the other, so a Thaw's request is never overtaken by the
/// Freeze's before it; a newer request of a user replaces a queued one, and a failed one is tried
/// again `PARK_RETRY` later, up to `PARK_TRIES` in all, unless a newer one of that user came in
/// meanwhile (`AudioQueue`). Each request is the whole state of that user (`park.rs` in
/// ruya-devices), so the newest is all that matters.
fn park_audio_worker(jobs: std::sync::mpsc::Receiver<AudioJob>) {
    use std::sync::mpsc::RecvTimeoutError;
    let mut queue = AudioQueue::default();
    loop {
        if queue.is_empty() {
            match jobs.recv() {
                Ok(job) => queue.push(job),
                Err(_) => return,
            }
        }
        while let Ok(job) = jobs.try_recv() {
            queue.push(job);
        }
        let Some((job, tries)) = queue.pop() else {
            continue;
        };
        if tries > 0 {
            // The pause before a retry still takes in new requests; a newer one of this user
            // replaces the retry.
            let until = Instant::now() + PARK_RETRY;
            while let Some(left) = until.checked_duration_since(Instant::now()) {
                match jobs.recv_timeout(left) {
                    Ok(newer) => queue.push(newer),
                    Err(RecvTimeoutError::Timeout) => break,
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            }
            if queue.has(&job.0) {
                continue;
            }
        }
        let (user, frozen, running) = &job;
        let args = match park_audio_command(user, frozen, running) {
            Ok(args) => args,
            Err(err) => {
                eprintln!("ruya-session: no park-audio for {user}: {err}");
                continue;
            }
        };
        let started = Instant::now();
        let done = run_bounded(&args, PARK_LIMIT).is_some();
        eprintln!(
            "ruya-session: park-audio {user} frozen=[{}] running=[{}]: {} in {} ms (try {})",
            frozen.join(","),
            running.join(","),
            if done { "done" } else { "failed" },
            started.elapsed().as_millis(),
            tries + 1
        );
        if !done && !queue.failed(job.clone(), tries) {
            eprintln!("ruya-session: park-audio {user}: given up (or a newer request is queued)");
        }
    }
}

/// Reads the swap state every `SWAP_EVERY` into `swap` (T-466), so `swap_active` never blocks the
/// core's tick (it runs under the session lock).
fn watch_swap(swap: Arc<std::sync::atomic::AtomicBool>) {
    let args: Vec<String> = SWAP_COMMAND.iter().map(|s| (*s).to_owned()).collect();
    loop {
        let on = run_bounded(&args, SYSTEMCTL_LIMIT).is_some_and(|out| any_swap(&out));
        swap.store(on, std::sync::atomic::Ordering::Relaxed);
        std::thread::sleep(SWAP_EVERY);
    }
}

/// `memory.current` of a cgroup (a path as `ControlGroup` gives it), in bytes.
fn memory_current(cgroup: &str) -> Option<u64> {
    std::fs::read_to_string(format!("/sys/fs/cgroup{cgroup}/memory.current"))
        .ok()
        .and_then(|s| s.trim().parse().ok())
}

/// The reclaim of one frozen app (T-466), on its own thread: the unit and the app's active scopes,
/// their cgroups from the manager, `reclaim_amount` of each one's `memory.current`, written by a
/// transient unit of the profile user (`reclaim_command`). Logs what it asked and what moved.
///
/// Returns false when the unit could not be started or timed out: the ledger keeps its entry then
/// (`ReclaimLedger::settle`), so the next thaw stops an older unit that may still run (RUY-593).
fn reclaim_app(
    unit: String,
    user: String,
    app_id: String,
    ledger: &ReclaimLedger,
    token: u64,
) -> bool {
    let Some(listing) = list_scopes_command(&user, &app_id)
        .ok()
        .and_then(|args| run_bounded(&args, SYSTEMCTL_LIMIT))
    else {
        eprintln!("ruya-session: {unit}: no reclaim, the scopes could not be listed");
        return true;
    };
    let mut units = vec![unit.clone()];
    units.extend(active_app_scopes(&app_id, &listing));
    let Some(text) = control_groups_command(&user, &units)
        .ok()
        .and_then(|args| run_bounded(&args, SYSTEMCTL_LIMIT))
    else {
        eprintln!("ruya-session: {unit}: no reclaim, the cgroups could not be read");
        return true;
    };
    let cgroups = parse_control_groups(&text);
    let before: Vec<(String, u64)> = cgroups
        .iter()
        .filter_map(|cg| memory_current(cg).map(|bytes| (cg.clone(), bytes)))
        .collect();
    let targets: Vec<(u64, String)> = before
        .iter()
        .map(|(cg, bytes)| (reclaim_amount(*bytes), cg.clone()))
        .filter(|(amount, _)| *amount > 0)
        .collect();
    let args = match reclaim_command(&user, &app_id, &targets) {
        Ok(args) => args,
        Err(err) => {
            eprintln!("ruya-session: {unit}: no reclaim: {err}");
            return true;
        }
    };
    if let Err(why) = ledger.try_start(&unit, token) {
        eprintln!("ruya-session: {unit}: no reclaim, {}", why.reason());
        return true;
    }
    let started = Instant::now();
    let done = run_bounded(&args, RECLAIM_LIMIT).is_some();
    let mib = |b: u64| b / (1024 * 1024);
    let was: u64 = before.iter().map(|(_, b)| b).sum();
    let now: u64 = before.iter().filter_map(|(cg, _)| memory_current(cg)).sum();
    let asked: u64 = targets.iter().map(|(a, _)| a).sum();
    eprintln!(
        "ruya-session: {unit}: memory reclaim {} in {} ms: asked {} MiB of {} cgroups, memory.current {} -> {} MiB",
        if done { "done" } else { "failed" },
        started.elapsed().as_millis(),
        mib(asked),
        targets.len(),
        mib(was),
        mib(now)
    );
    done
}

pub struct SystemdSpawner {
    flatpak_root: PathBuf,
    log_dir: PathBuf,
    gate: Gate,
    /// The sound requests, to `park_audio_worker` (T-466).
    audio: Mutex<std::sync::mpsc::Sender<AudioJob>>,
    /// Is swap active, as `watch_swap` last read it (T-466).
    swap: Arc<std::sync::atomic::AtomicBool>,
    /// The reclaims whose unit was started, for `cancel_reclaim` (RUY-573).
    reclaims: Arc<ReclaimLedger>,
    /// Did the last `adopt_running` fail to ask loginctl or a profile's manager (RUY-23)?
    adopt_failed: Arc<std::sync::atomic::AtomicBool>,
}

impl SystemdSpawner {
    pub fn new(events: Sender<UnitEvent>) -> Self {
        let gate = Gate {
            events,
            units: Arc::new(Mutex::new(HashMap::new())),
            scopes: Arc::new(Mutex::new(RunScopes::new())),
        };
        let watcher = gate.clone();
        if let Err(err) = std::thread::Builder::new()
            .name("scopes".to_owned())
            .spawn(move || watch_scopes(watcher))
        {
            eprintln!("ruya-session: cannot watch the Flatpak scopes: {err}");
        }
        let (audio, jobs) = std::sync::mpsc::channel();
        if let Err(err) = std::thread::Builder::new()
            .name("park-audio".to_owned())
            .spawn(move || park_audio_worker(jobs))
        {
            eprintln!("ruya-session: cannot park the sound of frozen apps: {err}");
        }
        let swap = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let watched = Arc::clone(&swap);
        if let Err(err) = std::thread::Builder::new()
            .name("swap".to_owned())
            .spawn(move || watch_swap(watched))
        {
            eprintln!("ruya-session: cannot watch the swap: no memory is reclaimed: {err}");
        }
        SystemdSpawner {
            flatpak_root: PathBuf::from(FLATPAK_ROOT),
            log_dir: PathBuf::from(LOG_DIR),
            gate,
            audio: Mutex::new(audio),
            swap,
            reclaims: Arc::new(ReclaimLedger::default()),
            adopt_failed: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        }
    }

    fn owner_of(&self, unit: &str) -> Result<(String, String), String> {
        self.gate
            .units
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(unit)
            .cloned()
            .ok_or_else(|| format!("no running unit {unit}"))
    }

    /// `systemctl --user --machine=<user>@.host <verb>... <unit> <scope>...` on its own thread:
    /// it talks to the bus and must not hold up a D-Bus call. Its failure is logged; the run's end
    /// (or the kill after the grace time) is what the core acts on. The scopes are the app itself
    /// (every one of the app's, listed first and named exactly, `app_scopes_of`,
    /// `control_command`, T-435); the unit is its `flatpak run` front end. The kill
    /// (`KILL_VERB`) leaves out a unit that has ended already while a scope holds the run
    /// (`kill_command`, RUY-736).
    fn systemctl(&self, unit: &str, verb: &'static [&'static str]) -> Result<(), String> {
        let (user, app_id) = self.owner_of(unit)?;
        // Checked here, so a bad name is the caller's error, not only a log line.
        control_command(&user, verb, unit, &app_id, &[])?;
        let what = format!("systemctl {} {unit}", verb.join(" "));
        let failed = format!("cannot start a thread for {unit}");
        let unit = unit.to_owned();
        let runs = Arc::clone(&self.gate.scopes);
        let spawned = std::thread::Builder::new()
            .name("systemctl".to_owned())
            .spawn(move || {
                let scopes = app_scopes_of(&user, &app_id).unwrap_or_default();
                let command = if verb == KILL_VERB {
                    let ended = runs
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .unit_ended(&unit);
                    kill_command(&user, &unit, &app_id, &scopes, ended)
                } else {
                    control_command(&user, verb, &unit, &app_id, &scopes)
                };
                match command {
                    Ok(args) => {
                        run_bounded(&args, SYSTEMCTL_LIMIT);
                    }
                    Err(err) => eprintln!("ruya-session: {what}: {err}"),
                }
            });
        spawned
            .map(|_| ())
            .map_err(|err| format!("{failed}: {err}"))
    }

    /// `systemctl --user --machine=<user>@.host freeze|thaw <unit> <scope>...` (T-457), on the
    /// caller's thread and waited for: the answer says whether it worked. The scopes are the app's
    /// active ones, listed first and named exactly (`active_app_scopes`, `control_command`), so
    /// both scopes of an Electron app are reached and a sibling app never is. Each `systemctl` is
    /// bounded (`SYSTEMCTL_LIMIT`); a listing that fails is an error (freezing the front end alone
    /// would leave the game running).
    fn freezer(&self, unit: &str, verb: &'static str) -> Result<(), String> {
        let (user, app_id) = self.owner_of(unit)?;
        let list = list_scopes_command(&user, &app_id)?;
        let listing = run_bounded(&list, SYSTEMCTL_LIMIT)
            .ok_or_else(|| format!("cannot list the scopes of {app_id} of {user}"))?;
        let scopes = active_app_scopes(&app_id, &listing);
        let args = control_command(&user, &[verb], unit, &app_id, &scopes)?;
        run_bounded(&args, SYSTEMCTL_LIMIT)
            .map(|_| ())
            .ok_or_else(|| format!("systemctl {verb} {unit} failed"))
    }
}

impl Spawner for SystemdSpawner {
    fn is_installed(&self, app_id: &str) -> bool {
        flatpak_app_installed(&self.flatpak_root, app_id)
    }

    /// `systemctl --machine=ruya-shell@.host --user start ruya-pulse@<user>.service`, the same
    /// path as the app units, and waits for it: the unit counts as started once its socket
    /// listens (its `ExecStartPost`), so the app never looks too early. Quick when the server
    /// already runs (every launch after the first). Runs under the session lock, so it is
    /// bounded: the unit gives up after 5 s, and the `systemctl` child is killed after 10 s.
    fn start_sound(&self, user: &str) -> Result<(), String> {
        const LIMIT: Duration = Duration::from_secs(10);
        let args = pulse_start_command(user)?;
        let what = args.join(" ");
        let mut child = Command::new(&args[0])
            .args(&args[1..])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|err| format!("{what}: {err}"))?;
        let deadline = Instant::now() + LIMIT;
        loop {
            match child.try_wait() {
                Ok(Some(status)) if status.success() => return Ok(()),
                Ok(Some(status)) => return Err(format!("{what} failed: {status}")),
                Ok(None) if Instant::now() >= deadline => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(format!("{what}: no answer in {} s", LIMIT.as_secs()));
                }
                Ok(None) => std::thread::sleep(Duration::from_millis(20)),
                Err(err) => return Err(format!("{what}: {err}")),
            }
        }
    }

    fn start(&self, user: &str, app_id: &str, env: &[(String, String)]) -> Result<String, String> {
        // X11-only apps get a private X server inside their unit (ADR-034, RUY-435).
        let mode = if display_mode_x11(&self.flatpak_root, app_id, Path::new(X11_OVERRIDES)) {
            eprintln!("ruya-session: {app_id} of {user} runs in X11 mode");
            DisplayMode::X11
        } else {
            DisplayMode::Wayland
        };
        // Per-app launch arguments from the image (Steam: Big Picture); a missing file is none.
        let mut app_args = app_args_from(
            &std::fs::read_to_string(APP_ARGS).unwrap_or_default(),
            app_id,
        );
        // A .play game's runner choice, from ruya-library (RUY-904); never fails the launch.
        app_args.extend(runner_args_from_library(user, app_id));
        let args = launch_command_in(user, app_id, env, mode, &app_args)?;
        let unit = unit_name(user, app_id);
        self.gate
            .units
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(unit.clone(), (user.to_owned(), app_id.to_owned()));
        self.gate
            .scopes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .begin(&unit, user, app_id, Instant::now());
        let job = Job {
            args,
            user: user.to_owned(),
            unit: unit.clone(),
            log_dir: self.log_dir.clone(),
            gate: self.gate.clone(),
        };
        std::thread::Builder::new()
            .name("systemd-run".to_owned())
            .spawn(move || job.run())
            .map_err(|err| {
                self.gate
                    .units
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .remove(&unit);
                self.gate
                    .scopes
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .forget(&unit);
                format!("cannot start a thread: {err}")
            })?;
        Ok(unit)
    }

    fn stop(&self, unit: &str) -> Result<(), String> {
        self.systemctl(unit, &["stop", "--no-block"])
    }

    fn kill(&self, unit: &str) -> Result<(), String> {
        self.systemctl(unit, KILL_VERB)
    }

    fn freeze(&self, unit: &str) -> Result<(), String> {
        self.freezer(unit, "freeze")
    }

    fn thaw(&self, unit: &str) -> Result<(), String> {
        self.freezer(unit, "thaw")
    }

    fn app_audio(&self, user: &str, frozen: &[String], running: &[String]) {
        let job = (user.to_owned(), frozen.to_vec(), running.to_vec());
        let sent = self
            .audio
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .send(job);
        if sent.is_err() {
            eprintln!(
                "ruya-session: the park-audio worker is gone: the sound of {user} stays as it is"
            );
        }
    }

    /// `systemctl list-units --type=swap --state=active` in the system manager, bounded.
    /// The last reading of `watch_swap` (at most `SWAP_EVERY` old); never blocks.
    fn swap_active(&self) -> bool {
        self.swap.load(std::sync::atomic::Ordering::Relaxed)
    }

    fn reclaim(&self, unit: &str) -> Result<(), String> {
        let (user, app_id) = self.owner_of(unit)?;
        let unit = unit.to_owned();
        let ledger = Arc::clone(&self.reclaims);
        let token = ledger.queued(&unit);
        let spawned = std::thread::Builder::new()
            .name("reclaim".to_owned())
            .spawn({
                let (unit, ledger) = (unit.clone(), Arc::clone(&ledger));
                move || {
                    let ok = reclaim_app(unit.clone(), user, app_id, &ledger, token);
                    ledger.settle(&unit, token, ok);
                }
            });
        spawned.map(|_| ()).map_err(|err| {
            ledger.finish(&unit, token);
            format!("cannot start a thread for the reclaim: {err}")
        })
    }

    /// `systemctl --user -M <user>@.host stop --no-block ruya-reclaim-<app>.service`, on its own
    /// thread (the thaw must not wait for it).
    fn cancel_reclaim(&self, unit: &str) {
        if !self.reclaims.take(unit) {
            return; // the reclaim never started its unit (RUY-573): nothing to stop
        }
        let Ok((user, app_id)) = self.owner_of(unit) else {
            return;
        };
        match cancel_reclaim_command(&user, &app_id) {
            Ok(args) => {
                let spawned = std::thread::Builder::new()
                    .name("reclaim-stop".to_owned())
                    .spawn(move || {
                        run_bounded(&args, SYSTEMCTL_LIMIT);
                    });
                if let Err(err) = spawned {
                    eprintln!("ruya-session: cannot stop the reclaim of {unit}: {err}");
                }
            }
            Err(err) => eprintln!("ruya-session: cannot stop the reclaim of {unit}: {err}"),
        }
    }

    /// `/proc/<pid>/cgroup` (T-459). Root reads it for every user's process under this unit's
    /// `ProtectProc=invisible` (checked on the Dell, 2026-11-10).
    fn process_cgroup(&self, pid: u32) -> Option<String> {
        std::fs::read_to_string(format!("/proc/{pid}/cgroup")).ok()
    }

    fn user_name(&self, uid: u32) -> Option<String> {
        user_name_of(uid)
    }

    fn adoption_complete(&self) -> bool {
        !self.adopt_failed.load(std::sync::atomic::Ordering::SeqCst)
    }

    fn adopt_running(&self) -> Vec<RunningUnit> {
        (self.adopt_lister())().found
    }

    fn tracks(&self, unit: &str) -> bool {
        // `Gate::send` removes a unit before it hands its end on.
        self.gate
            .units
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains_key(unit)
    }

    fn adopt_lister(&self) -> AdoptLister {
        let gate = self.gate.clone();
        let failed = Arc::clone(&self.adopt_failed);
        Box::new(move || list_running_apps(&gate, &failed))
    }
}

/// The app units that run in every profile user's manager, taken over (`Spawner::adopt_lister`).
/// Every external call is bounded (`SYSTEMCTL_LIMIT`); one that fails or times out makes the
/// listing incomplete, never an empty answer taken for "nothing runs" (RUY-621).
fn list_running_apps(gate: &Gate, adopt_failed: &std::sync::atomic::AtomicBool) -> Listing {
    let mut failed = false;
    let args: Vec<String> = ["loginctl", "list-users", "--no-legend", "--no-pager"]
        .iter()
        .map(|s| (*s).to_owned())
        .collect();
    let users = run_bounded(&args, SYSTEMCTL_LIMIT)
        .map(|out| parse_profile_users(&out))
        .unwrap_or_else(|| {
            eprintln!("ruya-session: loginctl list-users failed: no app is adopted");
            failed = true;
            Vec::new()
        });
    let mut found = Vec::new();
    for user in users {
        let Some(text) = show_units(&user, "ruya-app-*.service") else {
            eprintln!("ruya-session: cannot list the apps of {user}");
            failed = true;
            continue;
        };
        let mut mine = Vec::new();
        for show in parse_show(&text).into_iter().filter(ShowUnit::alive) {
            let Some(app_id) = unit_app_id(&user, &show.id) else {
                continue;
            };
            // Taken over (or started by us) already: a second pass skips it.
            if gate
                .units
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .contains_key(&show.id)
            {
                continue;
            }
            gate.units
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .insert(show.id.clone(), (user.clone(), app_id.clone()));
            gate.scopes.lock().unwrap_or_else(|e| e.into_inner()).begin(
                &show.id,
                &user,
                &app_id,
                Instant::now(),
            );
            mine.push(RunningUnit {
                unit: show.id,
                user: user.clone(),
                app_id,
                started: show.entered,
                frozen: matches!(show.freezer_state.as_str(), "frozen" | "freezing"),
            });
        }
        if mine.is_empty() {
            continue;
        }
        // One thread and one connection per manager, however many apps it runs.
        let names: Vec<String> = mine.iter().map(|u| u.unit.clone()).collect();
        let watcher = gate.clone();
        let who = user.clone();
        let spawned = std::thread::Builder::new()
            .name("watch".to_owned())
            .spawn(move || follow_user(&who, &names, &watcher));
        if let Err(err) = spawned {
            eprintln!("ruya-session: cannot watch the apps of {user}: {err}");
            let mut registry = gate.units.lock().unwrap_or_else(|e| e.into_inner());
            let mut scopes = gate.scopes.lock().unwrap_or_else(|e| e.into_inner());
            for u in &mine {
                registry.remove(&u.unit);
                scopes.forget(&u.unit);
            }
            continue;
        }
        for u in mine {
            eprintln!("ruya-session: adopted {}", u.unit);
            found.push(u);
        }
    }
    adopt_failed.store(failed, std::sync::atomic::Ordering::SeqCst);
    Listing {
        found,
        complete: !failed,
    }
}

/// `systemctl --user -M <user>@.host show` of the units matching `pattern`, or `None` when the
/// call failed. Times come as `@<unix seconds>`.
fn show_units(user: &str, pattern: &str) -> Option<String> {
    show_many(user, &[pattern.to_owned()])
}

/// The same for several names or patterns in one call. Bounded (`SYSTEMCTL_LIMIT`): a manager
/// that does not answer is a failed call, not a wait without end (RUY-621).
fn show_many(user: &str, names: &[String]) -> Option<String> {
    let mut args: Vec<String> = ["systemctl", "--user", "--no-pager", "--timestamp=unix"]
        .iter()
        .map(|s| (*s).to_owned())
        .collect();
    args.push(format!("--machine={user}@.host"));
    args.push("show".to_owned());
    for property in SHOW_PROPERTIES {
        args.push(format!("--property={property}"));
    }
    args.extend(names.iter().cloned());
    run_bounded(&args, SYSTEMCTL_LIMIT)
}

/// Follows the adopted units of one profile user until the last one has ended.
fn follow_user(user: &str, units: &[String], gate: &Gate) {
    let mut link = UserLink::new(user);
    let mut follower = Follower::new(units);
    while !follower.is_done() {
        for event in follower.step(&mut link) {
            gate.deliver(event);
        }
    }
}

const SYSTEMD: &str = "org.freedesktop.systemd1";
const MANAGER_PATH: &str = "/org/freedesktop/systemd1";
const MANAGER_IFACE: &str = "org.freedesktop.systemd1.Manager";
const NO_SUCH_UNIT: &str = "org.freedesktop.systemd1.NoSuchUnit";

/// The connection to one profile user's manager, and the means to look at a unit when it is down.
struct UserLink {
    user: String,
    backoff: Backoff,
    /// Not before this moment is the bridge started again.
    next_try: Option<Instant>,
    conn: Option<Connection>,
    stream: Option<MessageStream>,
    /// Was the failure to connect logged? Once per outage is enough.
    warned: bool,
}

impl UserLink {
    fn new(user: &str) -> Self {
        UserLink {
            user: user.to_owned(),
            backoff: Backoff::default(),
            next_try: None,
            conn: None,
            stream: None,
            warned: false,
        }
    }

    fn drop_connection(&mut self) {
        self.conn = None;
        self.stream = None;
    }

    /// Starts the bridge, connects over it and subscribes to the manager's signals.
    fn connect(&mut self) -> Result<(), String> {
        // The typed transport, not an address string (see `follow::bridge_args`).
        let args = bridge_args(&self.user)?;
        let exec = Unixexec::new(
            PathBuf::from(BRIDGE_PROGRAM),
            None,
            args.into_iter().map(OsString::from).collect(),
        );
        let address = Address::from(Transport::Unixexec(exec));
        let conn = future::block_on(
            Builder::address(address)
                .map_err(|e| e.to_string())?
                .build(),
        )
        .map_err(|e| e.to_string())?;
        let rule = MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .sender(SYSTEMD)
            .map_err(|e| e.to_string())?
            .build();
        // Open the stream first: nothing sent after `Subscribe` may be missed.
        let stream = future::block_on(MessageStream::for_match_rule(rule, &conn, None))
            .map_err(|e| e.to_string())?;
        future::block_on(conn.call_method(
            Some(SYSTEMD),
            MANAGER_PATH,
            Some(MANAGER_IFACE),
            "Subscribe",
            &(),
        ))
        .map_err(|e| e.to_string())?;
        self.conn = Some(conn);
        self.stream = Some(stream);
        Ok(())
    }

    /// A unit's state over the connection. `Err` is a broken connection.
    fn probe_bus(&self, unit: &str) -> Result<Probe, zbus::Error> {
        let Some(conn) = &self.conn else {
            return Err(zbus::Error::Failure("no connection".to_owned()));
        };
        let reply = match future::block_on(conn.call_method(
            Some(SYSTEMD),
            MANAGER_PATH,
            Some(MANAGER_IFACE),
            "GetUnit",
            &(unit,),
        )) {
            Ok(reply) => reply,
            Err(zbus::Error::MethodError(name, _, _)) if name.as_str() == NO_SUCH_UNIT => {
                return Ok(Probe::Gone);
            }
            Err(err) => return Err(err),
        };
        let path: OwnedObjectPath = reply.body().deserialize()?;
        let all = |interface: &str| -> Result<HashMap<String, OwnedValue>, zbus::Error> {
            future::block_on(conn.call_method(
                Some(SYSTEMD),
                &path,
                Some("org.freedesktop.DBus.Properties"),
                "GetAll",
                &(interface,),
            ))?
            .body()
            .deserialize()
        };
        let unit_props = all("org.freedesktop.systemd1.Unit")?;
        let service_props = all("org.freedesktop.systemd1.Service")?;
        let text = |key: &str| {
            unit_props
                .get(key)
                .and_then(|v| String::try_from(v.clone()).ok())
                .unwrap_or_default()
        };
        let int = |key: &str| {
            service_props
                .get(key)
                .and_then(|v| i32::try_from(v.clone()).ok())
                .unwrap_or(0)
        };
        let entered = unit_props
            .get("ActiveEnterTimestamp")
            .and_then(|v| u64::try_from(v.clone()).ok())
            .map_or(0, |usec| i64::try_from(usec / 1_000_000).unwrap_or(0));
        let show = ShowUnit {
            id: unit.to_owned(),
            load_state: text("LoadState"),
            active_state: text("ActiveState"),
            entered,
            exec_main_status: int("ExecMainStatus"),
            exec_main_code: int("ExecMainCode"),
            cpu_nsec: None,
            freezer_state: text("FreezerState"),
        };
        Ok(if show.alive() {
            Probe::Alive(show)
        } else {
            Probe::Gone
        })
    }
}

impl ManagerLink for UserLink {
    fn wait(&mut self, max: Duration) -> Wake {
        let deadline = Instant::now() + max;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Wake::Quiet;
            }
            let Some(stream) = self.stream.as_mut() else {
                return Wake::Lost;
            };
            let got = future::block_on(future::or(async { Some(stream.next().await) }, async {
                async_io::Timer::after(left).await;
                None
            }));
            match got {
                None => return Wake::Quiet,
                Some(Some(Ok(message))) => {
                    if let Some(event) = parse_signal(&message) {
                        return Wake::Event(event);
                    }
                }
                Some(_) => {
                    self.drop_connection();
                    return Wake::Lost;
                }
            }
        }
    }

    fn reconnect(&mut self, pause: Duration) -> bool {
        if !pause.is_zero() {
            std::thread::sleep(pause);
        }
        if self.next_try.is_some_and(|t| Instant::now() < t) {
            return false;
        }
        self.drop_connection();
        match self.connect() {
            Ok(()) => {
                self.backoff.worked();
                self.next_try = None;
                self.warned = false;
                true
            }
            Err(err) => {
                if !self.warned {
                    eprintln!(
                        "ruya-session: no connection to the manager of {}: {err}",
                        self.user
                    );
                    self.warned = true;
                }
                self.next_try = Some(Instant::now() + self.backoff.delay());
                self.backoff.failed();
                self.drop_connection();
                false
            }
        }
    }

    fn probe(&mut self, unit: &str) -> Probe {
        if self.conn.is_some() {
            match self.probe_bus(unit) {
                Ok(probe) => return probe,
                Err(err) => {
                    eprintln!("ruya-session: {unit}: {err}");
                    self.drop_connection();
                }
            }
        }
        match show_units(&self.user, unit).and_then(|text| parse_show(&text).into_iter().next()) {
            Some(show) if show.alive() => Probe::Alive(show),
            Some(_) => Probe::Gone,
            None => Probe::Unknown,
        }
    }

    /// Asked step by step (`follow::existence`): is there such a user (the user database), does
    /// its manager run (`user@<uid>.service`), what does the manager say of the unit. Only a
    /// clear answer is a "no"; an error of any step keeps the unit (RUY-23).
    fn exists(&mut self, unit: &str) -> Option<bool> {
        let uid = lookup_uid(&self.user);
        let user_known = match uid {
            Ok(found) => Some(found.is_some()),
            Err(_) => None,
        };
        existence(
            user_known,
            || manager_running(uid.ok().flatten()?),
            || unit_state(&self.user, unit),
        )
    }
}

/// The uid of a Unix user: `Ok(None)` when the user database says there is no such user, `Err`
/// (the errno) when it could not be asked.
fn lookup_uid(name: &str) -> Result<Option<u32>, i32> {
    let Ok(name) = std::ffi::CString::new(name) else {
        return Err(libc::EINVAL);
    };
    let mut buf = vec![0 as libc::c_char; 4096];
    // SAFETY: an all-zero `passwd` is a valid value for getpwnam_r to fill in.
    let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: every pointer is valid for the call and `buf.len()` is the buffer's real size.
    let rc = unsafe {
        libc::getpwnam_r(
            name.as_ptr(),
            &mut pwd,
            buf.as_mut_ptr(),
            buf.len(),
            &mut result,
        )
    };
    match rc {
        0 if !result.is_null() => Ok(Some(pwd.pw_uid)),
        // The documented "no such user" answers. EPERM read this way is harmless: profile users
        // are in /etc/passwd, which nothing here is denied (RUY-621).
        0 | libc::ENOENT | libc::ESRCH | libc::EBADF | libc::EPERM => Ok(None),
        err => Err(err),
    }
}

/// Does the system manager run `user@<uid>.service`, the user's manager? `None` when
/// `systemctl` could not be run or said something else.
fn manager_running(uid: u32) -> Option<bool> {
    // `is-active` exits non-zero for "inactive", so the status is not checked, only the answer.
    // A timeout is `None`: the unit is kept (`follow::existence`), never ended on a guess.
    let args = [
        "systemctl".to_owned(),
        "is-active".to_owned(),
        format!("user@{uid}.service"),
    ];
    let (_, out) = run_bounded_status(&args, SYSTEMCTL_LIMIT)?;
    match out.trim() {
        "active" | "reloading" => Some(true),
        "inactive" | "failed" => Some(false),
        _ => None,
    }
}

/// `systemctl is-active` of the unit in the user's manager (only asked when that runs).
/// A timeout is `None`: the caller keeps what it knew and asks again on its next pass.
fn unit_state(user: &str, unit: &str) -> Option<String> {
    let args = [
        "systemctl".to_owned(),
        "--user".to_owned(),
        "--no-pager".to_owned(),
        format!("--machine={user}@.host"),
        "is-active".to_owned(),
        unit.to_owned(),
    ];
    // `is-active` exits non-zero for an inactive unit; the word on stdout is the answer.
    let (_, out) = run_bounded_status(&args, SYSTEMCTL_LIMIT)?;
    Some(out.trim().to_owned())
}

/// One app's `systemd-run --wait`, on its own thread.
struct Job {
    args: Vec<String>,
    user: String,
    unit: String,
    log_dir: PathBuf,
    gate: Gate,
}

impl Job {
    fn run(self) {
        ensure_manager(&self.user);
        let (code, signaled, follower) = self.follow();
        let event = follower.finish(code, signaled);
        // The gate forgets the unit's user when it hands the end on (after the scope is gone).
        self.gate.deliver(event);
    }

    /// Runs `systemd-run`, forwards the events its lines make, returns how it ended.
    ///
    /// Its stderr is a file in the service's runtime directory, not a pipe: `systemd-run
    /// --machine=` hands its stderr on to PID 1 (for the helper it starts in the user's login),
    /// and SELinux does not let PID 1 write to a pipe of this service, which ends the call with
    /// "Connection reset by peer" (VM, T-162). A file in `/run` is fine. Stdout and stdin are
    /// /dev/null. The file is read about ten times a second until the process has ended.
    fn follow(&self) -> (i32, bool, RunFollower) {
        let mut follower = RunFollower::new(&self.unit);
        let Some((program, rest)) = self.args.split_first() else {
            return (1, false, follower);
        };
        let log_path = self.log_dir.join(format!("{}.log", self.unit));
        let opened = std::fs::create_dir_all(&self.log_dir)
            .and_then(|()| File::create(&log_path))
            .and_then(|log| LineTail::open(&log_path).map(|tail| (log, tail)));
        let (log, mut tail) = match opened {
            Ok(pair) => pair,
            Err(err) => {
                eprintln!("ruya-session: {}: no status file: {err}", self.unit);
                return (1, false, follower);
            }
        };
        let spawned = Command::new(program)
            .args(rest)
            .env("LC_ALL", "C")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::from(log))
            .spawn();
        let mut child = match spawned {
            Ok(child) => child,
            Err(err) => {
                eprintln!("ruya-session: {}: cannot run {program}: {err}", self.unit);
                let _ = std::fs::remove_file(&log_path);
                return (1, false, follower);
            }
        };
        let status = loop {
            let done = match child.try_wait() {
                Ok(done) => done,
                Err(err) => {
                    eprintln!("ruya-session: {}: waiting failed: {err}", self.unit);
                    break None;
                }
            };
            // Read after the exit was seen: what it wrote last is still in the file.
            for line in tail.poll() {
                eprintln!("ruya-session: {}: {line}", self.unit);
                if let Some(event) = follower.line(&line) {
                    self.gate.deliver(event);
                }
            }
            if done.is_some() {
                break done;
            }
            std::thread::sleep(POLL);
        };
        let _ = std::fs::remove_file(&log_path);
        match status {
            Some(status) => match status.signal() {
                Some(signal) => (signal, true, follower),
                None => (status.code().unwrap_or(1), false, follower),
            },
            None => (1, false, follower),
        }
    }
}

/// Runs a helper to its end, at most `limit` (then it is killed), stderr in the journal; a
/// failure or a timeout is logged and returned as `false`.
fn run_quiet(args: &[&str], limit: Duration) -> bool {
    let args: Vec<String> = args.iter().map(|a| (*a).to_owned()).collect();
    run_bounded(&args, limit).is_some()
}

/// Longest `ensure_manager` waits for one helper: `systemctl start user@N.service` may take up to
/// the 45 s start timeout.
const MANAGER_LIMIT: Duration = Duration::from_secs(50);

/// Keeps the profile user's manager alive without a login session, and has it running when this
/// returns. Idempotent and cheap; a failure is logged and the launch goes on.
///
/// The order matters (VM, T-162): `enable-linger` makes logind start the manager in the
/// background, and a `systemd-run --machine=` call that arrives meanwhile opens a session of its
/// own for the same manager; the two starts then wait for each other until the 45 s start
/// timeout. `systemctl start` joins the start that is under way and returns once it is done.
fn ensure_manager(user: &str) {
    // A timeout is a logged failure and the launch goes on (the unit then fails or starts later).
    run_quiet(&["loginctl", "enable-linger", user], MANAGER_LIMIT);
    let uid = run_bounded(
        &["id".to_owned(), "-u".to_owned(), user.to_owned()],
        SYSTEMCTL_LIMIT,
    )
    .map(|s| s.trim().to_owned())
    .filter(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit()));
    match uid {
        Some(uid) => {
            run_quiet(
                &["systemctl", "start", &format!("user@{uid}.service")],
                MANAGER_LIMIT,
            );
        }
        None => eprintln!("ruya-session: no uid for {user}"),
    }
}

/// The name of the Unix user `uid` (`getpwuid_r`, the system's user database), T-459.
fn user_name_of(uid: u32) -> Option<String> {
    let mut buf = vec![0 as libc::c_char; 4096];
    // SAFETY: an all-zero `passwd` is a valid value for getpwuid_r to fill in.
    let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: every pointer is valid for the call and `buf.len()` is the buffer's real size.
    let rc = unsafe { libc::getpwuid_r(uid, &mut pwd, buf.as_mut_ptr(), buf.len(), &mut result) };
    if rc != 0 || result.is_null() || pwd.pw_name.is_null() {
        return None;
    }
    // SAFETY: on success `pw_name` points to a NUL-terminated string inside `buf`, alive here.
    let name = unsafe { std::ffi::CStr::from_ptr(pwd.pw_name) };
    name.to_str().ok().map(str::to_owned)
}
