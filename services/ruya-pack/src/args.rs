//! A small argument parser: `--flag value`, `--flag=value`, switches, `-o`, and positionals. An
//! unknown option is a usage error. A key is never an option value (05 section 13): there is no
//! option that takes key text.

use crate::report::Stop;
use std::collections::{BTreeMap, BTreeSet};

/// What one command accepts.
pub struct Spec {
    /// Options that take a value (repeatable).
    pub values: &'static [&'static str],
    /// Options without a value.
    pub switches: &'static [&'static str],
    /// How many positionals (min, max).
    pub positionals: (usize, usize),
}

/// The parsed command line of one command.
#[derive(Debug, Default)]
pub struct Parsed {
    /// The positionals in order.
    pub positional: Vec<String>,
    values: BTreeMap<String, Vec<String>>,
    switches: BTreeSet<String>,
}

impl Parsed {
    /// True when the switch was given.
    pub fn has(&self, name: &str) -> bool {
        self.switches.contains(name)
    }

    /// The last value of an option.
    pub fn one(&self, name: &str) -> Option<&str> {
        self.values
            .get(name)
            .and_then(|v| v.last())
            .map(String::as_str)
    }

    /// Every value of a repeatable option.
    pub fn all(&self, name: &str) -> &[String] {
        self.values.get(name).map_or(&[], Vec::as_slice)
    }
}

/// Parse `args` (after the command name) against `spec`. `--json` is accepted everywhere and is
/// handled by the caller, so it is skipped here.
pub fn parse(args: &[String], spec: &Spec) -> Result<Parsed, Stop> {
    let mut out = Parsed::default();
    let mut it = args.iter();
    let mut only_positional = false;
    while let Some(a) = it.next() {
        if only_positional || !a.starts_with('-') || a == "-" {
            out.positional.push(a.clone());
            continue;
        }
        if a == "--" {
            only_positional = true;
            continue;
        }
        if a == "--json" {
            continue;
        }
        let a = if a == "-o" { "--output" } else { a.as_str() };
        let (name, inline) = match a.split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n, Some(v.to_string())),
            _ => (a, None),
        };
        let bare = name.trim_start_matches('-');
        if spec.switches.contains(&bare) && name.starts_with("--") {
            if inline.is_some() {
                return Err(Stop::Usage(format!("--{bare} takes no value")));
            }
            out.switches.insert(bare.to_string());
        } else if spec.values.contains(&bare) && name.starts_with("--") {
            let v = match inline {
                Some(v) => v,
                None => it
                    .next()
                    .cloned()
                    .ok_or_else(|| Stop::Usage(format!("--{bare} needs a value")))?,
            };
            out.values.entry(bare.to_string()).or_default().push(v);
        } else {
            return Err(Stop::Usage(format!("unknown option {name}")));
        }
    }
    let (min, max) = spec.positionals;
    if out.positional.len() < min {
        return Err(Stop::Usage(format!(
            "missing argument (expected {min}, got {})",
            out.positional.len()
        )));
    }
    if out.positional.len() > max {
        return Err(Stop::Usage(format!(
            "too many arguments (expected at most {max}, got {})",
            out.positional.len()
        )));
    }
    Ok(out)
}
