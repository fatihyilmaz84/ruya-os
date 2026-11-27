//! ruya-play: serves org.ruyaos.Play1 on the system bus (root; 05 §7). Three modes:
//!
//! - the service (default): the importer over `/var/lib/ruya-play`, its unprivileged helper as a
//!   transient systemd unit per run, and the Flatpak commit;
//! - `--helper`: the helper itself, started by the service inside its unit (05 §7.3): one request
//!   on standard input, JSON Lines on standard output;
//! - `--session` (development): the session bus, an in-process helper, state under
//!   `RUYA_PLAY_ROOT` (else a folder in the temporary directory), a commit that only logs, and
//!   every caller counts as an admin.

use std::error::Error;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Duration;

use ruya_play::core::deps::{NoHooks, RuyaPlayArt, SystemClock};
use ruya_play::core::helper::{self, HelperDeps};
use ruya_play::core::reconcile;
use ruya_play::dbus::{forward, PlayIface, Signal, BUS_NAME, OBJECT_PATH};
use ruya_play::service::{gates, sources, Environment, SystemEnvironment};
use ruya_play::{
    Commit, CommitError, CommitRequest, Config, Deps, Helper, Importer, Phase, RecommitRequest,
    Recommitted,
};
use ruya_play_trust::{FileTrustStore, StoreKeys};

/// The service's state (05 §7.1).
const ROOT: &str = "/var/lib/ruya-play";
/// The system Flatpak installation.
const FLATPAK: &str = "/var/lib/flatpak";
/// `staging/` and `inspect/` (root, 0700): on the mount of the helpers' state folders, which
/// are renamed into them (RUY-866, `Config::with_work`). Not `ruya-play-helper-*`, so the
/// helpers' leftover sweep never removes it.
const WORK: &str = "/var/lib/private/ruya-play-work";
/// A copy of each `Inspect`'s vetted art for the shell (root:ruya-shell 0750, created by
/// tmpfiles.d; RUY-1038, `Config::with_publish`). On `/run`, not on the work mount, so it is copied.
const PUBLISH: &str = "/run/ruya-play/inspect";
/// How often the mounts are looked at for `SourcesChanged`.
const MOUNT_POLL: Duration = Duration::from_secs(2);

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "--helper") {
        std::process::exit(helper_main());
    }
    if let Some(i) = args.iter().position(|a| a == "--helper-argv") {
        // For vm-play-check.sh: the helper unit's command line for a probe job reading `source`,
        // one argument per line, so the check can start the same sandbox around a probe.
        std::process::exit(print_helper_argv(args.get(i + 1).map(String::as_str)));
    }
    let session = args.iter().any(|a| a == "--session");
    if let Err(err) = run(session) {
        eprintln!("ruya-play: fatal: {err}");
        std::process::exit(1);
    }
}

/// The pinned store keys: none ship yet, so no package is `official` (05 §9.2).
fn store_keys() -> StoreKeys {
    StoreKeys::none()
}

fn helper_deps(in_unit: bool) -> HelperDeps {
    let opener: Box<dyn ruya_play::Opener> = {
        #[cfg(target_os = "linux")]
        {
            if in_unit {
                Box::new(ruya_play::service::fd_source::PassedFdOpener)
            } else {
                Box::new(ruya_play::core::opener::DiskOpener)
            }
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = in_unit;
            Box::new(ruya_play::core::opener::DiskOpener)
        }
    };
    HelperDeps {
        opener,
        art: Box::new(RuyaPlayArt),
        store_keys: store_keys(),
        hooks: Box::new(NoHooks),
    }
}

/// `--helper`: one request from standard input.
fn helper_main() -> i32 {
    let deps = helper_deps(true);
    let cancel = AtomicBool::new(false);
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    helper::serve(&mut stdin.lock(), &mut stdout.lock(), &deps, &cancel)
}

fn print_helper_argv(source: Option<&str>) -> i32 {
    let Some(source) = source else {
        eprintln!("usage: ruya-play --helper-argv <source path>");
        return 2;
    };
    let request = helper::Request {
        mode: helper::Mode::Install,
        job: "probe".into(),
        source: source.into(),
        staging: String::new(),
        now: 0,
        developer_mode: false,
        blocklist: None,
        art: false,
        official: false,
        expect: Default::default(),
    };
    let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("/usr/bin/ruya-play"));
    let name = ruya_play::core::systemd_run::fd_name(0, 0);
    match ruya_play::core::systemd_run::argv(&exe, &request, &name) {
        Some(v) => {
            for a in v {
                println!("{a}");
            }
            0
        }
        None => {
            eprintln!("ruya-play: that source cannot be passed to a helper unit");
            1
        }
    }
}

