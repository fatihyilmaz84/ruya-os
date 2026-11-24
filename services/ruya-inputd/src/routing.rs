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
//!   When the hold runs out the seat is freed (seat 1 keeps its profile without a pad).
//! - A virtual pad keeps its number for its owner's whole life (RUY-681): a seat without a pad
//!   leaves it quiet (`idle`), the next pad seated in that number binds it (the same player or
//!   another), and only `LeavePlayer` of that number or the owner's end destroys it. A joining
//!   player takes the free seat of their own quiet pad, else one the game has no pad for.
//! - Virtual pads (one per seated pad, phys `ruya-input/pad<n>`) exist only while the route is
//!   `app` or `overlay` over the same app instance and profile, frozen or not (a Freeze by the Hub
//!   keeps them, RUY-541), and the `app` that follows it keeps the same devices. Any other route,
//!   another instance or another profile destroys them (lock, switch, run end, an overlay that
//!   names no app): a descriptor the app opened reads `ENODEV`, so nothing reaches it afterwards
//!   (an ACL change would not close it).
//! - `PreparePads` (RUY-837) makes them before the game starts, with no route change, for a game
//!   that opens its pad once at start-up: they wait, neutral, through `shell` and `overlay` of the
//!   profile, and the first `app` or `overlay` with that app id and profile binds them to its
//!   instance. `locked`, a profile change, `app` for another app, another preparation or
//!   `PREPARE_TTL` without that route destroy them. Its answer (`PadsPrepared`) waits until each
//!   pad is ready (ACL set) or its udev fallback ran.
//! - `overlay` over the pads' instance holds them in neutral (once); no input reaches them.
//! - Entering `app` for a new owner, every seated pad's virtual pad is made at once (RUY-681), pad1
//!   (the profile's active controller) first; the others' first ACL waits until pad1's ACL is set
//!   or its udev fallback ran, so pad1 is the first pad an app can open (RUY-541); a pad that
//!   arrives while pad1 waits waits too.
//! - Entering `app`, a button or axis already held is not forwarded until it is let go (no
//!   double input from the press that closed the overlay); leaving `shell`, every navigation key
//!   but Guide is released.
//! - A virtual pad's node gets one ACL entry, for the profile's user, after every udev event on
//!   it (logind's uaccess flushes it on a `change`), and is announced (`routed`) only then.
//! - The caller that set the route leaving the bus means `locked`.
//! - `/dev/uinput` names the signed-in profile's user only, nobody without one (RUY-1063,
//!   `origin`); its ACL is set again after every udev event on it. A device another process made
//!   there (foreign: parentless, not marked as ours or root's) is never read; its node names its
//!   profile's user while that profile is signed in, nobody otherwise.
//! - A virtual pad shows what the profile that applies to its pad makes of the physical pad
//!   (`engine`, 06 §7): the console profile's global profile when its `match` fits, else the
//!   built-in default. The pad of seat n uses the seated player's own profiles (RUY-643; a guest
//!   has none: the defaults). A change to a seated player's profiles applies at once, to that
//!   player's pads only.

use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

use crate::accounts::Accounts;
use crate::acl;
use crate::activity::ActivityGate;
use crate::book::{Book, SaveAnswer, Summary};
use crate::caps::Capability;
use crate::engine::Engine;
use crate::mapping::{Axis, Button, Confirm, KeyBoard, KeyEvent, Mapper, NavKey};
use crate::origin::{self, Foreign, Origin, UINPUT_NODE};
use crate::owners::Owners;
use crate::pad::{
    diff, OutEvent, PadAxis, PadButton, PadInput, PadState, Rumble, TestEvent, ALL_AXES,
    PAD_PHYS_PREFIX, STICK_MAX, STICK_MIN, TRIGGER_MAX,
};
use crate::seats::{Joined, Player, Seats, SEATS};
use crate::udev::UdevEvent;
use ruya_flatpak::valid_session_app_id;
use ruya_ids::{user_of, valid_profile_id};

pub type PadKey = u64;
pub type VirtualId = u64;

/// When no udev event arrives for a new virtual pad (the monitor is not working), the ACL is set
/// this long after creation anyway, and the journal says so.
pub const UDEV_FALLBACK: Duration = Duration::from_secs(2);

/// How long a seat waits for its pad when the pad disconnects (RUY-627, ADR-017 point 9).
pub const SEAT_HOLD: Duration = Duration::from_secs(60);

