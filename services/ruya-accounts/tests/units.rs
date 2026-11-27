//! The image's units agree with this crate and with ADR-049 (RUY-1264): ruya-profiles connects
//! where the socket listens, the socket is root's and the ruya-profiles group's only, the helper
//! runs where the image installs it, without a bus name, with the store hidden, and ruya-profiles
//! itself runs as its own user without a capability. The VM check (`vm-profiles-check.sh helper`)
//! measures the same on a booted image.

use std::path::PathBuf;

use ruya_accounts::wire::{PEER_USER, SOCKET};

fn repo_file(rel: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(rel);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn unit(name: &str) -> String {
    repo_file(&format!("image/rootfs/usr/lib/systemd/system/{name}"))
}

/// Every value of `key=` in a unit, in order (comments skipped).
fn values(text: &str, key: &str) -> Vec<String> {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.starts_with('#'))
        .filter_map(|l| l.strip_prefix(key)?.strip_prefix('='))
        .map(|v| v.trim().to_owned())
        .collect()
}

fn one(text: &str, key: &str) -> String {
    let v = values(text, key);
    assert_eq!(v.len(), 1, "{key}= must be set exactly once: {v:?}");
    v[0].clone()
}

#[test]
fn the_socket_is_for_root_and_the_profiles_group_and_where_the_client_connects() {
    let socket = unit("ruya-accounts.socket");
    assert_eq!(one(&socket, "ListenSequentialPacket"), SOCKET);
    assert_eq!(one(&socket, "SocketUser"), "root");
    assert_eq!(one(&socket, "SocketGroup"), PEER_USER);
    assert_eq!(one(&socket, "SocketMode"), "0660");
    assert_eq!(one(&socket, "Accept"), "yes");
    assert_eq!(one(&socket, "WantedBy"), "sockets.target");
}

#[test]
fn the_helper_has_no_bus_name_and_never_sees_the_store() {
    let helper = unit("ruya-accounts@.service");
    assert_eq!(one(&helper, "StandardInput"), "socket");
    assert_eq!(
        one(&helper, "StandardOutput"),
        "journal",
        "the socket carries the reply only"
    );
    assert!(values(&helper, "BusName").is_empty());
    assert!(values(&helper, "User").is_empty(), "root: useradd needs it");
    let hidden = one(&helper, "InaccessiblePaths");
    let hidden: Vec<&str> = hidden.split_whitespace().collect();
    assert!(hidden.contains(&"/var/lib/ruyaos/profiles"), "{hidden:?}");
    assert!(hidden.contains(&"/sysroot"), "{hidden:?}");
    let mut caps: Vec<String> = one(&helper, "CapabilityBoundingSet")
        .split_whitespace()
        .map(str::to_owned)
        .collect();
    caps.sort();
    assert_eq!(
        caps,
        [
            "CAP_CHOWN",
            "CAP_DAC_OVERRIDE",
            "CAP_DAC_READ_SEARCH",
            "CAP_FOWNER",
            "CAP_FSETID"
        ]
    );
    assert_eq!(one(&helper, "PrivateNetwork"), "yes");
    assert_eq!(one(&helper, "NoNewPrivileges"), "yes");
    assert!(values(&helper, "AmbientCapabilities").is_empty());
    assert!(!values(&helper, "RuntimeMaxSec").is_empty());
}

#[test]
fn the_image_installs_the_helper_where_the_unit_runs_it() {
    let exec = one(&unit("ruya-accounts@.service"), "ExecStart");
    assert_eq!(exec, "/usr/libexec/ruya-accounts");
    let containerfile = repo_file("image/Containerfile");
    assert!(
        containerfile.contains(&format!(
            "install -Dm755 target/release/ruya-accounts /out{exec} "
        )),
        "the Containerfile installs the helper at {exec}"
    );
    assert!(
        containerfile.contains(" ruya-accounts.socket "),
        "the Containerfile enables the socket"
    );
    assert!(
        repo_file("image/build/enabled-units.txt")
            .lines()
            .any(|l| l.split_whitespace().next() == Some("ruya-accounts.socket")),
        "enabled-units.txt has the socket"
    );
}

#[test]
fn ruya_profiles_runs_as_its_own_user_without_a_capability() {
    let profiles = unit("ruya-profiles.service");
    assert_eq!(one(&profiles, "User"), PEER_USER);
    assert_eq!(one(&profiles, "CapabilityBoundingSet"), "");
    assert!(values(&profiles, "AmbientCapabilities").is_empty());
    assert!(values(&profiles, "Wants").contains(&"ruya-accounts.socket".to_owned()));
    assert!(values(&profiles, "After").contains(&"ruya-accounts.socket".to_owned()));
    // No step runs as root: one ExecStart, without a "+" or "!" prefix, and nothing before it.
    assert_eq!(one(&profiles, "ExecStart"), "/usr/bin/ruya-profiles");
    assert!(values(&profiles, "ExecStartPre").is_empty());
    let sysusers = repo_file("image/rootfs/usr/lib/sysusers.d/ruyaos.conf");
    assert!(
        sysusers
            .lines()
            .any(|l| l.split_whitespace().take(2).eq(["u", PEER_USER])),
        "sysusers.d makes the {PEER_USER} user"
    );
}
