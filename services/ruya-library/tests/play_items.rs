//! RUY-852: what a `.play` app adds to its Library1 item, read from a fixture deployment folder.

use std::path::Path;

use ruya_library::catalog::Item;
use ruya_library::dbus::record;

mod common;
use common::{files, full_deployment, list, put, FULL_ROW, PLAY_JSON};

fn art_of(item: &Item, role: &str) -> Option<String> {
    item.art
        .iter()
        .find(|(r, _)| r == role)
        .map(|(_, p)| p.clone())
}

#[test]
fn a_full_art_play_app_lists_every_role_and_field() {
    let dir = tempfile::tempdir().unwrap();
    full_deployment(dir.path());
    let items = list(dir.path(), FULL_ROW);
    let item = &items["flatpak:play.com.example.starhopper"];
    assert_eq!(item.title, "Star Hopper");
    for role in [
        "icon", "hero", "card", "cover", "logo", "trailer", "preview",
    ] {
        assert!(art_of(item, role).is_some(), "{role}: {:?}", item.art);
    }
    // The English logo is the second folder: the sorted keys are de, en.
    assert!(art_of(item, "logo")
        .unwrap()
        .replace('\\', "/")
        .contains("logo-1/"));
    assert!(art_of(item, "poster").is_none() && item.art.len() == 7);
    assert!(Path::new(&art_of(item, "card").unwrap()).is_file());
    let play = item.play.as_ref().expect("a play item");
    assert_eq!(play.genres, ["platformer", "adventure"]);
    assert_eq!(play.players, Some((1, 2)));
    assert_eq!(play.controller.as_deref(), Some("full"));
    assert_eq!(
        play.age_rating,
        [
            ("social-chat".to_string(), "none".to_string()),
            ("violence-cartoon".to_string(), "mild".to_string())
        ]
    );
    assert_eq!(play.tier.as_deref(), Some("developer"));
    assert_eq!(play.signer.as_deref(), Some("Example Games"));
    assert_eq!(
        play.signer_key_id.as_deref(),
        Some("0123456789abcdef0123456789abcdef")
    );
    // The 1080p screenshots in index order, not the thumbnails.
    let shots: Vec<String> = play
        .screenshots
        .iter()
        .map(|p| p.replace('\\', "/").rsplit('/').next().unwrap().to_owned())
        .collect();
    assert_eq!(
        shots,
        [
            "screenshot-0-1080.webp",
            "screenshot-1-1080.webp",
            "screenshot-2-1080.webp"
        ]
    );
}

/// RUY-908: trust.json's tier, signer name and signer id reach the served record's `play_tier`,
/// `play_signer` and `play_signer_key_id` (the contract test sees the signatures, not the values).
#[test]
fn the_served_record_carries_trust_jsons_tier_and_signer() {
    let dir = tempfile::tempdir().unwrap();
    full_deployment(dir.path());
    let items = list(dir.path(), FULL_ROW);
    let served = record(&items["flatpak:play.com.example.starhopper"]);
    let text = |key: &str| String::try_from(served[key].try_clone().unwrap()).unwrap();
    assert_eq!(text("play_tier"), "developer");
    assert_eq!(text("play_signer"), "Example Games");
    assert_eq!(
        text("play_signer_key_id"),
        "0123456789abcdef0123456789abcdef"
    );
}

