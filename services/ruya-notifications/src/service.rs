//! The service's rules above the history: which profiles exist (Profiles1's kept profiles and
//! live guests), whose settings the properties show (the active profile's), what a source that
//! is off keeps, and that every change is written to the store at once. Pure: the profile list,
//! the active profile and the time come in from the adapter.

use std::collections::{BTreeMap, BTreeSet};

use crate::history::{Event, History, Item, NewItem, Status};
use crate::settings::{Change, Settings};
use crate::store::{Persist, ProfileData};
use ruya_ids::valid_profile_id;

/// What the service knows about the profiles that exist.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Profiles {
    /// Profiles1 has not answered yet: a Post cannot be checked and answers "failed"; nothing is
    /// wiped.
    Unknown,
    /// Development (`--session` without Profiles1): every well-formed id is a profile.
    Any,
    /// ListProfiles together with ListGuests.
    Known(BTreeSet<String>),
}

/// The answer to Post.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Posted {
    pub status: Status,
    /// 0 unless "ok" with an item kept.
    pub id: u32,
    pub events: Vec<Event>,
}

/// Why a property write was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SetError {
    /// Nobody is signed in: there are no settings to write.
    NoProfile,
    /// The value is out of range.
    Invalid(&'static str),
}

pub struct Notifications<P: Persist> {
    history: History,
    settings: BTreeMap<String, Settings>,
    last_ids: BTreeMap<String, u32>,
    profiles: Profiles,
    active: String,
    store: P,
}

impl<P: Persist> Notifications<P> {
    /// The service at start: the stored profiles (`FileStore::load_all`) and what is known of
    /// Profiles1 so far.
    pub fn new(store: P, loaded: Vec<(String, ProfileData)>, profiles: Profiles) -> Self {
        let mut history = History::default();
        let mut settings = BTreeMap::new();
        let mut last_ids = BTreeMap::new();
        for (profile, data) in loaded {
            history.load(&profile, data.items, data.last_id);
            settings.insert(profile.clone(), data.settings);
            last_ids.insert(profile, data.last_id);
        }
        let mut svc = Notifications {
            history,
            settings,
            last_ids,
            profiles: Profiles::Unknown,
            active: String::new(),
            store,
        };
        svc.set_profiles(profiles);
        svc
    }

    pub fn store(&self) -> &P {
        &self.store
    }

    pub fn store_mut(&mut self) -> &mut P {
        &mut self.store
    }

    pub fn profiles(&self) -> &Profiles {
        &self.profiles
    }

    /// Is `profile` one that exists? `None` while Profiles1 has not answered.
    pub fn knows(&self, profile: &str) -> Option<bool> {
        match &self.profiles {
            Profiles::Unknown => None,
            Profiles::Any => Some(valid_profile_id(profile)),
            Profiles::Known(ids) => Some(ids.contains(profile)),
        }
    }

    /// The profiles that exist now. One that has data here and is not among them (deleted, or a
    /// temporary guest gone at Lock, SwitchTo or RemoveGuest) loses its items, its settings and
    /// its file: they were private to it. Answers the profiles wiped.
    pub fn set_profiles(&mut self, profiles: Profiles) -> Vec<String> {
        self.profiles = profiles;
        let Profiles::Known(ids) = &self.profiles else {
            return Vec::new();
        };
        let held: BTreeSet<String> = self
            .history
            .profiles()
            .chain(self.settings.keys())
            .chain(self.last_ids.keys())
            .cloned()
            .collect();
        let gone: Vec<String> = held.into_iter().filter(|p| !ids.contains(p)).collect();
        for profile in &gone {
            self.history.remove_profile(profile);
            self.settings.remove(profile);
            self.last_ids.remove(profile);
            match self.store.remove(profile) {
                Ok(()) => eprintln!(
                    "ruya-notifications: profile {profile} is gone; its notifications and settings were removed"
                ),
                Err(err) => eprintln!(
                    "ruya-notifications: profile {profile} is gone, but its file could not be removed: {err}"
                ),
            }
        }
        gone
    }

    /// Profiles1.ActiveProfile ("" = locked, nobody signed in).
    pub fn set_active(&mut self, profile: &str) {
        self.active = profile.to_owned();
    }

    pub fn active(&self) -> &str {
        &self.active
    }

    /// The settings the properties show: the active profile's, the defaults while nobody is
    /// signed in.
    pub fn active_settings(&self) -> Settings {
        self.settings_of(&self.active)
    }

    fn settings_of(&self, profile: &str) -> Settings {
        self.settings.get(profile).cloned().unwrap_or_default()
    }

