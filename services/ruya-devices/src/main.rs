//! ruya-devices: serves org.ruyaos.Devices1.Audio and .Network on the system bus, as a systemd
//! user unit of `ruya-shell` (ADR-010). With `--session` (development) it serves on the session
//! bus over a fake PipeWire and a fake NetworkManager.

use std::error::Error;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use ruya_devices::audio::{Audio, FakePipeWire};
use ruya_devices::dbus::{
    watch, watch_network, AudioIface, DynNm, DynPipeWire, NetworkIface, BUS_NAME, OBJECT_PATH,
};
use ruya_devices::network::{FakeNetworkManager, Network};
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

fn network_manager(session: bool) -> Result<DynNm, Box<dyn Error>> {
    #[cfg(target_os = "linux")]
    if !session {
        return Ok(Box::new(ruya_devices::networkmanager::NmClient::connect()?));
    }
    let _ = session;
    // The password of the fake networks is the one the shell's own mock accepts.
    Ok(Box::new(FakeNetworkManager::new("ruya-wifi-pass")))
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

    let net = Arc::new(Network::new(network_manager(session)?));
    // Same rule as for PipeWire: NetworkManager not up yet is retried by its signals.
    if let Err(err) = net.refresh() {
        eprintln!("ruya-devices: NetworkManager not readable yet: {err}");
    }

    futures_lite::future::block_on(async {
        let builder = if session {
            zbus::connection::Builder::session()?
        } else {
            zbus::connection::Builder::system()?
        };
        let connection = builder
            .name(BUS_NAME)?
            .serve_at(OBJECT_PATH, AudioIface::new(audio.clone()))?
            .serve_at(OBJECT_PATH, NetworkIface::new(net.clone()))?
            .build()
            .await?;
        // The fake NetworkManager has no signals to follow (it changes only through calls).
        if session {
            watch(connection, audio).await;
        } else {
            futures_lite::future::zip(
                watch(connection.clone(), audio),
                watch_network(connection, net),
            )
            .await;
        }
        Ok::<(), Box<dyn Error>>(())
    })
}
