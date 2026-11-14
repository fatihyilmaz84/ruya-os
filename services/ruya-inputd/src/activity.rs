//! When a pad's input counts as "the user is here" for the shell's idle clock (RUY-588,
//! `Input1.UserActive`). In the `app` route the pad's input goes to the game's virtual pad and the
//! shell sees none of it; this gate tells the shell that someone is playing, and no more: no device,
//! no button, at most once per `MIN_GAP`. Pure: the time is passed in.

use std::time::{Duration, Instant};

use crate::pad::{PadAxis, PadInput};

/// At most one `UserActive` per this long. The idle clock counts in minutes.
pub const MIN_GAP: Duration = Duration::from_secs(30);
/// A stick counts past a quarter of its range: drift and a resting thumb stay under it.
pub const STICK_THRESHOLD: i32 = 8192;
/// A trigger counts past a tenth of its range.
pub const TRIGGER_THRESHOLD: i32 = 3277;

#[derive(Debug, Default)]
pub struct ActivityGate {
    last: Option<Instant>,
    /// `MIN_GAP`, or shorter for the VM checks (`RUYA_IDLE_DIVISOR`, as the shell's idle times).
    gap: Option<Duration>,
}

/// A button press, or an axis moved past its threshold (a release or a return to rest is not input).
fn counts(input: PadInput) -> bool {
    match input {
        PadInput::Button(_, pressed) => pressed,
        PadInput::Axis(PadAxis::LeftTrigger | PadAxis::RightTrigger, v) => v >= TRIGGER_THRESHOLD,
        PadInput::Axis(_, v) => v.abs() >= STICK_THRESHOLD,
    }
}

impl ActivityGate {
    pub fn set_gap(&mut self, gap: Duration) {
        self.gap = Some(gap);
    }

    /// True when this batch of input should be announced now.
    pub fn note(&mut self, inputs: &[PadInput], now: Instant) -> bool {
        if !inputs.iter().any(|&i| counts(i)) {
            return false;
        }
        if self
            .last
            .is_some_and(|t| now.saturating_duration_since(t) < self.gap.unwrap_or(MIN_GAP))
        {
            return false;
        }
        self.last = Some(now);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pad::PadButton;

    fn press() -> [PadInput; 1] {
        [PadInput::Button(PadButton::South, true)]
    }

    #[test]
    fn the_first_input_is_announced() {
        let mut g = ActivityGate::default();
        assert!(g.note(&press(), Instant::now()));
    }

    #[test]
    fn inputs_within_thirty_seconds_are_not() {
        let mut g = ActivityGate::default();
        let t = Instant::now();
        assert!(g.note(&press(), t));
        assert!(!g.note(&press(), t + Duration::from_secs(1)));
        assert!(!g.note(&press(), t + Duration::from_secs(29)));
    }

    #[test]
    fn after_thirty_seconds_the_next_is() {
        let mut g = ActivityGate::default();
        let t = Instant::now();
        assert!(g.note(&press(), t));
        assert!(!g.note(&press(), t + Duration::from_secs(29)));
        assert!(g.note(&press(), t + MIN_GAP));
        // the window restarts from the announced one
        assert!(!g.note(&press(), t + MIN_GAP + Duration::from_secs(1)));
    }

    #[test]
    fn stick_noise_and_releases_do_not_count() {
        let mut g = ActivityGate::default();
        let t = Instant::now();
        assert!(!g.note(&[PadInput::Axis(PadAxis::LeftX, STICK_THRESHOLD - 1)], t));
        assert!(!g.note(
            &[PadInput::Axis(PadAxis::RightY, -(STICK_THRESHOLD - 1))],
            t
        ));
        assert!(!g.note(
            &[PadInput::Axis(PadAxis::RightTrigger, TRIGGER_THRESHOLD - 1)],
            t
        ));
        assert!(!g.note(&[PadInput::Button(PadButton::South, false)], t));
        assert!(g.note(&[PadInput::Axis(PadAxis::LeftY, -STICK_THRESHOLD)], t));
    }

    #[test]
    fn a_trigger_pull_counts() {
        let mut g = ActivityGate::default();
        assert!(g.note(
            &[PadInput::Axis(PadAxis::LeftTrigger, TRIGGER_THRESHOLD)],
            Instant::now()
        ));
    }
}
