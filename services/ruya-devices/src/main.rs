//! ruya-devices: serves org.ruyaos.Devices1.Audio, .Network, .Bluetooth, .Storage, .Batteries, .Thermal, .Time and .System on the system bus, as a systemd
//! user unit of `ruya-shell` (ADR-010). With `--session` (development) it serves on the session
//! bus over a fake PipeWire, NetworkManager, BlueZ, udisks2, UPower, sensors and timedated.

use std::error::Error;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use ruya_devices::audio::{Audio, FakePipeWire};
use ruya_devices::backlight::Backlight;
use ruya_devices::battery::{Batteries, FakeUPower, RawDevice, KIND_GAMING_INPUT};
use ruya_devices::bluetooth::{AgentHandler, AgentSlot, Bluetooth, FakeBluez};
#[cfg(target_os = "linux")]
use ruya_devices::dbus::{
    watch, watch_batteries, watch_bluetooth, watch_input, watch_installed, watch_network,
    watch_storage, watch_thermal, watch_time,
};
use ruya_devices::dbus::{
    AudioIface, BatteriesIface, BluetoothIface, DisplayIface, DynBluez, DynNm, DynPipeWire,
    DynScanSource, DynSource, DynThermal, DynTimedate, DynUPower, DynUdisks, NetworkIface, Shared,
    SharedBatteries, SharedBluetooth, SharedDisplay, SharedInput, SharedNet, SharedPerformance,
    SharedScans, SharedStorage, SharedSystem, SharedThermal, SharedTime, SharedUsage, StorageIface,
    SystemIface, ThermalIface, TimeIface, BUS_NAME, OBJECT_PATH,
};
use ruya_devices::display::{self, Display, DynDrm, FakeDrm, Mode, Output, SysfsDrm};
#[cfg(target_os = "linux")]
use ruya_devices::drive_scan::FsSource;
use ruya_devices::drive_scan::{FakeTree, Scans};
use ruya_devices::input::{DynInputSource, FakeInput, InputDevice, InputPresence};
use ruya_devices::network::{FakeNetworkManager, Network};
use ruya_devices::output_policy::ChoiceStore;
use ruya_devices::performance::Performance;
use ruya_devices::storage::{FakeUdisks, RawVolume, Storage};
use ruya_devices::store::Store;
use ruya_devices::sysinfo::{DynInfoSource, SystemInfo, WithPrimaryAdapter};
#[cfg(target_os = "linux")]
use ruya_devices::sysusage::LinuxSource;
use ruya_devices::sysusage::{FakeSource, MonotonicClock, SystemUsage};
use ruya_devices::thermal::{
    Class, Config as ThermalConfig, FakeSource as FakeSensors, Monitor, RawSensor, SysfsSource,
    LOCAL_CONFIG, SYSTEM_CONFIG,
};
use ruya_devices::time::{FakeTimedate, Time};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--display-guard") {
        return display_guard(&args);
    }
    if let Some(at) = args.iter().position(|a| a == "--display-list") {
        return display_list(args.get(at + 1).map(PathBuf::from));
    }
    if let Err(err) = run() {
        eprintln!("ruya-devices: fatal: {err}");
        std::process::exit(1);
    }
}

fn pipewire(session: bool) -> DynPipeWire {
    #[cfg(target_os = "linux")]
    if !session {
        return Box::new(ruya_devices::pipewire::WpCtl::default());
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

/// BlueZ, and the slot where BlueZ's agent calls find the core once it exists.
fn bluez(session: bool) -> Result<(DynBluez, AgentSlot), Box<dyn Error>> {
    #[cfg(target_os = "linux")]
    if !session {
        let client = ruya_devices::bluez::BluezClient::connect()?;
        let slot = client.agent_slot();
        return Ok((Box::new(client), slot));
    }
    let _ = session;
    // `RUYA_DEVICES_FAKE_BLUETOOTH=two-adapters`: a machine with two adapters (T-336).
    let fake = match std::env::var("RUYA_DEVICES_FAKE_BLUETOOTH").as_deref() {
        Ok("two-adapters") => FakeBluez::with_two_adapters(),
        // Two pads with the same name, one connected and one in pairing mode (T-334).
        Ok("two-pads") => FakeBluez::with_two_pads(),
        _ => FakeBluez::with_old_pad(),
    };
    Ok((Box::new(fake), AgentSlot::default()))
}

/// The kernel's input devices; in `--session` a keyboard is there unless
/// `RUYA_DEVICES_NO_INPUT` is set (to try the shell's "no controller" screens).
fn input_source(session: bool) -> DynInputSource {
    #[cfg(target_os = "linux")]
    if !session {
        return Box::new(ruya_devices::input::SysfsInput::system());
    }
    let _ = session;
    let devices: Vec<InputDevice> = if std::env::var_os("RUYA_DEVICES_NO_INPUT").is_some() {
        Vec::new()
    } else {
        vec![FakeInput::keyboard()]
    };
    Box::new(FakeInput::new(devices))
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
        ..RawDevice::default()
    }])))
}

