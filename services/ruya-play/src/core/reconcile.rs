//! The start-up reconcile (RUY-829, 05 §7.3): the `play.<id>` apps committed to the system
//! Flatpak installation against `state/installed.json` and the trust store's key records.
//!
//! An install writes its records before the commit (fail closed) and a Store uninstall does not
//! tell the importer, so the three can disagree after a crash or an uninstall. The rules
//! ([`plan`]):
//!
//! - a build recorded for an id with no committed app is forgotten (the commit never landed, or the
//!   app was uninstalled); its key record stays, so the id can only come back under its key (saves
//!   may be kept, 05 §10);
//! - a committed app whose own `play.json` (our verified commit) names another build than the
//!   record, or one that has no record, gets that build recorded (the downgrade guard);
//! - a committed app whose build cannot be read, or that is signed (`play.sig` in `/app`) but has
//!   no key record, is **held**: installs of its id are refused with `installed.unreconciled`
//!   until it is uninstalled (a first sight would let any key take it over);
//! - a committed app that is not held and whose record has an older metadata generation than the
//!   commit generates now (ADR-038; none recorded is generation 0) is **re-committed**: its
//!   deployed `/app` goes through the commit again with freshly generated metadata
//!   ([`installed_app`], `Importer::recommit`).
//!
//! The service reconciles before it takes its bus name, so no install runs against unreconciled
//! records. The re-commits run after it took the name (each can take as long as a commit), one job
//! at a time with the installs.

use crate::core::codes;
use crate::core::installed::Installed;
use crate::core::staging::Dir;
use crate::core::unpack::staging_problem;
use crate::core::verify;
use crate::service::commit::TRUST_RECORD_IN_APP;
use ruya_play_format::limits::{INPUT_MODES, REMOVABLE_MEDIA};
use ruya_play_format::manifest::{parse_manifest, Manifest, Permissions};
use ruya_play_format::problem::Problems;
use ruya_play_format::table::TableIndex;
use ruya_play_format::Problem;
use ruya_play_trust::trust_record::MAX_TRUST_RECORD_BYTES;
use ruya_play_trust::{check_ceiling, Assessment, Tier, TrustRecord};
use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::path::Path;

/// The most bytes read of a committed app's `play.json` (the format's own limit for it).
pub const MAX_PLAY_JSON_BYTES: u64 = 1024 * 1024;

/// What the installation holds for one id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Deployed {
    /// The build in its `/app/play.json`, `None` when it cannot be read.
    pub build: Option<u64>,
    /// `/app/play.sig` exists: the package was signed.
    pub signed: bool,
}

/// One step of the reconcile.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// Forget the recorded build of `id` (no app is committed for it).
    ForgetBuild {
        /// The id (lower case).
        id: String,
    },
    /// Record `build` for `id` (the committed app's own).
    RecordBuild {
        /// The id (lower case).
        id: String,
        /// The committed build.
        build: u64,
    },
    /// Refuse installs of `id` (`installed.unreconciled`).
    Hold {
        /// The id (lower case).
        id: String,
        /// Why, for the log.
        reason: String,
    },
    /// Commit the app of `id` again with the metadata generated now (ADR-038): its recorded
    /// generation is older than the current one. The service runs it after it took its bus name
    /// (`Importer::recommit`).
    Recommit {
        /// The id (lower case).
        id: String,
    },
}

impl Action {
    /// The id the step is about.
    pub fn id(&self) -> &str {
        match self {
            Action::ForgetBuild { id }
            | Action::RecordBuild { id, .. }
            | Action::Hold { id, .. }
            | Action::Recommit { id } => id,
        }
    }
}

/// The reconcile steps for the committed apps `deployed`, the records `recorded` and the ids with
/// a key record `trusted` (all ids lower case), in id order; `generation` is the generation of the
/// metadata the commit generates now. A held app is never re-committed.
pub fn plan(
    deployed: &BTreeMap<String, Deployed>,
    recorded: &BTreeMap<String, Installed>,
    trusted: &BTreeSet<String>,
    generation: u32,
) -> Vec<Action> {
    let mut out = Vec::new();
    for id in recorded.keys() {
        if !deployed.contains_key(id) {
            out.push(Action::ForgetBuild { id: id.clone() });
        }
    }
    for (id, d) in deployed {
        match d.build {
            None => out.push(Action::Hold {
                id: id.clone(),
                reason: "its play.json cannot be read".into(),
            }),
            Some(build) => {
                let record = recorded.get(id);
                if record.map(|r| r.build) != Some(build) {
                    out.push(Action::RecordBuild {
                        id: id.clone(),
                        build,
                    });
                }
                if d.signed && !trusted.contains(id) {
                    out.push(Action::Hold {
                        id: id.clone(),
                        reason: "it is signed but its key record is missing".into(),
                    });
                } else if record.map_or(0, |r| r.generation) < generation {
                    out.push(Action::Recommit { id: id.clone() });
                }
            }
        }
    }
    out
}

