//! The conformance cases of `org.ruyaos.Platform1` (RUY-158; the abuse list of
//! docs/developers/api-surface.md and the lead-44 list). Each case gets fresh apps of the
//! scenario (`Ctx::app`), so the buckets and registrations of one case never reach another, and
//! names the public elements it covers: `coverage` fails for a public element no case covers.
//! Absence ("no signal reached another app") is shown with a fence: a later signal to the same
//! connection arrives first, and the bus keeps one sender's messages in order.

use std::collections::BTreeSet;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use ruya_flatpak::scope::instance_scope;
use ruya_platform::dbus::{BUS_NAME, OBJECT_PATH};
use ruya_platform::lifecycle::{KEY, MAX_NAMES};
use ruya_platform::limits::CALLER_RATE;
use ruya_platform::mock::{Scenario, ScenarioApp, MOCK_BUS_NAME, MOCK_PATH};
use ruya_platform::Status;
use zbus::Connection;

use crate::docs::Docs;
use crate::peer::{Peer, PATIENCE};

const MANAGE: &str = "org.ruyaos.Platform1.Manage";
const MOCK: &str = "org.ruyaos.Platform1Mock";
const REGISTER: &str = "org.ruyaos.Platform1.Lifecycle.Register";
const SAVE_DONE: &str = "org.ruyaos.Platform1.Lifecycle.SaveDone";
const BACKGROUND: &str = "org.ruyaos.Platform1.Lifecycle.Background";
const RESUME: &str = "org.ruyaos.Platform1.Lifecycle.Resume";
const STOPPING: &str = "org.ruyaos.Platform1.Lifecycle.Stopping";
/// The element whose documented statuses a lifecycle event's answer is checked against (the
/// mock's `Fire` answers exactly as NotifyLifecycle).
const NOTIFY: &str = "org.ruyaos.Platform1.Manage.NotifyLifecycle";
/// The scenario's profiles: every app is the first one's; the second is for "not active".
const PROFILE: &str = "p1";
const OTHER_PROFILE: &str = "p2";
/// How many apps the scenario has (more than all cases take together).
const APPS: usize = 64;
/// A process name the scenario lacks: an unsandboxed caller.
const UNSANDBOXED: &str = "unsandboxed";

/// The scenario app number `n`.
fn app_name(n: usize) -> String {
    format!("app{n}")
}

fn app_of(n: usize) -> ScenarioApp {
    ScenarioApp {
        app_id: format!("org.ruyaos.conformance.App{n}"),
        instance: n.to_string(),
    }
}

/// The scenario `run` needs the mock to load (`ruya-platform-conformance scenario`).
pub fn scenario() -> Scenario {
    Scenario {
        profile: PROFILE.into(),
        profiles: [PROFILE, OTHER_PROFILE].map(str::to_owned).into(),
        active: None,
        default_app: None,
        apps: (1..=APPS).map(|n| (app_name(n), app_of(n))).collect(),
    }
}

pub struct Case {
    pub name: &'static str,
    /// The public elements this case calls or receives ("<interface>.<member>").
    pub covers: &'static [&'static str],
    pub run: fn(&mut Ctx) -> Result<(), String>,
}

/// The public elements of `org.ruyaos.Platform1.xml` in an apis.json (lint-dev-docs.ps1) that no
/// case covers, and covered elements that are not public there; an error if it is no apis.json.
pub fn coverage(apis_json: &str) -> Result<Vec<String>, String> {
    let entries: Vec<serde_json::Value> =
        serde_json::from_str(apis_json).map_err(|e| format!("not an apis.json: {e}"))?;
    let mut public = BTreeSet::new();
    for e in &entries {
        let file = e["file"].as_str().unwrap_or("");
        if !file.ends_with("/org.ruyaos.Platform1.xml") {
            continue;
        }
        let (Some(i), Some(m)) = (e["interface"].as_str(), e["member"].as_str()) else {
            return Err(format!(
                "an apis.json entry without interface or member: {e}"
            ));
        };
        public.insert(format!("{i}.{m}"));
    }
    let covered: BTreeSet<String> = CASES
        .iter()
        .flat_map(|c| c.covers.iter().map(|s| (*s).to_owned()))
        .collect();
    let mut problems: Vec<String> = public
        .difference(&covered)
        .map(|e| format!("no conformance case for {e}"))
        .collect();
    problems.extend(
        covered
            .difference(&public)
            .map(|e| format!("a case covers {e}, which is not a public element")),
    );
    Ok(problems)
}

