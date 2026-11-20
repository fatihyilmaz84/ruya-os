//! RUY-403: the interface ruya-store serves is the one in api/dbus/org.ruyaos.Store1.xml.

use std::sync::Arc;

use ruya_contract_test::{
    assert_interfaces_are, assert_record_served, assert_serves, record_signatures,
};
use ruya_store::app::App;
use ruya_store::appstream::Screenshot;
use ruya_store::dbus::{record, DynFlatpak, StoreIface};
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

/// RUY-907: the keys of the app record, with their signatures, are the ones the contract
/// documents. A bare app in a list and a fully known one from `GetApp` go through the same
/// `record()` the service serves; the second serves every optional key.
#[test]
fn store1_app_records_have_the_documented_keys() {
    let bare = App {
        id: "org.example.Bare".into(),
        name: "Bare".into(),
        ..Default::default()
    };
    let full = App {
        id: "org.example.Racer".into(),
        name: "Racer".into(),
        summary: "Fast".into(),
        description: "A racing game.".into(),
        developer: "Example".into(),
        source: "official".into(),
        controller: "full".into(),
        age_rating: "7+".into(),
        compatible: true,
        permissions: vec!["network".into()],
        new_permissions: vec!["home-files".into()],
        installed_size: 1 << 20,
        download_size: 1 << 19,
        version: "2.0".into(),
        release_date: 1_794_873_600,
        release_notes: "Faster.".into(),
        installed_version: "1.0".into(),
        license: "GPL-3.0-or-later".into(),
        categories: vec!["Game".into()],
        screenshots: vec![Screenshot {
            image: "https://example.org/a.png".into(),
            thumb: "https://example.org/a-thumb.png".into(),
            caption: "Race".into(),
        }],
        icon: "https://example.org/icon.png".into(),
        tile: "https://example.org/tile.png".into(),
        hero: "https://example.org/hero.png".into(),
        installed: true,
        update_available: true,
        ..Default::default()
    };
    assert_record_served(
        "org.ruyaos.Store1.xml",
        "App",
        &[
            ("a bare app", record_signatures(&record(&bare, false))),
            ("a known app", record_signatures(&record(&full, true))),
        ],
    );
}