/// The build in a committed app's `play.json` bytes, when its `id` is `id` (case folded).
pub fn build_in(play_json: &[u8], id: &str) -> Option<u64> {
    let v: serde_json::Value = serde_json::from_slice(play_json).ok()?;
    let own = v.get("id")?.as_str()?;
    if !own.eq_ignore_ascii_case(id) {
        return None;
    }
    v.get("build")?.as_u64()
}

/// The display name in a committed app's `play.json` bytes, when its `id` is `id` (case
/// folded): English, else the first language. `None` when there is none or it is not plain text
/// of at most [`crate::core::jobs::MAX_NAME_BYTES`] bytes.
pub fn name_in(play_json: &[u8], id: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_slice(play_json).ok()?;
    if !v.get("id")?.as_str()?.eq_ignore_ascii_case(id) {
        return None;
    }
    let names: ruya_play_format::manifest::Localized =
        serde_json::from_value(v.get("name")?.clone()).ok()?;
    let name = ruya_play_format::manifest::english(&names)?;
    (name.len() <= crate::core::jobs::MAX_NAME_BYTES && !name.chars().any(char::is_control))
        .then(|| name.to_string())
}

/// A committed app's own `play.json` bytes (at most [`MAX_PLAY_JSON_BYTES`]), `None` when it
/// cannot be read or is longer, when `id` is not a [`plain_id`], or when the deployment is not
/// [`ours`].
pub fn deployed_play_json(installation: &Path, id: &str) -> Option<Vec<u8>> {
    read_bounded(our_files(installation, id)?.open_file("play.json").ok()?)
}

/// The most of a deployment's `deploy` file read to find its origin (the origin is its first
/// string; the rest is the commit, subpaths and metadata).
const MAX_DEPLOY_HEAD_BYTES: u64 = 4096;

/// The Flatpak remote a deployment came from: the first, NUL-terminated string of its `deploy`
/// file (a GVariant `(ssasta{sv})`), read through `active`, the opened deployment folder. `None`
/// when the file is missing, not a plain file, unreadable, not UTF-8 or has no NUL in its first
/// [`MAX_DEPLOY_HEAD_BYTES`].
fn origin_in(active: &Dir) -> Option<String> {
    let mut head = Vec::new();
    active
        .open_file("deploy")
        .and_then(|f| f.take(MAX_DEPLOY_HEAD_BYTES).read_to_end(&mut head))
        .ok()?;
    let end = head.iter().position(|&b| b == 0)?;
    String::from_utf8(head[..end].to_vec()).ok()
}

/// Opens the deployment folder of the app `play.<id>` (`app/play.<id>/current/active`, where
/// Flatpak's own `current` and `active` are links, resolved once here) and returns it only when it
/// is one this service made, i.e. its `deploy` file, read through the opened folder, names
/// [`ruya_play_art::PLAY_REMOTE`]. `.play` is a real top-level domain, so a Flathub app can be
/// named `play.<something>`; nothing else in this service may adopt, verify or read it. A missing
/// or unreadable `deploy` file, a name that is not a [`plain_id`] and any other origin (a prefix
/// of ours too) are not ours. The one origin check of every reader of `app/play.*`: the caller
/// reads the app only through the returned folder, so what it reads is what was checked.
pub fn open_ours(installation: &Path, id: &str) -> Option<Dir> {
    if !plain_id(id) {
        return None;
    }
    let link = installation
        .join("app")
        .join(format!("play.{id}"))
        .join("current")
        .join("active");
    let active = Dir::open_root(&std::fs::canonicalize(link).ok()?).ok()?;
    (origin_in(&active).as_deref() == Some(ruya_play_art::PLAY_REMOTE)).then_some(active)
}

/// Is the deployed app `play.<id>` one this service made? See [`open_ours`].
pub fn ours(installation: &Path, id: &str) -> bool {
    open_ours(installation, id).is_some()
}

