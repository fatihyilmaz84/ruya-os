//! The generated Flatpak metadata (RUY-851, 05 §8): built from the manifest and its assessment
//! through the one permission table, compared as exact strings. A package gets exactly what it
//! asked for under its tier's ceiling and never a raw Flatpak key: what it writes in `env`,
//! `reasons` or a field name of its own reaches no line, and a key outside the vocabulary is
//! refused by the parser before anything is assessed. The extension points (ADR-038) follow the
//! runner: every app mounts the launcher and the system runners, a Windows runner adds the
//! runtime's 32-bit points.

mod common;

use common::fx::{assert_rejected, check};
use common::*;
use ruya_play::service::commit::{
    extension_points, metadata, EXTENSION_DIRS, LAUNCHER_DIR, LAUNCH_COMMAND,
};
use ruya_play_format::Manifest;
use ruya_play_trust::{assess, check_ceiling, Assessment, Tier};
use serde_json::json;

fn manifest_of(fx: &Fx) -> Manifest {
    match check(fx) {
        Ok(p) => p.manifest,
        Err(p) => panic!("the fixture does not validate: {p:#?}"),
    }
}

fn assessed(fx: &Fx, tier: Tier) -> (Manifest, Assessment) {
    let m = manifest_of(fx);
    let a = check_ceiling(tier, &m.permissions).expect("under the ceiling");
    (m, a)
}

/// The extension points of every app (ADR-038): the launcher and the system runners, both
/// linked in by the image, never fetched.
const PLAY_POINTS: &str = "[Extension org.ruyaos.Play.Launcher]\n\
                           directory=launcher\n\
                           version=1\n\
                           no-autodownload=true\n\
                           \n\
                           [Extension org.ruyaos.Play.Runner]\n\
                           directory=runners\n\
                           subdirectories=true\n\
                           version=1\n\
                           no-autodownload=true\n\
                           autodelete=false\n";

/// What a Windows runner adds: the runtime's 32-bit points, exactly as the spike declared them
/// (`scripts/spikes/play/q3-proton.sh`), on the runtime's branch.
const WINDOWS_POINTS: &str = "\n\
                              [Extension org.freedesktop.Platform.Compat.i386]\n\
                              directory=lib/i386-linux-gnu\n\
                              version=26.08\n\
                              \n\
                              [Extension org.freedesktop.Platform.GL32]\n\
                              directory=lib/i386-linux-gnu/GL\n\
                              version=1.4\n\
                              versions=26.08;1.4\n\
                              subdirectories=true\n\
                              add-ld-path=lib\n\
                              merge-dirs=vulkan/icd.d;glvnd/egl_vendor.d;\
                              egl/egl_external_platform.d;lib/dri;lib/gbm;\
                              vulkan/explicit_layer.d;vulkan/implicit_layer.d\n";

/// The metadata of a native app around its permission sections.
fn around(id: &str, permissions: &str) -> String {
    format!(
        "[Application]\n\
         name=play.{id}\n\
         runtime=org.freedesktop.Platform/x86_64/26.08\n\
         command=/app/launcher/bin/ruya-play-launch\n\
         \n\
         {permissions}\
         {PLAY_POINTS}"
    )
}

/// The same for an app of a Windows runner.
fn around_windows(id: &str, permissions: &str) -> String {
    format!("{}{WINDOWS_POINTS}", around(id, permissions))
}

/// The Wine fixture with runner `proton` (its component a Proton build).
fn proton_full() -> Fx {
    let mut fx = Fx::wine_full();
    fx.manifest["run"]["runner"] = json!("proton");
    fx.manifest["components"][0]["type"] = json!("proton");
    fx
}

/// What the Wine fixture asks for (`controllers+keyboard-mouse`, `multiarch`) on X11.
const WINE_SET: &str = "[Context]\n\
                        shared=ipc;\n\
                        sockets=x11;pulseaudio;\n\
                        devices=dri;\n\
                        features=multiarch;\n\
                        \n";

#[test]
fn the_wine_fixture_gets_exactly_its_set() {
    let (m, a) = assessed(&Fx::wine_full(), Tier::Developer);
    assert_eq!(
        metadata(&m, &a),
        around_windows("com.example.starhopper", WINE_SET)
    );
}

#[test]
fn a_proton_game_gets_the_32_bit_points_too() {
    let (m, a) = assessed(&proton_full(), Tier::Developer);
    assert_eq!(
        metadata(&m, &a),
        around_windows("com.example.starhopper", WINE_SET)
    );
}

#[test]
fn the_32_bit_points_grant_nothing_without_multiarch() {
    // A Windows package that does not ask for multiarch gets the points (inert) and no
    // `features=multiarch`: the permission, not the runner, opens 32-bit syscalls.
    let mut fx = Fx::wine_full();
    fx.manifest["permissions"] = json!({"input": "controllers+keyboard-mouse"});
    let (m, a) = assessed(&fx, Tier::Developer);
    let got = metadata(&m, &a);
    assert_eq!(
        got,
        around_windows(
            "com.example.starhopper",
            "[Context]\n\
             shared=ipc;\n\
             sockets=x11;pulseaudio;\n\
             devices=dri;\n\
             \n"
        )
    );
    assert!(!got.contains("multiarch"), "{got}");
}

