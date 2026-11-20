//! Which runner the launcher starts (RUY-901): one row per case, every `source` x bundled copy
//! present or absent x system runner absent, present (the bundled version), older than `min`,
//! newer than the bundled copy, or above `max_major`. Each row is a real launch on the fake
//! sandbox, so it covers the re-parse, the scan, `resolve::resolve` and the argv together. A
//! package the format refuses (a source that needs a bundled copy without one) fails with the
//! format's code, as it would at install.

mod common;

use common::*;
use serde_json::json;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Sys {
    Absent,
    /// 9.20, the bundled version.
    Present,
    /// 8.0, below `min` 9.0.
    Older,
    /// 10.2, above the bundled copy, within `max_major` 10.
    Newer,
    /// 11.0, above `max_major` 10.
    AboveMax,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Want {
    Bundled,
    System,
    Fails(&'static str),
}

use Sys::*;
use Want::*;

impl Want {
    /// What a launch reports: `bundled`, `system` or the failure's code.
    fn label(self) -> &'static str {
        match self {
            Bundled => "bundled",
            System => "system",
            Fails(code) => code,
        }
    }
}

const NO_SYSTEM: Want = Fails("resolve.no_system_runner");
const TOO_OLD: Want = Fails("resolve.system_too_old");
const TOO_NEW: Want = Fails("resolve.system_too_new");
const REFUSED: Want = Fails("component.missing_field");

#[rustfmt::skip]
const ROWS: &[(&str, bool, Sys, Want)] = &[
    // source           bundled  system     runs
    ("bundled",         true,  Absent,   Bundled),
    ("bundled",         true,  Present,  Bundled),
    ("bundled",         true,  Older,    Bundled),
    ("bundled",         true,  Newer,    Bundled),
    ("bundled",         true,  AboveMax, Bundled),
    ("bundled",         false, Absent,   REFUSED),
    ("bundled",         false, Present,  REFUSED),
    ("bundled",         false, Older,    REFUSED),
    ("bundled",         false, Newer,    REFUSED),
    ("bundled",         false, AboveMax, REFUSED),
    ("system",          true,  Absent,   NO_SYSTEM),
    ("system",          true,  Present,  System),
    ("system",          true,  Older,    TOO_OLD),
    ("system",          true,  Newer,    System),
    ("system",          true,  AboveMax, TOO_NEW),
    ("system",          false, Absent,   NO_SYSTEM),
    ("system",          false, Present,  System),
    ("system",          false, Older,    TOO_OLD),
    ("system",          false, Newer,    System),
    ("system",          false, AboveMax, TOO_NEW),
    ("prefer-system",   true,  Absent,   Bundled),
    ("prefer-system",   true,  Present,  System),
    ("prefer-system",   true,  Older,    Bundled),
    ("prefer-system",   true,  Newer,    System),
    ("prefer-system",   true,  AboveMax, Bundled),
    ("prefer-system",   false, Absent,   REFUSED),
    ("prefer-system",   false, Present,  REFUSED),
    ("prefer-system",   false, Older,    REFUSED),
    ("prefer-system",   false, Newer,    REFUSED),
    ("prefer-system",   false, AboveMax, REFUSED),
    ("prefer-bundled",  true,  Absent,   Bundled),
    ("prefer-bundled",  true,  Present,  Bundled),
    ("prefer-bundled",  true,  Older,    Bundled),
    ("prefer-bundled",  true,  Newer,    Bundled),
    ("prefer-bundled",  true,  AboveMax, Bundled),
    ("prefer-bundled",  false, Absent,   REFUSED),
    ("prefer-bundled",  false, Present,  REFUSED),
    ("prefer-bundled",  false, Older,    REFUSED),
    ("prefer-bundled",  false, Newer,    REFUSED),
    ("prefer-bundled",  false, AboveMax, REFUSED),
    ("newest",          true,  Absent,   Bundled),
    ("newest",          true,  Present,  Bundled), // a tie goes to the bundled copy
    ("newest",          true,  Older,    Bundled),
    ("newest",          true,  Newer,    System),
    ("newest",          true,  AboveMax, Bundled),
    ("newest",          false, Absent,   REFUSED),
    ("newest",          false, Present,  REFUSED),
    ("newest",          false, Older,    REFUSED),
    ("newest",          false, Newer,    REFUSED),
    ("newest",          false, AboveMax, REFUSED),
];

/// The player's override on top of the package default: the rows where it changes the answer
/// or is refused (bundled copy present, `source` x override x system).
#[rustfmt::skip]
const OVERRIDES: &[(&str, &str, Sys, Want)] = &[
    ("newest",         "--runner=system",  Present,  System),
    ("newest",         "--runner=system",  Older,    Bundled),   // not usable: package default
    ("newest",         "--runner=bundled", Newer,    Bundled),
    ("prefer-system",  "--runner=bundled", Present,  Bundled),
    ("prefer-bundled", "--runner=system",  Present,  System),
    ("prefer-bundled", "--runner=system",  AboveMax, Bundled),
    ("bundled",        "--runner=system",  Newer,    Bundled),   // never for source: bundled
    ("system",         "--runner=bundled", Present,  Bundled),
    ("system",         "--runner=package", Present,  System),
];

fn row(source: &str, bundled: bool, sys: Sys, args: &[&str]) -> String {
    let mut g = Game::wine();
    g.set(
        "/components/0",
        json!({"id": "wine", "type": "wine", "source": source, "min": "9.0", "max_major": 10,
               "bundled": {"path": "components/wine", "version": "9.20",
                           "licence": "LGPL-2.1-or-later"}}),
    );
    if !bundled {
        g.manifest["components"][0]
            .as_object_mut()
            .unwrap()
            .remove("bundled");
        g.files.retain(|(p, _)| !p.starts_with("components/"));
    }
    let mut os = g.install();
    let version = match sys {
        Absent => None,
        Present => Some("9.20"),
        Older => Some("8.0"),
        Newer => Some("10.2"),
        AboveMax => Some("11.0"),
    };
    if let Some(v) = version {
        add_system_runner(&mut os, "Sys", "wine", "wine", v);
    }
    match launch(&mut os, args) {
        Ok(cmd) if cmd.argv[0] == "/app/components/wine/bin/wine" => Bundled.label().into(),
        Ok(cmd) if cmd.argv[0] == "/app/runners/Sys/bin/wine" => System.label().into(),
        Ok(cmd) => panic!("unexpected argv {:?}", cmd.argv),
        Err(f) => f.code,
    }
}

#[test]
fn every_source_bundled_and_system_case() {
    let mut wrong = Vec::new();
    for &(source, bundled, sys, want) in ROWS {
        let got = row(source, bundled, sys, &[]);
        if got != want.label() {
            wrong.push(format!(
                "{source} bundled={bundled} {sys:?}: want {}, got {got}",
                want.label()
            ));
        }
    }
    assert_eq!(ROWS.len(), 5 * 2 * 5, "one row per case");
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
}

#[test]
fn the_players_override() {
    let mut wrong = Vec::new();
    for &(source, arg, sys, want) in OVERRIDES {
        let got = row(source, true, sys, &[arg]);
        if got != want.label() {
            wrong.push(format!(
                "{source} {arg} {sys:?}: want {}, got {got}",
                want.label()
            ));
        }
    }
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
}

#[test]
fn a_failure_is_one_sentence() {
    let mut g = Game::wine();
    g.set("/components/0/source", json!("system"));
    let mut os = g.install();
    let f = launch(&mut os, &[]).unwrap_err();
    assert_eq!(f.code, "resolve.no_system_runner");
    assert!(
        f.message.ends_with('.') && !f.message.contains('\n'),
        "{}",
        f.message
    );
}
