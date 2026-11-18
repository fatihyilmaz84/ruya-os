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
//!   until it is uninstalled (a first sight would let any key take it over).
//!
//! The service reconciles before it takes its bus name, so no install runs against unreconciled
//! records.

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
}

/// The reconcile steps for the committed apps `deployed`, the recorded builds `recorded` and the
/// ids with a key record `trusted` (all ids lower case), in id order.
pub fn plan(
    deployed: &BTreeMap<String, Deployed>,
    recorded: &BTreeMap<String, u64>,
    trusted: &BTreeSet<String>,
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
                if recorded.get(id) != Some(&build) {
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

/// The `play.*` apps of the Flatpak installation at `installation` (`/var/lib/flatpak`): every
/// `app/play.<id>/current/active/files/` with what its `play.json` and `play.sig` say. An app
/// folder that is not `play.` plus a plain id is skipped. A missing `app/` is an empty list.
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
        if id.is_empty() || id.contains(['/', '\\']) || id.chars().any(char::is_control) {
            continue;
        }
        let files = entry.path().join("current").join("active").join("files");
        let mut bytes = Vec::new();
        let read = std::fs::File::open(files.join("play.json")).and_then(|f| {
            f.take(MAX_PLAY_JSON_BYTES + 1)
                .read_to_end(&mut bytes)
                .map(|_| ())
        });
        let build = match read {
            Ok(()) if bytes.len() as u64 <= MAX_PLAY_JSON_BYTES => build_in(&bytes, id),
            _ => None,
        };
        let signed = std::fs::symlink_metadata(files.join("play.sig")).is_ok();
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

    #[test]
    fn the_rules() {
        let deployed: BTreeMap<String, Deployed> = [
            ("same".to_string(), d(Some(3), true)),
            ("newer".to_string(), d(Some(5), true)),
            ("unrecorded".to_string(), d(Some(2), false)),
            ("unreadable".to_string(), d(None, true)),
            ("keyless".to_string(), d(Some(1), true)),
        ]
        .into_iter()
        .collect();
        let recorded: BTreeMap<String, u64> = [
            ("same".to_string(), 3),
            ("newer".to_string(), 4),
            ("gone".to_string(), 7),
            ("keyless".to_string(), 1),
        ]
        .into_iter()
        .collect();
        let trusted: BTreeSet<String> = ["same", "newer", "gone", "unreadable"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let actions = plan(&deployed, &recorded, &trusted);
        assert_eq!(
            actions,
            vec![
                Action::ForgetBuild { id: "gone".into() },
                Action::Hold {
                    id: "keyless".into(),
                    reason: "it is signed but its key record is missing".into()
                },
                Action::RecordBuild {
                    id: "newer".into(),
                    build: 5
                },
                Action::Hold {
                    id: "unreadable".into(),
                    reason: "its play.json cannot be read".into()
                },
                Action::RecordBuild {
                    id: "unrecorded".into(),
                    build: 2
                },
            ]
        );
        // Everything agrees: nothing to do.
        let one: BTreeMap<String, Deployed> = [("same".to_string(), d(Some(3), true))]
            .into_iter()
            .collect();
        let rec: BTreeMap<String, u64> = [("same".to_string(), 3)].into_iter().collect();
        assert!(plan(&one, &rec, &trusted).is_empty());
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
            let files = root
                .path()
                .join("app")
                .join(name)
                .join("current/active/files");
            std::fs::create_dir_all(&files).unwrap();
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
            r#"{"time":5,"job":"job-2","id":"com.example.a","event":"rollback_failed","detail":"the key record: disk\nfull"}"#,
            "\n",
            r#"{"event":"other"}"#,
            "\nnot json\n"
        );
        assert_eq!(
            rollback_failures(journal),
            vec![
                "an earlier install's records could not be rolled back: time 5, job job-2, id com.example.a: the key record: diskfull"
            ]
        );
    }
}
