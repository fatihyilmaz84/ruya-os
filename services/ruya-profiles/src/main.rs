//! ruya-profiles: serves org.ruyaos.Profiles1 on the system bus. With `--session` (development)
//! it serves on the session bus instead and creates no Unix users.

use std::error::Error;
use std::path::{Path, PathBuf};

use ruya_profiles::accounts::NoAccounts;
use ruya_profiles::dbus::{DynAccounts, ProfilesIface, BUS_NAME, OBJECT_PATH};
use ruya_profiles::service::ProfileService;
use ruya_profiles::store::{rollback_path, Migration, Store, STORE_FILE};

/// The state directory: the store is `profiles/profiles.toml` in it (`Store::open_in`, RUY-1130).
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
        return Box::new(ruya_profiles::accounts::UnixAccounts);
    }
    let _ = session;
    Box::new(NoAccounts)
}

fn run() -> Result<(), Box<dyn Error>> {
    let session = std::env::args().any(|a| a == "--session");
    // Before the store is read: no peer reaches it through /proc/<pid>/root (RUY-1130).
    ruya_profiles::process::refuse_peer_access()?;
    // RUYA_PROFILES_FILE (development) names the store file itself: nothing is moved.
    let store = match std::env::var_os("RUYA_PROFILES_FILE") {
        Some(file) => Store::open(PathBuf::from(file))?,
        None => {
            let state = Path::new(STATE_DIR);
            let (store, migration) = Store::open_in(state)?;
            let old = state.join(STORE_FILE);
            match migration {
                Migration::Nothing => {}
                Migration::Moved => {
                    eprintln!("ruya-profiles: moved the store from {}", old.display())
                }
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
            store
        }
    };
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
