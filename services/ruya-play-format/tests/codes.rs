//! Every error code is stable, unique, asserted by a test, and listed in the spec.

use ruya_play_format::codes;
use std::collections::HashSet;

fn read(path: &str) -> String {
    std::fs::read_to_string(format!("{}/{path}", env!("CARGO_MANIFEST_DIR")))
        .unwrap_or_else(|e| panic!("{path}: {e}"))
}

#[test]
fn codes_are_unique_dotted_lower_case() {
    let mut seen = HashSet::new();
    for c in codes::ALL {
        assert!(seen.insert(*c), "{c} appears twice");
        let (group, rest) = c
            .split_once('.')
            .unwrap_or_else(|| panic!("{c} is not dotted"));
        assert!(!group.is_empty() && !rest.is_empty());
        assert!(
            c.bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'.' || b == b'_'),
            "{c}"
        );
    }
}

#[test]
fn every_code_is_asserted_by_a_test() {
    let tests: String = [
        "hostile",
        "limits",
        "forms",
        "schema",
        "hardening",
        "runner",
        "runner_schema",
    ]
    .iter()
    .map(|t| read(&format!("tests/{t}.rs")))
    .collect();
    let unasserted: Vec<&&str> = codes::ALL
        .iter()
        .filter(|c| !tests.contains(&format!("\"{c}\"")))
        .collect();
    assert!(
        unasserted.is_empty(),
        "no test asserts these codes: {unasserted:?}"
    );
}

#[test]
fn every_code_is_in_the_spec() {
    let spec = read("../../docs/specs/05-play-packages.md");
    let missing: Vec<&&str> = codes::ALL
        .iter()
        .filter(|c| !spec.contains(&format!("`{c}`")))
        .collect();
    assert!(
        missing.is_empty(),
        "docs/specs/05-play-packages.md does not list: {missing:?}"
    );
}
