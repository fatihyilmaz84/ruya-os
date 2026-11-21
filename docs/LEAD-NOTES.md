# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2); clean up every merged worktree with `scripts\worktree-done.ps1`**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-41 (Opus, 2026-11-21/22; the owner was present, and asked to stop after the in-flight work)

- **Review range:** 502020d2..HEAD (all reviewed). **Paper Plane `changes` cursor:** about 7740 (7724 plus this session's last moves).
- **Merged and Done (16):** RUY-1016, 1011, 1021, 799, 1019, 880, 494, 1022, 1031, 1017, 1034, 1028, 1029, 1030; also 102 (already done by RUY-851, no diff) and 1032 (a lead docs line). Lead commits: 99b26d16 (vm-queue guard), b4447552 (the RUY-494 check's real wording). Last gate on main: **2362 passed, 0 failed**.
- **RUY-494 is fixed** (X11 games dying at start). Cause: the compositor offered no xdg-decoration, so xwayland-satellite drew a 25 px title bar from a growing shm pool, which trips libwayland 1.26's deferred resize while Qt holds a pool ref. Fix: `XdgDecorationManagerV1`, server-side. **Dell 0.0.102: 10/10 starts** (ROTA 5/5, UT 5/5); before, it failed 1 to 2 times in 3. RUY-1027 tracks the same race for native clients.
- **RUY-1019** (the ADR-040 game tree) merged after a round 2 that fixed data loss on a rebuild cut short across two builds.
- **Images:** 0.0.101 (main 502020d2): base queue 17/17 (session check and storage scan passed on a rerun, logs lost; fixed in 99b26d16), .play 13/13. **0.0.102** (main 5f0dc506): x11, launch-windows, launch, check and session all PASS. **The Dell runs 0.0.102** (rollback 0.0.100); `bootloader-update.service` still fails (RUY-24).
- **Monster Boy** (owner's GOG copy) is packed as a local .play: `output\monsterboy-play\monsterboy.play.zip` (5 GiB, needs an exFAT stick; never commit). The owner installed it on the Dell from USB: it installs and boots. That run found two real bugs, below.

## In flight
- Nothing. All worktrees are merged and removed. Merged after 0.0.102 and still vm pending: RUY-1028 (vm-x11-check bridge step), 1029, 1022 (host-only is enough for 1022, 1031, 1034, 1011, 1021).

## Next
1. **RUY-1039 (high):** .play on GE-Proton sees no controller. winedevice logs `Failed loading SDL3 library.` and opens no input fd, although the virtual pad is routed and readable in the sandbox. The runtime 26.08 SDL2 is probably sdl2-compat. The failing process runs from `i386-unix` in a package without multiarch. Diagnose on the Dell with Monster Boy installed.
2. **RUY-1038 (high):** the install screen shows no art on a console. Inspect's art is in `/var/lib/private/ruya-play-work/...` (0700 root), which the shell can't read. Lead recommendation: a `/run/ruya-play/inspect/<job>` folder readable by the ruya-shell group, written via ruya-fs, rather than fd passing plus a C++ image provider.
3. The Dell with `RUYA_PIN`: `vm-play-check.sh launch` (RUY-1017), and UT without `INI=` through `run.writable` (RUY-1007).
4. A planning pass (inbox ~200), then the owner's next goal, **RUY-956 Steam first-class**.

## Concerns (ranked)
1. Controllers in Proton .play games (RUY-1039): every Windows .play with a pad is affected.
2. Pre-install art on real hardware (RUY-1038): the mock and the shots cannot see this class of bug. Add VM checks that open service-made paths as ruya-shell.
3. Disk: F: 22 GB free (0.0.101 and 0.0.102 OCIs, the 0.0.99 OCI deleted); D: about 80 GB. `free-space.ps1` was not run (compaction is slow, RUY-957).

## Process changes in lead-41
- **Tests:** `vm-queue.ps1` refuses a running QEMU *before* clearing its logs, and `Stop-Vm` waits for the exit (a second queue had deleted the first one's FAIL logs).
- **Lead:**
  - A diagnostic agent on the Dell with a reproducer found RUY-494's cause in 12 min. The same agent then proved the fix.
  - Lead-reviewed small diffs (<100 lines, no design question) instead of dispatching ruya-reviewer: 1016, 1011, 1021, 880, 494, 1022, 1031, 1017, 1034, 1029/1030. Opus reviewers went to 799, 1019 and 1028, and found real blocking issues in all three.
  - Mistakes: RUY-102 was rescoped without finding the existing test (grep the test *names*, not `include_str!`). A Git Bash `wsl ... /mnt/d` call needs `MSYS_NO_PATHCONV=1`. Helper modes (offline, generation, compat32, signals) are not queue checks.
- **Paper Plane:** none new.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-21 (lead-39) | 6a4b709..d639cdb | 15 tickets merged + 3 review commits + RUY-891 + worktree-done.ps1 | round 2+ on 13 tickets, all real | 2357 passed, 0 failed | 0.0.97 24/28; 0.0.98 26/30 (4 filed) |
| 2026-11-21 (lead-40) | d639cdb..502020d | 19 tickets done + ADR-039/040 + 2 lead docs/review commits; filed 1003-1023 | round 2 on 995, 996, 1018, 1004: all real | 2361 passed, 0 failed | 0.0.99 32/32, 0.0.100 32/32; Dell: sample + UT |
| 2026-11-21/22 (lead-41) | 502020d..HEAD | 14 merged + 102 closed + 2 lead commits; filed 1024-1039 | round 2 on 1021, 799, 1019, 1029, 1034, 1028: all real | 2362 passed, 0 failed | 0.0.101 17/17 + 13/13; 0.0.102 6/6; Dell: X11 10/10, Monster Boy installs (2 bugs filed) |
