//! The notification history: every profile's items, the ids, the keyed states and the caps.
//! Pure: time comes in as unix milliseconds, and every change answers the signals it causes
//! (`Event`) for the adapter to send. Where the XML is silent the shell's mock
//! (`shell/src/notifications/MockNotificationsBackend.cpp`) is the spec.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// At most this many items per profile (the oldest unpinned go first).
pub const MAX_ITEMS: usize = 50;
/// No unpinned item older than this (7 days).
pub const MAX_AGE_MS: i64 = 7 * 24 * 60 * 60 * 1000;

pub const SOURCES: [&str; 5] = ["system", "updates", "devices", "store", "app"];
pub const KINDS: [&str; 4] = ["info", "success", "warning", "error"];
pub const URGENCIES: [&str; 3] = ["low", "normal", "critical"];
pub const MAX_ACTIONS: usize = 2;

/// One item, the fields of the XML's struct in its order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    pub id: u32,
    pub source: String,
    pub app_id: String,
    pub kind: String,
    pub title: String,
    pub body: String,
    pub icon: String,
    pub actions: Vec<(String, String)>,
    pub urgency: String,
    pub pinned: bool,
    pub unread: bool,
    pub time: i64,
}

/// A stored item: the item and the key of the lasting state it shows ("" = none).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    #[serde(default)]
    pub key: String,
    pub item: Item,
}

/// What a poster gives; id, unread and time are the service's.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct NewItem {
    pub key: String,
    pub source: String,
    pub app_id: String,
    pub kind: String,
    pub title: String,
    pub body: String,
    pub icon: String,
    pub actions: Vec<(String, String)>,
    pub urgency: String,
    pub pinned: bool,
}

impl NewItem {
    /// The contract's "invalid": an empty title, an unknown source, kind or urgency, more than
    /// two actions.
    pub fn is_valid(&self) -> bool {
        !self.title.trim().is_empty()
            && SOURCES.contains(&self.source.as_str())
            && KINDS.contains(&self.kind.as_str())
            && URGENCIES.contains(&self.urgency.as_str())
            && self.actions.len() <= MAX_ACTIONS
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    Dismissed,
    Cleared,
    Invoked,
    Withdrawn,
    Replaced,
    Expired,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Reason::Dismissed => "dismissed",
            Reason::Cleared => "cleared",
            Reason::Invoked => "invoked",
            Reason::Withdrawn => "withdrawn",
            Reason::Replaced => "replaced",
            Reason::Expired => "expired",
        }
    }
}

/// A signal to send, in the order the change made them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Added(String, Item),
    Removed(String, Vec<u32>, Reason),
    Changed(String),
}

/// The status strings of the contract.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    Unknown,
    Pinned,
    Invalid,
    Forbidden,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::Unknown => "unknown",
            Status::Pinned => "pinned",
            Status::Invalid => "invalid",
            Status::Forbidden => "forbidden",
            Status::Failed => "failed",
        }
    }
}

/// Every profile's items, oldest posted first, and the next id.
#[derive(Debug, Clone)]
pub struct History {
    lists: BTreeMap<String, Vec<Entry>>,
    next_id: u32,
}

impl Default for History {
    fn default() -> Self {
        History {
            lists: BTreeMap::new(),
            next_id: 1,
        }
    }
}

/// Pinned first, then newest first (by time, then by id).
fn list_order(a: &Item, b: &Item) -> std::cmp::Ordering {
    b.pinned
        .cmp(&a.pinned)
        .then(b.time.cmp(&a.time))
        .then(b.id.cmp(&a.id))
}

impl History {
    /// Takes a profile's stored items over (start-up). `last_id` is the highest id the profile
    /// ever had; the next id is above it and above every stored item's.
    pub fn load(&mut self, profile: &str, entries: Vec<Entry>, last_id: u32) {
        let top = entries
            .iter()
            .map(|e| e.item.id)
            .max()
            .unwrap_or(0)
            .max(last_id);
        self.next_id = self.next_id.max(top.saturating_add(1));
        self.lists.insert(profile.to_owned(), entries);
    }

    /// The id the next item gets.
    pub fn next_id(&self) -> u32 {
        self.next_id
    }

