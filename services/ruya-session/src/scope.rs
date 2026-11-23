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
//!   - reads the CPU of the unit and of every scope of the app that started after it (`cpu_nsec`;
//!     the sum is the run's usage, kept after a scope has gone);
//!   - holds the unit's end (`on_unit_event`) while the scope lives, and hands it on when the
//!     scope is gone, so a run ends when **both** are gone; while an end is held the scope is
//!     looked at every second (`ATTACH_EVERY`), so a `Stop` that needed the kill ends well inside
//!     the wait of the `Launch` after it;
//!   - names the attached scope (`scope_of`, for a freeze, T-165);
//!   - asks for the app's leftover scopes to be cleared when the run's end is handed on
//!     (`take_sweeps`, T-435). A run can have more than one scope: an Electron app's sandboxed
//!     zygote is started through the Flatpak portal (zypak, `flatpak-spawn --sandbox`), which
//!     makes a second `app-flatpak-<app>-<n>.scope` in the same second, and the run attaches
//!     either of the two. `Stop` and the kill therefore name every scope of the app, listed
//!     first and kept by exact name (`spawner::app_scopes`, `control_command`), and the end of
//!     a run stops what is left and clears the `failed` state of a scope systemd had to kill,
//!     so nothing stays listed.
//!
//!
//! A run whose app has `children = steam` in the image's app table (`follow_children`, ADR-041,
//! RUY-1052) has child instances, one per Steam game:
//!   - every new scope of the app other than the attached one is probed (`take_probes`; the
//!     caller runs `steam-probe` as the profile user and hands the verdict back with `probed`); a
//!     scope whose probe names game G is one of child G's, every other scope is the parent's. A
//!     scope probed before its sandbox started is undecided and probed again at the next looks,
//!     at most `MAX_PROBES` times in all, then it is the parent's; a decided scope is never probed
//!     again;
//!   - child G starts with its first scope (`UnitEvent::ChildStarted`, named by
//!     `spawner::child_name`) and keeps every later scope of G (a launcher handing over);
//!   - it ends (`UnitEvent::Exited` of the child's name, code 0) when none of its scopes has
//!     existed for `CHILD_GRACE` and no probe of the run is still out, or at once when the run's
//!     attached scope is gone: a parent's end ends its children first, before the run's own end
//!     is handed on;
//!   - such a run is looked at every second (`ATTACH_EVERY`) while its scope lives, so a game's
//!     start is seen within a second and its end within `CHILD_GRACE` and a second;
//!   - `child`, `child_of_scope` and `child_scopes` name what a Stop, Freeze, Thaw, Kill and
//!     `InstanceOfPid` of a child reach, and what the freeze of a parent's own scopes leaves out.
//!
//! One round is `plan` (what to ask each manager), the caller's `systemctl show`, and `apply`
//! (the answer). Nothing here starts a process or waits.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::time::{Duration, Instant};

use crate::spawner::{child_name, scope_pattern, ShowUnit, UnitEvent};
use crate::steam_probe::Verdict;
use ruya_flatpak::scope::is_app_scope;

/// How often a run without a scope is looked at.
pub const ATTACH_EVERY: Duration = Duration::from_secs(1);
/// How long after its start a run is looked at for its scope; then it is taken to have none (a
/// launcher that is not a Flatpak sandbox).
pub const ATTACH_WINDOW: Duration = Duration::from_secs(60);
/// How often an attached scope is looked at.
pub const WATCH_EVERY: Duration = Duration::from_secs(5);
/// Failed looks in a row after which a scope is taken to be gone (its manager is gone).
pub const MAX_MISSES: u32 = 5;
/// A child instance ends when none of its scopes has existed for this long (ADR-041 point 5): a
/// launcher that hands over to the game in a new scope stays one child.
pub const CHILD_GRACE: Duration = Duration::from_secs(3);
/// How often one scope is probed while it stays undecided (its sandbox not started yet, about
/// 130 ms after the scope on the Dell); then it is the parent's. One look a second.
pub const MAX_PROBES: u32 = 5;

/// A scope of a `children` run to probe (`take_probes`): `steam-probe <scope>` as `user`, the
/// answer back through `probed`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProbeRequest {
    pub unit: String,
    pub user: String,
    pub scope: String,
}

/// What the control of a child instance reaches (`child`): its own scopes in `user`'s manager.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChildScopes {
    pub user: String,
    pub app_id: String,
    pub scopes: Vec<String>,
}

/// One child instance of a run: a Steam game.
#[derive(Debug)]
struct Kid {
    name: String,
    /// Its scopes that were alive at the last look.
    scopes: BTreeSet<String>,
    /// Since when it has had no scope.
    gone_since: Option<Instant>,
}

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
    /// The highest CPU reading of every scope of the app that started after the unit (the
    /// attached one, the portal's, a game's subsandbox), kept after a scope has ended.
    scope_cpu: BTreeMap<String, u64>,
    /// The unit's end, kept until the scope is gone.
    held: Option<UnitEvent>,
    next_at: Instant,
    give_up_at: Instant,
    misses: u32,
    /// Is a look in flight (between `plan` and `apply`)?
    queried: bool,
    /// The app has child instances (`follow_children`).
    children: bool,
    /// The live scopes of a `children` run that were probed: `Some(G)` child G's, `None` the
    /// parent's. A scope is probed once.
    sorted: BTreeMap<String, Option<String>>,
    /// The scopes whose probe is out: when each became active (unix seconds) and whether it was
    /// frozen, for the child it may start.
    probing: BTreeMap<String, (i64, bool)>,
    /// The live scopes that were probed undecided, with how often: probed again at the next look.
    undecided: BTreeMap<String, u32>,
    /// The child instances, by Steam app id.
    kids: BTreeMap<String, Kid>,
}

