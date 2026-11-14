//! The routing core (06-input.md §5.1-5.2): who receives the pads, the shell as navigation keys
//! or the focused app's profile as virtual pads. Pure: every device side effect goes through
//! `Backend`, time is passed in, and what the D-Bus adapter must announce comes out as `Notice`s.
//!
//! Rules:
//! - Routes `shell`, `overlay` and `locked` produce navigation keys; `app` produces only Guide
//!   (`KEY_HOMEPAGE`, always the shell's) and feeds the virtual pads.
//! - Virtual pads (one per physical pad, phys `ruya-input/pad<n>`) exist only while the route is
//!   `app` or `overlay` over the same app instance and profile. Any other route, another instance
//!   or another profile destroys them (lock, switch, run end, Freeze): a descriptor the app opened
//!   reads `ENODEV`, so nothing reaches it afterwards (an ACL change would not close it).
//! - `overlay` over the pads' instance holds them in neutral (once); no input reaches them.
//! - Entering `app`, a button or axis already held is not forwarded until it is let go (no
//!   double input from the press that closed the overlay); leaving `shell`, every navigation key
//!   but Guide is released.
//! - A virtual pad's node gets one ACL entry, for the profile's user, after every udev event on
//!   it (logind's uaccess flushes it on a `change`), and is announced (`routed`) only then.
//! - The caller that set the route leaving the bus means `locked`.
//! - A virtual pad shows what the profile that applies to its pad makes of the physical pad
//!   (`engine`, 06 §7): the console profile's global profile when its `match` fits, else the
//!   built-in default. A change to the owner's profiles applies at once, to pads already made.

use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

use crate::accounts::{valid_app_id, valid_profile_id, Accounts};
use crate::acl;
use crate::activity::ActivityGate;
use crate::book::{Book, SaveAnswer, Summary};
use crate::caps::Capability;
use crate::engine::Engine;
use crate::mapping::{Axis, Button, Confirm, KeyBoard, KeyEvent, Mapper, NavKey};
use crate::pad::{
    diff, OutEvent, PadAxis, PadButton, PadInput, PadState, Rumble, TestEvent, ALL_AXES,
    PAD_PHYS_PREFIX, STICK_MAX, STICK_MIN, TRIGGER_MAX,
};
use crate::udev::UdevEvent;

pub type PadKey = u64;
pub type VirtualId = u64;

/// When no udev event arrives for a new virtual pad (the monitor is not working), the ACL is set
/// this long after creation anyway, and the journal says so.
pub const UDEV_FALLBACK: Duration = Duration::from_secs(2);

/// A button test ends this long after its pad's last input (`Input1.StartTest`).
pub const TEST_IDLE: Duration = Duration::from_secs(120);
/// A button test sends one axis at most this often: 30 times a second.
pub const TEST_AXIS_INTERVAL: Duration = Duration::from_micros(33_334);

const ENODEV: i32 = 19;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    Shell,
    App,
    Overlay,
    Locked,
}

impl Route {
    pub fn parse(s: &str) -> Option<Route> {
        Some(match s {
            "shell" => Route::Shell,
            "app" => Route::App,
            "overlay" => Route::Overlay,
            "locked" => Route::Locked,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Route::Shell => "shell",
            Route::App => "app",
            Route::Overlay => "overlay",
            Route::Locked => "locked",
        }
    }
}

/// Status strings of `Input1` (stable API, the XML header).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    Invalid,
    UnknownProfile,
    UnknownDevice,
    NotAllowed,
    Busy,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::Invalid => "invalid",
            Status::UnknownProfile => "unknown-profile",
            Status::UnknownDevice => "unknown-device",
            Status::NotAllowed => "not-allowed",
            Status::Busy => "busy",
            Status::Failed => "failed",
        }
    }
}

/// A physical pad as the Linux side found it.
#[derive(Debug, Clone, Default)]
pub struct PadInfo {
    pub id: String,
    pub name: String,
    pub family: String,
    pub connection: String,
    /// The model whose silhouette the shell draws (`identity::model`); "" = the family's.
    pub model: String,
    /// The drawing of the pad for the Button test (`identity::layout`); "" = the family's default.
    pub layout: String,
    /// The pad takes `FF_RUMBLE`: only then does its virtual pad declare it.
    pub rumble: bool,
    /// Its capability descriptor (`caps::describe`), as found when it connected.
    pub capabilities: Vec<Capability>,
}

/// One row of `ListDevices` and the device signals.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceRecord {
    pub id: String,
    pub instance: String,
    pub name: String,
    pub family: String,
    pub connection: String,
    pub model: String,
    pub layout: String,
    pub battery: i32,
    pub charging: bool,
    pub slot: u32,
    pub profile: String,
    pub routed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Notice {
    DeviceAdded(DeviceRecord),
    DeviceChanged(DeviceRecord),
    DeviceRemoved {
        id: String,
        instance: String,
    },
    RouteChanged {
        route: String,
        instance: String,
    },
    /// One input of a running button test (`TestInput`).
    TestInput {
        device_id: String,
        input: String,
        value: i32,
        source: String,
    },
    /// A button test ended (`TestEnded`): "stopped" | "idle" | "route" | "gone" | "caller".
    TestEnded {
        device_id: String,
        reason: String,
    },
    /// The controller profiles of a console profile changed (`ProfilesChanged`).
    ProfilesChanged {
        profile: String,
    },
    /// The `ConfirmButton` property changed: the active profile's mode (a switch or a set).
    ConfirmButtonChanged,
    /// The last press among the pads came from another device (`ActiveInputChanged`).
    ActiveInput {
        device_id: String,
        family: String,
    },
    /// A pad press or a stick or trigger move reached the app in front (`UserActive`, RUY-588);
    /// rate-limited by `ActivityGate`, carries nothing.
    UserActive,
    /// A journal line (without the "ruya-inputd: " prefix).
    Journal(String),
}

/// What a virtual pad is made as.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VirtualSpec {
    pub phys: String,
    pub rumble: bool,
}

/// A created virtual pad: its id and the input device's sysfs name (`input23`), which the udev
/// events of its node name in their `DEVPATH`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Created {
    pub id: VirtualId,
    pub sysname: String,
}

/// The device side effects. Linux: `linux.rs`; tests: a fake that records every call.
pub trait Backend {
    /// Writes key transitions on the "RuyaOS Navigation" keyboard.
    fn nav_keys(&mut self, events: &[KeyEvent]);
    fn create_virtual(&mut self, pad: PadKey, spec: &VirtualSpec) -> Result<Created, String>;
    /// `UI_DEV_DESTROY`: every descriptor on the node reads `ENODEV` from now on.
    fn destroy_virtual(&mut self, id: VirtualId);
    fn write_virtual(&mut self, id: VirtualId, events: &[OutEvent]);
    /// The event node of an input device (`input23` -> `/dev/input/event17`), if it exists.
    fn node_of(&mut self, sysname: &str) -> Option<String>;
    fn read_acl(&mut self, node: &str) -> Option<Vec<u8>>;
    fn write_acl(&mut self, node: &str, acl: &[u8]) -> Result<(), String>;
    /// Uploads a rumble effect to the physical pad (`physical_id` -1: a new one); its id there.
    fn ff_upload(&mut self, pad: PadKey, physical_id: i16, rumble: &Rumble) -> Result<i16, i32>;
    fn ff_play(&mut self, pad: PadKey, physical_id: i16, value: i32);
    fn ff_erase(&mut self, pad: PadKey, physical_id: i16);
}

/// No devices at all: `--session` development, where the bus contract is what is tried out.
pub struct NullBackend;

impl Backend for NullBackend {
    fn nav_keys(&mut self, _: &[KeyEvent]) {}
    fn create_virtual(&mut self, _: PadKey, _: &VirtualSpec) -> Result<Created, String> {
        Err("no uinput in --session".into())
    }
    fn destroy_virtual(&mut self, _: VirtualId) {}
    fn write_virtual(&mut self, _: VirtualId, _: &[OutEvent]) {}
    fn node_of(&mut self, _: &str) -> Option<String> {
        None
    }
    fn read_acl(&mut self, _: &str) -> Option<Vec<u8>> {
        None
    }
    fn write_acl(&mut self, _: &str, _: &[u8]) -> Result<(), String> {
        Err("no devices in --session".into())
    }
    fn ff_upload(&mut self, _: PadKey, _: i16, _: &Rumble) -> Result<i16, i32> {
        Err(ENODEV)
    }
    fn ff_play(&mut self, _: PadKey, _: i16, _: i32) {}
    fn ff_erase(&mut self, _: PadKey, _: i16) {}
}

/// The app instance and profile the virtual pads are made for.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Owner {
    instance: String,
    profile: String,
    uid: u32,
}

#[derive(Debug)]
struct Virtual {
    id: VirtualId,
    sysname: String,
    phys: String,
    n: u32,
    created: Instant,
    ready: bool,
    fallback_tried: bool,
    /// What the virtual pad shows now.
    sent: PadState,
    /// Held when the route entered `app`: not forwarded until let go.
    masked_buttons: Vec<PadButton>,
    masked_axes: Vec<PadAxis>,
    /// The app's effect id -> the physical pad's.
    ff: BTreeMap<i16, i16>,
    playing: BTreeSet<i16>,
    /// The profile that applies to this pad, compiled.
    engine: Engine,
}

/// One axis of a button test: when it was last sent, and the newest value not sent yet.
#[derive(Debug)]
struct AxisSend {
    sent: Instant,
    pending: Option<(i32, String)>,
}

/// A running button test of one pad.
#[derive(Debug)]
struct ButtonTest {
    /// The bus name that started it: the test ends when it leaves the bus.
    caller: String,
    last_input: Instant,
    axes: BTreeMap<String, AxisSend>,
    /// The caller asked for the left stick's navigation keys to be held back while it runs.
    hold_left_stick: bool,
}

#[derive(Debug)]
struct Pad {
    info: PadInfo,
    instance: String,
    mapper: Mapper,
    state: PadState,
    virt: Option<Virtual>,
    /// Left-stick axes that do not navigate until they are back near neutral: a test that held
    /// the stick's keys ended while it was pushed.
    nav_masked: Vec<PadAxis>,
}

impl Pad {
    /// Whether `input` is a left-stick value that must not reach the mapper: `hold` is a test
    /// of this pad holding the stick, or the axis still waits for neutral after one.
    fn stick_held_back(&mut self, input: PadInput, hold: bool) -> bool {
        let PadInput::Axis(axis @ (PadAxis::LeftX | PadAxis::LeftY), value) = input else {
            return false;
        };
        if hold {
            return true;
        }
        if self.nav_masked.contains(&axis) {
            if !axis_held(axis, value) {
                self.nav_masked.retain(|&a| a != axis);
            }
            return true;
        }
        false
    }
}

/// An axis this far from neutral when the route enters `app` counts as held.
fn axis_held(axis: PadAxis, value: i32) -> bool {
    let full = match axis {
        PadAxis::LeftTrigger | PadAxis::RightTrigger => TRIGGER_MAX,
        _ => STICK_MAX,
    };
    value.abs() >= full / 4
}

/// One input of a pad of `family` as navigation keys. This is the seam of the family: the
/// confirm setting reaches the shell's keys here and nowhere else (the virtual pads never see it),
/// and `family` is `PadInfo::family` (identity.rs), the same value `ActiveInputChanged` reports.
fn mapper_events(
    mapper: &mut Mapper,
    input: PadInput,
    family: &str,
    mode: Confirm,
) -> Vec<KeyEvent> {
    let button = |b| -> Option<Button> {
        Some(match b {
            PadButton::South => Button::South,
            PadButton::East => Button::East,
            PadButton::Start => Button::Start,
            PadButton::Guide => Button::Mode,
            PadButton::L1 => Button::ShoulderLeft,
            PadButton::R1 => Button::ShoulderRight,
            PadButton::DpadUp => Button::DpadUp,
            PadButton::DpadDown => Button::DpadDown,
            PadButton::DpadLeft => Button::DpadLeft,
            PadButton::DpadRight => Button::DpadRight,
            _ => return None,
        })
    };
    match input {
        PadInput::Button(b, pressed) => match button(b) {
            Some(b) => mapper.button_as(b, pressed, family, mode),
            None => Vec::new(),
        },
        PadInput::Axis(PadAxis::LeftX, v) => {
            mapper.stick(Axis::Horizontal, v, STICK_MIN, STICK_MAX)
        }
        PadInput::Axis(PadAxis::LeftY, v) => mapper.stick(Axis::Vertical, v, STICK_MIN, STICK_MAX),
        PadInput::Axis(..) => Vec::new(),
    }
}

impl Virtual {
    /// What the app may see of `state`: held-at-entry inputs and Guide masked out, then the
    /// profile's mapping (which never presses Guide either).
    fn target(&self, state: &PadState) -> PadState {
        let mut t = state.clone();
        for &b in &self.masked_buttons {
            t.apply(PadInput::Button(b, false));
        }
        for &a in &self.masked_axes {
            t.apply(PadInput::Axis(a, 0));
        }
        t.apply(PadInput::Button(PadButton::Guide, false));
        let mut out = self.engine.apply(&t);
        out.apply(PadInput::Button(PadButton::Guide, false));
        out
    }

    fn mask_held(&mut self, state: &PadState) {
        self.masked_buttons = state.buttons().to_vec();
        self.masked_axes = ALL_AXES
            .into_iter()
            .filter(|&a| axis_held(a, state.axis(a)))
            .collect();
    }

