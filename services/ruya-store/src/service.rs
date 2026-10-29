//! The store's rules: the catalogue (remotes' app lists + AppStream + installed + updates), the
//! checks in front of every job, and the running of one job with its progress and result. All
//! side effects go through the `Flatpak` trait; the D-Bus adapter only converts and emits.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard};

use crate::app::{valid_app_id, valid_commit, valid_remote_name, App, JobStatus, Status};
use crate::appstream::{self, Component};
use crate::flatpak::{Flatpak, FlatpakError, Operation, Phase, Progress, RemoteInfo};
use crate::queue::{Monotone, Queue};

/// What a running job tells the outside world, in the order it must be sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Progress {
        job: String,
        percent: u32,
        phase: Phase,
    },
    /// The installed set or an update flag changed.
    InstalledChanged,
    /// The catalogue was (re)read: clients search again.
    CatalogChanged,
    Finished {
        job: String,
        status: JobStatus,
    },
}

/// Filters of `Search` (`options` of the contract).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SearchOptions {
    /// Only apps with controller support, `full` or `partial` (unknown counts as none).
    pub gamepad_only: bool,
    /// 0 = no limit.
    pub limit: usize,
}

impl SearchOptions {
    /// From the values of the `controller` and `limit` keys; `None` if `controller` is neither
    /// "any" nor "gamepad".
    pub fn parse(controller: Option<&str>, limit: Option<u32>) -> Option<Self> {
        let gamepad_only = match controller {
            None | Some("any") => false,
            Some("gamepad") => true,
            Some(_) => return None,
        };
        Some(SearchOptions {
            gamepad_only,
            limit: limit.map_or(0, |l| l as usize),
        })
    }
}

/// The trust level shown on an app's page, from the remote it comes from (spec 03 §4.2).
pub fn trust_of(remote: &str) -> &'static str {
    match remote {
        "ruyaos" => "official",
        "flathub" => "community",
        _ => "developer",
    }
}

#[derive(Default)]
struct State {
    catalogue: Vec<App>,
    queue: Queue,
    /// Permissions by (app id, remote): metadata is read once per app, not on every refresh.
    permissions: HashMap<(String, String), Vec<String>>,
}

pub struct Store<F: Flatpak> {
    flatpak: F,
    state: Mutex<State>,
}

impl<F: Flatpak> Store<F> {
    pub fn new(flatpak: F) -> Self {
        Store {
            flatpak,
            state: Mutex::new(State::default()),
        }
    }

    fn state(&self) -> MutexGuard<'_, State> {
        // A poisoned lock only means another call panicked; the state is plain data.
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Reads Flatpak again and rebuilds the catalogue. Returns whether the installed set or an
    /// update flag changed. A failing command keeps the old catalogue.
    pub fn refresh(&self) -> Result<bool, String> {
        let available = self.flatpak.remote_apps()?;
        let installed = self.flatpak.installed()?;
        // No network is not a reason to lose the catalogue: updates are optional knowledge.
        let updates = self.flatpak.updates().unwrap_or_default();

        let mut components: HashMap<String, Vec<Component>> = HashMap::new();
        let mut known: Vec<&str> = Vec::new();
        for app in &available {
            if !known.contains(&app.remote.as_str()) {
                known.push(&app.remote);
            }
        }
        for remote in known {
            if let Some(source) = self.flatpak.appstream(remote) {
                components.insert(
                    remote.to_owned(),
                    appstream::parse(&source.xml, &source.icon_base),
                );
            }
        }

        let mut catalogue: Vec<App> = Vec::new();
        for entry in &available {
            let component = components
                .get(&entry.remote)
                .and_then(|list| list.iter().find(|c| c.id == entry.id));
            let key = (entry.id.clone(), entry.remote.clone());
            // Permissions are read on demand (`get_app`): one `flatpak remote-info` per app
            // would stall the start-up on a remote with hundreds of apps.
            let permissions = self
                .state()
                .permissions
                .get(&key)
                .cloned()
                .unwrap_or_default();
            let mut app = app_from(entry.id.as_str(), component);
            app.remote = entry.remote.clone();
            app.source = trust_of(&entry.remote).to_owned();
            app.installed_size = entry.installed_size;
            app.permissions = permissions;
            catalogue.push(app);
        }
        // Installed apps no remote offers any more (a removed source) still have to be listed.
        for app in &installed {
            if !catalogue.iter().any(|c| c.id == app.id) {
                let mut gone = app_from(app.id.as_str(), None);
                gone.remote = app.remote.clone();
                gone.source = trust_of(&app.remote).to_owned();
                gone.installed_size = app.installed_size;
                catalogue.push(gone);
            }
        }
        for app in &mut catalogue {
            if let Some(i) = installed.iter().find(|i| i.id == app.id) {
                app.installed = true;
                app.installed_size = app.installed_size.max(i.installed_size);
                app.update_available = updates.contains(&app.id);
            }
        }
        catalogue.sort_by_key(|a| a.name.to_lowercase());

        let mut state = self.state();
        let changed = signature(&state.catalogue) != signature(&catalogue);
        state.catalogue = catalogue;
        Ok(changed)
    }

