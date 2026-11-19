//! RUY-852: what a `.play` app adds to its Library1 item, read from a fixture deployment folder.

use std::collections::HashMap;
use std::path::Path;

use ruya_library::catalog::{scan, Item};
use ruya_library::flatpak::FixtureLister;

const PLAY_JSON: &str = r#"{
  "format": 1, "id": "com.example.starhopper", "build": 3,
  "name": { "tr": "Yildiz Atlayici", "en": "Star Hopper" },
  "genres": ["platformer", "adventure"],
  "players": { "min": 1, "max": 2, "modes": ["single", "local"] },
  "controller": "full",
  "age_rating": { "scheme": "oars-1.1", "content": { "violence-cartoon": "mild", "social-chat": "none" } },
  "art": { "icon": "a.png", "logo": { "en": "l.png", "de": "d.png" } }
}"#;

const TRUST_JSON: &str = r#"{ "format": 1, "tier": "developer", "signer_id": "0123456789abcdef0123456789abcdef",
  "signer_name": "Example Games", "store_signed": false }"#;

fn files(root: &Path, id: &str) -> std::path::PathBuf {
    let f = root
        .join("app")
        .join(format!("play.{id}"))
        .join("current/active/files");
    std::fs::create_dir_all(f.join("share/ruyaos/play/art")).unwrap();
    f
}

fn put(path: &Path, bytes: &[u8]) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, bytes).unwrap();
}

fn list(root: &Path, rows: &str) -> HashMap<String, Item> {
    scan(&[], &FixtureLister::new(rows), root)
        .into_iter()
        .map(|i| (i.id.clone(), i))
        .collect()
}

fn art_of(item: &Item, role: &str) -> Option<String> {
    item.art
        .iter()
        .find(|(r, _)| r == role)
        .map(|(_, p)| p.clone())
}

#[test]
fn a_full_art_play_app_lists_every_role_and_field() {
    let dir = tempfile::tempdir().unwrap();
    let f = files(dir.path(), "com.example.starhopper");
    put(&f.join("play.json"), PLAY_JSON.as_bytes());
    put(
        &f.join("share/ruyaos/play/trust.json"),
        TRUST_JSON.as_bytes(),
    );
    let art = f.join("share/ruyaos/play/art");
    for name in [
        "icon-512.webp",
        "icon-128.webp",
        "hero-2160.webp",
        "card-540.webp",
        "cover-900.webp",
        "trailer-poster-1080.webp",
        "screenshot-0-1080.webp",
        "screenshot-2-1080.webp",
        "screenshot-1-1080.webp",
        "screenshot-0-thumb.webp",
        "trailer.webm",
        "preview.webm",
        "logo-0/logo.webp",
        "logo-1/logo.webp",
    ] {
        put(&art.join(name), b"x");
    }
    let items = list(
        dir.path(),
        "play.com.example.starhopper\tstarhopper\truyaos-play-local\n",
    );
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
