//! RUY-403: the interface ruya-inputd serves is the one in api/dbus/org.ruyaos.Input1.xml.
//!
//! `Input1` is a draft that ruya-inputd builds member by member (the header of the XML says
//! which). Every member it serves must match the contract; `NOT_BUILT` lists the contract members
//! it does not serve yet, and the test fails when one of them is served after all, so the list
//! cannot go stale. When a task builds one of them, it takes the name off the list.

use ruya_contract_test::{assert_interfaces_are, assert_serves};
use ruya_inputd::accounts::FixedAccounts;
use ruya_inputd::dbus::{DynBackend, InputIface, Shared};
use ruya_inputd::routing::{NullBackend, Router};

/// Contract members of `Input1` with no implementation yet (the XML header: UI ownership
/// T-397..T-399, platform and game assignments T-370 / RUY-43, OwnershipMode T-371).
const NOT_BUILT: &[&str] = &[
    "ForeignInput",
    "AssignPad",
    "GetOwnershipMode",
    "SetOwnershipMode",
];

#[test]
fn input1_matches_the_contract() {
    let backend: DynBackend = Box::new(NullBackend);
    let router = Router::new(backend, Box::new(FixedAccounts(vec![("p1".into(), 1001)])));
    let (shared, _notices) = Shared::new(router);
    let iface = InputIface::new(shared);
    assert_serves("org.ruyaos.Input1.xml", &iface, NOT_BUILT);
    assert_interfaces_are("org.ruyaos.Input1.xml", &["org.ruyaos.Input1"]);
}