    pub fn search(&self, query: &str, options: &SearchOptions) -> Vec<App> {
        let limit = if options.limit == 0 {
            usize::MAX
        } else {
            options.limit
        };
        self.state()
            .catalogue
            .iter()
            .filter(|a| a.matches(query))
            .filter(|a| {
                !options.gamepad_only || matches!(a.controller.as_str(), "full" | "partial")
            })
            .take(limit)
            .cloned()
            .collect()
    }

    /// Reads the catalogue, then fetches the remotes' AppStream data and reads it again, telling
    /// the clients after each step: `CatalogChanged` always, `InstalledChanged` only when the
    /// installed set or an update flag differs from before (an install does not re-send the
    /// catalogue, a refresh does not re-send the installed list).
    pub fn sync(&self, emit: &mut dyn FnMut(Event)) {
        let announce = |result: Result<bool, String>, emit: &mut dyn FnMut(Event)| match result {
            Ok(installed_changed) => {
                if installed_changed {
                    emit(Event::InstalledChanged);
                }
                emit(Event::CatalogChanged);
            }
            Err(err) => eprintln!("ruya-store: reading Flatpak failed: {err}"),
        };
        announce(self.refresh(), emit);
        announce(self.update_appstream(), emit);
    }

    /// One app with its permissions, read from Flatpak the first time they are asked for (the
    /// lists carry the ones already read). Blocks while it does.
    pub fn get_app(&self, id: &str) -> (Status, App) {
        let found = self.state().catalogue.iter().find(|a| a.id == id).cloned();
        let Some(mut app) = found else {
            return (Status::UnknownApp, App::default());
        };
        let key = (app.id.clone(), app.remote.clone());
        let cached = self.state().permissions.get(&key).cloned();
        app.permissions = cached.unwrap_or_else(|| {
            let list = self
                .flatpak
                .metadata(&app.remote, &app.id)
                .map(|m| appstream::permissions(&m))
                .unwrap_or_default();
            let mut state = self.state();
            state.permissions.insert(key, list.clone());
            if let Some(entry) = state.catalogue.iter_mut().find(|a| a.id == app.id) {
                entry.permissions = list.clone();
            }
            list
        });
        (Status::Ok, app)
    }

    pub fn list_installed(&self) -> Vec<App> {
        self.state()
            .catalogue
            .iter()
            .filter(|a| a.installed)
            .cloned()
            .collect()
    }

    /// Checks the request against the catalogue and queues it. `job` is "" unless `Ok`.
    fn queue(
        &self,
        id: &str,
        check: impl FnOnce(&App) -> Option<Status>,
        op: impl FnOnce(&App) -> Operation,
    ) -> (Status, String) {
        if !valid_app_id(id) {
            return (Status::Invalid, String::new());
        }
        let mut state = self.state();
        let Some(app) = state.catalogue.iter().find(|a| a.id == id).cloned() else {
            return (Status::UnknownApp, String::new());
        };
        if let Some(refused) = check(&app) {
            return (refused, String::new());
        }
        match state.queue.enqueue(op(&app)) {
            Some(job) => (Status::Ok, job),
            None => (Status::Busy, String::new()),
        }
    }

    pub fn install(&self, id: &str) -> (Status, String) {
        self.queue(
            id,
            |app| app.installed.then_some(Status::AlreadyInstalled),
            |app| Operation::Install {
                id: app.id.clone(),
                remote: app.remote.clone(),
            },
        )
    }

