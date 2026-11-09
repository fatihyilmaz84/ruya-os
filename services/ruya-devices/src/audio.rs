//! The audio rules of spec 03 §2.3: the output list, the default and its "previous" stack, the
//! hot-plug policy, master volume and mute, the three channel levels. No I/O except through
//! the `PipeWire` trait and the channel `Store`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use crate::output_policy::{rank, Avail, Choice, ChoiceStore, OutKind, Output};
use crate::store::{Channels, Store};

/// Channel names of the contract, in order.
pub const CHANNELS: [&str; 3] = ["ui", "ambient", "media"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Hdmi,
    Analog,
    Usb,
    Bluetooth,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Hdmi => "hdmi",
            Kind::Analog => "analog",
            Kind::Usb => "usb",
            Kind::Bluetooth => "bluetooth",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sink {
    pub id: String,
    pub name: String,
    pub kind: Kind,
}

/// Status strings of the contract (stable API).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    UnknownSink,
    UnknownOutput,
    /// The output exists but has no sink yet (its card profile is not active).
    Inactive,
    Invalid,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::UnknownSink => "unknown-sink",
            Status::UnknownOutput => "unknown-output",
            Status::Inactive => "inactive",
            Status::Invalid => "invalid",
            Status::Failed => "failed",
        }
    }
}

/// What PipeWire says right now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub sinks: Vec<Sink>,
    /// Every output of the cards, also those without a sink (T-322).
    pub outputs: Vec<Output>,
    pub default: Option<String>,
    pub volume: u32,
    pub muted: bool,
    /// Some output is running, i.e. something plays (T-202, `Playing`).
    pub playing: bool,
}

/// The side effects: PipeWire itself. A fake serves tests and `--session`; on Linux
/// `pipewire::WpCtl` runs `pw-dump` and `wpctl`.
pub trait PipeWire: Send {
    fn snapshot(&mut self) -> Result<Snapshot, String>;
    fn set_default(&mut self, id: &str) -> Result<(), String>;
    /// An opaque description of the card's active profile and route, to hand back to
    /// `restore_profile` (T-347).
    fn card_profile(&mut self, _card: &str) -> Result<String, String> {
        Err("card profiles are not supported".to_owned())
    }
    /// Switches the output's card to the profile and route that carry the output and returns the
    /// `node.name` of its sink once it exists. Does not change the default. On an error the card
    /// may be left on the new profile: the caller restores it.
    fn switch_to(&mut self, output: &Output) -> Result<String, String> {
        Err(format!("{}: its card profile is not active", output.id))
    }
    /// Puts the card back as `card_profile` described it, and returns once its sink is back.
    fn restore_profile(&mut self, _card: &str, _state: &str) -> Result<(), String> {
        Ok(())
    }
    /// Plays a short tone on the output's sink without changing the default.
    fn play_tone(&mut self, node: &str) -> Result<(), String>;
    /// 0-100 of the default output.
    fn set_volume(&mut self, volume: u32) -> Result<(), String>;
    fn set_muted(&mut self, muted: bool) -> Result<(), String>;
}

/// What a `refresh` changed, so the adapter knows which signals to emit.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Changes {
    pub sinks: bool,
    /// The outputs, the saved choice or the default changed (`OutputsChanged`).
    pub outputs: bool,
    /// The new default's id ("" when there is no output).
    pub default: Option<String>,
    /// Volume or mute.
    pub props: bool,
}

impl Changes {
    pub fn any(&self) -> bool {
        self.sinks || self.outputs || self.default.is_some() || self.props
    }
}

/// What the getters of the bus interface answer from (T-360): a copy of the state, refreshed
/// after every change, behind its own small lock. A card switch holds the `Audio` for seconds;
/// a read of this view never waits for it.
#[derive(Debug, Clone, Default)]
pub struct View {
    pub sinks: Vec<(Sink, bool)>,
    /// With whether it is the default and whether it is the saved choice.
    pub outputs: Vec<(Output, bool, bool)>,
    pub volume: u32,
    pub muted: bool,
    pub playing: bool,
    pub channels: BTreeMap<String, u32>,
}

pub type SharedView = Arc<Mutex<View>>;

/// The volume an output starts at the first time the console uses it (owner, 2026-11-08).
pub const FIRST_VOLUME: u32 = 100;

pub struct Audio<P: PipeWire> {
    view: SharedView,
    pw: P,
    store: Store,
    loaded: bool,
    sinks: Vec<Sink>,
    outputs: Vec<Output>,
    /// The ids of the headsets that were plugged at the last read.
    plugged: BTreeSet<String>,
    choice: Choice,
    choice_store: ChoiceStore,
    default: Option<String>,
    /// Earlier defaults, most recent last; only used when the default goes away.
    previous: Vec<String>,
    volume: u32,
    muted: bool,
    playing: bool,
    channels: Channels,
    /// The marker file of the one-time first-start volume; `None` = never apply it.
    first_start_marker: Option<PathBuf>,
    first_start_done: bool,
    /// A read has happened; the very first one only takes over the state (no signals, nobody listens yet).
    read_once: bool,
}

impl<P: PipeWire> Audio<P> {
    pub fn new(pw: P, store: Store) -> std::io::Result<Self> {
        let channels = store.load()?;
        let audio = Audio {
            view: SharedView::default(),
            pw,
            store,
            loaded: false,
            sinks: Vec::new(),
            outputs: Vec::new(),
            plugged: BTreeSet::new(),
            choice: Choice::default(),
            choice_store: ChoiceStore::in_memory(),
            default: None,
            previous: Vec::new(),
            volume: 0,
            muted: false,
            playing: false,
            channels,
            first_start_marker: None,
            first_start_done: true,
            read_once: false,
        };
        audio.publish();
        Ok(audio)
    }

    /// The copy the bus getters read.
    pub fn view(&self) -> SharedView {
        self.view.clone()
    }

    fn publish(&self) {
        let view = View {
            sinks: self
                .list_sinks()
                .into_iter()
                .map(|(s, d)| (s.clone(), d))
                .collect(),
            outputs: self
                .list_outputs()
                .into_iter()
                .map(|(o, d, s)| (o.clone(), d, s))
                .collect(),
            volume: self.volume,
            muted: self.muted,
            playing: self.playing,
            channels: self.channels(),
        };
        *self.view.lock().unwrap_or_else(|e| e.into_inner()) = view;
    }

    /// The first output starts at full volume, once (owner, 2026-11-08): the TV or monitor sets
    /// the loudness. `marker` is written after the volume was set and its presence stops it for
    /// good (reboot, restart, update); a volume the player sets later is never touched.
    ///
    /// `existing_install`: the state file was there before this start. Such a console may already
    /// hold a volume the player chose, so the marker is written at once and nothing is forced.
    pub fn with_first_start_marker(mut self, marker: &Path, existing_install: bool) -> Self {
        self.first_start_done = marker.exists();
        self.first_start_marker = Some(marker.to_owned());
        if existing_install && !self.first_start_done {
            self.first_start_done = true;
            self.write_marker();
        }
        self
    }

    fn write_marker(&self) {
        let Some(marker) = &self.first_start_marker else {
            return;
        };
        if let Some(dir) = marker.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        // A marker that can't be written still holds for this run (first_start_done).
        if let Err(err) = std::fs::write(marker, "the first-start volume was handled\n") {
            eprintln!(
                "ruya-devices: cannot write {}: {err} (the first-start volume may be set again after a restart)",
                marker.display()
            );
        }
    }

    /// Keeps the saved choice in `store` (loaded now; a corrupt file is an error).
    pub fn with_choice_store(mut self, store: ChoiceStore) -> std::io::Result<Self> {
        self.choice = store.load()?;
        self.choice_store = store;
        Ok(self)
    }