/// The development commit: logs what a console would install.
struct LoggedCommit;

impl Commit for LoggedCommit {
    fn commit(
        &self,
        request: &CommitRequest<'_>,
        progress: &mut dyn FnMut(Phase, f32),
    ) -> Result<(), CommitError> {
        progress(Phase::Committing, 1.0);
        eprintln!(
            "ruya-play --session: would commit play.{} from {}",
            request.manifest.id,
            request.tree.display()
        );
        progress(Phase::Installing, 1.0);
        Ok(())
    }

    fn recommit(&self, request: &RecommitRequest<'_>) -> Result<(), CommitError> {
        eprintln!(
            "ruya-play --session: would commit play.{} again from {}",
            request.manifest.id,
            request.files.display()
        );
        Ok(())
    }

    fn uninstall(&self, id: &str) -> Result<(), CommitError> {
        eprintln!("ruya-play --session: would uninstall play.{id}");
        Ok(())
    }

    // Nothing is committed in this mode, so nothing is kept: GetPrevious answers no-previous.
    fn keep_previous(&self, id: &str) -> Result<bool, CommitError> {
        eprintln!("ruya-play --session: would keep the deployed build of play.{id}");
        Ok(false)
    }

    // Nothing is committed, so nothing is kept: a rollback in this mode fails `commit.failed`.
    fn previous_file(&self, _id: &str, _name: &str) -> Result<Vec<u8>, CommitError> {
        Err(CommitError::Failed("--session keeps no builds".into()))
    }

    fn check_out_previous(&self, _id: &str, _dest: &Path) -> Result<(), CommitError> {
        Err(CommitError::Failed("--session keeps no builds".into()))
    }

    fn drop_previous(&self, id: &str) -> Result<(), CommitError> {
        eprintln!("ruya-play --session: would forget the kept build of play.{id}");
        Ok(())
    }
}

/// The image's blocklist; `--session` may point `RUYA_PLAY_BLOCKLIST` at a copy.
fn blocklist_path(session: bool) -> PathBuf {
    match std::env::var_os("RUYA_PLAY_BLOCKLIST") {
        Some(p) if session => PathBuf::from(p),
        _ => PathBuf::from(ruya_play_trust::revocation::IMAGE_BLOCKLIST_PATH),
    }
}

fn root_dir(session: bool) -> PathBuf {
    if !session {
        return PathBuf::from(ROOT);
    }
    std::env::var_os("RUYA_PLAY_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("ruya-play-session"))
}

fn helper_for(session: bool, env: Arc<dyn Environment>) -> Box<dyn Helper> {
    if session {
        return Box::new(ruya_play::InProcessHelper::new(helper_deps(false)));
    }
    #[cfg(target_os = "linux")]
    {
        let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("/usr/bin/ruya-play"));
        Box::new(ruya_play::service::GatedHelper::new(
            ruya_play::core::systemd_run::SystemdRunHelper { exe },
            env,
        ))
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = env;
        Box::new(ruya_play::InProcessHelper::new(helper_deps(false)))
    }
}

fn commit_for(session: bool, root: &Path) -> Box<dyn Commit> {
    if session {
        return Box::new(LoggedCommit);
    }
    Box::new(ruya_play::service::commit::FlatpakCommit::new(
        root,
        Box::new(ruya_play::service::commit::CommandRunner),
    ))
}

fn free_space() -> Box<dyn ruya_play::FreeSpace> {
    #[cfg(unix)]
    {
        Box::new(ruya_play::core::deps::StatvfsFreeSpace)
    }
    #[cfg(not(unix))]
    {
        Box::new(ruya_play::core::fakes::FixedFreeSpace::new(u64::MAX))
    }
}

/// Start-up (05 §7.3, RUY-829): the journal's failed rollbacks go to the log, and the committed
/// `play.*` apps are reconciled with the records before any install can run. Returns the ids the
/// reconcile wants committed again ([`recommit`]).
fn start_up(importer: &Importer, cfg: &Config, session: bool) -> Vec<String> {
    if let Ok(journal) = std::fs::read_to_string(cfg.journal_file()) {
        for line in reconcile::rollback_failures(&journal) {
            eprintln!("ruya-play: {line}");
        }
    }
    if session {
        return Vec::new();
    }
    // Fail closed: when the installed apps cannot be listed or the records cannot be read, every
    // install is refused (installed.unreconciled) until a restart reconciles them.
    match importer.reconcile_listed(reconcile::deployed_apps(Path::new(FLATPAK))) {
        Ok(actions) => {
            for a in &actions {
                eprintln!("ruya-play: reconcile: {a:?}");
            }
            actions
                .into_iter()
                .filter_map(|a| match a {
                    reconcile::Action::Recommit { id } => Some(id),
                    _ => None,
                })
                .collect()
        }
        Err(p) => {
            eprintln!(
                "ruya-play: reconcile failed ({}); every install is refused until the service restarts",
                p.message
            );
            Vec::new()
        }
    }
}

