//! org.ruyaos.Library1 on D-Bus. Thin adapter: the rules live in `catalog.rs`, `view.rs`,
//! `games.rs`, `profile_items.rs`, `runners.rs` and `choices.rs`.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use zbus::interface;
use zbus::message::Header;
use zbus::names::BusName;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedValue, Value};
use zbus::Connection;

use ruya_play_format::resolve::Override;

use crate::catalog::{self, Item};
use crate::choices::{self, Choices, Status};
use crate::flatpak::AppLister;
use crate::games::{self, Game, GameChoices};
use crate::play;
use crate::profile_items;
use crate::runners::{self, Resolution, Runner};
use crate::view::{may_put, View};

pub const BUS_NAME: &str = "org.ruyaos.Library1";
pub const OBJECT_PATH: &str = "/org/ruyaos/Library1";

pub type Dict = HashMap<String, OwnedValue>;

/// What a scan needs; shared with the thread that runs it.
pub struct Sources {
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
    view: Mutex<View>,
    choices: Choices,
    /// The uid check of the root-only calls (`view::may_put`); off only with `--session`.
    check_caller: bool,
}

/// The Flatpak items of one scan of `sources`.
fn scan(sources: &Sources) -> Vec<Item> {
    catalog::scan(
        sources.lister.as_ref(),
        &sources.play_root,
        &sources.play_runners,
    )
}

impl LibraryIface {
    /// Scans once, so the first `ListItems` has an answer. Nobody is active until ruya-session
    /// says (`SetActiveProfile`); the root-only calls check the caller's uid.
    pub fn new(sources: Sources) -> Self {
        let view = View::new(scan(&sources));
        LibraryIface {
            choices: Choices::new(sources.choices_dir.clone()),
            sources: Arc::new(sources),
            view: Mutex::new(view),
            check_caller: true,
        }
    }

    /// Development (`--session`): the root-only calls take any caller, since nothing on the
    /// session bus is root. Logged, so it is never off unnoticed.
    pub fn without_caller_check(mut self) -> Self {
        eprintln!(
            "ruya-library: development mode: PutProfileItems and SetActiveProfile take any caller"
        );
        self.check_caller = false;
        self
    }

    /// The Flatpak id of the `.play` item `id` (`choices::play_app` on the current list).
    fn play_app(&self, id: &str) -> Result<String, Status> {
        match self.view.lock() {
            Ok(view) => choices::play_app(view.items(), id),
            Err(_) => Err(Status::Failed),
        }
    }

