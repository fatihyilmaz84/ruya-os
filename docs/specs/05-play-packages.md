# RuyaOS — `.play` Packages (self-contained games and apps)

Status: **Draft v1, design only, nothing is built; reviewed 2026-11-10: read §18 first, it corrects §6, §7, §9 and §11** · Parent: [00-overview](00-overview.md) · Decision: ADR-014 (*Accepted 2026-11-06, conditional on the T-229 spike*; work parked by the owner) · Epic: [T-228](../tasks/T-228-epic-play-packages.md)

A `.play` package is one folder or one `.play.zip` file that holds a game or app **and everything it needs to run on RuyaOS**: the program, a Wine or Proton build or an emulator (or a pointer to the one the OS provides), artwork and video for the shell, metadata, a permission request and a signature. A developer builds it once; a player copies it to a USB stick or downloads it, and it appears in the library with its art. Think of a macOS `.app` in a `.dmg`, with a signature and a sandbox.

This document is the format, the install and run model, the security model and the update model. The build order is in the epic. Where a statement depends on something that has to be proven on Linux first, it says so and names the spike (**T-229**); the format itself does not depend on the answer.

## 0. Principles

1. **A package is data, never code that runs at install.** Installing a package runs nothing from it. No scripts, no hooks, no "installer". The only code that ever runs from a package runs at launch, inside the sandbox, as the player's profile user.
2. **Everything runs in a Flatpak sandbox** (ADR-005, security invariant "third-party apps run only in Flatpak sandboxes"). A `.play` is a *container for a Flatpak app plus art and policy*, not a new runtime and not a new sandbox. The sandbox, not Wine, not the emulator, not the package, is the security boundary.
3. **Nothing is trusted until verified, and nothing is verified twice by different rules.** One verifier (`ruya-play`), one set of parsing rules, used by the shell's "install from USB" screen, the update path, the Store and the developer tool.
4. **Permissions are a closed vocabulary**, requested statically, shown in plain words before install, and capped by how far the package is trusted. A package cannot ask for something the vocabulary does not name.
5. **The player decides, the developer proposes.** Which runner to use, whether to check for updates, which permissions to grant (down, never up): the package's manifest is a request and a default, never a command.
6. **Small packages are the developer's choice, not a rule.** A package can ship its own Wine (works anywhere, big) or point at the OS's (small, gets OS fixes), or accept either.
7. **Honest wording.** A signature proves *the same key signed this*, not that the developer is who they say. The UI says "Signed by key 3f9a… (first time seen)", never "verified publisher", unless the Official store signed it.

### Non-goals (v1)
- A new runtime, a new sandbox, a package manager, or a replacement for Flatpak. Flatpak and the Flathub route stay the main way to get apps (ADR-005).
- Running a package without installing it (a "play from USB" mode). Installs are fast enough, and verified content must be immutable.
- DRM, licence keys, online activation, anti-cheat. A package can include a game that needs them; we do not provide them.
- Shipping firmware, BIOS files, game discs or ROMs ourselves (03 §5). See §12 for what a *developer* may put in a package.
- Delta updates and a dedicated package store protocol (designed for in §11, built later).

## 1. Terms