    pub fn uninstall(&self, id: &str, delete_data: bool) -> (Status, String) {
        self.queue(
            id,
            |app| (!app.installed).then_some(Status::NotInstalled),
            |app| Operation::Uninstall {
                id: app.id.clone(),
                delete_data,
            },
        )
    }

    pub fn update(&self, id: &str) -> (Status, String) {
        self.queue(
            id,
            |app| {
                if !app.installed {
                    Some(Status::NotInstalled)
                } else if !app.update_available {
                    Some(Status::NoUpdate)
                } else {
                    None
                }
            },
            |app| Operation::Update { id: app.id.clone() },
        )
    }

    pub fn rollback(&self, id: &str, commit: &str) -> (Status, String) {
        if !valid_commit(commit) {
            return (Status::Invalid, String::new());
        }
        self.queue(
            id,
            |app| (!app.installed).then_some(Status::NotInstalled),
            |app| Operation::Rollback {
                id: app.id.clone(),
                commit: commit.to_owned(),
            },
        )
    }

    pub fn list_remotes(&self) -> Vec<(RemoteInfo, &'static str)> {
        self.flatpak
            .remotes()
            .unwrap_or_default()
            .into_iter()
            .map(|r| {
                let trust = trust_of(&r.name);
                (r, trust)
            })
            .collect()
    }

    /// Fetches every enabled remote's AppStream data again, then reads the catalogue. A remote
    /// that cannot be reached (no network) keeps the data flatpak has; that is logged once, not
    /// per remote. Returns whether the installed set or an update flag changed.
    pub fn update_appstream(&self) -> Result<bool, String> {
        let failed: Vec<String> = self
            .flatpak
            .remotes()?
            .into_iter()
            .filter(|r| r.enabled && valid_remote_name(&r.name))
            .filter(|r| self.flatpak.update_appstream(&r.name).is_err())
            .map(|r| r.name)
            .collect();
        if !failed.is_empty() {
            eprintln!(
                "ruya-store: AppStream not refreshed for {} (offline?), keeping the cached data",
                failed.join(", ")
            );
        }
        self.refresh()
    }

    /// Adds a software source. Only for an admin (`is_admin`, decided by the caller); a remote
    /// without signature verification is never added.
    pub fn add_remote(&self, name: &str, url: &str, is_admin: bool) -> Status {
        if !is_admin {
            return Status::Forbidden;
        }
        if !valid_remote_name(name) || !valid_remote_url(url) {
            return Status::Invalid;
        }
        match self.flatpak.add_remote(name, url) {
            Ok(()) => Status::Ok,
            // No usable key is the same as unsigned: refused as the contract says.
            Err(FlatpakError::Signature) => Status::Invalid,
            Err(_) => Status::Failed,
        }
    }

    /// Runs the oldest queued job to its end (blocking) unless one is already running, sending
    /// its events in order. Returns whether a job ran.
    pub fn run_next(&self, emit: &mut dyn FnMut(Event)) -> bool {
        let Some(job) = self.state().queue.take_next() else {
            return false;
        };
        let mut monotone = Monotone::default();
        let mut report = |percent: u32, phase: Phase, emit: &mut dyn FnMut(Event)| {
            if let Some(percent) = monotone.next(percent, phase) {
                emit(Event::Progress {
                    job: job.id.clone(),
                    percent,
                    phase,
                });
            }
        };
        report(0, job.op.phase(), emit);
        let result = self
            .flatpak
            .run(&job.op, &mut |p: Progress| report(p.percent, p.phase, emit));
        let status = match &result {
            Ok(()) => {
                report(100, job.op.phase(), emit);
                JobStatus::Ok
            }
            Err(err) => {
                if let FlatpakError::Other(line) = err {
                    eprintln!("ruya-store: {} failed: {line}", job.id);
                }
                err.job_status()
            }
        };
        // Free the app before the catalogue is rebuilt, so a client reacting to the signals can
        // queue the next job for it at once.
        self.state().queue.finish(&job.id);
        if status == JobStatus::Ok {
            match self.refresh() {
                Ok(true) => emit(Event::InstalledChanged),
                Ok(false) => {}
                Err(err) => eprintln!("ruya-store: reading Flatpak failed: {err}"),
            }
        }
        emit(Event::Finished {
            job: job.id,
            status,
        });
        true
    }
}