/// The `/app` folder (`files`) of an app that is [`ours`], opened through the folder that was
/// checked; `None` when it is not ours or has no such folder.
pub fn our_files(installation: &Path, id: &str) -> Option<Dir> {
    open_ours(installation, id)?.open_dir("files").ok()
}

fn read_bounded(file: std::fs::File) -> Option<Vec<u8>> {
    read_at_most(file, MAX_PLAY_JSON_BYTES)
}

/// The bytes of `file`, `None` when it cannot be read or is longer than `limit`.
fn read_at_most(file: std::fs::File, limit: u64) -> Option<Vec<u8>> {
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 <= limit).then_some(bytes)
}

/// What the commit of an app that is [`ours`] was generated from, read back from its deployed
/// `/app` folder `files` (opened through [`open_ours`]), for a re-commit (ADR-038): the manifest,
/// parsed by the format's own parser against the stored `play.files` (with the official rules
/// when the trust record says `official`), and its assessment under the tier of the trust record
/// the commit wrote, with the ceiling an install applies. An app that cannot be read back so, or
/// whose requests the ceiling now refuses, is an `installed.unreconciled` problem that says why:
/// it is left as it is.
pub fn installed_app(files: &Dir) -> Result<(Manifest, Assessment), Problem> {
    let unreadable = |what: &str| {
        Problem::new(
            codes::INSTALLED_UNRECONCILED,
            "",
            format!("The installed app cannot be committed again: {what}."),
        )
    };
    let mut trust_dir = files.try_clone().map_err(|e| staging_problem("", &e))?;
    let (folders, name) = TRUST_RECORD_IN_APP
        .rsplit_once('/')
        .unwrap_or(("", TRUST_RECORD_IN_APP));
    for folder in folders.split('/').filter(|f| !f.is_empty()) {
        trust_dir = trust_dir
            .open_dir(folder)
            .map_err(|_| unreadable("its trust record is missing"))?;
    }
    let tier = trust_dir
        .open_file(name)
        .ok()
        .and_then(|f| read_at_most(f, MAX_TRUST_RECORD_BYTES as u64))
        .and_then(|b| TrustRecord::parse(&b))
        .and_then(|r| r.tier())
        .ok_or_else(|| unreadable("its trust record cannot be read"))?;
    let table = verify::read_table(files)?;
    let bytes = files
        .open_file("play.json")
        .ok()
        .and_then(read_bounded)
        .ok_or_else(|| unreadable("its play.json cannot be read"))?;
    let mut problems = Problems::new();
    let manifest = parse_manifest(
        &bytes,
        &table,
        &TableIndex::new(&table),
        tier == Tier::Official,
        &mut problems,
    );
    let manifest = match (manifest, problems.finish().into_iter().next()) {
        (Some(m), None) => m,
        (_, Some(p)) => return Err(p),
        (None, None) => return Err(unreadable("its play.json does not parse")),
    };
    let assessment = check_ceiling(tier, &manifest.permissions).map_err(|e| e.to_problem())?;
    Ok((manifest, assessment))
}

/// The `permissions` of a committed app's `play.json` bytes, when its `id` is `id` (case folded):
/// the vocabulary's values with the defaults filled in, `reasons` left out. `None` for anything
/// the format would not have accepted (a key or value outside the vocabulary, a wrong type): the
/// commit was validated, so that means it cannot be trusted to say what it asked for.
pub fn permissions_in(play_json: &[u8], id: &str) -> Option<Permissions> {
    let v: serde_json::Value = serde_json::from_slice(play_json).ok()?;
    if !v.get("id")?.as_str()?.eq_ignore_ascii_case(id) {
        return None;
    }
    let mut out = Permissions::default();
    let Some(p) = v.get("permissions") else {
        return Some(out);
    };
    for (key, value) in p.as_object()? {
        match key.as_str() {
            "input" => {
                let s = value.as_str()?;
                INPUT_MODES.contains(&s).then_some(())?;
                out.input = s.to_string();
            }
            "removable_media" => {
                let s = value.as_str()?;
                REMOVABLE_MEDIA.contains(&s).then_some(())?;
                out.removable_media = s.to_string();
            }
            "network" => out.network = value.as_bool()?,
            "multiarch" => out.multiarch = value.as_bool()?,
            "gamemode" => out.gamemode = value.as_bool()?,
            "realtime" => out.realtime = value.as_bool()?,
            "devel" => out.devel = value.as_bool()?,
            "reasons" => {}
            _ => return None,
        }
    }
    Some(out)
}

