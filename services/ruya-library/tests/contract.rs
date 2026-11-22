//! RUY-403: the interface ruya-library serves is the one in api/dbus/org.ruyaos.Library1.xml.

use std::collections::BTreeMap;

use ruya_contract_test::{
    assert_interfaces_are, assert_record_served, assert_serves, record_signatures,
};
use ruya_library::catalog::scan;
use ruya_library::dbus::{record, resolution_record, runner_record, LibraryIface, Sources};
use ruya_library::flatpak::FixtureLister;
use ruya_library::profile_items::{self, Game};
use ruya_library::runners::{Resolution, Runner};

mod common;
use common::{full_deployment, FULL_ROW};

#[test]
fn library1_matches_the_contract() {
    let iface = LibraryIface::new(Sources {
        lister: Box::new(FixtureLister::new("")),
        play_root: std::path::PathBuf::from("/nonexistent"),
        play_runners: std::path::PathBuf::from("/nonexistent"),
        choices_dir: std::path::PathBuf::from("/nonexistent"),
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
    let rows = format!("org.example.App\tApp\tflathub\n{FULL_ROW}");
    let mut items = scan(
        &FixtureLister::new(&rows),
        dir.path(),
        &dir.path().join("runners"),
    );
    // A Steam game as PutProfileItems takes it in (RUY-1056): the reader's document, decoded.
    let steam = profile_items::encode(&[Game {
        appid: "220".into(),
        name: "Turbo Racer".into(),
        last_played: 1_700_000_000,
    }]);
    items.extend(profile_items::decode(&steam).unwrap());
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
    info.resolution.resolve_error = None;
    info.resolution.runner = Some("wine 10.2".into());
    info.resolution.runner_source = Some("system".into());
    info.resolution.runner_tested = Some("9.20".into());
    // play_fallback is ResolveRunner's (a choice); the item record shares the key and the code.
    info.resolution.fallback = true;
    let mut refused = play.clone();
    refused.id = "flatpak:play.refused".into();
    let why = &mut refused.play.as_mut().unwrap().resolution;
    why.resolve_error = Some("No runner.".into());
    why.resolve_code = Some("resolve.no_system_runner".into());
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

/// RUY-959: the Runner record of ListRunners and the Resolution record of ResolveRunner, through
/// the functions the service serves them with.
#[test]
fn library1_runner_and_resolution_records_have_the_documented_keys() {
    let full = Runner {
        family: "proton-ge".into(),
        kind: "proton".into(),
        version: "GE-Proton11-12".into(),
        licence: Some("BSD-3-Clause".into()),
        source_url: Some("https://example.org/ge".into()),
    };
    let bare = Runner {
        licence: None,
        source_url: None,
        ..full.clone()
    };
    assert_record_served(
        "org.ruyaos.Library1.xml",
        "Runner",
        &[
            ("full", record_signatures(&runner_record(&full))),
            ("bare", record_signatures(&runner_record(&bare))),
        ],
    );
    let resolved = Resolution {
        runner: Some("wine 10.2".into()),
        runner_source: Some("system".into()),
        runner_tested: Some("9.20".into()),
        resolve_error: None,
        resolve_code: None,
        fallback: true,
    };
    let refused = Resolution {
        resolve_error: Some("No runner.".into()),
        resolve_code: Some("resolve.no_system_runner".into()),
        ..Resolution::default()
    };
    assert_record_served(
        "org.ruyaos.Library1.xml",
        "Resolution",
        &[
            ("resolved", record_signatures(&resolution_record(&resolved))),
            ("refused", record_signatures(&resolution_record(&refused))),
            (
                "native",
                record_signatures(&resolution_record(&Resolution::default())),
            ),
        ],
    );
}
