//! ruya-library: serves org.ruyaos.Library1 on the system bus. With `--session` (development) it
//! serves on the session bus and, off Linux or without Flatpak, lists a few demo apps.
//!
//! The Steam roots come from the home directory in `RUYA_LIBRARY_HOME` (else `HOME`). Pointing
//! that at the active profile's user is a follow-up (needs the session service, T-130).

use std::error::Error;
use std::path::{Path, PathBuf};
use std::time::Duration;

use ruya_library::catalog::steam_roots;
use ruya_library::dbus::{LibraryIface, Sources, BUS_NAME, OBJECT_PATH};
use ruya_library::flatpak::{AppLister, FixtureLister};
use ruya_library::watch::{fingerprint, Fingerprint, Watcher};

fn main() {
    if let Err(err) = run() {
        eprintln!("ruya-library: fatal: {err}");
        std::process::exit(1);
    }
}

const DEMO_FLATPAK: &str =
    "org.ruyaos.Racer\tTurbo Racer\truyaos\norg.ruyaos.Notes\tNotes\truyaos\n";

fn lister(session: bool) -> Box<dyn AppLister> {
    #[cfg(target_os = "linux")]
    if !session {
        return Box::new(ruya_library::flatpak::FlatpakCli);
    }
    let _ = session;
    Box::new(
        FixtureLister::new(DEMO_FLATPAK)
            .with_desktop(
                "org.ruyaos.Racer",
                "[Desktop Entry]\nName=Turbo Racer\nCategories=Game;ArcadeGame;\n",
            )
            .with_desktop(
                "org.ruyaos.Notes",
                "[Desktop Entry]\nName=Notes\nCategories=Utility;\n",
            ),
    )
}

fn run() -> Result<(), Box<dyn Error>> {
    let session = std::env::args().any(|a| a == "--session");
    let home = std::env::var_os("RUYA_LIBRARY_HOME")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from);
    // Looked at before the first scan, so an install in between is seen by the watcher.
    let root = std::env::var_os("RUYA_FLATPAK_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(FLATPAK_ROOT));
    let baseline = fingerprint(&root);
    let sources = Sources {
        steam_roots: home.as_deref().map(steam_roots).unwrap_or_default(),
        lister: lister(session),
    };
    let iface = LibraryIface::new(sources);

    futures_lite::future::block_on(async {
        let builder = if session {
            zbus::connection::Builder::session()?
        } else {
            zbus::connection::Builder::system()?
        };
        let connection = builder
            .name(BUS_NAME)?
            .serve_at(OBJECT_PATH, iface)?
            .build()
            .await?;
        // `--session` lists fixed demo apps: nothing to watch.
        if !session {
            let connection = connection.clone();
            let root = root.clone();
            std::thread::spawn(move || watch_installation(&connection, &root, baseline));
        }
        std::future::pending::<()>().await;
        Ok::<(), Box<dyn Error>>(())
    })
}

/// The system Flatpak installation the image serves (spec 03 §5).
const FLATPAK_ROOT: &str = "/var/lib/flatpak";
const POLL: Duration = Duration::from_secs(2);

/// Looks at the installation every `POLL`; when apps were installed or removed, scans again and
/// sends `ItemsChanged` if the list differs (T-163). Runs on its own thread: the scan runs
/// `flatpak`. The pure change detection is in `ruya_library::watch`.
fn watch_installation(connection: &zbus::Connection, root: &Path, baseline: Fingerprint) {
    let mut watcher = Watcher::new();
    watcher.changed(baseline);
    loop {
        std::thread::sleep(POLL);
        if !watcher.changed(fingerprint(root)) {
            continue;
        }
        futures_lite::future::block_on(async {
            let iface = match connection
                .object_server()
                .interface::<_, LibraryIface>(OBJECT_PATH)
                .await
            {
                Ok(iface) => iface,
                Err(err) => {
                    eprintln!("ruya-library: interface not found: {err}");
                    return;
                }
            };
            let changed = iface.get().await.refresh();
            if changed {
                LibraryIface::announce(iface.signal_emitter()).await;
            }
        });
    }
}
