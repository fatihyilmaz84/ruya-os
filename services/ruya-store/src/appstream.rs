//! Reading what the store needs from AppStream catalogue XML (`appstream.xml` that flatpak keeps
//! per remote) and from an app's Flatpak `metadata` file (its permissions). Pure and tested here;
//! a damaged document gives what was read before the damage, never a panic.

use quick_xml::events::{BytesStart, Event};
use quick_xml::Reader;

/// What AppStream says about one app. Empty strings mean "not in the metadata".
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Component {
    pub id: String,
    pub name: String,
    pub summary: String,
    pub description: String,
    pub developer: String,
    /// "full" | "partial" | "none"
    pub controller: String,
    pub age_rating: String,
    pub icon: String,
    pub tile: String,
    pub hero: String,
}

/// An element that is open: its name and the attributes the rules look at.
struct Open {
    name: String,
    /// `xml:lang` present: the translations are not read, the default text is enough.
    translated: bool,
    kind: String,
    key: String,
    id: String,
    size: String,
}

/// OARS severity words, 0 (none) to 3 (intense).
fn severity(word: &str) -> u8 {
    match word.trim() {
        "mild" => 1,
        "moderate" => 2,
        "intense" => 3,
        _ => 0,
    }
}

#[derive(Default)]
struct Builder {
    c: Component,
    paragraphs: Vec<String>,
    gamepad: bool,
    custom_controller: String,
    rated: bool,
    worst: u8,
    adult: bool,
    cached_icon: String,
}

impl Builder {
    fn finish(mut self) -> Component {
        self.c.description = self.paragraphs.join("\n\n");
        self.c.controller =
            if matches!(self.custom_controller.as_str(), "full" | "partial" | "none") {
                self.custom_controller
            } else if self.gamepad {
                "partial".to_owned()
            } else {
                "none".to_owned()
            };
        if self.rated {
            self.c.age_rating = match self.worst {
                0 => "all",
                1 => "7+",
                2 => "12+",
                _ if self.adult => "18+",
                _ => "16+",
            }
            .to_owned();
        }
        if self.c.icon.is_empty() {
            self.c.icon = self.cached_icon;
        }
        self.c
    }
}

