//! The permission table of 05 §8 (RUY-851): for each value of the closed vocabulary, the lines of
//! Flatpak metadata it grants, its English words and its risk. The commit builds the generated
//! app's metadata from it, `ruya-play`'s Inspect and `ruya-pack inspect` take their words from it,
//! and [`crate::tier::assess`] its risks. A package never supplies a Flatpak key: what is not in
//! this table cannot be granted. `tests/permissions_spec_sync.rs` holds it to the spec's table.

use crate::tier::{Assessment, Request, Risk};

/// A section of the Flatpak metadata key file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Section {
    /// `[Context]`: `shared`, `sockets`, `devices`, `filesystems`, `features` (lists).
    Context,
    /// `[Session Bus Policy]`: one bus name per key.
    SessionBusPolicy,
}

impl Section {
    /// The section's name as the key file writes it between brackets.
    pub fn name(self) -> &'static str {
        match self {
            Section::Context => "Context",
            Section::SessionBusPolicy => "Session Bus Policy",
        }
    }
}

/// One line (or one list entry) of Flatpak metadata: `[section] key=value`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Grant {
    /// The section.
    pub section: Section,
    /// The key (`shared`, `devices`, a bus name, ...).
    pub key: &'static str,
    /// One value (`network`, `all`, `talk`, ...).
    pub value: &'static str,
}

impl Grant {
    /// `[Context] shared=network`, the form of the spec's table.
    pub fn text(&self) -> String {
        format!("[{}] {}={}", self.section.name(), self.key, self.value)
    }
}

const fn ctx(key: &'static str, value: &'static str) -> Grant {
    Grant {
        section: Section::Context,
        key,
        value,
    }
}

const fn bus(name: &'static str, policy: &'static str) -> Grant {
    Grant {
        section: Section::SessionBusPolicy,
        key: name,
        value: policy,
    }
}

/// One value of the vocabulary that asks for something.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Permission {
    /// The `permissions` key.
    pub key: &'static str,
    /// The value as the manifest writes it (`true` for bools).
    pub value: &'static str,
    /// Its risk.
    pub risk: Risk,
    /// The plain words, in English (the shell translates by key).
    pub words: &'static str,
    /// What it adds to the generated app's metadata (nothing for the input modes: every app gets
    /// `/dev/input` from `ruya-session`, and keyboards come through the compositor).
    pub grants: &'static [Grant],
}

const fn p(
    key: &'static str,
    value: &'static str,
    risk: Risk,
    words: &'static str,
    grants: &'static [Grant],
) -> Permission {
    Permission {
        key,
        value,
        risk,
        words,
        grants,
    }
}

/// The table of 05 §8, one row per value that asks for something. Values not listed
/// (`network: false`, `removable_media: none`, a `false` bool) ask for nothing.
pub const PERMISSIONS: [Permission; 10] = [
    p("input", "controllers", Risk::Low, "Uses controllers", &[]),
    p(
        "input",
        "controllers+keyboard-mouse",
        Risk::Low,
        "Uses controllers, keyboard and mouse",
        &[],
    ),
    p(
        "input",
        "all-devices",
        Risk::High,
        "Accesses all devices",
        &[ctx("devices", "all")],
    ),
    p(
        "network",
        "true",
        Risk::Medium,
        "Uses the network",
        &[ctx("shared", "network")],
    ),
    p(
        "removable_media",
        "read",
        Risk::Medium,
        "Reads files on USB drives",
        &[ctx("filesystems", "/run/media:ro")],
    ),
    p(
        "removable_media",
        "write",
        Risk::Medium,
        "Changes files on USB drives",
        &[ctx("filesystems", "/run/media")],
    ),
    p(
        "multiarch",
        "true",
        Risk::Medium,
        "Runs 32-bit programs",
        &[ctx("features", "multiarch")],
    ),
    p(
        "gamemode",
        "true",
        Risk::Low,
        "Asks the system to prioritise it",
        &[bus("com.feralinteractive.GameMode", "talk")],
    ),
    p(
        "realtime",
        "true",
        Risk::Low,
        "Asks the system to prioritise it",
        &[],
    ),
    p(
        "devel",
        "true",
        Risk::High,
        "Can inspect other programs",
        &[ctx("features", "devel")],
    ),
];

/// The row every app gets whatever it asks (not a request).
pub const ALWAYS_WORDS: &str = "Plays sound, uses graphics";

/// What every app gets besides its display socket ([`display_socket`]).
pub const ALWAYS: [Grant; 3] = [
    ctx("shared", "ipc"),
    ctx("sockets", "pulseaudio"),
    ctx("devices", "dri"),
];

/// The display socket of a runner: Windows programs
/// (`ruya_play_format::limits::windows_runner`) run on X11 (05 §6.3), the rest on Wayland.
pub fn display_socket(runner: &str) -> Grant {
    if ruya_play_format::limits::windows_runner(runner) {
        ctx("sockets", "x11")
    } else {
        ctx("sockets", "wayland")
    }
}

