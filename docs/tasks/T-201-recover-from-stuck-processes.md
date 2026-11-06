# T-201 — Recover from stuck processes: layered watchdogs, memory and CPU protection, force-closing an app

Status: todo · Phase: 2 · Depends: — · Area: image, services, shell · Size: M · Owner: lead

## Goal
A console in a living room has no keyboard to fix things with. Whatever hangs (an app, the shell, memory, the whole machine), the system recovers on its own in a bounded time, in the cheapest layer that works, and the owner can force-close a stuck app from the controller. Owner request, 2026-11-06: "look at task killing for processes that get stuck, to recover the OS".

## Facts (Dell, `0.0.44`; image today)
- `ruya-compositor@.service`: `Restart=always`, `RestartSec=1`, **no watchdog**: a shell whose event loop or render thread hangs (not crashes) stays hung.
- `systemd-oomd` is active, but the shell and apps share a policy by default: nothing protects the shell from an app that eats RAM; no `OOMScoreAdjust`, no limits on app units.
- The Dell has a hardware watchdog (`/dev/watchdog`, `/dev/watchdog0`); systemd's `RuntimeWatchdogSec=` is not set.
- `ruya-session` stops an app with `systemctl stop` of the unit and the app's `app-flatpak-*.scope` and kills it after a 5 s grace (T-162, vm-verified); nothing detects an app that is *not responding*; the shell has no "close this app" control yet (T-147).
- `kernel.sysrq` state, `panic=` and `softlockup` settings: not looked at.

