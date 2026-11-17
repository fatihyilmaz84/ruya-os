//! Test support only: `tests/hostile_install.rs` runs every hostile fixture of RUY-92 through the
//! full install (RUY-99). The fixtures are the format crate's own tests
//! (`ruya-play-format/tests/hostile.rs`), so a fixture added there is installed here too. This
//! script copies that file into `OUT_DIR` with its three header lines changed so it can be
//! `include!`d: the inner doc comment and `mod common;` go, and `validate` is no longer imported
//! from the format crate (the test supplies an install-backed one). The library does not use it.

use std::path::PathBuf;

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("set by cargo"));
    let src = manifest.join("../ruya-play-format/tests/hostile.rs");
    println!("cargo:rerun-if-changed={}", src.display());
    let text =
        std::fs::read_to_string(&src).unwrap_or_else(|e| panic!("reading {}: {e}", src.display()));
    const MOD: &str = "mod common;";
    const USE: &str = "use ruya_play_format::{validate, EntryKind, ValidateOptions};";
    let (mut saw_mod, mut saw_use) = (false, false);
    let mut out = String::with_capacity(text.len());
    for line in text.lines() {
        if line.starts_with("//!") {
            continue;
        }
        if line.trim() == MOD {
            saw_mod = true;
            continue;
        }
        if line.trim() == USE {
            saw_use = true;
            out.push_str("use ruya_play_format::{EntryKind, ValidateOptions};\n");
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    assert!(
        saw_mod && saw_use,
        "the header of {} changed: update ruya-play/build.rs ({MOD:?} and {USE:?} expected)",
        src.display()
    );
    let dest =
        PathBuf::from(std::env::var("OUT_DIR").expect("set by cargo")).join("hostile_cases.rs");
    std::fs::write(&dest, out).unwrap_or_else(|e| panic!("writing {}: {e}", dest.display()));
}
