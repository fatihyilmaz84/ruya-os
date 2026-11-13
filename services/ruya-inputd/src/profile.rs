//! Controller profiles, schema v1 (docs/specs/schemas/input-profile-v1.json, 06-input.md §7): the
//! typed model, the validation every profile passes on load, save and import, and the JSON the
//! service writes back. Pure: text in, a `Profile` or `path: message` lines out.
//!
//! The validation is the schema, keyword for keyword (tests/profile_schema.rs runs both on the same
//! fixtures), plus the rules a schema cannot express (06 §7, "Limits"):
//! - a file of at most 64 KiB, checked before it is parsed;
//! - macros: `press`, `release` and `tap` steps need a `target`, `wait` needs `ms`, no step targets
//!   a macro, and the waits of one macro add up to at most 10 s;
//! - a `button` target names a button and an `axis` target an axis of 06 §4.2;
//! - a stick's inner and outer dead zones leave something between them (their sum is below 1);
//! - a profile does not inherit from itself;
//! - names and descriptions are plain text: no control character and no bidirectional override
//!   or isolate (U+202A..U+202E, U+2066..U+2069), so a file cannot hide or reorder what the shell shows.
//!
//! Imported profiles are untrusted data (requirements §15): nothing in them is ever run.

use serde_json::{Map, Value};

/// The largest profile file, in bytes (06 §7).
pub const MAX_BYTES: usize = 64 * 1024;
/// The longest total wait of one macro, in milliseconds (06 §7).
pub const MAX_MACRO_MS: i64 = 10_000;

/// Buttons by position (06 §4.2).
pub const BUTTONS: [&str; 21] = [
    "south",
    "east",
    "west",
    "north",
    "l1",
    "r1",
    "l3",
    "r3",
    "start",
    "select",
    "guide",
    "dpad_up",
    "dpad_down",
    "dpad_left",
    "dpad_right",
    "paddle1",
    "paddle2",
    "paddle3",
    "paddle4",
    "misc1",
    "touchpad_click",
];
/// Sticks and triggers (06 §4.2).
pub const AXES: [&str; 6] = [
    "left_x",
    "left_y",
    "right_x",
    "right_y",
    "left_trigger",
    "right_trigger",
];
/// Motion and the touchpad as a whole (06 §4.2).
const MOTION: [&str; 7] = [
    "gyro_x", "gyro_y", "gyro_z", "accel_x", "accel_y", "accel_z", "touchpad",
];

const SCOPES_PLAIN: [&str; 2] = ["builtin", "global"];
const FAMILIES: [&str; 4] = ["xbox", "playstation", "nintendo", "generic"];
const OUTPUTS: [&str; 5] = ["xbox", "playstation", "generic", "keyboard_mouse", "none"];
const NODES: [&str; 3] = ["pad", "motion", "touchpad"];
const TARGETS: [&str; 10] = [
    "button",
    "axis",
    "key",
    "mouse_button",
    "mouse_move",
    "scroll",
    "layer",
    "macro",
    "action",
    "none",
];
const MODES: [&str; 6] = [
    "press",
    "hold",
    "toggle",
    "long_press",
    "double_press",
    "turbo",
];
const ACTIVATIONS: [&str; 3] = ["momentary", "toggle", "conditional"];
const STEPS: [&str; 4] = ["press", "release", "tap", "wait"];
const CURVES: [&str; 3] = ["linear", "precise", "aggressive"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Scope {
    Builtin,
    Global,
    Platform(String),
    Game(String),
}

impl Scope {
    /// The `scope` of a profile summary: "builtin" | "global" | "platform" | "game".
    pub fn kind(&self) -> &'static str {
        match self {
            Scope::Builtin => "builtin",
            Scope::Global => "global",
            Scope::Platform(_) => "platform",
            Scope::Game(_) => "game",
        }
    }

    /// The app id of a platform or game profile, else "".
    pub fn scope_id(&self) -> &str {
        match self {
            Scope::Platform(id) | Scope::Game(id) => id,
            _ => "",
        }
    }
}