/// Where a committed app's `/app` folder is: `app/play.<id>/current/active/files` below the
/// installation. Neither the id nor the origin is checked here; see [`open_ours`].
pub fn deployment_files(installation: &Path, id: &str) -> std::path::PathBuf {
    installation
        .join("app")
        .join(format!("play.{id}"))
        .join("current")
        .join("active")
        .join("files")
}

/// Is `id` a name [`deployed_apps`] would list (not empty, no separator or control character)?
pub fn plain_id(id: &str) -> bool {
    !id.is_empty() && !id.contains(['/', '\\']) && !id.chars().any(char::is_control)
}

/// The `play.*` apps of the Flatpak installation at `installation` (`/var/lib/flatpak`): every
/// `app/play.<id>/current/active/files/` with what its `play.json` and `play.sig` say. An app
/// folder that is not `play.` plus a plain id, or whose deployment is not [`ours`], is skipped
/// (so [`plan`] forgets a build recorded for it and never touches the app). A missing `app/` is
/// an empty list.
pub fn deployed_apps(installation: &Path) -> std::io::Result<BTreeMap<String, Deployed>> {
    let mut out = BTreeMap::new();
    let entries = match std::fs::read_dir(installation.join("app")) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(out),
        Err(e) => return Err(e),
    };
    for entry in entries {
        let entry = entry?;
        let Some(name) = entry.file_name().to_str().map(str::to_string) else {
            continue;
        };
        let Some(id) = name.strip_prefix("play.") else {
            continue;
        };
        let Some(files) = our_files(installation, id) else {
            continue;
        };
        let build = files
            .open_file("play.json")
            .ok()
            .and_then(read_bounded)
            .and_then(|b| build_in(&b, id));
        // Anything named `play.sig` (a link too) counts as signed; only its absence does not.
        let signed = !matches!(
            files.open_file("play.sig"),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound
        );
        out.insert(id.to_ascii_lowercase(), Deployed { build, signed });
    }
    Ok(out)
}

