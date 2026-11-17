//! `validate`: every rule that can run off the device. It is the format crate's own `validate`
//! (schema, paths, file table, hashes), then the art and video vetting of `ruya-play-art` into a
//! scratch folder, then the licence duty of bundled components, the FAT32 warning, and a dry run
//! of the runner resolution of 05 section 6.2 against the system runners given on the command line.

use crate::args::{parse, Parsed, Spec};
use crate::fixes::codes;
use crate::pkg::{self, OpenError, Opened};
use crate::report::{items, Item, Reply, Stop};
use crate::Context;
use ruya_play_art::{Outcome as ArtOutcome, Slot};
use ruya_play_format::manifest::{ArtPath, Manifest};
use ruya_play_format::resolve::{resolve, Chosen, Override, Resolution, SystemRunner};
use ruya_play_format::{FileEntry, Package, Source, ValidateOptions};
use serde_json::{json, Value};
use std::io::Write;
use std::path::PathBuf;

/// Options common to the commands that dry-run the runner resolution.
pub const RUNNER_VALUES: &[&str] = &["system-wine", "system-proton-ge", "system-runner"];

/// The system runners named on the command line.
pub fn runners_from(p: &Parsed) -> Result<Vec<SystemRunner>, Stop> {
    let mut out = Vec::new();
    for v in p.all("system-wine") {
        out.push(SystemRunner::new("wine", v));
    }
    for v in p.all("system-proton-ge") {
        out.push(SystemRunner::new("proton-ge", v));
    }
    for v in p.all("system-runner") {
        match v.split_once('=') {
            Some((f, ver)) if !f.is_empty() && !ver.is_empty() => {
                out.push(SystemRunner::new(f, ver))
            }
            _ => {
                return Err(Stop::Usage(format!(
                    "--system-runner takes family=version, not {v}"
                )))
            }
        }
    }
    Ok(out)
}

/// The status of one art slot.
#[derive(Debug, Clone)]
pub struct ArtStatus {
    /// `icon`, `screenshot-0`, ...
    pub slot: String,
    /// Package path of the file.
    pub path: String,
    /// `None` when the file passed, else the code that refused it.
    pub refused: Option<String>,
}

/// Everything `validate` found out.
pub struct Checked {
    /// The package, when the format rules passed.
    pub package: Option<Package>,
    /// Problems, in the order found.
    pub problems: Vec<Item>,
    /// Warnings.
    pub warnings: Vec<Item>,
    /// One entry per art file that was vetted.
    pub art: Vec<ArtStatus>,
    /// The dry run of the runner resolution (components with a system runner named only).
    pub resolution: Option<Resolution>,
    /// Ids of components that were not dry-run because no runner of their family was named.
    pub not_checked: Vec<String>,
}

const FAT32_LIMIT: u64 = 0xFFFF_FFFF;

/// Run every off-device rule on `source`. `zip_bytes` is the size of the zip file, if it is one.
pub fn check(source: &dyn Source, runners: &[SystemRunner], zip_bytes: u64) -> Checked {
    let mut out = Checked {
        package: None,
        problems: Vec::new(),
        warnings: Vec::new(),
        art: Vec::new(),
        resolution: None,
        not_checked: Vec::new(),
    };
    let package = match ruya_play_format::validate(source, &ValidateOptions::default()) {
        Ok(p) => p,
        Err(problems) => {
            out.problems = items(&problems);
            return out;
        }
    };
    vet_art(source, &package.manifest, &mut out);
    licence_duty(&package, &mut out.problems);
    fat32(&package, zip_bytes, &mut out.warnings);
    dry_run(&package.manifest, runners, &mut out);
    out.package = Some(package);
    out
}

fn art_inputs(m: &Manifest) -> Vec<(Slot, String)> {
    let a = &m.art;
    let mut v = vec![(Slot::Icon, a.icon.clone())];
    match &a.logo {
        Some(ArtPath::One(p)) => v.push((Slot::Logo, p.clone())),
        Some(ArtPath::PerLanguage(map)) => {
            v.extend(map.values().map(|p| (Slot::Logo, p.clone())));
        }
        None => {}
    }
    if let Some(p) = &a.hero {
        v.push((Slot::Hero, p.clone()));
    }
    if let Some(p) = &a.cover {
        v.push((Slot::Cover, p.clone()));
    }
    for (i, s) in a.screenshots.iter().enumerate() {
        v.push((Slot::Screenshot(i.min(255) as u8), s.file.clone()));
    }
    if let Some(t) = &a.trailer {
        v.push((Slot::Trailer, t.file.clone()));
        if let Some(p) = &t.poster {
            v.push((Slot::TrailerPoster, p.clone()));
        }
    }
    if let Some(p) = &a.preview {
        v.push((Slot::Preview, p.clone()));
    }
    v
}

