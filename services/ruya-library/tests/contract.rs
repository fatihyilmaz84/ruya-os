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
        play_runners: std::path::PathBuf::from("/nonexistent"),
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
    let mut items = scan(
        &[steam],
        &FixtureLister::new(&rows),
        dir.path(),
        &dir.path().join("runners"),
    );
    // The runner keys come from the launcher's resolution, which only Linux runs on a real folder
    // (play.rs tests the mapping): one sample that resolves and one that is refused serve them on
    // every host.
    let play = items
        .iter()
        .find(|i| i.id == "flatpak:play.com.example.starhopper")
        .unwrap();
    let mut resolved = play.clone();
    resolved.id = "flatpak:play.resolved".into();
    let info = resolved.play.as_mut().unwrap();
    info.resolve_error = None;
    info.runner = Some("wine 10.2".into());
    info.runner_source = Some("system".into());
    info.runner_tested = Some("9.20".into());
    let mut refused = play.clone();
    refused.id = "flatpak:play.refused".into();
    refused.play.as_mut().unwrap().resolve_error = Some("No runner.".into());
    items.extend([resolved, refused]);
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
        "flatpak:play.resolved",
        "flatpak:play.refused",
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