/// A normalised input (06 §4.2) or a raw source event.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum Input {
    Named(String),
    Raw {
        node: String,
        ev_type: i64,
        code: i64,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Target {
    pub kind: String,
    pub code: Option<String>,
    pub invert: Option<bool>,
    pub scale: Option<f64>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Mapping {
    pub from: Input,
    pub to: Target,
    pub mode: Option<String>,
    pub hold_ms: Option<i64>,
    pub turbo_hz: Option<f64>,
    pub threshold: Option<f64>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Layer {
    pub id: String,
    pub name: Option<String>,
    pub activation: String,
    pub trigger: Option<Input>,
    pub priority: Option<i64>,
    pub mappings: Vec<Mapping>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Chord {
    pub inputs: Vec<Input>,
    pub to: Target,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Step {
    pub kind: String,
    pub target: Option<Target>,
    pub ms: Option<i64>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Macro {
    pub id: String,
    pub steps: Vec<Step>,
    pub cancel_on_release: Option<bool>,
}

/// One stick's settings; a field that is absent comes from the parent profile.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Stick {
    pub inner_deadzone: Option<f64>,
    pub outer_deadzone: Option<f64>,
    pub anti_deadzone: Option<f64>,
    pub sensitivity: Option<f64>,
    pub curve: Option<String>,
    pub invert_x: Option<bool>,
    pub invert_y: Option<bool>,
    pub smoothing: Option<f64>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Settings {
    pub gyro_enabled: Option<bool>,
    pub rumble_enabled: Option<bool>,
    pub rumble_strength: Option<f64>,
    pub left_stick: Option<Stick>,
    pub right_stick: Option<Stick>,
    pub trigger_threshold: Option<f64>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Match {
    pub family: Option<String>,
    pub device: Option<String>,
}

/// A profile as its file says it: what it does not set comes from its parent (`inherits`, the
/// built-in `default` when absent).
#[derive(Debug, Clone, PartialEq)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    pub scope: Scope,
    pub inherits: Option<String>,
    pub matches: Option<Match>,
    pub output: Option<String>,
    pub mappings: Option<Vec<Mapping>>,
    pub layers: Option<Vec<Layer>>,
    pub chords: Option<Vec<Chord>>,
    pub macros: Option<Vec<Macro>>,
    pub settings: Option<Settings>,
}

// ---- patterns of the schema ----------------------------------------------------------------

fn chars_ok(
    s: &str,
    first: impl Fn(char) -> bool,
    rest: impl Fn(char) -> bool,
    max: usize,
) -> bool {
    let mut it = s.chars();
    match it.next() {
        Some(c) if first(c) => {}
        _ => return false,
    }
    s.chars().count() <= max && it.all(rest)
}

/// `^[a-z0-9][a-z0-9._-]{0,63}$`
pub fn valid_id(s: &str) -> bool {
    let lower = |c: char| c.is_ascii_lowercase() || c.is_ascii_digit();
    chars_ok(s, lower, |c| lower(c) || matches!(c, '.' | '_' | '-'), 64)
}

/// `^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$`
fn valid_app_id(s: &str) -> bool {
    chars_ok(
        s,
        |c| c.is_ascii_alphanumeric(),
        |c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'),
        255,
    )
}

/// One of the families a `match.family` may name.
pub fn valid_family(s: &str) -> bool {
    FAMILIES.contains(&s)
}

/// `^[a-z0-9:-]{1,64}$`
pub fn valid_device(s: &str) -> bool {
    let ok = |c: char| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, ':' | '-');
    chars_ok(s, ok, ok, 64)
}

/// `^[a-z0-9_]{1,32}$`
fn valid_code(s: &str) -> bool {
    let ok = |c: char| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_';
    chars_ok(s, ok, ok, 32)
}

/// Plain text (a service rule): no control character, no bidirectional override or isolate.
fn plain_text(s: &str) -> bool {
    !s.chars().any(|c| {
        c.is_control()
            || ('\u{202a}'..='\u{202e}').contains(&c)
            || ('\u{2066}'..='\u{2069}').contains(&c)
    })
}

// ---- the checker -----------------------------------------------------------------------------

/// Collects `path: message` lines while it walks the document.
struct Check {
    errors: Vec<String>,
}

impl Check {
    fn err(&mut self, path: &str, msg: impl std::fmt::Display) {
        let path = if path.is_empty() { "/" } else { path };
        self.errors.push(format!("{path}: {msg}"));
    }

    fn object<'a>(
        &mut self,
        v: &'a Value,
        path: &str,
        known: &[&str],
        required: &[&str],
    ) -> Option<&'a Map<String, Value>> {
        let Some(o) = v.as_object() else {
            self.err(path, "not an object");
            return None;
        };
        for k in o.keys() {
            if !known.contains(&k.as_str()) {
                self.err(path, format!("unknown field {k}"));
            }
        }
        for r in required {
            if !o.contains_key(*r) {
                self.err(path, format!("\"{r}\" is required"));
            }
        }
        Some(o)
    }

    fn string(&mut self, v: &Value, path: &str, min: usize, max: usize) -> Option<String> {
        let Some(s) = v.as_str() else {
            self.err(path, "not a string");
            return None;
        };
        let len = s.chars().count();
        if len < min || len > max {
            self.err(path, format!("length {len}, allowed {min} to {max}"));
            return None;
        }
        Some(s.to_owned())
    }

    fn text(&mut self, v: &Value, path: &str, min: usize, max: usize) -> Option<String> {
        let s = self.string(v, path, min, max)?;
        if !plain_text(&s) {
            self.err(path, "contains a control or text-direction character");
            return None;
        }
        Some(s)
    }

    fn pattern(&mut self, v: &Value, path: &str, ok: fn(&str) -> bool) -> Option<String> {
        let Some(s) = v.as_str() else {
            self.err(path, "not a string");
            return None;
        };
        if !ok(s) {
            self.err(path, format!("{s:?} is not a valid value here"));
            return None;
        }
        Some(s.to_owned())
    }

    fn one_of(&mut self, v: &Value, path: &str, values: &[&str]) -> Option<String> {
        match v.as_str() {
            Some(s) if values.contains(&s) => Some(s.to_owned()),
            _ => {
                self.err(path, format!("{v} is not one of {}", values.join(", ")));
                None
            }
        }
    }

    fn number(&mut self, v: &Value, path: &str, min: f64, max: f64) -> Option<f64> {
        let Some(n) = v.as_f64().filter(|_| v.is_number()) else {
            self.err(path, "not a number");
            return None;
        };
        if n < min || n > max {
            self.err(path, format!("{n}, allowed {min} to {max}"));
            return None;
        }
        Some(n)
    }

    fn integer(&mut self, v: &Value, path: &str, min: i64, max: i64) -> Option<i64> {
        let Some(n) = v.as_i64() else {
            self.err(path, "not an integer");
            return None;
        };
        if n < min || n > max {
            self.err(path, format!("{n}, allowed {min} to {max}"));
            return None;
        }
        Some(n)
    }

    fn boolean(&mut self, v: &Value, path: &str) -> Option<bool> {
        let b = v.as_bool();
        if b.is_none() {
            self.err(path, "not a boolean");
        }
        b
    }

    fn array<'a>(
        &mut self,
        v: &'a Value,
        path: &str,
        min: usize,
        max: usize,
    ) -> Option<&'a Vec<Value>> {
        let Some(a) = v.as_array() else {
            self.err(path, "not an array");
            return None;
        };
        if a.len() < min {
            self.err(path, format!("{} items, minItems {min}", a.len()));
        }
        if a.len() > max {
            self.err(path, format!("{} items, maxItems {max}", a.len()));
        }
        Some(a)
    }

    // ---- the definitions of the schema ----

    fn input(&mut self, v: &Value, path: &str) -> Option<Input> {
        if let Some(s) = v.as_str() {
            let known = BUTTONS.contains(&s) || AXES.contains(&s) || MOTION.contains(&s);
            if !known {
                self.err(path, format!("{s:?} is not an input"));
                return None;
            }
            return Some(Input::Named(s.to_owned()));
        }
        let o = self.object(v, path, &["raw"], &["raw"])?;
        let raw_path = format!("{path}/raw");
        let raw = self.object(
            o.get("raw")?,
            &raw_path,
            &["node", "type", "code"],
            &["node", "type", "code"],
        )?;
        let node = raw
            .get("node")
            .and_then(|n| self.one_of(n, &format!("{raw_path}/node"), &NODES));
        let ev_type = raw
            .get("type")
            .and_then(|n| self.integer(n, &format!("{raw_path}/type"), 0, 31));
        let code = raw
            .get("code")
            .and_then(|n| self.integer(n, &format!("{raw_path}/code"), 0, 767));
        Some(Input::Raw {
            node: node?,
            ev_type: ev_type?,
            code: code?,
        })
    }

    fn target(&mut self, v: &Value, path: &str) -> Option<Target> {
        let o = self.object(v, path, &["type", "code", "invert", "scale"], &["type"])?;
        let kind = o
            .get("type")
            .and_then(|t| self.one_of(t, &format!("{path}/type"), &TARGETS));
        let code = o
            .get("code")
            .and_then(|c| self.pattern(c, &format!("{path}/code"), valid_code));
        let invert = o
            .get("invert")
            .and_then(|b| self.boolean(b, &format!("{path}/invert")));
        let scale = o
            .get("scale")
            .and_then(|n| self.number(n, &format!("{path}/scale"), -8.0, 8.0));
        let kind = kind?;
        // Service rule: a pad target names a button or an axis of 06 §4.2.
        let names: Option<&[&str]> = match kind.as_str() {
            "button" => Some(&BUTTONS),
            "axis" => Some(&AXES),
            _ => None,
        };
        if let Some(names) = names {
            match &code {
                None if !o.contains_key("code") => {
                    self.err(path, format!("a {kind} target needs a code"))
                }
                Some(c) if !names.contains(&c.as_str()) => {
                    self.err(&format!("{path}/code"), format!("{c:?} is not a {kind}"))
                }
                _ => {}
            }
        }
        Some(Target {
            kind,
            code,
            invert,
            scale,
        })
    }

    fn mapping(&mut self, v: &Value, path: &str) -> Option<Mapping> {
        let o = self.object(
            v,
            path,
            &["from", "to", "mode", "hold_ms", "turbo_hz", "threshold"],
            &["from", "to"],
        )?;
        let from = o
            .get("from")
            .and_then(|i| self.input(i, &format!("{path}/from")));
        let to = o
            .get("to")
            .and_then(|t| self.target(t, &format!("{path}/to")));
        let mode = o
            .get("mode")
            .and_then(|m| self.one_of(m, &format!("{path}/mode"), &MODES));
        let hold_ms = o
            .get("hold_ms")
            .and_then(|n| self.integer(n, &format!("{path}/hold_ms"), 100, 5000));
        let turbo_hz = o
            .get("turbo_hz")
            .and_then(|n| self.number(n, &format!("{path}/turbo_hz"), 1.0, 30.0));
        let threshold = o
            .get("threshold")
            .and_then(|n| self.number(n, &format!("{path}/threshold"), 0.0, 1.0));
        Some(Mapping {
            from: from?,
            to: to?,
            mode,
            hold_ms,
            turbo_hz,
            threshold,
        })
    }

    fn mappings(&mut self, v: &Value, path: &str) -> Option<Vec<Mapping>> {
        let a = self.array(v, path, 0, 256)?;
        let out: Vec<Option<Mapping>> = a
            .iter()
            .enumerate()
            .map(|(n, m)| self.mapping(m, &format!("{path}/{n}")))
            .collect();
        out.into_iter().collect()
    }

    fn layer(&mut self, v: &Value, path: &str) -> Option<Layer> {
        let o = self.object(
            v,
            path,
            &[
                "id",
                "name",
                "activation",
                "trigger",
                "priority",
                "mappings",
            ],
            &["id", "activation", "mappings"],
        )?;
        let id = o
            .get("id")
            .and_then(|s| self.pattern(s, &format!("{path}/id"), valid_id));
        let name = o
            .get("name")
            .and_then(|s| self.text(s, &format!("{path}/name"), 1, 64));
        let activation = o
            .get("activation")
            .and_then(|s| self.one_of(s, &format!("{path}/activation"), &ACTIVATIONS));
        let trigger = o
            .get("trigger")
            .and_then(|i| self.input(i, &format!("{path}/trigger")));
        let priority = o
            .get("priority")
            .and_then(|n| self.integer(n, &format!("{path}/priority"), 0, 7));
        let mappings = o
            .get("mappings")
            .and_then(|m| self.mappings(m, &format!("{path}/mappings")));
        Some(Layer {
            id: id?,
            name,
            activation: activation?,
            trigger,
            priority,
            mappings: mappings?,
        })
    }

    fn chord(&mut self, v: &Value, path: &str) -> Option<Chord> {
        let o = self.object(v, path, &["inputs", "to"], &["inputs", "to"])?;
        let inputs = o.get("inputs").and_then(|a| {
            let ipath = format!("{path}/inputs");
            let a = self.array(a, &ipath, 2, 4)?;
            let out: Vec<Option<Input>> = a
                .iter()
                .enumerate()
                .map(|(n, i)| self.input(i, &format!("{ipath}/{n}")))
                .collect();
            out.into_iter().collect::<Option<Vec<Input>>>()
        });
        let to = o
            .get("to")
            .and_then(|t| self.target(t, &format!("{path}/to")));
        Some(Chord {
            inputs: inputs?,
            to: to?,
        })
    }

    fn step(&mut self, v: &Value, path: &str) -> Option<Step> {
        let o = self.object(v, path, &["type", "target", "ms"], &["type"])?;
        let kind = o
            .get("type")
            .and_then(|s| self.one_of(s, &format!("{path}/type"), &STEPS));
        let target = o
            .get("target")
            .and_then(|t| self.target(t, &format!("{path}/target")));
        let ms = o
            .get("ms")
            .and_then(|n| self.integer(n, &format!("{path}/ms"), 10, 10_000));
        let kind = kind?;
        // Service rules: what each step needs, and no macro inside a macro.
        if kind == "wait" && !o.contains_key("ms") {
            self.err(path, "a wait step needs ms");
        }
        if kind != "wait" && !o.contains_key("target") {
            self.err(path, format!("a {kind} step needs a target"));
        }
        if target.as_ref().is_some_and(|t| t.kind == "macro") {
            self.err(
                &format!("{path}/target"),
                "a macro step never targets a macro",
            );
        }
        Some(Step { kind, target, ms })
    }

    fn macro_def(&mut self, v: &Value, path: &str) -> Option<Macro> {
        let o = self.object(
            v,
            path,
            &["id", "steps", "cancel_on_release"],
            &["id", "steps"],
        )?;
        let id = o
            .get("id")
            .and_then(|s| self.pattern(s, &format!("{path}/id"), valid_id));
        let steps = o.get("steps").and_then(|a| {
            let spath = format!("{path}/steps");
            let a = self.array(a, &spath, 1, 32)?;
            let out: Vec<Option<Step>> = a
                .iter()
                .enumerate()
                .map(|(n, s)| self.step(s, &format!("{spath}/{n}")))
                .collect();
            out.into_iter().collect::<Option<Vec<Step>>>()
        });
        let cancel_on_release = o
            .get("cancel_on_release")
            .and_then(|b| self.boolean(b, &format!("{path}/cancel_on_release")));
        if let Some(steps) = &steps {
            let total: i64 = steps.iter().filter_map(|s| s.ms).sum();
            if total > MAX_MACRO_MS {
                self.err(
                    &format!("{path}/steps"),
                    format!("the waits add up to {total} ms, at most {MAX_MACRO_MS} ms"),
                );
            }
        }
        Some(Macro {
            id: id?,
            steps: steps?,
            cancel_on_release,
        })
    }

    fn stick(&mut self, v: &Value, path: &str) -> Option<Stick> {
        let o = self.object(
            v,
            path,
            &[
                "inner_deadzone",
                "outer_deadzone",
                "anti_deadzone",
                "sensitivity",
                "curve",
                "invert_x",
                "invert_y",
                "smoothing",
            ],
            &[],
        )?;
        let num = |c: &mut Check, k: &str, min, max| {
            o.get(k)
                .and_then(|n| c.number(n, &format!("{path}/{k}"), min, max))
        };
        let inner_deadzone = num(self, "inner_deadzone", 0.0, 0.9);
        let outer_deadzone = num(self, "outer_deadzone", 0.0, 0.5);
        let anti_deadzone = num(self, "anti_deadzone", 0.0, 0.9);
        let sensitivity = num(self, "sensitivity", 0.1, 4.0);
        let smoothing = num(self, "smoothing", 0.0, 1.0);
        let curve = o
            .get("curve")
            .and_then(|s| self.one_of(s, &format!("{path}/curve"), &CURVES));
        let invert_x = o
            .get("invert_x")
            .and_then(|b| self.boolean(b, &format!("{path}/invert_x")));
        let invert_y = o
            .get("invert_y")
            .and_then(|b| self.boolean(b, &format!("{path}/invert_y")));
        if let (Some(inner), Some(outer)) = (inner_deadzone, outer_deadzone) {
            if inner + outer >= 1.0 {
                self.err(
                    path,
                    "inner_deadzone and outer_deadzone add up to 1 or more",
                );
            }
        }
        Some(Stick {
            inner_deadzone,
            outer_deadzone,
            anti_deadzone,
            sensitivity,
            curve,
            invert_x,
            invert_y,
            smoothing,
        })
    }

    fn settings(&mut self, v: &Value, path: &str) -> Option<Settings> {
        let o = self.object(
            v,
            path,
            &[
                "gyro_enabled",
                "rumble_enabled",
                "rumble_strength",
                "left_stick",
                "right_stick",
                "trigger_threshold",
            ],
            &[],
        )?;
        let gyro_enabled = o
            .get("gyro_enabled")
            .and_then(|b| self.boolean(b, &format!("{path}/gyro_enabled")));
        let rumble_enabled = o
            .get("rumble_enabled")
            .and_then(|b| self.boolean(b, &format!("{path}/rumble_enabled")));
        let rumble_strength = o
            .get("rumble_strength")
            .and_then(|n| self.number(n, &format!("{path}/rumble_strength"), 0.0, 1.0));
        let trigger_threshold = o
            .get("trigger_threshold")
            .and_then(|n| self.number(n, &format!("{path}/trigger_threshold"), 0.0, 1.0));
        let left_stick = o
            .get("left_stick")
            .map(|s| self.stick(s, &format!("{path}/left_stick")));
        let right_stick = o
            .get("right_stick")
            .map(|s| self.stick(s, &format!("{path}/right_stick")));
        Some(Settings {
            gyro_enabled,
            rumble_enabled,
            rumble_strength,
            left_stick: left_stick.flatten(),
            right_stick: right_stick.flatten(),
            trigger_threshold,
        })
    }

    fn scope(&mut self, v: &Value, path: &str) -> Option<Scope> {
        let Some(o) = v.as_object() else {
            self.err(path, "not an object");
            return None;
        };
        let kind = o.get("type").and_then(Value::as_str).unwrap_or("");
        let (known, required, key): (&[&str], &[&str], &str) = match kind {
            k if SCOPES_PLAIN.contains(&k) => (&["type"], &["type"], ""),
            "platform" => (
                &["type", "platform_id"],
                &["type", "platform_id"],
                "platform_id",
            ),
            "game" => (&["type", "game_id"], &["type", "game_id"], "game_id"),
            _ => {
                self.err(path, "type is not one of builtin, global, platform, game");
                return None;
            }
        };
        let before = self.errors.len();
        self.object(v, path, known, required)?;
        let id = if key.is_empty() {
            None
        } else {
            o.get(key)
                .and_then(|s| self.pattern(s, &format!("{path}/{key}"), valid_app_id))
        };
        if self.errors.len() != before {
            return None;
        }
        Some(match kind {
            "builtin" => Scope::Builtin,
            "global" => Scope::Global,
            "platform" => Scope::Platform(id?),
            _ => Scope::Game(id?),
        })
    }

    fn matches(&mut self, v: &Value, path: &str) -> Option<Match> {
        let o = self.object(v, path, &["family", "device"], &[])?;
        let family = o
            .get("family")
            .and_then(|s| self.one_of(s, &format!("{path}/family"), &FAMILIES));
        let device = o
            .get("device")
            .and_then(|s| self.pattern(s, &format!("{path}/device"), valid_device));
        Some(Match { family, device })
    }

    fn profile(&mut self, v: &Value) -> Option<Profile> {
        let o = self.object(
            v,
            "",
            &[
                "schema_version",
                "id",
                "name",
                "description",
                "scope",
                "inherits",
                "match",
                "output",
                "mappings",
                "layers",
                "chords",
                "macros",
                "settings",
            ],
            &["schema_version", "id", "name", "scope"],
        )?;
        if let Some(version) = o.get("schema_version") {
            if version.as_u64() != Some(1) || !version.is_u64() {
                self.err("/schema_version", "must be 1");
            }
        }
        let id = o.get("id").and_then(|s| self.pattern(s, "/id", valid_id));
        let name = o.get("name").and_then(|s| self.text(s, "/name", 1, 64));
        let description = o
            .get("description")
            .and_then(|s| self.text(s, "/description", 0, 512));
        let scope = o.get("scope").and_then(|s| self.scope(s, "/scope"));
        let inherits = o
            .get("inherits")
            .and_then(|s| self.pattern(s, "/inherits", valid_id));
        let matches = o.get("match").and_then(|m| self.matches(m, "/match"));
        let output = o.get("output").and_then(|out| {
            let oo = self.object(out, "/output", &["type"], &["type"])?;
            oo.get("type")
                .and_then(|t| self.one_of(t, "/output/type", &OUTPUTS))
        });
        let mappings = o.get("mappings").map(|m| self.mappings(m, "/mappings"));
        let layers = o.get("layers").map(|a| {
            let a = self.array(a, "/layers", 0, 8)?;
            let out: Vec<Option<Layer>> = a
                .iter()
                .enumerate()
                .map(|(n, l)| self.layer(l, &format!("/layers/{n}")))
                .collect();
            out.into_iter().collect::<Option<Vec<Layer>>>()
        });
        let chords = o.get("chords").map(|a| {
            let a = self.array(a, "/chords", 0, 32)?;
            let out: Vec<Option<Chord>> = a
                .iter()
                .enumerate()
                .map(|(n, c)| self.chord(c, &format!("/chords/{n}")))
                .collect();
            out.into_iter().collect::<Option<Vec<Chord>>>()
        });
        let macros = o.get("macros").map(|a| {
            let a = self.array(a, "/macros", 0, 16)?;
            let out: Vec<Option<Macro>> = a
                .iter()
                .enumerate()
                .map(|(n, m)| self.macro_def(m, &format!("/macros/{n}")))
                .collect();
            out.into_iter().collect::<Option<Vec<Macro>>>()
        });
        let settings = o.get("settings").map(|s| self.settings(s, "/settings"));
        if let (Some(id), Some(parent)) = (&id, &inherits) {
            if id == parent {
                self.err("/inherits", "a profile cannot inherit from itself");
            }
        }
        if !self.errors.is_empty() {
            return None;
        }
        Some(Profile {
            id: id?,
            name: name?,
            description,
            scope: scope?,
            inherits,
            matches,
            output,
            mappings: mappings.flatten(),
            layers: layers.flatten(),
            chords: chords.flatten(),
            macros: macros.flatten(),
            settings: settings.flatten(),
        })
    }
}

/// Validates a parsed document: the profile, or every error as a `path: message` line.
pub fn from_value(v: &Value) -> Result<Profile, Vec<String>> {
    let mut check = Check { errors: Vec::new() };
    match check.profile(v) {
        Some(p) if check.errors.is_empty() => Ok(p),
        _ => {
            if check.errors.is_empty() {
                check.err("", "not a valid profile");
            }
            Err(check.errors)
        }
    }
}

/// Validates profile text (a file, an import, a `SaveProfile` argument): at most 64 KiB, checked
/// before parsing; JSON; then the schema and the service rules.
pub fn parse(text: &str) -> Result<Profile, Vec<String>> {
    if text.len() > MAX_BYTES {
        return Err(vec![format!(
            "/: {} bytes, larger than {MAX_BYTES} bytes",
            text.len()
        )]);
    }
    let value: Value = serde_json::from_str(text).map_err(|e| {
        vec![format!(
            "/: not JSON (line {}, column {})",
            e.line(),
            e.column()
        )]
    })?;
    from_value(&value)
}

// ---- writing it back ---------------------------------------------------------------------------

/// A number as JSON: a whole number is written without a fraction (15, not 15.0), so a file reads
/// back as it was written.
fn number(v: f64) -> Value {
    if v.fract() == 0.0 && v.abs() < 1e15 {
        Value::from(v as i64)
    } else {
        Value::from(v)
    }
}

fn input_value(i: &Input) -> Value {
    match i {
        Input::Named(n) => Value::from(n.as_str()),
        Input::Raw {
            node,
            ev_type,
            code,
        } => serde_json::json!({ "raw": { "node": node, "type": ev_type, "code": code } }),
    }
}

fn target_value(t: &Target) -> Value {
    let mut o = Map::new();
    o.insert("type".into(), Value::from(t.kind.as_str()));
    if let Some(c) = &t.code {
        o.insert("code".into(), Value::from(c.as_str()));
    }
    if let Some(b) = t.invert {
        o.insert("invert".into(), Value::from(b));
    }
    if let Some(s) = t.scale {
        o.insert("scale".into(), number(s));
    }
    Value::Object(o)
}

fn mapping_value(m: &Mapping) -> Value {
    let mut o = Map::new();
    o.insert("from".into(), input_value(&m.from));
    o.insert("to".into(), target_value(&m.to));
    if let Some(v) = &m.mode {
        o.insert("mode".into(), Value::from(v.as_str()));
    }
    if let Some(v) = m.hold_ms {
        o.insert("hold_ms".into(), Value::from(v));
    }
    if let Some(v) = m.turbo_hz {
        o.insert("turbo_hz".into(), number(v));
    }
    if let Some(v) = m.threshold {
        o.insert("threshold".into(), number(v));
    }
    Value::Object(o)
}

fn stick_value(s: &Stick) -> Value {
    let mut o = Map::new();
    let mut put = |k: &str, v: Option<Value>| {
        if let Some(v) = v {
            o.insert(k.into(), v);
        }
    };
    put("inner_deadzone", s.inner_deadzone.map(number));
    put("outer_deadzone", s.outer_deadzone.map(number));
    put("anti_deadzone", s.anti_deadzone.map(number));
    put("sensitivity", s.sensitivity.map(number));
    put("curve", s.curve.as_deref().map(Value::from));
    put("invert_x", s.invert_x.map(Value::from));
    put("invert_y", s.invert_y.map(Value::from));
    put("smoothing", s.smoothing.map(number));
    Value::Object(o)
}

fn settings_value(s: &Settings) -> Value {
    let mut o = Map::new();
    let mut put = |k: &str, v: Option<Value>| {
        if let Some(v) = v {
            o.insert(k.into(), v);
        }
    };
    put("gyro_enabled", s.gyro_enabled.map(Value::from));
    put("rumble_enabled", s.rumble_enabled.map(Value::from));
    put("rumble_strength", s.rumble_strength.map(number));
    put("left_stick", s.left_stick.as_ref().map(stick_value));
    put("right_stick", s.right_stick.as_ref().map(stick_value));
    put("trigger_threshold", s.trigger_threshold.map(number));
    Value::Object(o)
}

impl Profile {
    /// The profile as a schema-v1 document (only what it sets).
    pub fn to_value(&self) -> Value {
        let mut o = Map::new();
        o.insert("schema_version".into(), Value::from(1));
        o.insert("id".into(), Value::from(self.id.as_str()));
        o.insert("name".into(), Value::from(self.name.as_str()));
        if let Some(d) = &self.description {
            o.insert("description".into(), Value::from(d.as_str()));
        }
        let mut scope = Map::new();
        scope.insert("type".into(), Value::from(self.scope.kind()));
        match &self.scope {
            Scope::Platform(id) => {
                scope.insert("platform_id".into(), Value::from(id.as_str()));
            }
            Scope::Game(id) => {
                scope.insert("game_id".into(), Value::from(id.as_str()));
            }
            _ => {}
        }
        o.insert("scope".into(), Value::Object(scope));
        if let Some(p) = &self.inherits {
            o.insert("inherits".into(), Value::from(p.as_str()));
        }
        if let Some(m) = &self.matches {
            let mut mm = Map::new();
            if let Some(f) = &m.family {
                mm.insert("family".into(), Value::from(f.as_str()));
            }
            if let Some(d) = &m.device {
                mm.insert("device".into(), Value::from(d.as_str()));
            }
            o.insert("match".into(), Value::Object(mm));
        }
        if let Some(t) = &self.output {
            o.insert("output".into(), serde_json::json!({ "type": t }));
        }
        if let Some(ms) = &self.mappings {
            o.insert("mappings".into(), ms.iter().map(mapping_value).collect());
        }
        if let Some(ls) = &self.layers {
            let layers = ls
                .iter()
                .map(|l| {
                    let mut lo = Map::new();
                    lo.insert("id".into(), Value::from(l.id.as_str()));
                    if let Some(n) = &l.name {
                        lo.insert("name".into(), Value::from(n.as_str()));
                    }
                    lo.insert("activation".into(), Value::from(l.activation.as_str()));
                    if let Some(t) = &l.trigger {
                        lo.insert("trigger".into(), input_value(t));
                    }
                    if let Some(p) = l.priority {
                        lo.insert("priority".into(), Value::from(p));
                    }
                    lo.insert(
                        "mappings".into(),
                        l.mappings.iter().map(mapping_value).collect(),
                    );
                    Value::Object(lo)
                })
                .collect();
            o.insert("layers".into(), layers);
        }
        if let Some(cs) = &self.chords {
            let chords = cs
                .iter()
                .map(|c| {
                    serde_json::json!({
                        "inputs": c.inputs.iter().map(input_value).collect::<Vec<_>>(),
                        "to": target_value(&c.to),
                    })
                })
                .collect();
            o.insert("chords".into(), chords);
        }
        if let Some(ms) = &self.macros {
            let macros = ms
                .iter()
                .map(|m| {
                    let steps: Vec<Value> = m
                        .steps
                        .iter()
                        .map(|s| {
                            let mut so = Map::new();
                            so.insert("type".into(), Value::from(s.kind.as_str()));
                            if let Some(t) = &s.target {
                                so.insert("target".into(), target_value(t));
                            }
                            if let Some(ms) = s.ms {
                                so.insert("ms".into(), Value::from(ms));
                            }
                            Value::Object(so)
                        })
                        .collect();
                    let mut mo = Map::new();
                    mo.insert("id".into(), Value::from(m.id.as_str()));
                    mo.insert("steps".into(), Value::from(steps));
                    if let Some(c) = m.cancel_on_release {
                        mo.insert("cancel_on_release".into(), Value::from(c));
                    }
                    Value::Object(mo)
                })
                .collect();
            o.insert("macros".into(), macros);
        }
        if let Some(s) = &self.settings {
            o.insert("settings".into(), settings_value(s));
        }
        Value::Object(o)
    }

    /// The profile as JSON text, as the service stores and returns it.
    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(&self.to_value()).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(text: &str) -> Profile {
        parse(text).unwrap_or_else(|e| panic!("refused: {e:?}"))
    }

    fn refused(text: &str, needle: &str) {
        match parse(text) {
            Ok(p) => panic!("accepted {p:?}, wanted an error with {needle:?}"),
            Err(errors) => assert!(
                errors.iter().any(|e| e.contains(needle)),
                "no error with {needle:?} in {errors:?}"
            ),
        }
    }

    const MIN: &str = r#"{"schema_version":1,"id":"p","name":"P","scope":{"type":"global"}"#;

    fn with(extra: &str) -> String {
        format!("{MIN},{extra}}}")
    }

    #[test]
    fn a_minimal_profile_is_accepted_and_written_back_the_same() {
        let p = ok(&format!("{MIN}}}"));
        assert_eq!(p.id, "p");
        assert_eq!(p.scope, Scope::Global);
        assert_eq!(parse(&p.to_json()).unwrap(), p);
    }

    #[test]
    fn every_section_round_trips() {
        let text = with(
            r#""description":"d","inherits":"nintendo","match":{"family":"playstation","device":"usb-1-2-abc"},
            "output":{"type":"xbox"},
            "mappings":[{"from":"south","to":{"type":"button","code":"east"}},
                        {"from":{"raw":{"node":"pad","type":1,"code":316}},"to":{"type":"none"}},
                        {"from":"right_x","to":{"type":"axis","code":"left_x","invert":true,"scale":0.5},"threshold":0.4,"mode":"press"}],
            "layers":[{"id":"l","name":"L","activation":"momentary","trigger":"l1","priority":2,"mappings":[]}],
            "chords":[{"inputs":["guide","west"],"to":{"type":"action","code":"screenshot"}}],
            "macros":[{"id":"m","cancel_on_release":true,"steps":[{"type":"tap","target":{"type":"key","code":"r"}},{"type":"wait","ms":50}]}],
            "settings":{"gyro_enabled":false,"rumble_enabled":true,"rumble_strength":0.5,"trigger_threshold":0.1,
                        "left_stick":{"inner_deadzone":0.1,"outer_deadzone":0.05,"anti_deadzone":0.2,"sensitivity":1.5,"curve":"precise","invert_x":true,"invert_y":false,"smoothing":0.3},
                        "right_stick":{}}"#,
        );
        let p = ok(&text);
        assert_eq!(parse(&p.to_json()).unwrap(), p);
        let original: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(p.to_value(), original, "nothing is added or lost");
    }

    #[test]
    fn the_size_cap_is_checked_before_parsing() {
        // Not JSON at all, but too large: the size is the reason, the parser never runs.
        let big = "x".repeat(MAX_BYTES + 1);
        refused(&big, "larger than 65536 bytes");
        // Exactly 64 KiB is allowed (padding inside the description would break its own limit,
        // so the padding is whitespace).
        let base = format!("{MIN}}}");
        let padded = format!("{base}{}", " ".repeat(MAX_BYTES - base.len()));
        assert_eq!(padded.len(), MAX_BYTES);
        ok(&padded);
    }

    #[test]
    fn hostile_text_is_refused_with_a_reason() {
        refused("{", "not JSON");
        refused("[]", "/: not an object");
        refused(&"[".repeat(5000), "not JSON");
        refused(&with(r#""settings":{"rumble_strength":1e999}"#), "not JSON");
        refused(
            &with(r#""description":"a\u0000b""#),
            "/description: contains a control",
        );
        refused(
            &serde_json::json!({
                "schema_version": 1, "id": "p", "scope": { "type": "global" },
                "name": format!("Evil{}gnp.exe", char::from_u32(0x202e).unwrap()),
            })
            .to_string(),
            "/name: contains a control or text-direction",
        );
        refused(&with(r#""script":"rm -rf /""#), "/: unknown field script");
        refused(
            r#"{"schema_version":1.0,"id":"p","name":"P","scope":{"type":"global"}}"#,
            "/schema_version: must be 1",
        );
        refused(
            &with(r#""inherits":"p""#),
            "/inherits: a profile cannot inherit from itself",
        );
        refused(&with(r#""inherits":"../etc""#), "/inherits");
    }

    #[test]
    fn service_rules_beyond_the_schema() {
        refused(
            &with(r#""mappings":[{"from":"south","to":{"type":"button","code":"jump"}}]"#),
            "/mappings/0/to/code: \"jump\" is not a button",
        );
        refused(
            &with(r#""mappings":[{"from":"south","to":{"type":"axis","code":"south"}}]"#),
            "/mappings/0/to/code: \"south\" is not a axis",
        );
        refused(
            &with(r#""mappings":[{"from":"south","to":{"type":"button"}}]"#),
            "/mappings/0/to: a button target needs a code",
        );
        refused(
            &with(r#""macros":[{"id":"m","steps":[{"type":"wait"}]}]"#),
            "/macros/0/steps/0: a wait step needs ms",
        );
        refused(
            &with(r#""macros":[{"id":"m","steps":[{"type":"tap"}]}]"#),
            "/macros/0/steps/0: a tap step needs a target",
        );
        refused(
            &with(
                r#""macros":[{"id":"m","steps":[{"type":"press","target":{"type":"macro","code":"m"}}]}]"#,
            ),
            "/macros/0/steps/0/target: a macro step never targets a macro",
        );
        let waits = [r#"{"type":"wait","ms":5000}"#; 2].join(",");
        ok(&with(&format!(
            r#""macros":[{{"id":"m","steps":[{waits}]}}]"#
        )));
        let waits = [r#"{"type":"wait","ms":5000}"#, r#"{"type":"wait","ms":10}"#].join(",");
        let long = format!(r#""macros":[{{"id":"m","steps":[{waits},{waits}]}}]"#);
        refused(
            &with(&long),
            "/macros/0/steps: the waits add up to 10020 ms",
        );
        refused(
            &with(r#""settings":{"left_stick":{"inner_deadzone":0.6,"outer_deadzone":0.4}}"#),
            "/settings/left_stick: inner_deadzone and outer_deadzone add up to 1 or more",
        );
        ok(&with(
            r#""settings":{"left_stick":{"inner_deadzone":0.6,"outer_deadzone":0.39}}"#,
        ));
    }

    #[test]
    fn errors_name_every_problem_with_its_path() {
        let errors = parse(
            r#"{"schema_version":2,"id":"Bad Id","name":"","scope":{"type":"game"},"output":{"type":"n64"}}"#,
        )
        .unwrap_err();
        for path in ["/schema_version", "/id", "/name", "/scope", "/output/type"] {
            assert!(
                errors.iter().any(|e| e.starts_with(&format!("{path}: "))),
                "{path} missing in {errors:?}"
            );
        }
    }

    #[test]
    fn the_patterns_match_the_schema() {
        assert!(valid_id("global-default"));
        assert!(valid_id(&"a".repeat(64)));
        assert!(!valid_id(&"a".repeat(65)));
        assert!(!valid_id("-x"));
        assert!(!valid_id("Upper"));
        assert!(!valid_id(""));
        assert!(valid_app_id("org.ruyaos.Racer"));
        assert!(!valid_app_id(".hidden"));
        assert!(valid_device("usb-045e-028e-0123456789ab"));
        assert!(!valid_device("USB"));
        assert!(valid_code("left_x"));
        assert!(!valid_code(&"a".repeat(33)));
    }
}
