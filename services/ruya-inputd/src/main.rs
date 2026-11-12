//! ruya-inputd: the Ruya Input service (06-input.md). On Linux it reads every gamepad, makes the
//! navigation keys and the profile's virtual pads, and serves org.ruyaos.Input1 on the system
//! bus as the system user `ruya-input`. With `--session` (development, any OS) it serves the
//! contract on the session bus with no devices and the profiles p1..p3.

use ruya_inputd::accounts::FixedAccounts;
use ruya_inputd::dbus::{serve, DynBackend, Shared};
use ruya_inputd::routing::{NullBackend, Router};

fn main() {
    let session = std::env::args().any(|a| a == "--session");
    if !session {
        #[cfg(target_os = "linux")]
        {
            if let Err(err) = ruya_inputd::linux::run() {
                eprintln!("ruya-inputd: fatal: {err}");
                std::process::exit(1);
            }
            return;
        }
        #[cfg(not(target_os = "linux"))]
        {
            eprintln!("ruya-inputd only runs on Linux (or with --session)");
            std::process::exit(1);
        }
    }
    let accounts = FixedAccounts(vec![
        ("p1".into(), 1001),
        ("p2".into(), 1002),
        ("p3".into(), 1003),
    ]);
    let backend: DynBackend = Box::new(NullBackend);
    let (shared, notices) = Shared::new(Router::new(backend, Box::new(accounts)));
    if let Err(err) = futures_lite::future::block_on(serve(false, shared, notices)) {
        eprintln!("ruya-inputd: fatal: {err}");
        std::process::exit(1);
    }
}
