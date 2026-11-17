//! Every trust error code is stable, unique, asserted by a test, listed in the spec, and does not
//! collide with a format code.

use ruya_play_trust::codes;
use std::collections::HashSet;

fn read(path: &str) -> String {
    std::fs::read_to_string(format!("{}/{path}", env!("CARGO_MANIFEST_DIR")))
        .unwrap_or_else(|e| panic!("{path}: {e}"))
}

#[test]
fn codes_are_unique_dotted_lower_case_and_not_format_codes() {
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
        assert!(
            !ruya_play_format::codes::ALL.contains(c),
            "{c} is also a format code"
        );
    }
}

#[test]
fn every_code_is_asserted_by_a_test() {
    let tests: String = ["signing", "tiers", "continuity", "state", "revocation"]
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

#[test]
fn the_domain_prefixes_are_the_ones_in_the_spec() {
    use ruya_play_trust::envelope::Domain;
    let spec = read("../../docs/specs/05-play-packages.md");
    for d in [
        Domain::PlaySig,
        Domain::StoreSig,
        Domain::Rotation,
        Domain::Blocklist,
    ] {
        let p = std::str::from_utf8(d.prefix()).unwrap();
        let shown = format!("`{}\\0`", p.trim_end_matches('\0'));
        assert!(p.ends_with('\0'), "{p:?}");
        assert!(spec.contains(&shown), "the spec does not name {shown}");
    }
}
