//! org.ruyaos.Library1 on D-Bus. Thin adapter: the rules live in `catalog.rs`, `runners.rs` and
//! `choices.rs`.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use zbus::interface;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedValue, Value};

use ruya_play_format::resolve::Override;

use crate::catalog::{self, Item};
use crate::choices::{self, Choices, Status};
use crate::flatpak::AppLister;
use crate::play;
use crate::runners::{self, Resolution, Runner};

pub const BUS_NAME: &str = "org.ruyaos.Library1";
pub const OBJECT_PATH: &str = "/org/ruyaos/Library1";

pub type Dict = HashMap<String, OwnedValue>;

/// What a scan needs; shared with the thread that runs it.
pub struct Sources {
    pub steam_roots: Vec<PathBuf>,
    pub lister: Box<dyn AppLister>,
    /// The Flatpak installation whose `play.*` deployments carry the art and `play.json`
    /// (`/var/lib/flatpak`; a fixture folder in tests).
    pub play_root: PathBuf,
    /// The image's `.play` runners (`play::RUNNERS_DIR`; a fixture folder in tests).
    pub play_runners: PathBuf,
    /// Where each profile's runner choices are kept (`/var/lib/ruyaos/library`; a temporary
    /// folder in tests and with `--session`).
    pub choices_dir: PathBuf,
}

pub struct LibraryIface {
    sources: Arc<Sources>,
    items: Mutex<Vec<Item>>,
    choices: Choices,
}

impl LibraryIface {
    /// Scans once, so the first `ListItems` has an answer.
    pub fn new(sources: Sources) -> Self {
        let items = catalog::scan(
            &sources.steam_roots,
            sources.lister.as_ref(),
            &sources.play_root,
            &sources.play_runners,
        );
        LibraryIface {
            choices: Choices::new(sources.choices_dir.clone()),
            sources: Arc::new(sources),
            items: Mutex::new(items),
        }
    }

    /// The Flatpak id of the `.play` item `id` (`choices::play_app` on the current list).
    fn play_app(&self, id: &str) -> Result<String, Status> {
        match self.items.lock() {
            Ok(items) => choices::play_app(&items, id),
            Err(_) => Err(Status::Failed),
        }
    }

    /// `GetRunnerChoice`'s rule.
    pub fn runner_choice(&self, profile: &str, id: &str) -> Result<String, Status> {
        if !ruya_ids::valid_profile_id(profile) {
            return Err(Status::Invalid);
        }
        let app = self.play_app(id)?;
        self.choices.get(profile, &app)
    }

    /// `SetRunnerChoice`'s rule: true when the choice changed.
    pub fn store_runner_choice(
        &self,
        profile: &str,
        id: &str,
        choice: &str,
    ) -> Result<bool, Status> {
        if !ruya_ids::valid_profile_id(profile) || !choices::valid_choice(choice) {
            return Err(Status::Invalid);
        }
        let app = self.play_app(id)?;
        self.choices.set(profile, &app, choice)
    }

    /// What `ResolveRunner` resolves: the item's deployment, the image's runners and the choice.
    fn resolution_inputs(
        &self,
        id: &str,
        choice: &str,
    ) -> Result<(PathBuf, PathBuf, Override), Status> {
        let over = ruya_play_launch::parse_choice(choice).ok_or(Status::Invalid)?;
        let app = self.play_app(id)?;
        let files = play::deployment_files(&self.sources.play_root, &app).ok_or(Status::NotPlay)?;
        Ok((files, self.sources.play_runners.clone(), over))
    }

    /// `ResolveRunner`'s rule: the launcher's own dry run with that choice (the code `ListItems`
    /// gives the package's default to). Off Linux nothing is resolved: an empty resolution.
    pub fn runner_resolution(&self, id: &str, choice: &str) -> Result<Resolution, Status> {
        let (files, runners, over) = self.resolution_inputs(id, choice)?;
        Ok(runners::resolve_in_place(&files, &runners, over).unwrap_or_default())
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
            &self.sources.play_runners,
        ))
    }

    /// Sends `ItemsChanged`.
    pub async fn announce(emitter: &SignalEmitter<'_>) {
        if let Err(err) = Self::items_changed(emitter).await {
            eprintln!("ruya-library: emitting ItemsChanged failed: {err}");
        }
    }
}

/// The `a{sv}` record `ListItems` serves for one item (public for the contract test).
pub fn record(item: &Item) -> Dict {
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
        entries.extend(resolution_entries(&play.resolution));
    }
    dict(entries)
}

