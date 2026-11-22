//! Valve's text KeyValues ("VDF"), the format of Steam's `config.vdf`, `libraryfolders.vdf`,
//! `appmanifest_*.acf` and of a compatibility tool's `compatibilitytool.vdf`. A reader and a
//! writer, no OS: a file is text in, text out (reading it safely is `ruya-fs`'s).
//!
//! The reader takes quoted and unquoted tokens, `//` comments and a byte order mark.
//! Keys keep their order and may repeat (a file is rewritten without losing what it had); lookups
//! ignore case, as Steam does. Anything that is not the format is an `Err` with a short reason,
//! never a panic: the files belong to Steam and to the player.

use std::fmt::Write as _;

/// Nesting deeper than this is not a Steam file.
const MAX_DEPTH: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    Str(String),
    Obj(Vec<Entry>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub key: String,
    pub value: Value,
}

impl Value {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(s) => Some(s),
            Value::Obj(_) => None,
        }
    }

    /// The entries of a block (none for a string).
    pub fn entries(&self) -> &[Entry] {
        match self {
            Value::Obj(list) => list,
            Value::Str(_) => &[],
        }
    }

    /// The first child named `key` (any case; Steam files mix `appid` and `AppID`).
    pub fn get(&self, key: &str) -> Option<&Value> {
        find(self.entries(), key).map(|e| &e.value)
    }

    pub fn get_str(&self, key: &str) -> Option<&str> {
        self.get(key).and_then(Value::as_str)
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Token {
    Text(String),
    Open,
    Close,
}

fn tokens(text: &str) -> Result<Vec<Token>, String> {
    let mut out = Vec::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            c if c.is_whitespace() || c == '\u{feff}' => {}
            '{' => out.push(Token::Open),
            '}' => out.push(Token::Close),
            '/' if chars.peek() == Some(&'/') => {
                for c in chars.by_ref() {
                    if c == '\n' {
                        break;
                    }
                }
            }
            '"' => {
                let mut s = String::new();
                loop {
                    match chars.next() {
                        None => return Err("a string is not closed".to_owned()),
                        Some('"') => break,
                        Some('\\') => match chars.next() {
                            Some('n') => s.push('\n'),
                            Some('t') => s.push('\t'),
                            Some('\\') => s.push('\\'),
                            Some('"') => s.push('"'),
                            // Steam keeps an unknown escape as written.
                            Some(other) => {
                                s.push('\\');
                                s.push(other);
                            }
                            None => return Err("a string is not closed".to_owned()),
                        },
                        Some(c) => s.push(c),
                    }
                }
                out.push(Token::Text(s));
            }
            first => {
                // An unquoted token runs to white space, a brace or a quote.
                let mut s = String::from(first);
                while let Some(&c) = chars.peek() {
                    if c.is_whitespace() || matches!(c, '{' | '}' | '"') {
                        break;
                    }
                    s.push(c);
                    chars.next();
                }
                out.push(Token::Text(s));
            }
        }
    }
    Ok(out)
}

fn entries(
    toks: &mut std::iter::Peekable<std::vec::IntoIter<Token>>,
    depth: usize,
) -> Result<Vec<Entry>, String> {
    if depth > MAX_DEPTH {
        return Err("nested too deep".to_owned());
    }
    let mut out = Vec::new();
    loop {
        match toks.peek() {
            None | Some(Token::Close) => return Ok(out),
            Some(Token::Open) => return Err("a block has no key".to_owned()),
            Some(Token::Text(_)) => {}
        }
        let Some(Token::Text(key)) = toks.next() else {
            return Err("a key is missing".to_owned());
        };
        let value = match toks.next() {
            Some(Token::Text(s)) => Value::Str(s),
            Some(Token::Open) => {
                let inner = entries(toks, depth + 1)?;
                match toks.next() {
                    Some(Token::Close) => Value::Obj(inner),
                    _ => return Err("a block is not closed".to_owned()),
                }
            }
            _ => return Err(format!("{key:?} has no value")),
        };
        out.push(Entry { key, value });
    }
}

