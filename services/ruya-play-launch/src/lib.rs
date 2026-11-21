//! `ruya-play-launch`: the program every installed `.play` app starts with
//! (`command=/app/launcher/bin/ruya-play-launch`, ADR-037 and ADR-038, 05 §6.3).
//!
//! Inside the game's sandbox, as the profile user, it
//! 1. re-reads `/app/play.files` and `/app/play.json` with the format crate's parsers
//!    ([`load`]; untrusted even after install, but no full `validate`: `/app` also holds the OS's
//!    folders and a content pass would hash gigabytes at every launch),
//! 2. finds the OS's runners under `/app/runners` ([`runners::scan`]),
//! 3. decides the command ([`plan::plan`], pure, through `resolve::resolve`),
//! 4. prepares the prefix and runs the setup steps ([`prepare`]), keeping the status file
//!    ([`state`]) up to date,
//! 5. and `exec`s the game (the binary; no shell).
//!
//! Every effect goes through [`os::LaunchOs`]; a failure is one sentence ([`Failure`]) the shell
//! shows.

pub mod fake;
#[cfg(target_os = "linux")]
pub mod linux;
pub mod os;
pub mod plan;
pub mod runners;
pub mod state;

use os::{join, AppSource, Command, Exit, LaunchOs, NotFollowed};
use plan::{Action, Inputs, Plan, PrefixPlan, SetupRun};
use ruya_play_format::limits::{MAX_MANIFEST_BYTES, MAX_TABLE_BYTES};
use ruya_play_format::manifest::{parse_manifest, Manifest};
use ruya_play_format::problem::Problems;
use ruya_play_format::resolve::Override;
use ruya_play_format::runner::{bundled_runners, BundledRunner};
use ruya_play_format::table::{parse_table, TableIndex};
use state::{backup_dir, SetupFailure, State};
use std::collections::BTreeMap;
use std::fmt;
use std::time::Duration;

/// How long the setup steps of one launch may take, each (05 §6.3).
pub const SETUP_TIMEOUT: Duration = Duration::from_secs(10 * 60);

/// Why the game does not start: a stable code and one sentence for the player.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    /// A dotted code (`launch.*`, `resolve.*`, or a format problem's code).
    pub code: String,
    /// One English sentence.
    pub message: String,
}

impl Failure {
    /// A failure with `code` and `message`.
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Failure {
            code: code.to_string(),
            message: message.into(),
        }
    }
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

/// A runner choice by its name, `package`, `bundled` or `system`: what `--runner=` takes and what
/// ruya-library stores per game (Library1 `SetRunnerChoice`). Anything else is none.
pub fn parse_choice(name: &str) -> Option<Override> {
    match name {
        "package" => Some(Override::PackageDefault),
        "bundled" => Some(Override::Bundled),
        "system" => Some(Override::System),
        _ => None,
    }
}

/// The player's runner choice from the arguments: none, or one `--runner=package|bundled|system`
/// (added by ruya-session from ruya-library's per-game choice). Anything else is refused.
pub fn parse_args(args: &[String]) -> Result<Override, Failure> {
    let mut over = None;
    for a in args {
        let choice = match a.strip_prefix("--runner=").and_then(parse_choice) {
            Some(choice) => choice,
            None => {
                return Err(Failure::new(
                    "launch.argument",
                    "The launcher was started with an argument it does not know.",
                ))
            }
        };
        if over.replace(choice).is_some() {
            return Err(Failure::new(
                "launch.argument",
                "The launcher was given the runner choice twice.",
            ));
        }
    }
    Ok(over.unwrap_or(Override::PackageDefault))
}

/// The package as installed: its manifest and the runner of each bundled copy.
#[derive(Debug, Clone)]
pub struct Loaded {
    /// The checked `play.json`.
    pub manifest: Manifest,
    /// The runner of each bundled copy, by component id.
    pub bundled: BTreeMap<String, BundledRunner>,
}

fn damaged(problems: Problems) -> Failure {
    let list = problems.finish();
    let first = list
        .first()
        .map_or_else(|| "unknown".to_string(), |p| p.to_string());
    Failure::new(
        list.first().map_or("launch.damaged", |p| p.code.as_str()),
        format!("This game's files are damaged ({first}); reinstall it."),
    )
}

/// Re-read and check `/app/play.files` and `/app/play.json` (the table first, as `validate`
/// does), then each bundled copy's `runner.json`. Packages are checked for their tier at install;
/// here the reserved-id rule is lifted (`official`), since an official package is installed too.
pub fn load(os: &dyn LaunchOs) -> Result<Loaded, Failure> {
    load_from(os, plan::APP)
}

