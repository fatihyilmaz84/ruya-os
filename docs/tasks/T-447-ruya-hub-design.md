# T-447 — Ruya Hub design: the Quick Hub, the panels, focus and motion

Status: in-progress · Phase: 2 · Depends: — · Area: docs · Size: S · Owner: lead · Developer surface: none

## Goal
One written design for Ruya Hub (ADR-033) that the builder tasks T-448..T-454 follow: what the Quick Hub shows, which panels exist, how focus moves between them, and how it looks over a running game.

## Read first
- `docs/specs/00-overview.md` ADR-033, ADR-019, ADR-027; `docs/specs/07-hub-requirements.md` §4-§8 (owner input)
- `docs/specs/02-shell.md` §1.4, §1.5 (the quick menu as built, T-147); `docs/specs/04-design-system.md` §3 (glass, sheets), §4 (focus), §5 (motion), §8
- `shell/qml/QuickMenu.qml`; T-393 (Options menu design) so the two menus do not overlap

## Scope
1. Write `02` §1.4 "Ruya Hub" as the target: the Quick Hub (status row: time, network, battery cluster; the running app's header with Resume first; other running and recent games; a row of quick tiles; entries to panels: Audio, Controllers, Performance, Notifications, Power) and each panel's contents, states and empty states. Mark built vs planned.
2. Focus and Back: Guide toggles; B leaves a panel to the Quick Hub, then closes; Resume is first on every open over an app; decide whether the last panel is remembered across opens, and say why.
3. Layout and motion in `04`: the 640 px panel grows a second column or a panel replaces it (decide); reduced motion; readable at 10 ft on 720p.
4. Tiles: which quick settings are tiles (Wi-Fi, Bluetooth, mute, output, microphone, brightness), the toggle-vs-open rule, and what "unsupported" means (07 §5.2: no fake controls; a tile is absent rather than disabled).
5. Update T-448..T-454 if the design changes their scope.

## Out of scope
- Code; new typefaces or colours (owner-level).

## Acceptance criteria
- [ ] `02` §1.4 and `04` describe the Hub; every T-448..T-454 criterion traces to a paragraph; `.\scripts\dev.ps1 docs` green.

## Verification
```powershell
.\scripts\dev.ps1 docs
```

## Docs to update
- `docs/specs/02-shell.md` §1.4, `docs/specs/04-design-system.md`.

## Hints
- Planned by lead-10 on 2026-11-10 from ADR-033. Status, battery and network chips already exist (T-223 status cluster): reuse, do not redraw.

## Outcome
_Filled in by the implementer._
