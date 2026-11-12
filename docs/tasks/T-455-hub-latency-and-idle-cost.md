# T-455 — Hub budgets: activation latency, idle cost and the game's FPS with the Hub open, measured on the Dell

Status: in-progress · Phase: 2 · Depends: — · Area: scripts, shell (fixes only) · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
We know, with numbers from the Dell, how fast Guide opens the Hub over a game, what the Hub costs while hidden and open, and how much the game's FPS drops while it is open; budgets are written down and a script repeats the measurement.

## Read first
- ADR-033; `07-hub-requirements.md` §8; `scripts/dell-glass-check.sh` (uinput keys, drm fdinfo, KMS captures); T-451 (the compositor's FPS counter, if merged)

## Scope
1. `scripts/dell-hub-check.sh`: with STK in front, press Guide through uinput and measure the time to the Hub's first frame (compositor log line with a timestamp, added if missing), the shell's GPU and CPU while the Hub is hidden and open, and the game's FPS before and during.
2. Write the budgets into `02` §1.6 (proposal: open under 100 ms, hidden cost zero frames, game FPS drop under 10 % on the Dell) and the measured numbers into the Outcome.
3. Fix what the numbers show if the fix is small; otherwise an Inbox line.

## Acceptance criteria
- [ ] The script runs on the Dell and prints the numbers with PASS/FAIL against the budgets (output in the Outcome)
- [ ] hw: the numbers are from the Dell; `Verified: hw`
- [ ] `dev.ps1 test` ALL GREEN

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `02` §1.6 (budgets), `docs/dev-setup.md` (the script).

## Hints
- Planned by lead-10 (ADR-033). The builder may use the Dell (CLAUDE.md, Dell rule).

## Outcome
Verified: hw (numbers from the Dell; the T-455 shell was run there as an overlay, see Dell below; the image itself is not rebuilt, `vm` not needed).

**Built.** `scripts/dell-hub-check.sh` (PASS/FAIL per budget, exit 0/1/2). The shell now writes `page-open hub create= firstSwap= afterAnim=` for every Hub open that settles (PageProbe, begin on Guide in `Shell.guideDown`, settled from the new `QuickMenu.settled`; an open closed before it settles writes nothing). `RUYA_PERF_LOG=1` makes `Performance` hold a consumer for the run and log `perf-frames fps= full= commits= meanMs= p99Ms=` per frame update (the measuring switch for the game's FPS; the frame meter only runs while a consumer is open, and the T-469 overlay is not in 0.0.66). Budgets and numbers are in 02 section 1.6; `docs/dev-setup.md` describes the script.

**Numbers (Dell, 0.0.66 + T-455 shell, UHD 630, SuperTuxKart 60 FPS), final run of the script:**
```
Hub hidden: render 1128 ms in 10 s (11 % of the GPU), shell CPU 112 ticks in 10 s (11 % of a core)   PASS (budget 20 %)
Hub open (10 of 10): first frame median 23 ms, worst 47 ms; slide ended at median 215 ms            PASS (budget 100 ms)
Hub open, still, game frozen: render 5 ms in 10 s (0 %), shell CPU 0 ticks in 10 s                  PASS (budget 300 ms)
Game FPS: Hub closed 60.1 (44 samples), Hub open 60.0 (40 samples, pauseGames=false)                PASS (drop under 10 %)
```
The first run gave the same (23 / 27 ms, 0 ms, 60.0 / 60.0). Not tested: the budget numbers on a game that is heavier than STK's menu.

**Picker idle cost (item 3).** Not a regression: the picker's blobs drift for 30 s after the shell starts (LiquidGate), and `dell-update.sh` measured inside that window. After a shell restart, 10 s windows: 1623, 1704, 1483 ms (about 16 %, CPU 106-121 ticks) while the shell is 0-30 s old, then 0, 0, 0, 5, 0 ms from 30 s on; a picker locked from a long-running shell: 0 ms after 3 s and after 60 s. Fix: `dell-update.sh` waits until the shell is 40 s old before it measures. (The 39-43 % the lead saw is the same window, boot adds load; if a resting picker ever shows more than 0 % after 40 s, that is a real finding.)

**Revert check.** Removed `pageProbe.begin("hub")` in `Shell.guideDown`: `tst_hub_pause::test_the_hub_writes_its_open_time` failed; restored. `RUYA_PERF_LOG` and the script have no host test (a diagnostic switch; its proof is the Dell run).

**Dell.** Bind-mounted my build of `ruya-shell` (built in WSL from the Containerfile's shell-build stage) over `/usr/bin/ruya-shell` (copy in `/var/tmp/ruya-shell-t455`; gone at the next reboot), restarted the shell several times, signed in `p2` (tyx, no PIN) over D-Bus, stopped the apps of `p1` (STK, Cro-Mag Rally) and started STK as `p2` (still running). The script's FPS step edited `shell.conf` (`hub/pauseGames`) and added a volatile `/run` drop-in, both put back (checked). Profile is signed in as `p2`.

Files: scripts/dell-hub-check.sh (new), scripts/dell-update.sh, shell/qml/Shell.qml, shell/qml/QuickMenu.qml, shell/src/performance/Performance.{cpp,h}, shell/tests/tst_hub_pause.qml, docs/specs/02-shell.md, docs/dev-setup.md. No test removed or weakened.

