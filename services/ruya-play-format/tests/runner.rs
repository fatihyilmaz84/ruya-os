//! `runner.json` v1 (ADR-037, 05 §6.2.1): one test per field rule and per `runner.*` code, the
//! defaults of a bundled copy without the file, and `validate` refusing a present but invalid
//! file instead of defaulting it.

mod common;

use common::*;
use ruya_play_format::problem::Problems;
use ruya_play_format::runner::{parse_runner, BundledRunner, Entry, RunnerJson};
use ruya_play_format::{validate, Problem, ValidateOptions};
use serde_json::{json, Value};

const FILE: &str = "components/wine/runner.json";

fn parse_bytes(bytes: &[u8]) -> Result<RunnerJson, Vec<Problem>> {
    let mut p = Problems::new();
    match parse_runner(bytes, FILE, &mut p) {
        Some(r) => {
            assert!(p.is_empty(), "a runner came back with problems");
            Ok(r)
        }
        None => {
            let list = p.finish();
            assert!(!list.is_empty(), "no runner and no problem");
            Err(list)
        }
    }
}

fn parse(v: &Value) -> Result<RunnerJson, Vec<Problem>> {
    parse_bytes(&serde_json::to_vec(v).unwrap())
}

/// The wine sample with `key` set to `v` (`Value::Null` removes it).
fn wine_with(key: &str, v: Value) -> Value {
    let mut r = wine_runner_json();
    if v.is_null() {
        r.as_object_mut().unwrap().remove(key);
    } else {
        r[key] = v;
    }
    r
}

#[track_caller]
fn refused(r: Result<RunnerJson, Vec<Problem>>, code: &str, pointer: &str) {
    let path = format!("{FILE}#{pointer}");
    match r {
        Ok(r) => panic!("expected {code} at {path}, but it parsed: {r:?}"),
        Err(p) => assert!(
            p.iter().any(|x| x.code == code && x.path == path),
            "expected {code} at {path}, got {p:#?}"
        ),
    }
}

fn package(runner: &Value) -> Fx {
    Fx::wine_with_runner(&serde_json::to_vec_pretty(runner).unwrap())
}

// ----- a valid file ----------------------------------------------------------------------------

#[test]
fn a_full_wine_runner_parses_to_its_fields() {
    let r = parse(&wine_runner_json()).unwrap();
    assert_eq!(
        r,
        RunnerJson {
            family: "wine".into(),
            kind: "wine".into(),
            version: "9.20".into(),
            arch: "x86_64".into(),
            entry: Entry::Wine {
                wine: "bin/wine".into(),
                wineserver: "bin/wineserver".into()
            },
            capabilities: vec!["multiarch".into(), "dxvk".into()],
            licence: Some("LGPL-2.1-or-later".into()),
            source_url: Some("https://dl.winehq.org/wine/source/".into()),
        }
    );
}

#[test]
fn proton_emulator_and_engine_runners_parse() {
    let r = parse(
        &json!({"format": 1, "family": "proton-ge", "kind": "proton",
        "version": "GE-Proton10-9", "arch": "x86_64", "entry": {"proton": "proton"}}),
    )
    .unwrap();
    assert_eq!(
        r.entry,
        Entry::Proton {
            proton: "proton".into()
        }
    );
    assert!(r.capabilities.is_empty() && r.licence.is_none() && r.source_url.is_none());
    for kind in ["emulator", "engine"] {
        let r = parse(&json!({"format": 1, "family": "dosbox", "kind": kind,
            "version": "0.74-3", "arch": "x86_64"}))
        .unwrap();
        assert_eq!(r.entry, Entry::None, "{kind}");
    }
}

// ----- the whole file --------------------------------------------------------------------------

#[test]
fn a_garbled_file_is_refused_with_its_code() {
    for (bytes, code) in [
        (&b"{"[..], "runner.invalid_json"),
        (b"", "runner.invalid_json"),
        (b"{\"format\": 1,}", "runner.invalid_json"),
        (b"\xff\xfe{}", "runner.not_utf8"),
    ] {
        let p = parse_bytes(bytes).unwrap_err();
        assert_eq!(p[0].code, code, "{bytes:?}");
        assert_eq!(p[0].path, FILE);
    }
    refused(parse(&json!([1])), "runner.type", "");
    refused(parse(&json!("wine")), "runner.type", "");
}

