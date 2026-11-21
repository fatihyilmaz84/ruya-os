//! The pure core (ADR-037): from the checked manifest, the runners and what the status file says,
//! the command that starts the game and the steps before it. Nothing here touches the disk.
//!
//! * **Argv** (`S()` is a command after placeholder substitution): native, emulator and engine
//!   `S(run.command)`; wine `[root/entry.wine] + S(...)`; proton
//!   `[root/entry.proton, "waitforexitandrun"] + S(...)`. Setup steps run through the same
//!   wrapper: wine `[wine] + S(step)` then `wineserver -w`, proton `[proton, "run"] + S(step)`.
//! * **Environment:** the base environment, then `run.env` (already held to the deny table of
//!   05 §6.3 by `parse_manifest`), then the launcher's own variables: wine `WINEPREFIX`,
//!   `WINESERVER`, `WINELOADER` and, only when this launch creates the prefix, `WINEARCH`; proton
//!   `STEAM_COMPAT_DATA_PATH` and `STEAM_COMPAT_CLIENT_INSTALL_PATH`, plus `SteamAppId=0` and
//!   `SteamGameId=0` (no Steam game id outside Steam; protonfixes needs one); every kind gets
//!   `PWD`, the working folder of the command.
//! * **Prefix** (wine, proton): `runner::prefix_dir`. A missing prefix is created from
//!   `run.prefix.template` (copied, then `dosdevices`), else by the runner; a prefix made for a
//!   lower `run.prefix.epoch` is rebuilt with the `prefix:` saves kept.
//! * **Setup:** a `once` step runs when this prefix has not done it; a step without `once` runs at
//!   every launch.

use crate::os::{join, Command};
use crate::runners::FoundRunner;
use crate::state::{RunnerInUse, State};
use crate::Failure;
use ruya_play_format::limits::PLACEHOLDERS;
use ruya_play_format::manifest::{Component, Manifest};
use ruya_play_format::resolve::{self, Chosen, Note, Override};
use ruya_play_format::runner::{self, BundledRunner, Entry};
use std::collections::BTreeMap;

/// Where the package is in the sandbox.
pub const APP: &str = "/app";
/// `${payload}`.
pub const PAYLOAD: &str = "/app/payload";

/// Everything [`plan`] decides from.
pub struct Inputs<'a> {
    /// The re-checked `/app/play.json`.
    pub manifest: &'a Manifest,
    /// The runner of each bundled copy, by component id (`runner::bundled_runners`).
    pub bundled: &'a BTreeMap<String, BundledRunner>,
    /// The OS's runners found in the sandbox.
    pub system: &'a [FoundRunner],
    /// The player's choice (`--runner=`).
    pub over: Override,
    /// The environment the launcher was started with.
    pub base_env: &'a BTreeMap<String, String>,
    /// The status file.
    pub state: &'a State,
    /// Whether something is at the prefix path now.
    pub prefix_exists: bool,
}

/// One step before the game starts, in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// Create these folders below `${data}`.
    MakeDirs(Vec<String>),
    /// The prefix was made for `from` and the package asks for `to`: copy the `saves` (paths
    /// inside the prefix) to `epoch-<from>-backup/` (skipped when the status file says that
    /// backup is complete), remove the prefix, create it again, copy the saves back.
    Rebuild {
        /// The epoch of the prefix that is there.
        from: u64,
        /// The epoch to make.
        to: u64,
        /// The `prefix:` saves, as paths below the prefix.
        saves: Vec<String>,
    },
    /// There is no prefix: create it (from the template when the package has one) for `epoch`.
    Create {
        /// The epoch to record.
        epoch: u64,
    },
    /// Run a setup step.
    Setup(SetupRun),
}

/// A setup step ready to run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SetupRun {
    /// The step's id.
    pub id: String,
    /// Record it in the status file when it passes.
    pub once: bool,
    /// The step itself.
    pub command: Command,
    /// What runs after it, under the same timeout (wine: `wineserver -w`).
    pub then: Option<Command>,
}

/// The prefix of a wine or proton runner.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrefixPlan {
    /// The prefix below `${data}` (`prefix`, `proton/pfx`).
    pub rel: String,
    /// The template's folder in `/app`, when the package ships one.
    pub template: Option<String>,
}

