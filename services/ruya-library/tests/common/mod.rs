//! Fixture `.play` deployments shared by the test files of ruya-library (RUY-852, RUY-885).
#![allow(dead_code)] // each test crate uses some of these

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use ruya_library::catalog::{scan, Item};
use ruya_library::flatpak::FixtureLister;

pub const PLAY_JSON: &str = r#"{
  "format": 1, "id": "com.example.starhopper", "build": 3,
  "name": { "tr": "Yildiz Atlayici", "en": "Star Hopper" },
  "genres": ["platformer", "adventure"],
  "players": { "min": 1, "max": 2, "modes": ["single", "local"] },
  "controller": "full",
  "age_rating": { "scheme": "oars-1.1", "content": { "violence-cartoon": "mild", "social-chat": "none" } },
  "art": { "icon": "a.png", "logo": { "en": "l.png", "de": "d.png" } }
}"#;

pub const TRUST_JSON: &str = r#"{ "format": 1, "tier": "developer", "signer_id": "0123456789abcdef0123456789abcdef",
  "signer_name": "Example Games", "store_signed": false }"#;

/// The `files` folder of the deployment of `play.<id>` under `root`, with its art folder.
pub fn files(root: &Path, id: &str) -> PathBuf {
    let f = root
        .join("app")
        .join(format!("play.{id}"))
        .join("current/active/files");
    std::fs::create_dir_all(f.join("share/ruyaos/play/art")).unwrap();
    f
}

pub fn put(path: &Path, bytes: &[u8]) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, bytes).unwrap();
}

/// What `scan` finds in `root` for the `flatpak list` rows, by item id.
pub fn list(root: &Path, rows: &str) -> HashMap<String, Item> {
    scan(&[], &FixtureLister::new(rows), root, &root.join("runners"))
        .into_iter()
        .map(|i| (i.id.clone(), i))
        .collect()
}

/// The flatpak row of the app `full_deployment` writes.
pub const FULL_ROW: &str = "play.com.example.starhopper\tstarhopper\truyaos-play-local\n";

/// A `.play` app with every field and every art role: play.json, trust.json and the art files.
pub fn full_deployment(root: &Path) {
    let f = files(root, "com.example.starhopper");
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
}
