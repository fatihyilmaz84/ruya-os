//! Which runner a package gets (05 §6.2): one pure function the developer tool (`ruya-pack`, the
//! dry run) and the launcher (RUY-101) both call, so the answer a developer sees is the answer the
//! console computes.
//!
//! Inputs are the manifest's components, the runners the OS provides (family and version) and the
//! player's per-game override. Nothing is read from disk; versions compare as numbers.
//!
//! ```
//! use ruya_play_format::resolve::{resolve, Chosen, Override, SystemRunner};
//! # use ruya_play_format::manifest::{Bundled, Component};
//! let wine = Component {
//!     id: "wine".into(), kind: "wine".into(), source: "newest".into(),
//!     min: Some("9.0".into()), tested: None, max_major: None,
//!     bundled: Some(Bundled { path: "components/wine".into(), version: "9.20".into(),
//!         licence: "LGPL-2.1-or-later".into(), source_url: None }),
//! };
//! let system = [SystemRunner::new("wine", "10.2")];
//! let r = resolve(&[wine], &system, Override::PackageDefault);
//! assert!(matches!(r.components[0].outcome, Ok(Chosen::System { .. })));
//! ```

use crate::manifest::Component;
use std::cmp::Ordering;

/// A runner the OS provides.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SystemRunner {
    /// `wine`, `proton-ge`, `proton`, or an emulator or engine id.
    pub family: String,
    /// Its version text (`10.2`, `GE-Proton10-9`).
    pub version: String,
}

impl SystemRunner {
    /// A runner of `family` at `version`.
    pub fn new(family: &str, version: &str) -> Self {
        SystemRunner {
            family: family.to_string(),
            version: version.to_string(),
        }
    }
}

/// The player's choice for a game (Options, Compatibility).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Override {
    /// What the package says.
    PackageDefault,
    /// The shipped copy, when the package has one.
    Bundled,
    /// The OS's runner, when it satisfies `min` and `max_major`.
    System,
}

/// The runner a component gets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Chosen {
    /// The copy in the package.
    Bundled {
        /// Its version.
        version: String,
    },
    /// The OS's runner.
    System {
        /// Its family.
        family: String,
        /// Its version.
        version: String,
    },
}

/// Why a component has no runner.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Unresolved {
    /// The OS has no runner of the family; the installer offers to fetch one (online) or refuses.
    NoSystemRunner {
        /// The families that were looked for.
        families: Vec<String>,
    },
    /// The OS's runner is older than `min`.
    SystemTooOld {
        /// What the OS has.
        have: String,
        /// What the package needs.
        min: String,
    },
    /// The OS's runner has a higher major version than `max_major` allows.
    SystemTooNew {
        /// What the OS has.
        have: String,
        /// The fence.
        max_major: u64,
    },
    /// The source needs a bundled copy and the package has none.
    NoBundled,
}

impl Unresolved {
    /// A stable dotted code.
    pub fn code(&self) -> &'static str {
        match self {
            Unresolved::NoSystemRunner { .. } => "resolve.no_system_runner",
            Unresolved::SystemTooOld { .. } => "resolve.system_too_old",
            Unresolved::SystemTooNew { .. } => "resolve.system_too_new",
            Unresolved::NoBundled => "resolve.no_bundled",
        }
    }

    /// English text naming the cause.
    pub fn message(&self) -> String {
        match self {
            Unresolved::NoSystemRunner { families } => format!(
                "The OS has no runner of family {} and the package cannot use a bundled one here.",
                families.join(" or ")
            ),
            Unresolved::SystemTooOld { have, min } => {
                format!("The OS runner is {have}, older than the required {min}.")
            }
            Unresolved::SystemTooNew { have, max_major } => {
                format!("The OS runner is {have}, a major version above the allowed {max_major}.")
            }
            Unresolved::NoBundled => "The package has no bundled copy to fall back on.".into(),
        }
    }
}

/// Something worth telling the developer or the player that is not a failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Note {
    /// The override asked for the bundled copy, but there is none: the package default applied.
    OverrideBundledUnavailable,
    /// The override asked for the system runner, but it does not satisfy `min` and `max_major`:
    /// the package default applied.
    OverrideSystemUnavailable,
    /// The system runner was skipped because of `max_major` and the bundled copy runs instead.
    FencedByMaxMajor {
        /// The runner that was skipped.
        have: String,
    },
}

/// The outcome for one component.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ComponentResolution {
    /// The component's local id.
    pub id: String,
    /// The runner, or why there is none.
    pub outcome: Result<Chosen, Unresolved>,
    /// The version the developer tested, for "Tested with 9.20; running with 10.2".
    pub tested: Option<String>,
    /// Facts about how it was decided.
    pub notes: Vec<Note>,
}

/// The outcome for all components, in manifest order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolution {
    /// One entry per component.
    pub components: Vec<ComponentResolution>,
}

impl Resolution {
    /// True when every component has a runner.
    pub fn ok(&self) -> bool {
        self.components.iter().all(|c| c.outcome.is_ok())
    }
}

/// The numbers in a version text: every run of digits, in order (`GE-Proton10-9` is 10, 9).
fn numbers(v: &str) -> Vec<u64> {
    let mut out = Vec::new();
    let mut cur: Option<u64> = None;
    for b in v.bytes() {
        if b.is_ascii_digit() {
            cur = Some(
                cur.unwrap_or(0)
                    .saturating_mul(10)
                    .saturating_add(u64::from(b - b'0')),
            );
        } else if let Some(n) = cur.take() {
            out.push(n);
        }
    }
    out.extend(cur);
    out
}

