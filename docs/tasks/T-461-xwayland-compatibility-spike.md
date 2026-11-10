# T-461 — Spike: XWayland as a compatibility layer (ADR-034): mechanism, per-profile start and stop, two X11-only games on the Dell

Status: todo · Phase: 2 · Depends: — · Area: services (ruya-session), image (a package), shell (compositor, only if needed) · Size: M · Owner: lead · Complexity: hard · Developer surface: none

## Goal
A decision, with evidence from the Dell, on how RuyaOS runs X11-only apps through a rootless, per-profile, on-demand X server whose windows reach the shell as normal app windows; and a prototype that starts AAAAXY and Alien Arena.

## Read first
- ADR-034, ADR-004, ADR-023, ADR-002 A (`00-overview.md`); `03` (Session1, the spawner's `console_env`, T-164 per-profile sockets, T-435 scopes)
- `services/ruya-session/src/spawner.rs` (`console_env`), `shell/compositor/`, `image/build/` (package lists, `98-guard.sh` banned packages), the Dell launch-test lines in the STATUS Inbox (lead-10)

## Scope
1. Mechanism: is `xwayland-satellite` (or another rootless bridge acting as X window manager on top of a Wayland compositor) in Fedora 44; what it needs from our compositor (xdg-shell, xdg-output: T-362, linux-dmabuf, viewporter); versus XWayland with a window manager inside `ruya-shell`. Pick one with reasons.
2. Lifecycle: who starts it (ruya-session, as the profile user, in the profile's manager), when (an app whose Flatpak metadata has `x11` but not `wayland`, or an override), `DISPLAY` only for that app, stop after the profile's last X11 app; what happens on Hub pause (freeze) and Close.
3. Prototype on the Dell (overlay is fine): AAAAXY and Alien Arena start, take input, show in the app layer, the Hub opens over them, Close ends them and the X server.
4. Cost: memory and CPU of the idle X server, frame time against a Wayland game.
5. Write the build task(s) from the result (contract, image package, guard list, security baseline, tests).

## Acceptance criteria
- [ ] The decision and its evidence in the Outcome (and ADR-034 point 4 updated)
- [ ] hw: both games ran on the Dell through the prototype (captures, commands)
- [ ] The build task(s) written, with the image, security-baseline and guard changes named

## Hints
- Planned by lead-10 on 2026-11-10 from the owner's decision. The image guard bans desktop packages: check `xorg-x11-server-Xwayland` and the bridge against `98-guard.sh` and `docs/image-packages.md`.

## Outcome
_Filled in by the implementer._
