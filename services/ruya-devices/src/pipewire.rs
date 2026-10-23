//! PipeWire through its command line tools: `pw-dump` (JSON) to read the outputs and the
//! default, `wpctl` to change them. Parsing is pure and tested here; running the tools is
//! Linux-only. Chosen over a PipeWire binding crate: no C library to build against, and one
//! poll per second is enough for a living-room console.

use serde_json::Value;

use crate::audio::{Kind, Sink};

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

    use super::{parse_dump, parse_volume};
    use crate::audio::{PipeWire, Snapshot};

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
            let (sinks, default) = parse_dump(&run("pw-dump", &[])?)?;
            // No default output (none connected) means no volume to read.
            let (volume, muted) = if default.is_some() {
                parse_volume(&run("wpctl", &["get-volume", DEFAULT_SINK])?)?
            } else {
                (0, false)
            };
            Ok(Snapshot {
                sinks,
                default,
                volume,
                muted,
            })
        }

        fn set_default(&mut self, id: &str) -> Result<(), String> {
            let object = object_id(id)?;
            run("wpctl", &["set-default", &object.to_string()]).map(drop)
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

    #[test]
    fn configured_default_is_the_fallback() {
        let json = r#"[{"type":"PipeWire:Interface:Metadata","props":{"metadata.name":"default"},
          "metadata":[{"key":"default.configured.audio.sink","value":{"name":"cfg"}}]}]"#;
        assert_eq!(parse_dump(json).unwrap().1.as_deref(), Some("cfg"));
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
