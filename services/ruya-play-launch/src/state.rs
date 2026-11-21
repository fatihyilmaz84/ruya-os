//! The status file `${data}/.ruya-play/state.json` (ADR-037, 05 §6.3): what the launcher did to
//! this profile's copy of the game, for its next run and for the shell's launch splash.
//!
//! ```json
//! {"format":1,"epoch":2,"backup_of":null,"setup_done":["vcredist"],
//!  "setup_failed":null,
//!  "runner":{"component":"wine","family":"wine","version":"10.2","source":"system",
//!            "hash":"<64 hex>"}}
//! ```
//!
//! The file lives in the game's own data, so the game can write it: it is read as untrusted input
//! (at most [`MAX_STATE_BYTES`], every field type-checked). A file that cannot be read as format 1
//! counts as absent, which is the safe direction: an absent epoch is 0, so a prefix that exists
//! is rebuilt with its saves kept, and setup steps run again.

use crate::os::{AppSource, LaunchOs};
use serde_json::{json, Map, Value};

/// Where the launcher keeps its files, below `${data}`.
pub const DIR: &str = ".ruya-play";
/// The status file, below `${data}`.
pub const FILE: &str = ".ruya-play/state.json";
/// The format this launcher writes and reads.
pub const FORMAT: u64 = 1;
/// The largest status file read.
pub const MAX_STATE_BYTES: u64 = 64 * 1024;

/// The runner a launch used.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunnerInUse {
    /// The component's id in `play.json`.
    pub component: String,
    /// The runner's family.
    pub family: String,
    /// Its version.
    pub version: String,
    /// `bundled` or `system`.
    pub source: String,
    /// The runner hash (05 §7.3) when known: a system runner's `.ruya-runner-hash`.
    pub hash: Option<String>,
}

/// The last setup step that failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SetupFailure {
    /// The step's id.
    pub step: String,
    /// One sentence for the player.
    pub message: String,
}

/// The status file's content.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct State {
    /// The `run.prefix.epoch` the prefix was made for (0 when unknown).
    pub epoch: u64,
    /// Set while an epoch rebuild is under way: the saves of the prefix of this epoch are
    /// complete in `epoch-<n>-backup/`, so a rebuild cut short resumes without backing up again.
    pub backup_of: Option<u64>,
    /// The `once` setup steps done for this prefix.
    pub setup_done: Vec<String>,
    /// The last setup step that failed, until a launch passes every step.
    pub setup_failed: Option<SetupFailure>,
    /// The runner of the last launch.
    pub runner: Option<RunnerInUse>,
}

/// How a backup folder's name begins and ends: `epoch-<n>-backup`.
const BACKUP_NAME: (&str, &str) = ("epoch-", "-backup");

/// The folder (below `${data}`) that holds the saves of the prefix of `epoch`: made by a rebuild
/// from that epoch and kept until a later rebuild makes a newer one (05 §6.3).
pub fn backup_dir(epoch: u64) -> String {
    let (head, tail) = BACKUP_NAME;
    format!("{DIR}/{head}{epoch}{tail}")
}

/// The epoch of the backup folder called `name` (in [`DIR`]); none for any other name.
pub fn backup_epoch(name: &str) -> Option<u64> {
    let (head, tail) = BACKUP_NAME;
    let n = name.strip_prefix(head)?.strip_suffix(tail)?;
    if n.is_empty() || !n.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    n.parse().ok()
}

fn text(v: Option<&Value>) -> Option<String> {
    v.and_then(Value::as_str).map(str::to_string)
}

fn runner_of(v: &Value) -> Option<RunnerInUse> {
    let o = v.as_object()?;
    Some(RunnerInUse {
        component: text(o.get("component"))?,
        family: text(o.get("family"))?,
        version: text(o.get("version"))?,
        source: text(o.get("source"))?,
        hash: text(o.get("hash")),
    })
}

fn failure_of(v: &Value) -> Option<SetupFailure> {
    let o = v.as_object()?;
    Some(SetupFailure {
        step: text(o.get("step"))?,
        message: text(o.get("message"))?,
    })
}

