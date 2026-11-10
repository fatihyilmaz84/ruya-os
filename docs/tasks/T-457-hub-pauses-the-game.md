# T-457 — Ruya Hub pauses the game: freeze on open, thaw on close

Status: todo · Phase: 2 · Depends: T-448 · Area: api, services (ruya-session), shell · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

## Goal
Opening Ruya Hub over a game pauses it (no CPU, no sound, its last frame under the Hub) and closing the Hub returns to gameplay at once; online players can turn it off.

## Read first
- ADR-033 point 3 (owner, 2026-11-10) and ADR-019 (`00-overview.md`); `02` §1.6 "The game pauses"; `03` (Session1, ruya-session scopes, T-363, T-435)
- `api/dbus/org.ruyaos.Session1.xml`; `services/ruya-session/src/` (`scope.rs`, `systemd.rs`: app scopes named exactly since T-435); `shell/qml/QuickMenu.qml`, `Shell.qml` (launch, focusApp)
- T-274 and T-275 (the ADR-019 spike and freeze/Switch tasks): this task builds the freeze primitive they will reuse

## Scope
1. Contract first, `Session1`: `Freeze(instance)` and `Thaw(instance)` for a running app of the signed-in profile, a `Frozen` state in the app's record and a change signal; status strings (`ok`, `not-running`, `failed`). Implementation: `systemctl --user freeze`/`thaw` of the app's unit and every app scope it names exactly (T-435's `app_scopes`), bounded like T-435's calls; idempotent; a stop or kill of a frozen app thaws first.
2. Shell: the Hub freezes the app in front when it opens over it and thaws it on Resume/B/Guide; Home keeps it frozen; Switch to thaws the chosen one; Close thaws then stops. A failed freeze leaves the game running and the Hub open, with no "Paused" shown.
3. The app header shows "Paused" while frozen.
4. Settings -> System: "Pause games when Ruya Hub opens" (on by default), stored like the other device settings.

## Out of scope
- Background policy, memory pressure, snapshots and the switcher (T-275..T-278); per-game opt-outs (later, an Inbox line if wanted).

## Acceptance criteria
- [ ] XML, Rust service, mock and client agree; Rust tests: freeze and thaw name every scope of the app and nothing of a sibling app (like T-435's sibling test), thaw before stop, a second freeze is a no-op, another profile's app is refused (tests)
- [ ] Shell: open over an app calls Freeze, Resume/B/Guide call Thaw, Home does not, Close thaws then stops, the setting off calls neither (one test each, mock)
- [ ] A failed freeze: Hub open, no "Paused" (test)
- [ ] hw (builder or lead on the Dell): SuperTuxKart frozen while the Hub is open (its CPU 0 %, its sound stops), back in play within one frame of the close; a KMS capture of the Hub over the frozen frame
- [ ] VM (lead run): `vm-session-check.sh` extended: freeze/thaw of the test app's unit and scopes (`systemctl --user show -p FreezerState`)
- [ ] UX: Back and Guide leave; the paused state is readable at 10 ft; `UX notes:` line
- [ ] `dev.ps1 test` ALL GREEN; `shots` of the Hub over a paused app reviewed

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `02` §1.6 built marks, `03` (Session1 Freeze/Thaw), the T-275 ruling if its scope shrinks.

## Hints
- Planned by lead-10 on 2026-11-10 from the owner's request. Electron apps have two scopes (T-435): freeze all of them. Frozen PipeWire clients stop their stream; check that thaw does not leave the game muted.

## Outcome
_Filled in by the implementer._
