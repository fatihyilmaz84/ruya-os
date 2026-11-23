//! ruya-platform-conformance: the Platform API's conformance runner (RUY-158, ADR-022, ADR-031).
//! Each case in `cases.rs` calls public elements of `org.ruyaos.Platform1` as apps would, valid
//! calls and the abuse cases of `docs/developers/api-surface.md`, and compares every status with
//! the one the case expects and with the statuses the XML documents for that element. Apps are
//! child processes of this program (`peer`), each a different app of the mock's scenario.
//!
//!     ruya-platform-conformance run --xml <Platform1.xml> [--apis <apis.json>]
//!         against the developer mock on the session bus; prints PASS/FAIL per case and
//!         `CONFORMANCE: n/m`; exit 0 all passed, 1 a failure, 2 not run (no mock)
//!     ruya-platform-conformance coverage --apis <apis.json>
//!         no bus: every public Platform1 element of apis.json (lint-dev-docs.ps1) has a case
//!     ruya-platform-conformance scenario
//!         the scenario file the mock must load for `run`
//!     ruya-platform-conformance peer
//!         internal: one app's connections, driven on stdin
//!
//! `scripts/conformance.sh` runs all of it: a private bus, the mock, the run.

mod cases;
mod docs;
mod peer;

use std::process::ExitCode;

const USAGE: &str =
    "usage: ruya-platform-conformance run --xml <Platform1.xml> [--apis <apis.json>]
       ruya-platform-conformance coverage --apis <apis.json>
       ruya-platform-conformance scenario";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("run") => run(&args[1..]),
        Some("coverage") => match option(&args[1..], "--apis") {
            Some(apis) => coverage(&apis),
            None => usage(),
        },
        Some("scenario") if args.len() == 1 => {
            match serde_json::to_string_pretty(&cases::scenario()) {
                Ok(json) => {
                    println!("{json}");
                    ExitCode::SUCCESS
                }
                Err(err) => {
                    eprintln!("ruya-platform-conformance: {err}");
                    ExitCode::FAILURE
                }
            }
        }
        Some("peer") => peer::serve(),
        _ => usage(),
    }
}

fn usage() -> ExitCode {
    eprintln!("{USAGE}");
    ExitCode::FAILURE
}

/// The value after `name` in `args`.
fn option(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

fn read(path: &str) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))
}

/// The coverage problems of the apis.json at `path`, or why it cannot be read.
fn coverage_problems(path: &str) -> Result<Vec<String>, String> {
    cases::coverage(&read(path)?)
}

fn coverage(path: &str) -> ExitCode {
    match coverage_problems(path) {
        Ok(problems) if problems.is_empty() => {
            println!(
                "conformance coverage: every public Platform1 element has a case ({} cases)",
                cases::CASES.len()
            );
            ExitCode::SUCCESS
        }
        Ok(problems) => {
            for p in problems {
                println!("conformance coverage: {p}");
            }
            ExitCode::FAILURE
        }
        Err(err) => {
            eprintln!("ruya-platform-conformance: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &[String]) -> ExitCode {
    let Some(xml) = option(args, "--xml") else {
        return usage();
    };
    let xml = match read(&xml).and_then(|t| docs::Docs::parse(&t)) {
        Ok(docs) => docs,
        Err(err) => {
            eprintln!("ruya-platform-conformance: {err}");
            return ExitCode::FAILURE;
        }
    };
    let mut failed = false;
    if let Some(apis) = option(args, "--apis") {
        match coverage_problems(&apis) {
            Ok(problems) => {
                for p in &problems {
                    println!("FAIL coverage: {p}");
                }
                failed |= !problems.is_empty();
            }
            Err(err) => {
                eprintln!("ruya-platform-conformance: {err}");
                return ExitCode::FAILURE;
            }
        }
    }
    let mut ctx = match cases::Ctx::connect(xml) {
        Ok(ctx) => ctx,
        Err(err) => {
            println!("CONFORMANCE: NOT RUN ({err})");
            return ExitCode::from(2);
        }
    };
    let mut passed = 0;
    for case in cases::CASES {
        match ctx.run(case) {
            Ok(()) => {
                passed += 1;
                println!("PASS {}", case.name);
            }
            Err(why) => {
                failed = true;
                println!("FAIL {}: {why}", case.name);
            }
        }
    }
    println!("CONFORMANCE: {passed}/{}", cases::CASES.len());
    if failed {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}