| Term | Meaning |
|---|---|
| **Package** | The `.play` folder or `.play.zip` file. |
| **Payload** | The game or app files (`payload/`). |
| **Component** | Something the payload runs on: a Wine build, a Proton build, an emulator, a game engine, a library set (`components[]`). |
| **Runner** | A component that executes the payload (`wine`, `proton`, `emulator`, `engine`) or the payload itself (`native`). |
| **System runner** | A runner the OS provides and updates (a Flatpak extension of the Play platform, §6.4). |
| **Bundled** | Shipped inside the package. |
| **Trust tier** | `official` (countersigned by the RuyaOS store key), `developer` (signed, key seen), `unverified` (unsigned or unknown key, admin's developer mode only). §9.2. |
| **Installed id** | `play.<id>`: the Flatpak id the package is installed under (§7.1). |
| **Importer** | The `ruya-play` service plus its unprivileged unpack helper (§7.3). |

## 2. Package forms

| Form | Name | Notes |
|---|---|---|
| Folder | `Star Hopper.play/` | Easiest for developers and for USB. The folder's own name is display-only; identity is `id` in `play.json`. |
| Archive | `Star-Hopper.play.zip` | One file. ZIP (with ZIP64), entries stored or deflated. For games, "stored" is recommended: payloads are already compressed and the importer reads faster. |
| Later | `.play.tar.zst`, delta feeds | Not v1. The manifest and file table are the same, only the reader changes. |

- The MIME type is `application/x-ruya-play` (folder: `inode/directory` with a `play.json`); the shell recognises a package by `play.json` at its root (after unwrapping a single top-level folder in a zip), not by the extension alone.
- **Removable media:** a package on a USB drive is listed by an explicit "Install from USB" action; nothing is opened, previewed from raw files, or run just because a drive appeared (security invariant).
- **Symlinks, modes and special files are data, not filesystem objects.** exFAT and FAT USB sticks have no symlinks or Unix modes, and symlinks are the classic escape in archives. So a package contains **only regular files and directories**; links and the executable bit are recorded in `play.files` (§4.2) and recreated by the importer. A real symlink, hard link, device node, FIFO or socket in a folder or a zip makes the package invalid.

## 3. Layout

```
Star Hopper.play/
  play.json            manifest: metadata, run, components, permissions, data, update (required, <= 1 MiB)
  play.files           file table, JSON Lines (required)
  play.sig             signature statement (required for official and developer tiers)
  store.sig            countersignature by the RuyaOS store (only on store builds)
  art/                 icon, logo, hero, cover, screenshots, trailer (§5)
  payload/             the game or app, any layout
  components/          bundled runners: components/wine/, components/rpcs3/ ... (optional)
  licences/            licence texts and written source offers for bundled third-party code
  README.txt           optional, for people opening the folder on a PC
```

Everything under the root except `play.json`, `play.files`, `play.sig`, `store.sig` must be listed in `play.files`. A file that exists but is not listed, or listed but missing or different, makes the package invalid.

## 4. Manifest and file table

### 4.1 `play.json`

UTF-8 JSON, at most 1 MiB, nesting depth at most 12. Unknown keys are ignored (so a newer developer tool does not break an older console) **except** keys under `permissions`, `run` and `components`, where an unknown key is an error (a permission the console does not understand must not be silently dropped). `format` is the major version; a console that does not know it refuses the package with "needs a newer RuyaOS".

```json
{
  "format": 1,
  "id": "com.example.starhopper",
  "name": { "en": "Star Hopper", "tr": "Yildiz Atlayici" },
  "version": "1.4.2",
  "build": 142,
  "summary": { "en": "A two-player space platformer." },
  "description": { "en": "Hop between planets...\n\nSecond paragraph." },
  "developer": { "name": "Example Games", "url": "https://example.com" },
  "publisher": { "name": "Example Publishing" },
  "release_date": "2021-03-04",
  "genres": ["platformer", "adventure"],
  "tags": ["co-op", "space", "pixel-art"],
  "languages": ["en", "tr", "de"],
  "players": { "min": 1, "max": 2, "modes": ["single", "local"] },
  "controller": "full",
  "age_rating": { "scheme": "oars-1.1", "content": { "violence-cartoon": "mild" } },
  "licence": { "package": "LicenseRef-proprietary", "terms_url": "https://example.com/eula" },
  "links": [
    { "kind": "homepage", "url": "https://example.com/starhopper" },
    { "kind": "support",  "url": "https://example.com/support" },
    { "kind": "manual",   "url": "https://example.com/manual.pdf" },
    { "kind": "source",   "url": "https://github.com/example/starhopper" }
  ],
  "requirements": { "arch": "x86_64", "min_ram_mb": 4096, "gpu_api": ["vulkan"] },
  "art": { "icon": "art/icon.png", "logo": "art/logo.webp", "hero": "art/hero.webp",
           "cover": "art/cover.webp",
           "screenshots": [ { "file": "art/shot1.webp", "caption": { "en": "The first world" } } ],
           "trailer": { "file": "art/trailer.webm", "poster": "art/trailer.webp" },
           "preview": "art/preview.webm" },
  "components": [
    { "id": "wine", "type": "wine", "source": "newest", "min": "9.0", "tested": "9.20",
      "bundled": { "path": "components/wine", "version": "9.20", "licence": "LGPL-2.1-or-later",
                   "source_url": "https://dl.winehq.org/wine/source/" } }
  ],
  "run": {
    "runner": "wine",
    "component": "wine",
    "command": ["${payload}/StarHopper.exe", "-fullscreen"],
    "cwd": "${payload}",
    "env": { "WINEDLLOVERRIDES": "dinput8=n,b" },
    "launch_mode": "fullscreen",
    "prefix": { "arch": "win64", "template": "payload/prefix-template", "epoch": 1 },
    "setup": [ { "id": "vcredist", "command": ["${payload}/redist/vc_redist.x64.exe", "/q"], "once": true } ]
  },
  "permissions": {
    "network": false,
    "input": "controllers+keyboard-mouse",
    "reasons": { }
  },
  "data": { "saves": ["prefix:drive_c/users/steamuser/Documents/Star Hopper"], "cache": ["data:shader-cache"] },
  "update": { "feed": "https://example.com/starhopper/feed.json", "channel": "stable" }
}
```

**Field rules** (limits are initial values, tuned in T-230 and kept in one schema file, `api/play/play.schema.json`):

| Field | Rule |
|---|---|
| `id` | Reverse-DNS, the Flatpak id grammar (letters, digits, `_`, `-`, at least three elements, none empty, none starting with a digit, at most 120 bytes), lower-case recommended. The app is installed as `play.<id>`, which must itself be a valid Flatpak id: `-` only in the **last** element and at most 255 bytes (`id.flatpak_invalid`). Must not start with `org.ruyaos.` or `play.` unless it is ours; reserved names refused. Identity of the app for ever: a changed id is a different app. |
| `name`, `summary`, `description` | Localized maps (`"en"` required, other BCP-47 tags optional, at most 30 languages). `name` <= 60 chars, `summary` <= 140, `description` <= 4000, **plain text** with `\n\n` paragraph breaks (no markup, no HTML, no links inline). Control characters (a line break only in `description`), bidi overrides and zero-width characters are **refused** (`text.control`, `text.bidi`, `text.zero_width`), not silently stripped: a signed manifest is shown exactly as written. Text that looks like markup (`<b>`, `</`, `<!`) or contains `://` is refused (`text.markup`, `text.link`). A name that looks like a system name (Settings, RuyaOS, Store, Home, Guide, "Update") is refused unless the Official tier. |
| `version`, `build` | `version` is display text (<= 32 chars); `build` is a positive integer that **only increases** and is what update ordering uses. |
| `developer`, `publisher` | `name` <= 80 chars, optional `url` (https). Self-asserted; shown with the signature state, never as proof. |
| `genres` | From a closed vocabulary (action, adventure, arcade, platformer, puzzle, racing, role-playing, shooter, simulation, sports, strategy, fighting, music, party, family, sandbox, horror, visual-novel, retro, utility, other; list kept in the schema) at most 4; the first maps to the shell's category tint (04). `tags` are free text, <= 12, <= 24 chars. |
| `controller` | `full` \| `partial` \| `none`, same meaning as `x-ruya-controller` (03 §4.1); the Store's gamepad filter reads it. |
| `age_rating` | OARS 1.1 content attributes (as in AppStream); the shell derives the label, parental controls (T-211) read it. Missing = "Not rated" (never "All ages"). |
| `licence` | SPDX id or `LicenseRef-proprietary` for the package contents; `terms_url` https. Bundled third-party code declares its own (see components). |
| `links` | At most 12; `kind` from `homepage`, `support`, `manual`, `source`, `community`, `store`, `privacy`, `changelog`, `donate`, `other`; `https` URLs only (no `javascript:`, `file:`, `data:`, `http:`). The shell shows them as text and a QR code; **it never opens them automatically** (there is no browser in the base image). |
| `requirements` | Facts for the "can this run here" check and the install-space check: `arch` (`x86_64` only in v1), `min_ram_mb`, `gpu_api` (`vulkan`, `opengl`). The installed size is **computed** from the file table (the sum of the file sizes, `Package::installed_bytes`), never declared; a manifest that still has `installed_mb` is accepted and the key ignored (`requirements` is not a strict object). |
| `run`, `components`, `permissions`, `data`, `update` | §6 to §11. |

### 4.2 `play.files` (the file table)

JSON Lines, UTF-8, one object per line, sorted by `p` (bytewise), no blank lines, at most 64 MiB. It is the single list of everything in the package and the thing the signature protects.

```
{"p":"payload/StarHopper.exe","t":"f","s":18350080,"h":"<sha256 hex>","x":1}
{"p":"payload/data/level1.pak","t":"f","s":512000000,"h":"<sha256 hex>"}
{"p":"components/wine/lib/libwine.so","t":"l","to":"libwine.so.1"}
{"p":"payload/saves","t":"d"}
```

- `t`: `f` file (size `s`, SHA-256 `h` as 64 lower-case hex digits, optional `x:1` = executable), `l` symlink, `d` empty directory. Everything else is invalid, and so is a key not listed here.
  - **Links** (`to` relative to the link's folder, resolved lexically): the link is inside a top-level folder (not at the root); the target stays inside the **same top-level folder** and exists in the table; nothing is stored *below* a link or a file. A link may point at another link: a chain may pass through **at most 8 links** (a bundled Wine's `libx.so -> libx.so.1 -> libx.so.1.2` is legal; `ruya-pack build` flattens what it can). A loop is invalid.
  - **A Wine prefix template** (`run.prefix.template`) never contains a folder named `dosdevices` (it has a colon and absolute links); the launcher creates it.
- Paths: relative, `/` separators, NFC-normalised UTF-8, no empty, `.` or `..` components, no leading `/`, no `\`, no `:` in a component, no control characters, each component <= 255 bytes, the whole path <= 1024, **unique even when case is ignored** (exFAT and Wine games), no Windows reserved names (`CON`, `NUL`, ...) and no trailing dot or space. At most 200,000 entries.
- The importer sets file modes itself: 0644, or 0755 with `x:1`. No setuid/setgid/sticky, no file capabilities, no xattrs, ownership root (after commit), timestamps from the manifest's build time.

### 4.3 Folder versus zip, one rule set

The folder and the zip are read through the same verifier (the crate `services/ruya-play-format`, the only parser: the importer, `ruya-pack`, the service and the Store all use it). It lists entries and applies §4.2's rules to the *names and kinds* **before** reading any content, then reads `play.files` and `play.json`, checks the table against the listing, and only then streams content while hashing; a package that fails an earlier step is not read further. A zip adds, as built (`zip.rs`, written for this format rather than taken from a general zip crate):

- no encrypted entries (flags, strong encryption, AES), only the methods stored and deflate, no split archives;
- no entry that is a symlink, a device or a FIFO (the Unix mode in the external attributes), a hard link (two directory entries for the same local header) or an NTFS reparse point;
- no duplicate names (also not `x` and `x/`);
- central directory only: the end record is the last 22 bytes (no archive comment), the directory ends where the end record (or the ZIP64 record) begins, every entry's local header agrees with the directory (name, flags, method, CRC and sizes), and the entries tile the file exactly from offset 0 up to the directory (no data in front, between or behind; an entry with a data descriptor may have one of the four legal descriptor lengths after it);
- declared sizes enforced while reading (the content has exactly the declared size and CRC);
- **expansion limit**: any entry over 1 MiB that expands more than 200:1 is refused. A single top-level folder around `play.json` is unwrapped (§2).

The total unpacked size is the sum of the table's file sizes (`Package::installed_bytes`); fitting it into free space (with 10 % to spare) is the importer's check (T-237), made before the first byte is written.

### 4.4 Limits as built

All of them are constants in `limits.rs`, repeated in `api/play/play.schema.json` where a schema can say them (a test keeps the two equal), and each has a boundary test (below, at, above) in `tests/limits.rs`.

| Limit | Value | Code |
|---|---|---|
| `play.json` size / nesting depth | 1 MiB / 12 (the top-level object is depth 1) | `manifest.too_big`, `manifest.too_deep` |
| `play.files` size / entries | 64 MiB / 200,000 | `table.too_big`, `table.too_many` |
| Zip entries (files plus directory entries) / folder entries | 220,000 | `zip.too_many_entries`, `folder.too_many_entries` |
| Path / path component | 1024 / 255 bytes | `path.too_long`, `path.component_too_long` |
| Link chain | 8 links | `link.chain_too_long` |
| Expansion | free up to 1 MiB, then 200:1 | `zip.ratio` |
| Languages in a localized text, in `languages` | 30 | `lang.too_many`, `list.too_long` |
| `name` / `summary` / `description` / `version` | 60 / 140 / 4000 / 32 characters | `text.too_long` |
| Developer and publisher name; tag; tags; genres | 80 / 24 characters; 12; 4 | `text.too_long`, `list.too_long` |
| Links; URL | 12; 2048 bytes (https only, no user info) | `list.too_long`, `url.invalid`, `url.not_https` |
| Screenshots; caption; permission reason | 20; 100; 120 characters | `list.too_long`, `text.too_long` |
| `id` | 120 bytes (`play.<id>` 255) | `id.invalid`, `id.flatpak_invalid` |
| Components; component id; version string | 16; 32; 32 bytes | `list.too_long`, `value.unknown` |
| `run.env` entries / name / value | 64 / 64 / 1024 bytes | `list.too_long`, `env.bad_name`, `env.bad_value` |
| Command arguments / one argument | 64 / 4096 bytes | `list.too_long`, `text.too_long` |
| Setup steps; discs; paths in `data.saves` and `data.cache` | 16; 16; 32 each | `list.too_long` |
| Players; OARS attributes; licence expression | 64; 40; 128 bytes | `value.range`, `list.too_long`, `value.unknown` |
| Problems in one result | 100, then `problems.truncated` | |

### 4.5 Error codes

A check returns a list of problems `{ code, path, message }`. `code` is a stable dotted string (a code never changes meaning); `path` is a JSON pointer for `play.json` and the package path for files; `message` is English a developer can act on. The shell maps codes to translated text (T-236). `tests/codes.rs` fails when a code is missing from this list or is asserted by no test.

| Group | Codes |
|---|---|
| Format and JSON | `format.too_new`, `format.invalid`, `manifest.too_big`, `manifest.too_deep`, `manifest.not_utf8`, `manifest.invalid_json`, `manifest.type`, `manifest.missing`, `value.unknown`, `value.range`, `list.too_long`, `list.duplicate` |
| Identity and text | `id.invalid`, `id.flatpak_invalid`, `id.reserved`, `name.reserved`, `text.control`, `text.bidi`, `text.zero_width`, `text.markup`, `text.link`, `text.too_long`, `text.empty`, `lang.invalid`, `lang.too_many`, `lang.missing_en`, `url.not_https`, `url.invalid`, `requirements.arch` |
| Permissions, components, run | `permissions.unknown_key`, `permissions.reason_key`, `component.unknown_key`, `component.missing_field`, `component.duplicate`, `component.bundled_missing`, `component.path`, `run.unknown_key`, `run.component_missing`, `run.component_unknown`, `run.component_type`, `run.component_unexpected`, `run.placeholder_component`, `run.disc_placeholder_without_discs`, `run.disc_not_in_table`, `run.disc_path`, `run.disc_duplicate`, `run.command_missing`, `run.cwd`, `env.bad_name`, `env.reserved`, `env.bad_value`, `prefix.dosdevices`, `prefix.template_missing`, `art.path`, `art.missing`, `art.extension`, `data.path` |
| Paths | `path.empty`, `path.traversal`, `path.dot`, `path.absolute`, `path.backslash`, `path.colon`, `path.control`, `path.empty_component`, `path.component_too_long`, `path.too_long`, `path.not_nfc`, `path.case_collision`, `path.reserved_name`, `path.trailing_dot_space`, `path.invalid_utf8` |
| Kinds, table and links | `entry.symlink`, `entry.hardlink`, `entry.device`, `entry.special`, `table.not_utf8`, `table.too_big`, `table.too_many`, `table.line_invalid`, `table.blank_line`, `table.not_sorted`, `table.duplicate`, `table.reserved_path`, `table.parent_not_dir`, `link.absolute`, `link.target_invalid`, `link.at_root`, `link.escapes_tree`, `link.leaves_top_dir`, `link.chain_too_long`, `link.loop`, `link.dangling`, `link.as_parent` |
| Table against package | `package.no_manifest`, `package.no_table`, `package.root_kind`, `package.extra_file`, `package.extra_dir`, `package.missing_file`, `package.missing_dir`, `package.kind_mismatch`, `package.size_mismatch`, `package.hash_mismatch`, `package.read_failed`, `problems.truncated` |
| Zip and folder | `zip.not_a_zip`, `zip.trailing_data`, `zip.leading_data`, `zip.malformed`, `zip.encrypted`, `zip.method`, `zip.multi_disk`, `zip.duplicate_entry`, `zip.ratio`, `zip.too_many_entries`, `zip.gap`, `zip.overlap`, `zip.local_mismatch`, `zip.declared_size_lies`, `zip.crc_mismatch`, `folder.unreadable`, `folder.too_many_entries` |

## 5. Artwork and video

The art slots are the contract between a developer and the shell; the shell never shows a raw file from a package. The importer decodes every image in a sandboxed helper, checks dimensions and size, **strips metadata, converts to sRGB and re-encodes** to canonical WebP at the sizes the shell uses (§12), then the shell loads only those vetted files. A package whose art fails validation installs without it and says so (the generated tile of 03 §4.1 is used), unless `hero` or `icon` is *malformed* (a broken image is a refusal; a missing one is not).

| Slot | File | Spec | Used for |
|---|---|---|---|
| `icon` | PNG or WebP | **Square 1024x1024** (512 minimum), RGBA, full bleed. The shell applies the rounded-square mask itself, so do not pre-round; keep the subject in the centre 80 %. <= 2 MB. | Library list rows, Store, toasts, the system's "Running" list. **Required.** |
| `logo` | PNG or WebP | Transparent, at least 256 px high, at most 4:1 wide, <= 2 MB, light colours (it sits on the dark scrim). Per-language map allowed. | Home hero title (replaces the text title), detail page. Optional (the localized `name` is used as text). |
| `hero` | WebP, JPEG or PNG | **16:9** (+-1 %), recommended 3840x2160, at least 1920x1080, <= 8 MB. Keep the important content in the **right two thirds and the upper three quarters**: the shell puts its title block and a left scrim over the left third and its row of cards over the bottom (04 §5.1). | Home hero, the 16:9 art card, the launch splash, the blurred page backdrop. **Required for Home placement**; without it the tinted tile is used. |
| `cover` | WebP, JPEG or PNG | **2:3**, recommended 1200x1800, at least 600x900, <= 4 MB. | Library grid (Cover card, 04 §5 proposed). Falls back to a centre crop of the hero. |
| `screenshots[]` | WebP, JPEG or PNG | 1 to 20, **16:9**, at least 1280x720, <= 4 MB each, localized optional caption (<= 100 chars). | Detail page gallery. |
| `trailer` | WebM (VP9 or AV1 video, Opus audio) or MP4 (H.264, AAC); `poster` image | One, <= 120 s, <= 1080p60, <= 80 MB; poster 16:9. | Detail page. See the risk below. |
| `preview` | WebM or MP4, **no audio track** | One, <= 15 s, <= 720p30, <= 8 MB, loops. | Muted loop on the Home hero a second after focus (the console-style "live" hero). Optional. |

- No animated images (GIF, APNG, animated WebP), no SVG (a parser with a long CVE history, and it can embed scripts and external references), no embedded colour profiles other than sRGB, no EXIF (stripped).
- **Video is the largest parsing surface in the package.** v1 rule: the importer validates the container and codecs with an allow-list in a sandboxed helper (no network, no files outside its input) and refuses anything else; the shell plays the vetted file with its normal media stack. Out-of-process playback is the later hardening step (open question Q5).
- The shell does not need to show every slot; slots a screen does not use are still validated at import so a package that works today does not break later.
- A `.play` made for a store carries **no ads, no price, no rating, no "buy now"** in its art or text: the store adds those from its own data.

## 6. Running things: components and runners

### 6.1 Runner kinds

| `run.runner` | Meaning | Payload is | Component |
|---|---|---|---|
| `native` | Linux x86-64 program | an ELF (or script) inside the package | none required; uses the Play platform's runtime libraries |
| `wine` | Windows program | `.exe` and data | `type: wine` |
| `proton` | Windows program through Proton, run directly (no umu, no Steam Linux Runtime, §6.4) | `.exe` and data | `type: proton` |
| `emulator` | A disc/ROM image run by an emulator | image(s), saves skeleton | `type: emulator` (an emulator build, e.g. PS3, PSP, GameCube) |
| `engine` | A game engine or interpreter that runs content (ScummVM, DOSBox, ...) | the game's content files | `type: engine` |

A package has **exactly one** `run`. (Several launch entries, "Game" and "Launcher", are v2.)

### 6.2 Components and where they come from (`source`)

`components[].source` says where the runner comes from; this is how a developer picks "small and OS-provided", "self-contained" or "either":

| `source` | Behaviour | Needs |
|---|---|---|
| `bundled` | Only the shipped copy, always. Reproducible, size cost. | `bundled` block |
| `system` | Only the OS's runner of that `type` and at least `min`. If the OS has none, the installer offers to fetch it from the official store (§18 item 7) and refuses the install without network. | `min` |
| `prefer-system` | The OS's runner if it is present and at least `min`; otherwise the bundled copy. Smallest while safe. | `min` and `bundled` |
| `prefer-bundled` | The shipped copy, unless the player chooses the system one in the game's Compatibility setting. | `bundled` |
| `newest` | Whichever of bundled and system has the higher version; a tie goes to bundled. "Bundle my tested Wine, but use the OS's if it is newer and fixes more." | `min` and `bundled` |

- `tested` is the version the developer verified. It is shown on the Compatibility screen ("Tested with Wine 9.20; running with 10.2") and is not enforced. `max_major` (optional) is enforced: a system runner with a higher major version is skipped (a developer can fence off a known break), falling back to the bundled copy or failing with a clear message.
- Versions compare only within a runner **family** (`wine`, `proton`, `proton-ge`, one per emulator id). Each runner carries a `runner.json` (family, version, architecture, entry commands, capabilities), read as untrusted data like everything else. Different families never replace each other.
- **Per-game override (the player's choice).** Settings for a game (Options menu, "Compatibility") offer "Package default", "Bundled" (if it has one) and "System" (if it satisfies `min`), plus a "Try the bundled runner" safety net after a crash. The choice is stored per profile by `ruya-library` (T-385, §18 item 3), not in the app's own `config/` where the game could change it, and cannot widen permissions, since every runner runs in the same sandbox.
- **Why not always "system"?** Wine regressions are real: a game tested on 9.20 may break on 10.x. The developer decides how much to trust the OS's runner; the player can still choose.
- **Licensing duty of bundled third-party code.** A bundled component declares its SPDX `licence`; for copyleft code (Wine is LGPL-2.1, many emulators are GPL) it must include the licence text under `licences/` and a `source_url` (or the source itself). `ruya-pack validate` checks this and the Official review enforces it. RuyaOS only provides the tool; the developer is the distributor of what they bundle.

### 6.3 Launching

- `run.command` is an **argv array**, never a shell string. Placeholders (the only substitutions): `${payload}`, `${component:<id>}` (that component's root), `${data}` (`$XDG_DATA_HOME`), `${config}`, `${prefix}` (the Wine prefix), `${disc}` (the first disc image). Anything else is literal.
- `run.env` is a **deny list**, not an allow-list (native games need variables of their own, and a package can do nothing in its own sandbox that it could not do anyway): names match `[A-Z][A-Z0-9_]*` (at most 64 bytes, so `__GLX_*` and `__EGL_*` fail the grammar) and are none of the names the platform sets. The table (`limits.rs`, `ENV_DENY_EXACT` and `ENV_DENY_PREFIX`; refused with `env.reserved`):
  - exactly: `PATH`, `HOME`, `DISPLAY`, `XAUTHORITY`, `WINEPREFIX`, `WINESERVER`, `WINELOADER`, `WINEDLLPATH`;
  - prefixes: `LD_`, `XDG_`, `FLATPAK_`, `DBUS_`, `WAYLAND_`, `PULSE_`, `PIPEWIRE_`, `SDL_`, `STEAM_COMPAT_` (the launcher sets them for GE-Proton), `VK_`, `MESA_`, `LIBGL_`, `GST_`, `QT_`, `GTK_`, `GDK_`, `GIO_`.

  `WINEDLLOVERRIDES`, `WINEDEBUG`, `DXVK_*`, `VKD3D_*`, `PROTON_*` and `MANGOHUD*` pass. At most 64 variables; values are plain strings of at most 1024 bytes without control characters.
- **`run.discs[]`** (optional, at most 16, ordered): payload files for emulated games and multi-disc sets, each a file listed in the table under `payload/`. `${disc}` is `discs[0]`; a `${disc}` in `run.command`, `run.cwd` or a setup command with no `discs` is an error (`run.disc_placeholder_without_discs`).
- `launch_mode`: `fullscreen` (default) \| `gamescope` \| `default`, the same values as `x-ruya-launch-mode` (03 §4.1).
- **Wine prefix.** `prefix` lives in the player's data directory, `~/.var/app/play.<id>/data/prefix` (one per profile, one per game), created on first run from `prefix.template` if the package has one (copied, not linked), else by the runner. `epoch` is an integer: when an update raises it, the importer's first launch backs up the paths in `data.saves`, recreates the prefix, and restores them (so a runner change that needs a fresh prefix keeps saves).
- **First-run setup** (`setup[]`): commands such as a Visual C++ redistributable, run **once per prefix, at first launch, inside the sandbox with the game's own permissions**, never at install time and never as root. They are shown on the launch splash ("Preparing the game for the first time") and have a timeout (10 minutes). A failed setup step is reported, not ignored. There is no network fetch at setup (no `winetricks` downloads): redistributables are shipped in the package.
- Under Wine the Windows `Z:` drive is the *sandbox's* root, not the host's: the Flatpak sandbox is what limits files, not Wine's drive mapping.
- **Display:** apps reach the compositor through the per-profile Wayland socket (T-164).
  - **Windows packages (`wine`, `proton`) get `sockets=x11`, not `wayland`.** They run on X11 through `ruya-session x11-run` (xwayland-satellite, ADR-034). Spike Q2 measured full screen, 60 FPS and 17 ms frames at 1080p on the Dell.
  - Wine's own Wayland driver (`winewayland`) does not start on the compositor today. It needs `wl_data_device_manager` >= 2, `wl_output` >= 3 and `xdg_wm_base` >= 2, plus pointer constraints and relative pointer for mouse-look. It becomes an option after a compositor task.
- **The launcher owns `WINEPREFIX`.** A package-set `WINEPREFIX=/tmp/...` would silently put the prefix in the sandbox's tmpfs, so saves would be lost at exit (spike Q4). `run.env` refuses it (§18 item 21).
- **32-bit Windows code** needs `--allow=multiarch` and the `Compat.i386` (and `GL32`) extensions: without them Flatpak's seccomp kills it with SIGSYS (spike Q4). Flathub's Wine 11 and GE-Proton 11 both use the old WoW64 layout (`i386-unix`).

### 6.4 The Play platform (what the sandbox contains)

Proven by the T-229 spike (RUY-91, 2026-11-16, Q1): the package is installed as a Flatpak **app** whose runtime is the freedesktop platform plus **extensions we publish on the `ruyaos` remote**. Installing the app pulled the declared launcher extension on its own (a related ref), and `command=` may be an absolute path into that extension (`/app/launcher/bin/ruya-play-launch`).

- `org.ruyaos.Play.Launcher`: the small launcher (`ruya-play-launch`) that reads `/app/play.json`, resolves components (§6.2), prepares the prefix, applies the env allow-list and `exec`s the runner. One launcher for every package, updated with the OS or the Store, so a launcher fix reaches every game.
- `org.ruyaos.Play.Runner.Wine//<major>`, `...Proton...`: **system runners**, one extension branch per major version, updated by the Store, shared by all packages (this is what makes `source: system` cheap). They bundle DXVK and VKD3D-Proton as part of the runner.
- Support libraries a game commonly wants (32-bit compat, gamescope, MangoHud, GameMode) as extensions the app may mount.

**The image preinstalls the Wine runner** (owner, 2026-11-06, D3), so a Windows package with `source: system` works offline from the first boot; the Store still updates it independently of the OS. **RuyaOS provides only Wine as a system runner** (amended by ADR-025, owner 2026-11-09: GE-Proton is preinstalled and the default; Wine, Wine-GE, UMU-Proton and other builds are Store runners, chosen per game) (owner, 2026-11-06). Proton and its Steam Linux Runtime, emulators, console firmware and BIOS files are never shipped or hosted by RuyaOS: a packager who needs them bundles them (as `components[]` with `source: bundled`) and carries the licence and distribution duty. **Proton without its container (spike Q3).**
- Proton through umu and the Steam Linux Runtime (pressure-vessel) does **not** run inside the sandbox on Flatpak 1.18.4. The sub-sandbox portal is reachable, but its `--usr-path` / `--app-path` fails ("Can't find source path /proc/self/fd/N"); without the portal, pressure-vessel exits 125.
- So in v1 a Proton runner (the preinstalled GE-Proton, or a bundled one) runs **directly**, without umu and the runtime, like a Wine runner. It needs `STEAM_COMPAT_DATA_PATH` under `${data}` and `multiarch`, and it runs on the X11 path. Measured: 60 FPS; 2.2 s to the game's GL load with a fresh 280 MB prefix, 1.6 s warm.
- A package that bundles the Steam Linux Runtime is unsupported until a Flatpak with a working portal passes the re-test in `scripts/spikes/play/q3-proton.sh`. If that ever becomes supported, the runtime is one shared extension, never 696 MB per profile and app (umu's default).

## 7. Installing

### 7.1 Where things live

Design confirmed by the T-229 spike (RUY-91, Q1; it keeps every existing service working):

- **Install = import as a system Flatpak app** named `play.<id>`, built by the importer from the package and committed to the system Flatpak installation (`/var/lib/flatpak`, the same place and the same machinery as every other app). Consequences, all by reuse: the app is shared by profiles; per-profile data is `~/.var/app/play.<id>/{data,config,cache}` (03 §4.5a, so backups, "Keep saves?" and storage sizes already apply); `ruya-store` lists, updates, rolls back (`Rollback`) and uninstalls it; `ruya-library` finds it (exported desktop entry, `Game` category); `ruya-session` launches it (`flatpak run play.<id>`); permissions are Flatpak's. OSTree stores files by content hash, so **two packages that bundle the same Wine build share one copy on disk**.
- The importer adds to the app's `/app`: `play.json`, `play.files`, `play.sig`, the vetted art (`/app/share/ruyaos/play/art/`), the payload and bundled components. Its Flatpak metadata (`command=ruya-play-launch`, permissions) is **generated from the manifest** by the importer; the package never supplies Flatpak metadata, so it cannot request what §8's vocabulary does not allow.
- Trust of the generated commit: after the importer verified the package's signature (§9), it signs the OSTree commit with a **device-local key** generated on first use (root, 0600, under `/var/lib/ruya-play/`, never in the image, never in the repo). Flatpak verifies that signature as with any remote, so `ruya-store`'s rule "never `--no-gpg-verify`" is unchanged. The local key only says "this device's importer accepted this package", which is what we want.
- The package file itself is not needed after install (a USB stick can be removed). Keeping or deleting the downloaded copy is the player's choice.

**What the commit step must do (spike Q1, Flatpak 1.18.4):**
- Create every extension point's mount directory in `/app`. Otherwise bwrap fails at run time ("Can't mkdir parents ... Read-only file system").
- Write the app's own `share/applications/play.<id>.desktop` (category `Game`). Without it nothing is exported, and exports not named after the app id are refused.
- Use `install --or-update`: a plain `install` of an installed ref does nothing.
- Use a **`bare-user-only` staging repo on the same reflink-capable filesystem as `/var/lib/flatpak`** (XFS on the image). The Dell measured these numbers:

| Payload | Repo mode | Commit | Install | Disk peak | A second app with the same files |
|---|---|---|---|---|---|
| 20 GiB | `bare-user-only` | 52 s | 0.4 s | 1.03x the payload | +0 bytes |
| 20 GiB | `archive-z2` | 472 s | 117 s | 3.1x | +0 bytes |
| 2 GiB | `bare-user-only` | 5.3 s | 0.6 s | 1x | +0 bytes |

Two apps that bundle Flathub's 430 MB Wine tree added 23 MiB in total, because they share objects with the installed `org.winehq.Wine`.

The bubblewrap fallback is not needed: the spike confirmed the Flatpak route (ADR-014, "Spike result").

### 7.2 Who may install

Follows 03 §4.4. Admins install directly. A Standard profile may install a package whose permissions are all low or medium risk; anything with a high-risk permission needs an admin PIN (same dialog as the Store). `unverified` packages need **developer mode** (an admin setting, default off, red "Unverified" badge on every screen that shows the app) and are limited to low and medium permissions. A restricted profile (parental controls, T-211) cannot install.

### 7.3 The import pipeline (what `ruya-play` does)

1. **Open** the source read-only (a USB path or a downloaded file in `/var/lib/ruya-play/incoming/`). Removable media is mounted `nosuid,nodev,noexec`.
2. **Inspect** (unprivileged helper, no network, no access outside its input and a staging directory; started by the service as a transient systemd unit with `DynamicUser=yes`, `PrivateNetwork=yes`, `ProtectSystem=strict`, `NoNewPrivileges`, a system-call filter, memory and CPU limits and a time limit): parse `play.json`, `play.files`, signatures, apply every rule of §4. This is the cheap step; the shell's package page (name, art, permissions, size, trust badge, signer) is built from its result, so a player sees the app *before* a single payload byte is copied.
3. **Confirm** (shell): permissions in plain words, size, trust tier, update behaviour, "Install". Nothing was written beyond a small staging manifest.
4. **Unpack** (same helper, same limits): stream entries into staging on the target filesystem (free space was checked up front), hashing as it goes; every hash must match `play.files`; art and video are decoded and re-encoded here, never in the shell or in the root service. Progress goes to the shell (`JobProgress`-style).
5. **Commit** (the root part of the service, small): re-walk the staged tree without following links (names, kinds, modes; the helper's uid is gone, nothing else can write), recreate links and modes from `play.files`, generate the Flatpak metadata, build and sign the OSTree commit, install it. Any failure removes the staging directory; there is no half-installed package.
6. **Announce** `InstalledChanged` so the library updates (the Store/Library services already react).

Re-verification: "Verify files" in the app's options re-hashes the installed payload against `play.files` (cheap defence against disk corruption; OSTree also checks its own objects).

## 8. Permissions

A closed vocabulary. The manifest requests; the importer maps each entry to the Flatpak permission set of the generated app; the shell shows each in plain words before install; the effective set is the request **capped by the trust tier** (and can be reduced by an admin, 03 §4.4).

| Key | Values | Maps to | Risk | Plain words |
|---|---|---|---|---|
| (always) | | Wayland socket, GPU (`--device=dri`), audio (PulseAudio socket via the session service), the app's own data directory | low | "Plays sound, uses graphics" |
| `input` | `controllers` \| `controllers+keyboard-mouse` (default) \| `all-devices` | controllers and keyboards through the compositor; `all-devices` = `--device=all` | low / low / **high** | "Uses controllers" / "...and keyboard and mouse" / "Accesses all devices" |
| `network` | `false` (default) \| `true` | `--share=network` | medium | "Uses the network" |
| `removable_media` | `none` (default) \| `read` \| `write` | read-only or read-write access to mounted drives under `/run/media` | medium | "Reads / changes files on USB drives" |
| `multiarch` | bool | `--allow=multiarch` (32-bit Wine) | medium | "Runs 32-bit programs" |
| `microphone`, `camera`, `bluetooth` | not in the vocabulary yet | no portal backend exists (§18 item 12): a package that asks is refused with `permissions.unknown_key`, not silently reduced | | |
| `gamemode`, `realtime` | bool | talk to GameMode only; no other bus names | low | "Asks the system to prioritise it" |
| `devel` | bool | `--allow=devel` (ptrace, perf), needed by rare anti-tamper | **high** | "Can inspect other programs" |
| `reasons` | map key -> localized text (<= 120 chars) | shown next to the permission | | the developer's own words |

- **No host filesystem access, no session or system bus names, no `--talk-name`, no `--filesystem` of any other path, no access to other apps' data, no portal override**, because those keys do not exist in the vocabulary. A package that needs them is not a `.play` (it is a Flatpak and goes to Flathub or the developer remote).
- **Ceilings by trust tier:** `official`: low, medium, high (high needs the Official review and the admin gate); `developer`: low and medium freely, high with the admin's PIN and a warning; `unverified`: low and medium only (a high request makes the package uninstallable, not silently reduced).
- Permissions are **static** (03 §4.4). An update that adds one is shown as "The update adds: ..." and, when it adds a high-risk one, needs the admin's PIN, exactly as T-156 does for Flatpak updates.
- The platform, not the package, sets resource limits on the running scope: memory and task limits (a runaway game cannot take the whole console down), and CPU weight lower than the shell's.

## 9. Security model

### 9.1 What an attacker controls, and what stops them

| Threat (a hostile or compromised package, USB stick or update server) | Defence |
|---|---|
| Path traversal, absolute paths, odd Unicode, case-collision tricks, device files | §4.2 rules checked on names before content; extraction by an unprivileged helper into staging; commit walks without following links. |
| Symlink / hard-link escape from an archive | Links exist only as data in `play.files` (relative, in-tree, one hop); real links in the package are invalid; the importer creates them. |
| Zip bomb, huge file counts, endless nesting, slow parsers | Size, count, ratio, depth and time limits; free-space check first; helper under memory/time limits. |
| Malformed JSON / schema abuse | Size and depth caps, strict schema for the security-relevant sections, no dynamic evaluation of anything. |
| Image/video decoder exploits | Decoding only in the sandboxed helper; allow-listed formats; re-encode so the shell and the library load only vetted, canonical files; no SVG, no animated images. Video playback hardening is Q5. |
| Install-time code execution | None exists: no hooks or scripts. Setup steps run at first launch inside the sandbox. |
| Privilege through file attributes | setuid/setgid/caps/xattrs dropped; modes normalised; files owned by root and read-only in the Flatpak deployment. |
| Asking the sandbox for too much | Closed permission vocabulary; ceilings per tier; admin PIN for high risk; the manifest never supplies Flatpak metadata. |
| Impersonation (a game that is called "Settings" or copies another game's icon and name) | Reserved names, `id` uniqueness (installing over an existing id needs the same signing key, §11), signer shown on the detail page, the Official tier is the only "verified" label. |
| Reading other profiles' or other apps' data | Unix profile homes (0700) and per-app Flatpak data dirs; the Wine prefix is per profile and per game; the sandbox has no path to anything else. |
| Network exfiltration | `network: false` by default, shown on the page; a game without it cannot phone home. |
| Tampering after install | Read-only deployment; OSTree object checks; "Verify files". |
| TOCTOU between verify and use | The helper's identity is exclusive and gone before commit; commit re-walks without following links; files are copied into OSTree, not used in place from the stick. |
| A bundled runner with a known vulnerability | `source: newest/prefer-system` lets the OS's fixed runner win; the revocation list (below) can disable a runner by hash; the Store shows "uses an old Wine". |
| Malicious update (key takeover, downgrade, redirect, replayed old feed) | §11: same-key rule, `build` only increases, signed feed with `expires`, https with a pinned host, the service (not the game) downloads. |
| USB autorun | Never: nothing is opened until the player chooses "Install from USB"; step 2 reads data only. |
| Compromise of the Official store | The `official` badge needs two things (developer key *and* store key); revocation can be pushed by the OS image's pinned root key; the OS signing key is separate from the store key. |

### 9.2 Signatures and trust tiers

- **Signing is Ed25519** (recommended; T-231 fixes the exact encoding and whether to reuse an existing format such as `ssh-keygen -Y sign` or minisign so developers need no new tool). `play.sig` is a small statement `{ "format": 1, "id": "...", "build": 142, "play_json_sha256": "...", "play_files_sha256": "...", "signed_at": "...", "signer": { "key_id": "...", "name": "..." } }` plus the signature and the public key. Because `play.files` lists every other file's SHA-256, **one signature covers the whole package**. Signatures are checked before anything else is believed.
- **`store.sig`** is the same statement countersigned by the RuyaOS store key (public half baked into the image, rotatable through an OS update). Present only on packages the store reviewed and built; it is what makes the tier `official`.
- **Tiers:** `official` (valid developer signature *and* `store.sig`), `developer` (valid signature by a key the player's console has not seen revoked), `unverified` (no signature, an invalid one, or a key an admin has not allowed; developer mode only). A *bad* signature is never downgraded to `unverified`: it is an error ("This package was changed after it was signed").
- **Key continuity (trust on first use).** The first time a signing key installs an id, the console records `id -> key_id`; later installs and updates of that id must be signed by the same key, or by a **rotation statement** (the old key signs "key B takes over for id X"). The detail page shows "Signed by Example Games (key 3f9a...c01), first installed on ..." with the fingerprint always visible to an admin.
- **Revocation.** A signed `revoked.json` (key ids, id+build ranges, content hashes, runner hashes), distributed via the `ruyaos` remote metadata through `ruya-store`, cached on the device. A revoked package stops launching and the shell says "Removed for safety: ..." with the reason text; the player can uninstall but not run. Offline devices use the cache; a stale-cache policy (and whether the list is fetched without the Store being in use) is open (Q6).
- **Where private keys live:** only on developers' machines (`ruya-pack sign` reads a key file or an agent). Never in this repo, the image, or CI logs.

### 9.3 Rules for the code that handles packages

1. Everything inside a package is **untrusted data**: names, text, JSON, images, video, hashes, even sizes.
2. Parsing and unpacking never run as root and never in the shell process or in `ruya-library`.
3. Only the small commit step runs privileged, and it re-validates paths and kinds itself.
4. A package never reaches a `Command` string: argv arrays only; no shell, no `sh -c`.
5. Display strings are escaped for the target (QML text with `Text.PlainText`; never rich text from a package).
6. Every limit is a named constant tested at, below and above the boundary, with a fixture package for each hostile case (T-230, T-237).

## 10. Data, saves and uninstall

Follows 03 §4.5a without change: per-profile `~/.var/app/play.<id>/{data,config,cache}`; recommended layout `data/saves`, `data/states`; `data.saves` / `data.cache` in the manifest declare paths for backup (T-215), written with a root name: `data:` (XDG data), `config:`, `prefix:` (inside the Wine prefix, where Windows games keep `Documents/My Games/...`). Uninstall keeps data by default ("Keep saves?"); an OS update never touches `/var`. Emulator saves and states belong in `data:` so they survive an update of the game or the emulator.

## 11. Updates

Principle: **updates are signed, ordered by `build`, run by the OS and never by the game.** There are three ways, in priority order.

1. **From a store (replaced by §18 item 1 and `10-stores.md` §11: the store's signed index, the same importer; the text of this item is the old design).** If the package was installed from the `ruyaos` or a developer remote, `ruya-store` updates it like any other app (OSTree deltas, `Rollback(id, commit)`, the permission-diff flow). The manifest's `update` block is ignored. This is the recommended path for anything distributed publicly: one trusted place, one update mechanism, no per-game servers contacted. *Yes: the Store should be the update channel for Store packages.*
2. **Self-hosted feed (sideloaded packages).** `update.feed` is an https URL of a signed JSON feed:
   ```json
   { "format": 1, "id": "com.example.starhopper", "channel": "stable", "expires": "2026-12-31T00:00:00Z",
     "releases": [ { "version": "1.4.3", "build": 143, "released": "2026-11-01",
                     "notes": { "en": "Fixes the second boss." }, "min_os": "0.1",
                     "url": "https://example.com/files/starhopper-1.4.3.play.zip",
                     "size": 4900000000, "sha256": "..." } ] }
   ```
   plus `feed.json.sig` by the **same key** that signed the installed package (or a rotation). Rules: the feed host is the one in the installed manifest (redirects must stay on its registrable domain); `expires` must be in the future (stale feeds are ignored, which defeats replaying an old feed that hides a fix); only `build` greater than the installed one is offered (a downgrade is never an update); the download is performed by `ruya-play`, written to `incoming/`, **verified and imported exactly like an install** (§7.3), including the permission diff and the same-key rule. The shell shows "Update available: 1.4.3 (4.9 GB) from example.com".
   - **Privacy:** checking a developer's server tells that server this console's IP and the game. So sideloaded packages ask once at install ("This game can check example.com for updates. Allow?", default **No**), the choice is a per-app toggle in its options, and checks happen only when the console is idle and online (and the game's page was opened or weekly). Store-installed packages never contact the developer.
   - Never while the game runs; never silently when the update adds a permission; `Update automatically` is available for the `official` tier only, off by default elsewhere.
3. **By hand:** the player installs a newer `.play` over the old one (from USB or a download). Same verification; same-key rule; keeps the data. A package with a different key for the same id is refused with "This isn't the same developer".

Details:
- **Rollback:** the previous deployment stays until the next successful launch of the new one; "Roll back to 1.4.2" uses `Store1.Rollback`. A downgrade that is not a rollback of an installed deployment is refused.
- **Prefix / runner changes** are handled by `epoch` (§6.3). A runner update (system Wine) is an update of the extension, not of the game; the Compatibility screen shows the runner in use, and "Try the bundled runner" is the escape.
- **Delta updates (not v1):** `play.files` already hashes every file, so a future feed can list changed files only and the service can fetch just those objects (HTTP range / object URLs); Store builds already get OSTree deltas.
- **Size accounting:** an update downloads the whole new package in v1. The feed's `size` is shown before the download; the free-space check covers old + new.

## 12. Shell integration

- **Library and Home.** A `.play` is an installed Flatpak; `Library1` lists it with the vetted art (extend the contract: art paths, genres, players, controller, age rating; the T-163 service already reads the exports directory). The Home hero uses `hero`, `logo` and the genre tint; the card uses the 16:9 crop; `preview` loops on the hero after a second of focus.
- **Canonical art written by the importer:** `icon` 512, 256, 128; `hero` 3840x2160 (kept if smaller, never upscaled) and 1920x1080; `card` 960x540; `cover` 600x900; screenshots 1920x1080 plus 480x270 thumbnails, all WebP.
- **Detail page** (a package or a Store app): source/trust badge, signer, version, size, genres, players, controller, age label, permissions in plain words, runner (with "Compatibility"), screenshots and trailer, links (text and QR), "What's new" from the changelog, update state.
- **Install from USB:** Settings or Store -> "Install from USB" lists the packages on mounted drives (data only), then the confirm flow of §7.3. Controller only, like every flow.
- **Options menu** (T-221): Update, Roll back, Compatibility, Verify files, Check for updates (toggle), Remove (with Keep saves?).
- **Launch** is `Session1.Launch(play.<id>, profile)` as for any app; crash, quit and `launch-failed` reporting are unchanged. The launch splash uses the hero.

## 13. Developer tooling (`ruya-pack`)

A command-line tool for developers (Windows, Linux, macOS; Rust, MIT OR Apache-2.0; the format library it uses is the same crate as the verifier, so a package the tool accepts is a package the console accepts):

| Command | Does |
|---|---|
| `ruya-pack init` | Writes a skeleton `play.json` and folders. |
| `ruya-pack validate <pkg>` | Runs every rule of §4 to §9 that can run off-device: schema, paths, art sizes and aspect ratios, licence duties of bundled code, permission vocabulary, a size/memory estimate, and a dry run of the resolution logic of §6.2. Errors are specific and fixable ("hero is 1920x1200, needs 16:9"). |
| `ruya-pack build <dir> [-o out.play.zip]` | Creates `play.files`, normalises the layout, builds a **deterministic** zip (sorted entries, fixed timestamps, so the same input gives the same bytes and a build can be re-verified). |
| `ruya-pack sign <pkg> --key <file>` | Writes `play.sig`. `ruya-pack keygen` makes a key. |
| `ruya-pack inspect <pkg>` | Prints what the console will show: name, permissions in plain words, tier, signer, size, runners. |
| `ruya-pack run <pkg>` | On Linux with RuyaOS tooling or on a console in developer mode: install and launch for testing. |

A developer guide chapter and two sample packages (a native Linux one, a Windows one on Wine with `source: newest`) are part of the epic (T-243).

## 14. Content, legal and policy notes

- **Decided (owner, 2026-11-06):** RuyaOS ships and hosts **no** emulators, Proton or Steam runtime, console firmware, BIOS files, discs or ROMs (03 §5); packagers include what their game needs and are responsible for having the right to distribute it. RuyaOS therefore carries no distribution duty for those; the only third-party runner it ships is Wine (LGPL, source offer in the runner pack, T-244). The developer guide says this in plain words. If RuyaOS ever hosts packages itself (an Official remote), hosting is distribution: that remote's acceptance rules are a separate, later decision (D2, narrowed).
- A package's bundled third-party code (Wine, Proton, emulators) carries its own licences and a source offer (§6.2); `ruya-pack validate` checks it, and a remote that hosts packages may enforce it.
- Anti-cheat titles that block Linux remain unsupported (00 §2 non-goals).
- Age rating comes from the developer's OARS answers; the Official review spot-checks; an unreviewed package's rating is labelled "Developer's rating".

## 15. Compatibility and versioning of the format

- `format` is a major number; additive fields keep it; a new required behaviour bumps it. A console supports every major it knows and refuses newer ones with "needs a newer RuyaOS". Developers can keep a package readable by an older console by not using newer fields (the validator has `--target-os`).
- The schema file `api/play/play.schema.json` is the machine-readable contract (like `api/dbus/*.xml`: a draft until the first release, extend it in the same commit as the code that uses it). It states the shapes, vocabularies and numbers; the crate `services/ruya-play-format` is the only parser and applies the rules a schema cannot (the file table, paths, cross-references, reserved ids and names). `tests/schema.rs` keeps the schema's numbers and vocabularies equal to the crate's constants. Strict objects (`permissions`, `run`, `components`, and the objects inside them) refuse unknown keys with `permissions.unknown_key`, `run.unknown_key` or `component.unknown_key`; a `format` above the one the crate knows gives `format.too_new` and nothing else is checked.
- The `play.` Flatpak id prefix and the `${...}` placeholders are part of the format; changing them is a major bump.

## 16. Open questions (answered by the spike or the owner)

| # | Question | Who | Default if unanswered |
|---|---|---|---|
| Q1 | Does the "import as a Flatpak app signed by a device key" route work with the pinned Flatpak (extension mounts for launcher and runners, `command`, generated metadata, signed local commit, size of the commit step for a 30 GB payload)? | T-229 | *Answered (RUY-91, 2026-11-16): yes.* GPG checks stay on, and the launcher extension installs as a related ref. A 20 GiB payload commits in 52 s and installs in 0.4 s, with a 1.03x disk peak (`bare-user-only` staging on XFS). What the commit step must do: §7.1. No bubblewrap fallback. |
| Q2 | Windows games need X11 or Wine's Wayland driver: Xwayland in the compositor, or Wine >= 10 with `winewayland`? Fullscreen, controllers, vsync and gamescope with either? | T-229 (and a compositor task) | *Answered (RUY-91): X11 through xwayland-satellite for v1* (full screen, 60 FPS at 1080p, composited, so no tearing path). `winewayland` (Wine 11, GE-Proton 11) refuses the compositor's protocol versions: §6.3. Controller input under Wine and gamescope were not tested (no pad connected): open for T-239. |
| Q3 | Can a *bundled* Proton / Steam Linux Runtime (pressure-vessel) nest inside the sandbox (sub-sandbox portal)? Packagers supply it; this only decides whether we document it as supported. | T-229 | *Answered (RUY-91): not on Flatpak 1.18.4.* The portal's `--usr-path` fails. GE-Proton without the runtime works, and is the v1 path (§6.4). Documented as unsupported; re-test on a newer Flatpak with `q3-proton.sh`. |
| Q4 | Emulators: packagers bundle them (decided). Open: does the format need an `emulator` capability check (e.g. needs GPU API X)? | lead | No; `requirements.gpu_api` is enough. |
| Q5 | Trailer playback: vetted file with the shell's media stack (v1) or an out-of-process player? | lead, T-242 | v1 as in §5; hardening later. |
| Q6 | Revocation freshness: how old may the cached list be, and what happens past that? | lead, T-231 | Warn but still allow. |
| Q7 | Per-profile installs (one profile's private game) versus system-wide only. | owner | *Decided (owner, 2026-11-17): system-wide only*, like all apps (03 §4.1): every profile sees an installed package, and its data stays per profile. |
| D1 | *Decided 2026-11-06:* ADR-014 accepted, conditional on the T-229 spike confirming the Flatpak route. | owner | Done. |
| D2 | *Decided in part (2026-11-06):* RuyaOS ships no emulators, Proton, firmware or discs. Open only if we host packages: what an Official remote accepts. | owner, later | No Official `.play` remote in v1. |
| D3 | *Decided 2026-11-06:* the image preinstalls the Wine runner (T-244 reports the size cost). | owner | Done. |

## 17. Tasks

Epic **T-228** and tasks T-229 to T-243 (the list is in the epic file; T-244 was dropped into T-385); `.play` in stores is T-446; the verification split follows the root `CLAUDE.md` (host-verifiable core first, image and VM work after the spike).

## 18. Review of this draft (lead, 2026-11-10): what to fix before T-230 starts

*Built in RUY-92 (T-230): items 8, 9, 10, 12, 15, 21 and 24 are in the format crate and `api/play/play.schema.json`; items 11, 13, 14, 16 to 20, 22 and 23 belong to later tickets (T-231, T-237, T-239 and the importer).* Found while planning stores (ADR-032, `10-stores.md`). Nothing here is built, so nothing is broken yet; each item names where it gets fixed. **A to D change the design and win over the sections above; the rest are corrections for the first task that touches the section.**

**A. Decided here (the text above is stale where it differs)**
1. **Stores carry `.play` files, never ready-made `play.<id>` Flatpaks** (`10-stores.md` §11). §11 way 1 ("OSTree deltas, like any other app") is replaced: every install and update, from any store, a feed or a USB drive, goes through the one importer. Reason: a store-built Flatpak would bring its own Flatpak metadata and art, the two things §7.1 and §5 say a package never supplies.
2. **One Flatpak transaction queue.** `ruya-play` builds and signs the commit; installing it into `/var/lib/flatpak` is a job of `ruya-store`'s queue (ADR-011, ADR-026). §7.3 step 5 read as if two root services ran Flatpak transactions side by side. The device-local origin is a built-in, hidden store that nothing can remove or shadow (`10-stores.md` §3.1).
3. **The per-game runner choice is not stored in the app's own `config/`** (§6.2): the game can write there, so "the player decides" would not hold. It is kept by `ruya-library` (T-385, one mechanism for every Windows game, ADR-025).
4. **Sideloading needs an admin (owner, confirmed 2026-11-10).** §7.2 let a Standard profile install any signed low or medium package from a USB stick, system-wide, for every profile; a signature proves nothing about a stranger's key (§0.7). Store and USB installs follow `10-stores.md` §4: an admin, or an admin's PIN.

**B. Contradictions with later decisions**
5. **Runners (ADR-025, 2026-11-09).** §6.4, §14, Q3 and D3 still say Wine is the only system runner and Proton is never shipped; GE-Proton is now preinstalled and the default. So Q3 (does Proton's container nest inside the sandbox) is no longer optional: it decides whether the default runner works for `.play` at all, and is the first question of T-229. *Answered (RUY-91):* the default runner works for `.play`, but only without its container (§6.4).
6. **Words.** The tier `developer` and "developer remote" collide with the store trust `third-party` and with "developer mode". Keep the tier names, write "third-party store" for the place.
7. **Revocation (§9.2, Q6)** assumed the `ruyaos` remote; with D2 there is none in v1. It is one file with the store blocklist, shipped in the image and changed by OS updates (`10-stores.md` §6); a fresher copy from the official store is later. T-241 owns what an installed, revoked package does.

**C. Things the format cannot express today (T-230 must settle them in the schema)**
8. **Wine prefix templates do not fit the path rules.** A prefix has `dosdevices/c:` and `z:` (a colon in a name, forbidden by §4.2) and `z:` points at `/` (an absolute link, forbidden). Rule: a template never contains `dosdevices`; the launcher creates it.
9. **Real runner trees do not fit the link rule.** "A link must not point at another link" refuses the usual `libx.so -> libx.so.1 -> libx.so.1.2` chains of a bundled Wine or emulator. Allow chains up to 8 hops that stay inside the same top-level directory; `ruya-pack build` flattens what it can.
10. **Emulated games have no manifest fields.** `${disc}` exists (§6.3) but nothing declares discs, their order, or a multi-disc set. Add `run.discs[]`.
11. **"Timestamps from the manifest's build time"** (§4.2): the manifest has no such field. Use `play.sig`'s `signed_at`, or a fixed epoch for unsigned packages.
12. **`permissions` that have no mapping yet:** `microphone`, `camera`, `bluetooth` are "as the platform provides", and there is no portal backend (03 §4.4). Until one exists they are not in the vocabulary (an unknown key is an error, §4.1), and raw `bluetooth` is high risk, not medium.
13. **Combinations.** `network` with `removable_media`, `microphone` or `camera` is a way out for the player's files or voice: the pair counts as high risk even though each alone is medium.
14. **`multiarch`** needs 32-bit runtime extensions that the console may not have offline; say where they come from (the official store) and that the install fetches them or refuses, like `source: system`.
15. **Flatpak id grammar.** `play.<id>` must be a valid Flatpak id: check the `-` rule and the length for the prefixed form, not only for `id`.

**D. Security and data gaps**
16. **Kept saves and a different key.** After an uninstall with "Keep saves", a package with the same `id` signed by another key may be installed (the `id -> key` record: is it kept after uninstall? unspecified) and would inherit `~/.var/app/play.<id>`. Rule: the record survives uninstall while any profile keeps data for the id; a different key is then refused, and an admin can "Forget this game's data and key" to free the id.
17. **Squatting an id.** The first package to claim an id on a console owns it (trust on first use); the genuine game is then refused as "not the same developer". The same admin action as item 16 is the way out; the message must say so.
18. **A developer who loses the key** has no rotation path (rotation needs the old key). Say it plainly in the guide: players must remove and reinstall (item 16), or the official store's countersignature decides.
19. **Feeds (§11 way 2).** "Redirects must stay on the registrable domain" needs a public-suffix list on the console: use the exact host. `expires` needs a correct clock, and a console can boot offline with a wrong one: a feed is also refused when its newest release is older than the installed build's `signed_at`. A feed signed with the package key keeps that key on a web server: allow a feed key delegated by the package key (one statement, like rotation).
20. **Disk space.** A downloaded 30 GB package needs the archive, the staging copy and the OSTree objects unless staging and repository share extents; §11 only says "old + new". T-229 measures the peak and the importer checks that number before the download. *Measured (RUY-91):* the staging copy is the whole peak, about 1.03x the payload, while staging, the local repo and `/var/lib/flatpak` share one reflink-capable filesystem. The check asks for archive + payload + 5 % there, and for archive + 2x payload anywhere else. A filesystem without reflinks was not measured.
21. **`run.env` is a deny-list, called an allow-list** (§6.3): `WINEPREFIX`, `WINESERVER`, `VK_ICD_FILENAMES`, `VK_LAYER_PATH`, `GST_PLUGIN_PATH`, `QT_PLUGIN_PATH` pass it and break what the platform sets. Not an escape (the package runs its own code in its own sandbox either way), but make it a real allow-list of prefixes. *Seen in RUY-91 (Q4):* `LD_PRELOAD` reaches the process, `VK_ICD_FILENAMES` can leave the game with no GPU, and `WINEPREFIX=/tmp/...` loses saves. So the list also leaves out `WINEPREFIX`, `VK_*`, `__GLX_*`, `__EGL_*`, `MESA_*` and `LIBGL_*`.
22. **Threats missing from §9.1:** a hostile store index (answered in `10-stores.md` §11.1), a hostile `runner.json` in a bundled component (it is parsed by the launcher inside the sandbox: fine, but say so), and a child profile seeing a system-wide package whose rating is the developer's own claim (T-211: treated as not rated).
23. **USB limits.** A `.play.zip` over 4 GiB does not fit on FAT32, the commonest stick format; the folder form does unless one file is over 4 GiB. `ruya-pack build` warns; the guide recommends exFAT. A stick pulled during import is a clean failure (staging removed): add it to the hostile-case fixtures.

**E. Small**
24. (*Built in RUY-92: computed.*) §12 "Options menu (T-221)" is T-393/T-394; "Library1 ... T-163" is as built. §13 `ruya-pack` gains `index` (`10-stores.md` §11). `requirements.installed_mb` duplicates the file table: compute it, do not declare it.
25. Runner extensions pile up (one branch per major): who removes a major no package uses, and what a package pinned by `max_major` does when that major is gone, is not said (T-239).
