# AppStream metadata

The AppStream file (`metainfo.xml`) is how the console knows your game's name, picture, age rating and controller support. The Store reads it, and so will parental controls. Write it once, validate it, and the same file serves Flathub.

*Checked against the code as of 2026-11-06. Items marked **planned** are not built yet.*

## The rules

- **One file** per app, installed to `/app/share/metainfo/<app-id>.metainfo.xml`, with `<component type="desktop-application">`.
- **The id** is the Flatpak app id and the name of your desktop entry without `.desktop` (see [Getting started](getting-started.md)).
- **Required** (the Store shows an app without them, badly): `<name>`, `<summary>`, `<description>`, `<developer>`, `<metadata_license>`, `<project_license>`, `<launchable type="desktop-id">`, `<content_rating>`, at least one `<release>`.
- **Games add** `<categories><category>Game</category></categories>` here, **and** `Categories=Game;` in the *desktop entry*. They are two files: the Games row of the shell reads the desktop entry, the Store reads the metainfo.
- **Say what controllers do** with `<supports><control>gamepad</control></supports>` and the `x-ruya-controller` key below.
- **Say what the game contains** with an OARS content rating. Do not leave it out (see below).
- **Only the default language** of name, summary and description is read today; translated strings (`xml:lang`) are ignored. Write the default text in English.
- Validate before every release: `appstreamcli validate --no-net <file>`. Publishing on Flathub additionally requires your screenshots and URLs to be online; `appstreamcli validate` without `--no-net` checks that.

## A complete example

This is the sample game's file (`samples/hello-game/data/org.ruyaos.HelloGame.metainfo.xml`), which passes `appstreamcli validate --no-net` (AppStream 1.1.3). The only pedantic note is that Flatpak ids contain capital letters.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!-- SPDX-License-Identifier: CC0-1.0 -->
<component type="desktop-application">
  <id>org.ruyaos.HelloGame</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>CC0-1.0</project_license>

  <name>Hello Game</name>
  <summary>Collect coins. A tiny sample game for RuyaOS</summary>
  <developer id="org.ruyaos">
    <name>RuyaOS contributors</name>
  </developer>
  <description>
    <p>Move the blue square and collect the yellow coins. Your best score is saved on the console, separately for every profile.</p>
    <p>Hello Game exists to show how a game for RuyaOS is put together: a controller or keyboard, full screen, safe saves and a clean stop. Its source is public domain: copy it and make your own game.</p>
  </description>

  <launchable type="desktop-id">org.ruyaos.HelloGame.desktop</launchable>
  <url type="homepage">https://github.com/fatihyilmaz84/ruya-os/tree/main/samples/hello-game</url>
  <url type="bugtracker">https://github.com/fatihyilmaz84/ruya-os/issues</url>

  <categories>
    <category>Game</category>
    <category>ArcadeGame</category>
  </categories>

  <supports>
    <control>gamepad</control>
    <control>keyboard</control>
  </supports>

  <content_rating type="oars-1.1">
    <content_attribute id="violence-cartoon">none</content_attribute>
    <content_attribute id="violence-fantasy">none</content_attribute>
    <content_attribute id="social-chat">none</content_attribute>
    <content_attribute id="money-purchasing">none</content_attribute>
  </content_rating>

  <screenshots>
    <screenshot type="default">
      <image type="source" width="1920" height="1080">https://raw.githubusercontent.com/fatihyilmaz84/ruya-os/main/samples/hello-game/art/screenshot.png</image>
      <caption>Collecting coins; the score is inside the safe area</caption>
    </screenshot>
  </screenshots>

  <branding>
    <color type="primary" scheme_preference="dark">#0e1224</color>
  </branding>

  <releases>
    <release version="1.0.0" date="2026-11-06">
      <description>
        <p>First release.</p>
      </description>
    </release>
  </releases>

  <custom>
    <value key="x-ruya-controller">full</value>
    <value key="x-ruya-launch-mode">fullscreen</value>
    <value key="x-ruya-hero">https://raw.githubusercontent.com/fatihyilmaz84/ruya-os/main/samples/hello-game/art/hero.png</value>
    <value key="x-ruya-logo">https://raw.githubusercontent.com/fatihyilmaz84/ruya-os/main/samples/hello-game/art/logo.png</value>
  </custom>