/// What [`plan`] decided.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    /// The game.
    pub command: Command,
    /// What happens before it, in order.
    pub actions: Vec<Action>,
    /// `${data}`.
    pub data: String,
    /// The prefix, for wine and proton.
    pub prefix: Option<PrefixPlan>,
    /// The runner of `run.component` (none for native).
    pub runner: Option<RunnerInUse>,
    /// Facts worth a log line (the override did not apply, a fence).
    pub notes: Vec<String>,
}

/// A chosen runner on disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Root {
    /// Its folder.
    pub path: String,
    /// Its programs.
    pub entry: Entry,
    /// What the status file records.
    pub in_use: RunnerInUse,
    /// The version the developer tested the component with, for "Tested with 9.20".
    pub tested: Option<String>,
}

/// The values of the placeholders of 05 §6.3.
pub struct Places {
    /// `${payload}`.
    pub payload: String,
    /// `${data}`.
    pub data: String,
    /// `${config}`.
    pub config: String,
    /// `${prefix}`, for wine and proton.
    pub prefix: Option<String>,
    /// `${disc}`: the first disc.
    pub disc: Option<String>,
    /// `${component:<id>}`: each component's root.
    pub components: BTreeMap<String, String>,
}

/// Replace the placeholders of `s` (05 §6.3): `${payload}`, `${data}`, `${config}`, `${prefix}`,
/// `${disc}` and `${component:<id>}`. Anything else, `${HOME}` or a `$` without braces, stays as
/// written. A named placeholder with no value here (`${prefix}` for a native game) is a failure.
pub fn substitute(s: &str, places: &Places) -> Result<String, Failure> {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find("${") {
        out.push_str(&rest[..i]);
        let after = &rest[i + 2..];
        let Some(end) = after.find('}') else {
            out.push_str(&rest[i..]);
            return Ok(out);
        };
        let name = &after[..end];
        let value = if let Some(id) = name.strip_prefix("component:") {
            Some(places.components.get(id).cloned().ok_or_else(|| {
                Failure::new(
                    "launch.placeholder",
                    format!("The game names the component {id}, which has no runner here."),
                )
            })?)
        } else if PLACEHOLDERS.contains(&name) {
            let v = match name {
                "payload" => Some(places.payload.clone()),
                "data" => Some(places.data.clone()),
                "config" => Some(places.config.clone()),
                "prefix" => places.prefix.clone(),
                _ => places.disc.clone(),
            };
            Some(v.ok_or_else(|| {
                Failure::new(
                    "launch.placeholder",
                    format!("The game uses ${{{name}}}, which has no value for its runner."),
                )
            })?)
        } else {
            None
        };
        match value {
            Some(v) => out.push_str(&v),
            None => out.push_str(&rest[i..i + 2 + end + 1]),
        }
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

fn substitute_all(args: &[String], places: &Places) -> Result<Vec<String>, Failure> {
    args.iter().map(|a| substitute(a, places)).collect()
}

/// `path` relative to `data`, when it is below it.
fn below(data: &str, path: &str) -> Option<String> {
    path.strip_prefix(&format!("{data}/")).map(str::to_string)
}

/// An absolute folder from the environment (`XDG_DATA_HOME`, `XDG_CONFIG_HOME`).
pub fn env_dir(env: &BTreeMap<String, String>, name: &str) -> Result<String, Failure> {
    match env.get(name) {
        Some(v)
            if v.starts_with('/')
                && !v.split('/').any(|c| c == "..")
                && !v.chars().any(char::is_control) =>
        {
            Ok(v.trim_end_matches('/').to_string())
        }
        _ => Err(Failure::new(
            "launch.environment",
            format!("{name} is not set to a folder, so the game has nowhere to keep its data."),
        )),
    }
}

fn root_of(
    c: &Component,
    chosen: &Chosen,
    bundled: &BTreeMap<String, BundledRunner>,
    system: &[FoundRunner],
) -> Result<Root, Failure> {
    match chosen {
        Chosen::Bundled { version } => {
            let (Some(b), Some(r)) = (&c.bundled, bundled.get(&c.id)) else {
                return Err(Failure::new(
                    "resolve.no_bundled",
                    format!("The component {} has no bundled copy.", c.id),
                ));
            };
            Ok(Root {
                path: join(APP, b.path.trim_end_matches('/')),
                entry: r.entry.clone(),
                in_use: RunnerInUse {
                    component: c.id.clone(),
                    family: r.family.clone(),
                    version: version.clone(),
                    source: "bundled".into(),
                    hash: None,
                },
                tested: None,
            })
        }
        Chosen::System { family, version } => {
            let found = system
                .iter()
                .find(|f| &f.runner.family == family && &f.runner.version == version)
                .ok_or_else(|| {
                    Failure::new(
                        "launch.runner_missing",
                        format!("The OS runner {family} {version} is not in the sandbox."),
                    )
                })?;
            if found.runner.kind != c.kind {
                return Err(Failure::new(
                    "launch.runner_kind",
                    format!(
                        "The OS runner {family} {version} is a {} runner, but the game needs a {} runner.",
                        found.runner.kind, c.kind
                    ),
                ));
            }
            Ok(Root {
                path: found.root.clone(),
                entry: found.runner.entry.clone(),
                in_use: RunnerInUse {
                    component: c.id.clone(),
                    family: family.clone(),
                    version: version.clone(),
                    source: "system".into(),
                    hash: found.hash.clone(),
                },
                tested: None,
            })
        }
    }
}

fn note_text(id: &str, n: &Note) -> String {
    match n {
        Note::OverrideBundledUnavailable => {
            format!("{id}: there is no bundled copy, so the package default runs")
        }
        Note::OverrideSystemUnavailable => {
            format!("{id}: the OS runner cannot serve it, so the package default runs")
        }
        Note::FencedByMaxMajor { have } => {
            format!("{id}: the OS runner {have} is above max_major, so the bundled copy runs")
        }
    }
}

/// The runner of every component, by id, and the notes on how they were decided: the one place
/// that calls `resolve::resolve` and finds the chosen runner on disk. [`plan`] and the library's
/// dry run ([`crate::dry_run`]) both start here.
pub fn pick_runners(
    manifest: &Manifest,
    bundled: &BTreeMap<String, BundledRunner>,
    system: &[FoundRunner],
    over: Override,
) -> Result<(BTreeMap<String, Root>, Vec<String>), Failure> {
    let families = runner::bundled_families(bundled);
    let found: Vec<_> = system.iter().map(FoundRunner::system_runner).collect();
    let resolution = resolve::resolve(&manifest.components, &found, &families, over);
    let mut notes = Vec::new();
    let mut roots: BTreeMap<String, Root> = BTreeMap::new();
    for (c, r) in manifest.components.iter().zip(&resolution.components) {
        notes.extend(r.notes.iter().map(|n| note_text(&c.id, n)));
        let chosen = r
            .outcome
            .as_ref()
            .map_err(|why| Failure::new(why.code(), why.message()))?;
        let mut root = root_of(c, chosen, bundled, system)?;
        root.tested = r.tested.clone();
        roots.insert(c.id.clone(), root);
    }
    Ok((roots, notes))
}

/// Decide how the game starts (see the module docs).
pub fn plan(inp: &Inputs<'_>) -> Result<Plan, Failure> {
    let m = inp.manifest;
    let run = &m.run;
    let data = env_dir(inp.base_env, "XDG_DATA_HOME")?;
    let config = env_dir(inp.base_env, "XDG_CONFIG_HOME")?;

    // Every component gets its runner from the one resolver.
    let (roots, notes) = pick_runners(m, inp.bundled, inp.system, inp.over)?;
    let main = run.component.as_ref().and_then(|id| roots.get(id));

    // The prefix, for the kinds that have one.
    let prefix_path = runner::prefix_dir(&run.runner, &data);
    let prefix_rel = prefix_path.as_ref().and_then(|p| below(&data, p));
    let prefix = prefix_rel.as_ref().map(|rel| PrefixPlan {
        rel: rel.clone(),
        template: run
            .prefix
            .as_ref()
            .and_then(|p| p.template.as_ref())
            .map(|t| join(APP, t.trim_end_matches('/'))),
    });
    let places = Places {
        payload: PAYLOAD.into(),
        data: data.clone(),
        config,
        prefix: prefix_path,
        disc: run.discs.first().map(|d| join(APP, d)),
        components: roots
            .iter()
            .map(|(id, r)| (id.clone(), r.path.clone()))
            .collect(),
    };

    let mut actions = Vec::new();
    let epoch = run.prefix.as_ref().map_or(0, |p| p.epoch);
    let mut fresh = false;
    if prefix.is_some() {
        if run.runner == "proton" {
            let dirs = runner::proton_dirs(&data);
            actions.push(Action::MakeDirs(
                [dirs.compat_data, dirs.client]
                    .iter()
                    .filter_map(|d| below(&data, d))
                    .collect(),
            ));
        }
        if !inp.prefix_exists {
            actions.push(Action::Create { epoch });
            fresh = true;
        } else if inp.state.epoch < epoch {
            let saves = m
                .data
                .saves
                .iter()
                .filter_map(|s| s.strip_prefix("prefix:"))
                .map(|s| s.trim_end_matches('/').to_string())
                .collect();
            actions.push(Action::Rebuild {
                from: inp.state.epoch,
                to: epoch,
                saves,
            });
            fresh = true;
        }
    }

    // The environment: base, then run.env, then the launcher's own.
    let mut env = inp.base_env.clone();
    env.extend(run.env.iter().map(|(k, v)| (k.clone(), v.clone())));
    let mut wrapper: Vec<String> = Vec::new();
    let mut setup_wrapper: Vec<String> = Vec::new();
    let mut then: Option<Vec<String>> = None;
    match (run.runner.as_str(), main.map(|r| (&r.path, &r.entry))) {
        ("wine", Some((root, Entry::Wine { wine, wineserver }))) => {
            let (wine, wineserver) = (join(root, wine), join(root, wineserver));
            env.insert(
                "WINEPREFIX".into(),
                places.prefix.clone().unwrap_or_default(),
            );
            env.insert("WINESERVER".into(), wineserver.clone());
            env.insert("WINELOADER".into(), wine.clone());
            env.remove("WINEARCH");
            if let Some(arch) = run.prefix.as_ref().and_then(|p| p.arch.as_ref()) {
                if fresh {
                    env.insert("WINEARCH".into(), arch.clone());
                }
            }
            wrapper = vec![wine.clone()];
            setup_wrapper = vec![wine];
            then = Some(vec![wineserver, "-w".into()]);
        }
        ("proton", Some((root, Entry::Proton { proton }))) => {
            let proton = join(root, proton);
            let dirs = runner::proton_dirs(&data);
            env.insert("STEAM_COMPAT_DATA_PATH".into(), dirs.compat_data);
            env.insert("STEAM_COMPAT_CLIENT_INSTALL_PATH".into(), dirs.client);
            // Outside Steam there is no game id. GE-Proton's protonfixes parses one out of
            // STEAM_COMPAT_DATA_PATH when none of these is set, and fails on a path without digits;
            // `0` makes it apply its defaults only. umu's own `UMU_ID` is refused in `run.env`, and
            // protonfixes reads it before SteamAppId, so one inherited from the launcher's own
            // environment would beat the 0: it is not passed on.
            env.insert("SteamAppId".into(), "0".into());
            env.insert("SteamGameId".into(), "0".into());
            env.remove("UMU_ID");
            // WINEPREFIX is the platform's (05 §6.3): Proton derives its own from
            // STEAM_COMPAT_DATA_PATH, so an inherited one is not passed on.
            env.remove("WINEPREFIX");
            wrapper = vec![proton.clone(), "waitforexitandrun".into()];
            setup_wrapper = vec![proton, "run".into()];
        }
        ("wine" | "proton", _) => {
            return Err(Failure::new(
                "launch.runner_entry",
                format!("The {} runner has no program to start.", run.runner),
            ))
        }
        _ => {}
    }

    let cwd = substitute(run.cwd.as_deref().unwrap_or("${payload}"), &places)?;
    // The shell that would set PWD is not here (the launcher execs the game directly), and
    // protonfixes reads it unguarded: it is the working folder every command below gets.
    env.insert("PWD".into(), cwd.clone());
    let command_of = |head: &[String], args: &[String]| -> Result<Command, Failure> {
        let mut argv = head.to_vec();
        argv.extend(substitute_all(args, &places)?);
        Ok(Command {
            argv,
            env: env.clone(),
            cwd: cwd.clone(),
        })
    };
    for step in &run.setup {
        let done = !fresh && inp.state.setup_done.iter().any(|d| d == &step.id);
        if step.once && done {
            continue;
        }
        let then = match &then {
            Some(t) => Some(command_of(t, &[])?),
            None => None,
        };
        actions.push(Action::Setup(SetupRun {
            id: step.id.clone(),
            once: step.once,
            command: command_of(&setup_wrapper, &step.command)?,
            then,
        }));
    }
    let command = command_of(&wrapper, &run.command)?;
    Ok(Plan {
        command,
        actions,
        data,
        prefix,
        runner: main.map(|r| r.in_use.clone()),
        notes,
    })
}
