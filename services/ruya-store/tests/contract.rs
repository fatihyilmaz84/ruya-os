//! RUY-403: the interface ruya-store serves is the one in api/dbus/org.ruyaos.Store1.xml.

use std::sync::Arc;

use ruya_contract_test::{assert_interfaces_are, assert_serves};
use ruya_store::dbus::{DynFlatpak, StoreIface};
use ruya_store::flatpak::FakeFlatpak;
use ruya_store::service::Store;

#[test]
fn store1_matches_the_contract() {
    let fake: FakeFlatpak = Default::default();
    let flatpak: DynFlatpak = Box::new(fake);
    let (events, _receiver) = async_channel::unbounded();
    let iface = StoreIface::new(Arc::new(Store::new(flatpak)), events, true);
    assert_serves("org.ruyaos.Store1.xml", &iface, &[]);
    assert_interfaces_are("org.ruyaos.Store1.xml", &["org.ruyaos.Store1"]);
}
