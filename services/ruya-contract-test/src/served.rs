//! Which interfaces does a Rust source file serve (RUY-612)? The registry test
//! (`tests/registry.rs`) compares them with `api/dbus`, so this one rule decides whether a new
//! server is ever compared with its XML.
//!
//! A server is a zbus `interface` attribute, written however rustfmt or the author likes it:
//! `#[interface(name = "x")]`, `#[zbus::interface(name = "x")]`, `#[ zbus :: interface (` over
//! several lines, with `name` anywhere in the arguments. The scan reads Rust tokens, not text, so:
//!
//! - comments (`//`, `///`, nested `/* */`) and string literals hide what they contain: a server
//!   that is commented out, or an attribute quoted in a string or a test, is not a server.
//! - only an attribute counts: `fn interface(`, `.interface(` calls and `#[proxy(interface = ..)]`
//!   (a client) are not servers.
//! - fail closed: an `interface` attribute whose `name` is not a plain string literal (a `const`)
//!   is an error, never a silent skip.

#[derive(Debug, PartialEq)]
enum Tok {
    Ident(String),
    Str(String),
    Punct(char),
}

struct Token {
    tok: Tok,
    line: usize,
}

fn is_punct(token: Option<&Token>, c: char) -> bool {
    matches!(token, Some(Token { tok: Tok::Punct(p), .. }) if *p == c)
}

fn ident(token: Option<&Token>) -> Option<&str> {
    match token {
        Some(Token {
            tok: Tok::Ident(s), ..
        }) => Some(s),
        _ => None,
    }
}

/// Rust source as identifiers, string literals (their raw text) and single punctuation
/// characters; comments, whitespace, character literals and lifetimes are dropped.
fn lex(source: &str) -> Result<Vec<Token>, String> {
    let c: Vec<char> = source.chars().collect();
    let mut out = Vec::new();
    let (mut i, mut line) = (0, 1);
    while i < c.len() {
        let ch = c[i];
        if ch == '\n' {
            line += 1;
            i += 1;
        } else if ch.is_whitespace() {
            i += 1;
        } else if ch == '/' && c.get(i + 1) == Some(&'/') {
            while i < c.len() && c[i] != '\n' {
                i += 1;
            }
        } else if ch == '/' && c.get(i + 1) == Some(&'*') {
            let start = line;
            let mut depth = 0;
            loop {
                match (c.get(i), c.get(i + 1)) {
                    (None, _) => return Err(format!("line {start}: a block comment never ends")),
                    (Some('/'), Some('*')) => {
                        depth += 1;
                        i += 2;
                    }
                    (Some('*'), Some('/')) => {
                        depth -= 1;
                        i += 2;
                        if depth == 0 {
                            break;
                        }
                    }
                    (Some('\n'), _) => {
                        line += 1;
                        i += 1;
                    }
                    _ => i += 1,
                }
            }
        } else if ch == '"' {
            let start = line;
            i += 1;
            let from = i;
            loop {
                match c.get(i) {
                    None => return Err(format!("line {start}: a string never ends")),
                    Some('"') => break,
                    Some('\\') => {
                        if c.get(i + 1) == Some(&'\n') {
                            line += 1;
                        }
                        i += 2;
                    }
                    Some('\n') => {
                        line += 1;
                        i += 1;
                    }
                    _ => i += 1,
                }
            }
            out.push(Token {
                tok: Tok::Str(c[from..i].iter().collect()),
                line: start,
            });
            i += 1;
        } else if ch == '\'' {
            // A character literal (`'x'`, `'\n'`, `'\''`) is dropped; anything else is a lifetime.
            if c.get(i + 1) == Some(&'\\') {
                i += 2;
                while i < c.len() && c[i] != '\'' {
                    i += 1;
                }
                i += 1;
            } else if c.get(i + 2) == Some(&'\'') {
                i += 3;
            } else {
                out.push(Token {
                    tok: Tok::Punct('\''),
                    line,
                });
                i += 1;
            }
        } else if ch.is_alphanumeric() || ch == '_' {
            let from = i;
            while i < c.len() && (c[i].is_alphanumeric() || c[i] == '_') {
                i += 1;
            }
            let word: String = c[from..i].iter().collect();
            // A raw string: r"..", r#".."#, br#".."#.
            if matches!(word.as_str(), "r" | "br" | "cr") {
                let mut j = i;
                while c.get(j) == Some(&'#') {
                    j += 1;
                }
                let hashes = j - i;
                if c.get(j) == Some(&'"') {
                    let start = line;
                    let from = j + 1;
                    let mut k = from;
                    loop {
                        match c.get(k) {
                            None => return Err(format!("line {start}: a raw string never ends")),
                            Some('"') if (1..=hashes).all(|h| c.get(k + h) == Some(&'#')) => break,
                            Some('\n') => {
                                line += 1;
                                k += 1;
                            }
                            _ => k += 1,
                        }
                    }
                    out.push(Token {
                        tok: Tok::Str(c[from..k].iter().collect()),
                        line: start,
                    });
                    i = k + 1 + hashes;
                    continue;
                }
            }
            out.push(Token {
                tok: Tok::Ident(word),
                line,
            });
        } else {
            out.push(Token {
                tok: Tok::Punct(ch),
                line,
            });
            i += 1;
        }
    }
    Ok(out)
}