fn timedate(session: bool) -> Result<DynTimedate, Box<dyn Error>> {
    #[cfg(target_os = "linux")]
    if !session {
        return Ok(Box::new(ruya_devices::timedate::TimedateClient::connect()?));
    }
    let _ = session;
    Ok(Box::new(FakeTimedate::with_zones()))
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

/// The walk over a removable drive: the real file system, or in `--session` a made-up stick
/// where the fake udisks mounts "DEV STICK".
fn scan_source(session: bool) -> DynScanSource {
    #[cfg(target_os = "linux")]
    if !session {
        return Box::new(FsSource);
    }
    let _ = session;
    Box::new(FakeTree::dev_stick("/run/media/ruya-shell/DEV STICK"))
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

/// The sensors: the kernel's sysfs (`RUYA_THERMAL_SYSFS` points it at a made-up tree to try the
/// policy, see docs/dev-setup.md), or fixed believable values in `--session`.
fn thermal_source(session: bool) -> DynThermal {
    if session {
        let sensor = |id: &str, class, value| RawSensor {
            id: id.to_owned(),
            class,
            value,
            crit: None,
        };
        return Box::new(FakeSensors::new(vec![
            sensor("fake:cpu", Class::Cpu, 41.0),
            sensor("fake:ssd", Class::Ssd, 38.0),
            sensor("fake:fan", Class::Fan, 1820.0),
        ]));
    }
    match std::env::var_os("RUYA_THERMAL_SYSFS") {
        Some(root) => Box::new(SysfsSource::new(root, "/proc/stat")),
        None => Box::new(SysfsSource::system()),
    }
}

/// What the System information reads: the running system, or in `--session` the sample machine
/// of `ruya-sysinfo` (the Dell of the task), so the shell has something to show on any host.
fn info_source(session: bool) -> DynInfoSource {
    if session {
        return Box::new(ruya_sysinfo::FakeSource::from_dump(
            ruya_sysinfo::SAMPLE_MACHINE,
        ));
    }
    Box::new(ruya_sysinfo::RootSource::system())
}

/// What the performance numbers are read from: the running system, or in `--session` the Dell as
/// it was captured for T-451 (fixed counters, so the rates read 0).
fn performance_source(session: bool) -> DynInfoSource {
    if session {
        return Box::new(ruya_sysinfo::FakeSource::from_dump(include_str!(
            "../tests/fixtures/performance-dell.dump"
        )));
    }
    Box::new(ruya_sysinfo::RootSource::system())
}

/// The directory of the display's files (the choice, the KMS config, the markers): next to the
/// audio levels, i.e. the unit's `StateDirectory=`; `--state-dir` and `RUYA_DEVICES_FILE`'s parent
/// are for development, and the compositor's guard (which has no `STATE_DIRECTORY`) finds the
/// same directory under the shell user's home.
fn display_dir(session: bool, given: Option<PathBuf>) -> Option<PathBuf> {
    if let Some(dir) = given {
        return Some(dir);
    }
    if let Some(file) = std::env::var_os("RUYA_DEVICES_FILE") {
        return PathBuf::from(file).parent().map(PathBuf::from);
    }
    if let Some(dir) = std::env::var_os("STATE_DIRECTORY") {
        let first = dir.to_string_lossy().split(':').next()?.to_owned();
        return Some(PathBuf::from(first));
    }
    if session {
        return Some(std::env::temp_dir().join("ruya-devices-session"));
    }
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(".local/state/ruya-devices"))
}

/// The kernel's outputs (`RUYA_DRM_DIR` points at a copy of `/sys/class/drm`, e.g. a capture from
/// a TV), or in `--session` two believable fake ones.
fn drm_source(session: bool) -> DynDrm {
    if let Some(dir) = std::env::var_os("RUYA_DRM_DIR") {
        return Box::new(SysfsDrm::under(dir));
    }
    if session {
        let mode = |width, height, refresh_mhz, preferred| Mode {
            width,
            height,
            refresh_mhz,
            preferred,
        };
        let output = |id: &str, name: &str, mm: (u32, u32), modes| Output {
            id: id.to_owned(),
            name: name.to_owned(),
            width_mm: mm.0,
            height_mm: mm.1,
            modes,
        };
        return Box::new(FakeDrm(vec![
            output(
                "HDMI-A-1",
                "Dev TV",
                (1220, 690),
                vec![
                    mode(3840, 2160, 60_000, true),
                    mode(1920, 1080, 60_000, false),
                    mode(1280, 720, 60_000, false),
                ],
            ),
            output(
                "DP-1",
                "Dev Monitor",
                (700, 390),
                vec![
                    mode(2560, 1440, 60_000, true),
                    mode(1920, 1080, 60_000, false),
                ],
            ),
        ]));
    }
    Box::new(SysfsDrm::system())
}

/// `ruya-devices --display-guard [--state-dir DIR]`: `ExecStartPre=` of the compositor unit
/// (`display::guard`). Never fails the start, whatever happens.
fn display_guard(args: &[String]) {
    let given = args
        .iter()
        .position(|a| a == "--state-dir")
        .and_then(|at| args.get(at + 1))
        .map(PathBuf::from);
    let Some(dir) = display_dir(false, given) else {
        return eprintln!("ruya-devices: --display-guard: no state directory (HOME is not set)");
    };
    match display::guard(&dir, drm_source(false).as_ref()) {
        Ok(outcome) => eprintln!("ruya-devices: display guard: {outcome:?}"),
        Err(err) => eprintln!("ruya-devices: display guard failed: {err}"),
    }
}

/// `ruya-devices --display-list [DIR]`: prints the outputs and modes the service would offer, from
/// `/sys/class/drm` or from a capture of it (`scripts/display-capture.sh`), one line each.
fn display_list(dir: Option<PathBuf>) {
    let source = dir.map_or_else(SysfsDrm::system, SysfsDrm::under);
    match ruya_devices::display::DrmSource::outputs(&source) {
        Ok(outputs) if outputs.is_empty() => println!("no connected output"),
        Ok(outputs) => {
            for o in outputs {
                println!("{}  {:?}  {}x{} mm", o.id, o.name, o.width_mm, o.height_mm);
                for m in o.modes {
                    println!(
                        "  {}x{} @ {} mHz{}",
                        m.width,
                        m.height,
                        m.refresh_mhz,
                        if m.preferred { "  (preferred)" } else { "" }
                    );
                }
            }
        }
        Err(err) => {
            eprintln!("ruya-devices: {err}");
            std::process::exit(1);
        }
    }
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
#[allow(clippy::too_many_arguments)]
async fn follow_system(
    connection: zbus::Connection,
    audio: Shared,
    net: SharedNet,
    batteries: SharedBatteries,
    bluetooth: SharedBluetooth,
    input: SharedInput,
    storage: SharedStorage,
    usage: SharedUsage,
    thermal: SharedThermal,
    time: SharedTime,
) {
    #[cfg(target_os = "linux")]
    futures_lite::future::zip(
        watch(connection.clone(), audio),
        futures_lite::future::zip(
            watch_network(connection.clone(), net),
            futures_lite::future::zip(
                watch_batteries(connection.clone(), batteries, bluetooth.clone()),
                futures_lite::future::zip(
                    watch_bluetooth(connection.clone(), bluetooth),
                    futures_lite::future::zip(
                        watch_input(connection.clone(), input),
                        futures_lite::future::zip(
                            watch_storage(connection.clone(), storage),
                            futures_lite::future::zip(
                                watch_installed(connection.clone(), usage),
                                futures_lite::future::zip(
                                    watch_thermal(connection.clone(), thermal),
                                    watch_time(connection, time),
                                ),
                            ),
                        ),
                    ),
                ),
            ),
        ),
    )
    .await;
    #[cfg(not(target_os = "linux"))]
    {
        let _keep = (
            connection, audio, net, batteries, bluetooth, input, storage, usage, thermal, time,
        );
        futures_lite::future::pending::<()>().await;
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let session = std::env::args().any(|a| a == "--session");
    let store = state_file().map_or_else(Store::in_memory, |p| Store::at(&p));
    let choice_store = state_file().map_or_else(ChoiceStore::in_memory, |p| {
        ChoiceStore::at(&p.with_file_name("outputs.toml"))
    });
    let mut audio = Audio::new(pipewire(session), store)?.with_choice_store(choice_store)?;
    // The high first-start volume is set once, never again (T-347); `--session` has no state dir.
    if let Some(p) = state_file() {
        // An existing install (audio.toml, outputs.toml or WirePlumber's saved volumes are
        // there) never gets the volume forced.
        let existing = ruya_devices::audio::existing_install(&p);
        audio = audio.with_first_start_marker(&p.with_file_name("first-volume-done"), existing);
    }
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
    let (bluez, agent) = bluez(session)?;
    let bluetooth: SharedBluetooth = Arc::new(Bluetooth::new(bluez));
    // BlueZ's questions to our agent (only while the pairing window is open) go to the core.
    let handler: Arc<dyn AgentHandler> = bluetooth.clone();
    let _ = agent.set(handler);
    if let Err(err) = bluetooth.refresh() {
        eprintln!("ruya-devices: BlueZ not readable yet: {}", err.0);
    }
    // The batteries' first families, now that Bluetooth is known (nobody listens yet).
    batteries.recheck(&bluetooth.list());
    // Keyboards and gamepads, from the kernel; no input at all is what the shell offers
    // controller pairing for.
    let input: SharedInput = Arc::new(InputPresence::new(input_source(session)));
    input.refresh();

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

    // What is on a removable drive: names and sizes, one scan at a time (`drive_scan.rs`).
    let scans: SharedScans = Arc::new(Scans::new(scan_source(session), MonotonicClock::new()));

    // The thresholds: the image's file, then the owner's own.
    let monitor: SharedThermal = Arc::new(Monitor::new(
        thermal_source(session),
        ThermalConfig::load(&[PathBuf::from(SYSTEM_CONFIG), PathBuf::from(LOCAL_CONFIG)]),
    ));
    if let Err(err) = monitor.poll() {
        eprintln!("ruya-devices: sensors not readable yet: {err}");
    }

    // timedated not up yet is retried by its signals; its zone is read once now.
    let time: SharedTime = Arc::new(Time::new(timedate(session)?));
    if let Err(err) = time.refresh() {
        eprintln!("ruya-devices: timedated not readable yet: {err}");
    }

    // The outputs are read from the kernel at every call; the choice is a file in the state dir.
    let display: SharedDisplay = Arc::new(Display::new(
        drm_source(session),
        display_dir(session, None),
    ));

    // The slow part is read once, now, off the main thread, so the first call finds it.
    let primary_bt = bluetooth.clone();
    let system: SharedSystem = Arc::new(SystemInfo::new(Box::new(WithPrimaryAdapter::new(
        info_source(session),
        Box::new(move || primary_bt.primary_adapter()),
    ))));
    // Read only when the shell asks (its Performance view is open); no timer of its own.
    let performance: SharedPerformance = Arc::new(Performance::new(
        performance_source(session),
        !session && ruya_devices::performance::reads_all_processes(),
    ));
    {
        let warm = system.clone();
        std::thread::spawn(move || {
            warm.current(std::time::Instant::now());
        });
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
            .serve_at(
                OBJECT_PATH,
                BatteriesIface::new(batteries.clone(), bluetooth.clone()),
            )?
            .serve_at(
                OBJECT_PATH,
                BluetoothIface::new(bluetooth.clone(), input.clone(), batteries.clone()),
            )?
            .serve_at(
                OBJECT_PATH,
                StorageIface::new(storage.clone(), usage.clone(), scans.clone()),
            )?
            .serve_at(OBJECT_PATH, ThermalIface::new(monitor.clone()))?
            .serve_at(OBJECT_PATH, TimeIface::new(time.clone(), session))?
            .serve_at(
                OBJECT_PATH,
                DisplayIface::new(display.clone(), Arc::new(Backlight::system())),
            )?
            .serve_at(
                OBJECT_PATH,
                SystemIface::new(system.clone(), performance.clone()),
            )?
            .build()
            .await?;
        // The fakes have nothing to follow (they change only through calls): just stay up.
        if session {
            let _keep = (
                connection, audio, net, batteries, bluetooth, input, storage, usage, monitor, time,
                system, display,
            );
            futures_lite::future::pending::<()>().await;
        } else {
            follow_system(
                connection, audio, net, batteries, bluetooth, input, storage, usage, monitor, time,
            )
            .await;
        }
        Ok::<(), Box<dyn Error>>(())
    })
}