</component>
```

Replace the licence, the developer, the URLs and the `org.ruyaos` id with yours. The sample's licence is CC0-1.0 (see its `LICENSE`); use the SPDX id of your own licence for `<project_license>`, and CC0-1.0 or MIT for `<metadata_license>`.

## What the console reads, and what for

| Field | Used for | Status |
|---|---|---|
| `<name>`, `<summary>`, `<description>` (`<p>` and `<li>`), `<developer>` | The Store's cards and the app page. The developer is `<developer><name>`, else the older `<developer_name>` | built (`ruya-store`) |
| `<icon>` | A remote icon (`type="remote"`) or the cached icon Flatpak's appstream data holds | built |
| `<content_rating>` | The age on the app page ("All ages", "Ages 12+") | built; **limits by age: planned** (T-211) |
| `<supports>` / `<recommends>` with `<control>gamepad</control>` | Controller support, together with `x-ruya-controller` | built |
| `x-ruya-controller` | Overrides the guess from `<control>` | built |
| `x-ruya-hero`, `x-ruya-logo` | The Store's pictures | built |
| `x-ruya-launch-mode` | How the shell starts the app | **planned**: nothing reads it yet; set `fullscreen` |
| `<screenshots>`, `<releases>`, `<url>`, `<branding>` | Flathub and other stores; the console does not show them yet | not used yet |
| `x-ruya-save-paths`, `x-ruya-cache-paths` | Narrow what the backup copies ([Saves and data](saves-and-data.md)) | **planned** (T-215) |

Only apps of type `desktop-application`, `desktop`, `console-application` (or no type) are listed; runtimes and add-ons are skipped.

## Content rating (OARS) and the age limit

Use OARS 1.1, the standard for Flatpak: answer each question for your game, for example with the generator at <https://hughsie.github.io/oars/>, and paste the result. The console turns the **worst** answer into one age label:

| Worst answer | Label |
|---|---|
| all `none` | All ages |
| a `mild` | 7+ |
| a `moderate` | 12+ |
| an `intense` in `sex-*`, `drugs-*` or `violence-sexual` | 18+ |
| any other `intense` (also `money-gambling`: the code looks for an id starting with `gambling`, which OARS 1.1 does not have) | 16+ |

The label is shown on the app page ("Ages 12+"). **A game without a `<content_rating>` is shown as "All ages"; so do not skip it.** What it will do next (**planned**, T-211, T-212): a parent sets an age limit for a profile; an app above the limit does not launch and cannot be installed for that profile, and **an app with no rating counts as 18+** for restricted profiles. Rate honestly: the rating is yours, the console only applies it.

## Controller support

`x-ruya-controller` has three values: `full` (the whole game plays with a controller, menus included), `partial` (a controller works but some parts need a keyboard or mouse), `none`. The app page says "Full controller support", "Partial controller support" or "Needs a keyboard or mouse". If you leave the key out, `<control>gamepad</control>` alone counts as `partial` and no `<control>` as `none`. The Store hides apps rated `none` unless the player turns on "Show all apps". Add `<control>keyboard</control>` and `pointing` only if they are true; do not claim `gamepad` for a game that cannot be played with one.

## Art

| Key or file | What | Size |
|---|---|---|
| Icon | `share/icons/hicolor/scalable/apps/<app-id>.svg` (or 256 px PNG) | square, SVG preferred |
| `x-ruya-hero` | Key art behind the app page, 16:9 | at least 1920x1080 |
| `x-ruya-logo` | The card picture in the Store. Today it is drawn as a 16:9 picture that is cropped to fill the card, so give it a 16:9 image; the spec's separate transparent logo and tile come with the art pipeline (**planned**, spec 02 section 6) | 640x360 or more |

Both keys take a URL (`https:` or `file:`). If a picture is missing the shell draws a generated tile from the app's id and name, so nothing breaks. The Store uses the keys above today; the Games row and Home draw art for **installed** games from the library service, which carries no artwork yet (spec 03 section 5), so an installed game shows the generated tile until the art pipeline (**planned**) fills it in. All of the sample's art is in `samples/hello-game/art/`, and `art/make-art.py` shows how it was made.

## Checklist

- [ ] `appstreamcli validate --no-net` passes.
- [ ] Id, desktop-entry and metainfo file names agree; the desktop entry has `Categories=Game;`.
- [ ] `<content_rating>` is present and honest.
- [ ] `<supports><control>gamepad</control></supports>` and `x-ruya-controller` say what is true.
- [ ] `x-ruya-hero` (16:9, 1920 px or more) and `x-ruya-logo` (16:9) exist; the icon is SVG.
- [ ] The default-language text is English, complete, and the summary is one short line.

## Sources

Checked on 2026-11-06 against: `services/ruya-store/src/appstream.rs` (which fields are read, `severity` and the age label, `x-ruya-*`, `is_app`, only untranslated text); `shell/qml/AppDetailPage.qml` (`controllerText`, `ageText`) and `StorePage.qml` (`tile` and `hero` use); `docs/specs/03-services-and-apps.md` sections 4.1, 4.2, 4.5a; `docs/specs/02-shell.md` section 6; `docs/tasks/T-211-parental-controls-service.md` (planned age limit, unrated counts as 18+); `samples/hello-game/data/org.ruyaos.HelloGame.metainfo.xml` validated with `appstreamcli` 1.1.3 (`--no-net`, passes; pedantic: capital letters in the id).