#[test]
fn a_key_named_twice_is_refused() {
    let text = br#"{"format": 1, "family": "wine", "family": "proton", "kind": "wine",
        "version": "9.20", "arch": "x86_64", "entry": {"wine": "bin/wine", "wineserver": "bin/wineserver"}}"#;
    refused(parse_bytes(text), "json.duplicate_key", "");
    let nested = br#"{"format": 1, "family": "wine", "kind": "wine", "version": "9.20",
        "arch": "x86_64", "entry": {"wine": "bin/wine", "wine": "x", "wineserver": "bin/wineserver"}}"#;
    refused(parse_bytes(nested), "json.duplicate_key", "/entry");
}

#[test]
fn the_size_limit() {
    use ruya_play_format::limits::MAX_RUNNER_JSON_BYTES;
    let base = serde_json::to_vec(&wine_runner_json()).unwrap();
    let padded = |n: u64| {
        let mut b = base.clone();
        b.resize(n as usize, b' ');
        b
    };
    assert!(parse_bytes(&padded(MAX_RUNNER_JSON_BYTES - 1)).is_ok());
    assert!(parse_bytes(&padded(MAX_RUNNER_JSON_BYTES)).is_ok());
    let p = parse_bytes(&padded(MAX_RUNNER_JSON_BYTES + 1)).unwrap_err();
    assert_eq!(
        (p[0].code.as_str(), p[0].path.as_str()),
        ("runner.too_big", FILE)
    );
}

#[test]
fn format_comes_first() {
    refused(
        parse(&wine_with("format", Value::Null)),
        "runner.missing_field",
        "/format",
    );
    for bad in [json!(0), json!(1.5), json!("1"), json!(-1), json!(null)] {
        let mut r = wine_runner_json();
        r["format"] = bad.clone();
        refused(parse(&r), "runner.format_invalid", "/format");
    }
    // A newer format is told so and nothing else: its rules are not ours.
    let p = parse(&json!({"format": 2, "anything": "new", "kind": 7})).unwrap_err();
    assert_eq!(p.len(), 1);
    assert_eq!(p[0].code, "runner.format_too_new");
    assert_eq!(p[0].path, format!("{FILE}#/format"));
    refused(
        parse(&json!({"format": 2.5})),
        "runner.format_too_new",
        "/format",
    );
}

#[test]
fn every_key_is_known_and_the_required_ones_are_there() {
    refused(
        parse(&wine_with("name", json!("Wine"))),
        "runner.unknown_key",
        "/name",
    );
    for key in ["family", "kind", "version", "arch"] {
        refused(
            parse(&wine_with(key, Value::Null)),
            "runner.missing_field",
            &format!("/{key}"),
        );
        refused(
            parse(&wine_with(key, json!(5))),
            "runner.type",
            &format!("/{key}"),
        );
    }
    // Every problem of the file is listed, not only the first.
    let p = parse(&json!({"format": 1, "x": 1, "family": "Wine", "kind": "wine",
        "version": "", "arch": "arm64", "entry": {"wine": "bin/wine", "wineserver": "bin/wineserver"}}))
    .unwrap_err();
    let codes: Vec<&str> = p.iter().map(|x| x.code.as_str()).collect();
    assert_eq!(
        codes,
        [
            "runner.unknown_key",
            "runner.family_invalid",
            "runner.version_invalid",
            "runner.arch_invalid"
        ]
    );
}

// ----- one rule per field ----------------------------------------------------------------------

#[test]
fn family() {
    for ok in ["wine", "proton-ge", "0ad", "scummvm.daily", &"a".repeat(64)] {
        assert!(parse(&wine_with("family", json!(ok))).is_ok(), "{ok}");
    }
    for bad in [
        "",
        "Wine",
        "-wine",
        ".wine",
        "wine_ge",
        "wine ge",
        &"a".repeat(65),
    ] {
        refused(
            parse(&wine_with("family", json!(bad))),
            "runner.family_invalid",
            "/family",
        );
    }
}

#[test]
fn kind() {
    for bad in ["native", "WINE", "", "proton-ge"] {
        refused(
            parse(&wine_with("kind", json!(bad))),
            "runner.kind_invalid",
            "/kind",
        );
    }
}

#[test]
fn version() {
    for ok in ["9.20", "GE-Proton10-9", "1", "0.74-3+dfsg", &"9".repeat(32)] {
        assert!(parse(&wine_with("version", json!(ok))).is_ok(), "{ok}");
    }
    for bad in ["", "latest", "9.0 beta", "9/0", &"9".repeat(33)] {
        refused(
            parse(&wine_with("version", json!(bad))),
            "runner.version_invalid",
            "/version",
        );
    }
}