/// The top-level entries of a file (none for an empty or blank one).
pub fn parse(text: &str) -> Result<Vec<Entry>, String> {
    let mut toks = tokens(text)?.into_iter().peekable();
    let out = entries(&mut toks, 0)?;
    match toks.next() {
        None => Ok(out),
        Some(_) => Err("a closing brace has no block".to_owned()),
    }
}

/// A backslash is always doubled, Steam's own form (`"C:\\Games\\Steam"`). The reader keeps an
/// unknown escape such as `\x` as written, so such a value is written back doubled and reads
/// the same.
fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn write_entries(out: &mut String, list: &[Entry], depth: usize) {
    let pad = "\t".repeat(depth);
    for e in list {
        match &e.value {
            Value::Str(s) => {
                let _ = writeln!(out, "{pad}{}\t\t{}", quote(&e.key), quote(s));
            }
            Value::Obj(inner) => {
                let _ = writeln!(out, "{pad}{}\n{pad}{{", quote(&e.key));
                write_entries(out, inner, depth + 1);
                let _ = writeln!(out, "{pad}}}");
            }
        }
    }
}

/// Steam's own layout: tabs, one key per line.
pub fn write(list: &[Entry]) -> String {
    let mut out = String::new();
    write_entries(&mut out, list, 0);
    out
}

/// The first entry named `key` (any case).
pub fn find<'a>(list: &'a [Entry], key: &str) -> Option<&'a Entry> {
    list.iter().find(|e| e.key.eq_ignore_ascii_case(key))
}

/// The first entry named `key` (any case) as a string; `None` for a block or nothing.
pub fn find_str<'a>(list: &'a [Entry], key: &str) -> Option<&'a str> {
    find(list, key).and_then(|e| e.value.as_str())
}