/// Compare two versions numerically, segment by segment; a missing segment is 0.
pub fn compare_versions(a: &str, b: &str) -> Ordering {
    let (x, y) = (numbers(a), numbers(b));
    for i in 0..x.len().max(y.len()) {
        let o = x.get(i).unwrap_or(&0).cmp(y.get(i).unwrap_or(&0));
        if o != Ordering::Equal {
            return o;
        }
    }
    Ordering::Equal
}

/// The first number of a version (`10.2` is 10); 0 when there is none.
pub fn major_of(v: &str) -> u64 {
    numbers(v).first().copied().unwrap_or(0)
}

/// The runner families whose system runners may serve `c`. GE-Proton is the OS's Proton (ADR-025),
/// so a `proton` component can use a `proton-ge` runner; emulators and engines are one family per
/// component id. Versions are only compared inside one family: the newest runner of the first
/// family that has any wins.
pub fn families_of(c: &Component) -> Vec<String> {
    match c.kind.as_str() {
        "wine" => vec!["wine".into()],
        "proton" => vec!["proton-ge".into(), "proton".into()],
        _ => vec![c.id.clone()],
    }
}

enum System {
    Usable(SystemRunner),
    Unusable(Unresolved),
}

fn system_for(c: &Component, runners: &[SystemRunner]) -> System {
    let families = families_of(c);
    for family in &families {
        let best = runners
            .iter()
            .filter(|r| &r.family == family)
            .max_by(|a, b| compare_versions(&a.version, &b.version));
        let Some(r) = best else { continue };
        if let Some(min) = &c.min {
            if compare_versions(&r.version, min) == Ordering::Less {
                return System::Unusable(Unresolved::SystemTooOld {
                    have: r.version.clone(),
                    min: min.clone(),
                });
            }
        }
        if let Some(max) = c.max_major {
            if major_of(&r.version) > max {
                return System::Unusable(Unresolved::SystemTooNew {
                    have: r.version.clone(),
                    max_major: max,
                });
            }
        }
        return System::Usable(r.clone());
    }
    System::Unusable(Unresolved::NoSystemRunner { families })
}

fn bundled_of(c: &Component) -> Option<Chosen> {
    c.bundled.as_ref().map(|b| Chosen::Bundled {
        version: b.version.clone(),
    })
}

fn system_chosen(r: &SystemRunner) -> Chosen {
    Chosen::System {
        family: r.family.clone(),
        version: r.version.clone(),
    }
}

/// Decide the runner of one component.
pub fn resolve_one(
    c: &Component,
    system_runners: &[SystemRunner],
    over: Override,
) -> ComponentResolution {
    let system = system_for(c, system_runners);
    let mut notes = Vec::new();
    let mut over = over;
    match (over, &system, bundled_of(c)) {
        (Override::Bundled, _, None) => {
            notes.push(Note::OverrideBundledUnavailable);
            over = Override::PackageDefault;
        }
        (Override::System, System::Unusable(_), _) => {
            notes.push(Note::OverrideSystemUnavailable);
            over = Override::PackageDefault;
        }
        _ => {}
    }
    let bundled = bundled_of(c);
    let outcome = match (over, &system) {
        (Override::Bundled, _) => bundled.ok_or(Unresolved::NoBundled),
        (Override::System, System::Usable(r)) => Ok(system_chosen(r)),
        _ => by_source(c, &system, bundled, &mut notes),
    };
    ComponentResolution {
        id: c.id.clone(),
        outcome,
        tested: c.tested.clone(),
        notes,
    }
}

fn by_source(
    c: &Component,
    system: &System,
    bundled: Option<Chosen>,
    notes: &mut Vec<Note>,
) -> Result<Chosen, Unresolved> {
    let fence_note = |notes: &mut Vec<Note>| {
        if let System::Unusable(Unresolved::SystemTooNew { have, .. }) = system {
            notes.push(Note::FencedByMaxMajor { have: have.clone() });
        }
    };
    match c.source.as_str() {
        "bundled" | "prefer-bundled" => bundled.ok_or(Unresolved::NoBundled),
        "system" => match system {
            System::Usable(r) => Ok(system_chosen(r)),
            System::Unusable(why) => Err(why.clone()),
        },
        "prefer-system" => match (system, bundled) {
            (System::Usable(r), _) => Ok(system_chosen(r)),
            (System::Unusable(_), Some(b)) => {
                fence_note(notes);
                Ok(b)
            }
            (System::Unusable(why), None) => Err(why.clone()),
        },
        // "newest": the higher version wins; a tie goes to the bundled copy.
        _ => match (system, bundled) {
            (System::Usable(r), Some(Chosen::Bundled { version })) => {
                if compare_versions(&r.version, &version) == Ordering::Greater {
                    Ok(system_chosen(r))
                } else {
                    Ok(Chosen::Bundled { version })
                }
            }
            (System::Usable(r), _) => Ok(system_chosen(r)),
            (System::Unusable(_), Some(b)) => {
                fence_note(notes);
                Ok(b)
            }
            (System::Unusable(why), None) => Err(why.clone()),
        },
    }
}

/// Decide the runner of every component (05 §6.2).
pub fn resolve(
    components: &[Component],
    system_runners: &[SystemRunner],
    over: Override,
) -> Resolution {
    Resolution {
        components: components
            .iter()
            .map(|c| resolve_one(c, system_runners, over))
            .collect(),
    }
}
