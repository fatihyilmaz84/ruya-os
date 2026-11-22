# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2); clean up every merged worktree with `scripts\worktree-done.ps1`**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-43 (Opus, 2026-11-22; the owner was present all session)

- **Review range:** 74952c96..HEAD (every builder branch had an Opus review, RUY-1089 a lead review). **Paper Plane `changes` cursor:** about 8165.
- **Merged and Done:** RUY-1056 (per-profile Steam reader, ADR-045 + lead clarification SetActiveProfile), 1054 (B5: Steam never frozen; Hub sweep keeps a paused parent's children frozen), 1067 (B3b: LaunchItem for Steam games), 1089 (the window last in front comes back, the owner's "overlay" bug), 1075 (launch-windows check seated its pad). Lead work: 1059 (Steam docs), 1062 (ADR-046 `client` background reason, after an api-review round), 1049 (study S3), 1048 (spike S2), RUY-157 step 1 (ADR-022 identity proved). Last gate on main: 2381 QML + 2572 Rust, 0 failed. Pushed through 2fa93453; main is ahead by docs commits only.
- **Owner decisions today:** RUY-1081 = a (audio parking stays per profile; ADR-042 pt 2 amended; B4 cancelled). **Steam goal RUY-956 PAUSED** (owner rule: pause if S2 fails; S2 showed gamescope needs two permanent patches, and its Xwayland accepts unauthenticated clients; ADR-044 not accepted for now). **Next goal: Platform1, formation RUY-1095** (RUY-157 → 158 → 452-456 → Epic RUY-126). **New standing rule** (owner, in root CLAUDE.md): never build on a path you are not confident in; warn the owner plainly when their direction is wrong.

## In flight
- **RUY-1063 B9a (uinput for the signed-in profile), round 2**, worktree `D:\dev\RuyaOS-worktrees\RUY-1063`, Opus builder. Lead widened it: on a profile switch, `freeze = never` apps (Steam) are frozen too, and thawed on return (else the leaving profile's Steam keeps its uinput fd and injects into the next profile's game). Plus a bounded nav-keyboard remake, foreign nodes closed at start, and an SCM_CREDENTIALS uid check. Next: a delta review by ruya-reviewer (Opus, security), then merge and gate. Its VM/Dell checks go into the next image. **If lead-43's session has ended, the builder may have stopped with it:** look at the worktree's last commits and the ticket's comments; if round 2 is incomplete, dispatch a new `ruya-builder` (Opus) on the same worktree with the round-2 list in the ticket's lead comment "scope widened in round 2" and the review's findings.
- **0.0.105** (main 2fa93453, CHAIN OK): VM queues running, then `dell-update.sh 0.0.105` (one background chain; summaries `output\vm-queue-105-*.txt`, `output\dell-update-105.txt`). Dell list on RUY-390: steam-pause, RUY-1089 (Home → Running card → `focus app:hl_linux`), LaunchItem, `vm-library-check.sh steam`. Then delete the Dell's `/usr/local/bin/gamescope-spike`. **If those summaries are missing or partial** (the chain ran in lead-43's session): rerun `vm-queue.ps1` (default, then the .play list) and `dell-update.sh 0.0.105`; the oci archive is on F:.

## Next
1. Finish B9a (above); after its merge, the next image and the Dell negative/positive tests (criteria 9-10: a p1-made keyboard can't type in the PIN pad; the Half-Life left stick works with Steam Input).
2. **Platform1:** RUY-157's skeleton (scope 2-5) with the proven identity recipe in its comment; lead review against main first; ruya-api-reviewer on it.
3. Root CLAUDE.md is 11.2 KB (budget ~10 KB): prune.
4. Owner at the TV: the pad in Steam after a pause/resume, Monster Boy with the pad, USB install art.

## Concerns (ranked)
1. Steam Input under the satellite is still unproven even with B9a (S2 could not show a game template applied).
2. The Dell is the only real test of Steam; RUY-1094 (Dell Steam smoke script) should exist before Steam resumes.
3. An image build blocks merges for ~70 min (lead-42's idea: build from a throw-away worktree).

## Process changes in lead-43
- **Lead:** lead reviews by an Opus read-only pass, spot-checked by the lead, worked well (RUY-1056 split, RUY-1067 decisions, RUY-1063 found the scanner hole). Dell diagnostic agents settled 6 questions (S3, B4 audio identity, the overlay, S2, Dell lists).
- **Builders/reviewers:** two Dell runs by builders found real product bugs (Hub sweep thaws children; B5 widened) and a reviewer confirmed a cross-profile hole on the lead's prompt (B9a widened). Keep giving builders Dell access.
- **Owner rule:** CLAUDE.md maintainer bullet now says: never build on a path you are not confident in. **Tests:** none new. **Paper Plane:** none.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-21/22 (lead-41) | 502020d..52e8407 | 14 merged + 102 closed + 2 lead commits; filed 1024-1039 | round 2 on 1021, 799, 1019, 1029, 1034, 1028: all real | 2362 passed, 0 failed | 0.0.101 17/17 + 13/13; 0.0.102 6/6; Dell: X11 10/10, Monster Boy installs |
| 2026-11-22 (lead-42) | 52e8407..74952c9 | 11 merged, 3 closed, architect audit (ADR-041..045), 4 Dell diagnoses; filed 1040-1069 | round 2+ on 1038 (x2), 1039, 1050, 960, 1051, 1052, 52: all real | 2371 QML + 2540 Rust, 0 failed | 0.0.103 built, skipped; 0.0.104 building |
| 2026-11-22 (lead-43) | 74952c9..HEAD | 5 merged + 1 lead fix, 2 spikes + 1 study, ADR-046, 2 owner decisions, Steam paused; filed 1070-1095 | round 2+ on 1056, 1054 (x2), 1067, 1063: all real | 2381 QML + 2572 Rust, 0 failed | 0.0.104 17/17 + 11/12 (check bug, fixed); Dell 4/4; 0.0.105 running |
