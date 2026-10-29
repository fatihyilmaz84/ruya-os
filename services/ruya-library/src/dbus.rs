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
}

pub struct LibraryIface {
    sources: Arc<Sources>,
    items: Mutex<Vec<Item>>,
}

impl LibraryIface {
    /// Scans once, so the first `ListItems` has an answer.
    pub fn new(sources: Sources) -> Self {
        let items = catalog::scan(&sources.steam_roots, sources.lister.as_ref());
        LibraryIface {
            sources: Arc::new(sources),
            items: Mutex::new(items),
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
        let fresh =
            blocking::unblock(move || catalog::scan(&sources.steam_roots, sources.lister.as_ref()))
                .await;
        let changed = match self.items.lock() {
            Ok(mut items) => {
                let changed = *items != fresh;
                *items = fresh;
                changed
            }
            Err(_) => false,
        };
        if changed {
            if let Err(err) = Self::items_changed(&emitter).await {
                eprintln!("ruya-library: emitting ItemsChanged failed: {err}");
            }
        }
    }

    #[zbus(signal)]
    async fn items_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}
