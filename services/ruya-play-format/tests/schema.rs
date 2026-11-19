//! `api/play/play.schema.json` accepts the valid packages' manifests, rejects the schema-level
//! hostile ones, and states the same numbers and vocabularies as the crate's constants.
//!
//! The validator is the small one in `common/json_schema.rs`, shared with `runner_schema.rs`.

mod common;
#[path = "common/json_schema.rs"]
mod json_schema;

use common::*;
use json_schema::{errors, load_schema};
use ruya_play_format::limits::*;
use serde_json::{json, Value};

fn schema() -> Value {
    load_schema("api/play/play.schema.json")
}

fn problems(m: &Value) -> Vec<String> {
    let s = schema();
    let mut out = Vec::new();
    errors(&s, &s, m, "", &mut out);
    out
}

#[track_caller]
fn assert_schema_ok(m: &Value) {
    let p = problems(m);
    assert!(
        p.is_empty(),
        "the schema should accept this manifest: {p:#?}"
    );
}

#[track_caller]
fn assert_schema_rejects(m: &Value, needle: &str) {
    let p = problems(m);
    assert!(
        p.iter().any(|x| x.contains(needle)),
        "expected a schema error mentioning {needle}, got {p:#?}"
    );
}

fn with(key: &str, v: Value) -> Value {
    let mut m = Fx::minimal().manifest;
    m[key] = v;
    m
}

fn with_run(key: &str, v: Value) -> Value {
    let mut m = Fx::minimal().manifest;
    m["run"][key] = v;
    m
}

// ----- accepts -------------------------------------------------------------------------------

#[test]
fn the_schema_accepts_the_valid_packages() {
    assert_schema_ok(&Fx::minimal().manifest);
    assert_schema_ok(&Fx::wine_full().manifest);
}

#[test]
fn the_schema_ignores_unknown_keys_outside_the_strict_objects_and_a_declared_installed_mb() {
    let mut m = Fx::wine_full().manifest;
    m["from_a_newer_tool"] = json!([1, {"a": 2}]);
    m["developer"]["twitter"] = json!("@dev");
    m["art"]["hologram"] = json!("art/x.png");
    assert_eq!(m["requirements"]["installed_mb"], 4800);
    assert_schema_ok(&m);
}

#[test]
fn the_schema_accepts_what_the_validator_accepts_for_ids_names_and_env() {
    for id in ["com.example.my-game", "a.b.c", "io.github.user.Game_2"] {
        assert_schema_ok(&with("id", json!(id)));
    }
    for name in ["WINEDLLOVERRIDES", "DXVK_HUD", "MANGOHUD", "MY_GAME", "TZ"] {
        assert_schema_ok(&with_run("env", json!({ name: "1" })));
    }
    assert_schema_ok(&with("summary", json!({"en": "1 < 2 and 3 > 2"})));
    assert_schema_ok(&with("description", json!({"en": "one\n\ntwo"})));
}

// ----- rejects the schema-level hostile fixtures ---------------------------------------------

#[test]
fn unknown_permission_key() {
    assert_schema_rejects(
        &with("permissions", json!({"camera": true})),
        "/permissions/camera",
    );
    assert_schema_rejects(
        &with("permissions", json!({"microphone": true})),
        "/permissions/microphone",
    );
    assert_schema_rejects(
        &with("permissions", json!({"bluetooth": true})),
        "/permissions/bluetooth",
    );
}

#[test]
fn unknown_run_key() {
    assert_schema_rejects(&with_run("shell", json!("sh -c x")), "/run/shell");
}

#[test]
fn format_from_the_future() {
    assert_schema_rejects(&with("format", json!(2)), "/format");
    assert_schema_rejects(&with("format", json!(0)), "/format");
}

#[test]
fn http_link() {
    for bad in [
        "http://example.com",
        "javascript:alert(1)",
        "file:///etc/passwd",
        "https://user:pw@example.com/",
        "https://",
    ] {
        assert_schema_rejects(
            &with("links", json!([{"kind": "homepage", "url": bad}])),
            "/links/0/url",
        );
    }
}