/// [`load`] for the package tree at `root`: `/app` for the launcher, a deployment's `files/` for
/// the library's dry run ([`dry_run`]).
pub fn load_from(os: &dyn LaunchOs, root: &str) -> Result<Loaded, Failure> {
    let src = AppSource::new(os, root);
    let mut problems = Problems::new();
    let read = |path: &str, limit: u64| {
        ruya_play_format::read_small(&src, path, limit).map_err(|p| {
            Failure::new(
                &p.code,
                format!(
                    "This game's {path} cannot be read ({}); reinstall it.",
                    p.message
                ),
            )
        })
    };
    let table_bytes = read("play.files", MAX_TABLE_BYTES)?;
    if table_bytes.len() as u64 > MAX_TABLE_BYTES {
        problems.add(
            ruya_play_format::codes::TABLE_TOO_BIG,
            "play.files",
            "play.files is too big.",
        );
        return Err(damaged(problems));
    }
    let files = parse_table(&table_bytes, &mut problems);
    drop(table_bytes);
    if !problems.is_empty() {
        return Err(damaged(problems));
    }
    let index = TableIndex::new(&files);
    let manifest_bytes = read("play.json", MAX_MANIFEST_BYTES)?;
    let manifest = parse_manifest(&manifest_bytes, &files, &index, true, &mut problems);
    let Some(manifest) = manifest.filter(|_| problems.is_empty()) else {
        return Err(damaged(problems));
    };
    let bundled = bundled_runners(&src, &manifest, &index, &mut problems);
    if !problems.is_empty() {
        return Err(damaged(problems));
    }
    Ok(Loaded { manifest, bundled })
}

/// What the launcher would run the game with, decided without starting anything.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DryRun {
    /// The runner of `run.component`; none for a native game.
    pub runner: Option<plan::Root>,
}

/// The launcher's own resolution with other roots (RUY-903): the package tree at `package` (a
/// deployment's `files/` instead of `/app`) and the OS's runners under `runners` (the image's
/// `/usr/lib/ruyaos/play/runners` instead of `/app/runners`), with the choice `over` the launch
/// would get as `--runner` ([`parse_args`]; RUY-959). The same [`load_from`],
/// [`runners::scan_in`] and [`plan::pick_runners`] the launch runs, so the library tells the
/// player what the launch will say. A failure is the sentence the launch would show.
pub fn dry_run(
    os: &dyn LaunchOs,
    package: &str,
    runners: &str,
    over: Override,
) -> Result<DryRun, Failure> {
    let loaded = load_from(os, package)?;
    let system = runners::scan_in(os, runners);
    let (mut roots, _notes) = plan::pick_runners(&loaded.manifest, &loaded.bundled, &system, over)?;
    let runner = loaded
        .manifest
        .run
        .component
        .as_ref()
        .and_then(|id| roots.remove(id));
    Ok(DryRun { runner })
}

/// Everything before the `exec`: load, find runners, plan, prepare the prefix, run the setup
/// steps, write the status file. Returns the game's command.
pub fn prepare(
    os: &mut dyn LaunchOs,
    args: &[String],
    base_env: &BTreeMap<String, String>,
) -> Result<Command, Failure> {
    let over = parse_args(args)?;
    let loaded = load(os)?;
    let system = runners::scan(os);
    let data = plan::env_dir(base_env, "XDG_DATA_HOME")?;
    let mut state = State::read(os, &data);
    let prefix_exists = ruya_play_format::runner::prefix_dir(&loaded.manifest.run.runner, &data)
        .is_some_and(|p| os.kind(&p).is_some());
    let plan = plan::plan(&Inputs {
        manifest: &loaded.manifest,
        bundled: &loaded.bundled,
        system: &system,
        over,
        base_env,
        state: &state,
        prefix_exists,
    })?;
    for n in &plan.notes {
        os.log(n);
    }
    if let Some(r) = &plan.runner {
        os.log(&format!(
            "runner {} {} ({}) for {}",
            r.family, r.version, r.source, r.component
        ));
    }
    apply(os, &plan, &mut state)?;
    state.runner = plan.runner.clone();
    save(os, &plan.data, &state)?;
    Ok(plan.command)
}

fn save(os: &mut dyn LaunchOs, data: &str, state: &State) -> Result<(), Failure> {
    state.write(os, data).map_err(|e| {
        Failure::new(
            "launch.state",
            format!("The game's status file cannot be written ({e})."),
        )
    })
}

fn io_failure(code: &str, what: &str, e: &std::io::Error) -> Failure {
    Failure::new(code, format!("{what} ({e})."))
}

/// Run the plan's actions in order, saving the status file after each one that changes it.
fn apply(os: &mut dyn LaunchOs, plan: &Plan, state: &mut State) -> Result<(), Failure> {
    let data = plan.data.as_str();
    for action in &plan.actions {
        match action {
            Action::MakeDirs(dirs) => {
                for d in dirs {
                    os.make_dirs(data, d).map_err(|e| {
                        io_failure(
                            "launch.prefix",
                            "The game's data folder cannot be prepared",
                            &e,
                        )
                    })?;
                }
            }
            Action::Create { epoch } => {
                if let Some(p) = &plan.prefix {
                    create_prefix(os, data, p)?;
                }
                state.epoch = *epoch;
                state.setup_done.clear();
                save(os, data, state)?;
            }
            Action::Rebuild { from, to, saves } => {
                let Some(p) = &plan.prefix else { continue };
                rebuild(os, data, p, *from, *to, saves, state)?;
            }
            Action::Setup(step) => setup(os, data, step, state)?,
        }
    }
    Ok(())
}

