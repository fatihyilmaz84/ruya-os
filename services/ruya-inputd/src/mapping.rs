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

#[derive(Debug, Default)]
pub struct Mapper {
    hat: [Option<NavKey>; 2],
    stick: [Option<NavKey>; 2],
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
        let key = match button {
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
        };
        vec![(key, pressed)]
    }

    /// D-pad reported as a hat axis: value is -1, 0 or 1.
    pub fn hat(&mut self, axis: Axis, value: i32) -> Vec<KeyEvent> {
        transition(&mut self.hat[axis_index(axis)], direction(axis, value))
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
        transition(slot, new)
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
}
