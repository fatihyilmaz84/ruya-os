//! `api/play/runner.schema.json` accepts what `runner::parse_runner` accepts, refuses the
//! schema-level faults the parser refuses, and states the same numbers and vocabularies as the
//! crate's constants (the drift check of `tests/schema.rs`, for `runner.json`).

mod common;
#[path = "common/json_schema.rs"]
mod json_schema;

use common::*;
use json_schema::{errors, load_schema};
use ruya_play_format::limits::*;
use ruya_play_format::problem::Problems;
use ruya_play_format::runner::{is_family, parse_runner};
use serde_json::{json, Value};

fn schema() -> Value {
    load_schema("api/play/runner.schema.json")
}

fn schema_errors(v: &Value) -> Vec<String> {
    let s = schema();
    let mut out = Vec::new();
    errors(&s, &s, v, "", &mut out);
    out
}

fn parser_accepts(v: &Value) -> bool {
    let mut p = Problems::new();
    parse_runner(&serde_json::to_vec(v).unwrap(), "runner.json", &mut p).is_some()
}

fn samples() -> Vec<Value> {
    vec![
        wine_runner_json(),
        json!({"format": 1, "family": "proton-ge", "kind": "proton", "version": "GE-Proton10-9",
            "arch": "x86_64", "entry": {"proton": "proton"}, "capabilities": ["ntsync"]}),
        json!({"format": 1, "family": "dosbox", "kind": "engine", "version": "0.74-3",
            "arch": "x86_64"}),
        json!({"format": 1, "family": "rpcs3", "kind": "emulator", "version": "0.0.34",
            "arch": "x86_64", "licence": "GPL-2.0-only"}),
    ]
}

#[test]
fn the_schema_and_the_parser_accept_the_samples() {
    for s in samples() {
        assert!(parser_accepts(&s), "{s}");
        let e = schema_errors(&s);
        assert!(e.is_empty(), "the schema should accept {s}: {e:#?}");
    }
}

fn set(key: &str, v: Value) -> Value {
    let mut r = wine_runner_json();
    if v.is_null() {
        r.as_object_mut().unwrap().remove(key);
    } else {
        r[key] = v;
    }
    r
}

#[test]
fn the_schema_and_the_parser_refuse_the_same_faults() {
    let faults = [
        set("name", json!("Wine")),
        set("format", json!(2)),
        set("format", json!(0)),
        set("format", Value::Null),
        set("family", json!("Wine")),
        set("family", json!("")),
        set("family", json!("a".repeat(65))),
        set("kind", json!("native")),
        set("version", json!("latest")),
        set("version", json!("9".repeat(33))),
        set("arch", json!("i386")),
        set("arch", Value::Null),
        set("entry", Value::Null),
        set("entry", json!({"wine": "bin/wine"})),
        set(
            "entry",
            json!({"wine": "bin/wine", "wineserver": "bin/wineserver", "winecfg": "x"}),
        ),
        set(
            "entry",
            json!({"wine": "../bin/wine", "wineserver": "bin/wineserver"}),
        ),
        set(
            "entry",
            json!({"wine": "/usr/bin/wine", "wineserver": "bin/wineserver"}),
        ),
        set(
            "entry",
            json!({"wine": "bin\\wine", "wineserver": "bin/wineserver"}),
        ),
        set(
            "entry",
            json!({"wine": "bin//wine", "wineserver": "bin/wineserver"}),
        ),
        set(
            "entry",
            json!({"wine": "bin/./wine", "wineserver": "bin/wineserver"}),
        ),
        set("capabilities", json!(["dx12"])),
        set("capabilities", json!(["dxvk", "dxvk"])),
        set("licence", json!("<b>GPL</b>")),
        set("source_url", json!("http://dl.winehq.org/")),
        json!({"format": 1, "family": "dosbox", "kind": "engine", "version": "1",
            "arch": "x86_64", "entry": {}}),
        json!({"format": 1, "family": "proton", "kind": "proton", "version": "9",
            "arch": "x86_64", "entry": {"wine": "bin/wine"}}),
        json!([]),
    ];
    for f in faults {
        assert!(!parser_accepts(&f), "the parser accepted {f}");
        assert!(!schema_errors(&f).is_empty(), "the schema accepted {f}");
    }
}

#[test]
fn the_family_pattern_is_the_parsers_rule() {
    let s = schema();
    let pattern = s["properties"]["family"]["pattern"].as_str().unwrap();
    let re = regex::Regex::new(pattern).unwrap();
    for f in [
        "wine",
        "proton-ge",
        "0ad",
        "a.b-c",
        "",
        "-x",
        ".x",
        "Wine",
        "wine_ge",
        "w ine",
        "wine\n",
        &"a".repeat(MAX_RUNNER_FAMILY_BYTES),
        &"a".repeat(MAX_RUNNER_FAMILY_BYTES + 1),
    ] {
        assert_eq!(re.is_match(f), is_family(f), "{f:?}");
    }
}

#[test]
fn the_schema_states_the_same_limits_as_the_crate() {
    let s = schema();
    let at = |p: &str| {
        s.pointer(p)
            .unwrap_or_else(|| panic!("runner schema has no {p}"))
            .clone()
    };
    let strs = |v: Value| -> Vec<String> {
        let mut out: Vec<String> = v
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x.as_str().unwrap().to_string())
            .collect();
        out.sort();
        out
    };
    let sorted = |a: &[&str]| -> Vec<String> {
        let mut out: Vec<String> = a.iter().map(|x| x.to_string()).collect();
        out.sort();
        out
    };
    let mut keys: Vec<String> = at("/properties")
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect();
    keys.sort();
    assert_eq!(keys, sorted(&RUNNER_KEYS));
    assert_eq!(at("/additionalProperties"), json!(false));
    assert_eq!(strs(at("/required")), sorted(&RUNNER_REQUIRED_KEYS));
    assert_eq!(
        at("/properties/format/maximum"),
        json!(SUPPORTED_RUNNER_FORMAT)
    );
    assert_eq!(strs(at("/properties/kind/enum")), sorted(&COMPONENT_TYPES));
    assert_eq!(at("/properties/arch/const"), json!(RUNNER_ARCH));
    assert_eq!(
        at("/properties/version/maxLength"),
        json!(MAX_COMPONENT_VERSION_BYTES)
    );
    assert!(at("/properties/family/pattern")
        .as_str()
        .unwrap()
        .ends_with(&format!("{{0,{}}}$", MAX_RUNNER_FAMILY_BYTES - 1)));
    assert_eq!(
        strs(at("/properties/capabilities/items/enum")),
        sorted(&RUNNER_CAPABILITIES)
    );
    assert_eq!(
        strs(at("/allOf/0/then/properties/entry/required")),
        sorted(&RUNNER_ENTRY_WINE)
    );
    assert_eq!(
        strs(at("/allOf/1/then/properties/entry/required")),
        sorted(&RUNNER_ENTRY_PROTON)
    );
    assert_eq!(at("/allOf/0/if/properties/kind/const"), json!("wine"));
    assert_eq!(at("/allOf/1/if/properties/kind/const"), json!("proton"));
    // The https rule and the licence rule are the manifest's.
    let play = load_schema("api/play/play.schema.json");
    assert_eq!(at("/$defs/httpsUrl"), play["$defs"]["httpsUrl"]);
    assert_eq!(
        at("/properties/licence/pattern"),
        play["$defs"]["component"]["properties"]["bundled"]["properties"]["licence"]["pattern"]
    );
}
