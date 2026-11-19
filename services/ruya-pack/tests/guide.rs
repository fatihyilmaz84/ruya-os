//! The developer guide `docs/developers/play-packages.md` (RUY-105) says nothing the tool and the
//! schema contradict:
//!   - its error catalogue is generated from `fixes::catalogue()` and must equal it;
//!   - its field reference lists exactly the properties of `api/play/play.schema.json`.
//!
//! To rewrite the catalogue after a code or a fix line changed:
//! `RUYA_WRITE_CATALOGUE=1 cargo test -p ruya-pack --test guide`.

use ruya_pack::fixes::catalogue;
use serde_json::Value;
use std::collections::BTreeSet;
use std::path::PathBuf;

const START: &str = "<!-- catalogue:start -->";
const END: &str = "<!-- catalogue:end -->";

fn repo(rel: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join(rel)
}

fn guide() -> String {
    std::fs::read_to_string(repo("docs/developers/play-packages.md")).expect("the guide")
}

/// The catalogue as the guide shows it: one table row per code, text made safe for markdown.
fn render() -> String {
    let mut out = String::from("| Code | What to do |\n|---|---|\n");
    for (code, fix) in catalogue() {
        let fix = fix
            .replace('|', "\\|")
            .replace('<', "&lt;")
            .replace('>', "&gt;");
        out.push_str(&format!("| `{code}` | {fix} |\n"));
    }
    out
}

#[test]
fn the_guides_error_catalogue_is_the_tools_catalogue() {
    let text = guide();
    let (a, b) = (
        text.find(START).expect("catalogue start marker"),
        text.find(END).expect("catalogue end marker"),
    );
    assert!(a < b);
    let want = format!("{START}\n\n{}\n{END}", render());
    if std::env::var("RUYA_WRITE_CATALOGUE").is_ok() {
        let new = format!("{}{}{}", &text[..a], want, &text[b + END.len()..]);
        std::fs::write(repo("docs/developers/play-packages.md"), new).unwrap();
        return;
    }
    assert_eq!(
        &text[a..b + END.len()],
        want,
        "the catalogue is stale: run RUYA_WRITE_CATALOGUE=1 cargo test -p ruya-pack --test guide"
    );
}

/// Every property path of the schema: `run.prefix.arch`, `components[].bundled.path`, ...
fn schema_paths(root: &Value, node: &Value, at: &str, out: &mut BTreeSet<String>) {
    if let Some(r) = node.get("$ref").and_then(Value::as_str) {
        let target = root.pointer(r.strip_prefix('#').unwrap()).unwrap();
        schema_paths(root, target, at, out);
    }
    if let Some(all) = node.get("allOf").and_then(Value::as_array) {
        for sub in all {
            schema_paths(root, sub, at, out);
        }
    }
    if let Some(props) = node.get("properties").and_then(Value::as_object) {
        for (k, v) in props {
            let path = if at.is_empty() {
                k.clone()
            } else {
                format!("{at}.{k}")
            };
            out.insert(path.clone());
            schema_paths(root, v, &path, out);
        }
    }
    if let Some(items) = node.get("items") {
        schema_paths(root, items, &format!("{at}[]"), out);
    }
}

#[test]
fn the_field_reference_lists_the_schemas_properties_and_no_others() {
    let schema: Value =
        serde_json::from_str(&std::fs::read_to_string(repo("api/play/play.schema.json")).unwrap())
            .unwrap();
    let mut want = BTreeSet::new();
    schema_paths(&schema, &schema, "", &mut want);
    assert!(want.contains("run.prefix.epoch") && want.contains("components[].bundled.path"));

    let text = guide();
    let section = text
        .split("\n## ")
        .find(|s| s.starts_with("Field reference"))
        .expect("a '## Field reference' section");
    let mut have = BTreeSet::new();
    for line in section.lines() {
        if let Some(rest) = line.strip_prefix("| `") {
            if let Some((name, _)) = rest.split_once("` |") {
                assert!(have.insert(name.to_string()), "listed twice: {name}");
            }
        }
    }
    let missing: Vec<_> = want.difference(&have).collect();
    let extra: Vec<_> = have.difference(&want).collect();
    assert!(
        missing.is_empty() && extra.is_empty(),
        "field reference vs schema: missing {missing:?}, not in the schema {extra:?}"
    );
}

fn schema() -> Value {
    serde_json::from_str(&std::fs::read_to_string(repo("api/play/play.schema.json")).unwrap())
        .unwrap()
}

/// The guide row of one field: the line that starts with its name.
fn row(text: &str, field: &str) -> String {
    let start = format!("| `{field}` |");
    text.lines()
        .find(|l| l.starts_with(&start))
        .unwrap_or_else(|| panic!("no row for {field}"))
        .to_string()
}

