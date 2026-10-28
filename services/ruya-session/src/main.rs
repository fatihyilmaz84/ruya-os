//! ruya-session: serves org.ruyaos.Session1. Development only for now (T-139): it needs
//! `--session` and then serves on the session bus over a fake spawner with a few demo apps. The
//! real spawner, the systemd unit and the bus policy follow T-130; without `--session` this
//! program refuses to start.

use std::error::Error;
use std::sync::{Arc, Mutex};

use ruya_session::dbus::{forward, DynSpawner, SessionIface, BUS_NAME, OBJECT_PATH};
use ruya_session::directory::ProfileSnapshot;
use ruya_session::session::Session;
use ruya_session::spawner::FakeSpawner;

fn main() {
    if let Err(err) = run() {
        eprintln!("ruya-session: fatal: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    if !std::env::args().any(|a| a == "--session") {
        return Err("only --session (development, fake spawner) exists yet; see T-139".into());
    }
    let (tx, rx) = async_channel::unbounded();
    let spawner: DynSpawner = Box::new(
        FakeSpawner::new()
            .with_app("org.ruyaos.Racer")
            .with_app("org.ruyaos.Puzzle")
            .with_events(tx),
    );
    // The shell's mock profiles; `unix_user` is what the fake spawner is told to run as.
    let profiles = ProfileSnapshot::new(["p1", "p2", "guest"].map(str::to_owned));
    let env = vec![("WAYLAND_DISPLAY".to_owned(), "wayland-0".to_owned())];
    let session = Arc::new(Mutex::new(Session::new(spawner, profiles, env)));

    futures_lite::future::block_on(async {
        let connection = zbus::connection::Builder::session()?
            .name(BUS_NAME)?
            .serve_at(OBJECT_PATH, SessionIface::new(session.clone(), false))?
            .build()
            .await?;
        forward(connection, session, rx).await;
        Ok::<(), Box<dyn Error>>(())
    })
}
