//! The routing core (06-input.md §5.1-5.2): who receives the pads, the shell as navigation keys
//! or the focused app's profile as virtual pads. Pure: every device side effect goes through
//! `Backend`, time is passed in, and what the D-Bus adapter must announce comes out as `Notice`s.
//!
//! Rules:
//! - Routes `shell`, `overlay` and `locked` produce navigation keys; `app` produces only Guide
//!   (`KEY_HOMEPAGE`, always the shell's) and feeds the virtual pads.
//! - Only a seated pad (`seats`, ADR-017, RUY-121) has a virtual pad, and its number is its seat
//!   (`ruya-input/pad<slot>`, so pad1 is player 1); an unseated pad's input reaches no app. A
//!   profile change seats the new profile in seat 1 on the pad that signed it in and empties the
//!   other seats; a leave destroys the seat's virtual pad, a move binds it to the new pad. Of two
//!   connections with one stable id (twins) only one is the seat's pad (RUY-642).
//! - A seated pad that disconnects holds its seat for `SEAT_HOLD` (RUY-627, seat 1 too): its
//!   virtual pad stays (one neutral frame, its rumble dropped) and is bound to the pad that comes
//!   back, the same stable id or the one like pad (06 §4.1), so the app sees no pad go or come.
//!   When the hold runs out the seat is freed (seat 1 keeps its profile without a pad) and the
//!   virtual pad is destroyed.
//! - Virtual pads (one per seated pad, phys `ruya-input/pad<n>`) exist only while the route is
//!   `app` or `overlay` over the same app instance and profile, frozen or not (a Freeze by the Hub
//!   keeps them, RUY-541), and the `app` that follows it keeps the same devices. Any other route,
//!   another instance or another profile destroys them (lock, switch, run end, an overlay that
//!   names no app): a descriptor the app opened reads `ENODEV`, so nothing reaches it afterwards
//!   (an ACL change would not close it).
//! - `overlay` over the pads' instance holds them in neutral (once); no input reaches them.
//! - Entering `app` for a new owner, pad1 (the profile's active controller) is made first and the
//!   others wait until pad1's ACL is set or its udev fallback ran, so pad1 is the first pad an
//!   app can open (RUY-541); a pad that arrives while pad1 waits waits too.
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
use crate::seats::{Joined, Player, Seats, SEATS};
use crate::udev::UdevEvent;

pub type PadKey = u64;
pub type VirtualId = u64;

/// When no udev event arrives for a new virtual pad (the monitor is not working), the ACL is set
/// this long after creation anyway, and the journal says so.
pub const UDEV_FALLBACK: Duration = Duration::from_secs(2);

/// How long a seat waits for its pad when the pad disconnects (RUY-627, ADR-017 point 9).
pub const SEAT_HOLD: Duration = Duration::from_secs(60);

/// `RUYA_SEAT_HOLD_SECS` (the VM checks only): a whole number of seconds, at least 1, else `None`.
pub fn seat_hold_from_env(value: Option<&str>) -> Option<Duration> {
    value
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|&s| s > 0)
        .map(Duration::from_secs)
}

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
    /// `JoinPlayer`: every seat is taken (RUY-121).
    Full,
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
            Status::Full => "full",
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
    /// The stable id names the USB port, not the pad: a USB pad without a serial
    /// (`identity::port_bound`). Such a pad may take a like pad's held seat (06 §4.1, RUY-627).
    pub port_bound: bool,
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
    /// The seats changed (`PlayersChanged`, RUY-121): the whole list, once per change.
    PlayersChanged(Vec<Player>),
    /// A pad that does not navigate now asked for something (`ForeignInput`, RUY-38): `kind` is
    /// "press", "guide" or "player-guide" (06 §11.3).
    ForeignInput {
        device_id: String,
        kind: &'static str,
    },
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
    /// The profile seated on the pad when it was made: a seat taken by another profile is a new
    /// virtual pad (the player left, another joined).
    player: String,
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
    /// The app's effects as it uploaded them: uploaded again to the pad it is bound to (RUY-627).
    effects: BTreeMap<i16, Rumble>,
    playing: BTreeSet<i16>,
    /// The profile that applies to this pad, compiled.
    engine: Engine,
}

/// What a held seat keeps of its gone pad (RUY-627): the virtual pad the app still has (`None`
/// when the route had none, or it was destroyed meanwhile) and what the like-pad rule needs.
#[derive(Debug)]
struct Parked {
    /// The key the gone pad had.
    key: PadKey,
    port_bound: bool,
    virt: Option<Virtual>,
}

