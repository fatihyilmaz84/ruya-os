//! ruya-library: serves org.ruyaos.Library1 on the system bus. With `--session` (development) it
//! serves on the session bus and, off Linux or without Flatpak, lists a few demo apps.
//!
//! The Steam roots come from the home directory in `RUYA_LIBRARY_HOME` (else `HOME`). Pointing
//! that at the active profile's user is a follow-up (needs the session service, T-130).

use std::error::Error;
use std::path::PathBuf;

use ruya_library::catalog::steam_roots;
use ruya_library::dbus::{LibraryIface, Sources, BUS_NAME, OBJECT_PATH};
use ruya_library::flatpak::{AppLister, FixtureLister};

fn main() {
    if let Err(err) = run() {
        eprintln!("ruya-library: fatal: {err}");
        std::process::exit(1);
    }
}

const DEMO_FLATPAK: &str =
    "org.ruyaos.Racer\tTurbo Racer\truyaos\norg.ruyaos.Puzzle\tBlock Puzzle\truyaos\n";

fn lister(session: bool) -> Box<dyn AppLister> {
    #[cfg(target_os = "linux")]
    if !session {
        return Box::new(ruya_library::flatpak::FlatpakCli);
    }
    let _ = session;
    Box::new(FixtureLister(DEMO_FLATPAK.to_owned()))
}

fn run() -> Result<(), Box<dyn Error>> {
    let session = std::env::args().any(|a| a == "--session");
    let home = std::env::var_os("RUYA_LIBRARY_HOME")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from);
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
        let _connection = builder
            .name(BUS_NAME)?
            .serve_at(OBJECT_PATH, iface)?
            .build()
            .await?;
        std::future::pending::<()>().await;
        Ok::<(), Box<dyn Error>>(())
    })
}