/// The reconcile's re-commits (ADR-038), on a thread of their own once the bus name is taken: each
/// can take as long as a commit, and they wait for a running job (and a job for one of them
/// waits) like any job. A failure is logged and tried again at the next start.
fn recommit(importer: Arc<Importer>, ids: Vec<String>) {
    if ids.is_empty() {
        return;
    }
    std::thread::spawn(move || {
        for id in ids {
            match importer.recommit(&id) {
                Ok(Recommitted::Done) => eprintln!("ruya-play: recommitted play.{id}"),
                Ok(Recommitted::NotNeeded) => eprintln!("ruya-play: play.{id} needed no recommit"),
                Ok(Recommitted::Widens(added)) => eprintln!(
                    "ruya-play: play.{id} not recommitted: it would add {added:?} to the app's grants"
                ),
                Ok(Recommitted::MetadataUnreadable) => eprintln!(
                    "ruya-play: play.{id} not recommitted: its deployed metadata cannot be read safely"
                ),
                Err(p) => eprintln!(
                    "ruya-play: play.{id} could not be recommitted ({}: {}); it stays as it was",
                    p.code, p.message
                ),
            }
        }
    });
}

/// Sends `SourcesChanged` when the set of safe removable mounts changes.
fn watch_mounts(env: Arc<dyn Environment>, events: async_channel::Sender<Signal>) {
    std::thread::spawn(move || {
        let points = |env: &dyn Environment| -> Vec<PathBuf> {
            sources::media_mounts(&gates::parse_mountinfo(&env.mountinfo()))
                .into_iter()
                .map(|m| m.point)
                .collect()
        };
        let mut seen = points(&*env);
        loop {
            std::thread::sleep(MOUNT_POLL);
            let now = points(&*env);
            if now != seen {
                seen = now;
                let _ = events.send_blocking(Signal::SourcesChanged);
            }
        }
    });
}

fn run(session: bool) -> Result<(), Box<dyn Error>> {
    let root = root_dir(session);
    std::fs::create_dir_all(&root)?;
    let env: Arc<dyn Environment> = Arc::new(SystemEnvironment);
    let mut cfg = Config::under(&root);
    if !session {
        let gid = env
            .shell_gid()
            .ok_or("the group ruya-shell is not in /etc/group")?;
        cfg = cfg
            .with_work(Path::new(WORK))
            .with_publish(Path::new(PUBLISH), gid);
    }
    cfg.flatpak = PathBuf::from(FLATPAK);
    std::fs::create_dir_all(&cfg.state)?;
    let trust = FileTrustStore::open(root.join("trust.json")).map_err(|e| e.message())?;
    let installed =
        ruya_play::core::installed::FileInstalled::open(cfg.state.join("installed.json"))
            .map_err(|p| p.message)?;
    let deps = Deps {
        helper: helper_for(session, env.clone()),
        free_space: free_space(),
        commit: commit_for(session, &root),
        clock: Box::new(SystemClock),
        blocklists: Box::new(ruya_play::core::deps::ImageBlocklist {
            path: blocklist_path(session),
        }),
        store_keys: store_keys(),
        trust: Box::new(trust),
        installed: Box::new(installed),
        hooks: Box::new(NoHooks),
    };
    let importer = Importer::open(cfg.clone(), deps).map_err(|p| p.message)?;
    let recommits = start_up(&importer, &cfg, session);
    let importer = Arc::new(importer);
    let recommitter = importer.clone();
    let (events, receiver) = async_channel::unbounded();
    watch_mounts(env.clone(), events.clone());
    futures_lite::future::block_on(async {
        let builder = if session {
            zbus::connection::Builder::session()?
        } else {
            zbus::connection::Builder::system()?
        };
        let connection = builder
            .name(BUS_NAME)?
            .serve_at(OBJECT_PATH, PlayIface::new(importer, env, events, session))?
            .build()
            .await?;
        eprintln!("ruya-play: serving {BUS_NAME}");
        recommit(recommitter, recommits);
        forward(connection, receiver).await;
        Ok::<(), Box<dyn Error>>(())
    })
}
