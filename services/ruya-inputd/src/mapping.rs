//! Platform-independent translation of gamepad state changes into navigation keys.
//! Kept free of evdev types so it can be unit-tested on any host.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NavKey {
    Up,
    Down,
    Left,
    Right,
    Accept,
    Back,
    Menu,
    Guide,
    PrevTab,
    NextTab,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Button {
    South,
    East,
    Start,
    Mode,
    ShoulderLeft,
    ShoulderRight,
    DpadUp,
    DpadDown,
    DpadLeft,
    DpadRight,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Axis {
    Horizontal,
    Vertical,
}

/// One key transition to emit: `(key, pressed)`.
pub type KeyEvent = (NavKey, bool);

/// Stick deflection (as a fraction of the half-range) needed to press, and the lower
/// value it must fall back under to release. The gap prevents chatter around the edge.
const STICK_PRESS: f32 = 0.6;
const STICK_RELEASE: f32 = 0.35;

/// Every key, in the order a release list is written.
const ALL_KEYS: [NavKey; 10] = [
    NavKey::Up,
    NavKey::Down,
    NavKey::Left,
    NavKey::Right,
    NavKey::Accept,
    NavKey::Back,
    NavKey::Menu,
    NavKey::Guide,
    NavKey::PrevTab,
    NavKey::NextTab,
];

fn key_index(key: NavKey) -> usize {
    ALL_KEYS.iter().position(|&k| k == key).unwrap_or(0)
}

fn button_key(button: Button) -> NavKey {
    match button {
        Button::South => NavKey::Accept,
        Button::East => NavKey::Back,
        Button::Start => NavKey::Menu,
        Button::Mode => NavKey::Guide,
        Button::ShoulderLeft => NavKey::PrevTab,
        Button::ShoulderRight => NavKey::NextTab,
        Button::DpadUp => NavKey::Up,
        Button::DpadDown => NavKey::Down,
        Button::DpadLeft => NavKey::Left,
        Button::DpadRight => NavKey::Right,
    }
}

/// Counts presses and releases per key and returns only the 0 -> 1 presses and 1 -> 0 releases.
/// A release with nothing counted is ignored.
fn count_transitions(counts: &mut [u8; 10], events: &[KeyEvent]) -> Vec<KeyEvent> {
    let mut out = Vec::with_capacity(events.len());
    for &(key, pressed) in events {
        let count = &mut counts[key_index(key)];
        if pressed {
            *count = count.saturating_add(1);
            if *count == 1 {
                out.push((key, true));
            }
        } else if *count > 0 {
            *count -= 1;
            if *count == 0 {
                out.push((key, false));
            }
        }
    }
    out
}

/// One pad's view: what it presses and which keys it holds right now.
///
/// A key can be held by several sources of the same pad (the d-pad button and the stick both
/// say Down); `held` counts the sources, and the events a `Mapper` returns are the pad's own
/// transitions only: pressed when the first source takes the key, released when the last lets go.
#[derive(Debug, Default)]
pub struct Mapper {
    hat: [Option<NavKey>; 2],
    stick: [Option<NavKey>; 2],
    /// Buttons currently down, by the key they map to (two buttons never share a key).
    buttons: [bool; 10],
    held: [u8; 10],
}

fn axis_index(axis: Axis) -> usize {
    match axis {
        Axis::Horizontal => 0,
        Axis::Vertical => 1,
    }
}

fn direction(axis: Axis, sign: i32) -> Option<NavKey> {
    match (axis, sign.signum()) {
        (Axis::Horizontal, -1) => Some(NavKey::Left),
        (Axis::Horizontal, 1) => Some(NavKey::Right),
        (Axis::Vertical, -1) => Some(NavKey::Up),
        (Axis::Vertical, 1) => Some(NavKey::Down),
        _ => None,
    }
}

/// Release `old` and press `new` if they differ.
fn transition(slot: &mut Option<NavKey>, new: Option<NavKey>) -> Vec<KeyEvent> {
    if *slot == new {
        return Vec::new();
    }
    let mut out = Vec::with_capacity(2);
    if let Some(old) = slot.take() {
        out.push((old, false));
    }
    if let Some(key) = new {
        out.push((key, true));
    }
    *slot = new;
    out
}

impl Mapper {
    pub fn button(&mut self, button: Button, pressed: bool) -> Vec<KeyEvent> {
        let key = button_key(button);
        let down = &mut self.buttons[key_index(key)];
        if pressed && *down {
            return Vec::new(); // a repeated press is not a second hold
        }
        if !pressed && !*down {
            // Released without a press seen (the pad connected with it held): nothing of ours.
            return vec![(key, false)];
        }
        *down = pressed;
        self.settle(vec![(key, pressed)])
    }

    /// D-pad reported as a hat axis: value is -1, 0 or 1.
    pub fn hat(&mut self, axis: Axis, value: i32) -> Vec<KeyEvent> {
        let events = transition(&mut self.hat[axis_index(axis)], direction(axis, value));
        self.settle(events)
    }

    /// Analog stick: raw value within `[min, max]`.
    pub fn stick(&mut self, axis: Axis, value: i32, min: i32, max: i32) -> Vec<KeyEvent> {
        let half = (max as f32 - min as f32) / 2.0;
        if half <= 0.0 {
            return Vec::new();
        }
        let center = min as f32 + half;
        let deflection = (value as f32 - center) / half;

        let slot = &mut self.stick[axis_index(axis)];
        let held = slot.is_some();
        let new = if deflection.abs() >= STICK_PRESS || (held && deflection.abs() > STICK_RELEASE) {
            direction(axis, if deflection < 0.0 { -1 } else { 1 })
        } else {
            None
        };
        let events = transition(slot, new);
        self.settle(events)
    }

    /// Counts the sources behind each key and keeps only the pad's own transitions.
    fn settle(&mut self, events: Vec<KeyEvent>) -> Vec<KeyEvent> {
        count_transitions(&mut self.held, &events)
    }

    /// The pad is gone: a release for every key it holds, then it holds nothing.
    pub fn release_all(&mut self) -> Vec<KeyEvent> {
        let out = ALL_KEYS
            .iter()
            .filter(|&&key| self.held[key_index(key)] > 0)
            .map(|&key| (key, false))
            .collect();
        self.hat = [None; 2];
        self.stick = [None; 2];
        self.buttons = [false; 10];
        self.held = [0; 10];
        out
    }
}

/// The one virtual keyboard all pads share: a count of pads per key.
#[derive(Debug, Default)]
pub struct KeyBoard {
    pads: [u8; 10],
}

impl KeyBoard {
    /// Turns one pad's transitions into keyboard events: a key goes down when the first pad
    /// presses it and up when the last pad lets go.
    pub fn route(&mut self, events: &[KeyEvent]) -> Vec<KeyEvent> {
        count_transitions(&mut self.pads, events)
    }

    /// A pad vanished: release what it held (another pad's hold on a key survives).
    pub fn pad_gone(&mut self, mapper: &mut Mapper) -> Vec<KeyEvent> {
        let released = mapper.release_all();
        self.route(&released)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buttons_map_to_navigation() {
        let mut m = Mapper::default();
        assert_eq!(m.button(Button::South, true), vec![(NavKey::Accept, true)]);
        assert_eq!(m.button(Button::East, false), vec![(NavKey::Back, false)]);
        assert_eq!(m.button(Button::Mode, true), vec![(NavKey::Guide, true)]);
    }

    #[test]
    fn hat_presses_and_releases() {
        let mut m = Mapper::default();
        assert_eq!(m.hat(Axis::Horizontal, 1), vec![(NavKey::Right, true)]);
        assert_eq!(m.hat(Axis::Horizontal, 1), vec![]);
        assert_eq!(
            m.hat(Axis::Horizontal, -1),
            vec![(NavKey::Right, false), (NavKey::Left, true)]
        );
        assert_eq!(m.hat(Axis::Horizontal, 0), vec![(NavKey::Left, false)]);
    }

    #[test]
    fn hat_axes_are_independent() {
        let mut m = Mapper::default();
        m.hat(Axis::Horizontal, 1);
        assert_eq!(m.hat(Axis::Vertical, -1), vec![(NavKey::Up, true)]);
        assert_eq!(m.hat(Axis::Horizontal, 0), vec![(NavKey::Right, false)]);
    }

    #[test]
    fn stick_uses_hysteresis() {
        let mut m = Mapper::default();
        // Xbox-style signed range.
        let (min, max) = (-32768, 32767);
        assert_eq!(m.stick(Axis::Vertical, 15000, min, max), vec![]); // ~46%: below press
        assert_eq!(
            m.stick(Axis::Vertical, 22000, min, max),
            vec![(NavKey::Down, true)]
        );
        assert_eq!(m.stick(Axis::Vertical, 15000, min, max), vec![]); // still above release
        assert_eq!(
            m.stick(Axis::Vertical, 8000, min, max),
            vec![(NavKey::Down, false)]
        );
    }

    #[test]
    fn stick_handles_unsigned_ranges() {
        let mut m = Mapper::default();
        // DualShock-style 0..255 with centre 127.5.
        assert_eq!(m.stick(Axis::Horizontal, 128, 0, 255), vec![]);
        assert_eq!(
            m.stick(Axis::Horizontal, 5, 0, 255),
            vec![(NavKey::Left, true)]
        );
        assert_eq!(
            m.stick(Axis::Horizontal, 250, 0, 255),
            vec![(NavKey::Left, false), (NavKey::Right, true)]
        );
    }

    #[test]
    fn degenerate_range_is_ignored() {
        let mut m = Mapper::default();
        assert_eq!(m.stick(Axis::Horizontal, 10, 0, 0), vec![]);
    }

    fn press(m: &mut Mapper, b: Button) {
        m.button(b, true);
    }

    #[test]
    fn release_all_releases_held_buttons_hats_and_sticks() {
        let mut m = Mapper::default();
        press(&mut m, Button::South);
        m.hat(Axis::Horizontal, -1);
        m.stick(Axis::Vertical, 30000, -32768, 32767);
        assert_eq!(
            m.release_all(),
            vec![
                (NavKey::Down, false),
                (NavKey::Left, false),
                (NavKey::Accept, false)
            ]
        );
        // Everything is forgotten: the same inputs press again from scratch.
        assert_eq!(m.hat(Axis::Horizontal, -1), vec![(NavKey::Left, true)]);
        assert_eq!(m.button(Button::South, true), vec![(NavKey::Accept, true)]);
    }

    #[test]
    fn release_all_twice_releases_nothing_the_second_time() {
        let mut m = Mapper::default();
        press(&mut m, Button::DpadDown);
        assert_eq!(m.release_all(), vec![(NavKey::Down, false)]);
        assert_eq!(m.release_all(), vec![]);
    }

    #[test]
    fn a_key_held_by_two_sources_of_one_pad_is_released_once() {
        let mut m = Mapper::default();
        assert_eq!(m.button(Button::DpadDown, true), vec![(NavKey::Down, true)]);
        assert_eq!(m.stick(Axis::Vertical, 30000, -32768, 32767), vec![]);
        assert_eq!(m.button(Button::DpadDown, false), vec![]);
        assert_eq!(
            m.stick(Axis::Vertical, 0, -32768, 32767),
            vec![(NavKey::Down, false)]
        );
    }

    #[test]
    fn two_pads_holding_the_same_key_press_it_once() {
        let (mut a, mut b, mut kb) = (Mapper::default(), Mapper::default(), KeyBoard::default());
        assert_eq!(
            kb.route(&a.button(Button::DpadDown, true)),
            vec![(NavKey::Down, true)]
        );
        assert_eq!(kb.route(&b.button(Button::DpadDown, true)), vec![]);
    }

    #[test]
    fn a_key_stays_down_until_the_last_pad_lets_go() {
        let (mut a, mut b, mut kb) = (Mapper::default(), Mapper::default(), KeyBoard::default());
        kb.route(&a.button(Button::DpadDown, true));
        kb.route(&b.button(Button::DpadDown, true));
        // Pad B lets go: pad A still holds Down.
        assert_eq!(kb.route(&b.button(Button::DpadDown, false)), vec![]);
        // Pad A vanishes while holding it: now it goes up.
        assert_eq!(kb.pad_gone(&mut a), vec![(NavKey::Down, false)]);
        // And the other way round: B vanishes first, A still holds.
        let (mut c, mut d) = (Mapper::default(), Mapper::default());
        kb.route(&c.button(Button::South, true));
        kb.route(&d.button(Button::South, true));
        assert_eq!(kb.pad_gone(&mut c), vec![]);
        assert_eq!(
            kb.route(&d.button(Button::South, false)),
            vec![(NavKey::Accept, false)]
        );
    }

    #[test]
    fn a_vanished_pad_releases_only_what_it_held() {
        let (mut a, mut b, mut kb) = (Mapper::default(), Mapper::default(), KeyBoard::default());
        kb.route(&a.button(Button::DpadDown, true));
        kb.route(&a.button(Button::South, true));
        kb.route(&b.button(Button::DpadDown, true));
        kb.route(&b.button(Button::East, true));
        assert_eq!(kb.pad_gone(&mut a), vec![(NavKey::Accept, false)]);
        assert_eq!(
            kb.pad_gone(&mut b),
            vec![(NavKey::Down, false), (NavKey::Back, false)]
        );
    }

    #[test]
    fn a_pad_that_vanishes_holding_nothing_emits_nothing() {
        let (mut a, mut kb) = (Mapper::default(), KeyBoard::default());
        assert_eq!(kb.pad_gone(&mut a), vec![]);
        kb.route(&a.button(Button::South, true));
        kb.route(&a.button(Button::South, false));
        assert_eq!(kb.pad_gone(&mut a), vec![]);
    }
}
