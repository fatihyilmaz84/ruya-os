//! The Flatpak scope of a run (T-363). Pure: time comes in as `Instant`, the OS answers through
//! the `ShowUnit`s the caller got from `systemctl show` (`systemd.rs`).
//!
//! `flatpak run <app>` moves itself into its own `app-flatpak-<app>-<n>.scope` in the user's
//! manager and starts the sandbox there, outside our `ruya-app-*` unit (the unit's accounting
//! showed 28 ms of CPU for a 45 minute game, T-355). A run is therefore two things: the unit
//! (the `flatpak run` front end, whose end the rest of the service already reports) and the
//! scope (where the game really is).
//!
//! `RunScopes` knows every run the spawner started or adopted. It
//!   - finds the run's scope: the live `app-flatpak-<app>-<n>.scope` of the run's app that
//!     entered `active` no earlier than the unit (`attach`), looked for every second for a
//!     minute after the start (an adopted unit is looked at once, at once);
//!   - reads the CPU of the unit and of the scope (`cpu_nsec`; the sum is the run's usage, kept
//!     after the scope has gone);
//!   - holds the unit's end (`on_unit_event`) while the scope lives, and hands it on when the
//!     scope is gone, so a run ends when **both** are gone;
//!   - names the scope for `Stop` and the kill (`scope_of`).
//!
//! One round is `plan` (what to ask each manager), the caller's `systemctl show`, and `apply`
//! (the answer). Nothing here starts a process or waits.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::spawner::{is_app_scope, scope_pattern, ShowUnit, UnitEvent};

/// How often a run without a scope is looked at.
pub const ATTACH_EVERY: Duration = Duration::from_secs(1);
/// How long after its start a run is looked at for its scope; then it is taken to have none (a
/// launcher that is not a Flatpak sandbox).
pub const ATTACH_WINDOW: Duration = Duration::from_secs(60);
/// How often an attached scope is looked at.
pub const WATCH_EVERY: Duration = Duration::from_secs(5);
/// Failed looks in a row after which a scope is taken to be gone (its manager is gone).
pub const MAX_MISSES: u32 = 5;

/// One `systemctl show` to make: these units (names and patterns) in `user`'s manager.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Query {
    pub user: String,
    pub names: Vec<String>,
}

#[derive(Debug)]
struct Run {
    user: String,
    app_id: String,
    /// The attached scope.
    scope: Option<String>,
    /// The scope has gone (or never was): nothing is held for it any more.
    done: bool,
    unit_cpu: Option<u64>,
    scope_cpu: Option<u64>,
    /// The unit's end, kept until the scope is gone.
    held: Option<UnitEvent>,
    next_at: Instant,
    give_up_at: Instant,
    misses: u32,
    /// Is a look in flight (between `plan` and `apply`)?
    queried: bool,
}

impl Run {
    /// Does a live scope keep the run alive?
    fn attached(&self) -> bool {
        self.scope.is_some() && !self.done
    }
}

#[derive(Debug, Default)]
pub struct RunScopes {
    runs: HashMap<String, Run>,
}

impl RunScopes {
    pub fn new() -> Self {
        Self::default()
    }

    /// A run began (started by us, or adopted at start-up). `unit` is its `ruya-app-*` unit.
    pub fn begin(&mut self, unit: &str, user: &str, app_id: &str, now: Instant) {
        self.runs.insert(
            unit.to_owned(),
            Run {
                user: user.to_owned(),
                app_id: app_id.to_owned(),
                scope: None,
                done: false,
                unit_cpu: None,
                scope_cpu: None,
                held: None,
                next_at: now,
                give_up_at: now + ATTACH_WINDOW,
                misses: 0,
                queried: false,
            },
        );
    }

    /// The run is not followed any more (its start failed before anything ran).
    pub fn forget(&mut self, unit: &str) {
        self.runs.remove(unit);
    }

