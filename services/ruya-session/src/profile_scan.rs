//! When ruya-session runs a profile's Steam reader and what it tells Library1 (ADR-045 with the
//! lead's clarification of 2026-11-22, RUY-1056). Pure; the adapter (`library_feed.rs`, Linux)
//! feeds it `Trigger`s and carries out its `Action`s in order.
//!
//! ruya-library may not follow Profiles1, so this service tells it the signed-in profile
//! (`SetActiveProfile`) on every change, before any scan, and again when Library1's bus name gets
//! a new owner (a restarted ruya-library starts with nobody active). The reader
//! (`spawner::profile_scan_command`) runs:
//!   (a) when the active profile changes to a profile (not on a sign-out);
//!   (b) when Library1's name gets a new owner, for the active profile, so its items come back
//!       without a sign-in;
//!   (c) when a profile's Steam instance ends (it may have installed or removed games);
//!   (d) on `Library1.ProfileScanWanted(profile)`, which `Rescan` sends.
//! At most one reader per profile runs at a time; a trigger while it runs asks for one more run
//! after it (so a change during the run is not lost), never for a second one beside it.

use std::collections::BTreeSet;

use ruya_ids::{parse_item, valid_profile_id, ItemId};

use crate::steam_tool::STEAM_APP_ID;

/// Something that happened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Trigger {
    /// Profiles1's ActiveProfile was read as this value ("" = nobody); sent on every change.
    Active(String),
    /// Library1's bus name has this new owner ("" = it went away).
    LibraryOwner(String),
    /// An instance of this profile ended; `item` is its Library1 item id.
    Ended { profile: String, item: String },
    /// `Library1.ProfileScanWanted(profile)`.
    Wanted(String),
    /// The reader of this profile finished (its result already handed on).
    Done(String),
}

/// What the adapter does, in this order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// `Library1.SetActiveProfile(profile)`.
    SetActive(String),
    /// Run the profile's reader and `PutProfileItems` its output; then `Trigger::Done`.
    Scan(String),
}

/// Is `item` the profile's Steam client itself (not one of its games, ADR-041)?
pub fn is_steam_client(item: &str) -> bool {
    parse_item(item) == Some(ItemId::Flatpak(STEAM_APP_ID))
}

#[derive(Debug, Default)]
pub struct Planner {
    /// The signed-in profile as last read; `None` until the first read.
    active: Option<String>,
    /// Profiles whose reader runs.
    running: BTreeSet<String>,
    /// Profiles asked for again while their reader ran.
    again: BTreeSet<String>,
}

impl Planner {
    pub fn new() -> Self {
        Self::default()
    }

    /// The actions `trigger` asks for.
    pub fn on(&mut self, trigger: Trigger) -> Vec<Action> {
        match trigger {
            Trigger::Active(profile) => {
                if self.active.as_deref() == Some(profile.as_str()) {
                    return Vec::new();
                }
                self.active = Some(profile.clone());
                self.tell_active()
            }
            Trigger::LibraryOwner(owner) => {
                if owner.is_empty() {
                    return Vec::new();
                }
                self.tell_active()
            }
            Trigger::Ended { profile, item } => {
                if is_steam_client(&item) {
                    self.scan(&profile)
                } else {
                    Vec::new()
                }
            }
            Trigger::Wanted(profile) => self.scan(&profile),
            Trigger::Done(profile) => {
                self.running.remove(&profile);
                if self.again.remove(&profile) {
                    self.scan(&profile)
                } else {
                    Vec::new()
                }
            }
        }
    }

    /// `SetActiveProfile` with the active profile, then its scan when it is a profile. Nothing
    /// while the active profile has never been read.
    fn tell_active(&mut self) -> Vec<Action> {
        let Some(active) = self.active.clone() else {
            return Vec::new();
        };
        let mut actions = vec![Action::SetActive(active.clone())];
        if !active.is_empty() {
            actions.extend(self.scan(&active));
        }
        actions
    }

