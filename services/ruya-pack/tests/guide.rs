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
    let schema: Value = serde_json::from_str(
        &std::fs::read_to_string(repo("api/play/play.schema.json")).unwrap(),
    )
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
