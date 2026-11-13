//! The mapping engine of controller profiles v1 (06-input.md §7): what a virtual pad shows for the
//! physical pad's state. Pure and unit-tested; the router calls `Engine::apply` on every input
//! batch while the route is `app`.
//!
//! - **Inheritance** (`Resolved::merge`): parent first; a child's mapping replaces the parent's for
//!   the same `from`, a child's setting the parent's field by field; what nobody sets is the
//!   built-in default (inner 0.08, outer 0.02, anti 0, sensitivity 1, Linear, no inversion,
//!   trigger threshold 0).
//! - **Sticks** (on the vector, so the dead zone is round): `r` in 0..1, `r' = clamp((r - inner) /
//!   (1 - inner - outer), 0, 1)`, the curve (Linear `r'`, Precise `r'^2`, Aggressive `sqrt r'`),
//!   `out = 0` if `r' = 0` else `anti + (1 - anti) * c`, times `sensitivity`, clamped to 1; the
//!   direction is kept, inversion per axis afterwards. Triggers use `trigger_threshold` as their
//!   inner dead zone.
//! - **Mappings** applied in v1: a button or an axis of the virtual pad (06 §4.2) to a button, an
//!   axis or `none`, with `invert`, `scale` and (axis to button) `threshold`, mode absent or
//!   `press`. Anything else (keys, mouse, layers, macros, chords, other modes, raw, motion and
//!   paddle inputs, targets the Xbox 360 pad lacks) is stored and validated but not applied: that
//!   input keeps its default (T-372 / T-373). `smoothing` is stored, not applied (no tick yet).
//! - Guide never reaches the virtual pad, whatever a profile says (it belongs to the console).

use std::collections::BTreeMap;

use crate::pad::{
    PadAxis, PadButton, PadInput, PadState, ALL_AXES, ALL_BUTTONS, STICK_MAX, STICK_MIN,
    TRIGGER_MAX,
};
use crate::profile::{Input, Mapping, Profile, Settings, Stick};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Curve {
    Linear,
    Precise,
    Aggressive,
}

impl Curve {
    fn parse(s: &str) -> Curve {
        match s {
            "precise" => Curve::Precise,
            "aggressive" => Curve::Aggressive,
            _ => Curve::Linear,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Curve::Linear => "linear",
            Curve::Precise => "precise",
            Curve::Aggressive => "aggressive",
        }
    }
}

/// One stick, every field known (the defaults of 06 §7 where no profile sets it).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StickSettings {
    pub inner: f64,
    pub outer: f64,
    pub anti: f64,
    pub sensitivity: f64,
    pub curve: Curve,
    pub invert_x: bool,
    pub invert_y: bool,
    pub smoothing: f64,
}

impl Default for StickSettings {
    fn default() -> Self {
        StickSettings {
            inner: 0.08,
            outer: 0.02,
            anti: 0.0,
            sensitivity: 1.0,
            curve: Curve::Linear,
            invert_x: false,
            invert_y: false,
            smoothing: 0.0,
        }
    }
}

impl StickSettings {
    fn merge(&mut self, s: &Stick) {
        self.inner = s.inner_deadzone.unwrap_or(self.inner);
        self.outer = s.outer_deadzone.unwrap_or(self.outer);
        self.anti = s.anti_deadzone.unwrap_or(self.anti);
        self.sensitivity = s.sensitivity.unwrap_or(self.sensitivity);
        self.curve = s.curve.as_deref().map(Curve::parse).unwrap_or(self.curve);
        self.invert_x = s.invert_x.unwrap_or(self.invert_x);
        self.invert_y = s.invert_y.unwrap_or(self.invert_y);
        self.smoothing = s.smoothing.unwrap_or(self.smoothing);
    }

    fn to_stick(self) -> Stick {
        Stick {
            inner_deadzone: Some(self.inner),
            outer_deadzone: Some(self.outer),
            anti_deadzone: Some(self.anti),
            sensitivity: Some(self.sensitivity),
            curve: Some(self.curve.as_str().to_owned()),
            invert_x: Some(self.invert_x),
            invert_y: Some(self.invert_y),
            smoothing: Some(self.smoothing),
        }
    }
}

