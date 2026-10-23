//! The audio rules of spec 03 §2.3: the output list, the default and its "previous" stack, the
//! hot-plug policy, master volume and mute, the three channel levels. No I/O except through
//! the `PipeWire` trait and the channel `Store`.

use std::collections::BTreeMap;

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

    /// Outputs a user plugs in on purpose: they take over when they appear.
    fn is_headset(self) -> bool {
        matches!(self, Kind::Usb | Kind::Bluetooth)
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
    Invalid,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::UnknownSink => "unknown-sink",
            Status::Invalid => "invalid",
            Status::Failed => "failed",
        }
    }
}

/// What PipeWire says right now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub sinks: Vec<Sink>,
    pub default: Option<String>,
    pub volume: u32,
    pub muted: bool,
}

/// The side effects: PipeWire itself. A fake serves tests and `--session`; on Linux
/// `pipewire::WpCtl` runs `pw-dump` and `wpctl`.
pub trait PipeWire: Send {
    fn snapshot(&mut self) -> Result<Snapshot, String>;
    fn set_default(&mut self, id: &str) -> Result<(), String>;
    /// 0-100 of the default output.
    fn set_volume(&mut self, volume: u32) -> Result<(), String>;
    fn set_muted(&mut self, muted: bool) -> Result<(), String>;
}

/// What a `refresh` changed, so the adapter knows which signals to emit.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Changes {
    pub sinks: bool,
    /// The new default's id ("" when there is no output).
    pub default: Option<String>,
    /// Volume or mute.
    pub props: bool,
}

impl Changes {
    pub fn any(&self) -> bool {
        self.sinks || self.default.is_some() || self.props
    }
}

pub struct Audio<P: PipeWire> {
    pw: P,
    store: Store,
    loaded: bool,
    sinks: Vec<Sink>,
    default: Option<String>,
    /// Earlier defaults, most recent last; only used when the default goes away.
    previous: Vec<String>,
    volume: u32,
    muted: bool,
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
            default: None,
            previous: Vec::new(),
            volume: 0,
            muted: false,
            channels,
        })
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
        let added: Vec<&Sink> = snap
            .sinks
            .iter()
            .filter(|s| !self.sinks.iter().any(|o| o.id == s.id))
            .collect();
        let connected = |id: &str| snap.sinks.iter().any(|s| s.id == id);
        let default_gone = !first && old_default.as_deref().is_some_and(|d| !connected(d));
        let headset = added.iter().rev().find(|s| s.kind.is_headset());

        let mut default = snap.default.clone().filter(|d| connected(d));
        self.previous.retain(|p| connected(p));

        // Where the policy wants the default, if not where PipeWire has it.
        let target = if first {
            None
        } else if let Some(h) = headset {
            Some(h.id.clone())
        } else if default_gone {
            self.previous
                .pop()
                .or_else(|| snap.sinks.first().map(|s| s.id.clone()))
        } else {
            None
        };
        if let Some(target) = target {
            if default.as_deref() != Some(target.as_str()) && self.pw.set_default(&target).is_ok() {
                default = Some(target);
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
        if self.volume != snap.volume || self.muted != snap.muted {
            changes.props = true;
        }
        self.sinks = snap.sinks;
        self.default = default;
        self.volume = snap.volume.min(100);
        self.muted = snap.muted;
        if first {
            changes = Changes::default();
        }
        changes
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
pub struct FakePipeWire {
    pub sinks: Vec<Sink>,
    pub default: Option<String>,
    pub volume: u32,
    pub muted: bool,
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
            default: Some("hdmi-0".to_owned()),
            volume: 50,
            muted: false,
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
        Ok(Snapshot {
            sinks: self.sinks.clone(),
            default: self.default.clone(),
            volume: self.volume,
            muted: self.muted,
        })
    }

    fn set_default(&mut self, id: &str) -> Result<(), String> {
        if self.broken || !self.sinks.iter().any(|s| s.id == id) {
            return Err("refused".to_owned());
        }
        self.default = Some(id.to_owned());
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
}