#[test]
fn the_field_reference_states_the_schemas_constraints() {
    let (s, text) = (schema(), guide());
    let num = |p: &str| {
        s.pointer(p)
            .and_then(Value::as_u64)
            .unwrap_or_else(|| panic!("{p}"))
    };

    // art.screenshots: 1 to 20 when present.
    let shots = "/properties/art/properties/screenshots";
    let r = row(&text, "art.screenshots");
    assert!(r.contains(&format!(
        "{} to {}",
        num(&format!("{shots}/minItems")),
        num(&format!("{shots}/maxItems"))
    )));

    // players.min / players.max / age_rating.scheme are required by the schema, and say so.
    for (obj, key) in [
        ("players", "min"),
        ("players", "max"),
        ("age_rating", "scheme"),
    ] {
        let req = s
            .pointer(&format!("/properties/{obj}/required"))
            .unwrap()
            .as_array()
            .unwrap();
        assert!(
            req.iter().any(|v| v == key),
            "{obj}.{key} not required in the schema"
        );
        assert!(
            row(&text, &format!("{obj}.{key}")).contains("Required"),
            "{obj}.{key}"
        );
    }

    // art.logo may be a map from language tag.
    assert!(s
        .pointer("/properties/art/properties/logo/oneOf/1/type")
        .is_some());
    assert!(row(&text, "art.logo").contains("map from language tag"));

    // data.*: the byte limit and the forbidden parts.
    let max = num("/$defs/dataPath/maxLength");
    assert!(row(&text, "data.saves").contains(&format!("{max} bytes")));
    assert!(row(&text, "data.cache").contains("same rules"));
    assert!(row(&text, "data.saves").contains("`..`") && row(&text, "data.saves").contains("`\\`"));

    // run.discs: the payload/ prefix.
    let pat = s.pointer("/$defs/run/properties/discs/items/pattern");
    let pat = pat.or_else(|| s.pointer("/properties/run/properties/discs/items/pattern"));
    assert!(pat
        .and_then(Value::as_str)
        .unwrap()
        .starts_with("^payload/"));
    assert!(row(&text, "run.discs").contains("`payload/`"));
}

/// The first `run` object that carries `properties.env`.
fn find<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    match v {
        Value::Object(m) => m.get(key).or_else(|| m.values().find_map(|c| find(c, key))),
        Value::Array(a) => a.iter().find_map(|c| find(c, key)),
        _ => None,
    }
}

#[test]
fn the_run_env_and_cwd_rows_name_every_rule_of_the_schema() {
    let (s, text) = (schema(), guide());
    let env = find(&s, "env").expect("run.env");
    let row_env = row(&text, "run.env");

    // Every name and prefix of the deny pattern appears in the row.
    let deny = env["propertyNames"]["not"]["pattern"].as_str().unwrap();
    let (names, prefixes) = deny.split_once("$|^(").expect("deny pattern shape");
    let names = names.trim_start_matches("^(").trim_end_matches(')');
    let prefixes = prefixes.trim_end_matches(')');
    for n in names.split('|') {
        assert!(
            row_env.contains(&format!("`{n}`")),
            "deny name {n} missing from run.env"
        );
    }
    for p in prefixes.split('|') {
        assert!(
            row_env.contains(&format!("`{p}`")),
            "deny prefix {p} missing from run.env"
        );
    }
    let len = env["additionalProperties"]["maxLength"].as_u64().unwrap();
    assert!(row_env.contains(&format!("{len} bytes")));
    assert!(row_env.contains("[A-Z][A-Z0-9_]*"));

    // run.cwd: every placeholder of the pattern appears in the row.
    let cwd = find(&s, "cwd").unwrap()["pattern"].as_str().unwrap();
    let group = cwd
        .split_once("\\{(")
        .unwrap()
        .1
        .split_once(")\\}")
        .unwrap()
        .0;
    let row_cwd = row(&text, "run.cwd");
    for ph in group.split('|') {
        let ph = if ph.starts_with("component:") {
            "component:<id>"
        } else {
            ph
        };
        assert!(
            row_cwd.contains(&format!("${{{ph}}}")),
            "cwd placeholder {ph}"
        );
    }
}

/// The `runner.json` examples (a `json` block with `format`, `family` and `kind`) of `doc`, as
/// written.
fn runner_examples(doc: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = doc;
    while let Some(start) = rest.find("```json\n") {
        let body = &rest[start + 8..];
        let Some(end) = body.find("```") else { break };
        let block = &body[..end];
        rest = &body[end + 3..];
        // Chosen by its text, not by parsing: a broken example must reach the parser and fail
        // the test, never be skipped as "not a runner.json".
        if ["\"family\"", "\"kind\"", "\"arch\""]
            .iter()
            .all(|k| block.contains(k))
        {
            out.push(block.to_string());
        }
    }
    out
}

#[test]
fn the_runner_json_examples_are_what_the_parser_accepts() {
    use ruya_play_format::problem::Problems;
    use ruya_play_format::runner::parse_runner;
    for doc in [
        "docs/developers/play-packages.md",
        "docs/specs/05-play-packages.md",
    ] {
        let text = std::fs::read_to_string(repo(doc)).expect(doc);
        let examples = runner_examples(&text);
        assert!(!examples.is_empty(), "{doc} has no runner.json example");
        for e in examples {
            let mut p = Problems::new();
            let parsed = parse_runner(e.as_bytes(), "runner.json", &mut p);
            assert!(
                parsed.is_some(),
                "{doc}: the parser refuses the example: {:#?}\n{e}",
                p.finish()
            );
        }
    }
}
