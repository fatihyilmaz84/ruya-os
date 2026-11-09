//! PipeWire through its command line tools: `pw-dump` (JSON) to read the outputs and the
//! default, `wpctl` to change them. Parsing is pure and tested here; running the tools is
//! Linux-only. Chosen over a PipeWire binding crate: no C library to build against, and one
//! poll per second is enough for a living-room console.

use serde_json::Value;

use crate::audio::{Kind, Sink};
use crate::output_policy::{Avail, OutKind, Output};

/// The outputs and the default node name from a `pw-dump` document. `node.name` is the id (it
/// survives reboots), `node.description` the display name.
pub fn parse_dump(json: &str) -> Result<(Vec<Sink>, Option<String>), String> {
    let doc: Value = serde_json::from_str(json).map_err(|e| format!("pw-dump: {e}"))?;
    let objects = doc.as_array().ok_or("pw-dump: not an array")?;

    let mut sinks = Vec::new();
    let mut default = None;
    let mut configured = None;
    for obj in objects {
        match obj.get("type").and_then(Value::as_str) {
            Some("PipeWire:Interface:Node") => {
                let props = &obj["info"]["props"];
                if props["media.class"].as_str() != Some("Audio/Sink") {
                    continue;
                }
                let Some(id) = props["node.name"].as_str() else {
                    continue;
                };
                let name = props["node.description"]
                    .as_str()
                    .or_else(|| props["node.nick"].as_str())
                    .unwrap_or(id);
                sinks.push(Sink {
                    id: id.to_owned(),
                    name: name.to_owned(),
                    kind: classify(props),
                });
            }
            Some("PipeWire:Interface:Metadata") => {
                if obj["props"]["metadata.name"].as_str() != Some("default") {
                    continue;
                }
                for entry in obj["metadata"].as_array().into_iter().flatten() {
                    let name = entry["value"]["name"].as_str().map(str::to_owned);
                    match entry["key"].as_str() {
                        Some("default.audio.sink") => default = name,
                        Some("default.configured.audio.sink") => configured = name,
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    Ok((sinks, default.or(configured)))
}

/// Every output of the sound cards (T-322). PipeWire shows only the sinks of a card's active
/// profile, but each Device object lists all its routes (`EnumRoute`); an output with a route
/// that is in use (`Route`) is matched to its sink by `device.id` and `card.profile.device`.
/// A sink that belongs to no listed route (a device without routes) becomes an output of its own.
pub fn parse_outputs(json: &str, sinks: &[Sink]) -> Vec<Output> {
    let Ok(doc) = serde_json::from_str::<Value>(json) else {
        return Vec::new();
    };
    let objects: Vec<&Value> = doc.as_array().into_iter().flatten().collect();
    let is = |o: &Value, ty: &str| o.get("type").and_then(Value::as_str) == Some(ty);
    let node_of = |device_id: u64, route_device: u64| -> Option<String> {
        objects
            .iter()
            .filter(|o| is(o, "PipeWire:Interface:Node"))
            .map(|o| &o["info"]["props"])
            .find(|p| {
                p["media.class"].as_str() == Some("Audio/Sink")
                    && p["device.id"].as_u64() == Some(device_id)
                    && p["card.profile.device"].as_u64() == Some(route_device)
            })
            .and_then(|p| p["node.name"].as_str())
            .filter(|n| sinks.iter().any(|s| s.id == *n))
            .map(str::to_owned)
    };

    let mut outputs: Vec<Output> = Vec::new();
    for dev in objects
        .iter()
        .filter(|o| is(o, "PipeWire:Interface:Device"))
    {
        let props = &dev["info"]["props"];
        let (Some(card), Some(device_id)) = (props["device.name"].as_str(), dev["id"].as_u64())
        else {
            continue;
        };
        let bus = props["device.bus"].as_str().unwrap_or("");
        let api = props["device.api"].as_str().unwrap_or("");
        let params = &dev["info"]["params"];
        let in_use: Vec<&Value> = params["Route"].as_array().into_iter().flatten().collect();
        for route in params["EnumRoute"].as_array().into_iter().flatten() {
            if !route["direction"]
                .as_str()
                .is_some_and(|d| d.eq_ignore_ascii_case("output"))
            {
                continue;
            }
            let Some(port) = route["name"].as_str() else {
                continue;
            };
            let node = in_use
                .iter()
                .find(|r| r["name"].as_str() == Some(port))
                .and_then(|r| r["device"].as_u64())
                .and_then(|d| node_of(device_id, d));
            outputs.push(Output {
                id: format!("{card}:{port}"),
                name: route["description"].as_str().unwrap_or(port).to_owned(),
                kind: route_kind(port, bus, api),
                card: card.to_owned(),
                port: port.to_owned(),
                available: match route["available"].as_str() {
                    Some("yes") => Avail::Yes,
                    Some("no") => Avail::No,
                    _ => Avail::Unknown,
                },
                node,
            });
        }
    }
    for sink in sinks {
        if outputs.iter().any(|o| o.node.as_deref() == Some(&sink.id)) {
            continue;
        }
        let (kind, available) = match sink.kind {
            Kind::Hdmi => (OutKind::Hdmi, Avail::Unknown),
            Kind::Analog => (OutKind::Speaker, Avail::Unknown),
            Kind::Usb => (OutKind::Usb, Avail::Yes),
            Kind::Bluetooth => (OutKind::Bluetooth, Avail::Yes),
        };
        outputs.push(Output {
            id: sink.id.clone(),
            name: sink.name.clone(),
            kind,
            card: String::new(),
            port: String::new(),
            available,
            node: Some(sink.id.clone()),
        });
    }
    outputs
}

/// The kind of a route from its name and its card's bus and API.
fn route_kind(port: &str, bus: &str, api: &str) -> OutKind {
    let port = port.to_ascii_lowercase();
    if api == "bluez5" {
        OutKind::Bluetooth
    } else if bus == "usb" {
        OutKind::Usb
    } else if port.contains("hdmi") || port.contains("displayport") {
        OutKind::Hdmi
    } else if port.contains("headphone") || port.contains("headset") {
        OutKind::Headphones
    } else {
        OutKind::Speaker
    }
}

/// Whether something plays: an output stream (`Stream/Output/Audio`) is running (PipeWire's
/// `info.state`) and not corked. A paused or corked stream is "idle"/"paused" in the graph (or
/// carries `pulse.corked`), and the sink it feeds can stay "running" for a while after it
/// (T-293), so the sink's own state is not used: a player that paused must not keep the console
/// awake. A running microphone or monitor stream is not output either.
///
/// **The shell's own streams do not count (T-313):** its ambient bed is a running output stream
/// for as long as Home is up, and it must not hold the screen saver off. A stream is the shell's
/// when its `application.process.binary` is [`SHELL_BINARY`] (libpulse fills it in from the process;
/// Qt Multimedia has no way to set a stream's `media.role`). An app's stream still counts.
pub fn parse_playing(json: &str) -> bool {
    let Ok(doc) = serde_json::from_str::<Value>(json) else {
        return false;
    };
    doc.as_array().into_iter().flatten().any(|obj| {
        obj.get("type").and_then(Value::as_str) == Some("PipeWire:Interface:Node")
            && obj["info"]["props"]["media.class"].as_str() == Some("Stream/Output/Audio")
            && obj["info"]["state"].as_str() == Some("running")
            && !corked(&obj["info"]["props"])
            && !shells_own(&obj["info"]["props"])
    })
}

/// `application.process.binary` of the shell's streams (its executable is `ruya-shell`).
pub const SHELL_BINARY: &str = "ruya-shell";

/// Whether the stream belongs to the shell itself (its ambient bed and UI sounds).
fn shells_own(props: &Value) -> bool {
    props["application.process.binary"].as_str() == Some(SHELL_BINARY)
}

/// pipewire-pulse marks a corked stream `pulse.corked` (a string or a boolean, depending on the version).
fn corked(props: &Value) -> bool {
    match &props["pulse.corked"] {
        Value::String(s) => s.eq_ignore_ascii_case("true"),
        Value::Bool(b) => *b,
        _ => false,
    }
}

/// hdmi / analog / usb / bluetooth from the node's properties; analog when unsure.
fn classify(props: &Value) -> Kind {
    let text = |key: &str| props[key].as_str().unwrap_or("").to_ascii_lowercase();
    let node = text("node.name");
    if text("device.api") == "bluez5" || node.starts_with("bluez_") {
        return Kind::Bluetooth;
    }
    if text("device.bus") == "usb" {
        return Kind::Usb;
    }
    let hdmi = |s: &str| s.contains("hdmi") || s.contains("displayport");
    if hdmi(&node) || hdmi(&text("device.profile.name")) || hdmi(&text("api.alsa.pcm.name")) {
        return Kind::Hdmi;
    }
    Kind::Analog
}

/// "Volume: 0.50" or "Volume: 0.50 [MUTED]" -> (50, muted). Rounded, clamped to 0-100.
pub fn parse_volume(line: &str) -> Result<(u32, bool), String> {
    let rest = line
        .trim()
        .strip_prefix("Volume:")
        .ok_or_else(|| format!("wpctl: unexpected output {line:?}"))?;
    let value: f64 = rest
        .split_whitespace()
        .next()
        .and_then(|v| v.parse().ok())
        .ok_or_else(|| format!("wpctl: no volume in {line:?}"))?;
    let percent = (value * 100.0).round().clamp(0.0, 100.0) as u32;
    Ok((percent, rest.contains("[MUTED]")))
}

#[cfg(target_os = "linux")]
pub use linux::WpCtl;

#[cfg(target_os = "linux")]
mod linux {
    use std::process::Command;

    use super::{parse_dump, parse_outputs, parse_playing, parse_volume};
    use crate::audio::{PipeWire, Snapshot};
    use crate::output_policy::tone_wav;

    const DEFAULT_SINK: &str = "@DEFAULT_AUDIO_SINK@";

    pub struct WpCtl;

    fn run(program: &str, args: &[&str]) -> Result<String, String> {
        let out = Command::new(program)
            .args(args)
            .output()
            .map_err(|e| format!("{program}: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "{program} {}: {}",
                args.join(" "),
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }

    /// `wpctl set-default` wants the numeric object id, the contract uses `node.name`.
    fn object_id(name: &str) -> Result<u64, String> {
        let dump = run("pw-dump", &[])?;
        let doc: serde_json::Value = serde_json::from_str(&dump).map_err(|e| e.to_string())?;
        doc.as_array()
            .into_iter()
            .flatten()
            .find(|o| o["info"]["props"]["node.name"].as_str() == Some(name))
            .and_then(|o| o["id"].as_u64())
            .ok_or_else(|| format!("no node named {name}"))
    }

    impl PipeWire for WpCtl {
        fn snapshot(&mut self) -> Result<Snapshot, String> {
            let dump = run("pw-dump", &[])?;
            let (sinks, default) = parse_dump(&dump)?;
            let outputs = parse_outputs(&dump, &sinks);
            let playing = parse_playing(&dump);
            // No default output (none connected) means no volume to read.
            let (volume, muted) = if default.is_some() {
                parse_volume(&run("wpctl", &["get-volume", DEFAULT_SINK])?)?
            } else {
                (0, false)
            };
            Ok(Snapshot {
                sinks,
                outputs,
                default,
                volume,
                muted,
                playing,
            })
        }

        fn set_default(&mut self, id: &str) -> Result<(), String> {
            let object = object_id(id)?;
            run("wpctl", &["set-default", &object.to_string()]).map(drop)
        }

        fn play_tone(&mut self, node: &str) -> Result<(), String> {
            // pw-play with a target plays on that sink and leaves the default alone.
            let file = std::env::temp_dir().join("ruya-test-tone.wav");
            std::fs::write(&file, tone_wav()).map_err(|e| format!("tone: {e}"))?;
            let mut child = Command::new("pw-play")
                .arg(format!("--target={node}"))
                .arg(&file)
                .spawn()
                .map_err(|e| format!("pw-play: {e}"))?;
            // Reaped off the caller's thread; the tone lasts under half a second.
            std::thread::spawn(move || {
                let _ = child.wait();
            });
            Ok(())
        }

        fn set_volume(&mut self, volume: u32) -> Result<(), String> {
            let level = format!("{:.2}", f64::from(volume.min(100)) / 100.0);
            run("wpctl", &["set-volume", DEFAULT_SINK, &level]).map(drop)
        }

        fn set_muted(&mut self, muted: bool) -> Result<(), String> {
            run(
                "wpctl",
                &["set-mute", DEFAULT_SINK, if muted { "1" } else { "0" }],
            )
            .map(drop)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DUMP: &str = r#"[
      {"id":31,"type":"PipeWire:Interface:Metadata","props":{"metadata.name":"default"},
       "metadata":[
         {"subject":0,"key":"default.configured.audio.sink","type":"Spa:String:JSON","value":{"name":"cfg"}},
         {"subject":0,"key":"default.audio.sink","type":"Spa:String:JSON","value":{"name":"alsa_output.pci-0000_00_1b.0.analog-stereo"}}
       ]},
      {"id":40,"type":"PipeWire:Interface:Node","info":{"props":{
         "media.class":"Audio/Sink","node.name":"alsa_output.pci-0000_00_1b.0.analog-stereo",
         "node.description":"Built-in Audio Analog Stereo","device.profile.name":"analog-stereo"}}},
      {"id":41,"type":"PipeWire:Interface:Node","info":{"props":{
         "media.class":"Audio/Sink","node.name":"alsa_output.pci-0000_01_00.1.hdmi-stereo",
         "node.description":"TV","device.profile.name":"hdmi-stereo"}}},
      {"id":42,"type":"PipeWire:Interface:Node","info":{"props":{
         "media.class":"Audio/Sink","node.name":"alsa_output.usb-Logi.analog-stereo",
         "node.description":"Headset","device.bus":"usb"}}},
      {"id":43,"type":"PipeWire:Interface:Node","info":{"props":{
         "media.class":"Audio/Sink","node.name":"bluez_output.AA_BB.1","device.api":"bluez5"}}},
      {"id":44,"type":"PipeWire:Interface:Node","info":{"props":{
         "media.class":"Audio/Source","node.name":"alsa_input.mic"}}},
      {"id":45,"type":"PipeWire:Interface:Client","info":{"props":{}}}
    ]"#;

    #[test]
    fn dump_gives_sinks_kinds_and_default() {
        let (sinks, default) = parse_dump(DUMP).unwrap();
        let kinds: Vec<_> = sinks.iter().map(|s| s.kind.as_str()).collect();
        assert_eq!(kinds, ["analog", "hdmi", "usb", "bluetooth"]);
        assert_eq!(sinks[0].name, "Built-in Audio Analog Stereo");
        assert_eq!(sinks[3].name, "bluez_output.AA_BB.1"); // no description: the id
        assert_eq!(
            default.as_deref(),
            Some("alsa_output.pci-0000_00_1b.0.analog-stereo")
        );
    }

    /// A Dell-like card: the internal speaker is the active route, the headphones jack is
    /// unplugged, the HDMI port has a valid ELD but sits on an inactive profile (no sink).
    const CARD: &str = r#"[
      {"id":50,"type":"PipeWire:Interface:Device","info":{"props":{
         "device.name":"alsa_card.pci-0000_00_1f.3","device.description":"Built-in Audio"},
       "params":{
         "EnumRoute":[
           {"index":0,"direction":"Output","name":"analog-output-speaker","description":"Speakers","available":"unknown"},
           {"index":1,"direction":"Output","name":"analog-output-headphones","description":"Headphones","available":"no"},
           {"index":2,"direction":"Output","name":"hdmi-output-0","description":"HDMI / DisplayPort","available":"yes"},
           {"index":3,"direction":"Input","name":"analog-input-mic","description":"Microphone","available":"no"}],
         "Route":[
           {"index":0,"direction":"Output","name":"analog-output-speaker","device":2,"available":"unknown"}]}}},
      {"id":60,"type":"PipeWire:Interface:Node","info":{"props":{
         "media.class":"Audio/Sink","node.name":"alsa_output.pci-0000_00_1f.3.analog-stereo",
         "node.description":"Built-in Audio Analog Stereo","device.id":50,"card.profile.device":2}}}
    ]"#;

    #[test]
    fn a_card_lists_all_its_outputs_and_matches_the_active_one_to_its_sink() {
        let (sinks, _) = parse_dump(CARD).unwrap();
        let outputs = parse_outputs(CARD, &sinks);
        let view: Vec<_> = outputs
            .iter()
            .map(|o| {
                (
                    o.id.as_str(),
                    o.kind.as_str(),
                    o.available.as_str(),
                    o.node.as_deref(),
                )
            })
            .collect();
        assert_eq!(
            view,
            [
                (
                    "alsa_card.pci-0000_00_1f.3:analog-output-speaker",
                    "speaker",
                    "unknown",
                    Some("alsa_output.pci-0000_00_1f.3.analog-stereo")
                ),
                (
                    "alsa_card.pci-0000_00_1f.3:analog-output-headphones",
                    "headphones",
                    "no",
                    None
                ),
                (
                    "alsa_card.pci-0000_00_1f.3:hdmi-output-0",
                    "hdmi",
                    "yes",
                    None
                ),
            ]
        );
        assert_eq!(outputs[2].name, "HDMI / DisplayPort");
        assert_eq!(outputs[2].card, "alsa_card.pci-0000_00_1f.3");
        assert_eq!(outputs[2].port, "hdmi-output-0");
    }

    #[test]
    fn a_sink_without_routes_is_an_output_of_its_own() {
        let (sinks, _) = parse_dump(DUMP).unwrap();
        let outputs = parse_outputs(DUMP, &sinks);
        assert_eq!(outputs.len(), 4);
        assert_eq!(outputs[2].kind.as_str(), "usb");
        assert_eq!(outputs[2].id, "alsa_output.usb-Logi.analog-stereo");
        assert_eq!(
            outputs[2].node.as_deref(),
            Some("alsa_output.usb-Logi.analog-stereo")
        );
        assert!(parse_outputs("not json", &sinks).is_empty());
    }

    #[test]
    fn configured_default_is_the_fallback() {
        let json = r#"[{"type":"PipeWire:Interface:Metadata","props":{"metadata.name":"default"},
          "metadata":[{"key":"default.configured.audio.sink","value":{"name":"cfg"}}]}]"#;
        assert_eq!(parse_dump(json).unwrap().1.as_deref(), Some("cfg"));
    }

    #[test]
    fn a_running_output_stream_means_something_plays() {
        assert!(!parse_playing(DUMP), "no state at all");
        let node = |state: &str, class: &str| {
            format!(
                r#"[{{"id":1,"type":"PipeWire:Interface:Node","info":{{"state":"{state}","props":{{"media.class":"{class}"}}}}}}]"#
            )
        };
        assert!(parse_playing(&node("running", "Stream/Output/Audio")));
        // A paused stream is idle in the graph, and a stopped one suspended.
        assert!(!parse_playing(&node("idle", "Stream/Output/Audio")));
        assert!(!parse_playing(&node("paused", "Stream/Output/Audio")));
        assert!(!parse_playing(&node("suspended", "Stream/Output/Audio")));
        // A sink that is still running after its stream paused is not playing, and neither is a
        // running microphone or an input stream.
        assert!(!parse_playing(&node("running", "Audio/Sink")));
        assert!(!parse_playing(&node("running", "Audio/Source")));
        assert!(!parse_playing(&node("running", "Stream/Input/Audio")));
        assert!(!parse_playing("not json"));
    }

    #[test]
    fn a_corked_stream_does_not_count_even_when_running() {
        let stream = |corked: &str| {
            format!(
                r#"[{{"id":1,"type":"PipeWire:Interface:Node","info":{{"state":"running","props":{{"media.class":"Stream/Output/Audio"{corked}}}}}}}]"#
            )
        };
        assert!(parse_playing(&stream("")));
        assert!(parse_playing(&stream(r#","pulse.corked":"false""#)));
        assert!(!parse_playing(&stream(r#","pulse.corked":"true""#)));
        assert!(!parse_playing(&stream(r#","pulse.corked":true"#)));
    }

    #[test]
    fn a_paused_stream_beside_a_running_sink_is_quiet_and_a_running_one_is_not() {
        let graph = |stream_state: &str| {
            format!(
                r#"[{{"id":1,"type":"PipeWire:Interface:Node","info":{{"state":"running","props":{{"media.class":"Audio/Sink"}}}}}},
                    {{"id":2,"type":"PipeWire:Interface:Node","info":{{"state":"{stream_state}","props":{{"media.class":"Stream/Output/Audio"}}}}}}]"#
            )
        };
        assert!(!parse_playing(&graph("paused")));
        assert!(parse_playing(&graph("running")));
    }

    /// A running output stream with the given extra properties (T-313).
    fn stream(id: u32, state: &str, extra: &str) -> String {
        format!(
            r#"{{"id":{id},"type":"PipeWire:Interface:Node","info":{{"state":"{state}","props":{{"media.class":"Stream/Output/Audio"{extra}}}}}}}"#
        )
    }
    const SHELL: &str =
        r#","application.name":"ruya-shell","application.process.binary":"ruya-shell""#;
    const GAME: &str = r#","application.name":"Celeste","application.process.binary":"celeste""#;

    #[test]
    fn the_shells_ambient_bed_alone_does_not_play() {
        let dump = format!("[{}]", stream(1, "running", SHELL));
        assert!(!parse_playing(&dump));
    }

    #[test]
    fn a_game_stream_beside_the_ambient_bed_plays() {
        let dump = format!(
            "[{},{}]",
            stream(1, "running", SHELL),
            stream(2, "running", GAME)
        );
        assert!(parse_playing(&dump));
    }

    #[test]
    fn a_corked_game_beside_the_ambient_bed_does_not() {
        let corked = format!(r#"{GAME},"pulse.corked":"true""#);
        let dump = format!(
            "[{},{}]",
            stream(1, "running", SHELL),
            stream(2, "running", &corked)
        );
        assert!(!parse_playing(&dump));
        let paused = format!(
            "[{},{}]",
            stream(1, "running", SHELL),
            stream(2, "paused", GAME)
        );
        assert!(!parse_playing(&paused));
    }

    #[test]
    fn only_the_shells_own_binary_is_skipped() {
        // Another program that happens to be called the same in `application.name` is not skipped.
        let imposter = r#","application.name":"ruya-shell","application.process.binary":"mpv""#;
        assert!(parse_playing(&format!(
            "[{}]",
            stream(1, "running", imposter)
        )));
        // A stream without the property (a bare pipewire client) counts.
        assert!(parse_playing(&format!("[{}]", stream(1, "running", ""))));
    }

    #[test]
    fn garbage_is_an_error() {
        assert!(parse_dump("not json").is_err());
        assert!(parse_dump("{}").is_err());
        assert_eq!(parse_dump("[]").unwrap(), (vec![], None));
    }

    #[test]
    fn volume_lines() {
        assert_eq!(parse_volume("Volume: 0.50\n").unwrap(), (50, false));
        assert_eq!(parse_volume("Volume: 0.33 [MUTED]").unwrap(), (33, true));
        assert_eq!(parse_volume("Volume: 1.20").unwrap(), (100, false));
        assert!(parse_volume("oops").is_err());
        assert!(parse_volume("Volume: x").is_err());
    }
}
