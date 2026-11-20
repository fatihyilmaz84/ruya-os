//! RUY-403: the interface ruya-library serves is the one in api/dbus/org.ruyaos.Library1.xml.

use std::collections::BTreeMap;

use ruya_contract_test::{
    assert_interfaces_are, assert_record_served, assert_serves, record_signatures,
};
use ruya_library::catalog::scan;
use ruya_library::dbus::{record, LibraryIface, Sources};
use ruya_library::flatpak::FixtureLister;

mod common;
use common::{full_deployment, FULL_ROW};

#[test]
fn library1_matches_the_contract() {
    let iface = LibraryIface::new(Sources {
        steam_roots: Vec::new(),
        lister: Box::new(FixtureLister::new("")),
        play_root: std::path::PathBuf::from("/nonexistent"),
    });
    assert_serves("org.ruyaos.Library1.xml", &iface, &[]);
    assert_interfaces_are("org.ruyaos.Library1.xml", &["org.ruyaos.Library1"]);
}

/// RUY-885: the keys of the `a{sv}` item record, with their signatures, are the ones the contract
/// documents: a plain Flatpak app, a Steam game and a fully populated `.play` app go through the
/// same `record()` the service serves. The samples between them serve every documented key.
#[test]
fn library1_item_records_have_the_documented_keys() {
    let dir = tempfile::tempdir().unwrap();
    full_deployment(dir.path());
    let steam = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/steam");
    let rows = format!("org.example.App\tApp\tflathub\n{FULL_ROW}");
    let items = scan(&[steam], &FixtureLister::new(&rows), dir.path());
    let sample = |id: &str| {
        let item = items.iter().find(|i| i.id == id).unwrap_or_else(|| {
            panic!(
                "no item {id} in {:?}",
                items.iter().map(|i| &i.id).collect::<Vec<_>>()
            )
        });
        (item.id.clone(), record_signatures(&record(item)))
    };
    let samples: Vec<(String, BTreeMap<String, String>)> = [
        "flatpak:org.example.App",
        "steam:220",
        "flatpak:play.com.example.starhopper",
    ]
    .iter()
    .map(|id| sample(id))
    .collect();
    let labelled: Vec<(&str, BTreeMap<String, String>)> = samples
        .iter()
        .map(|(l, k)| (l.as_str(), k.clone()))
        .collect();
    assert_record_served("org.ruyaos.Library1.xml", "Item", &labelled);
}
