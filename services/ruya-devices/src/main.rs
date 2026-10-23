//! ruya-devices: serves org.ruyaos.Devices1.Audio on the system bus, as a systemd user unit of
//! `ruya-shell` (ADR-010). With `--session` (development) it serves on the session bus over a
//! fake PipeWire.

use std::error::Error;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use ruya_devices::audio::{Audio, FakePipeWire};
use ruya_devices::dbus::{watch, AudioIface, DynPipeWire, BUS_NAME, OBJECT_PATH};
use ruya_devices::store::Store;

fn main() {
    if let Err(err) = run() {
        eprintln!("ruya-devices: fatal: {err}");
        std::process::exit(1);
    }
}

fn pipewire(session: bool) -> DynPipeWire {
    #[cfg(target_os = "linux")]
    if !session {
        return Box::new(ruya_devices::pipewire::WpCtl);
    }
    let _ = session;
    Box::new(FakePipeWire::new())
}

/// `RUYA_DEVICES_FILE`, else `$STATE_DIRECTORY/audio.toml` (systemd's StateDirectory=), else none.
fn state_file() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("RUYA_DEVICES_FILE") {
        return Some(PathBuf::from(p));
    }
    let dir = std::env::var_os("STATE_DIRECTORY")?;
    // Several directories are colon-separated; we declare exactly one.
    let first = dir.to_string_lossy().split(':').next()?.to_owned();
    Some(PathBuf::from(first).join("audio.toml"))
}

fn run() -> Result<(), Box<dyn Error>> {
    let session = std::env::args().any(|a| a == "--session");
    let store = state_file().map_or_else(Store::in_memory, |p| Store::at(&p));
    let mut audio = Audio::new(pipewire(session), store)?;
    // The first read only takes over the state; a failure here (PipeWire not up yet) is retried
    // by the watcher, so it must not stop the service.
    if let Err(err) = audio.refresh() {
        eprintln!("ruya-devices: PipeWire not readable yet: {err}");
    }
    let audio = Arc::new(Mutex::new(audio));

    futures_lite::future::block_on(async {
        let builder = if session {
            zbus::connection::Builder::session()?
        } else {
            zbus::connection::Builder::system()?
        };
        let connection = builder
            .name(BUS_NAME)?
            .serve_at(OBJECT_PATH, AudioIface::new(audio.clone()))?
            .build()
            .await?;
        watch(connection, audio).await;
        Ok::<(), Box<dyn Error>>(())
    })
}
