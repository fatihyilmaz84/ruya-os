# T-472 — Running apps keep their sound when the shell is down for more than 10 s

Status: in-progress · Phase: 2 · Depends: — · Area: image, services (ruya-session) · Size: S · Owner: builder · Complexity: complex · Developer surface: none

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
Verified: host (vm pending: vm-session-check.sh check)

**Decision: neither (a) nor (b); `ruya-shell` keeps not lingering** (recorded in `03`, Launch, the Sound sentence; the Freeze paragraph points to it). The task's own rule ("prefer (a) unless it breaks the seat-session device access") decided it, and its premise does not hold for games. Dell (0.0.66 plus the T-455 shell overlay), by hand:
- **A game does not outlive the compositor.** SuperTuxKart launched for p2 had a running stream through `ruya-pulse@ruya-p2`; at `systemctl stop ruya-compositor@tty1` it logged `Error reading events from display: Broken pipe` and its unit ended `status=1/FAILURE` within 50 ms, linger or not. A game outliving a shell crash is not in V1 (ADR-033, owner answer 6(b)). So there is no running game whose sound a linger could save, and (b) has nothing to give the restarted servers to.
- **(a) works for what it keeps:** with `enable-linger ruya-shell` and the shell down 22 s, the manager, PipeWire, WirePlumber, `ruya-devices` and both `ruya-pulse@` stayed active (sinks `auto_null`, the ACL gone); 2 s after the start the ACL and the card were back.
- **(a) breaks the card at a shell start:** a lingering WirePlumber already runs while logind writes the `uaccess` ACLs, and opens the card half-way (`spa.alsa: Error opening hctl device: Permission denied`, `can't open control for card hw:0` in every lingering start). Wrong card in 2 of 15 lingering starts (9 "boot-like": `user@972` restarted with no seat session, then the shell; 6 shell stops of 20 to 22 s): once the `stereo-fallback` sink, once a duplicate card `alsa_card.pci-0000_00_1f.3.2` with `hdmi-stereo`, which WirePlumber saved in `default-nodes` and `default-routes`; the saved profile is `analog-stereo`. Without linger: 6 of 6 starts `analog-stereo`, no permission error.

**Check (Scope 3, adapted to the decision): `scripts/vm-session-check.sh check`**, new section after the kill section, before the relaunch (no app runs there: the sleeper is no Wayland client and would outlive the shell): `ruya-shell` does not linger; the shell stops; `user@<uid>` ends within 25 s; the `ruya-pulse@<user>` socket is gone; the shell starts again after 20 s and its manager returns with the seat session; the relaunch of the next section then has `ruya-pulse@<user>` active with its socket and `PULSE_SERVER` in the app unit. The T-470 linger around the Freeze checks stays (it keeps the manager for the Thaw's restore with the shell stopped). Header comment updated. `bash -n` passes. Not run anywhere yet: the lead's VM queue.

**Not done, by the decision:** no image change (so the "VM (this task)" criterion's condition "if the image changes" does not apply), no tmpfiles linger, no `ruya-session` change, no new unit test. Revert test: n/a (no code; the new check's assertions were seen on the Dell by hand: the manager `inactive` after 20 s without linger, 6 of 6, and `ruya-pulse@` gone with it).

**Developer surface:** none (no contract, file or permission an app reaches changes; an app's experience on a shell restart is unchanged).

**Dell:** launched SuperTuxKart as p2 (it ended at the first compositor stop); set and took back `loginctl enable-linger ruya-shell`; stopped and started `ruya-compositor@tty1` 23 times (each 5 to 22 s down, spaced to stay under its `StartLimitBurst`); restarted `user@972` 9 times with the shell stopped; started `ruya-pulse@ruya-p1` and `@ruya-p2` again by hand at the end (they were running before); removed the phantom card's lines (`alsa_card.pci-0000_00_1f.3.2`, `analog-stereo.2`) from `/var/lib/ruya-shell/.local/state/wireplumber/default-{profile,nodes,routes}` with WirePlumber stopped, then started it and `ruya-devices`. The analog speaker route reads `mute: true` (written 11:09 during the linger runs; its state before is unknown). Linger of `ruya-shell` is off, as before; scratch files in `/var/tmp` removed; no reboot.

Files: `docs/specs/03-services-and-apps.md`, `scripts/vm-session-check.sh`, this task file.