    /// A scan of `profile`, unless one runs (then one more after it). Not a profile id: nothing.
    fn scan(&mut self, profile: &str) -> Vec<Action> {
        if !valid_profile_id(profile) {
            return Vec::new();
        }
        if self.running.contains(profile) {
            self.again.insert(profile.to_owned());
            return Vec::new();
        }
        self.running.insert(profile.to_owned());
        vec![Action::Scan(profile.to_owned())]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn active(p: &str) -> Trigger {
        Trigger::Active(p.into())
    }
    fn set(p: &str) -> Action {
        Action::SetActive(p.into())
    }
    fn scan(p: &str) -> Action {
        Action::Scan(p.into())
    }
    fn ended(p: &str, item: &str) -> Trigger {
        Trigger::Ended {
            profile: p.into(),
            item: item.into(),
        }
    }

    #[test]
    fn a_sign_in_tells_library_first_then_scans() {
        let mut p = Planner::new();
        assert_eq!(p.on(active("p1")), [set("p1"), scan("p1")]);
        assert_eq!(p.on(active("p1")), [], "the same value again");
        p.on(Trigger::Done("p1".into()));
        assert_eq!(p.on(active("p2")), [set("p2"), scan("p2")], "a switch");
    }

    #[test]
    fn a_sign_out_tells_library_and_scans_nothing() {
        let mut p = Planner::new();
        assert_eq!(p.on(active("")), [set("")], "nobody at start");
        p.on(active("p1"));
        assert_eq!(p.on(active("")), [set("")]);
    }

    #[test]
    fn a_new_library_owner_hears_the_active_profile_again_and_gets_its_items() {
        let mut p = Planner::new();
        assert_eq!(
            p.on(Trigger::LibraryOwner(":1.9".into())),
            [],
            "nothing read yet"
        );
        p.on(active("p1"));
        p.on(Trigger::Done("p1".into()));
        assert_eq!(
            p.on(Trigger::LibraryOwner(":1.42".into())),
            [set("p1"), scan("p1")]
        );
        assert_eq!(p.on(Trigger::LibraryOwner(String::new())), [], "it left");
        p.on(Trigger::Done("p1".into()));
        p.on(active(""));
        assert_eq!(p.on(Trigger::LibraryOwner(":1.50".into())), [set("")]);
    }

    #[test]
    fn the_end_of_a_profiles_steam_client_scans_that_profile() {
        let mut p = Planner::new();
        p.on(active("p1"));
        p.on(Trigger::Done("p1".into()));
        let steam = "flatpak:com.valvesoftware.Steam";
        assert_eq!(p.on(ended("p2", steam)), [scan("p2")], "any profile's");
        assert_eq!(p.on(ended("p1", "steam:70")), [], "a game is not Steam");
        assert_eq!(p.on(ended("p1", "flatpak:org.example.App")), []);
        assert_eq!(p.on(ended("p1", steam)), [scan("p1")]);
    }

    #[test]
    fn profile_scan_wanted_scans_a_valid_profile() {
        let mut p = Planner::new();
        assert_eq!(p.on(Trigger::Wanted("p3".into())), [scan("p3")]);
        assert_eq!(p.on(Trigger::Wanted("../x".into())), []);
        assert_eq!(p.on(Trigger::Wanted(String::new())), []);
    }

    #[test]
    fn at_most_one_scan_per_profile_runs_and_a_trigger_meanwhile_runs_one_more() {
        let mut p = Planner::new();
        assert_eq!(p.on(active("p1")), [set("p1"), scan("p1")]);
        assert_eq!(p.on(Trigger::Wanted("p1".into())), [], "p1 runs");
        assert_eq!(
            p.on(Trigger::Wanted("p1".into())),
            [],
            "still one more only"
        );
        assert_eq!(
            p.on(Trigger::Wanted("p2".into())),
            [scan("p2")],
            "another profile is not held up"
        );
        assert_eq!(
            p.on(Trigger::Done("p1".into())),
            [scan("p1")],
            "the one more"
        );
        assert_eq!(p.on(Trigger::Done("p1".into())), [], "and no more");
        assert_eq!(p.on(Trigger::Wanted("p1".into())), [scan("p1")]);
    }

    #[test]
    fn the_steam_client_is_told_apart_from_its_games() {
        assert!(is_steam_client("flatpak:com.valvesoftware.Steam"));
        assert!(!is_steam_client("steam:70"));
        assert!(!is_steam_client("flatpak:com.valvesoftware.SteamLink"));
        assert!(!is_steam_client(""));
    }
}