    /// Reads PipeWire and applies the hot-plug policy. The first call only takes over the
    /// state (the outputs present at start are no "new headset").
    pub fn refresh(&mut self) -> Result<Changes, String> {
        let snap = match self.pw.snapshot() {
            Ok(snap) => snap,
            Err(err) => {
                // The boot read failed (PipeWire not up): nobody was told anything yet, and the
                // watcher's first good read must report what it finds (T-360).
                self.read_once = true;
                return Err(err);
            }
        };
        let changes = self.apply(snap);
        self.publish();
        Ok(changes)
    }

    /// Remembers that the console has used this output, so a later switch to it keeps the volume
    /// WirePlumber saved for it. Only a choice that can't be saved is lost (it is retried).
    fn mark_seen(&mut self, id: &str) {
        if self.choice.seen.contains(id) {
            return;
        }
        let mut next = self.choice.clone();
        next.seen.insert(id.to_owned());
        if self.choice_store.save(&next).is_ok() {
            self.choice = next;
        }
    }

    fn apply(&mut self, mut snap: Snapshot) -> Changes {
        let mut changes = Changes::default();
        // The first read that shows an output takes over the state; an empty list (PipeWire or
        // WirePlumber not settled yet at boot) waits, so the policy still runs once outputs exist.
        // A sink without an output (the card list not read yet) waits too: the policy ranks outputs.
        let nothing_yet = snap.outputs.is_empty();
        let first = !self.loaded && !nothing_yet;
        if first {
            self.loaded = true;
        }

        let old_default = self.default.clone();
        let connected = |id: &str| snap.sinks.iter().any(|s| s.id == id);
        let default_gone = !first && old_default.as_deref().is_some_and(|d| !connected(d));
        let plugged: BTreeSet<String> = snap
            .outputs
            .iter()
            .filter(|o| o.is_plugged_headset())
            .map(|o| o.id.clone())
            .collect();
        let headset = snap
            .outputs
            .iter()
            .rev()
            .find(|o| o.is_plugged_headset() && !self.plugged.contains(&o.id));
        // The saved output is usable now and was not before: back from a reboot, a TV switched on late.
        let usable = |outputs: &[Output]| {
            self.choice.saved.as_deref().is_some_and(|saved| {
                outputs
                    .iter()
                    .any(|o| o.id == saved && o.available != Avail::No)
            })
        };
        let saved_returned = !first && usable(&snap.outputs) && !usable(&self.outputs);

        let mut default = snap.default.clone().filter(|d| connected(d));
        self.previous.retain(|p| connected(p));

        // Where the policy wants the default, if not where PipeWire has it.
        if first || saved_returned {
            // A default WirePlumber remembered (even one that does not exist this boot) never decides.
            self.follow_policy(&snap.outputs, &mut default);
        } else if let Some(h) = headset {
            if h.node.is_none() || h.node != default {
                if let Ok(node) = self.activate_output(h) {
                    default = Some(node);
                }
            }
        } else if default_gone {
            match self.previous.pop() {
                Some(target) => {
                    if self.pw.set_default(&target).is_ok() {
                        default = Some(target);
                    }
                }
                None => self.follow_policy(&snap.outputs, &mut default),
            }
        }

        if !self.first_start_done && default.is_some() && self.pw.set_volume(100).is_ok() {
            snap.volume = 100;
            self.first_start_done = true;
            self.write_marker();
        }

        let live = default
            .as_ref()
            .and_then(|d| snap.outputs.iter().find(|o| o.node.as_ref() == Some(d)))
            .map(|o| o.id.clone());
        if let Some(id) = live {
            self.mark_seen(&id);
        }

        // A change we didn't make (or PipeWire's own pick) keeps the old default as "previous".
        if let (Some(old), Some(new)) = (&old_default, &default) {
            if old != new && connected(old) {
                self.previous.retain(|p| p != old);
                self.previous.push(old.clone());
            }
        }

        if default != old_default {
            changes.default = Some(default.clone().unwrap_or_default());
        }
        if self.sinks != snap.sinks {
            changes.sinks = true;
        }
        if self.outputs != snap.outputs || changes.default.is_some() || saved_returned {
            changes.outputs = true;
        }
        if self.volume != snap.volume || self.muted != snap.muted || self.playing != snap.playing {
            changes.props = true;
        }
        self.sinks = snap.sinks;
        self.outputs = snap.outputs;
        self.plugged = plugged;
        self.default = default;
        self.volume = snap.volume.min(100);
        self.muted = snap.muted;
        self.playing = snap.playing;
        if !std::mem::replace(&mut self.read_once, true) {
            changes = Changes::default();
        }
        changes
    }

    /// Puts the default where the policy table says (the first output that can be activated).
    fn follow_policy(&mut self, outputs: &[Output], default: &mut Option<String>) {
        for o in rank(outputs, self.choice.saved.as_deref(), &self.choice.rejected) {
            if o.node.is_some() && o.node == *default {
                return;
            }
            if let Ok(node) = self.activate_output(o) {
                *default = Some(node);
                return;
            }
        }
    }

    /// Makes the output the default and returns its sink. An output on another profile of its
    /// card first gets its profile and route switched; a card is never left on a profile
    /// without a sink: when the switch or the default fails, the old profile comes back.
    fn activate_output(&mut self, o: &Output) -> Result<String, String> {
        if let Some(node) = &o.node {
            self.pw.set_default(node)?;
            return Ok(node.clone());
        }
        let old = self.pw.card_profile(&o.card).ok();
        let result = self
            .pw
            .switch_to(o)
            .and_then(|node| self.pw.set_default(&node).map(|()| node));
        if result.is_err() {
            if let Some(old) = old {
                let _ = self.pw.restore_profile(&o.card, &old);
            }
        } else if !self.choice.seen.contains(&o.id) {
            // An output used for the first time: WirePlumber gives it 0.40, the console its own
            // first volume. A failed write leaves it unseen, so the next switch tries again.
            if self.pw.set_volume(FIRST_VOLUME).is_ok() {
                self.volume = FIRST_VOLUME;
                self.mark_seen(&o.id);
            }
        }
        result
    }

    /// Every output, with whether it is the default and whether it is the saved choice.
    pub fn list_outputs(&self) -> Vec<(&Output, bool, bool)> {
        self.outputs
            .iter()
            .map(|o| {
                (
                    o,
                    o.node.is_some() && o.node == self.default,
                    self.choice.saved.as_deref() == Some(o.id.as_str()),
                )
            })
            .collect()
    }

    /// The player's choice: switch to it, remember it, and remember a valid-ELD HDMI output the
    /// policy would have picked instead as rejected.
    pub fn set_output(&mut self, id: &str) -> Status {
        let status = self.choose_output(id);
        self.publish();
        status
    }

    fn choose_output(&mut self, id: &str) -> Status {
        let Some(out) = self.outputs.iter().find(|o| o.id == id).cloned() else {
            return Status::UnknownOutput;
        };
        let mut next = self.choice.clone();
        let auto = rank(&self.outputs, None, &self.choice.rejected)
            .first()
            .filter(|o| o.has_eld() && o.id != id)
            .map(|o| o.id.clone());
        next.rejected.remove(id);
        next.rejected.extend(auto);
        next.saved = Some(id.to_owned());
        let on_it = out.node.is_some() && out.node == self.default;
        let mut node = out.node.clone();
        if !on_it {
            match self.activate_output(&out) {
                Ok(n) => node = Some(n),
                Err(_) if out.node.is_none() => return Status::Inactive,
                Err(_) => return Status::Failed,
            }
        }
        next.seen = self.choice.seen.clone(); // activate_output may have added to it
        if self.choice_store.save(&next).is_err() {
            return Status::Failed;
        }
        self.choice = next;
        if !on_it {
            if let Some(old) = self.default.take() {
                self.previous.retain(|p| *p != old);
                self.previous.push(old);
            }
            if let Some(node) = &node {
                self.previous.retain(|p| p != node);
                self.default = Some(node.clone());
            }
        }
        Status::Ok
    }

