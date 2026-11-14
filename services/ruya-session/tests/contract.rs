//! RUY-403: the interface ruya-session serves is the one in api/dbus/org.ruyaos.Session1.xml.

use std::sync::{Arc, Mutex};

use ruya_contract_test::{assert_interfaces_are, assert_serves};
use ruya_session::dbus::{DynSpawner, SessionIface, Shared, SharedUsage};
use ruya_session::directory::ProfileSnapshot;
use ruya_session::session::Session;
use ruya_session::spawner::FakeSpawner;
use ruya_session::usage::SystemZone;
use ruya_session::usage_store::FileStore;
use ruya_session::usage_tracker::Tracker;

#[test]
fn session1_matches_the_contract() {
    let dir = tempfile::tempdir().expect("temp dir");
    let spawner: DynSpawner = Box::new(FakeSpawner::new());
    let session: Shared = Arc::new(Mutex::new(Session::new(
        spawner,
        ProfileSnapshot::default(),
        Vec::new(),
    )));
    let usage: SharedUsage = Arc::new(Mutex::new(Tracker::new(
        FileStore::new(dir.path()),
        SystemZone,
    )));
    // The system mode asks Profiles1; the interface is the same in both.
    let iface = SessionIface::new(session, usage, true);
    assert_serves("org.ruyaos.Session1.xml", &iface, &[]);
    assert_interfaces_are("org.ruyaos.Session1.xml", &["org.ruyaos.Session1"]);
}