#[test]
fn name_with_bidi_override() {
    assert_schema_rejects(
        &with("name", json!({"en": "Game\u{202E}exe.pdf"})),
        "/name/en",
    );
    assert_schema_rejects(&with("name", json!({"en": "Ga\u{200B}me"})), "/name/en");
    assert_schema_rejects(&with("summary", json!({"en": "<b>x</b>"})), "/summary/en");
}

#[test]
fn flatpak_id_invalid() {
    assert_schema_rejects(&with("id", json!("com.example-games.star")), "/id");
    assert_schema_rejects(&with("id", json!("com.example")), "/id");
    assert_schema_rejects(&with("id", json!("com.1example.game")), "/id");
}

#[test]
fn env_names_the_platform_owns() {
    assert_schema_rejects(
        &with_run("env", json!({"WINEPREFIX": "/tmp/p"})),
        "WINEPREFIX",
    );
    assert_schema_rejects(
        &with_run("env", json!({"VK_ICD_FILENAMES": "x"})),
        "VK_ICD_FILENAMES",
    );
    assert_schema_rejects(
        &with_run("env", json!({"STEAM_COMPAT_DATA_PATH": "x"})),
        "STEAM_COMPAT_DATA_PATH",
    );
    assert_schema_rejects(
        &with_run("env", json!({"__GLX_VENDOR_LIBRARY_NAME": "x"})),
        "__GLX_VENDOR_LIBRARY_NAME",
    );
    assert_schema_rejects(&with_run("env", json!({"LD_PRELOAD": "x"})), "LD_PRELOAD");
    for name in ENV_DENY_EXACT {
        assert_schema_rejects(&with_run("env", json!({ name: "x" })), name);
    }
    for p in ENV_DENY_PREFIX {
        let name = format!("{p}X");
        assert_schema_rejects(&with_run("env", json!({ name.clone(): "x" })), &name);
    }
}

#[test]
fn cross_references_stay_with_the_validator() {
    // A schema cannot know the file table; these are accepted by it and refused by the crate.
    assert_schema_ok(&with_run("discs", json!(["payload/not-there.iso"])));
    assert_schema_ok(&with("art", json!({"icon": "art/not-there.png"})));
}

// ----- numbers and vocabularies equal the constants -------------------------------------------

