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

fn button_index(button: Button) -> usize {
    match button {
        Button::South => 0,
        Button::East => 1,
        Button::Start => 2,
        Button::Mode => 3,
        Button::ShoulderLeft => 4,
        Button::ShoulderRight => 5,
        Button::DpadUp => 6,
        Button::DpadDown => 7,
        Button::DpadLeft => 8,
        Button::DpadRight => 9,
    }
}

/// The navigation key of `button` on a pad of `family` under `mode` (06 section 11.2): pure, the
/// one place the family x setting table is applied. Only south and east change.
pub fn nav_key(family: &str, mode: Confirm, button: Button) -> NavKey {
    button_key(button, mode.accept_button(family))
}

/// `accept` is the button that confirms; the other of south and east goes back.
fn button_key(button: Button, accept: Button) -> NavKey {
    match button {
        Button::South | Button::East => {
            if button == accept {
                NavKey::Accept
            } else {
                NavKey::Back
            }
        }
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

/// The "Confirm button" setting of a console profile (06 section 11.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Confirm {
    /// As on the controller: the family's own button (the default).
    #[default]
    Family,
    /// The bottom button confirms, whatever the family.
    South,
    /// The right button confirms, whatever the family.
    East,
}

impl Confirm {
    pub fn parse(text: &str) -> Option<Confirm> {
        match text {
            "family" => Some(Confirm::Family),
            "south" => Some(Confirm::South),
            "east" => Some(Confirm::East),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Confirm::Family => "family",
            Confirm::South => "south",
            Confirm::East => "east",
        }
    }

    /// The button that confirms for a pad of `family` (`xbox`, `playstation`, `nintendo`,
    /// `generic`, ...). The one table of 06 section 11.2; a family it does not know confirms
    /// by position (south). Back is always the other of the two.
    pub fn accept_button(self, family: &str) -> Button {
        match self {
            Confirm::South => Button::South,
            Confirm::East => Button::East,
            Confirm::Family => match family {
                "nintendo" => Button::East,
                _ => Button::South,
            },
        }
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
    /// Buttons currently down, with the key each was pressed as: a setting that changes while a
    /// button is held releases the key it pressed, not the one it would map to now.
    buttons: [Option<NavKey>; 10],
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
    /// A button by position (south confirms): the Phase 0 mapping.
    pub fn button(&mut self, button: Button, pressed: bool) -> Vec<KeyEvent> {
        self.button_as(button, pressed, "generic", Confirm::South)
    }

    /// A button of a pad of `family` under `mode` (`nav_key`). A release gives back the key its
    /// press emitted, whatever the family or mode is by then.
    pub fn button_as(
        &mut self,
        button: Button,
        pressed: bool,
        family: &str,
        mode: Confirm,
    ) -> Vec<KeyEvent> {
        let slot = &mut self.buttons[button_index(button)];
        let key = if pressed {
            if slot.is_some() {
                return Vec::new(); // a repeated press is not a second hold
            }
            let key = nav_key(family, mode, button);
            *slot = Some(key);
            key
        } else {
            // Released without a press seen (the pad was opened with it held): it holds nothing
            // of this key here, so it must not take away what another source or pad holds.
            match slot.take() {
                Some(key) => key,
                None => return Vec::new(),
            }
        };
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

    /// The keys this pad holds now, in release order.
    pub fn held_keys(&self) -> Vec<NavKey> {
        ALL_KEYS
            .iter()
            .copied()
            .filter(|&key| self.held[key_index(key)] > 0)
            .collect()
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
        self.buttons = [None; 10];
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

    /// Navigation stops (an app has the focus): every key that is down goes up, except `keep`
    /// (Guide, which still reaches the shell). The pads' mappers keep their state, so the release
    /// a pad sends later finds nothing counted and is ignored: no key is released twice.
    pub fn release_except(&mut self, keep: NavKey) -> Vec<KeyEvent> {
        let mut out = Vec::new();
        for key in ALL_KEYS {
            let count = &mut self.pads[key_index(key)];
            if key != keep && *count > 0 {
                *count = 0;
                out.push((key, false));
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buttons_map_to_navigation() {
        let mut m = Mapper::default();
        assert_eq!(m.button(Button::South, true), vec![(NavKey::Accept, true)]);
        assert_eq!(m.button(Button::East, true), vec![(NavKey::Back, true)]);
        assert_eq!(m.button(Button::East, false), vec![(NavKey::Back, false)]);
        assert_eq!(m.button(Button::Mode, true), vec![(NavKey::Guide, true)]);
    }

    #[test]
    fn the_confirm_table_by_family_and_mode() {
        use Confirm::{East, Family, South};
        // (family, mode, key of south, key of east)
        let table = [
            ("xbox", Family, NavKey::Accept, NavKey::Back),
            ("generic", Family, NavKey::Accept, NavKey::Back),
            ("playstation", Family, NavKey::Accept, NavKey::Back),
            ("nintendo", Family, NavKey::Back, NavKey::Accept),
            ("something-new", Family, NavKey::Accept, NavKey::Back),
            ("", Family, NavKey::Accept, NavKey::Back),
            ("xbox", South, NavKey::Accept, NavKey::Back),
            ("playstation", South, NavKey::Accept, NavKey::Back),
            ("nintendo", South, NavKey::Accept, NavKey::Back),
            ("something-new", South, NavKey::Accept, NavKey::Back),
            ("xbox", East, NavKey::Back, NavKey::Accept),
            ("generic", East, NavKey::Back, NavKey::Accept),
            ("playstation", East, NavKey::Back, NavKey::Accept),
            ("nintendo", East, NavKey::Back, NavKey::Accept),
            ("something-new", East, NavKey::Back, NavKey::Accept),
        ];
        for (family, mode, south, east) in table {
            assert_eq!(
                nav_key(family, mode, Button::South),
                south,
                "{family} {mode:?}"
            );
            assert_eq!(
                nav_key(family, mode, Button::East),
                east,
                "{family} {mode:?}"
            );
        }
    }

    #[test]
    fn only_south_and_east_depend_on_the_confirm_setting() {
        for button in [
            Button::Start,
            Button::Mode,
            Button::ShoulderLeft,
            Button::ShoulderRight,
            Button::DpadUp,
            Button::DpadDown,
            Button::DpadLeft,
            Button::DpadRight,
        ] {
            let base = nav_key("xbox", Confirm::Family, button);
            for family in ["nintendo", "playstation", "xbox", "generic"] {
                for mode in [Confirm::Family, Confirm::South, Confirm::East] {
                    assert_eq!(nav_key(family, mode, button), base);
                }
            }
        }
    }

    #[test]
    fn confirm_modes_parse_and_print() {
        for text in ["family", "south", "east"] {
            assert_eq!(Confirm::parse(text).map(Confirm::as_str), Some(text));
        }
        assert_eq!(Confirm::parse("Right"), None);
        assert_eq!(Confirm::parse(""), None);
    }

    #[test]
    fn a_release_gives_back_the_key_its_press_emitted() {
        let mut m = Mapper::default();
        let (f, e) = (Confirm::Family, Confirm::East);
        // Pressed as Accept (Xbox, as on the controller); the setting changes while it is held.
        assert_eq!(
            m.button_as(Button::South, true, "xbox", f),
            vec![(NavKey::Accept, true)]
        );
        assert_eq!(
            m.button_as(Button::South, false, "xbox", e),
            vec![(NavKey::Accept, false)]
        );
        // And the other way: pressed as Back under "east", released under "family".
        assert_eq!(
            m.button_as(Button::South, true, "xbox", e),
            vec![(NavKey::Back, true)]
        );
        assert_eq!(
            m.button_as(Button::South, false, "xbox", f),
            vec![(NavKey::Back, false)]
        );
        assert!(m.held_keys().is_empty());
    }

    #[test]
    fn two_buttons_on_one_key_after_a_change_release_together() {
        let mut m = Mapper::default();
        // Accept from south; then the setting flips, so east means Accept too.
        m.button_as(Button::South, true, "xbox", Confirm::Family);
        assert_eq!(
            m.button_as(Button::East, true, "xbox", Confirm::East),
            vec![]
        );
        assert_eq!(
            m.button_as(Button::South, false, "xbox", Confirm::East),
            vec![]
        );
        assert_eq!(
            m.button_as(Button::East, false, "xbox", Confirm::East),
            vec![(NavKey::Accept, false)]
        );
    }

    #[test]
    fn a_pad_that_vanishes_mid_press_releases_what_it_pressed() {
        let mut m = Mapper::default();
        let mut board = KeyBoard::default();
        let down = m.button_as(Button::East, true, "nintendo", Confirm::Family);
        assert_eq!(board.route(&down), vec![(NavKey::Accept, true)]);
        assert_eq!(board.pad_gone(&mut m), vec![(NavKey::Accept, false)]);
        // A stray release afterwards (the node is gone, but be sure) does nothing.
        assert_eq!(
            m.button_as(Button::East, false, "nintendo", Confirm::South),
            vec![]
        );
        assert!(m.held_keys().is_empty());
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

    #[test]
    fn a_release_never_seen_pressed_does_not_release_another_pads_key() {
        // Case 1: pad B was opened while its Down was already held; A really holds Down.
        let (mut a, mut b, mut kb) = (Mapper::default(), Mapper::default(), KeyBoard::default());
        assert_eq!(
            kb.route(&a.button(Button::DpadDown, true)),
            vec![(NavKey::Down, true)]
        );
        assert_eq!(kb.route(&b.button(Button::DpadDown, false)), vec![]);
        // A still holds Down: only A's own release lifts it.
        assert_eq!(
            kb.route(&a.button(Button::DpadDown, false)),
            vec![(NavKey::Down, false)]
        );
        // Case 2: one pad, the stick holds Down and an unseen d-pad Down release arrives.
        let mut m = Mapper::default();
        assert_eq!(
            m.stick(Axis::Vertical, 30000, -32768, 32767),
            vec![(NavKey::Down, true)]
        );
        assert_eq!(m.button(Button::DpadDown, false), vec![]);
        assert_eq!(m.held_keys(), vec![NavKey::Down]);
    }

    #[test]
    fn release_except_lifts_every_key_but_guide_and_later_releases_are_ignored() {
        let (mut a, mut kb) = (Mapper::default(), KeyBoard::default());
        kb.route(&a.button(Button::DpadDown, true));
        kb.route(&a.button(Button::Mode, true));
        assert_eq!(
            kb.release_except(NavKey::Guide),
            vec![(NavKey::Down, false)]
        );
        // The pad lets go later: nothing is released a second time; Guide still goes up.
        assert_eq!(kb.route(&a.button(Button::DpadDown, false)), vec![]);
        assert_eq!(
            kb.route(&a.button(Button::Mode, false)),
            vec![(NavKey::Guide, false)]
        );
    }
}
