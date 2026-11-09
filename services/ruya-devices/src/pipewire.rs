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

/// What it takes to make a card's output the one in use (T-347): found in a `pw-dump`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SwitchPlan {
    /// The card's Device object id (what `wpctl set-profile` and `pw-cli set-param` take).
    pub device: u64,
    /// The profile to switch to, `None` when the active one already carries the port.
    pub profile: Option<u32>,
    /// The route (`EnumRoute` index) and the card device it plays on.
    pub route_index: u32,
    pub route_device: u32,
    /// The route is the one in use.
    pub route_active: bool,
}

/// The Device object of the card named `card` (its `device.name`).
fn card_object<'a>(objects: &'a [Value], card: &str) -> Option<&'a Value> {
    objects.iter().find(|o| {
        o.get("type").and_then(Value::as_str) == Some("PipeWire:Interface:Device")
            && o["info"]["props"]["device.name"].as_str() == Some(card)
    })
}

fn objects_of(json: &str) -> Result<Vec<Value>, String> {
    let doc: Value = serde_json::from_str(json).map_err(|e| format!("pw-dump: {e}"))?;
    doc.as_array()
        .cloned()
        .ok_or_else(|| "pw-dump: not an array".to_owned())
}

fn index_of(v: &Value, key: &str) -> Option<u32> {
    v[key].as_u64().and_then(|n| u32::try_from(n).ok())
}

/// Which profile and route reach `port` of `card`, and whether they are in use already.
pub fn plan_switch(json: &str, card: &str, port: &str) -> Result<SwitchPlan, String> {
    let objects = objects_of(json)?;
    let dev = card_object(&objects, card).ok_or_else(|| format!("no card named {card}"))?;
    let device = dev["id"].as_u64().ok_or("card without an id")?;
    let params = &dev["info"]["params"];
    let route = params["EnumRoute"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|r| r["name"].as_str() == Some(port))
        .ok_or_else(|| format!("{card} has no port {port}"))?;
    let route_index = index_of(route, "index").ok_or("route without an index")?;
    let route_devices: Vec<u32> = route["devices"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|d| d.as_u64().and_then(|d| u32::try_from(d).ok()))
        .collect();
    let wanted: Vec<u32> = route["profiles"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|p| p.as_u64().and_then(|p| u32::try_from(p).ok()))
        .collect();
    let active = params["Profile"]
        .as_array()
        .and_then(|p| p.first())
        .and_then(|p| index_of(p, "index"));
    let profile = match active {
        Some(a) if wanted.contains(&a) => None,
        _ => Some(*wanted.first().ok_or("route without a profile")?),
    };
    // A route can list devices of several profiles: take one the chosen profile really has.
    let target = profile.or(active);
    let profile_devices = target
        .and_then(|t| {
            params["EnumProfile"]
                .as_array()?
                .iter()
                .find(|p| index_of(p, "index") == Some(t))
                .and_then(profile_devices)
        })
        .unwrap_or_default();
    let route_device = route_devices
        .iter()
        .find(|d| profile_devices.contains(d))
        .or_else(|| route_devices.first())
        .copied()
        .ok_or("route without a device")?;
    let route_active =
        params["Route"].as_array().into_iter().flatten().any(|r| {
            r["name"].as_str() == Some(port) && index_of(r, "device") == Some(route_device)
        });
    Ok(SwitchPlan {
        device,
        profile,
        route_index,
        route_device,
        route_active,
    })
}

/// The card devices an `EnumProfile` entry has: the value after `card.profile.devices` in its
/// `classes` (a flat struct in `pw-dump`, or an object key, depending on the version).
fn profile_devices(profile: &Value) -> Option<Vec<u32>> {
    fn numbers(v: &Value) -> Vec<u32> {
        v.as_array()
            .into_iter()
            .flatten()
            .filter_map(|n| n.as_u64().and_then(|n| u32::try_from(n).ok()))
            .collect()
    }
    fn walk(v: &Value) -> Option<Vec<u32>> {
        match v {
            Value::Array(items) => {
                for (i, item) in items.iter().enumerate() {
                    if item.as_str() == Some("card.profile.devices") {
                        if let Some(next) = items.get(i + 1) {
                            return Some(numbers(next));
                        }
                    }
                    if let Some(found) = walk(item) {
                        return Some(found);
                    }
                }
                None
            }
            Value::Object(map) => map
                .get("card.profile.devices")
                .map(numbers)
                .or_else(|| map.values().find_map(walk)),
            _ => None,
        }
    }
    walk(&profile["classes"])
}

