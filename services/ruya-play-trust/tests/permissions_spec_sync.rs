//! The permission table of 05 §8 and `PERMISSIONS` say the same (RUY-851): every row's key, value,
//! Flatpak metadata lines, risk and words, the row every app gets, the high-risk pairs and the keys
//! that are not in the vocabulary. The spec's markdown table is parsed; a change on either side
//! without the other fails here.

use ruya_play_format::limits::PERMISSION_KEYS;
use ruya_play_trust::permissions::{display_socket, ALWAYS, ALWAYS_WORDS};
use ruya_play_trust::{Risk, HIGH_RISK_PAIRS, PERMISSIONS};
use std::collections::BTreeSet;

const HEADER: &str = "| Key | Value | Flatpak metadata | Risk | Plain words |";

/// One row of the spec's table, its cells trimmed.
struct Row {
    key: String,
    value: String,
    metadata: String,
    risk: String,
    words: String,
}

fn spec_rows() -> Vec<Row> {
    let path = format!(
        "{}/../../docs/specs/05-play-packages.md",
        env!("CARGO_MANIFEST_DIR")
    );
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
    let mut lines = text.lines().skip_while(|l| l.trim() != HEADER);
    assert!(lines.next().is_some(), "05 has no table headed {HEADER}");
    lines
        .skip(1) // |---|
        .take_while(|l| l.starts_with('|'))
        .map(|l| {
            let cells: Vec<String> = l
                .trim()
                .trim_matches('|')
                .split('|')
                .map(|c| c.trim().to_string())
                .collect();
            assert_eq!(cells.len(), 5, "a row of 5 cells: {l}");
            Row {
                key: cells[0].clone(),
                value: cells[1].clone(),
                metadata: cells[2].clone(),
                risk: cells[3].trim_matches('*').to_string(),
                words: cells[4].clone(),
            }
        })
        .collect()
}

/// The `code` spans of a cell.
fn ticked(cell: &str) -> Vec<String> {
    cell.split('`')
        .enumerate()
        .filter(|(i, _)| i % 2 == 1)
        .map(|(_, s)| s.to_string())
        .collect()
}

/// The metadata lines of a cell: its code spans that start with a section.
fn lines(cell: &str) -> Vec<String> {
    ticked(cell)
        .into_iter()
        .filter(|s| s.starts_with('['))
        .collect()
}

/// The text between the first pair of double quotes.
fn quoted(cell: &str) -> String {
    let mut parts = cell.split('"');
    parts.next();
    parts.next().unwrap_or_default().to_string()
}

fn risk_word(r: Risk) -> &'static str {
    match r {
        Risk::Low => "low",
        Risk::Medium => "medium",
        Risk::High => "high",
    }
}

#[test]
fn every_value_row_of_the_spec_is_the_tables_row() {
    let spec: BTreeSet<(String, String, Vec<String>, String, String)> = spec_rows()
        .into_iter()
        .filter(|r| r.key.starts_with('`') && !r.key.contains('+') && !r.risk.is_empty())
        .map(|r| {
            let key = ticked(&r.key).remove(0);
            let value = ticked(&r.value).first().cloned().unwrap_or_default();
            (key, value, lines(&r.metadata), r.risk, quoted(&r.words))
        })
        .collect();
    let code: BTreeSet<(String, String, Vec<String>, String, String)> = PERMISSIONS
        .iter()
        .map(|p| {
            (
                p.key.to_string(),
                p.value.to_string(),
                p.grants.iter().map(|g| g.text()).collect(),
                risk_word(p.risk).to_string(),
                p.words.to_string(),
            )
        })
        .collect();
    let only_spec: Vec<_> = spec.difference(&code).collect();
    let only_code: Vec<_> = code.difference(&spec).collect();
    assert!(
        only_spec.is_empty() && only_code.is_empty(),
        "05 §8 and PERMISSIONS disagree.\nonly in the spec: {only_spec:#?}\nonly in the code: {only_code:#?}"
    );
    assert_eq!(spec.len(), PERMISSIONS.len(), "a value is listed twice");
}

#[test]
fn the_row_every_app_gets_is_the_tables() {
    let rows = spec_rows();
    let always = rows
        .iter()
        .find(|r| r.key == "(always)")
        .expect("05 §8 has the (always) row");
    let mut code: Vec<String> = ALWAYS.iter().map(|g| g.text()).collect();
    code.push(display_socket("native").text());
    let mut spec = lines(&always.metadata);
    code.sort();
    spec.sort();
    assert_eq!(spec, code);
    assert_eq!(quoted(&always.words), ALWAYS_WORDS);
    assert_eq!(always.risk, "low");
    // Windows programs get X11 instead of Wayland, as the row says.
    assert!(always
        .metadata
        .contains("`sockets=x11` instead for the `wine` and `proton`"));
    for runner in ["wine", "proton"] {
        assert_eq!(display_socket(runner).text(), "[Context] sockets=x11");
    }
}

#[test]
fn the_high_risk_pairs_are_the_specs() {
    let spec: Vec<(String, String, String, String)> = spec_rows()
        .into_iter()
        .filter(|r| r.key.contains('+') && r.key.starts_with('`'))
        .map(|r| {
            let t = ticked(&r.key);
            (t[0].clone(), t[1].clone(), r.risk, quoted(&r.words))
        })
        .collect();
    let code: Vec<(String, String, String, String)> = HIGH_RISK_PAIRS
        .iter()
        .map(|p| {
            (
                p.a.to_string(),
                p.b.to_string(),
                "high".to_string(),
                p.words.to_string(),
            )
        })
        .collect();
    assert_eq!(spec, code);
}

#[test]
fn keys_without_a_risk_are_not_in_the_vocabulary() {
    let rows = spec_rows();
    let missing: Vec<String> = rows
        .iter()
        .filter(|r| r.risk.is_empty() && r.key != "`reasons`")
        .flat_map(|r| ticked(&r.key))
        .collect();
    assert_eq!(missing, ["microphone", "camera", "bluetooth"]);
    for k in &missing {
        assert!(!PERMISSION_KEYS.contains(&k.as_str()), "{k} is a key");
    }
    // Every key of the vocabulary but `reasons` has a row.
    for k in PERMISSION_KEYS.iter().filter(|k| **k != "reasons") {
        assert!(
            rows.iter()
                .any(|r| ticked(&r.key).first().map(String::as_str) == Some(*k)),
            "05 §8 has no row for {k}"
        );
    }
}
