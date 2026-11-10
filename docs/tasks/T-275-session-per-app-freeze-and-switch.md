# T-275 — `ruya-session`: per-app freeze/thaw and an atomic `Switch`

Status: todo · Phase: 3 · Depends: T-273, T-274, T-165 · Area: api, services, shell · Size: M · Owner: builder · Developer surface: internal

**Ruya Hub (lead-10, 2026-11-10):** T-457 builds `Session1.Freeze`/`Thaw` (all scopes of an app, thaw before stop) for the Hub's pause; build `Switch` and the background policy on that primitive instead of a second one.
## Goal
The session service knows which app is in front and which are in the background, can freeze and thaw one app, and switches the foreground in one call so the shell never shows two apps running or a frozen app in front. Part of epic T-273.

## Read first
- T-273 (model), T-274 Outcome (what freezes safely), T-165 (profile-level `Suspend`/`Resume`: reuse its freezer code, do not duplicate it), `api/dbus/org.ruyaos.Session1.xml`, `services/ruya-session` (pure state machine + `Spawner`), `shell/src/library` and the Session client/mock
- `services/CLAUDE.md`, `ruya-profiles` pattern

## Scope
1. **Contract first:** instance states `foreground`, `background`, `frozen`, `suspended` (profile freeze) in `ListRunning`; `Switch(instance) -> status` (thaws the target, freezes the previous foreground unless it holds a background reason, returns `ok|unknown-instance|busy|failed`); `SetBackgroundReason(instance, reason, bool)` for audio/download holders; signals `StateChanged(instance, state)`.
2. **Service:** pure state machine in the core (fake clock): at most one foreground; a background app is frozen after a grace period (default 5 s, constant); an app with a background reason stays `background`; stop of a frozen app thaws it first; a crash while frozen is reported once; the freezer behind the `Spawner` trait.
3. **Shell:** client and mock for the new surface; `Session` exposes `foreground` and states; no UI here (T-277).
4. Rust tests for every rule; mock/client tests mirror the XML.

## Out of scope
- Snapshots and animation (T-276), the switcher UI (T-277), the memory killer (T-278).

## Acceptance criteria
- [ ] Rust tests: one foreground at a time, freeze after the grace period, background reason keeps an app running and a release freezes it, `Stop` of a frozen app, crash while frozen, `Switch` to an unknown/stopped instance, profile `Suspend` interplay.
- [ ] XML, Rust, mock and D-Bus client agree (names, argument order, status strings).
- [ ] VM (lead run): `scripts/vm-session-check.sh` extended: two sample apps, `Switch`, the previous one is frozen (`cgroup.freeze`), thaw on switch back, `systemd-analyze security` unchanged.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Docs to update
- Session1 XML, 03 §1.1/§4, developer guide lifecycle chapter.

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: …)`._
