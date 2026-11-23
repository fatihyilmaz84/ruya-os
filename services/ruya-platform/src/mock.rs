//! The developer mock's world (RUY-158): `ruya-platform-mock` serves the service's own objects
//! (`dbus.rs`: Lifecycle and Manage over this crate's core) on the session bus, and only who a
//! caller is comes from a scenario file instead of a sandbox. [`ScenarioProcfs`] and
//! [`ScenarioUsers`] implement the recipe's reads (`identity.rs`), so every rule (statuses, the
//! buckets, the eight connections, SaveDone's states, the permissions) is the service's code, run
//! unchanged. A process says which scenario app it is with `RUYA_MOCK_APP=<name>` in its
//! environment (none: the scenario's `default_app`); a name the scenario lacks is an unsandboxed
//! caller (`not-an-app`). Every caller is the scenario's `profile` (the session bus has one user).
//! [`MockIface`] is the control interface, `api/dbus/org.ruyaos.Platform1Mock.xml`.

use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::sync::Arc;
use std::time::Instant;

use ruya_flatpak::scope::{instance_scope, valid_instance_id};
use ruya_flatpak::valid_app_id;
use ruya_ids::{user_of, valid_profile_id};
use serde::{Deserialize, Serialize};
use zbus::{interface, Connection};

use std::sync::Mutex;
use zbus::message::Header;
use zbus::object_server::SignalEmitter;

use crate::dbus::{self as door_dbus, notify_lifecycle, Checks, ManageIface, Shared};
use crate::door::arg;
use crate::identity::{FileError, Procfs, Reply, Users};
use crate::limits::{MAX_APP_ID, MAX_PROFILE_ID};
use crate::registry::{Registry, RegistryError};
use crate::store::Store;
use crate::{Platform, Status};
use ruya_platform_identify::serve::{files_of, InMemory, Kernel};

pub const MOCK_BUS_NAME: &str = "org.ruyaos.Platform1Mock";
pub const MOCK_PATH: &str = "/org/ruyaos/Platform1Mock";
/// The environment variable that names a process's scenario app.
pub const APP_ENV: &str = "RUYA_MOCK_APP";
/// The Lifecycle methods `Fault` can make answer wrongly.
pub const FAULTABLE: &[&str] = &["Register", "SaveDone"];
/// The longest status `Fault` takes (every real one is far shorter).
const MAX_STATUS: usize = 32;

/// `arg` for an argument where "" has a meaning (the default app, no fault).
fn arg_or_empty(s: &str, max: usize) -> Result<&str, Status> {
    if s.is_empty() {
        Ok(s)
    } else {
        arg(s, max)
    }
}
/// The largest `/proc/<pid>/environ` read.
pub const MAX_ENVIRON: u64 = 256 * 1024;

/// One app of the scenario: what its `.flatpak-info` would name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ScenarioApp {
    pub app_id: String,
    pub instance: String,
}

/// The scenario file (JSON): the profiles, which is active, whose user every caller is, and the
/// apps a process can be.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Scenario {
    /// The profile of every caller (all of them are the developer's user).
    pub profile: String,
    /// Every profile that exists (`profile` among them).
    pub profiles: BTreeSet<String>,
    /// The signed-in profile at start; `profile` when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active: Option<String>,
    /// The app of a process without `RUYA_MOCK_APP`; absent: such a process is unsandboxed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_app: Option<String>,
    pub apps: BTreeMap<String, ScenarioApp>,
}

impl Scenario {
    /// Reads and checks a scenario; the error is a sentence for the developer.
    pub fn parse(text: &str) -> Result<Scenario, String> {
        let s: Scenario = serde_json::from_str(text).map_err(|e| format!("not a scenario: {e}"))?;
        for p in &s.profiles {
            if !valid_profile_id(p) {
                return Err(format!("profile {p:?} is not a profile id"));
            }
        }
        if !s.profiles.contains(&s.profile) {
            return Err(format!("profile {:?} is not in profiles", s.profile));
        }
        if !s.profiles.contains(s.active()) {
            return Err(format!("active {:?} is not in profiles", s.active()));
        }
        for (name, app) in &s.apps {
            if !valid_app_id(&app.app_id) {
                return Err(format!("app {name:?}: {:?} is not an app id", app.app_id));
            }
            if !valid_instance_id(&app.instance) {
                return Err(format!(
                    "app {name:?}: instance {:?} is not an instance id (digits)",
                    app.instance
                ));
            }
        }
        if let Some(d) = &s.default_app {
            if !s.apps.contains_key(d) {
                return Err(format!("default_app {d:?} is not in apps"));
            }
        }
        Ok(s)
    }