    /// Whether the sender of `header` may make a root-only call: its uid as the bus knows it
    /// (`GetConnectionUnixUser`), by `view::may_put`. A sender the bus cannot name is refused.
    async fn caller_allowed(&self, header: &Header<'_>, connection: &Connection) -> bool {
        if !self.check_caller {
            return true;
        }
        let Some(sender) = header.sender() else {
            return false;
        };
        let uid = match zbus::fdo::DBusProxy::new(connection).await {
            Ok(bus) => {
                bus.get_connection_unix_user(BusName::Unique(sender.clone()))
                    .await
            }
            Err(err) => Err(err.into()),
        };
        match uid {
            Ok(uid) => may_put(uid),
            Err(err) => {
                eprintln!("ruya-library: the caller {sender} has no uid: {err}");
                false
            }
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

    /// `SetActiveProfile`'s rule (the caller check aside): the profile ("" = nobody) and its links
    /// and preferences come into the view. Answers whether the profile moved and whether the served
    /// list changed.
    pub fn activate(&self, profile: &str) -> Result<(bool, bool), Status> {
        if !profile.is_empty() && !ruya_ids::valid_profile_id(profile) {
            return Err(Status::Invalid);
        }
        let choices = if profile.is_empty() {
            GameChoices::default()
        } else {
            // A file that cannot be read leaves the profile with its plain games (logged there).
            self.choices
                .state(profile)
                .map(|s| s.games)
                .unwrap_or_default()
        };
        let mut moved = false;
        let changed = self.store(|view| {
            moved = view.active() != profile;
            view.set_active(profile, choices)
        });
        Ok((moved, changed))
    }

    /// Changes `profile`'s links and preferences with `change`, given the games it sees now, and
    /// stores them. True when the served list changed (`ItemsChanged`).
    fn change_games(
        &self,
        profile: &str,
        change: impl FnOnce(&mut GameChoices, &[Game]) -> Result<bool, Status>,
    ) -> Result<bool, Status> {
        let (changed, state) = self.choices.update(profile, |state| {
            let seen = self
                .view
                .lock()
                .map_err(|_| Status::Failed)?
                .games_of(profile, &state.games);
            change(&mut state.games, &seen)
        })?;
        Ok(changed && self.store(|view| view.set_choices(profile, state.games)))
    }

    /// `LinkInstallations`' rule: the game of `b` joins the game of `a`.
    pub fn link(&self, profile: &str, a: &str, b: &str) -> Result<bool, Status> {
        self.change_games(profile, |c, seen| games::link(c, seen, a, b))
    }

    /// `UnlinkInstallation`'s rule.
    pub fn unlink(&self, profile: &str, installation: &str) -> Result<bool, Status> {
        self.change_games(profile, |c, seen| games::unlink(c, seen, installation))
    }

    /// `SetPreferredInstallation`'s rule.
    pub fn prefer(&self, profile: &str, game: &str, installation: &str) -> Result<bool, Status> {
        self.change_games(profile, |c, seen| {
            games::prefer(c, seen, game, installation)
        })
    }

    /// What `ListItems` serves now.
    pub fn list(&self) -> Vec<Dict> {
        match self.view.lock() {
            Ok(view) => view.games().iter().map(record).collect(),
            Err(_) => Vec::new(),
        }
    }

    /// The answer of an installation call: its status, after `ItemsChanged` when the list changed.
    async fn answer(
        result: Result<bool, Status>,
        call: &str,
        emitter: &SignalEmitter<'_>,
    ) -> String {
        match result {
            Ok(changed) => {
                if changed {
                    Self::announce(emitter).await;
                }
                Status::Ok.as_str().to_owned()
            }
            Err(status) => {
                eprintln!("ruya-library: {call} answered {}", status.as_str());
                status.as_str().to_owned()
            }
        }
    }

    /// Changes the view with `change`; true when the served list differs from the one before.
    fn store(&self, change: impl FnOnce(&mut View) -> bool) -> bool {
        match self.view.lock() {
            Ok(mut view) => change(&mut view),
            Err(_) => false,
        }
    }

    /// Scans on the calling thread (the watcher thread in `main.rs`, never the executor).
    /// True when the list changed; the caller then sends `ItemsChanged` with `announce`.
    pub fn refresh(&self) -> bool {
        let fresh = scan(&self.sources);
        self.store(|view| view.set_flatpak(fresh))
    }

    /// The active profile ("" = nobody).
    fn active(&self) -> String {
        self.view
            .lock()
            .map(|view| view.active().to_owned())
            .unwrap_or_default()
    }

    /// Sends `ItemsChanged`.
    pub async fn announce(emitter: &SignalEmitter<'_>) {
        if let Err(err) = Self::items_changed(emitter).await {
            eprintln!("ruya-library: emitting ItemsChanged failed: {err}");
        }
    }
}

/// The `a{sv}` record `ListItems` serves for one game (public for the contract test): the record of
/// its preferred installation under the game's id and latest play, with its installations.
pub fn record(game: &Game) -> Dict {
    let installations: Vec<Dict> = game
        .installations
        .iter()
        .enumerate()
        .map(|(n, i)| installation_record(i, n == game.preferred))
        .collect();
    let mut entries = item_entries(game.preferred(), &game.id, game.last_played());
    entries.push(("installations", Value::from(installations)));
    entries.push(("confidence", Value::from(game.confidence.as_str())));
    if !game.suggestions.is_empty() {
        entries.push(("suggestions", Value::from(game.suggestions.clone())));
    }
    dict(entries)
}

/// The `a{sv}` record of one installation of a game (public for the contract test).
pub fn installation_record(item: &Item, preferred: bool) -> Dict {
    let mut entries = vec![
        ("id", Value::from(item.id.clone())),
        ("source", Value::from(item.source.as_str())),
        ("launch", Value::from(item.launch.clone())),
        ("available", Value::from(games::available(item))),
        ("preferred", Value::from(preferred)),
    ];
    if let Some(play) = &item.play {
        entries.push(("play", Value::from(true)));
        if let Some(runner) = &play.resolution.runner {
            entries.push(("runner", Value::from(runner.clone())));
        }
        if let Some(version) = &play.version {
            entries.push(("version", Value::from(version.clone())));
        }
    }
    dict(entries)
}

/// The keys of an installation's own record, under the game's `id` and `last_played`.
fn item_entries(item: &Item, id: &str, last_played: i64) -> Vec<(&'static str, Value<'static>)> {
    let art: HashMap<String, String> = item.art.iter().cloned().collect();
    let mut entries = vec![
        ("id", Value::from(id.to_owned())),
        ("kind", Value::from(item.kind.as_str())),
        ("title", Value::from(item.title.clone())),
        ("source", Value::from(item.source.as_str())),
        ("launch", Value::from(item.launch.clone())),
        ("art", Value::from(art)),
        ("last_played", Value::from(last_played)),
    ];
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
    entries
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
        self.list()
    }

    async fn rescan(&self, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) {
        let sources = self.sources.clone();
        // File and process I/O: not on the executor.
        let fresh = blocking::unblock(move || scan(&sources)).await;
        if self.store(|view| view.set_flatpak(fresh)) {
            Self::announce(&emitter).await;
        }
        // The Steam items are read as the profile (ADR-045): ruya-session runs the reader.
        let active = self.active();
        if !active.is_empty() {
            if let Err(err) = Self::profile_scan_wanted(&emitter, &active).await {
                eprintln!("ruya-library: emitting ProfileScanWanted failed: {err}");
            }
        }
    }

    #[zbus(signal)]
    async fn items_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    async fn put_profile_items(
        &self,
        profile: &str,
        data: String,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        if !self.caller_allowed(&header, connection).await {
            eprintln!("ruya-library: PutProfileItems from a caller that is not root, refused");
            return Status::NotAllowed.as_str().to_owned();
        }
        if !ruya_ids::valid_profile_id(profile) {
            return Status::Invalid.as_str().to_owned();
        }
        // Up to 32 MiB of JSON: not on the executor.
        let items = match blocking::unblock(move || profile_items::decode(&data)).await {
            Ok(items) => items,
            Err(why) => {
                eprintln!(
                    "ruya-library: the Steam items of {profile} refused: {}",
                    why.as_str()
                );
                return Status::Invalid.as_str().to_owned();
            }
        };
        let count = items.len();
        if self.store(|view| view.put(profile, items)) {
            Self::announce(&emitter).await;
        }
        eprintln!("ruya-library: {count} Steam items for {profile}");
        Status::Ok.as_str().to_owned()
    }

    async fn set_active_profile(
        &self,
        profile: &str,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        if !self.caller_allowed(&header, connection).await {
            eprintln!("ruya-library: SetActiveProfile from a caller that is not root, refused");
            return Status::NotAllowed.as_str().to_owned();
        }
        let (moved, changed) = match self.activate(profile) {
            Ok(answer) => answer,
            Err(status) => return status.as_str().to_owned(),
        };
        if moved {
            if let Err(err) = self.active_profile_changed(&emitter).await {
                eprintln!("ruya-library: emitting ActiveProfile's change failed: {err}");
            }
        }
        if changed {
            Self::announce(&emitter).await;
        }
        Status::Ok.as_str().to_owned()
    }

    #[zbus(property)]
    fn active_profile(&self) -> String {
        self.active()
    }

    #[zbus(signal)]
    async fn profile_scan_wanted(emitter: &SignalEmitter<'_>, profile: &str) -> zbus::Result<()>;

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

    async fn set_preferred_installation(
        &self,
        profile: &str,
        game: &str,
        installation: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let result = self.prefer(profile, game, installation);
        Self::answer(result, "SetPreferredInstallation", &emitter).await
    }

    async fn link_installations(
        &self,
        profile: &str,
        a: &str,
        b: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let result = self.link(profile, a, b);
        Self::answer(result, "LinkInstallations", &emitter).await
    }

    async fn unlink_installation(
        &self,
        profile: &str,
        installation: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let result = self.unlink(profile, installation);
        Self::answer(result, "UnlinkInstallation", &emitter).await
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
            declared: Vec::new(),
        }
    }

    /// Which keys exist is the contract test's (tests/contract.rs); this is what it cannot see:
    /// the extra keys are absent for a plain item and for the fields a .play app does not have.
    #[test]
    fn the_extra_keys_are_absent_for_a_plain_item_and_for_what_a_play_app_lacks() {
        let game = |play| games::group(&[item(play)], &GameChoices::default()).remove(0);
        let plain = record(&game(None));
        assert!(["play", "genres", "players", "play_tier"]
            .iter()
            .all(|k| !plain.contains_key(*k)));
        let bare = record(&game(Some(PlayInfo::default())));
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