    /// A property write, for the active profile. Nothing is stored when it is refused.
    pub fn set(&mut self, change: Change) -> Result<(), SetError> {
        if self.active.is_empty() || !valid_profile_id(&self.active) {
            return Err(SetError::NoProfile);
        }
        let mut s = self.active_settings();
        s.apply(change).map_err(SetError::Invalid)?;
        let profile = self.active.clone();
        self.settings.insert(profile.clone(), s);
        self.persist(&profile);
        Ok(())
    }

    /// Post: the shell's own sources (and, later, the bridge's app items through the same core:
    /// RUY-88 adds a caller that sets `app_id` from the app, not from its arguments).
    pub fn post(&mut self, profile: &str, new: NewItem, now: i64) -> Posted {
        let refused = |status| Posted {
            status,
            id: 0,
            events: Vec::new(),
        };
        if !new.is_valid() || !valid_profile_id(profile) {
            return refused(Status::Invalid);
        }
        match self.knows(profile) {
            None => return refused(Status::Failed),
            Some(false) => return refused(Status::Invalid),
            Some(true) => {}
        }
        if !self
            .settings_of(profile)
            .source_enabled(&new.source, &new.app_id)
        {
            return refused(Status::Ok); // "not kept and not shown": ok, id 0
        }
        let Some((id, events)) = self.history.post(profile, new, now) else {
            eprintln!("ruya-notifications: no notification id left");
            return refused(Status::Failed);
        };
        self.last_ids.insert(profile.to_owned(), id);
        self.persist(profile);
        Posted {
            status: Status::Ok,
            id,
            events,
        }
    }

    pub fn withdraw(&mut self, key: &str) -> (Status, Vec<Event>) {
        let (status, events) = self.history.withdraw(key);
        self.persist_touched(&events);
        (status, events)
    }

    pub fn dismiss(&mut self, id: u32) -> (Status, Vec<Event>) {
        let (status, events) = self.history.dismiss(id);
        self.persist_touched(&events);
        (status, events)
    }

    pub fn dismiss_all(&mut self, profile: &str) -> (Status, Vec<Event>) {
        let (status, events) = self.history.dismiss_all(profile);
        self.persist_touched(&events);
        (status, events)
    }

    pub fn invoke(&mut self, id: u32, action: &str) -> (Status, Vec<Event>) {
        let (status, events) = self.history.invoke(id, action);
        self.persist_touched(&events);
        (status, events)
    }

    pub fn mark_read(&mut self, profile: &str) -> (Status, Vec<Event>) {
        let (status, events) = self.history.mark_read(profile);
        self.persist_touched(&events);
        (status, events)
    }

    /// The profile's items in order, after the caps at `now` (what they dropped is in the events).
    pub fn list(&mut self, profile: &str, now: i64) -> (Vec<Item>, Vec<Event>) {
        let (items, events) = self.history.list(profile, now);
        self.persist_touched(&events);
        (items, events)
    }

    fn persist_touched(&mut self, events: &[Event]) {
        let touched: BTreeSet<String> = events
            .iter()
            .map(|e| match e {
                Event::Added(p, _) | Event::Removed(p, _, _) | Event::Changed(p) => p.clone(),
            })
            .collect();
        for profile in touched {
            self.persist(&profile);
        }
    }