    pub fn active(&self) -> &str {
        self.active.as_deref().unwrap_or(&self.profile)
    }

    /// The app `name` names ("" the default app).
    pub fn app(&self, name: &str) -> Option<&ScenarioApp> {
        let name = if name.is_empty() {
            self.default_app.as_deref()?
        } else {
            name
        };
        self.apps.get(name)
    }

    /// The instance scope of the app `name` ("" the default app).
    pub fn scope_of(&self, name: &str) -> Option<String> {
        let app = self.app(name)?;
        instance_scope(&app.app_id, &app.instance)
    }
}

/// What the mock reads of a real process (the caller's): its pidfd, environment and uid.
pub trait Processes: Send {
    /// As [`Procfs::pidfd_pid`].
    fn pidfd_pid(&self, pidfd: i32) -> Option<i32>;
    /// `/proc/<pid>/environ`, at most [`MAX_ENVIRON`] bytes.
    fn environ(&self, pid: u32) -> io::Result<Vec<u8>>;
    /// The uid that owns the process.
    fn uid(&self, pid: u32) -> io::Result<u32>;
}

/// The value of `key` in an environ block (`KEY=value` entries, each ended by a NUL).
pub fn env_value<'a>(environ: &'a [u8], key: &str) -> Option<&'a str> {
    environ
        .split(|b| *b == 0)
        .filter_map(|entry| std::str::from_utf8(entry).ok())
        .find_map(|entry| entry.strip_prefix(key)?.strip_prefix('='))
}

/// The recipe's reads as the scenario says: a process that is a scenario app shows that app's
/// `.flatpak-info` and sits in its instance's scope under its own uid's user manager; any other
/// process has no `.flatpak-info` (an unsandboxed caller). The pidfd is the real one.
pub struct ScenarioProcfs {
    scenario: Arc<Scenario>,
    processes: Box<dyn Processes>,
}

impl ScenarioProcfs {
    pub fn new(scenario: Arc<Scenario>, processes: Box<dyn Processes>) -> ScenarioProcfs {
        ScenarioProcfs {
            scenario,
            processes,
        }
    }

    /// The scenario app the process `pid` is, `None` for an unsandboxed one.
    fn app_of(&self, pid: u32) -> Option<&ScenarioApp> {
        let environ = self.processes.environ(pid).ok()?;
        match env_value(&environ, APP_ENV) {
            Some(name) => {
                let app = self.scenario.apps.get(name);
                if app.is_none() {
                    eprintln!(
                        "ruya-platform-mock: pid {pid}: {APP_ENV}={name} is no app of the scenario: not an app"
                    );
                }
                app
            }
            None => self.scenario.app(""),
        }
    }
}

impl Procfs for ScenarioProcfs {
    fn pidfd_pid(&self, pidfd: i32) -> Option<i32> {
        self.processes.pidfd_pid(pidfd)
    }

    /// The identity helper's own rules (`serve::files_of`) on the scenario's kernel.
    fn caller_files(&self, pidfd: i32, uid: u32) -> io::Result<Reply> {
        Ok(files_of(self, pidfd, uid))
    }
}

/// What the helper's rules see of a process: a scenario app's `.flatpak-info` (owned by the
/// process's uid, so another uid's request is `not-owned`) and its instance's scope under that
/// uid's user manager; any other process has no `.flatpak-info`. The pidfd is the real one.
impl Kernel for ScenarioProcfs {
    type File = InMemory;

    fn pidfd_pid(&self, fd: i32) -> Option<i32> {
        self.processes.pidfd_pid(fd)
    }

    fn open_info(&self, pid: u32) -> Result<InMemory, FileError> {
        let app = self.app_of(pid).ok_or(FileError::Missing)?;
        let owner = self.processes.uid(pid).map_err(|_| FileError::Failed)?;
        let info = format!(
            "[Application]\nname={}\n\n[Instance]\ninstance-id={}\n",
            app.app_id, app.instance
        );
        Ok(InMemory::new(owner, info.into_bytes()))
    }