/// The part of a serial-less USB pad's stable id that a like pad shares (`usb-<vid>-<pid>`).
fn like_key(id: &str) -> Option<&str> {
    id.rsplit_once('-')
        .map(|(prefix, _)| prefix)
        .filter(|p| p.starts_with("usb-"))
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
    /// The pad navigates the shell now (`Router::navigates`, 06 §11.3; RUY-38). Its mapper's keys
    /// are counted in the `KeyBoard` exactly while this is true.
    navigates: bool,
    /// When its last `ForeignInput` "press" was sent (at most one per `FOREIGN_PRESS_GAP`).
    foreign_press: Option<Instant>,
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

/// The number of an unseated pad's virtual pad while the seat gate is off (RUY-121 round 2): the
/// lowest one after the seats that no live virtual pad has, so a later join renumbers nobody.
fn unseated_number(pads: &BTreeMap<PadKey, Pad>) -> u32 {
    (SEATS + 1..)
        .find(|n| {
            !pads
                .values()
                .any(|p| p.virt.as_ref().is_some_and(|v| v.n == *n))
        })
        .unwrap_or(SEATS + 1)
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
    /// The players' seats (ADR-017, RUY-121). Seat 1's pad is the signed-in profile's active
    /// controller: the pad that gave the last input when the route first went to the profile (the
    /// sign-in), kept until the profile changes or `JoinPlayer` moves player 1 (06 5.1).
    seats: Seats,
    /// The stable id of the pad that pressed last since the profile last changed. Only such a pad can
    /// become the next profile's seat 1 pad; a keyboard sign-in leaves it `None` (ADR-017 am. 6b).
    pad_since_change: Option<String>,
    /// Pads whose record changed: one `DeviceChanged` each when the notices are taken.
    dirty: BTreeSet<PadKey>,
    /// The players as `PlayersChanged` last announced them.
    announced_players: Vec<Player>,
    /// When pad input in `app` is announced to the shell as activity (RUY-588).
    activity: ActivityGate,
    /// Pads whose virtual pad waits for pad1 to be ready (RUY-541), in the order they are made.
    waiting: Vec<PadKey>,
    /// Only seated pads get a virtual pad (true), or every connected pad does, the unseated ones
    /// numbered after the seats (false: `SEAT_GATE`, until RUY-122's prompt calls JoinPlayer).
    seat_gate: bool,
    /// The held seats' leftovers, by the gone pad's stable id: an entry exactly while
    /// `seats.is_held` says so (RUY-627).
    holds: BTreeMap<String, Parked>,
    /// `SEAT_HOLD`, or what `RUYA_SEAT_HOLD_SECS` set.
    seat_hold: Duration,
    /// `SetNavigator` (RUY-38): the stable id of the only pad that navigates, and the bus name
    /// that set it (it is cleared when that name leaves the bus).
    navigator: Option<(String, String)>,
}

/// An unseated pad's `ForeignInput` "press" is sent at most once per pad in this time (06 §11.3).
pub const FOREIGN_PRESS_GAP: Duration = Duration::from_secs(1);

/// The production value of `Router::new`'s `seat_gate`: off until "Who's playing?" (RUY-122) can
/// seat a second pad, so local co-op keeps every pad meanwhile (lead decision, RUY-121 round 2).
pub const SEAT_GATE: bool = false;

impl<B: Backend> Router<B> {
    /// Starts in `shell` with no profile: navigation keys, no virtual pad (as before Input1).
    /// `seat_gate`: whether an unseated pad is kept from the app (`SEAT_GATE` in production).
    pub fn new(backend: B, accounts: Box<dyn Accounts>, seat_gate: bool) -> Self {
        Router {
            seat_gate,
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
            seats: Seats::default(),
            pad_since_change: None,
            dirty: BTreeSet::new(),
            announced_players: Vec::new(),
            waiting: Vec::new(),
            holds: BTreeMap::new(),
            seat_hold: SEAT_HOLD,
            navigator: None,
        }
    }

    /// Shortens `SEAT_HOLD` (`RUYA_SEAT_HOLD_SECS`: the VM checks).
    pub fn set_seat_hold(&mut self, hold: Duration) {
        self.seat_hold = hold;
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

    /// What to announce since the last call. A pad whose record changed is one `DeviceChanged`
    /// (with its record now), and a change of the seats is one `PlayersChanged`, at the end.
    pub fn take_notices(&mut self) -> Vec<Notice> {
        for key in std::mem::take(&mut self.dirty) {
            if let Some(pad) = self.pads.get(&key) {
                let rec = self.record(key, pad);
                self.notices.push(Notice::DeviceChanged(rec));
            }
        }
        let players = self.seats.players();
        if players != self.announced_players {
            self.announced_players = players.clone();
            self.notices.push(Notice::PlayersChanged(players));
        }
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

    fn record(&self, key: PadKey, pad: &Pad) -> DeviceRecord {
        let (slot, profile) = self.seat_number(key).unwrap_or_default();
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
            slot,
            profile,
            routed: pad.virt.as_ref().is_some_and(|v| v.ready),
        }
    }

    pub fn devices(&self) -> Vec<DeviceRecord> {
        self.pads.iter().map(|(&k, p)| self.record(k, p)).collect()
    }

    /// The seat (number, profile) of the connection `key`: its pad's seat, if it is the seat's
    /// connection. Of two connections with one stable id (twins, RUY-642) only one is: the one with
    /// the seat's virtual pad, else the first (the lowest key).
    fn seat_number(&self, key: PadKey) -> Option<(u32, String)> {
        let pad = self.pads.get(&key)?;
        let (n, profile) = self.seats.seat_of(&pad.info.id)?;
        let twins = || self.pads.iter().filter(|(_, p)| p.info.id == pad.info.id);
        let holder = twins()
            .find(|(_, p)| p.virt.as_ref().is_some_and(|v| v.n == n))
            .or_else(|| twins().next())
            .map(|(&k, _)| k);
        (holder == Some(key)).then(|| (n, profile.to_owned()))
    }

    /// The pad's record changed: announced once when the notices are taken.
    fn changed(&mut self, key: PadKey) {
        self.dirty.insert(key);
    }

    // ---- pads -------------------------------------------------------------------------------

    pub fn add_pad(&mut self, info: PadInfo, now: Instant) -> PadKey {
        let key = self.next_key;
        self.next_key += 1;
        let instance = format!("{}#{}", info.id, self.next_instance);
        self.next_instance += 1;
        let id = info.id.clone();
        let port_bound = info.port_bound;
        let pad = Pad {
            info,
            instance,
            mapper: Mapper::default(),
            state: PadState::default(),
            virt: None,
            nav_masked: Vec::new(),
            navigates: false,
            foreign_press: None,
        };
        self.pads.insert(key, pad);
        // A pad back within its seat's hold sits there again, on the virtual pad it had (RUY-627).
        self.take_held_seat(key, &id, port_bound);
        let rec = self.record(key, &self.pads[&key]);
        self.notices.push(Notice::DeviceAdded(rec));
        self.dirty.remove(&key);
        // Only a seated pad gets a virtual pad (RUY-121): a held seat's pad that came back without
        // one gets it now, and (gate off) an unseated pad gets a number after the seats.
        if self.route == Route::App && self.owner.is_some() {
            self.queue_missing();
            self.make_waiting(now);
        }
        self.sync_navigation();
        key
    }

    /// `remove_pad_at` with the real clock, for the tests that do not care about time.
    #[cfg(test)]
    pub fn remove_pad(&mut self, key: PadKey) -> Vec<NavKey> {
        self.remove_pad_at(key, Instant::now())
    }

    /// The pad is gone: its navigation keys are released (the keys it held are returned for the
    /// journal). A seated pad's seat is held until `now` + the hold, its virtual pad kept in
    /// neutral (RUY-627); an unseated pad's virtual pad is destroyed.
    pub fn remove_pad_at(&mut self, key: PadKey, now: Instant) -> Vec<NavKey> {
        let seat = self.seat_number(key);
        let Some(mut pad) = self.pads.remove(&key) else {
            return Vec::new();
        };
        // Pads waiting for this one as pad1 are made at the next tick (it has the clock).
        self.waiting.retain(|&k| k != key);
        if self.active_input.as_deref() == Some(pad.info.id.as_str()) {
            let before = self.active_mode();
            self.active_input = None;
            if before != Confirm::Family {
                self.notices.push(Notice::ConfirmButtonChanged);
            }
        }
        if self.pad_since_change.as_deref() == Some(pad.info.id.as_str()) {
            self.pad_since_change = None;
        }
        let held = pad.mapper.held_keys();
        let keys = self.board.pad_gone(&mut pad.mapper);
        self.backend.nav_keys(&keys);
        let twin = self.pads.values().any(|p| p.info.id == pad.info.id);
        let mut virt = pad.virt.take();
        if seat.is_some() {
            // The node is gone, and the effects the app played on it with it: nothing to erase.
            if let Some(v) = virt.as_mut() {
                v.ff.clear();
                v.playing.clear();
            }
        }
        match (seat, virt) {
            // Another connection with the same stable id is there (a twin): it is the seat's pad now.
            (Some(_), virt) if twin => {
                let spare = virt.map(|v| vec![(key, v)]).unwrap_or_default();
                self.sync_virtuals_with(now, spare);
            }
            (Some((slot, profile)), virt) => {
                let before = self.seats.clone();
                if self
                    .seats
                    .hold(&pad.info.id, now + self.seat_hold)
                    .is_some()
                {
                    let virt = virt.map(|mut v| {
                        self.neutral(&mut v);
                        v
                    });
                    self.journal(format!(
                        "player {slot} (ruya-{profile}) held for {} s: {} is gone",
                        self.seat_hold.as_secs(),
                        pad.info.id
                    ));
                    self.holds.insert(
                        pad.info.id.clone(),
                        Parked {
                            key,
                            port_bound: pad.info.port_bound,
                            virt,
                        },
                    );
                    self.seats_changed(&before);
                } else if let Some(v) = virt {
                    self.drop_virtual(key, v);
                }
            }
            (None, Some(v)) => self.drop_virtual(key, v),
            (None, None) => {}
        }
        self.end_test(&pad.info.id, "gone");
        if !twin
            && self
                .navigator
                .as_ref()
                .is_some_and(|(n, _)| *n == pad.info.id)
        {
            self.clear_navigator(&format!("{} is gone", pad.info.id));
        }
        self.sync_navigation();
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
    /// navigation keys, which the shell counts itself. Only a pad that navigates now gives the
    /// shell keys (06 §11.3, RUY-38); another pad's press or Guide is a `ForeignInput`.
    pub fn input_at(&mut self, key: PadKey, inputs: &[PadInput], now: Instant) {
        let app = self.route == Route::App;
        let Some(pad_id) = self.pads.get(&key).map(|p| p.info.id.clone()) else {
            return;
        };
        let signed_in = self.seats.active();
        let seat = self.seats.seat_of(&pad_id).map(|(n, _)| n);
        // The Confirm button of the pad the event came from (RUY-603).
        let mode = self.book.confirm_button(&self.profile, &pad_id);
        self.drain_book();
        let Some(pad) = self.pads.get_mut(&key) else {
            return;
        };
        let family = pad.info.family.clone();
        let hold = self
            .tests
            .get(&pad.info.id)
            .is_some_and(|t| t.hold_left_stick);
        let navigates = pad.navigates;
        let mut nav = Vec::new();
        let mut pressed = false;
        let mut guide = false;
        let mut other_button = false;
        for &input in inputs {
            pad.state.apply(input);
            pressed |= matches!(input, PadInput::Button(_, true));
            guide |= input == PadInput::Button(PadButton::Guide, true);
            other_button |= matches!(input, PadInput::Button(b, true) if b != PadButton::Guide);
            let events = if pad.stick_held_back(input, hold) {
                Vec::new()
            } else {
                mapper_events(&mut pad.mapper, input, &family, mode)
            };
            if !navigates {
                // Not this pad's turn: its keys reach neither the shell nor the KeyBoard's count.
            } else if app {
                // Navigation stops while an app has the focus; Guide still reaches the shell.
                nav.extend(events.into_iter().filter(|&(k, _)| k == NavKey::Guide));
            } else {
                nav.extend(events);
            }
            if let Some(v) = pad.virt.as_mut() {
                v.unmask(input);
            }
        }
        // What a pad that does not navigate asks for (06 §11.3): seat 1's pad (a navigator is set)
        // asks for nothing; Guide of seats 2-4 is "player-guide"; an unseated pad's Guide is
        // "guide" and its other buttons "press", at most once a second.
        let foreign = match (signed_in && !navigates, seat) {
            (false, _) | (true, Some(1)) => None,
            (true, Some(_)) => guide.then_some("player-guide"),
            (true, None) if guide => Some("guide"),
            (true, None) if other_button => {
                let due = pad.foreign_press.map_or(true, |t| {
                    now.saturating_duration_since(t) >= FOREIGN_PRESS_GAP
                });
                if due {
                    pad.foreign_press = Some(now);
                }
                due.then_some("press")
            }
            (true, None) => None,
        };
        let id = pad.info.id.clone();
        let keys = self.board.route(&nav);
        self.backend.nav_keys(&keys);
        if let Some(kind) = foreign {
            self.notices.push(Notice::ForeignInput {
                device_id: id.clone(),
                kind,
            });
        }
        // Only a pad that navigates can sign the next profile in or be the active input (§11.4).
        let pressed = pressed && navigates;
        if pressed {
            self.pad_since_change = Some(id.clone());
        }
        if pressed && self.active_input.as_deref() != Some(id.as_str()) {
            let before = self.active_mode();
            self.active_input = Some(id.clone());
            self.notices.push(Notice::ActiveInput {
                device_id: id,
                family,
            });
            // ConfirmButton is the active pad's mode: another pad with another mode changes it.
            if self.active_mode() != before {
                self.notices.push(Notice::ConfirmButtonChanged);
            }
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
        let Some(pad) = self.pads.get(&key) else {
            return;
        };
        // The number is the pad's seat: pad1 is player 1 (RUY-121). An unseated pad gets none, or,
        // with the seat gate off (until RUY-122), the lowest free number after the seats.
        let seat = self.seat_number(key);
        let n = match &seat {
            Some((n, _)) => *n,
            None if !self.seat_gate => unseated_number(&self.pads),
            None => return,
        };
        let player = seat.map(|(_, p)| p).unwrap_or_default();
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
                    player,
                    created: now,
                    ready: false,
                    fallback_tried: false,
                    sent: PadState::default(),
                    masked_buttons: Vec::new(),
                    masked_axes: Vec::new(),
                    ff: BTreeMap::new(),
                    effects: BTreeMap::new(),
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
        // A held seat keeps its hold, but not its virtual pad (RUY-627).
        let parked: Vec<(PadKey, Virtual)> = self
            .holds
            .values_mut()
            .filter_map(|p| p.virt.take().map(|v| (p.key, v)))
            .collect();
        for (key, v) in parked {
            self.drop_virtual(key, v);
        }
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
        self.waiting.clear();
        self.owner = None;
    }

    /// Pad1 exists and an app cannot open it yet: its ACL is not set and its udev fallback has not
    /// run. The other pads wait meanwhile, so a game that opens the first pad it is offered (SDL
    /// hot-plug, one pad) gets pad1 and not one whose ACL happened to be set first (RUY-541).
    fn pad1_settling(&self) -> bool {
        self.pads.values().any(|p| {
            p.virt
                .as_ref()
                .is_some_and(|v| v.n == 1 && !v.ready && !v.fallback_tried)
        })
    }

    /// Queues every seated pad that has no virtual pad and does not wait yet, by seat: player 1's
    /// pad (the profile's active controller) first, so it is pad1 (RUY-540, RUY-121).
    fn queue_missing(&mut self) {
        let missing: Vec<PadKey> = self
            .pads
            .iter()
            .filter(|(k, p)| p.virt.is_none() && !self.waiting.contains(k))
            .map(|(&k, _)| k)
            .collect();
        let mut keys: Vec<(u32, PadKey)> = missing
            .into_iter()
            .filter_map(|k| match self.seat_number(k) {
                Some((n, _)) => Some((n, k)),
                // Gate off: the unseated pads follow the seated ones, in connect (key) order.
                None if !self.seat_gate => Some((SEATS + 1, k)),
                None => None,
            })
            .collect();
        keys.sort_unstable();
        self.waiting.extend(keys.into_iter().map(|(_, k)| k));
    }

    /// Makes the waiting virtual pads in order while pad1 does not hold them back. With no pad1
    /// (seat 1 has no pad, or it vanished) the others are made at once, each with its seat's number.
    fn make_waiting(&mut self, now: Instant) {
        if self.route != Route::App || self.owner.is_none() {
            return;
        }
        while !self.waiting.is_empty() && !self.pad1_settling() {
            let key = self.waiting.remove(0);
            if self.pads.get(&key).is_some_and(|p| p.virt.is_none()) {
                self.create_virtual(key, now);
            }
        }
    }

    /// After a change of the seats: a pad that lost its seat, or whose seat is another number now,
    /// loses its virtual pad; a pad that has a seat now takes that seat's virtual pad if the seat
    /// had one (a move, a held seat moved: RUY-627), so the app keeps the device; the rest are
    /// destroyed. Under `app` every seated pad still without one gets it (in seat order, after
    /// pad1 as RUY-541 says). Under `overlay` they wait for the next `app`.
    fn sync_virtuals(&mut self, now: Instant) {
        self.sync_virtuals_with(now, Vec::new());
    }

    /// `sync_virtuals` with virtual pads that have lost their pad already (`spare`, each with the
    /// key of the pad it had, its rumble effects there dropped).
    fn sync_virtuals_with(&mut self, now: Instant, mut spare: Vec<(PadKey, Virtual)>) {
        let gate = self.seat_gate;
        // Holds that ended without their pad (a move, a leave, the deadline): spare too.
        let ended: Vec<String> = self
            .holds
            .keys()
            .filter(|d| !self.seats.is_held(d))
            .cloned()
            .collect();
        for device in ended {
            if let Some(Parked {
                key, virt: Some(v), ..
            }) = self.holds.remove(&device)
            {
                spare.push((key, v));
            }
        }
        let keys: Vec<PadKey> = self.pads.keys().copied().collect();
        let seats: BTreeMap<PadKey, Option<(u32, String)>> =
            keys.iter().map(|&k| (k, self.seat_number(k))).collect();
        for &key in &keys {
            let seat = &seats[&key];
            if seat.is_none() && gate {
                self.waiting.retain(|&k| k != key);
            }
            let Some(pad) = self.pads.get_mut(&key) else {
                continue;
            };
            // Stale: another seat or player; unseated, with the gate on or after it had a seat's
            // number (gate off it is made again after the seats). Nobody else is renumbered.
            let stale = pad.virt.as_ref().is_some_and(|v| match seat {
                Some((n, p)) => (v.n, v.player.as_str()) != (*n, p.as_str()),
                None => gate || v.n <= SEATS,
            });
            if !stale {
                continue;
            }
            if let Some(mut v) = pad.virt.take() {
                // The pad stays: its effects are erased on it, and go with the virtual pad.
                for physical in std::mem::take(&mut v.ff).into_values() {
                    self.backend.ff_erase(key, physical);
                }
                v.playing.clear();
                if v.ready {
                    self.changed(key);
                }
                spare.push((key, v));
            }
        }
        // A pad that has a seat and no virtual pad takes the seat's own (the same number and player).
        for &key in &keys {
            let Some((n, player)) = &seats[&key] else {
                continue;
            };
            if self.pads.get(&key).map_or(true, |p| p.virt.is_some()) {
                continue;
            }
            if let Some(i) = spare
                .iter()
                .position(|(_, v)| v.n == *n && v.player == *player)
            {
                let (_, v) = spare.remove(i);
                self.waiting.retain(|&k| k != key);
                self.bind(key, v);
            }
        }
        for (key, v) in spare {
            self.drop_virtual(key, v);
        }
        if self.route == Route::App && self.owner.is_some() {
            self.queue_missing();
            self.make_waiting(now);
        }
    }

    /// Binds the virtual pad `v` to the pad `key` (RUY-627: the pad back within its hold, a like
    /// pad, a move, a twin): the same device and node, so the app sees no pad go or come. What the
    /// pad holds now waits for its release (`mask_held`), the profile is compiled for this pad,
    /// and the app's rumble effects are uploaded to it again.
    fn bind(&mut self, key: PadKey, mut v: Virtual) {
        let Some(pad) = self.pads.get(&key) else {
            self.drop_virtual(key, v);
            return;
        };
        let pad_id = pad.info.id.clone();
        let family = pad.info.family.clone();
        let held = pad.state.clone();
        if let Some(owner) = self.owner.clone() {
            v.engine = self.book.engine_for(&owner.profile, &family, &pad_id);
            self.drain_book();
        }
        v.mask_held(&held);
        v.ff.clear();
        v.playing.clear();
        let effects: Vec<(i16, Rumble)> = v.effects.iter().map(|(&e, &r)| (e, r)).collect();
        for (effect, rumble) in effects {
            match self.backend.ff_upload(key, -1, &rumble) {
                Ok(physical) => {
                    v.ff.insert(effect, physical);
                }
                Err(errno) => self.journal(format!(
                    "rumble effect {effect} of {} not uploaded to {pad_id}: errno {errno}",
                    v.phys
                )),
            }
        }
        // Whatever the pad it had left pressed goes up (the new pad's own presses are masked).
        let target = v.target(&held);
        let events = diff(&v.sent, &target);
        v.sent = target;
        if !events.is_empty() {
            self.backend.write_virtual(v.id, &events);
        }
        self.journal(format!("virtual pad {} bound to {pad_id}", v.phys));
        let ready = v.ready;
        let sysname = v.sysname.clone();
        if let Some(pad) = self.pads.get_mut(&key) {
            pad.virt = Some(v);
        }
        if ready {
            self.changed(key);
            // A udev event on the node while it was parked was not answered: its one-entry ACL is
            // asserted again (a pad not ready yet still waits for its udev event or fallback).
            if let Some(node) = self.backend.node_of(&sysname) {
                self.assert_acl(key, &node, "rebind");
            }
        }
    }

    /// One neutral frame on a virtual pad whose pad is gone: sticks centred, nothing pressed.
    fn neutral(&mut self, v: &mut Virtual) {
        let events = diff(&v.sent, &PadState::default());
        v.sent = PadState::default();
        if !events.is_empty() {
            self.backend.write_virtual(v.id, &events);
        }
    }

    /// A pad that connects takes a held seat back (RUY-627): its own (the same stable id) or, for a
    /// serial-less USB pad, the held seat of the one like pad (a serial-less USB pad with the same
    /// `vid:pid`, 06 §4.1; with two or more such seats it takes none). The virtual pad the seat
    /// kept, if any, is bound to it.
    fn take_held_seat(&mut self, key: PadKey, id: &str, port_bound: bool) {
        if self.holds.is_empty() {
            return;
        }
        let before = self.seats.clone();
        let old = if self.seats.resume(id).is_some() {
            id.to_owned()
        } else if let Some(like) = like_key(id).filter(|_| port_bound) {
            let candidates: Vec<String> = self
                .holds
                .iter()
                .filter(|(d, p)| p.port_bound && like_key(d) == Some(like))
                .map(|(d, _)| d.clone())
                .collect();
            match candidates.as_slice() {
                [old] if self.seats.take_over(old, id).is_some() => old.clone(),
                [] | [_] => return,
                many => {
                    self.journal(format!(
                        "{id} is like the pads of {} held seats: it takes none",
                        many.len()
                    ));
                    return;
                }
            }
        } else {
            return;
        };
        if let Some((slot, profile)) = self.seats.seat_of(id).map(|(n, p)| (n, p.to_owned())) {
            let like = if old == id {
                String::new()
            } else {
                format!(", a like pad of {old}")
            };
            self.journal(format!(
                "player {slot} (ruya-{profile}) is back on {id}{like}"
            ));
        }
        self.seats_changed(&before);
        if let Some(Parked { virt: Some(v), .. }) = self.holds.remove(&old) {
            self.bind(key, v);
        }
    }

    /// The holds that ran out at `now` (RUY-627): seats 2-4 are freed, seat 1 keeps its profile
    /// without a pad, and their virtual pads are destroyed.
    fn expire_holds(&mut self, now: Instant) {
        if self.holds.is_empty() {
            return;
        }
        let before = self.seats.clone();
        let due = self.seats.expire(now);
        if due.is_empty() {
            return;
        }
        for (slot, device) in due {
            self.journal(format!(
                "player {slot}'s hold ran out: {device} did not come back"
            ));
        }
        self.seats_changed(&before);
        self.sync_virtuals(now);
    }

    /// A profile change: every hold ends with the seats, and the held virtual pads are destroyed.
    fn drop_holds(&mut self) {
        for (_, parked) in std::mem::take(&mut self.holds) {
            if let Some(v) = parked.virt {
                self.drop_virtual(parked.key, v);
            }
        }
    }

    /// The journal lines and the device records of a change of the seats from `before`.
    fn seats_changed(&mut self, before: &Seats) {
        let old = before.players();
        let new = self.seats.players();
        for slot in 1..=SEATS {
            let was = old.iter().find(|p| p.slot == slot);
            let now = new.iter().find(|p| p.slot == slot);
            match (was, now) {
                // A hold that starts or ends is not a new player (its own lines say so).
                (_, Some(p))
                    if was.map(|w| (&w.profile, &w.device_id))
                        != Some((&p.profile, &p.device_id)) =>
                {
                    let on = if p.device_id.is_empty() {
                        "no pad".to_owned()
                    } else {
                        p.device_id.clone()
                    };
                    self.journal(format!("player {slot} is ruya-{} on {on}", p.profile));
                }
                (Some(_), None) => self.journal(format!("player {slot} left")),
                _ => {}
            }
        }
        let moved: Vec<PadKey> = self
            .pads
            .iter()
            .filter(|(_, p)| before.seat_of(&p.info.id) != self.seats.seat_of(&p.info.id))
            .map(|(&k, _)| k)
            .collect();
        self.dirty.extend(moved);
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

    /// `udev_event_at` with the real clock, for the tests that do not care about time.
    #[cfg(test)]
    pub fn udev_event(&mut self, ev: &UdevEvent) {
        self.udev_event_at(ev, Instant::now());
    }

    /// A processed udev event (the monitor): an `add` or `change` on one of our nodes sets the
    /// ACL again, because logind's uaccess builtin rewrites it on every event. Pad1 ready: the
    /// pads that waited for it are made (`now` is their creation time).
    pub fn udev_event_at(&mut self, ev: &UdevEvent, now: Instant) {
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
            self.make_waiting(now);
        }
    }

    /// Timers: a virtual pad with no udev event after `UDEV_FALLBACK` gets its ACL anyway (then
    /// the pads that waited for pad1 are made, also when that ACL could not be set); a button test
    /// sends the axis values it held back and ends after `TEST_IDLE` without input.
    pub fn tick(&mut self, now: Instant) {
        self.tick_tests(now);
        self.expire_holds(now);
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
        self.make_waiting(now);
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
        if self.navigator.as_ref().is_some_and(|(_, c)| c == name) {
            self.clear_navigator(&format!("its caller {name} left the bus"));
            self.sync_navigation();
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
            // controller, seat 1; a keyboard or touch sign-in has none (ADR-017 am. 6b). Every
            // other seat is emptied: a joined player stays for the session (RUY-121).
            let pad = self.pad_since_change.take().unwrap_or_default();
            let before = self.seats.clone();
            self.seats.sign_in(profile, &pad);
            self.drop_holds();
            self.seats_changed(&before);
            self.clear_navigator("the profile changed");
        }
        match r {
            Route::App if same_owner => {
                if old != Route::App {
                    // Back from the overlay (the Hub, frozen or not: the same devices, RUY-541):
                    // what is held now waits for its release.
                    for pad in self.pads.values_mut() {
                        let state = pad.state.clone();
                        if let Some(v) = pad.virt.as_mut() {
                            v.mask_held(&state);
                        }
                    }
                }
                // A pad connected under the overlay gets its virtual pad now.
                self.queue_missing();
            }
            Route::App => {
                self.destroy_all();
                self.owner = uid.map(|uid| Owner {
                    instance: instance.to_owned(),
                    profile: profile.to_owned(),
                    uid,
                });
                // The profile's active controller (the pad that signed it in) is created first, so
                // it is `pad1` and SDL index 0 (RUY-540); the others follow in key order once
                // pad1 can be opened (RUY-541), below, when the route is `app`.
                self.queue_missing();
            }
            Route::Overlay if same_owner => self.neutral_all(),
            Route::Overlay | Route::Shell | Route::Locked => self.destroy_all(),
        }
        // A test goes on in `shell` and `overlay` (RUY-611: a game frozen or closing behind Home
        // keeps its pads, so the shell's route is `overlay` while the Controllers pages test).
        if matches!(r, Route::App | Route::Locked) {
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
        self.make_waiting(now);
        self.sync_navigation();
        if profile_changed {
            // The device records that changed (slot, profile) were marked by `seats_changed`.
            self.notices.push(Notice::ConfirmButtonChanged);
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

    // ---- players (ADR-017, 06 §11.3; RUY-121) ----------------------------------------------

    /// `ListPlayers`: the seated players, by slot (none while nobody is signed in).
    pub fn players(&self) -> Vec<Player> {
        self.seats.players()
    }

    /// `JoinPlayer(device_id, profile)`: the status and the seat taken (0 unless ok). The rules
    /// are `Seats::join`; a move destroys the old pad's virtual pad and, under `app`, makes the
    /// new pad's with the same number.
    pub fn join_player(&mut self, device_id: &str, profile: &str, now: Instant) -> (Status, u32) {
        if !crate::profile::valid_device(device_id) {
            return (Status::Invalid, 0);
        }
        if !self.seats.active() {
            return (Status::NotAllowed, 0);
        }
        if !self.console_ok(profile) {
            return (Status::UnknownProfile, 0);
        }
        if !self.pads.values().any(|p| p.info.id == device_id) {
            return (Status::UnknownDevice, 0);
        }
        let before = self.seats.clone();
        match self.seats.join(device_id, profile) {
            Joined::Full => (Status::Full, 0),
            Joined::Seated { slot, changed } => {
                if changed {
                    self.seats_changed(&before);
                    self.sync_virtuals(now);
                    self.sync_navigation();
                }
                (Status::Ok, slot)
            }
        }
    }

    /// `LeavePlayer(slot)`: seat `slot` (2..=4) is emptied, its pad unseated and its virtual pad
    /// destroyed. "ok" also for an empty seat.
    pub fn leave_player(&mut self, slot: u32, now: Instant) -> Status {
        if slot == 0 || slot > SEATS {
            return Status::Invalid;
        }
        if !self.seats.active() || slot == 1 {
            return Status::NotAllowed;
        }
        let before = self.seats.clone();
        if self.seats.leave(slot).is_some() {
            self.seats_changed(&before);
            self.sync_virtuals(now);
            self.sync_navigation();
        }
        Status::Ok
    }

    // ---- who drives the UI (ADR-017 points 2 and 9, 06 §11.3; RUY-38) -----------------------

    /// Whether the pad with the stable id `id` navigates the shell now: every pad while nobody is
    /// signed in; else only the navigator if one is set, or else only seat 1's pad (none while its
    /// seat is held or has no pad). The keyboard always navigates; the service does not see it.
    fn navigates(&self, id: &str) -> bool {
        if !self.seats.active() {
            return true;
        }
        match &self.navigator {
            Some((navigator, _)) => navigator == id,
            None => self.seats.player1_device() == Some(id) && !self.seats.is_held(id),
        }
    }

    /// Works out again which pads navigate. A pad that stops releases the keys it held through the
    /// `KeyBoard` (no key sticks); one that starts forgets what its mapper saw meanwhile, since
    /// none of it was counted, so its next release lets nothing up that another pad holds.
    fn sync_navigation(&mut self) {
        let keys: Vec<PadKey> = self.pads.keys().copied().collect();
        for key in keys {
            let Some(id) = self.pads.get(&key).map(|p| p.info.id.clone()) else {
                continue;
            };
            let navigates = self.navigates(&id);
            let Some(pad) = self.pads.get_mut(&key) else {
                continue;
            };
            if pad.navigates == navigates {
                continue;
            }
            pad.navigates = navigates;
            if navigates {
                pad.mapper.release_all();
            } else {
                let released = self.board.pad_gone(&mut pad.mapper);
                self.backend.nav_keys(&released);
            }
        }
    }

    fn clear_navigator(&mut self, why: &str) {
        if self.navigator.take().is_some() {
            self.journal(format!("navigator cleared ({why})"));
        }
    }

    /// `SetNavigator(device_id)`: only that connected pad navigates until it is cleared ("", its
    /// removal, a profile change, its caller leaving the bus); it is the active input at once.
    pub fn set_navigator(&mut self, device_id: &str, caller: &str) -> Status {
        if device_id.is_empty() {
            self.clear_navigator("SetNavigator \"\"");
            self.sync_navigation();
            return Status::Ok;
        }
        if !self.seats.active() {
            return Status::NotAllowed;
        }
        let Some(family) = self
            .pads
            .values()
            .find(|p| p.info.id == device_id)
            .map(|p| p.info.family.clone())
        else {
            return Status::UnknownDevice;
        };
        self.navigator = Some((device_id.to_owned(), caller.to_owned()));
        self.journal(format!("navigator {device_id}"));
        self.sync_navigation();
        // The hint bar shows the navigator's glyphs and its own Confirm choice (RUY-603).
        let before = self.active_mode();
        self.active_input = Some(device_id.to_owned());
        self.notices.push(Notice::ActiveInput {
            device_id: device_id.to_owned(),
            family,
        });
        if self.active_mode() != before {
            self.notices.push(Notice::ConfirmButtonChanged);
        }
        Status::Ok
    }

    // ---- the confirm button (06 §11.2) ------------------------------------------------------

    /// The mode of the active controller (the pad of the last press) for the signed-in profile;
    /// `Family` with no profile or no active pad (RUY-603).
    fn active_mode(&mut self) -> Confirm {
        let Some(device) = self.active_input.clone() else {
            return Confirm::Family;
        };
        let profile = self.profile.clone();
        let mode = self.book.confirm_button(&profile, &device);
        self.drain_book();
        mode
    }

    /// The `ConfirmButton` property: the active controller's mode for the signed-in profile
    /// ("family" with no profile, no active pad or no choice for it).
    pub fn confirm_button(&mut self) -> &'static str {
        self.active_mode().as_str()
    }

    /// `GetConfirmButtons`: the console profile's choices, device id -> "south" | "east".
    pub fn confirm_buttons(&mut self, profile: &str) -> (Status, BTreeMap<String, String>) {
        if !self.console_ok(profile) {
            return (Status::UnknownProfile, BTreeMap::new());
        }
        let answer = self.book.confirm_buttons(profile);
        self.drain_book();
        match answer {
            Ok(map) => (
                Status::Ok,
                map.into_iter()
                    .map(|(d, m)| (d, m.as_str().to_owned()))
                    .collect(),
            ),
            Err(status) => (status, BTreeMap::new()),
        }
    }

    /// `SetConfirmButton`: `mode` is "family" | "south" | "east" for one controller (`device`, a
    /// stable id; it need not be connected) of a profile account (RUY-603). It applies from that
    /// pad's next press on; a key held now is released as it was pressed.
    pub fn set_confirm_button(&mut self, profile: &str, device: &str, mode: &str) -> Status {
        if !self.console_ok(profile) {
            return Status::UnknownProfile;
        }
        let Some(mode) = Confirm::parse(mode) else {
            return Status::Invalid;
        };
        if !crate::profile::valid_device(device) {
            return Status::Invalid;
        }
        let before = self.active_mode();
        let status = self.book.set_confirm_button(profile, device, mode);
        self.drain_book();
        if status == Status::Ok {
            self.journal(format!(
                "confirm button of ruya-{profile} on {device}: {}",
                mode.as_str()
            ));
            if profile == self.profile && self.active_mode() != before {
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

    /// `Input1.StartTest`: only while the route is `shell` or `overlay`, one test per device. With
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
        if !matches!(self.route, Route::Shell | Route::Overlay) {
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

    /// A held seat's virtual pad (RUY-627): its pad is gone.
    fn parked_pad(&mut self, id: VirtualId) -> Option<&mut Virtual> {
        self.holds
            .values_mut()
            .find_map(|p| p.virt.as_mut().filter(|v| v.id == id))
    }

    /// The app uploaded (or updated) rumble effect `effect` on virtual pad `id`. On a held seat's
    /// virtual pad it is kept for the pad that comes back.
    pub fn ff_upload(&mut self, id: VirtualId, effect: i16, rumble: &Rumble) -> Result<(), i32> {
        if let Some(v) = self.parked_pad(id) {
            v.effects.insert(effect, *rumble);
            return Ok(());
        }
        let Some((key, v)) = self.virtual_pad(id) else {
            return Err(ENODEV);
        };
        let physical = v.ff.get(&effect).copied().unwrap_or(-1);
        let new = self.backend.ff_upload(key, physical, rumble)?;
        if let Some((_, v)) = self.virtual_pad(id) {
            v.ff.insert(effect, new);
            v.effects.insert(effect, *rumble);
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
        if let Some(v) = self.parked_pad(id) {
            v.effects.remove(&effect);
            return;
        }
        let Some((key, v)) = self.virtual_pad(id) else {
            return;
        };
        v.effects.remove(&effect);
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
        gated(true)
    }

    /// A router with the seat gate on (the rule of RUY-121) or off (`SEAT_GATE` until RUY-122).
    fn gated(seat_gate: bool) -> Router<Fake> {
        Router::new(
            Fake::default(),
            Box::new(FixedAccounts(vec![
                ("p1".into(), P1_UID),
                ("p2".into(), P2_UID),
                ("p3".into(), 1003),
                ("p4".into(), 1004),
                ("p5".into(), 1005),
            ])),
            seat_gate,
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
            port_bound: false,
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

    /// Pad1's udev fallback runs: the pads that waited for it are made now (RUY-541).
    fn settle(r: &mut Router<Fake>) {
        r.tick(Instant::now() + UDEV_FALLBACK);
    }

    /// The pad presses and lets go (Accept on the picker): the next profile change seats the new
    /// profile on it (seat 1, RUY-121).
    fn tap(r: &mut Router<Fake>, key: PadKey) {
        r.input(key, &[press(PadButton::South), release(PadButton::South)]);
    }

    /// The pad signs `profile` in (its press, then the route `shell` with the profile), so it is
    /// seat 1 and gets pad1 in an app (RUY-121). What that recorded is dropped.
    fn sign_in(r: &mut Router<Fake>, key: PadKey, profile: &str) {
        tap(r, key);
        assert_eq!(
            r.set_route("shell", "", "", profile, SHELL, t0()),
            Status::Ok
        );
        assert_eq!(
            r.seats.player1_device(),
            Some(r.pads[&key].info.id.as_str())
        );
        r.backend_mut().take();
        r.take_notices();
    }

    /// `JoinPlayer` for the pad: "ok", the seat it took.
    fn join(r: &mut Router<Fake>, key: PadKey, profile: &str) -> u32 {
        let id = r.pads[&key].info.id.clone();
        let (status, slot) = r.join_player(&id, profile, t0());
        assert_eq!(status, Status::Ok, "join {id} as {profile}");
        slot
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
        // Seated (player 1), so it has a virtual pad and its Guide reaches the shell (RUY-38).
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        r.input(a, &[press(PadButton::South), press(PadButton::DpadDown)]);
        r.input(a, &[PadInput::Axis(PadAxis::LeftX, STICK_MIN)]);
        r.input(a, &[press(PadButton::Guide)]);
        let calls = r.backend_mut().take();
        assert_eq!(nav(&calls), vec![(NavKey::Guide, true)]);
        // The game gets the pad (the control), but Guide is never forwarded to the virtual pad.
        let sent = writes(&calls);
        assert!(
            sent.iter()
                .any(|(_, e)| e.iter().any(|e| e.1 == code::BTN_SOUTH)),
            "{sent:?}"
        );
        for (_, events) in sent {
            assert!(!events.iter().any(|e| e.1 == code::BTN_MODE), "{events:?}");
        }
        r.input(a, &[release(PadButton::Guide)]);
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Guide, false)]);
    }

    fn foreign(notices: &[Notice]) -> Vec<(String, &'static str)> {
        notices
            .iter()
            .filter_map(|n| match n {
                Notice::ForeignInput { device_id, kind } => Some((device_id.clone(), *kind)),
                _ => None,
            })
            .collect()
    }

    /// RUY-11, changed by RUY-38 (06 §11.3): before a sign-in any pad's Guide is the shell's;
    /// after it only player 1's, a seated player's Guide is `player-guide` and an unseated pad's
    /// `guide`. No virtual pad ever sees Guide. The gate is off (production), so every pad has
    /// a virtual pad in the app and each one's "no BTN_MODE" is checked against its BTN_SOUTH.
    #[test]
    fn guide_reaches_the_shell_from_any_pad_before_a_sign_in_and_from_player_1_after_it() {
        let mut r = gated(false);
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        let c = r.add_pad(pad("c"), t0());
        for pad_key in [a, b, c] {
            r.input(pad_key, &[press(PadButton::Guide)]);
            r.input(pad_key, &[release(PadButton::Guide)]);
            let calls = r.backend_mut().take();
            assert_eq!(
                nav(&calls),
                vec![(NavKey::Guide, true), (NavKey::Guide, false)],
                "before a sign-in"
            );
            assert!(foreign(&r.take_notices()).is_empty());
        }
        sign_in(&mut r, a, "p1");
        assert_eq!(join(&mut r, b, "p2"), 2);
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        assert_eq!(phys_of(&r, c).as_deref(), Some("ruya-input/pad5"));
        r.backend_mut().take();
        r.take_notices();
        for (pad_key, id, shell, kind) in [
            (a, "a", true, None),
            (b, "b", false, Some("player-guide")),
            (c, "c", false, Some("guide")),
        ] {
            r.input(pad_key, &[press(PadButton::South), press(PadButton::Guide)]);
            let calls = r.backend_mut().take();
            let want: Vec<KeyEvent> = if shell {
                vec![(NavKey::Guide, true)]
            } else {
                Vec::new()
            };
            assert_eq!(nav(&calls), want, "{id}");
            let sent = writes(&calls);
            assert!(
                sent.iter()
                    .any(|(_, e)| e.iter().any(|e| e.1 == code::BTN_SOUTH)),
                "{id}: the game gets the pad: {sent:?}"
            );
            for (_, events) in sent {
                assert!(!events.iter().any(|e| e.1 == code::BTN_MODE), "{events:?}");
            }
            let asked: Vec<(String, &str)> = kind.map(|k| (id.to_owned(), k)).into_iter().collect();
            assert_eq!(foreign(&r.take_notices()), asked, "{id}");
            r.input(
                pad_key,
                &[release(PadButton::Guide), release(PadButton::South)],
            );
            let calls = r.backend_mut().take();
            let want: Vec<KeyEvent> = if shell {
                vec![(NavKey::Guide, false)]
            } else {
                Vec::new()
            };
            assert_eq!(nav(&calls), want, "{id}");
            for (_, events) in writes(&calls) {
                assert!(!events.iter().any(|e| e.1 == code::BTN_MODE), "{events:?}");
            }
            assert!(
                foreign(&r.take_notices()).is_empty(),
                "a release asks nothing"
            );
        }
    }

    // ---- who drives the UI (06 §11.3, RUY-38) ----------------------------------------------

    /// Pads a and b; a signs p1 in, so it is player 1 and b is unseated.
    fn a_signed_in() -> (Router<Fake>, PadKey, PadKey) {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        (r, a, b)
    }

    fn active_inputs(notices: &[Notice]) -> Vec<String> {
        notices
            .iter()
            .filter_map(|n| match n {
                Notice::ActiveInput { device_id, .. } => Some(device_id.clone()),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn an_unseated_pads_press_navigates_nothing_and_asks_at_most_once_a_second() {
        let (mut r, _a, b) = a_signed_in();
        let t = t0();
        let down = [press(PadButton::DpadDown)];
        let up = [release(PadButton::DpadDown)];
        r.input_at(b, &down, t);
        assert!(nav(&r.backend_mut().take()).is_empty(), "no navigation key");
        let notices = r.take_notices();
        assert_eq!(foreign(&notices), vec![("b".to_owned(), "press")]);
        assert!(
            active_inputs(&notices).is_empty(),
            "b is not the active input"
        );
        r.input_at(b, &up, t + Duration::from_millis(100));
        assert!(
            foreign(&r.take_notices()).is_empty(),
            "a release asks nothing"
        );
        r.input_at(b, &down, t + Duration::from_millis(900));
        r.input_at(b, &up, t + Duration::from_millis(950));
        assert!(foreign(&r.take_notices()).is_empty(), "within a second");
        r.input_at(b, &[press(PadButton::South)], t + FOREIGN_PRESS_GAP);
        assert_eq!(foreign(&r.take_notices()), vec![("b".to_owned(), "press")]);
        assert!(nav(&r.backend_mut().take()).is_empty());
    }

    #[test]
    fn an_unseated_pads_stick_gives_nothing() {
        let (mut r, _a, b) = a_signed_in();
        r.input_at(b, &[PadInput::Axis(PadAxis::LeftX, STICK_MAX)], t0());
        r.input_at(b, &[PadInput::Axis(PadAxis::LeftY, STICK_MIN)], t0());
        r.input_at(b, &[PadInput::Axis(PadAxis::LeftX, 0)], t0());
        assert!(nav(&r.backend_mut().take()).is_empty());
        assert!(foreign(&r.take_notices()).is_empty(), "never for an axis");
    }

    #[test]
    fn an_unseated_pads_guide_asks_and_is_no_homepage() {
        let (mut r, _a, b) = a_signed_in();
        r.input_at(b, &[press(PadButton::Guide)], t0());
        r.input_at(b, &[release(PadButton::Guide)], t0());
        assert!(nav(&r.backend_mut().take()).is_empty(), "no KEY_HOMEPAGE");
        assert_eq!(foreign(&r.take_notices()), vec![("b".to_owned(), "guide")]);
    }

    #[test]
    fn player_1s_pad_navigates_and_asks_nothing() {
        let (mut r, a, _b) = a_signed_in();
        r.input_at(a, &[press(PadButton::DpadDown)], t0());
        r.input_at(a, &[press(PadButton::Guide)], t0());
        assert_eq!(
            nav(&r.backend_mut().take()),
            vec![(NavKey::Down, true), (NavKey::Guide, true)]
        );
        assert!(foreign(&r.take_notices()).is_empty());
    }

    #[test]
    fn a_seated_players_guide_is_player_guide_and_its_buttons_ask_nothing() {
        let (mut r, _a, b) = a_signed_in();
        assert_eq!(join(&mut r, b, "p2"), 2);
        r.take_notices();
        r.input_at(b, &[press(PadButton::DpadDown)], t0());
        assert!(
            foreign(&r.take_notices()).is_empty(),
            "a seated pad's press"
        );
        r.input_at(b, &[press(PadButton::Guide)], t0());
        assert!(nav(&r.backend_mut().take()).is_empty());
        assert_eq!(
            foreign(&r.take_notices()),
            vec![("b".to_owned(), "player-guide")]
        );
    }

    #[test]
    fn before_any_sign_in_every_pad_navigates_and_asks_nothing() {
        let mut r = router();
        let _a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        for route in ["shell", "locked"] {
            r.set_route(route, "", "", "", SHELL, t0());
            r.backend_mut().take();
            r.input_at(b, &[press(PadButton::DpadDown)], t0());
            r.input_at(b, &[release(PadButton::DpadDown)], t0());
            assert_eq!(
                nav(&r.backend_mut().take()),
                vec![(NavKey::Down, true), (NavKey::Down, false)],
                "{route}"
            );
            assert!(foreign(&r.take_notices()).is_empty(), "{route}");
        }
    }

    #[test]
    fn the_navigator_navigates_and_player_1_gives_nothing_not_even_guide() {
        let (mut r, a, b) = a_signed_in();
        assert_eq!(r.set_navigator("b", SHELL), Status::Ok);
        assert_eq!(
            active_inputs(&r.take_notices()),
            vec!["b".to_owned()],
            "announced at the call"
        );
        r.backend_mut().take();
        r.input_at(
            b,
            &[press(PadButton::DpadDown), press(PadButton::Guide)],
            t0(),
        );
        assert_eq!(
            nav(&r.backend_mut().take()),
            vec![(NavKey::Down, true), (NavKey::Guide, true)]
        );
        assert!(
            foreign(&r.take_notices()).is_empty(),
            "the navigator asks nothing"
        );
        r.input_at(a, &[press(PadButton::South), press(PadButton::Guide)], t0());
        assert!(
            nav(&r.backend_mut().take()).is_empty(),
            "player 1 is silent"
        );
        let notices = r.take_notices();
        assert!(foreign(&notices).is_empty(), "seat 1 asks nothing");
        assert!(
            active_inputs(&notices).is_empty(),
            "nor is it the active input"
        );
        // Cleared: a navigates again, b asks again.
        assert_eq!(r.set_navigator("", SHELL), Status::Ok);
        r.backend_mut().take();
        r.take_notices();
        r.input_at(a, &[release(PadButton::South)], t0());
        r.input_at(a, &[press(PadButton::DpadUp)], t0());
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Up, true)]);
        r.input_at(b, &[press(PadButton::South)], t0() + FOREIGN_PRESS_GAP);
        assert!(nav(&r.backend_mut().take()).is_empty());
        assert_eq!(foreign(&r.take_notices()), vec![("b".to_owned(), "press")]);
    }

    #[test]
    fn the_navigators_confirm_choice_is_the_property_at_the_call() {
        let (mut r, _a, _b) = a_signed_in();
        assert_eq!(r.set_confirm_button("p1", "b", "east"), Status::Ok);
        r.take_notices();
        assert_eq!(r.set_navigator("b", SHELL), Status::Ok);
        assert_eq!(r.confirm_button(), "east");
        assert!(property_changed(&mut r));
    }

    #[test]
    fn a_key_player_1_held_is_released_when_the_navigator_is_set_and_back() {
        let (mut r, a, b) = a_signed_in();
        r.input_at(a, &[press(PadButton::DpadDown)], t0());
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Down, true)]);
        assert_eq!(r.set_navigator("b", SHELL), Status::Ok);
        assert_eq!(
            nav(&r.backend_mut().take()),
            vec![(NavKey::Down, false)],
            "released at the call"
        );
        // The navigator holds a key; the clear lets it go, and a's late release sends nothing.
        r.input_at(b, &[press(PadButton::DpadLeft)], t0());
        r.backend_mut().take();
        assert_eq!(r.set_navigator("", SHELL), Status::Ok);
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Left, false)]);
        r.input_at(a, &[release(PadButton::DpadDown)], t0());
        assert!(
            nav(&r.backend_mut().take()).is_empty(),
            "nothing released twice"
        );
    }

    #[test]
    fn a_held_key_is_released_when_player_1_moves_to_another_pad() {
        let (mut r, a, b) = a_signed_in();
        r.input_at(a, &[press(PadButton::DpadDown)], t0());
        r.backend_mut().take();
        join(&mut r, b, "p1");
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Down, false)]);
        r.input_at(b, &[press(PadButton::DpadUp)], t0());
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Up, true)]);
    }

    #[test]
    fn the_navigator_goes_with_its_pad_its_caller_and_a_profile_change() {
        const PROMPT: &str = ":1.9";
        for how in ["gone", "caller", "profile"] {
            let (mut r, a, b) = a_signed_in();
            assert_eq!(r.set_navigator("b", PROMPT), Status::Ok);
            let mut player1 = a;
            match how {
                "gone" => {
                    r.remove_pad_at(b, t0());
                }
                "caller" => r.caller_left(PROMPT, t0()),
                _ => {
                    // A Hub switch pressed on the navigator signs p2 in with it as player 1.
                    r.input_at(b, &[press(PadButton::South)], t0());
                    r.set_route("shell", "", "", "p2", SHELL, t0());
                    assert_eq!(r.players()[0].device_id, "b");
                    // a is unseated now and silent.
                    r.backend_mut().take();
                    r.input_at(a, &[press(PadButton::DpadUp)], t0());
                    assert!(nav(&r.backend_mut().take()).is_empty(), "{how}");
                    player1 = b;
                }
            }
            assert!(
                journal(&mut r)
                    .iter()
                    .any(|l| l.starts_with("navigator cleared")),
                "{how}"
            );
            r.backend_mut().take();
            r.input_at(player1, &[press(PadButton::DpadDown)], t0());
            assert_eq!(
                nav(&r.backend_mut().take()),
                vec![(NavKey::Down, true)],
                "{how}: player 1 navigates again"
            );
        }
    }

    #[test]
    fn set_navigator_answers_ok_not_allowed_or_unknown_device() {
        let mut r = router();
        let _a = r.add_pad(pad("a"), t0());
        assert_eq!(
            r.set_navigator("a", SHELL),
            Status::NotAllowed,
            "nobody signed in"
        );
        assert_eq!(
            r.set_navigator("", SHELL),
            Status::Ok,
            "clearing is always ok"
        );
        signed_in(&mut r, "p1");
        assert_eq!(r.set_navigator("zz", SHELL), Status::UnknownDevice);
        assert_eq!(r.set_navigator("Bad Id", SHELL), Status::UnknownDevice);
        assert_eq!(r.set_navigator("a", SHELL), Status::Ok);
        assert!(journal(&mut r).contains(&"navigator a".to_owned()));
    }

    #[test]
    fn while_seat_1_is_held_no_pad_navigates() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        let c = r.add_pad(pad("c"), t0());
        sign_in(&mut r, a, "p1");
        assert_eq!(join(&mut r, c, "p2"), 2);
        r.remove_pad_at(a, t0());
        assert!(r.players()[0].held_until.is_some(), "seat 1 is held");
        r.backend_mut().take();
        r.take_notices();
        for key in [b, c] {
            r.input_at(
                key,
                &[press(PadButton::DpadDown), press(PadButton::Guide)],
                t0(),
            );
        }
        assert!(nav(&r.backend_mut().take()).is_empty(), "only the keyboard");
        assert_eq!(
            foreign(&r.take_notices()),
            vec![("b".to_owned(), "guide"), ("c".to_owned(), "player-guide")]
        );
        // a back within the hold drives the shell again.
        let a = r.add_pad(pad("a"), t0());
        r.input_at(a, &[press(PadButton::DpadUp)], t0());
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Up, true)]);
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
        // The others join (RUY-121): their seats are their numbers.
        assert_eq!(join(&mut r, c, "p3"), 2);
        assert_eq!(join(&mut r, a, "p2"), 3);
        r.backend_mut().take();
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        assert_eq!(
            creations(&r.backend_mut().take()),
            vec![
                (b, "ruya-input/pad1".to_owned()),
                (c, "ruya-input/pad2".to_owned()),
                (a, "ruya-input/pad3".to_owned()),
            ]
        );
        // A pad plugged in during the app is not seated: no virtual pad until it joins, then the
        // number of its seat at once.
        let d = r.add_pad(pad("d"), t0());
        assert!(creations(&r.backend_mut().take()).is_empty());
        assert_eq!(join(&mut r, d, "p4"), 4);
        assert_eq!(
            creations(&r.backend_mut().take()),
            vec![(d, "ruya-input/pad4".to_owned())]
        );
        // No pad known at sign-in (the keyboard): seat 1 has no pad, so there is no pad1, and a
        // pad that joins gets its seat's number at once.
        let mut r = router();
        let _a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        r.backend_mut().take();
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        assert!(creations(&r.backend_mut().take()).is_empty());
        assert_eq!(join(&mut r, b, "p2"), 2);
        assert_eq!(
            creations(&r.backend_mut().take()),
            vec![(b, "ruya-input/pad2".to_owned())]
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
        // Seat 1 has no pad (RUY-121): neither b (p1's) nor a gets a virtual pad.
        assert_eq!(r.players()[0].device_id, "");
        assert!(created(&r.backend_mut().take()).is_empty());
        let _ = a;
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
        // In the Hub, pad c presses Switch profile: p1 goes straight to p2. Since RUY-38 only a
        // pad that navigates can: c drives the prompt (SetNavigator).
        assert_eq!(r.set_navigator("c", SHELL), Status::Ok);
        r.input(c, &[press(PadButton::South)]);
        r.set_route("shell", "", "", "p2", SHELL, t0());
        r.backend_mut().take();
        app(&mut r, "i2", STK, "p2");
        assert_eq!(pad1_of(&r.backend_mut().take()), Some(c));
    }

    /// RUY-38: a pad that does not navigate presses nothing in the shell, so its press does not
    /// make it the next profile's seat 1 either; player 1's pad does.
    #[test]
    fn a_press_of_a_pad_that_does_not_navigate_signs_nobody_in() {
        let mut r = router();
        let b = r.add_pad(pad("b"), t0());
        let c = r.add_pad(pad("c"), t0());
        r.input(b, &[press(PadButton::South), release(PadButton::South)]);
        r.set_route("shell", "", "", "p1", SHELL, t0());
        // Player 1 (b) presses Switch; c presses after it, which changes nothing.
        r.input(b, &[press(PadButton::South), release(PadButton::South)]);
        r.input(c, &[press(PadButton::South), release(PadButton::South)]);
        r.set_route("shell", "", "", "p2", SHELL, t0());
        assert_eq!(r.players()[0].device_id, "b");
    }

    #[test]
    fn a_virtual_pad_per_pad_exists_only_in_app() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        assert!(created(&r.backend_mut().take()).is_empty());
        sign_in(&mut r, a, "p1");
        join(&mut r, b, "p2");
        r.set_route("overlay", "", "", "p1", SHELL, t0());
        assert!(created(&r.backend_mut().take()).is_empty());
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
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
        sign_in(&mut r, a, "p1");
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
        sign_in(&mut r, a, "p1");
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
    fn lock_switch_run_end_and_an_overlay_naming_no_app_destroy_the_virtual_pads() {
        // Lock.
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        r.set_route("locked", "", "", "", SHELL, t0());
        assert_eq!(destroyed(&r.backend_mut().take()), vec![1]);
        // Profile switch: p1's pad goes, p2 gets a new one (a signs each in, RUY-121).
        tap(&mut r, a);
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        tap(&mut r, a);
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
        // An overlay that names no app (the shell sent it over a frozen game before RUY-541):
        // nobody owns the pads, so they go.
        app(&mut r, "i11", RACER, "p2");
        r.backend_mut().take();
        r.set_route("overlay", "", "", "p2", SHELL, t0());
        assert_eq!(destroyed(&r.backend_mut().take()), vec![5]);
        // Back in the app: fresh pads.
        app(&mut r, "i11", RACER, "p2");
        assert_eq!(created(&r.backend_mut().take()).len(), 1);
    }

    /// The journal lines that say a virtual pad was made or destroyed.
    fn pad_lines(r: &mut Router<Fake>) -> Vec<String> {
        journal(r)
            .into_iter()
            .filter(|l| l.contains(" created for ") || l.ends_with(" destroyed"))
            .collect()
    }

    #[test]
    fn a_hub_freeze_keeps_the_same_virtual_pads_through_overlay_and_back() {
        // RUY-541: the Hub over the game, frozen, sends the overlay with the game's instance.
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        join(&mut r, b, "p2");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        let sysnames = |r: &Router<Fake>| -> Vec<String> {
            r.pads
                .values()
                .filter_map(|p| p.virt.as_ref().map(|v| v.sysname.clone()))
                .collect()
        };
        let before = sysnames(&r);
        assert_eq!(before.len(), 2, "both pads have a virtual pad");
        r.input(a, &[press(PadButton::South)]);
        r.backend_mut().take();
        r.take_notices();
        r.set_route("overlay", "i1", STK, "p1", SHELL, t0());
        // Under the overlay (the game frozen): the one neutral frame, then nothing is written.
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(1, vec![(code::EV_KEY, code::BTN_SOUTH, 0)])]
        );
        r.input(a, &[release(PadButton::South), press(PadButton::East)]);
        r.input(b, &[PadInput::Axis(PadAxis::LeftX, 20000)]);
        // A pad that connects and joins under the overlay gets no virtual pad yet.
        let c = r.add_pad(pad("c"), t0());
        join(&mut r, c, "p3");
        let calls = r.backend_mut().take();
        assert!(writes(&calls).is_empty(), "nothing reaches a frozen game");
        assert!(created(&calls).is_empty());
        // The Thaw: the same devices, nothing destroyed or made for a and b.
        app(&mut r, "i1", STK, "p1");
        let calls = r.backend_mut().take();
        assert!(destroyed(&calls).is_empty(), "{calls:?}");
        assert_eq!(
            created(&calls),
            vec![VirtualSpec {
                phys: "ruya-input/pad3".into(),
                rumble: true
            }],
            "only the pad that joined under the overlay is made"
        );
        assert_eq!(
            pad_lines(&mut r),
            vec!["virtual pad ruya-input/pad3 created for ruya-p1 (c)"]
        );
        let after: Vec<String> = sysnames(&r).into_iter().take(2).collect();
        assert_eq!(after, before, "the same event nodes");
        // What is held at the Thaw is masked until it is let go.
        r.input(a, &[PadInput::Axis(PadAxis::LeftX, 0)]);
        r.input(b, &[PadInput::Axis(PadAxis::LeftX, 21000)]);
        r.input(a, &[release(PadButton::East)]);
        assert!(
            writes(&r.backend_mut().take()).is_empty(),
            "held buttons stay masked"
        );
        r.input(a, &[press(PadButton::South)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(1, vec![(code::EV_KEY, code::BTN_SOUTH, 1)])]
        );
        let _ = c;
    }

    #[test]
    fn lock_and_a_profile_switch_still_make_new_pads_after_the_app() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        r.take_notices();
        // app -> locked -> app: destroyed and made again.
        r.set_route("locked", "", "", "", SHELL, t0());
        tap(&mut r, a);
        app(&mut r, "i1", STK, "p1");
        assert_eq!(
            pad_lines(&mut r),
            vec![
                "virtual pad ruya-input/pad1 destroyed",
                "virtual pad ruya-input/pad1 created for ruya-p1 (a)"
            ]
        );
        assert_eq!(destroyed(&r.backend_mut().take()), vec![1]);
        // app -> another profile -> app: p1's pad goes and p2 gets a new one.
        tap(&mut r, a);
        r.set_route("shell", "", "", "p2", SHELL, t0());
        app(&mut r, "i1", STK, "p2");
        assert_eq!(
            pad_lines(&mut r),
            vec![
                "virtual pad ruya-input/pad1 destroyed",
                "virtual pad ruya-input/pad1 created for ruya-p2 (a)"
            ]
        );
        assert_eq!(destroyed(&r.backend_mut().take()), vec![2]);
        // An overlay of the same instance but under the old profile is not the owner: destroyed.
        r.set_route("overlay", "i1", STK, "p1", SHELL, t0());
        assert_eq!(destroyed(&r.backend_mut().take()), vec![3]);
    }

    /// The order of the creations (pad key) and ACL writes (node) in `calls`.
    fn order(calls: &[Call]) -> Vec<String> {
        calls
            .iter()
            .filter_map(|c| match c {
                Call::Create(k, s) => Some(format!("create {k} {}", s.phys)),
                Call::WriteAcl(node) => Some(format!("acl {node}")),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn the_other_pads_are_made_once_pad1_is_ready() {
        // pad1 ready by its udev event: then pad2 and pad3, at once.
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        let c = r.add_pad(pad("c"), t0());
        r.input(b, &[press(PadButton::South)]);
        r.set_route("shell", "", "", "p1", SHELL, t0());
        join(&mut r, a, "p2");
        join(&mut r, c, "p3");
        r.backend_mut().take();
        app(&mut r, "i1", STK, "p1");
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![format!("create {b} ruya-input/pad1")]
        );
        // A pad that joins while pad1 is not ready waits too.
        let d = r.add_pad(pad("d"), t0());
        join(&mut r, d, "p4");
        assert!(created(&r.backend_mut().take()).is_empty());
        r.udev_event(&udev("add", "input101"));
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![
                "acl /dev/input/event17".to_owned(),
                format!("create {a} ruya-input/pad2"),
                format!("create {c} ruya-input/pad3"),
                format!("create {d} ruya-input/pad4"),
            ]
        );
        let lines = journal(&mut r);
        let ready = lines
            .iter()
            .position(|l| l.starts_with("virtual pad ruya-input/pad1 ready"));
        let pad2 = lines
            .iter()
            .position(|l| l.starts_with("virtual pad ruya-input/pad2 created"));
        assert!(ready.is_some() && ready < pad2, "{lines:?}");
        // pad2's own ACL does not hold anything back; a pad that joins now is made at once, with
        // the number of the seat it takes (seat 3, which c left).
        assert_eq!(r.leave_player(3, t0()), Status::Ok);
        let e = r.add_pad(pad("e"), t0());
        assert_eq!(join(&mut r, e, "p5"), 3);
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![format!("create {e} ruya-input/pad3")]
        );

        // No udev event: the others follow pad1's fallback, also when its ACL write fails.
        let mut r = router();
        let start = t0();
        let a = r.add_pad(pad("a"), start);
        let b = r.add_pad(pad("b"), start);
        sign_in(&mut r, a, "p1");
        join(&mut r, b, "p2");
        assert_eq!(
            r.set_route("app", "i1", STK, "p1", SHELL, start),
            Status::Ok
        );
        r.backend_mut().acl_fails = true;
        r.tick(start + UDEV_FALLBACK / 2);
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![format!("create {a} ruya-input/pad1")]
        );
        r.tick(start + UDEV_FALLBACK);
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![format!("create {b} ruya-input/pad2")]
        );

        // pad1 vanishes before it is ready: at the next tick the waiting pads are made, each with
        // its seat's number (RUY-121: seat 1 has no pad now, so no pad1 holds them back).
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        let c = r.add_pad(pad("c"), t0());
        sign_in(&mut r, a, "p1");
        join(&mut r, b, "p2");
        join(&mut r, c, "p3");
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        r.remove_pad(a);
        r.tick(t0());
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![
                format!("create {b} ruya-input/pad2"),
                format!("create {c} ruya-input/pad3")
            ]
        );
    }

    #[test]
    fn a_lock_while_pads_wait_for_pad1_leaves_no_queue_for_the_next_profile() {
        // p1's app: b is pad1, a and c wait for it.
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        let c = r.add_pad(pad("c"), t0());
        r.input(b, &[press(PadButton::South)]);
        r.set_route("shell", "", "", "p1", SHELL, t0());
        join(&mut r, a, "p2");
        join(&mut r, c, "p3");
        app(&mut r, "i1", STK, "p1");
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![format!("create {b} ruya-input/pad1")]
        );
        // Locked before pad1 is ready; c signs p2 in, and p2's app makes c pad1 first: the
        // queue p1's app left (a, c) is gone with its pads.
        r.set_route("locked", "", "", "", SHELL, t0());
        r.input(c, &[press(PadButton::South)]);
        r.set_route("shell", "", "", "p2", SHELL, t0());
        // The lock emptied the seats: only b joins p2's session (RUY-121).
        assert_eq!(join(&mut r, b, "p1"), 2);
        r.backend_mut().take();
        app(&mut r, "i2", STK, "p2");
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![format!("create {c} ruya-input/pad1")]
        );
        settle(&mut r);
        assert_eq!(
            order(&r.backend_mut().take())
                .into_iter()
                .filter(|l| l.starts_with("create"))
                .collect::<Vec<_>>(),
            vec![format!("create {b} ruya-input/pad2")],
            "a, unseated now, is not made"
        );
        let _ = a;
    }

    #[test]
    fn another_profile_never_inherits_a_pad_even_with_the_same_instance() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        r.udev_event(&udev("add", "input101"));
        r.backend_mut().take();
        tap(&mut r, a);
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
        sign_in(&mut r, a, "p1");
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
        sign_in(&mut r, a, "p1");
        join(&mut r, b, "p2");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        r.backend_mut().take();
        r.take_notices();
        // A seated pad's virtual pad goes when the seat's hold runs out (RUY-627).
        let t = t0();
        r.remove_pad_at(a, t);
        assert!(destroyed(&r.backend_mut().take()).is_empty(), "held");
        assert!(r.take_notices().contains(&Notice::DeviceRemoved {
            id: "a".into(),
            instance: "a#1".into()
        }));
        r.tick(t + SEAT_HOLD);
        assert_eq!(destroyed(&r.backend_mut().take()), vec![1]);
        // Player 1 moves to a pad connected while the app is in front: it gets pad1 (RUY-121).
        let c = r.add_pad(pad("c"), t0());
        assert!(created(&r.backend_mut().take()).is_empty());
        assert_eq!(join(&mut r, c, "p1"), 1);
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
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
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
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
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
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        r.udev_event(&udev("add", "input101"));
        tap(&mut r, a);
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
        let a = r.add_pad(pad("a"), start);
        sign_in(&mut r, a, "p1");
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
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
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
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
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
    fn the_test_starts_only_in_the_shell_or_an_overlay_and_once_per_device() {
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
        // RUY-611: a game frozen behind Home keeps its pads under `overlay`; the Controllers pages
        // test there. The picker (`locked`) and an app in front still refuse.
        r.stop_test("a");
        assert_eq!(
            r.set_route("overlay", "i1", STK, "p1", SHELL, now),
            Status::Ok
        );
        assert_eq!(r.start_test("a", false, SHELL, now), Status::Ok);
        assert_eq!(r.set_route("locked", "", "", "", SHELL, now), Status::Ok);
        assert!(!r.testing(), "locked ends the test");
        assert_eq!(r.start_test("a", false, SHELL, now), Status::NotAllowed);
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
        // RUY-611: an overlay (a game's pads held behind Home) keeps it too; the app route ends it.
        r.set_route("overlay", "i1", STK, "p1", SHELL, now);
        assert!(ended(&r.take_notices()).is_empty());
        assert!(r.testing());
        r.set_route("app", "i1", STK, "p1", SHELL, now);
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
                    // RUY-611: an overlay no longer ends a test; `locked` and `app` do.
                    r.set_route("locked", "", "", "", SHELL, now);
                    // The pad signs p1 in, so it is player 1's and still navigates (RUY-38).
                    tap(&mut r, a);
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
        let a = r.add_pad(pad("a"), t0());
        assert_eq!(r.devices()[0].profile, "");
        assert_eq!(r.devices()[0].instance, "a#1");
        // The pad signs p1 in: it is seated, so its record names p1 and seat 1 (RUY-121).
        tap(&mut r, a);
        r.set_route("shell", "", "", "p1", SHELL, t0());
        assert_eq!(r.devices()[0].profile, "p1");
        assert_eq!(r.devices()[0].slot, 1);
        assert!(r
            .take_notices()
            .iter()
            .any(|n| matches!(n, Notice::DeviceChanged(d) if d.profile == "p1" && d.slot == 1)));
        // A second connection with the same id that goes does not unseat the first.
        let a2 = r.add_pad(pad("a"), t0());
        r.remove_pad(a2);
        assert_eq!(r.devices()[0].slot, 1);
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
        sign_in(&mut r, a, "p1");
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
        // Each pad in turn is player 1's (a move), the one pad that navigates (06 §11.3).
        let south_of = |r: &mut Router<Fake>, pad| {
            join(r, pad, "p1");
            r.backend_mut().take();
            r.input(pad, &[press(PadButton::South), release(PadButton::South)]);
            keys_of(r)[0].0
        };
        let set_all = |r: &mut Router<Fake>, mode: &str| {
            for id in ["ps", "nin", "odd"] {
                assert_eq!(r.set_confirm_button("p1", id, mode), Status::Ok);
            }
        };
        assert_eq!(south_of(&mut r, ps), NavKey::Accept);
        assert_eq!(south_of(&mut r, nin), NavKey::Back);
        assert_eq!(south_of(&mut r, odd), NavKey::Accept);
        set_all(&mut r, "east");
        assert_eq!(south_of(&mut r, ps), NavKey::Back, "Circle confirms");
        assert_eq!(south_of(&mut r, nin), NavKey::Back);
        assert_eq!(south_of(&mut r, odd), NavKey::Back);
        set_all(&mut r, "south");
        assert_eq!(south_of(&mut r, ps), NavKey::Accept);
        assert_eq!(
            south_of(&mut r, nin),
            NavKey::Accept,
            "Bottom on a Nintendo pad"
        );
        set_all(&mut r, "family");
        assert_eq!(south_of(&mut r, nin), NavKey::Back);
    }

    /// RUY-603: each pad of one profile confirms with its own choice.
    #[test]
    fn two_pads_of_one_profile_confirm_each_with_its_own_setting() {
        let mut r = router();
        let a = r.add_pad(family_pad("xa", "xbox"), t0());
        let b = r.add_pad(family_pad("xb", "xbox"), t0());
        signed_in(&mut r, "p1");
        assert_eq!(r.set_confirm_button("p1", "xa", "east"), Status::Ok);
        assert_eq!(r.set_confirm_button("p1", "xb", "south"), Status::Ok);
        // Each pad in turn is player 1's (a move), the one pad that navigates (06 §11.3).
        let keys = |r: &mut Router<Fake>, pad, button| {
            join(r, pad, "p1");
            r.backend_mut().take();
            r.input(pad, &[press(button), release(button)]);
            keys_of(r)[0].0
        };
        assert_eq!(keys(&mut r, a, PadButton::East), NavKey::Accept, "A: right");
        assert_eq!(keys(&mut r, a, PadButton::South), NavKey::Back);
        assert_eq!(
            keys(&mut r, b, PadButton::South),
            NavKey::Accept,
            "B: bottom"
        );
        assert_eq!(keys(&mut r, b, PadButton::East), NavKey::Back);
        // Back to "as on the controller" for one pad leaves the other's choice.
        assert_eq!(r.set_confirm_button("p1", "xa", "family"), Status::Ok);
        assert_eq!(keys(&mut r, a, PadButton::South), NavKey::Accept);
        assert_eq!(keys(&mut r, b, PadButton::South), NavKey::Accept);
        let (status, map) = r.confirm_buttons("p1");
        assert_eq!(status, Status::Ok);
        assert_eq!(
            map,
            BTreeMap::from([("xb".to_owned(), "south".to_owned())]),
            "family is no entry"
        );
    }

    /// RUY-603: one pad takes the choice of whoever is signed in.
    #[test]
    fn one_pad_takes_each_profiles_own_setting() {
        let mut r = router();
        let n = r.add_pad(family_pad("n", "nintendo"), t0());
        assert_eq!(r.set_confirm_button("p1", "n", "south"), Status::Ok);
        assert_eq!(r.set_confirm_button("p2", "n", "east"), Status::Ok);
        let south_of = |r: &mut Router<Fake>| {
            r.backend_mut().take();
            r.input(n, &[press(PadButton::South), release(PadButton::South)]);
            keys_of(r)[0].0
        };
        sign_in(&mut r, n, "p1");
        assert_eq!(south_of(&mut r), NavKey::Accept, "p1: Bottom");
        sign_in(&mut r, n, "p2");
        assert_eq!(south_of(&mut r), NavKey::Back, "p2: Right");
        assert_eq!(
            r.confirm_buttons("p1").1,
            BTreeMap::from([("n".to_owned(), "south".to_owned())])
        );
        assert_eq!(
            r.confirm_buttons("p2").1,
            BTreeMap::from([("n".to_owned(), "east".to_owned())])
        );
    }

    #[test]
    fn a_held_button_is_released_as_it_was_pressed_after_the_setting_changes() {
        let mut r = router();
        let a = r.add_pad(family_pad("x", "xbox"), t0());
        sign_in(&mut r, a, "p1");
        r.input(a, &[press(PadButton::South)]);
        assert_eq!(keys_of(&mut r), vec![(NavKey::Accept, true)]);
        assert_eq!(r.set_confirm_button("p1", "x", "east"), Status::Ok);
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
        sign_in(&mut r, a, "p1");
        r.input(a, &[press(PadButton::East)]);
        assert_eq!(r.set_confirm_button("p1", "n", "south"), Status::Ok);
        assert_eq!(r.remove_pad(a), vec![NavKey::Accept]);
        assert_eq!(
            keys_of(&mut r),
            vec![(NavKey::Accept, true), (NavKey::Accept, false)]
        );
    }

    fn property_changed(r: &mut Router<Fake>) -> bool {
        r.take_notices()
            .iter()
            .any(|n| matches!(n, Notice::ConfirmButtonChanged))
    }

    #[test]
    fn the_setting_is_per_console_profile_and_follows_the_switch() {
        let mut r = router();
        let a = r.add_pad(family_pad("x", "xbox"), t0());
        assert_eq!(r.confirm_button(), "family", "no profile");
        sign_in(&mut r, a, "p1");
        r.input(a, &[press(PadButton::DpadUp), release(PadButton::DpadUp)]);
        assert_eq!(r.set_confirm_button("p1", "x", "east"), Status::Ok);
        assert_eq!(r.confirm_button(), "east");
        r.take_notices();
        signed_in(&mut r, "p2");
        assert_eq!(r.confirm_button(), "family");
        assert!(property_changed(&mut r), "a switch announces the property");
        // A set for the signed-in profile's active pad announces the property.
        assert_eq!(r.set_confirm_button("p2", "x", "south"), Status::Ok);
        assert!(
            property_changed(&mut r),
            "a set for the active pad announces the property"
        );
        assert_eq!(r.set_confirm_button("p2", "x", "family"), Status::Ok);
        r.take_notices();
        // Another profile's change is not the active profile's property.
        assert_eq!(r.set_confirm_button("p1", "x", "south"), Status::Ok);
        assert!(
            !property_changed(&mut r),
            "another profile's change is not the property"
        );
        r.backend_mut().take();
        r.input(a, &[press(PadButton::South)]);
        assert_eq!(keys_of(&mut r), vec![(NavKey::Accept, true)]);
        signed_in(&mut r, "p1");
        assert_eq!(r.confirm_button(), "south");
    }

    /// RUY-603: ConfirmButton is the mode of the pad that pressed last.
    #[test]
    fn the_property_follows_the_active_pad() {
        let mut r = router();
        let a = r.add_pad(family_pad("xa", "xbox"), t0());
        let b = r.add_pad(family_pad("xb", "xbox"), t0());
        let c = r.add_pad(family_pad("xc", "xbox"), t0());
        signed_in(&mut r, "p1");
        assert_eq!(r.set_confirm_button("p1", "xa", "east"), Status::Ok);
        assert_eq!(r.set_confirm_button("p1", "xc", "east"), Status::Ok);
        assert_eq!(r.confirm_button(), "family", "no pad has pressed yet");
        r.take_notices();
        // Each pad in turn is player 1's (a move), the one pad that navigates (06 §11.3).
        let tap = |r: &mut Router<Fake>, pad| {
            join(r, pad, "p1");
            r.input(pad, &[press(PadButton::DpadUp), release(PadButton::DpadUp)]);
        };
        tap(&mut r, a);
        assert_eq!(r.confirm_button(), "east");
        assert!(property_changed(&mut r), "the active pad's mode differs");
        tap(&mut r, b);
        assert_eq!(r.confirm_button(), "family");
        assert!(property_changed(&mut r), "back to family");
        tap(&mut r, c);
        r.take_notices();
        tap(&mut r, a);
        assert_eq!(r.confirm_button(), "east");
        assert!(!property_changed(&mut r), "another pad with the same mode");
        // A set for a pad that is not the active one is not the property.
        assert_eq!(r.set_confirm_button("p1", "xb", "south"), Status::Ok);
        assert!(!property_changed(&mut r), "not the active pad");
        assert_eq!(r.confirm_button(), "east");
        // The active pad going takes the property back to family.
        r.remove_pad(a);
        assert_eq!(r.confirm_button(), "family");
        assert!(property_changed(&mut r), "the active pad went");
    }

    #[test]
    fn set_confirm_button_answers_ok_invalid_unknown_profile_or_failed() {
        let mut r = router();
        assert_eq!(r.set_confirm_button("p1", "x", "Right"), Status::Invalid);
        assert_eq!(r.set_confirm_button("p1", "x", ""), Status::Invalid);
        assert_eq!(r.set_confirm_button("p1", "", "east"), Status::Invalid);
        assert_eq!(r.set_confirm_button("p1", "Pad 1", "east"), Status::Invalid);
        assert_eq!(
            r.set_confirm_button("nobody", "x", "east"),
            Status::UnknownProfile
        );
        assert_eq!(
            r.set_confirm_button("", "x", "east"),
            Status::UnknownProfile
        );
        assert_eq!(
            r.set_confirm_button("root", "x", "east"),
            Status::UnknownProfile
        );
        assert_eq!(r.confirm_buttons("root").0, Status::UnknownProfile);
        // A pad that is not connected may be set (its controller page can outlive it).
        assert_eq!(r.set_confirm_button("p1", "x", "east"), Status::Ok);
        let store = crate::book::MemStore {
            fail: true,
            ..Default::default()
        };
        r.set_book(Book::new(Box::new(store)));
        let a = r.add_pad(family_pad("x", "xbox"), t0());
        signed_in(&mut r, "p1");
        r.input(a, &[press(PadButton::DpadUp), release(PadButton::DpadUp)]);
        assert_eq!(r.set_confirm_button("p1", "x", "east"), Status::Failed);
        assert_eq!(
            r.confirm_button(),
            "family",
            "a refused write changes nothing"
        );
        assert!(r.confirm_buttons("p1").1.is_empty());
    }

    #[test]
    fn the_setting_is_read_from_the_state_directory() {
        let mut store = crate::book::MemStore::default();
        store.files.insert(
            ("p1".into(), crate::book::SETTINGS.into()),
            r#"{"confirm_buttons":{"x":"east","y":"family","z":"sideways","Bad Id":"east"}}"#
                .into(),
        );
        store.files.insert(
            ("p2".into(), crate::book::SETTINGS.into()),
            r#"{"confirm_buttons":"east"}"#.into(),
        );
        let mut r = router();
        r.set_book(Book::new(Box::new(store)));
        let x = r.add_pad(family_pad("x", "xbox"), t0());
        signed_in(&mut r, "p1");
        assert_eq!(
            r.confirm_buttons("p1"),
            (
                Status::Ok,
                BTreeMap::from([("x".to_owned(), "east".to_owned())])
            ),
            "only good entries, family is no entry"
        );
        join(&mut r, x, "p1");
        r.input(x, &[press(PadButton::DpadUp), release(PadButton::DpadUp)]);
        assert_eq!(r.confirm_button(), "east");
        let lines = journal(&mut r);
        assert!(lines.iter().any(|l| l.contains("sideways")), "{lines:?}");
        assert!(lines.iter().any(|l| l.contains("Bad Id")), "{lines:?}");
        signed_in(&mut r, "p2");
        assert_eq!(r.confirm_button(), "family", "not a map: not used");
        assert!(journal(&mut r).iter().any(|l| l.contains("not a map")));
        // The settings file is no profile.
        let (_, list) = r.list_profiles("p1");
        assert!(list.iter().all(|s| s.id != "_settings"), "{list:?}");
    }

    /// RUY-603: the profile-wide value of RUY-40 is dropped on load and the next write leaves it out.
    #[test]
    fn the_old_profile_wide_setting_is_dropped() {
        let mut store = crate::book::MemStore::default();
        store.files.insert(
            ("p1".into(), crate::book::SETTINGS.into()),
            r#"{"confirm_button":"east"}"#.into(),
        );
        let mut r = router();
        r.set_book(Book::new(Box::new(store)));
        let x = r.add_pad(family_pad("x", "xbox"), t0());
        signed_in(&mut r, "p1");
        join(&mut r, x, "p1");
        r.backend_mut().take();
        r.input(x, &[press(PadButton::South), release(PadButton::South)]);
        assert_eq!(keys_of(&mut r)[0].0, NavKey::Accept, "as on the controller");
        assert_eq!(r.confirm_button(), "family");
        assert!(r.confirm_buttons("p1").1.is_empty());
        assert!(
            journal(&mut r)
                .iter()
                .any(|l| l.contains("confirm_button \"east\" is dropped")),
            "the drop is journaled"
        );
    }

    #[test]
    fn the_virtual_pad_never_sees_the_confirm_setting() {
        let events_for = |mode: &str| {
            let mut r = router();
            let a = r.add_pad(family_pad("n", "nintendo"), t0());
            sign_in(&mut r, a, "p1");
            assert_eq!(r.save_profile("p1", SWAP).0, Status::Ok);
            assert_eq!(r.assign_profile("p1", "global", "", "swap"), Status::Ok);
            assert_eq!(r.set_confirm_button("p1", "n", mode), Status::Ok);
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
        sign_in(&mut r, a, "p1");
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
        sign_in(&mut r, a, "p1");
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
        sign_in(&mut r, a, "p1");
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
        sign_in(&mut r, a, "p1");
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
        sign_in(&mut r, a, "p1");
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
        sign_in(&mut r, a, "p1");
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
        sign_in(&mut r, a, "p1");
        join(&mut r, b, "p2");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
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

    // ---- players (ADR-017, 06 §11.3; RUY-121) ----------------------------------------------

    fn seats_of(r: &Router<Fake>) -> Vec<(u32, String, String)> {
        r.players()
            .into_iter()
            .map(|p| (p.slot, p.profile, p.device_id))
            .collect()
    }

    fn seat(slot: u32, profile: &str, device: &str) -> (u32, String, String) {
        (slot, profile.to_owned(), device.to_owned())
    }

    /// The phys of the pad's virtual pad now, if it has one.
    fn phys_of(r: &Router<Fake>, key: PadKey) -> Option<String> {
        r.pads[&key].virt.as_ref().map(|v| v.phys.clone())
    }

    fn players_signals(notices: &[Notice]) -> Vec<Vec<(u32, String, String)>> {
        notices
            .iter()
            .filter_map(|n| match n {
                Notice::PlayersChanged(list) => Some(
                    list.iter()
                        .map(|p| (p.slot, p.profile.clone(), p.device_id.clone()))
                        .collect(),
                ),
                _ => None,
            })
            .collect()
    }

    /// The (device id, slot, profile) of every DeviceChanged in `notices`.
    fn device_changes(notices: &[Notice]) -> Vec<(String, u32, String)> {
        notices
            .iter()
            .filter_map(|n| match n {
                Notice::DeviceChanged(d) => Some((d.id.clone(), d.slot, d.profile.clone())),
                _ => None,
            })
            .collect()
    }

    /// Three pads, a signs p1 in, b and c join as p2 and p3, the app is in front and every
    /// virtual pad is made: pad1, pad2, pad3.
    fn three_players() -> (Router<Fake>, PadKey, PadKey, PadKey) {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        let c = r.add_pad(pad("c"), t0());
        sign_in(&mut r, a, "p1");
        assert_eq!(join(&mut r, b, "p2"), 2);
        assert_eq!(join(&mut r, c, "p3"), 3);
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        assert_eq!(phys_of(&r, c).as_deref(), Some("ruya-input/pad3"));
        r.backend_mut().take();
        r.take_notices();
        (r, a, b, c)
    }

    #[test]
    fn a_pad_sign_in_seats_player_1_on_that_pad_and_a_keyboard_sign_in_on_no_pad() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        assert!(r.players().is_empty(), "no seats before a sign-in");
        tap(&mut r, a);
        r.set_route("shell", "", "", "p1", SHELL, t0());
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "a")]);
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        assert_eq!(phys_of(&r, a).as_deref(), Some("ruya-input/pad1"));
        assert_eq!(phys_of(&r, b), None);
        // Lock: no seats. p2 signs in from the keyboard: seat 1 has no pad, no pad reaches p2's app.
        r.set_route("locked", "", "", "", SHELL, t0());
        assert!(r.players().is_empty());
        r.set_route("shell", "", "", "p2", SHELL, t0());
        assert_eq!(seats_of(&r), vec![seat(1, "p2", "")]);
        r.backend_mut().take();
        app(&mut r, "i2", STK, "p2");
        settle(&mut r);
        assert!(created(&r.backend_mut().take()).is_empty());
    }

    #[test]
    fn join_a_player_1_moves_to_another_pad_and_pad1_follows_it() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        r.backend_mut().take();
        assert_eq!(r.join_player("b", "p1", t0()), (Status::Ok, 1));
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "b")]);
        assert_eq!(phys_of(&r, a), None, "the old pad is unseated");
        assert_eq!(phys_of(&r, b).as_deref(), Some("ruya-input/pad1"));
        // RUY-627: pad1 is bound to b, the same device: the game sees no pad go or come.
        let calls = r.backend_mut().take();
        assert!(destroyed(&calls).is_empty(), "{calls:?}");
        assert!(created(&calls).is_empty(), "{calls:?}");
        assert_eq!(virtual_id(&r, b), Some(1));
        // a reaches no app now; b is pad1.
        r.input(a, &[press(PadButton::South)]);
        assert!(writes(&r.backend_mut().take()).is_empty());
        r.input(b, &[press(PadButton::South)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(1, vec![(code::EV_KEY, code::BTN_SOUTH, 1)])]
        );
    }

    #[test]
    fn join_b_a_player_moves_to_another_pad_and_keeps_its_seat_and_number() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        join(&mut r, b, "p2");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        let c = r.add_pad(pad("c"), t0());
        r.backend_mut().take();
        assert_eq!(r.join_player("c", "p2", t0()), (Status::Ok, 2));
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "a"), seat(2, "p2", "c")]);
        assert_eq!(phys_of(&r, b), None, "the old pad is unseated");
        assert_eq!(phys_of(&r, c).as_deref(), Some("ruya-input/pad2"));
        assert_eq!(phys_of(&r, a).as_deref(), Some("ruya-input/pad1"));
        // RUY-627: pad2 is bound to c, not destroyed and made again.
        let calls = r.backend_mut().take();
        assert!(destroyed(&calls).is_empty(), "{calls:?}");
        assert!(created(&calls).is_empty(), "{calls:?}");
        assert_eq!(virtual_id(&r, c), Some(2));
    }

    #[test]
    fn join_c_a_pad_seated_as_another_profile_leaves_that_seat_first() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        join(&mut r, b, "p2");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        r.backend_mut().take();
        // b was p2's: p2 leaves seat 2 and p3 takes it, on a new virtual pad2 (another player).
        assert_eq!(r.join_player("b", "p3", t0()), (Status::Ok, 2));
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "a"), seat(2, "p3", "b")]);
        let calls = r.backend_mut().take();
        assert_eq!(destroyed(&calls), vec![2]);
        assert_eq!(phys_of(&r, b).as_deref(), Some("ruya-input/pad2"));
        // Player 1's pad joins as p4: player 1 stays, without a pad, and a is pad3 now.
        assert_eq!(r.join_player("a", "p4", t0()), (Status::Ok, 3));
        assert_eq!(
            seats_of(&r),
            vec![seat(1, "p1", ""), seat(2, "p3", "b"), seat(3, "p4", "a")]
        );
        assert_eq!(phys_of(&r, a).as_deref(), Some("ruya-input/pad3"));
    }

    #[test]
    fn join_d_takes_the_lowest_free_seat_and_live_pads_keep_their_numbers() {
        let (mut r, _a, b, c) = three_players();
        let c_virtual = r.pads[&c].virt.as_ref().map(|v| v.id);
        assert_eq!(r.leave_player(2, t0()), Status::Ok);
        assert_eq!(phys_of(&r, b), None);
        assert_eq!(destroyed(&r.backend_mut().take()), vec![2]);
        // pad3 stays, the same device, still c's.
        assert_eq!(r.pads[&c].virt.as_ref().map(|v| v.id), c_virtual);
        assert_eq!(phys_of(&r, c).as_deref(), Some("ruya-input/pad3"));
        // p3 moves to a new pad: it keeps seat 3, so the new pad is pad3, not the free pad2.
        let d = r.add_pad(pad("d"), t0());
        assert_eq!(join(&mut r, d, "p3"), 3);
        assert_eq!(phys_of(&r, d).as_deref(), Some("ruya-input/pad3"));
        // The next join takes the lowest free seat, 2, and is pad2.
        let e = r.add_pad(pad("e"), t0());
        assert_eq!(join(&mut r, e, "p4"), 2);
        assert_eq!(phys_of(&r, e).as_deref(), Some("ruya-input/pad2"));
    }

    #[test]
    fn join_e_the_same_pad_and_profile_again_change_nothing_and_send_nothing() {
        let (mut r, _a, _b, _c) = three_players();
        // Seat 2 is free: p3 on c again keeps seat 3 (it does not leave and take the lowest seat).
        assert_eq!(r.leave_player(2, t0()), Status::Ok);
        r.backend_mut().take();
        r.take_notices();
        assert_eq!(r.join_player("c", "p3", t0()), (Status::Ok, 3));
        assert_eq!(r.join_player("a", "p1", t0()), (Status::Ok, 1));
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "a"), seat(3, "p3", "c")]);
        assert!(r.backend_mut().take().is_empty());
        let n = r.take_notices();
        assert!(n.is_empty(), "no signal, no journal line: {n:?}");
    }

    #[test]
    fn the_fourth_join_is_full_and_changes_nothing() {
        let (mut r, _a, _b, _c) = three_players();
        let d = r.add_pad(pad("d"), t0());
        let e = r.add_pad(pad("e"), t0());
        assert_eq!(join(&mut r, d, "p4"), 4);
        r.backend_mut().take();
        r.take_notices();
        let before = seats_of(&r);
        assert_eq!(r.join_player("e", "p5", t0()), (Status::Full, 0));
        assert_eq!(seats_of(&r), before);
        assert_eq!(phys_of(&r, e), None);
        assert!(r.backend_mut().take().is_empty());
        assert!(players_signals(&r.take_notices()).is_empty());
    }

    #[test]
    fn join_and_leave_answer_their_statuses() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        // Nobody signed in: the route is shell with "" now, then locked.
        assert_eq!(r.join_player("a", "p1", t0()), (Status::NotAllowed, 0));
        r.set_route("locked", "", "", "", SHELL, t0());
        assert_eq!(r.join_player("a", "p1", t0()), (Status::NotAllowed, 0));
        assert_eq!(r.leave_player(2, t0()), Status::NotAllowed);
        // A malformed device id is invalid first, also while locked.
        assert_eq!(r.join_player("", "p1", t0()), (Status::Invalid, 0));
        assert_eq!(r.join_player("A B", "p1", t0()), (Status::Invalid, 0));
        let long = "a".repeat(65);
        assert_eq!(r.join_player(&long, "p1", t0()), (Status::Invalid, 0));
        sign_in(&mut r, a, "p1");
        // Not a profile account: root, ruya-shell, an unknown id, a malformed one.
        for profile in ["root", "shell", "p9", "../p1", ""] {
            assert_eq!(
                r.join_player("a", profile, t0()),
                (Status::UnknownProfile, 0),
                "{profile}"
            );
        }
        assert_eq!(r.join_player("zz", "p2", t0()), (Status::UnknownDevice, 0));
        // LeavePlayer: 0 and 5 are invalid, seat 1 is not allowed, an empty seat is ok.
        assert_eq!(r.leave_player(0, t0()), Status::Invalid);
        assert_eq!(r.leave_player(5, t0()), Status::Invalid);
        assert_eq!(r.leave_player(1, t0()), Status::NotAllowed);
        r.take_notices();
        assert_eq!(r.leave_player(3, t0()), Status::Ok);
        assert!(r.take_notices().is_empty(), "an empty seat: no signal");
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "a")]);
    }

    #[test]
    fn lock_and_a_profile_switch_clear_every_seat_and_destroy_the_virtual_pads() {
        let (mut r, a, b, c) = three_players();
        r.set_route("locked", "", "", "", SHELL, t0());
        assert!(r.players().is_empty());
        assert_eq!(destroyed(&r.backend_mut().take()).len(), 3);
        assert_eq!(players_signals(&r.take_notices()), vec![vec![]]);
        // b signs p2 in; a joins; the app; then a Hub switch to p3 pressed on c.
        sign_in(&mut r, b, "p2");
        join(&mut r, a, "p1");
        app(&mut r, "i2", STK, "p2");
        settle(&mut r);
        assert_eq!(phys_of(&r, a).as_deref(), Some("ruya-input/pad2"));
        r.backend_mut().take();
        r.take_notices();
        // c drives the prompt (RUY-38): only a pad that navigates can press Switch.
        assert_eq!(r.set_navigator("c", SHELL), Status::Ok);
        tap(&mut r, c);
        r.set_route("shell", "", "", "p3", SHELL, t0());
        assert_eq!(seats_of(&r), vec![seat(1, "p3", "c")]);
        assert_eq!(destroyed(&r.backend_mut().take()).len(), 2);
        assert_eq!(phys_of(&r, a), None);
        assert_eq!(phys_of(&r, b), None);
        assert_eq!(
            players_signals(&r.take_notices()),
            vec![vec![seat(1, "p3", "c")]],
            "one PlayersChanged for the switch"
        );
    }

    #[test]
    fn only_seated_pads_get_a_virtual_pad() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        let calls = r.backend_mut().take();
        assert_eq!(
            created(&calls),
            vec![VirtualSpec {
                phys: "ruya-input/pad1".into(),
                rumble: true
            }]
        );
        assert_eq!(pad1_of(&calls), Some(a));
        // The unseated pad's input reaches no app; its record says so.
        r.input(
            b,
            &[
                press(PadButton::South),
                PadInput::Axis(PadAxis::LeftX, 20000),
            ],
        );
        assert!(writes(&r.backend_mut().take()).is_empty());
        let rec = r.devices().into_iter().find(|d| d.id == "b").expect("b");
        assert_eq!((rec.slot, rec.profile.as_str(), rec.routed), (0, "", false));
    }

    #[test]
    fn a_pad_that_joins_under_the_overlay_gets_pad2_at_the_next_app() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        r.set_route("overlay", "i1", STK, "p1", SHELL, t0());
        r.backend_mut().take();
        let b = r.add_pad(pad("b"), t0());
        assert_eq!(join(&mut r, b, "p2"), 2);
        assert!(
            created(&r.backend_mut().take()).is_empty(),
            "not under the overlay"
        );
        app(&mut r, "i1", STK, "p1");
        let calls = r.backend_mut().take();
        assert!(destroyed(&calls).is_empty());
        assert_eq!(
            created(&calls),
            vec![VirtualSpec {
                phys: "ruya-input/pad2".into(),
                rumble: true
            }]
        );
        assert_eq!(phys_of(&r, b).as_deref(), Some("ruya-input/pad2"));
    }

    #[test]
    fn the_device_record_follows_the_seat_with_one_device_changed_each() {
        let (mut r, _a, _b, _c) = three_players();
        let d = r.add_pad(pad("d"), t0());
        r.take_notices();
        // p2 moves from b (pad2, ready) to d: one DeviceChanged for each of the two pads.
        assert_eq!(join(&mut r, d, "p2"), 2);
        let n = r.take_notices();
        let mut changes = device_changes(&n);
        changes.sort();
        assert_eq!(
            changes,
            vec![("b".into(), 0, String::new()), ("d".into(), 2, "p2".into())]
        );
        assert_eq!(players_signals(&n).len(), 1);
        let rec = r.devices().into_iter().find(|x| x.id == "b").expect("b");
        assert_eq!((rec.slot, rec.profile.as_str(), rec.routed), (0, "", false));
        // Leaving: one for d.
        assert_eq!(r.leave_player(2, t0()), Status::Ok);
        assert_eq!(
            device_changes(&r.take_notices()),
            vec![("d".into(), 0, String::new())]
        );
    }

    #[test]
    fn players_changed_carries_the_whole_list_once_per_change() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        tap(&mut r, a);
        r.set_route("shell", "", "", "p1", SHELL, t0());
        assert_eq!(
            players_signals(&r.take_notices()),
            vec![vec![seat(1, "p1", "a")]]
        );
        join(&mut r, b, "p2");
        assert_eq!(
            players_signals(&r.take_notices()),
            vec![vec![seat(1, "p1", "a"), seat(2, "p2", "b")]]
        );
        // A route change that keeps the profile changes no seat.
        app(&mut r, "i1", STK, "p1");
        assert!(players_signals(&r.take_notices()).is_empty());
    }

    #[test]
    fn a_seated_pad_that_disconnects_frees_its_seat_and_seat_1_keeps_its_profile() {
        // Since RUY-627 that happens when the hold runs out: at 61 s.
        let (mut r, a, b, c) = three_players();
        let t = t0();
        r.remove_pad_at(b, t);
        r.remove_pad_at(a, t);
        r.tick(t + Duration::from_secs(59));
        assert_eq!(
            seats_of(&r),
            vec![seat(1, "p1", "a"), seat(2, "p2", "b"), seat(3, "p3", "c")]
        );
        r.backend_mut().take();
        journal(&mut r);
        r.tick(t + Duration::from_secs(61));
        assert_eq!(seats_of(&r), vec![seat(1, "p1", ""), seat(3, "p3", "c")]);
        let lines = journal(&mut r);
        assert!(lines.contains(&"player 2 left".to_owned()), "{lines:?}");
        assert!(lines.contains(&"player 1 is ruya-p1 on no pad".to_owned()));
        // Seat 2's pad2 and seat 1's pad1 are destroyed; pad3 stays.
        let mut gone = destroyed(&r.backend_mut().take());
        gone.sort_unstable();
        assert_eq!(gone, vec![1, 2]);
        assert_eq!(phys_of(&r, c).as_deref(), Some("ruya-input/pad3"));
        // The same pad back after the hold is not seated: only JoinPlayer seats player 1 again.
        let a2 = r.add_pad(pad("a"), t + Duration::from_secs(62));
        assert_eq!(phys_of(&r, a2), None);
        assert_eq!(seats_of(&r)[0], seat(1, "p1", ""));
        assert!(created(&r.backend_mut().take()).is_empty());
    }

    // ---- the seat hold (RUY-627) ----------------------------------------------------------

    fn held_of(r: &Router<Fake>) -> Vec<(u32, bool)> {
        r.players()
            .into_iter()
            .map(|p| (p.slot, p.held_until.is_some()))
            .collect()
    }

    #[test]
    fn removing_a_seated_pad_holds_its_seat_and_keeps_its_virtual_pad_in_neutral() {
        let (mut r, a, b, _c) = three_players();
        let vb = virtual_id(&r, b);
        r.input(
            b,
            &[
                press(PadButton::South),
                PadInput::Axis(PadAxis::LeftX, 30000),
            ],
        );
        r.backend_mut().take();
        let t = t0();
        r.remove_pad_at(b, t);
        // The seat keeps b's id, held, with the seconds left.
        assert_eq!(
            seats_of(&r),
            vec![seat(1, "p1", "a"), seat(2, "p2", "b"), seat(3, "p3", "c")]
        );
        assert_eq!(held_of(&r), vec![(1, false), (2, true), (3, false)]);
        assert_eq!(r.players()[1].held_secs(t), 60);
        // pad2 stays: not destroyed, one neutral frame and nothing more.
        let calls = r.backend_mut().take();
        assert!(destroyed(&calls).is_empty(), "{calls:?}");
        let vb = vb.expect("b had pad2");
        assert_eq!(
            writes(&calls),
            vec![(
                vb,
                vec![
                    (code::EV_KEY, code::BTN_SOUTH, 0),
                    (code::EV_ABS, code::ABS_X, 0)
                ]
            )]
        );
        let n = r.take_notices();
        assert_eq!(
            players_signals(&n).len(),
            1,
            "one PlayersChanged as it starts"
        );
        let lines = journal_of(&n);
        assert!(lines.contains(&"player 2 (ruya-p2) held for 60 s: b is gone".to_owned()));
        assert!(
            !lines.iter().any(|l| l.starts_with("player 2 is")),
            "a hold is not a new player: {lines:?}"
        );
        // Nothing while it counts down; seat 1 is held the same way.
        r.tick(t + Duration::from_secs(30));
        assert!(players_signals(&r.take_notices()).is_empty());
        r.remove_pad_at(a, t);
        assert_eq!(held_of(&r), vec![(1, true), (2, true), (3, false)]);
        assert!(destroyed(&r.backend_mut().take()).is_empty());
    }

    fn journal_of(notices: &[Notice]) -> Vec<String> {
        notices
            .iter()
            .filter_map(|n| match n {
                Notice::Journal(l) => Some(l.clone()),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn a_pad_back_within_the_hold_gets_its_seat_and_the_same_virtual_pad() {
        let (mut r, a, b, _c) = three_players();
        let (va, vb) = (virtual_id(&r, a), virtual_id(&r, b));
        let t = t0();
        r.remove_pad_at(b, t);
        r.remove_pad_at(a, t);
        r.backend_mut().take();
        r.take_notices();
        // b is back at 59 s.
        let at = t + Duration::from_secs(59);
        r.tick(at);
        let b2 = r.add_pad(pad("b"), at);
        assert_eq!(held_of(&r), vec![(1, true), (2, false), (3, false)]);
        assert_eq!(virtual_id(&r, b2), vb, "the same virtual pad");
        let calls = r.backend_mut().take();
        assert!(created(&calls).is_empty(), "{calls:?}");
        assert!(destroyed(&calls).is_empty(), "{calls:?}");
        let n = r.take_notices();
        assert_eq!(
            players_signals(&n).len(),
            1,
            "one PlayersChanged as it ends"
        );
        assert!(journal_of(&n).contains(&"player 2 (ruya-p2) is back on b".to_owned()));
        let rec = r.devices().into_iter().find(|d| d.id == "b").expect("b");
        assert_eq!((rec.slot, rec.profile.as_str()), (2, "p2"));
        // A button held through the reconnect was pressed before the node was opened: only its
        // release arrives, which changes nothing on pad2. The next press reaches it.
        let vb = vb.expect("b had pad2");
        r.input(b2, &[release(PadButton::South)]);
        assert!(writes(&r.backend_mut().take()).is_empty());
        r.input(b2, &[press(PadButton::East)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(vb, vec![(code::EV_KEY, code::BTN_EAST, 1)])]
        );
        // Seat 1 the same: a is player 1's pad again, on pad1.
        let a2 = r.add_pad(pad("a"), at);
        assert_eq!(virtual_id(&r, a2), va);
        assert_eq!(r.seats.player1_device(), Some("a"));
        assert!(r.players().iter().all(|p| p.held_until.is_none()));
        // The hold has ended: its deadline frees nothing.
        r.tick(t + Duration::from_secs(61));
        assert!(destroyed(&r.backend_mut().take()).is_empty());
        assert_eq!(seats_of(&r).len(), 3);
    }

    fn usb_pad(id: &str) -> PadInfo {
        PadInfo {
            connection: "usb".into(),
            port_bound: true,
            ..pad(id)
        }
    }

    const X1: &str = "usb-045e-028e-000000000001";
    const X2: &str = "usb-045e-028e-000000000002";
    const X3: &str = "usb-045e-028e-000000000003";

    #[test]
    fn a_like_pad_in_another_socket_takes_the_one_held_seat_of_its_model() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let x = r.add_pad(usb_pad(X1), t0());
        sign_in(&mut r, a, "p1");
        assert_eq!(join(&mut r, x, "p2"), 2);
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        let vx = virtual_id(&r, x);
        let t = t0();
        r.remove_pad_at(x, t);
        r.backend_mut().take();
        // Another model, a pad with a serial, and a Bluetooth pad of the same model take nothing.
        let other = r.add_pad(usb_pad("usb-054c-0ce6-000000000009"), t);
        let serial = r.add_pad(
            PadInfo {
                port_bound: false,
                ..usb_pad("usb-045e-028e-00000000000a")
            },
            t,
        );
        let bt = r.add_pad(pad("bluetooth-045e-028e-00000000000b"), t);
        assert_eq!(held_of(&r), vec![(1, false), (2, true)]);
        for k in [other, serial, bt] {
            assert_eq!(phys_of(&r, k), None);
        }
        // The same model, serial-less, in another socket: seat 2 is its now, on the same pad2.
        let y = r.add_pad(usb_pad(X2), t + Duration::from_secs(10));
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "a"), seat(2, "p2", X2)]);
        assert_eq!(held_of(&r), vec![(1, false), (2, false)]);
        assert_eq!(virtual_id(&r, y), vx);
        let calls = r.backend_mut().take();
        assert!(created(&calls).is_empty() && destroyed(&calls).is_empty());
        assert!(journal(&mut r).contains(&format!(
            "player 2 (ruya-p2) is back on {X2}, a like pad of {X1}"
        )));
    }

    #[test]
    fn a_like_pad_never_takes_the_held_seat_of_a_pad_with_a_serial() {
        // Player 2's USB pad has a serial (its id is the pad's, not the socket's) and drops; a
        // serial-less pad of the same model plugged in is someone else's.
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let x = r.add_pad(
            PadInfo {
                port_bound: false,
                ..usb_pad(X1)
            },
            t0(),
        );
        sign_in(&mut r, a, "p1");
        assert_eq!(join(&mut r, x, "p2"), 2);
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        let t = t0();
        r.remove_pad_at(x, t);
        let y = r.add_pad(usb_pad(X2), t);
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "a"), seat(2, "p2", X1)]);
        assert_eq!(held_of(&r), vec![(1, false), (2, true)]);
        assert_eq!(phys_of(&r, y), None);
    }

    #[test]
    fn the_rebind_asserts_the_virtual_pads_acl_again() {
        let (mut r, _a, b, _c) = three_players();
        // pad2's own udev fallback runs: it is ready, with its one-entry ACL.
        r.tick(Instant::now() + Duration::from_secs(10));
        let sysname = r.pads[&b]
            .virt
            .as_ref()
            .map(|v| v.sysname.clone())
            .expect("pad2");
        let node = format!("/dev/input/event-{sysname}");
        assert!(r.pads[&b].virt.as_ref().is_some_and(|v| v.ready));
        let t = t0();
        r.remove_pad_at(b, t);
        // A udev change while the seat is held wipes the ACL (logind's uaccess); nobody answers it.
        r.backend_mut().acls.insert(node.clone(), Vec::new());
        r.backend_mut().take();
        r.add_pad(pad("b"), t);
        let calls = r.backend_mut().take();
        assert!(calls.contains(&Call::WriteAcl(node.clone())), "{calls:?}");
        assert!(acl::is_only_user(&r.backend().acls[&node], P1_UID));
    }

    #[test]
    fn a_like_pad_with_two_held_seats_of_its_model_takes_none() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let x1 = r.add_pad(usb_pad(X1), t0());
        let x2 = r.add_pad(usb_pad(X2), t0());
        sign_in(&mut r, a, "p1");
        join(&mut r, x1, "p2");
        join(&mut r, x2, "p3");
        let t = t0();
        r.remove_pad_at(x1, t);
        r.remove_pad_at(x2, t);
        r.take_notices();
        let y = r.add_pad(usb_pad(X3), t);
        assert_eq!(
            seats_of(&r),
            vec![seat(1, "p1", "a"), seat(2, "p2", X1), seat(3, "p3", X2)]
        );
        assert_eq!(held_of(&r), vec![(1, false), (2, true), (3, true)]);
        let rec = r.devices().into_iter().find(|d| d.id == X3).expect("y");
        assert_eq!(rec.slot, 0, "an unseated pad: RUY-38/122 ask who plays");
        assert!(journal(&mut r).contains(&format!(
            "{X3} is like the pads of 2 held seats: it takes none"
        )));
        // The same ids back still take their own seats.
        let x1b = r.add_pad(usb_pad(X1), t);
        assert_eq!(held_of(&r), vec![(1, false), (2, false), (3, true)]);
        let _ = (y, x1b);
    }

    #[test]
    fn a_move_of_a_held_seat_binds_its_virtual_pad_to_the_new_pad_and_ends_the_hold() {
        let (mut r, _a, b, _c) = three_players();
        let vb = virtual_id(&r, b);
        let d = r.add_pad(pad("d"), t0());
        let t = t0();
        r.remove_pad_at(b, t);
        // d still holds the South that answered "Who's playing?" when the join comes.
        r.input(d, &[press(PadButton::South)]);
        r.backend_mut().take();
        assert_eq!(join(&mut r, d, "p2"), 2);
        assert_eq!(held_of(&r), vec![(1, false), (2, false), (3, false)]);
        assert_eq!(virtual_id(&r, d), vb);
        let calls = r.backend_mut().take();
        assert!(created(&calls).is_empty() && destroyed(&calls).is_empty());
        assert!(
            writes(&calls).is_empty(),
            "the held South is masked: {calls:?}"
        );
        // East reaches pad2 at once; South only once it was let go and pressed again.
        let vb = vb.expect("b had pad2");
        r.input(d, &[press(PadButton::East)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(vb, vec![(code::EV_KEY, code::BTN_EAST, 1)])]
        );
        r.input(d, &[release(PadButton::South)]);
        r.input(d, &[press(PadButton::South)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(vb, vec![(code::EV_KEY, code::BTN_SOUTH, 1)])]
        );
        // b back now is an unseated pad, and the old deadline frees nothing.
        let b2 = r.add_pad(pad("b"), t);
        assert_eq!(phys_of(&r, b2), None);
        r.tick(t + Duration::from_secs(61));
        assert_eq!(seats_of(&r)[1], seat(2, "p2", "d"));
        assert!(destroyed(&r.backend_mut().take()).is_empty());
    }

    #[test]
    fn a_leave_of_a_held_seat_destroys_its_virtual_pad() {
        let (mut r, _a, b, _c) = three_players();
        let vb = virtual_id(&r, b).expect("pad2");
        r.remove_pad_at(b, t0());
        r.backend_mut().take();
        assert_eq!(r.leave_player(2, t0()), Status::Ok);
        assert_eq!(destroyed(&r.backend_mut().take()), vec![vb]);
        let b2 = r.add_pad(pad("b"), t0());
        assert_eq!(phys_of(&r, b2), None);
    }

    #[test]
    fn lock_during_a_hold_clears_it_and_destroys_the_held_virtual_pads() {
        let (mut r, a, b, _c) = three_players();
        let t = t0();
        r.remove_pad_at(b, t);
        r.remove_pad_at(a, t);
        r.backend_mut().take();
        r.set_route("locked", "", "", "", SHELL, t);
        assert!(r.players().is_empty());
        assert!(r.holds.is_empty(), "the holds end with the seats");
        let mut gone = destroyed(&r.backend_mut().take());
        gone.sort_unstable();
        assert_eq!(gone, vec![1, 2, 3], "the held pad1 and pad2 and c's pad3");
        // p1 again: the pads that come back are not seated.
        let a2 = r.add_pad(pad("a"), t);
        let b2 = r.add_pad(pad("b"), t);
        signed_in(&mut r, "p1");
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "")]);
        app(&mut r, "i2", STK, "p1");
        settle(&mut r);
        assert!(created(&r.backend_mut().take()).is_empty());
        let _ = (a2, b2);
    }

    #[test]
    fn a_hold_without_a_virtual_pad_gets_one_when_the_pad_is_back_in_the_app() {
        // The pad went in the shell: no virtual pad to keep; back in the app it is made with its seat.
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        join(&mut r, b, "p2");
        let t = t0();
        r.remove_pad_at(b, t);
        assert_eq!(held_of(&r), vec![(1, false), (2, true)]);
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        assert_eq!(created(&r.backend_mut().take()).len(), 1, "pad1 only");
        let b2 = r.add_pad(pad("b"), t);
        assert_eq!(phys_of(&r, b2).as_deref(), Some("ruya-input/pad2"));
    }

    #[test]
    fn rumble_after_the_rebind_reaches_the_new_pad() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        let strong = Rumble {
            strong: 40000,
            weak: 20000,
            length_ms: 500,
            delay_ms: 0,
        };
        let soft = Rumble {
            strong: 1000,
            ..strong
        };
        assert_eq!(r.ff_upload(1, 0, &strong), Ok(()));
        r.ff_play(1, 0, 1);
        r.backend_mut().take();
        let t = t0();
        r.remove_pad_at(a, t);
        let calls = r.backend_mut().take();
        assert!(
            !calls
                .iter()
                .any(|c| matches!(c, Call::FfPlay(..) | Call::FfErase(..))),
            "nothing goes to the gone pad: {calls:?}"
        );
        // While the pad is gone the game uploads another effect and plays: kept, nothing sent.
        assert_eq!(r.ff_upload(1, 1, &soft), Ok(()));
        r.ff_play(1, 1, 1);
        assert!(r.backend_mut().take().is_empty());
        // Back: both effects are uploaded to the new pad, and a play reaches it.
        let a2 = r.add_pad(pad("a"), t + Duration::from_secs(5));
        let uploads: Vec<Call> = r
            .backend_mut()
            .take()
            .into_iter()
            .filter(|c| matches!(c, Call::FfUpload(..)))
            .collect();
        assert_eq!(
            uploads,
            vec![Call::FfUpload(a2, -1, strong), Call::FfUpload(a2, -1, soft)]
        );
        r.ff_play(1, 0, 1);
        assert_eq!(r.backend_mut().take(), vec![Call::FfPlay(a2, 2, 1)]);
    }

    #[test]
    fn twin_connections_of_one_seated_id_give_the_seat_to_one_of_them() {
        // RUY-642: two connections with one stable id (two serial-less pads in one socket path).
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b1 = r.add_pad(pad("b"), t0());
        let b2 = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        assert_eq!(join(&mut r, b1, "p2"), 2);
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        assert_eq!(phys_of(&r, b1).as_deref(), Some("ruya-input/pad2"));
        assert_eq!(phys_of(&r, b2), None, "one pad2 only");
        let slots: Vec<u32> = r
            .devices()
            .into_iter()
            .filter(|d| d.id == "b")
            .map(|d| d.slot)
            .collect();
        assert_eq!(slots, vec![2, 0]);
        // The seat's connection goes: the twin is the seat's pad now, on the same pad2, no hold.
        let vb = virtual_id(&r, b1);
        r.backend_mut().take();
        r.remove_pad_at(b1, t0());
        assert_eq!(virtual_id(&r, b2), vb);
        assert_eq!(held_of(&r), vec![(1, false), (2, false)]);
        let calls = r.backend_mut().take();
        assert!(created(&calls).is_empty() && destroyed(&calls).is_empty());
        // With the gate off the other twin is an unseated pad after the seats.
        let mut r = gated(false);
        let a = r.add_pad(pad("a"), t0());
        let b1 = r.add_pad(pad("b"), t0());
        let b2 = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        join(&mut r, b1, "p2");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        assert_eq!(phys_of(&r, b1).as_deref(), Some("ruya-input/pad2"));
        assert_eq!(phys_of(&r, b2).as_deref(), Some("ruya-input/pad5"));
    }

    #[test]
    fn with_the_seat_gate_off_a_held_seat_keeps_its_number_from_unseated_pads() {
        let mut r = gated(false);
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        join(&mut r, b, "p2");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        let t = t0();
        r.remove_pad_at(b, t);
        // An unseated pad that connects during the hold is pad5, not the held pad2.
        let c = r.add_pad(pad("c"), t);
        assert_eq!(phys_of(&r, c).as_deref(), Some("ruya-input/pad5"));
        // An unseated pad that vanishes loses its virtual pad at once: it holds no seat.
        let vc = virtual_id(&r, c).expect("pad5");
        r.backend_mut().take();
        r.remove_pad_at(c, t);
        assert_eq!(destroyed(&r.backend_mut().take()), vec![vc]);
        let b2 = r.add_pad(pad("b"), t);
        assert_eq!(phys_of(&r, b2).as_deref(), Some("ruya-input/pad2"));
    }

    #[test]
    fn the_hold_is_60_s_and_the_test_setting_shortens_it() {
        assert_eq!(SEAT_HOLD, Duration::from_secs(60));
        assert_eq!(seat_hold_from_env(None), None);
        assert_eq!(seat_hold_from_env(Some("")), None);
        assert_eq!(seat_hold_from_env(Some("0")), None);
        assert_eq!(seat_hold_from_env(Some("-5")), None);
        assert_eq!(seat_hold_from_env(Some("abc")), None);
        assert_eq!(
            seat_hold_from_env(Some(" 5 ")),
            Some(Duration::from_secs(5))
        );
        let (mut r, _a, b, _c) = three_players();
        r.set_seat_hold(Duration::from_secs(5));
        let t = t0();
        r.remove_pad_at(b, t);
        r.tick(t + Duration::from_secs(5));
        assert_eq!(seats_of(&r).len(), 2, "seat 2 is free after 5 s");
    }

    #[test]
    fn the_journal_names_players_by_id_only() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        tap(&mut r, a);
        r.take_notices();
        r.set_route("shell", "", "", "p1", SHELL, t0());
        let player = |r: &mut Router<Fake>| -> Vec<String> {
            journal(r)
                .into_iter()
                .filter(|l| l.starts_with("player "))
                .collect()
        };
        assert_eq!(player(&mut r), vec!["player 1 is ruya-p1 on a"]);
        join(&mut r, b, "p2");
        assert_eq!(player(&mut r), vec!["player 2 is ruya-p2 on b"]);
        r.leave_player(2, t0());
        assert_eq!(player(&mut r), vec!["player 2 left"]);
        r.set_route("locked", "", "", "", SHELL, t0());
        assert_eq!(player(&mut r), vec!["player 1 left"]);
    }

    // ---- the seat gate off (SEAT_GATE until RUY-122; RUY-121 round 2) ----------------------

    fn virtual_id(r: &Router<Fake>, key: PadKey) -> Option<VirtualId> {
        r.pads[&key].virt.as_ref().map(|v| v.id)
    }

    #[test]
    fn with_the_seat_gate_off_an_unseated_pad_still_gets_a_virtual_pad_after_the_seats() {
        let mut r = gated(false);
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        // b signs in, so the seated b is pad1 and the unseated a follows it, after the seats.
        sign_in(&mut r, b, "p1");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        let creations: Vec<(PadKey, String)> = r
            .backend_mut()
            .take()
            .iter()
            .filter_map(|c| match c {
                Call::Create(k, s) => Some((*k, s.phys.clone())),
                _ => None,
            })
            .collect();
        assert_eq!(
            creations,
            vec![
                (b, "ruya-input/pad1".to_owned()),
                (a, "ruya-input/pad5".to_owned())
            ]
        );
        // The seats are the same as with the gate on: a is not a player.
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "b")]);
        let rec = r.devices().into_iter().find(|d| d.id == "a").expect("a");
        assert_eq!((rec.slot, rec.profile.as_str()), (0, ""));
        // Its input reaches its own virtual pad.
        r.input(a, &[press(PadButton::South)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(2, vec![(code::EV_KEY, code::BTN_SOUTH, 1)])]
        );
        // A pad connected while the app is in front gets the next free number at once.
        let c = r.add_pad(pad("c"), t0());
        assert_eq!(phys_of(&r, c).as_deref(), Some("ruya-input/pad6"));
    }

    #[test]
    fn with_the_seat_gate_off_a_join_renumbers_nobody_alive() {
        let mut r = gated(false);
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        let c = r.add_pad(pad("c"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        assert_eq!(phys_of(&r, b).as_deref(), Some("ruya-input/pad5"));
        assert_eq!(phys_of(&r, c).as_deref(), Some("ruya-input/pad6"));
        let (va, vb) = (virtual_id(&r, a), virtual_id(&r, b));
        r.backend_mut().take();
        // c joins: it becomes pad2 (its own pad is replaced); a and b keep their devices.
        assert_eq!(join(&mut r, c, "p2"), 2);
        assert_eq!(phys_of(&r, c).as_deref(), Some("ruya-input/pad2"));
        assert_eq!((virtual_id(&r, a), virtual_id(&r, b)), (va, vb));
        assert_eq!(destroyed(&r.backend_mut().take()).len(), 1, "only c's pad6");
        // c leaves: pad2 goes and c is an unseated pad again, after the seats; b is untouched.
        assert_eq!(r.leave_player(2, t0()), Status::Ok);
        assert_eq!(phys_of(&r, c).as_deref(), Some("ruya-input/pad6"));
        assert_eq!((virtual_id(&r, a), virtual_id(&r, b)), (va, vb));
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "a")]);
    }

    #[test]
    fn the_image_runs_with_the_seat_gate_off_until_ruy_122() {
        // Lead decision (RUY-121 round 2): with the production value an unseated pad still reaches
        // the game, so local co-op keeps every pad until the prompt (RUY-122) can seat one.
        let mut r = gated(SEAT_GATE);
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        assert_eq!(phys_of(&r, a).as_deref(), Some("ruya-input/pad1"));
        assert_eq!(phys_of(&r, b).as_deref(), Some("ruya-input/pad5"));
    }
}
