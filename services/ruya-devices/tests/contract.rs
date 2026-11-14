//! RUY-403: every interface ruya-devices serves is its `<interface>` in
//! api/dbus/org.ruyaos.Devices1.xml. The objects are built with the same fakes `--session` serves,
//! and read without a bus.

use std::sync::{Arc, Mutex};

use ruya_contract_test::{assert_interfaces_are, assert_serves};
use ruya_devices::audio::{Audio, FakePipeWire};
use ruya_devices::backlight::Backlight;
use ruya_devices::battery::{Batteries, FakeUPower};
use ruya_devices::bluetooth::{Bluetooth, FakeBluez};
use ruya_devices::dbus::{
    AudioIface, BatteriesIface, BluetoothIface, DisplayIface, DynBluez, DynNm, DynPipeWire,
    DynScanSource, DynSource, DynThermal, DynTimedate, DynUPower, DynUdisks, NetworkIface, Shared,
    SharedBatteries, SharedBluetooth, SharedDisplay, SharedInput, SharedNet, SharedPerformance,
    SharedScans, SharedStorage, SharedSystem, SharedThermal, SharedTime, SharedUsage, StorageIface,
    SystemIface, ThermalIface, TimeIface,
};
use ruya_devices::display::{Display, DynDrm, FakeDrm};
use ruya_devices::drive_scan::{FakeTree, Scans};
use ruya_devices::input::{DynInputSource, FakeInput, InputPresence};
use ruya_devices::network::{FakeNetworkManager, Network};
use ruya_devices::performance::Performance;
use ruya_devices::storage::{FakeUdisks, Storage};
use ruya_devices::store::Store;
use ruya_devices::sysinfo::{DynInfoSource, SystemInfo};
use ruya_devices::sysusage::{FakeSource, MonotonicClock, SystemUsage};
use ruya_devices::thermal::{Config as ThermalConfig, FakeSource as FakeSensors, Monitor};
use ruya_devices::time::{FakeTimedate, Time};

const FILE: &str = "org.ruyaos.Devices1.xml";

fn batteries() -> SharedBatteries {
    Arc::new(Batteries::new(
        Box::new(FakeUPower::new(Vec::new())) as DynUPower
    ))
}

fn bluetooth() -> SharedBluetooth {
    Arc::new(Bluetooth::new(
        Box::new(FakeBluez::with_old_pad()) as DynBluez
    ))
}

#[test]
fn audio_matches_the_contract() {
    let pipewire: DynPipeWire = Box::new(FakePipeWire::new());
    let audio = Audio::new(pipewire, Store::in_memory()).expect("a fake PipeWire");
    let shared: Shared = Arc::new(Mutex::new(audio));
    assert_serves(FILE, &AudioIface::new(shared), &[]);
}

#[test]
fn network_matches_the_contract() {
    let nm: DynNm = Box::new(FakeNetworkManager::new("secret"));
    let net: SharedNet = Arc::new(Network::new(nm));
    assert_serves(FILE, &NetworkIface::new(net), &[]);
}

#[test]
fn batteries_matches_the_contract() {
    assert_serves(FILE, &BatteriesIface::new(batteries(), bluetooth()), &[]);
}

#[test]
fn bluetooth_matches_the_contract() {
    let input: SharedInput = Arc::new(InputPresence::new(
        Box::new(FakeInput::new(Vec::new())) as DynInputSource
    ));
    assert_serves(
        FILE,
        &BluetoothIface::new(bluetooth(), input, batteries()),
        &[],
    );
}

#[test]
fn storage_matches_the_contract() {
    let storage: SharedStorage = Arc::new(Storage::new(
        Box::new(FakeUdisks::new(Vec::new())) as DynUdisks
    ));
    let usage: SharedUsage = Arc::new(SystemUsage::new(
        Box::new(FakeSource::new(1, 1, 1, 1)) as DynSource,
        MonotonicClock::new(),
    ));
    let scans: SharedScans = Arc::new(Scans::new(
        Box::new(FakeTree::dev_stick("/media/stick")) as DynScanSource,
        MonotonicClock::new(),
    ));
    assert_serves(FILE, &StorageIface::new(storage, usage, scans), &[]);
}

#[test]
fn thermal_matches_the_contract() {
    let monitor: SharedThermal = Arc::new(Monitor::new(
        Box::new(FakeSensors::new(Vec::new())) as DynThermal,
        ThermalConfig::default(),
    ));
    assert_serves(FILE, &ThermalIface::new(monitor), &[]);
}

#[test]
fn time_matches_the_contract() {
    let time: SharedTime = Arc::new(Time::new(
        Box::new(FakeTimedate::with_zones()) as DynTimedate
    ));
    assert_serves(FILE, &TimeIface::new(time, true), &[]);
}

#[test]
fn display_matches_the_contract() {
    let dir = tempfile::tempdir().expect("temp dir");
    let display: SharedDisplay = Arc::new(Display::new(
        Box::new(FakeDrm(Vec::new())) as DynDrm,
        Some(dir.path().to_owned()),
    ));
    let backlight = Arc::new(Backlight::new(dir.path().join("backlight"), true));
    assert_serves(FILE, &DisplayIface::new(display, backlight), &[]);
}

#[test]
fn system_matches_the_contract() {
    let source = || -> DynInfoSource {
        Box::new(ruya_sysinfo::FakeSource::from_dump(
            ruya_sysinfo::SAMPLE_MACHINE,
        ))
    };
    let system: SharedSystem = Arc::new(SystemInfo::new(source()));
    let performance: SharedPerformance = Arc::new(Performance::new(source(), false));
    assert_serves(FILE, &SystemIface::new(system, performance), &[]);
}

/// The test file covers every interface of Devices1.xml: a tenth one added to the contract fails
/// here until it has a test above.
#[test]
fn every_devices1_interface_has_a_test() {
    assert_interfaces_are(
        FILE,
        &[
            "org.ruyaos.Devices1.Audio",
            "org.ruyaos.Devices1.Network",
            "org.ruyaos.Devices1.Batteries",
            "org.ruyaos.Devices1.Bluetooth",
            "org.ruyaos.Devices1.Storage",
            "org.ruyaos.Devices1.Thermal",
            "org.ruyaos.Devices1.Time",
            "org.ruyaos.Devices1.Display",
            "org.ruyaos.Devices1.System",
        ],
    );
}
