//! ruya-devices: serves org.ruyaos.Devices1.Audio, .Network, .Bluetooth, .Storage and .Batteries on the system bus, as a systemd
//! user unit of `ruya-shell` (ADR-010). With `--session` (development) it serves on the session
//! bus over a fake PipeWire, NetworkManager, BlueZ, udisks2 and UPower.

use std::error::Error;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use ruya_devices::audio::{Audio, FakePipeWire};
use ruya_devices::battery::{Batteries, FakeUPower, RawDevice, KIND_GAMING_INPUT};
use ruya_devices::bluetooth::{Bluetooth, FakeBluez};
#[cfg(target_os = "linux")]
use ruya_devices::dbus::{
    watch, watch_batteries, watch_bluetooth, watch_installed, watch_network, watch_storage,
};
use ruya_devices::dbus::{
    AudioIface, BatteriesIface, BluetoothIface, DynBluez, DynNm, DynPipeWire, DynSource, DynUPower,
    DynUdisks, NetworkIface, Shared, SharedBatteries, SharedBluetooth, SharedNet, SharedStorage,
    SharedUsage, StorageIface, BUS_NAME, OBJECT_PATH,
};
use ruya_devices::network::{FakeNetworkManager, Network};
use ruya_devices::storage::{FakeUdisks, RawVolume, Storage};
use ruya_devices::store::Store;
#[cfg(target_os = "linux")]
use ruya_devices::sysusage::LinuxSource;
use ruya_devices::sysusage::{FakeSource, MonotonicClock, SystemUsage};

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

fn bluez(session: bool) -> Result<DynBluez, Box<dyn Error>> {
    #[cfg(target_os = "linux")]
    if !session {
        return Ok(Box::new(ruya_devices::bluez::BluezClient::connect()?));
    }
    let _ = session;
    Ok(Box::new(FakeBluez::with_devices()))
}

fn upower(session: bool) -> Result<DynUPower, Box<dyn Error>> {
    #[cfg(target_os = "linux")]
    if !session {
        return Ok(Box::new(ruya_devices::upower::UPowerClient::connect()?));
    }
    let _ = session;
    Ok(Box::new(FakeUPower::new(vec![RawDevice {
        id: "/fake/gaming_input_0".to_owned(),
        kind: KIND_GAMING_INPUT,
        model: "Dev Pad".to_owned(),
        percentage: 60.0,
        state: 2,
    }])))
}

fn udisks(session: bool) -> Result<DynUdisks, Box<dyn Error>> {
    #[cfg(target_os = "linux")]
    if !session {
        return Ok(Box::new(ruya_devices::udisks::UdisksClient::connect()?));
    }
    let _ = session;
    Ok(Box::new(FakeUdisks::new(vec![RawVolume {
        id: "/fake/sdb1".to_owned(),
        drive: "/fake/sdb".to_owned(),
        label: "DEV STICK".to_owned(),
        model: "Ruya Dev Stick".to_owned(),
        id_type: "exfat".to_owned(),
        size_bytes: 16_000_000_000,
        free_bytes: 0,
        hint_system: false,
        hint_ignore: false,
        drive_removable: true,
        bus: "usb".to_owned(),
        mount_points: Vec::new(),
        read_only: false,
    }])))
}

fn usage_source(session: bool) -> DynSource {
    #[cfg(target_os = "linux")]
    if !session {
        return Box::new(LinuxSource);
    }
    let _ = session;
    // A believable disk for development: 464 GB, 450 GB free.
    Box::new(FakeSource::new(
        464_000_000_000,
        450_000_000_000,
        8_000_000_000,
        2_000_000_000,
    ))
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

/// PipeWire's events, NetworkManager's, BlueZ's and UPower's signals, until the process is stopped.
async fn follow_system(
    connection: zbus::Connection,
    audio: Shared,
    net: SharedNet,
    batteries: SharedBatteries,
    bluetooth: SharedBluetooth,
    storage: SharedStorage,
    usage: SharedUsage,
) {
    #[cfg(target_os = "linux")]
    futures_lite::future::zip(
        watch(connection.clone(), audio),
        futures_lite::future::zip(
            watch_network(connection.clone(), net),
            futures_lite::future::zip(
                watch_batteries(connection.clone(), batteries),
                futures_lite::future::zip(
                    watch_bluetooth(connection.clone(), bluetooth),
                    futures_lite::future::zip(
                        watch_storage(connection.clone(), storage),
                        watch_installed(connection, usage),
                    ),
                ),
            ),
        ),
    )
    .await;
    #[cfg(not(target_os = "linux"))]
    {
        let _keep = (connection, audio, net, batteries, bluetooth, storage, usage);
        futures_lite::future::pending::<()>().await;
    }
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

    // UPower missing is an empty list (the client says so), and UPower not up yet is retried by
    // its signals, like the others.
    let batteries: SharedBatteries = Arc::new(Batteries::new(upower(session)?));
    if let Err(err) = batteries.refresh() {
        eprintln!("ruya-devices: UPower not readable yet: {err}");
    }

    // No adapter (or no BlueZ) is "unavailable" and an empty list; BlueZ not up yet is retried
    // by its signals.
    let bluetooth: SharedBluetooth = Arc::new(Bluetooth::new(bluez(session)?));
    if let Err(err) = bluetooth.refresh() {
        eprintln!("ruya-devices: BlueZ not readable yet: {}", err.0);
    }

    // udisks2 not up yet is retried by its signals. The first read mounts the removable volumes
    // that are already plugged in (without announcing them as added).
    let storage: SharedStorage = Arc::new(Storage::new(udisks(session)?));
    if let Err(err) = storage.refresh() {
        eprintln!("ruya-devices: udisks2 not readable yet: {err}");
    }

    // Directory sizes are measured off the executor, cached, and re-measured when the Store says
    // the installed apps changed (`sysusage.rs`).
    let usage: SharedUsage = Arc::new(SystemUsage::new(
        usage_source(session),
        MonotonicClock::new(),
    ));

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
            .serve_at(OBJECT_PATH, BatteriesIface::new(batteries.clone()))?
            .serve_at(OBJECT_PATH, BluetoothIface::new(bluetooth.clone()))?
            .serve_at(
                OBJECT_PATH,
                StorageIface::new(storage.clone(), usage.clone()),
            )?
            .build()
            .await?;
        // The fakes have nothing to follow (they change only through calls): just stay up.
        if session {
            let _keep = (connection, audio, net, batteries, bluetooth, storage, usage);
            futures_lite::future::pending::<()>().await;
        } else {
            follow_system(connection, audio, net, batteries, bluetooth, storage, usage).await;
        }
        Ok::<(), Box<dyn Error>>(())
    })
}