/// The apps in an AppStream document. `icon_base` is the directory holding the `<size>/<icon>`
/// folders that `cached` icons live in (a `file://` URL is made of it).
pub fn parse(xml: &str, icon_base: &str) -> Vec<Component> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut out = Vec::new();
    let mut stack: Vec<Open> = Vec::new();
    let mut cur: Option<Builder> = None;

    while let Ok(event) = reader.read_event() {
        match event {
            Event::Start(e) => {
                let open = open_of(&e);
                if open.name == "component" && stack.last().is_some_and(|p| p.name == "components")
                {
                    cur = is_app(&open).then(Builder::default);
                }
                stack.push(open);
            }
            Event::Text(t) => {
                if let (Some(b), Ok(text)) = (cur.as_mut(), t.unescape()) {
                    on_text(b, &stack, text.trim(), icon_base);
                }
            }
            Event::CData(t) => {
                if let (Some(b), Ok(text)) = (cur.as_mut(), std::str::from_utf8(&t)) {
                    on_text(b, &stack, text.trim(), icon_base);
                }
            }
            Event::End(_) => {
                if let Some(open) = stack.pop() {
                    if open.name == "component" {
                        if let Some(b) = cur.take() {
                            let c = b.finish();
                            if !c.id.is_empty() {
                                out.push(c);
                            }
                        }
                    }
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    out
}

fn open_of(e: &BytesStart<'_>) -> Open {
    let mut open = Open {
        name: String::from_utf8_lossy(e.name().as_ref()).into_owned(),
        translated: false,
        kind: String::new(),
        key: String::new(),
        id: String::new(),
        size: String::new(),
    };
    for attr in e.attributes().flatten() {
        let value = attr
            .unescape_value()
            .map(|v| v.into_owned())
            .unwrap_or_default();
        match attr.key.as_ref() {
            b"xml:lang" => open.translated = true,
            b"type" => open.kind = value,
            b"key" => open.key = value,
            b"id" => open.id = value,
            b"width" => open.size = value,
            _ => {}
        }
    }
    open
}

/// Apps only: runtimes, add-ons and the like are not for the store.
fn is_app(component: &Open) -> bool {
    matches!(
        component.kind.as_str(),
        "" | "desktop-application" | "desktop" | "console-application"
    )
}

fn on_text(b: &mut Builder, stack: &[Open], text: &str, icon_base: &str) {
    if text.is_empty() {
        return;
    }
    let Some(top) = stack.last() else { return };
    let parent = stack
        .len()
        .checked_sub(2)
        .and_then(|i| stack.get(i))
        .map_or("", |p| p.name.as_str());
    let in_description = stack
        .iter()
        .any(|o| o.name == "description" && !o.translated);
    match (top.name.as_str(), parent) {
        ("id", "component") => {
            b.c.id = text.strip_suffix(".desktop").unwrap_or(text).to_owned();
        }
        ("name", "component") if !top.translated => b.c.name.push_str(text),
        ("summary", "component") if !top.translated => b.c.summary.push_str(text),
        ("developer_name", "component") if !top.translated => b.c.developer.push_str(text),
        ("name", "developer") if !top.translated => b.c.developer.push_str(text),
        ("p" | "li", _) if in_description && !top.translated => b.paragraphs.push(text.to_owned()),
        ("icon", "component") => match top.kind.as_str() {
            "remote" => b.c.icon = text.to_owned(),
            "cached" if b.cached_icon.is_empty() => {
                let size = if top.size.is_empty() {
                    "128"
                } else {
                    &top.size
                };
                b.cached_icon = format!("file://{icon_base}/{size}x{size}/{text}");
            }
            _ => {}
        },
        ("content_attribute", "content_rating") => {
            b.rated = true;
            let level = severity(text);
            b.worst = b.worst.max(level);
            let adult = ["sex-", "violence-sexual", "drugs-", "gambling"]
                .iter()
                .any(|prefix| top.id.starts_with(prefix));
            if adult && level >= 3 {
                b.adult = true;
            }
        }
        ("control", "recommends" | "supports") if text == "gamepad" => b.gamepad = true,
        ("value", "custom") => match top.key.as_str() {
            "x-ruya-controller" => b.custom_controller = text.to_owned(),
            "x-ruya-hero" => b.c.hero = text.to_owned(),
            "x-ruya-logo" => b.c.tile = text.to_owned(),
            _ => {}
        },
        _ => {}
    }
}

/// The permission keys of an app from its Flatpak `metadata` (a keyfile), in the order the
/// contract lists them. Negated entries (`!x`) grant nothing.
pub fn permissions(metadata: &str) -> Vec<String> {
    let mut section = "";
    let (mut network, mut audio, mut gamepad) = (false, false, false);
    let (mut home, mut host, mut devices, mut session_bus) = (false, false, false, false);
    for line in metadata.lines() {
        let line = line.trim();
        if let Some(name) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            section = name;
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let items = || {
            value
                .split(';')
                .map(str::trim)
                .filter(|i| !i.is_empty() && !i.starts_with('!'))
        };
        match (section, key.trim()) {
            ("Context", "shared") => network |= items().any(|i| i == "network"),
            ("Context", "sockets") => {
                audio |= items().any(|i| i == "pulseaudio");
                session_bus |= items().any(|i| i == "session-bus");
            }
            ("Context", "devices") => {
                devices |= items().any(|i| i == "all");
                gamepad |= items().any(|i| i == "input");
            }
            ("Context", "filesystems") => {
                for item in items() {
                    let path = item.split(':').next().unwrap_or(item);
                    if matches!(path, "host" | "host-os" | "host-etc") || path.starts_with('/') {
                        host = true;
                    } else if path == "home" || path.starts_with('~') || path.starts_with("xdg-") {
                        home = true;
                    }
                }
            }
            ("Session Bus Policy", "org.freedesktop.Flatpak") => {
                session_bus |= matches!(value.trim(), "talk" | "own");
            }
            _ => {}
        }
    }
    [
        (network, "network"),
        (home, "home-files"),
        (host, "host-files"),
        (devices, "all-devices"),
        (audio, "audio"),
        (gamepad, "gamepad"),
        (session_bus, "session-bus"),
    ]
    .into_iter()
    .filter(|(on, _)| *on)
    .map(|(_, key)| key.to_owned())
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const XML: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<components version="0.14" origin="ruyaos">
  <component type="desktop-application">
    <id>org.example.Racer.desktop</id>
    <name>Turbo Racer</name>
    <name xml:lang="tr">Turbo Yarisci</name>
    <summary>Drive fast &amp; far</summary>
    <summary xml:lang="tr">Hizli surun</summary>
    <developer_name>Example Games</developer_name>
    <description>
      <p>Race around the world.</p>
      <p xml:lang="tr">Dunyayi gez.</p>
      <ul><li>Eight cars</li></ul>
    </description>
    <icon type="cached" width="128" height="128">org.example.Racer.png</icon>
    <content_rating type="oars-1.1">
      <content_attribute id="violence-cartoon">mild</content_attribute>
      <content_attribute id="social-chat">none</content_attribute>
    </content_rating>
    <recommends><control>gamepad</control></recommends>
    <custom>
      <value key="x-ruya-controller">full</value>
      <value key="x-ruya-hero">https://example.org/hero.webp</value>
      <value key="x-ruya-logo">https://example.org/logo.webp</value>
    </custom>
  </component>
  <component type="runtime"><id>org.example.Platform</id><name>Platform</name></component>
  <component type="desktop-application">
    <id>org.example.Quiet</id>
    <name>Quiet</name>
    <icon type="remote">https://example.org/quiet.png</icon>
    <supports><control>gamepad</control></supports>
    <developer><name>Quiet Dev</name></developer>
    <content_rating type="oars-1.1">
      <content_attribute id="sex-nudity">intense</content_attribute>
    </content_rating>
  </component>
  <component><id>org.example.Plain</id><name>Plain</name></component>
</components>"#;

    #[test]
    fn reads_the_fields_the_store_shows() {
        let apps = parse(XML, "/var/lib/flatpak/appstream/ruyaos/x86_64/active/icons");
        let ids: Vec<_> = apps.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "org.example.Racer",
                "org.example.Quiet",
                "org.example.Plain"
            ]
        );

        let racer = &apps[0];
        assert_eq!(racer.name, "Turbo Racer");
        assert_eq!(racer.summary, "Drive fast & far");
        assert_eq!(racer.developer, "Example Games");
        assert_eq!(racer.description, "Race around the world.\n\nEight cars");
        assert_eq!(racer.controller, "full");
        assert_eq!(racer.age_rating, "7+");
        assert_eq!(racer.hero, "https://example.org/hero.webp");
        assert_eq!(racer.tile, "https://example.org/logo.webp");
        assert_eq!(
            racer.icon,
            "file:///var/lib/flatpak/appstream/ruyaos/x86_64/active/icons/128x128/org.example.Racer.png"
        );
    }

    #[test]
    fn controller_age_and_icon_fallbacks() {
        let apps = parse(XML, "/icons");
        let quiet = &apps[1];
        assert_eq!(
            quiet.controller, "partial",
            "gamepad without the custom key"
        );
        assert_eq!(quiet.age_rating, "18+", "intense nudity");
        assert_eq!(quiet.icon, "https://example.org/quiet.png");
        assert_eq!(quiet.developer, "Quiet Dev");
        let plain = &apps[2];
        assert_eq!(plain.controller, "none");
        assert_eq!(plain.age_rating, "", "no rating in the metadata");
        assert_eq!(plain.icon, "");
    }

    #[test]
    fn age_ratings_by_worst_severity() {
        let rate = |attrs: &str| {
            let xml = format!(
                "<components><component><id>a.b.C</id><name>C</name><content_rating type=\"oars-1.1\">{attrs}</content_rating></component></components>"
            );
            parse(&xml, "/i")[0].age_rating.clone()
        };
        assert_eq!(
            rate("<content_attribute id=\"drugs-alcohol\">none</content_attribute>"),
            "all"
        );
        assert_eq!(
            rate("<content_attribute id=\"language-humor\">mild</content_attribute>"),
            "7+"
        );
        assert_eq!(
            rate("<content_attribute id=\"violence-fantasy\">moderate</content_attribute>"),
            "12+"
        );
        assert_eq!(
            rate("<content_attribute id=\"violence-fantasy\">intense</content_attribute>"),
            "16+"
        );
        assert_eq!(
            rate("<content_attribute id=\"drugs-narcotics\">intense</content_attribute>"),
            "18+"
        );
    }

    #[test]
    fn a_damaged_document_keeps_what_came_before() {
        let apps = parse(
            "<components><component><id>a.b.One</id><name>One</name></component><component><id>a.b.Two",
            "/i",
        );
        assert_eq!(apps.len(), 1);
        assert!(parse("not xml at all", "/i").is_empty());
        assert!(parse("", "/i").is_empty());
    }

    #[test]
    fn permissions_in_contract_order() {
        let meta = "[Application]\nname=org.example.Racer\n\n[Context]\nshared=network;ipc;\nsockets=wayland;pulseaudio;\ndevices=all;input;\nfilesystems=xdg-download:ro;host;!home;\n\n[Session Bus Policy]\norg.freedesktop.Flatpak=talk\n";
        assert_eq!(
            permissions(meta),
            [
                "network",
                "home-files",
                "host-files",
                "all-devices",
                "audio",
                "gamepad",
                "session-bus"
            ]
        );
    }

    #[test]
    fn permissions_ignore_what_is_denied_or_harmless() {
        let meta = "[Context]\nshared=!network;ipc\nsockets=wayland;x11\nfilesystems=!host;/media;~/Games\n";
        assert_eq!(permissions(meta), ["home-files", "host-files"]);
        assert!(permissions("").is_empty());
        assert!(permissions("garbage").is_empty());
    }
}
