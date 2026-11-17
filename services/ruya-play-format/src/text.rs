//! Plain-text, URL, language-tag and name rules for the strings in `play.json` (05 §4.1).

use crate::limits::{MAX_LANGUAGE_TAG_BYTES, MAX_URL_BYTES, RESERVED_APP_NAMES};
use crate::problem::codes;

/// A broken text rule: the stable code and a message for the developer.
pub type TextFault = (&'static str, String);

fn is_bidi(c: char) -> bool {
    matches!(c, '\u{061C}' | '\u{200E}' | '\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}')
}

fn is_zero_width(c: char) -> bool {
    matches!(
        c,
        '\u{200B}'..='\u{200D}' | '\u{2060}' | '\u{FEFF}' | '\u{00AD}'
    )
}

/// Check that `s` is plain text: no control characters (a line break only when `multiline`), no
/// bidi overrides, no zero-width characters, no markup, no inline links.
///
/// The spec text said such characters are stripped; a signed manifest is shown exactly as written,
/// so the format refuses them and the developer removes them.
pub fn check_plain(s: &str, multiline: bool) -> Result<(), TextFault> {
    for c in s.chars() {
        if c == '\n' && multiline {
            continue;
        }
        if is_bidi(c) {
            return Err((
                codes::TEXT_BIDI,
                format!(
                    "The text contains the invisible direction character U+{:04X}; remove it.",
                    c as u32
                ),
            ));
        }
        if is_zero_width(c) {
            return Err((
                codes::TEXT_ZERO_WIDTH,
                format!(
                    "The text contains the invisible character U+{:04X}; remove it.",
                    c as u32
                ),
            ));
        }
        if c.is_control() {
            return Err((
                codes::TEXT_CONTROL,
                format!(
                    "The text contains the control character U+{:04X}; remove it.",
                    c as u32
                ),
            ));
        }
    }
    let bytes = s.as_bytes();
    for (i, w) in bytes.windows(2).enumerate() {
        if w[0] == b'<' && (w[1].is_ascii_alphabetic() || w[1] == b'/' || w[1] == b'!') {
            return Err((
                codes::TEXT_MARKUP,
                format!("The text looks like markup at position {i}; descriptions are plain text."),
            ));
        }
    }
    if s.contains("://") {
        return Err((
            codes::TEXT_LINK,
            "The text contains a link; put links in \"links\" instead.".into(),
        ));
    }
    Ok(())
}

/// Check the length of `s` in characters.
pub fn check_chars(s: &str, max: usize) -> Result<(), TextFault> {
    let n = s.chars().count();
    if n == 0 {
        return Err((codes::TEXT_EMPTY, "The text is empty.".into()));
    }
    if n > max {
        return Err((
            codes::TEXT_TOO_LONG,
            format!("The text has {n} characters; at most {max}."),
        ));
    }
    Ok(())
}

/// A BCP-47-shaped language tag: 2 or 3 letters, then `-` groups of 2 to 8 letters or digits.
pub fn is_language_tag(tag: &str) -> bool {
    if tag.is_empty() || tag.len() > MAX_LANGUAGE_TAG_BYTES {
        return false;
    }
    let mut parts = tag.split('-');
    let first = parts.next().unwrap_or("");
    if !(2..=3).contains(&first.len()) || !first.bytes().all(|b| b.is_ascii_alphabetic()) {
        return false;
    }
    parts.all(|p| (2..=8).contains(&p.len()) && p.bytes().all(|b| b.is_ascii_alphanumeric()))
}

/// Check an `https` URL: scheme, a host, no user info, no spaces or control characters.
pub fn check_https_url(s: &str) -> Result<(), TextFault> {
    if s.len() > MAX_URL_BYTES {
        return Err((
            codes::URL_INVALID,
            format!("The URL is longer than {MAX_URL_BYTES} bytes."),
        ));
    }
    if s.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err((
            codes::URL_INVALID,
            "The URL contains a space or a control character.".into(),
        ));
    }
    let Some(colon) = s.find(':') else {
        return Err((
            codes::URL_INVALID,
            "The URL has no scheme; write it as https://...".into(),
        ));
    };
    if !s[..colon].eq_ignore_ascii_case("https") {
        return Err((
            codes::URL_NOT_HTTPS,
            format!("Only https:// links are allowed, not \"{}:\".", &s[..colon]),
        ));
    }
    let Some(rest) = s[colon..].strip_prefix("://") else {
        return Err((
            codes::URL_INVALID,
            "Write the link as https://host/...".into(),
        ));
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    if authority.is_empty() {
        return Err((codes::URL_INVALID, "The URL has no host.".into()));
    }
    if authority.contains('@') {
        return Err((
            codes::URL_INVALID,
            "The URL must not contain a user name or password.".into(),
        ));
    }
    Ok(())
}

fn normalise_name(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

/// True when an app name would pass for a system name (05 §4.1).
pub fn is_reserved_app_name(name: &str) -> bool {
    let n = normalise_name(name);
    n.contains("ruyaos") || RESERVED_APP_NAMES.contains(&n.as_str())
}
