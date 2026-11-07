# T-274 — Spike: freeze and thaw real apps and games (how pausable are they?)

Status: todo · Phase: 3 · Depends: T-164, T-162 · Area: services, image · Size: M · Owner: lead

## Goal
Know, with numbers from the Dell, whether the cgroup freezer is a safe way to "pause" apps, and where it is not, before the switcher and the memory policy are built on it. Part of epic T-273.

## Read first
- T-273, T-165 (profile freeze), `services/ruya-session` (Spawner, `systemctl` calls), `docs/developers/fullscreen-and-lifecycle.md`, 03 §4.6
- systemd `FreezeUnit`/`ThawUnit` (user manager, cgroup v2 freezer), Flatpak scopes (`app-flatpak-*.scope`, T-162), `memory.events`, `memory.pressure` (PSI)

## Scope
1. Freeze and thaw, 20 times each, a set of apps on the Dell: the sample Flatpak, a Qt app, an SDL game (GL), a Wine/Proton title if T-229 produced one, a video player (mpv), and a game with an online session. Record: resume latency (freeze→first correct frame), picture after thaw (GL context loss? black frame? tearing), audio (stuck buffer, glitch, PipeWire stream state of a frozen client), controller input after thaw (evdev backlog), timers/network (disconnects, TCP keepalive), GPU memory held by a frozen app, and `ruya-session`'s view (a frozen app must not look hung to T-201's watchdog).
2. Compare with the alternatives per case: SIGSTOP/SIGCONT, `xdg_toplevel` suspended hint only (cooperative), and "ask the app to save and close" for apps that break.
3. Measure memory: RSS/PSS of a frozen game, whether swap/zram is configured (none today: say so), and how fast `systemd-oomd` or a custom killer must act to keep the foreground at 60 fps.
4. Output: a table in the Outcome (app × result), a recommendation for the default policy and the opt-out metadata key (`X-Ruya-Background`), and Inbox lines for what to fix. If a hardware check cannot be done on this machine, mark it **unverified** and list what the owner runs on the Dell.

## Out of scope
- Building the switcher or the killer (T-275..T-278).

## Acceptance criteria
- [ ] The Outcome has the measured table and the recommendation; ADR-019 is updated (Accepted by the lead, or sent to the owner if a product decision remains).

## Outcome
_Filled in by the lead. First line: `Verified: hw | vm | host`._