    /// A short tone on the output, without touching the default.
    pub fn test_output(&mut self, id: &str) -> Status {
        let Some(out) = self.outputs.iter().find(|o| o.id == id).cloned() else {
            return Status::UnknownOutput;
        };
        if let Some(node) = &out.node {
            return match self.pw.play_tone(node) {
                Ok(()) => Status::Ok,
                Err(_) => Status::Failed,
            };
        }
        // Another profile of the card: borrow it for the tone and give it back, so the default
        // output and what the player hears do not change.
        let Ok(old) = self.pw.card_profile(&out.card) else {
            return Status::Inactive;
        };
        let played = self
            .pw
            .switch_to(&out)
            .and_then(|node| self.pw.play_tone(&node));
        // restore_profile returns once the old sink is back, so the default can be set again:
        // it may have vanished with the profile and WirePlumber picked another one.
        let restored = self.pw.restore_profile(&out.card, &old);
        if let Some(default) = self.default.clone() {
            let _ = self.pw.set_default(&default);
        }
        match (played, restored) {
            (Ok(()), Ok(())) => Status::Ok,
            _ => Status::Failed,
        }
    }

    /// Forgets the saved choice and the rejected outputs and applies the policy table now.
    pub fn reset_choice(&mut self) -> Status {
        let status = self.forget_choice();
        self.publish();
        status
    }

    fn forget_choice(&mut self) -> Status {
        let reset = Choice {
            seen: self.choice.seen.clone(),
            ..Choice::default()
        };
        if self.choice_store.save(&reset).is_err() {
            return Status::Failed;
        }
        self.choice = reset;
        let outputs = self.outputs.clone();
        let mut default = self.default.clone();
        self.follow_policy(&outputs, &mut default);
        if default != self.default {
            if let Some(old) = self.default.take() {
                self.previous.retain(|p| *p != old);
                self.previous.push(old);
            }
            self.default = default;
        }
        Status::Ok
    }

    /// The outputs in a stable order, with whether each is the default.
    pub fn list_sinks(&self) -> Vec<(&Sink, bool)> {
        self.sinks
            .iter()
            .map(|s| (s, self.default.as_deref() == Some(s.id.as_str())))
            .collect()
    }

    pub fn default_sink(&self) -> Option<&str> {
        self.default.as_deref()
    }

    pub fn set_default_sink(&mut self, id: &str) -> Status {
        let status = self.move_default(id);
        self.publish();
        status
    }

    fn move_default(&mut self, id: &str) -> Status {
        if !self.sinks.iter().any(|s| s.id == id) {
            return Status::UnknownSink;
        }
        if self.default.as_deref() == Some(id) {
            return Status::Ok;
        }
        if self.pw.set_default(id).is_err() {
            return Status::Failed;
        }
        if let Some(old) = self.default.take() {
            self.previous.retain(|p| *p != old);
            self.previous.push(old);
        }
        self.previous.retain(|p| p != id);
        self.default = Some(id.to_owned());
        Status::Ok
    }

    pub fn volume(&self) -> u32 {
        self.volume
    }

    pub fn muted(&self) -> bool {
        self.muted
    }

    /// Something is playing on an output (an output stream is "running" and not corked).
    pub fn playing(&self) -> bool {
        self.playing
    }

    pub fn set_volume(&mut self, volume: u32) -> Status {
        let volume = volume.min(100);
        match self.pw.set_volume(volume) {
            Ok(()) => {
                self.volume = volume;
                self.publish();
                Status::Ok
            }
            Err(_) => Status::Failed,
        }
    }

    pub fn set_muted(&mut self, muted: bool) -> Status {
        match self.pw.set_muted(muted) {
            Ok(()) => {
                self.muted = muted;
                self.publish();
                Status::Ok
            }
            Err(_) => Status::Failed,
        }
    }

    /// All three channels, always present.
    pub fn channels(&self) -> BTreeMap<String, u32> {
        BTreeMap::from([
            ("ui".to_owned(), self.channels.ui),
            ("ambient".to_owned(), self.channels.ambient),
            ("media".to_owned(), self.channels.media),
        ])
    }

    pub fn set_channel(&mut self, channel: &str, value: u32) -> Status {
        let value = value.min(100);
        let mut next = self.channels;
        match channel {
            "ui" => next.ui = value,
            "ambient" => next.ambient = value,
            "media" => next.media = value,
            _ => return Status::Invalid,
        }
        if self.store.save(&next).is_err() {
            return Status::Failed;
        }
        self.channels = next;
        self.publish();
        Status::Ok
    }
}

/// Does this console hold anything a player produced? `audio.toml` (only the channel
/// sliders write it), `outputs.toml` (the saved output) or WirePlumber's saved volumes
/// (`default-routes`, `stream-properties`) in its state directory, a sibling of ours
/// (T-360). Any of them means a volume may have been chosen: nothing is forced.
pub fn existing_install(audio_toml: &Path) -> bool {
    let dir = audio_toml.parent();
    let wireplumber = dir.and_then(Path::parent).map(|p| p.join("wireplumber"));
    let sibling = |name: &str| dir.is_some_and(|d| d.join(name).exists());
    audio_toml.exists()
        || sibling("outputs.toml")
        || wireplumber.is_some_and(|w| {
            ["default-routes", "stream-properties"]
                .iter()
                .any(|f| w.join(f).exists())
        })
}

/// A profile of a fake sound card: the ports it can carry and whether it has a sink at all.
#[derive(Clone)]
pub struct FakeProfile {
    pub name: String,
    pub ports: Vec<(String, OutKind, Avail)>,
    pub sink: bool,
}

/// A fake sound card (T-347): one active profile and route, like PipeWire shows it, and the
/// volume WirePlumber keeps per route.
#[derive(Clone)]
pub struct FakeCard {
    pub name: String,
    pub profiles: Vec<FakeProfile>,
    pub active: String,
    pub route: String,
    /// The volume each route had when it was left (WirePlumber's route persistence).
    pub volumes: BTreeMap<String, u32>,
    /// What a route never seen before starts at (WirePlumber's own default, 40).
    pub fresh_volume: u32,
}

impl FakeCard {
    /// The Dell: `analog` (speaker, empty headphone jack), `hdmi` (a monitor, no ELD yet) and
    /// `off` (no sink). Starts on `analog` and the speaker.
    pub fn dell() -> FakeCard {
        let profile = |name: &str, sink: bool, ports: Vec<(&str, OutKind, Avail)>| FakeProfile {
            name: name.to_owned(),
            sink,
            ports: ports
                .into_iter()
                .map(|(p, k, a)| (p.to_owned(), k, a))
                .collect(),
        };
        FakeCard {
            name: "card".to_owned(),
            profiles: vec![
                profile(
                    "analog",
                    true,
                    vec![
                        ("spk", OutKind::Speaker, Avail::Unknown),
                        ("hp", OutKind::Headphones, Avail::No),
                    ],
                ),
                profile("hdmi", true, vec![("tv", OutKind::Hdmi, Avail::Unknown)]),
                profile(
                    "dead",
                    false,
                    vec![("ghost", OutKind::Hdmi, Avail::Unknown)],
                ),
                profile("off", false, vec![]),
            ],
            active: "analog".to_owned(),
            route: "spk".to_owned(),
            volumes: BTreeMap::new(),
            fresh_volume: 40,
        }
    }

    fn active_profile(&self) -> Option<&FakeProfile> {
        self.profiles.iter().find(|p| p.name == self.active)
    }

    fn node(&self) -> String {
        format!("{}.{}", self.name, self.active)
    }
}

