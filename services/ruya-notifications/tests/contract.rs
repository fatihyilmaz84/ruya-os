//! RUY-403: the interface ruya-notifications serves is the one in
//! api/dbus/org.ruyaos.Notifications1.xml.

use ruya_contract_test::{assert_interfaces_are, assert_serves};
use ruya_notifications::dbus::{DynStore, NotificationsIface};
use ruya_notifications::service::{Notifications, Profiles};
use ruya_notifications::store::MemoryStore;

#[test]
fn notifications1_matches_the_contract() {
    let store: DynStore = Box::<MemoryStore>::default();
    let iface = NotificationsIface::new(Notifications::new(store, Vec::new(), Profiles::Any), true);
    assert_serves("org.ruyaos.Notifications1.xml", &iface, &[]);
    assert_interfaces_are(
        "org.ruyaos.Notifications1.xml",
        &["org.ruyaos.Notifications1"],
    );
}