#[test]
fn every_mount_folder_is_in_the_list_the_layout_and_verify_use() {
    for fx in [Fx::minimal(), Fx::wine_full(), proton_full()] {
        let (m, a) = assessed(&fx, Tier::Developer);
        let got = metadata(&m, &a);
        let dirs: Vec<&str> = got
            .lines()
            .filter_map(|l| l.strip_prefix("directory="))
            .collect();
        let points: Vec<&str> = extension_points(&m.run.runner)
            .iter()
            .map(|p| p.directory)
            .collect();
        assert_eq!(dirs, points, "{got}");
        for d in &dirs {
            assert!(EXTENSION_DIRS.contains(d), "{d} is not in EXTENSION_DIRS");
        }
        // The command runs from the launcher's mount.
        assert!(LAUNCH_COMMAND.starts_with(&format!("/app/{LAUNCHER_DIR}/")));
    }
    // And the list holds nothing a metadata does not declare.
    let windows: Vec<&str> = extension_points("wine")
        .iter()
        .map(|p| p.directory)
        .collect();
    assert_eq!(EXTENSION_DIRS, windows.as_slice());
}

#[test]
fn a_native_game_that_asks_for_nothing_gets_the_base_set() {
    let (m, a) = assessed(&Fx::minimal(), Tier::Unverified);
    assert_eq!(
        metadata(&m, &a),
        around(
            "com.example.mini",
            "[Context]\n\
             shared=ipc;\n\
             sockets=wayland;pulseaudio;\n\
             devices=dri;\n\
             \n"
        )
    );
}

#[test]
fn every_permission_maps_to_its_lines() {
    let mut fx = Fx::minimal();
    fx.manifest["permissions"] = json!({
        "network": true,
        "input": "all-devices",
        "removable_media": "write",
        "multiarch": true,
        "gamemode": true,
        "realtime": true,
        "devel": true
    });
    let (m, a) = assessed(&fx, Tier::Official);
    assert_eq!(
        metadata(&m, &a),
        around(
            "com.example.mini",
            "[Context]\n\
             shared=ipc;network;\n\
             sockets=wayland;pulseaudio;\n\
             devices=dri;all;\n\
             filesystems=/run/media;\n\
             features=devel;multiarch;\n\
             \n\
             [Session Bus Policy]\n\
             com.feralinteractive.GameMode=talk\n\
             \n"
        )
    );
    // Reading only: the drives read-only.
    fx.manifest["permissions"] = json!({"removable_media": "read"});
    let (m, a) = assessed(&fx, Tier::Developer);
    assert!(metadata(&m, &a).contains("\nfilesystems=/run/media:ro;\n"));
}

#[test]
fn filesystem_host_cannot_be_smuggled_in() {
    let mut fx = Fx::wine_full();
    // Through the environment, a reason, and field names of its own (unknown keys outside
    // `permissions`, `run` and `components` are ignored by the format).
    fx.manifest["run"]["env"] = json!({
        "WINEDLLOVERRIDES": "dinput8=n,b",
        "EXTRA_ARGS": "--filesystem=host --talk-name=org.freedesktop.Flatpak",
        "CONTEXT": "filesystems=host;"
    });
    fx.manifest["permissions"]["reasons"] = json!({
        "multiarch": {"en": "filesystems=host;"},
        "network": {"en": "[Context] filesystems=host"}
    });
    fx.manifest["filesystems"] = json!("host");
    fx.manifest["finish-args"] = json!(["--filesystem=host", "--socket=session-bus"]);
    fx.manifest["context"] = json!({"filesystems": "host"});
    let (m, a) = assessed(&fx, Tier::Developer);
    let got = metadata(&m, &a);
    assert_eq!(got, around_windows("com.example.starhopper", WINE_SET));
    assert!(!got.contains("host"), "{got}");
}

#[test]
fn microphone_camera_and_bluetooth_are_refused_by_the_parser() {
    for key in ["microphone", "camera", "bluetooth"] {
        let mut fx = Fx::minimal();
        fx.manifest["permissions"] = json!({ key: true });
        assert_rejected(check(&fx), "permissions.unknown_key");
    }
    // As is a raw Flatpak key.
    let mut fx = Fx::minimal();
    fx.manifest["permissions"] = json!({"filesystems": "host"});
    assert_rejected(check(&fx), "permissions.unknown_key");
}

#[test]
fn a_request_without_a_row_grants_nothing() {
    let m = manifest_of(&Fx::minimal());
    let mut a = assess(Tier::Official, &m.permissions);
    a.requests.push(ruya_play_trust::Request {
        key: "filesystems".into(),
        value: "host".into(),
        risk: ruya_play_trust::Risk::High,
    });
    assert_eq!(
        metadata(&m, &a),
        metadata(&m, &assess(Tier::Official, &m.permissions))
    );
}
