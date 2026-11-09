//! ruya-session: serves org.ruyaos.Session1. In the image (no argument) it runs as root on the
//! system bus and starts apps through systemd (`SystemdSpawner`, Linux only); the profiles come
//! from `Profiles1` before each launch. `--session` is the development mode: the session bus,
//! a fake spawner with a few demo apps and the shell's mock profiles (T-139).

use std::error::Error;
use std::sync::{Arc, Mutex};

use async_channel::{Receiver, Sender};
use ruya_session::dbus::{
    adopt_running, forward, DynSpawner, SessionIface, SharedUsage, BUS_NAME, OBJECT_PATH,
};
use ruya_session::directory::ProfileSnapshot;
use ruya_session::session::Session;
use ruya_session::spawner::{FakeSpawner, UnitEvent, PULSE_DIR, WAYLAND_DIR};
use ruya_session::usage::SystemZone;
use ruya_session::usage_store::FileStore;
use ruya_session::usage_tracker::Tracker;

fn main() {
    if let Err(err) = run() {
        eprintln!("ruya-session: fatal: {err}");
        std::process::exit(1);
    }
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
        // server, so SDL is told to use Wayland: SDL 2 otherwise tries X11 first and, without
        // the xdg-decoration protocol, may never try Wayland ("No available video device").
        (
            system_spawner(tx)?,
            ProfileSnapshot::default(),
            vec![("SDL_VIDEODRIVER".to_owned(), "wayland".to_owned())],
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
        let connection = builder
            .serve_at(
                OBJECT_PATH,
                SessionIface::new(session.clone(), usage.clone(), !dev),
            )?
            .build()
            .await?;
        // Apps that kept running through a restart are taken over, and play runs that never
        // ended (crash, power cut) end at their last heartbeat, before the name is taken: the
        // first `ListRunning` of the shell already sees them.
        adopt_running(&connection, &session, &usage, !dev).await;
        connection.request_name(BUS_NAME).await?;
        forward(connection, session, usage, !dev, rx).await;
        Ok::<(), Box<dyn Error>>(())
    })
}
