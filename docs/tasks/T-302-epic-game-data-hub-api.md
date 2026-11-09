# T-302 — EPIC: the game data hub (ROM folders, save and capture paths, now-playing metadata) as an OS API

Status: todo · Phase: 5 · Depends: — · Area: docs · Size: M · Owner: lead · Developer surface: public-API

## Goal
RuyaOS becomes the hub between game apps: an emulator asks the OS where the SNES ROMs are, where to put saves, states, configs, screenshots and recordings; the OS in turn learns from the app what is being played (game, emulator, core, settings, state) and exposes it to the shell and to other apps that are allowed to see it. Owner request, 2026-11-07: "an os level api for rom management ... where it can find roms for SNES, where it should save save states, saves, configs, screenshots, screen recordings ... the os can ask the app for metadata ... who was playing, which emulator, which settings ... use Ruya also as a hub between apps that can use this data".

## What exists (checked 2026-11-08)
- Built: the per-profile app data convention (03 §4.5a: `~/.var/app/<id>/data|config|cache`, recommended `saves/ states/ screenshots/`), `ruya-library` (Library1), `ruya-session` (Session1, play ledger T-247), the sandbox rules (`docs/developers/permissions-and-sandbox.md`, `saves-and-data.md`).
- Planned: T-215 save backup (needs to know which paths are saves), T-259 emulator frontend (finds ROMs itself today), T-246 achievements, T-264 player slots (who is playing), T-220 privacy/per-app permissions, T-250/ADR-015 app platform, T-217 controller mapping per system.
- Missing (this epic): a standard system list and ROM layout, a sandbox-reachable API for paths and metadata, captures owned by the compositor, a now-playing exchange, permissions, a developer guide.

## Use cases the design must serve
1. Emulator start-up: "ROM roots for `snes`" (the profile's folder, shared console folder, ROM folders on mounted USB drives), "where do I write saves/states/config/screenshots for this game", "who is player 1".
2. The player takes a screenshot or a clip from the Guide menu, in any app: the OS saves it with the game name, time and profile in one Captures library; the emulator needs no code.
3. The Library shows "Super Mario World · SNES · RetroArch (snes9x) · 2 h 10 min · last save 12 Nov" without a scraper: the app (or the OS) reports it.
4. Backup (T-215) knows saves from states and configs by kind, per game, across emulators.
5. Other apps (stats, a friends/presence app, a scraper for art, a stream overlay) read now-playing and the Captures library, each only with the permission the player granted.
6. Settings snapshots (shader, scale, input mapping per system) travel with a profile and can be shared between emulators that opt in.
7. **External drives are first-class.** ROM libraries often live on a USB drive, an SD card or a second internal disk: the hub names every drive's `RuyaOS/ROMs/<system>/` as a root with a stable identity (the filesystem UUID, not the mount path), says whether it is writable and currently present, and tells apps when it appears or goes away. A game whose drive is unplugged stays in the Library greyed with "Insert <drive name>" instead of vanishing, and its saves (on the console) are untouched. Captures may be stored on a drive (a player choice with a console fallback when it is missing); backups of saves go to a drive (T-215). Network shares (SMB/NFS) are a later root type with the same shape.

## Model (ADR-020, Accepted by the owner 2026-11-08, in `00-overview.md`)
A system service `ruya-hub` (`org.ruyaos.Hub1`), an **internal service behind `Platform1`** (ADR-022: no sandbox reaches it directly; the app-facing calls are an interface of `Platform1`, T-352, which identifies the app and profile and checks the player's permission; the shell and root reach `Hub1` itself), answering per profile: `RomRoots(system)`, `Paths(kind, game?)` with kinds `saves|states|config|screenshots|recordings|mods`, `Identify(file)` (stable game id: content hash, optional offline DAT match), `NowPlaying` push from the app (`Report{game, system, emulator, core, settings summary, state}`), `Players()` (ADR-017 slots), and signals for the shell and permitted clients. System ids follow libretro/No-Intro naming (`snes`, `nes`, `gba`, `psx`, ...). Captures are made by the compositor (the shell), not by apps. RuyaOS ships no ROMs, BIOS or emulators (owner, 2026-11-06); nothing scans removable media without an explicit player action (invariant).

## Children
T-303 spike and spec (lead): systems list, layout, sandbox reach · T-304 `Hub1` contract and service · T-305 captures (screenshot, recording, clip) · T-306 now-playing exchange and Library/Activity display · T-307 Library and emulator-frontend integration (ROM roots, game identity) · T-308 developer guide, sample and permissions UI.

## Owner decisions (decided 2026-11-08, ADR-020 Accepted)
**Saves and states stay on the console** (a pulled drive must never lose or corrupt a save); drives hold ROMs, captures and backups (an expert opt-in per game with a warning stays possible later). **Other apps may read now-playing and captures: off by default, asked per app on first use, revocable in Settings > Privacy** (the `Platform1` permission table, T-220). **A shared read-only ROM folder** visible to all profiles besides the per-profile folders. **Captures stay local in v1** (they never leave the console). Still the lead's: capture storage limits.

## Scope of this task (docs only)
Write the spec (03 new section "Game data hub", 02 captures and Library display) consistent with ADR-020; every child traces to a paragraph.

## Acceptance criteria
- [ ] The spec sections exist and agree with ADR-020 and the children; `.\scripts\dev.ps1 docs` green.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): the hub's app-facing calls become an interface of `Platform1` (T-352), `Hub1` stays an internal service. Each child that is public carries the DoD of `api-surface.md`; T-308 owns the chapter and the sample.

## Note (lead-8, ADR-028)
Write the epic spec as `docs/specs/08-games-and-saves.md` from ADR-028 and the good parts of the owner's proposal (`docs/archive/research/universal-game-and-save-management-proposal.md`): the game/installation model (§3), the save rules (§6, §12-§13), discovery sources and confidence (§7), Proton/Wine prefixes (§8), data classification (§9.2), storage locations by volume id (§4.3), long operations (§22.3, as ADR-026's job record); take its edge-case table (§26) and test list (§27) as the acceptance matrix, and list what ADR-028 rejects. T-400 is the spike for discovery.

## Outcome
_Filled in by the implementer. First line: `Verified: host`._