    fn open_cgroup(&self, pid: u32) -> Result<InMemory, FileError> {
        let app = self.app_of(pid).ok_or(FileError::Missing)?;
        let owner = self.processes.uid(pid).map_err(|_| FileError::Failed)?;
        let scope = instance_scope(&app.app_id, &app.instance).ok_or(FileError::Failed)?;
        let cgroup =
            format!("0::/user.slice/user-{owner}.slice/user@{owner}.service/app.slice/{scope}\n");
        Ok(InMemory::new(owner, cgroup.into_bytes()))
    }
}

/// Every uid is the scenario profile's user (on the session bus every caller is the developer).
pub struct ScenarioUsers {
    pub profile: String,
}

impl Users for ScenarioUsers {
    fn name_of(&self, _uid: u32) -> Option<String> {
        Some(user_of(&self.profile))
    }
}

/// The kernel's `/proc` for the mock: the pidfd as the service reads it, the caller's environment
/// and owner.
#[cfg(target_os = "linux")]
#[derive(Debug, Default)]
pub struct LinuxProcesses;

#[cfg(target_os = "linux")]
impl Processes for LinuxProcesses {
    fn pidfd_pid(&self, pidfd: i32) -> Option<i32> {
        ruya_platform_identify::fdinfo::own_pidfd_pid(pidfd)
    }

    fn environ(&self, pid: u32) -> io::Result<Vec<u8>> {
        ruya_fs::Dir::open(std::path::Path::new(&format!("/proc/{pid}")))?
            .read(std::path::Path::new("environ"), MAX_ENVIRON)
    }

    fn uid(&self, pid: u32) -> io::Result<u32> {
        use std::os::unix::fs::MetadataExt;
        Ok(std::fs::metadata(format!("/proc/{pid}"))?.uid())
    }
}

/// The mock's core: the service's [`Platform`] with every served capability, the scenario's
/// identities, permissions in `store`, and the scenario's profiles (Profiles1 is not followed).
pub fn core(
    scenario: Arc<Scenario>,
    processes: Box<dyn Processes>,
    store: Store,
) -> Result<Shared, RegistryError> {
    let users = ScenarioUsers {
        profile: scenario.profile.clone(),
    };
    let procfs = ScenarioProcfs::new(scenario.clone(), processes);
    let mut door = Platform::new(
        Box::new(procfs),
        Box::new(users),
        store,
        Registry::served()?,
    );
    door.follow_profiles(scenario.profiles.clone(), scenario.active(), Instant::now());
    Ok(Arc::new(Mutex::new(door)))
}

/// Statuses that replace a Lifecycle method's real answer, by member name (`Register`,
/// `SaveDone`), set by `Fault`, so a conformance run can be shown to catch a wrong answer. Only
/// the mock has them: the service's own `LifecycleIface` carries nothing of the kind.
pub type Faults = Arc<Mutex<BTreeMap<String, String>>>;

/// The mock's Lifecycle object: the service's own interface (`dbus::lifecycle_interface!`, the
/// same method bodies and signals), each answer passed through the mock's faults. The contract
/// test holds it to `Platform1.xml` like the service's object.
pub struct MockLifecycle {
    core: Shared,
    faults: Faults,
}

impl MockLifecycle {
    pub fn new(core: Shared, faults: Faults) -> MockLifecycle {
        MockLifecycle { core, faults }
    }

    /// The reply of `member`: its fault if one is set, else `status`.
    fn reply(&self, member: &str, status: Status) -> String {
        let fault = self.faults.lock().ok().and_then(|f| f.get(member).cloned());
        fault.unwrap_or_else(|| status.as_str().to_owned())
    }
}

door_dbus::lifecycle_interface!(
    // Its signals are declared for the introspection only: they are sent through the service's
    // object (`dbus::notify_lifecycle`).
    #[allow(dead_code)]
    MockLifecycle
);

