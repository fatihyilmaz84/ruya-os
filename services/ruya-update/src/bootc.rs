//! The `bootc` command behind a trait, the reading of its `status --json`, and a fake for tests
//! and `--session` development.

use std::process::Command;
use std::sync::mpsc::{Receiver, Sender};
use std::sync::Mutex;

/// One deployment of `bootc status`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Deployment {
    /// Full reference, e.g. `registry:5000/ruyaos:stable`.
    pub image: String,
    /// The image's version label, "" when it has none.
    pub version: String,
    pub digest: String,
}

impl Deployment {
    /// The tag of `image`, "" without one.
    pub fn tag(&self) -> &str {
        tag_of(&self.image)
    }

    /// What the user sees: the version label, else the tag.
    pub fn label(&self) -> String {
        if self.version.is_empty() {
            self.tag().to_owned()
        } else {
            self.version.clone()
        }
    }
}

/// The tag of an image reference: after the last `:` that follows the last `/`.
pub fn tag_of(image: &str) -> &str {
    let name = image.rsplit('/').next().unwrap_or(image);
    // A digest reference (`name@sha256:...`) has no tag.
    if name.contains('@') {
        return "";
    }
    name.rsplit_once(':').map_or("", |(_, tag)| tag)
}

/// `image` with its tag replaced by `tag`.
pub fn with_tag(image: &str, tag: &str) -> String {
    let old = tag_of(image);
    let base = if old.is_empty() {
        image
    } else {
        &image[..image.len() - old.len() - 1]
    };
    format!("{base}:{tag}")
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HostStatus {
    /// The image the host tracks (`spec.image`).
    pub tracked: String,
    pub booted: Option<Deployment>,
    pub staged: Option<Deployment>,
    pub rollback: Option<Deployment>,
    pub rollback_queued: bool,
    /// What the last `upgrade --check` found for the booted image (`cachedUpdate`).
    pub cached_update: Option<Deployment>,
}

pub trait Bootc: Send + Sync {
    fn status(&self) -> Result<HostStatus, String>;
    /// `bootc upgrade --check`: asks the registry about the tracked tag.
    fn check(&self) -> Result<(), String>;
    /// `bootc upgrade`: stages the newer image of the tracked tag.
    fn upgrade(&self) -> Result<(), String>;
    /// `bootc switch <image>`: tracks and stages another image reference.
    fn switch(&self, image: &str) -> Result<(), String>;
    /// `bootc rollback`.
    fn rollback(&self) -> Result<(), String>;
}

impl Bootc for Box<dyn Bootc> {
    fn status(&self) -> Result<HostStatus, String> {
        (**self).status()
    }
    fn check(&self) -> Result<(), String> {
        (**self).check()
    }
    fn upgrade(&self) -> Result<(), String> {
        (**self).upgrade()
    }
    fn switch(&self, image: &str) -> Result<(), String> {
        (**self).switch(image)
    }
    fn rollback(&self) -> Result<(), String> {
        (**self).rollback()
    }
}

// ---- bootc status --json ------------------------------------------------------------

/// `v` is an image status: `{ "image": {"image": ref, "transport": ..}, "version", "imageDigest" }`.
fn image_status(v: &serde_json::Value) -> Option<Deployment> {
    Some(Deployment {
        image: v.get("image")?.get("image")?.as_str()?.to_owned(),
        version: v
            .get("version")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_owned(),
        digest: v
            .get("imageDigest")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_owned(),
    })
}

/// `v` is a boot entry: `{ "image": <image status>, "cachedUpdate": <image status>, .. }`.
fn deployment(v: &serde_json::Value) -> Option<Deployment> {
    image_status(v.get("image")?)
}

/// Reads the output of `bootc status --json`.
pub fn parse_status(json: &str) -> Result<HostStatus, String> {
    let root: serde_json::Value =
        serde_json::from_str(json).map_err(|e| format!("bootc status: {e}"))?;
    let status = root
        .get("status")
        .ok_or("bootc status: no `status` object")?;
    Ok(HostStatus {
        tracked: root
            .pointer("/spec/image/image")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_owned(),
        booted: status.get("booted").and_then(deployment),
        staged: status.get("staged").and_then(deployment),
        rollback: status.get("rollback").and_then(deployment),
        rollback_queued: status
            .get("rollbackQueued")
            .and_then(|b| b.as_bool())
            .unwrap_or(false),
        cached_update: status
            .get("booted")
            .and_then(|b| b.get("cachedUpdate"))
            .and_then(image_status),
    })
}

// ---- the real command ---------------------------------------------------------------

pub struct BootcCli;

impl BootcCli {
    fn run(args: &[&str]) -> Result<String, String> {
        let out = Command::new("bootc")
            .args(args)
            .output()
            .map_err(|e| format!("bootc: {e}"))?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            let stderr = String::from_utf8_lossy(&out.stderr);
            let last = stderr.lines().rev().find(|l| !l.trim().is_empty());
            Err(format!(
                "bootc {}: {}",
                args.join(" "),
                last.unwrap_or("failed")
            ))
        }
    }
}

