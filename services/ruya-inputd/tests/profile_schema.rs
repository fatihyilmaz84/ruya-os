//! The controller profile schema v1 (docs/specs/schemas/input-profile-v1.json, 06-input.md §7)
//! accepts the owner's example profile (06-input-requirements.md §9.3) and refuses broken ones.
//!
//! The validator here implements only the JSON Schema keywords the schema uses and panics on any
//! other, so the schema cannot grow a keyword this test silently ignores. It is test code: the
//! service's own validation (RUY-42, `ruya_inputd::profile`) is a typed model, and every fixture
//! here goes through both: they accept and refuse the same files, and the service refuses on top
//! what a schema cannot express (06 §7, "Limits"). This is also the conformance test of the public
//! format (ADR-022): the sample in samples/controller-profile-example, the example of the
//! developer chapter (docs/developers/controller-input.md) and the built-in profiles pass both.

use ruya_inputd::book::Book;
use ruya_inputd::profile;
use serde_json::Value;
use std::path::PathBuf;

fn repo_file(rel: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(rel);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn schema() -> Value {
    serde_json::from_str(&repo_file("docs/specs/schemas/input-profile-v1.json"))
        .expect("schema is JSON")
}

/// The example of §9.3, cut out of the requirements file itself.
fn requirements_example() -> Value {
    let text = repo_file("docs/specs/06-input-requirements.md");
    let section = text
        .split("## 9.3 Example profile")
        .nth(1)
        .expect("§9.3 exists");
    let mut block = Vec::new();
    for line in section.lines().skip_while(|l| l.trim() != "{") {
        block.push(line);
        if line.trim_end() == "}" {
            break;
        }
    }
    serde_json::from_str(&block.join("\n")).expect("the §9.3 example is JSON")
}

// ---- a minimal validator for the keywords the schema uses ----

fn resolve<'a>(root: &'a Value, reference: &str) -> &'a Value {
    let name = reference
        .strip_prefix("#/$defs/")
        .unwrap_or_else(|| panic!("unsupported $ref {reference}"));
    &root["$defs"][name]
}

fn type_ok(t: &str, v: &Value) -> bool {
    match t {
        "object" => v.is_object(),
        "array" => v.is_array(),
        "string" => v.is_string(),
        "boolean" => v.is_boolean(),
        "number" => v.is_number(),
        "integer" => v.is_i64() || v.is_u64(),
        other => panic!("unsupported type {other}"),
    }
}

/// A character class (ranges) with its repeat bounds.
type Atom = (Vec<(char, char)>, usize, usize);

/// `^` atoms `$`, an atom being `[class]` or a literal character, optionally followed by `{n}` or
/// `{m,n}`; a class holds characters and ranges `a-z` (a `-` first or last is literal).
fn pattern_ok(pattern: &str, s: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    assert!(
        p.first() == Some(&'^') && p.last() == Some(&'$'),
        "pattern must be anchored: {pattern}"
    );
    let mut atoms: Vec<Atom> = Vec::new();
    let mut i = 1;
    while i < p.len() - 1 {
        let set = if p[i] == '[' {
            let end = i + p[i..].iter().position(|&c| c == ']').expect("closed class");
            let body = &p[i + 1..end];
            let mut set = Vec::new();
            let mut k = 0;
            while k < body.len() {
                if k + 2 < body.len() && body[k + 1] == '-' {
                    set.push((body[k], body[k + 2]));
                    k += 3;
                } else {
                    set.push((body[k], body[k]));
                    k += 1;
                }
            }
            i = end + 1;
            set
        } else {
            assert!(
                !"()|*+?.\\".contains(p[i]),
                "unsupported pattern syntax in {pattern}"
            );
            i += 1;
            vec![(p[i - 1], p[i - 1])]
        };
        let (mut lo, mut hi) = (1, 1);
        if i < p.len() - 1 && p[i] == '{' {
            let end = i + p[i..]
                .iter()
                .position(|&c| c == '}')
                .expect("closed quantifier");
            let q: String = p[i + 1..end].iter().collect();
            let mut parts = q.split(',').map(|n| n.parse::<usize>().expect("number"));
            lo = parts.next().unwrap();
            hi = parts.next().unwrap_or(lo);
            i = end + 1;
        }
        atoms.push((set, lo, hi));
    }
    fn go(atoms: &[Atom], s: &[char]) -> bool {
        let Some(((set, lo, hi), rest)) = atoms.split_first() else {
            return s.is_empty();
        };
        let fits = |c: &char| set.iter().any(|(a, b)| a <= c && c <= b);
        let run = s.iter().take(*hi).take_while(|c| fits(c)).count();
        (*lo..=run).rev().any(|n| go(rest, &s[n..]))
    }
    go(&atoms, &s.chars().collect::<Vec<_>>())
}

