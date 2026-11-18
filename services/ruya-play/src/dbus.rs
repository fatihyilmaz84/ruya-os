//! org.ruyaos.Play1 on D-Bus (RUY-829). Thin adapter: the rules live in the importer core and in
//! [`crate::service::gates`]. Jobs run on their own thread (the helper and Flatpak block); their
//! events come back over a channel and become signals here, in order.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use async_channel::{Receiver, Sender};
use ruya_play_trust::{Continuity, Risk};
use zbus::message::Header;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedValue, Value};
use zbus::{fdo, interface, Connection};

use crate::core::art::VettedArt;
use crate::core::importer::{Event, Importer, InspectReport};
use crate::core::jobs::{JobRecord, JobState};
use crate::core::status::{JobStatus, MethodStatus};
use crate::service::{gates, sources, Environment};

/// The bus name.
pub const BUS_NAME: &str = "org.ruyaos.Play1";
/// The object path.
pub const OBJECT_PATH: &str = "/org/ruyaos/Play1";

/// A job starts this long after its method returned, so the reply is on the wire before the first
/// `JobProgress` (the Store's rule).
const START_DELAY: Duration = Duration::from_millis(100);

/// What the job thread and the watchers want sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Signal {
    /// `JobProgress`.
    Progress {
        /// The job.
        job: String,
        /// 0-100.
        percent: u32,
        /// The phase word.
        phase: String,
    },
    /// `JobFinished`.
    Finished {
        /// The job.
        job: String,
        /// The status word.
        status: String,
    },
    /// `SourcesChanged`.
    SourcesChanged,
    /// `DeveloperModeChanged`.
    DeveloperModeChanged(bool),
}

// Sorted keys: replies read the same every time (a{sv} has no order; clients must not rely on it).
type Dict = BTreeMap<String, OwnedValue>;

fn dict(entries: Vec<(&str, Value<'_>)>) -> Dict {
    entries
        .into_iter()
        .filter_map(|(k, v)| OwnedValue::try_from(v).ok().map(|v| (k.to_owned(), v)))
        .collect()
}

/// A bool option: absent is `false`, another type is `None` (`invalid`).
fn bool_option(options: &HashMap<String, OwnedValue>, key: &str) -> Option<bool> {
    match options.get(key).map(|v| &**v) {
        None => Some(false),
        Some(Value::Bool(b)) => Some(*b),
        Some(_) => None,
    }
}

/// The source record of one candidate.
pub fn source_record(c: &sources::Candidate) -> Dict {
    dict(vec![
        ("drive", Value::from(c.drive.clone())),
        ("drive_label", Value::from(c.drive_label.clone())),
        ("path", Value::from(c.path.to_string_lossy().into_owned())),
        ("name", Value::from(c.name.clone())),
        ("kind", Value::from(c.kind.to_string())),
        ("size", Value::from(c.size)),
    ])
}

/// The job record of `ListJobs`.
pub fn job_record(r: &JobRecord) -> Dict {
    let status = match (r.state, r.status) {
        (JobState::Finished, Some(s)) => s.as_str(),
        _ => "",
    };
    dict(vec![
        ("id", Value::from(r.job.clone())),
        ("kind", Value::from(r.kind.as_str().to_string())),
        ("path", Value::from(r.path.clone())),
        ("app", Value::from(r.app.clone())),
        ("state", Value::from(r.state.as_str().to_string())),
        ("status", Value::from(status.to_string())),
        ("reason", Value::from(r.reason().to_string())),
        ("percent", Value::from(r.percent.min(100))),
        ("phase", Value::from(r.phase.as_str().to_string())),
    ])
}

fn english(map: &BTreeMap<String, String>) -> Option<String> {
    map.get("en").or_else(|| map.values().next()).cloned()
}

fn risk_word(r: Risk) -> &'static str {
    match r {
        Risk::Low => "low",
        Risk::Medium => "medium",
        Risk::High => "high",
    }
}

/// The plain words of 05 §8 for a request, in English (the shell translates by key). The same
/// table as `ruya-pack inspect`'s.
pub fn plain_words(key: &str, value: &str) -> &'static str {
    match (key, value) {
        ("input", "controllers") => "Uses controllers",
        ("input", "controllers+keyboard-mouse") => "Uses controllers and keyboard and mouse",
        ("input", "all-devices") => "Accesses all devices",
        ("network", _) => "Uses the network",
        ("removable_media", "read") => "Reads files on USB drives",
        ("removable_media", "write") => "Changes files on USB drives",
        ("multiarch", _) => "Runs 32-bit programs",
        ("gamemode" | "realtime", _) => "Asks the system to prioritise it",
        ("devel", _) => "Can inspect other programs",
        ("network+removable_media", _) => "Uses the network and reaches USB drives",
        _ => "Asks for a permission",
    }
}