## Layers (to design, decide and build in this order)
1. **App not responding -> close it (UX, owner-visible).** The shell is the Wayland compositor: it can `xdg_wm_base.ping` the focused app (QtWaylandCompositor's XdgShell pong timeout); no pong for 5 s while the app is focused -> an overlay "<App> is not responding: Wait / Close"; Close = `Session1.Stop` (SIGTERM, SIGKILL after 5 s). Also reachable from the Guide overlay at any time ("Close app"), because a hung app that still answers pings but draws nothing must be closable too. (The overlay and quick menu are T-147; build the detection and the call here, or hand T-147 a ready interface and say so.)
2. **The shell hangs -> systemd restarts it.** `Type=notify` + `WatchdogSec=` (suggested 20 s) on `ruya-compositor@.service`, the shell sends `WATCHDOG=1` from a heartbeat that proves both the GUI thread and the render thread are alive (a main-thread timer that waits for the last rendered frame counter to change; not a bare timer, which a stuck render thread would not stop); `Restart=always` brings it back and the session returns to the picker; `StartLimit` so a crash loop ends in the greenboot rollback path, not an infinite restart. Check `NotifyAccess` and the hardening interplay.
3. **Memory pressure -> kill the app, not the shell.** `OOMScoreAdjust=-900` and `ManagedOOMPreference=avoid` for the compositor and the core services; apps run in `app.slice` with `ManagedOOMMemoryPressure=kill` / `ManagedOOMMemoryPressureLimit=` (suggested 60 % for 20 s), a per-app `MemoryHigh` (80 % of RAM) and `MemoryMax` (90 %), set by `ruya-session` through the transient unit properties (so a runaway game is throttled, then killed). The shell shows "<App> was closed because the console ran out of memory" (the exit reason `killed` exists; add an OOM hint if the unit result says so). Swap/zram: decide whether `zram-generator` is already there.
4. **CPU/IO starvation -> the UI stays alive.** Lower `CPUWeight`/`IOWeight` for apps relative to the shell (suggested shell 200, apps 100) so a spinning app cannot starve the compositor.
5. **The whole machine hangs -> hardware watchdog reboots it.** `RuntimeWatchdogSec=30s`, `RebootWatchdogSec=5min` in `/usr/lib/systemd/system.conf.d/`; kernel `panic=10` (reboot after a panic), `softlockup_panic`/`hung_task_timeout` decisions recorded; `kernel.sysrq` left at a safe value (documented recovery on a USB keyboard: Alt+SysRq+REISUB). A reboot that did not come back is greenboot's job (existing).
6. **Boot never reaches the shell -> greenboot rollback (exists).** Only verify it still covers the new watchdog (a crash-looping shell must end in rollback, with the timing in the Outcome).

## Scope
1. Decide each layer's numbers above with the owner-visible behaviour in mind (a short "Recovery" section in `01-platform.md` with the table: what hangs -> who notices -> after how long -> what happens -> what the owner sees).
2. Build layers 2-5 (image/unit/`ruya-session` changes and the shell heartbeat) and the detection+call of layer 1.
3. A **hang test app** for the VM checks (like the T-162 test apps: a local Flatpak) with modes: ignore pings/stop drawing, burn all CPUs, allocate memory until killed, ignore SIGTERM; and a `shell` hang switch for the shell's heartbeat (a debug-only `RUYA_DEBUG_HANG` env that stops the render loop; compiled out of release or guarded so a profile app cannot trigger it).

## Out of scope
- The full-screen app flow UI (T-147), freezing apps on profile switch (T-165), thermal protection (T-200), remote recovery over the network, a separate recovery partition/boot entry.

## Acceptance criteria
- [ ] The Recovery table in `01-platform.md` exists and every number in it is the one built.
- [ ] VM (this task; image build + QEMU): `scripts/vm-recovery-check.sh`:
  - the spinning/allocating test app is killed by oomd/limits while `ruya-compositor` keeps its PID (compare before/after), and the memory-eater is reported as `killed` by `Session1`;
  - a spinning app does not stop the shell: the shell's heartbeat / frame counter keeps advancing under load;
  - `RUYA_DEBUG_HANG` on the shell: systemd restarts `ruya-compositor` within `WatchdogSec` + `RestartSec` (assert the journal line `Watchdog timeout` and a new PID);
  - `systemctl show` has the watchdog settings (`RuntimeWatchdogUSec`, `WatchdogUSec`), `OOMScoreAdjust`, the slice policies;
  - a crash loop (the shell killed 5x in 30 s) ends in the greenboot rollback path (use the existing drill; Outcome gives the time).
- [ ] Unit/QML tests for layer 1: a mock app that stops answering pings produces the "not responding" state after 5 s (fake timer) and `Close` calls `Session.stop`; a responding app does not.
- [ ] `systemd-analyze security` of the touched units not worse than before (numbers in the Outcome); `.\scripts\dev.ps1 test` ALL GREEN.
- [ ] Hardware (lead, the Dell): hardware watchdog active (`wdctl`), the shell watchdog restart demonstrated once with the debug hang.

## Verification
```powershell
.\scripts\dev.ps1 test
```
Then the image recipe in `docs/dev-setup.md`, `smoke-test.ps1`, `vm-recovery-check.sh`, the update/rollback drill for the crash-loop case. One image build at a time; `free-space.ps1` after.

## Docs to update
- `01-platform.md` (Recovery section), `02-shell.md` (not-responding overlay, Guide overlay "Close app"), `03` (`ruya-session` unit properties), `docs/dev-setup.md` (the check, the debug hang), `image/CLAUDE.md` if a quirk appears.

## Hints
- `systemd-run --property=` accepts `MemoryHigh`, `MemoryMax`, `CPUWeight`, `IOWeight`, `ManagedOOMMemoryPressure*` for the app units that `ruya-session` creates (see `spawner::launch_command`); remember the app lives in `app-flatpak-*.scope` (T-162): set the limits on the **slice** (`app.slice` drop-in in the user manager) or on both.
- `WatchdogSec` needs `sd_notify`: the shell can write the notify socket itself (`QLocalSocket` to `$NOTIFY_SOCKET`, datagram) or link `libsystemd`; check the Containerfile for the dev package and the Fedora/Qt versions.
- Do not let the heartbeat run on a thread that survives a frozen GUI thread; that would defeat the check.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