/// The output magnitude for a stick magnitude `r` (0..1), by the formula of 06 §7.
pub fn response(r: f64, s: &StickSettings) -> f64 {
    let r = r.clamp(0.0, 1.0);
    let span = 1.0 - s.inner - s.outer;
    // A file cannot set inner + outer >= 1 (profile.rs), but inheritance can combine them: the
    // stick is then on or off at the inner dead zone.
    let rp = if span <= 1e-9 {
        if r > s.inner {
            1.0
        } else {
            0.0
        }
    } else {
        ((r - s.inner) / span).clamp(0.0, 1.0)
    };
    if rp <= 0.0 {
        return 0.0;
    }
    let c = match s.curve {
        Curve::Linear => rp,
        Curve::Precise => rp * rp,
        Curve::Aggressive => rp.sqrt(),
    };
    ((s.anti + (1.0 - s.anti) * c) * s.sensitivity).clamp(0.0, 1.0)
}

fn stick_norm(v: i32) -> f64 {
    (v as f64 / STICK_MAX as f64).clamp(-1.0, 1.0)
}

fn stick_value(v: f64) -> i32 {
    (v * STICK_MAX as f64)
        .round()
        .clamp(STICK_MIN as f64, STICK_MAX as f64) as i32
}

fn trigger_norm(v: i32) -> f64 {
    (v as f64 / TRIGGER_MAX as f64).clamp(0.0, 1.0)
}

fn trigger_value(v: f64) -> i32 {
    (v.clamp(0.0, 1.0) * TRIGGER_MAX as f64).round() as i32
}

/// One stick's (x, y) through the dead zones, the curve, the sensitivity and the inversion.
pub fn stick(x: i32, y: i32, s: &StickSettings) -> (i32, i32) {
    let (fx, fy) = (stick_norm(x), stick_norm(y));
    let raw = (fx * fx + fy * fy).sqrt();
    if raw <= 0.0 {
        return (0, 0);
    }
    // The direction is kept; a square stick's corner (raw > 1) counts as full.
    let k = response(raw.min(1.0), s) / raw;
    let (mut ox, mut oy) = (fx * k, fy * k);
    if s.invert_x {
        ox = -ox;
    }
    if s.invert_y {
        oy = -oy;
    }
    (stick_value(ox), stick_value(oy))
}

/// A trigger (0..32767) through its threshold, used as an inner dead zone.
pub fn trigger(v: i32, threshold: f64) -> i32 {
    let t = trigger_norm(v);
    if threshold >= 1.0 {
        return 0;
    }
    trigger_value(((t - threshold) / (1.0 - threshold)).clamp(0.0, 1.0))
}

/// A profile and its parents, merged: what applies.
#[derive(Debug, Clone, PartialEq)]
pub struct Resolved {
    /// By `from`, the last profile of the chain that maps it wins.
    pub mappings: BTreeMap<Input, Mapping>,
    pub left: StickSettings,
    pub right: StickSettings,
    pub trigger_threshold: f64,
    /// The other settings, the most specific profile's value (applied by T-373).
    pub other: Settings,
}

impl Default for Resolved {
    fn default() -> Self {
        Resolved {
            mappings: BTreeMap::new(),
            left: StickSettings::default(),
            right: StickSettings::default(),
            trigger_threshold: 0.0,
            other: Settings::default(),
        }
    }
}

impl Resolved {
    /// `chain` from the root (the built-in default) to the most specific profile.
    pub fn merge(chain: &[&Profile]) -> Resolved {
        let mut out = Resolved::default();
        for p in chain {
            for m in p.mappings.iter().flatten() {
                out.mappings.insert(m.from.clone(), m.clone());
            }
            if let Some(s) = &p.settings {
                if let Some(l) = &s.left_stick {
                    out.left.merge(l);
                }
                if let Some(r) = &s.right_stick {
                    out.right.merge(r);
                }
                out.trigger_threshold = s.trigger_threshold.unwrap_or(out.trigger_threshold);
                let o = &mut out.other;
                o.gyro_enabled = s.gyro_enabled.or(o.gyro_enabled);
                o.rumble_enabled = s.rumble_enabled.or(o.rumble_enabled);
                o.rumble_strength = s.rumble_strength.or(o.rumble_strength);
            }
        }
        out
    }