#[test]
fn the_schema_states_the_same_limits_as_the_crate() {
    let s = schema();
    let at = |p: &str| {
        s.pointer(p)
            .unwrap_or_else(|| panic!("schema has no {p}"))
            .clone()
    };
    let n = |p: &str| {
        at(p)
            .as_u64()
            .unwrap_or_else(|| panic!("{p} is not a number")) as usize
    };
    let list = |p: &str| -> Vec<String> {
        at(p)
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x.as_str().unwrap().to_string())
            .collect()
    };
    let strs = |a: &[&str]| -> Vec<String> { a.iter().map(|x| x.to_string()).collect() };
    let sorted = |mut v: Vec<String>| {
        v.sort();
        v
    };

    assert_eq!(at("/properties/format/maximum"), json!(SUPPORTED_FORMAT));
    assert_eq!(n("/properties/id/maxLength"), MAX_ID_BYTES);
    assert_eq!(n("/properties/version/maxLength"), MAX_VERSION_CHARS);
    assert_eq!(n("/$defs/localizedName/maxProperties"), MAX_LANGUAGES);
    assert_eq!(
        n("/$defs/localizedName/additionalProperties/maxLength"),
        MAX_NAME_CHARS
    );
    assert_eq!(
        n("/$defs/localizedSummary/additionalProperties/maxLength"),
        MAX_SUMMARY_CHARS
    );
    assert_eq!(
        n("/$defs/localizedDescription/additionalProperties/maxLength"),
        MAX_DESCRIPTION_CHARS
    );
    assert_eq!(
        n("/$defs/localizedCaption/additionalProperties/maxLength"),
        MAX_CAPTION_CHARS
    );
    assert_eq!(
        n("/$defs/localizedReason/additionalProperties/maxLength"),
        MAX_REASON_CHARS
    );
    assert_eq!(
        n("/$defs/credit/properties/name/maxLength"),
        MAX_CREDIT_NAME_CHARS
    );
    assert_eq!(n("/$defs/languageTag/maxLength"), MAX_LANGUAGE_TAG_BYTES);
    assert_eq!(n("/$defs/httpsUrl/maxLength"), MAX_URL_BYTES);
    assert_eq!(n("/properties/genres/maxItems"), MAX_GENRES);
    assert_eq!(n("/properties/tags/maxItems"), MAX_TAGS);
    assert_eq!(n("/properties/tags/items/maxLength"), MAX_TAG_CHARS);
    assert_eq!(n("/properties/languages/maxItems"), MAX_LANGUAGES);
    assert_eq!(n("/properties/links/maxItems"), MAX_LINKS);
    assert_eq!(
        n("/properties/players/properties/max/maximum"),
        MAX_PLAYERS as usize
    );
    assert_eq!(
        n("/properties/age_rating/properties/content/maxProperties"),
        MAX_AGE_ATTRIBUTES
    );
    assert_eq!(
        n("/properties/licence/properties/package/maxLength"),
        MAX_LICENCE_BYTES
    );
    assert_eq!(
        n("/properties/art/properties/screenshots/maxItems"),
        MAX_SCREENSHOTS
    );
    // 05 section 5: when the list is there it holds at least one (art.no_screenshots).
    assert_eq!(n("/properties/art/properties/screenshots/minItems"), 1);
    assert_eq!(n("/properties/components/maxItems"), MAX_COMPONENTS);
    assert_eq!(
        n("/properties/data/properties/saves/maxItems"),
        MAX_DATA_PATHS
    );
    assert_eq!(
        n("/properties/data/properties/cache/maxItems"),
        MAX_DATA_PATHS
    );
    assert_eq!(n("/$defs/localId/maxLength"), MAX_LOCAL_ID_BYTES);
    assert_eq!(n("/$defs/version/maxLength"), MAX_COMPONENT_VERSION_BYTES);
    assert_eq!(n("/$defs/command/maxItems"), MAX_COMMAND_ARGS);
    assert_eq!(n("/$defs/command/items/maxLength"), MAX_ARG_BYTES);
    assert_eq!(
        n("/$defs/run/properties/env/maxProperties"),
        MAX_ENV_ENTRIES
    );
    assert_eq!(
        n("/$defs/run/properties/env/additionalProperties/maxLength"),
        MAX_ENV_VALUE_BYTES
    );
    assert_eq!(n("/$defs/run/properties/setup/maxItems"), MAX_SETUP_STEPS);
    assert_eq!(n("/$defs/run/properties/discs/maxItems"), MAX_DISCS);

    // The env deny table, character for character.
    let exact = ENV_DENY_EXACT.join("|");
    let prefixes = ENV_DENY_PREFIX.join("|");
    let want = format!("^({exact})$|^({prefixes})");
    assert_eq!(
        at("/$defs/run/properties/env/propertyNames/not/pattern"),
        json!(want)
    );
    let name_pattern = format!("^[A-Z][A-Z0-9_]{{0,{}}}$", MAX_ENV_NAME_BYTES - 1);
    assert_eq!(
        at("/$defs/run/properties/env/propertyNames/pattern"),
        json!(name_pattern)
    );

    // Vocabularies.
    assert_eq!(list("/properties/genres/items/enum"), strs(&GENRES));
    assert_eq!(
        list("/properties/links/items/properties/kind/enum"),
        strs(&LINK_KINDS)
    );
    assert_eq!(list("/properties/controller/enum"), strs(&CONTROLLER));
    assert_eq!(
        list("/properties/players/properties/modes/items/enum"),
        strs(&PLAYER_MODES)
    );
    assert_eq!(
        list("/properties/age_rating/properties/content/additionalProperties/enum"),
        strs(&OARS_VALUES)
    );
    assert_eq!(
        list("/properties/requirements/properties/gpu_api/items/enum"),
        strs(&GPU_APIS)
    );
    assert_eq!(list("/$defs/run/properties/runner/enum"), strs(&RUNNERS));
    assert_eq!(
        list("/$defs/component/properties/type/enum"),
        strs(&COMPONENT_TYPES)
    );
    assert_eq!(
        list("/$defs/component/properties/source/enum"),
        strs(&COMPONENT_SOURCES)
    );
    assert_eq!(
        list("/$defs/run/properties/launch_mode/enum"),
        strs(&LAUNCH_MODES)
    );
    assert_eq!(
        list("/$defs/run/properties/prefix/properties/arch/enum"),
        strs(&PREFIX_ARCHES)
    );
    assert_eq!(
        list("/$defs/permissions/properties/input/enum"),
        strs(&INPUT_MODES)
    );
    assert_eq!(
        list("/$defs/permissions/properties/removable_media/enum"),
        strs(&REMOVABLE_MEDIA)
    );

    // The strict objects' keys.
    let keys =
        |p: &str| -> Vec<String> { sorted(at(p).as_object().unwrap().keys().cloned().collect()) };
    assert_eq!(
        keys("/$defs/permissions/properties"),
        sorted(strs(&PERMISSION_KEYS))
    );
    assert_eq!(keys("/$defs/run/properties"), sorted(strs(&RUN_KEYS)));
    assert_eq!(
        keys("/$defs/component/properties"),
        sorted(strs(&COMPONENT_KEYS))
    );
    assert_eq!(
        keys("/$defs/component/properties/bundled/properties"),
        sorted(strs(&BUNDLED_KEYS))
    );
    assert_eq!(
        keys("/$defs/run/properties/prefix/properties"),
        sorted(strs(&PREFIX_KEYS))
    );
    assert_eq!(
        keys("/$defs/run/properties/setup/items/properties"),
        sorted(strs(&SETUP_KEYS))
    );
    for p in [
        "/$defs/permissions",
        "/$defs/run",
        "/$defs/component",
        "/$defs/component/properties/bundled",
        "/$defs/run/properties/prefix",
    ] {
        assert_eq!(
            at(&format!("{p}/additionalProperties")),
            json!(false),
            "{p} must be strict"
        );
    }
    // The properties of ordinary objects stay open.
    for p in [
        "",
        "/properties/developer",
        "/properties/requirements",
        "/properties/art",
    ] {
        assert!(
            s.pointer(&format!("{p}/additionalProperties")).is_none(),
            "{p} must ignore unknown keys"
        );
    }
}