/// An in-memory PipeWire for tests and `--session` development: an HDMI and an analog output.
#[derive(Clone)]
pub struct FakePipeWire {
    pub sinks: Vec<Sink>,
    /// The card's outputs; `None` derives one per sink (an HDMI sink has a valid ELD).
    pub outputs: Option<Vec<Output>>,
    /// The nodes a tone was played on.
    pub tones: Vec<String>,
    pub default: Option<String>,
    pub volume: u32,
    pub muted: bool,
    pub playing: bool,
    /// Make every write fail (to test the "failed" status).
    pub broken: bool,
    /// Make every read fail (PipeWire not up yet at boot).
    pub read_fails: bool,
    /// A sound card with profiles; when set it decides `sinks` and `outputs` (T-347).
    pub card: Option<FakeCard>,
    /// How often a volume was written (the service must not write a volume it need not).
    pub volume_writes: u32,
    /// How long a profile switch takes (a real card needs seconds).
    pub switch_delay: std::time::Duration,
}

impl FakePipeWire {
    pub fn new() -> Self {
        let sink = |id: &str, name: &str, kind| Sink {
            id: id.to_owned(),
            name: name.to_owned(),
            kind,
        };
        FakePipeWire {
            sinks: vec![
                sink("hdmi-0", "TV (HDMI)", Kind::Hdmi),
                sink("analog-0", "Analog output", Kind::Analog),
            ],
            outputs: None,
            tones: Vec::new(),
            default: Some("hdmi-0".to_owned()),
            volume: 50,
            muted: false,
            playing: false,
            broken: false,
            read_fails: false,
            card: None,
            volume_writes: 0,
            switch_delay: std::time::Duration::ZERO,
        }
    }

    /// A fake with one sound card; the default is its active sink, at the volume it starts at.
    pub fn with_card(card: FakeCard) -> Self {
        let mut pw = FakePipeWire::new();
        pw.volume = card.fresh_volume;
        pw.card = Some(card);
        pw.sync_card();
        pw.default = pw.sinks.first().map(|s| s.id.clone());
        pw
    }

    /// Rebuilds the sinks and outputs from the card: only the active profile has a sink, and
    /// only the route in use is tied to it.
    fn sync_card(&mut self) {
        let Some(card) = &self.card else { return };
        self.sinks.clear();
        if card.active_profile().is_some_and(|p| p.sink) {
            let kind = match card
                .profiles
                .iter()
                .flat_map(|p| &p.ports)
                .find(|p| p.0 == card.route)
            {
                Some((_, OutKind::Hdmi, _)) => Kind::Hdmi,
                _ => Kind::Analog,
            };
            self.sinks.push(Sink {
                id: card.node(),
                name: card.node(),
                kind,
            });
        }
        let mut outputs = Vec::new();
        for profile in &card.profiles {
            for (port, kind, available) in &profile.ports {
                let live = profile.name == card.active && profile.sink && *port == card.route;
                outputs.push(Output {
                    id: format!("{}:{port}", card.name),
                    name: port.clone(),
                    kind: *kind,
                    card: card.name.clone(),
                    port: port.clone(),
                    available: *available,
                    node: live.then(|| card.node()),
                });
            }
        }
        self.outputs = Some(outputs);
    }

    /// Moves the card to the profile and route, keeping each route's volume as WirePlumber does.
    fn move_card(&mut self, profile: &str, route: &str) {
        let Some(card) = &mut self.card else { return };
        if card.active_profile().is_some_and(|p| p.sink) {
            card.volumes.insert(card.route.clone(), self.volume);
        }
        card.active = profile.to_owned();
        card.route = route.to_owned();
        self.volume = card
            .volumes
            .get(route)
            .copied()
            .unwrap_or(card.fresh_volume);
        self.sync_card();
    }
}

impl Default for FakePipeWire {
    fn default() -> Self {
        Self::new()
    }
}

impl PipeWire for FakePipeWire {
    fn snapshot(&mut self) -> Result<Snapshot, String> {
        if self.read_fails {
            return Err("PipeWire is not up".to_owned());
        }
        let outputs = self.outputs.clone().unwrap_or_else(|| {
            self.sinks
                .iter()
                .map(|s| {
                    let (kind, available) = match s.kind {
                        Kind::Hdmi => (OutKind::Hdmi, Avail::Yes),
                        Kind::Analog => (OutKind::Speaker, Avail::Unknown),
                        Kind::Usb => (OutKind::Usb, Avail::Yes),
                        Kind::Bluetooth => (OutKind::Bluetooth, Avail::Yes),
                    };
                    Output {
                        id: s.id.clone(),
                        name: s.name.clone(),
                        kind,
                        card: String::new(),
                        port: String::new(),
                        available,
                        node: Some(s.id.clone()),
                    }
                })
                .collect()
        });
        Ok(Snapshot {
            sinks: self.sinks.clone(),
            outputs,
            default: self.default.clone(),
            volume: self.volume,
            muted: self.muted,
            playing: self.playing,
        })
    }

    fn set_default(&mut self, id: &str) -> Result<(), String> {
        if self.broken || !self.sinks.iter().any(|s| s.id == id) {
            return Err("refused".to_owned());
        }
        self.default = Some(id.to_owned());
        Ok(())
    }

    fn card_profile(&mut self, card: &str) -> Result<String, String> {
        match &self.card {
            Some(c) if c.name == card => Ok(format!("{}/{}", c.active, c.route)),
            _ => Err("no such card".to_owned()),
        }
    }

    fn switch_to(&mut self, output: &Output) -> Result<String, String> {
        if self.broken {
            return Err("refused".to_owned());
        }
        let profile = self
            .card
            .as_ref()
            .filter(|c| c.name == output.card)
            .and_then(|c| {
                c.profiles
                    .iter()
                    .find(|p| p.ports.iter().any(|x| x.0 == output.port))
            })
            .map(|p| p.name.clone())
            .ok_or_else(|| "no profile carries it".to_owned())?;
        std::thread::sleep(self.switch_delay);
        self.move_card(&profile, &output.port);
        self.sinks
            .first()
            .map(|s| s.id.clone())
            .ok_or_else(|| "the profile has no sink".to_owned())
    }

    fn restore_profile(&mut self, card: &str, state: &str) -> Result<(), String> {
        let (profile, route) = state.split_once('/').ok_or("bad state")?;
        if !self.card.as_ref().is_some_and(|c| c.name == card) {
            return Err("no such card".to_owned());
        }
        self.move_card(profile, route);
        Ok(())
    }

    fn play_tone(&mut self, node: &str) -> Result<(), String> {
        if self.broken {
            return Err("refused".to_owned());
        }
        self.tones.push(node.to_owned());
        Ok(())
    }

    fn set_volume(&mut self, volume: u32) -> Result<(), String> {
        if self.broken {
            return Err("refused".to_owned());
        }
        self.volume = volume;
        self.volume_writes += 1;
        Ok(())
    }