/// The record's permission key: the vocabulary key, with its value when it is not a bool
/// (`input:controllers`, `removable_media:read`, `network`, `network+removable_media`).
fn permission_key(key: &str, value: &str) -> String {
    if value.is_empty() || value == "true" {
        key.to_string()
    } else {
        format!("{key}:{value}")
    }
}

/// Play1's `art` (role -> file) and `screenshots` from the vetted art (the rules are
/// `ruya_play_art::art_roles`, shared with Library1).
pub fn art_roles(art: &[VettedArt]) -> (BTreeMap<String, String>, Vec<String>) {
    ruya_play_art::art_roles(art.iter().map(|s| (s.lang.as_deref(), s.files.as_slice())))
}

/// Play1's Inspect record. Optional keys are absent when unknown (`age_label`: the manifest
/// declares an OARS map, not a label, so it is absent; `signer_name`: a signature carries a key,
/// not a name).
pub fn inspect_record(report: &InspectReport) -> Dict {
    let mut e: Vec<(&str, Value<'_>)> = Vec::new();
    e.push(("verdict", Value::from(report.verdict.as_str().to_string())));
    e.push(("revoked", Value::from(report.verdict == JobStatus::Revoked)));
    let unsupported = report.verdict == JobStatus::Unsupported;
    e.push((
        "requirement",
        Value::from(if unsupported { "unsupported" } else { "ok" }.to_string()),
    ));
    let problems: Vec<(String, String, String)> = report
        .problems
        .iter()
        .map(|p| (p.code.clone(), p.path.clone(), p.message.clone()))
        .collect();
    e.push(("problems", Value::from(problems)));
    if let Some(b) = report.installed_build {
        e.push((
            "installed_build",
            Value::from(u32::try_from(b).unwrap_or(u32::MAX)),
        ));
    }
    if report.verdict == JobStatus::DifferentDeveloper {
        e.push(("key_state", Value::from("different".to_string())));
    }
    if let Some(insp) = &report.inspection {
        let m = &insp.package.manifest;
        e.push(("id", Value::from(m.id.clone())));
        if let Some(n) = english(&m.name) {
            e.push(("name", Value::from(n)));
        }
        if let Some(s) = m.summary.as_ref().and_then(english) {
            e.push(("summary", Value::from(s)));
        }
        e.push(("version", Value::from(m.version.clone())));
        e.push((
            "build",
            Value::from(u32::try_from(m.build).unwrap_or(u32::MAX)),
        ));
        if let Some(d) = &m.developer {
            e.push(("developer", Value::from(d.name.clone())));
        }
        e.push(("genres", Value::from(m.genres.clone())));
        if let Some(p) = &m.players {
            let text = if p.min == p.max {
                p.min.to_string()
            } else {
                format!("{}-{}", p.min, p.max)
            };
            e.push(("players", Value::from(text)));
        }
        if let Some(c) = &m.controller {
            e.push(("controller", Value::from(c.clone())));
        }
        e.push(("size", Value::from(insp.package.installed_bytes)));
        e.push(("tier", Value::from(insp.tier.tier.as_str().to_string())));
        if let Some(key) = insp.signatures.key() {
            e.push(("signer_key_id", Value::from(key.key_id())));
        }
        let key_state = match insp.continuity {
            Continuity::FirstSight { .. } => Some("new"),
            Continuity::SameKey | Continuity::Rotated { .. } => Some("same"),
            Continuity::Unsigned => None,
        };
        if let Some(k) = key_state {
            e.retain(|(name, _)| *name != "key_state");
            e.push(("key_state", Value::from(k.to_string())));
        }
        let perms: Vec<(String, String, String)> = insp
            .assessment
            .requests
            .iter()
            .map(|r| {
                (
                    permission_key(&r.key, &r.value),
                    plain_words(&r.key, &r.value).to_string(),
                    risk_word(r.risk).to_string(),
                )
            })
            .collect();
        e.push(("permissions", Value::from(perms)));
    }
    let (roles, shots) = art_roles(&report.art);
    if !report.art.is_empty() {
        e.push((
            "art",
            Value::from(roles.into_iter().collect::<HashMap<_, _>>()),
        ));
        e.push(("screenshots", Value::from(shots)));
    }
    dict(e)
}

/// The D-Bus object.
pub struct PlayIface {
    importer: Arc<Importer>,
    env: Arc<dyn Environment>,
    events: Sender<Signal>,
    /// Development (`--session`): every caller is an admin.
    everyone_admin: bool,
}

impl PlayIface {
    /// The object over `importer`.
    pub fn new(
        importer: Arc<Importer>,
        env: Arc<dyn Environment>,
        events: Sender<Signal>,
        everyone_admin: bool,
    ) -> Self {
        PlayIface {
            importer,
            env,
            events,
            everyone_admin,
        }
    }

    /// Runs queued jobs on a thread until none is left (a second thread waits for the first).
    fn kick(&self) {
        let importer = self.importer.clone();
        let events = self.events.clone();
        std::thread::spawn(move || {
            std::thread::sleep(START_DELAY);
            while importer
                .run_next(&mut |event| {
                    let signal = match event {
                        Event::Progress {
                            job,
                            percent,
                            phase,
                            ..
                        } => Signal::Progress {
                            job,
                            percent,
                            phase: phase.as_str().to_string(),
                        },
                        Event::Finished { job, status } => Signal::Finished {
                            job,
                            status: status.as_str().to_string(),
                        },
                    };
                    let _ = events.send_blocking(signal);
                })
                .is_some()
            {}
        });
    }

    /// Does the caller's `admin_approved` count (Play1.xml's trust boundary)?
    async fn admin(&self, approved: bool, header: &Header<'_>, connection: &Connection) -> bool {
        if !approved {
            return false;
        }
        if self.everyone_admin {
            return true;
        }
        let caller = match (header.sender(), fdo::DBusProxy::new(connection).await) {
            (Some(sender), Ok(bus)) => bus
                .get_connection_unix_user(sender.clone().into())
                .await
                .ok(),
            _ => None,
        };
        gates::admin_counts(approved, caller, self.env.shell_uid(), false)
    }

    fn send(&self, signal: Signal) {
        let _ = self.events.try_send(signal);
    }
}

#[interface(name = "org.ruyaos.Play1")]
impl PlayIface {
    /// Candidate packages on mounted removable drives (names only).
    async fn list_sources(&self) -> Vec<Dict> {
        let env = self.env.clone();
        blocking::unblock(move || {
            let mounts = gates::parse_mountinfo(&env.mountinfo());
            sources::list(&mounts).iter().map(source_record).collect()
        })
        .await
    }

    /// Look inside one candidate.
    #[zbus(out_args("status", "info"))]
    async fn inspect(&self, path: String) -> (String, Dict) {
        let gated = {
            let env = self.env.clone();
            let incoming = self.importer.config().incoming.clone();
            let path = path.clone();
            blocking::unblock(move || gate_with(&*env, &incoming, &path)).await
        };
        let p = match gated {
            Ok(p) => p,
            Err(s) => return (s.as_str().to_string(), Dict::new()),
        };
        let importer = self.importer.clone();
        let (status, report) = blocking::unblock(move || importer.inspect(&p)).await;
        match report {
            Some(r) if status == MethodStatus::Ok => {
                (status.as_str().to_string(), inspect_record(&r))
            }
            _ => (status.as_str().to_string(), Dict::new()),
        }
    }

    /// Queue an install.
    #[zbus(out_args("status", "job"))]
    async fn install(
        &self,
        path: String,
        options: HashMap<String, OwnedValue>,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
    ) -> (String, String) {
        let Some(approved) = bool_option(&options, "admin_approved") else {
            return (MethodStatus::Invalid.as_str().to_string(), String::new());
        };
        if !self.admin(approved, &header, connection).await {
            return (MethodStatus::Forbidden.as_str().to_string(), String::new());
        }
        let gated = {
            let env = self.env.clone();
            let incoming = self.importer.config().incoming.clone();
            blocking::unblock(move || gate_with(&*env, &incoming, &path)).await
        };
        let p = match gated {
            Ok(p) => p,
            Err(s) => return (s.as_str().to_string(), String::new()),
        };
        let (status, job) = self.importer.queue_install(&p, true);
        if status == MethodStatus::Ok {
            self.kick();
        }
        (status.as_str().to_string(), job)
    }

    /// Queue a re-hash of an installed package against its `play.files`.
    #[zbus(out_args("status", "job"))]
    async fn verify(&self, app_id: String) -> (String, String) {
        let Some(id) = app_id.strip_prefix("play.").filter(|id| !id.is_empty()) else {
            let s = if app_id.is_empty() {
                MethodStatus::Invalid
            } else {
                MethodStatus::UnknownApp
            };
            return (s.as_str().to_string(), String::new());
        };
        let (status, job) = self.importer.queue_verify(id);
        if status == MethodStatus::Ok {
            self.kick();
        }
        (status.as_str().to_string(), job)
    }

    /// Stop a queued or running job.
    async fn cancel(&self, job: String) -> String {
        self.importer.cancel(&job).as_str().to_string()
    }

    /// Developer mode.
    async fn get_developer_mode(&self) -> bool {
        self.importer.developer_mode().unwrap_or(false)
    }

    /// Change developer mode (an admin's).
    async fn set_developer_mode(
        &self,
        on: bool,
        options: HashMap<String, OwnedValue>,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
    ) -> String {
        let Some(approved) = bool_option(&options, "admin_approved") else {
            return MethodStatus::Invalid.as_str().to_string();
        };
        if !self.admin(approved, &header, connection).await {
            return MethodStatus::Forbidden.as_str().to_string();
        }
        let before = self.importer.developer_mode().ok();
        match self.importer.set_developer_mode(on) {
            Ok(()) => {
                if before != Some(on) {
                    self.send(Signal::DeveloperModeChanged(on));
                }
                MethodStatus::Ok.as_str().to_string()
            }
            Err(p) => {
                eprintln!("ruya-play: developer mode: {}", p.message);
                MethodStatus::Failed.as_str().to_string()
            }
        }
    }

    /// The job table.
    async fn list_jobs(&self) -> Vec<Dict> {
        self.importer.list_jobs().iter().map(job_record).collect()
    }

    #[zbus(signal)]
    async fn developer_mode_changed(emitter: &SignalEmitter<'_>, on: bool) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn job_progress(
        emitter: &SignalEmitter<'_>,
        job: String,
        percent: u32,
        phase: String,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn job_finished(
        emitter: &SignalEmitter<'_>,
        job: String,
        status: String,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn sources_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

/// The source gate (RUY-829): a plain absolute path that `ListSources` lists now (or a download in
/// `incoming/`), on a drive mounted `nosuid,nodev,noexec`; else the status to answer.
fn gate_with(env: &dyn Environment, incoming: &Path, path: &str) -> Result<PathBuf, MethodStatus> {
    let p = PathBuf::from(path);
    if !gates::is_plain_absolute(&p) {
        return Err(MethodStatus::Invalid);
    }
    let mounts = gates::parse_mountinfo(&env.mountinfo());
    if p.starts_with(sources::MEDIA_ROOT) && !gates::mount_is_safe_for(&mounts, &p) {
        eprintln!("ruya-play: refused a path on a drive that is not mounted nosuid,nodev,noexec");
        return Err(MethodStatus::UnknownSource);
    }
    let candidates: Vec<PathBuf> = sources::list(&mounts).into_iter().map(|c| c.path).collect();
    if !gates::source_allowed(&p, &candidates, incoming) {
        return Err(MethodStatus::UnknownSource);
    }
    Ok(p)
}

/// Turns the signals of the job thread and the watchers into D-Bus signals, in order. Runs
/// forever.
pub async fn forward(connection: Connection, signals: Receiver<Signal>) {
    while let Ok(signal) = signals.recv().await {
        let sent = async {
            let iface = connection
                .object_server()
                .interface::<_, PlayIface>(OBJECT_PATH)
                .await?;
            let emitter = iface.signal_emitter();
            match signal {
                Signal::Progress {
                    job,
                    percent,
                    phase,
                } => PlayIface::job_progress(emitter, job, percent, phase).await,
                Signal::Finished { job, status } => {
                    PlayIface::job_finished(emitter, job, status).await
                }
                Signal::SourcesChanged => PlayIface::sources_changed(emitter).await,
                Signal::DeveloperModeChanged(on) => {
                    PlayIface::developer_mode_changed(emitter, on).await
                }
            }
        }
        .await;
        if let Err(err) = sent {
            eprintln!("ruya-play: emitting a signal failed: {err}");
        }
    }
}