#[test]
fn data_paths_and_cwd_have_no_dot_dot_parts_in_the_schema_either() {
    for bad in [
        "data:../x",
        "data:a/../b",
        "data:a//b",
        "data:a/",
        "data:",
        "data:./x",
        "/etc",
        "x:y",
    ] {
        assert_schema_rejects(&with("data", json!({"saves": [bad]})), "/data/saves/0");
    }
    for ok in [
        "data:.hidden/x",
        "prefix:drive_c/users/steamuser/Documents/Star Hopper",
        "config:a..b",
    ] {
        assert_schema_ok(&with("data", json!({"saves": [ok]})));
    }
    assert_schema_rejects(&with_run("cwd", json!("${payload}/../x")), "/run/cwd");
    assert_schema_rejects(&with_run("cwd", json!("${payload}/..")), "/run/cwd");
    assert_schema_ok(&with_run("cwd", json!("${payload}/sub/..x")));
}

#[test]
fn the_newer_env_names_are_in_the_schema() {
    for name in [
        "WINEARCH",
        "TMPDIR",
        "GCONV_PATH",
        "LOCPATH",
        "NLSPATH",
        "PRESSURE_VESSEL_X",
    ] {
        assert_schema_rejects(&with_run("env", json!({ name: "x" })), name);
    }
}