    fn set_muted(&mut self, muted: bool) -> Result<(), String> {
        if self.broken {
            return Err("refused".to_owned());
        }
        self.muted = muted;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headset(id: &str, kind: Kind) -> Sink {
        Sink {
            id: id.to_owned(),
            name: id.to_owned(),
            kind,
        }
    }

    fn started() -> Audio<FakePipeWire> {
        let mut a = Audio::new(FakePipeWire::new(), Store::in_memory()).unwrap();
        a.refresh().unwrap();
        a
    }

    fn defaults(a: &Audio<FakePipeWire>) -> Vec<&str> {
        a.list_sinks()
            .into_iter()
            .filter(|(_, d)| *d)
            .map(|(s, _)| s.id.as_str())
            .collect()
    }

    #[test]
    fn first_refresh_takes_over_without_changes() {
        let mut a = Audio::new(FakePipeWire::new(), Store::in_memory()).unwrap();
        let c = a.refresh().unwrap();
        assert!(!c.any());
        assert_eq!(defaults(&a), ["hdmi-0"]);
        assert_eq!(a.volume(), 50);
        assert_eq!(a.list_sinks().len(), 2);
    }

    #[test]
    fn unknown_sink_is_refused() {
        let mut a = started();
        assert_eq!(a.set_default_sink("nope"), Status::UnknownSink);
        assert_eq!(defaults(&a), ["hdmi-0"]);
    }

    #[test]
    fn set_default_moves_pipewire_and_is_idempotent() {
        let mut a = started();
        assert_eq!(a.set_default_sink("analog-0"), Status::Ok);
        assert_eq!(a.pw.default.as_deref(), Some("analog-0"));
        assert_eq!(a.set_default_sink("analog-0"), Status::Ok);
        assert_eq!(defaults(&a), ["analog-0"]);
        assert_eq!(a.previous, ["hdmi-0"]);
    }

    #[test]
    fn set_default_failure_changes_nothing() {
        let mut a = started();
        a.pw.broken = true;
        assert_eq!(a.set_default_sink("analog-0"), Status::Failed);
        assert_eq!(defaults(&a), ["hdmi-0"]);
        assert!(a.previous.is_empty());
    }

    #[test]
    fn new_usb_or_bluetooth_sink_becomes_the_default() {
        for kind in [Kind::Usb, Kind::Bluetooth] {
            let mut a = started();
            a.pw.sinks.push(headset("hs", kind));
            let c = a.refresh().unwrap();
            assert_eq!(c.default.as_deref(), Some("hs"));
            assert!(c.sinks);
            assert_eq!(a.pw.default.as_deref(), Some("hs"));
            assert_eq!(defaults(&a), ["hs"]);
        }
    }

    #[test]
    fn new_hdmi_or_analog_sink_does_not_take_over() {
        let mut a = started();
        a.pw.sinks.push(headset("hdmi-1", Kind::Hdmi));
        a.pw.sinks.push(headset("analog-1", Kind::Analog));
        let c = a.refresh().unwrap();
        assert!(c.sinks);
        assert_eq!(c.default, None);
        assert_eq!(defaults(&a), ["hdmi-0"]);
    }

    #[test]
    fn when_the_default_goes_the_previous_one_comes_back() {
        let mut a = started();
        a.set_default_sink("analog-0");
        a.pw.sinks.push(headset("hs", Kind::Usb));
        a.refresh().unwrap();
        // Unplug: PipeWire itself would pick any output; the policy wants analog-0 (previous).
        a.pw.sinks.retain(|s| s.id != "hs");
        a.pw.default = Some("hdmi-0".to_owned());
        let c = a.refresh().unwrap();
        assert_eq!(c.default.as_deref(), Some("analog-0"));
        assert_eq!(a.pw.default.as_deref(), Some("analog-0"));
        assert_eq!(defaults(&a), ["analog-0"]);
    }

    #[test]
    fn previous_that_is_gone_too_is_skipped() {
        let mut a = started();
        a.pw.sinks.push(headset("usb-1", Kind::Usb));
        a.refresh().unwrap();
        a.pw.sinks.push(headset("bt-1", Kind::Bluetooth));
        a.refresh().unwrap();
        // previous = [hdmi-0, usb-1]; both usb-1 and bt-1 vanish at once.
        a.pw.sinks.retain(|s| s.id != "usb-1" && s.id != "bt-1");
        a.pw.default = None;
        let c = a.refresh().unwrap();
        assert_eq!(c.default.as_deref(), Some("hdmi-0"));
    }

    #[test]
    fn with_no_previous_the_first_output_is_used() {
        let mut a = started();
        a.pw.sinks.retain(|s| s.id != "hdmi-0");
        a.pw.default = None;
        let c = a.refresh().unwrap();
        assert_eq!(c.default.as_deref(), Some("analog-0"));
    }

    #[test]
    fn last_output_gone_means_no_default() {
        let mut a = started();
        a.pw.sinks.clear();
        a.pw.default = None;
        let c = a.refresh().unwrap();
        assert_eq!(c.default.as_deref(), Some(""));
        assert!(defaults(&a).is_empty());
    }

    #[test]
    fn default_changed_from_outside_is_adopted_and_remembered() {
        let mut a = started();
        a.pw.default = Some("analog-0".to_owned());
        let c = a.refresh().unwrap();
        assert_eq!(c.default.as_deref(), Some("analog-0"));
        assert_eq!(a.previous, ["hdmi-0"]);
    }

    #[test]
    fn playing_follows_pipewire_and_is_announced() {
        let mut a = started();
        assert!(!a.playing());
        a.pw.playing = true;
        assert!(a.refresh().unwrap().props);
        assert!(a.playing());
        assert!(!a.refresh().unwrap().props, "no change, no announcement");
        a.pw.playing = false;
        assert!(a.refresh().unwrap().props);
        assert!(!a.playing());
    }

    #[test]
    fn volume_and_mute_clamp_and_reach_pipewire() {
        let mut a = started();
        assert_eq!(a.set_volume(250), Status::Ok);
        assert_eq!((a.volume(), a.pw.volume), (100, 100));
        assert_eq!(a.set_muted(true), Status::Ok);
        assert!(a.muted() && a.pw.muted);
        a.pw.broken = true;
        assert_eq!(a.set_volume(10), Status::Failed);
        assert_eq!(a.volume(), 100);
    }

    #[test]
    fn volume_changed_from_outside_is_reported() {
        let mut a = started();
        a.pw.volume = 20;
        a.pw.muted = true;
        let c = a.refresh().unwrap();
        assert!(c.props && !c.sinks && c.default.is_none());
        assert_eq!((a.volume(), a.muted()), (20, true));
        assert!(!a.refresh().unwrap().any());
    }

    #[test]
    fn channels_are_always_present_clamped_and_validated() {
        let mut a = started();
        let c = a.channels();
        assert_eq!(c.len(), 3);
        assert!(c.values().all(|v| *v == 100));
        assert_eq!(a.set_channel("media", 500), Status::Ok);
        assert_eq!(a.set_channel("ui", 30), Status::Ok);
        assert_eq!(a.channels()["ui"], 30);
        assert_eq!(a.channels()["media"], 100);
        assert_eq!(a.set_channel("bass", 10), Status::Invalid);
        assert_eq!(a.channels().len(), 3);
    }

    #[test]
    fn channel_levels_persist() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("audio.toml");
        let mut a = Audio::new(FakePipeWire::new(), Store::at(&path)).unwrap();
        a.set_channel("ambient", 40);
        let b = Audio::new(FakePipeWire::new(), Store::at(&path)).unwrap();
        assert_eq!(b.channels()["ambient"], 40);
    }

    #[test]
    fn failed_save_keeps_the_old_level() {
        let dir = tempfile::tempdir().unwrap();
        // The store path is a directory: the write fails.
        let mut a = Audio::new(FakePipeWire::new(), Store::in_memory()).unwrap();
        a.store = Store::at(dir.path());
        assert_eq!(a.set_channel("ui", 10), Status::Failed);
        assert_eq!(a.channels()["ui"], 100);
    }

    /// Outputs of a card are tied to a sink only while their profile is active.
    fn out(id: &str, kind: OutKind, available: Avail, node: Option<&str>) -> Output {
        Output {
            id: id.to_owned(),
            name: id.to_owned(),
            kind,
            card: "card".to_owned(),
            port: id.to_owned(),
            available,
            node: node.map(str::to_owned),
        }
    }

