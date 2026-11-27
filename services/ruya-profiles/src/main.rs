//! ruya-profiles: serves org.ruyaos.Profiles1 on the system bus, as its own user `ruya-profiles`
//! with no capability (ADR-049). With `--session` (development) it serves on the session bus
//! instead and creates no Unix users. It never runs a program.

use std::error::Error;
use std::path::{Path, PathBuf};

use ruya_profiles::accounts::NoAccounts;
use ruya_profiles::dbus::{DynAccounts, ProfilesIface, BUS_NAME, OBJECT_PATH};
use ruya_profiles::service::ProfileService;
use ruya_profiles::store::{file_in, Store};

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
    // Before the store is read: no peer reaches it through /proc/<pid>/root (RUY-1130).
    ruya_profiles::process::refuse_peer_access()?;
    // RUYA_PROFILES_FILE (development) names the store file itself. In the image the directory is
    // the unit's StateDirectory, owned by ruya-profiles; a store this user cannot read (an older
    // image wrote it as root) stops the service (`Store::open`): it never starts empty.
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
