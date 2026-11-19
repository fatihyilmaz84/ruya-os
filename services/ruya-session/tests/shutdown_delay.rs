//! RUY-888: logind waits for ruya-session's shutdown delay lock longer than the service takes to
//! stop every app. The setting is in the image's logind drop-in; this reads it on the host. The
//! VM part is `vm-reboot-check.ps1 -Shutdown` (`vm-session-check.sh shutdown`, `shutdown-verify`).

use std::path::PathBuf;
use std::time::Duration;

use ruya_session::shutdown::STOP_ALL_WAIT;

const DROPIN: &str = "image/rootfs/usr/lib/systemd/logind.conf.d/50-ruyaos-inhibit-delay.conf";

fn dropin() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(DROPIN);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// The value of `key` in the `[Login]` section (the last one wins, as in logind).
fn login_value(text: &str, key: &str) -> Option<String> {
    let mut inside = false;
    let mut found = None;
    for line in text.lines().map(str::trim) {
        if line.starts_with('[') {
            inside = line == "[Login]";
        } else if inside && !line.starts_with('#') {
            if let Some((k, v)) = line.split_once('=') {
                if k.trim() == key {
                    found = Some(v.trim().to_owned());
                }
            }
        }
    }
    found
}

#[test]
fn logind_waits_longer_than_every_app_takes_to_quit() {
    let value = login_value(&dropin(), "InhibitDelayMaxSec")
        .unwrap_or_else(|| panic!("{DROPIN}: no InhibitDelayMaxSec in [Login]"));
    let secs: u64 = value
        .trim_end_matches('s')
        .parse()
        .unwrap_or_else(|_| panic!("{DROPIN}: InhibitDelayMaxSec={value} is not plain seconds"));
    assert!(
        Duration::from_secs(secs) > STOP_ALL_WAIT,
        "logind waits {secs} s, the stop of every app up to {STOP_ALL_WAIT:?}: logind would cut it short"
    );
}