    /// The profile's stored entries, oldest posted first (for the store).
    pub fn entries(&self, profile: &str) -> &[Entry] {
        self.lists.get(profile).map_or(&[], Vec::as_slice)
    }

    /// Profiles that have a list (possibly empty).
    pub fn profiles(&self) -> impl Iterator<Item = &String> {
        self.lists.keys()
    }

    /// Drops a profile and everything it had (it no longer exists). No signal: nobody is left to
    /// show it to.
    pub fn remove_profile(&mut self, profile: &str) -> bool {
        self.lists.remove(profile).is_some()
    }

    fn find(&self, id: u32) -> Option<(String, usize)> {
        self.lists.iter().find_map(|(profile, list)| {
            list.iter()
                .position(|e| e.item.id == id)
                .map(|i| (profile.clone(), i))
        })
    }

    /// Adds an item to the profile (the caller has validated it and checked the profile and its
    /// sources). A keyed item replaces the profile's earlier item with that key (Removed
    /// "replaced", then Added); the caps follow. Answers the new id, or `None` when the ids ran out.
    pub fn post(&mut self, profile: &str, new: NewItem, now: i64) -> Option<(u32, Vec<Event>)> {
        if self.next_id == u32::MAX {
            return None;
        }
        let mut events = Vec::new();
        let list = self.lists.entry(profile.to_owned()).or_default();
        if !new.key.is_empty() {
            if let Some(i) = list.iter().position(|e| e.key == new.key) {
                let old = list.remove(i).item.id;
                events.push(Event::Removed(
                    profile.to_owned(),
                    vec![old],
                    Reason::Replaced,
                ));
            }
        }
        let id = self.next_id;
        self.next_id += 1;
        let item = Item {
            id,
            source: new.source,
            app_id: new.app_id,
            kind: new.kind,
            title: new.title,
            body: new.body,
            icon: new.icon,
            actions: new.actions,
            urgency: new.urgency,
            pinned: new.pinned,
            unread: true,
            time: now,
        };
        list.push(Entry {
            key: new.key,
            item: item.clone(),
        });
        events.extend(self.apply_caps(profile, now));
        events.push(Event::Added(profile.to_owned(), item));
        Some((id, events))
    }

    /// The caps: unpinned items older than 7 days go, then the oldest unpinned past 50; pinned
    /// items are never dropped. One Removed "expired" for both.
    pub fn apply_caps(&mut self, profile: &str, now: i64) -> Vec<Event> {
        let Some(list) = self.lists.get_mut(profile) else {
            return Vec::new();
        };
        let mut dropped = Vec::new();
        let oldest = now.saturating_sub(MAX_AGE_MS);
        list.retain(|e| {
            let keep = e.item.pinned || e.item.time >= oldest;
            if !keep {
                dropped.push(e.item.id);
            }
            keep
        });
        while list.len() > MAX_ITEMS {
            let victim = list
                .iter()
                .enumerate()
                .filter(|(_, e)| !e.item.pinned)
                .min_by_key(|(_, e)| (e.item.time, e.item.id))
                .map(|(i, _)| i);
            let Some(i) = victim else {
                break; // only pinned items left: they are never dropped
            };
            dropped.push(list.remove(i).item.id);
        }
        if dropped.is_empty() {
            Vec::new()
        } else {
            vec![Event::Removed(profile.to_owned(), dropped, Reason::Expired)]
        }
    }

    /// The profile's items in the contract's order, after the caps at `now`.
    pub fn list(&mut self, profile: &str, now: i64) -> (Vec<Item>, Vec<Event>) {
        let events = self.apply_caps(profile, now);
        let mut items: Vec<Item> = self
            .entries(profile)
            .iter()
            .map(|e| e.item.clone())
            .collect();
        items.sort_by(list_order);
        (items, events)
    }

