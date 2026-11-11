//! Parking a frozen game's sound (T-466). A game the Ruya Hub froze (Session1 `Freeze`) stops
//! feeding its PulseAudio stream, but the stream stays linked to the sound card, so PipeWire keeps
//! the card running on silence (on the Dell about 1.4 % of a core and +0.15 W at idle). Parking
//! moves such a stream to a null sink of its own (`PARKED_SINK`), so the card has nothing to play
//! and WirePlumber suspends it; the thaw moves it back to where it was.
//!
//! `ruya-session` decides when (it knows what is frozen) and runs `ruya-devices --park-audio` in
//! `ruya-shell`'s manager, the only place that reaches the console's PipeWire (ADR-010). Every run
//! is a full reconcile of one profile's streams from a `pw-dump`, so a late or repeated run is
//! harmless and nothing is remembered between runs: a parked stream carries its old target in the
//! `default` metadata under `PARKED_KEY`.
//!
//! Which streams are a profile's: the ones whose PipeWire client is that profile's own pulse server
//! (`ruya-pulse@<user>.service`, T-365), told by the client's `pipewire.sec.pid` (set by PipeWire
//! from the socket, not by the client). Which app a stream is: the client's
//! `pipewire.access.portal.app_id` when the server could read it; otherwise (today's case: the
//! server, running as `ruya-shell`, cannot look into another user's sandbox) the stream is parked
//! only while every running app of the profile is frozen, so a game that plays is never silenced.
//! Pure here; `apply` (Linux) runs the tools.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

/// The null sink parked streams play into. Created when the first stream is parked, destroyed
/// when none is left; never offered as an output (`pipewire::parse_dump` skips it).
pub const PARKED_SINK: &str = "ruya-parked";
/// The `default` metadata key on a parked stream: where it was (`{"target":..,"type":..}`).
pub const PARKED_KEY: &str = "ruya.parked";
/// The key WirePlumber links a stream by (a node name or serial).
pub const TARGET_KEY: &str = "target.object";

/// What `ruya-session` asks for one profile user: its frozen apps and all its running ones.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub user: String,
    pub frozen: Vec<String>,
    pub running: Vec<String>,
}

/// A `default` metadata entry: its value and its type ("" when it had none).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub value: String,
    pub kind: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Step {
    /// Creates `PARKED_SINK` (before the first park).
    CreateSink,
    /// Saves the stream's current target (`None`: it had none) and points it at `PARKED_SINK`.
    Park { node: u64, saved: Option<Target> },
    /// Puts the saved target back (`None`: removes the target, the stream follows the default).
    Restore { node: u64, saved: Option<Target> },
    /// Destroys `PARKED_SINK` (no stream is parked any more).
    DropSink { id: u64 },
}

fn valid_user(user: &str) -> bool {
    user.strip_prefix("ruya-").is_some_and(|id| {
        !id.is_empty()
            && id.len() <= 32
            && id
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    })
}

