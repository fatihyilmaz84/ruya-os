# T-264 — Controller registry and player slots: contract, `ruya-inputd` service, mock, client

Status: todo · Phase: 2 · Depends: T-263 · Area: api, services, shell · Size: M · Owner: builder · Developer surface: internal

## Goal
The system knows which pad is which player: a registry of known pads and the slot assignment (slot → profile or Guest) for the active session, exposed over D-Bus with the shell client and a mock. Part of epic ADR-017 (T-263).

## Read first
- `docs/specs/00-overview.md` ADR-017, the controllers/players section of `03-services-and-apps.md` (written by T-263)
- `api/dbus/*.xml` (the Devices and Profiles contracts), `services/ruya-inputd`, `services/ruya-devices` (Bluetooth `ListDevices`, families, T-260 rename/forget)
- `shell/src/network` (newest complete backend with a pane), `services/CLAUDE.md`

## Scope
1. **Contract first** (XML): list/rename/forget known pads, set a pad's default owner, `Assign(pad, profile|guest)`, `Release(slot)`, `ListSlots`, signals `PadConnected`, `PadDisconnected`, `SlotChanged`. The service decides nothing about the shell UI.
2. **Service:** the registry persists under `/var/lib` with root-only permissions (hardened systemd unit unchanged or tighter); slots live for the session; a pad that reconnects within 60 s gets its slot back; the session owner's pad is slot 1; guest slots are wiped at session end. Pure Rust core with fakes, as `ruya-profiles`.
3. **Shell:** D-Bus client and mock for the same surface (a `Players`-style backend under `shell/src/`), no UI beyond what a test needs.
4. The shell-navigation rule of ADR-017 (slot 1 anywhere; any pad at login and on the "Who's playing?" dialog) is enforced by the service: `ruya-inputd` marks which pads may produce navigation keys.

## Out of scope
- UI (T-265), virtual pads for apps (T-266), LEDs, default owner at login (T-267), guest lifecycle policy (T-268).

## Acceptance criteria
- [ ] Rust tests: registry round trip, slot assignment, stickiness within and after 60 s (fake clock), guest wipe, navigation allowed/denied per state, root-only file mode.
- [ ] Mock and client tests in the shell mirror the contract (names, argument order, status strings agree with the XML).
- [ ] VM (lead run): `scripts/vm-inputd-check.sh` (extend or add) drives `Assign`/`Release` over `busctl --json=short` and checks the persisted file mode.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Docs to update
- the XML, `03-services-and-apps.md`, `docs/dev-setup.md` if a check is added.

## Hints
- Robustness work that lands before this (2026-11-08, from the "second pad overrides the first" report): T-334 (two-pad tests and fixtures: reuse them), T-335 (INFO logging), T-336 (per-device Bluetooth adapter: the registry keys controllers by address, the adapter name is an extra field), T-337 (`ruya-inputd` releases keys when a pad vanishes and shares keys safely between pads: start from that mapper). T-338 is the Dell investigation of the 21 s drop.

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: …)`._
