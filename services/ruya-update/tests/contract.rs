//! RUY-403: the interface ruya-update serves is the one in api/dbus/org.ruyaos.Update1.xml; RUY-885
//! and RUY-29: so are the keys of its records (status, image job, download day).

use std::sync::Arc;

use ruya_contract_test::{
    assert_interfaces_are, assert_record_served, assert_serves, record_signatures,
};
use ruya_jobs::ledger::Day;
use ruya_update::bootc::{Bootc, Deployment, FakeBootc, FakeEnd, FakeRun, HostStatus, Progress};
use ruya_update::dbus::{day_dict, job_dict, record, DynBootc, UpdateIface};
use ruya_update::schedule::FakeClock;
use ruya_update::service::Update;

#[test]
fn update1_matches_the_contract() {
    let bootc: DynBootc = Box::new(FakeBootc::new(HostStatus::default()));
    let (changes, _receiver) = async_channel::unbounded();
    let iface = UpdateIface::new(Arc::new(Update::new(bootc, None)), changes, true);
    assert_serves("org.ruyaos.Update1.xml", &iface, &[]);
    assert_interfaces_are("org.ruyaos.Update1.xml", &["org.ruyaos.Update1"]);
}

fn host() -> HostStatus {
    let dep = |version: &str, digest: &str| Deployment {
        image: "reg:5000/ruyaos:stable".to_owned(),
        version: version.to_owned(),
        digest: digest.to_owned(),
    };
    HostStatus {
        tracked: "reg:5000/ruyaos:stable".to_owned(),
        booted: Some(dep("0.0.19", "sha256:a")),
        cached_update: Some(dep("0.0.20", "sha256:b")),
        ..HostStatus::default()
    }
}

#[test]
fn the_records_have_the_documented_keys() {
    let fake = FakeBootc::new(host());
    fake.script_pulls(vec![FakeRun {
        events: vec![Progress::Bytes {
            bytes: 10,
            bytes_total: 100,
            bytes_cached: 0,
            steps: 0,
            steps_total: 1,
            steps_cached: 0,
        }],
        end: FakeEnd::Done,
    }]);
    let bootc: Box<dyn Bootc> = Box::new(fake);
    let u = Update::new(bootc, None);
    u.refresh().expect("refresh");
    let clock = FakeClock::new(1000, 0);
    assert_eq!(u.begin_check().as_str(), "ok");
    u.run_check(1000, &mut || {});
    assert_eq!(u.begin_download(1000).as_str(), "ok");
    let running = u.job_record(0).expect("a job");
    u.run_download(&clock, &mut || {});
    let finished = u.job_record(0).expect("a job");
    assert_eq!(finished.status, "ok");
    let samples = [
        ("running", record_signatures(&job_dict(&running))),
        ("finished", record_signatures(&job_dict(&finished))),
    ];
    assert_record_served("org.ruyaos.Update1.xml", "Job", &samples);
    assert_record_served(
        "org.ruyaos.Update1.xml",
        "Status",
        &[("staged", record_signatures(&record(&u.record())))],
    );
    let day = Day {
        day: "2026-11-23".to_owned(),
        bytes: 10,
        jobs: 1,
        failed: 0,
    };
    assert_record_served(
        "org.ruyaos.Update1.xml",
        "Day",
        &[("day", record_signatures(&day_dict(&day)))],
    );
}