/// Everything the mock serves: Lifecycle (the service's bodies, with the faults the control
/// interface sets) and the service's own Manage (unchecked, as its `--session`) at
/// `/org/ruyaos/Platform1`, and the control interface at [`MOCK_PATH`]. One constructor, so the
/// contract test checks exactly what the binary serves.
pub struct Objects {
    pub lifecycle: MockLifecycle,
    pub manage: ManageIface,
    pub control: MockIface,
}

impl Objects {
    pub fn new(core: Shared, scenario: Arc<Scenario>) -> Objects {
        let faults = Faults::default();
        let checks = Checks {
            enforce: false,
            shell_uid: None,
        };
        Objects {
            lifecycle: MockLifecycle::new(core.clone(), faults.clone()),
            manage: ManageIface::new(core.clone(), checks),
            control: MockIface::new(core, scenario, faults),
        }
    }
}

/// `org.ruyaos.Platform1Mock` (module doc).
pub struct MockIface {
    core: Shared,
    scenario: Arc<Scenario>,
    faults: Faults,
}

impl MockIface {
    pub fn new(core: Shared, scenario: Arc<Scenario>, faults: Faults) -> MockIface {
        MockIface {
            core,
            scenario,
            faults,
        }
    }

    fn switch(&self, profile_id: &str) -> Status {
        let Ok(profile) = arg(profile_id, MAX_PROFILE_ID) else {
            return Status::InvalidArgument;
        };
        if !self.scenario.profiles.contains(profile) {
            return Status::InvalidArgument;
        }
        let Ok(mut door) = self.core.lock() else {
            return Status::Failed;
        };
        door.follow_profiles(self.scenario.profiles.clone(), profile, Instant::now());
        eprintln!("ruya-platform-mock: {profile} is the active profile");
        Status::Ok
    }

    fn set_fault(&self, member: &str, status: &str) -> Status {
        let (Ok(member), Ok(status)) = (arg(member, MAX_STATUS), arg_or_empty(status, MAX_STATUS))
        else {
            return Status::InvalidArgument;
        };
        if !FAULTABLE.contains(&member) {
            return Status::InvalidArgument;
        }
        let Ok(mut faults) = self.faults.lock() else {
            return Status::Failed;
        };
        if status.is_empty() {
            faults.remove(member);
            eprintln!("ruya-platform-mock: {member} answers for real again");
        } else {
            faults.insert(member.to_owned(), status.to_owned());
            eprintln!("ruya-platform-mock: {member} answers {status:?} (a fault)");
        }
        Status::Ok
    }
}

#[interface(name = "org.ruyaos.Platform1Mock")]
impl MockIface {
    async fn fire(
        &self,
        app: &str,
        event: &str,
        value_ms: u64,
        #[zbus(connection)] conn: &Connection,
    ) -> String {
        let scope = arg_or_empty(app, MAX_APP_ID)
            .ok()
            .and_then(|a| self.scenario.scope_of(a));
        let Some(scope) = scope else {
            return Status::InvalidArgument.as_str().to_owned();
        };
        notify_lifecycle(
            &self.core,
            conn,
            &self.scenario.profile,
            &scope,
            event,
            value_ms,
        )
        .await
        .as_str()
        .to_owned()
    }

    async fn switch_profile(&self, profile_id: &str) -> String {
        self.switch(profile_id).as_str().to_owned()
    }

    async fn fault(&self, member: &str, status: &str) -> String {
        self.set_fault(member, status).as_str().to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::{identify, Caller, Identity, NotAnApp};
    use std::collections::HashMap;

    const SCENARIO: &str = r#"{
        "profile": "p1",
        "profiles": ["p1", "p2"],
        "default_app": "demo",
        "apps": {
            "demo": {"app_id": "org.ruyaos.samples.PlatformDemo", "instance": "1"},
            "other": {"app_id": "org.example.Other", "instance": "22"}
        }
    }"#;

    /// pid -> (environ, uid); every pidfd names the pid `fd - 100`.
    #[derive(Default)]
    struct FakeProcesses(HashMap<u32, (Vec<u8>, u32)>);