/// A new prefix: the template copied (links as links), then `dosdevices` with `c:` and `z:`,
/// which a template never holds (05 §6.3). Without a template the runner creates the prefix.
fn create_prefix(os: &mut dyn LaunchOs, data: &str, p: &PrefixPlan) -> Result<(), Failure> {
    let Some(template) = &p.template else {
        return Ok(());
    };
    let fail =
        |e: std::io::Error| io_failure("launch.prefix", "The game's prefix cannot be created", &e);
    os.copy(template, "", data, &p.rel).map_err(fail)?;
    os.make_dirs(data, &join(&p.rel, "dosdevices"))
        .map_err(fail)?;
    os.symlink("../drive_c", data, &join(&p.rel, "dosdevices/c:"))
        .map_err(fail)?;
    os.symlink("/", data, &join(&p.rel, "dosdevices/z:"))
        .map_err(fail)?;
    Ok(())
}

/// The epoch rebuild (ADR-037): saves out, prefix gone, prefix new, saves back. The backup stays
/// in `epoch-<from>-backup/`. A save behind a planted link is not followed and not kept (what the
/// link points at is not in the prefix, and removing the prefix removes only the link).
fn rebuild(
    os: &mut dyn LaunchOs,
    data: &str,
    p: &PrefixPlan,
    from: u64,
    to: u64,
    saves: &[String],
    state: &mut State,
) -> Result<(), Failure> {
    let fail = |e: std::io::Error| {
        io_failure(
            "launch.epoch",
            "The game's prefix cannot be rebuilt for its update",
            &e,
        )
    };
    let backup = backup_dir(from);
    let mut kept = Vec::new();
    if state.backup_of == Some(from) {
        kept = saves.to_vec();
    } else {
        os.remove(data, &backup).map_err(fail)?;
        os.make_dirs(data, &backup).map_err(fail)?;
        for s in saves {
            match os.copy(data, &join(&p.rel, s), data, &join(&backup, s)) {
                Ok(true) => kept.push(s.clone()),
                Ok(false) => {}
                Err(e) if NotFollowed::is(&e) => os.log(&format!("save {s} skipped: {e}")),
                Err(e) => return Err(fail(e)),
            }
        }
        state.backup_of = Some(from);
        save(os, data, state)?;
    }
    os.remove(data, &p.rel).map_err(fail)?;
    create_prefix(os, data, p)?;
    for s in &kept {
        match os.copy(data, &join(&backup, s), data, &join(&p.rel, s)) {
            Ok(_) => {}
            Err(e) if NotFollowed::is(&e) => os.log(&format!("save {s} not restored: {e}")),
            Err(e) => return Err(fail(e)),
        }
    }
    state.epoch = to;
    state.backup_of = None;
    state.setup_done.clear();
    save(os, data, state)
}

fn exit_text(exit: Exit) -> String {
    match exit {
        Exit::Code(c) => format!("ended with code {c}"),
        Exit::Signal(s) => format!("was stopped by signal {s}"),
        Exit::TimedOut => format!(
            "did not finish within {} minutes",
            SETUP_TIMEOUT.as_secs() / 60
        ),
    }
}

/// Run one setup step under [`SETUP_TIMEOUT`] (the step and what runs after it together). A
/// failure is written to the status file and stops the launch.
fn setup(
    os: &mut dyn LaunchOs,
    data: &str,
    step: &SetupRun,
    state: &mut State,
) -> Result<(), Failure> {
    os.log(&format!("setup step {}", step.id));
    let cmds: Vec<Command> = std::iter::once(&step.command)
        .chain(&step.then)
        .cloned()
        .collect();
    let outcome = os.run(&cmds, SETUP_TIMEOUT);
    let why = match outcome {
        Ok((Exit::Code(0), _)) => None,
        Ok((exit, _)) => Some(exit_text(exit)),
        Err(e) => Some(format!("could not be started ({e})")),
    };
    match why {
        None => {
            if step.once {
                state.setup_done.push(step.id.clone());
            }
            state.setup_failed = None;
            save(os, data, state)
        }
        Some(why) => {
            let failure = Failure::new(
                "launch.setup_failed",
                format!("The game's first-time setup step {} {why}.", step.id),
            );
            state.setup_failed = Some(SetupFailure {
                step: step.id.clone(),
                message: failure.message.clone(),
            });
            save(os, data, state)?;
            Err(failure)
        }
    }
}