    /// The keyed state is over: its item goes from every profile, pinned or not. An empty key is
    /// "invalid" (the mock's rule).
    pub fn withdraw(&mut self, key: &str) -> (Status, Vec<Event>) {
        if key.is_empty() {
            return (Status::Invalid, Vec::new());
        }
        let mut events = Vec::new();
        for (profile, list) in &mut self.lists {
            let mut ids = Vec::new();
            list.retain(|e| {
                let hit = e.key == key;
                if hit {
                    ids.push(e.item.id);
                }
                !hit
            });
            if !ids.is_empty() {
                events.push(Event::Removed(profile.clone(), ids, Reason::Withdrawn));
            }
        }
        (Status::Ok, events)
    }

    /// Clears one item; a pinned item answers "pinned" and stays.
    pub fn dismiss(&mut self, id: u32) -> (Status, Vec<Event>) {
        let Some((profile, i)) = self.find(id) else {
            return (Status::Unknown, Vec::new());
        };
        let list = self
            .lists
            .get_mut(&profile)
            .expect("find just returned this profile");
        if list[i].item.pinned {
            return (Status::Pinned, Vec::new());
        }
        list.remove(i);
        (
            Status::Ok,
            vec![Event::Removed(profile, vec![id], Reason::Dismissed)],
        )
    }

    /// Clears every unpinned item of the profile; "ok" also when nothing was there.
    pub fn dismiss_all(&mut self, profile: &str) -> (Status, Vec<Event>) {
        let mut ids = Vec::new();
        if let Some(list) = self.lists.get_mut(profile) {
            list.retain(|e| {
                if e.item.pinned {
                    true
                } else {
                    ids.push(e.item.id);
                    false
                }
            });
        }
        if ids.is_empty() {
            (Status::Ok, Vec::new())
        } else {
            (
                Status::Ok,
                vec![Event::Removed(profile.to_owned(), ids, Reason::Cleared)],
            )
        }
    }

    /// Runs one of the item's actions: an action it does not offer is "invalid". Clears the item
    /// unless it is pinned.
    pub fn invoke(&mut self, id: u32, action: &str) -> (Status, Vec<Event>) {
        let Some((profile, i)) = self.find(id) else {
            return (Status::Unknown, Vec::new());
        };
        let list = self
            .lists
            .get_mut(&profile)
            .expect("find just returned this profile");
        if !list[i].item.actions.iter().any(|(a, _)| a == action) {
            return (Status::Invalid, Vec::new());
        }
        if list[i].item.pinned {
            return (Status::Ok, Vec::new());
        }
        list.remove(i);
        (
            Status::Ok,
            vec![Event::Removed(profile, vec![id], Reason::Invoked)],
        )
    }

