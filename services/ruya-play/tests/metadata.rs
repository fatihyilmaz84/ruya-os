//! The generated Flatpak metadata (RUY-851, 05 §8): built from the manifest and its assessment
//! through the one permission table, compared as exact strings. A package gets exactly what it
//! asked for under its tier's ceiling and never a raw Flatpak key: what it writes in `env`,
//! `reasons` or a field name of its own reaches no line, and a key outside the vocabulary is
//! refused by the parser before anything is assessed.

mod common;

use common::fx::{assert_rejected, check};
use common::*;
use ruya_play::service::commit::metadata;
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

/// The metadata around the permission sections, for an app id.
fn around(id: &str, permissions: &str) -> String {
    format!(
        "[Application]\n\
         name=play.{id}\n\
         runtime=org.freedesktop.Platform/x86_64/26.08\n\
         command=/app/launcher/bin/ruya-play-launch\n\
         \n\
         {permissions}\
         [Extension org.ruyaos.Play.Launcher]\n\
         directory=launcher\n\
         version=1\n\
         no-autodownload=false\n"
    )
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
    assert_eq!(metadata(&m, &a), around("com.example.starhopper", WINE_SET));
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
    assert_eq!(got, around("com.example.starhopper", WINE_SET));
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
