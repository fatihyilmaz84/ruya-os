# T-472 — Running apps keep their sound when the shell is down for more than 10 s

Status: todo · Phase: 2 · Depends: — · Area: image, services (ruya-session) · Size: S · Owner: builder · Complexity: complex · Developer surface: none

## Goal
Found by T-470 (lead-12, 2026-11-12; reproduced on the Dell): `ruya-shell` does not linger, so when the shell (`ruya-compositor@tty1`) is down for more than logind's `UserStopDelaySec` (10 s: a crash loop, a slow restart, an update of the shell), logind stops `ruya-shell`'s user manager. That takes down PipeWire and **every profile's `ruya-pulse@` sound server**. ruya-session starts a profile's sound server only at Launch, so the running games stay silent after the shell comes back, until each is relaunched. A shell restart must never cost a running game its sound.

## Read first
- `docs/tasks/T-470-thawed-app-sound-not-restored.md` (Outcome: the timing, the journal lines), T-365's Outcome (a pulse server per profile), ADR-010 (`ruya-devices` as a user unit of `ruya-shell`)
- `image/rootfs/usr/lib/systemd/` (the units), `services/ruya-session/src/spawner.rs` (how `ruya-pulse@` is started), `docs/specs/01-platform.md` and `03` (sound for profile apps)

## Scope
1. Decide between, and record in `01`/`03`: (a) `ruya-shell` lingers in the image (`/var/lib/systemd/linger/ruya-shell` via tmpfiles), so its manager, PipeWire and the profile sound servers outlive the shell; or (b) ruya-session restarts `ruya-pulse@<user>` (and re-links) for users with running apps when the shell's manager returns. Prefer (a) unless it breaks the seat-session device access (the sound card belongs to the seat session through uaccess; check that a lingering manager's PipeWire still reaches the card after the shell's seat session returns).
2. Implement it; take the linger set/unset back out of `scripts/vm-session-check.sh` if (a) makes it unnecessary.
3. A VM check: with an app running and playing, stop the compositor for 20 s, start it, and assert the app's sound server and stream are still there (extend `vm-session-check.sh` or `vm-audio-check.sh`).

## Out of scope
- The card-suspend half of T-466's check (Inbox), the Hub.

## Acceptance criteria
- [ ] The decision and its reason are in `01` or `03`
- [ ] VM (this task, if the image changes): build, `make-disk`, `smoke-test.ps1` RUYA_BOOT_OK, then the new check passes: after a 20 s shell stop the running app's `ruya-pulse@` and its stream are still there
- [ ] `vm-session-check.sh check` still passes (the T-466 Freeze/Thaw part)
- [ ] `dev.ps1 test` ALL GREEN

## Hints
- Planned by lead-12 from T-470's review. The Dell may be used (CLAUDE.md Dell rule) for the hardware look: stop the compositor 20 s with STK playing.

## Outcome