fn validate(root: &Value, schema: &Value, v: &Value, path: &str, errors: &mut Vec<String>) {
    let obj = schema.as_object().expect("a schema is an object");
    for (key, rule) in obj {
        match key.as_str() {
            "$schema" | "$id" | "title" | "description" | "$defs" => {}
            "$ref" => validate(root, resolve(root, rule.as_str().unwrap()), v, path, errors),
            "type" => {
                if !type_ok(rule.as_str().unwrap(), v) {
                    errors.push(format!("{path}: not a {rule}"));
                }
            }
            "const" => {
                if v != rule {
                    errors.push(format!("{path}: must be {rule}"));
                }
            }
            "enum" => {
                if !rule.as_array().unwrap().contains(v) {
                    errors.push(format!("{path}: {v} is not one of {rule}"));
                }
            }
            "oneOf" => {
                let passing = rule
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter(|alt| {
                        let mut e = Vec::new();
                        validate(root, alt, v, path, &mut e);
                        e.is_empty()
                    })
                    .count();
                if passing != 1 {
                    errors.push(format!(
                        "{path}: matches {passing} alternatives, not exactly one"
                    ));
                }
            }
            "required" => {
                if let Some(o) = v.as_object() {
                    for name in rule.as_array().unwrap() {
                        if !o.contains_key(name.as_str().unwrap()) {
                            errors.push(format!("{path}: {name} is required"));
                        }
                    }
                }
            }
            "properties" => {
                if let Some(o) = v.as_object() {
                    for (name, sub) in rule.as_object().unwrap() {
                        if let Some(value) = o.get(name) {
                            validate(root, sub, value, &format!("{path}/{name}"), errors);
                        }
                    }
                }
            }
            "additionalProperties" => {
                assert_eq!(
                    rule,
                    &Value::Bool(false),
                    "only additionalProperties: false is supported"
                );
                if let Some(o) = v.as_object() {
                    let known = obj.get("properties").and_then(Value::as_object);
                    for name in o.keys() {
                        if !known.is_some_and(|k| k.contains_key(name)) {
                            errors.push(format!("{path}: unknown field {name}"));
                        }
                    }
                }
            }
            "items" => {
                if let Some(a) = v.as_array() {
                    for (n, item) in a.iter().enumerate() {
                        validate(root, rule, item, &format!("{path}/{n}"), errors);
                    }
                }
            }
            "minItems" | "maxItems" => {
                if let Some(a) = v.as_array() {
                    let limit = rule.as_u64().unwrap() as usize;
                    if (key == "minItems" && a.len() < limit)
                        || (key == "maxItems" && a.len() > limit)
                    {
                        errors.push(format!("{path}: {} items, {key} {limit}", a.len()));
                    }
                }
            }
            "minLength" | "maxLength" => {
                if let Some(s) = v.as_str() {
                    let limit = rule.as_u64().unwrap() as usize;
                    let len = s.chars().count();
                    if (key == "minLength" && len < limit) || (key == "maxLength" && len > limit) {
                        errors.push(format!("{path}: length {len}, {key} {limit}"));
                    }
                }
            }
            "minimum" | "maximum" => {
                if let Some(n) = v.as_f64() {
                    let limit = rule.as_f64().unwrap();
                    if (key == "minimum" && n < limit) || (key == "maximum" && n > limit) {
                        errors.push(format!("{path}: {n}, {key} {limit}"));
                    }
                }
            }
            "pattern" => {
                if let Some(s) = v.as_str() {
                    if !pattern_ok(rule.as_str().unwrap(), s) {
                        errors.push(format!("{path}: {s:?} does not match {rule}"));
                    }
                }
            }
            other => panic!("the schema uses {other}, which this validator does not check"),
        }
    }
}

fn errors_of(profile: &Value) -> Vec<String> {
    let root = schema();
    let mut errors = Vec::new();
    validate(&root, &root, profile, "", &mut errors);
    errors
}

/// The service's verdict on the same document.
fn typed(profile: &Value) -> Result<profile::Profile, Vec<String>> {
    profile::parse(&profile.to_string())
}

fn with(mut base: Value, pointer: &str, value: Value) -> Value {
    let (parent, key) = pointer.rsplit_once('/').unwrap();
    base.pointer_mut(if parent.is_empty() { "" } else { parent })
        .unwrap()
        .as_object_mut()
        .unwrap()
        .insert(key.to_string(), value);
    base
}

