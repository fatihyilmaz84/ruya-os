# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; up to four lanes; builders run nothing in WSL since lead-20**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`); `docs/STATUS*.md` and `docs/tasks/T-*.md` are a frozen archive. **Goals are formations** (`formation` lists them; `PLANNING.md` step 4). This file is the lead's session record.

## State of lead-21 (Opus, 2026-11-14/15; ran overnight, owner asleep)

- **Owner, 2026-11-15:** keep going in this session, don't stop for usage; **no images and no VM queue** (the Dell is off): every VM criterion stays `vm pending`, listed on RUY-390.
- **Review range:** 00bbe87..HEAD. Paper Plane `changes` cursor: read from **2638** (much since).
- **Merged and Done (31):** 156, 404, 621, 414, 125, 402, 121, 18, 21, 629, 627 (+642), 641, 25, 637, 653, 636, 640, 38, 651, 654, 652, 648, 655, 155, 625, 467, 656, 649, 122, 657; plus 448 (co-op re-plan) and 120. **Co-op chain:** seats (121), hold (627), only player 1 navigates (38), chips (629, 649), "Who's playing?" with the **seat gate on** (122). Next: 628 (Move + PIN, in flight), then 631 (Guest), 124 (remembered owner), 630 (Add profile: needs a board).
- **Images:** 0.0.83 (00bbe87) is the newest, on the Dell. **Nothing merged this session is on an image.** RUY-18 changes the image itself (sudo gone, unit hardening, LLMNR off): the next image's VM queue must pass before the Dell gets it. RUY-390 lists every pending check.

## In flight
- **RUY-628** (Move + PIN with the new pad; replaces RUY-122's interim "Join as player 1" and PIN notice): Opus builder. Then code + design + UX reviews.
- **RUY-643** (seats 2-4 use their own controller profiles), **RUY-659** (revert-check default mode reads dev.ps1's exit code): builders.
- Worktree `RUY-549b` (stale, needs WSL). Locked folders to delete by hand: `D:\dev\RuyaOS-worktrees\RUY-403`, `525`, `547`, `590`, `622`, `156`, `636`.

## Next
After 628: RUY-631, 124, 644 (replay after a restart during a hold), 638 (notifications follow-ups), 650 (HubControllers shot), 658 (battery flake). Held for a re-plan: RUY-12 (compositor, VM), 26 (stale), 407 (needs a design board shared with the game page).

## Owner decisions open
- **RUY-632:** Guide on player 2-4's pad (recommend: nothing now) and "Use this controller" in the Hub (recommend: no; the prompt's Move is the path).
- Lead items that may become owner questions: RUY-639 (notification policy), RUY-647 (release support access without sudo), RUY-633 (attribution, strictest age limit).

## Concerns (ranked)
1. Real hardware and the VM: 31 merges unproven on Linux; RUY-18 could break the compositor boot or the first-boot Flathub remote; the seat gate (122) changes what every game sees.
2. `dev.ps1 shots` is unreliable while several builders run (lost window activation): UI tickets merged on reviewed shots where they ran.
3. Co-op service tickets ran large (121: 529k, 627: ~750k, 38: ~460k, 122: ~485k tokens, all Opus).

## Process changes in lead-21
- Pre-build reviews by read-only Explore agents (<= 40 lines back); the lead writes the ruling. Caught stale tickets (407, 26, 12) and done items.
- Big re-plans: an Opus planner drafts into the scratchpad; a script applies them over `POST /api/tools/update`.
- UX and design reviewers get the ticket text as a scratchpad file (they have no Paper Plane tools).
- **Builders stop processes by PID only** (ruya-builder.md): a `taskkill /IM ruya-shell.exe` turned a merge gate red.
- revert-check: verdict from exit codes and this run's logs (654), `-Mode docs|vmchecks` (657).
- Paper Plane: issues #10 (blocks=[] doesn't clear) and #9 (same-state move drops evidence) commented.

## Host facts learned
- Git Bash rewrites `/mnt/c/...` arguments to `wsl`: prefix `MSYS_NO_PATHCONV=1`. `pkill -f image-chain.sh` inside `wsl bash -lc` kills that bash too.
- In PowerShell `git worktree remove` is devkitPro's git: use the Bash tool.
- merge-gate's RED summary greps "FAIL" only: when it shows none, rerun `dev.ps1 test` with full output to find the step.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-14 (lead-20) | a1f1299..00bbe87 | 11 merged | round 2 for 41; 4 VM-check bugs fixed; 624 found in the VM; 12 inbox filed | 1680 QML + 144 skips | 0.0.81, 0.0.82 queues; 0.0.82 on the Dell |
| 2026-11-15 (lead-21) | 00bbe87..HEAD | 31 merged + 448 re-plan | rounds 2-3 for 404, 621, 121, 21, 627, 38 (x2), 122, 637, 654; lead fixes in 404, 402, 18, 629, 649, 122; 1 VM check bug and 1 test race fixed; ~35 tickets filed | 1788 QML + 148 skips; GitHub CI green on the pushes | 0.0.83 queue (RUY-624 proven; RUY-645 open); Dell on 0.0.83 |