/// The block named `key` (any case), made empty at the end when there is none. A string of that
/// name is not a block: `Err`, and nothing is changed.
pub fn block_mut<'a>(list: &'a mut Vec<Entry>, key: &str) -> Result<&'a mut Vec<Entry>, String> {
    let at = match list.iter().position(|e| e.key.eq_ignore_ascii_case(key)) {
        Some(at) => at,
        None => {
            list.push(Entry {
                key: key.to_owned(),
                value: Value::Obj(Vec::new()),
            });
            list.len() - 1
        }
    };
    match &mut list[at].value {
        Value::Obj(inner) => Ok(inner),
        Value::Str(_) => Err(format!("{key:?} is not a block")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_round_trips_in_steams_layout() {
        let text = "\"A\"\n{\n\t\"k\"\t\t\"v \\\"q\\\" \\\\\"\n\t\"B\"\n\t{\n\t}\n}\n";
        let parsed = parse(text).expect("valid");
        assert_eq!(write(&parsed), text);
    }

    #[test]
    fn an_unknown_escape_is_kept_by_the_reader_and_survives_a_rewrite() {
        for text in [
            "\"a\"\t\t\"C:\\x\\dir\"\n",
            "\"a\"\t\t\"\\q\"\n",
            "\"a\"\t\t\"\\\\x\\y\\\\\"\n",
        ] {
            let parsed = parse(text).expect("valid");
            assert_eq!(parse(&write(&parsed)).expect("valid"), parsed, "{text:?}");
        }
        let kept = parse("\"a\"\t\t\"C:\\x\"\n").expect("valid");
        assert_eq!(kept[0].value, Value::Str("C:\\x".to_owned()));
    }

    #[test]
    fn a_path_with_doubled_backslashes_is_written_back_byte_identical() {
        let text = "\"path\"\t\t\"C:\\\\Games\\\\Steam\"\n\"n\"\t\t\"a\\\\nb\"\n";
        let parsed = parse(text).expect("valid");
        assert_eq!(parsed[0].value, Value::Str("C:\\Games\\Steam".to_owned()));
        assert_eq!(write(&parsed), text);
    }

    #[test]
    fn comments_blank_files_and_a_bom_are_read() {
        assert_eq!(parse("").expect("empty"), vec![]);
        assert_eq!(parse("  \n\t").expect("blank"), vec![]);
        let parsed = parse("\u{feff}// c\n\"a\" \"b\" // tail\n").expect("valid");
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].value, Value::Str("b".to_owned()));
    }

    #[test]
    fn what_is_not_the_format_is_an_error_not_a_panic() {
        for bad in [
            "\"a\"",
            "\"a\" {",
            "\"a\" { \"b\" }",
            "}",
            "{ }",
            "\"a\" \"b",
            "a { b }",
            "a",
            "\"a\" \"b\" }",
            &format!("{}{}", "\"a\" {".repeat(40), "}".repeat(40)),
        ] {
            assert!(parse(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn lookups_ignore_case_and_a_string_is_no_block() {
        let mut list = parse("\"Valve\" { }\n\"s\" \"x\"").expect("valid");
        assert!(find(&list, "valve").is_some());
        assert!(block_mut(&mut list, "VALVE").is_ok());
        assert!(block_mut(&mut list, "s").is_err());
        assert_eq!(list.len(), 2);
        assert!(block_mut(&mut list, "new").is_ok());
        assert_eq!(list.len(), 3);
    }

    // From ruya-library's old reader.

    fn doc(text: &str) -> Value {
        Value::Obj(parse(text).expect("valid"))
    }

    #[test]
    fn nested_objects() {
        let v = doc(r#""a" { "b" { "c" "1" } "d" "2" }"#);
        let a = v.get("a").unwrap();
        assert_eq!(a.get("b").unwrap().get_str("c"), Some("1"));
        assert_eq!(a.get_str("d"), Some("2"));
    }

    #[test]
    fn escapes_in_quoted_strings() {
        let v = doc(r#""k" "a\"b\\c\nd\te""#);
        assert_eq!(v.get_str("k"), Some("a\"b\\c\nd\te"));
    }

    #[test]
    fn comments_are_skipped_between_pairs() {
        let v = doc("// head\n\"a\" \"1\" // tail\n// more\n\"b\" \"2\"");
        assert_eq!(v.get_str("a"), Some("1"));
        assert_eq!(v.get_str("b"), Some("2"));
    }

    #[test]
    fn unquoted_tokens() {
        let v = doc("key value\nobj { inner 3 }\nurl http://x/y");
        assert_eq!(v.get_str("key"), Some("value"));
        assert_eq!(v.get("obj").unwrap().get_str("inner"), Some("3"));
        assert_eq!(find_str(v.entries(), "URL"), Some("http://x/y"));
    }

    #[test]
    fn keys_match_case_insensitively_and_a_string_has_no_children() {
        let v = doc(r#""AppID" "7""#);
        assert_eq!(v.get_str("appid"), Some("7"));
        assert!(v.get("appid").unwrap().get("x").is_none());
        assert!(v.get("AppID").unwrap().entries().is_empty());
    }

    #[test]
    fn absurd_nesting_is_an_error_not_a_stack_overflow() {
        assert!(parse(&"\"a\" {".repeat(10_000)).is_err());
    }

    #[test]
    fn repeated_keys_are_kept_in_order() {
        let text = "\"a\"\t\t\"1\"\n\"a\"\t\t\"2\"\n";
        let list = parse(text).expect("valid");
        assert_eq!(list.len(), 2);
        assert_eq!(find_str(&list, "A"), Some("1"));
        assert_eq!(write(&list), text);
    }

    #[test]
    fn a_steam_config_round_trips() {
        let text = "\"InstallConfigStore\"\n{\n\t\"Software\"\n\t{\n\t\t\"Valve\"\n\t\t{\n\t\t\t\"Steam\"\n\t\t\t{\n\t\t\t\t\"CompatToolMapping\"\n\t\t\t\t{\n\t\t\t\t\t\"0\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"name\"\t\t\"GE-Proton9-1\"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n";
        assert_eq!(write(&parse(text).expect("valid")), text);
    }
}