    fn unmask(&mut self, input: PadInput) {
        match input {
            PadInput::Button(b, false) => self.masked_buttons.retain(|&x| x != b),
            PadInput::Axis(a, v) if !axis_held(a, v) => self.masked_axes.retain(|&x| x != a),
            _ => {}
        }
    }
}

pub struct Router<B: Backend> {
    backend: B,
    accounts: Box<dyn Accounts>,
    route: Route,
    instance: String,
    app_id: String,
    profile: String,
    /// The bus name that set the route.
    caller: Option<String>,
    owner: Option<Owner>,
    pads: BTreeMap<PadKey, Pad>,
    board: KeyBoard,
    next_key: PadKey,
    next_instance: u64,
    notices: Vec<Notice>,
    /// Running button tests, by stable device id.
    tests: BTreeMap<String, ButtonTest>,
    /// The controller profiles of every console profile.
    book: Book,
    /// The stable id of the pad whose press was announced last (`ActiveInputChanged`).
    active_input: Option<String>,
    /// The stable id of the signed-in profile's active controller: the pad that gave the last input
    /// when the route first went to the profile (the sign-in). Kept until the profile changes (06 5.1).
    profile_pad: Option<String>,
    /// The stable id of the pad that pressed last since the profile last changed. Only such a pad can
    /// become the next profile's `profile_pad`; a keyboard sign-in leaves it `None` (ADR-017 am. 6b).
    pad_since_change: Option<String>,
    /// When pad input in `app` is announced to the shell as activity (RUY-588).
    activity: ActivityGate,
}

impl<B: Backend> Router<B> {
    /// Starts in `shell` with no profile: navigation keys, no virtual pad (as before Input1).
    pub fn new(backend: B, accounts: Box<dyn Accounts>) -> Self {
        Router {
            backend,
            accounts,
            route: Route::Shell,
            instance: String::new(),
            app_id: String::new(),
            profile: String::new(),
            caller: None,
            owner: None,
            pads: BTreeMap::new(),
            board: KeyBoard::default(),
            next_key: 1,
            next_instance: 1,
            notices: Vec::new(),
            tests: BTreeMap::new(),
            book: Book::default(),
            active_input: None,
            activity: ActivityGate::default(),
            profile_pad: None,
            pad_since_change: None,
        }
    }

    /// Where the controller profiles live (in memory until this is called).
    /// Shortens the 30 s between two `UserActive` (the VM checks run the shell's clock faster).
    pub fn set_activity_gap(&mut self, gap: Duration) {
        self.activity.set_gap(gap);
    }

    pub fn set_book(&mut self, book: Book) {
        self.book = book;
    }

    pub fn backend(&self) -> &B {
        &self.backend
    }

    pub fn backend_mut(&mut self) -> &mut B {
        &mut self.backend
    }

    pub fn take_notices(&mut self) -> Vec<Notice> {
        std::mem::take(&mut self.notices)
    }

    pub fn route(&self) -> Route {
        self.route
    }

    pub fn route_instance(&self) -> &str {
        &self.instance
    }

    pub fn route_app_id(&self) -> &str {
        &self.app_id
    }

    fn journal(&mut self, line: String) {
        self.notices.push(Notice::Journal(line));
    }

    fn record(&self, pad: &Pad) -> DeviceRecord {
        DeviceRecord {
            id: pad.info.id.clone(),
            instance: pad.instance.clone(),
            name: pad.info.name.clone(),
            family: pad.info.family.clone(),
            connection: pad.info.connection.clone(),
            model: pad.info.model.clone(),
            layout: pad.info.layout.clone(),
            battery: -1,
            charging: false,
            slot: 0,
            profile: self.profile.clone(),
            routed: pad.virt.as_ref().is_some_and(|v| v.ready),
        }
    }

    pub fn devices(&self) -> Vec<DeviceRecord> {
        self.pads.values().map(|p| self.record(p)).collect()
    }

    fn changed(&mut self, key: PadKey) {
        if let Some(pad) = self.pads.get(&key) {
            let rec = self.record(pad);
            self.notices.push(Notice::DeviceChanged(rec));
        }
    }

    // ---- pads -------------------------------------------------------------------------------

    pub fn add_pad(&mut self, info: PadInfo, now: Instant) -> PadKey {
        let key = self.next_key;
        self.next_key += 1;
        let instance = format!("{}#{}", info.id, self.next_instance);
        self.next_instance += 1;
        let pad = Pad {
            info,
            instance,
            mapper: Mapper::default(),
            state: PadState::default(),
            virt: None,
            nav_masked: Vec::new(),
        };
        self.notices.push(Notice::DeviceAdded(self.record(&pad)));
        self.pads.insert(key, pad);
        if self.route == Route::App && self.owner.is_some() {
            self.create_virtual(key, now);
        }
        key
    }

    /// The pad is gone: its navigation keys are released (the keys it held are returned for the
    /// journal) and its virtual pad is destroyed.
    pub fn remove_pad(&mut self, key: PadKey) -> Vec<NavKey> {
        let Some(mut pad) = self.pads.remove(&key) else {
            return Vec::new();
        };
        if self.active_input.as_deref() == Some(pad.info.id.as_str()) {
            self.active_input = None;
        }
        if self.pad_since_change.as_deref() == Some(pad.info.id.as_str()) {
            self.pad_since_change = None;
        }
        let held = pad.mapper.held_keys();
        let keys = self.board.pad_gone(&mut pad.mapper);
        self.backend.nav_keys(&keys);
        if let Some(v) = pad.virt.take() {
            self.drop_virtual(key, v);
        }
        self.end_test(&pad.info.id, "gone");
        self.notices.push(Notice::DeviceRemoved {
            id: pad.info.id,
            instance: pad.instance,
        });
        held
    }

    /// `input_at` with the real clock, for the tests that do not care about time.
    #[cfg(test)]
    pub fn input(&mut self, key: PadKey, inputs: &[PadInput]) {
        self.input_at(key, inputs, Instant::now());
    }

    /// One batch of a pad's input (one evdev `SYN_REPORT`). In `app` the shell sees none of it, so
    /// it is announced as `UserActive` (at most once per 30 s); in the other routes it arrives as
    /// navigation keys, which the shell counts itself.
    pub fn input_at(&mut self, key: PadKey, inputs: &[PadInput], now: Instant) {
        let app = self.route == Route::App;
        let mode = self.book.confirm_button(&self.profile);
        self.drain_book();
        let Some(pad) = self.pads.get_mut(&key) else {
            return;
        };
        let family = pad.info.family.clone();
        let hold = self
            .tests
            .get(&pad.info.id)
            .is_some_and(|t| t.hold_left_stick);
        let mut nav = Vec::new();
        let mut pressed = false;
        for &input in inputs {
            pad.state.apply(input);
            pressed |= matches!(input, PadInput::Button(_, true));
            let events = if pad.stick_held_back(input, hold) {
                Vec::new()
            } else {
                mapper_events(&mut pad.mapper, input, &family, mode)
            };
            if app {
                // Navigation stops while an app has the focus; Guide always reaches the shell.
                nav.extend(events.into_iter().filter(|&(k, _)| k == NavKey::Guide));
            } else {
                nav.extend(events);
            }
            if let Some(v) = pad.virt.as_mut() {
                v.unmask(input);
            }
        }
        let id = pad.info.id.clone();
        let keys = self.board.route(&nav);
        self.backend.nav_keys(&keys);
        if pressed {
            self.pad_since_change = Some(id.clone());
        }
        if pressed && self.active_input.as_deref() != Some(id.as_str()) {
            self.active_input = Some(id.clone());
            self.notices.push(Notice::ActiveInput {
                device_id: id,
                family,
            });
        }
        if !app {
            return;
        }
        if self.activity.note(inputs, now) {
            self.notices.push(Notice::UserActive);
        }
        let Some(pad) = self.pads.get_mut(&key) else {
            return;
        };
        if let Some(v) = pad.virt.as_mut() {
            let target = v.target(&pad.state);
            let events = diff(&v.sent, &target);
            v.sent = target;
            if !events.is_empty() {
                self.backend.write_virtual(v.id, &events);
            }
        }
    }

    // ---- virtual pads -----------------------------------------------------------------------

    fn create_virtual(&mut self, key: PadKey, now: Instant) {
        let Some(owner) = self.owner.clone() else {
            return;
        };
        let used: BTreeSet<u32> = self
            .pads
            .values()
            .filter_map(|p| p.virt.as_ref().map(|v| v.n))
            .collect();
        let n = (1..).find(|n| !used.contains(n)).unwrap_or(1);
        let Some(pad) = self.pads.get(&key) else {
            return;
        };
        let spec = VirtualSpec {
            phys: format!("{PAD_PHYS_PREFIX}{n}"),
            rumble: pad.info.rumble,
        };
        let pad_id = pad.info.id.clone();
        let family = pad.info.family.clone();
        let engine = self.book.engine_for(&owner.profile, &family, &pad_id);
        self.drain_book();
        match self.backend.create_virtual(key, &spec) {
            Ok(created) => {
                let mut v = Virtual {
                    id: created.id,
                    sysname: created.sysname,
                    phys: spec.phys.clone(),
                    n,
                    created: now,
                    ready: false,
                    fallback_tried: false,
                    sent: PadState::default(),
                    masked_buttons: Vec::new(),
                    masked_axes: Vec::new(),
                    ff: BTreeMap::new(),
                    playing: BTreeSet::new(),
                    engine,
                };
                if let Some(pad) = self.pads.get_mut(&key) {
                    v.mask_held(&pad.state);
                    pad.virt = Some(v);
                }
                self.journal(format!(
                    "virtual pad {} created for ruya-{} ({pad_id})",
                    spec.phys, owner.profile
                ));
            }
            Err(err) => self.journal(format!("creating a virtual pad for {pad_id} failed: {err}")),
        }
    }

    /// Destroys a virtual pad: its rumble effects are erased on the physical pad first.
    fn drop_virtual(&mut self, key: PadKey, v: Virtual) {
        for &physical in v.ff.values() {
            self.backend.ff_erase(key, physical);
        }
        self.backend.destroy_virtual(v.id);
        self.journal(format!("virtual pad {} destroyed", v.phys));
    }

    fn destroy_all(&mut self) {
        let keys: Vec<PadKey> = self.pads.keys().copied().collect();
        for key in keys {
            let taken = self.pads.get_mut(&key).and_then(|p| p.virt.take());
            if let Some(v) = taken {
                let was_ready = v.ready;
                self.drop_virtual(key, v);
                if was_ready {
                    self.changed(key);
                }
            }
        }
        self.owner = None;
    }

    /// Sticks centred, nothing pressed, rumble stopped: the overlay is in front.
    fn neutral_all(&mut self) {
        for (&key, pad) in self.pads.iter_mut() {
            let Some(v) = pad.virt.as_mut() else {
                continue;
            };
            let events = diff(&v.sent, &PadState::default());
            v.sent = PadState::default();
            if !events.is_empty() {
                self.backend.write_virtual(v.id, &events);
            }
            for effect in std::mem::take(&mut v.playing) {
                if let Some(&physical) = v.ff.get(&effect) {
                    self.backend.ff_play(key, physical, 0);
                }
            }
        }
    }

    /// Sets the one-entry ACL on a virtual pad's node unless it is already exactly that.
    fn assert_acl(&mut self, key: PadKey, node: &str, why: &str) {
        let Some(owner) = self.owner.clone() else {
            return;
        };
        let current = self.backend.read_acl(node);
        let fine = current
            .as_deref()
            .is_some_and(|a| acl::is_only_user(a, owner.uid));
        let result = if fine {
            Ok(())
        } else {
            self.backend.write_acl(node, &acl::only_user(owner.uid))
        };
        let Some(v) = self.pads.get_mut(&key).and_then(|p| p.virt.as_mut()) else {
            return;
        };
        let phys = v.phys.clone();
        let was_ready = v.ready;
        if result.is_ok() {
            v.ready = true;
        }
        match result {
            Err(err) => {
                self.journal(format!("setting the ACL of {phys} ({node}) failed: {err}"));
            }
            Ok(()) if !was_ready => {
                self.journal(format!(
                    "virtual pad {phys} ready for ruya-{} ({node}, {why})",
                    owner.profile
                ));
                self.changed(key);
            }
            Ok(()) if !fine => {
                self.journal(format!("ACL of {phys} ({node}) re-asserted after {why}"));
            }
            Ok(()) => {}
        }
    }

    /// A processed udev event (the monitor): an `add` or `change` on one of our nodes sets the
    /// ACL again, because logind's uaccess builtin rewrites it on every event.
    pub fn udev_event(&mut self, ev: &UdevEvent) {
        if !ev.is_event_node() || !matches!(ev.action.as_str(), "add" | "change") {
            return;
        }
        let Some(sysname) = ev.parent_sysname() else {
            return;
        };
        let key = self.pads.iter().find_map(|(&k, p)| {
            p.virt
                .as_ref()
                .is_some_and(|v| v.sysname == sysname)
                .then_some(k)
        });
        if let Some(key) = key {
            let why = format!("udev {}", ev.action);
            self.assert_acl(key, &ev.devname, &why);
        }
    }

    /// Timers: a virtual pad with no udev event after `UDEV_FALLBACK` gets its ACL anyway; a
    /// button test sends the axis values it held back and ends after `TEST_IDLE` without input.
    pub fn tick(&mut self, now: Instant) {
        self.tick_tests(now);
        let due: Vec<(PadKey, String)> = self
            .pads
            .iter_mut()
            .filter_map(|(&k, p)| {
                let v = p.virt.as_mut()?;
                if v.ready || v.fallback_tried || now.duration_since(v.created) < UDEV_FALLBACK {
                    return None;
                }
                v.fallback_tried = true;
                Some((k, v.sysname.clone()))
            })
            .collect();
        for (key, sysname) in due {
            match self.backend.node_of(&sysname) {
                Some(node) => self.assert_acl(key, &node, "no udev event in 2 s"),
                None => self.journal(format!("virtual pad {sysname} has no event node")),
            }
        }
    }