    /// Marks every item of the profile read; Changed when one changed.
    pub fn mark_read(&mut self, profile: &str) -> (Status, Vec<Event>) {
        let mut any = false;
        if let Some(list) = self.lists.get_mut(profile) {
            for e in list.iter_mut().filter(|e| e.item.unread) {
                e.item.unread = false;
                any = true;
            }
        }
        let events = if any {
            vec![Event::Changed(profile.to_owned())]
        } else {
            Vec::new()
        };
        (Status::Ok, events)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: i64 = 1_800_000_000_000;

    fn new(title: &str) -> NewItem {
        NewItem {
            source: "system".into(),
            kind: "info".into(),
            title: title.into(),
            urgency: "normal".into(),
            ..NewItem::default()
        }
    }

    fn keyed(title: &str, key: &str) -> NewItem {
        NewItem {
            key: key.into(),
            ..new(title)
        }
    }

    fn pinned(title: &str, key: &str) -> NewItem {
        NewItem {
            pinned: true,
            ..keyed(title, key)
        }
    }

    fn with_actions(title: &str, actions: &[&str]) -> NewItem {
        NewItem {
            actions: actions
                .iter()
                .map(|a| ((*a).to_owned(), format!("Label {a}")))
                .collect(),
            ..new(title)
        }
    }

    fn stored(id: u32, time: i64) -> Item {
        Item {
            id,
            source: "system".into(),
            app_id: String::new(),
            kind: "info".into(),
            title: "t".into(),
            body: String::new(),
            icon: String::new(),
            actions: vec![],
            urgency: "normal".into(),
            pinned: false,
            unread: true,
            time,
        }
    }

    fn ids(items: &[Item]) -> Vec<u32> {
        items.iter().map(|i| i.id).collect()
    }

    fn post(h: &mut History, profile: &str, item: NewItem, now: i64) -> (u32, Vec<Event>) {
        h.post(profile, item, now).expect("ids left")
    }

    #[test]
    fn validation_follows_the_contract() {
        assert!(new("Controller connected").is_valid());
        assert!(!new("").is_valid(), "empty title");
        assert!(!new("   ").is_valid(), "blank title");
        assert!(
            !NewItem {
                source: "games".into(),
                ..new("x")
            }
            .is_valid(),
            "unknown source"
        );
        assert!(
            !NewItem {
                kind: "fatal".into(),
                ..new("x")
            }
            .is_valid(),
            "unknown kind"
        );
        assert!(
            !NewItem {
                urgency: "high".into(),
                ..new("x")
            }
            .is_valid(),
            "unknown urgency"
        );
        assert!(with_actions("x", &["a", "b"]).is_valid(), "two actions");
        assert!(
            !with_actions("x", &["a", "b", "c"]).is_valid(),
            "three actions"
        );
        for source in SOURCES {
            assert!(
                NewItem {
                    source: source.into(),
                    ..new("x")
                }
                .is_valid(),
                "{source}"
            );
        }
    }

    #[test]
    fn ids_start_at_one_and_are_never_reused() {
        let mut h = History::default();
        let (a, _) = post(&mut h, "p1", new("a"), T0);
        let (b, _) = post(&mut h, "p2", new("b"), T0);
        assert_eq!((a, b), (1, 2));
        h.dismiss(b);
        let (c, _) = post(&mut h, "p2", new("c"), T0);
        assert_eq!(c, 3, "a dismissed id is not handed out again");
    }

    #[test]
    fn a_post_is_unread_with_the_services_time_and_signals_added() {
        let mut h = History::default();
        let (id, events) = post(&mut h, "p1", new("Hello"), T0);
        let (items, _) = h.list("p1", T0);
        assert_eq!(items.len(), 1);
        assert!(items[0].unread);
        assert_eq!(items[0].time, T0);
        assert_eq!(events, vec![Event::Added("p1".into(), items[0].clone())]);
        assert_eq!(items[0].id, id);
    }

    #[test]
    fn ids_after_reload_are_above_every_stored_one() {
        let mut h = History::default();
        let entry = |id| Entry {
            key: String::new(),
            item: stored(id, T0),
        };
        h.load("p1", vec![entry(4), entry(9)], 9);
        h.load("p2", vec![entry(2)], 20); // p2 once had id 20, since dismissed
        assert_eq!(h.next_id(), 21);
        h.load("p3", vec![entry(30)], 0);
        assert_eq!(h.next_id(), 31);
        let (id, _) = post(&mut h, "p1", new("x"), T0);
        assert_eq!(id, 31);
    }

    #[test]
    fn a_keyed_post_replaces_the_earlier_item_removed_then_added() {
        let mut h = History::default();
        let (old, _) = post(&mut h, "p1", keyed("Update ready", "update-restart"), T0);
        post(&mut h, "p1", new("other"), T0);
        post(&mut h, "p2", keyed("Update ready", "update-restart"), T0);
        let (fresh, events) = post(&mut h, "p1", keyed("Restart now", "update-restart"), T0 + 1);
        assert_eq!(events.len(), 2);
        assert_eq!(
            events[0],
            Event::Removed("p1".into(), vec![old], Reason::Replaced)
        );
        assert!(matches!(&events[1], Event::Added(p, item) if p == "p1" && item.id == fresh));
        let (items, _) = h.list("p1", T0 + 1);
        assert_eq!(items.len(), 2);
        assert!(!ids(&items).contains(&old));
        assert_eq!(
            h.list("p2", T0).0.len(),
            1,
            "another profile's keyed item stays"
        );
    }

    #[test]
    fn withdraw_removes_the_key_from_every_profile_pinned_or_not() {
        let mut h = History::default();
        let (a, _) = post(&mut h, "p1", pinned("Restart", "update-restart"), T0);
        let (b, _) = post(&mut h, "p2", keyed("Restart", "update-restart"), T0);
        post(&mut h, "p2", new("stays"), T0);
        let (status, events) = h.withdraw("update-restart");
        assert_eq!(status, Status::Ok);
        assert_eq!(
            events,
            vec![
                Event::Removed("p1".into(), vec![a], Reason::Withdrawn),
                Event::Removed("p2".into(), vec![b], Reason::Withdrawn),
            ]
        );
        assert!(h.list("p1", T0).0.is_empty());
        assert_eq!(h.list("p2", T0).0.len(), 1);
        assert_eq!(
            h.withdraw("update-restart"),
            (Status::Ok, vec![]),
            "ok when nothing had it"
        );
        assert_eq!(h.withdraw("").0, Status::Invalid);
    }

    #[test]
    fn dismiss_refuses_a_pinned_item_and_answers_unknown_for_a_gone_one() {
        let mut h = History::default();
        let (p, _) = post(&mut h, "p1", pinned("Hot", "thermal-critical"), T0);
        let (n, _) = post(&mut h, "p1", new("Plain"), T0);
        assert_eq!(h.dismiss(p), (Status::Pinned, vec![]));
        assert_eq!(
            h.dismiss(n),
            (
                Status::Ok,
                vec![Event::Removed("p1".into(), vec![n], Reason::Dismissed)]
            )
        );
        assert_eq!(h.dismiss(n).0, Status::Unknown);
        assert_eq!(h.dismiss(0).0, Status::Unknown);
        assert_eq!(ids(&h.list("p1", T0).0), vec![p]);
    }

    #[test]
    fn dismiss_all_keeps_pinned_items_and_is_ok_on_an_empty_list() {
        let mut h = History::default();
        let (p, _) = post(&mut h, "p1", pinned("Hot", "thermal-critical"), T0);
        let (a, _) = post(&mut h, "p1", new("a"), T0);
        let (b, _) = post(&mut h, "p1", new("b"), T0);
        let (status, events) = h.dismiss_all("p1");
        assert_eq!(status, Status::Ok);
        assert_eq!(
            events,
            vec![Event::Removed("p1".into(), vec![a, b], Reason::Cleared)]
        );
        assert_eq!(ids(&h.list("p1", T0).0), vec![p]);
        assert_eq!(h.dismiss_all("p1"), (Status::Ok, vec![]));
        assert_eq!(h.dismiss_all("nobody"), (Status::Ok, vec![]));
    }

    #[test]
    fn invoke_needs_an_offered_action_and_keeps_a_pinned_item() {
        let mut h = History::default();
        let (a, _) = post(&mut h, "p1", with_actions("Drive", &["open-storage"]), T0);
        let pinned_item = NewItem {
            pinned: true,
            ..with_actions("Restart", &["restart"])
        };
        let (p, _) = post(&mut h, "p1", pinned_item, T0);
        assert_eq!(h.invoke(a, "restart"), (Status::Invalid, vec![]));
        assert_eq!(
            h.invoke(p, "restart"),
            (Status::Ok, vec![]),
            "pinned: ok, and it stays"
        );
        assert_eq!(
            h.invoke(a, "open-storage"),
            (
                Status::Ok,
                vec![Event::Removed("p1".into(), vec![a], Reason::Invoked)]
            )
        );
        assert_eq!(h.invoke(a, "open-storage").0, Status::Unknown);
        assert_eq!(ids(&h.list("p1", T0).0), vec![p]);
    }

    #[test]
    fn mark_read_clears_unread_and_signals_changed_only_when_something_changed() {
        let mut h = History::default();
        post(&mut h, "p1", new("a"), T0);
        post(&mut h, "p2", new("b"), T0);
        assert_eq!(
            h.mark_read("p1"),
            (Status::Ok, vec![Event::Changed("p1".into())])
        );
        assert!(h.list("p1", T0).0.iter().all(|i| !i.unread));
        assert!(
            h.list("p2", T0).0.iter().all(|i| i.unread),
            "only that profile's items"
        );
        assert_eq!(h.mark_read("p1"), (Status::Ok, vec![]));
    }

    #[test]
    fn list_order_is_pinned_then_newest_by_time_then_id() {
        let mut h = History::default();
        let (old, _) = post(&mut h, "p1", new("old"), T0);
        let (pin, _) = post(&mut h, "p1", pinned("pin", "k"), T0 - 10);
        let (same1, _) = post(&mut h, "p1", new("same time 1"), T0 + 5);
        let (same2, _) = post(&mut h, "p1", new("same time 2"), T0 + 5);
        let (items, _) = h.list("p1", T0 + 5);
        assert_eq!(ids(&items), vec![pin, same2, same1, old]);
    }

    #[test]
    fn the_age_cap_drops_unpinned_items_older_than_seven_days() {
        let mut h = History::default();
        let (old, _) = post(&mut h, "p1", new("old"), T0);
        let (pin, _) = post(&mut h, "p1", pinned("pin", "k"), T0);
        let (edge, _) = post(&mut h, "p1", new("edge"), T0 + 1);
        // Exactly seven days old is kept (the mock drops only what is older).
        let (items, events) = h.list("p1", T0 + 1 + MAX_AGE_MS);
        assert_eq!(
            events,
            vec![Event::Removed("p1".into(), vec![old], Reason::Expired)]
        );
        assert_eq!(ids(&items), vec![pin, edge]);
        // Long after, the pinned item still stays.
        let (items, _) = h.list("p1", T0 + 100 * MAX_AGE_MS);
        assert_eq!(ids(&items), vec![pin]);
    }

    #[test]
    fn the_count_cap_drops_the_oldest_unpinned_and_never_a_pinned_one() {
        let mut h = History::default();
        let (pin, _) = post(&mut h, "p1", pinned("pin", "k"), T0 - 1000);
        let mut first = Vec::new();
        for n in 0..MAX_ITEMS - 1 {
            let (id, events) = post(&mut h, "p1", new(&format!("n{n}")), T0 + n as i64);
            assert_eq!(events.len(), 1, "no cap yet");
            first.push(id);
        }
        assert_eq!(h.entries("p1").len(), MAX_ITEMS);
        let (id, events) = post(&mut h, "p1", new("one more"), T0 + 500);
        assert_eq!(
            events[0],
            Event::Removed("p1".into(), vec![first[0]], Reason::Expired)
        );
        assert!(matches!(&events[1], Event::Added(_, item) if item.id == id));
        let (items, _) = h.list("p1", T0 + 500);
        assert_eq!(items.len(), MAX_ITEMS);
        assert!(
            ids(&items).contains(&pin),
            "the pinned item, the oldest of all, stays"
        );
        assert!(!ids(&items).contains(&first[0]));
    }

    #[test]
    fn age_and_count_caps_go_out_in_one_removed() {
        // 52 stored items: id 1 is older than seven days, so the age cap takes it and the count
        // cap the oldest of the rest (id 2); both in one Removed "expired".
        let mut h = History::default();
        let entries = (1..=52)
            .map(|id| Entry {
                key: String::new(),
                item: stored(
                    id,
                    if id == 1 {
                        T0 - MAX_AGE_MS - 1
                    } else {
                        T0 + i64::from(id)
                    },
                ),
            })
            .collect();
        h.load("p1", entries, 52);
        let (items, events) = h.list("p1", T0 + 100);
        assert_eq!(
            events,
            vec![Event::Removed("p1".into(), vec![1, 2], Reason::Expired)]
        );
        assert_eq!(items.len(), MAX_ITEMS);
    }

    #[test]
    fn only_pinned_items_past_the_cap_are_all_kept() {
        let mut h = History::default();
        for n in 0..MAX_ITEMS + 3 {
            post(
                &mut h,
                "p1",
                pinned(&format!("pin {n}"), &format!("k{n}")),
                T0,
            );
        }
        assert_eq!(h.list("p1", T0 + 100 * MAX_AGE_MS).0.len(), MAX_ITEMS + 3);
    }

    #[test]
    fn remove_profile_drops_its_items_only() {
        let mut h = History::default();
        post(&mut h, "p1", new("a"), T0);
        post(&mut h, "p2", new("b"), T0);
        assert!(h.remove_profile("p2"));
        assert!(h.list("p2", T0).0.is_empty());
        assert_eq!(h.list("p1", T0).0.len(), 1);
        assert!(!h.remove_profile("p2"));
    }
}