impl Bootc for BootcCli {
    fn status(&self) -> Result<HostStatus, String> {
        parse_status(&Self::run(&["status", "--json"])?)
    }
    fn check(&self) -> Result<(), String> {
        Self::run(&["upgrade", "--check"]).map(|_| ())
    }
    fn upgrade(&self) -> Result<(), String> {
        Self::run(&["upgrade"]).map(|_| ())
    }
    fn switch(&self, image: &str) -> Result<(), String> {
        Self::run(&["switch", image]).map(|_| ())
    }
    fn rollback(&self) -> Result<(), String> {
        Self::run(&["rollback"]).map(|_| ())
    }
}

// ---- a fake host --------------------------------------------------------------------

/// A host in memory: `check` changes nothing (the cached update is set up front), `upgrade`
/// stages it, `switch` stages the other tag, `rollback` queues the previous deployment.
#[derive(Default)]
pub struct FakeBootc {
    host: Mutex<HostStatus>,
    fail: Mutex<Option<String>>,
    /// Set by `fail_next_call`: the next call with this name fails with this message.
    fail_named: Mutex<Option<(String, String)>>,
    calls: Mutex<Vec<String>>,
    /// Set by `hold_next_rollback`.
    gate: Mutex<Option<(Sender<()>, Receiver<()>)>>,
}

impl FakeBootc {
    pub fn new(host: HostStatus) -> Self {
        FakeBootc {
            host: Mutex::new(host),
            ..Default::default()
        }
    }

    /// The next command fails with this message.
    pub fn fail_next(&self, message: &str) {
        *self.fail.lock().expect("fake lock") = Some(message.to_owned());
    }

    /// The next call of this command (`"upgrade"`, `"check"`, ...) fails with this message.
    pub fn fail_next_call(&self, call: &str, message: &str) {
        *self.fail_named.lock().expect("fake lock") = Some((call.to_owned(), message.to_owned()));
    }

    /// The commands run so far, e.g. `["check", "switch x:beta"]`.
    pub fn calls(&self) -> Vec<String> {
        self.calls.lock().expect("fake lock").clone()
    }

    /// The next `rollback` stops inside the command: the first channel fires when it has
    /// started, it goes on when the second is sent to (or dropped). For tests of racing calls.
    pub fn hold_next_rollback(&self) -> (Receiver<()>, Sender<()>) {
        let (entered, started) = std::sync::mpsc::channel();
        let (release, wait) = std::sync::mpsc::channel();
        *self.gate.lock().expect("fake lock") = Some((entered, wait));
        (started, release)
    }

    pub fn set_cached_update(&self, update: Option<Deployment>) {
        self.host.lock().expect("fake lock").cached_update = update;
    }

