//! ruya-notifications: serves org.ruyaos.Notifications1 on the system bus, as root, with one
//! root-only file per profile under /var/lib/ruyaos/notifications (the unit's StateDirectory).
//! With `--session` (development) it serves on the session bus, keeps its files in the
//! temporary directory, lets every caller post and takes any well-formed profile id until a
//! Profiles1 answers there. `RUYA_NOTIFICATIONS_DIR` overrides the directory.

use std::error::Error;
use std::path::PathBuf;
use std::time::Duration;

use ruya_notifications::dbus::{
    follow_profiles_once, watch_profiles, DynStore, NotificationsIface, BUS_NAME, OBJECT_PATH,
};
use ruya_notifications::service::{Notifications, Profiles};
use ruya_notifications::store::FileStore;

const DEFAULT_DIR: &str = "/var/lib/ruyaos/notifications";

fn main() {
    if let Err(err) = run() {
        eprintln!("ruya-notifications: fatal: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let session = std::env::args().any(|a| a == "--session");
    let dir = std::env::var_os("RUYA_NOTIFICATIONS_DIR").map_or_else(
        || {
            if session {
                std::env::temp_dir().join("ruya-notifications")
            } else {
                PathBuf::from(DEFAULT_DIR)
            }
        },
        PathBuf::from,
    );
    let store = FileStore::new(&dir);
    let loaded = store.load_all()?;
    eprintln!(
        "ruya-notifications: {} profile(s) from {}",
        loaded.len(),
        dir.display()
    );
    // Nothing is wiped and no Post is accepted before Profiles1 has said which profiles exist.
    let start = if session {
        Profiles::Any
    } else {
        Profiles::Unknown
    };
    let store: DynStore = Box::new(store);
    let iface = NotificationsIface::new(Notifications::new(store, loaded, start), session);

    futures_lite::future::block_on(async {
        let builder = if session {
            zbus::connection::Builder::session()?
        } else {
            zbus::connection::Builder::system()?
        };
        let connection = builder
            .method_timeout(Duration::from_secs(10))
            .serve_at(OBJECT_PATH, iface)?
            .build()
            .await?;
        // The profile list is read before the name is taken, so the shell's first Post can be
        // checked against it; if Profiles1 is not there yet the watcher keeps asking.
        let answering = follow_profiles_once(&connection).await;
        connection.request_name(BUS_NAME).await?;
        watch_profiles(connection.clone(), answering).await;
        std::future::pending::<()>().await;
        Ok::<(), Box<dyn Error>>(())
    })
}