#[test]
fn an_unsigned_app_without_screenshots_has_neither() {
    let dir = tempfile::tempdir().unwrap();
    let f = files(dir.path(), "com.example.bare");
    put(&f.join("play.json"), br#"{ "name": { "en": "B" } }"#);
    put(
        &f.join("share/ruyaos/play/trust.json"),
        br#"{ "format": 1, "tier": "unverified", "signer_id": null }"#,
    );
    put(&f.join("share/ruyaos/play/art/icon-512.webp"), b"x");
    let items = list(dir.path(), "play.com.example.bare\tx\truyaos-play-local\n");
    let play = items["flatpak:play.com.example.bare"].play.clone().unwrap();
    assert!(play.signer_key_id.is_none() && play.screenshots.is_empty());
}

#[test]
fn screenshots_are_capped_at_the_formats_maximum() {
    let dir = tempfile::tempdir().unwrap();
    let f = files(dir.path(), "com.example.many");
    put(&f.join("play.json"), br#"{ "name": { "en": "M" } }"#);
    for n in 0..25 {
        put(
            &f.join(format!("share/ruyaos/play/art/screenshot-{n}-1080.webp")),
            b"x",
        );
    }
    let items = list(dir.path(), "play.com.example.many\tx\truyaos-play-local\n");
    let play = items["flatpak:play.com.example.many"].play.clone().unwrap();
    assert_eq!(play.screenshots.len(), 20);
}

#[test]
fn an_icon_only_package_has_just_the_icon() {
    let dir = tempfile::tempdir().unwrap();
    let f = files(dir.path(), "com.example.small");
    put(
        &f.join("play.json"),
        br#"{ "name": { "en": "Small" }, "genres": [] }"#,
    );
    put(&f.join("share/ruyaos/play/art/icon-512.webp"), b"x");
    let items = list(dir.path(), "play.com.example.small\tx\truyaos-play-local\n");
    let item = &items["flatpak:play.com.example.small"];
    assert_eq!(item.art.len(), 1);
    assert!(art_of(item, "icon").is_some());
    let play = item.play.as_ref().unwrap();
    assert!(play.genres.is_empty() && play.players.is_none() && play.controller.is_none());
    assert!(play.age_rating.is_empty());
}

#[test]
fn a_missing_or_garbled_play_json_is_a_plain_item() {
    let dir = tempfile::tempdir().unwrap();
    let missing = files(dir.path(), "com.example.missing");
    put(&missing.join("share/ruyaos/play/art/icon-512.webp"), b"x");
    let garbled = files(dir.path(), "com.example.garbled");
    put(&garbled.join("play.json"), b"{ not json");
    put(&garbled.join("share/ruyaos/play/art/icon-512.webp"), b"x");
    let array = files(dir.path(), "com.example.array");
    put(&array.join("play.json"), b"[1, 2]");
    let items = list(
        dir.path(),
        "play.com.example.missing\tMissing\truyaos-play-local\nplay.com.example.garbled\tGarbled\truyaos-play-local\nplay.com.example.array\tArray\truyaos-play-local\nplay.com.example.nodeploy\tNone\truyaos-play-local\n",
    );
    assert_eq!(items.len(), 4);
    for (id, title) in [
        ("missing", "Missing"),
        ("garbled", "Garbled"),
        ("array", "Array"),
        ("nodeploy", "None"),
    ] {
        let item = &items[&format!("flatpak:play.com.example.{id}")];
        assert_eq!(item.title, title);
        assert!(item.play.is_none() && item.art.is_empty(), "{id}: {item:?}");
    }
}

#[test]
fn a_missing_or_garbled_trust_json_gives_no_tier() {
    let dir = tempfile::tempdir().unwrap();
    for (id, trust) in [
        ("none", None),
        ("garbled", Some(&b"{ nope"[..])),
        (
            "future",
            Some(&br#"{ "format": 2, "tier": "official" }"#[..]),
        ),
        ("odd", Some(&br#"{ "format": 1, "tier": "godlike" }"#[..])),
    ] {
        let f = files(dir.path(), &format!("com.example.{id}"));
        put(&f.join("play.json"), br#"{ "name": { "en": "N" } }"#);
        if let Some(t) = trust {
            put(&f.join("share/ruyaos/play/trust.json"), t);
        }
    }
    let rows: String = ["none", "garbled", "future", "odd"]
        .iter()
        .map(|i| format!("play.com.example.{i}\tx\truyaos-play-local\n"))
        .collect();
    for (id, item) in list(dir.path(), &rows) {
        let play = item.play.as_ref().unwrap_or_else(|| panic!("{id}"));
        assert!(
            play.tier.is_none() && play.signer.is_none(),
            "{id}: {play:?}"
        );
    }
}

#[test]
fn a_signer_without_a_name_shows_its_id_and_an_unsigned_app_none() {
    let dir = tempfile::tempdir().unwrap();
    let a = files(dir.path(), "com.example.a");
    put(&a.join("play.json"), br#"{ "name": { "en": "A" } }"#);
    put(
        &a.join("share/ruyaos/play/trust.json"),
        br#"{ "format": 1, "tier": "unverified", "signer_id": "k9", "signer_name": "" }"#,
    );
    let b = files(dir.path(), "com.example.b");
    put(&b.join("play.json"), br#"{ "name": { "en": "B" } }"#);
    put(
        &b.join("share/ruyaos/play/trust.json"),
        br#"{ "format": 1, "tier": "unverified" }"#,
    );
    let items = list(
        dir.path(),
        "play.com.example.a\tx\truyaos-play-local\nplay.com.example.b\tx\truyaos-play-local\n",
    );
    let play = |id: &str| items[&format!("flatpak:play.{id}")].play.clone().unwrap();
    assert_eq!(play("com.example.a").signer.as_deref(), Some("k9"));
    assert_eq!(play("com.example.b").tier.as_deref(), Some("unverified"));
    assert_eq!(play("com.example.b").signer, None);
}

#[test]
fn a_flatpak_app_that_is_not_play_is_unaffected() {
    let dir = tempfile::tempdir().unwrap();
    // A deployment with the same files under a non-play id must not be read.
    let f = dir.path().join("app/org.example.Tux/current/active/files");
    put(&f.join("play.json"), PLAY_JSON.as_bytes());
    put(&f.join("share/ruyaos/play/art/icon-512.webp"), b"x");
    let items = list(dir.path(), "org.example.Tux\tTux\tflathub\n");
    let item = &items["flatpak:org.example.Tux"];
    assert_eq!(item.title, "Tux");
    assert!(item.play.is_none() && item.art.is_empty());
}

#[test]
fn a_play_app_from_another_remote_stays_plain() {
    let dir = tempfile::tempdir().unwrap();
    let f = files(dir.path(), "com.example.spoof");
    put(&f.join("play.json"), PLAY_JSON.as_bytes());
    put(
        &f.join("share/ruyaos/play/trust.json"),
        br#"{ "format": 1, "tier": "official", "signer_name": "RuyaOS" }"#,
    );
    put(&f.join("share/ruyaos/play/art/icon-512.webp"), b"x");
    let items = list(dir.path(), "play.com.example.spoof\tSpoof\tflathub\n");
    let item = &items["flatpak:play.com.example.spoof"];
    assert_eq!(item.title, "Spoof");
    assert!(item.play.is_none() && item.art.is_empty(), "{item:?}");
}

#[test]
fn genres_title_and_signer_are_capped() {
    let dir = tempfile::tempdir().unwrap();
    let f = files(dir.path(), "com.example.long");
    let long = "n".repeat(500);
    put(
        &f.join("play.json"),
        format!(r#"{{ "name": {{ "en": "{long}" }}, "genres": ["a","b","c","d","e","f"] }}"#)
            .as_bytes(),
    );
    put(
        &f.join("share/ruyaos/play/trust.json"),
        format!(r#"{{ "format": 1, "tier": "developer", "signer_name": "{long}" }}"#).as_bytes(),
    );
    let items = list(dir.path(), "play.com.example.long\tx\truyaos-play-local\n");
    let item = &items["flatpak:play.com.example.long"];
    let play = item.play.as_ref().unwrap();
    assert_eq!(item.title.chars().count(), 120);
    assert_eq!(play.signer.as_ref().unwrap().chars().count(), 120);
    assert_eq!(play.genres, ["a", "b", "c", "d"]);
}

#[test]
fn null_signer_fields_are_absent() {
    let dir = tempfile::tempdir().unwrap();
    for (id, trust) in [
        (
            "both",
            r#"{ "format": 1, "tier": "unverified", "signer_id": null, "signer_name": null }"#,
        ),
        (
            "name",
            r#"{ "format": 1, "tier": "developer", "signer_id": "k1", "signer_name": null }"#,
        ),
    ] {
        let f = files(dir.path(), &format!("com.example.{id}"));
        put(&f.join("play.json"), br#"{ "name": { "en": "N" } }"#);
        put(&f.join("share/ruyaos/play/trust.json"), trust.as_bytes());
    }
    let items = list(
        dir.path(),
        "play.com.example.both\tx\truyaos-play-local\nplay.com.example.name\tx\truyaos-play-local\n",
    );
    let play = |id: &str| {
        items[&format!("flatpak:play.com.example.{id}")]
            .play
            .clone()
            .unwrap()
    };
    assert_eq!(play("both").tier.as_deref(), Some("unverified"));
    assert_eq!(play("both").signer, None);
    assert_eq!(play("name").signer.as_deref(), Some("k1"));
}

/// RUY-903 (Linux only: the launcher's real file system): a package the launcher can read, laid
/// out as `ruya-play` commits it, and the image's runners folder.
#[cfg(target_os = "linux")]
mod runner_keys {
    use super::*;

    const ROW: &str = "play.com.example.hop\thop\truyaos-play-local\n";

    /// The wine game of ruya-play-launch's tests, with the component's `source`.
    fn deployment(root: &Path, source: &str) {
        let f = files(root, "com.example.hop");
        let manifest = serde_json::json!({
            "format": 1, "id": "com.example.hop", "name": {"en": "Hop"},
            "version": "1.0", "build": 1, "art": {"icon": "art/icon.png"},
            "components": [{
                "id": "wine", "type": "wine", "source": source, "min": "9.0", "tested": "9.20",
                "bundled": {"path": "components/wine", "version": "9.20",
                            "licence": "LGPL-2.1-or-later"}
            }],
            "run": {"runner": "wine", "component": "wine", "command": ["${payload}/Hop.exe"]}
        });
        put(&f.join("play.json"), manifest.to_string().as_bytes());
        let mut table = String::new();
        for (path, data) in [
            ("art/icon.png", "icon"),
            ("components/wine/bin/wine", "elf"),
            ("components/wine/bin/wineserver", "elf"),
            ("licences/LGPL-2.1.txt", "text"),
            ("payload/Hop.exe", "MZ"),
        ] {
            put(&f.join(path), data.as_bytes());
            table.push_str(&format!(
                "{{\"h\":\"{}\",\"p\":\"{path}\",\"s\":{},\"t\":\"f\"}}\n",
                "0".repeat(64),
                data.len()
            ));
        }
        put(&f.join("play.files"), table.as_bytes());
    }

    fn image_runner(root: &Path, version: &str) {
        let dir = root.join("runners").join(format!("wine-{version}"));
        put(
            &dir.join("runner.json"),
            format!(
                r#"{{"format":1,"family":"wine","kind":"wine","version":"{version}","arch":"x86_64","entry":{{"wine":"bin/wine","wineserver":"bin/wineserver"}}}}"#
            )
            .as_bytes(),
        );
        put(&dir.join("bin/wine"), b"elf");
        put(&dir.join("bin/wineserver"), b"elf");
    }

    #[test]
    fn the_image_runner_is_what_the_item_says_will_run() {
        let dir = tempfile::tempdir().unwrap();
        deployment(dir.path(), "system");
        image_runner(dir.path(), "10.2");
        let item = &list(dir.path(), ROW)["flatpak:play.com.example.hop"];
        let play = item.play.as_ref().unwrap();
        assert_eq!(play.runner.as_deref(), Some("wine 10.2"));
        assert_eq!(play.runner_source.as_deref(), Some("system"));
        assert_eq!(play.runner_tested.as_deref(), Some("9.20"));
        assert_eq!(play.resolve_error, None);
        let rec = record(item);
        assert!(rec.contains_key("play_runner") && !rec.contains_key("play_resolve_error"));
    }

    #[test]
    fn without_the_image_runner_the_item_says_why() {
        let dir = tempfile::tempdir().unwrap();
        deployment(dir.path(), "system");
        let item = &list(dir.path(), ROW)["flatpak:play.com.example.hop"];
        let play = item.play.as_ref().unwrap();
        assert_eq!(play.runner, None);
        assert!(play
            .resolve_error
            .as_deref()
            .is_some_and(|s| s.contains("no runner of family wine")));
    }

    #[test]
    fn a_runner_older_than_the_package_needs_gives_the_sentence() {
        let dir = tempfile::tempdir().unwrap();
        deployment(dir.path(), "system");
        image_runner(dir.path(), "8.0");
        let item = &list(dir.path(), ROW)["flatpak:play.com.example.hop"];
        assert_eq!(
            item.play.as_ref().unwrap().resolve_error.as_deref(),
            Some("The OS runner is 8.0, older than the required 9.0.")
        );
    }

    #[test]
    fn a_package_the_launcher_cannot_read_is_a_sentence_not_a_broken_item() {
        let dir = tempfile::tempdir().unwrap();
        let f = files(dir.path(), "com.example.hop");
        put(&f.join("play.json"), br#"{ "name": { "en": "Hop" } }"#);
        let item = &list(dir.path(), ROW)["flatpak:play.com.example.hop"];
        assert_eq!(item.title, "Hop");
        let play = item.play.as_ref().unwrap();
        assert_eq!(play.runner, None);
        assert!(play.resolve_error.is_some());
    }
}