    /// The Dell: the speaker's sink is the only one (the active profile); the headphones jack is
    /// empty; the monitor's HDMI port is on an inactive profile, so no sink (T-347 activates it).
    fn dell_pw(default: Option<&str>) -> FakePipeWire {
        let mut pw = FakePipeWire::new();
        pw.sinks = vec![headset("spk-node", Kind::Analog)];
        pw.outputs = Some(vec![
            out("spk", OutKind::Speaker, Avail::Unknown, Some("spk-node")),
            out("hp", OutKind::Headphones, Avail::No, None),
            out("tv", OutKind::Hdmi, Avail::Yes, None),
        ]);
        pw.default = default.map(str::to_owned);
        pw
    }

    /// A TV whose profile is active: both a sink and an output.
    fn tv_on(pw: &mut FakePipeWire) {
        pw.sinks.push(headset("tv-node", Kind::Hdmi));
        if let Some(outs) = &mut pw.outputs {
            outs.retain(|o| o.id != "tv");
            outs.push(out("tv", OutKind::Hdmi, Avail::Yes, Some("tv-node")));
        }
    }

    fn with_choice(pw: FakePipeWire, dir: &std::path::Path) -> Audio<FakePipeWire> {
        Audio::new(pw, Store::in_memory())
            .unwrap()
            .with_choice_store(ChoiceStore::at(&dir.join("outputs.toml")))
            .unwrap()
    }

    fn saved_file(dir: &std::path::Path) -> Choice {
        ChoiceStore::at(&dir.join("outputs.toml")).load().unwrap()
    }

    #[test]
    fn nothing_plugged_the_speaker_is_the_default_at_start() {
        let mut a = Audio::new(dell_pw(None), Store::in_memory()).unwrap();
        a.refresh().unwrap();
        assert_eq!(a.default_sink(), Some("spk-node"));
        assert_eq!(a.pw.default.as_deref(), Some("spk-node"));
    }

    #[test]
    fn a_stale_remembered_default_is_overridden_at_start() {
        // default.configured.audio.sink names a node that does not exist this boot.
        let mut a = Audio::new(dell_pw(Some("alsa_output.gone")), Store::in_memory()).unwrap();
        a.refresh().unwrap();
        assert_eq!(a.pw.default.as_deref(), Some("spk-node"));
    }

    #[test]
    fn the_saved_output_present_at_start_is_the_default_whatever_wireplumber_kept() {
        let dir = tempfile::tempdir().unwrap();
        let mut pw = dell_pw(Some("spk-node"));
        tv_on(&mut pw);
        let mut first = with_choice(pw.clone(), dir.path());
        first.refresh().unwrap();
        assert_eq!(first.set_output("tv"), Status::Ok);
        // Reboot: a new service; WirePlumber remembered the speaker.
        let mut a = with_choice(pw, dir.path());
        a.refresh().unwrap();
        assert_eq!(a.pw.default.as_deref(), Some("tv-node"));
        assert_eq!(a.default_sink(), Some("tv-node"));
        assert!(a
            .list_outputs()
            .iter()
            .any(|(o, d, s)| o.id == "tv" && *d && *s));
    }

    #[test]
    fn a_saved_output_that_is_absent_gives_the_fallback_keeps_the_choice_and_returns() {
        let dir = tempfile::tempdir().unwrap();
        let mut pw = dell_pw(Some("spk-node"));
        tv_on(&mut pw);
        let mut first = with_choice(pw, dir.path());
        first.refresh().unwrap();
        first.set_output("tv");
        // Reboot with the TV off: its sink and output are gone, the default is stale.
        let mut off = dell_pw(Some("tv-node"));
        off.outputs = Some(vec![out(
            "spk",
            OutKind::Speaker,
            Avail::Unknown,
            Some("spk-node"),
        )]);
        let mut a = with_choice(off, dir.path());
        a.refresh().unwrap();
        assert_eq!(a.pw.default.as_deref(), Some("spk-node"), "fallback");
        assert_eq!(
            saved_file(dir.path()).saved.as_deref(),
            Some("tv"),
            "choice kept"
        );
        // The TV is switched on late: it becomes the default again at once.
        tv_on(&mut a.pw);
        let c = a.refresh().unwrap();
        assert_eq!(c.default.as_deref(), Some("tv-node"));
        assert!(c.outputs);
        assert_eq!(a.pw.default.as_deref(), Some("tv-node"));
    }

    #[test]
    fn plugging_hdmi_audio_does_not_steal_the_default_unless_chosen() {
        let mut a = Audio::new(dell_pw(Some("spk-node")), Store::in_memory()).unwrap();
        a.refresh().unwrap();
        // The monitor is unplugged at first (the policy chose the speaker), then plugged.
        let mut off = a.pw.outputs.clone().unwrap();
        off[2].available = Avail::No;
        a.pw.outputs = Some(off);
        a.refresh().unwrap();
        tv_on(&mut a.pw);
        let c = a.refresh().unwrap();
        assert!(c.outputs && c.default.is_none());
        assert_eq!(a.pw.default.as_deref(), Some("spk-node"));
        assert_eq!(a.set_output("tv"), Status::Ok);
        assert_eq!(a.pw.default.as_deref(), Some("tv-node"));
    }

    #[test]
    fn headphones_in_the_jack_take_over_and_the_speaker_returns_when_unplugged() {
        let mut pw = dell_pw(Some("spk-node"));
        pw.sinks.push(headset("hp-node", Kind::Analog));
        let mut a = Audio::new(pw, Store::in_memory()).unwrap();
        a.refresh().unwrap();
        let mut outs = a.pw.outputs.clone().unwrap();
        outs[1] = out("hp", OutKind::Headphones, Avail::Yes, Some("hp-node"));
        a.pw.outputs = Some(outs);
        let c = a.refresh().unwrap();
        assert_eq!(c.default.as_deref(), Some("hp-node"));
        // Unplugged: the sink goes with the route.
        a.pw.sinks.retain(|s| s.id != "hp-node");
        let mut outs = a.pw.outputs.clone().unwrap();
        outs[1] = out("hp", OutKind::Headphones, Avail::No, None);
        a.pw.outputs = Some(outs);
        a.pw.default = None;
        let c = a.refresh().unwrap();
        assert_eq!(c.default.as_deref(), Some("spk-node"));
    }

    #[test]
    fn choosing_the_speaker_over_a_monitor_rejects_the_monitor_and_reset_forgets_it() {
        let dir = tempfile::tempdir().unwrap();
        let mut pw = dell_pw(Some("spk-node"));
        tv_on(&mut pw);
        let mut a = with_choice(pw, dir.path());
        a.refresh().unwrap();
        assert_eq!(
            a.default_sink(),
            Some("tv-node"),
            "an ELD wins without a choice"
        );
        assert_eq!(a.set_output("spk"), Status::Ok);
        let c = saved_file(dir.path());
        assert_eq!(c.saved.as_deref(), Some("spk"));
        assert!(c.rejected.contains("tv"));
        assert_eq!(a.reset_choice(), Status::Ok);
        assert_eq!(a.default_sink(), Some("tv-node"));
        let c = saved_file(dir.path());
        assert!(c.saved.is_none() && c.rejected.is_empty());
    }

    #[test]
    fn set_output_and_test_output_statuses() {
        let mut a = Audio::new(dell_pw(Some("spk-node")), Store::in_memory()).unwrap();
        a.refresh().unwrap();
        assert_eq!(a.set_output("nope"), Status::UnknownOutput);
        assert_eq!(a.test_output("nope"), Status::UnknownOutput);
        // The monitor's profile is not active yet: no sink, nothing saved.
        assert_eq!(a.set_output("tv"), Status::Inactive);
        assert_eq!(a.test_output("tv"), Status::Inactive);
        assert!(a.list_outputs().iter().all(|(_, _, saved)| !saved));
        // A tone leaves the default and the saved choice alone.
        assert_eq!(a.test_output("spk"), Status::Ok);
        assert_eq!(a.pw.tones, ["spk-node"]);
        assert_eq!(a.default_sink(), Some("spk-node"));
        assert!(a.list_outputs().iter().all(|(_, _, saved)| !saved));
        a.pw.broken = true;
        assert_eq!(a.test_output("spk"), Status::Failed);
    }

