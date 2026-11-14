//! RUY-403: the interface ruya-update serves is the one in api/dbus/org.ruyaos.Update1.xml.

use std::sync::Arc;

use ruya_contract_test::{assert_interfaces_are, assert_serves};
use ruya_update::bootc::{FakeBootc, HostStatus};
use ruya_update::dbus::{DynBootc, UpdateIface};
use ruya_update::service::Update;

#[test]
fn update1_matches_the_contract() {
    let bootc: DynBootc = Box::new(FakeBootc::new(HostStatus::default()));
    let (changes, _receiver) = async_channel::unbounded();
    let iface = UpdateIface::new(Arc::new(Update::new(bootc, None)), changes, true);
    assert_serves("org.ruyaos.Update1.xml", &iface, &[]);
    assert_interfaces_are("org.ruyaos.Update1.xml", &["org.ruyaos.Update1"]);
}
