//! Normalised pad input (06-input.md §4.2) and the Xbox 360-style virtual pad it drives.
//!
//! Pure: evdev codes are plain numbers here, so the conversion from a physical pad's events and
//! the events written to a virtual pad are unit-tested on any host.

/// Linux event types and codes used here (linux/input-event-codes.h).
pub mod code {
    pub const EV_SYN: u16 = 0x00;
    pub const EV_KEY: u16 = 0x01;
    pub const EV_ABS: u16 = 0x03;
    pub const EV_FF: u16 = 0x15;

    pub const BTN_SOUTH: u16 = 0x130;
    pub const BTN_EAST: u16 = 0x131;
    /// `BTN_X`: on xpad (Xbox family) the west button, by gamepad.rst the north one.
    pub const BTN_X: u16 = 0x133;
    /// `BTN_Y`: on xpad the north button, by gamepad.rst the west one.
    pub const BTN_Y: u16 = 0x134;
    pub const BTN_TL: u16 = 0x136;
    pub const BTN_TR: u16 = 0x137;
    pub const BTN_TL2: u16 = 0x138;
    pub const BTN_TR2: u16 = 0x139;
    pub const BTN_SELECT: u16 = 0x13a;
    pub const BTN_START: u16 = 0x13b;
    pub const BTN_MODE: u16 = 0x13c;
    pub const BTN_THUMBL: u16 = 0x13d;
    pub const BTN_THUMBR: u16 = 0x13e;
    pub const BTN_DPAD_UP: u16 = 0x220;
    pub const BTN_DPAD_DOWN: u16 = 0x221;
    pub const BTN_DPAD_LEFT: u16 = 0x222;
    pub const BTN_DPAD_RIGHT: u16 = 0x223;

    pub const ABS_X: u16 = 0x00;
    pub const ABS_Y: u16 = 0x01;
    pub const ABS_Z: u16 = 0x02;
    pub const ABS_RX: u16 = 0x03;
    pub const ABS_RY: u16 = 0x04;
    pub const ABS_RZ: u16 = 0x05;
    pub const ABS_HAT0X: u16 = 0x10;
    pub const ABS_HAT0Y: u16 = 0x11;

    pub const FF_RUMBLE: u16 = 0x50;
}

/// Buttons by position (06-input.md §4.2), the subset an Xbox 360 pad carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum PadButton {
    South,
    East,
    West,
    North,
    L1,
    R1,
    Select,
    Start,
    Guide,
    L3,
    R3,
    DpadUp,
    DpadDown,
    DpadLeft,
    DpadRight,
}

pub const ALL_BUTTONS: [PadButton; 15] = [
    PadButton::South,
    PadButton::East,
    PadButton::West,
    PadButton::North,
    PadButton::L1,
    PadButton::R1,
    PadButton::Select,
    PadButton::Start,
    PadButton::Guide,
    PadButton::L3,
    PadButton::R3,
    PadButton::DpadUp,
    PadButton::DpadDown,
    PadButton::DpadLeft,
    PadButton::DpadRight,
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum PadAxis {
    LeftX,
    LeftY,
    RightX,
    RightY,
    LeftTrigger,
    RightTrigger,
}

pub const ALL_AXES: [PadAxis; 6] = [
    PadAxis::LeftX,
    PadAxis::LeftY,
    PadAxis::RightX,
    PadAxis::RightY,
    PadAxis::LeftTrigger,
    PadAxis::RightTrigger,
];

/// Sticks are -32768..32767 (up negative), triggers 0..32767 (06-input.md §4.2).
pub const STICK_MIN: i32 = -32768;
pub const STICK_MAX: i32 = 32767;
pub const TRIGGER_MAX: i32 = 32767;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PadInput {
    Button(PadButton, bool),
    Axis(PadAxis, i32),
}

/// An axis range as the kernel reports it (`input_absinfo` minimum and maximum).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Range {
    pub min: i32,
    pub max: i32,
}

