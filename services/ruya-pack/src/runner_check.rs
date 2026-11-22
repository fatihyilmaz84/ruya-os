//! `runner-check <dir> [--write-hash]`: check a runner folder on disk the way the
//! console reads it and compute its runner hash (ADR-037, 05 sections 6.2.1 and 7.3).
//!
//! The folder's `runner.json` must be a regular file that [`parse_runner`] accepts, and every
//! entry it names a regular file of the folder ([`check_entries`]). The hash is the format's one
//! formula ([`runner_hash`]) over the folder's file table as `build` would write it ([`plan`]):
//! files with their SHA-256 and executable bit, links as written (relative, inside the folder),
//! empty folders; a root `.ruya-runner-hash` is left out. The image build runs it on each of its
//! system runners (`image/play/install-runners.sh`): `--write-hash` writes `.ruya-runner-hash`,
//! which the launcher reports; the folder is then a system runner's, so its name must be one
//! (`is_system_runner_name`). The shell's About pane lists the image's runners through Library1
//! (`ListRunners`, RUY-959), not through a file of this command. A packager can run it on a
//! bundled copy.

use crate::args::{parse, Spec};
use crate::build::{plan, write_if_changed, Planned};
use crate::report::{items, Reply, Stop};
use crate::Context;
use ruya_play_format::limits::MAX_RUNNER_JSON_BYTES;
use ruya_play_format::problem::Problems;
use ruya_play_format::runner::{
    check_entries, is_system_runner_name, parse_runner, runner_hash, BundledRunner, RunnerEntry,
    FILE_NAME, HASH_FILE,
};
use ruya_play_format::table::TableIndex;
use ruya_play_format::{codes as fcodes, EntryKind, FileEntry, FolderSource, Source};
use serde_json::json;
use std::collections::BTreeSet;
use std::path::PathBuf;

const SPEC: Spec = Spec {
    values: &[],
    switches: &["write-hash"],
    positionals: (1, 1),
};

/// The table as the format's entries, below `root/` (for [`check_entries`]).
fn table(root: &str, planned: &[Planned]) -> Vec<FileEntry> {
    planned
        .iter()
        .map(|p| match p {
            Planned::File {
                path,
                size,
                sha256,
                executable,
                ..
            } => FileEntry::File {
                path: format!("{root}/{path}"),
                size: *size,
                sha256: sha256.clone(),
                executable: *executable,
            },
            Planned::Link { path, to } => FileEntry::Link {
                path: format!("{root}/{path}"),
                to: to.clone(),
            },
            Planned::Dir { path } => FileEntry::Dir {
                path: format!("{root}/{path}"),
            },
        })
        .collect()
}

/// `runner-check`.
pub fn run(args: &[String], _ctx: &Context) -> Result<Reply, Stop> {
    let p = parse(args, &SPEC)?;
    let dir = PathBuf::from(&p.positional[0]);
    if !dir.is_dir() {
        return Err(Stop::Usage(format!(
            "{} is not a folder; runner-check takes the runner's folder",
            dir.display()
        )));
    }
    let name = std::fs::canonicalize(&dir)
        .ok()
        .and_then(|d| d.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_default();
    if p.has("write-hash") && !is_system_runner_name(&name) {
        return Err(Stop::Usage(format!(
            "{name:?} cannot be a system runner's folder: its name is the last part of the id org.ruyaos.Play.Runner.<Name> (letters, digits and _, not starting with a digit)"
        )));
    }
    let mut reply = Reply::default();
    let source = FolderSource::new(&dir);
    let listed = match source.entries() {
        Ok(e) => e,
        Err(problems) => {
            reply.problems = items(&problems);
            return Ok(reply);
        }
    };
    let file = format!("{name}/{FILE_NAME}");
    let is_file = listed
        .iter()
        .any(|e| e.path == FILE_NAME && e.kind == EntryKind::File);
    let mut problems = Problems::new();
    let runner = if is_file {
        match ruya_play_format::read_small(&source, FILE_NAME, MAX_RUNNER_JSON_BYTES) {
            Ok(bytes) => parse_runner(&bytes, &file, &mut problems),
            Err(e) => {
                let pr = e.into_problem(&file);
                problems.add(&pr.code, file.clone(), pr.message);
                None
            }
        }
    } else {
        problems.add(
            fcodes::RUNNER_NOT_A_FILE,
            file.clone(),
            "A runner carries runner.json as a regular file at the root of its folder.",
        );
        None
    };
    let keep = |e: &ruya_play_format::Entry| e.path != HASH_FILE;
    let planned = plan(
        &dir,
        &listed,
        &keep,
        true,
        &BTreeSet::new(),
        &mut reply.problems,
    )?;
    let entries = table(&name, &planned);
    if let Some(r) = &runner {
        let bundled = BundledRunner {
            family: r.family.clone(),
            entry: r.entry.clone(),
            declared: Some(r.clone()),
        };
        check_entries(&name, &bundled, &TableIndex::new(&entries), &mut problems);
    }
    reply.problems.extend(items(&problems.finish()));
    let (Some(r), true) = (runner, reply.problems.is_empty()) else {
        return Ok(reply);
    };
    // The runner hash (05 section 7.3) of the table below the folder, paths relative to it.
    let prefix = format!("{name}/");
    let h = runner_hash(entries.iter().filter_map(|e| {
        let rel = e.path().strip_prefix(&prefix)?;
        Some(RunnerEntry::from(e).with_rel(rel))
    }));
    let mut text = format!(
        "runner {name}: {} {} ({}), {} entries\nrunner hash {h}\n",
        r.family,
        r.version,
        r.kind,
        planned.len()
    );
    if p.has("write-hash") {
        let path = dir.join(HASH_FILE);
        write_if_changed(&path, format!("{h}\n").as_bytes())?;
        text.push_str(&format!("wrote {}\n", path.display()));
    }
    reply.fields.insert(
        "runner".into(),
        json!({
            "name": name,
            "family": r.family,
            "kind": r.kind,
            "version": r.version,
            "licence": r.licence,
            "source_url": r.source_url,
        }),
    );
    reply.fields.insert("hash".into(), json!(h));
    reply.fields.insert("entries".into(), json!(planned.len()));
    reply.text = text;
    Ok(reply)
}