    /// The scope `Stop` and the kill must reach next to the unit: `None` before one is attached
    /// and after it has gone.
    pub fn scope_of(&self, unit: &str) -> Option<String> {
        self.runs
            .get(unit)
            .filter(|r| r.attached())
            .and_then(|r| r.scope.clone())
    }

    /// CPU time of the run so far, in nanoseconds: the unit's and the scope's together. The
    /// scope's last reading stays after it has gone. `None` when nothing was readable.
    pub fn cpu_nsec(&self, unit: &str) -> Option<u64> {
        let run = self.runs.get(unit)?;
        match (run.unit_cpu, run.scope_cpu) {
            (None, None) => None,
            (a, b) => Some(a.unwrap_or(0).saturating_add(b.unwrap_or(0))),
        }
    }

    /// An event of a unit on its way to the core. `Started` and the events of units without a
    /// live scope pass; the end of a unit whose scope still lives is kept (`None`) until `apply`
    /// sees the scope go.
    pub fn on_unit_event(&mut self, event: UnitEvent) -> Option<UnitEvent> {
        let unit = match &event {
            UnitEvent::Exited { unit, .. } | UnitEvent::ExecFailed { unit } => unit.clone(),
            UnitEvent::Started { .. } => return Some(event),
        };
        let Some(run) = self.runs.get_mut(&unit) else {
            return Some(event);
        };
        if run.attached() {
            run.held.get_or_insert(event);
            return None;
        }
        self.runs.remove(&unit);
        Some(event)
    }

    /// What to ask the managers now: for every run that is due, its unit (for the CPU) and its
    /// scope (the attached one, or the pattern of the app's scopes while none is).
    pub fn plan(&mut self, now: Instant) -> Vec<Query> {
        let mut by_user: Vec<Query> = Vec::new();
        let mut units: Vec<&String> = self.runs.keys().collect();
        units.sort();
        let units: Vec<String> = units.into_iter().cloned().collect();
        for unit in units {
            let Some(run) = self.runs.get_mut(&unit) else {
                continue;
            };
            if run.done || run.next_at > now {
                continue;
            }
            let scope = match &run.scope {
                Some(name) => name.clone(),
                None => match scope_pattern(&run.app_id) {
                    Ok(pattern) => pattern,
                    Err(_) => {
                        run.done = true;
                        continue;
                    }
                },
            };
            run.queried = true;
            let at = match by_user.iter().position(|q| q.user == run.user) {
                Some(at) => at,
                None => {
                    by_user.push(Query {
                        user: run.user.clone(),
                        names: Vec::new(),
                    });
                    by_user.len() - 1
                }
            };
            by_user[at].names.push(unit);
            if !by_user[at].names.contains(&scope) {
                by_user[at].names.push(scope);
            }
        }
        by_user
    }

