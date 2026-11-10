# T-305 — Captures: screenshots, recordings and "clip the last seconds" by the OS, for any app

Status: todo · Phase: 5 · Depends: T-302, T-304, T-164, T-352 · Area: shell, services · Size: M · Owner: lead · Developer surface: public-API

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** Split: screenshots; the recording spike; the Captures page and drive storage. Captures are written as the profile user. App-facing calls are `Platform1` seats.

## Goal
The player presses a button (or picks it in the Guide menu) and gets a screenshot or a recording of whatever is in front, with the game name, time and profile attached, in one Captures library. No app needs code for this: the shell is the compositor. Part of epic T-302.

## Read first
- T-302, 02 §1.5 (Guide menu, "screenshot (later)"), T-304 (`Paths(screenshots|recordings)`), T-276 (compositor snapshots), `shell/compositor/*`, B-003 (compositor performance), `docs/specs/05-play-packages.md`

## Scope
1. **Screenshot:** capture the app layer's front surface (not the quick menu) at its native size to PNG, name `<game> <date time>.png`, JSON sidecar `{game_id, title, system, app, profile, time, size}`; a toast "Screenshot saved" with the thumbnail; a button chord (decide with the owner's gesture decision, ADR-019; default Guide + X) and a quick-menu entry; controller-only.
2. **Recording:** spike first (lead): GPU/CPU cost on the Dell of an H.264/AV1 encode through VA-API (`intel-media-driver` is in the image) of the composited frame plus PipeWire audio, versus the frame budget; ring buffer for "clip the last 30 s" (memory, power). Build the shipped variant only if it keeps the shell and the game inside budget; otherwise ship screenshots and document recording as later.
3. **Where captures go:** the console by default; the player may choose a drive (Settings > Storage), identified by UUID; if it is missing the capture goes to the console and a toast says so; a drive that is full or read-only is refused with a message, never a silent loss.
3b. **Captures library:** the profile's `~/Captures`, listed by a Library page (grid of thumbnails, date, game), actions Delete / Copy to USB / Set as wallpaper; storage limit and oldest-first cleanup prompt (never silent deletion).
4. Privacy: captures never leave the console; DRM/protected content windows (none yet) are excluded by a flag.

## Out of scope
- Sharing to the network, editing, per-app opt-out UI (T-308).

## Acceptance criteria
- [ ] Tests: the capture writes PNG + sidecar with the right fields, names are safe (no path separators from a game title), the quick menu is not in the picture, limit/cleanup rules, reduced motion toast; screenshots of the Captures page; UX note.
- [ ] VM (lead run) a screenshot of a running sample app; Dell (hw): frame-time cost of a capture and, if built, of recording.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): other apps read captures only with a per-app permission, off by default. Missing: a paragraph for developers, a conformance test (permission off, another profile).

## Outcome
_Filled in by the implementer. First line: `Verified: host (hw pending: …)`._