/// The sink (`node.name`) of a card device, once its profile is up.
pub fn find_sink(json: &str, device: u64, route_device: u32) -> Option<String> {
    let objects = objects_of(json).ok()?;
    objects
        .iter()
        .filter(|o| o.get("type").and_then(Value::as_str) == Some("PipeWire:Interface:Node"))
        .map(|o| &o["info"]["props"])
        .find(|p| {
            p["media.class"].as_str() == Some("Audio/Sink")
                && p["device.id"].as_u64() == Some(device)
                && p["card.profile.device"].as_u64() == Some(u64::from(route_device))
        })
        .and_then(|p| p["node.name"].as_str())
        .map(str::to_owned)
}

/// A card's state as one token for `restore_profile`: "<device>/<profile>/<route>/<route device>"
/// with "-" when no output route is in use.
pub fn card_state(json: &str, card: &str) -> Result<String, String> {
    let objects = objects_of(json)?;
    let dev = card_object(&objects, card).ok_or_else(|| format!("no card named {card}"))?;
    let device = dev["id"].as_u64().ok_or("card without an id")?;
    let params = &dev["info"]["params"];
    let profile = params["Profile"]
        .as_array()
        .and_then(|p| p.first())
        .and_then(|p| index_of(p, "index"))
        .ok_or("card without a profile")?;
    let route = params["Route"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|r| {
            r["direction"]
                .as_str()
                .is_some_and(|d| d.eq_ignore_ascii_case("output"))
        })
        .and_then(|r| Some((index_of(r, "index")?, index_of(r, "device")?)));
    Ok(match route {
        Some((i, d)) => format!("{device}/{profile}/{i}/{d}"),
        None => format!("{device}/{profile}/-/-"),
    })
}

/// A route in use: its index and its card device.
pub type RouteInUse = (u32, u32);

