//! `ruya-pack`, the `.play` developer tool (docs/specs/05-play-packages.md section 13).
//!
//! The commands live in this library so the one `ruya` CLI (T-416, ADR-031) can mount them as
//! `ruya pack` without a rewrite: [`run`] takes the arguments after the program name and returns
//! an [`Outcome`] (exit code, JSON result, text). Every command takes `--json`. The rules are not
//! in this crate: it calls `ruya-play-format`, `ruya-play-art` and `ruya-play-trust`, the crates
//! the console verifies with, so a package the tool accepts is a package the console accepts.
//!
//! Exit codes: 0 ok, 1 problems found, 2 usage, 3 I/O.
//!
//! ```
//! let ctx = ruya_pack::Context::new(0, None);
//! let out = ruya_pack::run(&["--help".to_string()], &ctx);
//! assert_eq!(out.exit, 0);
//! ```

pub mod args;
pub mod build;
pub mod fixes;
pub mod init;
pub mod inspect;
pub mod keys;
pub mod pkg;
pub mod png;
pub mod report;
pub mod sign;
pub mod validate;
pub mod zipw;

pub use report::{Item, Outcome, Reply, Stop, EXIT_IO, EXIT_OK, EXIT_PROBLEMS, EXIT_USAGE};

use serde_json::json;

/// What the commands need from the process: the clock and `RUYA_PACK_KEY`. Passed in, so tests do
/// not touch the process environment.
#[derive(Clone)]
pub struct Context {
    /// Seconds since 1970 (UTC): the default `signed_at`.
    pub now: i64,
    /// The value of `RUYA_PACK_KEY`, when set.
    pub key_env: Option<String>,
}

impl Context {
    /// A context with this clock and key variable.
    pub fn new(now: i64, key_env: Option<String>) -> Context {
        Context { now, key_env }
    }

    /// The real clock and environment.
    pub fn from_process() -> Context {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs() as i64);
        Context {
            now,
            key_env: std::env::var("RUYA_PACK_KEY")
                .ok()
                .filter(|v| !v.trim().is_empty()),
        }
    }
}

// The key must never reach a log through a `{:?}` of the context.
impl std::fmt::Debug for Context {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Context")
            .field("now", &self.now)
            .field("key_env", &self.key_env.as_ref().map(|_| "<set>"))
            .finish()
    }
}

/// The text printed for `--help`.
pub const USAGE: &str = "\
ruya-pack: the RuyaOS .play developer tool

usage: ruya-pack <command> [options]   (every command takes --json)

  init <dir> [--id ID] [--name NAME] [--force]
        write a skeleton package
  validate <pkg> [--system-wine V] [--system-proton-ge V] [--system-runner family=V]
        check every rule that runs off the device; <pkg> is a folder or a .play.zip
  build <dir> [-o out.play.zip] [--deflate] [--links-as-data] [--exec PATH]
        write play.files and a deterministic zip, then validate it
  keygen <name> [--force]
        write <name>.key (secret) and <name>.pub
  sign <pkg> [--key FILE | RUYA_PACK_KEY] [--rotate-from OLDKEYFILE] [--signed-at TIME] [--deflate]
        write play.sig
  inspect <pkg> [--system-wine V] ...
        show what the console will show

exit codes: 0 ok, 1 problems found, 2 usage, 3 I/O
";

/// Run one command line (the arguments after the program name).
pub fn run(args: &[String], ctx: &Context) -> Outcome {
    let json_out = args.iter().any(|a| a == "--json");
    let rest: Vec<String> = args.to_vec();
    let Some(cmd) = rest
        .iter()
        .find(|a| !a.starts_with('-') || a.as_str() == "-")
        .cloned()
    else {
        if rest.iter().any(|a| a == "--help" || a == "-h") {
            return Outcome {
                exit: EXIT_OK,
                json: json!({"ok": true, "command": "help", "problems": [], "warnings": [], "usage": USAGE}),
                text: USAGE.to_string(),
            };
        }
        return Outcome::of("", Err(Stop::Usage("no command given; try --help".into())));
    };
    let pos = rest.iter().position(|a| *a == cmd).unwrap_or(0);
    let mut tail: Vec<String> = rest[pos + 1..].to_vec();
    // Options before the command (only --json) are dropped.
    if rest[..pos].iter().any(|a| a != "--json") {
        return Outcome::of(
            &cmd,
            Err(Stop::Usage("options go after the command".into())),
        );
    }
    if tail.iter().any(|a| a == "--help" || a == "-h") {
        return Outcome {
            exit: EXIT_OK,
            json: json!({"ok": true, "command": "help", "problems": [], "warnings": [], "usage": USAGE}),
            text: USAGE.to_string(),
        };
    }
    tail.retain(|a| a != "--json");
    let result = match cmd.as_str() {
        "init" => init::run(&tail, ctx),
        "validate" => validate::run(&tail, ctx),
        "build" => build::run(&tail, ctx),
        "keygen" => keys::keygen(&tail, ctx),
        "sign" => sign::run(&tail, ctx),
        "inspect" => inspect::run(&tail, ctx),
        other => Err(Stop::Usage(format!("unknown command {other}; try --help"))),
    };
    let _ = json_out;
    Outcome::of(&cmd, result)
}
