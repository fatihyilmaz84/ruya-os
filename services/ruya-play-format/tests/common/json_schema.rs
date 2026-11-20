//! A small JSON Schema validator for the keywords `api/play/*.schema.json` use, shared by the schema
//! tests (`#[path]`-included by `schema.rs` and `runner_schema.rs`, not part of `common`, which
//! other crates' tests include without `regex`). It panics on a keyword it does not know, so a new
//! keyword cannot be silently ignored.
#![allow(dead_code)]

use regex::Regex;
use serde_json::{json, Value};

/// The schema at `rel` (from the repository root), parsed.
pub fn load_schema(rel: &str) -> Value {
    let path = format!("{}/../../{rel}", env!("CARGO_MANIFEST_DIR"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{rel}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{rel} is not JSON: {e}"))
}

const ANNOTATIONS: [&str; 7] = [
    "$schema",
    "$id",
    "title",
    "description",
    "$comment",
    "$defs",
    "default",
];

pub fn resolve<'a>(root: &'a Value, r: &str) -> &'a Value {
    let ptr = r
        .strip_prefix('#')
        .unwrap_or_else(|| panic!("only local refs: {r}"));
    root.pointer(ptr)
        .unwrap_or_else(|| panic!("unresolved ref {r}"))
}

pub fn is_type(v: &Value, t: &str) -> bool {
    match t {
        "object" => v.is_object(),
        "array" => v.is_array(),
        "string" => v.is_string(),
        "boolean" => v.is_boolean(),
        "integer" => v.is_i64() || v.is_u64(),
        "number" => v.is_number(),
        other => panic!("type {other}"),
    }
}

pub fn errors(root: &Value, schema: &Value, v: &Value, at: &str, out: &mut Vec<String>) {
    let Some(s) = schema.as_object() else {
        match schema.as_bool() {
            Some(true) => return,
            Some(false) => return out.push(format!("{at}: false schema")),
            None => panic!("bad schema node"),
        }
    };
    for (k, kv) in s {
        match k.as_str() {
            k if ANNOTATIONS.contains(&k) => {}
            "$ref" => errors(root, resolve(root, kv.as_str().unwrap()), v, at, out),
            "type" => {
                if !is_type(v, kv.as_str().unwrap()) {
                    out.push(format!("{at}: not a {kv}"));
                }
            }
            "enum" => {
                if !kv.as_array().unwrap().contains(v) {
                    out.push(format!("{at}: not one of the allowed values"));
                }
            }
            "const" => {
                if kv != v {
                    out.push(format!("{at}: not {kv}"));
                }
            }
            "minimum" => {
                if v.as_f64().is_some_and(|n| n < kv.as_f64().unwrap()) {
                    out.push(format!("{at}: below {kv}"));
                }
            }
            "maximum" => {
                if v.as_f64().is_some_and(|n| n > kv.as_f64().unwrap()) {
                    out.push(format!("{at}: above {kv}"));
                }
            }
            "minLength" => {
                if v.as_str()
                    .is_some_and(|t| (t.chars().count() as u64) < kv.as_u64().unwrap())
                {
                    out.push(format!("{at}: too short"));
                }
            }
            "maxLength" => {
                if v.as_str()
                    .is_some_and(|t| t.chars().count() as u64 > kv.as_u64().unwrap())
                {
                    out.push(format!("{at}: too long"));
                }
            }
            "pattern" => {
                if let Some(t) = v.as_str() {
                    let re =
                        Regex::new(kv.as_str().unwrap()).unwrap_or_else(|e| panic!("{kv}: {e}"));
                    if !re.is_match(t) {
                        out.push(format!("{at}: does not match {kv}"));
                    }
                }
            }
            "minItems" => {
                if v.as_array()
                    .is_some_and(|a| (a.len() as u64) < kv.as_u64().unwrap())
                {
                    out.push(format!("{at}: too few items"));
                }
            }
            "maxItems" => {
                if v.as_array()
                    .is_some_and(|a| a.len() as u64 > kv.as_u64().unwrap())
                {
                    out.push(format!("{at}: too many items"));
                }
            }
            "uniqueItems" => {
                if let Some(a) = v.as_array() {
                    if kv == &json!(true) && a.iter().enumerate().any(|(i, x)| a[..i].contains(x)) {
                        out.push(format!("{at}: items repeat"));
                    }
                }
            }
            "items" => {
                if let Some(a) = v.as_array() {
                    for (i, x) in a.iter().enumerate() {
                        errors(root, kv, x, &format!("{at}/{i}"), out);
                    }
                }
            }
            "required" => {
                if let Some(o) = v.as_object() {
                    for r in kv.as_array().unwrap() {
                        if !o.contains_key(r.as_str().unwrap()) {
                            out.push(format!("{at}: missing {r}"));
                        }
                    }
                }
            }
            "maxProperties" => {
                if v.as_object()
                    .is_some_and(|o| o.len() as u64 > kv.as_u64().unwrap())
                {
                    out.push(format!("{at}: too many properties"));
                }
            }
            "properties" => {
                if let Some(o) = v.as_object() {
                    for (name, sub) in kv.as_object().unwrap() {
                        if let Some(x) = o.get(name) {
                            errors(root, sub, x, &format!("{at}/{name}"), out);
                        }
                    }
                }
            }
            "additionalProperties" => {
                if let Some(o) = v.as_object() {
                    let known = s.get("properties").and_then(Value::as_object);
                    for (name, x) in o {
                        if known.is_some_and(|k| k.contains_key(name)) {
                            continue;
                        }
                        errors(root, kv, x, &format!("{at}/{name}"), out);
                    }
                }
            }
            "propertyNames" => {
                if let Some(o) = v.as_object() {
                    for name in o.keys() {
                        errors(root, kv, &json!(name), &format!("{at}/{name} (name)"), out);
                    }
                }
            }
            "allOf" => {
                for sub in kv.as_array().unwrap() {
                    errors(root, sub, v, at, out);
                }
            }
            "oneOf" => {
                let n = kv
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter(|sub| valid(root, sub, v))
                    .count();
                if n != 1 {
                    out.push(format!("{at}: matches {n} of the oneOf branches"));
                }
            }
            "not" => {
                if valid(root, kv, v) {
                    out.push(format!("{at}: matches a pattern that is not allowed"));
                }
            }
            "if" | "then" => {
                if k == "if" && valid(root, kv, v) {
                    if let Some(t) = s.get("then") {
                        errors(root, t, v, at, out);
                    }
                }
            }
            other => panic!("the test validator does not know the keyword {other}"),
        }
    }
}

pub fn valid(root: &Value, schema: &Value, v: &Value) -> bool {
    let mut e = Vec::new();
    errors(root, schema, v, "", &mut e);
    e.is_empty()
}