/// How long pads made by `PreparePads` wait for the game's route (RUY-837): longer than a slow
/// start (the shell's splash says "still starting" after 20 s), short enough that a launch that
/// failed leaves nothing for long.
pub const PREPARE_TTL: Duration = Duration::from_secs(60);

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
    /// The profile that last played on this pad ("" when none, or its account is gone; RUY-124).
    pub owner: String,
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
    /// The preparation of `PreparePads` for `app_id` and `profile` is over (RUY-837): its pads
    /// are ready (`Ok`), one could not get its ACL (`Failed`), or it ended before (`NotAllowed`).
    /// The bus answers the waiting `PreparePads` calls with it; it is no signal.
    PadsPrepared {
        app_id: String,
        profile: String,
        status: Status,
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
    /// The service made the input device `sysname` (`input23`) and it still exists: its origin
    /// marker is there (`origin`, `marks`).
    fn is_own(&mut self, sysname: &str) -> bool;
    /// `sysname` is the "RuyaOS Navigation" keyboard.
    fn is_nav(&mut self, sysname: &str) -> bool;
    /// Destroys the navigation keyboard (its marker first) and makes it again; the new sysname.
    fn renew_nav(&mut self) -> Result<String, String>;
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
    fn is_own(&mut self, _: &str) -> bool {
        false
    }
    fn is_nav(&mut self, _: &str) -> bool {
        false
    }
    fn renew_nav(&mut self) -> Result<String, String> {
        Err("no uinput in --session".into())
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
    /// Its first ACL waits for pad1 (RUY-541, RUY-681): the node and the reason it was due for.
    acl_due: Option<(String, String)>,
    /// What the virtual pad shows now.
    sent: PadState,
    /// Held when the route entered `app`: not forwarded until let go.
    masked_buttons: Vec<PadButton>,
    masked_axes: Vec<PadAxis>,
    /// The first input forwarded since the route entered `app` was journalled (`mask_held`
    /// starts a route entry, so a new route and a Thaw reset it together with the mask).
    first_input_logged: bool,
    /// The app's effect id -> the physical pad's.
    ff: BTreeMap<i16, i16>,
    /// The app's effects as it uploaded them: uploaded again to the pad it is bound to (RUY-627).
    effects: BTreeMap<i16, Rumble>,
    playing: BTreeSet<i16>,
    /// The profile that applies to this pad, compiled.
    engine: Engine,
    /// The physical pad has no left stick: its D-pad also moves the virtual left stick
    /// (RUY-832), so a game that steers with the stick can be played with it.
    mirror_dpad: bool,
}

/// Pads made before the game starts (`PreparePads`, RUY-837): the owner's instance is "" until
/// the first `SetRoute` "app" or "overlay" with this app id and the owner's profile binds them.
#[derive(Debug)]
struct Prepared {
    app_id: String,
    until: Instant,
    /// `PadsPrepared` was announced for this preparation.
    answered: bool,
}

/// A held game's virtual pads, set aside while a preparation for another game runs (RUY-840): the
/// same devices come back if the new game never takes the pads.
#[derive(Debug)]
struct Stash {
    owner: Owner,
    pads: BTreeMap<PadKey, Virtual>,
    idle: BTreeMap<u32, Virtual>,
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

/// Whether the pad's probe found no left stick (`ABS_X`/`ABS_Y`, `caps` "sticks"). A pad whose
/// descriptor does not say is taken to have one.
fn lacks_stick(info: &PadInfo) -> bool {
    info.capabilities
        .iter()
        .find(|c| c.name == "sticks")
        .is_some_and(|c| !c.driver)
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
        if self.mirror_dpad {
            let axis = |neg: PadButton, pos: PadButton| match (out.pressed(neg), out.pressed(pos)) {
                (true, false) => STICK_MIN,
                (false, true) => STICK_MAX,
                _ => 0,
            };
            let x = axis(PadButton::DpadLeft, PadButton::DpadRight);
            let y = axis(PadButton::DpadUp, PadButton::DpadDown);
            out.apply(PadInput::Axis(PadAxis::LeftX, x));
            out.apply(PadInput::Axis(PadAxis::LeftY, y));
        }
        out
    }

    fn mask_held(&mut self, state: &PadState) {
        self.masked_buttons = state.buttons().to_vec();
        self.masked_axes = ALL_AXES
            .into_iter()
            .filter(|&a| axis_held(a, state.axis(a)))
            .collect();
        self.first_input_logged = false;
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
    /// When the route last entered `app` (a new route or a Thaw), for the first-input journal line.
    app_entered: Option<Instant>,
    instance: String,
    app_id: String,
    profile: String,
    /// The bus name that set the route.
    caller: Option<String>,
    owner: Option<Owner>,
    /// The owner's pads were made by `PreparePads` and no route has bound them yet (RUY-837).
    prepared: Option<Prepared>,
    /// The held game's pads while `prepared` runs for another game (RUY-840).
    stash: Option<Stash>,
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
    /// The owner's virtual pads whose seat has no pad now, by number (RUY-681): a hold ran out, or
    /// the seat's pad was unseated. They stay, quiet, until the seat gets a pad again (bound to it),
    /// its player leaves (`LeavePlayer`) or the owner ends (the game's run).
    idle: BTreeMap<u32, Virtual>,
    /// The held seats' leftovers, by the gone pad's stable id: an entry exactly while
    /// `seats.is_held` says so (RUY-627).
    holds: BTreeMap<String, Parked>,
    /// `SEAT_HOLD`, or what `RUYA_SEAT_HOLD_SECS` set.
    seat_hold: Duration,
    /// `SetNavigator` (RUY-38): the stable id of the only pad that navigates, and the bus name
    /// that set it (it is cleared when that name leaves the bus).
    navigator: Option<(String, String)>,
    /// The last non-guest profile seated on each pad (RUY-124).
    owners: Owners,
    /// Who holds `/dev/uinput` and the foreign devices made through it (RUY-1063).
    foreign: Foreign,
    /// How often the navigation keyboard was made again since start (`NAV_RENEWALS` at most).
    nav_renewals: u32,
}

/// The navigation keyboard is made again at most this often per start: udev that never sees its
/// marker would otherwise have it made and destroyed without end (RUY-1063 review).
pub const NAV_RENEWALS: u32 = 1;

/// An unseated pad's `ForeignInput` "press" is sent at most once per pad in this time (06 §11.3).
pub const FOREIGN_PRESS_GAP: Duration = Duration::from_secs(1);

impl<B: Backend> Router<B> {
    /// Starts in `shell` with no profile: navigation keys, no virtual pad (as before Input1). Only
    /// a seated pad ever gets a virtual pad (the seat gate, on since "Who's playing?", RUY-122).
    pub fn new(backend: B, accounts: Box<dyn Accounts>) -> Self {
        Router {
            backend,
            accounts,
            route: Route::Shell,
            app_entered: None,
            instance: String::new(),
            app_id: String::new(),
            profile: String::new(),
            caller: None,
            owner: None,
            prepared: None,
            stash: None,
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
            idle: BTreeMap::new(),
            holds: BTreeMap::new(),
            seat_hold: SEAT_HOLD,
            navigator: None,
            owners: Owners::in_memory(),
            foreign: Foreign::default(),
            nav_renewals: 0,
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

    /// Where the pads' owners are kept (in memory until this is called).
    pub fn set_owners(&mut self, owners: Owners) {
        self.owners = owners;
        self.drain_owners();
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
            owner: self.owner_of(&pad.info.id),
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
        // one gets it now.
        self.make_missing(now);
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
        // A held game's stashed pad of this pad goes with it (RUY-840).
        if let Some(v) = self.stash.as_mut().and_then(|s| s.pads.remove(&key)) {
            self.drop_virtual(key, v);
        }
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
        // A pad1 that went before it was ready holds no other pad's ACL back.
        self.release_acls();
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
                // The first input that reaches the game per pad and route entry: when, never what
                // (no button or axis: not a key logger).
                if !v.first_input_logged {
                    v.first_input_logged = true;
                    let ms = self
                        .app_entered
                        .map_or(0, |t| now.saturating_duration_since(t).as_millis());
                    let instance = self.owner.as_ref().map_or("", |o| o.instance.as_str());
                    let line = format!(
                        "first input forwarded to pad{} (instance {instance}, {ms} ms after the route)",
                        v.n
                    );
                    self.notices.push(Notice::Journal(line));
                }
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
        // The number is the pad's seat: pad1 is player 1 (RUY-121). An unseated pad gets none.
        let Some((n, player)) = self.seat_number(key) else {
            return;
        };
        // The seat's number already has a device in this game (RUY-681): the pad takes it over, so
        // the game sees no new pad.
        if let Some(v) = self.idle.remove(&n) {
            self.bind(key, v);
            return;
        }
        let spec = VirtualSpec {
            phys: format!("{PAD_PHYS_PREFIX}{n}"),
            rumble: pad.info.rumble,
        };
        let pad_id = pad.info.id.clone();
        let family = pad.info.family.clone();
        let mirror_dpad = lacks_stick(&pad.info);
        // The seated player's own controller profiles (RUY-643); a guest has none: the defaults.
        let engine = self.book.engine_for(&player, &family, &pad_id);
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
                    acl_due: None,
                    sent: PadState::default(),
                    masked_buttons: Vec::new(),
                    masked_axes: Vec::new(),
                    first_input_logged: false,
                    ff: BTreeMap::new(),
                    effects: BTreeMap::new(),
                    playing: BTreeSet::new(),
                    engine,
                    mirror_dpad,
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

    /// A preparation for another game starts while a game of this profile is held (frozen behind
    /// Home): its virtual pads are set aside, not destroyed, so a failed launch gives them back
    /// (RUY-840). Held seats' parked pads are destroyed as before.
    fn stash_owner_pads(&mut self) {
        let Some(owner) = self.owner.clone() else {
            return;
        };
        let pads: BTreeMap<PadKey, Virtual> = self
            .pads
            .iter_mut()
            .filter_map(|(&k, p)| p.virt.take().map(|v| (k, v)))
            .collect();
        let idle = std::mem::take(&mut self.idle);
        self.journal(format!(
            "pads of instance '{}' set aside for the next game",
            owner.instance
        ));
        // Game B runs under the same uid: it must not be able to open the older pads (RUY-840).
        let sysnames: Vec<String> = pads
            .values()
            .chain(idle.values())
            .map(|v| v.sysname.clone())
            .collect();
        self.set_stash_acls(&sysnames, &acl::closed());
        self.stash = Some(Stash { owner, pads, idle });
    }

    /// Writes `acl` on the nodes of the stashed virtual pads (those that have one).
    fn set_stash_acls(&mut self, sysnames: &[String], acl: &[u8]) {
        for sysname in sysnames {
            if let Some(node) = self.backend.node_of(sysname) {
                if let Err(err) = self.backend.write_acl(&node, acl) {
                    self.journal(format!(
                        "setting the ACL of {sysname} ({node}) failed: {err}"
                    ));
                }
            }
        }
    }

    /// Ends the stash: its pads are destroyed.
    fn drop_stash(&mut self) {
        if let Some(st) = self.stash.take() {
            for (key, v) in st.pads {
                self.drop_virtual(key, v);
            }
            for (_, v) in st.idle {
                self.drop_virtual(0, v);
            }
        }
    }

    /// A preparation ends without a game taking the pads: the held game gets its pads back if it
    /// is still the one held behind Home (`overlay` with its instance), else they go (it exited).
    fn end_stash(&mut self, why: &str) {
        let held = self.stash.as_ref().is_some_and(|s| {
            self.route == Route::Overlay
                && self.instance == s.owner.instance
                && self.profile == s.owner.profile
        });
        if held {
            self.restore_stash(why);
        } else {
            self.destroy_all();
        }
    }

    /// The new game did not take the pads: its prepared pads go and the held game's come back,
    /// the same virtual devices (RUY-840). A pad that is gone or whose seat changed meanwhile
    /// loses its stashed pad; the route's `make_missing` makes a new one.
    fn restore_stash(&mut self, why: &str) {
        let Some(st) = self.stash.take() else {
            return;
        };
        self.destroy_all();
        let mut back = Vec::new();
        let sysnames: Vec<String> = st
            .pads
            .values()
            .chain(st.idle.values())
            .map(|v| v.sysname.clone())
            .collect();
        self.set_stash_acls(&sysnames, &acl::only_user(st.owner.uid));
        for (key, v) in st.pads {
            let fits = self.pads.get(&key).is_some_and(|p| p.virt.is_none())
                && self
                    .seat_number(key)
                    .is_some_and(|(n, p)| (v.n, v.player.as_str()) == (n, p.as_str()));
            if fits {
                back.push((key, v));
            } else {
                self.drop_virtual(key, v);
            }
        }
        for (key, v) in back {
            if let Some(p) = self.pads.get_mut(&key) {
                p.virt = Some(v);
            }
        }
        self.idle = st.idle;
        self.journal(format!(
            "pads of instance '{}' are the game's again: {why}",
            st.owner.instance
        ));
        self.owner = Some(st.owner);
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
        // The quiet pads of the game go with it (RUY-681).
        for (_, v) in std::mem::take(&mut self.idle) {
            self.drop_virtual(0, v);
        }
        // So do the pads a preparation set aside (RUY-840).
        self.drop_stash();
        // A preparation still waited on ends unready (RUY-837).
        if let (Some(p), Some(o)) = (self.prepared.take(), self.owner.as_ref()) {
            if !p.answered {
                self.notices.push(Notice::PadsPrepared {
                    app_id: p.app_id,
                    profile: o.profile.clone(),
                    status: Status::NotAllowed,
                });
            }
        }
        self.owner = None;
    }

    /// Pad1 exists and an app cannot open it yet: its ACL is not set and its udev fallback has not
    /// run. The other pads' first ACL waits meanwhile, so a game that opens the first pad it is
    /// offered (SDL hot-plug, one pad) gets pad1 and not one whose ACL happened to be set first
    /// (RUY-541).
    fn pad1_settling(&self) -> bool {
        self.pads.values().any(|p| {
            p.virt
                .as_ref()
                .is_some_and(|v| v.n == 1 && !v.ready && !v.fallback_tried)
        })
    }

    /// Makes the virtual pad of every seated pad that has none, at once, by seat: player 1's pad
    /// (the profile's active controller) first, so it is pad1 (RUY-540, RUY-121, RUY-681). Only
    /// under `app` with an owner, or for a preparation (`PreparePads`, RUY-837); the ACLs of the
    /// others wait for pad1 (`assert_acl`).
    fn make_missing(&mut self, now: Instant) {
        if (self.route != Route::App && self.prepared.is_none()) || self.owner.is_none() {
            return;
        }
        let missing: Vec<PadKey> = self
            .pads
            .iter()
            .filter(|(_, p)| p.virt.is_none())
            .map(|(&k, _)| k)
            .collect();
        let mut keys: Vec<(u32, PadKey)> = missing
            .into_iter()
            .filter_map(|k| self.seat_number(k).map(|(n, _)| (n, k)))
            .collect();
        keys.sort_unstable();
        for (_, key) in keys {
            if self.pads.get(&key).is_some_and(|p| p.virt.is_none()) {
                self.create_virtual(key, now);
            }
        }
        self.release_acls();
    }

    /// Sets the ACLs that waited for pad1 (in seat order), once pad1 does not hold them back: its
    /// ACL is set, its udev fallback ran, or there is no pad1 that waits.
    fn release_acls(&mut self) {
        if self.pad1_settling() {
            return;
        }
        let mut due: Vec<(u32, PadKey, String, String)> = self
            .pads
            .iter_mut()
            .filter_map(|(&k, p)| {
                let v = p.virt.as_mut()?;
                let (node, why) = v.acl_due.take()?;
                Some((v.n, k, node, why))
            })
            .collect();
        due.sort_unstable();
        for (_, key, node, why) in due {
            self.assert_acl(key, &node, &why);
        }
    }

    /// After a change of the seats: a pad that lost its seat, or whose seat is another number or
    /// player now, loses its virtual pad; a pad that has a seat now takes that seat number's
    /// virtual pad if the game has one (a move, a held seat moved: RUY-627; a seat whose pad went
    /// or a new player in it: RUY-681), so the app keeps the device; the rest stay quiet (`idle`)
    /// while the owner lasts, else they are destroyed. Under `app` every seated pad still without
    /// one gets it. Under `overlay` they wait for the next `app`.
    fn sync_virtuals(&mut self, now: Instant) {
        self.sync_virtuals_with(now, Vec::new());
    }

    /// `sync_virtuals` with virtual pads that have lost their pad already (`spare`, each with the
    /// key of the pad it had, its rumble effects there dropped).
    fn sync_virtuals_with(&mut self, now: Instant, mut spare: Vec<(PadKey, Virtual)>) {
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
            let Some(pad) = self.pads.get_mut(&key) else {
                continue;
            };
            // Stale: another seat or player, or unseated. Nobody else is renumbered.
            let stale = pad.virt.as_ref().is_some_and(|v| match seat {
                Some((n, p)) => (v.n, v.player.as_str()) != (*n, p.as_str()),
                None => true,
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
        // A pad that has a seat and no virtual pad takes the one of the seat's number (RUY-681: also
        // when another player sits there now; the engine is compiled for that player).
        for &key in &keys {
            let Some((n, _)) = &seats[&key] else {
                continue;
            };
            if self.pads.get(&key).map_or(true, |p| p.virt.is_some()) {
                continue;
            }
            if let Some(i) = spare.iter().position(|(_, v)| v.n == *n) {
                let (_, v) = spare.remove(i);
                self.bind(key, v);
            } else if let Some(v) = self.idle.remove(n) {
                self.bind(key, v);
            }
        }
        // The rest go quiet for the game's life (RUY-681: a game may not survive a pad that goes and
        // comes back), or are destroyed when there is no game.
        for (key, v) in spare {
            self.park(key, v);
        }
        self.make_missing(now);
    }

    /// A virtual pad whose seat has no pad now: kept quiet (one neutral frame, no rumble) under
    /// the owner it was made for, by its number, so the game keeps the device (RUY-681); with no
    /// owner it is destroyed.
    fn park(&mut self, key: PadKey, mut v: Virtual) {
        if self.owner.is_none() {
            self.drop_virtual(key, v);
            return;
        }
        for physical in std::mem::take(&mut v.ff).into_values() {
            self.backend.ff_erase(key, physical);
        }
        v.playing.clear();
        self.neutral(&mut v);
        self.journal(format!(
            "virtual pad {} stays quiet: its seat has no pad",
            v.phys
        ));
        if let Some(old) = self.idle.insert(v.n, v) {
            self.drop_virtual(0, old);
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
            // The seat's player, else the route owner (RUY-643); the seat's player owns it now.
            let who = self.seat_number(key).map_or(owner.profile, |(_, p)| p);
            v.engine = self.book.engine_for(&who, &family, &pad_id);
            self.drain_book();
            v.player = who;
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
    /// without a pad, and their virtual pads stay quiet for the game's life (RUY-681).
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
        // The first ACL of pad2-4 waits while pad1 cannot be opened yet (RUY-541, RUY-681).
        let first = self
            .pads
            .get(&key)
            .and_then(|p| p.virt.as_ref())
            .is_some_and(|v| v.n != 1 && !v.ready);
        if first && self.pad1_settling() {
            if let Some(v) = self.pads.get_mut(&key).and_then(|p| p.virt.as_mut()) {
                v.acl_due = Some((node.to_owned(), why.to_owned()));
            }
            return;
        }
        let result = self.ensure_acl(node, &acl::only_user(owner.uid));
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
            Ok(_) if !was_ready => {
                self.journal(format!(
                    "virtual pad {phys} ready for ruya-{} ({node}, {why})",
                    owner.profile
                ));
                self.changed(key);
            }
            Ok(true) => {
                self.journal(format!("ACL of {phys} ({node}) re-asserted after {why}"));
            }
            Ok(false) => {}
        }
    }

    /// Gives `node` the ACL `want` unless it has exactly that already: `Ok(true)` when it wrote.
    fn ensure_acl(&mut self, node: &str, want: &[u8]) -> Result<bool, String> {
        let current = self.backend.read_acl(node);
        if current.as_deref().is_some_and(|a| acl::matches(a, want)) {
            return Ok(false);
        }
        self.backend.write_acl(node, want).map(|()| true)
    }

    // ---- /dev/uinput and the devices made through it (06 section 3 rule 1, RUY-1063) ---------

    /// Gives `/dev/uinput` its ACL: the signed-in profile's user only, nobody while nobody is
    /// signed in. At start, after each profile change and after each udev event on the node (udev
    /// sets its mode again, which masks the entry).
    pub fn assert_uinput(&mut self, why: &str) {
        let want = self.foreign.uinput_acl();
        let holder = match self.foreign.holder() {
            "" => "nobody (closed)".to_owned(),
            p => user_of(p),
        };
        match self.ensure_acl(UINPUT_NODE, &want) {
            Ok(true) => self.journal(format!("{UINPUT_NODE} for {holder} ({why})")),
            Ok(false) => {}
            Err(err) => self.journal(format!(
                "setting the ACL of {UINPUT_NODE} for {holder} failed ({why}): {err}"
            )),
        }
    }

    /// A udev event on a foreign device (parentless, unmarked: a pad, keyboard or mouse a profile
    /// made): its ACL, its profile's user while that profile is signed in (`Foreign::seen`). Never
    /// a device the service reads; the udev rules keep it from the shell.
    fn foreign_event(&mut self, sysname: &str, node: &str, why: &str, now: Instant) {
        let new = !self.foreign.knows(sysname);
        let want = self.foreign.seen(sysname, now);
        if new {
            let whose = self
                .foreign
                .attributed(sysname)
                .map_or_else(|| "nobody's: closed".to_owned(), user_of);
            self.journal(format!("foreign device {sysname} ({node}): {whose}"));
        }
        self.write_foreign_acl(sysname, node, &want, why);
    }

    fn write_foreign_acl(&mut self, sysname: &str, node: &str, want: &[u8], why: &str) {
        match self.ensure_acl(node, want) {
            Ok(true) => {
                let whose = if acl::matches(want, &acl::closed()) {
                    "closed".to_owned()
                } else {
                    self.foreign
                        .attributed(sysname)
                        .map_or_else(String::new, user_of)
                };
                self.journal(format!(
                    "ACL of foreign device {sysname} ({node}): {whose} ({why})"
                ));
            }
            Ok(false) => {}
            Err(err) => self.journal(format!(
                "setting the ACL of foreign device {sysname} ({node}) failed: {err}"
            )),
        }
    }

    /// At start: an event node that exists already (`devpath`, its node, udev's
    /// `RUYA_INPUT_ORIGIN`). A foreign one (made before this start; the foreign record went with the
    /// last run) is nobody's and closed now, so it keeps no profile's entry of an earlier run.
    pub fn found_at_start(&mut self, devpath: &str, node: &str, udev_origin: &str) {
        let backend = &mut self.backend;
        if origin::classify(devpath, udev_origin, |s| backend.is_own(s)) != Origin::Foreign {
            return;
        }
        let Some(sysname) = origin::parentless_input(devpath) else {
            return;
        };
        self.foreign.found_at_start(sysname);
        self.journal(format!(
            "foreign device {sysname} ({node}) found at start: nobody's"
        ));
        self.write_foreign_acl(sysname, node, &acl::closed(), "start");
    }

    /// The signed-in profile changed: `/dev/uinput` and every foreign device follow it.
    fn uinput_profile_changed(&mut self, profile: &str, uid: Option<u32>, now: Instant) {
        self.foreign.profile_changed(profile, uid, now);
        self.assert_uinput("the profile changed");
        for (sysname, want) in self.foreign.acls() {
            match self.backend.node_of(&sysname) {
                Some(node) => self.write_foreign_acl(&sysname, &node, &want, "the profile changed"),
                // Gone without a `remove` we heard: nothing to close.
                None => self.foreign.forget(&sysname),
            }
        }
    }

    /// `udev_event_at` with the real clock, for the tests that do not care about time.
    #[cfg(test)]
    pub fn udev_event(&mut self, ev: &UdevEvent) {
        self.udev_event_at(ev, Instant::now());
    }

    /// A processed udev event (the monitor): an `add` or `change` on one of our nodes sets the
    /// ACL again, because logind's uaccess builtin rewrites it on every event. Pad1 ready: the
    /// ACLs that waited for it are set. On `/dev/uinput` its ACL is set again; on a foreign device
    /// (`origin`) its ACL follows its profile; the navigation keyboard that udev processed before
    /// its marker is made again (RUY-1063).
    pub fn udev_event_at(&mut self, ev: &UdevEvent, now: Instant) {
        let why = format!("udev {}", ev.action);
        let processed = matches!(ev.action.as_str(), "add" | "change");
        if ev.is_uinput() {
            if processed {
                self.assert_uinput(&why);
            }
            return;
        }
        if !ev.is_event_node() {
            return;
        }
        let Some(sysname) = ev.parent_sysname() else {
            return;
        };
        if ev.action == "remove" {
            if self.foreign.knows(sysname) {
                self.foreign.forget(sysname);
                self.journal(format!("foreign device {sysname} ({}) gone", ev.devname));
            }
            return;
        }
        if !processed {
            return;
        }
        let key = self.pads.iter().find_map(|(&k, p)| {
            p.virt
                .as_ref()
                .is_some_and(|v| v.sysname == sysname)
                .then_some(k)
        });
        if let Some(key) = key {
            self.assert_acl(key, &ev.devname, &why);
            self.release_acls();
            self.answer_prepared();
            return;
        }
        let backend = &mut self.backend;
        match origin::classify(&ev.devpath, &ev.origin, |s| backend.is_own(s)) {
            // Ours (also when an earlier event, before its marker, made it foreign), or root's
            // (`Trusted`, below): not a foreign device any more.
            Origin::Own => {
                self.foreign.forget(sysname);
                // libinput (the shell) reads a device at its `add` only: a navigation keyboard
                // that udev called foreign then never reaches the shell. A new one gets a new
                // `add`, after its marker. Only on udev's word "foreign": rules without the origin
                // (an older image) say nothing, and nothing is made again then.
                if ev.action == "add" && ev.origin == "foreign" && self.backend.is_nav(sysname) {
                    self.nav_renewals += 1;
                    if self.nav_renewals > NAV_RENEWALS {
                        if self.nav_renewals == NAV_RENEWALS + 1 {
                            self.journal(format!(
                                "udev does not see the origin marker of the navigation keyboard \
                                 {sysname}: not made again (the shell cannot read it)"
                            ));
                        }
                        return;
                    }
                    match self.backend.renew_nav() {
                        Ok(new) => self.journal(format!(
                            "navigation keyboard {sysname} was processed by udev before its marker \
                             (origin '{}'): made again as {new}",
                            ev.origin
                        )),
                        Err(err) => self.journal(format!(
                            "making the navigation keyboard {sysname} again failed: {err}"
                        )),
                    }
                }
            }
            Origin::Foreign => self.foreign_event(sysname, &ev.devname, &why, now),
            Origin::Trusted => self.foreign.forget(sysname),
            Origin::Physical => {}
        }
    }

    /// Timers: a virtual pad with no udev event after `UDEV_FALLBACK` gets its ACL anyway (then
    /// the ACLs that waited for pad1 are set, also when its ACL could not be set); a button test
    /// sends the axis values it held back and ends after `TEST_IDLE` without input.
    pub fn tick(&mut self, now: Instant) {
        self.tick_tests(now);
        self.expire_holds(now);
        self.expire_prepared(now);
        let mut due: Vec<(u32, PadKey, String)> = self
            .pads
            .iter_mut()
            .filter_map(|(&k, p)| {
                let v = p.virt.as_mut()?;
                if v.ready || v.fallback_tried || now.duration_since(v.created) < UDEV_FALLBACK {
                    return None;
                }
                v.fallback_tried = true;
                Some((v.n, k, v.sysname.clone()))
            })
            .collect();
        // By number: pads made together come due together, and pad1's ACL must be set first
        // (RUY-541), whatever the pads' keys.
        due.sort_unstable();
        for (_, key, sysname) in due {
            match self.backend.node_of(&sysname) {
                Some(node) => self.assert_acl(key, &node, "no udev event in 2 s"),
                None => self.journal(format!("virtual pad {sysname} has no event node")),
            }
        }
        self.release_acls();
        self.answer_prepared();
    }

    // ---- pads before the game (RUY-837) -----------------------------------------------------

    /// `Input1.PreparePads(app_id, profile)`: makes the virtual pads of every seated pad for
    /// `profile` now, before the game starts, with no route change. `PadsPrepared` follows once
    /// they are ready (at once when there are none). The next `SetRoute` "app" or "overlay" with
    /// this app id and profile binds them (`apply`).
    pub fn prepare_pads(&mut self, app_id: &str, profile: &str, now: Instant) -> Status {
        if !valid_session_app_id(app_id) {
            return Status::Invalid;
        }
        if !valid_profile_id(profile) {
            return Status::UnknownProfile;
        }
        let Some(uid) = self.accounts.account(profile).map(|a| a.uid) else {
            return Status::UnknownProfile;
        };
        if matches!(self.route, Route::Locked | Route::App) || self.profile != profile {
            return Status::NotAllowed;
        }
        let again = self.prepared.as_ref().is_some_and(|p| p.app_id == app_id)
            && self.owner.as_ref().is_some_and(|o| o.profile == profile);
        if again {
            if let Some(p) = self.prepared.as_mut() {
                p.until = now + PREPARE_TTL;
                p.answered = false;
            }
        } else {
            // A held game (bound owner of this profile) keeps its pads aside meanwhile (RUY-840).
            if self.stash.is_some() {
                self.end_stash("another game is prepared");
            }
            let held = self.prepared.is_none()
                && self
                    .owner
                    .as_ref()
                    .is_some_and(|o| !o.instance.is_empty() && o.profile == profile);
            if held {
                self.stash_owner_pads();
            }
            // `destroy_all` ends a stash too: this one is only now made.
            let aside = self.stash.take();
            self.destroy_all();
            self.stash = aside;
            self.owner = Some(Owner {
                instance: String::new(),
                profile: profile.to_owned(),
                uid,
            });
            self.prepared = Some(Prepared {
                app_id: app_id.to_owned(),
                until: now + PREPARE_TTL,
                answered: false,
            });
            self.journal(format!("pads prepared for {app_id} (ruya-{profile})"));
            self.make_missing(now);
        }
        self.answer_prepared();
        Status::Ok
    }

    /// Announces the end of a preparation once each of its pads is ready or its udev fallback ran.
    fn answer_prepared(&mut self) {
        if self.prepared.as_ref().map_or(true, |p| p.answered) {
            return;
        }
        let virts: Vec<&Virtual> = self.pads.values().filter_map(|p| p.virt.as_ref()).collect();
        if !virts.iter().all(|v| v.ready || v.fallback_tried) {
            return;
        }
        let status = if virts.iter().all(|v| v.ready) {
            Status::Ok
        } else {
            Status::Failed
        };
        let Some(profile) = self.owner.as_ref().map(|o| o.profile.clone()) else {
            return;
        };
        let Some(p) = self.prepared.as_mut() else {
            return;
        };
        p.answered = true;
        let app_id = p.app_id.clone();
        self.notices.push(Notice::PadsPrepared {
            app_id,
            profile,
            status,
        });
    }

    /// A preparation no route took within `PREPARE_TTL`: its pads go.
    fn expire_prepared(&mut self, now: Instant) {
        let Some(p) = self.prepared.as_ref() else {
            return;
        };
        if now < p.until {
            return;
        }
        let line = format!(
            "prepared pads for {} were not used in {} s",
            p.app_id,
            PREPARE_TTL.as_secs()
        );
        self.journal(line);
        self.end_stash("the preparation expired");
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
        let app_ok = app_id.is_empty() || valid_session_app_id(app_id);
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
            match self.accounts.account(profile).map(|a| a.uid) {
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
        // The game's first route takes the pads prepared for it (RUY-837), whatever its instance:
        // the shell did not know it at PreparePads.
        let adopt = matches!(r, Route::App | Route::Overlay)
            && !instance.is_empty()
            && self.prepared.as_ref().is_some_and(|p| p.app_id == app_id)
            && self.owner.as_ref().is_some_and(|o| o.profile == profile);
        if adopt {
            // The new game owns the pads: the held game's set-aside ones go (RUY-840).
            self.drop_stash();
            if let Some(p) = self.prepared.take() {
                if !p.answered {
                    self.notices.push(Notice::PadsPrepared {
                        app_id: p.app_id,
                        profile: profile.to_owned(),
                        status: Status::Ok,
                    });
                }
            }
            if let Some(o) = self.owner.as_mut() {
                o.instance = instance.to_owned();
            }
            self.journal(format!(
                "prepared pads for {app_id} bound to instance '{instance}'"
            ));
        }
        // The route is back to the held game: its own pads again, the prepared ones go (RUY-840).
        // Only `app`: the shell may send `overlay` for the held game while the launch runs.
        let back = !adopt
            && r == Route::App
            && self.stash.as_ref().is_some_and(|s| {
                !instance.is_empty() && s.owner.instance == instance && s.owner.profile == profile
            });
        if back {
            self.restore_stash("the route is back to it");
        }
        // A preparation waits through "shell" and "overlay" of its profile.
        let keep_prepared = self.prepared.is_some()
            && matches!(r, Route::Shell | Route::Overlay)
            && self.owner.as_ref().is_some_and(|o| o.profile == profile);
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
            self.remember_owner(&pad, profile);
            self.drop_holds();
            self.seats_changed(&before);
            self.clear_navigator("the profile changed");
            self.uinput_profile_changed(profile, uid, now);
        }
        match r {
            Route::App if same_owner => {
                if old != Route::App {
                    self.app_entered = Some(now);
                    // Back from the overlay (the Hub, frozen or not: the same devices, RUY-541):
                    // what is held now waits for its release.
                    for pad in self.pads.values_mut() {
                        let state = pad.state.clone();
                        if let Some(v) = pad.virt.as_mut() {
                            v.mask_held(&state);
                        }
                    }
                }
                // A pad connected under the overlay gets its virtual pad now (`make_missing`).
            }
            Route::App => {
                self.app_entered = Some(now);
                self.destroy_all();
                self.owner = uid.map(|uid| Owner {
                    instance: instance.to_owned(),
                    profile: profile.to_owned(),
                    uid,
                });
                // Every seated pad's virtual pad is made at once, below (RUY-681), the profile's
                // active controller (the pad that signed it in) first, so it is `pad1` and SDL
                // index 0 (RUY-540); the others' ACLs follow once pad1 can be opened (RUY-541).
            }
            Route::Overlay if same_owner => self.neutral_all(),
            Route::Overlay | Route::Shell if keep_prepared => {}
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
        self.make_missing(now);
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
    /// are `Seats::join`; a move binds the seat's virtual pad to the new pad. A new player takes
    /// the free seat whose quiet pad was theirs in this game, else the lowest free seat the game
    /// has no pad for, else the lowest free seat (taking over its quiet pad; RUY-681).
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
        let theirs = self
            .idle
            .values()
            .filter(|v| v.player == profile)
            .map(|v| v.n);
        let order: Vec<u32> = theirs
            .chain((2..=SEATS).filter(|n| !self.idle.contains_key(n)))
            .chain((2..=SEATS).filter(|n| self.idle.contains_key(n)))
            .collect();
        match self.seats.join_in_order(device_id, profile, &order) {
            Joined::Full => (Status::Full, 0),
            Joined::Seated { slot, changed } => {
                self.remember_owner(device_id, profile);
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
    /// destroyed, also a quiet one (RUY-681: the player left). "ok" also for an empty seat.
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
        if let Some(v) = self.idle.remove(&slot) {
            self.drop_virtual(0, v);
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

    /// The pad's recorded owner, "" when none or when it is no longer a (non-guest) profile account.
    fn owner_of(&self, pad: &str) -> String {
        self.owners
            .get(pad)
            .filter(|who| self.accounts.account(who).is_some_and(|a| !a.guest))
            .unwrap_or_default()
            .to_owned()
    }

    /// `profile` played on `pad` (a sign-in or a JoinPlayer): the pad's owner, unless it is a
    /// temporary guest or the player has no pad (RUY-124).
    fn remember_owner(&mut self, pad: &str, profile: &str) {
        if pad.is_empty() || profile.is_empty() {
            return;
        }
        let Some(account) = self.accounts.account(profile) else {
            return;
        };
        if account.guest {
            return;
        }
        let accounts = &self.accounts;
        let live = |who: &str| accounts.account(who).is_some();
        if self.owners.record(pad, profile, &live) {
            self.owner_changed(pad);
        }
        self.drain_owners();
    }

    /// The owner of the pad with stable id `pad` changed: its record is announced.
    fn owner_changed(&mut self, pad: &str) {
        let marked: Vec<PadKey> = self
            .pads
            .iter()
            .filter(|(_, p)| p.info.id == pad)
            .map(|(&k, _)| k)
            .collect();
        self.dirty.extend(marked);
    }

    fn drain_owners(&mut self) {
        for line in self.owners.take_journal() {
            self.journal(line);
        }
    }

    /// A console profile's controller profiles exist only for a profile account.
    fn console_ok(&self, profile: &str) -> bool {
        valid_profile_id(profile) && self.accounts.account(profile).is_some()
    }

    /// The profiles of `profile` changed: the signal, and the owner's pads take the new mapping
    /// now (in `app`; held in neutral in `overlay`, they show it from the next input on).
    fn profiles_changed(&mut self, profile: &str) {
        self.notices.push(Notice::ProfilesChanged {
            profile: profile.to_owned(),
        });
        if self.owner.is_none() {
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
            // Only the seats of this profile are rebuilt (RUY-643).
            if self.seat_number(key).map(|(_, p)| p).as_deref() != Some(profile) {
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

    /// `Input1.ForgetConsoleProfile` (RUY-468): the console profile (deleted, or a guest that went)
    /// loses its controller profiles. Not a profile account check: the account is gone by now; the
    /// id rule alone keeps the removal inside the state directory. A pad still seated with it takes
    /// `default`, as a profile without files does; one `ProfilesChanged` (also after a failure:
    /// what was read of it is dropped either way).
    pub fn forget_console_profile(&mut self, profile: &str) -> Status {
        if !valid_profile_id(profile) {
            return Status::Invalid;
        }
        let status = self.book.forget(profile);
        self.drain_book();
        if status == Status::Ok {
            self.journal(format!("controller profiles of ruya-{profile} removed"));
        }
        // A pad that remembered this profile now reads no owner: one `DeviceChanged` each.
        let orphaned: Vec<String> = self
            .pads
            .values()
            .map(|p| p.info.id.clone())
            .filter(|id| self.owners.get(id) == Some(profile) && self.owner_of(id).is_empty())
            .collect();
        for id in orphaned {
            self.owner_changed(&id);
        }
        self.profiles_changed(profile);
        status
    }

    /// `Input1.StoredConsoleProfiles`: the console profiles with a directory of controller
    /// profiles (the shell's start sweep, RUY-468).
    pub fn stored_console_profiles(&mut self) -> (Status, Vec<String>) {
        let out = self.book.stored_consoles();
        self.drain_book();
        match out {
            Ok(list) => (Status::Ok, list),
            Err(status) => (status, Vec::new()),
        }
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
                "{}'s {scope} controller profile for {slot} is '{profile_id}'",
                user_of(profile)
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
        if !app_id.is_empty() && !valid_session_app_id(app_id) {
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

    /// A held seat's virtual pad (RUY-627) or a quiet one (RUY-681): its pad is gone.
    fn parked_pad(&mut self, id: VirtualId) -> Option<&mut Virtual> {
        self.holds
            .values_mut()
            .find_map(|p| p.virt.as_mut().filter(|v| v.id == id))
            .or_else(|| self.idle.values_mut().find(|v| v.id == id))
            .or_else(|| {
                let st = self.stash.as_mut()?;
                st.pads
                    .values_mut()
                    .chain(st.idle.values_mut())
                    .find(|v| v.id == id)
            })
    }

    /// The app uploaded (or updated) rumble effect `effect` on virtual pad `id`. On a held seat's
    /// or a quiet virtual pad it is kept for the pad that comes back.
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
        RenewNav,
        FfUpload(PadKey, i16, Rumble),
        FfPlay(PadKey, i16, i32),
        FfErase(PadKey, i16),
    }

    /// A fake uinput and filesystem: records every call, keeps one ACL per node.
    struct Fake {
        calls: Vec<Call>,
        next: VirtualId,
        alive: BTreeSet<VirtualId>,
        acls: HashMap<String, Vec<u8>>,
        acl_fails: bool,
        next_ff: i16,
        /// The sysnames of the devices it made and has not destroyed (their markers).
        own: BTreeSet<String>,
        /// The navigation keyboard's sysname (`input1` until `renew_nav`) and how often it was renewed.
        nav: String,
        navs: u32,
    }

    impl Fake {
        fn take(&mut self) -> Vec<Call> {
            std::mem::take(&mut self.calls)
        }
    }

    impl Default for Fake {
        fn default() -> Self {
            Fake {
                calls: Vec::new(),
                next: 0,
                alive: BTreeSet::new(),
                acls: HashMap::new(),
                acl_fails: false,
                next_ff: 0,
                own: BTreeSet::from(["input1".to_owned()]),
                nav: "input1".to_owned(),
                navs: 0,
            }
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
            let sysname = format!("input{}", 100 + self.next);
            self.own.insert(sysname.clone());
            Ok(Created {
                id: self.next,
                sysname,
            })
        }
        fn destroy_virtual(&mut self, id: VirtualId) {
            self.alive.remove(&id);
            self.own.remove(&format!("input{}", 100 + id));
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
        fn is_own(&mut self, sysname: &str) -> bool {
            self.own.contains(sysname)
        }
        fn is_nav(&mut self, sysname: &str) -> bool {
            self.nav == sysname
        }
        fn renew_nav(&mut self) -> Result<String, String> {
            self.own.remove(&self.nav);
            self.navs += 1;
            self.nav = format!("input{}", 900 + self.navs);
            self.own.insert(self.nav.clone());
            self.calls.push(Call::RenewNav);
            Ok(self.nav.clone())
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
                ("p3".into(), 1003),
                ("p4".into(), 1004),
                ("p5".into(), 1005),
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
            ..UdevEvent::default()
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
    /// `guide`. No virtual pad ever sees Guide: each seated one's "no BTN_MODE" is checked against
    /// its BTN_SOUTH; the unseated pad has none (the seat gate, RUY-122), so its game sees nothing.
    #[test]
    fn guide_reaches_the_shell_from_any_pad_before_a_sign_in_and_from_player_1_after_it() {
        let mut r = router();
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
        assert_eq!(phys_of(&r, c), None, "the unseated c has no virtual pad");
        r.backend_mut().take();
        r.take_notices();
        for (pad_key, id, shell, kind, game) in [
            (a, "a", true, None, true),
            (b, "b", false, Some("player-guide"), true),
            (c, "c", false, Some("guide"), false),
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
            assert_eq!(
                sent.iter()
                    .any(|(_, e)| e.iter().any(|e| e.1 == code::BTN_SOUTH)),
                game,
                "{id}: the game gets the pad (seated pads only): {sent:?}"
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

    /// RUY-122 (the gate on, RUY-38's interim fallback gone): seat 1 lost its pad for good (the
    /// hold ran out), and an unseated pad's press only asks (`ForeignInput` "press": the shell opens
    /// "Who's playing?"). Its "Join as player 1" (`JoinPlayer` with player 1's profile) makes it seat
    /// 1's pad: it navigates from then on, and back in the app its virtual pad is pad1.
    #[test]
    fn after_the_hold_a_pad_asks_and_its_join_as_player_1_takes_seat_1() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        let t = t0();
        r.remove_pad_at(a, t);
        // The Hub opened over the game (the shell's lost-pad pause): the route is overlay.
        r.set_route("overlay", "i1", STK, "p1", SHELL, t);
        r.tick(t + SEAT_HOLD + Duration::from_secs(1));
        assert_eq!(r.players()[0].device_id, "", "the hold ran out");
        r.backend_mut().take();
        r.take_notices();
        let later = t + SEAT_HOLD + Duration::from_secs(2);
        r.input_at(
            b,
            &[press(PadButton::South), release(PadButton::South)],
            later,
        );
        assert_eq!(r.players()[0].device_id, "", "a press takes no seat");
        assert!(nav(&r.backend_mut().take()).is_empty(), "nor navigates");
        assert_eq!(foreign(&r.take_notices()), vec![("b".to_owned(), "press")]);
        assert_eq!(join(&mut r, b, "p1"), 1, "Join as player 1");
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "b")]);
        r.backend_mut().take();
        r.input_at(b, &[press(PadButton::South)], later);
        assert_eq!(
            nav(&r.backend_mut().take()),
            vec![(NavKey::Accept, true)],
            "b navigates"
        );
        assert!(foreign(&r.take_notices()).is_empty(), "and asks nothing");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        assert_eq!(phys_of(&r, b).as_deref(), Some("ruya-input/pad1"));
    }

    #[test]
    fn after_a_keyboard_sign_in_join_as_player_1_gives_seat_1_a_pad() {
        let mut r = router();
        let b = r.add_pad(pad("b"), t0());
        signed_in(&mut r, "p1");
        assert_eq!(r.players()[0].device_id, "");
        assert_eq!(join(&mut r, b, "p1"), 1);
        assert_eq!(r.players()[0].device_id, "b");
        r.backend_mut().take();
        r.input_at(b, &[press(PadButton::DpadDown)], t0());
        assert_eq!(nav(&r.backend_mut().take()), vec![(NavKey::Down, true)]);
    }

    /// A player in seat 2 who presses while seat 1 has no pad keeps their seat and asks nothing but
    /// with Guide (`player-guide`).
    #[test]
    fn a_seated_players_press_does_not_take_a_padless_seat_1() {
        let mut r = router();
        let b = r.add_pad(pad("b"), t0());
        signed_in(&mut r, "p1");
        assert_eq!(join(&mut r, b, "p2"), 2);
        r.backend_mut().take();
        r.take_notices();
        r.input_at(
            b,
            &[press(PadButton::South), release(PadButton::South)],
            t0(),
        );
        assert_eq!(
            seats_of(&r),
            vec![seat(1, "p1", ""), seat(2, "p2", "b")],
            "seat 1 stays padless, b stays player 2"
        );
        assert!(nav(&r.backend_mut().take()).is_empty(), "no navigation key");
        let notices = r.take_notices();
        assert!(players_signals(&notices).is_empty(), "no PlayersChanged");
        assert!(
            foreign(&notices).is_empty(),
            "a seated pad's press asks nothing"
        );
        r.input_at(b, &[press(PadButton::Guide)], t0());
        assert_eq!(
            foreign(&r.take_notices()),
            vec![("b".to_owned(), "player-guide")]
        );
    }

    /// The seat gate (RUY-122): a press takes no seat; the prompt's Join as player 1 (or, with
    /// RUY-628, its Move) is the path.
    #[test]
    fn gate_on_no_pad_takes_a_padless_seat_1() {
        // A keyboard sign-in.
        let mut r = router();
        let b = r.add_pad(pad("b"), t0());
        signed_in(&mut r, "p1");
        r.backend_mut().take();
        r.input_at(b, &[press(PadButton::DpadDown)], t0());
        assert_eq!(r.players()[0].device_id, "");
        assert!(nav(&r.backend_mut().take()).is_empty());
        assert_eq!(foreign(&r.take_notices()), vec![("b".to_owned(), "press")]);
        // A hold that ran out.
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        let t = t0();
        r.remove_pad_at(a, t);
        r.tick(t + SEAT_HOLD + Duration::from_secs(1));
        assert_eq!(r.players()[0].device_id, "");
        r.backend_mut().take();
        r.input_at(b, &[press(PadButton::South)], t);
        assert_eq!(r.players()[0].device_id, "");
        assert!(nav(&r.backend_mut().take()).is_empty());
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

    /// The journal lines about the first input forwarded to a virtual pad (RUY-602).
    fn first_input_lines(r: &mut Router<Fake>) -> Vec<String> {
        journal(r)
            .into_iter()
            .filter(|l| l.starts_with("first input forwarded"))
            .collect()
    }

    #[test]
    fn the_first_forwarded_input_is_journalled_once_per_pad_and_route() {
        let ms = Duration::from_millis;
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        join(&mut r, b, "p2");
        let t = t0();
        r.set_route("app", "i1", STK, "p1", SHELL, t);
        // Guide and a button held at the entry are not forwarded: no line for them.
        r.input_at(
            a,
            &[press(PadButton::Guide), release(PadButton::Guide)],
            t + ms(10),
        );
        assert!(first_input_lines(&mut r).is_empty());
        r.input_at(a, &[press(PadButton::South)], t + ms(20));
        r.input_at(
            a,
            &[release(PadButton::South), press(PadButton::East)],
            t + ms(30),
        );
        r.input_at(a, &[release(PadButton::East)], t + ms(40));
        // Pad b gets its own line; its later batches none.
        r.input_at(b, &[PadInput::Axis(PadAxis::LeftX, 20000)], t + ms(250));
        r.input_at(b, &[PadInput::Axis(PadAxis::LeftX, 0)], t + ms(260));
        assert_eq!(
            first_input_lines(&mut r),
            vec![
                "first input forwarded to pad1 (instance i1, 20 ms after the route)",
                "first input forwarded to pad2 (instance i1, 250 ms after the route)",
            ]
        );
        // A new route entry starts over.
        let t2 = t + ms(1000);
        r.set_route("app", "i2", STK, "p1", SHELL, t2);
        r.input_at(a, &[press(PadButton::South)], t2 + ms(5));
        r.input_at(a, &[release(PadButton::South)], t2 + ms(6));
        assert_eq!(
            first_input_lines(&mut r),
            vec!["first input forwarded to pad1 (instance i2, 5 ms after the route)"]
        );
        // The Hub and back (a Thaw) starts over too; a button held at the Thaw does not count.
        r.set_route("overlay", "i2", STK, "p1", SHELL, t2 + ms(100));
        let t3 = t2 + ms(500);
        r.input_at(a, &[press(PadButton::North)], t3 - ms(100));
        r.set_route("app", "i2", STK, "p1", SHELL, t3);
        r.input_at(a, &[release(PadButton::North)], t3 + ms(1));
        assert!(first_input_lines(&mut r).is_empty());
        r.input_at(a, &[press(PadButton::West)], t3 + ms(7));
        assert_eq!(
            first_input_lines(&mut r),
            vec!["first input forwarded to pad1 (instance i2, 7 ms after the route)"]
        );
    }

    #[test]
    fn the_first_input_line_names_no_button_or_axis() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
        let t = t0();
        r.set_route("app", "i1", STK, "p1", SHELL, t);
        r.input_at(
            a,
            &[
                press(PadButton::South),
                PadInput::Axis(PadAxis::RightX, 30000),
            ],
            t + Duration::from_millis(3),
        );
        assert_eq!(
            first_input_lines(&mut r),
            vec!["first input forwarded to pad1 (instance i1, 3 ms after the route)"]
        );
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

    /// The order of the creations (pad key) and the pad nodes' ACL writes (node) in `calls`; the
    /// ACL of `/dev/uinput` follows the profile (RUY-1063), not a pad: `uinput_writes` has it.
    fn order(calls: &[Call]) -> Vec<String> {
        calls
            .iter()
            .filter_map(|c| match c {
                Call::Create(k, s) => Some(format!("create {k} {}", s.phys)),
                Call::WriteAcl(node) if node != UINPUT_NODE => Some(format!("acl {node}")),
                _ => None,
            })
            .collect()
    }

    /// The pad nodes' ACLs: every node but `/dev/uinput`.
    fn pad_acls(r: &mut Router<Fake>) -> Vec<String> {
        let mut nodes: Vec<String> = r
            .backend()
            .acls
            .keys()
            .filter(|n| n.as_str() != UINPUT_NODE)
            .cloned()
            .collect();
        nodes.sort();
        nodes
    }

    /// The calls without the writes of `/dev/uinput`'s ACL.
    fn pad_calls(calls: Vec<Call>) -> Vec<Call> {
        calls
            .into_iter()
            .filter(|c| c != &Call::WriteAcl(UINPUT_NODE.into()))
            .collect()
    }

    /// A udev event on the node `devname` of the input device `sysname`.
    fn udev_node(action: &str, sysname: &str, devname: &str) -> UdevEvent {
        UdevEvent {
            devname: devname.into(),
            ..udev(action, sysname)
        }
    }

    #[test]
    fn every_seated_pad_is_made_at_once_and_opened_only_after_pad1() {
        // RUY-681: on `app` every seated pad's virtual pad is made at once, pad1 first (RUY-540);
        // the others' first ACL waits until pad1's is set (RUY-541), so pad1 is the first pad an
        // app can open.
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
            vec![
                format!("create {b} ruya-input/pad1"),
                format!("create {a} ruya-input/pad2"),
                format!("create {c} ruya-input/pad3"),
            ]
        );
        // pad2's and pad3's udev events come first: neither is opened before pad1.
        r.udev_event(&udev_node("add", "input102", "/dev/input/event22"));
        r.udev_event(&udev_node("add", "input103", "/dev/input/event23"));
        assert!(order(&r.backend_mut().take()).is_empty());
        // A pad that joins while pad1 is not ready is made at once and waits too.
        let d = r.add_pad(pad("d"), t0());
        join(&mut r, d, "p4");
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![format!("create {d} ruya-input/pad4")]
        );
        r.udev_event(&udev_node("add", "input104", "/dev/input/event24"));
        r.udev_event(&udev_node("add", "input101", "/dev/input/event21"));
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![
                "acl /dev/input/event21",
                "acl /dev/input/event22",
                "acl /dev/input/event23",
                "acl /dev/input/event24",
            ]
        );
        let lines = journal(&mut r);
        let ready = |n: u32| {
            lines
                .iter()
                .position(|l| l.starts_with(&format!("virtual pad ruya-input/pad{n} ready")))
        };
        assert!(ready(1).is_some() && ready(1) < ready(2), "{lines:?}");
        assert!(r.devices().iter().all(|d| d.routed));
        // pad2's own ACL does not hold anything back; a pad that joins now is made and opened at
        // once, with the number of the seat it takes (seat 3, which c left).
        assert_eq!(r.leave_player(3, t0()), Status::Ok);
        let e = r.add_pad(pad("e"), t0());
        assert_eq!(join(&mut r, e, "p5"), 3);
        r.udev_event(&udev_node("add", "input105", "/dev/input/event25"));
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![
                format!("create {e} ruya-input/pad3"),
                "acl /dev/input/event25".to_owned()
            ]
        );

        // No udev event: the others' ACLs follow pad1's fallback, also when its ACL write fails.
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
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![
                format!("create {a} ruya-input/pad1"),
                format!("create {b} ruya-input/pad2")
            ]
        );
        r.take_notices();
        r.backend_mut().acl_fails = true;
        r.tick(start + UDEV_FALLBACK / 2);
        assert!(journal(&mut r).is_empty(), "nothing before the fallback");
        r.tick(start + UDEV_FALLBACK);
        let tried: Vec<String> = journal(&mut r)
            .into_iter()
            .filter(|l| l.starts_with("setting the ACL of"))
            .map(|l| l.split(' ').nth(4).unwrap_or_default().to_owned())
            .collect();
        assert_eq!(tried, vec!["ruya-input/pad1", "ruya-input/pad2"]);

        // pad1 vanishes before it is ready: the others' ACLs are set at once (seat 1 is held,
        // with no pad, so no pad1 holds them back).
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        let c = r.add_pad(pad("c"), t0());
        sign_in(&mut r, a, "p1");
        join(&mut r, b, "p2");
        join(&mut r, c, "p3");
        app(&mut r, "i1", STK, "p1");
        r.udev_event(&udev_node("add", "input103", "/dev/input/event23"));
        r.udev_event(&udev_node("add", "input102", "/dev/input/event22"));
        r.backend_mut().take();
        r.remove_pad(a);
        assert_eq!(
            order(&r.backend_mut().take()),
            vec!["acl /dev/input/event22", "acl /dev/input/event23"]
        );
    }

    #[test]
    fn fallbacks_due_together_set_pad1s_acl_first_whatever_the_keys() {
        // a has the lower key but joins as player 2; b signs in, so pad1 is on the higher key.
        let mut r = router();
        let start = t0();
        let a = r.add_pad(pad("a"), start);
        let b = r.add_pad(pad("b"), start);
        sign_in(&mut r, b, "p1");
        join(&mut r, a, "p2");
        assert_eq!(
            r.set_route("app", "i1", STK, "p1", SHELL, start),
            Status::Ok
        );
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![
                format!("create {b} ruya-input/pad1"),
                format!("create {a} ruya-input/pad2")
            ]
        );
        // No udev event at all: both fallbacks come due on one tick, pad1's ACL first.
        r.tick(start + UDEV_FALLBACK);
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![
                "acl /dev/input/event-input101",
                "acl /dev/input/event-input102"
            ]
        );
    }

    #[test]
    fn a_lock_while_acls_wait_for_pad1_leaves_nothing_for_the_next_profile() {
        // p1's app: b is pad1, a and c are made with it and wait for its ACL.
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        let c = r.add_pad(pad("c"), t0());
        r.input(b, &[press(PadButton::South)]);
        r.set_route("shell", "", "", "p1", SHELL, t0());
        join(&mut r, a, "p2");
        join(&mut r, c, "p3");
        app(&mut r, "i1", STK, "p1");
        r.udev_event(&udev_node("add", "input102", "/dev/input/event22"));
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![
                format!("create {b} ruya-input/pad1"),
                format!("create {a} ruya-input/pad2"),
                format!("create {c} ruya-input/pad3"),
            ]
        );
        // Locked before pad1 is ready; c signs p2 in, and p2's app makes c pad1 first: what p1's
        // app left waiting (a's ACL) is gone with its pads.
        r.set_route("locked", "", "", "", SHELL, t0());
        let mut gone = destroyed(&r.backend_mut().take());
        gone.sort_unstable();
        assert_eq!(gone, vec![1, 2, 3]);
        r.input(c, &[press(PadButton::South)]);
        r.set_route("shell", "", "", "p2", SHELL, t0());
        // The lock emptied the seats: only b joins p2's session (RUY-121).
        assert_eq!(join(&mut r, b, "p1"), 2);
        r.backend_mut().take();
        app(&mut r, "i2", STK, "p2");
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![
                format!("create {c} ruya-input/pad1"),
                format!("create {b} ruya-input/pad2")
            ],
            "a, unseated now, is not made"
        );
        // pad1's udev event sets its ACL alone: pad2 waits for its own event, not a's old one.
        r.udev_event(&udev_node("add", "input104", "/dev/input/event24"));
        assert_eq!(
            order(&r.backend_mut().take()),
            vec!["acl /dev/input/event24"]
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
    fn a_vanished_pad_keeps_its_virtual_pad_until_the_game_ends() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        join(&mut r, b, "p2");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        r.backend_mut().take();
        r.take_notices();
        // A seated pad's virtual pad stays through the hold (RUY-627) and after it (RUY-681).
        let t = t0();
        r.remove_pad_at(a, t);
        assert!(destroyed(&r.backend_mut().take()).is_empty(), "held");
        assert!(r.take_notices().contains(&Notice::DeviceRemoved {
            id: "a".into(),
            instance: "a#1".into()
        }));
        r.tick(t + SEAT_HOLD);
        assert!(destroyed(&r.backend_mut().take()).is_empty(), "quiet");
        // Player 1 moves to a pad connected while the app is in front: it gets the same pad1.
        let c = r.add_pad(pad("c"), t0());
        assert!(created(&r.backend_mut().take()).is_empty());
        assert_eq!(join(&mut r, c, "p1"), 1);
        assert_eq!(phys_of(&r, c).as_deref(), Some("ruya-input/pad1"));
        assert_eq!(virtual_id(&r, c), Some(1));
        assert!(created(&r.backend_mut().take()).is_empty());
        assert_eq!(r.devices().len(), 2);
        // The game ends (Home, no game held): pad1 and pad2 go with it.
        r.set_route("shell", "", "", "p1", SHELL, t0());
        let mut gone = destroyed(&r.backend_mut().take());
        gone.sort_unstable();
        assert_eq!(gone, vec![1, 2]);
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
        // The new pad (input102) is p2's; an event on p1's old node gives p1 nothing (the device
        // is gone and no longer ours: since RUY-1063 it would be a foreign device, never p1's
        // within the 2 s after the switch).
        r.backend_mut().acls.clear();
        r.udev_event(&udev("change", "input101"));
        assert!(r.backend().acls.values().all(|a| !acl::named_users(a)
            .unwrap_or_default()
            .contains(&(P1_UID, 6))));
        assert!(!r.devices()[0].routed);
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
        // Another device (hardware; a parentless one is a foreign device since RUY-1063).
        r.udev_event(&UdevEvent {
            devpath: "/devices/pci0000:00/usb1/1-2/1-2:1.0/input/input7/event17".into(),
            ..udev("add", "input7")
        });
        r.udev_event(&udev("remove", "input101"));
        assert!(pad_acls(&mut r).is_empty());
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
        assert!(pad_acls(&mut r).is_empty());
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

    fn wii_remote(id: &str) -> (PadInfo, crate::pad::Normalizer) {
        let info = PadInfo {
            name: "Nintendo Wii Remote".into(),
            model: "wii_remote".into(),
            ..family_pad(id, "nintendo")
        };
        let n = crate::pad::Normalizer::new(crate::pad::PadLayout {
            keys: crate::pad::model_keys("wii_remote"),
            ..Default::default()
        });
        (info, n)
    }

    /// Evdev presses and releases of `keys`, one frame each, through the remote's normaliser.
    fn wii_taps(r: &mut Router<Fake>, a: PadKey, n: &mut crate::pad::Normalizer, keys: &[u16]) {
        for &k in keys {
            for v in [1, 0] {
                for f in n.frames([(code::EV_KEY, k, v), (code::EV_SYN, code::SYN_REPORT, 0)]) {
                    r.input(a, &f.inputs);
                }
            }
        }
    }

    #[test]
    fn a_wii_remote_reaches_a_game_as_a_normal_pad() {
        let mut r = router();
        let (info, mut n) = wii_remote("w");
        let a = r.add_pad(info, t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        wii_taps(&mut r, a, &mut n, &[code::KEY_UP, code::BTN_2]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![
                (1, vec![(code::EV_ABS, code::ABS_HAT0X, -1)]),
                (1, vec![(code::EV_ABS, code::ABS_HAT0X, 0)]),
                (1, vec![(code::EV_KEY, code::BTN_EAST, 1)]),
                (1, vec![(code::EV_KEY, code::BTN_EAST, 0)]),
            ]
        );
    }

    fn stickless_wii(id: &str) -> (PadInfo, crate::pad::Normalizer) {
        let (mut info, n) = wii_remote(id);
        info.capabilities = vec![crate::caps::Capability {
            name: "sticks",
            hardware: false,
            driver: false,
            available: false,
            output: false,
        }];
        (info, n)
    }

    /// Evdev frames: `k` goes down (`v` 1) or up (0).
    fn wii_key(r: &mut Router<Fake>, a: PadKey, n: &mut crate::pad::Normalizer, k: u16, v: i32) {
        for f in n.frames([(code::EV_KEY, k, v), (code::EV_SYN, code::SYN_REPORT, 0)]) {
            r.input(a, &f.inputs);
        }
    }

    fn hat_x(v: i32) -> OutEvent {
        (code::EV_ABS, code::ABS_HAT0X, v)
    }
    fn abs_x(v: i32) -> OutEvent {
        (code::EV_ABS, code::ABS_X, v)
    }
    fn abs_y(v: i32) -> OutEvent {
        (code::EV_ABS, code::ABS_Y, v)
    }

    fn flat(calls: &[Call]) -> Vec<OutEvent> {
        writes(calls).into_iter().flat_map(|(_, e)| e).collect()
    }

    #[test]
    fn a_pad_without_a_stick_also_moves_the_left_stick_with_its_dpad() {
        let mut r = router();
        let (info, mut n) = stickless_wii("w");
        let a = r.add_pad(info, t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        // Held sideways, the remote's KEY_UP is the D-pad's left and KEY_RIGHT its up.
        wii_key(&mut r, a, &mut n, code::KEY_UP, 1);
        let got = flat(&r.backend_mut().take());
        assert!(
            got.contains(&hat_x(-1)) && got.contains(&abs_x(STICK_MIN)),
            "{got:?}"
        );
        wii_key(&mut r, a, &mut n, code::KEY_UP, 0);
        let got = flat(&r.backend_mut().take());
        assert!(
            got.contains(&hat_x(0)) && got.contains(&abs_x(0)),
            "{got:?}"
        );
        // Up and right together.
        wii_key(&mut r, a, &mut n, code::KEY_RIGHT, 1);
        wii_key(&mut r, a, &mut n, code::KEY_DOWN, 1);
        let got = flat(&r.backend_mut().take());
        assert!(
            got.contains(&abs_y(STICK_MIN)) && got.contains(&abs_x(STICK_MAX)),
            "{got:?}"
        );
    }

    #[test]
    fn a_pad_with_sticks_sends_only_the_hat_for_its_dpad() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        r.input(a, &[press(PadButton::DpadLeft)]);
        assert_eq!(flat(&r.backend_mut().take()), vec![hat_x(-1)]);
        // A pad whose probe found sticks (Xbox 360, Wii U Pro) behaves the same.
        let mut info = pad("b");
        info.capabilities = vec![crate::caps::Capability {
            name: "sticks",
            hardware: true,
            driver: true,
            available: true,
            output: true,
        }];
        let b = r.add_pad(info, t0());
        join(&mut r, b, "p2");
        r.backend_mut().take();
        r.input(b, &[press(PadButton::DpadLeft)]);
        let got = flat(&r.backend_mut().take());
        assert!(
            got.contains(&hat_x(-1)) && !got.iter().any(|e| e.1 == code::ABS_X),
            "{got:?}"
        );
    }

    #[test]
    fn the_mirrored_stick_is_centred_by_neutral_and_by_a_pad_leaving() {
        let mut r = router();
        let (info, mut n) = stickless_wii("w");
        let a = r.add_pad(info, t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        wii_key(&mut r, a, &mut n, code::KEY_UP, 1);
        r.backend_mut().take();
        // The overlay (the Hub) neutralises the virtual pad.
        assert_eq!(
            r.set_route("overlay", "i1", STK, "p1", SHELL, t0()),
            Status::Ok
        );
        let got = flat(&r.backend_mut().take());
        assert!(
            got.contains(&abs_x(0)) && got.contains(&hat_x(0)),
            "{got:?}"
        );
        // A pad that goes while the stick is pushed (let go first: a press held at entry is masked).
        wii_key(&mut r, a, &mut n, code::KEY_UP, 0);
        app(&mut r, "i1", STK, "p1");
        wii_key(&mut r, a, &mut n, code::KEY_UP, 1);
        r.backend_mut().take();
        r.remove_pad(a);
        let got = flat(&r.backend_mut().take());
        assert!(got.contains(&abs_x(0)), "{got:?}");
    }

    #[test]
    fn a_wii_remote_navigates_the_shell() {
        let mut r = router();
        let (info, mut n) = wii_remote("w");
        let a = r.add_pad(info, t0());
        sign_in(&mut r, a, "p1");
        wii_taps(&mut r, a, &mut n, &[code::KEY_UP, code::BTN_2]);
        assert_eq!(
            keys_of(&mut r),
            vec![
                (NavKey::Left, true),
                (NavKey::Left, false),
                (NavKey::Accept, true),
                (NavKey::Accept, false)
            ]
        );
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
        let calls = pad_calls(r.backend_mut().take());
        assert_eq!(calls[0], Call::FfErase(a, 1));
        assert_eq!(destroyed(&calls), vec![1]);
    }

    // ---- /dev/uinput and foreign devices (RUY-1063) -----------------------------------------

    fn uinput_acl(r: &Router<Fake>) -> Option<Vec<u8>> {
        r.backend().acls.get(UINPUT_NODE).cloned()
    }

    fn misc_uinput(action: &str) -> UdevEvent {
        UdevEvent {
            action: action.into(),
            subsystem: "misc".into(),
            devpath: "/devices/virtual/misc/uinput".into(),
            devname: UINPUT_NODE.into(),
            ..UdevEvent::default()
        }
    }

    /// A udev event on the event node of a parentless device another process made.
    fn foreign_udev(action: &str, sysname: &str, devname: &str) -> UdevEvent {
        UdevEvent {
            origin: "foreign".into(),
            ..udev_node(action, sysname, devname)
        }
    }

    #[test]
    fn uinput_names_the_signed_in_profile_and_nobody_after_lock_or_the_callers_end() {
        let mut r = router();
        r.assert_uinput("start");
        assert_eq!(uinput_acl(&r), Some(acl::closed()), "nobody at start");
        r.set_route("shell", "", "", "p1", SHELL, t0());
        assert!(acl::is_only_user(&uinput_acl(&r).expect("acl"), P1_UID));
        assert!(journal(&mut r)
            .iter()
            .any(|l| l == "/dev/uinput for ruya-p1 (the profile changed)"));
        // A switch moves it to p2: p1's user is not named any more.
        r.set_route("shell", "", "", "p2", SHELL, t0());
        let acl = uinput_acl(&r).expect("acl");
        assert!(acl::is_only_user(&acl, P2_UID));
        assert_eq!(acl::named_users(&acl), Some(vec![(P2_UID, 6)]));
        r.set_route("locked", "", "", "", SHELL, t0());
        assert_eq!(uinput_acl(&r), Some(acl::closed()));
        // The shell gone from the bus: locked, closed.
        r.set_route("shell", "", "", "p1", SHELL, t0());
        r.caller_left(SHELL, t0());
        assert_eq!(uinput_acl(&r), Some(acl::closed()));
        assert!(journal(&mut r)
            .iter()
            .any(|l| l == "/dev/uinput for nobody (closed) (the profile changed)"));
    }

    #[test]
    fn uinputs_acl_is_set_again_after_a_udev_event_on_it() {
        let mut r = router();
        r.set_route("shell", "", "", "p1", SHELL, t0());
        r.backend_mut().take();
        journal(&mut r);
        // udev's MODE on the event masked the entry: the service writes it again.
        r.backend_mut()
            .acls
            .insert(UINPUT_NODE.into(), acl::closed());
        r.udev_event(&misc_uinput("change"));
        assert!(acl::is_only_user(&uinput_acl(&r).expect("acl"), P1_UID));
        assert_eq!(
            journal(&mut r),
            vec!["/dev/uinput for ruya-p1 (udev change)".to_owned()]
        );
        // Already right: nothing written.
        r.backend_mut().take();
        r.udev_event(&misc_uinput("add"));
        assert!(r.backend_mut().take().is_empty());
        // A remove writes nothing.
        r.backend_mut()
            .acls
            .insert(UINPUT_NODE.into(), acl::closed());
        r.udev_event(&misc_uinput("remove"));
        assert_eq!(uinput_acl(&r), Some(acl::closed()));
    }

    #[test]
    fn a_foreign_pad_is_its_profiles_while_signed_in_and_never_read() {
        let mut r = router();
        let start = t0();
        r.set_route("shell", "", "", "p1", SHELL, start);
        r.backend_mut().take();
        journal(&mut r);
        let later = start + origin::HANDOVER;
        r.udev_event_at(&foreign_udev("add", "input40", "/dev/input/event30"), later);
        assert!(acl::is_only_user(
            &r.backend().acls["/dev/input/event30"],
            P1_UID
        ));
        assert!(journal(&mut r)
            .iter()
            .any(|l| l == "foreign device input40 (/dev/input/event30): ruya-p1"));
        // Never a pad the service reads or makes a virtual pad for.
        assert!(r.devices().is_empty());
        assert!(created(&r.backend_mut().take()).is_empty());
        // A change (logind, udev's MODE) masked it: written again.
        r.backend_mut()
            .acls
            .insert("/dev/input/event30".into(), acl::closed());
        r.udev_event_at(
            &foreign_udev("change", "input40", "/dev/input/event30"),
            later,
        );
        assert!(acl::is_only_user(
            &r.backend().acls["/dev/input/event30"],
            P1_UID
        ));
        // A switch to p2 closes it (node_of names the node then); back to p1 opens it again.
        r.set_route("shell", "", "", "p2", SHELL, later);
        assert_eq!(r.backend().acls["/dev/input/event-input40"], acl::closed());
        r.set_route("shell", "", "", "p1", SHELL, later);
        assert!(acl::is_only_user(
            &r.backend().acls["/dev/input/event-input40"],
            P1_UID
        ));
        r.set_route("locked", "", "", "", SHELL, later);
        assert_eq!(r.backend().acls["/dev/input/event-input40"], acl::closed());
        // Gone: forgotten, a later profile change writes nothing for it.
        r.udev_event_at(
            &foreign_udev("remove", "input40", "/dev/input/event30"),
            later,
        );
        r.backend_mut().take();
        r.set_route("shell", "", "", "p1", SHELL, later);
        assert!(!r
            .backend_mut()
            .take()
            .contains(&Call::WriteAcl("/dev/input/event-input40".into())));
    }

    #[test]
    fn a_foreign_pad_within_two_seconds_of_a_switch_stays_closed() {
        let mut r = router();
        let start = t0();
        r.set_route("shell", "", "", "p1", SHELL, start);
        let switch = start + origin::HANDOVER * 2;
        r.set_route("shell", "", "", "p2", SHELL, switch);
        let soon = switch + Duration::from_millis(1500);
        r.udev_event_at(&foreign_udev("add", "input41", "/dev/input/event31"), soon);
        assert_eq!(r.backend().acls["/dev/input/event31"], acl::closed());
        assert!(journal(&mut r)
            .iter()
            .any(|l| l == "foreign device input41 (/dev/input/event31): nobody's: closed"));
        // Not p1's either, when p1 comes back.
        r.set_route("shell", "", "", "p1", SHELL, switch + origin::HANDOVER * 3);
        assert_eq!(r.backend().acls["/dev/input/event-input41"], acl::closed());
    }

    #[test]
    fn a_foreign_keyboard_is_its_profiles_like_a_pad() {
        // Criterion 7: a keyboard p1 made reaches no reader (the udev rules), its node names p1.
        let mut r = router();
        let start = t0();
        r.set_route("shell", "", "", "p1", SHELL, start);
        r.udev_event_at(
            &foreign_udev("add", "input42", "/dev/input/event32"),
            start + origin::HANDOVER,
        );
        let acl = r.backend().acls["/dev/input/event32"].clone();
        assert_eq!(acl::named_users(&acl), Some(vec![(P1_UID, 6)]));
        assert!(r.devices().is_empty());
    }

    #[test]
    fn our_own_devices_roots_and_hardware_are_not_foreign() {
        let mut r = router();
        let start = t0();
        r.set_route("shell", "", "", "p1", SHELL, start);
        r.backend_mut().take();
        let later = start + origin::HANDOVER;
        // The navigation keyboard (marked): ours, never foreign, even if udev called it so.
        r.udev_event_at(
            &foreign_udev("change", "input1", "/dev/input/event3"),
            later,
        );
        // Hardware: not this rule's.
        let usb = UdevEvent {
            devpath: "/devices/pci0000:00/usb1/1-2/1-2:1.0/input/input5/event4".into(),
            devname: "/dev/input/event4".into(),
            ..udev("add", "input5")
        };
        r.udev_event_at(&usb, later);
        // What root vouched for: hardware too.
        r.udev_event_at(
            &UdevEvent {
                origin: "trusted".into(),
                ..foreign_udev("add", "input43", "/dev/input/event33")
            },
            later,
        );
        assert!(r.backend_mut().take().is_empty());
    }

    #[test]
    fn a_device_marked_after_udev_called_it_foreign_is_ours_at_the_next_event() {
        let mut r = router();
        let start = t0();
        r.set_route("shell", "", "", "p1", SHELL, start);
        let later = start + origin::HANDOVER;
        r.udev_event_at(&foreign_udev("add", "input44", "/dev/input/event34"), later);
        assert!(r.backend().acls.contains_key("/dev/input/event34"));
        // Its marker appears: the next event finds it ours and it leaves the foreign pads.
        r.backend_mut().own.insert("input44".into());
        r.udev_event_at(
            &foreign_udev("change", "input44", "/dev/input/event34"),
            later,
        );
        r.backend_mut().take();
        r.set_route("shell", "", "", "p2", SHELL, later);
        assert!(!r
            .backend_mut()
            .take()
            .contains(&Call::WriteAcl("/dev/input/event-input44".into())));
    }

    #[test]
    fn the_navigation_keyboard_udev_processed_before_its_marker_is_made_again() {
        let mut r = router();
        // Its add processed as foreign: libinput never reads it again, so a new one is made.
        r.udev_event(&foreign_udev("add", "input1", "/dev/input/event3"));
        assert_eq!(r.backend_mut().take(), vec![Call::RenewNav]);
        assert!(journal(&mut r).iter().any(|l| l
            == "navigation keyboard input1 was processed by udev before its marker \
                (origin 'foreign'): made again as input901"));
        // The new one's add processed as own: nothing more. A change never renews.
        let own = UdevEvent {
            origin: "own".into(),
            ..udev_node("add", "input901", "/dev/input/event3")
        };
        r.udev_event(&own);
        r.udev_event(&foreign_udev("change", "input901", "/dev/input/event3"));
        // Rules that set no origin at all (an older image): no endless renewal.
        r.udev_event(&udev_node("add", "input901", "/dev/input/event3"));
        assert!(r.backend_mut().take().is_empty());
        // A virtual pad processed as foreign keeps working (the same udev treatment): no renew.
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        r.backend_mut().take();
        r.udev_event(&foreign_udev("add", "input101", "/dev/input/event17"));
        let calls = r.backend_mut().take();
        assert!(!calls.contains(&Call::RenewNav));
        assert!(calls.contains(&Call::WriteAcl("/dev/input/event17".into())));
    }

    #[test]
    fn a_foreign_device_found_at_start_is_closed_and_stays_nobodys() {
        let mut r = router();
        // An earlier run left p1's entry on it.
        r.backend_mut()
            .acls
            .insert("/dev/input/event30".into(), acl::only_user(P1_UID));
        r.found_at_start(
            "/devices/virtual/input/input40/event30",
            "/dev/input/event30",
            "foreign",
        );
        assert_eq!(r.backend().acls["/dev/input/event30"], acl::closed());
        // Ours (the navigation keyboard), root's and hardware are left alone.
        r.found_at_start(
            "/devices/virtual/input/input1/event3",
            "/dev/input/event3",
            "foreign",
        );
        r.found_at_start(
            "/devices/virtual/input/input43/event33",
            "/dev/input/event33",
            "trusted",
        );
        r.found_at_start(
            "/devices/pci0000:00/usb1/1-2/1-2:1.0/input/input5/event4",
            "/dev/input/event4",
            "",
        );
        assert_eq!(pad_acls(&mut r), vec!["/dev/input/event30".to_owned()]);
        // p1 signs in: it is not p1's (nobody's for its life).
        r.set_route("shell", "", "", "p1", SHELL, t0());
        r.udev_event_at(
            &foreign_udev("change", "input40", "/dev/input/event30"),
            t0() + origin::HANDOVER * 2,
        );
        assert_eq!(r.backend().acls["/dev/input/event30"], acl::closed());
    }

    #[test]
    fn the_navigation_keyboard_is_made_again_once_per_start_at_most() {
        let mut r = router();
        r.udev_event(&foreign_udev("add", "input1", "/dev/input/event3"));
        assert_eq!(r.backend_mut().take(), vec![Call::RenewNav]);
        journal(&mut r);
        // The new one is foreign at its add too (udev never sees the marker): one line, no remake.
        r.udev_event(&foreign_udev("add", "input901", "/dev/input/event3"));
        r.udev_event(&foreign_udev("add", "input901", "/dev/input/event3"));
        assert!(r.backend_mut().take().is_empty());
        assert_eq!(
            journal(&mut r),
            vec![
                "udev does not see the origin marker of the navigation keyboard input901: \
                  not made again (the shell cannot read it)"
                    .to_owned()
            ]
        );
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

    // RUY-468: a console profile that goes takes its controller profiles with it; a pad still
    // seated with it emits as `default` at once, and one ProfilesChanged tells the shell.
    #[test]
    fn a_forgotten_console_profile_leaves_its_pads_on_default() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        assert_eq!(r.save_profile("p1", SWAP).0, Status::Ok);
        assert_eq!(r.assign_profile("p1", "global", "", "swap"), Status::Ok);
        r.input(a, &[press(PadButton::South)]);
        r.backend_mut().take();
        r.take_notices();
        assert_eq!(
            r.stored_console_profiles(),
            (Status::Ok, vec!["p1".to_owned()])
        );
        // South is held as East: the virtual pad presses South and lets go of East (by code).
        assert_eq!(r.forget_console_profile("p1"), Status::Ok);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(
                1,
                vec![
                    (code::EV_KEY, code::BTN_SOUTH, 1),
                    (code::EV_KEY, code::BTN_EAST, 0)
                ]
            )]
        );
        assert_eq!(profiles_changed(&mut r), ["p1"], "one ProfilesChanged");
        assert_eq!(r.stored_console_profiles(), (Status::Ok, vec![]));
        let (_, list) = r.list_profiles("p1");
        assert!(
            list.iter().all(|s| s.id != "swap" && !s.assigned),
            "{list:?}"
        );
        r.input(a, &[release(PadButton::South)]);
        r.backend_mut().take();
        r.input(a, &[press(PadButton::South)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(1, vec![(code::EV_KEY, code::BTN_SOUTH, 1)])]
        );
        // Not a profile account (a guest that went): still forgotten, by the id rule alone.
        assert_eq!(r.forget_console_profile("gone"), Status::Ok);
        assert_eq!(profiles_changed(&mut r), ["gone"]);
    }

    #[test]
    fn forget_refuses_a_hostile_id_without_a_signal() {
        let mut r = router();
        assert_eq!(r.save_profile("p1", SWAP).0, Status::Ok);
        r.take_notices();
        let long = "a".repeat(33);
        for id in ["", "..", "../etc", "a/b", ".", long.as_str(), "p3\n"] {
            assert_eq!(r.forget_console_profile(id), Status::Invalid, "{id:?}");
        }
        assert!(profiles_changed(&mut r).is_empty());
        assert_eq!(
            r.stored_console_profiles(),
            (Status::Ok, vec!["p1".to_owned()])
        );
        // A store that fails: "failed", and the signal still goes (what was read is dropped).
        let store = crate::book::MemStore {
            fail: true,
            ..Default::default()
        };
        r.set_book(Book::new(Box::new(store)));
        assert_eq!(r.forget_console_profile("p1"), Status::Failed);
        let notices = r.take_notices();
        let signals: Vec<&Notice> = notices
            .iter()
            .filter(|n| matches!(n, Notice::ProfilesChanged { .. }))
            .collect();
        assert_eq!(
            signals,
            [&Notice::ProfilesChanged {
                profile: "p1".into()
            }]
        );
        assert!(notices.iter().any(|n| matches!(n, Notice::Journal(l)
            if l.contains("removing the controller profiles of p1 failed"))));
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
        // Pad b is player 2's (RUY-643): its family's profile is player 2's.
        assert_eq!(r.save_profile("p2", family).0, Status::Ok);
        assert_eq!(
            r.assign_profile("p1", "global", "device:a", "own"),
            Status::Ok
        );
        assert_eq!(
            r.assign_profile("p2", "global", "family:nintendo", "fam"),
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
            r.effective_profile("p2", "b", "").2,
            ["fam".to_owned(), "default".to_owned()]
        );
        // Emptying the family's slot: B gets the default, A keeps its own.
        assert_eq!(
            r.assign_profile("p2", "global", "family:nintendo", ""),
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
        // b was p2's: p2 leaves seat 2 and p3 takes it, on the same pad2 (RUY-681: the game keeps
        // its device; before, another player meant a new pad2, which a game like SuperTuxKart
        // does not survive).
        assert_eq!(r.join_player("b", "p3", t0()), (Status::Ok, 2));
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "a"), seat(2, "p3", "b")]);
        let calls = r.backend_mut().take();
        assert!(destroyed(&calls).is_empty() && created(&calls).is_empty());
        assert_eq!(phys_of(&r, b).as_deref(), Some("ruya-input/pad2"));
        assert_eq!(virtual_id(&r, b), Some(2));
        assert_eq!(
            r.pads[&b].virt.as_ref().map(|v| v.player.as_str()),
            Some("p3")
        );
        // Player 1's pad joins as p4: player 1 stays, without a pad (pad1 stays quiet), and a is
        // pad3 now.
        assert_eq!(r.join_player("a", "p4", t0()), (Status::Ok, 3));
        assert_eq!(
            seats_of(&r),
            vec![seat(1, "p1", ""), seat(2, "p3", "b"), seat(3, "p4", "a")]
        );
        assert_eq!(phys_of(&r, a).as_deref(), Some("ruya-input/pad3"));
        assert!(destroyed(&r.backend_mut().take()).is_empty());
        // Player 1 on a new pad takes pad1 back.
        let c = r.add_pad(pad("c"), t0());
        assert_eq!(join(&mut r, c, "p1"), 1);
        assert_eq!(virtual_id(&r, c), Some(1));
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
        // Seat 2's pad2 and seat 1's pad1 stay, quiet, for the game (RUY-681); pad3 stays c's.
        assert!(destroyed(&r.backend_mut().take()).is_empty());
        assert_eq!(r.idle.keys().copied().collect::<Vec<_>>(), vec![1, 2]);
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

    /// What pad `key` sends for a press of South: the button code of its virtual pad.
    fn south_code(r: &mut Router<Fake>, key: PadKey) -> (u64, u16) {
        r.backend_mut().take();
        r.input(key, &[press(PadButton::South)]);
        let w = writes(&r.backend_mut().take());
        r.input(key, &[release(PadButton::South)]);
        r.backend_mut().take();
        assert_eq!(w.len(), 1, "{w:?}");
        assert_eq!(w[0].1.len(), 1, "{w:?}");
        (w[0].0, w[0].1[0].1)
    }

    #[test]
    fn seat_2_uses_player_2s_own_profile_and_a_guest_seat_the_defaults() {
        let (mut r, a, b, c) = three_players();
        let (v1, v2, v3) = (
            virtual_id(&r, a).unwrap(),
            virtual_id(&r, b).unwrap(),
            virtual_id(&r, c).unwrap(),
        );
        // Player 2 swaps A and B in their own profile; player 1 and p3 (no profile files: the
        // defaults, as a guest) keep the standard layout.
        assert_eq!(r.save_profile("p2", SWAP).0, Status::Ok);
        assert_eq!(r.assign_profile("p2", "global", "", "swap"), Status::Ok);
        assert_eq!(south_code(&mut r, b), (v2, code::BTN_EAST));
        assert_eq!(south_code(&mut r, a), (v1, code::BTN_SOUTH));
        assert_eq!(south_code(&mut r, c), (v3, code::BTN_SOUTH));
        // Player 1's own change leaves seat 2 alone.
        r.save_profile("p1", SWAP);
        r.assign_profile("p1", "global", "", "swap");
        assert_eq!(south_code(&mut r, a), (v1, code::BTN_EAST));
        assert_eq!(south_code(&mut r, b), (v2, code::BTN_EAST));
    }

    #[test]
    fn seat_2_pad_is_made_with_player_2s_profile() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        assert_eq!(r.save_profile("p2", SWAP).0, Status::Ok);
        assert_eq!(r.assign_profile("p2", "global", "", "swap"), Status::Ok);
        assert_eq!(join(&mut r, b, "p2"), 2);
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        let (v1, v2) = (virtual_id(&r, a).unwrap(), virtual_id(&r, b).unwrap());
        assert_eq!(south_code(&mut r, b), (v2, code::BTN_EAST));
        assert_eq!(south_code(&mut r, a), (v1, code::BTN_SOUTH));
    }

    #[test]
    fn seat_2_keeps_its_profile_after_a_hold_and_a_move() {
        let (mut r, _a, b, _c) = three_players();
        assert_eq!(r.save_profile("p2", SWAP).0, Status::Ok);
        assert_eq!(r.assign_profile("p2", "global", "", "swap"), Status::Ok);
        let vb = virtual_id(&r, b).unwrap();
        r.remove_pad_at(b, t0());
        // The same pad back within the hold: rebound, still player 2's mapping.
        let b2 = r.add_pad(pad("b"), t0());
        assert_eq!(virtual_id(&r, b2), Some(vb));
        assert_eq!(south_code(&mut r, b2), (vb, code::BTN_EAST));
        // A move to another pad keeps it too.
        let d = r.add_pad(pad("d"), t0());
        assert_eq!(join(&mut r, d, "p2"), 2);
        assert_eq!(south_code(&mut r, d), (vb, code::BTN_EAST));
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
    }

    #[test]
    fn a_pad_that_connects_during_a_hold_gets_no_virtual_pad() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        join(&mut r, b, "p2");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        let t = t0();
        r.remove_pad_at(b, t);
        // An unseated pad that connects during the hold gets nothing, not the held pad2.
        r.backend_mut().take();
        let c = r.add_pad(pad("c"), t);
        assert_eq!(phys_of(&r, c), None);
        assert!(created(&r.backend_mut().take()).is_empty());
        // It holds no seat when it vanishes; the held pad back takes its pad2 again.
        r.remove_pad_at(c, t);
        assert_eq!(held_of(&r), vec![(1, false), (2, true)]);
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

    // ---- the seat gate (on since RUY-122; RUY-121 round 2 ran with it off) ------------------

    fn virtual_id(r: &Router<Fake>, key: PadKey) -> Option<VirtualId> {
        r.pads[&key].virt.as_ref().map(|v| v.id)
    }

    #[test]
    fn an_unseated_pad_reaches_no_app() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        // b signs in, so the seated b is pad1; the unseated a gets no virtual pad.
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
        assert_eq!(creations, vec![(b, "ruya-input/pad1".to_owned())]);
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "b")]);
        let rec = r.devices().into_iter().find(|d| d.id == "a").expect("a");
        assert_eq!((rec.slot, rec.profile.as_str()), (0, ""));
        // Its input reaches no virtual pad.
        r.input(a, &[press(PadButton::South)]);
        assert!(writes(&r.backend_mut().take()).is_empty());
        // Neither does a pad connected while the app is in front.
        let c = r.add_pad(pad("c"), t0());
        assert_eq!(phys_of(&r, c), None);
    }

    #[test]
    fn a_join_gives_a_seat_its_pad_and_a_leave_takes_it() {
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        let c = r.add_pad(pad("c"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        assert_eq!((phys_of(&r, b), phys_of(&r, c)), (None, None));
        let va = virtual_id(&r, a);
        r.backend_mut().take();
        // c joins: it becomes pad2; a keeps its device, b still has none.
        assert_eq!(join(&mut r, c, "p2"), 2);
        assert_eq!(phys_of(&r, c).as_deref(), Some("ruya-input/pad2"));
        assert_eq!((virtual_id(&r, a), phys_of(&r, b)), (va, None));
        assert!(destroyed(&r.backend_mut().take()).is_empty());
        // c leaves: pad2 goes and c has none again; a is untouched.
        let vc = virtual_id(&r, c).expect("pad2");
        assert_eq!(r.leave_player(2, t0()), Status::Ok);
        assert_eq!(destroyed(&r.backend_mut().take()), vec![vc]);
        assert_eq!(phys_of(&r, c), None);
        assert_eq!(virtual_id(&r, a), va);
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "a")]);
    }

    #[test]
    fn the_image_runs_with_the_seat_gate_on() {
        // RUY-122: "Who's playing?" seats a new pad, so the production router (the only one) keeps
        // an unseated pad from the game; local co-op is a join through the prompt.
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        assert_eq!(phys_of(&r, a).as_deref(), Some("ruya-input/pad1"));
        assert_eq!(phys_of(&r, b), None);
    }

    // ---- a pad remembers its player (RUY-124) -------------------------------------------------

    /// Accounts that change under the test: the profiles that still exist, and the guests.
    struct Live {
        profiles: std::sync::Arc<std::sync::Mutex<Vec<&'static str>>>,
        guests: Vec<&'static str>,
        /// How many times the router asked (each is one `/etc/passwd` read in production).
        lookups: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    }

    impl Accounts for Live {
        fn account(&self, profile: &str) -> Option<crate::accounts::Account> {
            self.lookups
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            self.profiles
                .lock()
                .expect("lock")
                .iter()
                .position(|p| *p == profile)
                .map(|i| crate::accounts::Account {
                    uid: 1001 + i as u32,
                    guest: self.guests.contains(&profile),
                })
        }
    }

    type Profiles = std::sync::Arc<std::sync::Mutex<Vec<&'static str>>>;

    type Lookups = std::sync::Arc<std::sync::atomic::AtomicUsize>;

    fn owner_router(guests: Vec<&'static str>) -> (Router<Fake>, Profiles) {
        let (r, profiles, _) = counted_router(guests);
        (r, profiles)
    }

    fn counted_router(guests: Vec<&'static str>) -> (Router<Fake>, Profiles, Lookups) {
        let profiles: Profiles =
            std::sync::Arc::new(std::sync::Mutex::new(vec!["p1", "p2", "p3", "g1"]));
        let lookups = Lookups::default();
        let r = Router::new(
            Fake::default(),
            Box::new(Live {
                profiles: profiles.clone(),
                guests,
                lookups: lookups.clone(),
            }),
        );
        (r, profiles, lookups)
    }

    fn owner_of(r: &Router<Fake>, key: PadKey) -> String {
        r.devices()
            .into_iter()
            .find(|d| d.id == r.pads[&key].info.id)
            .expect("record")
            .owner
    }

    #[test]
    fn a_pad_sign_in_and_a_join_record_the_pads_owner() {
        let (mut r, _) = owner_router(vec![]);
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        assert_eq!(owner_of(&r, a), "");
        sign_in(&mut r, a, "p1");
        assert_eq!(owner_of(&r, a), "p1", "the sign-in");
        assert_eq!(owner_of(&r, b), "");
        assert_eq!(join(&mut r, b, "p2"), 2);
        assert_eq!(owner_of(&r, b), "p2", "the join");
        // The record is announced as it changes.
        assert!(r
            .take_notices()
            .iter()
            .any(|n| matches!(n, Notice::DeviceChanged(d) if d.id == "b" && d.owner == "p2")));
        // The last one wins, and a keyboard sign-in (no pad) records nothing.
        assert_eq!(join(&mut r, b, "p3"), 2);
        assert_eq!(owner_of(&r, b), "p3");
        r.set_route("locked", "", "", "", SHELL, t0());
        r.set_route("shell", "", "", "p2", SHELL, t0());
        assert_eq!(owner_of(&r, a), "p1");
        assert_eq!(owner_of(&r, b), "p3");
    }

    #[test]
    fn a_guest_is_never_a_pads_owner() {
        let (mut r, _) = owner_router(vec!["g1"]);
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        assert_eq!(join(&mut r, b, "g1"), 2);
        assert_eq!(r.owners.get("b"), None, "not recorded");
        assert_eq!(owner_of(&r, b), "");
        // A guest signing in on a pad is not recorded either, and the earlier owner stays.
        let before = r.owners.get("a").map(str::to_owned);
        tap(&mut r, a);
        r.set_route("shell", "", "", "g1", SHELL, t0());
        assert_eq!(r.owners.get("a").map(str::to_owned), before);
    }

    #[test]
    fn an_owner_whose_account_is_gone_reads_empty_and_is_dropped_at_the_next_write() {
        let (mut r, profiles) = owner_router(vec![]);
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        assert_eq!(join(&mut r, b, "p2"), 2);
        profiles.lock().expect("lock").retain(|p| *p != "p2");
        assert_eq!(owner_of(&r, b), "", "p2 was deleted");
        assert_eq!(
            r.owners.get("b"),
            Some("p2"),
            "still in the list until a write"
        );
        assert_eq!(join(&mut r, a, "p3"), 3);
        assert_eq!(r.owners.get("b"), None, "dropped by that write");
        assert_eq!(owner_of(&r, a), "p3");
    }

    #[test]
    fn forgetting_a_profile_announces_each_pad_that_remembered_it() {
        let (mut r, profiles) = owner_router(vec![]);
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        let c = r.add_pad(pad("c"), t0());
        sign_in(&mut r, a, "p1");
        assert_eq!(join(&mut r, b, "p2"), 2);
        assert_eq!(join(&mut r, c, "p1"), 1, "p1 already has seat 1");
        assert_eq!(owner_of(&r, c), "p1");
        r.take_notices();
        // The account is deleted, then the shell forgets the profile (RUY-468).
        profiles.lock().expect("lock").retain(|p| *p != "p1");
        assert_eq!(r.forget_console_profile("p1"), Status::Ok);
        let changed: Vec<(String, String)> = r
            .take_notices()
            .into_iter()
            .filter_map(|n| match n {
                Notice::DeviceChanged(d) => Some((d.id, d.owner)),
                _ => None,
            })
            .collect();
        assert_eq!(
            changed,
            vec![("a".into(), "".into()), ("c".into(), "".into())],
            "one per pad that p1 owned, owner empty; b (p2) is untouched"
        );
        assert_eq!(owner_of(&r, b), "p2");
    }

    #[test]
    fn forgetting_a_profile_whose_account_is_still_there_changes_no_owner() {
        let (mut r, _) = owner_router(vec![]);
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
        r.take_notices();
        assert_eq!(r.forget_console_profile("p1"), Status::Ok);
        assert!(!r
            .take_notices()
            .iter()
            .any(|n| matches!(n, Notice::DeviceChanged(_))));
        assert_eq!(owner_of(&r, a), "p1");
    }

    #[test]
    fn an_owner_is_read_from_the_accounts_once_per_record() {
        let (mut r, _, lookups) = counted_router(vec![]);
        let a = r.add_pad(pad("a"), t0());
        sign_in(&mut r, a, "p1");
        let before = lookups.load(std::sync::atomic::Ordering::SeqCst);
        let _ = owner_of(&r, a);
        assert_eq!(
            lookups.load(std::sync::atomic::Ordering::SeqCst) - before,
            1,
            "uid and guest come from one lookup"
        );
    }

    #[test]
    fn the_owners_survive_a_restart_of_the_service() {
        let dir = tempfile::tempdir().expect("dir");
        let (mut r, _) = owner_router(vec![]);
        r.set_owners(Owners::load(dir.path().to_path_buf()));
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        assert_eq!(join(&mut r, b, "p2"), 2);
        let (mut again, _) = owner_router(vec![]);
        again.set_owners(Owners::load(dir.path().to_path_buf()));
        let b2 = again.add_pad(pad("b"), t0());
        assert_eq!(owner_of(&again, b2), "p2");
    }

    // ---- split-screen co-op under a game (RUY-681) -------------------------------------------

    /// The Dell of RUY-681: x (a Wii U Pro) signs p1 in, y (a DualSense) joins as `seat2`
    /// ("g1" is a temporary guest), and p1's game is in front with every pad made.
    fn coop(seat2: &str) -> (Router<Fake>, PadKey, PadKey) {
        let (mut r, _) = owner_router(vec!["g1"]);
        let x = r.add_pad(
            PadInfo {
                name: "Nintendo Wii Remote Pro Controller".into(),
                family: "nintendo".into(),
                model: String::new(),
                ..pad("x")
            },
            t0(),
        );
        let y = r.add_pad(pad("y"), t0());
        sign_in(&mut r, x, "p1");
        assert_eq!(join(&mut r, y, seat2), 2);
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        r.take_notices();
        (r, x, y)
    }

    /// A press and a full stick on seat 2's pad reach pad2's device as they are (the defaults:
    /// a guest has no controller profiles, nor has p2 here), never pad1; the game's user can
    /// open pad2, and its record says it is routed to seat 2.
    fn seat_2_reaches_pad2(seat2: &str) {
        let (mut r, x, y) = coop(seat2);
        assert_eq!(phys_of(&r, x).as_deref(), Some("ruya-input/pad1"));
        assert_eq!(phys_of(&r, y).as_deref(), Some("ruya-input/pad2"));
        let (v1, v2) = (virtual_id(&r, x).unwrap(), virtual_id(&r, y).unwrap());
        r.backend_mut().take();
        r.input(
            y,
            &[
                press(PadButton::South),
                PadInput::Axis(PadAxis::LeftX, STICK_MAX),
            ],
        );
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(
                v2,
                vec![
                    (code::EV_KEY, code::BTN_SOUTH, 1),
                    (code::EV_ABS, code::ABS_X, STICK_MAX)
                ]
            )]
        );
        r.input(x, &[press(PadButton::East)]);
        assert_eq!(
            writes(&r.backend_mut().take()),
            vec![(v1, vec![(code::EV_KEY, code::BTN_EAST, 1)])]
        );
        // pad2's node, once udev announced it, carries the one ACL entry of the game's user (p1,
        // uid 1001), so the game can open it.
        let sysname = r.pads[&y].virt.as_ref().unwrap().sysname.clone();
        r.udev_event(&udev("add", &sysname));
        let acl = r.backend().acls.get("/dev/input/event17").cloned();
        let acl = acl.unwrap_or_default();
        assert!(acl::is_only_user(&acl, 1001), "pad2's ACL is p1's");
        let rec = r.devices().into_iter().find(|d| d.id == "y").expect("y");
        assert_eq!(
            (rec.slot, rec.profile.as_str(), rec.routed),
            (2, seat2, true)
        );
    }

    #[test]
    fn a_temporary_guest_in_seat_2_reaches_pad2_under_the_game() {
        seat_2_reaches_pad2("g1");
    }

    #[test]
    fn a_kept_profile_in_seat_2_reaches_pad2_under_the_game() {
        seat_2_reaches_pad2("p2");
    }

    #[test]
    fn every_seat_has_its_pad_when_the_game_comes_in_front_and_a_focus_change_makes_none() {
        let (mut r, _) = owner_router(vec!["g1"]);
        let x = r.add_pad(pad("x"), t0());
        let y = r.add_pad(pad("y"), t0());
        let z = r.add_pad(pad("z"), t0());
        sign_in(&mut r, x, "p1");
        join(&mut r, y, "g1");
        join(&mut r, z, "p2");
        // The SetRoute "app" for the new instance makes every seat's pad, before any udev event.
        app(&mut r, "i1", STK, "p1");
        let made: Vec<String> = created(&r.backend_mut().take())
            .into_iter()
            .map(|s| s.phys)
            .collect();
        assert_eq!(
            made,
            vec!["ruya-input/pad1", "ruya-input/pad2", "ruya-input/pad3"]
        );
        // The Hub over the game and the game in front again (the focus moving away and back) make
        // and destroy nothing.
        settle(&mut r);
        r.backend_mut().take();
        r.set_route("overlay", "i1", STK, "p1", SHELL, t0());
        app(&mut r, "i1", STK, "p1");
        let calls = r.backend_mut().take();
        assert!(created(&calls).is_empty() && destroyed(&calls).is_empty());
    }

    #[test]
    fn a_seat_whose_pad_goes_keeps_its_virtual_pad_past_the_hold_until_the_game_ends() {
        // The Dell of RUY-681: the DualSense powers off mid-race and stays off past the hold.
        let (mut r, x, y) = coop("g1");
        let (v1, v2) = (virtual_id(&r, x).unwrap(), virtual_id(&r, y).unwrap());
        r.input(y, &[press(PadButton::South)]);
        r.backend_mut().take();
        let t = t0();
        r.remove_pad_at(y, t);
        r.tick(t + SEAT_HOLD + Duration::from_secs(1));
        // The seat ends (the player is gone), pad2 does not: one neutral frame and nothing else.
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "x")]);
        let calls = r.backend_mut().take();
        assert!(destroyed(&calls).is_empty(), "{calls:?}");
        assert_eq!(
            writes(&calls),
            vec![(v2, vec![(code::EV_KEY, code::BTN_SOUTH, 0)])]
        );
        assert!(r.backend().alive.contains(&v2));
        let lines = journal(&mut r);
        assert!(
            lines.contains(&"virtual pad ruya-input/pad2 stays quiet: its seat has no pad".into()),
            "{lines:?}"
        );
        // The game's rumble on the quiet pad is kept, nothing reaches a pad.
        let rumble = Rumble {
            strong: 1000,
            weak: 1000,
            length_ms: 100,
            delay_ms: 0,
        };
        assert_eq!(r.ff_upload(v2, 0, &rumble), Ok(()));
        r.ff_play(v2, 0, 1);
        assert!(r.backend_mut().take().is_empty());
        // The Hub over the game and back: still there.
        r.set_route("overlay", "i1", STK, "p1", SHELL, t0());
        app(&mut r, "i1", STK, "p1");
        r.tick(t + SEAT_HOLD * 3);
        assert!(destroyed(&r.backend_mut().take()).is_empty());
        // The game ends: pad1 and pad2 go with it.
        r.set_route("shell", "", "", "p1", SHELL, t0());
        let mut gone = destroyed(&r.backend_mut().take());
        gone.sort_unstable();
        assert_eq!(gone, vec![v1, v2]);
        assert!(r.idle.is_empty());
    }

    #[test]
    fn pad_numbers_stay_across_a_hold_its_end_and_a_rejoin() {
        let (mut r, _a, b, c) = three_players();
        let (vb, vc) = (virtual_id(&r, b).unwrap(), virtual_id(&r, c).unwrap());
        let t = t0();
        r.remove_pad_at(b, t);
        r.remove_pad_at(c, t);
        r.tick(t + SEAT_HOLD);
        assert_eq!(seats_of(&r), vec![seat(1, "p1", "a")]);
        r.backend_mut().take();
        // p3 is back first: seat 3 and its own pad3 again, not the lowest free seat (2).
        let c2 = r.add_pad(pad("c"), t + SEAT_HOLD);
        assert_eq!(join(&mut r, c2, "p3"), 3);
        assert_eq!(virtual_id(&r, c2), Some(vc));
        // A newcomer gets the next number the game has no pad for (4): one hotplug.
        let d = r.add_pad(pad("d"), t + SEAT_HOLD);
        assert_eq!(join(&mut r, d, "p4"), 4);
        assert_eq!(phys_of(&r, d).as_deref(), Some("ruya-input/pad4"));
        let calls = r.backend_mut().take();
        assert_eq!(created(&calls).len(), 1, "{calls:?}");
        // p2 back: seat 2 and its pad2; a press reaches it.
        let b2 = r.add_pad(pad("b"), t + SEAT_HOLD);
        assert_eq!(join(&mut r, b2, "p2"), 2);
        assert_eq!(virtual_id(&r, b2), Some(vb));
        assert_eq!(south_code(&mut r, b2), (vb, code::BTN_SOUTH));
        assert!(destroyed(&r.backend_mut().take()).is_empty());
        // With every free seat's number taken by a quiet pad, a newcomer takes one over (its own
        // controller profiles), rather than a new device.
        r.remove_pad_at(b2, t + SEAT_HOLD);
        r.tick(t + SEAT_HOLD * 2);
        assert_eq!(r.idle.keys().copied().collect::<Vec<_>>(), vec![2]);
        assert_eq!(r.save_profile("p5", SWAP).0, Status::Ok);
        assert_eq!(r.assign_profile("p5", "global", "", "swap"), Status::Ok);
        let e = r.add_pad(pad("e"), t + SEAT_HOLD * 2);
        assert_eq!(join(&mut r, e, "p5"), 2);
        assert_eq!(virtual_id(&r, e), Some(vb));
        assert_eq!(south_code(&mut r, e), (vb, code::BTN_EAST));
        let calls = r.backend_mut().take();
        assert!(created(&calls).is_empty() && destroyed(&calls).is_empty());
        // Leaving through the Hub (LeavePlayer) destroys the seat's pad, also a quiet one.
        r.remove_pad_at(e, t + SEAT_HOLD * 2);
        r.tick(t + SEAT_HOLD * 3);
        r.backend_mut().take();
        assert_eq!(r.leave_player(2, t0()), Status::Ok);
        assert_eq!(destroyed(&r.backend_mut().take()), vec![vb]);
        assert!(r.idle.is_empty());
    }

    // ---- PreparePads (RUY-837) ----------------------------------------------------------------

    /// The `PadsPrepared` notices since the last call (the rest is dropped).
    fn prepared(r: &mut Router<Fake>) -> Vec<(String, String, Status)> {
        r.take_notices()
            .into_iter()
            .filter_map(|n| match n {
                Notice::PadsPrepared {
                    app_id,
                    profile,
                    status,
                } => Some((app_id, profile, status)),
                _ => None,
            })
            .collect()
    }

    fn done(app_id: &str, status: Status) -> Vec<(String, String, Status)> {
        vec![(app_id.to_owned(), "p1".to_owned(), status)]
    }

    #[test]
    fn prepared_pads_are_ready_before_the_game_and_its_first_route_keeps_them() {
        // Neverball opens its pad once at start-up (the Dell, 0.0.90): the pads and their ACLs
        // must be there before the game runs, while the shell is still in front.
        let mut r = router();
        let a = r.add_pad(pad("a"), t0());
        let b = r.add_pad(pad("b"), t0());
        sign_in(&mut r, a, "p1");
        join(&mut r, b, "p2");
        r.backend_mut().take();
        r.take_notices();
        assert_eq!(r.prepare_pads(STK, "p1", t0()), Status::Ok);
        assert_eq!(
            order(&r.backend_mut().take()),
            vec![
                format!("create {a} ruya-input/pad1"),
                format!("create {b} ruya-input/pad2"),
            ]
        );
        // No route change, and no answer before the ACLs are set.
        assert_eq!(r.route(), Route::Shell);
        let notices = r.take_notices();
        assert!(
            !notices
                .iter()
                .any(|n| matches!(n, Notice::RouteChanged { .. } | Notice::PadsPrepared { .. })),
            "{notices:?}"
        );
        r.udev_event(&udev_node("add", "input101", "/dev/input/event21"));
        assert!(prepared(&mut r).is_empty(), "pad2 is not ready yet");
        r.udev_event(&udev_node("add", "input102", "/dev/input/event22"));
        assert_eq!(
            order(&r.backend_mut().take()),
            vec!["acl /dev/input/event21", "acl /dev/input/event22"]
        );
        assert_eq!(prepared(&mut r), done(STK, Status::Ok));
        assert!(acl::is_only_user(
            &r.backend().acls["/dev/input/event21"],
            P1_UID
        ));
        // Pad input still navigates the shell, and reaches no virtual pad.
        r.input(a, &[press(PadButton::South)]);
        r.input(a, &[release(PadButton::South)]);
        let calls = r.backend_mut().take();
        assert!(!nav(&calls).is_empty(), "{calls:?}");
        assert!(
            !calls.iter().any(|c| matches!(c, Call::Write(..))),
            "{calls:?}"
        );
        // The shell, an overlay over another game, then the game's own window: the same devices.
        let (va, vb) = (virtual_id(&r, a), virtual_id(&r, b));
        assert_eq!(r.set_route("shell", "", "", "p1", SHELL, t0()), Status::Ok);
        assert_eq!(
            r.set_route("overlay", "old", RACER, "p1", SHELL, t0()),
            Status::Ok
        );
        assert_eq!(
            r.set_route("overlay", "", "", "p1", SHELL, t0()),
            Status::Ok
        );
        app(&mut r, "i1", STK, "p1");
        let calls = r.backend_mut().take();
        assert!(
            created(&calls).is_empty() && destroyed(&calls).is_empty(),
            "{calls:?}"
        );
        assert_eq!((virtual_id(&r, a), virtual_id(&r, b)), (va, vb));
        assert!(journal(&mut r)
            .iter()
            .any(|l| l == &format!("prepared pads for {STK} bound to instance 'i1'")));
        assert_eq!(south_code(&mut r, a).0, va.expect("pad1"));
        // Bound: they are the instance's pads now, gone with it as before.
        assert_eq!(r.set_route("shell", "", "", "p1", SHELL, t0()), Status::Ok);
        assert_eq!(destroyed(&r.backend_mut().take()).len(), 2);
    }

    #[test]
    fn preparing_pads_is_refused_outside_the_shell_and_answers_at_once_with_no_pad() {
        let mut r = router();
        // Nobody signed in: the route's profile is "".
        assert_eq!(r.prepare_pads(STK, "p1", t0()), Status::NotAllowed);
        assert_eq!(r.prepare_pads("neverball", "p1", t0()), Status::Invalid);
        assert_eq!(r.prepare_pads(STK, "root", t0()), Status::UnknownProfile);
        assert_eq!(r.prepare_pads(STK, "Bad!", t0()), Status::UnknownProfile);
        // A keyboard sign-in: no seated pad, nothing to wait for.
        assert_eq!(r.set_route("shell", "", "", "p1", SHELL, t0()), Status::Ok);
        r.take_notices();
        assert_eq!(
            r.prepare_pads(STK, "p2", t0()),
            Status::NotAllowed,
            "not the route's"
        );
        assert_eq!(r.prepare_pads(STK, "p1", t0()), Status::Ok);
        assert_eq!(prepared(&mut r), done(STK, Status::Ok));
        // Again: answered again, nothing made.
        assert_eq!(r.prepare_pads(STK, "p1", t0()), Status::Ok);
        assert_eq!(prepared(&mut r), done(STK, Status::Ok));
        app(&mut r, "i1", STK, "p1");
        assert_eq!(
            r.prepare_pads(RACER, "p1", t0()),
            Status::NotAllowed,
            "a game is in front"
        );
        assert_eq!(r.set_route("locked", "", "", "", SHELL, t0()), Status::Ok);
        assert_eq!(r.prepare_pads(STK, "p1", t0()), Status::NotAllowed);
    }

    #[test]
    fn a_preparation_ends_with_a_lock_another_game_or_its_time() {
        let start = t0();
        let mut r = router();
        let a = r.add_pad(pad("a"), start);
        sign_in(&mut r, a, "p1");
        // A lock before the ACL: the waiting call learns it, the pad goes.
        assert_eq!(r.prepare_pads(STK, "p1", start), Status::Ok);
        assert_eq!(r.set_route("locked", "", "", "", SHELL, start), Status::Ok);
        assert_eq!(prepared(&mut r), done(STK, Status::NotAllowed));
        assert_eq!(destroyed(&r.backend_mut().take()).len(), 1);
        // Another game prepared: the first one's answer, then new pads for the second.
        sign_in(&mut r, a, "p1");
        assert_eq!(r.prepare_pads(STK, "p1", start), Status::Ok);
        assert_eq!(r.prepare_pads(RACER, "p1", start), Status::Ok);
        assert_eq!(prepared(&mut r), done(STK, Status::NotAllowed));
        let calls = r.backend_mut().take();
        assert_eq!((created(&calls).len(), destroyed(&calls).len()), (2, 1));
        // Another app comes to the front: its own pads, the prepared ones go.
        app(&mut r, "i9", STK, "p1");
        assert_eq!(prepared(&mut r), done(RACER, Status::NotAllowed));
        let calls = r.backend_mut().take();
        assert_eq!((created(&calls).len(), destroyed(&calls).len()), (1, 1));
        // No route takes them: they go after PREPARE_TTL.
        assert_eq!(r.set_route("shell", "", "", "p1", SHELL, start), Status::Ok);
        r.backend_mut().take();
        assert_eq!(r.prepare_pads(STK, "p1", start), Status::Ok);
        r.udev_event(&udev_node("add", "input105", "/dev/input/event25"));
        assert_eq!(prepared(&mut r), done(STK, Status::Ok));
        r.tick(start + PREPARE_TTL - Duration::from_secs(1));
        assert!(destroyed(&r.backend_mut().take()).is_empty());
        r.tick(start + PREPARE_TTL);
        assert_eq!(destroyed(&r.backend_mut().take()).len(), 1);
        assert!(journal(&mut r)
            .iter()
            .any(|l| l == &format!("prepared pads for {STK} were not used in 60 s")));
        app(&mut r, "i1", STK, "p1");
        assert_eq!(
            created(&r.backend_mut().take()).len(),
            1,
            "made again for the game"
        );
        // An ACL that cannot be set: answered "failed" once the udev fallback ran.
        assert_eq!(r.set_route("shell", "", "", "p1", SHELL, start), Status::Ok);
        r.backend_mut().acl_fails = true;
        r.take_notices();
        assert_eq!(r.prepare_pads(STK, "p1", start), Status::Ok);
        r.tick(start + UDEV_FALLBACK - Duration::from_millis(1));
        assert!(prepared(&mut r).is_empty());
        r.tick(start + UDEV_FALLBACK);
        assert_eq!(prepared(&mut r), done(STK, Status::Failed));
    }

    // ---- a held game's pads during a preparation (RUY-840) ------------------------------------

    /// Game `i1` (STK) runs with pad a and is held behind Home (`overlay`); RACER is prepared.
    fn held_then_prepared(start: Instant) -> (Router<Fake>, PadKey, VirtualId) {
        let mut r = router();
        let a = r.add_pad(pad("a"), start);
        sign_in(&mut r, a, "p1");
        app(&mut r, "i1", STK, "p1");
        settle(&mut r);
        let va = virtual_id(&r, a).expect("the held game's pad");
        assert_eq!(
            r.set_route("overlay", "i1", STK, "p1", SHELL, start),
            Status::Ok
        );
        r.backend_mut().take();
        r.take_notices();
        assert_eq!(r.prepare_pads(RACER, "p1", start), Status::Ok);
        let calls = r.backend_mut().take();
        assert!(destroyed(&calls).is_empty(), "{calls:?}");
        assert_eq!(created(&calls).len(), 1);
        assert_ne!(virtual_id(&r, a), Some(va));
        (r, a, va)
    }

    #[test]
    fn a_failed_launch_gives_the_held_game_its_pads_back() {
        let start = t0();
        let (mut r, a, va) = held_then_prepared(start);
        assert_eq!(prepared(&mut r).len(), 0);
        // The shell may say `overlay` for the held game meanwhile: the preparation waits on.
        assert_eq!(
            r.set_route("overlay", "i1", STK, "p1", SHELL, start),
            Status::Ok
        );
        assert!(r.stash.is_some() && r.prepared.is_some());
        assert_eq!(
            r.set_route("app", "i1", STK, "p1", SHELL, start),
            Status::Ok
        );
        assert_eq!(prepared(&mut r), done(RACER, Status::NotAllowed));
        let calls = r.backend_mut().take();
        assert!(created(&calls).is_empty(), "{calls:?}");
        assert_eq!(
            destroyed(&calls).len(),
            1,
            "only the prepared pad: {calls:?}"
        );
        assert!(!destroyed(&calls).contains(&va));
        assert_eq!(virtual_id(&r, a), Some(va));
        assert_eq!(south_code(&mut r, a).0, va);
        assert!(r.stash.is_none());
    }

    #[test]
    fn the_new_games_first_route_destroys_the_held_pads_and_binds_the_prepared_ones() {
        let start = t0();
        let (mut r, a, va) = held_then_prepared(start);
        let vb = virtual_id(&r, a).unwrap();
        app(&mut r, "i2", RACER, "p1");
        let calls = r.backend_mut().take();
        assert_eq!(destroyed(&calls), vec![va], "{calls:?}");
        assert!(created(&calls).is_empty());
        assert_eq!(virtual_id(&r, a), Some(vb));
        assert!(r.stash.is_none());
        assert_eq!(south_code(&mut r, a).0, vb);
        // Gone with the new game, nothing else left.
        assert_eq!(r.set_route("shell", "", "", "p1", SHELL, start), Status::Ok);
        assert_eq!(destroyed(&r.backend_mut().take()), vec![vb]);
    }

    #[test]
    fn an_unused_preparation_expires_and_the_held_game_has_its_pads_again() {
        let start = t0();
        let (mut r, a, va) = held_then_prepared(start);
        r.tick(start + PREPARE_TTL);
        let calls = r.backend_mut().take();
        assert_eq!(destroyed(&calls).len(), 1, "{calls:?}");
        assert!(created(&calls).is_empty());
        assert_eq!(virtual_id(&r, a), Some(va));
        let lines = journal(&mut r);
        assert!(lines
            .iter()
            .any(|l| l == &format!("prepared pads for {RACER} were not used in 60 s")));
        assert!(lines
            .iter()
            .any(|l| l == "pads of instance 'i1' are the game's again: the preparation expired"));
        app(&mut r, "i1", STK, "p1");
        assert_eq!(south_code(&mut r, a).0, va);
    }

    #[test]
    fn a_third_game_prepared_gives_the_held_pads_back_and_sets_them_aside_again() {
        let start = t0();
        let (mut r, a, va) = held_then_prepared(start);
        assert_eq!(r.prepare_pads("org.ruyaos.Third", "p1", start), Status::Ok);
        let calls = r.backend_mut().take();
        assert_eq!(destroyed(&calls).len(), 1, "{calls:?}");
        assert_eq!(created(&calls).len(), 1);
        assert!(!destroyed(&calls).contains(&va));
        // The held game is still the one to get them back.
        assert_eq!(
            r.set_route("app", "i1", STK, "p1", SHELL, start),
            Status::Ok
        );
        assert_eq!(virtual_id(&r, a), Some(va));
    }

    #[test]
    fn a_lock_or_a_profile_switch_leaves_no_set_aside_pad() {
        let start = t0();
        let (mut r, _a, va) = held_then_prepared(start);
        assert_eq!(r.set_route("locked", "", "", "", SHELL, start), Status::Ok);
        let calls = r.backend_mut().take();
        assert_eq!(destroyed(&calls).len(), 2, "{calls:?}");
        assert!(destroyed(&calls).contains(&va));
        assert!(r.stash.is_none());
        assert!(r.pads.values().all(|p| p.virt.is_none()) && r.idle.is_empty());

        let (mut r, _a, va) = held_then_prepared(start);
        assert_eq!(r.set_route("shell", "", "", "p2", SHELL, start), Status::Ok);
        let calls = r.backend_mut().take();
        assert_eq!(destroyed(&calls).len(), 2, "{calls:?}");
        assert!(destroyed(&calls).contains(&va));
        assert!(r.stash.is_none());
        assert!(r.pads.values().all(|p| p.virt.is_none()) && r.idle.is_empty());
    }

    #[test]
    fn a_preparation_with_no_held_game_sets_nothing_aside() {
        let start = t0();
        let mut r = router();
        let a = r.add_pad(pad("a"), start);
        sign_in(&mut r, a, "p1");
        assert_eq!(r.prepare_pads(STK, "p1", start), Status::Ok);
        assert!(r.stash.is_none());
        // An owner with no instance (a preparation) is not a held game either.
        assert_eq!(r.prepare_pads(RACER, "p1", start), Status::Ok);
        assert!(r.stash.is_none());
    }

    #[test]
    fn set_aside_pads_cannot_be_opened_by_the_new_game_and_open_again_on_return() {
        let start = t0();
        let (mut r, a, va) = held_then_prepared(start);
        let sysname = r.stash.as_ref().unwrap().pads[&a].sysname.clone();
        let node_a = format!("/dev/input/event-{sysname}");
        let _ = va;
        // The held game's node was opened for the profile; set aside it is closed.
        assert_eq!(r.backend().acls[&node_a], acl::closed());
        assert!(!acl::is_only_user(&r.backend().acls[&node_a], P1_UID));
        r.set_route("app", "i1", STK, "p1", SHELL, start);
        assert!(acl::is_only_user(&r.backend().acls[&node_a], P1_UID));
    }

    #[test]
    fn a_preparation_that_ends_after_the_held_game_exited_leaves_no_pad() {
        let start = t0();
        let (mut r, _a, _va) = held_then_prepared(start);
        assert_eq!(r.set_route("shell", "", "", "p1", SHELL, start), Status::Ok);
        r.backend_mut().take();
        r.tick(start + PREPARE_TTL);
        assert!(r.stash.is_none() && r.prepared.is_none());
        assert!(r.pads.values().all(|p| p.virt.is_none()) && r.idle.is_empty());
        let calls = r.backend_mut().take();
        assert!(created(&calls).is_empty(), "{calls:?}");
    }

    #[test]
    fn a_pad_unplugged_while_set_aside_loses_its_held_pad() {
        let start = t0();
        let (mut r, a, va) = held_then_prepared(start);
        r.remove_pad_at(a, start);
        let calls = r.backend_mut().take();
        assert!(destroyed(&calls).contains(&va), "{calls:?}");
        assert!(r.stash.as_ref().is_some_and(|s| s.pads.is_empty()));
    }
}
