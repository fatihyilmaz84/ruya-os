# Game settings: let the player change your game's options from Ruya Hub

> **Experimental.** The file format below is public ([tier C](api-surface.md#tier-c-data-only-formats), ADR-022, ADR-035) but may change without notice until the first release. The half that carries values between your game and the console is **planned (ADR-035, Platform1)**: you cannot call it yet.

When the player opens Ruya Hub (the Guide button) your game is frozen. The Hub can then show **your game's own settings** (graphics quality, sensitivity, difficulty) in the console's look, drawn by the console and driven with a controller. You do not write any user interface: you ship **one data file** that describes your settings and, later (planned), exchange their values with the console.

The Hub always shows the panel under **your game's name and icon**, so the player knows whose settings these are, and it draws every row itself. An `action` row only **sends a message to your game** (it is a button for your game's own feature, such as "Reset to defaults"); it never calls a function of the console.

The console never trusts the file. It reads it as data, checks every limit below, and shows either all of it or nothing: a file with one mistake gives one error message and no Game entry in the Hub, never half a list. Nothing in the file is run, and a text in it is never shown as markup.

## Where the file goes

In your Flatpak, at `/app/share/ruya/settings.json`. A game without the file has no Game entry in the Hub, and nothing else changes for it.

## A complete example

This file is also `samples/game-settings-example/settings.json`, and the console's checks run on it.

```json
{
  "version": 1,
  "settings": [
    {
      "id": "graphics.quality",
      "label": { "en": "Quality preset", "tr": "Kalite ayarı" },
      "description": { "en": "Sets many graphics options at once.", "tr": "Birçok grafik seçeneğini birden ayarlar." },
      "type": "enum",
      "category": "graphics",
      "default": "high",
      "options": [
        { "value": "low", "label": { "en": "Low", "tr": "Düşük" } },
        { "value": "high", "label": { "en": "High", "tr": "Yüksek" } }
      ]
    },
    {
      "id": "graphics.shadows",
      "label": "Shadows",
      "type": "bool",
      "category": "graphics",
      "default": true
    },
    {
      "id": "graphics.shadow_distance",
      "label": "Shadow distance",
      "type": "int",
      "category": "graphics",
      "default": 50,
      "min": 10,
      "max": 100,
      "step": 10,
      "unit": "m",
      "visibleWhen": { "id": "graphics.shadows", "equals": true }
    },
    {
      "id": "graphics.textures",
      "label": "Texture detail",
      "description": "Loaded when the game starts.",
      "type": "enum",
      "category": "graphics",
      "default": "standard",
      "restart": true,
      "options": [
        { "value": "standard", "label": "Standard" },
        { "value": "high", "label": "High" }
      ]
    },
    {
      "id": "controls.sensitivity",
      "label": "Look sensitivity",
      "type": "float",
      "category": "controls",
      "default": 0.5,
      "min": 0.1,
      "max": 1,
      "step": 0.1
    },
    {
      "id": "controls.recalibrate",
      "label": "Recalibrate the sticks",
      "type": "action",
      "category": "controls"
    },
    {
      "id": "advanced.version",
      "label": "Game version",
      "type": "info",
      "category": "advanced",
      "default": "1.0.0"
    }
  ]
}
```

The file is an object with `"version": 1` and a list `settings`. The console shows the settings grouped by `category` in a fixed order, and inside a category in the order of your list.

## One setting

| Key | Required | Meaning |
|---|---|---|
| `id` | yes | `a-z`, `0-9`, `_` and `.`, 1 to 64 characters, unique in the file. This is the name your game uses for the setting when values are exchanged (planned) |
| `label` | yes | What the player reads, at most 40 characters |
| `description` | no | One line of help, at most 160 characters |
| `type` | yes | `bool`, `enum`, `int`, `float`, `action` or `info` (below) |
| `category` | yes | One of `graphics`, `display`, `controls`, `audio`, `gameplay`, `interface`, `accessibility`, `advanced`. You cannot add a category: the Hub names and orders them itself, so it never shows a heading of yours |
| `default` | by type | The value your game uses when the player has not changed it |
| `visibleWhen` | no | Show this row only while another setting has a value (below) |
| `restart` | no | `true` when a change only applies after the game restarts: the Hub tells the player "Applies after a restart of the game" |

A key that is not in this chapter is an error, so a typo is found at once.

### The six types

| Type | The Hub draws | Extra keys |
|---|---|---|
| `bool` | a switch | `default`: `true` or `false` |
| `enum` | a choice | `options`: 1 to 32 of `{ "value": "...", "label": ... }` (a value is `A-Z a-z 0-9 _ . -`, 1 to 64 characters, unique in the setting); `default` is the value of one option |
| `int` | a slider | `min`, `max` (whole numbers, `min` below `max`), `default` (from `min` to `max`), optional `step` (a whole number, 1 if absent, at most `max - min`), optional `unit` (at most 16 characters, for example `%` or `fps`) |
| `float` | a slider | the same with any numbers between -1000000000 and 1000000000; the default step is `(max - min) / 100` |
| `action` | a button | none, and no `default`. The game is told when the player presses it ("Reset to defaults", "Recalibrate"); the label is the button text |
| `info` | a read-only row | optional `default`: text (at most 40 characters) shown until your game publishes a value |

### Texts in the player's language

A `label`, `description`, option label and `info` text is either a string, or an object with one text per language: `{ "en": "Shadows", "tr": "Gölgeler" }`. The console takes the profile's language, then the language without a region (`pt-BR` falls back to `pt`), then `en`; **`en` is required** in an object. At most 16 languages. Language codes are compared without regard to case, and two keys that differ only in case (`pt-BR` and `pt-br`) are an error. A game that only speaks English can use plain strings.

### Showing a row only sometimes

```json
{
  "id": "graphics.shadow_distance",
  "visibleWhen": { "id": "graphics.shadows", "equals": true }
}
```

(Only the `visibleWhen` line is the point here; the other keys of the row are as in the example above.)

One condition and no expressions: the row is shown while the setting `id` has the value `equals`. The other setting must be in the file, must not be this one, must have a value (`bool`, `enum`, `int` or `float`, not an `action` or an `info`), and `equals` must fit it (`true`/`false`, one of the enum's values, a number). The conditions must not form a loop (A shows when B is on, B when A is on): that is an error. A hidden row keeps its value.

## Limits

| What | Limit |
|---|---|
| The file | 64 KiB (65536 bytes), UTF-8 |
| Settings | 200 |
| Options of one enum | 32 |
| `label`, option label | 40 characters |
| `description` | 160 characters |
| `unit` | 16 characters |

Texts are **plain text on one line**, and what the player reads must be what the file says. A text in any place of the file (label, description, option label, translation, unit, info text) is refused when it contains:

- a control character (a line break or a tab too), or a line or paragraph separator;
- a Unicode format character (category Cf): the bidirectional marks, embeddings, overrides and isolates (U+061C, U+200E, U+200F, U+202A to U+202E, U+2066 to U+2069), the zero-width characters (U+200B, U+200C, U+200D), the word joiner (U+2060), the soft hyphen (U+00AD), the byte order mark (U+FEFF) and the tag characters (U+E0000 and up);
- a Hangul filler (U+115F, U+1160, U+3164, U+FFA0), which draws as a blank letter;
- no visible character at all (spaces only);
- more than 3 combining marks in a row (a pile of accents);
- anything that is not valid Unicode, such as a lone surrogate.

There is no markup and no image.

## What the console checks, and what JSON Schema can check

The machine-readable format is [`api/settings/game-settings.schema.json`](../../api/settings/game-settings.schema.json) (JSON Schema 2020-12). It covers the shape, the types, the limits above and, as far as a regular expression reaches (the Basic Multilingual Plane, the combining diacritics blocks), the plain-text rule. The console also refuses what a schema cannot say: a duplicate id; an `int` or `float` whose `min` is not below `max`, whose `step` is above `max - min`, or whose default is outside `min` to `max`; an enum with a repeated option value or a default that is not an option; two language keys of one text that differ only in case (`pt-BR` and `pt-br`); a `visibleWhen` that points nowhere, at itself or in a circle; a file over the size limit; and the plain-text rule on all of Unicode (the tag characters, every combining mark, a lone surrogate). The first problem found is the message; nothing of a broken file is used, the shell logs one line with it, and the game has no Game entry in the Hub. `ruya app validate` will run both kinds of check at build time (planned, ADR-031).

You can check the shape of a file today with any JSON Schema validator, for example `check-jsonschema --schemafile api/settings/game-settings.schema.json settings.json`. The second kind of check is only in the console for now.

## Versions

The file says which format it is in: `"version": 1`.

- **A new key or a new type comes only with a new version.** Version 1 has exactly the keys and types in this chapter, and a console refuses a key it does not know.
- **A console refuses a version it does not know.** That game gets no Game entry in the Hub, and the shell logs one error naming the version. Nothing else about the game changes.
- **A console may keep reading older versions** next to the newest one it knows, so a game does not have to ship a new file for every console release.
- **Until the first release, version 1 itself may change** (this chapter is experimental). After it, a change to version 1 that is not backward compatible does not happen: it becomes version 2.
- **Planned:** `ruya app validate` (ADR-031) will report an unknown version as an error that names the versions the installed console reads.

## Values and changes (planned)

**Planned (ADR-035, Platform1):** your game sends its current values when it starts and when it changes one itself. While the Hub is open the player's changes are collected, and when the player presses Resume your game is thawed and told **once** which values were changed. Your game applies what it can and answers which it took and which it refused (with a reason of up to 60 characters, shown as a message), and it may mark a row unavailable ("Needs ray tracing hardware"). None of this exists yet.

What already holds, so you can design for it:

- **Your game owns its settings.** The console keeps no copy: store the values in your own `config/` ([Saves and data](saves-and-data.md)), where a console backup also finds them.
- **The file is a hint, not a guarantee.** The player's changes arrive as data; check every value again (type, range, option) before you use it.
- **A change reaches you on Resume, not live.** Do not expect it while frozen.

## Trying it without a game

The shell's development build (Windows, or Linux with `RUYA_SERVICES=mock`) carries a **mock game**, *Turbo Racer* (`org.example.Racer`), with a settings file of 18 rows that uses every type, a `visibleWhen`, a `restart` row and published values (`shell/src/gamesettings/mock-game-settings.json`). It is what the Hub's Game panel is built against, and a good second example.

## Checklist

- [ ] The file is at `/app/share/ruya/settings.json`, UTF-8, under 64 KiB.
- [ ] `"version": 1`; every `id` is unique and matches `[a-z0-9_.]{1,64}`.
- [ ] Every `category` is one of the eight; every `default` is a valid value of its type.
- [ ] Texts are plain text within the limits; an object of texts has `en`.
- [ ] Each `visibleWhen` names another setting that has a value.
- [ ] Your game checks a change again before it applies it.

## Sources

Checked on 2026-11-13 against: `docs/specs/00-overview.md` ADR-035 and ADR-022; `docs/archive/research/system-dialogs-and-game-settings-proposal.md` part 2.3; `api/settings/game-settings.schema.json`; `shell/src/gamesettings/GameSettingsSchema.cpp` (the limits, the plain-text rule, `visibleWhen`); `samples/game-settings-example/settings.json` (identical to the example above); `scripts/check-game-settings-schema.py` (the schema accepts the example and the mock game's file and refuses the bad cases); `shell/tests/tst_game_settings_schema.qml`.
