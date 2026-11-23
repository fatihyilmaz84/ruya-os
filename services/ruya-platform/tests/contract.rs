//! RUY-403: the interfaces ruya-platform serves are the ones in api/dbus/org.ruyaos.Platform1.xml.

use std::sync::{Arc, Mutex};

use ruya_contract_test::{assert_interfaces_are, assert_serves, parse, served_xml};
use ruya_platform::dbus::{Checks, LifecycleIface, ManageIface, Shared};
use ruya_platform::lifecycle::{self, Lifecycle};
use ruya_platform::procfs::{NoProcfs, SystemUsers};
use ruya_platform::registry::Registry;
use ruya_platform::store::Store;
use ruya_platform::Platform;

const FILE: &str = "org.ruyaos.Platform1.xml";

fn core(dir: &tempfile::TempDir) -> Shared {
    let mut registry = Registry::default();
    registry
        .register(
            lifecycle::INTERFACE,
            lifecycle::KEY,
            Box::<Lifecycle>::default(),
        )
        .expect("registers");
    let store = Store::open(&dir.path().join("platform")).expect("opens");
    Arc::new(Mutex::new(Platform::new(
        Box::new(NoProcfs),
        Box::new(SystemUsers),
        store,
        registry,
    )))
}

#[test]
fn platform1_matches_the_contract() {
    let dir = tempfile::tempdir().expect("temp dir");
    let core = core(&dir);
    assert_serves(FILE, &LifecycleIface::new(core.clone()), &[]);
    let checks = Checks {
        enforce: true,
        shell_uid: None,
    };
    assert_serves(FILE, &ManageIface::new(core, checks), &[]);
    assert_interfaces_are(
        FILE,
        &[
            "org.ruyaos.Platform1.Lifecycle",
            "org.ruyaos.Platform1.Manage",
        ],
    );
}

/// Identity is never an argument (ADR-022): no Lifecycle method takes one, so an app cannot name
/// another app, instance or profile.
#[test]
fn no_lifecycle_method_takes_an_argument() {
    let dir = tempfile::tempdir().expect("temp dir");
    let served = served_xml(&LifecycleIface::new(core(&dir)));
    let interfaces = parse(&served).expect("the served XML parses");
    let lifecycle = &interfaces["org.ruyaos.Platform1.Lifecycle"];
    let methods: Vec<_> = lifecycle
        .iter()
        .filter(|(key, _)| key.starts_with("method "))
        .collect();
    assert_eq!(methods.len(), 2, "{methods:?}");
    for (key, shape) in methods {
        assert!(!shape.contains("in:"), "{key} takes an argument: {shape}");
    }
}

/// Manage broadcasts nothing (RUY-1098 round 2): which app of which profile is saving or stopping
/// is the caller's answer, not a signal every listener could hear.
#[test]
fn manage_has_no_signal() {
    let contract = parse(&ruya_contract_test::read_contract(FILE)).expect("the contract parses");
    let manage = &contract["org.ruyaos.Platform1.Manage"];
    let signals: Vec<_> = manage.keys().filter(|k| k.starts_with("signal ")).collect();
    assert!(signals.is_empty(), "{signals:?}");
}