/// What the normaliser needs to know about one physical pad.
#[derive(Debug, Clone, Default)]
pub struct PadLayout {
    /// xpad (the Xbox family) reports the west button as `BTN_X` and the north one as `BTN_Y`;
    /// hid-playstation, hid-nintendo and gamepad.rst the other way round.
    pub xbox_xy: bool,
    pub ranges: Vec<(u16, Range)>,
}

impl PadLayout {
    fn range(&self, abs: u16) -> Option<Range> {
        self.ranges.iter().find(|(c, _)| *c == abs).map(|&(_, r)| r)
    }

    fn has(&self, abs: u16) -> bool {
        self.range(abs).is_some()
    }
}

/// Scales `value` from `range` onto `out_min..=out_max`, clamped.
fn scale(value: i32, range: Range, out_min: i32, out_max: i32) -> i32 {
    let span = range.max as i64 - range.min as i64;
    if span <= 0 {
        return out_min.max(0).min(out_max);
    }
    let v = (value as i64).clamp(range.min as i64, range.max as i64) - range.min as i64;
    let out = out_min as i64 + v * (out_max as i64 - out_min as i64) / span;
    out as i32
}

/// Turns one physical pad's evdev events into normalised input. Keeps the hat state, so a hat
/// that jumps from -1 to 1 releases one direction and presses the other.
#[derive(Debug, Default)]
pub struct Normalizer {
    layout: PadLayout,
    hat: [i32; 2],
}

impl Normalizer {
    pub fn new(layout: PadLayout) -> Self {
        Normalizer {
            layout,
            hat: [0; 2],
        }
    }

    /// One evdev event (`type`, `code`, `value`); key autorepeat (value 2) is dropped.
    pub fn event(&mut self, ev_type: u16, ev_code: u16, value: i32) -> Vec<PadInput> {
        match ev_type {
            code::EV_KEY if value != 2 => self.key(ev_code, value == 1),
            code::EV_ABS => self.abs(ev_code, value),
            _ => Vec::new(),
        }
    }

    fn key(&mut self, ev_code: u16, pressed: bool) -> Vec<PadInput> {
        use PadButton::*;
        let (west, north) = if self.layout.xbox_xy {
            (code::BTN_X, code::BTN_Y)
        } else {
            (code::BTN_Y, code::BTN_X)
        };
        let button = match ev_code {
            code::BTN_SOUTH => South,
            code::BTN_EAST => East,
            c if c == west => West,
            c if c == north => North,
            code::BTN_TL => L1,
            code::BTN_TR => R1,
            code::BTN_SELECT => Select,
            code::BTN_START => Start,
            code::BTN_MODE => Guide,
            code::BTN_THUMBL => L3,
            code::BTN_THUMBR => R3,
            code::BTN_DPAD_UP => DpadUp,
            code::BTN_DPAD_DOWN => DpadDown,
            code::BTN_DPAD_LEFT => DpadLeft,
            code::BTN_DPAD_RIGHT => DpadRight,
            // Digital triggers count only on a pad without the analog axis (a DualSense reports
            // both: the axis is the real value).
            code::BTN_TL2 if !self.layout.has(code::ABS_Z) => {
                let v = if pressed { TRIGGER_MAX } else { 0 };
                return vec![PadInput::Axis(PadAxis::LeftTrigger, v)];
            }
            code::BTN_TR2 if !self.layout.has(code::ABS_RZ) => {
                let v = if pressed { TRIGGER_MAX } else { 0 };
                return vec![PadInput::Axis(PadAxis::RightTrigger, v)];
            }
            _ => return Vec::new(),
        };
        vec![PadInput::Button(button, pressed)]
    }