fn dict(entries: Vec<(&str, Value<'static>)>) -> Dict {
    entries
        .into_iter()
        .filter_map(|(k, v)| OwnedValue::try_from(v).ok().map(|v| (k.to_owned(), v)))
        .collect()
}

/// The runner keys of a resolution: the item record's and `ResolveRunner`'s, one code path.
/// `play_fallback` is there only when true, and only with a runner (Library1 XML).
fn resolution_entries(r: &Resolution) -> Vec<(&'static str, Value<'static>)> {
    let mut entries: Vec<(&'static str, Value<'static>)> = [
        ("play_runner", &r.runner),
        ("play_runner_source", &r.runner_source),
        ("play_runner_tested", &r.runner_tested),
        ("play_resolve_error", &r.resolve_error),
        ("play_resolve_code", &r.resolve_code),
    ]
    .into_iter()
    .filter_map(|(key, value)| value.as_ref().map(|v| (key, Value::from(v.clone()))))
    .collect();
    if r.fallback && r.runner.is_some() {
        entries.push(("play_fallback", Value::from(true)));
    }
    entries
}

/// The `a{sv}` record `ResolveRunner` serves (public for the contract test).
pub fn resolution_record(r: &Resolution) -> Dict {
    dict(resolution_entries(r))
}

/// The `a{sv}` record `ListRunners` serves for one runner (public for the contract test).
pub fn runner_record(r: &Runner) -> Dict {
    let mut entries = vec![
        ("family", Value::from(r.family.clone())),
        ("kind", Value::from(r.kind.clone())),
        ("version", Value::from(r.version.clone())),
    ];
    if let Some(licence) = &r.licence {
        entries.push(("licence", Value::from(licence.clone())));
    }
    if let Some(url) = &r.source_url {
        entries.push(("source_url", Value::from(url.clone())));
    }
    dict(entries)
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
                &sources.play_runners,
            )
        })
        .await;
        if self.store(fresh) {
            Self::announce(&emitter).await;
        }
    }

    #[zbus(signal)]
    async fn items_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    async fn list_runners(&self) -> Vec<Dict> {
        let dir = self.sources.play_runners.clone();
        // File I/O: not on the executor.
        let found = blocking::unblock(move || runners::list_in_place(&dir)).await;
        found.iter().map(runner_record).collect()
    }

    fn get_runner_choice(&self, profile: &str, id: &str) -> (String, String) {
        match self.runner_choice(profile, id) {
            Ok(choice) => (Status::Ok.as_str().to_owned(), choice),
            Err(status) => (status.as_str().to_owned(), String::new()),
        }
    }

    async fn set_runner_choice(
        &self,
        profile: &str,
        id: &str,
        choice: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        match self.store_runner_choice(profile, id, choice) {
            Ok(changed) => {
                if changed {
                    if let Err(err) =
                        Self::runner_choice_changed(&emitter, profile, id, choice).await
                    {
                        eprintln!("ruya-library: emitting RunnerChoiceChanged failed: {err}");
                    }
                }
                Status::Ok.as_str().to_owned()
            }
            Err(status) => {
                eprintln!(
                    "ruya-library: SetRunnerChoice {choice:?} for {id:?} of {profile:?} answered {}",
                    status.as_str()
                );
                status.as_str().to_owned()
            }
        }
    }

    async fn resolve_runner(&self, id: &str, choice: &str) -> (String, Dict) {
        let (files, runners, over) = match self.resolution_inputs(id, choice) {
            Ok(inputs) => inputs,
            Err(status) => return (status.as_str().to_owned(), Dict::new()),
        };
        // The dry run reads the package and the runners folder: not on the executor.
        let r = blocking::unblock(move || {
            runners::resolve_in_place(&files, &runners, over).unwrap_or_default()
        })
        .await;
        (Status::Ok.as_str().to_owned(), resolution_record(&r))
    }

    #[zbus(signal)]
    async fn runner_choice_changed(
        emitter: &SignalEmitter<'_>,
        profile: &str,
        id: &str,
        choice: &str,
    ) -> zbus::Result<()>;
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

    /// Which keys exist is the contract test's (tests/contract.rs); this is what it cannot see:
    /// the extra keys are absent for a plain item and for the fields a .play app does not have.
    #[test]
    fn the_extra_keys_are_absent_for_a_plain_item_and_for_what_a_play_app_lacks() {
        let plain = record(&item(None));
        assert!(["play", "genres", "players", "play_tier"]
            .iter()
            .all(|k| !plain.contains_key(*k)));
        let bare = record(&item(Some(PlayInfo::default())));
        assert!(bool::try_from(bare["play"].try_clone().unwrap()).unwrap());
        for key in [
            "players",
            "controller",
            "age_rating",
            "play_tier",
            "play_signer",
            "play_signer_key_id",
            "play_screenshots",
            "play_runner",
            "play_runner_source",
            "play_runner_tested",
            "play_resolve_error",
            "play_resolve_code",
            "play_fallback",
        ] {
            assert!(!bare.contains_key(key), "{key}");
        }
    }
}
