# T-278 — Background and memory policy ("game mode"): keep the foreground fast, close background apps politely

Status: todo · Phase: 3 · Depends: T-273, T-274, T-275, T-201 · Area: services, image · Size: M · Owner: lead

## Goal
While a game runs, it gets the CPU, GPU, IO and memory it needs: background apps are frozen, deprioritised and, when memory runs short, closed least-recently-used first with a warning and a chance to save; the shell and the foreground app are never the victims. Part of epic T-273.

## Read first
- T-273 (model), T-274 Outcome (measured freeze behaviour, zram/swap facts), T-201 (watchdogs, `OOMScoreAdjust`, systemd-oomd facts), T-275 contract, `image/CLAUDE.md`, `ruya-session`, systemd resource control (`CPUWeight`, `IOWeight`, `MemoryLow/High/Max`, `ManagedOOMMemoryPressure`, PSI)

## Scope
1. **Slices:** the foreground app's unit gets high weights and `MemoryLow`; background apps `MemoryHigh` and lower weights (set by `ruya-session` on `Switch`, undone on thaw); the shell stays protected (T-201). Limits scale with RAM (8 GB baseline).
2. **Killer:** a policy in `ruya-session` fed by PSI (`memory.pressure`) and cgroup memory events: above a threshold it closes the least recently used background app with `Stop` (SIGTERM, 5 s grace to save, then kill); emits `AppClosedForMemory(instance, app_id)`; never the foreground app, never an app holding a background reason unless nothing else is left. Hysteresis so it does not oscillate; a cool-down; an `ruya-oomd`-style rule, not a second daemon, unless the spike (T-274) shows `systemd-oomd` cannot rank by recency.
3. **Shell:** toast "<App> was closed to free memory" (kind `warning`, queued while an app is in front only if not critical: decide in the Outcome), the relaunch card in the switcher (T-277).
4. **Open-app limit:** `Launch` above N background apps closes the oldest first (same path).
5. Optional zram swap in the image if T-274 says it helps; an image change, VM-verified.

## Out of scope
- UI beyond the toast, per-app user settings, cloud saves.

## Acceptance criteria
- [ ] Rust tests for the ranking (LRU, holders last, foreground never), hysteresis and cool-down with a fake pressure source and clock.
- [ ] VM (this task): a memory-eater background app in a QEMU guest with small RAM is closed first while the foreground sample keeps running; `systemd-analyze security` unchanged; `RUYA_BOOT_OK`; Dell frame-time check queued for the lead (hw).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Docs to update
- 01 §2 (resource policy), 03 §1.1, `image/CLAUDE.md`, developer guide (what an app can expect).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | hw (pending: …)`._
