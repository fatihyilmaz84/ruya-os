//! The audio rules of spec 03 §2.3: the output list, the default and its "previous" stack, the
//! hot-plug policy, master volume and mute, the three channel levels. No I/O except through
//! the `PipeWire` trait and the channel `Store`.

use std::collections::{BTreeMap, BTreeSet};

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
    /// Makes the output the default: its sink when it has one. Switching a card profile so an
    /// output without a sink gets one is T-347; until then that is an error.
    fn activate(&mut self, output: &Output) -> Result<(), String> {
        match &output.node {
            Some(node) => self.set_default(node),
            None => Err(format!("{}: its card profile is not active", output.id)),
        }
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

pub struct Audio<P: PipeWire> {
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
}

impl<P: PipeWire> Audio<P> {
    pub fn new(pw: P, store: Store) -> std::io::Result<Self> {
        let channels = store.load()?;
        Ok(Audio {
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
        })
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
        let snap = self.pw.snapshot()?;
        Ok(self.apply(snap))
    }

    fn apply(&mut self, snap: Snapshot) -> Changes {
        let mut changes = Changes::default();
        let first = !self.loaded;
        self.loaded = true;

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
            if (h.node.is_none() || h.node != default) && self.pw.activate(h).is_ok() {
                if let Some(n) = &h.node {
                    default = Some(n.clone());
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
        if first {
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
            if self.pw.activate(o).is_ok() {
                if let Some(n) = &o.node {
                    *default = Some(n.clone());
                }
                return;
            }
        }
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
        if !on_it && self.pw.activate(&out).is_err() {
            return if out.node.is_none() {
                Status::Inactive
            } else {
                Status::Failed
            };
        }
        if self.choice_store.save(&next).is_err() {
            return Status::Failed;
        }
        self.choice = next;
        if !on_it {
            if let Some(old) = self.default.take() {
                self.previous.retain(|p| *p != old);
                self.previous.push(old);
            }
            if let Some(node) = &out.node {
                self.previous.retain(|p| p != node);
                self.default = Some(node.clone());
            }
        }
        Status::Ok
    }

    /// A short tone on the output, without touching the default.
    pub fn test_output(&mut self, id: &str) -> Status {
        let Some(node) = self
            .outputs
            .iter()
            .find(|o| o.id == id)
            .map(|o| o.node.clone())
        else {
            return Status::UnknownOutput;
        };
        match node {
            None => Status::Inactive,
            Some(node) => match self.pw.play_tone(&node) {
                Ok(()) => Status::Ok,
                Err(_) => Status::Failed,
            },
        }
    }

    /// Forgets the saved choice and the rejected outputs and applies the policy table now.
    pub fn reset_choice(&mut self) -> Status {
        if self.choice_store.save(&Choice::default()).is_err() {
            return Status::Failed;
        }
        self.choice = Choice::default();
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
                Status::Ok
            }
            Err(_) => Status::Failed,
        }
    }

    pub fn set_muted(&mut self, muted: bool) -> Status {
        match self.pw.set_muted(muted) {
            Ok(()) => {
                self.muted = muted;
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
        Status::Ok
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
        }
    }
}

impl Default for FakePipeWire {
    fn default() -> Self {
        Self::new()
    }
}

impl PipeWire for FakePipeWire {
    fn snapshot(&mut self) -> Result<Snapshot, String> {
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
        assert_eq!(saved_file(dir.path()), Choice::default());
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
}
