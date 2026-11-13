//! ruya-session: serves org.ruyaos.Session1. In the image (no argument) it runs as root on the
//! system bus and starts apps through systemd (`SystemdSpawner`, Linux only); the profiles come
//! from `Profiles1` before each launch. `--session` is the development mode: the session bus,
//! a fake spawner with a few demo apps and the shell's mock profiles (T-139).

use std::error::Error;
use std::sync::{Arc, Mutex};

use async_channel::{Receiver, Sender};
use ruya_session::dbus::{
    adopt_running, forward, watch_active_profile, DynSpawner, SessionIface, SharedUsage, BUS_NAME,
    OBJECT_PATH,
};
use ruya_session::directory::ProfileSnapshot;
use ruya_session::session::Session;
use ruya_session::spawner::{console_env, FakeSpawner, UnitEvent, PULSE_DIR, WAYLAND_DIR};
use ruya_session::usage::SystemZone;
use ruya_session::usage_store::FileStore;
use ruya_session::usage_tracker::Tracker;

fn main() {
    // `x11-run <app id>` / `x11-cleanup <app id>`: the main process and the ExecStopPost of an
    // X11-mode app unit, as the profile user (ADR-034, `ruya_session::x11`).
    let args: Vec<String> = std::env::args().collect();
    if let [_, verb, app_id] = args.as_slice() {
        if verb == "x11-run" || verb == "x11-cleanup" {
            x11_subcommand(verb, app_id);
        }
    }
    if let Err(err) = run() {
        eprintln!("ruya-session: fatal: {err}");
        std::process::exit(1);
    }
}

#[cfg(target_os = "linux")]
fn x11_subcommand(verb: &str, app_id: &str) -> ! {
    use ruya_session::x11::{exit_like, run_cleanup, run_helper, End, LinuxOs};
    let mut os = LinuxOs::default();
    let runtime = std::env::var("XDG_RUNTIME_DIR").ok();
    if verb == "x11-cleanup" {
        run_cleanup(&mut os, app_id, runtime.as_deref());
        exit_like(End::Code(0));
    }
    let wayland = std::env::var("WAYLAND_DISPLAY").ok();
    exit_like(run_helper(
        &mut os,
        app_id,
        runtime.as_deref(),
        wayland.as_deref(),
    ))
}

#[cfg(not(target_os = "linux"))]
fn x11_subcommand(verb: &str, _app_id: &str) -> ! {
    eprintln!("ruya-session: {verb} needs Linux");
    std::process::exit(ruya_session::x11::EXIT_LAUNCH_FAILED)
}

#[cfg(target_os = "linux")]
fn system_spawner(events: Sender<UnitEvent>) -> Result<DynSpawner, Box<dyn Error>> {
    Ok(Box::new(ruya_session::systemd::SystemdSpawner::new(events)))
}

#[cfg(not(target_os = "linux"))]
fn system_spawner(_events: Sender<UnitEvent>) -> Result<DynSpawner, Box<dyn Error>> {
    Err("the real spawner needs Linux and systemd; use --session for development".into())
}

fn run() -> Result<(), Box<dyn Error>> {
    let dev = std::env::args().any(|a| a == "--session");
    let (tx, rx): (Sender<UnitEvent>, Receiver<UnitEvent>) = async_channel::unbounded();
    type Setup = (
        DynSpawner,
        ProfileSnapshot,
        Vec<(String, String)>,
        Option<&'static str>,
    );
    let (spawner, profiles, env, wayland_dir): Setup = if dev {
        let fake = FakeSpawner::new()
            .with_app("org.ruyaos.Racer")
            .with_app("org.ruyaos.Puzzle")
            .with_events(tx);
        // The shell's mock profiles; `unix_user` is what the fake spawner is told to run as.
        (
            Box::new(fake),
            ProfileSnapshot::new(["p1", "p2", "guest"].map(str::to_owned)),
            vec![("WAYLAND_DISPLAY".to_owned(), "wayland-0".to_owned())],
            None,
        )
    } else {
        // Each app gets its profile's own Wayland socket (ADR-023, T-164). The console has no X
        // server, so SDL, Electron and the rest are told to use Wayland (`console_env`, T-435).
        (
            system_spawner(tx)?,
            ProfileSnapshot::default(),
            console_env(),
            Some(WAYLAND_DIR),
        )
    };
    let mut session = Session::new(spawner, profiles, env);
    if let Some(dir) = wayland_dir {
        // On the console each app also gets its profile's own sound server (ADR-010, T-365).
        session = session.with_wayland_dir(dir).with_pulse_dir(PULSE_DIR);
    }
    let session = Arc::new(Mutex::new(session));
    // The play ledger (T-247): root-only files under /var/lib/ruya-session/usage (the unit's
    // StateDirectory); `--session` keeps them in the temporary directory.
    let usage_dir = std::env::var_os("RUYA_USAGE_DIR").map_or_else(
        || {
            if dev {
                std::env::temp_dir().join("ruya-session-usage")
            } else {
                std::path::PathBuf::from("/var/lib/ruya-session/usage")
            }
        },
        std::path::PathBuf::from,
    );
    let tracker = Tracker::new(FileStore::new(usage_dir), SystemZone);
    let usage: SharedUsage = Arc::new(Mutex::new(tracker));

    futures_lite::future::block_on(async {
        let builder = if dev {
            zbus::connection::Builder::session()?
        } else {
            zbus::connection::Builder::system()?
        };
        let iface = SessionIface::new(session.clone(), usage.clone(), !dev);
        let turn = iface.freezer_turn();
        let connection = builder.serve_at(OBJECT_PATH, iface)?.build().await?;
        // Apps that kept running through a restart are taken over, and play runs that never
        // ended (crash, power cut) end at their last heartbeat, before the name is taken: the
        // first `ListRunning` of the shell already sees them.
        adopt_running(&connection, &session, &usage, !dev).await;
        connection.request_name(BUS_NAME).await?;
        // A profile that leaves has its apps frozen (T-165): the watcher follows Profiles1.
        futures_lite::future::zip(
            forward(connection.clone(), session.clone(), usage, !dev, rx),
            watch_active_profile(connection, session, turn),
        )
        .await;
        Ok::<(), Box<dyn Error>>(())
    })
}