/// Copy each art file out of the package into a scratch folder and vet it with `ruya-play-art`.
fn vet_art(source: &dyn Source, m: &Manifest, out: &mut Checked) {
    let scratch = match tempfile::tempdir() {
        Ok(s) => s,
        Err(e) => {
            out.problems.push(Item::new(
                codes::IO,
                "",
                format!("cannot make a scratch folder for the art check ({e})"),
            ));
            return;
        }
    };
    for (n, (slot, rel)) in art_inputs(m).into_iter().enumerate() {
        let dir = scratch.path().join(format!("in{n}"));
        let local: PathBuf = rel.split('/').fold(dir.clone(), |p, c| p.join(c));
        let copied = (|| -> std::io::Result<()> {
            if let Some(parent) = local.parent() {
                std::fs::create_dir_all(parent)?;
            }
            let mut f = std::fs::File::create(&local)?;
            std::io::copy(&mut source.open(&rel)?, &mut f)?;
            f.flush()
        })();
        if let Err(e) = copied {
            out.problems.push(Item::new(
                codes::IO,
                rel.clone(),
                format!("cannot read the file for the art check ({e})"),
            ));
            continue;
        }
        let results = ruya_play_art::vet(&[(slot, local)], &scratch.path().join(format!("out{n}")));
        for r in results {
            let refused = match r.outcome {
                ArtOutcome::Ok { .. } => None,
                ArtOutcome::Missing => Some("art.missing".to_string()),
                ArtOutcome::Invalid { code, message } => {
                    out.problems.push(Item::new(code, rel.clone(), message));
                    Some(code.to_string())
                }
            };
            out.art.push(ArtStatus {
                slot: r.slot.key(),
                path: rel.clone(),
                refused,
            });
        }
    }
}

fn is_copyleft(spdx: &str) -> bool {
    let u = spdx.to_ascii_uppercase();
    [
        "GPL", "MPL", "EPL", "CDDL", "EUPL", "OSL", "CC-BY-SA", "SSPL", "CECILL", "MS-RL",
    ]
    .iter()
    .any(|c| u.contains(c))
}

/// The licence duty of bundled components (05 section 6.2): the SPDX id (the format crate checks
/// its shape), the licence text under `licences/`, and for copyleft code a `source_url` or the
/// source itself under `licences/`.
fn licence_duty(p: &Package, problems: &mut Vec<Item>) {
    let under_licences: Vec<String> = p
        .files
        .iter()
        .filter_map(|f| match f {
            FileEntry::File { path, .. } if path.starts_with("licences/") => {
                Some(path.to_lowercase())
            }
            _ => None,
        })
        .collect();
    for (i, c) in p.manifest.components.iter().enumerate() {
        let Some(b) = &c.bundled else { continue };
        let at = format!("/components/{i}/bundled");
        let folder = b.path.rsplit('/').next().unwrap_or("").to_lowercase();
        let names = [c.id.to_lowercase(), b.licence.to_lowercase(), folder];
        let has_text = under_licences.iter().any(|f| {
            names
                .iter()
                .any(|n| !n.is_empty() && f.contains(n.as_str()))
        });
        if !has_text {
            problems.push(Item::new(
                codes::LICENCE_TEXT_MISSING,
                format!("{at}/licence"),
                format!(
                    "The bundled component \"{}\" ({}) has no licence text under licences/; a file there must be named after the component or the licence.",
                    c.id, b.licence
                ),
            ));
        }
        if is_copyleft(&b.licence)
            && b.source_url.is_none()
            && !under_licences.iter().any(|f| f.contains("source"))
        {
            problems.push(Item::new(
                codes::LICENCE_SOURCE_MISSING,
                format!("{at}/source_url"),
                format!(
                    "{} is copyleft: the package must say where the source of \"{}\" is.",
                    b.licence, c.id
                ),
            ));
        }
    }
}

/// Warnings for files (and a zip) a FAT32 drive cannot hold.
pub fn fat32(p: &Package, zip_bytes: u64, warnings: &mut Vec<Item>) {
    for f in &p.files {
        if let FileEntry::File { path, size, .. } = f {
            if *size > FAT32_LIMIT {
                warnings.push(Item::new(
                    codes::SIZE_FAT32,
                    path.clone(),
                    format!("This file is {size} bytes; a FAT32 drive holds files below 4 GiB. Use exFAT for the USB drive."),
                ));
            }
        }
    }
    if zip_bytes > FAT32_LIMIT {
        warnings.push(Item::new(
            codes::SIZE_FAT32,
            "",
            format!("The zip file is {zip_bytes} bytes; a FAT32 drive holds files below 4 GiB. Use exFAT for the USB drive."),
        ));
    }
}

