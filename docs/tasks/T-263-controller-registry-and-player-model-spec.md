# T-263 — EPIC: multiple controllers and local players: spec for the registry and the player model

Status: todo · Phase: 2 · Depends: T-260, T-366 · Area: docs · Size: S · Owner: lead · Developer surface: internal

## Goal
The design of ADR-017 (accepted by the owner, 2026-11-07) is written down as a spec section that the child tasks build from: the data model, the D-Bus surface (draft), the flows and the states. Epic children: T-264 services, T-265 shell UX, T-266 virtual pads for apps, T-267 default owner at login, T-268 guest player. The owner's question: "when we add a second controller how do we use it; which controller is used by who; on PS it asks which user; what about guests".

## Read first
- `docs/specs/00-overview.md` ADR-017, ADR-003 (input arbitration), ADR-004 (one session at a time)
- `docs/specs/02-shell.md` (input, Guide overlay, top-right cluster), `03-services-and-apps.md` (`ruya-inputd`, devices)
- `docs/tasks/T-260-controller-onboarding-flow.md` Outcome (registry, rename, one glyph per device)

## Scope
1. A new section in `03-services-and-apps.md` (controllers and players): registry record, slots, lifetime, stickiness (60 s), the three accepted decisions as rules, what a hardware Guide button does per state, LEDs best effort (DualSense lights; the Xbox ring is firmware), honesty when a device cannot show its slot.
2. In `02-shell.md`: the "Who's playing?" dialog (appears only when an unassigned pad is used while a session is active **and** an app that supports several players runs, or when opened from Settings), player chips (P1/P2 + avatar) next to the T-223 battery chips, disconnect toast and reassign on reconnect, Settings > Bluetooth & controllers > Players (slots, change/clear, per-pad default owner, "Guest sessions: ask / allow / off").
3. A list of open questions as Inbox lines (for example: how many slots; a game that wants more players than slots).

## Out of scope
- Code. The XML contract is written by T-264.

## Acceptance criteria
- [ ] The two spec sections exist and are consistent with ADR-017; every child task's Scope can be traced to a spec paragraph.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN (docs lint).

## Docs to update
- the specs named above.

## Note (lead-8)
ADR-024 (Ruya Input) makes one input service the owner of the pads; T-366 decides the engine and the service. The registry and player slots of ADR-017 must be designed inside that service, not as a separate `ruya-inputd` registry: rewrite this task with T-366's result before anyone builds T-264.

## Outcome
_Filled in by the implementer. First line: `Verified: host | unverified`._