    #[test]
    fn list_outputs_marks_default_and_saved() {
        let mut a = Audio::new(dell_pw(None), Store::in_memory()).unwrap();
        a.refresh().unwrap();
        assert_eq!(a.set_output("spk"), Status::Ok);
        let rows: Vec<_> = a
            .list_outputs()
            .iter()
            .map(|(o, d, s)| (o.id.clone(), *d, *s))
            .collect();
        assert_eq!(
            rows,
            [
                ("spk".into(), true, true),
                ("hp".into(), false, false),
                ("tv".into(), false, false)
            ]
        );
    }

    // --- T-347: card profiles and volumes ---

    const MARKER: &str = "first-volume-done";

    /// The Dell card with the marker in `dir`; the choice file lives there too.
    fn card_audio(pw: FakePipeWire, dir: &std::path::Path) -> Audio<FakePipeWire> {
        with_choice(pw, dir).with_first_start_marker(&dir.join(MARKER), false)
    }

    #[test]
    fn choose_output_switches_the_card_profile() {
        let dir = tempfile::tempdir().unwrap();
        let mut a = card_audio(FakePipeWire::with_card(FakeCard::dell()), dir.path());
        a.refresh().unwrap();
        assert_eq!(a.default_sink(), Some("card.analog"));
        // The HDMI port is listed and selectable although its profile is not the active one.
        let ids: Vec<_> = a
            .list_outputs()
            .iter()
            .map(|(o, _, _)| o.id.clone())
            .collect();
        assert!(ids.contains(&"card:tv".to_owned()));
        assert_eq!(a.set_output("card:tv"), Status::Ok);
        assert_eq!(a.pw.card.as_ref().unwrap().active, "hdmi");
        assert_eq!(a.default_sink(), Some("card.hdmi"));
        assert_eq!(a.pw.default.as_deref(), Some("card.hdmi"));
        assert_eq!(saved_file(dir.path()).saved.as_deref(), Some("card:tv"));
        // The next read agrees, and the speaker is still listed and reachable.
        a.refresh().unwrap();
        assert_eq!(a.default_sink(), Some("card.hdmi"));
        assert!(a
            .list_outputs()
            .iter()
            .any(|(o, d, s)| o.id == "card:tv" && *d && *s));
        assert_eq!(a.set_output("card:spk"), Status::Ok);
        assert_eq!(a.pw.card.as_ref().unwrap().active, "analog");
        assert_eq!(a.default_sink(), Some("card.analog"));
    }

    #[test]
    fn the_policy_may_pick_an_hdmi_port_on_an_inactive_profile() {
        let mut card = FakeCard::dell();
        card.profiles[1].ports[0].2 = Avail::Yes; // the monitor announced itself
        let mut a = Audio::new(FakePipeWire::with_card(card), Store::in_memory()).unwrap();
        a.refresh().unwrap();
        assert_eq!(a.default_sink(), Some("card.hdmi"));
        assert_eq!(a.pw.card.as_ref().unwrap().active, "hdmi");
    }

    #[test]
    fn an_empty_first_read_waits_for_the_outputs_and_then_applies_the_policy() {
        let mut pw = FakePipeWire::with_card(FakeCard::dell());
        pw.card.as_mut().unwrap().profiles[1].ports[0].2 = Avail::Yes;
        pw.sinks.clear();
        pw.outputs = Some(Vec::new());
        pw.default = None;
        let card = pw.card.take();
        let mut a = Audio::new(pw, Store::in_memory()).unwrap();
        assert_eq!(a.refresh().unwrap().default, None);
        assert_eq!(a.default_sink(), None);
        // WirePlumber is up: the card appears on its analog profile with a remembered default.
        a.pw.card = card;
        a.pw.sync_card();
        a.pw.default = Some("card.analog".to_owned());
        // The watcher's late read reports what appeared (the very first read cannot: nobody listens).
        let late = a.refresh().unwrap();
        assert!(late.sinks && late.outputs, "{late:?}");
        assert_eq!(late.default.as_deref(), Some("card.hdmi"));
        assert_eq!(a.default_sink(), Some("card.hdmi"));
    }

    #[test]
    fn an_existing_install_gets_the_marker_and_no_forced_volume() {
        let dir = tempfile::tempdir().unwrap();
        let mut pw = FakePipeWire::with_card(FakeCard::dell());
        pw.volume = 25; // what the player chose before this update
        let mut a =
            with_choice(pw, dir.path()).with_first_start_marker(&dir.path().join(MARKER), true);
        assert!(dir.path().join(MARKER).exists());
        a.refresh().unwrap();
        assert_eq!((a.volume(), a.pw.volume_writes), (25, 0));
    }

    #[test]
    fn test_output_restores_the_profile() {
        let dir = tempfile::tempdir().unwrap();
        let mut a = card_audio(FakePipeWire::with_card(FakeCard::dell()), dir.path());
        a.refresh().unwrap();
        assert_eq!(a.test_output("card:tv"), Status::Ok);
        assert_eq!(a.pw.tones, ["card.hdmi"]);
        let card = a.pw.card.as_ref().unwrap();
        assert_eq!(
            (card.active.as_str(), card.route.as_str()),
            ("analog", "spk")
        );
        assert_eq!(a.pw.default.as_deref(), Some("card.analog"));
        assert_eq!(a.default_sink(), Some("card.analog"));
        assert!(saved_file(dir.path()).saved.is_none());
        // The speaker's own volume came back with its route.
        a.refresh().unwrap();
        assert_eq!(a.volume(), 100);
    }

    #[test]
    fn a_card_is_never_left_without_a_sink() {
        let dir = tempfile::tempdir().unwrap();
        let mut a = card_audio(FakePipeWire::with_card(FakeCard::dell()), dir.path());
        a.refresh().unwrap();
        // A profile that has no sink: the choice is refused and the old profile comes back.
        assert_eq!(a.set_output("card:ghost"), Status::Inactive);
        let card = a.pw.card.as_ref().unwrap();
        assert_eq!(card.active, "analog");
        assert_eq!(a.pw.sinks.len(), 1);
        assert_eq!(a.pw.default.as_deref(), Some("card.analog"));
        assert!(saved_file(dir.path()).saved.is_none());
        // The same for a tone.
        assert_ne!(a.test_output("card:ghost"), Status::Ok);
        assert_eq!(a.pw.card.as_ref().unwrap().active, "analog");
        assert_eq!(a.pw.sinks.len(), 1);
        assert_eq!(a.default_sink(), Some("card.analog"));
    }

    #[test]
    fn first_output_starts_at_full_volume() {
        let dir = tempfile::tempdir().unwrap();
        let mut a = card_audio(FakePipeWire::with_card(FakeCard::dell()), dir.path());
        assert_eq!(a.pw.volume, 40, "WirePlumber's own default");
        a.refresh().unwrap();
        assert_eq!(a.pw.volume, 100);
        assert_eq!(a.volume(), 100);
        // The second output starts at the first volume too, not at WirePlumber's 0.40 (T-360).
        assert_eq!(a.set_output("card:tv"), Status::Ok);
        assert_eq!(a.pw.volume, 100);
    }

