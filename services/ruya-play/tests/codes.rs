//! The importer's codes are stable, unique, asserted by a test, listed in the spec, and do not
//! collide with the format's or the trust crate's; its status words are the contract's.

use ruya_play::{codes, JobStatus, MethodStatus};
use std::collections::HashSet;

fn read(path: &str) -> String {
    std::fs::read_to_string(format!("{}/{path}", env!("CARGO_MANIFEST_DIR")))
        .unwrap_or_else(|e| panic!("{path}: {e}"))
}

#[test]
fn codes_are_unique_dotted_lower_case_and_new() {
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
            "{c} is a format code"
        );
        assert!(
            !ruya_play_trust::codes::ALL.contains(c),
            "{c} is a trust code"
        );
    }
}

#[test]
fn every_code_is_asserted_by_a_test() {
    let files = [
        "tests/install.rs",
        "tests/cancel.rs",
        "tests/jobs.rs",
        "tests/toctou.rs",
        "tests/modes.rs",
        "tests/helper.rs",
        "src/core/installed.rs",
        "src/core/jobs.rs",
    ];
    let tests: String = files.iter().map(|f| read(f)).collect();
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
fn the_status_words_are_the_contracts() {
    let xml = read("../../api/dbus/org.ruyaos.Play1.xml");
    for s in JobStatus::ALL {
        assert!(
            xml.contains(&format!("\"{}\"", s.as_str())),
            "Play1.xml lacks {}",
            s.as_str()
        );
    }
    for s in [
        MethodStatus::Ok,
        MethodStatus::UnknownSource,
        MethodStatus::UnknownJob,
        MethodStatus::TooLate,
        MethodStatus::Busy,
        MethodStatus::Forbidden,
        MethodStatus::Invalid,
        MethodStatus::Failed,
    ] {
        assert!(
            xml.contains(&format!("\"{}\"", s.as_str())),
            "Play1.xml lacks {}",
            s.as_str()
        );
    }
    for phase in [
        "staging",
        "verifying",
        "vetting-art",
        "committing",
        "installing",
    ] {
        assert!(
            xml.contains(&format!("\"{phase}\"")),
            "Play1.xml lacks {phase}"
        );
    }
}