    impl Processes for FakeProcesses {
        fn pidfd_pid(&self, pidfd: i32) -> Option<i32> {
            Some(pidfd - 100)
        }
        fn environ(&self, pid: u32) -> io::Result<Vec<u8>> {
            self.0
                .get(&pid)
                .map(|p| p.0.clone())
                .ok_or_else(|| io::ErrorKind::NotFound.into())
        }
        fn uid(&self, pid: u32) -> io::Result<u32> {
            self.0
                .get(&pid)
                .map(|p| p.1)
                .ok_or_else(|| io::ErrorKind::NotFound.into())
        }
    }

    fn world() -> (ScenarioProcfs, ScenarioUsers) {
        let scenario = Arc::new(Scenario::parse(SCENARIO).expect("valid"));
        let mut p = FakeProcesses::default();
        p.0.insert(10, (b"HOME=/home/dev\0PATH=/usr/bin\0".to_vec(), 1000));
        p.0.insert(11, (b"RUYA_MOCK_APP=other\0".to_vec(), 1000));
        p.0.insert(12, (b"RUYA_MOCK_APP=missing\0".to_vec(), 1000));
        p.0.insert(13, (b"XRUYA_MOCK_APP=other\0".to_vec(), 1000));
        let users = ScenarioUsers {
            profile: scenario.profile.clone(),
        };
        (ScenarioProcfs::new(scenario, Box::new(p)), users)
    }

    fn who(pid: u32) -> Result<Identity, NotAnApp> {
        let (procfs, users) = world();
        let caller = Caller {
            name: ":1.7",
            uid: Some(1000),
            pid: Some(pid),
            pidfd: Some(100 + pid as i32),
        };
        identify(&procfs, &users, &caller, |p| p == "p1" || p == "p2")
    }

    #[test]
    fn a_process_without_the_variable_is_the_default_app() {
        assert_eq!(
            who(10),
            Ok(Identity {
                app_id: "org.ruyaos.samples.PlatformDemo".into(),
                instance_id: "1".into(),
                scope: "app-flatpak-org.ruyaos.samples.PlatformDemo-1.scope".into(),
                uid: 1000,
                profile: "p1".into(),
            })
        );
    }

    #[test]
    fn the_variable_picks_the_app() {
        let id = who(11).expect("an app");
        assert_eq!(
            (id.app_id.as_str(), id.instance_id.as_str()),
            ("org.example.Other", "22")
        );
        // Only the exact variable name counts.
        assert_eq!(
            who(13).expect("an app").app_id,
            "org.ruyaos.samples.PlatformDemo"
        );
    }

    #[test]
    fn an_app_the_scenario_lacks_is_an_unsandboxed_caller() {
        assert_eq!(who(12), Err(NotAnApp::NoFlatpakInfo));
        // A process whose environment cannot be read is not an app either.
        assert_eq!(who(14), Err(NotAnApp::NoFlatpakInfo));
    }

    #[test]
    fn without_a_default_app_a_plain_process_is_not_an_app() {
        let mut s = Scenario::parse(SCENARIO).expect("valid");
        s.default_app = None;
        let mut p = FakeProcesses::default();
        p.0.insert(10, (Vec::new(), 1000));
        let procfs = ScenarioProcfs::new(Arc::new(s), Box::new(p));
        let Ok(Reply::Files(files)) = procfs.caller_files(110, 1000) else {
            panic!("the files of pid 10");
        };
        assert_eq!(files.info, Err(FileError::Missing));
    }

    #[test]
    fn another_uids_request_is_not_owned() {
        let (procfs, _) = world();
        let Ok(Reply::Files(files)) = procfs.caller_files(110, 1001) else {
            panic!("the files of pid 10");
        };
        assert_eq!(files.info, Err(FileError::NotOwned));
    }

    #[test]
    fn the_pidfd_is_the_real_check() {
        let (procfs, users) = world();
        // A pidfd that names another process: the recipe refuses it, scenario or not.
        let caller = Caller {
            name: ":1.7",
            uid: Some(1000),
            pid: Some(10),
            pidfd: Some(111),
        };
        assert_eq!(
            identify(&procfs, &users, &caller, |_| true),
            Err(NotAnApp::ProcessGone)
        );
    }

    #[test]
    fn every_caller_is_the_scenario_profile() {
        let users = ScenarioUsers {
            profile: "p2".into(),
        };
        assert_eq!(users.name_of(1000).as_deref(), Some("ruya-p2"));
        assert_eq!(users.name_of(0).as_deref(), Some("ruya-p2"));
    }

