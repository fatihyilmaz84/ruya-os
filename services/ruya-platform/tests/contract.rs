//! RUY-403: the interfaces ruya-platform serves are the ones in api/dbus/org.ruyaos.Platform1.xml,
//! and the developer mock's control interface the one in org.ruyaos.Platform1Mock.xml (RUY-158).

use std::sync::{Arc, Mutex};

use ruya_contract_test::{assert_interfaces_are, assert_serves, parse, served_xml};
use ruya_platform::dbus::{Checks, LifecycleIface, ManageIface, Shared};
use ruya_platform::procfs::{NoProcfs, SystemUsers};
use ruya_platform::registry::Registry;
use ruya_platform::store::Store;
use ruya_platform::Platform;

const FILE: &str = "org.ruyaos.Platform1.xml";
#[cfg(feature = "dev-mock")]
const MOCK_FILE: &str = "org.ruyaos.Platform1Mock.xml";

fn core(dir: &tempfile::TempDir) -> Shared {
    let registry = Registry::served().expect("registers");
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

/// What the developer mock serves (RUY-158): the service's own Lifecycle and Manage, so the
/// mock cannot offer an element Platform1.xml lacks or miss one it has, and its control
/// interface, which is in a file of its own and never in Platform1.xml.
#[cfg(feature = "dev-mock")]
#[test]
fn the_mock_serves_the_contract_and_its_control_interface() {
    use ruya_platform::mock::{self, Objects, Processes, Scenario};
    struct NoProcesses;
    impl Processes for NoProcesses {
        fn pidfd_pid(&self, _pidfd: i32) -> Option<i32> {
            None
        }
        fn environ(&self, _pid: u32) -> std::io::Result<Vec<u8>> {
            Err(std::io::ErrorKind::Unsupported.into())
        }
        fn uid(&self, _pid: u32) -> std::io::Result<u32> {
            Err(std::io::ErrorKind::Unsupported.into())
        }
    }
    let dir = tempfile::tempdir().expect("temp dir");
    let scenario = Arc::new(
        Scenario::parse(r#"{"profile": "p1", "profiles": ["p1"], "apps": {}}"#).expect("valid"),
    );
    let store = Store::open(&dir.path().join("platform")).expect("opens");
    let core = mock::core(scenario.clone(), Box::new(NoProcesses), store).expect("registers");
    let objects = Objects::new(core, scenario);
    assert_serves(FILE, &objects.lifecycle, &[]);
    assert_serves(FILE, &objects.manage, &[]);
    assert_serves(MOCK_FILE, &objects.control, &[]);
    assert_interfaces_are(MOCK_FILE, &["org.ruyaos.Platform1Mock"]);
}