    fn enter(&self, call: &str) -> Result<(), String> {
        self.calls.lock().expect("fake lock").push(call.to_owned());
        {
            let mut named = self.fail_named.lock().expect("fake lock");
            if named.as_ref().is_some_and(|(name, _)| name == call) {
                if let Some((_, message)) = named.take() {
                    return Err(message);
                }
            }
        }
        match self.fail.lock().expect("fake lock").take() {
            Some(message) => Err(message),
            None => Ok(()),
        }
    }
}

impl Bootc for FakeBootc {
    fn status(&self) -> Result<HostStatus, String> {
        self.enter("status")?;
        Ok(self.host.lock().expect("fake lock").clone())
    }
    fn check(&self) -> Result<(), String> {
        self.enter("check")
    }
    fn upgrade(&self) -> Result<(), String> {
        self.enter("upgrade")?;
        let mut host = self.host.lock().expect("fake lock");
        if let Some(update) = host.cached_update.take() {
            host.staged = Some(update);
        }
        Ok(())
    }
    fn switch(&self, image: &str) -> Result<(), String> {
        self.enter(&format!("switch {image}"))?;
        let mut host = self.host.lock().expect("fake lock");
        host.tracked = image.to_owned();
        host.cached_update = None;
        host.staged = Some(Deployment {
            image: image.to_owned(),
            version: String::new(),
            digest: format!("sha256:{image}"),
        });
        Ok(())
    }
    fn rollback(&self) -> Result<(), String> {
        self.enter("rollback")?;
        let gate = self.gate.lock().expect("fake lock").take();
        if let Some((entered, wait)) = gate {
            let _ = entered.send(());
            let _ = wait.recv();
        }
        self.host.lock().expect("fake lock").rollback_queued = true;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags() {
        assert_eq!(tag_of("host:5000/ruyaos:stable"), "stable");
        assert_eq!(tag_of("host:5000/ruyaos"), "");
        assert_eq!(tag_of("host/ruyaos@sha256:abc"), "");
        assert_eq!(
            with_tag("host:5000/ruyaos:stable", "beta"),
            "host:5000/ruyaos:beta"
        );
        assert_eq!(
            with_tag("host:5000/ruyaos", "beta"),
            "host:5000/ruyaos:beta"
        );
    }

    const SAMPLE: &str = r#"{
      "apiVersion": "org.containers.bootc/v1", "kind": "BootcHost",
      "metadata": {"name": "host"},
      "spec": {"image": {"image": "10.0.0.2:5000/ruyaos:stable", "transport": "registry"}, "bootOrder": "default"},
      "status": {
        "staged": null,
        "booted": {"image": {"image": {"image": "10.0.0.2:5000/ruyaos:stable", "transport": "registry"},
                             "version": "0.0.19", "timestamp": null, "imageDigest": "sha256:aaa"},
                   "cachedUpdate": {"image": {"image": "10.0.0.2:5000/ruyaos:stable", "transport": "registry"},
                             "version": "0.0.20", "timestamp": null, "imageDigest": "sha256:bbb"},
                   "incompatible": false, "pinned": false},
        "rollback": {"image": {"image": {"image": "10.0.0.2:5000/ruyaos:old", "transport": "registry"},
                             "version": null, "imageDigest": "sha256:ccc"}},
        "rollbackQueued": false, "type": "bootcHost"}
    }"#;

    #[test]
    fn reads_a_status() {
        let host = parse_status(SAMPLE).expect("parses");
        assert_eq!(host.tracked, "10.0.0.2:5000/ruyaos:stable");
        let booted = host.booted.expect("booted");
        assert_eq!(booted.label(), "0.0.19");
        assert_eq!(booted.digest, "sha256:aaa");
        assert!(host.staged.is_none());
        assert_eq!(host.cached_update.expect("update").label(), "0.0.20");
        let rollback = host.rollback.expect("rollback");
        assert_eq!(rollback.label(), "old", "no version label: the tag");
        assert!(!host.rollback_queued);
    }

    #[test]
    fn bad_json_is_an_error() {
        assert!(parse_status("not json").is_err());
        assert!(parse_status("{}").is_err());
    }
}