/// Dry-run the resolution for the components whose family has a runner named on the command line.
fn dry_run(m: &Manifest, runners: &[SystemRunner], out: &mut Checked) {
    use ruya_play_format::resolve::families_of;
    let mut checked = Vec::new();
    for c in &m.components {
        let named = families_of(c)
            .iter()
            .any(|f| runners.iter().any(|r| &r.family == f));
        // A component that never looks at the OS needs no list; the others are skipped honestly.
        let needs_system = !matches!(c.source.as_str(), "bundled" | "prefer-bundled");
        if needs_system && !named {
            out.not_checked.push(c.id.clone());
        } else {
            checked.push(c.clone());
        }
    }
    if !out.not_checked.is_empty() {
        out.warnings.push(Item::new(
            codes::RESOLVE_NOT_CHECKED,
            "/components",
            format!(
                "No system runner was named for: {}. Their runner choice was not checked.",
                out.not_checked.join(", ")
            ),
        ));
    }
    if checked.is_empty() {
        return;
    }
    let r = resolve(&checked, runners, Override::PackageDefault);
    for (i, c) in r.components.iter().enumerate() {
        if let Err(why) = &c.outcome {
            out.problems.push(Item::new(
                why.code(),
                format!("/components/{}", component_index(m, &c.id).unwrap_or(i)),
                format!("Component \"{}\": {}", c.id, why.message()),
            ));
        }
    }
    out.resolution = Some(r);
}

fn component_index(m: &Manifest, id: &str) -> Option<usize> {
    m.components.iter().position(|c| c.id == id)
}

/// The JSON of a dry run.
pub fn resolution_json(r: &Resolution) -> Value {
    Value::Array(
        r.components
            .iter()
            .map(|c| match &c.outcome {
                Ok(Chosen::Bundled { version }) => {
                    json!({"id": c.id, "runner": "bundled", "version": version, "tested": c.tested})
                }
                Ok(Chosen::System { family, version }) => {
                    json!({"id": c.id, "runner": "system", "family": family, "version": version, "tested": c.tested})
                }
                Err(why) => json!({"id": c.id, "runner": null, "code": why.code(), "message": why.message()}),
            })
            .collect(),
    )
}

/// One line per component for the text form.
pub fn resolution_text(r: &Resolution) -> String {
    let mut s = String::new();
    for c in &r.components {
        let how = match &c.outcome {
            Ok(Chosen::Bundled { version }) => format!("the bundled copy ({version})"),
            Ok(Chosen::System { family, version }) => format!("the system {family} {version}"),
            Err(why) => format!("none ({})", why.message()),
        };
        let tested = c
            .tested
            .as_deref()
            .map(|t| format!(", tested with {t}"))
            .unwrap_or_default();
        s.push_str(&format!("  runner {}: {how}{tested}\n", c.id));
    }
    s
}

/// The JSON of the art status.
pub fn art_json(art: &[ArtStatus]) -> Value {
    Value::Array(
        art.iter()
            .map(|a| json!({"slot": a.slot, "path": a.path, "ok": a.refused.is_none(), "code": a.refused}))
            .collect(),
    )
}

const SPEC: Spec = Spec {
    values: RUNNER_VALUES,
    switches: &[],
    positionals: (1, 1),
};

/// `validate <pkg> [--system-wine V] [--system-proton-ge V] [--system-runner family=V]`.
pub fn run(args: &[String], _ctx: &Context) -> Result<Reply, Stop> {
    let p = parse(args, &SPEC)?;
    let runners = runners_from(&p)?;
    let opened = match pkg::open(&p.positional[0]) {
        Ok(o) => o,
        Err(OpenError::Stop(s)) => return Err(s),
        Err(OpenError::Problems(problems)) => {
            return Ok(Reply {
                problems,
                ..Reply::default()
            })
        }
    };
    Ok(report(
        &opened,
        check(&*opened.source, &runners, opened.file_bytes),
    ))
}

/// The reply of `validate` for a checked package.
pub fn report(opened: &Opened, c: Checked) -> Reply {
    let mut reply = Reply {
        problems: c.problems,
        warnings: c.warnings,
        ..Reply::default()
    };
    let form = if opened.is_dir { "folder" } else { "zip" };
    reply.fields.insert("form".into(), json!(form));
    if let Some(p) = &c.package {
        let m = &p.manifest;
        reply.fields.insert("id".into(), json!(m.id));
        reply.fields.insert("build".into(), json!(m.build));
        reply
            .fields
            .insert("installed_bytes".into(), json!(p.installed_bytes));
        reply
            .fields
            .insert("installed_mb".into(), json!(p.installed_mb()));
        reply
            .fields
            .insert("min_ram_mb".into(), json!(m.requirements.min_ram_mb));
        reply.text.push_str(&format!(
            "{} {} (build {}): {} files, {} MB installed\n",
            m.id,
            m.version,
            m.build,
            p.files.len(),
            p.installed_mb()
        ));
        if let Some(ram) = m.requirements.min_ram_mb {
            reply
                .text
                .push_str(&format!("  needs at least {ram} MB of memory\n"));
        }
    }
    reply.fields.insert("art".into(), art_json(&c.art));
    if let Some(r) = &c.resolution {
        reply.fields.insert("resolution".into(), resolution_json(r));
        reply.text.push_str(&resolution_text(r));
    }
    if reply.problems.is_empty() {
        reply
            .text
            .push_str("ok: the package passes every check that runs off the device\n");
    }
    reply
}