/// A `card_state` token: (device, profile, route).
pub fn parse_state(state: &str) -> Option<(u64, u32, Option<RouteInUse>)> {
    let mut it = state.split('/');
    let device = it.next()?.parse().ok()?;
    let profile = it.next()?.parse().ok()?;
    let route = match (it.next()?, it.next()?) {
        ("-", _) | (_, "-") => None,
        (i, d) => Some((i.parse().ok()?, d.parse().ok()?)),
    };
    Some((device, profile, route))
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
    use std::process::{Child, Command};
    use std::time::{Duration, Instant};

    use super::{
        card_state, find_sink, parse_dump, parse_outputs, parse_playing, parse_state, parse_volume,
        plan_switch,
    };
    use crate::audio::{PipeWire, Snapshot};
    use crate::output_policy::{tone_wav, Output};

    const DEFAULT_SINK: &str = "@DEFAULT_AUDIO_SINK@";
    /// A profile switch or a route change takes a moment to show up as a sink.
    const SETTLE: Duration = Duration::from_secs(4);

    /// `pw-dump`, `wpctl`, `pw-cli` and `pw-play`. Profiles and routes are set through the same
    /// PipeWire objects WirePlumber manages (it keeps each route's volume and saves the choice).
    #[derive(Default)]
    pub struct WpCtl {
        /// The tone that may still be playing: a profile borrowed for it is given back after it.
        tone: Option<Child>,
    }

    impl WpCtl {
        fn wait_tone(&mut self) {
            if let Some(mut child) = self.tone.take() {
                let _ = child.wait();
            }
        }

        fn poll<T>(&mut self, mut probe: impl FnMut(&str) -> Option<T>) -> Result<T, String> {
            let until = Instant::now() + SETTLE;
            loop {
                if let Some(found) = probe(&run("pw-dump", &[])?) {
                    return Ok(found);
                }
                if Instant::now() >= until {
                    return Err("the sound card did not settle".to_owned());
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        }

        fn set_route(device: u64, index: u32, route_device: u32) -> Result<(), String> {
            let param = format!("{{ index: {index}, device: {route_device}, save: true }}");
            run(
                "pw-cli",
                &["set-param", &device.to_string(), "Route", &param],
            )
            .map(drop)
        }
    }

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
            self.wait_tone();
            let file = std::env::temp_dir().join("ruya-test-tone.wav");
            std::fs::write(&file, tone_wav()).map_err(|e| format!("tone: {e}"))?;
            let child = Command::new("pw-play")
                .arg(format!("--target={node}"))
                .arg(&file)
                .spawn()
                .map_err(|e| format!("pw-play: {e}"))?;
            // Kept so the next call (or a profile restore) waits for it: under half a second.
            self.tone = Some(child);
            Ok(())
        }

        fn card_profile(&mut self, card: &str) -> Result<String, String> {
            card_state(&run("pw-dump", &[])?, card)
        }

        fn switch_to(&mut self, output: &Output) -> Result<String, String> {
            let (card, port) = (output.card.as_str(), output.port.as_str());
            let plan = plan_switch(&run("pw-dump", &[])?, card, port)?;
            if let Some(profile) = plan.profile {
                run(
                    "wpctl",
                    &[
                        "set-profile",
                        &plan.device.to_string(),
                        &profile.to_string(),
                    ],
                )?;
                // The routes of the new profile appear with it.
                self.poll(|dump| {
                    plan_switch(dump, card, port)
                        .ok()
                        .filter(|p| p.profile.is_none())
                })?;
            }
            let plan = plan_switch(&run("pw-dump", &[])?, card, port)?;
            if !plan.route_active {
                Self::set_route(plan.device, plan.route_index, plan.route_device)?;
            }
            self.poll(|dump| find_sink(dump, plan.device, plan.route_device))
        }

        fn restore_profile(&mut self, card: &str, state: &str) -> Result<(), String> {
            self.wait_tone();
            let (device, profile, route) = parse_state(state).ok_or("bad card state")?;
            let now =
                parse_state(&card_state(&run("pw-dump", &[])?, card)?).ok_or("bad card state")?;
            if now.1 != profile {
                run(
                    "wpctl",
                    &["set-profile", &device.to_string(), &profile.to_string()],
                )?;
            }
            if let Some((index, route_device)) = route {
                if now.2 != Some((index, route_device)) || now.1 != profile {
                    // Let the profile's routes appear before choosing one.
                    self.poll(|dump| {
                        let now = parse_state(&card_state(dump, card).ok()?)?;
                        (now.1 == profile).then_some(())
                    })?;
                    Self::set_route(device, index, route_device)?;
                }
                // Back only when its sink is: the caller sets the default right after.
                self.poll(|dump| find_sink(dump, device, route_device))?;
            }
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

    /// The Dell card on its analog profile (index 1); the HDMI port belongs to profile 2.
    const PROFILES: &str = r#"[
      {"id":50,"type":"PipeWire:Interface:Device","info":{"props":{"device.name":"card0"},
       "params":{
         "Profile":[{"index":1,"name":"analog"}],
         "EnumProfile":[
           {"index":1,"name":"analog","classes":[["Audio/Sink",1,"card.profile.devices",[2]]]},
           {"index":2,"name":"hdmi","classes":[["Audio/Sink",1,"card.profile.devices",[5]]]},
           {"index":3,"name":"hdmi2","classes":[["Audio/Sink",1,"card.profile.devices",[6]]]}],
         "EnumRoute":[
           {"index":0,"direction":"Output","name":"speaker","profiles":[1],"devices":[2]},
           {"index":1,"direction":"Output","name":"headphones","profiles":[1],"devices":[2]},
           {"index":2,"direction":"Output","name":"hdmi-0","profiles":[2,3],"devices":[6,5]}],
         "Route":[{"index":0,"direction":"Output","name":"speaker","device":2}]}}},
      {"id":60,"type":"PipeWire:Interface:Node","info":{"props":{
         "media.class":"Audio/Sink","node.name":"sink.analog","device.id":50,"card.profile.device":2}}}
    ]"#;

    #[test]
    fn a_plan_names_the_profile_the_route_and_what_is_already_in_use() {
        // Another profile: switch it, then the route.
        let hdmi = plan_switch(PROFILES, "card0", "hdmi-0").unwrap();
        assert_eq!(
            hdmi,
            SwitchPlan {
                device: 50,
                profile: Some(2),
                route_index: 2,
                route_device: 5,
                route_active: false
            }
        );
        // The same profile, another route (the jack): no profile switch, just the route.
        let jack = plan_switch(PROFILES, "card0", "headphones").unwrap();
        assert_eq!(
            (jack.profile, jack.route_index, jack.route_active),
            (None, 1, false)
        );
        // The route in use needs nothing.
        let spk = plan_switch(PROFILES, "card0", "speaker").unwrap();
        assert_eq!((spk.profile, spk.route_active), (None, true));
        assert!(plan_switch(PROFILES, "card0", "nope").is_err());
        assert!(plan_switch(PROFILES, "other", "speaker").is_err());
    }

    #[test]
    fn a_card_state_round_trips_and_a_sink_is_found_by_its_device() {
        let state = card_state(PROFILES, "card0").unwrap();
        assert_eq!(state, "50/1/0/2");
        assert_eq!(parse_state(&state), Some((50, 1, Some((0, 2)))));
        assert_eq!(parse_state("50/1/-/-"), Some((50, 1, None)));
        assert_eq!(parse_state("junk"), None);
        assert_eq!(find_sink(PROFILES, 50, 2).as_deref(), Some("sink.analog"));
        assert_eq!(
            find_sink(PROFILES, 50, 5),
            None,
            "no sink on the other profile yet"
        );
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
