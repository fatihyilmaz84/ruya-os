# Play packages (`.play`)

How to package a game as a `.play`: one folder or one `.play.zip` that holds the game, what it runs on, its art, a permission request and a signature, so a player can copy it to a USB stick and install it with a controller. The short version: **run `ruya-pack init`, put your game in `payload/`, list your art and permissions in `play.json`, run `ruya-pack build`, then `keygen` and `sign`. `ruya-pack validate` tells you what the console will say, before the console does.**

*Checked against the code and specs as of 2026-11-18. Items marked **planned** are not built yet.*

**What exists today, and what does not.** The format, the verifier and the developer tool (`ruya-pack`) are built and tested; the shell has an "Install from USB" page that shows a package (on its mock backend). The service that installs a package on a console is built (`ruya-play`, `org.ruyaos.Play1`, RUY-829): it inspects and unpacks a package in an unprivileged sandbox without network, checks it again as root and installs it as the system Flatpak app `play.<your id>`; its first run on a real console image is still being checked (RUY-100). The launcher that runs the installed game (**planned: RUY-101**) is not built, so an installed package does not start yet. So this chapter can take you from an empty folder to a signed package that the console verifies and installs, but not yet to "it runs on my console". Where a step needs the unbuilt part it says **planned**.

**Your package gets exactly the permissions it asks for, under its trust tier's ceiling (RUY-851).** The console writes the sandbox from the closed vocabulary below and nothing else: every game gets IPC, the display (Wayland, or X11 for the `wine` and `proton` runners), sound (PulseAudio) and the GPU (`dri`), and each permission you ask for adds its own lines (for example `network: true` adds the network). Nothing in `run.env`, `reasons` or a field of your own can add a sandbox permission. *Verified on the host; the check on a console (`flatpak info --show-permissions`) is pending.*

## What a package is, and is not

A `.play` is a **container for a Flatpak app plus art and policy**. The console unpacks it into its own Flatpak sandbox under the id `play.<your id>`; the sandbox is the security boundary, not the package and not Wine.

| | Flatpak (the [Getting started](getting-started.md) route) | `.play` |
|---|---|---|
| What you ship | a Flatpak built with `flatpak-builder` against a runtime | a folder or zip with your files, no build step on the console |
| Windows games | you build and bundle Wine yourself | the manifest names a runner (`wine`, `proton`) and where it comes from |
| Distribution | Flathub, the `ruyaos` remote, your own repository | a file: USB stick, a download, later a store |
| Art, controller and age data | AppStream metadata | `play.json` (same ideas, one file) |
| Permissions | Flatpak permissions, shown as "High risk" when broad | a **closed list** (below); anything not in it cannot be asked for |
| Updates | the Store | the Store, a signed feed you host, or by hand (planned) |

A `.play` is **not** an installer: installing runs nothing from the package. No script, hook or "setup.exe" runs when the player presses Install. The only code that ever runs from a package runs at launch, inside the sandbox, as the player's profile user. It is also not a new runtime or a new sandbox, and it cannot ask for the host filesystem, the session bus or a portal override. If your app needs those, it is a Flatpak ([Publishing](publishing.md)).

## From an empty folder to a signed package

Every command below is real `ruya-pack` output as of the date above. Build the tool with `cargo build -p ruya-pack` in `services/` (it is one binary; there is no installer yet).

```sh
ruya-pack init mygame --id com.example.mygame --name "My Game"
```

`init` writes `play.json`, a `README.txt` that explains it (JSON has no comments), `art/icon.png` (a 64x64 **placeholder**), and `payload/run.sh`. Now:

1. Copy your game into `payload/` and change `run.command` in `play.json` to start it.
2. Replace `art/icon.png` with your own **512x512 or larger, square** image. Until you do, the tool says `art.too_small`.
3. Edit the rest of `play.json` (the [field reference](#field-reference) lists every field).

```sh
ruya-pack build mygame -o mygame.play.zip
```

`build` writes `play.files` (the sorted list of every file with its SHA-256), builds a deterministic zip (the same input gives the same bytes) and then validates it. Run it again after every edit; a package validated before `build` fails with `package.no_table` because the list does not exist yet.

```sh
ruya-pack keygen mykey
ruya-pack sign mygame.play.zip --key mykey.key
ruya-pack validate mygame.play.zip
ruya-pack inspect mygame.play.zip
```

`keygen` writes `mykey.key` (secret) and `mykey.pub` and prints the key id. `sign` writes `play.sig` into the zip and checks it with the console's own verifier before saving. `validate` is the full check; `inspect` prints what the console will show the player: the signer and tier, the permissions in plain words, the size and the runner. The last lines of a good run read:

```text
signed com.example.mygame build 1 with key f95fe7ef9e0e86e3b7dca9d0720c30f9
com.example.mygame 0.1.0 (build 1): 4 files, 1 MB installed
ok: the package passes every check that runs off the device
```

Every command takes `--json` for a machine-readable result (`{ "schema": 1, "ok": ..., "problems": [ { "code", "path", "message", "fix" } ], "warnings": [...] }`) and the exit code is `0` ok, `1` problems found, `2` usage, `3` I/O. Warnings never change the exit code. `ruya-pack` links the same crates the console verifies with, so **a package the tool accepts is a package the console's verifier accepts**.

## Layout

```text
Star Hopper.play/
  play.json       the manifest (required, at most 1 MiB)
  play.files      the file table: every file with its size and SHA-256 (written by ruya-pack build)
  play.sig        your signature (written by ruya-pack sign)
  art/            icon, hero and the other art
  payload/        the game, any layout
  components/     a bundled runner, such as components/wine/ (optional)
  licences/       licence texts and source offers for bundled third-party code
  README.txt      optional
```

- A package holds **only regular files and folders**. A symlink, hard link, device or FIFO makes it invalid (USB sticks formatted exFAT or FAT have none). If your game needs links, `ruya-pack build --links-as-data` records a relative link that stays inside the same top-level folder as data, and the console recreates it.
- The top-level names `.ref`, `launcher` and `share` are the console's: a package may not have them at its top (the folder or anything below it; `table.reserved_top_level`). `payload/share/` is fine.
- Names are relative, use `/`, and must stay unique even when letter case is ignored (exFAT and Wine). `build` tells you which two files collide.
- A file of 4 GiB or more cannot be copied to a FAT32 stick. `build` warns (`size.fat32`); tell your players to use exFAT.
- The executable bit is recorded in `play.files`. On Windows, `build` marks a file that starts with `#!` or an ELF header, or one you name with `--exec payload/start`.

## An example

This is the manifest of the native sample ([`samples/hello-play-native/`](../../samples/hello-play-native/README.md)), which the checks below run on:

```json
{
  "format": 1,
  "id": "org.example.helloplaynative",
  "name": { "en": "Hello Play Native" },
  "version": "1.0.0",
  "build": 1,
  "summary": { "en": "A tiny native Linux game packaged as a .play." },
  "description": { "en": "Move a square, collect coins, keep the best score.\n\nThe sample for the .play developer guide: a native game with a controller, saves and no permissions beyond input." },
  "developer": { "name": "RuyaOS contributors" },
  "release_date": "2026-11-17",
  "genres": ["arcade"],
  "tags": ["sample"],
  "languages": ["en"],
  "players": { "min": 1, "max": 1, "modes": ["single"] },
  "controller": "full",
  "licence": { "package": "CC0-1.0" },
  "requirements": { "arch": "x86_64", "min_ram_mb": 512 },
  "art": { "icon": "art/icon.png", "hero": "art/hero.png" },
  "run": {
    "runner": "native",
    "command": ["${payload}/hello-game"],
    "cwd": "${payload}",
    "launch_mode": "fullscreen"
  },
  "permissions": {
    "network": false,
    "input": "controllers+keyboard-mouse"
  },
  "data": { "saves": ["data:saves"] }
}
```

Every JSON block in this chapter that is a whole manifest is checked against [`api/play/play.schema.json`](../../api/play/play.schema.json) by `scripts\lint-dev-docs.ps1`. The schema states shapes, vocabularies and numbers; `ruya-pack validate` applies the rules a schema cannot (the file table, path rules, that the files you name exist, reserved ids and names).

## Field reference

Required: `format`, `id`, `name`, `version`, `build`, `art` and `run` (with `art.icon`). Text is **plain text**: no markup, no links in the text, no control or invisible characters (they are refused, not stripped). A "localized" field is a map of BCP-47 language tags to text and must have `"en"`. Unknown keys are ignored, **except** under `permissions`, `run` and `components`, where an unknown key is an error. A key named twice is an error (`json.duplicate_key`). The list of fields below is compared with the schema by a test (`services/ruya-pack/tests/guide.rs`), so it cannot drift.

| Field | Rule |
|---|---|
| `format` | The major version of the format: `1`. A console that does not know it says "needs a newer RuyaOS". |
| `id` | Reverse-DNS, at least three parts, letters, digits, `_` and `-`, no part starting with a digit, at most 120 bytes. `play.<id>` must be a valid Flatpak id, so `-` is allowed only in the **last** part. Not `org.ruyaos.` or `play.` (reserved). It is the identity of your app for ever; a changed id is a different app. |
| `name` | Localized, at most 60 characters. A name that looks like a system name (Settings, RuyaOS, Store, Home, Guide, Update) is refused. |
| `version` | Display text, at most 32 characters. |
| `build` | A positive integer that **only increases**. Update order uses it, not `version`. |
| `summary` | Localized, at most 140 characters. |
| `description` | Localized, at most 4000 characters; a blank line separates paragraphs. |
| `developer` | `name` (at most 80 characters) and an optional https `url`. Self-asserted: shown next to the signature, never as proof. |
| `developer.name` | The display name. |
| `developer.url` | An `https://` address. |
| `publisher` | Same shape as `developer`. |
| `publisher.name` | The display name. |
| `publisher.url` | An `https://` address. |
| `release_date` | `YYYY-MM-DD`. |
| `genres` | At most 4 from a closed list (action, adventure, arcade, platformer, puzzle, racing, role-playing, shooter, simulation, sports, strategy, fighting, music, party, family, sandbox, horror, visual-novel, retro, utility, other). The first sets the tile colour. |
| `tags` | At most 12 free tags of at most 24 characters. |
| `languages` | At most 30 language tags the game supports. |
| `players` | How many play: `min`, `max` (1 to 64) and `modes`. |
| `players.min` | The fewest players. Required when `players` is present. |
| `players.max` | The most players. Required when `players` is present. |
| `players.modes` | Any of `single`, `local`, `online`. |
| `controller` | `full`, `partial` or `none`: the same meaning as `x-ruya-controller` ([Controller input](controller-input.md)). The Store's gamepad filter reads it. |
| `age_rating` | OARS 1.1 content answers, as in AppStream ([AppStream metadata](appstream-metadata.md)). Missing means "Not rated", never "All ages". |
| `age_rating.scheme` | Always `oars-1.1`. Required when `age_rating` is present. |
| `age_rating.content` | A map of OARS attribute to level, for example `"violence-cartoon": "mild"`. |
| `licence` | The licence of the package contents. |
| `licence.package` | An SPDX id, or `LicenseRef-proprietary`. |
| `licence.terms_url` | An `https://` address of your terms. |
| `links` | At most 12. The console shows them as text and a QR code and never opens them. |
| `links[].kind` | One of `homepage`, `support`, `manual`, `source`, `community`, `store`, `privacy`, `changelog`, `donate`, `other`. |
| `links[].url` | `https://` only. |
| `requirements` | Facts for the "can this run here" check. The installed size is **computed** from `play.files`; do not declare it. |
| `requirements.arch` | `x86_64` (the only value in format 1). |
| `requirements.min_ram_mb` | Memory the game needs, in MB. |
| `requirements.gpu_api` | `vulkan` and/or `opengl`. |
| `art` | The art slots; see [Artwork](#artwork). |
| `art.icon` | Required. Path under `art/`, PNG or WebP. |
| `art.logo` | Optional title logo: one path, or a map from language tag to path (a different logo per language, at most 30). |
| `art.hero` | The big 16:9 picture. Needed to be placed on Home. |
| `art.cover` | Optional 2:3 poster. |
| `art.screenshots` | Optional; when present, 1 to 20 screenshots (an empty list is `art.no_screenshots`). |
| `art.screenshots[].file` | A path under `art/`. |
| `art.screenshots[].caption` | Localized, at most 100 characters. |
| `art.trailer` | Optional video. |
| `art.trailer.file` | WebM or MP4 under `art/`. |
| `art.trailer.poster` | A 16:9 still for the trailer. |
| `art.preview` | Optional muted loop for the Home hero, no audio track. |
| `components` | The runners your game needs (at most 16); see [Choosing a runner](#choosing-a-runner-source). |
| `components[].id` | Your name for it (lower case, at most 32 bytes); `run.component` refers to it. |
| `components[].type` | `wine`, `proton`, `emulator` or `engine`. |
| `components[].source` | Where the runner comes from: `bundled`, `system`, `prefer-system`, `prefer-bundled` or `newest`. |
| `components[].min` | The lowest version you accept (needed for `system`, `prefer-system`, `newest`). |
| `components[].tested` | The version you tested; shown to the player, not enforced. |
| `components[].max_major` | Optional: skip a system runner of a higher major version. Enforced. |
| `components[].bundled` | Describes the runner you ship in the package. |
| `components[].bundled.path` | Where it lives, under `components/`. |
| `components[].bundled.version` | Its version. |
| `components[].bundled.licence` | Its SPDX licence. |
| `components[].bundled.source_url` | Where its source can be downloaded (required for copyleft licences). |
| `run` | How to start. Exactly one per package. |
| `run.runner` | `native`, `wine`, `proton`, `emulator` or `engine`. |
| `run.component` | The `id` of the component that runs it (not for `native`). |
| `run.command` | An **argument list**, never a shell string. Placeholders: `${payload}`, `${component:<id>}`, `${data}`, `${config}`, `${prefix}`, `${disc}`. |
| `run.cwd` | Working directory, usually `${payload}`. Must start with a placeholder (`${payload}`, `${data}`, `${config}`, `${prefix}` or `${component:<id>}`), optionally followed by `/` and a path without `..`. |
| `run.env` | Extra environment variables. A deny list applies: the variables the platform sets (`PATH`, `HOME`, `WINEPREFIX`, `LD_*`, `XDG_*`, `SDL_*`, ...) are refused with `env.reserved`; `WINEDLLOVERRIDES`, `DXVK_*` and `PROTON_*` pass. Names match `[A-Z][A-Z0-9_]*` (at most 64 characters), values are at most 1024 bytes without control characters, at most 64 variables. The full deny list is `PATH`, `HOME`, `DISPLAY`, `XAUTHORITY`, `WINEPREFIX`, `WINESERVER`, `WINELOADER`, `WINEDLLPATH`, `WINEARCH`, `TMPDIR`, `GCONV_PATH`, `LOCPATH`, `NLSPATH` and every name starting `LD_`, `XDG_`, `FLATPAK_`, `DBUS_`, `WAYLAND_`, `PULSE_`, `PIPEWIRE_`, `SDL_`, `STEAM_COMPAT_`, `PRESSURE_VESSEL_`, `VK_`, `MESA_`, `LIBGL_`, `GST_`, `QT_`, `GTK_`, `GDK_`, `GIO_` or `RUYA_`. |
| `run.launch_mode` | `fullscreen` (default), `gamescope` or `default`. |
| `run.prefix` | The Wine prefix settings (Windows runners). |
| `run.prefix.arch` | `win32` or `win64`. |
| `run.prefix.template` | A prefix you ship, copied on first run. Must not contain a folder named `dosdevices`. |
| `run.prefix.epoch` | An integer you raise when an update needs a fresh prefix; the console backs up `data.saves`, rebuilds the prefix and restores them. |
| `run.setup` | First-run steps, at most 16; see [Wine prefix and saves](#wine-prefix-and-saves). |
| `run.setup[].id` | A name for the step. |
| `run.setup[].command` | An argument list, like `run.command`. |
| `run.setup[].once` | `true`: run once per prefix. |
| `run.discs` | Ordered disc images, for emulated games; at most 16, no repeats, each starting with `payload/`; `${disc}` is the first. |
| `permissions` | What you ask for; see [Permissions](#permissions-and-what-each-costs-the-player). |
| `permissions.network` | `true` or `false` (default `false`). |
| `permissions.input` | `controllers`, `controllers+keyboard-mouse` (default) or `all-devices`. |
| `permissions.removable_media` | `none` (default), `read` or `write`. |
| `permissions.multiarch` | `true` for 32-bit Windows programs. |
| `permissions.gamemode` | `true` to ask the system to prioritise the game. |
| `permissions.realtime` | `true`, same effect as `gamemode`. |
| `permissions.devel` | `true` to allow ptrace (rare anti-tamper). High risk. |
| `permissions.reasons` | A map of permission key to a short localized reason (at most 120 characters), shown next to it. |
| `data` | Where your saves are, for backup. |
| `data.saves` | Up to 32 paths with a root name: `data:` (your `$XDG_DATA_HOME`), `config:`, or `prefix:` (inside the Wine prefix). Each is at most 1030 bytes and has no `..` or `.` part and no `\`. |
| `data.cache` | The same rules, for things that can be rebuilt (never backed up). |
| `update` | (planned) A self-hosted feed; see [Updates](#updates). |
| `update.feed` | The https address of your signed feed. |
| `update.channel` | A channel name, for example `stable`. |

## Artwork

The art slots are the contract between you and the shell. The shell never shows a raw file: the importer decodes each image in a helper, checks size and shape, strips metadata, converts to sRGB and re-encodes it. A **broken** `icon` or `hero` refuses the package; a missing optional slot just uses the generated tile.

| Slot | Format and size | Used for |
|---|---|---|
| `icon` | PNG or WebP, **square**, 1024x1024 recommended, 512x512 at least, RGBA, at most 2 MB. Full bleed: the shell rounds the corners itself, so do not pre-round. | Library rows, Store, toasts. **Required.** |
| `logo` | PNG or WebP with transparency, at least 256 px high, at most 4:1 wide, light colours, at most 2 MB. | The Home hero title. Optional (your `name` is used as text). |
| `hero` | WebP, JPEG or PNG, **16:9** (within 1 %), 3840x2160 recommended, 1920x1080 at least, at most 8 MB. | Home hero, the 16:9 card, the launch splash, the page backdrop. |
| `cover` | WebP, JPEG or PNG, **2:3**, 1200x1800 recommended, 600x900 at least, at most 4 MB. | The Library grid. |
| `screenshots[]` | 16:9, at least 1280x720, at most 4 MB each, 1 to 20. | The detail page. |
| `trailer` | WebM (VP9 or AV1, Opus) or MP4 (H.264, AAC), at most 120 s, 1080p60, 80 MB; plus a 16:9 `poster`. | The detail page. |
| `preview` | WebM or MP4 **without audio**, at most 15 s, 720p30, 8 MB. | A muted loop on the Home hero. |

No animated images (GIF, APNG, animated WebP), no SVG, no EXIF (it is stripped). A colour profile is converted to sRGB and dropped; one that cannot be read, or is not RGB, is refused (`art.colour_profile`). A store-bound package carries no ads, price, rating or "buy now" in its art or text.

### Composing the hero

The shell lays text and cards over the hero. Keep the subject where nothing covers it:

```text
+-----------------------------------------------------------+  top
| title block   |                                           |
| and a dark    |      KEEP THE IMPORTANT PICTURE HERE      |
| scrim cover   |      right two thirds,                    |
| the LEFT      |      upper three quarters                 |
| THIRD         |                                           |
|               |                                           |
+-----------------------------------------------------------+  3/4 down
| the row of cards covers the BOTTOM QUARTER                |
+-----------------------------------------------------------+  bottom
 0            1/3                                         1
```

- Put faces, logos and the focal object in the right two thirds and above the bottom quarter.
- Make the left third and the bottom quarter quiet: sky, ground, blur. Detail there is covered anyway.
- Draw for 3840x2160 but check at 1920x1080; the console writes both sizes and never upscales.
- Leave the title out of the hero if you give a `logo`: the shell puts the logo on top.

### The icon safe area

The icon is used from 128 px up to 512 px and masked to a rounded square. Keep the subject inside the **centre 80 %** (for 1024x1024, inside the square from 102 to 922) and let the background run to the edges.

The two samples carry art made by a script (`make-art.py` in each sample, Python standard library only, public domain), so you can copy a file that is known to pass.

## Choosing a runner source

`native` games need no component. A Windows game names a component of `type: wine` or `proton`, and `source` says where that runner comes from. It is a size against compatibility choice:

| `source` | The player gets | Size cost | Compatibility | Needs |
|---|---|---|---|---|
| `bundled` | only your copy, always | big (a Wine is typically hundreds of megabytes) | the one you tested, never changes | `bundled` block |
| `system` | only the OS's runner of that type, at least `min` | none | follows the OS: fixes arrive, so can regressions | `min` |
| `prefer-system` | the OS's runner if present and at least `min`, else your copy | big (the fallback is shipped) | OS fixes when safe | `min` and `bundled` |
| `prefer-bundled` | your copy, unless the player picks the system one in the game's Compatibility setting | big | yours by default | `bundled` |
| `newest` | whichever of yours and the OS's has the higher version (a tie goes to yours) | big | "my tested Wine, or the OS's if it is newer" | `min` and `bundled` |

- `tested` is the version you verified. It is shown ("Tested with Wine 9.20; running with 10.2") and **not enforced**. `max_major` is enforced: a system runner with a higher major version is skipped, which fences off a version you know breaks your game.
- Versions are compared only inside one family (`wine`, `proton`, `proton-ge`, one per emulator). A bundled Valve Proton is never replaced by the OS's GE-Proton. For `source: system`, a `type: proton` component means the OS's GE-Proton.
- Wine regressions are real: a game tested on 9.20 may break on 10.x. The more you trust the OS, the smaller your package; the player can always choose "Package default", "Bundled" or "System" in the game's Compatibility setting (**planned**: the screen is part of the launcher, RUY-101).
- `ruya-pack validate --system-wine 10.2` (and `--system-proton-ge`, `--system-runner family=version`) dry-runs the choice against the runners you name, with the console's own resolution code. A component whose family you did not name is skipped, and a `resolve.not_checked` warning says so.

The Wine sample uses `source: system` so that no Wine has to be committed to git. A manifest that bundles Wine and takes the OS's when it is newer looks like this (the files under `components/wine/` are yours to add, with a licence text under `licences/`):

```json
{
  "format": 1,
  "id": "com.example.starhopper",
  "name": { "en": "Star Hopper" },
  "version": "1.4.2",
  "build": 142,
  "art": { "icon": "art/icon.png", "hero": "art/hero.webp" },
  "components": [
    {
      "id": "wine",
      "type": "wine",
      "source": "newest",
      "min": "9.0",
      "tested": "9.20",
      "bundled": {
        "path": "components/wine",
        "version": "9.20",
        "licence": "LGPL-2.1-or-later",
        "source_url": "https://dl.winehq.org/wine/source/"
      }
    }
  ],
  "run": {
    "runner": "wine",
    "component": "wine",
    "command": ["${payload}/StarHopper.exe", "-fullscreen"],
    "cwd": "${payload}",
    "env": { "WINEDLLOVERRIDES": "dinput8=n,b" },
    "prefix": { "arch": "win64", "epoch": 1 }
  },
  "permissions": { "input": "controllers+keyboard-mouse", "multiarch": true },
  "data": { "saves": ["prefix:drive_c/users/steamuser/Documents/Star Hopper"] }
}
```

### The bundled runner's `runner.json`

*Experimental (ADR-037): the format may change before the first release.* A bundled runner may carry a `runner.json` at the root of its folder, here `components/wine/runner.json`. It tells the console the runner's family (versions are compared only inside one family), its version and the programs it is started through. It is checked against [`api/play/runner.schema.json`](../../api/play/runner.schema.json):

```json
{
  "format": 1,
  "family": "wine",
  "kind": "wine",
  "version": "9.20",
  "arch": "x86_64",
  "entry": { "wine": "bin/wine", "wineserver": "bin/wineserver" },
  "capabilities": ["multiarch", "dxvk"],
  "licence": "LGPL-2.1-or-later",
  "source_url": "https://dl.winehq.org/wine/source/"
}
```

- `kind` must be the component's `type`. `entry` names files of the runner's folder, as regular files and not links: `wine` and `wineserver` for Wine, `proton` for Proton (`{"proton": "proton"}`), and nothing for an emulator or engine, whose `run.command` names `${component:<id>}` itself.
- `version` holds a number, compared like the versions in `components` (`GE-Proton10-9` is 10, 9). `capabilities` (`multiarch`, `dxvk`, `vkd3d`, `ntsync`) are informational for now.
- **Leave the file out** and the console uses the defaults of the type: family `wine` or `proton` (an emulator's or engine's family is its component id), entries `bin/wine` and `bin/wineserver`, or `proton`. A bundled Proton without the file is Valve's `proton`, so the OS's GE-Proton never replaces it; declare `"family": "proton-ge"` if you bundle GE-Proton.
- **A file that is there must be valid.** `ruya-pack validate` and the console refuse the package with a `runner.*` code (listed in the catalogue below) instead of falling back to the defaults. Every key must be one of the nine above.

## Wine prefix and saves

A Windows game keeps its saves in a Wine **prefix**, a fake `C:` drive. The console creates one **per profile and per game** in the player's data directory (`~/.var/app/play.<id>/data/prefix`; for a Proton runner `~/.var/app/play.<id>/data/proton/pfx`), from `run.prefix.template` if you ship one, else fresh. **The console owns `WINEPREFIX`**: setting it in `run.env` is refused, because a prefix put in `/tmp` would vanish when the game exits, saves included.

- **Saves paths** in `data.saves` start with a root name. For a Windows game write `prefix:` and the path inside the prefix, for example `prefix:drive_c/users/steamuser/Documents/Hello Play`. The sample's program writes to `Documents\Hello Play` and the manifest lists that folder, so the console can back it up and keep it across a prefix rebuild. The user folder is `steamuser` for the Proton-style runners; check the folder your runner creates when you can run the game on a console (**planned**, RUY-101). A native game writes to `$XDG_DATA_HOME` and lists `data:saves` ([Saves and data](saves-and-data.md)).
- **`run.prefix.epoch`** is a whole number. When an update raises it, the first launch backs up `data.saves`, recreates the prefix, and restores them. Raise it only when a new runner or a new redistributable needs a clean prefix.
- **First-run setup** (`run.setup[]`) runs commands such as a Visual C++ redistributable **once per prefix, at the first launch, inside the sandbox with the game's own permissions**; never at install time and never as root. They show on the launch splash and time out after 10 minutes; a failed step is reported, not ignored. There is **no network** at setup (no `winetricks` downloads): ship the redistributable in the package. The sample's step, `setup.exe`, does nothing and exits `0`, to show the field.
- Under Wine the `Z:` drive is the sandbox's root, not the host's. The Flatpak sandbox limits files, not Wine's drive mapping.
- **32-bit Windows programs** need `"multiarch": true` (below); without it the sandbox kills them.
- Windows packages show through X11 on the console's compositor; you do not need to do anything for it.

## Permissions and what each costs the player

The vocabulary is closed and static: you **request**, the shell shows each entry in plain words before install, and the effective set is your request **capped by how far the package is trusted**. An update that adds one is shown as "The update adds ..." and a high-risk one needs the admin's PIN.

| Key | Values | What the player reads | Risk | The cost to you |
|---|---|---|---|---|
| (always) | | "Plays sound, uses graphics" | low | none |
| `input` | `controllers`, `controllers+keyboard-mouse` (default), `all-devices` | "Uses controllers" / "Uses controllers, keyboard and mouse" / "Accesses all devices" | low, low, **high** | `all-devices` makes the install need the admin's PIN with a warning, and an unsigned package with it cannot be installed at all |
| `network` | `false` (default), `true` | "Uses the network" | medium | players see it; do not ask unless the game goes online |
| `removable_media` | `none` (default), `read`, `write` | "Reads files on USB drives" / "Changes files on USB drives" | medium | `network` together with `removable_media` counts as **high** |
| `multiarch` | bool | "Runs 32-bit programs" | medium | only for 32-bit Windows code |
| `gamemode`, `realtime` | bool | "Asks the system to prioritise it" | low | none |
| `devel` | bool | "Can inspect other programs" | **high** | only for rare anti-tamper code; expect the admin gate |

`microphone`, `camera` and `bluetooth` are **not in the vocabulary yet**: a package that asks is refused with `permissions.unknown_key`. There is no host filesystem access, no bus name and no `--talk-name` to ask for.

By trust tier: a `developer` (signed) package gets low and medium freely, and high with the admin's PIN and a warning; an `unverified` (unsigned) package gets low and medium only, and a high request makes it uninstallable (`ceiling.refused`), not quietly reduced. `permissions.reasons` lets you put a short sentence next to a permission; the shell does not show it yet (RUY-803, RUY-805). Ask for the least you need: the page the player sees is the whole of your pitch.

## Signing and keys

A signature proves that **the same key signed this**, not who you are. The console shows "Signed by Example Games, key 3f9a..." and never "verified publisher" (only the Official store's own countersignature earns more). Signing is Ed25519 in a small format of our own, made and checked by `ruya-pack`; you need no other tool.

- `ruya-pack keygen mykey` writes `mykey.key` (the secret) and `mykey.pub`. `sign` reads the key from `--key <file>` or from the environment variable `RUYA_PACK_KEY` (the base64 line from the file). **No option takes the key text itself**, so it never lands in your shell history, and the key appears in no output.
- **Never commit a key.** Not to the repository of your game, not to CI logs. Keep it on your machine and in a backup. In CI, put it in the CI's secret store and pass `RUYA_PACK_KEY`. The sample folders git-ignore `*.key`.
- One signature covers the **whole package**: `play.sig` signs the hash of `play.json` and `play.files`, and `play.files` lists every other file's hash. Change any file and the console says "This package was changed after it was signed" (`sig.*`, `package.hash_mismatch`): run `build` and `sign` again. A `play.sig` left in the folder is not built into the new zip (the warning `build.signature_dropped`), because `play.files` was just rewritten.
- **Continuity.** The console keeps, per id, the key that owns it (trust on first use). Every later install or update of that id must be signed by the **same key**, and an unsigned package for a signed id is refused. A different key gets "This isn't the same developer".
- **Rotation.** To move to a new key, sign the next build with the new key and the old one: `ruya-pack sign game.play.zip --key new.key --rotate-from old.key`. The package carries a statement signed by the old key that hands the id to the new one; the console follows the chain from the key it knows. Rotations are numbered, a replayed one is refused, and a retired key stays retired.
- **If you lose the key you cannot rotate.** The player or an admin has to use "Forget this game's data and key" and install the package signed with the new key. Back the key up.
- **If the key is stolen or leaked** (not only lost), act at once while you still hold it: sign a new build with the new key and `--rotate-from` the old one, so players follow the chain, and report the old key id so it can go on the revocation list, the `[packages]` blocklist (a console then refuses the key with `revoked.key`). Until you rotate, whoever has the key can sign packages the console accepts as yours.
- `--rotate-from` takes a key **file** only, never key text, like `--key`.
- **On Windows the key file gets no 0600 protection** (that is a Unix file mode). Keep it in a folder only you can read, not in a synced or shared folder.
- **Read the `build.signature_dropped` warning before you ship.** `build` leaves `play.sig` out, so a package you forget to sign again counts as `unverified` on the console (developer mode only, and high-risk permissions refused).
- The console records `signed_at` (the date `sign` ran, or `--signed-at` for reproducible builds) but never uses it to decide trust.

## Updates

Updates are ordered by `build`, signed, and run by the OS, never by the game. **None of this is built into a console yet**; the rules are the design:

1. **From a store** (recommended for public games): the store updates it like any app; the `update` block is ignored. Store-installed packages never contact your server.
2. **A feed you host** (for packages that are sideloaded): `update.feed` is an https address of a signed JSON feed; the signature must come from the same key as the installed package (or a rotation), the feed must not be expired, and only a higher `build` is offered. The download is verified and imported exactly like an install. **Privacy:** checking your server tells it the console's IP and the game, so the console asks the player once ("This game can check example.com for updates. Allow?", default **No**) and checks only when idle and online.
3. **By hand:** the player installs a newer `.play` over the old one. The same key rule applies, and the saves stay.

An update never runs while the game is running, and never adds a permission silently.

## Legal duties for what you bundle

RuyaOS ships and hosts **no** emulators, Proton or Steam runtime, console firmware, BIOS files, discs or ROMs. **You are the distributor of everything you put in a package** and must have the right to distribute it. A game that needs a Windows runner can use the OS's Wine (`source: system`), which costs you nothing and needs no licence work.

If you bundle third-party code (Wine, Proton, an emulator), `ruya-pack validate` checks your duty:

- the component names an SPDX `licence`;
- a licence text is under `licences/`, with a path or file name that names the component or the licence (`licences/wine-LGPL-2.1.txt`; not a substring match: `licences/Wine/COPYING` works);
- for copyleft licences (GPL, LGPL, AGPL, MPL, EPL, CDDL and others) a `bundled.source_url` or the source itself under `sources/`.

The codes are `licence.text_missing` and `licence.source_missing`. Anti-cheat titles that block Linux remain unsupported. The age rating is your own answer to the OARS questions; an unreviewed package's rating is labelled "Developer's rating".

## Testing on a console

**Partly built: installing works through `ruya-play` (RUY-829, being checked on a console image under RUY-100); running the game is planned (RUY-101).** What you can do today:

1. `ruya-pack validate`, `inspect` and (for Windows runners) `validate --system-wine <version>` run the console's verifier and resolution off the device. Most failures are found here.
2. The shell's "Install from USB" page (Store toolbar and Settings, Storage) lists packages on a mounted drive and shows one as a game page: trust badge, signer, permissions in plain words, size. Off the console it runs against the mock backend; on a console it talks to `ruya-play`.
3. A Standard profile needs an admin's PIN for every USB install; an admin installs directly.
4. Developer mode is a switch in Settings, System (admins only). It lets an **unsigned** package install; a signed package does not need it.

Planned: starting the game, the launch splash and the Compatibility screen, and `ruya-pack run`. The permissions your manifest asks for are granted at install (above); the shell's PIN prompt for a high-risk request and its "The update adds: ..." sheet are still to come (RUY-102). When they exist this section will say what to expect and what the logs look like.

## Troubleshooting

Every command prints problems as `error[<code>] at <path>: <message>` followed by `fix: <one line>`. `--json` gives the same as `{ code, path, message, fix }`. The catalogue below lists **every code the tool can print** and its fix line. It is generated from `ruya_pack::fixes::catalogue()`; a test fails if this table and the tool disagree. The same codes appear in the specification ([05-play-packages](../specs/05-play-packages.md), section 4.5 and 9.2).

Common ones first:

- `art.too_small`: the placeholder icon from `init` is still there; use an image of at least 512x512.
- `package.no_table` or `package.hash_mismatch`: run `ruya-pack build` again; `play.files` must match the folder.
- `path.case_collision`: two files differ only by letter case; rename one.
- `resolve.no_system_runner`, `resolve.system_too_old`: the OS's Wine or Proton does not satisfy `min`; lower `min`, or bundle a copy and use `prefer-system` or `newest`.
- `licence.text_missing` and `licence.source_missing`: see "Legal duties".
- `sig.*`: the package was changed after signing; build and sign again.
- `trust.needs_developer_mode`: an unsigned package; sign it or turn on developer mode on the console.
- `ceiling.refused`: an unsigned package asked for a high-risk permission.

<!-- catalogue:start -->

| Code | What to do |
|---|---|
| `art.animated` | Use a still image; animation belongs in the preview video. |
| `art.aspect_ratio` | Crop the image to the slot's shape (icon 1:1, hero and screenshots 16:9, cover 2:3). |
| `art.colour_profile` | Export the image as sRGB (or with an RGB ICC profile). |
| `art.corrupt` | Export the image again from your editor; the file cannot be decoded. |
| `art.dimensions_too_large` | Scale the image below 16384 pixels each way and 100 megapixels. |
| `art.extension` | Use .png, .jpg, .jpeg or .webp for images and .webm or .mp4 for video. |
| `art.file_too_large` | Make the file smaller: icon and logo 2 MB, cover and screenshots 4 MB, hero 8 MB. |
| `art.format_unsupported` | Use PNG, JPEG or WebP. |
| `art.icc_too_large` | Fix the image as the message says. |
| `art.io` | Fix the image as the message says. |
| `art.magic_mismatch` | The file's contents do not match its extension; export it again in the format its name says. |
| `art.missing` | Add the file listed in play.json to the package, or remove the entry. |
| `art.no_screenshots` | Add a screenshot, or remove the empty screenshots list. |
| `art.not_a_file` | Fix the image as the message says. |
| `art.path` | Fix the image as the message says. |
| `art.svg` | Export the image as PNG, JPEG or WebP; SVG is not accepted. |
| `art.too_many_screenshots` | Keep at most 20 screenshots. |
| `art.too_small` | Replace the image with one at least as large as the slot needs (icon 512x512, hero 1920x1080, cover 600x900, screenshots 1280x720). |
| `blocklist.changed` | The console's blocklist is not the tool's business; update the console. |
| `blocklist.expired` | The console's blocklist is not the tool's business; update the console. |
| `blocklist.malformed` | The console's blocklist is not the tool's business; update the console. |
| `blocklist.not_newer` | The console's blocklist is not the tool's business; update the console. |
| `blocklist.not_store_key` | The console's blocklist is not the tool's business; update the console. |
| `blocklist.unavailable` | The console's blocklist is not the tool's business; update the console. |
| `build.output_inside` | Choose an output file outside the package folder with -o. |
| `build.signature_dropped` | Run ruya-pack sign on the new package: a signature covers play.files, which the build just wrote. |
| `build.symlink` | Remove the link, or build with --links-as-data to record a relative link inside the folder in play.files. |
| `build.symlink_unsupported` | Make the link relative and keep its target inside the same top-level folder, or replace it with a copy of the file. |
| `ceiling.refused` | Remove the high-risk permission, or sign the package with a developer key. |
| `component.bundled_missing` | Fix the components block of play.json (05 section 6.2). |
| `component.duplicate` | Fix the components block of play.json (05 section 6.2). |
| `component.missing_field` | Fix the components block of play.json (05 section 6.2). |
| `component.path` | Fix the components block of play.json (05 section 6.2). |
| `component.unknown_key` | Fix the components block of play.json (05 section 6.2). |
| `data.path` | Use a prefix:, data: or config: path inside the package's own data. |
| `entry.device` | Remove the device file; a package holds only regular files and folders. |
| `entry.hardlink` | Replace the hard link with a separate copy of the file. |
| `entry.special` | Remove the special file (FIFO, socket); a package holds only regular files and folders. |
| `entry.symlink` | Remove the link, or build with --links-as-data to record it in play.files as a package link. |
| `env.bad_name` | Remove or rename the environment variable; the console sets its own. |
| `env.bad_value` | Remove or rename the environment variable; the console sets its own. |
| `env.reserved` | Remove or rename the environment variable; the console sets its own. |
| `folder.too_many_entries` | Check the folder: names must be UTF-8 and the folder must be readable and under the entry limit. |
| `folder.unreadable` | Check the folder: names must be UTF-8 and the folder must be readable and under the entry limit. |
| `format.invalid` | Fix play.json as described; the schema is in api/play/play.schema.json. |
| `format.too_new` | Install a newer ruya-pack; this package uses a newer format than the tool knows. |
| `id.flatpak_invalid` | Use - only in the last part of the id, and keep it under 255 bytes. |
| `id.invalid` | Use a reverse-DNS id such as com.example.mygame: three or more parts, letters, digits, _ and -, no part starting with a digit. |
| `id.reserved` | Choose an id of your own; org.ruyaos. and play. are for the Official tier. |
| `init.not_empty` | Choose an empty or new folder, or pass --force to add the skeleton files that are missing. |
| `io.error` | Check that the path exists, that you may read it, and that the disk is not full. |
| `json.duplicate_key` | Remove the repeated key from the JSON. |
| `key.exists` | Choose another name, or pass --force to replace the key (the old key is gone for good). |
| `key.invalid` | Use a key file made by ruya-pack keygen (header ruyaos-play-key-v1), or RUYA_PACK_KEY holding its base64 line. |
| `key.missing` | Pass --key &lt;file&gt; or set RUYA_PACK_KEY; make a key with ruya-pack keygen &lt;name&gt;. |
| `key.same` | Rotate from the previous key: --rotate-from takes the old key file, --key the new one. |
| `lang.invalid` | Use BCP-47 language tags such as en, tr or pt-BR, at most 30. |
| `lang.missing_en` | Add an "en" text next to the other languages. |
| `lang.too_many` | Use BCP-47 language tags such as en, tr or pt-BR, at most 30. |
| `licence.source_missing` | Set bundled.source_url to where the source of the bundled code can be downloaded, or ship the source as a file under sources/. |
| `licence.text_missing` | Add the licence text of the bundled component as a file under licences/ whose name or folder names the component or the licence (licences/wine-LGPL-2.1.txt). |
| `link.absolute` | Fix the link: relative target, inside the same top-level folder, at most 8 hops, no loop. |
| `link.as_parent` | Fix the link: relative target, inside the same top-level folder, at most 8 hops, no loop. |
| `link.at_root` | Fix the link: relative target, inside the same top-level folder, at most 8 hops, no loop. |
| `link.chain_too_long` | Fix the link: relative target, inside the same top-level folder, at most 8 hops, no loop. |
| `link.dangling` | Fix the link: relative target, inside the same top-level folder, at most 8 hops, no loop. |
| `link.escapes_tree` | Fix the link: relative target, inside the same top-level folder, at most 8 hops, no loop. |
| `link.leaves_top_dir` | Fix the link: relative target, inside the same top-level folder, at most 8 hops, no loop. |
| `link.loop` | Fix the link: relative target, inside the same top-level folder, at most 8 hops, no loop. |
| `link.target_invalid` | Fix the link: relative target, inside the same top-level folder, at most 8 hops, no loop. |
| `list.duplicate` | Shorten the list or remove the repeated entry. |
| `list.too_long` | Shorten the list or remove the repeated entry. |
| `manifest.invalid_json` | Fix play.json: it must be one UTF-8 JSON object of at most 1 MiB, nested at most 12 deep. |
| `manifest.missing` | Fix play.json: it must be one UTF-8 JSON object of at most 1 MiB, nested at most 12 deep. |
| `manifest.not_utf8` | Fix play.json: it must be one UTF-8 JSON object of at most 1 MiB, nested at most 12 deep. |
| `manifest.too_big` | Fix play.json: it must be one UTF-8 JSON object of at most 1 MiB, nested at most 12 deep. |
| `manifest.too_deep` | Fix play.json: it must be one UTF-8 JSON object of at most 1 MiB, nested at most 12 deep. |
| `manifest.type` | Fix play.json: it must be one UTF-8 JSON object of at most 1 MiB, nested at most 12 deep. |
| `name.reserved` | Choose another name; system-like names are for the Official tier. |
| `package.extra_dir` | Run ruya-pack build again: play.files must list every folder that is empty. |
| `package.extra_file` | Run ruya-pack build again: play.files must list every file. |
| `package.hash_mismatch` | The file changed after play.files was written; run ruya-pack build again. |
| `package.kind_mismatch` | A file and a folder swapped places; run ruya-pack build again. |
| `package.missing_dir` | Restore the folder or run ruya-pack build again to rewrite play.files. |
| `package.missing_file` | Restore the file or run ruya-pack build again to rewrite play.files. |
| `package.no_manifest` | Add play.json at the root of the package (ruya-pack init writes a skeleton). |
| `package.no_table` | Run ruya-pack build to write play.files. |
| `package.read_failed` | Check that you may read the file and that the disk is healthy. |
| `package.root_kind` | play.json, play.files, play.sig and store.sig must be regular files. |
| `package.size_mismatch` | The file changed after play.files was written; run ruya-pack build again. |
| `path.absolute` | Rename the file or folder so its path follows 05 section 4.2. |
| `path.backslash` | Rename the file or folder so its path follows 05 section 4.2. |
| `path.case_collision` | Rename one of the files: names must differ by more than letter case (exFAT and Wine ignore case). |
| `path.colon` | Rename the file or folder so its path follows 05 section 4.2. |
| `path.component_too_long` | Rename the file or folder so its path follows 05 section 4.2. |
| `path.control` | Rename the file or folder so its path follows 05 section 4.2. |
| `path.dot` | Rename the file or folder so its path follows 05 section 4.2. |
| `path.empty` | Rename the file or folder so its path follows 05 section 4.2. |
| `path.empty_component` | Rename the file or folder so its path follows 05 section 4.2. |
| `path.invalid_utf8` | Rename the file so its name is valid UTF-8. |
| `path.not_nfc` | Rename the file with its characters in Unicode normal form C (NFC). |
| `path.reserved_name` | Rename the file: names like CON, NUL or COM1 cannot exist on Windows drives. |
| `path.too_long` | Rename the file or folder so its path follows 05 section 4.2. |
| `path.trailing_dot_space` | Remove the trailing dot or space from the name. |
| `path.traversal` | Remove the .. part from the path; every path stays inside the package. |
| `permissions.reason_key` | Use only the permission keys of 05 section 8; remove the unknown one. |
| `permissions.unknown_key` | Use only the permission keys of 05 section 8; remove the unknown one. |
| `prefix.dosdevices` | Fix run.prefix; the launcher creates dosdevices itself. |
| `prefix.template_missing` | Fix run.prefix; the launcher creates dosdevices itself. |
| `problems.truncated` | Fix the problems listed first, then run the command again. |
| `requirements.arch` | Set requirements.arch to x86_64. |
| `resolve.no_bundled` | Add the bundled block (path, version, licence) and the files under components/, or choose source system. |
| `resolve.no_system_runner` | Give the component a bundled copy and source prefer-system or newest, or accept that the installer fetches the runner. |
| `resolve.not_checked` | Pass --system-wine &lt;version&gt; (or --system-proton-ge, --system-runner family=version) to check the dry run. |
| `resolve.system_too_new` | Raise max_major once you tested the newer runner, or bundle a copy so the fence has a fallback. |
| `resolve.system_too_old` | Lower min if the older runner works, or bundle a copy and use source prefer-system or newest. |
| `revoked.content` | This package, key or runner is on the revocation list; do not distribute it. |
| `revoked.id` | This package, key or runner is on the revocation list; do not distribute it. |
| `revoked.key` | This package, key or runner is on the revocation list; do not distribute it. |
| `revoked.runner` | This package, key or runner is on the revocation list; do not distribute it. |
| `rotation.not_by_old_key` | Rotate with ruya-pack sign --rotate-from &lt;old key file&gt;, from the key the console last saw. |
| `rotation.replayed` | Rotate with ruya-pack sign --rotate-from &lt;old key file&gt;, from the key the console last saw. |
| `rotation.to_retired_key` | Rotate with ruya-pack sign --rotate-from &lt;old key file&gt;, from the key the console last saw. |
| `rotation.wrong_id` | Rotate with ruya-pack sign --rotate-from &lt;old key file&gt;, from the key the console last saw. |
| `run.argument_path` | Fix the run block of play.json (05 section 6.3). |
| `run.command_missing` | Fix the run block of play.json (05 section 6.3). |
| `run.component_missing` | Fix the run block of play.json (05 section 6.3). |
| `run.component_type` | Fix the run block of play.json (05 section 6.3). |
| `run.component_unexpected` | Fix the run block of play.json (05 section 6.3). |
| `run.component_unknown` | Fix the run block of play.json (05 section 6.3). |
| `run.cwd` | Fix the run block of play.json (05 section 6.3). |
| `run.disc_duplicate` | Fix the run block of play.json (05 section 6.3). |
| `run.disc_not_in_table` | Fix the run block of play.json (05 section 6.3). |
| `run.disc_path` | Fix the run block of play.json (05 section 6.3). |
| `run.disc_placeholder_without_discs` | Fix the run block of play.json (05 section 6.3). |
| `run.placeholder_component` | Fix the run block of play.json (05 section 6.3). |
| `run.unknown_key` | Fix the run block of play.json (05 section 6.3). |
| `runner.arch_invalid` | Fix the bundled runner's runner.json as the message says (05 section 6.2.1); the schema is in api/play/runner.schema.json. |
| `runner.capability_invalid` | Fix the bundled runner's runner.json as the message says (05 section 6.2.1); the schema is in api/play/runner.schema.json. |
| `runner.entry_invalid` | Fix the bundled runner's runner.json as the message says (05 section 6.2.1); the schema is in api/play/runner.schema.json. |
| `runner.entry_missing` | Put the program named in runner.json's entry into the runner's folder, or correct the path in entry. |
| `runner.family_invalid` | Fix the bundled runner's runner.json as the message says (05 section 6.2.1); the schema is in api/play/runner.schema.json. |
| `runner.format_invalid` | Fix the bundled runner's runner.json as the message says (05 section 6.2.1); the schema is in api/play/runner.schema.json. |
| `runner.format_too_new` | Install a newer ruya-pack; the bundled runner's runner.json uses a newer format than the tool knows. |
| `runner.invalid_json` | Fix the bundled runner's runner.json as the message says (05 section 6.2.1); the schema is in api/play/runner.schema.json. |
| `runner.kind_invalid` | Fix the bundled runner's runner.json as the message says (05 section 6.2.1); the schema is in api/play/runner.schema.json. |
| `runner.kind_mismatch` | Set kind in runner.json to the component's type, or bundle the runner under a component of its own type. |
| `runner.licence_invalid` | Fix the bundled runner's runner.json as the message says (05 section 6.2.1); the schema is in api/play/runner.schema.json. |
| `runner.missing_field` | Fix the bundled runner's runner.json as the message says (05 section 6.2.1); the schema is in api/play/runner.schema.json. |
| `runner.not_a_file` | Make runner.json a regular file in the runner's folder; a link or a folder of that name is refused. |
| `runner.not_utf8` | Fix the bundled runner's runner.json as the message says (05 section 6.2.1); the schema is in api/play/runner.schema.json. |
| `runner.too_big` | Fix the bundled runner's runner.json as the message says (05 section 6.2.1); the schema is in api/play/runner.schema.json. |
| `runner.type` | Fix the bundled runner's runner.json as the message says (05 section 6.2.1); the schema is in api/play/runner.schema.json. |
| `runner.unknown_key` | Fix the bundled runner's runner.json as the message says (05 section 6.2.1); the schema is in api/play/runner.schema.json. |
| `runner.url_invalid` | Fix the bundled runner's runner.json as the message says (05 section 6.2.1); the schema is in api/play/runner.schema.json. |
| `runner.version_invalid` | Fix the bundled runner's runner.json as the message says (05 section 6.2.1); the schema is in api/play/runner.schema.json. |
| `sig.bad_signature` | Run ruya-pack sign again with your key; do not edit play.sig by hand. |
| `sig.duplicate_key` | Run ruya-pack sign again. |
| `sig.format_too_new` | Run ruya-pack sign again. |
| `sig.malformed` | Run ruya-pack sign again. |
| `sig.play_files_changed` | play.files changed after signing; run ruya-pack sign again. |
| `sig.play_json_changed` | play.json changed after signing; run ruya-pack sign again. |
| `sig.rotations_changed` | Run ruya-pack sign again; do not edit play.sig by hand. |
| `sig.weak_key` | Run ruya-pack sign again. |
| `sig.wrong_build` | Run ruya-pack sign again after changing build. |
| `sig.wrong_id` | Sign this package, not a copy of another package's play.sig. |
| `size.fat32` | Format the USB drive as exFAT: FAT32 cannot hold a file of 4 GiB or more. |
| `state.corrupt` | The console's trust state is damaged; this is not a package problem. |
| `state.io` | The console's trust state is damaged; this is not a package problem. |
| `store_sig.play_sig_changed` | Remove store.sig; only the store writes it. |
| `store_sig.without_play_sig` | Remove store.sig; only the store writes it. |
| `table.blank_line` | Run ruya-pack build to write play.files again; do not edit it by hand. |
| `table.duplicate` | Run ruya-pack build to write play.files again; do not edit it by hand. |
| `table.line_invalid` | Run ruya-pack build to write play.files again; do not edit it by hand. |
| `table.not_sorted` | Run ruya-pack build to write play.files again; do not edit it by hand. |
| `table.not_utf8` | Run ruya-pack build to write play.files again; do not edit it by hand. |
| `table.parent_not_dir` | Run ruya-pack build to write play.files again; do not edit it by hand. |
| `table.reserved_path` | Run ruya-pack build to write play.files again; do not edit it by hand. |
| `table.reserved_top_level` | Move the contents below another folder (for example payload/): .ref, launcher and share at the top of a package belong to the console. |
| `table.too_big` | Run ruya-pack build to write play.files again; do not edit it by hand. |
| `table.too_many` | Run ruya-pack build to write play.files again; do not edit it by hand. |
| `text.bidi` | Write plain text: no markup, no links, no control or invisible characters. |
| `text.control` | Write plain text: no markup, no links, no control or invisible characters. |
| `text.empty` | Write plain text: no markup, no links, no control or invisible characters. |
| `text.link` | Write plain text: no markup, no links, no control or invisible characters. |
| `text.markup` | Write plain text: no markup, no links, no control or invisible characters. |
| `text.too_long` | Write plain text: no markup, no links, no control or invisible characters. |
| `text.zero_width` | Write plain text: no markup, no links, no control or invisible characters. |
| `trust.different_developer` | Sign the package with your developer key. |
| `trust.needs_developer_mode` | Sign the package (ruya-pack sign), or turn on developer mode on the console. |
| `url.invalid` | Use a plain https:// address. |
| `url.not_https` | Use an https:// address. |
| `usage.error` | Run ruya-pack --help for the commands and options. |
| `value.range` | Use one of the values the message lists. |
| `value.unknown` | Use one of the values the message lists. |
| `video.audio_not_allowed` | Fix the video as the message says (05 section 5). |
| `video.bitrate_too_high` | Re-encode the video at a lower bitrate. |
| `video.codec_not_allowed` | Encode with VP9 or AV1 (WebM) or H.264 (MP4) and a supported audio codec. |
| `video.container_not_allowed` | Use a WebM or MP4 container. |
| `video.content_encoding` | Fix the video as the message says (05 section 5). |
| `video.file_too_large` | Fix the video as the message says (05 section 5). |
| `video.frame_rate_too_high` | Re-encode the video at 60 frames per second or less. |
| `video.header_invalid` | Fix the video as the message says (05 section 5). |
| `video.io` | Fix the video as the message says (05 section 5). |
| `video.no_duration` | Fix the video as the message says (05 section 5). |
| `video.no_video_track` | Fix the video as the message says (05 section 5). |
| `video.not_a_file` | Fix the video as the message says (05 section 5). |
| `video.resolution_too_large` | Scale the video down to 1080p. |
| `video.sample_entries` | Fix the video as the message says (05 section 5). |
| `video.too_long` | Shorten the video. |
| `video.track_not_allowed` | Fix the video as the message says (05 section 5). |
| `zip.crc_mismatch` | Build the zip with ruya-pack build; other zip tools may write what the console refuses. |
| `zip.declared_size_lies` | Build the zip with ruya-pack build; other zip tools may write what the console refuses. |
| `zip.duplicate_entry` | Build the zip with ruya-pack build; other zip tools may write what the console refuses. |
| `zip.encrypted` | Build the zip with ruya-pack build; other zip tools may write what the console refuses. |
| `zip.gap` | Build the zip with ruya-pack build; other zip tools may write what the console refuses. |
| `zip.leading_data` | Build the zip with ruya-pack build; other zip tools may write what the console refuses. |
| `zip.local_mismatch` | Build the zip with ruya-pack build; other zip tools may write what the console refuses. |
| `zip.malformed` | Build the zip with ruya-pack build; other zip tools may write what the console refuses. |
| `zip.method` | Build the zip with ruya-pack build; other zip tools may write what the console refuses. |
| `zip.multi_disk` | Build the zip with ruya-pack build; other zip tools may write what the console refuses. |
| `zip.not_a_zip` | Build the zip with ruya-pack build; other zip tools may write what the console refuses. |
| `zip.overlap` | Build the zip with ruya-pack build; other zip tools may write what the console refuses. |
| `zip.ratio` | Build the zip with ruya-pack build; other zip tools may write what the console refuses. |
| `zip.too_many_entries` | Build the zip with ruya-pack build; other zip tools may write what the console refuses. |
| `zip.trailing_data` | Build the zip with ruya-pack build; other zip tools may write what the console refuses. |

<!-- catalogue:end -->

## The samples

Both samples are public domain (CC0) and committed **without** any binary: the folder `package/` holds the manifest and the art (neither sample bundles third-party code, so neither has a `licences/` folder; bundled code would need one), and a script builds the program into `package/payload/` (git-ignored).

| Sample | What it shows | Build |
|---|---|---|
| [`samples/hello-play-native/`](../../samples/hello-play-native/README.md) | A native Linux game (the Hello Game sources) with a controller, saves in `data:saves` and only the input permission | `./build.sh` (a C compiler and SDL3 development files) |
| [`samples/hello-play-wine/`](../../samples/hello-play-wine/README.md) | A Windows program cross-compiled with `x86_64-w64-mingw32-gcc`, `source: system`, a saves path inside the prefix, a no-op first-run setup step | `./build.sh` (Fedora: `sudo dnf install mingw64-gcc`) |

Their tests (`services/ruya-pack/tests/samples.rs`) copy the folder to a scratch directory, write a stand-in file where the compiled program goes, and run `ruya-pack build`, `validate` and `inspect` on it; the tests need no compiler. CI's `samples` job compiles both (with `-Werror`), builds each zip with the real `ruya-pack` and inspects it. The art in both is made by `make-art.py` and checked by the same vetting the console uses.

## Sources

Checked on 2026-11-17 against: `docs/specs/05-play-packages.md` sections 1 to 15 (format, art, runners, permissions, signatures, updates, tooling, legal); `api/play/play.schema.json`; `services/ruya-pack` (`init`, `build`, `keygen`, `sign`, `validate`, `inspect` run from an empty folder to a signed zip on Windows, output quoted above; `src/fixes.rs` for the catalogue; `tests/guide.rs` and `tests/samples.rs`); `services/ruya-play-format`, `ruya-play-art` and `ruya-play-trust` through the tool; `shell/qml/InstallSourcesPage.qml` and `InstallPackagePage.qml` (mock backend only); `samples/hello-play-native/` and `samples/hello-play-wine/` (manifests and stand-in builds pass `build`, `validate` and `inspect`; CI compiles both C samples and builds and inspects their zips with `scripts/ci-samples-linux.sh`, RUY-822). `services/ruya-play` (the install service, RUY-829: Play1, the helper sandbox, the Flatpak commit with its fixed permission set). The launcher, the Compatibility screen, the permission mapping and feed updates are planned: RUY-101, RUY-102, T-241.
