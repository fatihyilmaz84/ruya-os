//! ruya-platform: serves org.ruyaos.Platform1 on the system bus, as root, with the player's
//! permissions in one root-only file per profile under /var/lib/ruyaos/platform/profiles. With
//! `--session` (development) it serves on the session bus, keeps its files in the temporary
//! directory and does not check who calls Manage. `RUYA_PLATFORM_DIR` overrides the directory.
//! Off Linux nobody can be identified, so every app call is refused.

use std::error::Error;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ruya_platform::dbus::{
    watch_names, watch_profiles, Checks, LifecycleIface, ManageIface, Shared, BUS_NAME, OBJECT_PATH,
};
use ruya_platform::identity::{Procfs, Users};
use ruya_platform::procfs::SystemUsers;
use ruya_platform::registry::Registry;
use ruya_platform::store::Store;
use ruya_platform::Platform;

const DEFAULT_DIR: &str = "/var/lib/ruyaos/platform";

fn main() {
    if let Err(err) = run() {
        eprintln!("ruya-platform: fatal: {err}");
        std::process::exit(1);
    }
}

fn readers() -> (Box<dyn Procfs>, Box<dyn Users>) {
    #[cfg(target_os = "linux")]
    return (
        Box::new(ruya_platform::procfs::LinuxProcfs),
        Box::new(SystemUsers),
    );
    #[cfg(not(target_os = "linux"))]
    return (
        Box::new(ruya_platform::procfs::NoProcfs),
        Box::new(SystemUsers),
    );
}

fn run() -> Result<(), Box<dyn Error>> {
    let session = std::env::args().any(|a| a == "--session");
    let dir = std::env::var_os("RUYA_PLATFORM_DIR").map_or_else(
        || {
            if session {
                std::env::temp_dir().join("ruya-platform")
            } else {
                PathBuf::from(DEFAULT_DIR)
            }
        },
        PathBuf::from,
    );
    let store = Store::open(&dir)?;
    let registry = Registry::served()?;
    let (procfs, users) = readers();
    let core: Shared = Arc::new(Mutex::new(Platform::new(procfs, users, store, registry)));
    let checks = Checks {
        enforce: !session,
        shell_uid: ruya_users::uid_of(ruya_users::SHELL_USER),
    };
    if session {
        eprintln!("ruya-platform: --session: Manage callers are not checked");
    }
    eprintln!("ruya-platform: permissions in {}", dir.display());

    futures_lite::future::block_on(async {
        let builder = if session {
            zbus::connection::Builder::session()?
        } else {
            zbus::connection::Builder::system()?
        };
        let connection = builder
            .method_timeout(Duration::from_secs(10))
            .serve_at(OBJECT_PATH, LifecycleIface::new(core.clone()))?
            .serve_at(OBJECT_PATH, ManageIface::new(core.clone(), checks))?
            .build()
            .await?;
        connection.request_name(BUS_NAME).await?;
        futures_lite::future::zip(
            watch_names(connection.clone(), core.clone()),
            watch_profiles(connection.clone(), core),
        )
        .await;
        std::future::pending::<()>().await;
        Ok::<(), Box<dyn Error>>(())
    })
}
