# T-366 - Ruya Input: spike, engine decision and the design (06-input.md, Input1 draft)

Status: todo · Phase: 2 · Depends: — · Area: docs, image, services (spike) · Size: M · Owner: lead · Complexity: hard · Developer surface: internal

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** The design file is `docs/specs/06-input.md`; `06-input-requirements.md` becomes its appendix or moves to `docs/archive/` in the same commit (two files numbered 06 otherwise). The design must also answer, with a named owner task each: how the service learns sign-in, switch and lock (which service calls which, the bus policy line); how an app's already open descriptor loses the pad at lock, profile switch and run end (revoke or re-create the node, not only "cannot open"); the udev rules for virtual nodes, hidraw and `/dev/uinput` under a non-root service; the Bluetooth pairing window as an attack surface (who may become a controller, and what such a pad may do before a profile owns it). T-396, T-397 and T-398 wait for this task.

## Goal
Phase 0 of the owner's input requirements (`docs/specs/06-input-requirements.md` §16): we know, with evidence from the Dell and the VM, which engine owns the pads, how a virtual pad reaches only the signed-in profile's game, and the design every later input task builds from.

## Read first
- ADR-003, ADR-017, ADR-022, ADR-023, **ADR-024** in `docs/specs/00-overview.md`; `docs/specs/06-input-requirements.md`; `docs/specs/02-shell.md` §4.3
- `services/ruya-inputd/` (all of it, 719 lines), `image/rootfs/usr/lib/udev/rules.d/70-ruya-input.rules`, `shell/compositor` `KeyRouter`
- T-217 (split into T-366..T-374; its spike questions are this task's), T-266, T-207, T-203

## Scope
1. **Engine:** InputPlumber built from source in the image (it is not in Fedora 44) versus `ruya-inputd` grown into the service. Compare on the Dell: privilege (root or not), memory, added latency (timestamps in, out), virtual device types, routing/intercept for an overlay, licence and build cost, Bluetooth reconnect (T-207). Decide inside ADR-003 (its fallback is named there) and record it in ADR-003 and ADR-024.
2. **Reach:** by hand on the Dell, a uinput Xbox-style pad with an ACL for `ruya-p1` only is seen by SuperTuxKart (Flatpak, `--device=all`) as a gamepad, and not by another user; what a sandbox without `--device` sees; whether SDL needs udev inside the sandbox.
3. **Shell safety:** what keeps the shell navigable when the service dies (the shell reads the physical pads itself as a fallback, or systemd restarts plus a watchdog); prove the chosen path on the Dell by killing the service.
4. **Design, `docs/specs/06-input.md`:** the normalised model (§4 of the requirements), device identity (stable id, like-pad tie-break with ADR-017), the capability descriptor (hardware / driver / available / output-supported), the routing state machine (shell, app, overlay, locked; ownership modes), the profile JSON schema v1 (`docs/specs/schemas/input-profile-v1.json`, with inheritance and limits for macros), and the draft `api/dbus/org.ruyaos.Input1.xml` (devices, capabilities, live state for the button test, profiles, routing).
5. Re-check T-367..T-374 against the result and fix their scopes (each task file updated in this commit).

## Out of scope
- Building the features (T-367 onward).

## Acceptance criteria
- [ ] The Outcome answers Scope 1-3 with numbers and commands from the Dell (versions, memory, latency, ACL listings, the STK Controls screen as a photo note from the owner or a log line).
- [ ] `06-input.md`, the schema and the draft XML exist; `lint-dbus`/`dev.ps1 docs` pass; the schema validates the requirements' example profile (a test in `scripts` or Rust).
- [ ] ADR-003 and ADR-024 updated with the decision.

## Outcome
_Filled in by the implementer._