/// One case's world: the bus, the contract's documented statuses, the next unused app.
pub struct Ctx {
    conn: Connection,
    docs: Docs,
    next_app: usize,
}

/// One app of the scenario, run as a peer process.
pub struct App {
    pub peer: Peer,
    pub name: String,
    pub app_id: String,
    pub scope: String,
}

impl Ctx {
    /// The session bus, with a mock on it; `Err` (the run is NOT RUN) without one.
    pub fn connect(docs: Docs) -> Result<Ctx, String> {
        futures_lite::future::block_on(async {
            let conn = Connection::session()
                .await
                .map_err(|e| format!("no session bus: {e}"))?;
            let bus = zbus::fdo::DBusProxy::new(&conn)
                .await
                .map_err(|e| e.to_string())?;
            let name = zbus::names::BusName::try_from(MOCK_BUS_NAME).map_err(|e| e.to_string())?;
            if !bus.name_has_owner(name).await.unwrap_or(false) {
                return Err(format!(
                    "no {MOCK_BUS_NAME} on the session bus: start ruya-platform-mock with \
                     `ruya-platform-conformance scenario` as its scenario"
                ));
            }
            Ok(Ctx {
                conn,
                docs,
                next_app: 1,
            })
        })
    }

    /// Runs `case`; the active profile is the first again afterwards, whatever happened.
    pub fn run(&mut self, case: &Case) -> Result<(), String> {
        let result = (case.run)(self);
        let restored = self.switch(PROFILE);
        result.and(restored)
    }

    /// A fresh app of the scenario.
    fn app(&mut self) -> Result<App, String> {
        let n = self.next_app;
        if n > APPS {
            return Err(format!("the scenario has only {APPS} apps"));
        }
        self.next_app += 1;
        let app = app_of(n);
        let scope = instance_scope(&app.app_id, &app.instance).ok_or("no scope")?;
        Ok(App {
            peer: Peer::spawn(&app_name(n))?,
            name: app_name(n),
            app_id: app.app_id,
            scope,
        })
    }

    /// `got` must be `want`, and both must be statuses the XML documents for `element`.
    fn expect(&self, element: &str, got: &str, want: Status) -> Result<(), String> {
        let want = want.as_str();
        if !self.docs.allows(element, want) {
            return Err(format!(
                "the case expects {want:?} from {element}, which the XML does not document"
            ));
        }
        if got != want {
            let note = if self.docs.allows(element, got) {
                ""
            } else {
                " (not even a status the XML documents for it)"
            };
            return Err(format!(
                "{element} answered {got:?}, expected {want:?}{note}"
            ));
        }
        Ok(())
    }

    fn call(
        &self,
        dest: &str,
        path: &str,
        iface: &str,
        member: &str,
        body: &(impl serde::Serialize + zbus::zvariant::DynamicType),
    ) -> Result<String, String> {
        futures_lite::future::block_on(call(&self.conn, dest, path, iface, member, body))
    }

    /// The mock's `Fire`: the event for `app`, the answer of NotifyLifecycle.
    fn fire(&self, app: &App, event: &str, value_ms: u64) -> Result<String, String> {
        self.call(
            MOCK_BUS_NAME,
            MOCK_PATH,
            MOCK,
            "Fire",
            &(app.name.as_str(), event, value_ms),
        )
    }