impl Run {
    /// Does a live scope keep the run alive?
    fn attached(&self) -> bool {
        self.scope.is_some() && !self.done
    }

    /// Ends every child (the run's attached scope is gone, or its manager is): their `Exited`s, in
    /// the order of their app ids.
    fn end_kids(&mut self, released: &mut Vec<UnitEvent>) {
        for (_, kid) in std::mem::take(&mut self.kids) {
            released.push(child_end(&kid.name));
        }
        self.probing.clear();
        self.undecided.clear();
    }

    /// The unit's CPU and that of every scope read so far; `None` when nothing was readable.
    fn cpu(&self) -> Option<u64> {
        if self.unit_cpu.is_none() && self.scope_cpu.is_empty() {
            return None;
        }
        Some(
            self.scope_cpu
                .values()
                .fold(self.unit_cpu.unwrap_or(0), |sum, cpu| {
                    sum.saturating_add(*cpu)
                }),
        )
    }
}

/// A run has ended: every scope of `app_id` left in `user`'s manager is to be stopped and its
/// `failed` state cleared (`spawner::sweep_commands`) before the end reaches the core, so a
/// relaunch can never be caught by it. One app runs once per profile user, so the app's scopes
/// in that manager all belong to the run that ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sweep {
    pub user: String,
    pub app_id: String,
}

/// The end of a child instance as the core takes it: an `Exited` of its name.
fn child_end(name: &str) -> UnitEvent {
    UnitEvent::Exited {
        unit: name.to_owned(),
        code: 0,
        signaled: false,
    }
}

