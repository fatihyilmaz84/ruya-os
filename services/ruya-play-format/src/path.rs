//! The path rules of 05 §4.2, applied to names before any content is read.

use crate::limits::{MAX_COMPONENT_BYTES, MAX_PATH_BYTES};
use crate::problem::{codes, Problems};
use std::collections::HashMap;
use unicode_normalization::is_nfc;

/// A broken path rule: the stable code and a message for the developer.
pub type PathFault = (&'static str, String);

const RESERVED_DEVICE_NAMES: [&str; 4] = ["CON", "PRN", "AUX", "NUL"];

fn is_reserved_device(component: &str) -> bool {
    let stem = component
        .split('.')
        .next()
        .unwrap_or("")
        .trim_end_matches(' ');
    let upper = stem.to_uppercase();
    if RESERVED_DEVICE_NAMES.contains(&upper.as_str()) {
        return true;
    }
    for prefix in ["COM", "LPT"] {
        if let Some(rest) = upper.strip_prefix(prefix) {
            if rest.len() == 1 && matches!(rest.as_bytes()[0], b'1'..=b'9') {
                return true;
            }
        }
    }
    false
}

fn is_control(c: char) -> bool {
    c.is_control()
}

/// Check one package path against every rule of 05 §4.2 and report the first one it breaks.
pub fn check_path(p: &str) -> Result<(), PathFault> {
    if p.is_empty() {
        return Err((codes::PATH_EMPTY, "The path is empty.".into()));
    }
    if p.contains('\\') {
        return Err((
            codes::PATH_BACKSLASH,
            "Use / between folders, never a backslash (Windows tools: check the pack settings)."
                .into(),
        ));
    }
    if p.starts_with('/') {
        return Err((
            codes::PATH_ABSOLUTE,
            "The path starts with /; paths are relative to the package.".into(),
        ));
    }
    if p.len() > MAX_PATH_BYTES {
        return Err((
            codes::PATH_TOO_LONG,
            format!("The path is longer than {MAX_PATH_BYTES} bytes."),
        ));
    }
    if p.chars().any(is_control) {
        return Err((
            codes::PATH_CONTROL,
            "The path contains a control character.".into(),
        ));
    }
    if !is_nfc(p) {
        return Err((
            codes::PATH_NOT_NFC,
            "The path is not NFC-normalised Unicode.".into(),
        ));
    }
    for component in p.split('/') {
        if component.is_empty() {
            return Err((
                codes::PATH_EMPTY_COMPONENT,
                "The path has an empty part (// or a trailing /).".into(),
            ));
        }
        if component == "." {
            return Err((codes::PATH_DOT, "The path contains a . part.".into()));
        }
        if component == ".." {
            return Err((
                codes::PATH_TRAVERSAL,
                "The path contains .., which leaves the package.".into(),
            ));
        }
        if component.len() > MAX_COMPONENT_BYTES {
            return Err((
                codes::PATH_COMPONENT_TOO_LONG,
                format!("A part of the path is longer than {MAX_COMPONENT_BYTES} bytes."),
            ));
        }
        if component.contains(':') {
            return Err((
                codes::PATH_COLON,
                "A part of the path contains a colon.".into(),
            ));
        }
        if component.ends_with('.') || component.ends_with(' ') {
            return Err((
                codes::PATH_TRAILING_DOT_SPACE,
                "A part of the path ends with a dot or a space.".into(),
            ));
        }
        if is_reserved_device(component) {
            return Err((
                codes::PATH_RESERVED_NAME,
                format!("\"{component}\" is a reserved Windows device name."),
            ));
        }
    }
    Ok(())
}

/// The path with each part lower-cased, for the case-insensitive uniqueness rule.
fn fold(s: &str) -> String {
    s.to_lowercase()
}

/// Report paths that differ only in letter case, including through a shared parent folder
/// (`A/x` and `a/y` collide on exFAT). Each pair is reported once, at the later path.
pub fn check_case_collisions<'a>(paths: impl Iterator<Item = &'a str>, problems: &mut Problems) {
    let mut seen: HashMap<String, String> = HashMap::new();
    for p in paths {
        let mut prefix_end = 0;
        for component in p.split('/') {
            prefix_end += component.len();
            let prefix = &p[..prefix_end];
            let folded = fold(prefix);
            match seen.get(&folded) {
                Some(first) if first != prefix => {
                    problems.add(
                        codes::PATH_CASE_COLLISION,
                        p,
                        format!("\"{prefix}\" and \"{first}\" differ only in letter case; they are the same name on USB sticks and under Wine."),
                    );
                    break;
                }
                Some(_) => {}
                None => {
                    seen.insert(folded, prefix.to_string());
                }
            }
            prefix_end += 1;
        }
    }
}