    fn abs(&mut self, ev_code: u16, value: i32) -> Vec<PadInput> {
        let stick = |axis| {
            let range = self.layout.range(ev_code).unwrap_or(Range {
                min: STICK_MIN,
                max: STICK_MAX,
            });
            vec![PadInput::Axis(
                axis,
                scale(value, range, STICK_MIN, STICK_MAX),
            )]
        };
        let trigger = |axis| {
            let range = self
                .layout
                .range(ev_code)
                .unwrap_or(Range { min: 0, max: 255 });
            vec![PadInput::Axis(axis, scale(value, range, 0, TRIGGER_MAX))]
        };
        match ev_code {
            code::ABS_X => stick(PadAxis::LeftX),
            code::ABS_Y => stick(PadAxis::LeftY),
            code::ABS_RX => stick(PadAxis::RightX),
            code::ABS_RY => stick(PadAxis::RightY),
            code::ABS_Z => trigger(PadAxis::LeftTrigger),
            code::ABS_RZ => trigger(PadAxis::RightTrigger),
            code::ABS_HAT0X => {
                self.hat(0, value.signum(), PadButton::DpadLeft, PadButton::DpadRight)
            }
            code::ABS_HAT0Y => self.hat(1, value.signum(), PadButton::DpadUp, PadButton::DpadDown),
            _ => Vec::new(),
        }
    }

    fn hat(&mut self, i: usize, value: i32, neg: PadButton, pos: PadButton) -> Vec<PadInput> {
        let old = std::mem::replace(&mut self.hat[i], value);
        let mut out = Vec::new();
        if old == value {
            return out;
        }
        match old {
            -1 => out.push(PadInput::Button(neg, false)),
            1 => out.push(PadInput::Button(pos, false)),
            _ => {}
        }
        match value {
            -1 => out.push(PadInput::Button(neg, true)),
            1 => out.push(PadInput::Button(pos, true)),
            _ => {}
        }
        out
    }
}

/// The state of one pad: buttons held and axis values, normalised.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PadState {
    buttons: Vec<PadButton>,
    axes: [i32; 6],
}

fn axis_index(axis: PadAxis) -> usize {
    ALL_AXES.iter().position(|&a| a == axis).unwrap_or(0)
}

impl PadState {
    pub fn apply(&mut self, input: PadInput) {
        match input {
            PadInput::Button(b, true) => {
                if !self.buttons.contains(&b) {
                    self.buttons.push(b);
                    self.buttons.sort();
                }
            }
            PadInput::Button(b, false) => self.buttons.retain(|&x| x != b),
            PadInput::Axis(a, v) => self.axes[axis_index(a)] = v,
        }
    }

    pub fn pressed(&self, b: PadButton) -> bool {
        self.buttons.contains(&b)
    }

    pub fn axis(&self, a: PadAxis) -> i32 {
        self.axes[axis_index(a)]
    }

    pub fn buttons(&self) -> &[PadButton] {
        &self.buttons
    }

    pub fn is_neutral(&self) -> bool {
        self.buttons.is_empty() && self.axes.iter().all(|&v| v == 0)
    }
}

impl PadButton {
    /// The normalised name (06-input.md §4.2), as the button test sends it.
    pub fn name(self) -> &'static str {
        match self {
            PadButton::South => "south",
            PadButton::East => "east",
            PadButton::West => "west",
            PadButton::North => "north",
            PadButton::L1 => "l1",
            PadButton::R1 => "r1",
            PadButton::Select => "select",
            PadButton::Start => "start",
            PadButton::Guide => "guide",
            PadButton::L3 => "l3",
            PadButton::R3 => "r3",
            PadButton::DpadUp => "dpad_up",
            PadButton::DpadDown => "dpad_down",
            PadButton::DpadLeft => "dpad_left",
            PadButton::DpadRight => "dpad_right",
        }
    }
}

impl PadAxis {
    /// The normalised name (06-input.md §4.2).
    pub fn name(self) -> &'static str {
        match self {
            PadAxis::LeftX => "left_x",
            PadAxis::LeftY => "left_y",
            PadAxis::RightX => "right_x",
            PadAxis::RightY => "right_y",
            PadAxis::LeftTrigger => "left_trigger",
            PadAxis::RightTrigger => "right_trigger",
        }
    }
}

/// One input of the button test (`Input1.TestInput`): what the normaliser made of one evdev event
/// (`input`), or `None` for an input without a normal name, with the raw event it came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TestEvent {
    pub input: Option<PadInput>,
    pub ev_type: u16,
    pub code: u16,
    pub value: i32,
}