#[test]
fn the_requirements_example_profile_is_valid() {
    assert_eq!(errors_of(&requirements_example()), Vec::<String>::new());
    typed(&requirements_example()).expect("the service accepts the §9.3 example");
}

#[test]
fn a_full_profile_with_every_section_is_valid() {
    let profile: Value = serde_json::from_str(
        r#"{
          "schema_version": 1, "id": "global-default", "name": "Default", "scope": { "type": "global" },
          "match": { "family": "playstation" }, "output": { "type": "xbox" },
          "mappings": [
            { "from": "south", "to": { "type": "button", "code": "east" } },
            { "from": "right_trigger", "to": { "type": "mouse_button", "code": "left" }, "threshold": 0.4 },
            { "from": { "raw": { "node": "pad", "type": 1, "code": 316 } }, "to": { "type": "none" } },
            { "from": "west", "to": { "type": "key", "code": "r" }, "mode": "turbo", "turbo_hz": 15 }
          ],
          "layers": [ { "id": "menu", "activation": "momentary", "trigger": "l1", "priority": 1,
                        "mappings": [ { "from": "right_x", "to": { "type": "scroll", "code": "x" } } ] } ],
          "chords": [ { "inputs": ["guide", "west"], "to": { "type": "action", "code": "screenshot" } } ],
          "macros": [ { "id": "reload", "cancel_on_release": true,
                        "steps": [ { "type": "tap", "target": { "type": "key", "code": "r" } }, { "type": "wait", "ms": 50 } ] } ],
          "settings": { "gyro_enabled": false, "rumble_enabled": true, "rumble_strength": 0.5,
                        "left_stick": { "inner_deadzone": 0.08, "curve": "precise", "invert_y": false } }
        }"#,
    )
    .unwrap();
    assert_eq!(errors_of(&profile), Vec::<String>::new());
    let model = typed(&profile).expect("the service accepts it");
    assert_eq!(model.to_value(), profile, "and writes it back unchanged");
}

#[test]
fn broken_profiles_are_refused_with_the_path() {
    let base = requirements_example();
    let cases: Vec<(Value, &str)> = vec![
        (
            with(base.clone(), "/schema_version", Value::from(2)),
            "/schema_version",
        ),
        (
            with(base.clone(), "/script", Value::from("rm -rf /")),
            "unknown field script",
        ),
        (
            with(base.clone(), "/id", Value::from("Cyberpunk 2077")),
            "/id",
        ),
        (
            with(
                base.clone(),
                "/scope",
                serde_json::json!({ "type": "game" }),
            ),
            "/scope",
        ),
        (
            with(
                base.clone(),
                "/scope",
                serde_json::json!({ "type": "game", "game_id": "x", "platform_id": "y" }),
            ),
            "/scope",
        ),
        (
            with(
                base.clone(),
                "/output",
                serde_json::json!({ "type": "n64" }),
            ),
            "/output/type",
        ),
        (
            with(
                base.clone(),
                "/mappings",
                serde_json::json!([{ "from": "south" }]),
            ),
            "/mappings/0",
        ),
        (
            with(
                base.clone(),
                "/mappings",
                serde_json::json!([{ "from": "button_17", "to": { "type": "none" } }]),
            ),
            "/mappings/0/from",
        ),
        (
            with(
                base.clone(),
                "/mappings",
                serde_json::json!([{ "from": "west", "to": { "type": "key", "code": "r" }, "turbo_hz": 120 }]),
            ),
            "/mappings/0/turbo_hz",
        ),
        (
            with(
                base.clone(),
                "/layers",
                Value::Array(vec![
                    serde_json::json!({ "id": "l", "activation": "toggle", "mappings": [] });
                    9
                ]),
            ),
            "maxItems 8",
        ),
        (
            with(
                base.clone(),
                "/macros",
                serde_json::json!([{ "id": "m", "steps": [{ "type": "wait", "ms": 1 }] }]),
            ),
            "/macros/0/steps/0/ms",
        ),
        (
            with(
                base.clone(),
                "/chords",
                serde_json::json!([{ "inputs": ["guide"], "to": { "type": "none" } }]),
            ),
            "minItems 2",
        ),
        (
            with(
                base.clone(),
                "/settings",
                serde_json::json!({ "left_stick": { "inner_deadzone": 1.5 } }),
            ),
            "/settings/left_stick/inner_deadzone",
        ),
        (with(base, "/name", Value::from("")), "/name"),
    ];
    for (profile, expected) in cases {
        let errors = errors_of(&profile);
        assert!(
            errors.iter().any(|e| e.contains(expected)),
            "expected an error containing {expected:?}, got {errors:?} for {profile}"
        );
        let errors = typed(&profile).expect_err("the service refuses it too");
        assert!(
            errors.iter().any(|e| e.contains(expected)),
            "the service: expected {expected:?}, got {errors:?} for {profile}"
        );
    }
}