/// The `rollback_failed` lines of `state/journal` as log lines (05 §7.3 step 9): one per JSON line
/// with that event, its `time`, `job`, `id` and `detail` cleaned of control characters and cut to
/// 512 characters each. Other lines are skipped.
pub fn rollback_failures(journal: &str) -> Vec<String> {
    let clean = |v: Option<&serde_json::Value>| -> String {
        let text = match v {
            Some(serde_json::Value::String(s)) => s.clone(),
            Some(serde_json::Value::Number(n)) => n.to_string(),
            _ => String::new(),
        };
        text.chars().filter(|c| !c.is_control()).take(512).collect()
    };
    journal
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .filter(|v| v.get("event").and_then(|e| e.as_str()) == Some("rollback_failed"))
        .map(|v| {
            format!(
                "an earlier install's records could not be rolled back: time {}, job {}, id {}: {}",
                clean(v.get("time")),
                clean(v.get("job")),
                clean(v.get("id")),
                clean(v.get("detail"))
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(build: Option<u64>, signed: bool) -> Deployed {
        Deployed { build, signed }
    }

    fn rec(build: u64, generation: u32) -> Installed {
        Installed { build, generation }
    }

    #[test]
    fn the_rules() {
        let deployed: BTreeMap<String, Deployed> = [
            ("same".to_string(), d(Some(3), true)),
            ("newer".to_string(), d(Some(5), true)),
            ("unrecorded".to_string(), d(Some(2), false)),
            ("unreadable".to_string(), d(None, true)),
            ("keyless".to_string(), d(Some(1), true)),
            ("stale".to_string(), d(Some(6), false)),
        ]
        .into_iter()
        .collect();
        let recorded: BTreeMap<String, Installed> = [
            ("same".to_string(), rec(3, 2)),
            ("newer".to_string(), rec(4, 2)),
            ("gone".to_string(), rec(7, 0)),
            ("keyless".to_string(), rec(1, 0)),
            ("stale".to_string(), rec(6, 1)),
        ]
        .into_iter()
        .collect();
        let trusted: BTreeSet<String> = ["same", "newer", "gone", "unreadable"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let actions = plan(&deployed, &recorded, &trusted, 2);
        assert_eq!(
            actions,
            vec![
                Action::ForgetBuild { id: "gone".into() },
                // Held: never re-committed, whatever its generation.
                Action::Hold {
                    id: "keyless".into(),
                    reason: "it is signed but its key record is missing".into()
                },
                Action::RecordBuild {
                    id: "newer".into(),
                    build: 5
                },
                // Generation 1 of 2: committed again.
                Action::Recommit { id: "stale".into() },
                Action::Hold {
                    id: "unreadable".into(),
                    reason: "its play.json cannot be read".into()
                },
                // No record is generation 0.
                Action::RecordBuild {
                    id: "unrecorded".into(),
                    build: 2
                },
                Action::Recommit {
                    id: "unrecorded".into()
                },
            ]
        );
        // Everything agrees: nothing to do.
        let one: BTreeMap<String, Deployed> = [("same".to_string(), d(Some(3), true))]
            .into_iter()
            .collect();
        let at = |generation| -> BTreeMap<String, Installed> {
            [("same".to_string(), rec(3, generation))]
                .into_iter()
                .collect()
        };
        assert!(plan(&one, &at(2), &trusted, 2).is_empty());
        // A newer generation than the commit's (an OS rollback) is left alone too.
        assert!(plan(&one, &at(3), &trusted, 2).is_empty());
        assert_eq!(
            plan(&one, &at(1), &trusted, 2),
            vec![Action::Recommit { id: "same".into() }]
        );
    }

    #[test]
    fn the_build_is_read_from_the_apps_own_play_json() {
        assert_eq!(
            build_in(
                br#"{"id":"Com.Example.Game","build":12}"#,
                "com.example.game"
            ),
            Some(12)
        );
        assert_eq!(
            build_in(br#"{"id":"com.other","build":12}"#, "com.example.game"),
            None
        );
        assert_eq!(build_in(br#"{"id":"a","build":"12"}"#, "a"), None);
        assert_eq!(build_in(b"not json", "a"), None);
    }

    #[test]
    fn deployed_apps_are_read_from_the_installation() {
        let root = tempfile::tempdir().unwrap();
        let app = |name: &str, json: Option<&[u8]>, sig: bool| {
            let origin = match name {
                "play.com.example.hub" => "flathub",
                "play.com.example.evil" => "ruyaos-play-local-evil",
                "play.com.example.nodeploy" => "",
                _ => ruya_play_art::PLAY_REMOTE,
            };
            let files = root
                .path()
                .join("app")
                .join(name)
                .join("current/active/files");
            std::fs::create_dir_all(&files).unwrap();
            if !origin.is_empty() {
                std::fs::write(
                    files.parent().unwrap().join("deploy"),
                    format!("{origin}\0abcdef\0"),
                )
                .unwrap();
            }
            if let Some(j) = json {
                std::fs::write(files.join("play.json"), j).unwrap();
            }
            if sig {
                std::fs::write(files.join("play.sig"), b"sig").unwrap();
            }
        };
        app(
            "play.com.example.a",
            Some(br#"{"id":"com.example.a","build":4}"#),
            true,
        );
        app("play.com.example.b", None, false);
        // Not ours: another remote, a prefix of ours, no deploy file. All skipped.
        for foreign in ["hub", "evil", "nodeploy"] {
            app(
                &format!("play.com.example.{foreign}"),
                Some(format!(r#"{{"id":"com.example.{foreign}","build":9}}"#).as_bytes()),
                true,
            );
        }
        app(
            "org.example.NotPlay",
            Some(br#"{"id":"x","build":1}"#),
            false,
        );
        let found = deployed_apps(root.path()).unwrap();
        assert_eq!(
            found,
            [
                ("com.example.a".to_string(), d(Some(4), true)),
                ("com.example.b".to_string(), d(None, false)),
            ]
            .into_iter()
            .collect()
        );
        assert!(deployed_apps(&root.path().join("none")).unwrap().is_empty());
    }

    #[test]
    fn rollback_failures_are_logged_cleanly() {
        let journal = concat!(
            r#"{"time":5,"job":"job-2","id":"com.example.a","event":"rollback_failed","#,
            r#""detail":"the key record: disk\nfull"}"#,
            "\n",
            r#"{"event":"other"}"#,
            "\nnot json\n"
        );
        assert_eq!(
            rollback_failures(journal),
            vec![
                "an earlier install's records could not be rolled back: time 5, job job-2, \
                 id com.example.a: the key record: diskfull"
            ]
        );
    }
}