    /// `fire` in the background, for a "stopping" that waits for the app's answer.
    fn fire_later(
        &self,
        app: &App,
        event: &str,
        value_ms: u64,
    ) -> JoinHandle<Result<String, String>> {
        let (conn, name, event) = (self.conn.clone(), app.name.clone(), event.to_owned());
        std::thread::spawn(move || {
            futures_lite::future::block_on(call(
                &conn,
                MOCK_BUS_NAME,
                MOCK_PATH,
                MOCK,
                "Fire",
                &(name.as_str(), event.as_str(), value_ms),
            ))
        })
    }

    fn switch(&self, profile: &str) -> Result<(), String> {
        let got = self.call(MOCK_BUS_NAME, MOCK_PATH, MOCK, "SwitchProfile", &(profile,))?;
        if got == Status::Ok.as_str() {
            Ok(())
        } else {
            Err(format!("SwitchProfile {profile}: {got}"))
        }
    }

    fn set_permission(&self, app: &App, allowed: bool) -> Result<(), String> {
        let got = self.call(
            BUS_NAME,
            OBJECT_PATH,
            MANAGE,
            "SetPermission",
            &(PROFILE, app.app_id.as_str(), KEY, allowed),
        )?;
        if got == Status::Ok.as_str() {
            Ok(())
        } else {
            Err(format!("SetPermission {allowed}: {got}"))
        }
    }

    /// Manage.NotifyLifecycle for `scope` in `profile` (unchecked on the mock's session bus).
    fn notify(
        &self,
        profile: &str,
        scope: &str,
        event: &str,
        value_ms: u64,
    ) -> Result<String, String> {
        self.call(
            BUS_NAME,
            OBJECT_PATH,
            MANAGE,
            "NotifyLifecycle",
            &(profile, scope, event, value_ms),
        )
    }

    /// A fresh app with one registered connection (number 0).
    fn registered(&mut self) -> Result<App, String> {
        let mut app = self.app()?;
        let n = app.peer.open()?;
        let got = app.peer.call(n, "Register")?;
        self.expect(REGISTER, &got, Status::Ok)?;
        Ok(app)
    }

    /// The next signal of the app's connection `n` must be `want` (with its argument), sent to it
    /// alone.
    fn signal(&self, app: &mut App, n: usize, want: &str) -> Result<(), String> {
        let got = app.peer.signal(n)?;
        let want = format!("{want} unicast");
        if got == want {
            Ok(())
        } else {
            Err(format!(
                "{} got the signal {got:?}, expected {want:?}",
                app.name
            ))
        }
    }

    /// A "stopping" for `app`, run until its Stopping signal arrived: the pending answer.
    fn stopping(
        &self,
        app: &mut App,
        deadline_ms: u64,
    ) -> Result<JoinHandle<Result<String, String>>, String> {
        let answer = self.fire_later(app, "stopping", deadline_ms);
        self.signal(app, 0, &format!("Stopping {deadline_ms}"))?;
        Ok(answer)
    }

    fn settled(
        &self,
        answer: JoinHandle<Result<String, String>>,
        want: Status,
    ) -> Result<(), String> {
        let got = answer.join().map_err(|_| "the Fire call panicked")??;
        self.expect(NOTIFY, &got, want)
    }
}

async fn call(
    conn: &Connection,
    dest: &str,
    path: &str,
    iface: &str,
    member: &str,
    body: &(impl serde::Serialize + zbus::zvariant::DynamicType),
) -> Result<String, String> {
    let reply = conn
        .call_method(Some(dest), path, Some(iface), member, body)
        .await
        .map_err(|e| format!("{iface}.{member}: {e}"))?;
    reply
        .body()
        .deserialize::<String>()
        .map_err(|e| format!("{iface}.{member}: no status: {e}"))
}