    /// The merged profile as one document with every stick field filled in (GetEffectiveProfile):
    /// `top` gives the id, name, scope and match; `inherits` is dropped.
    pub fn flatten(&self, top: &Profile) -> Profile {
        let mut settings = self.other.clone();
        settings.left_stick = Some(self.left.to_stick());
        settings.right_stick = Some(self.right.to_stick());
        settings.trigger_threshold = Some(self.trigger_threshold);
        Profile {
            inherits: None,
            mappings: Some(self.mappings.values().cloned().collect()),
            settings: Some(settings),
            ..top.clone()
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Source {
    Button(PadButton),
    Axis(PadAxis),
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Out {
    Button(PadButton),
    Axis(PadAxis),
    Nothing,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct Route {
    to: Out,
    /// -1 or 1.
    sign: f64,
    scale: f64,
    /// Axis to button: pressed from this value on (and above 0).
    threshold: f64,
}

fn button_of(name: &str) -> Option<PadButton> {
    ALL_BUTTONS.into_iter().find(|b| b.name() == name)
}

fn axis_of(name: &str) -> Option<PadAxis> {
    ALL_AXES.into_iter().find(|a| a.name() == name)
}

fn is_trigger(a: PadAxis) -> bool {
    matches!(a, PadAxis::LeftTrigger | PadAxis::RightTrigger)
}

/// What v1 applies of a mapping, or `None` when it is not applied (the input keeps its default).
fn route_of(m: &Mapping) -> Option<Route> {
    if m.mode.as_deref().is_some_and(|mode| mode != "press") {
        return None;
    }
    let code = m.to.code.as_deref().unwrap_or("");
    let to = match m.to.kind.as_str() {
        "none" => Out::Nothing,
        "button" => match button_of(code)? {
            PadButton::Guide => return None,
            b => Out::Button(b),
        },
        "axis" => Out::Axis(axis_of(code)?),
        _ => return None,
    };
    Some(Route {
        to,
        sign: if m.to.invert == Some(true) { -1.0 } else { 1.0 },
        scale: m.to.scale.unwrap_or(1.0),
        threshold: m.threshold.unwrap_or(0.5),
    })
}

/// A resolved profile, compiled for one virtual pad.
#[derive(Debug, Clone, PartialEq)]
pub struct Engine {
    left: StickSettings,
    right: StickSettings,
    trigger_threshold: f64,
    /// One route per physical input, buttons (Guide excluded) then axes.
    routes: Vec<(Source, Route)>,
}

impl Default for Engine {
    /// The built-in default: every input to itself, the default stick settings.
    fn default() -> Self {
        Engine::compile(&Resolved::default())
    }
}

impl Engine {
    pub fn compile(r: &Resolved) -> Engine {
        let identity = |to| Route {
            to,
            sign: 1.0,
            scale: 1.0,
            threshold: 0.5,
        };
        let mut routes = Vec::new();
        for b in ALL_BUTTONS {
            if b == PadButton::Guide {
                continue;
            }
            let route = r
                .mappings
                .get(&Input::Named(b.name().to_owned()))
                .and_then(route_of)
                .unwrap_or(identity(Out::Button(b)));
            routes.push((Source::Button(b), route));
        }
        for a in ALL_AXES {
            let route = r
                .mappings
                .get(&Input::Named(a.name().to_owned()))
                .and_then(route_of)
                .unwrap_or(identity(Out::Axis(a)));
            routes.push((Source::Axis(a), route));
        }
        Engine {
            left: r.left,
            right: r.right,
            trigger_threshold: r.trigger_threshold,
            routes,
        }
    }

    /// The left and right stick settings.
    pub fn sticks(&self) -> (StickSettings, StickSettings) {
        (self.left, self.right)
    }

    /// The buttons (Guide excluded) whose route differs from `other`'s.
    pub fn buttons_differing(&self, other: &Engine) -> usize {
        self.routes
            .iter()
            .zip(&other.routes)
            .filter(|((s, a), (_, b))| matches!(s, Source::Button(_)) && a != b)
            .count()
    }

    /// What the virtual pad shows for the physical pad's `state`.
    pub fn apply(&self, state: &PadState) -> PadState {
        let (lx, ly) = stick(
            state.axis(PadAxis::LeftX),
            state.axis(PadAxis::LeftY),
            &self.left,
        );
        let (rx, ry) = stick(
            state.axis(PadAxis::RightX),
            state.axis(PadAxis::RightY),
            &self.right,
        );
        let processed = |a: PadAxis| -> f64 {
            match a {
                PadAxis::LeftX => stick_norm(lx),
                PadAxis::LeftY => stick_norm(ly),
                PadAxis::RightX => stick_norm(rx),
                PadAxis::RightY => stick_norm(ry),
                t => trigger_norm(trigger(state.axis(t), self.trigger_threshold)),
            }
        };
        let mut out = PadState::default();
        // Per output axis, the contribution of the largest magnitude.
        let mut axes = [0.0f64; 6];
        let slot = |a: PadAxis| ALL_AXES.iter().position(|&x| x == a).unwrap_or(0);
        let mut contribute = |a: PadAxis, v: f64| {
            let cur = &mut axes[slot(a)];
            if v.abs() > cur.abs() {
                *cur = v;
            }
        };
        for &(source, route) in &self.routes {
            match (source, route.to) {
                (_, Out::Nothing) => {}
                (Source::Button(b), Out::Button(t)) => {
                    if state.pressed(b) {
                        out.apply(PadInput::Button(t, true));
                    }
                }
                (Source::Button(b), Out::Axis(t)) => {
                    if state.pressed(b) {
                        contribute(t, route.sign * route.scale);
                    }
                }
                (Source::Axis(a), Out::Axis(t)) => {
                    contribute(t, processed(a) * route.sign * route.scale);
                }
                (Source::Axis(a), Out::Button(t)) => {
                    let v = processed(a) * route.sign;
                    if v > 0.0 && v >= route.threshold {
                        out.apply(PadInput::Button(t, true));
                    }
                }
            }
        }
        for a in ALL_AXES {
            let v = axes[slot(a)];
            let value = if is_trigger(a) {
                trigger_value(v)
            } else {
                stick_value(v.clamp(-1.0, 1.0))
            };
            out.apply(PadInput::Axis(a, value));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::parse;

    const EPS: f64 = 1e-9;

    fn settings(
        inner: f64,
        outer: f64,
        anti: f64,
        sensitivity: f64,
        curve: Curve,
    ) -> StickSettings {
        StickSettings {
            inner,
            outer,
            anti,
            sensitivity,
            curve,
            ..StickSettings::default()
        }
    }

    #[test]
    fn the_response_follows_the_formula() {
        // (r, settings, expected out): straight from 06 §7.
        let d = StickSettings::default();
        let table: Vec<(f64, StickSettings, f64)> = vec![
            // Defaults: inner 0.08, outer 0.02, Linear.
            (0.0, d, 0.0),
            (0.05, d, 0.0),
            (0.08, d, 0.0),
            (0.53, d, (0.53 - 0.08) / 0.9),
            (0.98, d, 1.0),
            (1.0, d, 1.0),
            // Precise squares r', Aggressive takes its root.
            (0.53, settings(0.08, 0.02, 0.0, 1.0, Curve::Precise), 0.25),
            (
                0.53,
                settings(0.08, 0.02, 0.0, 1.0, Curve::Aggressive),
                0.5f64.sqrt(),
            ),
            // Anti dead zone: the first step past the dead zone jumps to it.
            (
                0.53,
                settings(0.08, 0.02, 0.2, 1.0, Curve::Linear),
                0.2 + 0.8 * 0.5,
            ),
            (0.08, settings(0.08, 0.02, 0.2, 1.0, Curve::Linear), 0.0),
            // Sensitivity scales, clamped to 1.
            (0.53, settings(0.08, 0.02, 0.0, 1.5, Curve::Linear), 0.75),
            (0.89, settings(0.08, 0.02, 0.0, 1.5, Curve::Linear), 1.0),
            (0.53, settings(0.08, 0.02, 0.0, 0.5, Curve::Linear), 0.25),
            // No dead zone at all: the identity.
            (0.3, settings(0.0, 0.0, 0.0, 1.0, Curve::Linear), 0.3),
            // inner + outer >= 1 (only through inheritance): on or off at the inner dead zone.
            (0.59, settings(0.6, 0.5, 0.0, 1.0, Curve::Linear), 0.0),
            (0.61, settings(0.6, 0.5, 0.0, 1.0, Curve::Linear), 1.0),
        ];
        for (r, s, want) in table {
            let got = response(r, &s);
            assert!((got - want).abs() < EPS, "r {r} {s:?}: {got} != {want}");
        }
    }

    #[test]
    fn the_dead_zone_is_round_and_the_direction_is_kept() {
        let d = StickSettings::default();
        // 0.07 along a diagonal: inside the round dead zone (a square one would pass 0.07 / sqrt 2
        // on each axis just as well, but 0.06 on both axes is r 0.085, outside).
        let v = (0.07 / 2f64.sqrt() * STICK_MAX as f64) as i32;
        assert_eq!(stick(v, v, &d), (0, 0));
        let v = (0.06 * STICK_MAX as f64) as i32;
        let (x, y) = stick(v, v, &d);
        assert!(
            x > 0 && x == y,
            "outside the round zone on the diagonal: {x} {y}"
        );
        // The direction: out is along the input's vector.
        let (x, y) = stick(STICK_MAX / 2, -(STICK_MAX / 4), &d);
        let ratio = y as f64 / x as f64;
        assert!((ratio + 0.5).abs() < 1e-3, "direction kept: {x} {y}");
        // A square stick's corner counts as full deflection, not more.
        let (x, y) = stick(STICK_MAX, STICK_MAX, &d);
        let len = ((x as f64).powi(2) + (y as f64).powi(2)).sqrt();
        assert!((len - STICK_MAX as f64).abs() < 2.0, "corner {x} {y}");
        // Full left is full left (−32768 is clamped to −1).
        assert_eq!(stick(STICK_MIN, 0, &d), (-STICK_MAX, 0));
    }

    #[test]
    fn inversion_is_per_axis_after_the_curve() {
        let s = StickSettings {
            invert_y: true,
            ..settings(0.0, 0.0, 0.0, 1.0, Curve::Linear)
        };
        assert_eq!(stick(1000, -2000, &s), (1000, 2000));
        let s = StickSettings {
            invert_x: true,
            ..settings(0.0, 0.0, 0.0, 1.0, Curve::Linear)
        };
        assert_eq!(stick(1000, -2000, &s), (-1000, -2000));
    }

    #[test]
    fn the_trigger_threshold_is_its_inner_dead_zone() {
        assert_eq!(trigger(TRIGGER_MAX / 2, 0.0), TRIGGER_MAX / 2);
        assert_eq!(trigger(TRIGGER_MAX / 4, 0.3), 0);
        assert_eq!(trigger(TRIGGER_MAX, 0.3), TRIGGER_MAX);
        let half = trigger((0.65 * TRIGGER_MAX as f64) as i32, 0.3);
        assert!(
            (half - TRIGGER_MAX / 2).abs() <= 2,
            "0.65 past 0.3 is half: {half}"
        );
        assert_eq!(trigger(TRIGGER_MAX, 1.0), 0);
    }

    fn engine(json_mappings: &str, settings: &str) -> Engine {
        let text = format!(
            r#"{{"schema_version":1,"id":"t","name":"T","scope":{{"type":"global"}},"mappings":{json_mappings},"settings":{settings}}}"#
        );
        let p = parse(&text).unwrap_or_else(|e| panic!("{e:?}"));
        Engine::compile(&Resolved::merge(&[&p]))
    }

    fn state(inputs: &[PadInput]) -> PadState {
        let mut s = PadState::default();
        for &i in inputs {
            s.apply(i);
        }
        s
    }

    use PadAxis::*;
    use PadButton::*;

    #[test]
    fn the_default_engine_passes_buttons_and_applies_the_default_dead_zone() {
        let e = Engine::default();
        let s = state(&[
            PadInput::Button(South, true),
            PadInput::Button(DpadUp, true),
            PadInput::Axis(LeftX, 1000), // inside the 8 % dead zone
            PadInput::Axis(RightTrigger, TRIGGER_MAX),
        ]);
        let out = e.apply(&s);
        assert!(out.pressed(South) && out.pressed(DpadUp));
        assert_eq!(out.axis(LeftX), 0);
        assert_eq!(out.axis(RightTrigger), TRIGGER_MAX);
        assert_eq!(e.apply(&PadState::default()), PadState::default());
    }

    #[test]
    fn button_to_button_swaps_and_none_disables() {
        let e = engine(
            r#"[{"from":"south","to":{"type":"button","code":"east"}},
                {"from":"east","to":{"type":"button","code":"south"}},
                {"from":"west","to":{"type":"none"}}]"#,
            "{}",
        );
        let out = e.apply(&state(&[PadInput::Button(South, true)]));
        assert_eq!(out.buttons(), &[East]);
        let out = e.apply(&state(&[PadInput::Button(East, true)]));
        assert_eq!(out.buttons(), &[South]);
        let out = e.apply(&state(&[PadInput::Button(West, true)]));
        assert!(out.buttons().is_empty());
        // Two sources on one target: held while either is.
        let e = engine(
            r#"[{"from":"l1","to":{"type":"button","code":"south"}}]"#,
            "{}",
        );
        let out = e.apply(&state(&[
            PadInput::Button(L1, true),
            PadInput::Button(South, true),
        ]));
        assert_eq!(out.buttons(), &[South]);
    }

    #[test]
    fn axis_mappings_invert_scale_and_cross() {
        let none = r#"{"left_stick":{"inner_deadzone":0,"outer_deadzone":0},"right_stick":{"inner_deadzone":0,"outer_deadzone":0}}"#;
        let e = engine(
            r#"[{"from":"left_y","to":{"type":"axis","code":"left_y","invert":true}},
                {"from":"right_x","to":{"type":"axis","code":"right_x","scale":0.5}}]"#,
            none,
        );
        let out = e.apply(&state(&[
            PadInput::Axis(LeftY, -10000),
            PadInput::Axis(RightX, 20000),
        ]));
        assert_eq!(out.axis(LeftY), 10000);
        assert_eq!(out.axis(RightX), 10000);
        // A stick axis onto a trigger: only the positive half; a trigger onto a stick axis.
        let e = engine(
            r#"[{"from":"left_x","to":{"type":"axis","code":"right_trigger"}},
                {"from":"left_trigger","to":{"type":"axis","code":"right_y","invert":true}}]"#,
            none,
        );
        let out = e.apply(&state(&[
            PadInput::Axis(LeftX, -STICK_MAX),
            PadInput::Axis(LeftTrigger, TRIGGER_MAX),
        ]));
        assert_eq!(out.axis(RightTrigger), 0);
        assert_eq!(out.axis(RightY), -STICK_MAX);
        let out = e.apply(&state(&[PadInput::Axis(LeftX, STICK_MAX)]));
        assert_eq!(out.axis(RightTrigger), TRIGGER_MAX);
        assert_eq!(
            out.axis(LeftX),
            0,
            "the source no longer drives its own axis"
        );
    }

    #[test]
    fn buttons_and_axes_cross_over() {
        let e = engine(
            r#"[{"from":"r1","to":{"type":"axis","code":"right_trigger"}},
                {"from":"south","to":{"type":"axis","code":"left_x","invert":true,"scale":0.5}},
                {"from":"left_trigger","to":{"type":"button","code":"west"},"threshold":0.4},
                {"from":"right_x","to":{"type":"button","code":"dpad_left","invert":true}}]"#,
            r#"{"right_stick":{"inner_deadzone":0,"outer_deadzone":0}}"#,
        );
        let out = e.apply(&state(&[
            PadInput::Button(R1, true),
            PadInput::Button(South, true),
        ]));
        assert_eq!(out.axis(RightTrigger), TRIGGER_MAX);
        // -0.5 of the range, rounded away from zero.
        assert_eq!(out.axis(LeftX), -16384);
        assert!(!out.pressed(South));
        let at = |v: f64| (v * TRIGGER_MAX as f64) as i32;
        assert!(!e
            .apply(&state(&[PadInput::Axis(LeftTrigger, at(0.39))]))
            .pressed(West));
        assert!(e
            .apply(&state(&[PadInput::Axis(LeftTrigger, at(0.41))]))
            .pressed(West));
        // Inverted: the negative half presses; the default threshold is 0.5.
        assert!(e
            .apply(&state(&[PadInput::Axis(RightX, -STICK_MAX)]))
            .pressed(DpadLeft));
        assert!(!e
            .apply(&state(&[PadInput::Axis(RightX, -STICK_MAX / 3)]))
            .pressed(DpadLeft));
        assert!(!e
            .apply(&state(&[PadInput::Axis(RightX, STICK_MAX)]))
            .pressed(DpadLeft));
        // A threshold of 0 still needs the axis off its rest.
        let e = engine(
            r#"[{"from":"left_trigger","to":{"type":"button","code":"west"},"threshold":0}]"#,
            "{}",
        );
        assert!(!e.apply(&PadState::default()).pressed(West));
    }

    #[test]
    fn what_v1_does_not_apply_keeps_the_default() {
        let e = engine(
            r#"[{"from":"south","to":{"type":"key","code":"r"}},
                {"from":"east","to":{"type":"button","code":"west"},"mode":"turbo","turbo_hz":10},
                {"from":"west","to":{"type":"button","code":"paddle1"}},
                {"from":"north","to":{"type":"button","code":"guide"}},
                {"from":"guide","to":{"type":"button","code":"south"}},
                {"from":"gyro_x","to":{"type":"axis","code":"right_x"}}]"#,
            "{}",
        );
        assert_eq!(e, Engine::default());
        let out = e.apply(&state(&[PadInput::Button(Guide, true)]));
        assert!(
            out.buttons().is_empty(),
            "Guide never reaches the virtual pad"
        );
    }

    #[test]
    fn inheritance_overrides_by_input_and_by_field() {
        let parent = parse(
            r#"{"schema_version":1,"id":"a","name":"A","scope":{"type":"global"},
                "mappings":[{"from":"south","to":{"type":"button","code":"east"}},{"from":"west","to":{"type":"button","code":"north"}}],
                "settings":{"left_stick":{"inner_deadzone":0.2,"curve":"precise"},"trigger_threshold":0.1,"rumble_enabled":false}}"#,
        )
        .unwrap();
        let child = parse(
            r#"{"schema_version":1,"id":"b","name":"B","scope":{"type":"global"},"inherits":"a",
                "mappings":[{"from":"south","to":{"type":"button","code":"south"}}],
                "settings":{"left_stick":{"inner_deadzone":0.12}}}"#,
        )
        .unwrap();
        let r = Resolved::merge(&[&parent, &child]);
        assert_eq!(r.mappings.len(), 2);
        assert_eq!(
            r.mappings[&Input::Named("south".into())].to.code.as_deref(),
            Some("south")
        );
        assert_eq!(r.left.inner, 0.12);
        assert_eq!(
            r.left.curve,
            Curve::Precise,
            "a field the child does not set"
        );
        assert_eq!(r.left.outer, 0.02, "a field nobody sets is the default");
        assert_eq!(r.right, StickSettings::default());
        assert_eq!(r.trigger_threshold, 0.1);
        assert_eq!(r.other.rumble_enabled, Some(false));
        let flat = r.flatten(&child);
        assert!(flat.inherits.is_none());
        let back = parse(&flat.to_json()).expect("the flattened profile is valid");
        assert_eq!(
            back.settings.unwrap().left_stick.unwrap().inner_deadzone,
            Some(0.12)
        );
        let e = Engine::compile(&r);
        assert_eq!(e.buttons_differing(&Engine::default()), 1, "west only");
    }
}
