//! ruya-profiles: serves org.ruyaos.Profiles1 on the system bus (or the session bus with
//! `--session`, for development).

use std::error::Error;
use std::path::PathBuf;

use ruya_profiles::dbus::{ProfilesIface, SystemAccounts, BUS_NAME, OBJECT_PATH};
use ruya_profiles::service::ProfileService;
use ruya_profiles::store::Store;

const DEFAULT_STORE: &str = "/var/lib/ruyaos/profiles.toml";

fn main() {
    if let Err(err) = run() {
        eprintln!("ruya-profiles: fatal: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let session = std::env::args().any(|a| a == "--session");
    let path = std::env::var_os("RUYA_PROFILES_FILE")
        .map_or_else(|| PathBuf::from(DEFAULT_STORE), PathBuf::from);
    let store = Store::open(&path)?;
    eprintln!(
        "ruya-profiles: {} profile(s) from {}",
        store.profiles().len(),
        path.display()
    );
    let iface = ProfilesIface::new(ProfileService::new(store, SystemAccounts::default()));

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