impl TestEvent {
    /// The raw source, `raw:pad:<type>:<code>` (06-input.md §4.2; `pad` is the pad's main node).
    pub fn source(&self) -> String {
        format!("raw:pad:{}:{}", self.ev_type, self.code)
    }

    /// The normal name, or the raw source for an input that has none.
    pub fn name(&self) -> String {
        match self.input {
            Some(PadInput::Button(b, _)) => b.name().to_owned(),
            Some(PadInput::Axis(a, _)) => a.name().to_owned(),
            None => self.source(),
        }
    }

    /// A button 1 or 0, an axis its normalised value, a raw input the kernel's value.
    pub fn test_value(&self) -> i32 {
        match self.input {
            Some(PadInput::Button(_, pressed)) => i32::from(pressed),
            Some(PadInput::Axis(_, v)) => v,
            None => self.value,
        }
    }

    /// Axes (normal or raw) are sent at most 30 times a second; buttons at once.
    pub fn is_axis(&self) -> bool {
        match self.input {
            Some(PadInput::Axis(..)) => true,
            Some(PadInput::Button(..)) => false,
            None => self.ev_type == code::EV_ABS,
        }
    }
}

/// The button test's events for one evdev event, given what the normaliser made of it: one per
/// normalised input, else one raw event for a key or axis that has no normal name. A digital
/// trigger next to its analog axis (the axis carries it), a hat that did not move and key
/// autorepeat give none.
pub fn test_events(ev_type: u16, ev_code: u16, value: i32, inputs: &[PadInput]) -> Vec<TestEvent> {
    let raw = |input| TestEvent {
        input,
        ev_type,
        code: ev_code,
        value,
    };
    if !inputs.is_empty() {
        return inputs.iter().map(|&i| raw(Some(i))).collect();
    }
    let named = match ev_type {
        code::EV_KEY => value == 2 || matches!(ev_code, code::BTN_TL2 | code::BTN_TR2),
        code::EV_ABS => matches!(
            ev_code,
            code::ABS_X
                | code::ABS_Y
                | code::ABS_Z
                | code::ABS_RX
                | code::ABS_RY
                | code::ABS_RZ
                | code::ABS_HAT0X
                | code::ABS_HAT0Y
        ),
        _ => true,
    };
    if named {
        Vec::new()
    } else {
        vec![raw(None)]
    }
}

/// One event for a virtual pad: (type, code, value). A batch ends with its own `SYN_REPORT`,
/// added by the writer.
pub type OutEvent = (u16, u16, i32);

/// The virtual pad's identity: an Xbox 360 wired pad (`045e:028e`, version `0x0114`, USB), so
/// SDL's own "Xbox 360 Controller" mapping applies (verified with SuperTuxKart, 06-input.md §1).
pub const VIRTUAL_NAME: &str = "Ruya Xbox 360 Pad";
pub const VIRTUAL_VENDOR: u16 = 0x045e;
pub const VIRTUAL_PRODUCT: u16 = 0x028e;
pub const VIRTUAL_VERSION: u16 = 0x0114;
pub const VIRTUAL_BUS_USB: u16 = 0x03;
/// Every device the service creates has a phys starting with this; the service never reads one
/// of them as a physical pad.
pub const OWN_PHYS_PREFIX: &str = "ruya-input/";
/// The phys of a virtual pad, `ruya-input/pad<n>`: the udev rule hands exactly these to
/// `ruya-input` without uaccess (06-input.md §3), so a later `ruya-input/kbm*` keyboard or mouse
/// for the compositor (RUY-45) can keep it.
pub const PAD_PHYS_PREFIX: &str = "ruya-input/pad";

/// The keys of the virtual pad in the xpad order SDL's mapping counts (`a:b0 ... rightstick:b10`):
/// `BTN_MODE` is declared so the indices match, but nothing ever presses it (Guide belongs to the
/// console).
pub const VIRTUAL_KEYS: [u16; 11] = [
    code::BTN_SOUTH,
    code::BTN_EAST,
    code::BTN_X,
    code::BTN_Y,
    code::BTN_TL,
    code::BTN_TR,
    code::BTN_SELECT,
    code::BTN_START,
    code::BTN_MODE,
    code::BTN_THUMBL,
    code::BTN_THUMBR,
];