    // ---- routing ----------------------------------------------------------------------------

    /// `Input1.SetRoute`. `caller` is the bus name of the caller (the route falls back to
    /// `locked` when it leaves the bus).
    pub fn set_route(
        &mut self,
        route: &str,
        instance: &str,
        app_id: &str,
        profile: &str,
        caller: &str,
        now: Instant,
    ) -> Status {
        let Some(r) = Route::parse(route) else {
            return Status::Invalid;
        };
        let instance_ok = instance.len() <= 255 && !instance.chars().any(char::is_control);
        let app_ok = app_id.is_empty() || valid_app_id(app_id);
        let shape_ok = match r {
            Route::App => !instance.is_empty() && !app_id.is_empty() && !profile.is_empty(),
            Route::Overlay => !profile.is_empty() && (instance.is_empty() == app_id.is_empty()),
            Route::Shell => instance.is_empty() && app_id.is_empty(),
            Route::Locked => instance.is_empty() && app_id.is_empty() && profile.is_empty(),
        };
        if !instance_ok || !app_ok || !shape_ok {
            return Status::Invalid;
        }
        let uid = if profile.is_empty() {
            None
        } else {
            if !valid_profile_id(profile) {
                return Status::UnknownProfile;
            }
            match self.accounts.profile_uid(profile) {
                Some(uid) => Some(uid),
                None => return Status::UnknownProfile,
            }
        };
        self.caller = Some(caller.to_owned());
        self.apply(r, instance, app_id, profile, uid, now);
        Status::Ok
    }

    /// The bus name `name` has left the bus (`NameOwnerChanged` with no new owner).
    pub fn caller_left(&mut self, name: &str, now: Instant) {
        let theirs: Vec<String> = self
            .tests
            .iter()
            .filter(|(_, t)| t.caller == name)
            .map(|(id, _)| id.clone())
            .collect();
        for id in theirs {
            self.end_test(&id, "caller");
        }
        if self.caller.as_deref() != Some(name) {
            return;
        }
        self.caller = None;
        if self.route != Route::Locked {
            self.journal(format!(
                "the route's caller {name} left the bus: route locked"
            ));
            self.apply(Route::Locked, "", "", "", None, now);
        }
    }

    fn apply(
        &mut self,
        r: Route,
        instance: &str,
        app_id: &str,
        profile: &str,
        uid: Option<u32>,
        now: Instant,
    ) {
        let old = self.route;
        // Leaving navigation: every key but Guide goes up now.
        if old != Route::App && r == Route::App {
            let keys = self.board.release_except(NavKey::Guide);
            self.backend.nav_keys(&keys);
        }
        let same_owner = self.owner.as_ref().is_some_and(|o| {
            !instance.is_empty() && o.instance == instance && o.profile == profile
        });
        if self.profile != profile {
            // A sign-in or switch: the pad that pressed since the last change is this profile's
            // controller; a keyboard or touch sign-in has none (ADR-017 am. 6b).
            self.profile_pad = self.pad_since_change.take().filter(|_| !profile.is_empty());
        }
        match r {
            Route::App if same_owner => {
                if old != Route::App {
                    // Back from the overlay: what is held now waits for its release.
                    for pad in self.pads.values_mut() {
                        let state = pad.state.clone();
                        if let Some(v) = pad.virt.as_mut() {
                            v.mask_held(&state);
                        }
                    }
                }
            }
            Route::App => {
                self.destroy_all();
                self.owner = uid.map(|uid| Owner {
                    instance: instance.to_owned(),
                    profile: profile.to_owned(),
                    uid,
                });
                // The profile's active controller (the pad that signed it in) is created first, so
                // it is `pad1` and SDL index 0; the others follow in key order (RUY-540).
                let mut keys: Vec<PadKey> = self.pads.keys().copied().collect();
                if let Some(active) = self.profile_pad.as_deref() {
                    if let Some(i) = keys.iter().position(|k| self.pads[k].info.id == active) {
                        let k = keys.remove(i);
                        keys.insert(0, k);
                    }
                }
                for key in keys {
                    self.create_virtual(key, now);
                }
            }
            Route::Overlay if same_owner => self.neutral_all(),
            Route::Overlay | Route::Shell | Route::Locked => self.destroy_all(),
        }
        if r != Route::Shell {
            let running: Vec<String> = self.tests.keys().cloned().collect();
            for id in running {
                self.end_test(&id, "route");
            }
        }
        let profile_changed = self.profile != profile;
        let changed = self.route != r
            || self.instance != instance
            || self.app_id != app_id
            || profile_changed;
        self.route = r;
        self.instance = instance.to_owned();
        self.app_id = app_id.to_owned();
        self.profile = profile.to_owned();
        if profile_changed {
            self.notices.push(Notice::ConfirmButtonChanged);
            let keys: Vec<PadKey> = self.pads.keys().copied().collect();
            for key in keys {
                self.changed(key);
            }
        }
        if changed {
            self.journal(format!(
                "route {} instance '{instance}' app '{app_id}' profile '{profile}'",
                r.as_str()
            ));
            self.notices.push(Notice::RouteChanged {
                route: r.as_str().to_owned(),
                instance: instance.to_owned(),
            });
        }
    }

    // ---- the confirm button (06 §11.2) ------------------------------------------------------

