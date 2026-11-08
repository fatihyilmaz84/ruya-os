# T-259 — First-party app: Emulator frontend

Status: todo · Phase: 7 · Depends: T-251, T-252, T-256 · Area: apps · Size: M · Owner: builder · Developer surface: none

## Goal
A launcher for retro games that the player owns: it finds game files on storage and USB drives, matches them to an installed emulator, shows them with art, and starts them. **RuyaOS and this app ship no emulators, no ROMs, no BIOS or firmware, and link to none** (owner, 2026-11-06; `05-play-packages.md`): emulators are separate Flatpaks (or `.play` packages) that the user installs. Part of T-248; its own Flatpak (`org.ruyaos.Retro`).

## Read first
- T-248, `docs/specs/06-hig.md`, `docs/specs/05-play-packages.md` and the `.play` tasks T-239 and T-244 (runners and launching: **do not duplicate them**; if a `.play` package already wraps an emulator and its games, this app only lists and launches it), `Session1` (how an app launches another app: the frontend launches through the platform, never by running binaries itself), T-256 (the folder browser), the library service (`Library1`)
- Legal note: owner confirmation for this task is in T-248's decisions (4); until given the task stays a plan

## Scope
1. **Emulator registry:** a small data file of known emulators (Flatpak id, the systems it plays, the file extensions, the launch arguments template), shipped as data; an emulator not installed shows "Install RetroArch / <name> from the Store" (a Store deep link, no auto-install); only the registry's known ids are launched.
2. **Scan:** the folders the player chooses (a drive or a folder, through the file portal or a permitted path): file extensions per system, by name and size only (no hashing of huge files on the GUI thread; an optional hash match for art is a later task), nothing is opened or executed during a scan; hidden and system files skipped.
3. **Library view:** systems as rows, games as cards with art from the player's own `<game>.png` or a neutral placeholder, a name cleaned from the file name, favourites and recents per profile, a search, a launch counter feeding the platform's play statistics only through the platform (T-247 counts the foreground app).
4. **Launch:** through the platform's launch API with the file path passed to the emulator inside the sandbox grant the user made (state what permission the emulator needs to read the file: the frontend does not widen it); an error in plain words when the emulator is missing or exits at once.
5. Per-game save data stays with the emulator (the HIG's lifecycle rules apply to the frontend's own state only). Turkish and English, accessible names.

## Out of scope
- Bundling or downloading emulators, ROMs, BIOS files or covers from the internet, netplay, achievements for emulated games (RetroAchievements is a separate, later idea), shaders and per-core settings.

## Acceptance criteria
- [ ] Tests (fake file system, fake launcher): scan by extension, the registry matching, missing-emulator state, launch arguments (no shell, no path injection: file names with spaces, quotes, `;`, leading `-`), favourites and recents, controller-only operation, focus asserted.
- [ ] The app contains no emulator binary, no ROM, no BIOS (a check in the build lists the Flatpak's files against an allow-list).
- [ ] Screenshots (English and Turkish) against `04` §8 and the HIG checklist.
- [ ] Builds as a Flatpak from the template; VM (lead run, needs T-164 for windows): launches an installed emulator test app with a dummy file. `.\scripts\dev.ps1 test` green.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): none. Dogfooding rule: this app may use only the public surface; if it needs something else, add an Inbox line proposing the capability, do not use a private service. It reads ROM roots and paths through the hub (ADR-020) only via `Platform1`.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified`._