    #[test]
    fn first_start_volume_waits_for_the_first_output() {
        let dir = tempfile::tempdir().unwrap();
        let mut pw = FakePipeWire::with_card(FakeCard::dell());
        let card = pw.card.take();
        pw.sinks.clear();
        pw.outputs = Some(Vec::new());
        pw.default = None;
        let mut a = card_audio(pw, dir.path());
        a.refresh().unwrap();
        assert_eq!(a.pw.volume_writes, 0);
        assert!(!dir.path().join(MARKER).exists());
        a.pw.card = card;
        a.pw.sync_card();
        a.pw.default = Some("card.analog".to_owned());
        a.refresh().unwrap();
        assert_eq!(a.pw.volume, 100);
        assert!(dir.path().join(MARKER).exists());
    }

    #[test]
    fn first_start_volume_is_applied_once_and_the_marker_is_written() {
        let dir = tempfile::tempdir().unwrap();
        let mut a = card_audio(FakePipeWire::with_card(FakeCard::dell()), dir.path());
        assert!(!dir.path().join(MARKER).exists());
        a.refresh().unwrap();
        assert!(dir.path().join(MARKER).exists());
        assert_eq!(a.pw.volume_writes, 1);
        // Reads and the way back to a known output write no volume again; an output used for
        // the first time gets its own first volume once (one more write).
        a.refresh().unwrap();
        assert_eq!(a.set_output("card:tv"), Status::Ok);
        a.refresh().unwrap();
        assert_eq!(a.set_output("card:spk"), Status::Ok);
        a.refresh().unwrap();
        assert_eq!(a.pw.volume_writes, 2);
    }

    #[test]
    fn first_start_volume_never_reapplies_after_the_player_changed_it() {
        let dir = tempfile::tempdir().unwrap();
        let mut a = card_audio(FakePipeWire::with_card(FakeCard::dell()), dir.path());
        a.refresh().unwrap();
        assert_eq!(a.set_volume(30), Status::Ok);
        // The service restarts (and the machine reboots: PipeWire keeps what WirePlumber saved).
        let pw = a.pw.clone();
        let mut b = card_audio(pw, dir.path());
        b.refresh().unwrap();
        assert_eq!(b.volume(), 30);
        assert_eq!(b.pw.volume, 30);
        assert!(dir.path().join(MARKER).exists());
        // The marker alone stops it: even a fresh PipeWire at its default stays as it is.
        let mut c = card_audio(FakePipeWire::with_card(FakeCard::dell()), dir.path());
        c.refresh().unwrap();
        assert_eq!(c.pw.volume, 40);
        assert_eq!(c.pw.volume_writes, 0);
    }

    #[test]
    fn a_set_volume_is_never_touched() {
        let dir = tempfile::tempdir().unwrap();
        let mut a = card_audio(FakePipeWire::with_card(FakeCard::dell()), dir.path());
        a.refresh().unwrap();
        assert_eq!(a.set_volume(30), Status::Ok);
        let writes = a.pw.volume_writes;
        for _ in 0..3 {
            a.refresh().unwrap();
        }
        assert_eq!(a.test_output("card:tv"), Status::Ok);
        a.refresh().unwrap();
        assert_eq!((a.volume(), a.pw.volume), (30, 30));
        assert_eq!(a.pw.volume_writes, writes);
    }

    #[test]
    fn volume_is_remembered_per_output() {
        let dir = tempfile::tempdir().unwrap();
        let mut a = card_audio(FakePipeWire::with_card(FakeCard::dell()), dir.path());
        a.refresh().unwrap();
        assert_eq!(a.set_volume(30), Status::Ok);
        assert_eq!(a.set_output("card:tv"), Status::Ok);
        a.refresh().unwrap();
        assert_eq!(
            a.volume(),
            100,
            "an output never seen starts at the first volume"
        );
        assert_eq!(a.set_volume(70), Status::Ok);
        assert_eq!(a.set_output("card:spk"), Status::Ok);
        a.refresh().unwrap();
        assert_eq!(a.volume(), 30);
        assert_eq!(a.set_output("card:tv"), Status::Ok);
        a.refresh().unwrap();
        assert_eq!(a.volume(), 70);
    }

    #[test]
    fn a_new_output_starts_at_the_first_volume() {
        let dir = tempfile::tempdir().unwrap();
        let mut a = card_audio(FakePipeWire::with_card(FakeCard::dell()), dir.path());
        a.refresh().unwrap();
        assert_eq!(a.set_volume(30), Status::Ok);
        assert_eq!(a.set_output("card:tv"), Status::Ok);
        a.refresh().unwrap();
        assert_eq!((a.volume(), a.pw.volume), (FIRST_VOLUME, FIRST_VOLUME));
        // Back on a known output: the volume WirePlumber saved for it, not the first volume.
        assert_eq!(a.set_output("card:spk"), Status::Ok);
        a.refresh().unwrap();
        assert_eq!(a.volume(), 30);
        // The memory survives a restart, and a reset of the choice.
        assert_eq!(a.reset_choice(), Status::Ok);
        let pw = a.pw.clone();
        let mut b = card_audio(pw, dir.path());
        b.refresh().unwrap();
        assert_eq!(b.set_output("card:tv"), Status::Ok);
        b.refresh().unwrap();
        assert_eq!(b.volume(), FIRST_VOLUME);
        assert_eq!(b.set_output("card:spk"), Status::Ok);
        b.refresh().unwrap();
        assert_eq!(b.volume(), 30);
    }

    #[test]
    fn the_policy_is_reapplied_on_the_first_non_empty_list() {
        // PipeWire already has the card's sink, but WirePlumber has not listed the outputs yet.
        let mut pw = FakePipeWire::with_card(FakeCard::dell());
        pw.card.as_mut().unwrap().profiles[1].ports[0].2 = Avail::Yes;
        pw.outputs = Some(Vec::new());
        let mut a = Audio::new(pw, Store::in_memory()).unwrap();
        a.refresh().unwrap();
        assert_eq!(a.default_sink(), Some("card.analog"));
        // The outputs arrive: a monitor with a valid ELD outranks the speaker.
        a.pw.sync_card();
        let late = a.refresh().unwrap();
        assert_eq!(late.default.as_deref(), Some("card.hdmi"));
        assert_eq!(a.default_sink(), Some("card.hdmi"));
    }

    #[test]
    fn saved_outputs_count_as_an_existing_install() {
        let root = tempfile::tempdir().unwrap();
        let state = root.path().join("ruya-devices");
        std::fs::create_dir_all(&state).unwrap();
        let audio_toml = state.join("audio.toml");
        assert!(!existing_install(&audio_toml), "a fresh console");
        std::fs::write(
            state.join("outputs.toml"),
            "saved = \"card:tv\"
",
        )
        .unwrap();
        assert!(existing_install(&audio_toml), "a saved output");
        std::fs::remove_file(state.join("outputs.toml")).unwrap();
        let wp = root.path().join("wireplumber");
        std::fs::create_dir_all(&wp).unwrap();
        assert!(
            !existing_install(&audio_toml),
            "an empty WirePlumber directory"
        );
        std::fs::write(
            wp.join("default-routes"),
            "[default-routes]
",
        )
        .unwrap();
        assert!(existing_install(&audio_toml), "WirePlumber's saved volumes");
        std::fs::remove_file(wp.join("default-routes")).unwrap();
        std::fs::write(
            &audio_toml,
            "ui = 50
",
        )
        .unwrap();
        assert!(existing_install(&audio_toml), "channel sliders");
    }

    #[test]
    fn a_failed_boot_read_does_not_silence_the_first_good_read() {
        let dir = tempfile::tempdir().unwrap();
        let mut pw = FakePipeWire::with_card(FakeCard::dell());
        pw.read_fails = true;
        let mut a = card_audio(pw, dir.path());
        assert!(a.refresh().is_err());
        a.pw.read_fails = false;
        // The shell listens by now: what the watcher finds is announced.
        let first_good = a.refresh().unwrap();
        assert!(first_good.sinks && first_good.outputs, "{first_good:?}");
        assert_eq!(first_good.default.as_deref(), Some("card.analog"));
    }
}
