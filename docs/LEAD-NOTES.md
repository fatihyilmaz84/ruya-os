# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2); clean up every merged worktree with `scripts\worktree-done.ps1`**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-40 (Opus, 2026-11-21; the owner was present most of the day)

- **Review range:** d639cdbb..HEAD (all reviewed). **Paper Plane `changes` cursor:** 7517.
- **Merged and Done (20):** RUY-989, 995, 999 (+1000, the same cause), 1001, 1002, 1003, 973, 996, 1005, 1006, 1014, 1018, 1013, 1008, 1009, 1010, 1004; also RUY-1015 (design: ADR-040) and RUY-1020 (folded into 1018). The last gate on main is **2361 passed, 0 failed**.
- **The .play Windows path works.** On VM 0.0.99 and again on 0.0.100: base queue 17/17 and .play queue 15/15 (launch-windows: `0 quit` twice, the save survives, no network). On the Dell (0.0.99): the sample passes, and **Unreal Tournament GOTY runs as a local .play at 60 FPS** (RUY-1007, from the owner's `C:\GOG Games`; packages stay in `output\ut-play\` and on the Dell, never the repo).
- **Images:** 0.0.99, then **0.0.100** (main f747f15f), both all PASS. The Dell runs 0.0.100 (rollback 0.0.99): no WebP errors; `bootloader-update.service` fails (Secure Boot without the 2023 CA, RUY-24 item 1). Merged after 0.0.100 and still vm pending: 1018, 1013, 1008, 1009/1010, 1004.
- **Decisions:**
  - ADR-036 amended (one CIL module per concern; `ruya_play_runners.cil`).
  - **ADR-039 Proposed** (a game asks for the player's own ROM; owner decision **RUY-1012**).
  - **ADR-040 Accepted (architect)**: `run.writable`, the per-profile game tree.
  - New crate **ruya-ids** (the profile-id and user-name rule).

## In flight
- Nothing. RUY-1004 (Play1 `offline`, Try again) merged in lead-40 after a round 2 that added the shot (128b) and the **real Flatpak offline line** from the Dell (`[7] Could not connect to server`); vm pending: RUY-1023. The Dell is free, with UT installed (`play.com.example.utgotylocal`).

## Next
1. **RUY-1019** (Ready, complex, Opus): the launcher's game tree (ADR-040). Then the Dell: UT keeps its settings without `INI=` (RUY-1007).
2. **RUY-494** (xwayland-satellite wl_shm_pool panic, now seen in 3 games, Wine included): the first X11 lead ticket.
3. Small .play items: RUY-1011, 1016, 1017, 1021, 1022, 1023, 982, 968, 963.
4. A **planning pass is overdue** (the inbox is past 190; the owner wishlist RUY-931..955 needs canvases). Then the owner's next goal, **RUY-956 Steam first-class**.

## Concerns (ranked)
1. X11 games crash in xwayland-satellite (RUY-494): the biggest gap for real games now.
2. A .play install needs the network once (the offline runtime set, RUY-916/974, is not built).
3. Disk: F: had 14 GB free (I deleted the 0.0.96 OCI and the 0.0.56 ISO); the WSL vhdx is 76 GB. `free-space.ps1` compaction is slow (RUY-957).
4. A merge gate went red once with every QML test green; the log was lost (now kept, see Process).

## Process changes in lead-40
- **Tests:** `merge-gate.ps1` keeps the whole test run in `output\merge-gate-test.log` and prints real failures, not the fixture tests' "ok ... FAIL" lines.
- **Lead:**
  - Linux-only crate tests run in WSL as an unprivileged user on ext4 (root ignores mode bits; drvfs ignores modes). The script is `output\fs-test.sh <worktree> <crates>`; make it a tracked script (inbox).
  - One debugging agent with a booted VM found all four 0.0.98 failures in 16 min.
  - A Dell agent ran the sample and a real game.
  - Lead-checked facts on the Dell (flatpak output formats, the offline error text) caught a real gap in RUY-1004.
- **Lesson:** a `sed` on a script with Windows paths turned `\f` into a form feed again. Write such files with Write/Edit (CLAUDE.md's rule).
- **Paper Plane:** none new.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-20/21 (lead-38) | 58bb188..6a4b709 | 5 tickets merged + 4 lead review/docs commits | rounds 2-3 on 816, 744, 909, 35 (all real) | 2305 passed, 0 failed | 0.0.97 failed twice (musl; F: full) |
| 2026-11-21 (lead-39) | 6a4b709..d639cdb | 15 tickets merged + 3 review commits + RUY-891 + worktree-done.ps1 | round 2+ on 13 tickets, all real | 2357 passed, 0 failed | 0.0.97 24/28; 0.0.98 26/30 (4 filed) |
| 2026-11-21 (lead-40) | d639cdb..HEAD | 19 tickets done + ADR-039/040 + 2 lead docs/review commits; filed 1003-1023 | round 2 on 995, 996, 1018 (case-folding, API review), 1004 (shot, real offline text): all real | 2361 passed, 0 failed | 0.0.99 32/32, 0.0.100 32/32; Dell: sample + UT |