/// Hostile files (an import is untrusted, requirements §15): both refuse them.
#[test]
fn hostile_files_are_refused_by_both() {
    let base = requirements_example();
    let mapping = |m: Value| with(base.clone(), "/mappings", Value::Array(vec![m]));
    let none = serde_json::json!({ "from": "south", "to": { "type": "none" } });
    let cases: Vec<(Value, &str)> = vec![
        (
            with(base.clone(), "/id", Value::from("../../etc/passwd")),
            "/id",
        ),
        (
            with(base.clone(), "/id", Value::from("a".repeat(65))),
            "/id",
        ),
        (
            with(base.clone(), "/inherits", Value::from("/root")),
            "/inherits",
        ),
        (
            with(base.clone(), "/name", Value::from("n".repeat(65))),
            "/name",
        ),
        (
            with(
                base.clone(),
                "/scope",
                serde_json::json!({ "type": "game", "game_id": "../x" }),
            ),
            "/scope",
        ),
        (
            with(
                base.clone(),
                "/match",
                serde_json::json!({ "device": "/dev/input/event3" }),
            ),
            "/match/device",
        ),
        (
            mapping(
                serde_json::json!({ "from": { "raw": { "node": "pad", "type": 1, "code": 99999 } },
                                        "to": { "type": "none" } }),
            ),
            "/mappings/0/from",
        ),
        (
            mapping(
                serde_json::json!({ "from": { "raw": { "node": "/dev/mem", "type": 1, "code": 1 } },
                                        "to": { "type": "none" } }),
            ),
            "/mappings/0/from",
        ),
        (
            mapping(serde_json::json!({ "from": "south", "to": { "type": "exec", "code": "sh" } })),
            "/mappings/0/to/type",
        ),
        (
            mapping(
                serde_json::json!({ "from": "south", "to": { "type": "key", "code": "$(reboot)" } }),
            ),
            "/mappings/0/to/code",
        ),
        (
            mapping(
                serde_json::json!({ "from": "south", "to": { "type": "axis", "code": "left_x", "scale": 1e9 } }),
            ),
            "/mappings/0/to/scale",
        ),
        (
            mapping(
                serde_json::json!({ "from": "south", "to": { "type": "none" }, "threshold": "0.5" }),
            ),
            "/mappings/0/threshold",
        ),
        (
            with(
                base.clone(),
                "/mappings",
                Value::Array(vec![none.clone(); 257]),
            ),
            "maxItems 256",
        ),
        (
            with(
                base.clone(),
                "/layers",
                serde_json::json!([{ "id": "l", "activation": "toggle",
                                     "mappings": [{ "from": "south", "to": { "type": "none" }, "run": "x" }] }]),
            ),
            "unknown field run",
        ),
        (
            with(
                base.clone(),
                "/macros",
                serde_json::json!([{ "id": "m", "steps": vec![serde_json::json!({ "type": "wait", "ms": 10 }); 33] }]),
            ),
            "maxItems 32",
        ),
        (
            with(
                base.clone(),
                "/macros",
                Value::Array(vec![
                    serde_json::json!({ "id": "m", "steps": [{ "type": "wait", "ms": 10 }] });
                    17
                ]),
            ),
            "maxItems 16",
        ),
        (
            with(
                base.clone(),
                "/chords",
                serde_json::json!([{ "inputs": ["south", "east", "west", "north", "l1"], "to": { "type": "none" } }]),
            ),
            "maxItems 4",
        ),
        (
            with(
                base.clone(),
                "/settings",
                serde_json::json!({ "trigger_threshold": -1 }),
            ),
            "/settings/trigger_threshold",
        ),
        (
            with(
                base.clone(),
                "/settings",
                serde_json::json!({ "left_stick": { "sensitivity": 40 } }),
            ),
            "/settings/left_stick/sensitivity",
        ),
        (
            with(
                base.clone(),
                "/settings",
                serde_json::json!({ "left_stick": { "curve": "cubic" } }),
            ),
            "/settings/left_stick/curve",
        ),
        (
            with(base, "/description", Value::from("d".repeat(513))),
            "/description",
        ),
    ];
    for (profile, expected) in cases {
        let errors = errors_of(&profile);
        assert!(
            errors.iter().any(|e| e.contains(expected)),
            "schema: expected {expected:?}, got {errors:?}"
        );
        let errors = typed(&profile).expect_err("the service refuses it too");
        assert!(
            errors.iter().any(|e| e.contains(expected)),
            "service: expected {expected:?}, got {errors:?}"
        );
    }
}

