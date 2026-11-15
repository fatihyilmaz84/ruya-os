# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; up to four lanes; builders run nothing in WSL since lead-20**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`); `docs/STATUS*.md` and `docs/tasks/T-*.md` are a frozen archive. **Goals are formations** (`formation` lists them; `PLANNING.md` step 4). This file is the lead's session record.

## State after lead-21 (Opus, 2026-11-14/15; ran overnight)

- **Review range:** 00bbe87..HEAD. Paper Plane `changes`: read the latest 200 (the cursor moved far past 2638).
- **Merged and Done (38):** 156, 404, 621, 414, 125, 402, 121, 18, 21, 629, 627 (+642), 641, 25, 637, 653, 636, 640, 38, 651, 654, 652, 648, 655, 155, 625, 467, 656, 649, 122, 657, 643, 659, 660, 658, 628, 644, 631; plus 448 (co-op re-plan) and 120. Lead fix `7b7dc5f2` (StorePage: Back from a search focused stale rows over D-Bus; found by CI's Linux job).
- **Co-op is end to end on the host:** seats, 60 s hold, only player 1 navigates, chips, "Who's playing?" with the **seat gate on** (unjoined pads reach no game), Move + PIN with the new pad, Guest. Left: RUY-124 (in flight), 630 (Add profile: needs a board), 664 (guest follow-ups), 662 (PinPad polish).
- **Pushed:** origin at 17a8a2b2 (GitHub CI green, incl. RUY-155's first `-Samples`); main is ahead by RUY-631 and these notes: push with `push-main.ps1`.

## First thing next session: images (the Dell is back on, owner 2026-11-15)
**Nothing merged in lead-21 has run on Linux hardware or in a VM.** Build 0.0.84 from main (`image-chain.sh 0.0.84 oci`), then the VM queue: the default list plus every check queued on **RUY-390** (players, seathold, owner, guide, join, shell, confirm, twopads, close, useractive, signals; profiles create+guests; store; session check/restart/display; devices bluetooth). **RUY-18 changes the image** (sudo gone, units hardened, LLMNR off, deny own): watch the compositor boot and the first-boot Flathub remote; then `vm-security-check.sh measure` (RUY-646). Only after the queue passes: `dell-update.sh 0.0.84`, and try co-op on the Dell with two pads (the seat gate changes what every game sees: the owner already saw SuperTuxKart take both pads on 0.0.83). RUY-645 (session `display`) needs the VM commands in its ticket.

## In flight at handoff
- **RUY-124** (a controller remembers its player): a ruya-builder (Sonnet) is running in worktree `D:\dev\RuyaOS-worktrees\RUY-124`, branch `t/RUY-124-remembered-owner`. Its HANDOFF reaches lead-21 only: check the ticket (In Review + Outcome comment) and the branch's last commit, then send it to `ruya-reviewer` (+ UX if the focus order reads oddly).
- Locked folders to delete by hand: `D:\dev\RuyaOS-worktrees\RUY-403`, `525`, `547`, `590`, `622`, `156`, `636`, `659`. Stale worktree `RUY-549b` (RUY-549 needs WSL).

## Next (after the images)
RUY-664, 662, 638 (notifications), 661 (callLater-focus audit), 663 (dev.ps1 lock), 650 (HubControllers shot). Re-plan: 12 (compositor, VM), 26 (stale), 407 (needs a board shared with the game page), 630 (Add profile board). Inbox to plan: about 25 tickets filed tonight (labels `inbox`).

## Owner decisions open
- **RUY-632:** Guide on player 2-4's pad (recommend: nothing now); "Use this controller" in the Hub (recommend: no, the prompt's Move is the path).
- Lead items that may become owner questions: RUY-639 (notification policy), 647 (release support access without sudo), 633 (per-player attribution, strictest age limit).

## Concerns (ranked)
1. 38 merges unproven on Linux; RUY-18 and the seat gate are the riskiest.
2. `dev.ps1 shots` is unreliable while several builders run (lost window activation).
3. Co-op tickets ran large: 121 529k, 627 ~750k, 38 ~460k, 122 ~485k, 628 ~590k tokens (Opus).

## Process changes in lead-21
- Pre-build reviews by read-only Explore agents (<= 40 lines back); the lead writes the ruling (caught stale 407, 26, 12).
- Big re-plans: an Opus planner drafts into the scratchpad; a script applies them over `POST /api/tools/update`.
- Design/UX reviewers get the ticket text as a file (no Paper Plane tools).
- **Builders stop processes by PID only** (ruya-builder.md).
- revert-check: verdict from exit codes and this run's logs (654, 659), `-Mode docs|vmchecks` (657), script self-checks in `dev.ps1 docs` (660).
- A Linux-only CI failure is diagnosed by an agent allowed to run the CI image in WSL (found a real bug in 20 min).
- Paper Plane: issues #10 (blocks=[] doesn't clear) and #9 (a same-state move drops evidence) commented.

## Host facts learned
- Git Bash rewrites `/mnt/c/...` for `wsl`: prefix `MSYS_NO_PATHCONV=1`. `pkill -f image-chain.sh` inside `wsl bash -lc` kills that bash too.
- merge-gate's RED summary greps "FAIL" only: if it shows none, rerun `dev.ps1 test` with full output.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-14 (lead-20) | a1f1299..00bbe87 | 11 merged | round 2 for 41; 4 VM-check bugs fixed; 624 found in the VM; 12 inbox filed | 1680 QML + 144 skips | 0.0.81, 0.0.82 queues; 0.0.82 on the Dell |
| 2026-11-15 (lead-21) | 00bbe87..HEAD | 38 merged + 448 re-plan | rounds 2-3 for 404, 621, 121, 21, 627, 38, 122, 637, 654, 628, 631; lead fixes in 404, 402, 18, 629, 649, 122, StorePage; 1 VM check bug and 1 test race fixed; ~45 tickets filed | 1832 QML + 149 skips; GitHub CI green | 0.0.83 queue (624 proven; 645 open); Dell on 0.0.83 |
