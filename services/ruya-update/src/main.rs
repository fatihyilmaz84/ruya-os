//! ruya-update: serves org.ruyaos.Update1 on the system bus (root, over the `bootc` command).
//! With `--session` (development) it serves on the session bus over a fake host with one newer
//! image waiting.

use std::error::Error;
use std::path::PathBuf;
use std::sync::Arc;

use ruya_update::bootc::{Bootc, BootcCli, Deployment, FakeBootc, HostStatus};
use ruya_update::dbus::{forward, DynBootc, UpdateIface, BUS_NAME, OBJECT_PATH};
use ruya_update::service::Update;

fn main() {
    if let Err(err) = run() {
        eprintln!("ruya-update: fatal: {err}");
        std::process::exit(1);
    }
}

fn dep(tag: &str, version: &str, digest: &str) -> Deployment {
    Deployment {
        image: format!("registry.example/ruyaos:{tag}"),
        version: version.to_owned(),
        digest: digest.to_owned(),
    }
}

fn bootc(session: bool) -> DynBootc {
    if !session {
        return Box::new(BootcCli);
    }
    let b: Box<dyn Bootc> = Box::new(FakeBootc::new(HostStatus {
        tracked: "registry.example/ruyaos:stable".to_owned(),
        booted: Some(dep("stable", "0.0.18", "sha256:a")),
        staged: None,
        rollback: Some(dep("stable", "0.0.17", "sha256:z")),
        rollback_queued: false,
        cached_update: Some(dep("stable", "0.0.19", "sha256:b")),
    }));
    b
}

fn run() -> Result<(), Box<dyn Error>> {
    let session = std::env::args().any(|a| a == "--session");
    let dir = (!session).then(|| {
        PathBuf::from(
            std::env::var("RUYA_UPDATE_STATE").unwrap_or_else(|_| "/var/lib/ruya-update".into()),
        )
    });
    let update: Arc<Update<DynBootc>> = Arc::new(Update::new(bootc(session), dir));
    // `bootc status` can be slow right after boot: the name is taken first and a client reading
    // earlier sees an empty record until the deployments are known.
    let (changes, receiver) = async_channel::unbounded();
    {
        let update = update.clone();
        let changes = changes.clone();
        std::thread::spawn(move || {
            for attempt in 1..=5 {
                match update.refresh() {
                    Ok(()) => break,
                    Err(err) => {
                        eprintln!("ruya-update: reading bootc status failed ({attempt}/5): {err}");
                        std::thread::sleep(std::time::Duration::from_secs(5));
                    }
                }
            }
            let _ = changes.send_blocking(());
        });
    }

    futures_lite::future::block_on(async {
        let builder = if session {
            zbus::connection::Builder::session()?
        } else {
            zbus::connection::Builder::system()?
        };
        let connection = builder
            .name(BUS_NAME)?
            .serve_at(OBJECT_PATH, UpdateIface::new(update, changes, session))?
            .build()
            .await?;
        forward(connection, receiver).await;
        Ok::<(), Box<dyn Error>>(())
    })
}
