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
    /// `x-ruya-min-api-level`: the API level the app needs; 0 when missing or not an integer.
    pub min_api_level: u32,
    pub icon: String,
    pub tile: String,
    pub hero: String,
    /// At most 10, the `type="default"` one first.
    pub screenshots: Vec<Screenshot>,
    /// Version of the newest `<release>` (by timestamp or date, not file order); "" when none.
    pub version: String,
    /// Unix seconds of that release; 0 when unknown.
    pub release_date: i64,
    /// That release's `<description>` as plain text; "" when none.
    pub release_notes: String,
    /// `<project_license>` as written (an SPDX expression).
    pub license: String,
    /// `<categories>` in AppStream order, raw names.
    pub categories: Vec<String>,
}

/// One screenshot: `image` is the widest picture of at most 1920 px, `thumb` the narrowest of at
/// least 400 px (else `image`).
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Screenshot {
    pub image: String,
    pub thumb: String,
    pub caption: String,
}

const MAX_SCREENSHOTS: usize = 10;
const MAX_IMAGE_WIDTH: u32 = 1920;
const MIN_THUMB_WIDTH: u32 = 400;

/// (type, width, url) of one `<image>`; width 0 when it names none.
type Image = (String, u32, String);

struct ShotBuild {
    default: bool,
    images: Vec<Image>,
    caption: String,
}

impl ShotBuild {
    fn finish(self) -> Option<Screenshot> {
        let widest = self
            .images
            .iter()
            .filter(|(_, w, _)| *w > 0 && *w <= MAX_IMAGE_WIDTH)
            .fold(None::<&Image>, |best, i| match best {
                Some(b) if b.1 >= i.1 => Some(b),
                _ => Some(i),
            });
        let image = widest
            .or_else(|| self.images.iter().find(|(kind, _, _)| kind == "source"))
            .or_else(|| self.images.first())
            .map(|(_, _, url)| url.clone())?;
        let thumb = self
            .images
            .iter()
            .filter(|(_, w, _)| *w >= MIN_THUMB_WIDTH)
            .fold(None::<&Image>, |best, i| match best {
                Some(b) if b.1 <= i.1 => Some(b),
                _ => Some(i),
            })
            .map_or_else(|| image.clone(), |(_, _, url)| url.clone());
        Some(Screenshot {
            image,
            thumb,
            caption: self.caption,
        })
    }
}

/// A `<release>`; notes are (is_list_item, text) in document order.
struct ReleaseBuild {
    version: String,
    when: i64,
    notes: Vec<(bool, String)>,
}

/// "• " lines for `<li>`, one blank line between the other blocks.
fn plain_notes(notes: &[(bool, String)]) -> String {
    let mut out = String::new();
    let mut prev_item = false;
    for (item, text) in notes {
        if !out.is_empty() {
            out.push_str(if *item && prev_item { "\n" } else { "\n\n" });
        }
        if *item {
            out.push_str("\u{2022} ");
        }
        out.push_str(text);
        prev_item = *item;
    }
    out
}

/// Unix seconds of "YYYY-MM-DD" (a time after it is ignored); 0 when not a date.
fn date_to_unix(date: &str) -> i64 {
    let mut parts = date.get(..10).unwrap_or("").split('-');
    let (Some(y), Some(m), Some(d)) = (parts.next(), parts.next(), parts.next()) else {
        return 0;
    };
    let (Ok(y), Ok(m), Ok(d)) = (y.parse::<i64>(), m.parse::<i64>(), d.parse::<i64>()) else {
        return 0;
    };
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return 0;
    }
    // Days from civil date (Howard Hinnant's algorithm).
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    (era * 146_097 + doe - 719_468) * 86_400
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
    version: String,
    timestamp: String,
    date: String,
}