#[derive(Debug, Default)]
pub struct RunScopes {
    runs: HashMap<String, Run>,
    sweeps: Vec<Sweep>,
    probes: Vec<ProbeRequest>,
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
                scope_cpu: BTreeMap::new(),
                held: None,
                next_at: now,
                give_up_at: now + ATTACH_WINDOW,
                misses: 0,
                queried: false,
                children: false,
                sorted: BTreeMap::new(),
                probing: BTreeMap::new(),
                undecided: BTreeMap::new(),
                kids: BTreeMap::new(),
            },
        );
    }

    /// The run's app has child instances (the app table's `children = steam`, ADR-041): its new
    /// scopes other than the attached one are probed from now on.
    pub fn follow_children(&mut self, unit: &str) {
        if let Some(run) = self.runs.get_mut(unit) {
            run.children = true;
        }
    }

    /// The probes `apply` asked for since the last call, in order.
    pub fn take_probes(&mut self) -> Vec<ProbeRequest> {
        std::mem::take(&mut self.probes)
    }

    /// The verdict of a probe of `take_probes` (`steam_probe::parse_answer`). A scope of a new
    /// game starts its child (`ChildStarted`); one of a running child joins it; the parent's is
    /// sorted for good; an undecided one is probed again at the next look, until its
    /// `MAX_PROBES`th undecided verdict makes it the parent's. Nothing for a run whose scope has
    /// gone meanwhile.
    pub fn probed(&mut self, unit: &str, scope: &str, verdict: Verdict) -> Option<UnitEvent> {
        let run = self.runs.get_mut(unit).filter(|r| !r.done)?;
        let (started, frozen) = run.probing.remove(scope)?;
        let tries = run.undecided.remove(scope).unwrap_or(0) + 1;
        let game = match verdict {
            Verdict::Undecided if tries < MAX_PROBES => {
                run.undecided.insert(scope.to_owned(), tries);
                return None;
            }
            Verdict::Undecided => {
                eprintln!(
                    "ruya-session: {unit}: {scope} still undecided after {tries} probes, Steam's"
                );
                None
            }
            Verdict::Parent => None,
            Verdict::Game(appid) => Some(appid),
        };
        run.sorted.insert(scope.to_owned(), game.clone());
        let appid = game?;
        if let Some(kid) = run.kids.get_mut(&appid) {
            kid.scopes.insert(scope.to_owned());
            kid.gone_since = None;
            return None;
        }
        let name = child_name(unit, &appid);
        eprintln!("ruya-session: {unit}: {scope} is steam:{appid}, child {name}");
        run.kids.insert(
            appid.clone(),
            Kid {
                name: name.clone(),
                scopes: BTreeSet::from([scope.to_owned()]),
                gone_since: None,
            },
        );
        Some(UnitEvent::ChildStarted {
            parent: unit.to_owned(),
            child: name,
            appid,
            started,
            frozen,
        })
    }

    /// The child instance `name`: its user, its app and the scopes it had at the last look.
    pub fn child(&self, name: &str) -> Option<ChildScopes> {
        self.runs.values().find_map(|run| {
            let kid = run.kids.values().find(|k| k.name == name)?;
            Some(ChildScopes {
                user: run.user.clone(),
                app_id: run.app_id.clone(),
                scopes: kid.scopes.iter().cloned().collect(),
            })
        })
    }

    /// The child instance one of whose scopes is `scope` in `user`'s manager.
    pub fn child_of_scope(&self, user: &str, scope: &str) -> Option<String> {
        self.runs
            .values()
            .filter(|run| run.user == user)
            .flat_map(|run| run.kids.values())
            .find(|kid| kid.scopes.contains(scope))
            .map(|kid| kid.name.clone())
    }

    /// Every scope of every child of the run `unit`: what a freeze of the parent's own scopes
    /// leaves out (ADR-041 point 7).
    pub fn child_scopes(&self, unit: &str) -> Vec<String> {
        self.runs
            .get(unit)
            .map(|run| {
                run.kids
                    .values()
                    .flat_map(|k| k.scopes.iter().cloned())
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The sweeps of the runs whose end was handed on since the last call (`on_unit_event`,
    /// `apply`), in that order. The caller runs them before it hands the ends on.
    pub fn take_sweeps(&mut self) -> Vec<Sweep> {
        std::mem::take(&mut self.sweeps)
    }

    /// A run's end is handed on: it is forgotten, and its app's leftover scopes are to go.
    fn end_run(&mut self, unit: &str) {
        if let Some(run) = self.runs.remove(unit) {
            self.sweeps.push(Sweep {
                user: run.user,
                app_id: run.app_id,
            });
        }
    }

    /// The run is not followed any more (its start failed before anything ran).
    pub fn forget(&mut self, unit: &str) {
        self.runs.remove(unit);
    }

    /// The scope the run follows: `None` before one is attached and after it has gone. `Stop`
    /// and the kill do not use it (they name every scope of the app, T-435).
    pub fn scope_of(&self, unit: &str) -> Option<String> {
        self.runs
            .get(unit)
            .filter(|r| r.attached())
            .and_then(|r| r.scope.clone())
    }

    /// Has the run's unit ended while its scope still holds the run (its end is held)? Then the
    /// kill names the scopes only (`spawner::kill_command`, RUY-736).
    pub fn unit_ended(&self, unit: &str) -> bool {
        self.runs.get(unit).is_some_and(|r| r.held.is_some())
    }

    /// CPU time of the run so far, in nanoseconds: the unit's and every scope's together. A
    /// scope's last reading stays after it has gone. `None` when nothing was readable.
    pub fn cpu_nsec(&self, unit: &str) -> Option<u64> {
        self.runs.get(unit).and_then(Run::cpu)
    }

    /// An event of a unit on its way to the core. `Started` and the events of units without a
    /// live scope pass; the end of a unit whose scope still lives is kept (`None`) until `apply`
    /// sees the scope go.
    pub fn on_unit_event(&mut self, event: UnitEvent, now: Instant) -> Option<UnitEvent> {
        let unit = match &event {
            UnitEvent::Exited { unit, .. } | UnitEvent::ExecFailed { unit } => unit.clone(),
            UnitEvent::Started { .. } | UnitEvent::ChildStarted { .. } => return Some(event),
        };
        let Some(run) = self.runs.get_mut(&unit) else {
            return Some(event);
        };
        if run.attached() {
            run.held.get_or_insert(event);
            // The scope is looked at every second from now on, not every `WATCH_EVERY`: a `Stop`
            // that needed the kill (a Force quit) must end inside `LAUNCH_WAIT`, or the launch
            // after it answers "already-running".
            run.next_at = run.next_at.min(now + ATTACH_EVERY);
            return None;
        }
        self.end_run(&unit);
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
            // The attached scope by name (it is asked for even when the glob misses it), and
            // the pattern of the app's scopes for the others (a Steam client, a game's own).
            let Ok(pattern) = scope_pattern(&run.app_id) else {
                run.done = true;
                continue;
            };
            let mut names = vec![unit.clone()];
            names.extend(run.scope.clone());
            names.push(pattern);
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
            for name in names {
                if !by_user[at].names.contains(&name) {
                    by_user[at].names.push(name);
                }
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
                    run.end_kids(&mut released);
                    if let Some(event) = run.held.take() {
                        released.push(event);
                        self.end_run(&unit);
                    }
                }
                continue;
            };
            run.misses = 0;
            let unit_show = shows.iter().find(|s| s.id == unit);
            if let Some(cpu) = unit_show.and_then(|s| s.cpu_nsec) {
                run.unit_cpu = Some(run.unit_cpu.map_or(cpu, |old| old.max(cpu)));
            }
            let entered = unit_show.map_or(0, |s| s.entered);
            let own: Vec<&ShowUnit> = shows
                .iter()
                .filter(|s| is_app_scope(&run.app_id, &s.id) && s.alive())
                // A scope is made after the unit started. A second of slack: the timestamps
                // are whole seconds.
                .filter(|s| entered == 0 || s.entered + 1 >= entered)
                .collect();
            for scope in &own {
                if let Some(cpu) = scope.cpu_nsec {
                    let seen = run.scope_cpu.entry(scope.id.clone()).or_insert(cpu);
                    *seen = (*seen).max(cpu);
                }
            }
            match run.scope.clone() {
                None => {
                    let found = own
                        .iter()
                        .min_by(|a, b| (a.entered, &a.id).cmp(&(b.entered, &b.id)));
                    match found {
                        Some(scope) => {
                            eprintln!("ruya-session: {unit}: attached {}", scope.id);
                            run.scope = Some(scope.id.clone());
                            run.next_at = now + WATCH_EVERY;
                        }
                        None if now >= run.give_up_at => run.done = true,
                        None => run.next_at = now + ATTACH_EVERY,
                    }
                }
                Some(name) => {
                    let live = shows.iter().any(|s| s.id == name && s.alive());
                    if live {
                        run.next_at = now
                            + if run.held.is_some() {
                                ATTACH_EVERY
                            } else {
                                WATCH_EVERY
                            };
                    } else {
                        eprintln!(
                            "ruya-session: {unit}: scope gone, cpu {} ms, {} scopes counted",
                            run.cpu().unwrap_or(0) / 1_000_000,
                            run.scope_cpu.len()
                        );
                        run.done = true;
                    }
                }
            }
            if run.children && !run.done {
                if let Some(attached) = run.scope.clone() {
                    let live: BTreeSet<&str> = own.iter().map(|s| s.id.as_str()).collect();
                    run.sorted.retain(|scope, _| live.contains(scope.as_str()));
                    run.undecided
                        .retain(|scope, _| live.contains(scope.as_str()));
                    for scope in own.iter().filter(|s| s.id != attached) {
                        if run.sorted.contains_key(&scope.id) || run.probing.contains_key(&scope.id)
                        {
                            continue;
                        }
                        let frozen = matches!(scope.freezer_state.as_str(), "frozen" | "freezing");
                        run.probing
                            .insert(scope.id.clone(), (scope.entered, frozen));
                        self.probes.push(ProbeRequest {
                            unit: unit.clone(),
                            user: run.user.clone(),
                            scope: scope.id.clone(),
                        });
                    }
                    let mut ended = Vec::new();
                    for (appid, kid) in run.kids.iter_mut() {
                        kid.scopes.retain(|scope| live.contains(scope.as_str()));
                        if !kid.scopes.is_empty() {
                            kid.gone_since = None;
                            continue;
                        }
                        let since = *kid.gone_since.get_or_insert(now);
                        // A probe still out may be this game's next scope (an undecided scope is
                        // queued again above, so its probe is out too).
                        if run.probing.is_empty()
                            && now.saturating_duration_since(since) >= CHILD_GRACE
                        {
                            ended.push(appid.clone());
                        }
                    }
                    for appid in ended {
                        if let Some(kid) = run.kids.remove(&appid) {
                            eprintln!("ruya-session: {unit}: child {} has ended", kid.name);
                            released.push(child_end(&kid.name));
                        }
                    }
                    run.next_at = now + ATTACH_EVERY;
                }
            }
            if run.done {
                run.end_kids(&mut released);
                if let Some(event) = run.held.take() {
                    released.push(event);
                    self.end_run(&unit);
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
    ///
    /// It also answers `steam-probe` (RUY-1052): `games` is what the probe of each scope prints
    /// (a scope not in it prints nothing), `probed` the scopes it was asked about, in order.
    struct FakeManager {
        units: Vec<ShowUnit>,
        down: bool,
        asked: Vec<Query>,
        games: HashMap<String, String>,
        /// How many undecided verdicts a scope's probe gives before its answer.
        early: HashMap<String, u32>,
        probed: Vec<String>,
    }

    impl FakeManager {
        fn new(units: Vec<ShowUnit>) -> Self {
            FakeManager {
                units,
                down: false,
                asked: Vec::new(),
                games: HashMap::new(),
                early: HashMap::new(),
                probed: Vec::new(),
            }
        }

        /// A scope whose probe prints `appid` (a Steam game's scope).
        fn game(&mut self, show: ShowUnit, appid: &str) {
            self.games.insert(show.id.clone(), appid.to_owned());
            self.set(show);
        }

        fn gone(&mut self, name: &str) {
            self.units.retain(|u| u.id != name);
        }

        /// The scope's probe is undecided `times` times first (its sandbox has not started).
        fn early(&mut self, scope: &str, times: u32) {
            self.early.insert(scope.to_owned(), times);
        }

        fn probe(&mut self, r: &ProbeRequest) -> Verdict {
            self.probed.push(r.scope.clone());
            if let Some(n) = self.early.get_mut(&r.scope).filter(|n| **n > 0) {
                *n -= 1;
                return Verdict::Undecided;
            }
            match self.games.get(&r.scope) {
                Some(appid) => Verdict::Game(appid.clone()),
                None => Verdict::Parent,
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

    /// One round: plan, ask the manager, apply, and run the probes it asked for. Returns the
    /// released events and the children that started, in that order.
    fn round(scopes: &mut RunScopes, mgr: &mut FakeManager, now: Instant) -> Vec<UnitEvent> {
        let mut out = Vec::new();
        for q in scopes.plan(now) {
            let shows = mgr.show(&q);
            out.extend(scopes.apply(&q.user, shows.as_deref(), now));
            for r in scopes.take_probes() {
                let game = mgr.probe(&r);
                out.extend(scopes.probed(&r.unit, &r.scope, game));
            }
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
        // From now on the exact scope is asked too, and the pattern still (the app's other
        // scopes count for the CPU).
        let now = now + WATCH_EVERY;
        round(&mut scopes, &mut mgr, now);
        assert_eq!(
            mgr.asked.last().map(|q| q.names.clone()),
            Some(vec![
                UNIT.to_owned(),
                SCOPE.to_owned(),
                "app-flatpak-net.supertuxkart.SuperTuxKart-*.scope".to_owned()
            ])
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
        assert_eq!(scopes.on_unit_event(exited(0), now), Some(exited(0)));
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
    fn usage_counts_every_scope_of_the_app() {
        let now = t0();
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        let second = "app-flatpak-net.supertuxkart.SuperTuxKart-5000.scope";
        let third = "app-flatpak-net.supertuxkart.SuperTuxKart-6000.scope";
        let sibling = "app-flatpak-net.supertuxkart.SuperTuxKart-Extra-9.scope";
        let older = "app-flatpak-net.supertuxkart.SuperTuxKart-7.scope";
        let mut mgr = FakeManager::new(vec![
            unit_show(1000, Some(10)),
            scope_show(SCOPE, 1001, Some(100)),
            scope_show(sibling, 1001, Some(1_000_000)),
            scope_show("app-flatpak-org.other.Game-77.scope", 1001, Some(1_000_000)),
            // Made before the unit started: an older run's.
            scope_show(older, 900, Some(1_000_000)),
        ]);
        round(&mut scopes, &mut mgr, now);
        assert_eq!(scopes.scope_of(UNIT).as_deref(), Some(SCOPE));
        assert_eq!(scopes.cpu_nsec(UNIT), Some(110));
        // The portal's scope and a game's subsandbox appear later.
        mgr.set(scope_show(second, 1010, Some(1_000)));
        round(&mut scopes, &mut mgr, now + WATCH_EVERY);
        mgr.set(scope_show(third, 1020, Some(20_000)));
        mgr.set(scope_show(SCOPE, 1001, Some(200)));
        round(&mut scopes, &mut mgr, now + WATCH_EVERY * 2);
        assert_eq!(scopes.cpu_nsec(UNIT), Some(10 + 200 + 1_000 + 20_000));
        // A scope that ends keeps its last reading in the sum; the others go on.
        mgr.set(gone_scope(second));
        mgr.set(scope_show(third, 1020, Some(30_000)));
        round(&mut scopes, &mut mgr, now + WATCH_EVERY * 3);
        assert_eq!(scopes.cpu_nsec(UNIT), Some(10 + 200 + 1_000 + 30_000));
        assert_eq!(scopes.scope_of(UNIT).as_deref(), Some(SCOPE));
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
        assert_eq!(scopes.on_unit_event(exited(0), now), None);
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
    fn a_held_end_looks_at_the_scope_every_second_so_a_killed_stop_ends_before_the_launch_gives_up()
    {
        let now = t0();
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        let mut mgr = FakeManager::new(vec![unit_show(1000, None), scope_show(SCOPE, 1001, None)]);
        round(&mut scopes, &mut mgr, now);
        assert_eq!(scopes.scope_of(UNIT).as_deref(), Some(SCOPE));
        // `Stop` was ignored, the kill came a moment before the unit's end: the unit ends, the
        // scope goes with the kill. The scope was last looked at 2 s ago (every 5 s while the
        // app runs).
        let mut at = now + Duration::from_secs(2);
        assert_eq!(scopes.on_unit_event(exited(137), at), None);
        // The scope dies a little later than the unit ended: until then it is looked at every
        // second, not every 5 s.
        for _ in 0..2 {
            at += Duration::from_secs(1);
            let asked = mgr.asked.len();
            assert!(round(&mut scopes, &mut mgr, at).is_empty());
            assert_eq!(mgr.asked.len(), asked + 1, "looked at again a second later");
        }
        mgr.set(gone_scope(SCOPE));
        let gone_at = at;
        let released = loop {
            at += Duration::from_secs(1);
            let out = round(&mut scopes, &mut mgr, at);
            if !out.is_empty() {
                break out;
            }
            assert!(
                at - gone_at < crate::dbus::LAUNCH_WAIT,
                "the end must not outlast the wait of the Launch after the Stop"
            );
        };
        assert_eq!(released, [exited(137)]);
        assert!(
            at - gone_at <= ATTACH_EVERY * 2,
            "within a second or two, not the 5 s of WATCH_EVERY"
        );
        // The Launch that waited for it starts the new run, which attaches its own scope.
        let mut sweeps = scopes.take_sweeps();
        assert_eq!(sweeps.len(), 1);
        sweeps.clear();
        let fresh = "app-flatpak-net.supertuxkart.SuperTuxKart-4343.scope";
        scopes.begin(UNIT, USER, APP, at);
        mgr.set(unit_show(2000, None));
        mgr.set(scope_show(fresh, 2001, None));
        round(&mut scopes, &mut mgr, at);
        assert_eq!(scopes.scope_of(UNIT).as_deref(), Some(fresh));
    }

    #[test]
    fn a_manager_that_does_not_answer_keeps_the_end_held_for_a_while_then_gives_it() {
        let now = t0();
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        let mut mgr = FakeManager::new(vec![scope_show(SCOPE, 1001, None)]);
        round(&mut scopes, &mut mgr, now);
        assert_eq!(scopes.on_unit_event(exited(3), now), None);
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
        assert_eq!(scopes.on_unit_event(exited(0), now), Some(exited(0)));
        // Events of units it does not know, and a start, pass.
        let other = UnitEvent::Started {
            unit: "ruya-app-ruya-p1-org.x.Y.service".to_owned(),
        };
        assert_eq!(scopes.on_unit_event(other.clone(), now), Some(other));
    }

    fn sweep() -> Sweep {
        Sweep {
            user: USER.to_owned(),
            app_id: APP.to_owned(),
        }
    }

    #[test]
    fn the_end_of_a_run_sweeps_the_other_scopes_of_its_app() {
        // T-435, ACBR on the Dell: an Electron app's sandboxed zygote runs in a second scope the
        // Flatpak portal made. The run follows the first; when it ends the second must go too.
        const ZYGOTE: &str = "app-flatpak-net.supertuxkart.SuperTuxKart-17.scope";
        let now = t0();
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        let mut mgr = FakeManager::new(vec![
            unit_show(1000, None),
            scope_show(SCOPE, 1000, None),
            scope_show(ZYGOTE, 1001, None),
        ]);
        round(&mut scopes, &mut mgr, now);
        assert_eq!(scopes.scope_of(UNIT).as_deref(), Some(SCOPE));
        assert_eq!(scopes.on_unit_event(exited(139), now), None);
        assert!(
            scopes.take_sweeps().is_empty(),
            "nothing while the run lives"
        );
        // The browser's scope is gone, the zygote's still lives: the end is handed on with a
        // sweep of the app's scopes, once.
        mgr.set(gone_scope(SCOPE));
        assert_eq!(
            round(&mut scopes, &mut mgr, now + WATCH_EVERY),
            [exited(139)]
        );
        assert_eq!(scopes.take_sweeps(), [sweep()]);
        assert!(scopes.take_sweeps().is_empty());
        round(&mut scopes, &mut mgr, now + WATCH_EVERY * 2);
        assert!(scopes.take_sweeps().is_empty());
    }

    #[test]
    fn every_way_a_run_ends_sweeps_once() {
        let now = t0();
        // The unit ends with no scope attached (not held): swept as it passes.
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        assert_eq!(scopes.on_unit_event(exited(0), now), Some(exited(0)));
        assert_eq!(scopes.take_sweeps(), [sweep()]);
        // The scope went first; the unit's end then passes and sweeps.
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        let mut mgr = FakeManager::new(vec![scope_show(SCOPE, 1001, None)]);
        round(&mut scopes, &mut mgr, now);
        mgr.set(gone_scope(SCOPE));
        round(&mut scopes, &mut mgr, now + WATCH_EVERY);
        assert!(scopes.take_sweeps().is_empty(), "the unit still runs");
        assert_eq!(scopes.on_unit_event(exited(0), now), Some(exited(0)));
        assert_eq!(scopes.take_sweeps(), [sweep()]);
        // The manager stops answering: the held end is given up with a sweep.
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        let mut mgr = FakeManager::new(vec![scope_show(SCOPE, 1001, None)]);
        round(&mut scopes, &mut mgr, now);
        assert_eq!(scopes.on_unit_event(exited(0), now), None);
        mgr.down = true;
        let mut at = now;
        for _ in 0..MAX_MISSES {
            at += WATCH_EVERY;
            round(&mut scopes, &mut mgr, at);
        }
        assert_eq!(scopes.take_sweeps(), [sweep()]);
        // A start that failed before anything ran, and units it does not know: no sweep.
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        scopes.forget(UNIT);
        let other = UnitEvent::Exited {
            unit: "ruya-app-ruya-p1-org.x.Y.service".to_owned(),
            code: 0,
            signaled: false,
        };
        assert_eq!(scopes.on_unit_event(other.clone(), now), Some(other));
        assert!(scopes.take_sweeps().is_empty());
    }

    #[test]
    fn stop_also_stops_the_scope() {
        use crate::spawner::control_command;
        // Every scope of the app the manager lists, by exact name (`app_scopes`), next to the
        // unit, not only the one the run attached (T-435: an Electron app's zygote may be it).
        const ZYGOTE: &str = "app-flatpak-net.supertuxkart.SuperTuxKart-17.scope";
        let scopes = [ZYGOTE.to_owned(), SCOPE.to_owned()];
        let stop =
            control_command(USER, &["stop", "--no-block"], UNIT, APP, &scopes).expect("stop");
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
                ZYGOTE,
                SCOPE,
            ]
        );
        // The kill of an overdue Stop reaches them too; with none listed, the unit alone.
        let kill = control_command(
            USER,
            &["kill", "--signal=SIGKILL", "--kill-whom=all"],
            UNIT,
            APP,
            &scopes,
        )
        .expect("kill");
        assert_eq!(&kill[kill.len() - 3..], [UNIT, ZYGOTE, SCOPE]);
        let bare = control_command(USER, &["stop"], UNIT, APP, &[]).expect("unit only");
        assert_eq!(bare.last().map(String::as_str), Some(UNIT));
        // Nothing foreign gets through.
        assert!(control_command(USER, &["stop"], UNIT, "../x", &[]).is_err());
        assert!(control_command(USER, &["stop"], UNIT, "org.x.*", &[]).is_err());
        assert!(control_command("root", &["stop"], UNIT, APP, &[]).is_err());
        let other = ["app-flatpak-org.other.Game-1.scope".to_owned()];
        assert!(control_command(USER, &["stop"], UNIT, APP, &other).is_err());
    }

    #[test]
    fn the_kill_of_a_run_whose_unit_ended_names_only_its_scopes() {
        use crate::spawner::{kill_command, KILL_VERB};
        // The Dell (2026-11-15, ACBR and SeriousSamClassic): the unit died of the stop's SIGTERM
        // and its end was held for the live scope; the kill named the unit too and systemctl
        // answered "Unit ... not loaded" (exit 1), so every such kill read as a failure. RUY-736:
        // while the end is held, the kill names the scopes alone.
        let now = t0();
        let mut scopes = RunScopes::new();
        scopes.begin(UNIT, USER, APP, now);
        let mut mgr = FakeManager::new(vec![unit_show(1000, None), scope_show(SCOPE, 1001, None)]);
        round(&mut scopes, &mut mgr, now);
        assert!(!scopes.unit_ended(UNIT), "the unit still runs");
        let listed = [SCOPE.to_owned()];
        let live = kill_command(USER, UNIT, APP, &listed, scopes.unit_ended(UNIT)).expect("kill");
        assert_eq!(
            &live[live.len() - 2..],
            [UNIT, SCOPE],
            "both while the unit lives"
        );
        assert!(live.windows(3).any(|w| w == KILL_VERB));
        // The unit ends on the SIGTERM; the scope lives on and holds the run.
        assert_eq!(scopes.on_unit_event(exited(143), now), None);
        assert!(scopes.unit_ended(UNIT));
        let held = kill_command(USER, UNIT, APP, &listed, scopes.unit_ended(UNIT)).expect("kill");
        assert!(
            !held.iter().any(|a| a == UNIT),
            "the gone unit is not named"
        );
        assert_eq!(held.last().map(String::as_str), Some(SCOPE));
        assert!(held.windows(3).any(|w| w == KILL_VERB));
        // With no scope listed (a listing that failed) the unit is named anyway: never no target.
        let bare = kill_command(USER, UNIT, APP, &[], true).expect("kill");
        assert_eq!(bare.last().map(String::as_str), Some(UNIT));
        // A run that is not followed (unknown unit) has not "ended".
        assert!(!scopes.unit_ended("ruya-app-ruya-p1-org.x.Y.service"));
        // Nothing foreign gets through.
        let other = ["app-flatpak-org.other.Game-1.scope".to_owned()];
        assert!(kill_command(USER, UNIT, APP, &other, true).is_err());
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

    // Steam's games as child instances (ADR-041, RUY-1052).

    const STEAM: &str = "com.valvesoftware.Steam";
    const STEAM_UNIT: &str = "ruya-app-ruya-p1-com.valvesoftware.Steam.service";
    /// Steam's own sandbox (the run attaches it), its web helper's client scope, a game's scope,
    /// the same game's next scope (a launcher handing over), and UpdatingDRM's short scope.
    const ATTACHED: &str = "app-flatpak-com.valvesoftware.Steam-2192235278.scope";
    const CLIENT: &str = "app-flatpak-com.valvesoftware.Steam-3327064059.scope";
    const GAME: &str = "app-flatpak-com.valvesoftware.Steam-1623993748.scope";
    const GAME_NEXT: &str = "app-flatpak-com.valvesoftware.Steam-1700000000.scope";
    const DRM: &str = "app-flatpak-com.valvesoftware.Steam-1500000000.scope";

    fn child() -> String {
        child_name(STEAM_UNIT, "70")
    }

    fn child_started(started: i64, frozen: bool) -> UnitEvent {
        UnitEvent::ChildStarted {
            parent: STEAM_UNIT.to_owned(),
            child: child(),
            appid: "70".to_owned(),
            started,
            frozen,
        }
    }

    /// Steam's run with its sandbox attached and its client scope probed (Steam's own).
    fn steam(now: Instant) -> (RunScopes, FakeManager) {
        let mut scopes = RunScopes::new();
        scopes.begin(STEAM_UNIT, USER, STEAM, now);
        scopes.follow_children(STEAM_UNIT);
        let mut mgr = FakeManager::new(vec![
            scope_show(STEAM_UNIT, 1000, None),
            scope_show(ATTACHED, 1001, None),
            scope_show(CLIENT, 1005, None),
        ]);
        assert!(round(&mut scopes, &mut mgr, now).is_empty());
        assert_eq!(scopes.scope_of(STEAM_UNIT).as_deref(), Some(ATTACHED));
        (scopes, mgr)
    }

    #[test]
    fn a_game_scope_becomes_a_child_and_only_new_scopes_but_the_attached_one_are_probed() {
        let now = t0();
        let (mut scopes, mut mgr) = steam(now);
        assert_eq!(mgr.probed, [CLIENT], "never the attached scope");
        mgr.game(scope_show(GAME, 1100, None), "70");
        // Looked at every second, not every WATCH_EVERY.
        let now = now + ATTACH_EVERY;
        assert_eq!(
            round(&mut scopes, &mut mgr, now),
            [child_started(1100, false)]
        );
        assert_eq!(mgr.probed, [CLIENT, GAME]);
        // Probed once: later rounds ask nothing more and start nothing.
        for i in 1..5 {
            assert!(round(&mut scopes, &mut mgr, now + ATTACH_EVERY * i).is_empty());
        }
        assert_eq!(mgr.probed, [CLIENT, GAME]);
        // What a child's control and InstanceOfPid reach: its own scope only.
        assert_eq!(
            scopes.child(&child()),
            Some(ChildScopes {
                user: USER.to_owned(),
                app_id: STEAM.to_owned(),
                scopes: vec![GAME.to_owned()]
            })
        );
        assert_eq!(scopes.child_of_scope(USER, GAME), Some(child()));
        assert_eq!(scopes.child_of_scope(USER, ATTACHED), None);
        assert_eq!(scopes.child_of_scope(USER, CLIENT), None);
        assert_eq!(scopes.child_of_scope("ruya-p2", GAME), None);
        assert_eq!(scopes.child_scopes(STEAM_UNIT), [GAME]);
    }

    #[test]
    fn a_run_without_children_probes_nothing() {
        let now = t0();
        let mut scopes = RunScopes::new();
        scopes.begin(STEAM_UNIT, USER, STEAM, now);
        let mut mgr = FakeManager::new(vec![
            scope_show(STEAM_UNIT, 1000, None),
            scope_show(ATTACHED, 1001, None),
        ]);
        mgr.game(scope_show(GAME, 1100, None), "70");
        round(&mut scopes, &mut mgr, now);
        round(&mut scopes, &mut mgr, now + WATCH_EVERY);
        assert!(mgr.probed.is_empty());
        assert_eq!(scopes.child(&child()), None);
    }

    #[test]
    fn a_drm_scope_then_the_game_scope_make_one_child_and_no_early_end() {
        let now = t0();
        let (mut scopes, mut mgr) = steam(now);
        // UpdatingDRM: its probe prints nothing (SteamGameId without SteamAppId), Steam's.
        mgr.set(scope_show(DRM, 1050, None));
        let mut events = round(&mut scopes, &mut mgr, now + ATTACH_EVERY);
        mgr.gone(DRM);
        // The game about 9 s after the DRM step.
        for i in 2..11 {
            events.extend(round(&mut scopes, &mut mgr, now + ATTACH_EVERY * i));
        }
        mgr.game(scope_show(GAME, 1060, None), "70");
        for i in 11..20 {
            events.extend(round(&mut scopes, &mut mgr, now + ATTACH_EVERY * i));
        }
        assert_eq!(events, [child_started(1060, false)]);
        assert_eq!(mgr.probed, [CLIENT, DRM, GAME]);
    }

    #[test]
    fn a_child_ends_when_none_of_its_scopes_has_existed_for_three_seconds() {
        let now = t0();
        let (mut scopes, mut mgr) = steam(now);
        mgr.game(scope_show(GAME, 1100, None), "70");
        let t = now + ATTACH_EVERY;
        assert_eq!(round(&mut scopes, &mut mgr, t).len(), 1);
        // A launcher hands over: its scope goes, the game's own scope comes within the grace.
        mgr.gone(GAME);
        assert!(round(&mut scopes, &mut mgr, t + ATTACH_EVERY).is_empty());
        mgr.game(scope_show(GAME_NEXT, 1103, None), "70");
        assert!(round(&mut scopes, &mut mgr, t + ATTACH_EVERY * 3).is_empty());
        assert_eq!(scopes.child_of_scope(USER, GAME_NEXT), Some(child()));
        assert!(round(&mut scopes, &mut mgr, t + ATTACH_EVERY * 6).is_empty());
        // The game ends: its last scope gone, the child ends 3 s later and not before.
        mgr.gone(GAME_NEXT);
        let gone = t + ATTACH_EVERY * 7;
        assert!(round(&mut scopes, &mut mgr, gone).is_empty());
        assert!(round(&mut scopes, &mut mgr, gone + ATTACH_EVERY).is_empty());
        assert!(round(&mut scopes, &mut mgr, gone + ATTACH_EVERY * 2).is_empty());
        assert_eq!(
            round(&mut scopes, &mut mgr, gone + CHILD_GRACE),
            [UnitEvent::Exited {
                unit: child(),
                code: 0,
                signaled: false
            }]
        );
        assert_eq!(scopes.child(&child()), None);
        // Steam runs on.
        assert_eq!(scopes.scope_of(STEAM_UNIT).as_deref(), Some(ATTACHED));
    }

    #[test]
    fn the_end_of_steam_ends_its_children_before_its_own_end_is_handed_on() {
        let now = t0();
        let (mut scopes, mut mgr) = steam(now);
        mgr.game(scope_show(GAME, 1100, None), "70");
        assert_eq!(round(&mut scopes, &mut mgr, now + ATTACH_EVERY).len(), 1);
        let end = UnitEvent::Exited {
            unit: STEAM_UNIT.to_owned(),
            code: 0,
            signaled: false,
        };
        assert_eq!(
            scopes.on_unit_event(end.clone(), now),
            None,
            "held for the scope"
        );
        mgr.gone(ATTACHED);
        assert_eq!(
            round(&mut scopes, &mut mgr, now + ATTACH_EVERY * 2),
            [
                UnitEvent::Exited {
                    unit: child(),
                    code: 0,
                    signaled: false
                },
                end
            ]
        );
        assert_eq!(scopes.child(&child()), None);
    }

    #[test]
    fn adoption_probes_the_game_scopes_that_run_already_and_rebuilds_the_child() {
        let now = t0();
        let mut scopes = RunScopes::new();
        scopes.begin(STEAM_UNIT, USER, STEAM, now);
        scopes.follow_children(STEAM_UNIT);
        let mut game = scope_show(GAME, 1500, None);
        game.freezer_state = "frozen".to_owned();
        let mut mgr = FakeManager::new(vec![
            scope_show(STEAM_UNIT, 1000, None),
            scope_show(ATTACHED, 1001, None),
        ]);
        mgr.game(game, "70");
        // The first look after the restart attaches Steam's sandbox and probes the game's.
        assert_eq!(
            round(&mut scopes, &mut mgr, now),
            [child_started(1500, true)]
        );
        assert_eq!(scopes.scope_of(STEAM_UNIT).as_deref(), Some(ATTACHED));
        assert_eq!(mgr.probed, [GAME]);
    }

    #[test]
    fn a_game_scope_probed_before_its_sandbox_started_is_probed_again_and_becomes_the_child() {
        let now = t0();
        let (mut scopes, mut mgr) = steam(now);
        mgr.game(scope_show(GAME, 1100, None), "70");
        mgr.early(GAME, 2);
        let mut events = Vec::new();
        for i in 1..6 {
            events.extend(round(&mut scopes, &mut mgr, now + ATTACH_EVERY * i));
        }
        assert_eq!(
            events,
            [child_started(1100, false)],
            "one child, after two undecided looks"
        );
        assert_eq!(mgr.probed, [CLIENT, GAME, GAME, GAME]);
    }

    #[test]
    fn a_scope_that_stays_undecided_is_probed_at_most_max_probes_times_then_is_steams() {
        let now = t0();
        let (mut scopes, mut mgr) = steam(now);
        mgr.set(scope_show(DRM, 1050, None));
        mgr.early(DRM, 1000);
        for i in 1..20 {
            assert!(round(&mut scopes, &mut mgr, now + ATTACH_EVERY * i).is_empty());
        }
        let asked = mgr.probed.iter().filter(|s| *s == DRM).count();
        assert_eq!(asked, MAX_PROBES as usize);
        // A scope whose sandbox is there without the ids is Steam's at the first probe.
        mgr.set(scope_show(GAME, 1100, None));
        round(&mut scopes, &mut mgr, now + ATTACH_EVERY * 20);
        round(&mut scopes, &mut mgr, now + ATTACH_EVERY * 21);
        assert_eq!(mgr.probed.iter().filter(|s| *s == GAME).count(), 1);
    }

    #[test]
    fn an_undecided_scope_holds_the_end_of_a_child_whose_scope_went() {
        let now = t0();
        let (mut scopes, mut mgr) = steam(now);
        mgr.game(scope_show(GAME, 1100, None), "70");
        assert_eq!(round(&mut scopes, &mut mgr, now + ATTACH_EVERY).len(), 1);
        // The launcher's scope goes, the game's next scope comes and is undecided for a while.
        mgr.gone(GAME);
        mgr.game(scope_show(GAME_NEXT, 1102, None), "70");
        mgr.early(GAME_NEXT, 4);
        let mut events = Vec::new();
        for i in 2..10 {
            events.extend(round(&mut scopes, &mut mgr, now + ATTACH_EVERY * i));
        }
        assert!(
            events.is_empty(),
            "no end while the next scope is undecided: {events:?}"
        );
        assert_eq!(scopes.child_of_scope(USER, GAME_NEXT), Some(child()));
    }
}
