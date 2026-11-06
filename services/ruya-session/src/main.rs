//! ruya-session: serves org.ruyaos.Session1. In the image (no argument) it runs as root on the
//! system bus and starts apps through systemd (`SystemdSpawner`, Linux only); the profiles come
//! from `Profiles1` before each launch. `--session` is the development mode: the session bus,
//! a fake spawner with a few demo apps and the shell's mock profiles (T-139).

use std::error::Error;
use std::sync::{Arc, Mutex};

use async_channel::{Receiver, Sender};
use ruya_session::dbus::{forward, DynSpawner, SessionIface, BUS_NAME, OBJECT_PATH};
use ruya_session::directory::ProfileSnapshot;
use ruya_session::session::Session;
use ruya_session::spawner::{FakeSpawner, UnitEvent};

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
    let (spawner, profiles, env): (DynSpawner, ProfileSnapshot, Vec<(String, String)>) = if dev {
        let fake = FakeSpawner::new()
            .with_app("org.ruyaos.Racer")
            .with_app("org.ruyaos.Puzzle")
            .with_events(tx);
        // The shell's mock profiles; `unix_user` is what the fake spawner is told to run as.
        (
            Box::new(fake),
            ProfileSnapshot::new(["p1", "p2", "guest"].map(str::to_owned)),
            vec![("WAYLAND_DISPLAY".to_owned(), "wayland-0".to_owned())],
        )
    } else {
        // No display for the app yet: the profile's own Wayland socket is T-164's.
        (system_spawner(tx)?, ProfileSnapshot::default(), Vec::new())
    };
    let session = Arc::new(Mutex::new(Session::new(spawner, profiles, env)));

    futures_lite::future::block_on(async {
        let builder = if dev {
            zbus::connection::Builder::session()?
        } else {
            zbus::connection::Builder::system()?
        };
        let connection = builder
            .name(BUS_NAME)?
            .serve_at(OBJECT_PATH, SessionIface::new(session.clone(), !dev))?
            .build()
            .await?;
        forward(connection, session, rx).await;
        Ok::<(), Box<dyn Error>>(())
    })
}
