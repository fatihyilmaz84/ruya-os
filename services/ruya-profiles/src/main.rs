//! ruya-profiles: serves org.ruyaos.Profiles1 on the system bus, as its own user `ruya-profiles`
//! with no capability (ADR-049). With `--session` (development) it serves on the session bus
//! instead and creates no Unix users. With `--migrate` (the unit's `ExecStartPre=+`, as root) it
//! only moves an earlier image's store into its directory and hands that directory to the
//! service's user, then exits. It never runs a program.

use std::error::Error;
use std::path::{Path, PathBuf};

use ruya_profiles::accounts::NoAccounts;
use ruya_profiles::dbus::{DynAccounts, ProfilesIface, BUS_NAME, OBJECT_PATH};
use ruya_profiles::service::ProfileService;
use ruya_profiles::store::{file_in, rollback_path, Migration, Store, STORE_FILE};

/// The state directory: the store is `profiles/profiles.toml` in it (`store::file_in`, RUY-1130).
const STATE_DIR: &str = "/var/lib/ruyaos";

fn main() {
    if let Err(err) = run() {
        eprintln!("ruya-profiles: fatal: {err}");
        std::process::exit(1);
    }
}

fn system_accounts(session: bool) -> DynAccounts {
    #[cfg(target_os = "linux")]
    if !session {
        return Box::new(ruya_profiles::accounts::HelperAccounts::default());
    }
    let _ = session;
    Box::new(NoAccounts)
}

fn run() -> Result<(), Box<dyn Error>> {
    let session = std::env::args().any(|a| a == "--session");
    // Before the store is read: no peer reaches it through /proc/<pid>/root (RUY-1130), also not
    // in the root migration step.
    ruya_profiles::process::refuse_peer_access()?;
    if std::env::args().any(|a| a == "--migrate") {
        return migrate(Path::new(STATE_DIR));
    }
    // RUYA_PROFILES_FILE (development) names the store file itself.
    let path = match std::env::var_os("RUYA_PROFILES_FILE") {
        Some(file) => PathBuf::from(file),
        None => file_in(Path::new(STATE_DIR)),
    };
    let store = Store::open(path)?;
    eprintln!(
        "ruya-profiles: {} profile(s) from {}",
        store.profiles().len(),
        store.path().display()
    );
    let iface = ProfilesIface::new(ProfileService::new(store, system_accounts(session)));

    futures_lite::future::block_on(async {
        let builder = if session {
            zbus::connection::Builder::session()?
        } else {
            zbus::connection::Builder::system()?
        };
        let _connection = builder
            .name(BUS_NAME)?
            .serve_at(OBJECT_PATH, iface)?
            .build()
            .await?;
        std::future::pending::<()>().await;
        Ok::<(), Box<dyn Error>>(())
    })
}

/// The root step before the service starts: moves an earlier image's store into its directory
/// (`Store::open_in`, RUY-1130), then hands the directory and its files to the service's user
/// (`store::hand_over`, ADR-049). Both are idempotent: every start runs them.
fn migrate(state: &Path) -> Result<(), Box<dyn Error>> {
    let (store, migration) = Store::open_in(state)?;
    let old = state.join(STORE_FILE);
    match migration {
        Migration::Nothing => {}
        Migration::Moved => eprintln!("ruya-profiles: moved the store from {}", old.display()),
        Migration::OldRemoved => eprintln!(
            "ruya-profiles: removed {}, the same as the store",
            old.display()
        ),
        Migration::OldKept => eprintln!(
            "ruya-profiles: {} differs from the store (written by an older image after a \
             rollback); the store wins, nothing is merged, the old file is kept as {}",
            old.display(),
            rollback_path(store.path()).display()
        ),
    }
    hand_to_service_user(store.path())
}

#[cfg(unix)]
fn hand_to_service_user(store: &Path) -> Result<(), Box<dyn Error>> {
    use ruya_accounts::wire::PEER_USER;
    let Some(dir) = store.parent() else {
        return Err(format!("{} has no directory", store.display()).into());
    };
    let owner = ruya_users::passwd_of(PEER_USER)
        .map_err(std::io::Error::from_raw_os_error)?
        .ok_or_else(|| format!("no user {PEER_USER} (sysusers.d/ruyaos.conf)"))?;
    let handed = ruya_profiles::store::hand_over(dir, &mut |path| {
        std::os::unix::fs::lchown(path, Some(owner.uid), Some(owner.gid))
    })?;
    eprintln!(
        "ruya-profiles: {} and {} file(s) in it belong to {PEER_USER}",
        dir.display(),
        handed.len() - 1
    );
    Ok(())
}

#[cfg(not(unix))]
fn hand_to_service_user(_store: &Path) -> Result<(), Box<dyn Error>> {
    Err("--migrate runs only in the image".into())
}