#[test]
fn arch() {
    for bad in ["i386", "x86-64", "X86_64", "aarch64"] {
        refused(
            parse(&wine_with("arch", json!(bad))),
            "runner.arch_invalid",
            "/arch",
        );
    }
}

#[test]
fn entry() {
    refused(
        parse(&wine_with("entry", Value::Null)),
        "runner.missing_field",
        "/entry",
    );
    refused(
        parse(&wine_with("entry", json!("bin/wine"))),
        "runner.type",
        "/entry",
    );
    refused(
        parse(&wine_with("entry", json!({"wine": "bin/wine"}))),
        "runner.missing_field",
        "/entry/wineserver",
    );
    refused(
        parse(&wine_with(
            "entry",
            json!({"wine": "bin/wine", "wineserver": "bin/wineserver", "winecfg": "bin/winecfg"}),
        )),
        "runner.unknown_key",
        "/entry/winecfg",
    );
    refused(
        parse(&wine_with(
            "entry",
            json!({"wine": 1, "wineserver": "bin/wineserver"}),
        )),
        "runner.type",
        "/entry/wine",
    );
    for bad in [
        "../bin/wine",
        "/usr/bin/wine",
        "bin\\wine",
        "bin/./wine",
        "",
        "c:wine",
    ] {
        refused(
            parse(&wine_with(
                "entry",
                json!({"wine": bad, "wineserver": "bin/wineserver"}),
            )),
            "runner.entry_invalid",
            "/entry/wine",
        );
    }
    // A proton entry has the proton key only; a wine key there is unknown.
    let mut r = json!({"format": 1, "family": "proton", "kind": "proton", "version": "9.0",
        "arch": "x86_64", "entry": {"wine": "bin/wine"}});
    refused(parse(&r), "runner.unknown_key", "/entry/wine");
    refused(parse(&r), "runner.missing_field", "/entry/proton");
    r["entry"] = json!({"proton": "proton"});
    assert!(parse(&r).is_ok());
    // An emulator or engine names no entry: run.command names ${component:<id>} itself.
    for kind in ["emulator", "engine"] {
        refused(
            parse(
                &json!({"format": 1, "family": "x", "kind": kind, "version": "1",
                "arch": "x86_64", "entry": {}}),
            ),
            "runner.entry_invalid",
            "/entry",
        );
    }
}

#[test]
fn capabilities() {
    assert!(parse(&wine_with(
        "capabilities",
        json!(["multiarch", "dxvk", "vkd3d", "ntsync"])
    ))
    .is_ok());
    assert!(parse(&wine_with("capabilities", json!([]))).is_ok());
    refused(
        parse(&wine_with("capabilities", json!("dxvk"))),
        "runner.type",
        "/capabilities",
    );
    refused(
        parse(&wine_with("capabilities", json!(["dxvk", 3]))),
        "runner.type",
        "/capabilities/1",
    );
    refused(
        parse(&wine_with("capabilities", json!(["dx12"]))),
        "runner.capability_invalid",
        "/capabilities/0",
    );
    refused(
        parse(&wine_with("capabilities", json!(["dxvk", "dxvk"]))),
        "runner.capability_invalid",
        "/capabilities/1",
    );
}

#[test]
fn licence_and_source_url() {
    for bad in ["", "<b>GPL</b>", "GPL;rm"] {
        refused(
            parse(&wine_with("licence", json!(bad))),
            "runner.licence_invalid",
            "/licence",
        );
    }
    refused(
        parse(&wine_with("licence", json!(2))),
        "runner.type",
        "/licence",
    );
    for bad in [
        "http://dl.winehq.org/",
        "ftp://x/y",
        "https://",
        "winehq.org",
    ] {
        refused(
            parse(&wine_with("source_url", json!(bad))),
            "runner.url_invalid",
            "/source_url",
        );
    }
}

#[test]
fn hostile_text_in_a_problem_is_escaped() {
    let p = parse(&wine_with("family", json!("w\u{202E}ine"))).unwrap_err();
    assert!(p[0].message.contains("\\u{202E}"), "{}", p[0].message);
    let p = parse(&wine_with("x\u{202E}y", json!(1))).unwrap_err();
    assert!(!p[0].path.contains('\u{202E}'), "{}", p[0].path);
}

