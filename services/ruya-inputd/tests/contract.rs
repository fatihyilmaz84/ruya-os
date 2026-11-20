//! RUY-403: the interface ruya-inputd serves is the one in api/dbus/org.ruyaos.Input1.xml.
//!
//! `Input1` is a draft that ruya-inputd builds member by member (the header of the XML says
//! which). Every member it serves must match the contract; `NOT_BUILT` lists the contract members
//! it does not serve yet, and the test fails when one of them is served after all, so the list
//! cannot go stale. When a task builds one of them, it takes the name off the list.

use std::time::{Duration, Instant};

use ruya_contract_test::{
    assert_interfaces_are, assert_record_served, assert_serves, record_signatures,
};
use ruya_inputd::accounts::FixedAccounts;
use ruya_inputd::dbus::{player, record, DynBackend, InputIface, Shared};
use ruya_inputd::routing::{DeviceRecord, NullBackend, Router};
use ruya_inputd::seats::Player;

/// Contract members of `Input1` with no implementation yet (the XML header: platform and game
/// assignments T-370 / RUY-43, OwnershipMode T-371). The players (JoinPlayer, LeavePlayer,
/// ListPlayers, PlayersChanged) are built since RUY-121, ForeignInput and SetNavigator since RUY-38.
const NOT_BUILT: &[&str] = &["GetOwnershipMode", "SetOwnershipMode"];

#[test]
fn input1_matches_the_contract() {
    let backend: DynBackend = Box::new(NullBackend);
    let router = Router::new(backend, Box::new(FixedAccounts(vec![("p1".into(), 1001)])));
    let (shared, _notices) = Shared::new(router);
    let iface = InputIface::new(shared);
    assert_serves("org.ruyaos.Input1.xml", &iface, NOT_BUILT);
    assert_interfaces_are("org.ruyaos.Input1.xml", &["org.ruyaos.Input1"]);
}

/// RUY-907: the keys of the device and player records, with their signatures, are the ones the
/// contract documents: a seated pad and a held seat go through the same `record()` and `player()`
/// the service serves.
#[test]
fn input1_device_and_player_records_have_the_documented_keys() {
    let device = DeviceRecord {
        id: "bluetooth-054c-0ce6-0123456789ab".into(),
        instance: "bluetooth-054c-0ce6-0123456789ab#1".into(),
        name: "DualSense Wireless Controller".into(),
        family: "playstation".into(),
        connection: "bluetooth".into(),
        model: "dualsense".into(),
        layout: String::new(),
        battery: 80,
        charging: true,
        slot: 1,
        profile: "p1".into(),
        owner: "p1".into(),
        routed: true,
    };
    assert_record_served(
        "org.ruyaos.Input1.xml",
        "Device",
        &[("a seated pad", record_signatures(&record(&device)))],
    );
    let now = Instant::now();
    let held = Player {
        slot: 2,
        profile: "p2".into(),
        device_id: device.id.clone(),
        held_until: Some(now + Duration::from_secs(30)),
    };
    assert_record_served(
        "org.ruyaos.Input1.xml",
        "Player",
        &[("a held seat", record_signatures(&player(&held, now)))],
    );
}