    /// The `ConfirmButton` property: the signed-in profile's mode ("family" with none).
    pub fn confirm_button(&mut self) -> &'static str {
        let profile = self.profile.clone();
        let mode = self.book.confirm_button(&profile);
        self.drain_book();
        mode.as_str()
    }

    /// `SetConfirmButton`: `mode` is "family" | "south" | "east" for a profile account. It applies
    /// from the next press on; a key held now is released as it was pressed.
    pub fn set_confirm_button(&mut self, profile: &str, mode: &str) -> Status {
        if !self.console_ok(profile) {
            return Status::UnknownProfile;
        }
        let Some(mode) = Confirm::parse(mode) else {
            return Status::Invalid;
        };
        let status = self.book.set_confirm_button(profile, mode);
        self.drain_book();
        if status == Status::Ok {
            self.journal(format!(
                "confirm button of ruya-{profile}: {}",
                mode.as_str()
            ));
            if profile == self.profile {
                self.notices.push(Notice::ConfirmButtonChanged);
            }
        }
        status
    }

    // ---- controller profiles (06 §7) --------------------------------------------------------

    fn drain_book(&mut self) {
        for line in self.book.take_journal() {
            self.journal(line);
        }
    }

    /// A console profile's controller profiles exist only for a profile account.
    fn console_ok(&self, profile: &str) -> bool {
        valid_profile_id(profile) && self.accounts.profile_uid(profile).is_some()
    }

    /// The profiles of `profile` changed: the signal, and the owner's pads take the new mapping
    /// now (in `app`; held in neutral in `overlay`, they show it from the next input on).
    fn profiles_changed(&mut self, profile: &str) {
        self.notices.push(Notice::ProfilesChanged {
            profile: profile.to_owned(),
        });
        if self.owner.as_ref().map(|o| o.profile.as_str()) != Some(profile) {
            return;
        }
        let app = self.route == Route::App;
        let keys: Vec<PadKey> = self.pads.keys().copied().collect();
        let mut updated = 0;
        for key in keys {
            let Some(pad) = self.pads.get(&key) else {
                continue;
            };
            if pad.virt.is_none() {
                continue;
            }
            let (family, id) = (pad.info.family.clone(), pad.info.id.clone());
            let engine = self.book.engine_for(profile, &family, &id);
            let Some(pad) = self.pads.get_mut(&key) else {
                continue;
            };
            let state = pad.state.clone();
            let Some(v) = pad.virt.as_mut() else {
                continue;
            };
            v.engine = engine;
            updated += 1;
            if app {
                let target = v.target(&state);
                let events = diff(&v.sent, &target);
                v.sent = target;
                if !events.is_empty() {
                    self.backend.write_virtual(v.id, &events);
                }
            }
        }
        self.drain_book();
        if updated > 0 {
            self.journal(format!(
                "controller profiles of ruya-{profile} changed: {updated} virtual pad(s) updated"
            ));
        }
    }

    /// `Input1.ListProfiles`.
    pub fn list_profiles(&mut self, profile: &str) -> (Status, Vec<Summary>) {
        if !self.console_ok(profile) {
            return (Status::UnknownProfile, Vec::new());
        }
        let out = self.book.list(profile);
        self.drain_book();
        match out {
            Ok(list) => (Status::Ok, list),
            Err(status) => (status, Vec::new()),
        }
    }

    /// `Input1.GetProfile`.
    pub fn get_profile(&mut self, profile: &str, profile_id: &str) -> (Status, String) {
        if !self.console_ok(profile) {
            return (Status::UnknownProfile, String::new());
        }
        let out = self.book.get(profile, profile_id);
        self.drain_book();
        match out {
            Ok(json) => (Status::Ok, json),
            Err(status) => (status, String::new()),
        }
    }

    /// `Input1.ValidateProfile`: the file alone (schema and service rules).
    pub fn validate_profile(json: &str) -> (Status, Vec<String>) {
        Book::validate(json)
    }

    /// `Input1.SaveProfile`.
    pub fn save_profile(&mut self, profile: &str, json: &str) -> SaveAnswer {
        if !self.console_ok(profile) {
            return (Status::UnknownProfile, String::new(), Vec::new());
        }
        let answer = self.book.save(profile, json);
        self.drain_book();
        if answer.0 == Status::Ok {
            self.journal(format!(
                "controller profile {} of ruya-{profile} saved",
                answer.1
            ));
            self.profiles_changed(profile);
        }
        answer
    }

    /// `Input1.DeleteProfile`.
    pub fn delete_profile(&mut self, profile: &str, profile_id: &str) -> Status {
        if !self.console_ok(profile) {
            return Status::UnknownProfile;
        }
        let status = self.book.delete(profile, profile_id);
        self.drain_book();
        if status == Status::Ok {
            self.journal(format!(
                "controller profile {profile_id} of ruya-{profile} deleted"
            ));
            self.profiles_changed(profile);
        }
        status
    }

    /// `Input1.AssignProfile` (the global scope; platform and game are RUY-43).
    pub fn assign_profile(
        &mut self,
        profile: &str,
        scope: &str,
        scope_id: &str,
        profile_id: &str,
    ) -> Status {
        if !self.console_ok(profile) {
            return Status::UnknownProfile;
        }
        let status = self.book.assign(profile, scope, scope_id, profile_id);
        self.drain_book();
        if status == Status::Ok {
            let slot = if scope_id.is_empty() {
                "all controllers"
            } else {
                scope_id
            };
            self.journal(format!(
                "ruya-{profile}'s {scope} controller profile for {slot} is '{profile_id}'"
            ));
            self.profiles_changed(profile);
        }
        status
    }

    /// `Input1.GetEffectiveProfile`: what applies to a connected pad (`device_id`, or "" for a
    /// pad that no `match` names) in `app_id` ("" or an app id; game and platform profiles are
    /// RUY-43, so today it does not change the answer).
    pub fn effective_profile(
        &mut self,
        profile: &str,
        device_id: &str,
        app_id: &str,
    ) -> (Status, String, Vec<String>) {
        if !self.console_ok(profile) {
            return (Status::UnknownProfile, String::new(), Vec::new());
        }
        if !app_id.is_empty() && !valid_app_id(app_id) {
            return (Status::Invalid, String::new(), Vec::new());
        }
        let family = if device_id.is_empty() {
            String::new()
        } else {
            match self.pads.values().find(|p| p.info.id == device_id) {
                Some(p) => p.info.family.clone(),
                None => return (Status::UnknownDevice, String::new(), Vec::new()),
            }
        };
        let out = self.book.effective(profile, &family, device_id);
        self.drain_book();
        match out {
            Ok((json, chain)) => (Status::Ok, json, chain),
            Err(status) => (status, String::new(), Vec::new()),
        }
    }

    // ---- capabilities and the button test ---------------------------------------------------

    /// `Input1.GetCapabilities`.
    pub fn capabilities(&self, device_id: &str) -> (Status, Vec<Capability>) {
        match self.pads.values().find(|p| p.info.id == device_id) {
            Some(pad) => (Status::Ok, pad.info.capabilities.clone()),
            None => (Status::UnknownDevice, Vec::new()),
        }
    }

    /// Whether a button test runs (the Linux loop then ticks often enough for the axis rate).
    pub fn testing(&self) -> bool {
        !self.tests.is_empty()
    }

    /// `Input1.StartTest`: only while the route is `shell`, one test per device. With
    /// `hold_left_stick` the pad's left stick sends no navigation key until the test ends (its
    /// D-pad and buttons still navigate), and a direction it holds now is released once.
    pub fn start_test(
        &mut self,
        device_id: &str,
        hold_left_stick: bool,
        caller: &str,
        now: Instant,
    ) -> Status {
        if !self.pads.values().any(|p| p.info.id == device_id) {
            return Status::UnknownDevice;
        }
        if self.route != Route::Shell {
            return Status::NotAllowed;
        }
        if self.tests.contains_key(device_id) {
            return Status::Busy;
        }
        self.tests.insert(
            device_id.to_owned(),
            ButtonTest {
                caller: caller.to_owned(),
                last_input: now,
                axes: BTreeMap::new(),
                hold_left_stick,
            },
        );
        if hold_left_stick {
            if let Some(pad) = self.pads.values_mut().find(|p| p.info.id == device_id) {
                let released = pad.mapper.release_sticks();
                let keys = self.board.route(&released);
                self.backend.nav_keys(&keys);
            }
        }
        self.journal(format!("button test started for {device_id}"));
        Status::Ok
    }

    /// `Input1.StopTest`: "ok" also when no test runs for a connected device.
    pub fn stop_test(&mut self, device_id: &str) -> Status {
        if self.tests.contains_key(device_id) {
            self.end_test(device_id, "stopped");
            return Status::Ok;
        }
        if self.pads.values().any(|p| p.info.id == device_id) {
            Status::Ok
        } else {
            Status::UnknownDevice
        }
    }

    fn end_test(&mut self, device_id: &str, reason: &str) {
        let Some(test) = self.tests.remove(device_id) else {
            return;
        };
        if test.hold_left_stick {
            // A stick still pushed does not navigate until it has been neutral.
            if let Some(pad) = self.pads.values_mut().find(|p| p.info.id == device_id) {
                pad.nav_masked = [PadAxis::LeftX, PadAxis::LeftY]
                    .into_iter()
                    .filter(|&a| axis_held(a, pad.state.axis(a)))
                    .collect();
            }
        }
        self.journal(format!("button test for {device_id} ended: {reason}"));
        self.notices.push(Notice::TestEnded {
            device_id: device_id.to_owned(),
            reason: reason.to_owned(),
        });
    }

    /// The button test's view of one batch of a pad's input: buttons go out at once, an axis at
    /// most every `TEST_AXIS_INTERVAL` (a newer value waits for `tick`).
    pub fn test_input(&mut self, key: PadKey, events: &[TestEvent], now: Instant) {
        if events.is_empty() {
            return;
        }
        let Some(id) = self.pads.get(&key).map(|p| p.info.id.clone()) else {
            return;
        };
        let Some(test) = self.tests.get_mut(&id) else {
            return;
        };
        test.last_input = now;
        let mut out = Vec::new();
        for ev in events {
            let (name, value, source) = (ev.name(), ev.test_value(), ev.source());
            if ev.is_axis() {
                match test.axes.get_mut(&name) {
                    Some(axis) if now.duration_since(axis.sent) < TEST_AXIS_INTERVAL => {
                        axis.pending = Some((value, source));
                        continue;
                    }
                    Some(axis) => {
                        axis.sent = now;
                        axis.pending = None;
                    }
                    None => {
                        test.axes.insert(
                            name.clone(),
                            AxisSend {
                                sent: now,
                                pending: None,
                            },
                        );
                    }
                }
            }
            out.push(Notice::TestInput {
                device_id: id.clone(),
                input: name,
                value,
                source,
            });
        }
        self.notices.extend(out);
    }

    fn tick_tests(&mut self, now: Instant) {
        let idle: Vec<String> = self
            .tests
            .iter()
            .filter(|(_, t)| now.duration_since(t.last_input) >= TEST_IDLE)
            .map(|(id, _)| id.clone())
            .collect();
        for id in idle {
            self.end_test(&id, "idle");
        }
        let mut out = Vec::new();
        for (id, test) in self.tests.iter_mut() {
            for (name, axis) in test.axes.iter_mut() {
                if now.duration_since(axis.sent) < TEST_AXIS_INTERVAL {
                    continue;
                }
                if let Some((value, source)) = axis.pending.take() {
                    axis.sent = now;
                    out.push(Notice::TestInput {
                        device_id: id.clone(),
                        input: name.clone(),
                        value,
                        source,
                    });
                }
            }
        }
        self.notices.extend(out);
    }

    // ---- rumble -----------------------------------------------------------------------------

    fn virtual_pad(&mut self, id: VirtualId) -> Option<(PadKey, &mut Virtual)> {
        self.pads
            .iter_mut()
            .find_map(|(&k, p)| p.virt.as_mut().filter(|v| v.id == id).map(|v| (k, v)))
    }

    /// The app uploaded (or updated) rumble effect `effect` on virtual pad `id`.
    pub fn ff_upload(&mut self, id: VirtualId, effect: i16, rumble: &Rumble) -> Result<(), i32> {
        let Some((key, v)) = self.virtual_pad(id) else {
            return Err(ENODEV);
        };
        let physical = v.ff.get(&effect).copied().unwrap_or(-1);
        let new = self.backend.ff_upload(key, physical, rumble)?;
        if let Some((_, v)) = self.virtual_pad(id) {
            v.ff.insert(effect, new);
        }
        Ok(())
    }

    /// The app plays (`value` > 0, the repeat count) or stops (0) an effect: forwarded only while
    /// the route is `app`.
    pub fn ff_play(&mut self, id: VirtualId, effect: i16, value: i32) {
        if self.route != Route::App {
            return;
        }
        let Some((key, v)) = self.virtual_pad(id) else {
            return;
        };
        let Some(&physical) = v.ff.get(&effect) else {
            return;
        };
        if value > 0 {
            v.playing.insert(effect);
        } else {
            v.playing.remove(&effect);
        }
        self.backend.ff_play(key, physical, value);
    }

    pub fn ff_erase(&mut self, id: VirtualId, effect: i16) {
        let Some((key, v)) = self.virtual_pad(id) else {
            return;
        };
        v.playing.remove(&effect);
        if let Some(physical) = v.ff.remove(&effect) {
            self.backend.ff_erase(key, physical);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::accounts::FixedAccounts;
    use crate::pad::code;
    use std::collections::HashMap;

    #[derive(Debug, Clone, PartialEq, Eq)]
    enum Call {
        Nav(Vec<KeyEvent>),
        Create(PadKey, VirtualSpec),
        Destroy(VirtualId),
        Write(VirtualId, Vec<OutEvent>),
        WriteAcl(String),
        FfUpload(PadKey, i16, Rumble),
        FfPlay(PadKey, i16, i32),
        FfErase(PadKey, i16),
    }

    /// A fake uinput and filesystem: records every call, keeps one ACL per node.
    #[derive(Default)]
    struct Fake {
        calls: Vec<Call>,
        next: VirtualId,
        alive: BTreeSet<VirtualId>,
        acls: HashMap<String, Vec<u8>>,
        acl_fails: bool,
        next_ff: i16,
    }

    impl Fake {
        fn take(&mut self) -> Vec<Call> {
            std::mem::take(&mut self.calls)
        }
    }

    impl Backend for Fake {
        fn nav_keys(&mut self, events: &[KeyEvent]) {
            if !events.is_empty() {
                self.calls.push(Call::Nav(events.to_vec()));
            }
        }
        fn create_virtual(&mut self, pad: PadKey, spec: &VirtualSpec) -> Result<Created, String> {
            self.next += 1;
            self.alive.insert(self.next);
            self.calls.push(Call::Create(pad, spec.clone()));
            Ok(Created {
                id: self.next,
                sysname: format!("input{}", 100 + self.next),
            })
        }
        fn destroy_virtual(&mut self, id: VirtualId) {
            self.alive.remove(&id);
            self.calls.push(Call::Destroy(id));
        }
        fn write_virtual(&mut self, id: VirtualId, events: &[OutEvent]) {
            assert!(self.alive.contains(&id), "write to a destroyed pad {id}");
            self.calls.push(Call::Write(id, events.to_vec()));
        }
        fn node_of(&mut self, sysname: &str) -> Option<String> {
            Some(format!("/dev/input/event-{sysname}"))
        }
        fn read_acl(&mut self, node: &str) -> Option<Vec<u8>> {
            self.acls.get(node).cloned()
        }
        fn write_acl(&mut self, node: &str, acl: &[u8]) -> Result<(), String> {
            if self.acl_fails {
                return Err("Operation not permitted".into());
            }
            self.acls.insert(node.to_owned(), acl.to_vec());
            self.calls.push(Call::WriteAcl(node.to_owned()));
            Ok(())
        }
        fn ff_upload(&mut self, pad: PadKey, physical: i16, r: &Rumble) -> Result<i16, i32> {
            self.calls.push(Call::FfUpload(pad, physical, *r));
            if physical >= 0 {
                return Ok(physical);
            }
            self.next_ff += 1;
            Ok(self.next_ff)
        }
        fn ff_play(&mut self, pad: PadKey, physical: i16, value: i32) {
            self.calls.push(Call::FfPlay(pad, physical, value));
        }
        fn ff_erase(&mut self, pad: PadKey, physical: i16) {
            self.calls.push(Call::FfErase(pad, physical));
        }
    }

    const P1_UID: u32 = 1001;
    const P2_UID: u32 = 1002;
    const STK: &str = "net.supertuxkart.SuperTuxKart";
    const RACER: &str = "org.ruyaos.Racer";
    const SHELL: &str = ":1.5";

    fn router() -> Router<Fake> {
        Router::new(
            Fake::default(),
            Box::new(FixedAccounts(vec![
                ("p1".into(), P1_UID),
                ("p2".into(), P2_UID),
            ])),
        )
    }

    fn pad(id: &str) -> PadInfo {
        PadInfo {
            id: id.into(),
            name: "DualSense Wireless Controller".into(),
            family: "playstation".into(),
            connection: "bluetooth".into(),
            model: "dualsense".into(),
            layout: String::new(),
            rumble: true,
            capabilities: Vec::new(),
        }
    }

    fn t0() -> Instant {
        Instant::now()
    }

    fn press(b: PadButton) -> PadInput {
        PadInput::Button(b, true)
    }

    fn release(b: PadButton) -> PadInput {
        PadInput::Button(b, false)
    }

    fn app(r: &mut Router<Fake>, instance: &str, app_id: &str, profile: &str) {
        assert_eq!(
            r.set_route("app", instance, app_id, profile, SHELL, t0()),
            Status::Ok
        );
    }

    fn created(calls: &[Call]) -> Vec<VirtualSpec> {
        calls
            .iter()
            .filter_map(|c| match c {
                Call::Create(_, s) => Some(s.clone()),
                _ => None,
            })
            .collect()
    }

    fn destroyed(calls: &[Call]) -> Vec<VirtualId> {
        calls
            .iter()
            .filter_map(|c| match c {
                Call::Destroy(id) => Some(*id),
                _ => None,
            })
            .collect()
    }

    fn writes(calls: &[Call]) -> Vec<(VirtualId, Vec<OutEvent>)> {
        calls
            .iter()
            .filter_map(|c| match c {
                Call::Write(id, e) => Some((*id, e.clone())),
                _ => None,
            })
            .collect()
    }

    fn nav(calls: &[Call]) -> Vec<KeyEvent> {
        calls
            .iter()
            .filter_map(|c| match c {
                Call::Nav(e) => Some(e.clone()),
                _ => None,
            })
            .flatten()
            .collect()
    }

    fn udev(action: &str, sysname: &str) -> UdevEvent {
        UdevEvent {
            action: action.into(),
            subsystem: "input".into(),
            devpath: format!("/devices/virtual/input/{sysname}/event17"),
            devname: "/dev/input/event17".into(),
        }
    }

    fn journal(r: &mut Router<Fake>) -> Vec<String> {
        r.take_notices()
            .into_iter()
            .filter_map(|n| match n {
                Notice::Journal(l) => Some(l),
                _ => None,
            })
            .collect()
    }

    // ---- the route -------------------------------------------------------------------------

    #[test]
    fn the_route_starts_as_shell() {
        let r = router();
        assert_eq!(r.route(), Route::Shell);
        assert_eq!(r.route_instance(), "");
    }

    #[test]
    fn set_route_validates_its_arguments() {
        let mut r = router();
        let mut s = |route, inst, app, prof| r.set_route(route, inst, app, prof, SHELL, t0());
        assert_eq!(s("game", "", "", ""), Status::Invalid);
        assert_eq!(s("app", "", STK, "p1"), Status::Invalid); // no instance
        assert_eq!(s("app", "i1", "", "p1"), Status::Invalid); // no app id
        assert_eq!(s("app", "i1", "supertuxkart", "p1"), Status::Invalid); // not an app id
        assert_eq!(s("app", "i1", STK, ""), Status::Invalid); // nobody signed in
        assert_eq!(s("app", "i\n1", STK, "p1"), Status::Invalid);
        assert_eq!(s("overlay", "i1", "", "p1"), Status::Invalid);
        assert_eq!(s("shell", "i1", "", "p1"), Status::Invalid);
        assert_eq!(s("locked", "", "", "p1"), Status::Invalid);
        assert_eq!(s("app", "i1", STK, "shell"), Status::UnknownProfile);
        assert_eq!(s("app", "i1", STK, "../p1"), Status::UnknownProfile);
        assert_eq!(s("shell", "", "", "p9"), Status::UnknownProfile);
        assert_eq!(s("overlay", "", "", "p1"), Status::Ok); // over a frozen app
        assert_eq!(s("shell", "", "", ""), Status::Ok);
        assert_eq!(s("locked", "", "", ""), Status::Ok);
        assert_eq!(s("app", "i1", STK, "p1"), Status::Ok);
    }

    #[test]
    fn a_refused_route_changes_nothing() {
        let mut r = router();
        r.add_pad(pad("a"), t0());
        r.take_notices();
        assert_eq!(
            r.set_route("app", "i1", STK, "p9", SHELL, t0()),
            Status::UnknownProfile
        );
        assert_eq!(r.route(), Route::Shell);
        assert!(r.backend_mut().take().is_empty());
        assert!(r.take_notices().is_empty());
    }

    #[test]
    fn route_changes_are_announced_once() {
        let mut r = router();
        app(&mut r, "i1", STK, "p1");
        let n = r.take_notices();
        assert!(n.contains(&Notice::RouteChanged {
            route: "app".into(),
            instance: "i1".into()
        }));
        app(&mut r, "i1", STK, "p1");
        assert!(!r
            .take_notices()
            .iter()
            .any(|n| matches!(n, Notice::RouteChanged { .. })));
        assert_eq!(r.route_app_id(), STK);
    }

    // ---- navigation keys -------------------------------------------------------------------

    fn user_active(r: &mut Router<Fake>) -> usize {
        r.take_notices()
            .iter()
            .filter(|n| matches!(n, Notice::UserActive))
            .count()
    }

    #[test]
    fn pad_input_to_an_app_is_announced_as_activity_once_per_gap() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        let t = t0();
        r.take_notices();
        r.input_at(a, &[press(PadButton::South)], t);
        assert_eq!(user_active(&mut r), 1);
        r.input_at(a, &[press(PadButton::East)], t + Duration::from_secs(5));
        assert_eq!(user_active(&mut r), 0);
        r.input_at(a, &[press(PadButton::East)], t + Duration::from_secs(31));
        assert_eq!(user_active(&mut r), 1);
    }

    #[test]
    fn stick_noise_to_an_app_is_not_activity() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.take_notices();
        r.input_at(a, &[PadInput::Axis(PadAxis::LeftX, 500)], t0());
        assert_eq!(user_active(&mut r), 0);
    }

    #[test]
    fn input_outside_an_app_is_not_announced() {
        // The shell, the overlay and the lock screen get navigation keys, which the shell counts.
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        r.input_at(a, &[press(PadButton::South)], t0());
        assert_eq!(user_active(&mut r), 0);
    }

    #[test]
    fn the_shell_gets_navigation_keys() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        r.input(a, &[press(PadButton::South)]);
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Accept, true)]);
    }

    #[test]
    fn no_navigation_key_while_an_app_has_the_focus_except_guide() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        r.input(a, &[press(PadButton::South), press(PadButton::DpadDown)]);
        r.input(a, &[PadInput::Axis(PadAxis::LeftX, STICK_MIN)]);
        r.input(a, &[press(PadButton::Guide)]);
        let calls = r.backend_mut().take();
        assert_eq!(nav(&calls), vec![(NavKey::Guide, true)]);
        // Guide is never forwarded to the virtual pad.
        for (_, events) in writes(&calls) {
            assert!(!events.iter().any(|e| e.1 == code::BTN_MODE), "{events:?}");
        }
        r.input(a, &[release(PadButton::Guide)]);
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Guide, false)]);
    }

    #[test]
    fn guide_from_either_of_two_pads_reaches_the_shell_and_neither_game_pad() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        for pad_key in [a, b] {
            r.input(pad_key, &[press(PadButton::South), press(PadButton::Guide)]);
            let calls = r.backend_mut().take();
            assert_eq!(nav(&calls), vec![(NavKey::Guide, true)]);
            for (_, events) in writes(&calls) {
                assert!(!events.iter().any(|e| e.1 == code::BTN_MODE), "{events:?}");
            }
            r.input(
                pad_key,
                &[release(PadButton::Guide), release(PadButton::South)],
            );
            let calls = r.backend_mut().take();
            assert_eq!(nav(&calls), vec![(NavKey::Guide, false)]);
            for (_, events) in writes(&calls) {
                assert!(!events.iter().any(|e| e.1 == code::BTN_MODE), "{events:?}");
            }
        }
    }

    #[test]
    fn entering_an_app_releases_held_navigation_keys_once() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        r.input(a, &[press(PadButton::DpadDown), press(PadButton::South)]);
        r.backend_mut().take();
        app(&mut r, "i1", STK, "p1");
        assert_eq!(
            nav(&r.backend_mut().take()),
            vec![(NavKey::Down, false), (NavKey::Accept, false)]
        );
        // The release that follows in the app changes nothing on the keyboard.
        r.input(a, &[release(PadButton::DpadDown)]);
        assert!(nav(&r.backend_mut().take()).is_empty());
        // Back in the shell, a fresh press navigates once.
        r.set_route("shell", "", "", "p1", SHELL, t0());
        r.input(a, &[press(PadButton::DpadDown)]);
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Down, true)]);
    }

    #[test]
    fn a_held_key_does_not_move_the_shell_again_after_the_app() {
        // Down held from inside the game through the switch back to the shell: no extra move.
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.input(a, &[press(PadButton::DpadDown)]);
        r.set_route("overlay", "i1", STK, "p1", SHELL, t0());
        r.backend_mut().take();
        r.input(a, &[release(PadButton::DpadDown)]);
        assert!(nav(&r.backend_mut().take()).is_empty());
    }

    // ---- virtual pads ----------------------------------------------------------------------

    #[test]
    fn the_active_pad_becomes_pad1_and_is_created_first() {
        let creations = |calls: &[Call]| -> Vec<(PadKey, String)> {
            calls
                .iter()
                .filter_map(|c| match c {
                    Call::Create(k, s) => Some((*k, s.phys.clone())),
                    _ => None,
                })
                .collect()
        };
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        let c = r.add_pad(pad("c"), t0());
        // The second pad in key order signs the profile in.
        r.input(b, &[press(PadButton::South)]);
        r.set_route("shell", "", "", "p1", SHELL, t0());
        // A later press on another pad does not move the profile's active controller.
        r.input(c, &[press(PadButton::South)]);
        r.backend_mut().take();
        app(&mut r, "i1", STK, "p1");
        assert_eq!(
            creations(&r.backend_mut().take()),
            vec![
                (b, "ruya-input/pad1".to_owned()),
                (a, "ruya-input/pad2".to_owned()),
                (c, "ruya-input/pad3".to_owned()),
            ]
        );
        // A pad plugged in during the app takes the next free number.
        let d = r.add_pad(pad("d"), t0());
        assert_eq!(
            creations(&r.backend_mut().take()),
            vec![(d, "ruya-input/pad4".to_owned())]
        );
        // No pad known at sign-in: key order, as before.
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        r.backend_mut().take();
        app(&mut r, "i1", STK, "p1");
        assert_eq!(
            creations(&r.backend_mut().take()),
            vec![
                (a, "ruya-input/pad1".to_owned()),
                (b, "ruya-input/pad2".to_owned())
            ]
        );
    }

    #[test]
    fn a_profile_switch_captures_the_pad_that_signed_the_new_profile_in() {
        let pad_of = |calls: &[Call], phys: &str| -> Option<PadKey> {
            calls.iter().find_map(|c| match c {
                Call::Create(k, s) if s.phys == phys => Some(*k),
                _ => None,
            })
        };
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        r.input(a, &[press(PadButton::South)]);
        r.set_route("shell", "", "", "p1", SHELL, t0());
        r.backend_mut().take();
        app(&mut r, "i1", STK, "p1");
        assert_eq!(pad_of(&r.backend_mut().take(), "ruya-input/pad1"), Some(a));
        // Switch: lock, then b signs p2 in.
        r.set_route("locked", "", "", "", SHELL, t0());
        r.input(b, &[press(PadButton::South)]);
        r.set_route("shell", "", "", "p2", SHELL, t0());
        r.input(a, &[press(PadButton::South)]);
        r.backend_mut().take();
        app(&mut r, "i2", STK, "p2");
        assert_eq!(pad_of(&r.backend_mut().take(), "ruya-input/pad1"), Some(b));
    }

    fn pad1_of(calls: &[Call]) -> Option<PadKey> {
        calls.iter().find_map(|c| match c {
            Call::Create(k, s) if s.phys == "ruya-input/pad1" => Some(*k),
            _ => None,
        })
    }

    #[test]
    fn a_keyboard_sign_in_does_not_inherit_the_previous_profiles_pad() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        // Pad b signs p1 in and is the last to press.
        r.input(b, &[press(PadButton::South)]);
        r.set_route("shell", "", "", "p1", SHELL, t0());
        // Lock; p2 signs in from the keyboard: no pad pressed since the change.
        r.set_route("locked", "", "", "", SHELL, t0());
        r.set_route("shell", "", "", "p2", SHELL, t0());
        r.backend_mut().take();
        app(&mut r, "i2", STK, "p2");
        assert_eq!(pad1_of(&r.backend_mut().take()), Some(a));
    }

    #[test]
    fn a_pad_sign_in_makes_that_pad_pad1() {
        let mut r = router();
        let _a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        r.set_route("locked", "", "", "", SHELL, t0());
        r.input(b, &[press(PadButton::South)]);
        r.set_route("shell", "", "", "p1", SHELL, t0());
        r.backend_mut().take();
        app(&mut r, "i1", STK, "p1");
        assert_eq!(pad1_of(&r.backend_mut().take()), Some(b));
    }

    #[test]
    fn a_hub_switch_pressed_on_a_pad_makes_that_pad_pad1() {
        let mut r = router();
        let _a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        let c = r.add_pad(pad("c"), t0());
        r.input(b, &[press(PadButton::South)]);
        r.set_route("shell", "", "", "p1", SHELL, t0());
        // In the Hub, pad c presses Switch profile: p1 goes straight to p2.
        r.input(c, &[press(PadButton::South)]);
        r.set_route("shell", "", "", "p2", SHELL, t0());
        r.backend_mut().take();
        app(&mut r, "i2", STK, "p2");
        assert_eq!(pad1_of(&r.backend_mut().take()), Some(c));
    }

    #[test]
    fn a_virtual_pad_per_pad_exists_only_in_app() {
        let mut r = router();
        r.add_pad(pad("a"), t0());
        r.add_pad(pad("b"), t0());
        assert!(created(&r.backend_mut().take()).is_empty());
        r.set_route("shell", "", "", "p1", SHELL, t0());
        r.set_route("overlay", "", "", "p1", SHELL, t0());
        assert!(created(&r.backend_mut().take()).is_empty());
        app(&mut r, "i1", STK, "p1");
        let specs = created(&r.backend_mut().take());
        assert_eq!(
            specs,
            vec![
                VirtualSpec {
                    phys: "ruya-input/pad1".into(),
                    rumble: true
                },
                VirtualSpec {
                    phys: "ruya-input/pad2".into(),
                    rumble: true
                },
            ]
        );
    }

    #[test]
    fn a_pad_press_reaches_the_virtual_pad_only_while_the_app_has_the_focus() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        r.input(a, &[press(PadButton::South), release(PadButton::South)]);
        assert!(writes(&r.backend_mut().take()).is_empty());
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        r.input(a, &[press(PadButton::South)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(1, vec![(code::EV_KEY, code::BTN_SOUTH, 1)])]
        );
        r.input(a, &[release(PadButton::South)]);
        r.set_route("overlay", "i1", STK, "p1", SHELL, t0());
        r.backend_mut().take();
        r.input(
            a,
            &[
                press(PadButton::South),
                PadInput::Axis(PadAxis::LeftX, 9000),
            ],
        );
        assert!(writes(&r.backend_mut().take()).is_empty());
    }

    #[test]
    fn the_overlay_sends_neutral_once() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.input(
            a,
            &[
                press(PadButton::East),
                PadInput::Axis(PadAxis::RightTrigger, TRIGGER_MAX),
            ],
        );
        r.backend_mut().take();
        r.set_route("overlay", "i1", STK, "p1", SHELL, t0());
        let calls = r.backend_mut().take();
        assert_eq!(
            writes(&calls),
            vec![(
                1,
                vec![
                    (code::EV_KEY, code::BTN_EAST, 0),
                    (code::EV_ABS, code::ABS_RZ, 0)
                ]
            )]
        );
        assert!(destroyed(&calls).is_empty(), "the overlay keeps the pads");
        // Again: nothing more to send.
        r.set_route("overlay", "i1", STK, "p1", SHELL, t0());
        assert!(writes(&r.backend_mut().take()).is_empty());
    }

    #[test]
    fn a_press_held_through_the_overlay_does_not_reach_the_app() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.set_route("overlay", "i1", STK, "p1", SHELL, t0());
        // A closes the overlay ("Resume") and is still down when the app is back in front.
        r.input(a, &[press(PadButton::South)]);
        r.input(a, &[PadInput::Axis(PadAxis::LeftTrigger, TRIGGER_MAX)]);
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        r.input(a, &[PadInput::Axis(PadAxis::LeftTrigger, TRIGGER_MAX - 5)]);
        r.input(a, &[release(PadButton::South)]);
        assert!(writes(&r.backend_mut().take()).is_empty());
        // The next press is the app's.
        r.input(a, &[press(PadButton::South)]);
        r.input(a, &[PadInput::Axis(PadAxis::LeftTrigger, 0)]);
        r.input(a, &[PadInput::Axis(PadAxis::LeftTrigger, TRIGGER_MAX)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![
                (1, vec![(code::EV_KEY, code::BTN_SOUTH, 1)]),
                (1, vec![(code::EV_ABS, code::ABS_Z, 255)])
            ]
        );
    }

    #[test]
    fn lock_switch_run_end_and_freeze_destroy_the_virtual_pads() {
        // Lock.
        let mut r = router();
        r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        r.set_route("locked", "", "", "", SHELL, t0());
        assert_eq!(destroyed(&r.backend_mut().take()), vec![1]);
        // Profile switch: p1's pad goes, p2 gets a new one.
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        app(&mut r, "i9", STK, "p2");
        let calls = r.backend_mut().take();
        assert_eq!(destroyed(&calls), vec![2]);
        assert_eq!(created(&calls).len(), 1);
        // Another app of the same profile: the first app's descriptor must go dead too.
        app(&mut r, "i10", RACER, "p2");
        assert_eq!(destroyed(&r.backend_mut().take()), vec![3]);
        // Run end: the shell is in front.
        r.set_route("shell", "", "", "p2", SHELL, t0());
        assert_eq!(destroyed(&r.backend_mut().take()), vec![4]);
        // Freeze under the overlay: the shell passes the overlay with no instance.
        app(&mut r, "i11", RACER, "p2");
        r.backend_mut().take();
        r.set_route("overlay", "", "", "p2", SHELL, t0());
        assert_eq!(destroyed(&r.backend_mut().take()), vec![5]);
        // The Thaw: back in the app, fresh pads.
        app(&mut r, "i11", RACER, "p2");
        assert_eq!(created(&r.backend_mut().take()).len(), 1);
    }

    #[test]
    fn another_profile_never_inherits_a_pad_even_with_the_same_instance() {
        let mut r = router();
        r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.udev_event(&udev("add", "input101"));
        r.backend_mut().take();
        app(&mut r, "i1", STK, "p2");
        let calls = r.backend_mut().take();
        assert_eq!(destroyed(&calls), vec![1]);
        assert_eq!(created(&calls).len(), 1);
        // Back to p1's overlay with p2's pads: the profile differs, so they go too.
        r.set_route("overlay", "i1", STK, "p1", SHELL, t0());
        assert_eq!(destroyed(&r.backend_mut().take()), vec![2]);
    }

    #[test]
    fn nothing_is_written_to_a_destroyed_pad() {
        // The fake asserts on a write to a destroyed id; drive input around every destroy.
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.input(a, &[press(PadButton::South)]);
        r.set_route("locked", "", "", "", SHELL, t0());
        r.input(a, &[release(PadButton::South), press(PadButton::North)]);
        let calls = r.backend_mut().take();
        assert!(writes(&calls)
            .iter()
            .all(|(id, _)| *id == 1 && calls.contains(&Call::Destroy(1))));
        assert!(writes(&calls).len() == 1, "only the press before the lock");
    }

    #[test]
    fn a_vanished_pad_removes_its_virtual_pad() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        r.take_notices();
        r.remove_pad(a);
        assert_eq!(destroyed(&r.backend_mut().take()), vec![1]);
        assert!(r.take_notices().contains(&Notice::DeviceRemoved {
            id: "a".into(),
            instance: "a#1".into()
        }));
        // A pad connected while the app is in front gets the free phys number.
        r.add_pad(pad("c"), t0());
        assert_eq!(created(&r.backend_mut().take())[0].phys, "ruya-input/pad1");
        assert_eq!(r.devices().len(), 2);
        let _ = b;
    }

    #[test]
    fn a_device_record_carries_the_pads_model() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let _ = a;
        assert_eq!(r.devices()[0].model, "dualsense");
    }

    #[test]
    fn a_vanished_pad_releases_its_navigation_keys() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        r.input(a, &[press(PadButton::DpadDown)]);
        r.backend_mut().take();
        assert_eq!(r.remove_pad(a), vec![NavKey::Down]);
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Down, false)]);
    }

    // ---- the ACL ---------------------------------------------------------------------------

    #[test]
    fn the_acl_names_the_profile_user_after_udev_and_then_the_pad_is_routed() {
        let mut r = router();
        r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        assert!(!r.devices()[0].routed, "not announced before udev");
        r.take_notices();
        r.udev_event(&udev("add", "input101"));
        let acl = r.backend_mut().acls["/dev/input/event17"].clone();
        assert!(acl::is_only_user(&acl, P1_UID));
        assert!(r.devices()[0].routed);
        let n = r.take_notices();
        assert!(n
            .iter()
            .any(|n| matches!(n, Notice::DeviceChanged(d) if d.routed)));
        assert!(n
            .iter()
            .any(|n| matches!(n, Notice::Journal(l) if l.contains("ready for ruya-p1"))));
    }

    #[test]
    fn an_acl_wiped_by_a_change_event_is_reasserted() {
        let mut r = router();
        r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.udev_event(&udev("add", "input101"));
        r.backend_mut().take();
        // logind's uaccess builtin on a `change`: the seat user only.
        r.backend_mut()
            .acls
            .insert("/dev/input/event17".into(), acl::only_user(990));
        r.udev_event(&udev("change", "input101"));
        assert!(acl::is_only_user(
            &r.backend_mut().acls["/dev/input/event17"],
            P1_UID
        ));
        assert!(journal(&mut r).iter().any(|l| l.contains("re-asserted")));
        // An event that left the ACL alone writes nothing.
        r.backend_mut().take();
        r.udev_event(&udev("change", "input101"));
        assert!(r.backend_mut().take().is_empty());
    }

    #[test]
    fn the_acl_target_follows_the_profile_switch() {
        let mut r = router();
        r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.udev_event(&udev("add", "input101"));
        app(&mut r, "i2", STK, "p2");
        // The new pad (input102) is p2's; an event on p1's old node does nothing.
        r.backend_mut().acls.clear();
        r.udev_event(&udev("change", "input101"));
        assert!(r.backend_mut().acls.is_empty());
        r.udev_event(&udev("add", "input102"));
        assert!(acl::is_only_user(
            &r.backend_mut().acls["/dev/input/event17"],
            P2_UID
        ));
    }

    #[test]
    fn udev_events_of_other_devices_are_ignored() {
        let mut r = router();
        r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.udev_event(&udev("add", "input7"));
        r.udev_event(&udev("remove", "input101"));
        assert!(r.backend_mut().acls.is_empty());
        assert!(!r.devices()[0].routed);
    }

    #[test]
    fn without_a_udev_event_the_acl_is_set_after_the_fallback_time() {
        let mut r = router();
        let start = t0();
        r.add_pad(pad("a"), start);
        r.set_route("app", "i1", STK, "p1", SHELL, start);
        r.tick(start + Duration::from_millis(500));
        assert!(r.backend_mut().acls.is_empty());
        r.tick(start + UDEV_FALLBACK);
        assert!(acl::is_only_user(
            &r.backend_mut().acls["/dev/input/event-input101"],
            P1_UID
        ));
        assert!(r.devices()[0].routed);
        assert!(journal(&mut r).iter().any(|l| l.contains("no udev event")));
    }

    #[test]
    fn a_failed_acl_write_is_not_routed() {
        let mut r = router();
        r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().acl_fails = true;
        r.udev_event(&udev("add", "input101"));
        assert!(!r.devices()[0].routed);
        assert!(journal(&mut r).iter().any(|l| l.contains("failed")));
    }

    // ---- the caller ------------------------------------------------------------------------

    #[test]
    fn the_route_falls_back_to_locked_when_its_caller_leaves() {
        let mut r = router();
        r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        r.caller_left(":1.99", t0()); // someone else
        assert_eq!(r.route(), Route::App);
        r.caller_left(SHELL, t0());
        assert_eq!(r.route(), Route::Locked);
        assert_eq!(destroyed(&r.backend_mut().take()), vec![1]);
        assert!(r.take_notices().contains(&Notice::RouteChanged {
            route: "locked".into(),
            instance: "".into()
        }));
    }

    // ---- capabilities and the button test ----------------------------------------------------

    fn tested(notices: &[Notice]) -> Vec<(String, i32)> {
        notices
            .iter()
            .filter_map(|n| match n {
                Notice::TestInput { input, value, .. } => Some((input.clone(), *value)),
                _ => None,
            })
            .collect()
    }

    fn ended(notices: &[Notice]) -> Vec<(String, String)> {
        notices
            .iter()
            .filter_map(|n| match n {
                Notice::TestEnded { device_id, reason } => {
                    Some((device_id.clone(), reason.clone()))
                }
                _ => None,
            })
            .collect()
    }

    fn ev(input: PadInput) -> TestEvent {
        let (ev_type, c) = match input {
            PadInput::Button(..) => (code::EV_KEY, code::BTN_SOUTH),
            PadInput::Axis(..) => (code::EV_ABS, code::ABS_X),
        };
        TestEvent {
            input: Some(input),
            ev_type,
            code: c,
            value: 0,
        }
    }

    #[test]
    fn get_capabilities_returns_the_pads_descriptor() {
        use crate::caps::{describe, model, Part, Probe};
        let mut r = router();
        let caps = describe(
            model(0x054c, 0x0ce6),
            &Probe {
                buttons: true,
                rumble: true,
                motion: Part::Missing,
                ..Probe::default()
            },
        );
        r.add_pad(
            PadInfo {
                capabilities: caps.clone(),
                ..pad("a")
            },
            t0(),
        );
        assert_eq!(r.capabilities("a"), (Status::Ok, caps));
        assert_eq!(r.capabilities("nope"), (Status::UnknownDevice, Vec::new()));
    }

    #[test]
    fn the_test_starts_only_in_the_shell_and_once_per_device() {
        let mut r = router();
        let now = t0();
        r.add_pad(pad("a"), now);
        assert_eq!(
            r.start_test("nope", false, SHELL, now),
            Status::UnknownDevice
        );
        app(&mut r, "i1", STK, "p1");
        assert_eq!(r.start_test("a", false, SHELL, now), Status::NotAllowed);
        assert_eq!(r.set_route("shell", "", "", "p1", SHELL, now), Status::Ok);
        assert_eq!(r.start_test("a", false, SHELL, now), Status::Ok);
        assert!(r.testing());
        assert_eq!(r.start_test("a", false, SHELL, now), Status::Busy);
    }

    #[test]
    fn the_live_stream_starts_on_open_and_stops_on_close() {
        let mut r = router();
        let now = t0();
        let a = r.add_pad(pad("a"), now);
        // No test: input reaches no stream.
        r.test_input(a, &[ev(press(PadButton::South))], now);
        assert!(tested(&r.take_notices()).is_empty());
        assert_eq!(r.start_test("a", false, SHELL, now), Status::Ok);
        r.test_input(a, &[ev(press(PadButton::South))], now);
        let notices = r.take_notices();
        assert_eq!(tested(&notices), vec![("south".to_owned(), 1)]);
        assert!(notices.contains(&Notice::TestInput {
            device_id: "a".into(),
            input: "south".into(),
            value: 1,
            source: "raw:pad:1:304".into(),
        }));
        assert_eq!(r.stop_test("a"), Status::Ok);
        assert_eq!(
            ended(&r.take_notices()),
            vec![("a".to_owned(), "stopped".to_owned())]
        );
        assert!(!r.testing());
        r.test_input(a, &[ev(release(PadButton::South))], now);
        assert!(tested(&r.take_notices()).is_empty());
        // Stopping again is fine; an unknown device is not.
        assert_eq!(r.stop_test("a"), Status::Ok);
        assert_eq!(r.stop_test("nope"), Status::UnknownDevice);
    }

    #[test]
    fn axes_are_sent_at_most_30_times_a_second_and_the_last_value_arrives() {
        let mut r = router();
        let now = t0();
        let a = r.add_pad(pad("a"), now);
        r.start_test("a", false, SHELL, now);
        r.take_notices();
        // 100 stick values within one second (every 10 ms) and a button in the middle.
        for i in 0..100u32 {
            let t = now + Duration::from_millis(10 * u64::from(i));
            r.test_input(a, &[ev(PadInput::Axis(PadAxis::LeftX, i as i32))], t);
            if i == 50 {
                r.test_input(a, &[ev(press(PadButton::East))], t);
            }
        }
        let sent = tested(&r.take_notices());
        let axis: Vec<i32> = sent
            .iter()
            .filter(|(n, _)| n == "left_x")
            .map(|&(_, v)| v)
            .collect();
        assert!(axis.len() <= 30, "{} axis values in one second", axis.len());
        assert!(axis.len() >= 25, "{} axis values in one second", axis.len());
        // Buttons are never held back.
        assert!(sent.contains(&("east".to_owned(), 1)));
        // The newest value waits for the tick, then goes out once.
        r.tick(now + Duration::from_millis(1100));
        let flushed = tested(&r.take_notices());
        assert_eq!(flushed, vec![("left_x".to_owned(), 99)]);
        r.tick(now + Duration::from_millis(1200));
        assert!(tested(&r.take_notices()).is_empty());
    }

    #[test]
    fn the_test_ends_after_two_idle_minutes() {
        let mut r = router();
        let now = t0();
        let a = r.add_pad(pad("a"), now);
        r.start_test("a", false, SHELL, now);
        r.test_input(
            a,
            &[ev(press(PadButton::South))],
            now + Duration::from_secs(60),
        );
        r.take_notices();
        r.tick(now + Duration::from_secs(179));
        assert!(ended(&r.take_notices()).is_empty(), "input 119 s ago");
        r.tick(now + Duration::from_secs(180));
        assert_eq!(
            ended(&r.take_notices()),
            vec![("a".to_owned(), "idle".to_owned())]
        );
        assert!(!r.testing());
    }

    #[test]
    fn the_test_ends_on_a_route_change_a_vanished_pad_and_a_vanished_caller() {
        let mut r = router();
        let now = t0();
        let a = r.add_pad(pad("a"), now);
        r.add_pad(pad("b"), now);
        r.add_pad(pad("c"), now);
        r.start_test("a", false, SHELL, now);
        r.start_test("b", false, ":1.77", now);
        r.take_notices();
        r.caller_left(":1.77", now);
        assert_eq!(
            ended(&r.take_notices()),
            vec![("b".to_owned(), "caller".to_owned())]
        );
        r.remove_pad(a);
        assert_eq!(
            ended(&r.take_notices()),
            vec![("a".to_owned(), "gone".to_owned())]
        );
        r.start_test("c", false, SHELL, now);
        // A sign-in keeps the route "shell": the test goes on.
        assert_eq!(r.set_route("shell", "", "", "p1", SHELL, now), Status::Ok);
        assert!(ended(&r.take_notices()).is_empty());
        r.set_route("overlay", "", "", "p1", SHELL, now);
        assert_eq!(
            ended(&r.take_notices()),
            vec![("c".to_owned(), "route".to_owned())]
        );
        assert!(!r.testing());
    }

    // ---- the left stick held out of navigation (RUY-479) -------------------------------------

    fn lx(v: i32) -> PadInput {
        PadInput::Axis(PadAxis::LeftX, v)
    }

    #[test]
    fn a_held_test_sends_no_stick_key_but_still_streams_it_and_the_dpad_navigates() {
        let mut r = router();
        let now = t0();
        let a = r.add_pad(pad("a"), now);
        assert_eq!(r.start_test("a", true, SHELL, now), Status::Ok);
        r.take_notices();
        r.backend_mut().take();
        r.input(
            a,
            &[lx(STICK_MAX), PadInput::Axis(PadAxis::LeftY, STICK_MIN)],
        );
        r.test_input(a, &[ev(lx(STICK_MAX))], now);
        assert!(
            nav(&r.backend_mut().take()).is_empty(),
            "no arrow from the stick"
        );
        assert_eq!(
            tested(&r.take_notices()),
            vec![("left_x".to_owned(), STICK_MAX)]
        );
        // The right stick and the D-pad are not held.
        r.input(a, &[press(PadButton::DpadDown)]);
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Down, true)]);
        r.input(a, &[release(PadButton::DpadDown), lx(0)]);
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Down, false)]);
    }

    #[test]
    fn without_the_flag_the_stick_navigates_during_a_test() {
        let mut r = router();
        let now = t0();
        let a = r.add_pad(pad("a"), now);
        r.start_test("a", false, SHELL, now);
        r.input(a, &[lx(STICK_MIN)]);
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Left, true)]);
        r.input(a, &[lx(0)]);
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Left, false)]);
    }

    #[test]
    fn a_stick_held_when_the_hold_starts_is_released_once() {
        let mut r = router();
        let now = t0();
        let a = r.add_pad(pad("a"), now);
        r.input(a, &[lx(STICK_MIN)]);
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Left, true)]);
        r.start_test("a", true, SHELL, now);
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Left, false)]);
        // Letting go afterwards sends no second release.
        r.input(a, &[lx(0)]);
        assert!(nav(&r.backend_mut().take()).is_empty());
    }

    #[test]
    fn after_the_test_a_pushed_stick_waits_for_neutral_and_a_resting_one_navigates() {
        // Every way a test ends: the stick is pushed (no key, no stray key at its next value),
        // then neutral, then it navigates again.
        for how in ["stopped", "idle", "route", "gone", "caller"] {
            let mut r = router();
            let now = t0();
            let a = r.add_pad(pad("a"), now);
            r.start_test("a", true, SHELL, now);
            r.input(a, &[lx(STICK_MAX)]);
            match how {
                "stopped" => {
                    r.stop_test("a");
                }
                "idle" => r.tick(now + Duration::from_secs(121)),
                "route" => {
                    r.set_route("overlay", "i1", STK, "p1", SHELL, now);
                    r.set_route("shell", "", "", "p1", SHELL, now);
                }
                "gone" => {
                    r.remove_pad(a);
                }
                _ => r.caller_left(SHELL, now),
            }
            assert!(!r.testing(), "{how}");
            if how == "gone" {
                continue;
            }
            r.backend_mut().take();
            r.input(a, &[lx(STICK_MAX - 100)]);
            r.input(a, &[lx(STICK_MAX)]);
            assert!(
                nav(&r.backend_mut().take()).is_empty(),
                "{how}: no stray key"
            );
            r.input(a, &[lx(0)]);
            assert!(
                nav(&r.backend_mut().take()).is_empty(),
                "{how}: neutral sends nothing"
            );
            r.input(a, &[lx(STICK_MAX)]);
            assert_eq!(
                nav(&r.backend_mut().take()),
                vec![(NavKey::Right, true)],
                "{how}"
            );
        }
    }

    #[test]
    fn a_stick_at_rest_navigates_at_once_after_the_test() {
        let mut r = router();
        let now = t0();
        let a = r.add_pad(pad("a"), now);
        r.start_test("a", true, SHELL, now);
        r.input(a, &[lx(STICK_MAX), lx(0)]);
        r.stop_test("a");
        r.backend_mut().take();
        r.input(a, &[lx(STICK_MIN)]);
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Left, true)]);
    }

    // ---- records ---------------------------------------------------------------------------

    #[test]
    fn records_carry_the_owner_profile_and_instances_count_up() {
        let mut r = router();
        r.add_pad(pad("a"), t0());
        assert_eq!(r.devices()[0].profile, "");
        assert_eq!(r.devices()[0].instance, "a#1");
        r.set_route("shell", "", "", "p1", SHELL, t0());
        assert_eq!(r.devices()[0].profile, "p1");
        assert!(r
            .take_notices()
            .iter()
            .any(|n| matches!(n, Notice::DeviceChanged(d) if d.profile == "p1")));
        let a2 = r.add_pad(pad("a"), t0());
        r.remove_pad(a2);
        let a3 = r.add_pad(pad("a"), t0());
        let _ = a3;
        assert_eq!(r.devices()[1].instance, "a#3");
    }

    // ---- the confirm button (06 section 11.2) -----------------------------------------------

    fn family_pad(id: &str, family: &str) -> PadInfo {
        PadInfo {
            family: family.into(),
            ..pad(id)
        }
    }

    /// The shell route with `profile` signed in.
    fn signed_in(r: &mut Router<Fake>, profile: &str) {
        assert_eq!(
            r.set_route("shell", "", "", profile, SHELL, t0()),
            Status::Ok
        );
    }

    fn keys_of(r: &mut Router<Fake>) -> Vec<KeyEvent> {
        nav(&r.backend_mut().take())
    }

    #[test]
    fn a_nintendo_pad_confirms_with_its_right_button() {
        let mut r = router();
        let a = r.add_pad(family_pad("n", "nintendo"), t0());
        signed_in(&mut r, "p1");
        r.backend_mut().take();
        r.input(a, &[press(PadButton::East), release(PadButton::East)]);
        assert_eq!(
            keys_of(&mut r),
            vec![(NavKey::Accept, true), (NavKey::Accept, false)]
        );
        r.input(a, &[press(PadButton::South), release(PadButton::South)]);
        assert_eq!(
            keys_of(&mut r),
            vec![(NavKey::Back, true), (NavKey::Back, false)]
        );
    }

    #[test]
    fn the_setting_swaps_per_family_and_unknown_families_stay_positional() {
        let mut r = router();
        let ps = r.add_pad(family_pad("ps", "playstation"), t0());
        let nin = r.add_pad(family_pad("nin", "nintendo"), t0());
        let odd = r.add_pad(family_pad("odd", "unheard-of"), t0());
        signed_in(&mut r, "p1");
        let south_of = |r: &mut Router<Fake>, pad| {
            r.backend_mut().take();
            r.input(pad, &[press(PadButton::South), release(PadButton::South)]);
            keys_of(r)[0].0
        };
        assert_eq!(south_of(&mut r, ps), NavKey::Accept);
        assert_eq!(south_of(&mut r, nin), NavKey::Back);
        assert_eq!(south_of(&mut r, odd), NavKey::Accept);
        assert_eq!(r.set_confirm_button("p1", "east"), Status::Ok);
        assert_eq!(south_of(&mut r, ps), NavKey::Back, "Circle confirms");
        assert_eq!(south_of(&mut r, nin), NavKey::Back);
        assert_eq!(south_of(&mut r, odd), NavKey::Back);
        assert_eq!(r.set_confirm_button("p1", "south"), Status::Ok);
        assert_eq!(south_of(&mut r, ps), NavKey::Accept);
        assert_eq!(
            south_of(&mut r, nin),
            NavKey::Accept,
            "Bottom on a Nintendo pad"
        );
        assert_eq!(r.set_confirm_button("p1", "family"), Status::Ok);
        assert_eq!(south_of(&mut r, nin), NavKey::Back);
    }

    #[test]
    fn a_held_button_is_released_as_it_was_pressed_after_the_setting_changes() {
        let mut r = router();
        let a = r.add_pad(family_pad("x", "xbox"), t0());
        signed_in(&mut r, "p1");
        r.backend_mut().take();
        r.input(a, &[press(PadButton::South)]);
        assert_eq!(keys_of(&mut r), vec![(NavKey::Accept, true)]);
        assert_eq!(r.set_confirm_button("p1", "east"), Status::Ok);
        r.input(a, &[release(PadButton::South)]);
        assert_eq!(keys_of(&mut r), vec![(NavKey::Accept, false)]);
        // Held across a profile switch too: p2 has "family", p1 "east".
        r.input(a, &[press(PadButton::South)]);
        assert_eq!(keys_of(&mut r), vec![(NavKey::Back, true)]);
        signed_in(&mut r, "p2");
        r.input(a, &[release(PadButton::South)]);
        assert_eq!(keys_of(&mut r), vec![(NavKey::Back, false)]);
    }

    #[test]
    fn a_pad_that_vanishes_mid_press_leaves_no_key_down() {
        let mut r = router();
        let a = r.add_pad(family_pad("n", "nintendo"), t0());
        signed_in(&mut r, "p1");
        r.backend_mut().take();
        r.input(a, &[press(PadButton::East)]);
        assert_eq!(r.set_confirm_button("p1", "south"), Status::Ok);
        assert_eq!(r.remove_pad(a), vec![NavKey::Accept]);
        assert_eq!(
            keys_of(&mut r),
            vec![(NavKey::Accept, true), (NavKey::Accept, false)]
        );
    }

    #[test]
    fn the_setting_is_per_console_profile_and_follows_the_switch() {
        let mut r = router();
        let a = r.add_pad(family_pad("x", "xbox"), t0());
        assert_eq!(r.confirm_button(), "family", "no profile");
        signed_in(&mut r, "p1");
        assert_eq!(r.set_confirm_button("p1", "east"), Status::Ok);
        assert_eq!(r.confirm_button(), "east");
        r.take_notices();
        signed_in(&mut r, "p2");
        assert_eq!(r.confirm_button(), "family");
        assert!(
            r.take_notices()
                .iter()
                .any(|n| matches!(n, Notice::ConfirmButtonChanged)),
            "a switch announces the property"
        );
        // A set for the signed-in profile announces the property.
        assert_eq!(r.set_confirm_button("p2", "south"), Status::Ok);
        assert!(
            r.take_notices()
                .iter()
                .any(|n| matches!(n, Notice::ConfirmButtonChanged)),
            "a set for the active profile announces the property"
        );
        assert_eq!(r.set_confirm_button("p2", "family"), Status::Ok);
        r.take_notices();
        // Another profile's change is not the active profile's property.
        assert_eq!(r.set_confirm_button("p1", "south"), Status::Ok);
        assert!(
            !r.take_notices()
                .iter()
                .any(|n| matches!(n, Notice::ConfirmButtonChanged)),
            "another profile's change is not the property"
        );
        r.backend_mut().take();
        r.input(a, &[press(PadButton::South)]);
        assert_eq!(keys_of(&mut r), vec![(NavKey::Accept, true)]);
        signed_in(&mut r, "p1");
        assert_eq!(r.confirm_button(), "south");
    }

    #[test]
    fn set_confirm_button_answers_ok_invalid_unknown_profile_or_failed() {
        let mut r = router();
        assert_eq!(r.set_confirm_button("p1", "Right"), Status::Invalid);
        assert_eq!(r.set_confirm_button("p1", ""), Status::Invalid);
        assert_eq!(
            r.set_confirm_button("nobody", "east"),
            Status::UnknownProfile
        );
        assert_eq!(r.set_confirm_button("", "east"), Status::UnknownProfile);
        assert_eq!(r.set_confirm_button("root", "east"), Status::UnknownProfile);
        assert_eq!(r.set_confirm_button("p1", "east"), Status::Ok);
        let store = crate::book::MemStore {
            fail: true,
            ..Default::default()
        };
        r.set_book(Book::new(Box::new(store)));
        signed_in(&mut r, "p1");
        assert_eq!(r.set_confirm_button("p1", "east"), Status::Failed);
        assert_eq!(
            r.confirm_button(),
            "family",
            "a refused write changes nothing"
        );
    }

    #[test]
    fn the_setting_is_read_from_the_state_directory() {
        let mut store = crate::book::MemStore::default();
        store.files.insert(
            ("p1".into(), crate::book::SETTINGS.into()),
            r#"{"confirm_button":"east"}"#.into(),
        );
        store.files.insert(
            ("p2".into(), crate::book::SETTINGS.into()),
            r#"{"confirm_button":"sideways"}"#.into(),
        );
        let mut r = router();
        r.set_book(Book::new(Box::new(store)));
        signed_in(&mut r, "p1");
        assert_eq!(r.confirm_button(), "east");
        signed_in(&mut r, "p2");
        assert_eq!(r.confirm_button(), "family", "a bad mode is not used");
        assert!(journal(&mut r).iter().any(|l| l.contains("sideways")));
        // The settings file is no profile.
        let (_, list) = r.list_profiles("p1");
        assert!(list.iter().all(|s| s.id != "_settings"), "{list:?}");
    }

    #[test]
    fn the_virtual_pad_never_sees_the_confirm_setting() {
        let events_for = |mode: &str| {
            let mut r = router();
            let a = r.add_pad(family_pad("n", "nintendo"), t0());
            assert_eq!(r.save_profile("p1", SWAP).0, Status::Ok);
            assert_eq!(r.assign_profile("p1", "global", "", "swap"), Status::Ok);
            assert_eq!(r.set_confirm_button("p1", mode), Status::Ok);
            app(&mut r, "i1", STK, "p1");
            r.backend_mut().take();
            r.input(a, &[press(PadButton::South), press(PadButton::East)]);
            let calls = r.backend_mut().take();
            assert!(nav(&calls).is_empty(), "no navigation key under an app");
            writes(&calls)
        };
        let family = events_for("family");
        assert!(!family.is_empty());
        assert_eq!(family, events_for("east"));
        assert_eq!(family, events_for("south"));
    }

    #[test]
    fn the_active_input_is_announced_when_another_pad_presses() {
        let active = |r: &mut Router<Fake>| -> Vec<(String, String)> {
            r.take_notices()
                .into_iter()
                .filter_map(|n| match n {
                    Notice::ActiveInput { device_id, family } => Some((device_id, family)),
                    _ => None,
                })
                .collect()
        };
        let mut r = router();
        let a = r.add_pad(family_pad("a", "playstation"), t0());
        let b = r.add_pad(family_pad("b", "nintendo"), t0());
        r.take_notices();
        r.input(a, &[PadInput::Axis(PadAxis::LeftX, 100)]);
        assert!(active(&mut r).is_empty(), "no press, no change");
        r.input(a, &[press(PadButton::South)]);
        r.input(a, &[release(PadButton::South), press(PadButton::East)]);
        assert_eq!(
            active(&mut r),
            vec![("a".to_owned(), "playstation".to_owned())]
        );
        r.input(b, &[press(PadButton::East)]);
        assert_eq!(
            active(&mut r),
            vec![("b".to_owned(), "nintendo".to_owned())]
        );
        r.input(a, &[release(PadButton::East)]);
        assert!(active(&mut r).is_empty(), "a release is no press");
    }

    // ---- rumble ----------------------------------------------------------------------------

    const RUMBLE: Rumble = Rumble {
        strong: 40000,
        weak: 20000,
        length_ms: 500,
        delay_ms: 0,
    };

    #[test]
    fn rumble_is_forwarded_to_the_physical_pad() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        assert_eq!(r.ff_upload(1, 0, &RUMBLE), Ok(()));
        r.ff_play(1, 0, 1);
        // An update keeps the physical effect id.
        assert_eq!(r.ff_upload(1, 0, &RUMBLE), Ok(()));
        r.ff_play(1, 0, 0);
        r.ff_erase(1, 0);
        assert_eq!(
            r.backend_mut().take(),
            vec![
                Call::FfUpload(a, -1, RUMBLE),
                Call::FfPlay(a, 1, 1),
                Call::FfUpload(a, 1, RUMBLE),
                Call::FfPlay(a, 1, 0),
                Call::FfErase(a, 1),
            ]
        );
        assert_eq!(r.ff_upload(77, 0, &RUMBLE), Err(ENODEV));
    }

    #[test]
    fn rumble_stops_at_the_overlay_and_its_effects_go_with_the_pad() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.ff_upload(1, 0, &RUMBLE).expect("uploaded");
        r.ff_play(1, 0, 1);
        r.backend_mut().take();
        r.set_route("overlay", "i1", STK, "p1", SHELL, t0());
        assert_eq!(r.backend_mut().take(), vec![Call::FfPlay(a, 1, 0)]);
        r.ff_play(1, 0, 1); // the app plays again under the overlay: not forwarded
        assert!(r.backend_mut().take().is_empty());
        r.set_route("locked", "", "", "", SHELL, t0());
        let calls = r.backend_mut().take();
        assert_eq!(calls[0], Call::FfErase(a, 1));
        assert_eq!(destroyed(&calls), vec![1]);
    }

    // ---- controller profiles ----------------------------------------------------------------

    const SWAP: &str = r#"{"schema_version":1,"id":"swap","name":"Swap","scope":{"type":"global"},
        "mappings":[{"from":"south","to":{"type":"button","code":"east"}},
                    {"from":"guide","to":{"type":"button","code":"south"}}]}"#;

    fn profiles_changed(r: &mut Router<Fake>) -> Vec<String> {
        r.take_notices()
            .into_iter()
            .filter_map(|n| match n {
                Notice::ProfilesChanged { profile } => Some(profile),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn a_remap_changes_what_the_virtual_pad_emits_at_once() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.input(a, &[press(PadButton::South)]);
        r.backend_mut().take();
        r.take_notices();
        // South is held when the profile changes: the virtual pad lets go of South, presses East.
        assert_eq!(r.save_profile("p1", SWAP).0, Status::Ok);
        assert!(
            writes(&r.backend_mut().take()).is_empty(),
            "saved, not assigned yet"
        );
        assert_eq!(r.assign_profile("p1", "global", "", "swap"), Status::Ok);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(
                1,
                vec![
                    (code::EV_KEY, code::BTN_SOUTH, 0),
                    (code::EV_KEY, code::BTN_EAST, 1)
                ]
            )]
        );
        assert_eq!(
            profiles_changed(&mut r),
            ["p1", "p1"],
            "the save and the assignment"
        );
        r.input(a, &[release(PadButton::South)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(1, vec![(code::EV_KEY, code::BTN_EAST, 0)])]
        );
        // The next press on the same virtual pad follows the profile too (RUY-493).
        r.input(a, &[press(PadButton::South)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(1, vec![(code::EV_KEY, code::BTN_EAST, 1)])]
        );
        r.input(a, &[release(PadButton::South)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(1, vec![(code::EV_KEY, code::BTN_EAST, 0)])]
        );
        // Guide stays the console's whatever the profile says.
        r.input(a, &[press(PadButton::Guide)]);
        let calls = r.backend_mut().take();
        assert!(
            writes(&calls).is_empty(),
            "Guide mapped to south reached the pad: {calls:?}"
        );
        assert_eq!(nav(&calls), vec![(NavKey::Guide, true)]);
        r.input(a, &[release(PadButton::Guide)]);
        // A new virtual pad (the next app) is made with the profile.
        app(&mut r, "i2", STK, "p1");
        r.backend_mut().take();
        r.input(a, &[press(PadButton::South)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(2, vec![(code::EV_KEY, code::BTN_EAST, 1)])]
        );
        // Removing the assignment gives the built-in default back.
        r.input(a, &[release(PadButton::South)]);
        r.assign_profile("p1", "global", "", "");
        r.backend_mut().take();
        r.input(a, &[press(PadButton::South)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(2, vec![(code::EV_KEY, code::BTN_SOUTH, 1)])]
        );
    }

    #[test]
    fn a_release_and_a_press_in_separate_frames_both_reach_the_virtual_pad() {
        // The router sees one `input` call per evdev frame (`Normalizer::frames`): the release and
        // the press of a held button after a profile swap are two calls, two writes.
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.input(a, &[press(PadButton::South)]);
        r.save_profile("p1", SWAP);
        r.assign_profile("p1", "global", "", "swap");
        r.backend_mut().take();
        r.input(a, &[release(PadButton::South)]);
        r.input(a, &[press(PadButton::South)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![
                (1, vec![(code::EV_KEY, code::BTN_EAST, 0)]),
                (1, vec![(code::EV_KEY, code::BTN_EAST, 1)])
            ]
        );
    }

    #[test]
    fn another_profiles_change_does_not_touch_the_pads() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        r.save_profile("p2", SWAP);
        r.assign_profile("p2", "global", "", "swap");
        assert_eq!(profiles_changed(&mut r), ["p2", "p2"]);
        r.input(a, &[press(PadButton::South)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(1, vec![(code::EV_KEY, code::BTN_SOUTH, 1)])]
        );
    }

    #[test]
    fn the_stick_settings_reach_the_virtual_pad() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        // Inside the default 8 % dead zone: nothing moves.
        r.input(a, &[PadInput::Axis(PadAxis::LeftX, 2000)]);
        assert!(writes(&r.backend_mut().take()).is_empty());
        let none = r#"{"schema_version":1,"id":"raw","name":"Raw","scope":{"type":"global"},
            "settings":{"left_stick":{"inner_deadzone":0,"outer_deadzone":0,"invert_x":true}}}"#;
        r.save_profile("p1", none);
        r.assign_profile("p1", "global", "", "raw");
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(1, vec![(code::EV_ABS, code::ABS_X, -2000)])]
        );
    }

    #[test]
    fn under_the_overlay_a_profile_change_sends_nothing() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        app(&mut r, "i1", STK, "p1");
        r.input(a, &[press(PadButton::South)]);
        r.set_route("overlay", "i1", STK, "p1", SHELL, t0());
        r.backend_mut().take();
        r.save_profile("p1", SWAP);
        r.assign_profile("p1", "global", "", "swap");
        assert!(writes(&r.backend_mut().take()).is_empty());
    }

    #[test]
    fn profile_calls_need_a_profile_account() {
        let mut r = router();
        assert_eq!(r.list_profiles("p9").0, Status::UnknownProfile);
        assert_eq!(r.list_profiles("../etc").0, Status::UnknownProfile);
        assert_eq!(r.get_profile("shell", "default").0, Status::UnknownProfile);
        assert_eq!(r.save_profile("", SWAP).0, Status::UnknownProfile);
        assert_eq!(r.delete_profile("p9", "swap"), Status::UnknownProfile);
        assert_eq!(
            r.assign_profile("p9", "global", "", "default"),
            Status::UnknownProfile
        );
        assert_eq!(r.effective_profile("p9", "", "").0, Status::UnknownProfile);
        assert_eq!(r.list_profiles("p1").0, Status::Ok);
        assert_eq!(r.get_profile("p1", "nope").0, Status::UnknownProfile);
        assert!(profiles_changed(&mut r).is_empty(), "nothing changed");
    }

    #[test]
    fn the_effective_profile_follows_the_pad() {
        let mut r = router();
        r.add_pad(pad("a"), t0());
        let ps = SWAP.replace(
            r#""scope":{"type":"global"},"#,
            r#""scope":{"type":"global"},"match":{"family":"playstation"},"#,
        );
        assert_eq!(r.save_profile("p1", &ps).0, Status::Ok);
        // The slot its match names (RUY-545; all controllers' slot refuses it).
        assert_eq!(
            r.assign_profile("p1", "global", "", "swap"),
            Status::Invalid
        );
        assert_eq!(
            r.assign_profile("p1", "global", "family:playstation", "swap"),
            Status::Ok
        );
        let (status, json, chain) = r.effective_profile("p1", "a", "");
        assert_eq!(
            (status, chain.as_slice()),
            (
                Status::Ok,
                ["swap".to_owned(), "default".to_owned()].as_slice()
            )
        );
        assert!(json.contains("\"east\""));
        assert_eq!(
            r.effective_profile("p1", "", "").2,
            ["default"],
            "no family: the match does not fit"
        );
        assert_eq!(r.effective_profile("p1", "b", "").0, Status::UnknownDevice);
        assert_eq!(
            r.effective_profile("p1", "a", "no spaces").0,
            Status::Invalid
        );
        assert_eq!(r.effective_profile("p1", "a", RACER).0, Status::Ok);
    }

    // RUY-545: a DualSense with its own profile and a Nintendo pad with its family's, both in the
    // game; each virtual pad follows its own, and emptying one slot changes only that pad.
    #[test]
    fn each_pad_takes_its_own_slot_at_once() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(family_pad("b", "nintendo"), t0());
        app(&mut r, "i1", STK, "p1");
        let own = SWAP.replace(r#""id":"swap""#, r#""id":"own""#).replace(
            r#""scope":{"type":"global"},"#,
            r#""scope":{"type":"global"},"match":{"device":"a"},"#,
        );
        let family = r#"{"schema_version":1,"id":"fam","name":"Fam","scope":{"type":"global"},
            "match":{"family":"nintendo"},"mappings":[{"from":"south","to":{"type":"button","code":"l1"}}]}"#;
        assert_eq!(r.save_profile("p1", &own).0, Status::Ok);
        assert_eq!(r.save_profile("p1", family).0, Status::Ok);
        assert_eq!(
            r.assign_profile("p1", "global", "device:a", "own"),
            Status::Ok
        );
        assert_eq!(
            r.assign_profile("p1", "global", "family:nintendo", "fam"),
            Status::Ok
        );
        r.backend_mut().take();
        let tap = |r: &mut Router<Fake>, key: PadKey| {
            r.input(key, &[press(PadButton::South)]);
            let out = writes(&r.backend_mut().take());
            r.input(key, &[release(PadButton::South)]);
            r.backend_mut().take();
            assert_eq!(out.len(), 1, "{out:?}");
            out[0].clone()
        };
        let (va, ea) = tap(&mut r, a);
        let (vb, eb) = tap(&mut r, b);
        assert_ne!(va, vb, "each pad has its own virtual pad");
        assert_eq!(ea, vec![(code::EV_KEY, code::BTN_EAST, 1)], "A: its own");
        assert_eq!(eb, vec![(code::EV_KEY, code::BTN_TL, 1)], "B: its family's");
        assert_eq!(
            r.effective_profile("p1", "a", "").2,
            ["own".to_owned(), "default".to_owned()]
        );
        assert_eq!(
            r.effective_profile("p1", "b", "").2,
            ["fam".to_owned(), "default".to_owned()]
        );
        // Emptying the family's slot: B gets the default, A keeps its own.
        assert_eq!(
            r.assign_profile("p1", "global", "family:nintendo", ""),
            Status::Ok
        );
        assert_eq!(
            tap(&mut r, b),
            (vb, vec![(code::EV_KEY, code::BTN_SOUTH, 1)])
        );
        assert_eq!(
            tap(&mut r, a),
            (va, vec![(code::EV_KEY, code::BTN_EAST, 1)])
        );
    }
}