/// The index of the `(` when the tokens at `at` start an attribute whose last path segment is
/// `interface`: `#[interface(`, `#[zbus::interface(`, `#[::zbus::interface(`.
fn interface_attribute(toks: &[Token], at: usize) -> Option<usize> {
    if !is_punct(toks.get(at), '#') || !is_punct(toks.get(at + 1), '[') {
        return None;
    }
    let mut j = at + 2;
    if is_punct(toks.get(j), ':') && is_punct(toks.get(j + 1), ':') {
        j += 2;
    }
    while ident(toks.get(j)).is_some()
        && is_punct(toks.get(j + 1), ':')
        && is_punct(toks.get(j + 2), ':')
    {
        j += 3;
    }
    (ident(toks.get(j)) == Some("interface") && is_punct(toks.get(j + 1), '(')).then_some(j + 1)
}

/// The arguments between the `(` at `open` and its `)`, split at the commas of the top level.
fn arguments(toks: &[Token], open: usize) -> Result<Vec<&[Token]>, String> {
    let mut args = Vec::new();
    let (mut depth, mut from) = (0_usize, open + 1);
    for (n, token) in toks.iter().enumerate().skip(open) {
        if let Tok::Punct(p) = token.tok {
            match p {
                '(' | '[' | '{' => depth += 1,
                ')' | ']' | '}' => {
                    depth -= 1;
                    if depth == 0 {
                        if n > from {
                            args.push(&toks[from..n]);
                        }
                        return Ok(args);
                    }
                }
                ',' if depth == 1 => {
                    if n > from {
                        args.push(&toks[from..n]);
                    }
                    from = n + 1;
                }
                _ => {}
            }
        }
    }
    Err(format!(
        "line {}: this attribute never ends",
        toks[open].line
    ))
}

