//! What every command returns: one result object (`ok`, `problems`, `warnings` and the command's
//! own fields) and the text form of the same facts. `--json` prints the object; without it the
//! text is printed. Exit codes: 0 ok, 1 problems, 2 usage, 3 I/O.

use crate::fixes::{self, codes};
use ruya_play_format::Problem;
use serde_json::{json, Map, Value};

/// Exit code: everything fine (warnings allowed).
pub const EXIT_OK: i32 = 0;
/// Exit code: the package or the request has problems.
pub const EXIT_PROBLEMS: i32 = 1;
/// Exit code: the command line is wrong.
pub const EXIT_USAGE: i32 = 2;
/// Exit code: a file could not be read or written.
pub const EXIT_IO: i32 = 3;

/// One problem or warning: a stable code, where, what, and how to fix it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Item {
    /// Stable dotted code.
    pub code: String,
    /// JSON pointer or package path; empty for the whole package.
    pub path: String,
    /// What is wrong.
    pub message: String,
    /// One line on how to fix it, from [`fixes::fix_for`].
    pub fix: String,
}

impl Item {
    /// An item with the fix line of its code.
    pub fn new(code: &str, path: impl Into<String>, message: impl Into<String>) -> Item {
        Item {
            code: code.to_string(),
            path: path.into(),
            message: message.into(),
            fix: fixes::fix_for(code).to_string(),
        }
    }

    pub(crate) fn json(&self) -> Value {
        json!({"code": self.code, "path": self.path, "message": self.message, "fix": self.fix})
    }

    fn text(&self, label: &str) -> String {
        let at = if self.path.is_empty() {
            String::new()
        } else {
            format!(" at {}", self.path)
        };
        format!(
            "{label}[{}]{at}: {}\n  fix: {}\n",
            self.code, self.message, self.fix
        )
    }
}

impl From<&Problem> for Item {
    fn from(p: &Problem) -> Item {
        Item::new(&p.code, p.path.clone(), p.message.clone())
    }
}

/// Items from a list of the crates' problems.
pub fn items(problems: &[Problem]) -> Vec<Item> {
    problems.iter().map(Item::from).collect()
}

/// Why a command stopped before it could report on a package.
#[derive(Debug)]
pub enum Stop {
    /// The command line is wrong (exit 2).
    Usage(String),
    /// A file could not be read or written (exit 3).
    Io(String),
}

impl Stop {
    /// An I/O stop that names the path and the cause, never file contents.
    pub fn io(what: &str, path: &std::path::Path, err: &std::io::Error) -> Stop {
        Stop::Io(format!("{what} {}: {err}", path.display()))
    }
}

/// What a command found.
#[derive(Debug, Default)]
pub struct Reply {
    /// The command's own lines of text (printed before problems and warnings).
    pub text: String,
    /// The command's own JSON fields.
    pub fields: Map<String, Value>,
    /// Problems: any of them makes the exit code 1.
    pub problems: Vec<Item>,
    /// Warnings: printed, exit code unchanged.
    pub warnings: Vec<Item>,
}

/// The finished result of one run.
#[derive(Debug, Clone, PartialEq)]
pub struct Outcome {
    /// The process exit code.
    pub exit: i32,
    /// The `--json` result object.
    pub json: Value,
    /// The text form.
    pub text: String,
}

impl Outcome {
    /// Assemble the outcome of `command` from its reply or its stop.
    pub fn of(command: &str, result: Result<Reply, Stop>) -> Outcome {
        match result {
            Ok(r) => {
                let ok = r.problems.is_empty();
                let mut text = r.text;
                for p in &r.problems {
                    text.push_str(&p.text("error"));
                }
                for w in &r.warnings {
                    text.push_str(&w.text("warning"));
                }
                let mut obj = Map::new();
                obj.insert("ok".into(), Value::Bool(ok));
                obj.insert("command".into(), Value::from(command));
                obj.insert(
                    "problems".into(),
                    Value::Array(r.problems.iter().map(Item::json).collect()),
                );
                obj.insert(
                    "warnings".into(),
                    Value::Array(r.warnings.iter().map(Item::json).collect()),
                );
                for (k, v) in r.fields {
                    obj.entry(k).or_insert(v);
                }
                Outcome {
                    exit: if ok { EXIT_OK } else { EXIT_PROBLEMS },
                    json: Value::Object(obj),
                    text,
                }
            }
            Err(stop) => {
                let (exit, code, msg) = match stop {
                    Stop::Usage(m) => (EXIT_USAGE, codes::USAGE, m),
                    Stop::Io(m) => (EXIT_IO, codes::IO, m),
                };
                let item = Item::new(code, "", msg);
                Outcome {
                    exit,
                    text: item.text("error"),
                    json: json!({"ok": false, "command": command, "problems": [item.json()], "warnings": []}),
                }
            }
        }
    }
}