/// Two requests that count as high risk together though each alone is medium (05 §18 item 13):
/// a way out for the player's files. Named `<a>+<b>` in an [`Assessment`]; they grant nothing
/// beyond what each grants.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HighRiskPair {
    /// The first key.
    pub a: &'static str,
    /// The second key.
    pub b: &'static str,
    /// The plain words of the pair.
    pub words: &'static str,
}

/// The pairs of 05 §8.
pub const HIGH_RISK_PAIRS: [HighRiskPair; 1] = [HighRiskPair {
    a: "network",
    b: "removable_media",
    words: "Uses the network and reaches USB drives",
}];

/// The words for a request the table has no row for (it counts as high risk and grants nothing).
pub const UNKNOWN_WORDS: &str = "Asks for a permission";

/// The row of `key` = `value`.
pub fn permission(key: &str, value: &str) -> Option<&'static Permission> {
    PERMISSIONS
        .iter()
        .find(|r| r.key == key && r.value == value)
}

/// The plain words of a request: its row's, a pair's, else [`UNKNOWN_WORDS`].
pub fn words(key: &str, value: &str) -> &'static str {
    if let Some(r) = permission(key, value) {
        return r.words;
    }
    HIGH_RISK_PAIRS
        .iter()
        .find(|pair| value.is_empty() && key == format!("{}+{}", pair.a, pair.b))
        .map_or(UNKNOWN_WORDS, |pair| pair.words)
}

/// Everything the generated app is granted: [`ALWAYS`] with the runner's display socket, then the
/// grants of each request of `assessment` that has a row, in its order, each line once. A request
/// without a row (and a pair) grants nothing.
pub fn grants(runner: &str, assessment: &Assessment) -> Vec<Grant> {
    let mut out: Vec<Grant> = Vec::new();
    let mut add = |g: Grant| {
        if !out.contains(&g) {
            out.push(g);
        }
    };
    add(ALWAYS[0]);
    add(display_socket(runner));
    for g in &ALWAYS[1..] {
        add(*g);
    }
    for r in &assessment.requests {
        if let Some(row) = permission(&r.key, &r.value) {
            for g in row.grants {
                add(*g);
            }
        }
    }
    out
}

/// The order of the `[Context]` keys in the generated metadata.
const CONTEXT_KEYS: [&str; 5] = ["shared", "sockets", "devices", "filesystems", "features"];

/// The permission sections of a Flatpak metadata file for `grants`: `[Context]` with each list
/// key once (`shared=ipc;network;`), then `[Session Bus Policy]` when a bus name is granted.
/// Every section ends with an empty line.
pub fn metadata_sections(grants: &[Grant]) -> String {
    let mut out = String::from("[Context]\n");
    for key in CONTEXT_KEYS {
        let values: Vec<&str> = grants
            .iter()
            .filter(|g| g.section == Section::Context && g.key == key)
            .map(|g| g.value)
            .collect();
        if !values.is_empty() {
            out.push_str(&format!("{key}={};\n", values.join(";")));
        }
    }
    out.push('\n');
    let names: Vec<&Grant> = grants
        .iter()
        .filter(|g| g.section == Section::SessionBusPolicy)
        .collect();
    if !names.is_empty() {
        out.push_str("[Session Bus Policy]\n");
        for g in names {
            out.push_str(&format!("{}={}\n", g.key, g.value));
        }
        out.push('\n');
    }
    out
}

/// What an update changes in the requests (05 §8: "The update adds: ..."; a high-risk addition
/// needs the admin's PIN).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PermissionDiff {
    /// Requests of the new build the installed one did not make, in the new build's order.
    pub added: Vec<Request>,
    /// Requests of the installed build the new one drops, in the installed build's order.
    pub removed: Vec<Request>,
    /// The high-risk ones of `added` (a pair counts).
    pub high_risk_added: Vec<Request>,
}

/// The requests `new` adds to and drops from `installed`, compared by key and value (a changed
/// `input` mode is one added and one removed).
pub fn diff(installed: &Assessment, new: &Assessment) -> PermissionDiff {
    let has = |a: &Assessment, r: &Request| {
        a.requests
            .iter()
            .any(|x| x.key == r.key && x.value == r.value)
    };
    let added: Vec<Request> = new
        .requests
        .iter()
        .filter(|r| !has(installed, r))
        .cloned()
        .collect();
    let removed = installed
        .requests
        .iter()
        .filter(|r| !has(new, r))
        .cloned()
        .collect();
    let high_risk_added = added
        .iter()
        .filter(|r| r.risk == Risk::High)
        .cloned()
        .collect();
    PermissionDiff {
        added,
        removed,
        high_risk_added,
    }
}