fn valid_app(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 120
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// The list of `--frozen=a,b` (an empty value is an empty list).
fn list(arg: &str, name: &str) -> Result<Vec<String>, String> {
    let value = arg
        .strip_prefix(name)
        .ok_or_else(|| format!("expected {name}<ids>, got {arg:?}"))?;
    let ids: Vec<String> = value
        .split(',')
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect();
    match ids.iter().find(|id| !valid_app(id)) {
        Some(bad) => Err(format!("not an application id: {bad:?}")),
        None => Ok(ids),
    }
}

/// The arguments after `--park-audio`: `<user> --frozen=<ids> --running=<ids>` (comma lists).
pub fn parse_args(args: &[String]) -> Result<Request, String> {
    let [user, frozen, running] = args else {
        return Err("usage: --park-audio ruya-<id> --frozen=<ids> --running=<ids>".to_owned());
    };
    if !valid_user(user) {
        return Err(format!("not a profile user: {user:?}"));
    }
    Ok(Request {
        user: user.clone(),
        frozen: list(frozen, "--frozen=")?,
        running: list(running, "--running=")?,
    })
}

/// A number that pw-dump writes either as a number or as a string.
fn number(v: &Value) -> Option<u64> {
    v.as_u64()
        .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
}

/// A metadata value as text (pw-dump writes JSON-typed values as JSON, the others as strings).
fn text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// The target saved under `PARKED_KEY` (`None` when the stream had none).
fn saved_target(v: &Value) -> Option<Target> {
    let parsed;
    let obj = match v {
        Value::String(s) => {
            parsed = serde_json::from_str::<Value>(s).ok()?;
            &parsed
        }
        other => other,
    };
    let value = obj.get("target")?.as_str()?;
    Some(Target {
        value: value.to_owned(),
        kind: obj
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned(),
    })
}

/// The value written under `PARKED_KEY` for `saved`.
pub fn saved_json(saved: &Option<Target>) -> String {
    match saved {
        Some(t) => serde_json::json!({ "target": t.value, "type": t.kind }).to_string(),
        None => serde_json::json!({ "target": null }).to_string(),
    }
}

struct Graph {
    /// Output streams: node id -> client id.
    streams: BTreeMap<u64, Option<u64>>,
    /// Client id -> (`pipewire.sec.pid`, `pipewire.access.portal.app_id`).
    clients: BTreeMap<u64, (Option<u64>, Option<String>)>,
    /// Subject -> key -> entry of the `default` metadata.
    meta: BTreeMap<u64, BTreeMap<String, (Value, String)>>,
    sink: Option<u64>,
}

fn graph(json: &str) -> Result<Graph, String> {
    let doc: Value = serde_json::from_str(json).map_err(|e| format!("pw-dump: {e}"))?;
    let objects = doc.as_array().ok_or("pw-dump: not an array")?;
    let mut g = Graph {
        streams: BTreeMap::new(),
        clients: BTreeMap::new(),
        meta: BTreeMap::new(),
        sink: None,
    };
    for obj in objects {
        let Some(id) = number(&obj["id"]) else {
            continue;
        };
        let props = &obj["info"]["props"];
        match obj["type"].as_str() {
            Some("PipeWire:Interface:Node") => match props["media.class"].as_str() {
                Some("Stream/Output/Audio") => {
                    g.streams.insert(id, number(&props["client.id"]));
                }
                Some("Audio/Sink") if props["node.name"].as_str() == Some(PARKED_SINK) => {
                    g.sink = Some(id);
                }
                _ => {}
            },
            Some("PipeWire:Interface:Client") => {
                let app = props["pipewire.access.portal.app_id"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .map(str::to_owned);
                g.clients
                    .insert(id, (number(&props["pipewire.sec.pid"]), app));
            }
            Some("PipeWire:Interface:Metadata")
                if obj["props"]["metadata.name"].as_str() == Some("default") =>
            {
                for e in obj["metadata"].as_array().into_iter().flatten() {
                    let (Some(subject), Some(key)) = (number(&e["subject"]), e["key"].as_str())
                    else {
                        continue;
                    };
                    let kind = e["type"].as_str().unwrap_or("").to_owned();
                    g.meta
                        .entry(subject)
                        .or_default()
                        .insert(key.to_owned(), (e["value"].clone(), kind));
                }
            }
            _ => {}
        }
    }
    Ok(g)
}

/// What to do so that `req.user`'s streams are parked exactly when they should be. `pulse_pid` is
/// the main process of `ruya-pulse@<user>.service` (0: not running, so the user has no stream).
/// Order: the sink is created before the first park and dropped after the last restore.
pub fn plan(json: &str, pulse_pid: u64, req: &Request) -> Result<Vec<Step>, String> {
    let g = graph(json)?;
    let running: BTreeSet<&str> = req.running.iter().map(String::as_str).collect();
    let frozen: BTreeSet<&str> = req.frozen.iter().map(String::as_str).collect();
    // A stream that names no running app is parked only when nothing of the profile plays.
    let all_frozen = !running.is_empty() && running.iter().all(|a| frozen.contains(a));
    let parked = |node: &u64| g.meta.get(node).and_then(|m| m.get(PARKED_KEY));

    let mut steps = Vec::new();
    let mut parked_after = g.streams.keys().filter(|n| parked(n).is_some()).count();
    for (node, client) in &g.streams {
        let Some((pid, app)) = client.and_then(|c| g.clients.get(&c)) else {
            continue;
        };
        if pulse_pid == 0 || *pid != Some(pulse_pid) {
            continue;
        }
        let should = match app.as_deref() {
            Some(a) if running.contains(a) => frozen.contains(a),
            _ => all_frozen,
        };
        match (should, parked(node)) {
            (true, None) => {
                let saved = g
                    .meta
                    .get(node)
                    .and_then(|m| m.get(TARGET_KEY))
                    .map(|(v, kind)| Target {
                        value: text(v),
                        kind: kind.clone(),
                    })
                    .filter(|t| !t.value.is_empty() && t.value != PARKED_SINK);
                steps.push(Step::Park { node: *node, saved });
                parked_after += 1;
            }
            (false, Some((value, _))) => {
                steps.push(Step::Restore {
                    node: *node,
                    saved: saved_target(value),
                });
                parked_after -= 1;
            }
            _ => {}
        }
    }
    let parks = steps.iter().any(|s| matches!(s, Step::Park { .. }));
    if parks && g.sink.is_none() {
        steps.insert(0, Step::CreateSink);
    }
    if let (0, Some(id)) = (parked_after, g.sink) {
        steps.push(Step::DropSink { id });
    }
    Ok(steps)
}

fn owned(args: &[&str]) -> Vec<String> {
    args.iter().map(|s| (*s).to_owned()).collect()
}

/// The `pw-cli` and `pw-metadata` argument lists for `steps`, in order. A park saves the old
/// target before it moves the stream, so a run cut short leaves a stream that a later run can
/// still put back.
pub fn commands(steps: &[Step]) -> Vec<Vec<String>> {
    // `--` ends the options: a value that starts with `-` is never read as one.
    let meta = |rest: &[&str]| {
        let mut args = owned(&["pw-metadata", "-n", "default", "--"]);
        args.extend(rest.iter().map(|s| (*s).to_owned()));
        args
    };
    let delete = |rest: &[&str]| {
        let mut args = owned(&["pw-metadata", "-n", "default", "-d", "--"]);
        args.extend(rest.iter().map(|s| (*s).to_owned()));
        args
    };
    let mut out = Vec::new();
    for step in steps {
        match step {
            Step::CreateSink => out.push(owned(&[
                "pw-cli",
                "create-node",
                "adapter",
                &format!(
                    "{{ factory.name = support.null-audio-sink node.name = {PARKED_SINK} \
                     node.description = \"Paused game sound\" media.class = Audio/Sink \
                     audio.position = [ FL FR ] object.linger = true node.virtual = true \
                     priority.session = 0 priority.driver = 0 }}"
                ),
            ])),
            Step::Park { node, saved } => {
                let node = node.to_string();
                out.push(meta(&[
                    &node,
                    PARKED_KEY,
                    &saved_json(saved),
                    "Spa:String:JSON",
                ]));
                out.push(meta(&[&node, TARGET_KEY, PARKED_SINK, "Spa:String"]));
            }
            Step::Restore { node, saved } => {
                let node = node.to_string();
                match saved {
                    Some(t) if t.kind.is_empty() => {
                        out.push(meta(&[&node, TARGET_KEY, &t.value]));
                    }
                    Some(t) => out.push(meta(&[&node, TARGET_KEY, &t.value, &t.kind])),
                    None => out.push(delete(&[&node, TARGET_KEY])),
                }
                out.push(delete(&[&node, PARKED_KEY]));
            }
            Step::DropSink { id } => out.push(owned(&["pw-cli", "destroy", &id.to_string()])),
        }
    }
    out
}

/// One line for the journal: how many streams were parked and put back.
pub fn summary(user: &str, steps: &[Step]) -> String {
    let parked = steps
        .iter()
        .filter(|s| matches!(s, Step::Park { .. }))
        .count();
    let restored = steps
        .iter()
        .filter(|s| matches!(s, Step::Restore { .. }))
        .count();
    format!("ruya-devices: park-audio {user}: parked {parked}, restored {restored}")
}

/// Runs one reconcile (Linux): the pulse server's pid from `ruya-shell`'s own manager, `pw-dump`,
/// then every command of the plan. A failed command is reported, the rest still run, and the run
/// is an error, so the caller tries again (a stream left half-parked is put back by the next run).
#[cfg(target_os = "linux")]
pub fn apply(req: &Request) -> Result<String, String> {
    use std::process::{Command, Stdio};
    let run = |args: &[String]| -> Result<String, String> {
        let out = Command::new(&args[0])
            .args(&args[1..])
            .stdin(Stdio::null())
            .output()
            .map_err(|e| format!("{}: {e}", args[0]))?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            Err(format!(
                "{} failed: {}",
                args.join(" "),
                String::from_utf8_lossy(&out.stderr).trim()
            ))
        }
    };
    let unit = format!("ruya-pulse@{}.service", req.user);
    let pid = run(&owned(&[
        "systemctl",
        "--user",
        "show",
        "-p",
        "MainPID",
        "--value",
        &unit,
    ]))
    .ok()
    .and_then(|s| s.trim().parse::<u64>().ok())
    .unwrap_or(0);
    let dump = run(&owned(&["pw-dump"]))?;
    let steps = plan(&dump, pid, req)?;
    let mut failed = 0;
    for args in commands(&steps) {
        if let Err(err) = run(&args) {
            eprintln!("ruya-devices: park-audio: {err}");
            failed += 1;
        }
    }
    // A failed step fails the run (exit 1), so ruya-session tries again: a stream left on the null
    // sink after a thaw would play unheard until the next Freeze.
    if failed > 0 {
        return Err(format!(
            "{failed} step(s) failed ({})",
            summary(&req.user, &steps)
        ));
    }
    Ok(summary(&req.user, &steps))
}

#[cfg(test)]
mod tests {
    use super::*;

    const PULSE: u64 = 900;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| (*x).to_owned()).collect()
    }

    fn req(frozen: &[&str], running: &[&str]) -> Request {
        Request {
            user: "ruya-p1".to_owned(),
            frozen: s(frozen),
            running: s(running),
        }
    }

    fn client(id: u64, pid: u64, app: Option<&str>) -> String {
        let app = app
            .map(|a| format!(r#","pipewire.access.portal.app_id":"{a}""#))
            .unwrap_or_default();
        format!(
            r#"{{"id":{id},"type":"PipeWire:Interface:Client","info":{{"props":{{"pipewire.sec.pid":{pid}{app}}}}}}}"#
        )
    }

    fn stream(id: u64, client: u64) -> String {
        format!(
            r#"{{"id":{id},"type":"PipeWire:Interface:Node","info":{{"state":"running","props":{{"media.class":"Stream/Output/Audio","client.id":{client}}}}}}}"#
        )
    }

    fn sink(id: u64, name: &str) -> String {
        format!(
            r#"{{"id":{id},"type":"PipeWire:Interface:Node","info":{{"props":{{"media.class":"Audio/Sink","node.name":"{name}"}}}}}}"#
        )
    }

    fn meta(entries: &[String]) -> String {
        format!(
            r#"{{"id":30,"type":"PipeWire:Interface:Metadata","props":{{"metadata.name":"default"}},"metadata":[{}]}}"#,
            entries.join(",")
        )
    }

    fn entry(subject: u64, key: &str, kind: &str, value: &str) -> String {
        format!(r#"{{"subject":{subject},"key":"{key}","type":"{kind}","value":{value}}}"#)
    }

    fn dump(parts: &[String]) -> String {
        format!("[{}]", parts.join(","))
    }

    /// The card (40), p1's pulse server with one stream (60, client 50), the shell's own stream
    /// (61, client 51, another pid) and another profile's (62, client 52).
    fn base(extra: &[String]) -> Vec<String> {
        let mut v = vec![
            sink(40, "alsa_output.pci-0000_00_1f.3.analog-stereo"),
            client(50, PULSE, None),
            client(51, 111, None),
            client(52, 222, None),
            stream(60, 50),
            stream(61, 51),
            stream(62, 52),
        ];
        v.extend_from_slice(extra);
        v
    }

    #[test]
    fn a_profile_whose_only_game_is_frozen_has_its_stream_parked_and_nothing_else() {
        let steps = plan(
            &dump(&base(&[])),
            PULSE,
            &req(&["org.x.Game"], &["org.x.Game"]),
        )
        .unwrap();
        // Only p1's stream; the sink is made first.
        assert_eq!(
            steps,
            vec![
                Step::CreateSink,
                Step::Park {
                    node: 60,
                    saved: None
                }
            ]
        );
        let cmds = commands(&steps);
        assert_eq!(cmds[0][..3], s(&["pw-cli", "create-node", "adapter"]));
        assert!(cmds[0][3].contains("node.name = ruya-parked"));
        assert!(cmds[0][3].contains("object.linger = true"));
        // The old target is saved before the stream is moved.
        assert_eq!(
            cmds[1],
            s(&[
                "pw-metadata",
                "-n",
                "default",
                "--",
                "60",
                "ruya.parked",
                r#"{"target":null}"#,
                "Spa:String:JSON"
            ])
        );
        assert_eq!(
            cmds[2],
            s(&[
                "pw-metadata",
                "-n",
                "default",
                "--",
                "60",
                "target.object",
                "ruya-parked",
                "Spa:String"
            ])
        );
    }

    #[test]
    fn a_stream_moved_by_the_player_keeps_its_target_through_the_park() {
        let parts = base(&[meta(&[entry(
            60,
            "target.object",
            "Spa:Id",
            r#""alsa_output.usb""#,
        )])]);
        let steps = plan(&dump(&parts), PULSE, &req(&["org.x.Game"], &["org.x.Game"])).unwrap();
        let saved = Some(Target {
            value: "alsa_output.usb".to_owned(),
            kind: "Spa:Id".to_owned(),
        });
        assert_eq!(
            steps[1],
            Step::Park {
                node: 60,
                saved: saved.clone()
            }
        );
        assert_eq!(
            commands(&steps)[1][6],
            r#"{"target":"alsa_output.usb","type":"Spa:Id"}"#
        );
        // The thaw: pw-dump shows the JSON value as JSON; the target goes back with its type, then
        // the key goes, then the sink (no stream is parked any more).
        let parked = base(&[
            sink(70, PARKED_SINK),
            meta(&[
                entry(60, "target.object", "Spa:String", r#""ruya-parked""#),
                entry(
                    60,
                    "ruya.parked",
                    "Spa:String:JSON",
                    r#"{"target":"alsa_output.usb","type":"Spa:Id"}"#,
                ),
            ]),
        ]);
        let steps = plan(&dump(&parked), PULSE, &req(&[], &["org.x.Game"])).unwrap();
        assert_eq!(
            steps,
            vec![Step::Restore { node: 60, saved }, Step::DropSink { id: 70 }]
        );
        let cmds = commands(&steps);
        assert_eq!(
            cmds,
            vec![
                s(&[
                    "pw-metadata",
                    "-n",
                    "default",
                    "--",
                    "60",
                    "target.object",
                    "alsa_output.usb",
                    "Spa:Id"
                ]),
                s(&[
                    "pw-metadata",
                    "-n",
                    "default",
                    "-d",
                    "--",
                    "60",
                    "ruya.parked"
                ]),
                s(&["pw-cli", "destroy", "70"]),
            ]
        );
    }

    #[test]
    fn a_stream_with_no_target_before_follows_the_default_again() {
        // The saved value as a JSON string too (an older pw-dump writes it so).
        let parked = base(&[
            sink(70, PARKED_SINK),
            meta(&[
                entry(60, "target.object", "Spa:String", r#""ruya-parked""#),
                entry(
                    60,
                    "ruya.parked",
                    "Spa:String:JSON",
                    r#""{\"target\":null}""#,
                ),
            ]),
        ]);
        let steps = plan(&dump(&parked), PULSE, &req(&[], &["org.x.Game"])).unwrap();
        assert_eq!(
            commands(&steps)[..2],
            [
                s(&[
                    "pw-metadata",
                    "-n",
                    "default",
                    "-d",
                    "--",
                    "60",
                    "target.object"
                ]),
                s(&[
                    "pw-metadata",
                    "-n",
                    "default",
                    "-d",
                    "--",
                    "60",
                    "ruya.parked"
                ]),
            ]
        );
    }

    #[test]
    fn a_game_that_plays_is_never_silenced_by_a_frozen_one_of_the_same_profile() {
        // Two games of p1, one frozen: the stream names no app, so it is left alone.
        let steps = plan(
            &dump(&base(&[])),
            PULSE,
            &req(&["org.x.Game"], &["org.x.Game", "org.x.Other"]),
        )
        .unwrap();
        assert!(steps.is_empty(), "{steps:?}");
        // With the app ids known, the frozen game's stream is parked and the other's is not.
        let parts = vec![
            client(50, PULSE, Some("org.x.Game")),
            client(53, PULSE, Some("org.x.Other")),
            stream(60, 50),
            stream(63, 53),
        ];
        let steps = plan(
            &dump(&parts),
            PULSE,
            &req(&["org.x.Game"], &["org.x.Game", "org.x.Other"]),
        )
        .unwrap();
        assert_eq!(
            steps,
            vec![
                Step::CreateSink,
                Step::Park {
                    node: 60,
                    saved: None
                }
            ]
        );
    }

    #[test]
    fn nothing_is_parked_without_a_frozen_app_or_a_pulse_server() {
        for r in [req(&[], &["org.x.Game"]), req(&[], &[])] {
            assert!(plan(&dump(&base(&[])), PULSE, &r).unwrap().is_empty());
        }
        // No server pid (not running): no stream is the profile's.
        assert!(
            plan(&dump(&base(&[])), 0, &req(&["org.x.Game"], &["org.x.Game"]))
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn a_reconcile_is_idempotent_and_the_sink_lives_while_any_stream_is_parked() {
        // p1's stream is parked already, p2's too: the run for p1 does nothing.
        let parked = base(&[
            sink(70, PARKED_SINK),
            meta(&[
                entry(60, "ruya.parked", "Spa:String:JSON", r#"{"target":null}"#),
                entry(62, "ruya.parked", "Spa:String:JSON", r#"{"target":null}"#),
            ]),
        ]);
        let frozen = req(&["org.x.Game"], &["org.x.Game"]);
        assert!(plan(&dump(&parked), PULSE, &frozen).unwrap().is_empty());
        // p1's game thaws: its stream goes back, the sink stays for p2's.
        let steps = plan(&dump(&parked), PULSE, &req(&[], &["org.x.Game"])).unwrap();
        assert_eq!(
            steps,
            vec![Step::Restore {
                node: 60,
                saved: None
            }]
        );
        // A sink left over with nothing parked (a run cut short) is dropped.
        let stale = base(&[sink(70, PARKED_SINK)]);
        assert_eq!(
            plan(&dump(&stale), PULSE, &req(&[], &[])).unwrap(),
            vec![Step::DropSink { id: 70 }]
        );
        // A metadata entry of a stream that is gone does not keep the sink alive.
        let gone = base(&[
            sink(70, PARKED_SINK),
            meta(&[entry(99, "ruya.parked", "Spa:String:JSON", "{}")]),
        ]);
        assert_eq!(
            plan(&dump(&gone), PULSE, &req(&[], &[])).unwrap(),
            vec![Step::DropSink { id: 70 }]
        );
    }

    #[test]
    fn an_app_that_moved_itself_onto_the_parked_sink_is_neither_restored_nor_left_silent() {
        // The app set `target.object` to ruya-parked itself (no `ruya.parked` of ours).
        let own = |extra: &[String]| {
            let mut v = base(&[
                sink(70, PARKED_SINK),
                meta(&[entry(60, "target.object", "Spa:String", r#""ruya-parked""#)]),
            ]);
            v.extend_from_slice(extra);
            v
        };
        // Not frozen: nothing is "put back" (it was never parked by us), and the sink, holding no
        // stream of ours, goes, so the stream falls back to the default output.
        let steps = plan(&dump(&own(&[])), PULSE, &req(&[], &["org.x.Game"])).unwrap();
        assert_eq!(steps, vec![Step::DropSink { id: 70 }]);
        // Frozen: parked with no saved target (never "ruya-parked"), so the thaw removes the target
        // and the stream follows the default instead of staying on the null sink.
        let steps = plan(
            &dump(&own(&[])),
            PULSE,
            &req(&["org.x.Game"], &["org.x.Game"]),
        )
        .unwrap();
        assert_eq!(
            steps,
            vec![Step::Park {
                node: 60,
                saved: None
            }]
        );
        let parked = base(&[
            sink(70, PARKED_SINK),
            meta(&[
                entry(60, "target.object", "Spa:String", r#""ruya-parked""#),
                entry(60, "ruya.parked", "Spa:String:JSON", r#"{"target":null}"#),
            ]),
        ]);
        let cmds = commands(&plan(&dump(&parked), PULSE, &req(&[], &["org.x.Game"])).unwrap());
        assert_eq!(
            cmds[0],
            s(&[
                "pw-metadata",
                "-n",
                "default",
                "-d",
                "--",
                "60",
                "target.object"
            ])
        );
    }

    #[test]
    fn the_arguments_are_checked() {
        let ok = parse_args(&s(&[
            "ruya-p1",
            "--frozen=org.x.Game",
            "--running=org.x.Game,org.y.B",
        ]))
        .unwrap();
        assert_eq!(ok.frozen, s(&["org.x.Game"]));
        assert_eq!(ok.running, s(&["org.x.Game", "org.y.B"]));
        let empty = parse_args(&s(&["ruya-p1", "--frozen=", "--running="])).unwrap();
        assert!(empty.frozen.is_empty() && empty.running.is_empty());
        for bad in [
            s(&["root", "--frozen=", "--running="]),
            s(&["ruya-", "--frozen=", "--running="]),
            s(&["ruya-p1", "--frozen=a;b", "--running="]),
            s(&["ruya-p1", "--running=", "--frozen="]),
            s(&["ruya-p1", "--frozen="]),
        ] {
            assert!(parse_args(&bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn the_summary_counts_parks_and_restores() {
        let steps = [
            Step::CreateSink,
            Step::Park {
                node: 1,
                saved: None,
            },
            Step::Restore {
                node: 2,
                saved: None,
            },
        ];
        assert_eq!(
            summary("ruya-p1", &steps),
            "ruya-devices: park-audio ruya-p1: parked 1, restored 1"
        );
    }
}