/// `https://` or `file://`; nothing that could be read as an option or a different scheme.
fn valid_remote_url(url: &str) -> bool {
    (url.starts_with("https://") || url.starts_with("file:///"))
        && url.len() <= 2048
        && !url.chars().any(|c| c.is_control() || c.is_whitespace())
}

fn app_from(id: &str, component: Option<&Component>) -> App {
    match component {
        Some(c) => App {
            id: id.to_owned(),
            name: if c.name.is_empty() {
                fallback_name(id)
            } else {
                c.name.clone()
            },
            summary: c.summary.clone(),
            description: c.description.clone(),
            developer: c.developer.clone(),
            controller: c.controller.clone(),
            age_rating: c.age_rating.clone(),
            icon: c.icon.clone(),
            tile: c.tile.clone(),
            hero: c.hero.clone(),
            ..App::default()
        },
        None => App {
            id: id.to_owned(),
            name: fallback_name(id),
            controller: "none".to_owned(),
            ..App::default()
        },
    }
}

/// "org.example.TurboRacer" -> "TurboRacer" for an app AppStream does not describe.
fn fallback_name(id: &str) -> String {
    id.rsplit('.').next().unwrap_or(id).to_owned()
}

/// What `InstalledChanged` is about: which apps are installed and which have an update.
fn signature(catalogue: &[App]) -> Vec<(&str, bool)> {
    let mut sig: Vec<_> = catalogue
        .iter()
        .filter(|a| a.installed)
        .map(|a| (a.id.as_str(), a.update_available))
        .collect();
    sig.sort_unstable();
    sig
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::flatpak::FakeFlatpak;

    const XML: &str = r#"<components origin="ruyaos">
      <component type="desktop-application"><id>org.ruya.Racer.desktop</id><name>Turbo Racer</name>
        <summary>Drive fast</summary></component>
      <component type="desktop-application"><id>org.ruya.Puzzle</id><name>Block Puzzle</name>
        <summary>Fit the blocks</summary></component>
    </components>"#;

    const ANY: SearchOptions = SearchOptions {
        gamepad_only: false,
        limit: 0,
    };

    fn fake() -> FakeFlatpak {
        FakeFlatpak::default()
            .with_remote("ruyaos", "RuyaOS", true)
            .with_app("ruyaos", "org.ruya.Racer", 5_000_000)
            .with_app("ruyaos", "org.ruya.Puzzle", 2_000_000)
            .with_app("flathub", "org.other.Tool", 1_000)
            .with_appstream("ruyaos", XML)
            .with_metadata(
                "org.ruya.Racer",
                "[Context]\nshared=network;\nsockets=pulseaudio;\n",
            )
    }

    fn store(f: FakeFlatpak) -> Store<FakeFlatpak> {
        let s = Store::new(f);
        s.refresh().unwrap();
        s
    }

    fn drain(s: &Store<FakeFlatpak>) -> Vec<Event> {
        let mut events = Vec::new();
        while s.run_next(&mut |e| events.push(e)) {}
        events
    }

    #[test]
    fn the_catalogue_joins_remotes_appstream_and_permissions() {
        let s = store(fake());
        let all = s.search("", &ANY);
        let names: Vec<_> = all.iter().map(|a| a.name.as_str()).collect();
        assert_eq!(
            names,
            ["Block Puzzle", "Tool", "Turbo Racer"],
            "sorted, id tail for unknown"
        );
        assert!(
            s.search("racer", &ANY)[0].permissions.is_empty(),
            "not read yet"
        );
        let racer = s.get_app("org.ruya.Racer").1;
        assert_eq!(racer.summary, "Drive fast");
        assert_eq!(racer.source, "official");
        assert_eq!(racer.installed_size, 5_000_000);
        assert_eq!(racer.permissions, ["network", "audio"]);
        assert_eq!(
            s.search("racer", &ANY)[0].permissions,
            ["network", "audio"],
            "kept after GetApp"
        );
        s.refresh().unwrap();
        assert_eq!(
            s.search("racer", &ANY)[0].permissions,
            ["network", "audio"],
            "and across a refresh"
        );
        assert_eq!(s.get_app("org.other.Tool").1.source, "community");
        assert_eq!(s.get_app("org.nope.Missing").0, Status::UnknownApp);
    }

    #[test]
    fn search_matches_name_summary_and_id() {
        let s = store(fake());
        assert_eq!(s.search("racer", &ANY).len(), 1);
        assert_eq!(s.search("FIT THE", &ANY).len(), 1);
        assert_eq!(s.search("org.other", &ANY).len(), 1);
        assert!(s.search("zzz", &ANY).is_empty());
    }

    #[test]
    fn install_runs_a_job_and_reports_in_order() {
        let s = store(fake());
        let (status, job) = s.install("org.ruya.Racer");
        assert_eq!((status, job.as_str()), (Status::Ok, "job-1"));
        assert_eq!(s.install("org.ruya.Racer").0, Status::Busy);
        let events = drain(&s);
        let last_two = &events[events.len() - 2..];
        assert_eq!(last_two[0], Event::InstalledChanged, "before JobFinished");
        assert_eq!(
            last_two[1],
            Event::Finished {
                job: "job-1".into(),
                status: JobStatus::Ok
            }
        );
        assert!(matches!(&events[0], Event::Progress { percent: 0, .. }));
        assert!(events
            .iter()
            .any(|e| matches!(e, Event::Progress { percent: 100, .. })));
        assert!(s.get_app("org.ruya.Racer").1.installed);
        assert_eq!(s.list_installed().len(), 1);
        assert_eq!(s.install("org.ruya.Racer").0, Status::AlreadyInstalled);
    }

    #[test]
    fn progress_never_decreases_whatever_flatpak_prints() {
        let s = store(fake().with_progress(&[10, 60, 30, 60, 100, 90]));
        s.install("org.ruya.Racer");
        let seen: Vec<u32> = drain(&s)
            .into_iter()
            .filter_map(|e| match e {
                Event::Progress { percent, .. } => Some(percent),
                _ => None,
            })
            .collect();
        assert_eq!(seen, [0, 10, 60, 100]);
    }

    #[test]
    fn jobs_run_one_at_a_time_in_order() {
        let s = store(fake());
        let (_, a) = s.install("org.ruya.Racer");
        let (_, b) = s.install("org.ruya.Puzzle");
        let finished: Vec<_> = drain(&s)
            .into_iter()
            .filter_map(|e| match e {
                Event::Finished { job, .. } => Some(job),
                _ => None,
            })
            .collect();
        assert_eq!(finished, [a, b]);
    }

    #[test]
    fn each_failure_is_its_job_status_and_leaves_the_app_alone() {
        for (error, want) in [
            (FlatpakError::Network, JobStatus::Network),
            (FlatpakError::Signature, JobStatus::Signature),
            (FlatpakError::MissingRuntime, JobStatus::MissingRuntime),
            (FlatpakError::DiskFull, JobStatus::DiskFull),
            (FlatpakError::Other("boom".into()), JobStatus::Failed),
        ] {
            let f = fake();
            f.fail_next(error);
            let s = store(f);
            s.install("org.ruya.Racer");
            let events = drain(&s);
            assert_eq!(
                events.last(),
                Some(&Event::Finished {
                    job: "job-1".into(),
                    status: want
                })
            );
            assert!(!events.contains(&Event::InstalledChanged), "{want:?}");
            assert!(!s.get_app("org.ruya.Racer").1.installed);
            assert_eq!(
                s.install("org.ruya.Racer").0,
                Status::Ok,
                "free again after {want:?}"
            );
        }
    }

    #[test]
    fn uninstall_update_and_rollback_need_an_installed_app() {
        let s = store(fake());
        assert_eq!(s.uninstall("org.ruya.Racer", false).0, Status::NotInstalled);
        assert_eq!(s.update("org.ruya.Racer").0, Status::NotInstalled);
        assert_eq!(
            s.rollback("org.ruya.Racer", "abcdef123456").0,
            Status::NotInstalled
        );
        assert_eq!(s.install("org.nope.Missing").0, Status::UnknownApp);
        assert_eq!(s.install("not an id").0, Status::Invalid);
        assert_eq!(s.rollback("org.ruya.Racer", "--user").0, Status::Invalid);
    }

    #[test]
    fn update_needs_an_update_and_clears_the_flag() {
        let f = fake()
            .with_installed("ruyaos", "org.ruya.Racer", 5_000_000)
            .with_update("org.ruya.Racer");
        let s = store(f);
        assert!(s.get_app("org.ruya.Racer").1.update_available);
        assert_eq!(s.update("org.ruya.Puzzle").0, Status::NotInstalled);
        let (status, _) = s.update("org.ruya.Racer");
        assert_eq!(status, Status::Ok);
        let events = drain(&s);
        assert!(
            events.contains(&Event::InstalledChanged),
            "the update flag changed"
        );
        assert!(!s.get_app("org.ruya.Racer").1.update_available);
        assert_eq!(s.update("org.ruya.Racer").0, Status::NoUpdate);
    }

    #[test]
    fn uninstall_and_rollback_are_queued_with_their_arguments() {
        let f = fake().with_installed("ruyaos", "org.ruya.Racer", 1);
        let s = store(f);
        s.uninstall("org.ruya.Racer", true);
        drain(&s);
        assert_eq!(
            s.flatpak.ran(),
            [Operation::Uninstall {
                id: "org.ruya.Racer".into(),
                delete_data: true
            }]
        );
        assert!(s.list_installed().is_empty());
    }

    #[test]
    fn rollback_passes_the_commit() {
        let s = store(fake().with_installed("ruyaos", "org.ruya.Racer", 1));
        assert_eq!(s.rollback("org.ruya.Racer", "abcdef123456").0, Status::Ok);
        drain(&s);
        assert_eq!(
            s.flatpak.ran(),
            [Operation::Rollback {
                id: "org.ruya.Racer".into(),
                commit: "abcdef123456".into()
            }]
        );
    }

    const FRESH: &str = r#"<components origin="flathub">
      <component type="desktop-application"><id>org.other.Tool</id><name>Other Tool</name>
        <summary>Does things</summary></component>
    </components>"#;

    #[test]
    fn appstream_refresh_gives_names_to_the_remotes_apps() {
        let s = store(
            fake()
                .with_remote("flathub", "Flathub", true)
                .with_fresh_appstream("flathub", FRESH),
        );
        assert_eq!(s.get_app("org.other.Tool").1.name, "Tool");
        s.update_appstream().unwrap();
        let app = s.get_app("org.other.Tool").1;
        assert_eq!(
            (app.name.as_str(), app.summary.as_str()),
            ("Other Tool", "Does things")
        );
        assert_eq!(s.flatpak.appstream_updates(), ["ruyaos", "flathub"]);
    }

    #[test]
    fn appstream_refresh_failure_keeps_the_catalogue() {
        let s = store(
            fake()
                .with_remote("flathub", "Flathub", true)
                .with_fresh_appstream("flathub", FRESH)
                .offline(),
        );
        let before: Vec<_> = s
            .search("", &ANY)
            .into_iter()
            .map(|a| (a.id, a.name))
            .collect();
        assert_eq!(s.update_appstream(), Ok(false));
        let after: Vec<_> = s
            .search("", &ANY)
            .into_iter()
            .map(|a| (a.id, a.name))
            .collect();
        assert_eq!(before, after);
        assert!(before
            .iter()
            .any(|(id, name)| id == "org.ruya.Racer" && name == "Turbo Racer"));
    }

    #[test]
    fn add_remote_is_for_admins_and_refuses_unsigned() {
        let s = store(fake());
        assert_eq!(
            s.add_remote("beta", "https://example.org/beta.flatpakrepo", false),
            Status::Forbidden
        );
        assert_eq!(
            s.add_remote("-x", "https://example.org/a.flatpakrepo", true),
            Status::Invalid
        );
        assert_eq!(
            s.add_remote("beta", "http://example.org/a.flatpakrepo", true),
            Status::Invalid
        );
        assert_eq!(
            s.add_remote("beta", "https://example.org/a b", true),
            Status::Invalid
        );
        assert_eq!(
            s.add_remote("beta", "https://example.org/unsigned.flatpakrepo", true),
            Status::Invalid
        );
        assert!(s.flatpak.added().is_empty());
        assert_eq!(
            s.add_remote("beta", "https://example.org/beta.flatpakrepo", true),
            Status::Ok
        );
        let names: Vec<_> = s
            .list_remotes()
            .into_iter()
            .map(|(r, t)| (r.name, t))
            .collect();
        assert_eq!(
            names,
            [
                ("ruyaos".to_owned(), "official"),
                ("beta".to_owned(), "developer")
            ]
        );
    }

    #[test]
    fn an_installed_app_no_remote_offers_is_still_listed() {
        let f = FakeFlatpak::default()
            .with_remote("ruyaos", "RuyaOS", true)
            .with_installed("old", "org.gone.Game", 10);
        let s = store(f);
        let gone = s.get_app("org.gone.Game").1;
        assert!(gone.installed);
        assert_eq!(gone.name, "Game");
        assert_eq!(gone.source, "developer");
    }

    const GAMES: &str = r#"<components origin="ruyaos">
      <component type="desktop-application"><id>org.ruya.Racer</id><name>Turbo Racer</name>
        <custom><value key="x-ruya-controller">full</value></custom></component>
      <component type="desktop-application"><id>org.ruya.Puzzle</id><name>Block Puzzle</name>
        <custom><value key="x-ruya-controller">partial</value></custom></component>
      <component type="desktop-application"><id>org.ruya.Editor</id><name>Text Editor</name>
        <custom><value key="x-ruya-controller">none</value></custom></component>
    </components>"#;

    #[test]
    fn search_options_are_parsed() {
        assert_eq!(SearchOptions::parse(None, None), Some(ANY));
        assert_eq!(SearchOptions::parse(Some("any"), Some(0)), Some(ANY));
        assert_eq!(
            SearchOptions::parse(Some("gamepad"), Some(5)),
            Some(SearchOptions {
                gamepad_only: true,
                limit: 5
            })
        );
        assert_eq!(SearchOptions::parse(Some("keyboard"), None), None);
    }

    #[test]
    fn the_controller_filter_keeps_full_and_partial_and_counts_unknown_as_none() {
        let f = FakeFlatpak::default()
            .with_remote("ruyaos", "RuyaOS", true)
            .with_app("ruyaos", "org.ruya.Racer", 1)
            .with_app("ruyaos", "org.ruya.Puzzle", 1)
            .with_app("ruyaos", "org.ruya.Editor", 1)
            .with_app("ruyaos", "org.ruya.NoMetadata", 1)
            .with_appstream("ruyaos", GAMES);
        let s = store(f);
        let gamepad = SearchOptions::parse(Some("gamepad"), None).unwrap();
        let mut ids: Vec<_> = s.search("", &gamepad).into_iter().map(|a| a.id).collect();
        ids.sort();
        assert_eq!(ids, ["org.ruya.Puzzle", "org.ruya.Racer"]);
        assert_eq!(s.search("", &ANY).len(), 4);
        assert_eq!(
            s.search("editor", &gamepad).len(),
            0,
            "the query still applies"
        );
    }

    #[test]
    fn the_limit_caps_the_result() {
        let s = store(fake());
        let two = SearchOptions::parse(None, Some(2)).unwrap();
        assert_eq!(s.search("", &two).len(), 2);
        assert_eq!(s.search("", &ANY).len(), 3, "0 means no limit");
    }

    #[test]
    fn a_job_sends_installed_changed_and_never_catalog_changed() {
        let s = store(fake());
        s.install("org.ruya.Racer");
        let events = drain(&s);
        assert!(events.contains(&Event::InstalledChanged));
        assert!(!events.contains(&Event::CatalogChanged));
    }

    #[test]
    fn sync_sends_catalog_changed_and_installed_changed_only_when_it_changed() {
        let s = Store::new(fake().with_installed("ruyaos", "org.ruya.Racer", 1));
        let mut events = Vec::new();
        s.sync(&mut |e| events.push(e));
        // First read: the installed set is new, the AppStream step changes none of it.
        assert_eq!(
            events,
            [
                Event::InstalledChanged,
                Event::CatalogChanged,
                Event::CatalogChanged
            ]
        );
        events.clear();
        s.sync(&mut |e| events.push(e));
        assert_eq!(events, [Event::CatalogChanged, Event::CatalogChanged]);
    }
}
