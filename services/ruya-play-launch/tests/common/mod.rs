//! An installed game in a [`FakeOs`]: `/app` with `play.json`, `play.files` and the listed files,
//! system runners under `/app/runners`, and the sandbox's environment.
#![allow(dead_code)]

use ruya_play_launch::fake::FakeOs;
use ruya_play_launch::os::Command;
use ruya_play_launch::state::State;
use ruya_play_launch::Failure;
use serde_json::{json, Value};
use std::collections::BTreeMap;

pub const DATA: &str = "/home/p/.var/app/play.com.example.hop/data";
pub const CONFIG: &str = "/home/p/.var/app/play.com.example.hop/config";
pub const PREFIX: &str = "/home/p/.var/app/play.com.example.hop/data/prefix";

/// A package as installed.
pub struct Game {
    pub manifest: Value,
    /// Regular files below `/app` (not the root files).
    pub files: Vec<(String, Vec<u8>)>,
}

/// A runner.json of format 1.
pub fn runner_json(family: &str, kind: &str, version: &str) -> String {
    let entry = match kind {
        "wine" => r#","entry":{"wine":"bin/wine","wineserver":"bin/wineserver"}"#,
        "proton" => r#","entry":{"proton":"proton"}"#,
        _ => "",
    };
    format!(
        r#"{{"format":1,"family":"{family}","kind":"{kind}","version":"{version}","arch":"x86_64"{entry}}}"#
    )
}

impl Game {
    /// A native game.
    pub fn native() -> Game {
        Game {
            manifest: json!({
                "format": 1, "id": "com.example.hop", "name": {"en": "Hop"},
                "version": "1.0", "build": 1, "art": {"icon": "art/icon.png"},
                "run": {"runner": "native", "command": ["${payload}/game", "--data=${data}/x"]}
            }),
            files: vec![
                ("art/icon.png".into(), b"icon".to_vec()),
                ("payload/game".into(), b"elf".to_vec()),
            ],
        }
    }

    /// A Windows game on a bundled Wine 9.20 (`source: newest`, `min` 9.0), with a prefix
    /// template, a once setup step and a save inside the prefix.
    pub fn wine() -> Game {
        let mut g = Game::native();
        g.manifest = json!({
            "format": 1, "id": "com.example.hop", "name": {"en": "Hop"},
            "version": "1.0", "build": 1, "art": {"icon": "art/icon.png"},
            "components": [{
                "id": "wine", "type": "wine", "source": "newest", "min": "9.0",
                "bundled": {"path": "components/wine", "version": "9.20",
                            "licence": "LGPL-2.1-or-later"}
            }],
            "run": {
                "runner": "wine", "component": "wine",
                "command": ["${payload}/Hop.exe", "-fullscreen"],
                "env": {"WINEDLLOVERRIDES": "dinput8=n,b"},
                "prefix": {"arch": "win64", "template": "payload/prefix-template", "epoch": 1},
                "setup": [{"id": "vcredist", "command": ["${payload}/redist/vc.exe", "/q"], "once": true}]
            },
            "data": {"saves": ["prefix:drive_c/users/steamuser/Documents/Hop"]}
        });
        g.files.extend(
            [
                ("payload/Hop.exe", &b"MZ"[..]),
                ("payload/redist/vc.exe", b"MZ redist"),
                (
                    "payload/prefix-template/drive_c/windows/system.ini",
                    b"[boot]",
                ),
                ("components/wine/bin/wine", b"elf"),
                ("components/wine/bin/wineserver", b"elf"),
                ("licences/LGPL-2.1.txt", b"text"),
            ]
            .into_iter()
            .map(|(p, d)| (p.to_string(), d.to_vec())),
        );
        g
    }

    /// Set `pointer` (a JSON pointer into the manifest) to `v`.
    pub fn set(&mut self, pointer: &str, v: Value) -> &mut Self {
        *self.manifest.pointer_mut(pointer).expect("pointer exists") = v;
        self
    }

    /// The `play.files` text (hashes are not checked at launch).
    pub fn table(&self) -> String {
        let mut files = self.files.clone();
        files.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
        let mut out = String::new();
        for (p, d) in &files {
            out.push_str(&format!(
                "{{\"h\":\"{}\",\"p\":{},\"s\":{},\"t\":\"f\"}}\n",
                "0".repeat(64),
                serde_json::to_string(p).unwrap(),
                d.len()
            ));
        }
        out
    }

    /// The game installed in a fresh fake.
    pub fn install(&self) -> FakeOs {
        let mut os = FakeOs::new();
        self.install_into(&mut os);
        os.dir(DATA);
        os
    }

    /// Write `/app` into `os` (replacing the root files: an update).
    pub fn install_into(&self, os: &mut FakeOs) {
        os.file("/app/play.json", self.manifest.to_string());
        os.file("/app/play.files", self.table());
        for (p, d) in &self.files {
            os.file(&format!("/app/{p}"), d.clone());
        }
    }
}

/// A system runner folder `/app/runners/<name>` with its `runner.json` and entries.
pub fn add_system_runner(os: &mut FakeOs, name: &str, family: &str, kind: &str, version: &str) {
    add_runner_at(os, &format!("/app/runners/{name}"), family, kind, version);
}

/// A runner folder at `root` with its `runner.json` and entries.
pub fn add_runner_at(os: &mut FakeOs, root: &str, family: &str, kind: &str, version: &str) {
    os.file(
        &format!("{root}/runner.json"),
        runner_json(family, kind, version),
    );
    match kind {
        "wine" => {
            os.file(&format!("{root}/bin/wine"), "elf");
            os.file(&format!("{root}/bin/wineserver"), "elf");
        }
        "proton" => {
            os.file(&format!("{root}/proton"), "#!/usr/bin/env python3");
        }
        _ => {}
    }
}

/// The sandbox's environment.
pub fn base_env() -> BTreeMap<String, String> {
    [
        ("PATH", "/app/bin:/usr/bin"),
        ("HOME", "/home/p"),
        ("FLATPAK_ID", "play.com.example.hop"),
        ("XDG_DATA_HOME", DATA),
        ("XDG_CONFIG_HOME", CONFIG),
        ("WINEPREFIX", "/tmp/elsewhere"),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect()
}

/// `prepare` with these arguments and the default environment.
pub fn launch(os: &mut FakeOs, args: &[&str]) -> Result<Command, Failure> {
    let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
    ruya_play_launch::prepare(os, &args, &base_env())
}

/// The status file as the launcher left it.
pub fn state(os: &FakeOs) -> State {
    let bytes = os
        .read(&format!("{DATA}/.ruya-play/state.json"))
        .expect("the status file exists");
    State::parse(bytes).expect("the status file parses")
}