#[derive(Default)]
struct Builder {
    c: Component,
    paragraphs: Vec<String>,
    gamepad: bool,
    custom_controller: String,
    /// The `content_rating` answers: (OARS attribute id, severity word).
    oars: Vec<(String, String)>,
    cached_icon: String,
    /// The older `<developer_name>`; used only when there is no `<developer><name>`.
    developer_name: String,
    shots: Vec<ShotBuild>,
    releases: Vec<ReleaseBuild>,
}

impl Builder {
    fn finish(mut self) -> Component {
        // The default screenshot first, otherwise AppStream order; ten at most.
        self.shots.sort_by_key(|s| !s.default);
        self.c.screenshots = self
            .shots
            .into_iter()
            .filter_map(ShotBuild::finish)
            .take(MAX_SCREENSHOTS)
            .collect();
        // The newest release; on equal times the first in the file.
        let mut newest: Option<&ReleaseBuild> = None;
        for r in &self.releases {
            if newest.map_or(true, |n| r.when > n.when) {
                newest = Some(r);
            }
        }
        if let Some(r) = newest {
            self.c.version = r.version.clone();
            self.c.release_date = r.when;
            self.c.release_notes = plain_notes(&r.notes);
        }
        if self.c.developer.is_empty() {
            self.c.developer = self.developer_name;
        }
        self.c.description = self.paragraphs.join("\n\n");
        self.c.controller =
            if matches!(self.custom_controller.as_str(), "full" | "partial" | "none") {
                self.custom_controller
            } else if self.gamepad {
                "partial".to_owned()
            } else {
                "none".to_owned()
            };
        if let Some(label) =
            ruya_flatpak::oars::age_label(self.oars.iter().map(|(i, w)| (i.as_str(), w.as_str())))
        {
            self.c.age_rating = label.to_owned();
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
                if let Some(b) = cur.as_mut() {
                    on_start(b, &stack, &open);
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
            Event::Empty(e) => {
                // `<release .../>`: no children, but it is a release.
                if let Some(b) = cur.as_mut() {
                    on_start(b, &stack, &open_of(&e));
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
        version: String::new(),
        timestamp: String::new(),
        date: String::new(),
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
            b"version" => open.version = value,
            b"timestamp" => open.timestamp = value,
            b"date" => open.date = value,
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

/// Elements that start a record of their own: a screenshot and a release.
fn on_start(b: &mut Builder, stack: &[Open], open: &Open) {
    let parent = stack.last().map_or("", |p| p.name.as_str());
    match (open.name.as_str(), parent) {
        ("screenshot", "screenshots") => b.shots.push(ShotBuild {
            default: open.kind == "default",
            images: Vec::new(),
            caption: String::new(),
        }),
        ("release", "releases") => {
            let when = open
                .timestamp
                .trim()
                .parse::<i64>()
                .unwrap_or_else(|_| date_to_unix(open.date.trim()));
            b.releases.push(ReleaseBuild {
                version: open.version.clone(),
                when,
                notes: Vec::new(),
            });
        }
        _ => {}
    }
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
    let in_release = stack.iter().any(|o| o.name == "release");
    let in_description = stack
        .iter()
        .any(|o| o.name == "description" && !o.translated);
    match (top.name.as_str(), parent) {
        ("id", "component") => {
            b.c.id = text.strip_suffix(".desktop").unwrap_or(text).to_owned();
        }
        ("name", "component") if !top.translated => b.c.name.push_str(text),
        ("summary", "component") if !top.translated => b.c.summary.push_str(text),
        ("developer_name", "component") if !top.translated => b.developer_name.push_str(text),
        ("name", "developer") if !top.translated => b.c.developer.push_str(text),
        ("p" | "li", _) if in_description && in_release && !top.translated => {
            if let Some(r) = b.releases.last_mut() {
                r.notes.push((top.name == "li", text.to_owned()));
            }
        }
        ("p" | "li", _) if in_description && !top.translated => b.paragraphs.push(text.to_owned()),
        ("project_license", "component") => b.c.license.push_str(text),
        ("category", "categories") => b.c.categories.push(text.to_owned()),
        ("image", "screenshot") if !top.translated => {
            if let Some(s) = b.shots.last_mut() {
                let width = top.size.trim().parse::<u32>().unwrap_or(0);
                s.images.push((top.kind.clone(), width, text.to_owned()));
            }
        }
        ("caption", "screenshot") if !top.translated => {
            if let Some(s) = b.shots.last_mut() {
                s.caption.push_str(text);
            }
        }
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
            b.oars.push((top.id.clone(), text.to_owned()));
        }
        ("control", "recommends" | "supports") if text == "gamepad" => b.gamepad = true,
        ("value", "custom") => match top.key.as_str() {
            "x-ruya-controller" => b.custom_controller = text.to_owned(),
            "x-ruya-min-api-level" => b.c.min_api_level = crate::level::parse_level(text),
            "x-ruya-hero" => b.c.hero = text.to_owned(),
            "x-ruya-logo" => b.c.tile = text.to_owned(),
            _ => {}
        },
        _ => {}
    }
}

/// The permissions an update adds: those of the new version the installed one does not have, in
/// the new version's order. A removed or unchanged permission is not reported.
pub fn added_permissions(installed: &[String], update: &[String]) -> Vec<String> {
    update
        .iter()
        .filter(|p| !installed.contains(p))
        .cloned()
        .collect()
}

/// The permission keys of an app from its Flatpak `metadata` (a keyfile), in the order the
/// contract lists them. Negated entries (`!x`) grant nothing. The reading is the one the
/// overrides use (`overrides::Context`), so what an app asks for and what is withdrawn from it are
/// named alike.
pub fn permissions(metadata: &str) -> Vec<String> {
    crate::overrides::Context::parse(metadata).keys()
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
    fn the_developer_is_named_once_whichever_elements_carry_it() {
        let one = |inner: &str| {
            let xml = format!(
                "<components><component><id>org.example.D</id><name>D</name>{inner}</component></components>"
            );
            parse(&xml, "/icons").remove(0).developer
        };
        let old = "<developer_name>Old Name</developer_name>";
        let new = "<developer><name>New Name</name></developer>";
        assert_eq!(
            one(&format!("{old}{new}")),
            "New Name",
            "both: the current element"
        );
        assert_eq!(one(&format!("{new}{old}")), "New Name", "in either order");
        assert_eq!(one(old), "Old Name");
        assert_eq!(one(new), "New Name");
        assert_eq!(one(""), "");
        let translated = "<developer_name xml:lang=\"tr\">Eski</developer_name>";
        assert_eq!(one(&format!("{old}{translated}")), "Old Name");
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
    fn the_minimum_api_level_is_an_integer_or_zero() {
        let level = |value: &str| {
            let xml = format!(
                r#"<components><component><id>org.example.A</id><name>A</name>
                <custom><value key="x-ruya-min-api-level">{value}</value></custom></component></components>"#
            );
            parse(&xml, "/i")[0].min_api_level
        };
        assert_eq!(level("0"), 0);
        assert_eq!(level("3"), 3);
        assert_eq!(level("99"), 99);
        assert_eq!(level("-1"), 0);
        assert_eq!(level("new"), 0);
        let plain = parse(
            "<components><component><id>org.example.B</id><name>B</name></component></components>",
            "/i",
        );
        assert_eq!(plain[0].min_api_level, 0, "missing");
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
    fn every_oars_attribute_gives_its_age() {
        let rate = |id: &str, level: &str| {
            let xml = format!(
                "<components><component><id>a.b.C</id><name>C</name><content_rating type=\"oars-1.1\"><content_attribute id=\"{id}\">{level}</content_attribute></content_rating></component></components>"
            );
            parse(&xml, "/i")[0].age_rating.clone()
        };
        // (attribute, age at mild / moderate / intense)
        let table: [(&str, [&str; 3]); 26] = [
            ("violence-cartoon", ["7+", "12+", "16+"]),
            ("violence-fantasy", ["7+", "12+", "16+"]),
            ("violence-realistic", ["7+", "12+", "16+"]),
            ("violence-bloodshed", ["7+", "12+", "16+"]),
            ("violence-sexual", ["7+", "12+", "18+"]),
            ("violence-desecration", ["7+", "12+", "16+"]),
            ("violence-slavery", ["7+", "12+", "16+"]),
            ("drugs-alcohol", ["7+", "12+", "18+"]),
            ("drugs-narcotics", ["7+", "12+", "18+"]),
            ("drugs-tobacco", ["7+", "12+", "18+"]),
            ("sex-nudity", ["7+", "12+", "18+"]),
            ("sex-themes", ["7+", "12+", "18+"]),
            ("sex-homosexuality", ["7+", "12+", "18+"]),
            ("sex-prostitution", ["7+", "12+", "18+"]),
            ("sex-adultery", ["7+", "12+", "18+"]),
            ("sex-appearance", ["7+", "12+", "18+"]),
            ("language-profanity", ["7+", "12+", "16+"]),
            ("language-humor", ["7+", "12+", "16+"]),
            ("language-discrimination", ["7+", "12+", "16+"]),
            ("money-gambling", ["7+", "12+", "18+"]),
            ("money-purchasing", ["7+", "12+", "16+"]),
            ("social-chat", ["7+", "12+", "16+"]),
            ("social-audio", ["7+", "12+", "16+"]),
            ("social-contacts", ["7+", "12+", "16+"]),
            ("social-info", ["7+", "12+", "16+"]),
            ("social-location", ["7+", "12+", "16+"]),
        ];
        for (id, [mild, moderate, intense]) in table {
            assert_eq!(rate(id, "none"), "all", "{id} none");
            assert_eq!(rate(id, "mild"), mild, "{id} mild");
            assert_eq!(rate(id, "moderate"), moderate, "{id} moderate");
            assert_eq!(rate(id, "intense"), intense, "{id} intense");
        }
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

    fn keys(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn an_update_reports_the_permissions_it_adds() {
        let old = keys(&["network", "audio"]);
        // Added high-risk, and added harmless: both are reported, the shell judges the risk.
        assert_eq!(
            added_permissions(&old, &keys(&["network", "all-devices", "audio", "gamepad"])),
            ["all-devices", "gamepad"]
        );
        // Removed: nothing added.
        assert!(added_permissions(&old, &keys(&["network"])).is_empty());
        // Unchanged.
        assert!(added_permissions(&old, &old).is_empty());
        // Nothing known about the installed version: everything counts as added.
        assert_eq!(added_permissions(&[], &old), ["network", "audio"]);
        assert!(added_permissions(&old, &[]).is_empty());
    }

    const DETAIL: &str = r#"<components><component type="desktop-application">
  <id>org.example.Racer.desktop</id><name>Turbo Racer</name>
  <project_license>MIT AND CC-BY-4.0</project_license>
  <categories><category>Game</category><category>AdventureGame</category><category>LogicGame</category></categories>
  <screenshots>
    <screenshot>
      <caption>Second in the file</caption>
      <image type="thumbnail" width="224" height="126">https://x/a-224.png</image>
      <image type="thumbnail" width="624" height="351">https://x/a-624.png</image>
      <image type="thumbnail" width="1248" height="702">https://x/a-1248.png</image>
      <image type="source" width="3840" height="2160">https://x/a-4k.png</image>
    </screenshot>
    <screenshot type="default">
      <image type="source">https://x/b-src.png</image>
    </screenshot>
    <screenshot>
      <image type="thumbnail" width="200" height="100">https://x/c-200.png</image>
      <image type="thumbnail" width="1920" height="1080">https://x/c-1920.png</image>
    </screenshot>
  </screenshots>
  <releases>
    <release version="1.0.0" date="2023-05-01"><description><p>Old.</p></description></release>
    <release version="1.5.0" timestamp="1709251200">
      <description><p>Faster cars.</p><p>Fixes:</p><ul><li>Steering</li><li>Brakes</li></ul></description>
    </release>
    <release version="1.4.0" date="2024-01-15"><description><p>Mid.</p></description></release>
  </releases>
</component></components>"#;

    #[test]
    fn screenshots_pick_the_right_sizes_in_the_right_order() {
        let c = &parse(DETAIL, "/i")[0];
        let shots: Vec<_> = c
            .screenshots
            .iter()
            .map(|s| (s.image.as_str(), s.thumb.as_str(), s.caption.as_str()))
            .collect();
        assert_eq!(
            shots,
            [
                ("https://x/b-src.png", "https://x/b-src.png", ""),
                (
                    "https://x/a-1248.png",
                    "https://x/a-624.png",
                    "Second in the file"
                ),
                ("https://x/c-1920.png", "https://x/c-1920.png", ""),
            ],
            "default first; widest at most 1920 (4k source ignored); narrowest at least 400; source without widths"
        );
    }

    #[test]
    fn a_localised_image_is_not_picked() {
        let xml = "<components><component><id>org.a.B</id><screenshots><screenshot>\n            <image type=\"source\" width=\"800\">https://x/en.png</image>\n            <image type=\"source\" width=\"1200\" xml:lang=\"tr\">https://x/tr.png</image>\n            </screenshot></screenshots></component></components>";
        let shots = &parse(xml, "/i")[0].screenshots;
        assert_eq!(shots[0].image, "https://x/en.png");
    }

    #[test]
    fn at_most_ten_screenshots() {
        let mut xml = String::from("<components><component><id>org.a.B</id><screenshots>");
        for n in 0..12 {
            xml.push_str(&format!(
                "<screenshot><image type=\"source\">https://x/{n}.png</image></screenshot>"
            ));
        }
        xml.push_str("</screenshots></component></components>");
        let shots = &parse(&xml, "/i")[0].screenshots;
        assert_eq!(shots.len(), 10);
        assert_eq!(shots[9].image, "https://x/9.png");
    }

    #[test]
    fn the_newest_release_wins_whatever_the_file_order() {
        let c = &parse(DETAIL, "/i")[0];
        assert_eq!(c.version, "1.5.0");
        assert_eq!(c.release_date, 1_709_251_200);
        assert_eq!(c.description, "", "release text is not the app description");
        let by_date = "<components><component><id>org.a.B</id><releases>\
            <release version=\"1\" date=\"2024-01-15\"/><release version=\"2\" date=\"2024-03-01\"/>\
            </releases></component></components>";
        let c = &parse(by_date, "/i")[0];
        assert_eq!((c.version.as_str(), c.release_date), ("2", 1_709_251_200));
        assert_eq!(date_to_unix("2024-01-15"), 1_705_276_800);
        assert_eq!(date_to_unix("nonsense"), 0);
        let none = "<components><component><id>org.a.B</id></component></components>";
        let c = &parse(none, "/i")[0];
        assert_eq!(
            (c.version.as_str(), c.release_date, c.release_notes.as_str()),
            ("", 0, "")
        );
    }

    #[test]
    fn release_notes_are_plain_text() {
        let c = &parse(DETAIL, "/i")[0];
        assert_eq!(
            c.release_notes,
            "Faster cars.\n\nFixes:\n\n\u{2022} Steering\n\u{2022} Brakes"
        );
    }

    #[test]
    fn licence_and_categories_are_read_as_written() {
        let c = &parse(DETAIL, "/i")[0];
        assert_eq!(c.license, "MIT AND CC-BY-4.0");
        assert_eq!(c.categories, ["Game", "AdventureGame", "LogicGame"]);
    }
}
