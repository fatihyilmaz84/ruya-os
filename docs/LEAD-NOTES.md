# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. History lives in the STATUS session log and git.

## State at the end of lead-11 (Opus, 2026-11-11/12; weekly plan 85 %)

- **Owner, this session:** two builder lanes are fine; "stop after the current tasks" (so lead-11 ended with T-466 and T-454); T-469 written, **not started** (the Hub's Performance panel becomes a toggle for a performance overlay in the top corners while gaming). Owner asked for: no unneeded test runs (merge gate), developer docs kept current automatically (the "what a running app experiences" rule), frozen games' cost (study, T-464..T-466), NTSYNC (in T-381's scope).
- **Merged:** T-462 (shots refuse a sleeping display), T-458 (Closing screen), T-452 (Hub Performance panel), T-453 (Hub Controllers panel + `Devices1.Bluetooth.ListGamepads`), T-464 (a frozen game never thawed behind another), T-465 (zram), T-467 (running games always reachable), T-463 (Qt step about 110 s instead of 345 s: per-file processes, test motion scale 0.1), T-468 (developer docs: the Hub freezes your game), T-466 (a frozen app's sound parked on `ruya-parked`, memory reclaimed after 30 s with swap; restore retried), T-454 (Hub Display panel, `Devices1.Display` brightness). Nothing in flight: no worktree, no builder. Last gate green at 6e358a3.
- **Images:** 0.0.64 (VM queue PASS after three check fixes); **0.0.65** at 65af336 (zram; not T-467, T-463, T-468, T-466, T-454): VM queue PASS except the idle-spawn check (Inbox); **the Dell runs 0.0.65** (rollback 0.0.64), zram 3.7 GB zstd live. `dell-glass-check.sh` PASS on the High tier on 0.0.64 (the Dell itself is set to Performance; the check now refuses other tiers). CI green at a789afd (sharded).

## Next, in this order
1. **Build 0.0.66** from main (T-467, T-466, T-454 and the check fixes), `vm-queue.ps1` with `-Audio` for T-466's Freeze sound part, plus `vm-app-check.sh reachable` and `recreate` (need a game driven by hand), then `dell-update.sh 0.0.66`.
2. **On the Dell** (look-at list in STATUS, VM queue paragraph): the Hub over a frozen STK with sound and the park/restore of T-466 (sound back after Resume? idle power with a frozen game, Resume time); Play on BombSquad/Asteroid Shooter's Running card after Home and the Hub from Home (T-467); a wired pad in the Controllers panel (T-453); the shell's GPU at the picker right after boot (0.0.65's update summary said 43 % busy; 0.0.64 said 0 %: check it is not a regression); Superfluous Returnz segfaults at start.
3. Builders: T-469 (owner), T-455, then STATUS's order. Planning pass due: the Inbox is long (lead-10's untriaged lines are parked in STATUS-parked.md).

## Concerns (ranked)
1. T-466's park/restore and reclaim are VM- and hardware-unverified and touch sound for every game: watch the first Dell run closely (a game left silent = the retry path).
2. The idle-spawn VM check catches one event-driven `pw-dump` per minute (3 of 3 runs): find the PipeWire event before touching the check.
3. Tests at motion 0.1 can hide or cause flakes: two found and fixed (tst_hub_pause, tst_settings_lazy, tst_wallpaper on CI); a weekly `RUYA_TEST_MOTION=1` run is on the Inbox.
4. STATUS is over its 10 KB budget (Inbox): prune at the next planning pass.

## Process changes in lead-11
- `scripts/merge-gate.ps1`: reuses the builder's green `dev.ps1 test` when main differs only in docs; never commit on main while a gate runs (no marker). Builders run the last full test after committing.
- Builders grep `vm-*.sh`/`dell-*.sh` for changed log lines and answers; UX review only for new screens, flows, modals or navigation paths.
- Changes to what a running app experiences make a task `public-*`, update `docs/developers` and get the API reviewer (PLANNING, builder, reviewer, LEAD).
- `dell-glass-check.sh` stops with NOT RUN off the High tier.

## Host facts learned
- Never put backslashes in a Bash heredoc or a `python -c` string: use Write/Edit. PowerShell `-like` treats `[` as a wildcard. `powershell -File` from Bash joins array arguments; `wsl.exe` from Git Bash needs `MSYS_NO_PATHCONV=1` for `/mnt/...`.
- Never `Stop-Process tst_ruyashell` blindly. `make-disk` beside `dev.ps1 test` can run out of WSL memory (retry with `SKIP_BUILD=1`).
- The Dell's host key changes with a reinstall: the scripts use `StrictHostKeyChecking=no`; the old entry in `~/.ssh/known_hosts` makes a plain `ssh` fail.
- A builder hand-back of just "placeholder" happened once: check the worktree's commits and ask for the real HANDOFF.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-10 (lead-9) | 66d6f25..main | T-423, T-421, T-424, T-147 | T-147 deleted 9 tests silently (round 2); CI red fixed | 1063 QML + 89 skips | none built |
| 2026-11-10 (lead-10) | 8e02406..main | T-434, T-435, T-449, T-451, T-448, T-429, T-457, T-450 | 5 of 8 needed a round 2; 4 stale VM check patterns fixed; T-448 broke shots (T-460) | 1134 QML + 95 skips | `0.0.62`, `0.0.63` PASS; Dell 0.0.63 |
| 2026-11-11 (lead-11) | 6cd6b20..main | T-462, T-458, T-452, T-453, T-464, T-465, T-467, T-463, T-468, T-466, T-454 | round 2 for T-452 (contrast), T-453 (contract), T-463 (flake), T-466 (restore retry); 6 stale VM checks fixed; dell-glass ran on the wrong tier | 1232 QML + 100 skips, Qt step 110 s | `0.0.64`, `0.0.65`; Dell 0.0.65 |
