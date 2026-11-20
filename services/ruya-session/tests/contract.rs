//! RUY-403: the interface ruya-session serves is the one in api/dbus/org.ruyaos.Session1.xml.

use std::sync::{Arc, Mutex};

use ruya_contract_test::{
    assert_interfaces_are, assert_record_served, assert_serves, record_signatures,
};
use ruya_session::dbus::{
    running_dict, session_dict, DynSpawner, SessionIface, Shared, SharedUsage,
};
use ruya_session::directory::ProfileSnapshot;
use ruya_session::session::{RunningApp, Session, State};
use ruya_session::spawner::FakeSpawner;
use ruya_session::usage::{EndReason, SessionRecord, SystemZone};
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

/// RUY-907: the keys of the running and session records, with their signatures, are the ones the
/// contract documents; both go through the dictionaries the service serves.
#[test]
fn session1_running_and_session_records_have_the_documented_keys() {
    let app = RunningApp {
        instance: "ruya-app-p1-org.example.Racer-1.scope".into(),
        app_id: "org.example.Racer".into(),
        profile: "p1".into(),
        started: 1_794_873_600,
        state: State::Running,
        frozen: false,
    };
    assert_record_served(
        "org.ruyaos.Session1.xml",
        "Running",
        &[("a running app", record_signatures(&running_dict(app)))],
    );
    let session = SessionRecord {
        app_id: "org.example.Racer".into(),
        app_version: "1.2".into(),
        start: 1_794_873_600,
        end: 1_794_877_200,
        foreground_seconds: 3000,
        reason: EndReason::Quit,
        days: vec![(20_408, 3000)],
        open: false,
    };
    assert_record_served(
        "org.ruyaos.Session1.xml",
        "Session",
        &[("a session", record_signatures(&session_dict(session)))],
    );
}