// ----- in a package ----------------------------------------------------------------------------

#[test]
fn a_copy_without_runner_json_gets_its_types_defaults() {
    let p = assert_valid(check(&Fx::wine_full()));
    let wine = &p.runners["wine"];
    assert_eq!(
        wine,
        &BundledRunner {
            family: "wine".into(),
            entry: Entry::Wine {
                wine: "bin/wine".into(),
                wineserver: "bin/wineserver".into()
            },
            declared: None,
        }
    );
    assert_eq!(p.bundled_families()["wine"], "wine");
    // Proton: its own family `proton` (never `proton-ge`) and entry `proton`; an emulator: its id.
    let c = |kind: &str, id: &str| ruya_play_format::manifest::Component {
        id: id.into(),
        kind: kind.into(),
        source: "bundled".into(),
        min: None,
        tested: None,
        max_major: None,
        bundled: None,
    };
    let proton = BundledRunner::defaults(&c("proton", "proton"));
    assert_eq!(
        (proton.family.as_str(), proton.entry),
        (
            "proton",
            Entry::Proton {
                proton: "proton".into()
            }
        )
    );
    let emu = BundledRunner::defaults(&c("emulator", "rpcs3"));
    assert_eq!((emu.family.as_str(), emu.entry), ("rpcs3", Entry::None));
    // A native package has no bundled runner at all.
    assert!(assert_valid(check(&Fx::minimal())).runners.is_empty());
}

#[test]
fn a_valid_runner_json_is_what_the_package_reports() {
    let mut r = wine_runner_json();
    r["family"] = json!("wine-ge");
    let p = assert_valid(check(&package(&r)));
    assert_eq!(p.runners["wine"].family, "wine-ge");
    assert_eq!(p.runners["wine"].declared.as_ref().unwrap().version, "9.20");
    assert_eq!(p.bundled_families()["wine"], "wine-ge");
    // The zip form reads it the same way.
    let z = assert_valid(check_zip(package(&r).zip()));
    assert_eq!(z.runners, p.runners);
}

#[test]
fn a_present_but_invalid_runner_json_refuses_the_package_never_defaults() {
    // Garbled: refused, even though the folder would be fine without the file.
    assert_rejected_at(
        check(&Fx::wine_with_runner(b"{\"family\": ")),
        "runner.invalid_json",
        FILE,
    );
    // Only a family (what ruya-pack read leniently before ADR-037).
    assert_rejected_at(
        check(&Fx::wine_with_runner(br#"{"family": "wine"}"#)),
        "runner.missing_field",
        &format!("{FILE}#/format"),
    );
    // validate checks it even when it does not hash the content.
    let fx = Fx::wine_with_runner(b"[]");
    let r = validate(
        &fx.mem(),
        &ValidateOptions {
            verify_content: false,
            ..ValidateOptions::default()
        },
    );
    assert_rejected_at(r, "runner.type", &format!("{FILE}#"));
}

#[test]
fn the_kind_is_the_components_type() {
    let r = json!({"format": 1, "family": "proton", "kind": "proton", "version": "9.0",
        "arch": "x86_64", "entry": {"proton": "bin/wine"}});
    assert_rejected_at(
        check(&package(&r)),
        "runner.kind_mismatch",
        &format!("{FILE}#/kind"),
    );
}

#[test]
fn every_entry_is_a_regular_file_of_the_copy() {
    let at = format!("{FILE}#/entry/wineserver");
    for target in [
        "bin/not-there",
        // A link and a folder are not regular files.
        "lib/libwine.so",
        "lib",
        // Another component's or the payload's file is not in this copy.
        "../../payload/StarHopper.exe",
    ] {
        let mut r = wine_runner_json();
        r["entry"]["wineserver"] = json!(target);
        let code = if target.starts_with("..") {
            "runner.entry_invalid"
        } else {
            "runner.entry_missing"
        };
        assert_rejected_at(check(&package(&r)), code, &at);
    }
}

#[test]
fn runner_json_must_be_a_regular_file() {
    let mut fx = Fx::wine_full();
    fx.links
        .push(("components/wine/runner.json".into(), "bin/wine".into()));
    assert_rejected_at(check(&fx), "runner.not_a_file", FILE);
    let mut fx = Fx::wine_full();
    fx.dirs.push("components/wine/runner.json".into());
    assert_rejected_at(check(&fx), "runner.not_a_file", FILE);
}
