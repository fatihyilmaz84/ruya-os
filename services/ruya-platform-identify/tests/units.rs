//! The image's units agree with this crate and with ADR-022 build decision 4 (RUY-1129): the door
//! connects where the socket listens, the socket is root's only, the helper runs where the image
//! installs it, with exactly its two capabilities and no bus, and the door holds no capability.
//! The VM check (`vm-platform-check.sh`) measures the same on a booted image.

use std::path::PathBuf;

use ruya_platform_identify::wire::SOCKET;

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
fn the_socket_is_roots_only_and_where_the_door_connects() {
    let socket = unit("ruya-platform-identify.socket");
    assert_eq!(one(&socket, "ListenSequentialPacket"), SOCKET);
    assert_eq!(one(&socket, "SocketUser"), "root");
    assert_eq!(one(&socket, "SocketMode"), "0600");
    assert_eq!(one(&socket, "Accept"), "yes");
    assert_eq!(one(&socket, "MaxConnections"), "8");
    // Far above what the serial door can ask (the unit's comment has the numbers).
    assert_eq!(one(&socket, "TriggerLimitIntervalSec"), "2s");
    assert_eq!(one(&socket, "TriggerLimitBurst"), "4000");
    assert_eq!(one(&socket, "WantedBy"), "sockets.target");
}

#[test]
fn the_helper_has_its_two_capabilities_and_no_bus() {
    let helper = unit("ruya-platform-identify@.service");
    let mut caps: Vec<String> = one(&helper, "CapabilityBoundingSet")
        .split_whitespace()
        .map(str::to_owned)
        .collect();
    caps.sort();
    assert_eq!(caps, ["CAP_DAC_READ_SEARCH", "CAP_SYS_PTRACE"]);
    assert_eq!(one(&helper, "StandardInput"), "socket");
    assert_eq!(
        one(&helper, "StandardOutput"),
        "journal",
        "the socket carries the reply only"
    );
    assert_eq!(one(&helper, "InaccessiblePaths"), "/run/dbus");
    assert_eq!(one(&helper, "PrivateNetwork"), "yes");
    assert_eq!(one(&helper, "TasksMax"), "1");
    assert_eq!(one(&helper, "NoNewPrivileges"), "yes");
    assert!(values(&helper, "AmbientCapabilities").is_empty());
    assert!(
        values(&helper, "User").is_empty(),
        "root: the reads need the capabilities"
    );
    assert!(!values(&helper, "RuntimeMaxSec").is_empty());
}

#[test]
fn the_image_installs_the_helper_where_the_unit_runs_it() {
    let exec = one(&unit("ruya-platform-identify@.service"), "ExecStart");
    assert_eq!(exec, "/usr/libexec/ruya-platform-identify");
    let containerfile = repo_file("image/Containerfile");
    assert!(
        containerfile.contains(&format!(
            "install -Dm755 target/release/ruya-platform-identify /out{exec} "
        )),
        "the Containerfile installs the helper at {exec}"
    );
    assert!(
        containerfile.contains(" ruya-platform-identify.socket "),
        "the Containerfile enables the socket"
    );
    assert!(
        repo_file("image/build/enabled-units.txt")
            .lines()
            .any(|l| l.split_whitespace().next() == Some("ruya-platform-identify.socket")),
        "enabled-units.txt has the socket"
    );
}

#[test]
fn the_door_holds_no_capability() {
    let door = unit("ruya-platform.service");
    assert_eq!(one(&door, "CapabilityBoundingSet"), "");
    assert_eq!(one(&door, "ProtectProc"), "invisible");
    assert!(values(&door, "AmbientCapabilities").is_empty());
    assert!(values(&door, "Wants").contains(&"ruya-platform-identify.socket".to_owned()));
}
