# T-279 — App cooperation: save state before close/freeze, audio and downloads in the background, developer guide

Status: todo · Phase: 3 · Depends: T-273, T-275 · Area: services, docs · Size: M · Owner: builder

## Goal
Apps (first-party and third-party) know what happens to them in the background and can behave: they get told they will be frozen or closed, a music or download app may declare a reason to keep running, and a frozen app never makes noise. Part of epic T-273.

## Read first
- T-273 (model), T-275 (`SetBackgroundReason`, states), `docs/developers/fullscreen-and-lifecycle.md`, 03 §4.6, T-248/T-249 (HIG), `ruya-devices` audio (PipeWire streams per app, ADR-010), the Flatpak sandbox facts (what an app can call)

## Scope
1. **Signals to the app:** SIGTERM with the 5 s grace (existing) plus the `xdg_toplevel` suspended state (T-276); document that a frozen app gets no CPU, so it must save *before* losing focus ("save on pause"). For apps that want a stronger hook, a small D-Bus/portal call `org.ruyaos.AppLifecycle.WillClose` is evaluated and, if feasible in the sandbox, added as a contract (otherwise documented as not available: say why).
2. **Background reasons:** an app declares `X-Ruya-Background=audio|download|none` in its AppStream metadata (default `none`); the service honours it (T-275) only while the reason holds (an active PipeWire playback stream, an active transfer reported through the portal). Validation: unknown values are ignored.
3. **Audio:** a frozen app's PipeWire streams are muted/paused by the shell side (`ruya-devices`) so no stuck buffer repeats; an app that holds the `audio` reason keeps its stream; volume ducking is out.
4. **Developer guide** chapter "Running in the background" and the sample app shows save-on-pause; HIG rule in T-249 if it exists.

## Out of scope
- The killer (T-278), UI (T-277), per-app user toggles.

## Acceptance criteria
- [ ] Rust/unit tests: reason parsing from metadata (valid/invalid/hostile), the mute rule for frozen streams with a fake PipeWire, holders stay running.
- [ ] VM (lead run): `scripts/vm-session-check.sh`/`vm-audio-check.sh` extended: a sample that plays a tone keeps playing with the `audio` reason and is silent when frozen without it.
- [ ] Developer guide chapter written; `.\scripts\dev.ps1 test` ALL GREEN.

## Docs to update
- `docs/developers/fullscreen-and-lifecycle.md`, 03 §4.6, AppStream metadata chapter.

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: …)`._
