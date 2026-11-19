//! org.ruyaos.Library1 on D-Bus. Thin adapter: the rules live in `catalog.rs`.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use zbus::interface;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedValue, Value};

use crate::catalog::{self, Item};
use crate::flatpak::AppLister;

pub const BUS_NAME: &str = "org.ruyaos.Library1";
pub const OBJECT_PATH: &str = "/org/ruyaos/Library1";

type Dict = HashMap<String, OwnedValue>;

/// What a scan needs; shared with the thread that runs it.
pub struct Sources {
    pub steam_roots: Vec<PathBuf>,
    pub lister: Box<dyn AppLister>,
    /// The Flatpak installation whose `play.*` deployments carry the art and `play.json`
    /// (`/var/lib/flatpak`; a fixture folder in tests).
    pub play_root: PathBuf,
}

pub struct LibraryIface {
    sources: Arc<Sources>,
    items: Mutex<Vec<Item>>,
}

impl LibraryIface {
    /// Scans once, so the first `ListItems` has an answer.
    pub fn new(sources: Sources) -> Self {
        let items = catalog::scan(
            &sources.steam_roots,
            sources.lister.as_ref(),
            &sources.play_root,
        );
        LibraryIface {
            sources: Arc::new(sources),
            items: Mutex::new(items),
        }
    }

    /// Replaces the list; true when it differs from the one before.
    fn store(&self, fresh: Vec<Item>) -> bool {
        match self.items.lock() {
            Ok(mut items) => {
                let changed = *items != fresh;
                *items = fresh;
                changed
            }
            Err(_) => false,
        }
    }

    /// Scans on the calling thread (the watcher thread in `main.rs`, never the executor).
    /// True when the list changed; the caller then sends `ItemsChanged` with `announce`.
    pub fn refresh(&self) -> bool {
        self.store(catalog::scan(
            &self.sources.steam_roots,
            self.sources.lister.as_ref(),
            &self.sources.play_root,
        ))
    }

    /// Sends `ItemsChanged`.
    pub async fn announce(emitter: &SignalEmitter<'_>) {
        if let Err(err) = Self::items_changed(emitter).await {
            eprintln!("ruya-library: emitting ItemsChanged failed: {err}");
        }
    }
}

fn record(item: &Item) -> Dict {
    let art: HashMap<String, String> = item.art.iter().cloned().collect();
    let entries = vec![
        ("id", Value::from(item.id.clone())),
        ("kind", Value::from(item.kind.as_str())),
        ("title", Value::from(item.title.clone())),
        ("source", Value::from(item.source.as_str())),
        ("launch", Value::from(item.launch.clone())),
        ("art", Value::from(art)),
        ("last_played", Value::from(item.last_played)),
    ];
    let mut entries = entries;
    // A `.play` app adds its own keys; others have none of them (Library1 XML).
    if let Some(play) = &item.play {
        entries.push(("play", Value::from(true)));
        entries.push(("genres", Value::from(play.genres.clone())));
        if let Some((min, max)) = play.players {
            entries.push(("players", Value::from((min, max))));
        }
        if let Some(controller) = &play.controller {
            entries.push(("controller", Value::from(controller.clone())));
        }
        if !play.age_rating.is_empty() {
            let rating: HashMap<String, String> = play.age_rating.iter().cloned().collect();
            entries.push(("age_rating", Value::from(rating)));
        }
        if let Some(tier) = &play.tier {
            entries.push(("play_tier", Value::from(tier.clone())));
        }
        if let Some(signer) = &play.signer {
            entries.push(("play_signer", Value::from(signer.clone())));
        }
        if let Some(key_id) = &play.signer_key_id {
            entries.push(("play_signer_key_id", Value::from(key_id.clone())));
        }
        if !play.screenshots.is_empty() {
            entries.push(("play_screenshots", Value::from(play.screenshots.clone())));
        }
    }
    entries
        .into_iter()
        .filter_map(|(k, v)| OwnedValue::try_from(v).ok().map(|v| (k.to_owned(), v)))
        .collect()
}

#[interface(name = "org.ruyaos.Library1")]
impl LibraryIface {
    fn list_items(&self) -> Vec<Dict> {
        match self.items.lock() {
            Ok(items) => items.iter().map(record).collect(),
            Err(_) => Vec::new(),
        }
    }

    async fn rescan(&self, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) {
        let sources = self.sources.clone();
        // File and process I/O: not on the executor.
        let fresh = blocking::unblock(move || {
            catalog::scan(
                &sources.steam_roots,
                sources.lister.as_ref(),
                &sources.play_root,
            )
        })
        .await;
        if self.store(fresh) {
            Self::announce(&emitter).await;
        }
    }

    #[zbus(signal)]
    async fn items_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::{Kind, Source};
    use crate::play::PlayInfo;

    fn item(play: Option<PlayInfo>) -> Item {
        Item {
            id: "flatpak:play.a".into(),
            kind: Kind::Game,
            title: "A".into(),
            source: Source::Flatpak,
            launch: "flatpak:play.a".into(),
            art: Vec::new(),
            last_played: 0,
            play,
        }
    }

    #[test]
    fn a_play_record_has_the_contracts_keys_and_others_none_of_them() {
        let plain = record(&item(None));
        assert!(["play", "genres", "players", "play_tier"]
            .iter()
            .all(|k| !plain.contains_key(*k)));
        let rec = record(&item(Some(PlayInfo {
            genres: vec!["platformer".into()],
            players: Some((1, 4)),
            controller: Some("full".into()),
            age_rating: vec![("violence-cartoon".into(), "mild".into())],
            tier: Some("official".into()),
            signer: Some("Example".into()),
            signer_key_id: Some("0123456789abcdef0123456789abcdef".into()),
            screenshots: vec!["/a/screenshot-0-1080.webp".into()],
        })));
        assert!(bool::try_from(rec["play"].try_clone().unwrap()).unwrap());
        assert_eq!(rec["players"].value_signature().to_string(), "(uu)");
        assert_eq!(rec["age_rating"].value_signature().to_string(), "a{ss}");
        assert_eq!(rec["genres"].value_signature().to_string(), "as");
        let tier: String = rec["play_tier"].try_clone().unwrap().try_into().unwrap();
        assert_eq!(tier, "official");
        assert!(rec.contains_key("controller") && rec.contains_key("play_signer"));
        assert_eq!(rec["play_signer_key_id"].value_signature().to_string(), "s");
        assert_eq!(rec["play_screenshots"].value_signature().to_string(), "as");
        let bare = record(&item(Some(PlayInfo::default())));
        assert!(!bare.contains_key("play_signer_key_id") && !bare.contains_key("play_screenshots"));
    }
}