    /// The answer to a `Query` of `user`: `shows` is what `systemctl show` printed, `None` when
    /// the call failed. Returns the unit ends that were held for a scope that is gone now.
    pub fn apply(
        &mut self,
        user: &str,
        shows: Option<&[ShowUnit]>,
        now: Instant,
    ) -> Vec<UnitEvent> {
        let mut released = Vec::new();
        let mut units: Vec<String> = self
            .runs
            .iter()
            .filter(|(_, r)| r.user == user && r.queried)
            .map(|(u, _)| u.clone())
            .collect();
        units.sort();
        for unit in units {
            let Some(run) = self.runs.get_mut(&unit) else {
                continue;
            };
            run.queried = false;
            let Some(shows) = shows else {
                run.misses += 1;
                run.next_at = now + WATCH_EVERY.min(ATTACH_EVERY * 2);
                if (run.attached() && run.misses >= MAX_MISSES)
                    || (run.scope.is_none() && now >= run.give_up_at)
                {
                    run.done = true;
                }
                if run.done {
                    if let Some(event) = run.held.take() {
                        released.push(event);
                        self.runs.remove(&unit);
                    }
                }
                continue;
            };
            run.misses = 0;
            let unit_show = shows.iter().find(|s| s.id == unit);
            if let Some(cpu) = unit_show.and_then(|s| s.cpu_nsec) {
                run.unit_cpu = Some(run.unit_cpu.map_or(cpu, |old| old.max(cpu)));
            }
            match run.scope.clone() {
                None => {
                    let entered = unit_show.map_or(0, |s| s.entered);
                    let found = shows
                        .iter()
                        .filter(|s| is_app_scope(&run.app_id, &s.id) && s.alive())
                        // The scope is made after the unit started. A second of slack: the
                        // timestamps are whole seconds.
                        .filter(|s| entered == 0 || s.entered + 1 >= entered)
                        .min_by(|a, b| (a.entered, &a.id).cmp(&(b.entered, &b.id)));
                    match found {
                        Some(scope) => {
                            eprintln!("ruya-session: {unit}: attached {}", scope.id);
                            run.scope = Some(scope.id.clone());
                            run.scope_cpu = scope.cpu_nsec;
                            run.next_at = now + WATCH_EVERY;
                        }
                        None if now >= run.give_up_at => run.done = true,
                        None => run.next_at = now + ATTACH_EVERY,
                    }
                }
                Some(name) => {
                    let live = shows.iter().find(|s| s.id == name && s.alive());
                    match live {
                        Some(scope) => {
                            if let Some(cpu) = scope.cpu_nsec {
                                run.scope_cpu = Some(run.scope_cpu.map_or(cpu, |old| old.max(cpu)));
                            }
                            run.next_at = now + WATCH_EVERY;
                        }
                        None => {
                            eprintln!(
                                "ruya-session: {unit}: scope gone, cpu {} ms",
                                run.unit_cpu
                                    .unwrap_or(0)
                                    .saturating_add(run.scope_cpu.unwrap_or(0))
                                    / 1_000_000
                            );
                            run.done = true;
                        }
                    }
                }
            }
            if run.done {
                if let Some(event) = run.held.take() {
                    released.push(event);
                    self.runs.remove(&unit);
                }
            }
        }
        released
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const USER: &str = "ruya-p1";
    const APP: &str = "net.supertuxkart.SuperTuxKart";
    const UNIT: &str = "ruya-app-ruya-p1-net.supertuxkart.SuperTuxKart.service";
    const SCOPE: &str = "app-flatpak-net.supertuxkart.SuperTuxKart-4242.scope";

    fn exited(code: i32) -> UnitEvent {
        UnitEvent::Exited {
            unit: UNIT.to_owned(),
            code,
            signaled: false,
        }
    }

    fn unit_show(entered: i64, cpu: Option<u64>) -> ShowUnit {
        ShowUnit {
            id: UNIT.to_owned(),
            load_state: "loaded".to_owned(),
            active_state: "active".to_owned(),
            entered,
            cpu_nsec: cpu,
            ..ShowUnit::default()
        }
    }

    fn scope_show(name: &str, entered: i64, cpu: Option<u64>) -> ShowUnit {
        ShowUnit {
            id: name.to_owned(),
            load_state: "loaded".to_owned(),
            active_state: "active".to_owned(),
            entered,
            cpu_nsec: cpu,
            ..ShowUnit::default()
        }
    }

    fn gone_scope(name: &str) -> ShowUnit {
        ShowUnit {
            id: name.to_owned(),
            load_state: "not-found".to_owned(),
            active_state: "inactive".to_owned(),
            ..ShowUnit::default()
        }
    }

    /// A user manager that holds a list of units and answers `systemctl show` for names and
    /// the one glob (`app-flatpak-<id>-*.scope`) the service asks.
    struct FakeManager {
        units: Vec<ShowUnit>,
        down: bool,
        asked: Vec<Query>,
    }

    impl FakeManager {
        fn new(units: Vec<ShowUnit>) -> Self {
            FakeManager {
                units,
                down: false,
                asked: Vec::new(),
            }
        }

        fn set(&mut self, show: ShowUnit) {
            self.units.retain(|u| u.id != show.id);
            self.units.push(show);
        }

        fn show(&mut self, q: &Query) -> Option<Vec<ShowUnit>> {
            self.asked.push(q.clone());
            if self.down {
                return None;
            }
            let mut out = Vec::new();
            for name in &q.names {
                if let Some(prefix) = name.strip_suffix("-*.scope") {
                    out.extend(
                        self.units
                            .iter()
                            .filter(|u| u.id.starts_with(prefix) && u.id.ends_with(".scope"))
                            .cloned(),
                    );
                } else if let Some(u) = self.units.iter().find(|u| u.id == *name) {
                    out.push(u.clone());
                } else {
                    // An exact name that is not loaded is still answered: not-found.
                    out.push(gone_scope(name));
                }
            }
            Some(out)
        }
    }

    /// One round: plan, ask the manager, apply. Returns the released events.
    fn round(scopes: &mut RunScopes, mgr: &mut FakeManager, now: Instant) -> Vec<UnitEvent> {
        let mut out = Vec::new();
        for q in scopes.plan(now) {
            let shows = mgr.show(&q);
            out.extend(scopes.apply(&q.user, shows.as_deref(), now));
        }
        out
    }

    fn t0() -> Instant {
        Instant::now()
    }

    #[test]
    fn a_flatpak_scope_is_attached_to_its_run() {
        let now = t0();
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        let mut mgr = FakeManager::new(vec![
            unit_show(1000, Some(28_000_000)),
            // Another app's scope, an older run of ours and an app whose id only starts like
            // ours: none of them is the scope of this run.
            scope_show("app-flatpak-org.other.Game-77.scope", 1001, None),
            scope_show(
                "app-flatpak-net.supertuxkart.SuperTuxKart-7.scope",
                900,
                None,
            ),
            scope_show(
                "app-flatpak-net.supertuxkart.SuperTuxKart-Extra-9.scope",
                1001,
                None,
            ),
        ]);
        assert!(round(&mut scopes, &mut mgr, now).is_empty());
        assert_eq!(scopes.scope_of(UNIT), None, "no scope of this run yet");
        // The question was one call: the unit and the pattern of the app's scopes.
        assert_eq!(
            mgr.asked[0],
            Query {
                user: USER.to_owned(),
                names: vec![
                    UNIT.to_owned(),
                    "app-flatpak-net.supertuxkart.SuperTuxKart-*.scope".to_owned()
                ]
            }
        );
        // `flatpak run` makes the scope a second after the unit started.
        mgr.set(scope_show(SCOPE, 1001, Some(5)));
        let now = now + ATTACH_EVERY;
        assert!(round(&mut scopes, &mut mgr, now).is_empty());
        assert_eq!(scopes.scope_of(UNIT).as_deref(), Some(SCOPE));
        // From now on the exact scope is asked, not the pattern.
        let now = now + WATCH_EVERY;
        round(&mut scopes, &mut mgr, now);
        assert_eq!(
            mgr.asked.last().map(|q| q.names.clone()),
            Some(vec![UNIT.to_owned(), SCOPE.to_owned()])
        );
    }

    #[test]
    fn a_run_without_a_scope_is_given_up_after_the_window_and_never_held() {
        let now = t0();
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        let mut mgr = FakeManager::new(vec![unit_show(1000, None)]);
        round(&mut scopes, &mut mgr, now);
        let late = now + ATTACH_WINDOW + ATTACH_EVERY;
        round(&mut scopes, &mut mgr, late);
        let asked = mgr.asked.len();
        round(&mut scopes, &mut mgr, late + WATCH_EVERY);
        assert_eq!(mgr.asked.len(), asked, "no more looks");
        // Its end passes at once.
        assert_eq!(scopes.on_unit_event(exited(0)), Some(exited(0)));
    }

    #[test]
    fn usage_counts_the_scope_cpu() {
        let now = t0();
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        assert_eq!(scopes.cpu_nsec(UNIT), None, "nothing read yet");
        // The unit's own 28 ms, and the game in the scope: 45 minutes at 15 % of a core.
        let game = 45 * 60 * 150_000_000_u64;
        let mut mgr = FakeManager::new(vec![
            unit_show(1000, Some(28_000_000)),
            scope_show(SCOPE, 1001, Some(1_000)),
        ]);
        round(&mut scopes, &mut mgr, now);
        mgr.set(scope_show(SCOPE, 1001, Some(game)));
        round(&mut scopes, &mut mgr, now + WATCH_EVERY);
        assert_eq!(scopes.cpu_nsec(UNIT), Some(game + 28_000_000));
        // A reading below the last one (a restarted counter) never lowers the total.
        mgr.set(scope_show(SCOPE, 1001, Some(5)));
        round(&mut scopes, &mut mgr, now + WATCH_EVERY * 2);
        assert_eq!(scopes.cpu_nsec(UNIT), Some(game + 28_000_000));
        // The scope's last reading stays after it has gone, until the run's end.
        mgr.set(gone_scope(SCOPE));
        assert!(round(&mut scopes, &mut mgr, now + WATCH_EVERY * 3).is_empty());
        assert_eq!(scopes.scope_of(UNIT), None);
        assert_eq!(scopes.cpu_nsec(UNIT), Some(game + 28_000_000));
    }

    #[test]
    fn the_run_ends_only_when_the_scope_is_gone() {
        let now = t0();
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        let mut mgr = FakeManager::new(vec![unit_show(1000, None), scope_show(SCOPE, 1001, None)]);
        round(&mut scopes, &mut mgr, now);
        assert_eq!(scopes.scope_of(UNIT).as_deref(), Some(SCOPE));
        // The `flatpak run` front end ends first; the game keeps running: nothing ends yet.
        assert_eq!(scopes.on_unit_event(exited(0)), None);
        mgr.set(gone_scope(UNIT));
        let mut at = now;
        for _ in 0..3 {
            at += WATCH_EVERY;
            assert!(round(&mut scopes, &mut mgr, at).is_empty());
        }
        assert_eq!(
            scopes.scope_of(UNIT).as_deref(),
            Some(SCOPE),
            "Stop and the kill can still reach it"
        );
        // The game quits: the held end is handed on, once, with the unit's own status.
        mgr.set(gone_scope(SCOPE));
        at += WATCH_EVERY;
        assert_eq!(round(&mut scopes, &mut mgr, at), [exited(0)]);
        at += WATCH_EVERY;
        assert!(round(&mut scopes, &mut mgr, at).is_empty());
        assert_eq!(scopes.scope_of(UNIT), None);
        assert_eq!(scopes.cpu_nsec(UNIT), None, "the run is forgotten");
    }

    #[test]
    fn a_manager_that_does_not_answer_keeps_the_end_held_for_a_while_then_gives_it() {
        let now = t0();
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        let mut mgr = FakeManager::new(vec![scope_show(SCOPE, 1001, None)]);
        round(&mut scopes, &mut mgr, now);
        assert_eq!(scopes.on_unit_event(exited(3)), None);
        mgr.down = true;
        let mut at = now;
        for _ in 0..MAX_MISSES - 1 {
            at += WATCH_EVERY;
            assert!(round(&mut scopes, &mut mgr, at).is_empty());
        }
        at += WATCH_EVERY;
        assert_eq!(round(&mut scopes, &mut mgr, at), [exited(3)]);
    }

    #[test]
    fn a_unit_that_ends_with_the_scope_already_gone_is_not_held() {
        let now = t0();
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        let mut mgr = FakeManager::new(vec![scope_show(SCOPE, 1001, None)]);
        round(&mut scopes, &mut mgr, now);
        mgr.set(gone_scope(SCOPE));
        round(&mut scopes, &mut mgr, now + WATCH_EVERY);
        assert_eq!(scopes.on_unit_event(exited(0)), Some(exited(0)));
        // Events of units it does not know, and a start, pass.
        let other = UnitEvent::Started {
            unit: "ruya-app-ruya-p1-org.x.Y.service".to_owned(),
        };
        assert_eq!(scopes.on_unit_event(other.clone()), Some(other));
    }

    #[test]
    fn stop_also_stops_the_scope() {
        use crate::spawner::{control_command, scope_target};
        let now = t0();
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        // Before the scope is attached the pattern of the app's scopes goes along.
        let target = scope_target(APP, scopes.scope_of(UNIT).as_deref()).expect("pattern");
        let stop = control_command(USER, &["stop", "--no-block"], UNIT, &target).expect("stop");
        assert_eq!(
            stop,
            [
                "systemctl",
                "--user",
                "--no-pager",
                "--machine=ruya-p1@.host",
                "stop",
                "--no-block",
                UNIT,
                "app-flatpak-net.supertuxkart.SuperTuxKart-*.scope",
            ]
        );
        // Attached: the exact scope, and it is still named after the unit has ended, so the
        // kill of an overdue Stop reaches the game too.
        let mut mgr = FakeManager::new(vec![scope_show(SCOPE, 1001, None)]);
        round(&mut scopes, &mut mgr, now);
        assert_eq!(scopes.on_unit_event(exited(0)), None);
        let target = scope_target(APP, scopes.scope_of(UNIT).as_deref()).expect("scope");
        let kill = control_command(
            USER,
            &["kill", "--signal=SIGKILL", "--kill-whom=all"],
            UNIT,
            &target,
        )
        .expect("kill");
        assert_eq!(&kill[kill.len() - 2..], [UNIT, SCOPE]);
        // Nothing foreign gets through.
        assert!(scope_target(APP, Some("app-flatpak-org.other.Game-1.scope")).is_err());
        assert!(scope_target(APP, Some("../x")).is_err());
        assert!(control_command("root", &["stop"], UNIT, SCOPE).is_err());
    }

    #[test]
    fn only_the_scopes_of_the_app_match() {
        assert!(is_app_scope(APP, SCOPE));
        for bad in [
            "app-flatpak-net.supertuxkart.SuperTuxKart-.scope",
            "app-flatpak-net.supertuxkart.SuperTuxKart-x1.scope",
            "app-flatpak-net.supertuxkart.SuperTuxKart-Extra-1.scope",
            "app-flatpak-net.supertuxkart.SuperTuxKart-1.service",
            "flatpak-net.supertuxkart.SuperTuxKart-1.scope",
            "app-flatpak-net.supertuxkart.SuperTuxKar-1.scope",
        ] {
            assert!(!is_app_scope(APP, bad), "{bad}");
        }
        assert!(!is_app_scope("bad id", "app-flatpak-bad id-1.scope"));
    }

    #[test]
    fn a_cpu_reading_of_a_unit_is_parsed_from_show() {
        use crate::spawner::parse_show;
        let text = "Id=a.scope\nLoadState=loaded\nActiveState=active\nCPUUsageNSec=1234\n\n\
                    Id=b.scope\nLoadState=loaded\nActiveState=active\nCPUUsageNSec=[not set]\n\n\
                    Id=c.scope\nLoadState=loaded\nActiveState=active\nCPUUsageNSec=18446744073709551615\n";
        let shows = parse_show(text);
        assert_eq!(
            shows.iter().map(|s| s.cpu_nsec).collect::<Vec<_>>(),
            [Some(1234), None, None]
        );
    }
}
