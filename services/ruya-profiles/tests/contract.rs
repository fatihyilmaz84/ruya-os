//! RUY-403: the interface ruya-profiles serves is the one in api/dbus/org.ruyaos.Profiles1.xml.

use ruya_contract_test::{assert_interfaces_are, assert_serves};
use ruya_profiles::accounts::NoAccounts;
use ruya_profiles::dbus::{DynAccounts, ProfilesIface};
use ruya_profiles::store::Store;
use ruya_profiles::ProfileService;

#[test]
fn profiles1_matches_the_contract() {
    let dir = tempfile::tempdir().expect("temp dir");
    let store = Store::open(dir.path().join("profiles.toml")).expect("an empty store opens");
    let accounts: DynAccounts = Box::new(NoAccounts);
    let iface = ProfilesIface::new(ProfileService::new(store, accounts));
    assert_serves("org.ruyaos.Profiles1.xml", &iface, &[]);
    assert_interfaces_are("org.ruyaos.Profiles1.xml", &["org.ruyaos.Profiles1"]);
}
