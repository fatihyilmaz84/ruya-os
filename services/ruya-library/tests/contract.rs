//! RUY-403: the interface ruya-library serves is the one in api/dbus/org.ruyaos.Library1.xml.

use ruya_contract_test::{assert_interfaces_are, assert_serves};
use ruya_library::dbus::{LibraryIface, Sources};
use ruya_library::flatpak::FixtureLister;

#[test]
fn library1_matches_the_contract() {
    let iface = LibraryIface::new(Sources {
        steam_roots: Vec::new(),
        lister: Box::new(FixtureLister::new("")),
    });
    assert_serves("org.ruyaos.Library1.xml", &iface, &[]);
    assert_interfaces_are("org.ruyaos.Library1.xml", &["org.ruyaos.Library1"]);
}