impl State {
    /// Parse the file; `None` when it is not a format 1 status file.
    pub fn parse(bytes: &[u8]) -> Option<State> {
        let v: Value = serde_json::from_slice(bytes).ok()?;
        let o: &Map<String, Value> = v.as_object()?;
        if o.get("format").and_then(Value::as_u64) != Some(FORMAT) {
            return None;
        }
        let setup_done = match o.get("setup_done") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(a)) => a
                .iter()
                .map(|s| s.as_str().map(str::to_string))
                .collect::<Option<Vec<_>>>()?,
            Some(_) => return None,
        };
        Some(State {
            epoch: o.get("epoch").and_then(Value::as_u64)?,
            backup_of: o.get("backup_of").and_then(Value::as_u64),
            setup_done,
            setup_failed: o.get("setup_failed").and_then(failure_of),
            runner: o.get("runner").and_then(runner_of),
        })
    }

    /// The file's bytes (one JSON object and a newline).
    pub fn to_bytes(&self) -> Vec<u8> {
        let runner = self.runner.as_ref().map(|r| {
            json!({"component": r.component, "family": r.family, "version": r.version,
                   "source": r.source, "hash": r.hash})
        });
        let failed = self
            .setup_failed
            .as_ref()
            .map(|f| json!({"step": f.step, "message": f.message}));
        let v = json!({
            "format": FORMAT,
            "epoch": self.epoch,
            "backup_of": self.backup_of,
            "setup_done": self.setup_done,
            "setup_failed": failed,
            "runner": runner,
        });
        let mut out = v.to_string().into_bytes();
        out.push(b'\n');
        out
    }

    /// Read the status file below `data`; the default when it is absent, too big or not format 1
    /// (logged).
    pub fn read(os: &dyn LaunchOs, data: &str) -> State {
        if os.kind(&crate::os::join(data, FILE)).is_none() {
            return State::default();
        }
        let src = AppSource::new(os, data);
        match ruya_play_format::read_within(&src, FILE, MAX_STATE_BYTES) {
            Ok(Some(b)) => State::parse(&b).unwrap_or_else(|| {
                os.log("the status file is not a format 1 status file; starting from none");
                State::default()
            }),
            Ok(None) => {
                os.log("the status file is too big; starting from none");
                State::default()
            }
            Err(p) => {
                os.log(&format!(
                    "the status file cannot be read ({}); starting from none",
                    p.message
                ));
                State::default()
            }
        }
    }

    /// Write the status file below `data` atomically.
    pub fn write(&self, os: &mut dyn LaunchOs, data: &str) -> std::io::Result<()> {
        os.write_atomic(data, FILE, &self.to_bytes())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_backup_folder_name_gives_its_epoch_back() {
        for n in [0, 1, 7, u64::MAX] {
            let dir = backup_dir(n);
            let name = dir.strip_prefix(&format!("{DIR}/")).expect("in DIR");
            assert_eq!(backup_epoch(name), Some(n));
        }
        for other in [
            "state.json",
            "epoch--backup",
            "epoch-+1-backup",
            "epoch-1-backup.tmp",
            "epoch-x-backup",
            "epoch-99999999999999999999-backup",
        ] {
            assert_eq!(backup_epoch(other), None, "{other}");
        }
    }

    #[test]
    fn round_trip() {
        let s = State {
            epoch: 3,
            backup_of: Some(2),
            setup_done: vec!["vcredist".into()],
            setup_failed: Some(SetupFailure {
                step: "dx".into(),
                message: "It failed.".into(),
            }),
            runner: Some(RunnerInUse {
                component: "wine".into(),
                family: "wine".into(),
                version: "10.2".into(),
                source: "system".into(),
                hash: None,
            }),
        };
        assert_eq!(State::parse(&s.to_bytes()), Some(s));
        assert_eq!(
            State::parse(&State::default().to_bytes()),
            Some(State::default())
        );
    }

    #[test]
    fn a_foreign_file_is_none() {
        for bad in [
            &b"not json"[..],
            br#"[]"#,
            br#"{"format":2,"epoch":1}"#,
            br#"{"format":1}"#,
            br#"{"format":1,"epoch":-1}"#,
            br#"{"format":1,"epoch":1,"setup_done":[1]}"#,
            br#"{"format":1,"epoch":1,"setup_done":"x"}"#,
        ] {
            assert_eq!(State::parse(bad), None, "{}", String::from_utf8_lossy(bad));
        }
    }
}
