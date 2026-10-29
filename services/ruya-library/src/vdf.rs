//! Valve's text KeyValues format (VDF): `"key" "value"` pairs and `"key" { ... }` objects, with
//! `//` comments, backslash escapes in quoted strings and unquoted tokens. Malformed input is an
//! error, never a panic.

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    Str(String),
    Obj(Vec<(String, Value)>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError(pub String);

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "vdf: {}", self.0)
    }
}

impl std::error::Error for ParseError {}

impl Value {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(s) => Some(s),
            Value::Obj(_) => None,
        }
    }

    pub fn entries(&self) -> &[(String, Value)] {
        match self {
            Value::Obj(e) => e,
            Value::Str(_) => &[],
        }
    }

    /// The first child with this key, matched case-insensitively (Steam files mix `appid` and
    /// `AppID`).
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.entries()
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(key))
            .map(|(_, v)| v)
    }

    pub fn get_str(&self, key: &str) -> Option<&str> {
        self.get(key).and_then(Value::as_str)
    }
}

/// Parses a whole document: a sequence of pairs, returned as an object.
pub fn parse(text: &str) -> Result<Value, ParseError> {
    let mut p = Parser {
        chars: text.trim_start_matches('\u{feff}').chars().peekable(),
        depth: 0,
    };
    Ok(Value::Obj(p.entries(false)?))
}

/// Deeper nesting is not a real Steam file; refusing it keeps the recursion bounded.
const MAX_DEPTH: usize = 64;

enum Token {
    Text(String),
    Open,
    Close,
}

struct Parser<'a> {
    chars: std::iter::Peekable<std::str::Chars<'a>>,
    depth: usize,
}

impl Parser<'_> {
    /// Pairs up to the closing brace (`nested`) or the end of input.
    fn entries(&mut self, nested: bool) -> Result<Vec<(String, Value)>, ParseError> {
        let mut out = Vec::new();
        loop {
            let key = match self.token()? {
                None if nested => return Err(ParseError("missing closing brace".into())),
                None => return Ok(out),
                Some(Token::Close) if nested => return Ok(out),
                Some(Token::Close) => return Err(ParseError("unexpected closing brace".into())),
                Some(Token::Open) => return Err(ParseError("brace without a key".into())),
                Some(Token::Text(k)) => k,
            };
            let value = match self.token()? {
                None | Some(Token::Close) => {
                    return Err(ParseError(format!("key {key:?} has no value")));
                }
                Some(Token::Text(v)) => Value::Str(v),
                Some(Token::Open) => {
                    if self.depth >= MAX_DEPTH {
                        return Err(ParseError("nesting too deep".into()));
                    }
                    self.depth += 1;
                    let inner = self.entries(true)?;
                    self.depth -= 1;
                    Value::Obj(inner)
                }
            };
            out.push((key, value));
        }
    }

    fn skip_space_and_comments(&mut self) {
        loop {
            match self.chars.peek() {
                Some(c) if c.is_whitespace() => {
                    self.chars.next();
                }
                Some('/') => {
                    let mut look = self.chars.clone();
                    look.next();
                    if look.peek() != Some(&'/') {
                        return;
                    }
                    for c in self.chars.by_ref() {
                        if c == '\n' {
                            break;
                        }
                    }
                }
                _ => return,
            }
        }
    }

    fn token(&mut self) -> Result<Option<Token>, ParseError> {
        self.skip_space_and_comments();
        match self.chars.peek().copied() {
            None => Ok(None),
            Some('{') => {
                self.chars.next();
                Ok(Some(Token::Open))
            }
            Some('}') => {
                self.chars.next();
                Ok(Some(Token::Close))
            }
            Some('"') => {
                self.chars.next();
                self.quoted().map(|s| Some(Token::Text(s)))
            }
            Some(_) => {
                let mut s = String::new();
                while let Some(&c) = self.chars.peek() {
                    if c.is_whitespace() || matches!(c, '{' | '}' | '"') {
                        break;
                    }
                    s.push(c);
                    self.chars.next();
                }
                Ok(Some(Token::Text(s)))
            }
        }
    }

    fn quoted(&mut self) -> Result<String, ParseError> {
        let mut s = String::new();
        loop {
            match self.chars.next() {
                None => return Err(ParseError("unterminated string".into())),
                Some('"') => return Ok(s),
                Some('\\') => match self.chars.next() {
                    Some('n') => s.push('\n'),
                    Some('t') => s.push('\t'),
                    // `\\` and `\"` are themselves; an unknown escape keeps its character.
                    Some(c) => s.push(c),
                    None => return Err(ParseError("unterminated string".into())),
                },
                Some(c) => s.push(c),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nested_objects() {
        let v = parse(r#""a" { "b" { "c" "1" } "d" "2" }"#).unwrap();
        let a = v.get("a").unwrap();
        assert_eq!(a.get("b").unwrap().get_str("c"), Some("1"));
        assert_eq!(a.get_str("d"), Some("2"));
    }

    #[test]
    fn escapes_in_quoted_strings() {
        let v = parse(r#""k" "a\"b\\c\nd\te""#).unwrap();
        assert_eq!(v.get_str("k"), Some("a\"b\\c\nd\te"));
    }

    #[test]
    fn comments_are_skipped() {
        let v = parse("// head\n\"a\" \"1\" // tail\n// more\n\"b\" \"2\"").unwrap();
        assert_eq!(v.get_str("a"), Some("1"));
        assert_eq!(v.get_str("b"), Some("2"));
    }

    #[test]
    fn unquoted_tokens() {
        let v = parse("key value\nobj { inner 3 }").unwrap();
        assert_eq!(v.get_str("key"), Some("value"));
        assert_eq!(v.get("obj").unwrap().get_str("inner"), Some("3"));
    }

    #[test]
    fn keys_match_case_insensitively() {
        let v = parse(r#""AppID" "7""#).unwrap();
        assert_eq!(v.get_str("appid"), Some("7"));
    }

    #[test]
    fn byte_order_mark_and_empty_input() {
        assert!(parse("\u{feff}\"a\" \"1\"").is_ok());
        assert_eq!(parse("").unwrap(), Value::Obj(vec![]));
    }

    #[test]
    fn malformed_inputs_are_errors() {
        assert!(parse(r#""a" { "b" "1""#).is_err(), "missing closing brace");
        assert!(
            parse(r#""a" "unterminated"#).is_err(),
            "unterminated string"
        );
        assert!(parse(r#""a" "1" }"#).is_err(), "stray closing brace");
        assert!(parse(r#""a""#).is_err(), "key without value");
        assert!(parse(r#"{ "a" "1" }"#).is_err(), "brace without key");
    }

    #[test]
    fn absurd_nesting_is_an_error_not_a_stack_overflow() {
        let text = "\"a\" {".repeat(10_000);
        assert!(parse(&text).is_err());
    }
}