/// The virtual pad's axes: (code, min, max, fuzz, flat), as xpad declares them for a 360 pad.
pub const VIRTUAL_AXES: [(u16, i32, i32, i32, i32); 8] = [
    (code::ABS_X, STICK_MIN, STICK_MAX, 16, 128),
    (code::ABS_Y, STICK_MIN, STICK_MAX, 16, 128),
    (code::ABS_Z, 0, 255, 0, 0),
    (code::ABS_RX, STICK_MIN, STICK_MAX, 16, 128),
    (code::ABS_RY, STICK_MIN, STICK_MAX, 16, 128),
    (code::ABS_RZ, 0, 255, 0, 0),
    (code::ABS_HAT0X, -1, 1, 0, 0),
    (code::ABS_HAT0Y, -1, 1, 0, 0),
];

/// The 360 key a button is written as; `None` for Guide (never forwarded) and the D-pad (a hat).
fn virtual_key(b: PadButton) -> Option<u16> {
    use PadButton::*;
    Some(match b {
        South => code::BTN_SOUTH,
        East => code::BTN_EAST,
        // xpad: X (west) is BTN_X, Y (north) is BTN_Y; SDL's 360 mapping says x:b2, y:b3.
        West => code::BTN_X,
        North => code::BTN_Y,
        L1 => code::BTN_TL,
        R1 => code::BTN_TR,
        Select => code::BTN_SELECT,
        Start => code::BTN_START,
        L3 => code::BTN_THUMBL,
        R3 => code::BTN_THUMBR,
        Guide | DpadUp | DpadDown | DpadLeft | DpadRight => return None,
    })
}

/// What a virtual pad shows for a state: (code, value) for every key and axis. Guide is never
/// pressed; triggers are 0..255 on the 360 pad.
fn virtual_values(state: &PadState) -> Vec<OutEvent> {
    let mut out = Vec::with_capacity(VIRTUAL_KEYS.len() + VIRTUAL_AXES.len());
    for b in ALL_BUTTONS {
        if let Some(key) = virtual_key(b) {
            out.push((code::EV_KEY, key, state.pressed(b) as i32));
        }
    }
    let hat = |neg, pos| state.pressed(pos) as i32 - state.pressed(neg) as i32;
    let trigger = |a| state.axis(a).clamp(0, TRIGGER_MAX) * 255 / TRIGGER_MAX;
    out.push((code::EV_ABS, code::ABS_X, state.axis(PadAxis::LeftX)));
    out.push((code::EV_ABS, code::ABS_Y, state.axis(PadAxis::LeftY)));
    out.push((code::EV_ABS, code::ABS_Z, trigger(PadAxis::LeftTrigger)));
    out.push((code::EV_ABS, code::ABS_RX, state.axis(PadAxis::RightX)));
    out.push((code::EV_ABS, code::ABS_RY, state.axis(PadAxis::RightY)));
    out.push((code::EV_ABS, code::ABS_RZ, trigger(PadAxis::RightTrigger)));
    out.push((
        code::EV_ABS,
        code::ABS_HAT0X,
        hat(PadButton::DpadLeft, PadButton::DpadRight),
    ));
    out.push((
        code::EV_ABS,
        code::ABS_HAT0Y,
        hat(PadButton::DpadUp, PadButton::DpadDown),
    ));
    out
}

/// The events that take a virtual pad from showing `from` to showing `to` (only what differs).
pub fn diff(from: &PadState, to: &PadState) -> Vec<OutEvent> {
    virtual_values(from)
        .into_iter()
        .zip(virtual_values(to))
        .filter(|(a, b)| a != b)
        .map(|(_, b)| b)
        .collect()
}