/// What a schema cannot say (06 §7, "Limits"): the schema passes these, the service does not.
#[test]
fn the_service_refuses_what_the_schema_cannot_express() {
    let base = requirements_example();
    let wait = |ms: i64| serde_json::json!({ "type": "wait", "ms": ms });
    let macros = |steps: Value| {
        with(
            base.clone(),
            "/macros",
            serde_json::json!([{ "id": "m", "steps": steps }]),
        )
    };
    let cases: Vec<(String, &str)> = vec![
        (
            macros(serde_json::json!([wait(10000), wait(10)])).to_string(),
            "the waits add up to 10010 ms",
        ),
        (macros(serde_json::json!([{ "type": "wait" }])).to_string(), "a wait step needs ms"),
        (macros(serde_json::json!([{ "type": "press" }])).to_string(), "a press step needs a target"),
        (
            macros(serde_json::json!([{ "type": "tap", "target": { "type": "macro", "code": "m" } }])).to_string(),
            "a macro step never targets a macro",
        ),
        (
            with(
                base.clone(),
                "/mappings",
                serde_json::json!([{ "from": "south", "to": { "type": "button", "code": "jump" } }]),
            )
            .to_string(),
            "is not a button",
        ),
        (
            with(
                base.clone(),
                "/settings",
                serde_json::json!({ "left_stick": { "inner_deadzone": 0.5, "outer_deadzone": 0.5 } }),
            )
            .to_string(),
            "add up to 1 or more",
        ),
        (
            with(base.clone(), "/inherits", Value::from("cyberpunk-2077")).to_string(),
            "cannot inherit from itself",
        ),
        (
            with(base.clone(), "/name", Value::from(format!("a{}b", char::from_u32(0x1b).unwrap()))).to_string(),
            "/name: contains a control",
        ),
        (
            with(base.clone(), "/name", Value::from(format!("a{}b", char::from_u32(0x2067).unwrap()))).to_string(),
            "/name: contains a control or text-direction",
        ),
        // The size cap: a valid document padded with whitespace past 64 KiB.
        (format!("{base}{}", " ".repeat(profile::MAX_BYTES)), "larger than 65536 bytes"),
    ];
    for (text, expected) in cases {
        let value: Value = serde_json::from_str(&text).expect("JSON");
        assert_eq!(
            errors_of(&value),
            Vec::<String>::new(),
            "the schema accepts {text:.200}"
        );
        let errors = profile::parse(&text).expect_err("the service refuses it");
        assert!(
            errors.iter().any(|e| e.contains(expected)),
            "expected {expected:?}, got {errors:?}"
        );
    }
}

/// Conformance of the public format: the sample, the chapter's example (which must be the sample)
/// and the console's built-in profiles pass the schema and the service.
#[test]
fn the_sample_the_chapter_and_the_builtins_are_valid() {
    let sample_text = repo_file("samples/controller-profile-example/profile.json");
    let sample: Value = serde_json::from_str(&sample_text).expect("the sample is JSON");
    assert_eq!(errors_of(&sample), Vec::<String>::new());
    typed(&sample).expect("the service accepts the sample");

    let chapter = repo_file("docs/developers/controller-input.md");
    let after = chapter
        .split("This file is also `samples/controller-profile-example/profile.json`")
        .nth(1)
        .expect("the chapter names the sample");
    let block: String = after
        .split("```json")
        .nth(1)
        .and_then(|b| b.split("```").next())
        .expect("a json block follows")
        .to_owned();
    let example: Value = serde_json::from_str(&block).expect("the chapter's example is JSON");
    assert_eq!(example, sample, "the chapter's example is the sample");

    let mut book = Book::default();
    for id in ["default", "nintendo"] {
        let text = book.get("p1", id).expect("a built-in");
        let value: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(errors_of(&value), Vec::<String>::new(), "{id}");
    }
}

#[test]
fn the_pattern_subset_matches_like_json_schema() {
    let id = "^[a-z0-9][a-z0-9._-]{0,63}$";
    assert!(pattern_ok(id, "global-default"));
    assert!(pattern_ok(id, "a"));
    assert!(!pattern_ok(id, ""));
    assert!(!pattern_ok(id, "-leading"));
    assert!(!pattern_ok(id, "Upper"));
    assert!(pattern_ok(id, &"a".repeat(64)));
    assert!(!pattern_ok(id, &"a".repeat(65)));
}