    #[test]
    fn environ_values() {
        let env = b"A=1\0RUYA_MOCK_APP=x\0B=\0";
        assert_eq!(env_value(env, "RUYA_MOCK_APP"), Some("x"));
        assert_eq!(env_value(env, "B"), Some(""));
        assert_eq!(env_value(env, "C"), None);
        assert_eq!(env_value(b"", "A"), None);
    }

    #[test]
    fn a_bad_scenario_is_refused_with_its_reason() {
        let base: serde_json::Value = serde_json::from_str(SCENARIO).expect("json");
        let with = |key: &str, value: serde_json::Value| {
            let mut v = base.clone();
            v[key] = value;
            Scenario::parse(&v.to_string()).expect_err("refused")
        };
        assert!(with("profile", "p9".into()).contains("not in profiles"));
        assert!(with("active", "p9".into()).contains("not in profiles"));
        assert!(with("default_app", "nope".into()).contains("not in apps"));
        assert!(with("profiles", serde_json::json!(["p1", "bad id"])).contains("not a profile id"));
        assert!(with(
            "apps",
            serde_json::json!({"a": {"app_id": "Racer", "instance": "1"}})
        )
        .contains("not an app id"));
        assert!(with(
            "apps",
            serde_json::json!({"a": {"app_id": "org.a.B", "instance": "x"}})
        )
        .contains("not an instance id"));
        assert!(with("extra", 1.into()).contains("not a scenario"));
    }

    #[test]
    fn scopes_and_the_default_app() {
        let s = Scenario::parse(SCENARIO).expect("valid");
        assert_eq!(s.active(), "p1");
        assert_eq!(
            s.scope_of("").as_deref(),
            Some("app-flatpak-org.ruyaos.samples.PlatformDemo-1.scope")
        );
        assert_eq!(
            s.scope_of("other").as_deref(),
            Some("app-flatpak-org.example.Other-22.scope")
        );
        assert_eq!(s.scope_of("nope"), None);
    }

    fn mock(dir: &tempfile::TempDir) -> MockIface {
        let scenario = Arc::new(Scenario::parse(SCENARIO).expect("valid"));
        let store = Store::open(&dir.path().join("platform")).expect("opens");
        let core =
            core(scenario.clone(), Box::new(FakeProcesses::default()), store).expect("registers");
        MockIface::new(core, scenario, Faults::default())
    }

    #[test]
    fn switch_profile_takes_only_a_scenario_profile() {
        let dir = tempfile::tempdir().expect("temp dir");
        let m = mock(&dir);
        assert_eq!(m.switch("p2"), Status::Ok);
        assert_eq!(m.switch("p3"), Status::InvalidArgument);
        assert_eq!(m.switch("p1\n"), Status::InvalidArgument);
    }

    #[test]
    fn faults_are_set_and_cleared_for_lifecycle_methods_only() {
        let dir = tempfile::tempdir().expect("temp dir");
        let m = mock(&dir);
        assert_eq!(m.set_fault("Register", "not-allowed"), Status::Ok);
        assert_eq!(
            m.faults
                .lock()
                .expect("lock")
                .get("Register")
                .map(String::as_str),
            Some("not-allowed")
        );
        assert_eq!(m.set_fault("Register", ""), Status::Ok);
        assert!(m.faults.lock().expect("lock").is_empty());
        assert_eq!(m.set_fault("Stopping", "ok"), Status::InvalidArgument);
        assert_eq!(m.set_fault("SaveDone", "bad\u{7}"), Status::InvalidArgument);
    }

    #[test]
    fn a_fault_replaces_the_served_lifecycle_answer() {
        let dir = tempfile::tempdir().expect("temp dir");
        let m = mock(&dir);
        let lifecycle = MockLifecycle::new(m.core.clone(), m.faults.clone());
        assert_eq!(lifecycle.reply("Register", Status::Ok), "ok");
        assert_eq!(m.set_fault("Register", "rate-limited"), Status::Ok);
        assert_eq!(lifecycle.reply("Register", Status::Ok), "rate-limited");
        assert_eq!(lifecycle.reply("SaveDone", Status::Ok), "ok");
    }
}