/// A rumble effect (`FF_RUMBLE`, the only effect the virtual pad declares): magnitudes 0..65535,
/// times in ms.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rumble {
    pub strong: u16,
    pub weak: u16,
    pub length_ms: u16,
    pub delay_ms: u16,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dualsense() -> Normalizer {
        Normalizer::new(PadLayout {
            xbox_xy: false,
            ranges: vec![
                (code::ABS_X, Range { min: 0, max: 255 }),
                (code::ABS_Y, Range { min: 0, max: 255 }),
                (code::ABS_Z, Range { min: 0, max: 255 }),
                (code::ABS_RZ, Range { min: 0, max: 255 }),
            ],
        })
    }

    #[test]
    fn test_events_name_each_input_and_keep_its_raw_source() {
        let mut ps = dualsense();
        let ins = ps.event(code::EV_KEY, code::BTN_SOUTH, 1);
        let evs = test_events(code::EV_KEY, code::BTN_SOUTH, 1, &ins);
        assert_eq!(evs.len(), 1);
        assert_eq!(evs[0].name(), "south");
        assert_eq!(evs[0].test_value(), 1);
        assert_eq!(evs[0].source(), "raw:pad:1:304");
        assert!(!evs[0].is_axis());
        // A hat move from left to right: two inputs from one raw event.
        let _ = ps.event(code::EV_ABS, code::ABS_HAT0X, -1);
        let ins = ps.event(code::EV_ABS, code::ABS_HAT0X, 1);
        let evs = test_events(code::EV_ABS, code::ABS_HAT0X, 1, &ins);
        let names: Vec<String> = evs.iter().map(|e| e.name()).collect();
        assert_eq!(names, vec!["dpad_left", "dpad_right"]);
        assert_eq!(evs[1].source(), "raw:pad:3:16");
        // A trigger is an axis, sent at its normalised value.
        let ins = ps.event(code::EV_ABS, code::ABS_Z, 255);
        let evs = test_events(code::EV_ABS, code::ABS_Z, 255, &ins);
        assert_eq!(evs[0].name(), "left_trigger");
        assert_eq!(evs[0].test_value(), TRIGGER_MAX);
        assert!(evs[0].is_axis());
    }

    #[test]
    fn test_events_report_inputs_without_a_normal_name_raw() {
        // A paddle (BTN_TRIGGER_HAPPY1): no normal name in v1, so its raw source is its name.
        let evs = test_events(code::EV_KEY, 0x2c0, 1, &[]);
        assert_eq!(evs.len(), 1);
        assert_eq!(evs[0].name(), "raw:pad:1:704");
        assert_eq!(evs[0].test_value(), 1);
        // An unknown axis is rate-limited like the others.
        let evs = test_events(code::EV_ABS, 0x12, 5, &[]);
        assert!(evs[0].is_axis());
        // The digital trigger next to its analog axis, autorepeat and a hat that stayed: nothing.
        assert!(test_events(code::EV_KEY, code::BTN_TL2, 1, &[]).is_empty());
        assert!(test_events(code::EV_KEY, 0x2c0, 2, &[]).is_empty());
        assert!(test_events(code::EV_ABS, code::ABS_HAT0X, 0, &[]).is_empty());
        assert!(test_events(code::EV_SYN, 0, 0, &[]).is_empty());
    }

    #[test]
    fn buttons_are_named_by_position_per_family() {
        let mut ps = dualsense();
        assert_eq!(
            ps.event(code::EV_KEY, code::BTN_Y, 1),
            vec![PadInput::Button(PadButton::West, true)]
        );
        let mut xbox = Normalizer::new(PadLayout {
            xbox_xy: true,
            ranges: vec![],
        });
        assert_eq!(
            xbox.event(code::EV_KEY, code::BTN_X, 1),
            vec![PadInput::Button(PadButton::West, true)]
        );
        assert_eq!(
            xbox.event(code::EV_KEY, code::BTN_Y, 0),
            vec![PadInput::Button(PadButton::North, false)]
        );
    }

    #[test]
    fn autorepeat_and_unknown_codes_are_dropped() {
        let mut n = dualsense();
        assert!(n.event(code::EV_KEY, code::BTN_SOUTH, 2).is_empty());
        assert!(n.event(code::EV_KEY, 0x2c0, 1).is_empty());
        assert!(n.event(code::EV_FF, 0, 1).is_empty());
    }

    #[test]
    fn sticks_and_triggers_are_scaled_to_the_normal_ranges() {
        let mut n = dualsense();
        assert_eq!(
            n.event(code::EV_ABS, code::ABS_X, 0),
            vec![PadInput::Axis(PadAxis::LeftX, STICK_MIN)]
        );
        assert_eq!(
            n.event(code::EV_ABS, code::ABS_Y, 255),
            vec![PadInput::Axis(PadAxis::LeftY, STICK_MAX)]
        );
        assert_eq!(
            n.event(code::EV_ABS, code::ABS_Z, 255),
            vec![PadInput::Axis(PadAxis::LeftTrigger, TRIGGER_MAX)]
        );
        // An axis the pad did not declare a range for: the 360 defaults.
        assert_eq!(
            n.event(code::EV_ABS, code::ABS_RX, -32768),
            vec![PadInput::Axis(PadAxis::RightX, STICK_MIN)]
        );
    }

    #[test]
    fn a_hat_becomes_dpad_buttons_and_jumps_release_first() {
        let mut n = dualsense();
        assert_eq!(
            n.event(code::EV_ABS, code::ABS_HAT0X, -1),
            vec![PadInput::Button(PadButton::DpadLeft, true)]
        );
        assert_eq!(
            n.event(code::EV_ABS, code::ABS_HAT0X, 1),
            vec![
                PadInput::Button(PadButton::DpadLeft, false),
                PadInput::Button(PadButton::DpadRight, true)
            ]
        );
        assert!(n.event(code::EV_ABS, code::ABS_HAT0X, 1).is_empty());
        assert_eq!(
            n.event(code::EV_ABS, code::ABS_HAT0Y, 0),
            Vec::<PadInput>::new()
        );
    }

    #[test]
    fn digital_triggers_count_only_without_the_analog_axis() {
        let mut ps = dualsense();
        assert!(ps.event(code::EV_KEY, code::BTN_TL2, 1).is_empty());
        let mut switch = Normalizer::new(PadLayout::default());
        assert_eq!(
            switch.event(code::EV_KEY, code::BTN_TR2, 1),
            vec![PadInput::Axis(PadAxis::RightTrigger, TRIGGER_MAX)]
        );
    }

    #[test]
    fn diff_writes_only_what_changed_and_never_guide() {
        let neutral = PadState::default();
        let mut s = PadState::default();
        s.apply(PadInput::Button(PadButton::South, true));
        s.apply(PadInput::Button(PadButton::Guide, true));
        s.apply(PadInput::Button(PadButton::DpadUp, true));
        s.apply(PadInput::Axis(PadAxis::RightTrigger, TRIGGER_MAX));
        assert_eq!(
            diff(&neutral, &s),
            vec![
                (code::EV_KEY, code::BTN_SOUTH, 1),
                (code::EV_ABS, code::ABS_RZ, 255),
                (code::EV_ABS, code::ABS_HAT0Y, -1),
            ]
        );
        assert_eq!(
            diff(&s, &neutral),
            vec![
                (code::EV_KEY, code::BTN_SOUTH, 0),
                (code::EV_ABS, code::ABS_RZ, 0),
                (code::EV_ABS, code::ABS_HAT0Y, 0),
            ]
        );
        assert!(diff(&s, &s).is_empty());
    }

    #[test]
    fn west_and_north_are_written_as_xpad_writes_them() {
        let mut s = PadState::default();
        s.apply(PadInput::Button(PadButton::West, true));
        assert_eq!(
            diff(&PadState::default(), &s),
            vec![(code::EV_KEY, code::BTN_X, 1)]
        );
    }

    #[test]
    fn the_virtual_key_list_is_xpad_order_with_mode() {
        // SDL's "Xbox 360 Controller" mapping counts keys in code order: b8 must be BTN_MODE.
        let mut sorted = VIRTUAL_KEYS;
        sorted.sort();
        assert_eq!(sorted, VIRTUAL_KEYS);
        assert_eq!(VIRTUAL_KEYS[8], code::BTN_MODE);
        assert_eq!(VIRTUAL_KEYS[6], code::BTN_SELECT);
    }
}