pub const CASES: &[Case] = &[
    Case {
        name: "register-ok-and-again",
        covers: &[REGISTER],
        run: |ctx| {
            let mut app = ctx.registered()?;
            let again = app.peer.call(0, "Register")?;
            ctx.expect(REGISTER, &again, Status::Ok)
        },
    },
    Case {
        name: "background-is-sent-to-the-app",
        covers: &[BACKGROUND],
        run: |ctx| {
            let mut app = ctx.registered()?;
            ctx.expect(NOTIFY, &ctx.fire(&app, "background", 0)?, Status::Ok)?;
            ctx.signal(&mut app, 0, "Background")
        },
    },
    Case {
        name: "resume-carries-frozen-ms",
        covers: &[RESUME],
        run: |ctx| {
            let mut app = ctx.registered()?;
            ctx.expect(NOTIFY, &ctx.fire(&app, "resume", 1234)?, Status::Ok)?;
            ctx.signal(&mut app, 0, "Resume 1234")
        },
    },
    Case {
        name: "stopping-then-savedone-is-saved",
        covers: &[STOPPING, SAVE_DONE],
        run: |ctx| {
            let mut app = ctx.registered()?;
            let answer = ctx.stopping(&mut app, 5000)?;
            ctx.expect(SAVE_DONE, &app.peer.call(0, "SaveDone")?, Status::Ok)?;
            ctx.settled(answer, Status::Saved)
        },
    },
    Case {
        name: "stopping-without-savedone-times-out-and-a-late-savedone-is-ok",
        covers: &[STOPPING, SAVE_DONE],
        run: |ctx| {
            let mut app = ctx.registered()?;
            let answer = ctx.stopping(&mut app, 300)?;
            ctx.settled(answer, Status::Timeout)?;
            ctx.expect(SAVE_DONE, &app.peer.call(0, "SaveDone")?, Status::Ok)
        },
    },
    Case {
        name: "an-unsandboxed-caller-is-not-an-app",
        covers: &[REGISTER, SAVE_DONE],
        run: |ctx| {
            let mut peer = Peer::spawn(UNSANDBOXED)?;
            let n = peer.open()?;
            ctx.expect(REGISTER, &peer.call(n, "Register")?, Status::NotAnApp)?;
            ctx.expect(SAVE_DONE, &peer.call(n, "SaveDone")?, Status::NotAnApp)
        },
    },
    Case {
        name: "a-flood-is-rate-limited-after-the-burst",
        covers: &[REGISTER],
        run: |ctx| {
            let mut app = ctx.app()?;
            let n = app.peer.open()?;
            for i in 1..=CALLER_RATE.capacity {
                let got = app.peer.call(n, "Register")?;
                ctx.expect(REGISTER, &got, Status::Ok)
                    .map_err(|e| format!("call {i}: {e}"))?;
            }
            let got = app.peer.call(n, "Register")?;
            ctx.expect(REGISTER, &got, Status::RateLimited)
                .map_err(|e| format!("call {}: {e}", CALLER_RATE.capacity + 1))
        },
    },
    Case {
        name: "a-connection-beyond-eight-is-rate-limited",
        covers: &[REGISTER],
        run: |ctx| {
            let mut app = ctx.app()?;
            for i in 1..=MAX_NAMES + 1 {
                let n = app.peer.open()?;
                let want = if i <= MAX_NAMES {
                    Status::Ok
                } else {
                    Status::RateLimited
                };
                let got = app.peer.call(n, "Register")?;
                ctx.expect(REGISTER, &got, want)
                    .map_err(|e| format!("connection {i}: {e}"))?;
            }
            Ok(())
        },
    },
    Case {
        name: "savedone-without-stopping-is-not-allowed",
        covers: &[SAVE_DONE],
        run: |ctx| {
            let mut app = ctx.registered()?;
            ctx.expect(
                SAVE_DONE,
                &app.peer.call(0, "SaveDone")?,
                Status::NotAllowed,
            )?;
            // Not registered at all: another connection of a fresh app.
            let mut other = ctx.app()?;
            let n = other.peer.open()?;
            ctx.expect(
                SAVE_DONE,
                &other.peer.call(n, "SaveDone")?,
                Status::NotRegistered,
            )
        },
    },
    Case {
        name: "a-second-savedone-is-not-allowed",
        covers: &[SAVE_DONE],
        run: |ctx| {
            let mut app = ctx.registered()?;
            let answer = ctx.stopping(&mut app, 5000)?;
            ctx.expect(SAVE_DONE, &app.peer.call(0, "SaveDone")?, Status::Ok)?;
            ctx.settled(answer, Status::Saved)?;
            ctx.expect(
                SAVE_DONE,
                &app.peer.call(0, "SaveDone")?,
                Status::NotAllowed,
            )
        },
    },
    Case {
        name: "savedone-after-a-resume-is-not-allowed",
        covers: &[SAVE_DONE, BACKGROUND, RESUME],
        run: |ctx| {
            let mut app = ctx.registered()?;
            ctx.expect(NOTIFY, &ctx.fire(&app, "background", 0)?, Status::Ok)?;
            ctx.signal(&mut app, 0, "Background")?;
            ctx.expect(NOTIFY, &ctx.fire(&app, "resume", 50)?, Status::Ok)?;
            ctx.signal(&mut app, 0, "Resume 50")?;
            ctx.expect(
                SAVE_DONE,
                &app.peer.call(0, "SaveDone")?,
                Status::NotAllowed,
            )
        },
    },
    Case {
        name: "an-inactive-profile-may-not-register",
        covers: &[REGISTER],
        run: |ctx| {
            let mut app = ctx.app()?;
            let n = app.peer.open()?;
            ctx.switch(OTHER_PROFILE)?;
            ctx.expect(REGISTER, &app.peer.call(n, "Register")?, Status::NotAllowed)?;
            ctx.switch(PROFILE)?;
            ctx.expect(REGISTER, &app.peer.call(n, "Register")?, Status::Ok)
        },
    },
    Case {
        name: "an-inactive-profile-may-still-answer-its-stopping",
        covers: &[SAVE_DONE, STOPPING],
        run: |ctx| {
            let mut app = ctx.registered()?;
            let answer = ctx.stopping(&mut app, 5000)?;
            ctx.switch(OTHER_PROFILE)?;
            ctx.expect(SAVE_DONE, &app.peer.call(0, "SaveDone")?, Status::Ok)?;
            ctx.settled(answer, Status::Saved)
        },
    },
    Case {
        name: "the-capability-turned-off-during-the-run",
        covers: &[REGISTER, SAVE_DONE, STOPPING],
        run: |ctx| {
            let mut app = ctx.registered()?;
            let answer = ctx.stopping(&mut app, 5000)?;
            ctx.set_permission(&app, false)?;
            let result = (|| {
                ctx.settled(answer, Status::NotRegistered)?;
                ctx.expect(REGISTER, &app.peer.call(0, "Register")?, Status::NotAllowed)?;
                ctx.expect(
                    SAVE_DONE,
                    &app.peer.call(0, "SaveDone")?,
                    Status::NotAllowed,
                )
            })();
            ctx.set_permission(&app, true)?;
            result?;
            ctx.expect(REGISTER, &app.peer.call(0, "Register")?, Status::Ok)
        },
    },
    Case {
        name: "the-registration-ends-with-its-connection",
        covers: &[REGISTER],
        run: |ctx| {
            let mut app = ctx.registered()?;
            app.peer.close(0)?;
            // The service learns of the closed connection from NameOwnerChanged, which it
            // handles beside this call: wait for that state, as long as the runner's patience.
            let until = Instant::now() + PATIENCE;
            loop {
                let got = ctx.fire(&app, "background", 0)?;
                if got != Status::Ok.as_str() || Instant::now() >= until {
                    return ctx.expect(NOTIFY, &got, Status::NotRegistered);
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        },
    },
    Case {
        name: "no-signal-reaches-another-app-or-profile",
        covers: &[BACKGROUND, RESUME, STOPPING],
        run: |ctx| {
            let mut a = ctx.registered()?;
            let mut b = ctx.registered()?;
            // A's Background and Stopping; B's first signal is its own Resume (the fence).
            ctx.expect(NOTIFY, &ctx.fire(&a, "background", 0)?, Status::Ok)?;
            ctx.signal(&mut a, 0, "Background")?;
            let answer = ctx.stopping(&mut a, 300)?;
            ctx.settled(answer, Status::Timeout)?;
            ctx.expect(NOTIFY, &ctx.fire(&b, "resume", 7)?, Status::Ok)?;
            ctx.signal(&mut b, 0, "Resume 7")?;
            // The same scope in another profile is another instance: not A's.
            let got = ctx.notify(OTHER_PROFILE, &a.scope, "background", 0)?;
            ctx.expect(NOTIFY, &got, Status::NotRegistered)?;
            ctx.expect(NOTIFY, &ctx.fire(&a, "resume", 8)?, Status::Ok)?;
            ctx.signal(&mut a, 0, "Resume 8")
        },
    },
];

/// The elements each case covers, by name.
#[cfg(test)]
fn covered() -> std::collections::BTreeMap<&'static str, &'static [&'static str]> {
    CASES.iter().map(|c| (c.name, c.covers)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn apis(members: &[&str]) -> String {
        let entries: Vec<serde_json::Value> = members
            .iter()
            .map(|m| {
                let (i, m) = m.rsplit_once('.').expect("interface.member");
                serde_json::json!({
                    "interface": i, "member": m, "kind": "method", "stability": "experimental",
                    "since": 0, "signature": "", "file": "api/dbus/org.ruyaos.Platform1.xml"
                })
            })
            .collect();
        serde_json::Value::Array(entries).to_string()
    }

    const ALL: &[&str] = &[REGISTER, SAVE_DONE, BACKGROUND, RESUME, STOPPING];

    #[test]
    fn every_lifecycle_element_has_a_case() {
        assert_eq!(coverage(&apis(ALL)), Ok(Vec::new()));
    }

    #[test]
    fn a_new_public_element_without_a_case_fails() {
        let mut members = ALL.to_vec();
        members.push("org.ruyaos.Platform1.Lifecycle.Extra");
        assert_eq!(
            coverage(&apis(&members)),
            Ok(vec![
                "no conformance case for org.ruyaos.Platform1.Lifecycle.Extra".to_owned()
            ])
        );
    }

    #[test]
    fn a_case_for_an_element_that_is_not_public_fails() {
        let problems = coverage(&apis(&ALL[..4])).expect("an apis.json");
        assert_eq!(
            problems,
            vec![format!(
                "a case covers {STOPPING}, which is not a public element"
            )]
        );
    }

    #[test]
    fn elements_of_other_files_are_not_this_runners() {
        let other = serde_json::json!([{
            "interface": "org.ruyaos.Other1", "member": "Do", "file": "api/dbus/org.ruyaos.Other1.xml"
        }]);
        let mut all: Vec<serde_json::Value> = serde_json::from_str(&apis(ALL)).expect("json");
        all.push(other[0].clone());
        assert_eq!(
            coverage(&serde_json::Value::Array(all).to_string()),
            Ok(Vec::new())
        );
        assert!(coverage("{").is_err());
    }

    #[test]
    fn the_scenario_parses_and_every_case_has_its_apps() {
        let json = serde_json::to_string(&scenario()).expect("serialises");
        let s = Scenario::parse(&json).expect("a valid scenario");
        assert_eq!(s.apps.len(), APPS);
        assert!(!s.apps.contains_key(UNSANDBOXED));
        // registered() and app() each take one; no case takes more than three.
        assert!(CASES.len() * 3 <= APPS, "{} cases", CASES.len());
    }

    #[test]
    fn the_numbers_the_cases_rely_on_are_the_contracts() {
        let xml = include_str!("../../../../../api/dbus/org.ruyaos.Platform1.xml");
        assert!(xml.contains(&format!("a burst of {} calls", CALLER_RATE.capacity)));
        assert!(xml.contains(&format!("already has {MAX_NAMES} registered connections")));
    }

    #[test]
    fn case_names_are_unique() {
        assert_eq!(covered().len(), CASES.len());
    }
}