    /// Writes the profile's file now (no timer). A failure is logged; the change stays in memory.
    fn persist(&mut self, profile: &str) {
        let data = ProfileData {
            last_id: self.last_ids.get(profile).copied().unwrap_or(0),
            settings: self.settings_of(profile),
            items: self.history.entries(profile).to_vec(),
        };
        if let Err(err) = self.store.save(profile, &data) {
            eprintln!("ruya-notifications: cannot save the notifications of {profile}: {err}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::history::Reason;
    use crate::settings::{Property, QuietHours};
    use crate::store::MemoryStore;

    const T0: i64 = 1_800_000_000_000;

    fn known(ids: &[&str]) -> Profiles {
        Profiles::Known(ids.iter().map(|s| (*s).to_owned()).collect())
    }

    fn svc(ids: &[&str]) -> Notifications<MemoryStore> {
        Notifications::new(MemoryStore::default(), Vec::new(), known(ids))
    }

    fn item(title: &str) -> NewItem {
        NewItem {
            source: "devices".into(),
            kind: "info".into(),
            title: title.into(),
            urgency: "normal".into(),
            ..NewItem::default()
        }
    }

    #[test]
    fn a_post_for_a_profile_that_does_not_exist_is_invalid() {
        let mut s = svc(&["p1"]);
        assert_eq!(s.post("p9", item("x"), T0).status, Status::Invalid);
        assert_eq!(s.post("", item("x"), T0).status, Status::Invalid);
        assert_eq!(s.post("../p1", item("x"), T0).status, Status::Invalid);
        assert!(s.store().files.is_empty(), "nothing kept");
        assert_eq!(
            s.post(
                "p1",
                NewItem {
                    kind: "loud".into(),
                    ..item("x")
                },
                T0
            )
            .status,
            Status::Invalid
        );
        let ok = s.post("p1", item("x"), T0);
        assert_eq!((ok.status, ok.id), (Status::Ok, 1));
    }

    #[test]
    fn a_live_guest_is_a_profile_too() {
        // valid ids = ListProfiles ∪ ListGuests (the adapter joins them).
        let mut s = svc(&["p1", "p7"]);
        assert_eq!(
            s.post("p7", item("Controller connected"), T0).status,
            Status::Ok
        );
    }

    #[test]
    fn before_profiles1_answers_a_post_fails_and_nothing_is_wiped() {
        let loaded = vec![("p3".to_owned(), ProfileData::default())];
        let mut store = MemoryStore::default();
        store.files.insert("p3".into(), ProfileData::default());
        let mut s = Notifications::new(store, loaded, Profiles::Unknown);
        assert_eq!(s.post("p3", item("x"), T0).status, Status::Failed);
        assert!(s.store().files.contains_key("p3"));
        assert_eq!(s.knows("p3"), None);
    }

    #[test]
    fn development_mode_accepts_any_well_formed_id() {
        let mut s = Notifications::new(MemoryStore::default(), Vec::new(), Profiles::Any);
        assert_eq!(s.post("p2", item("x"), T0).status, Status::Ok);
        assert_eq!(s.post("a/b", item("x"), T0).status, Status::Invalid);
    }

    #[test]
    fn a_source_that_is_off_keeps_nothing_and_answers_ok_with_id_0() {
        let mut s = svc(&["p1", "p2"]);
        s.set_active("p1");
        let mut off = BTreeMap::new();
        off.insert("devices".to_owned(), false);
        off.insert("app:org.example.Game".to_owned(), false);
        s.set(Change::SourcesEnabled(off)).unwrap();
        let p = s.post("p1", item("Controller connected"), T0);
        assert_eq!((p.status, p.id, p.events.len()), (Status::Ok, 0, 0));
        assert!(s.list("p1", T0).0.is_empty());
        let app = NewItem {
            source: "app".into(),
            app_id: "org.example.Game".into(),
            ..item("hi")
        };
        assert_eq!(s.post("p1", app.clone(), T0).id, 0);
        let other = NewItem {
            app_id: "org.example.Other".into(),
            ..app
        };
        assert_ne!(s.post("p1", other, T0).id, 0, "another app is on");
        // The posting profile's switches count, not the active profile's.
        assert_ne!(s.post("p2", item("Controller connected"), T0).id, 0);
    }

    #[test]
    fn every_change_is_written_at_once() {
        let mut s = svc(&["p1"]);
        let id = s.post("p1", item("a"), T0).id;
        let file = |s: &Notifications<MemoryStore>| s.store().files.get("p1").cloned().unwrap();
        assert_eq!(file(&s).items.len(), 1);
        assert_eq!(file(&s).last_id, id);
        assert!(file(&s).items[0].item.unread);
        s.mark_read("p1");
        assert!(!file(&s).items[0].item.unread);
        s.dismiss(id);
        assert!(file(&s).items.is_empty());
        assert_eq!(
            file(&s).last_id,
            id,
            "the last id stays after the item went"
        );
    }

    #[test]
    fn a_restart_keeps_items_ids_and_settings() {
        let mut s = svc(&["p1", "p2"]);
        s.set_active("p1");
        s.set(Change::ToastSeconds(9)).unwrap();
        let first = s.post("p1", item("kept"), T0).id;
        let gone = s.post("p2", item("cleared"), T0).id;
        s.dismiss(gone);
        let files: Vec<(String, ProfileData)> = s.store().files.clone().into_iter().collect();
        let mut again = Notifications::new(MemoryStore::default(), files, known(&["p1", "p2"]));
        let (items, _) = again.list("p1", T0);
        assert_eq!(items.iter().map(|i| i.id).collect::<Vec<_>>(), vec![first]);
        again.set_active("p1");
        assert_eq!(again.active_settings().toast_seconds, 9);
        let next = again.post("p1", item("new"), T0).id;
        assert!(
            next > gone,
            "{next} must be above every id handed out before ({gone})"
        );
    }

    #[test]
    fn settings_are_per_profile_and_follow_the_active_one() {
        let mut s = svc(&["p1", "p2"]);
        assert_eq!(
            s.active_settings(),
            Settings::default(),
            "locked: the defaults"
        );
        s.set_active("p1");
        s.set(Change::Quiet(true)).unwrap();
        s.set(Change::QuietHours(QuietHours {
            enabled: true,
            from: "21:00".into(),
            to: "06:30".into(),
        }))
        .unwrap();
        let p1 = s.active_settings();
        s.set_active("p2");
        assert_eq!(s.active_settings(), Settings::default());
        assert_eq!(
            p1.differing(&s.active_settings()),
            vec![Property::Quiet, Property::QuietHours],
            "the properties the adapter announces on the switch"
        );
        s.set(Change::Sounds(false)).unwrap();
        s.set_active("p1");
        assert_eq!(s.active_settings(), p1, "p2's write did not touch p1");
    }

    #[test]
    fn a_set_while_nobody_is_signed_in_fails_and_stores_nothing() {
        let mut s = svc(&["p1"]);
        assert_eq!(s.set(Change::Quiet(true)), Err(SetError::NoProfile));
        assert!(s.store().files.is_empty());
        assert_eq!(s.active_settings(), Settings::default());
    }

    #[test]
    fn an_invalid_value_is_refused_and_stores_nothing() {
        let mut s = svc(&["p1"]);
        s.set_active("p1");
        assert!(matches!(
            s.set(Change::ToastSeconds(30)),
            Err(SetError::Invalid(_))
        ));
        assert!(s.store().files.is_empty());
        assert!(s.set(Change::ToastSeconds(6)).is_ok());
        assert_eq!(s.store().files["p1"].settings.toast_seconds, 6);
    }

    #[test]
    fn a_profile_that_goes_loses_its_items_settings_and_file() {
        let mut s = svc(&["p1", "p5"]);
        s.set_active("p5");
        s.set(Change::Quiet(true)).unwrap();
        let guest_item = s.post("p5", item("guest's"), T0).id;
        s.post("p1", item("p1's"), T0);
        assert!(s.store().files.contains_key("p5"));
        let wiped = s.set_profiles(known(&["p1"])); // the guest was removed at Lock
        assert_eq!(wiped, vec!["p5".to_owned()]);
        assert!(!s.store().files.contains_key("p5"), "its file is gone");
        assert!(s.list("p5", T0).0.is_empty());
        assert_eq!(s.dismiss(guest_item).0, Status::Unknown);
        assert_eq!(
            s.active_settings(),
            Settings::default(),
            "its settings are gone too"
        );
        assert_eq!(s.list("p1", T0).0.len(), 1);
        assert_eq!(s.post("p5", item("late"), T0).status, Status::Invalid);
    }

    #[test]
    fn stored_profiles_that_no_longer_exist_are_wiped_at_start() {
        let loaded = vec![
            ("p1".to_owned(), ProfileData::default()),
            ("p6".to_owned(), ProfileData::default()),
        ];
        let mut store = MemoryStore::default();
        for (p, d) in &loaded {
            store.files.insert(p.clone(), d.clone());
        }
        let s = Notifications::new(store, loaded, known(&["p1"]));
        assert_eq!(s.store().files.keys().collect::<Vec<_>>(), vec!["p1"]);
    }

    #[test]
    fn withdraw_and_caps_write_every_profile_they_touched() {
        let mut s = svc(&["p1", "p2"]);
        let keyed = NewItem {
            key: "update-restart".into(),
            pinned: true,
            ..item("Restart")
        };
        s.post("p1", keyed.clone(), T0);
        s.post("p2", keyed, T0);
        let (status, events) = s.withdraw("update-restart");
        assert_eq!(status, Status::Ok);
        assert_eq!(events.len(), 2);
        assert!(s.store().files["p1"].items.is_empty());
        assert!(s.store().files["p2"].items.is_empty());
        let old = s.post("p1", item("old"), T0).id;
        let (_, events) = s.list("p1", T0 + crate::history::MAX_AGE_MS + 1);
        assert_eq!(
            events,
            vec![Event::Removed("p1".into(), vec![old], Reason::Expired)]
        );
        assert!(
            s.store().files["p1"].items.is_empty(),
            "the cap's drop is written too"
        );
    }

    #[test]
    fn a_store_that_fails_still_answers() {
        let store = MemoryStore {
            fail: true,
            ..MemoryStore::default()
        };
        let mut s = Notifications::new(store, Vec::new(), known(&["p1"]));
        let p = s.post("p1", item("x"), T0);
        assert_eq!(
            p.status,
            Status::Ok,
            "kept in memory; the failure is logged"
        );
        assert_eq!(s.list("p1", T0).0.len(), 1);
    }
}
