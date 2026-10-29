//! ruya-store: serves org.ruyaos.Store1 on the system bus (root, over the `flatpak` command).
//! With `--session` (development) it serves on the session bus over a fake Flatpak with a few
//! apps.

use std::error::Error;
use std::sync::Arc;

use ruya_store::dbus::{forward, spawn_sync, DynFlatpak, StoreIface, BUS_NAME, OBJECT_PATH};
use ruya_store::flatpak::FakeFlatpak;
use ruya_store::service::Store;

fn main() {
    if let Err(err) = run() {
        eprintln!("ruya-store: fatal: {err}");
        std::process::exit(1);
    }
}

const DEMO_APPSTREAM: &str = r#"<components origin="ruyaos">
  <component type="desktop-application"><id>org.ruyaos.Racer</id><name>Turbo Racer</name>
    <summary>Race on a closed course</summary>
    <recommends><control>gamepad</control></recommends></component>
  <component type="desktop-application"><id>org.ruyaos.Puzzle</id><name>Block Puzzle</name>
    <summary>Fit the falling blocks</summary></component>
</components>"#;

fn flatpak(session: bool) -> DynFlatpak {
    #[cfg(target_os = "linux")]
    if !session {
        return Box::new(ruya_store::flatpak_cli::FlatpakCli::system());
    }
    let _ = session;
    Box::new(
        FakeFlatpak::default()
            .with_remote("ruyaos", "RuyaOS", true)
            .with_app("ruyaos", "org.ruyaos.Racer", 40_000_000)
            .with_app("ruyaos", "org.ruyaos.Puzzle", 8_000_000)
            .with_appstream("ruyaos", DEMO_APPSTREAM)
            .with_progress(&[20, 60, 100]),
    )
}

fn run() -> Result<(), Box<dyn Error>> {
    let session = std::env::args().any(|a| a == "--session");
    let store: Arc<Store<DynFlatpak>> = Arc::new(Store::new(flatpak(session)));
    let (events, receiver) = async_channel::unbounded();
    // The first read of the catalogue can take a while (remotes are asked over the network):
    // the name is taken first and clients are told when the lists are ready. A failing flatpak
    // leaves an empty store, not a dead service.
    spawn_sync(store.clone(), events.clone());

    futures_lite::future::block_on(async {
        let builder = if session {
            zbus::connection::Builder::session()?
        } else {
            zbus::connection::Builder::system()?
        };
        let connection = builder
            .name(BUS_NAME)?
            .serve_at(OBJECT_PATH, StoreIface::new(store, events, session))?
            .build()
            .await?;
        forward(connection, receiver).await;
        Ok::<(), Box<dyn Error>>(())
    })
}