/// The interface names a Rust source file serves, in file order, each as the literal of the
/// `name = "..."` argument of its `interface` attribute (any name, not only `org.ruyaos.*`).
/// An `interface` attribute without a literal name is an error naming its line.
pub fn served_interface_names(source: &str) -> Result<Vec<String>, String> {
    let toks = lex(source)?;
    let mut names = Vec::new();
    for at in 0..toks.len() {
        let Some(open) = interface_attribute(&toks, at) else {
            continue;
        };
        let line = toks[at].line;
        let mut name = None;
        for arg in arguments(&toks, open)? {
            if ident(arg.first()) == Some("name") && is_punct(arg.get(1), '=') {
                if let [_, _, Token {
                    tok: Tok::Str(s), ..
                }] = arg
                {
                    name = Some(s.clone());
                }
                break;
            }
        }
        match name {
            Some(name) => names.push(name),
            None => {
                return Err(format!(
                    "line {line}: cannot tell which interface this serves: use a literal name"
                ))
            }
        }
    }
    Ok(names)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(source: &str) -> Vec<String> {
        served_interface_names(source).expect("scans")
    }

    #[test]
    fn the_plain_attribute() {
        assert_eq!(
            names("#[interface(name = \"org.ruyaos.X1\")]\nimpl X {}"),
            ["org.ruyaos.X1"]
        );
    }

    #[test]
    fn the_path_form() {
        assert_eq!(
            names("#[zbus::interface(name = \"org.ruyaos.X1\")]"),
            ["org.ruyaos.X1"]
        );
        assert_eq!(
            names("#[::zbus::interface(name = \"org.ruyaos.X1\")]"),
            ["org.ruyaos.X1"]
        );
    }

    #[test]
    fn no_spaces_around_the_equals_sign() {
        assert_eq!(
            names("#[interface(name=\"org.ruyaos.X1\")]"),
            ["org.ruyaos.X1"]
        );
    }

    #[test]
    fn an_attribute_split_over_several_lines() {
        let source = "#[ zbus\n  :: interface (\n    name\n      =\n        \"org.ruyaos.X1\",\n)]";
        assert_eq!(names(source), ["org.ruyaos.X1"]);
    }

    #[test]
    fn the_name_after_another_argument() {
        assert_eq!(
            names("#[interface(spawn = false, name = \"org.ruyaos.X1\")]"),
            ["org.ruyaos.X1"]
        );
        assert_eq!(
            names(
                "#[interface(proxy(name = \"Other\"), name = \"org.ruyaos.X1\", spawn = false,)]"
            ),
            ["org.ruyaos.X1"]
        );
    }

    #[test]
    fn two_interfaces_in_one_file_in_file_order() {
        let source = "#[interface(name = \"org.ruyaos.A1\")]\nimpl A {}\n\
                      #[zbus::interface(name = \"org.ruyaos.B1\")]\nimpl B {}";
        assert_eq!(names(source), ["org.ruyaos.A1", "org.ruyaos.B1"]);
    }

    #[test]
    fn a_name_that_is_not_org_ruyaos_is_returned_too() {
        assert_eq!(
            names("#[interface(name = \"org.bluez.Agent1\")]"),
            ["org.bluez.Agent1"]
        );
    }

    #[test]
    fn a_commented_out_server_is_not_a_server() {
        let source = "// #[interface(name = \"org.ruyaos.A1\")]\n\
                      /// #[interface(name = \"org.ruyaos.B1\")]\n\
                      /* #[interface(name = \"org.ruyaos.C1\")]\n /* nested */ still a comment */\n\
                      #[interface(name = \"org.ruyaos.D1\")]";
        assert_eq!(names(source), ["org.ruyaos.D1"]);
    }

    #[test]
    fn an_attribute_inside_a_string_is_not_a_server() {
        let source = "const A: &str = \"#[interface(name = \\\"org.ruyaos.A1\\\")]\";\n\
                      const B: &str = r#\"#[interface(name = \"org.ruyaos.B1\")]\"#;\n\
                      #[interface(name = \"org.ruyaos.C1\")]";
        assert_eq!(names(source), ["org.ruyaos.C1"]);
    }

    #[test]
    fn character_literals_and_lifetimes_do_not_confuse_the_scan() {
        let source = "fn f<'a>(x: &'a str) -> char { if x == \"\" { '\"' } else { '\\'' } }\n\
                      #[interface(name = \"org.ruyaos.X1\")]";
        assert_eq!(names(source), ["org.ruyaos.X1"]);
    }

    #[test]
    fn only_an_attribute_is_a_server() {
        let source = "fn interface(x: u8) {}\n\
                      let p = b.interface(\"org.freedesktop.DBus\");\n\
                      #[proxy(interface = \"org.ruyaos.A1\", name = \"b\")]\n\
                      #[zbus::proxy(interface = \"org.ruyaos.B1\")]\n\
                      #[derive(Debug)] struct S;\n\
                      #[interface]\n";
        assert_eq!(names(source), Vec::<String>::new());
    }

    #[test]
    fn a_name_that_is_not_a_literal_is_an_error_naming_the_line() {
        for attribute in [
            "#[interface(name = NAME)]",
            "#[zbus::interface(spawn = false)]",
            "#[interface()]",
            "#[interface(name = concat!(\"a\", \"b\"))]",
            "#[interface(name = \"a\".to_owned())]",
        ] {
            let source = format!("// one\n\n{attribute}\nimpl X {{}}");
            let err = served_interface_names(&source).expect_err(attribute);
            assert!(err.starts_with("line 3: "), "{attribute}: {err}");
            assert!(err.contains("use a literal name"), "{attribute}: {err}");
        }
    }

    #[test]
    fn a_source_that_cannot_be_read_is_an_error() {
        assert!(served_interface_names("/* never closed").is_err());
        assert!(served_interface_names("let s = \"never closed").is_err());
        assert!(served_interface_names("#[interface(name = \"a\"").is_err());
    }
}
