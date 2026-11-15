# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; up to four lanes; builders run nothing in WSL since lead-20**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`); `docs/STATUS*.md` and `docs/tasks/T-*.md` are a frozen archive. **Goals are formations** (`formation` lists them; `PLANNING.md` step 4). This file is the lead's session record.

## State of lead-21 (Opus, 2026-11-14/15; running overnight, owner asleep)

- **Owner, 2026-11-15:** keep going in this session, don't stop for usage; **no images and no VM queue** (the Dell is off): every VM criterion stays `vm pending` and is listed on RUY-390.
- **Review range:** 00bbe87..HEAD. Paper Plane `changes` cursor: read from **2638**.
- **Merged and Done (18):** RUY-156 (API level), 404 (vm-session-check trap), 621 (session late adoption), 414 (Hub Notifications panel, Settings > Notifications), 125 (VerifyPin, temporary guests), 402 (Hub tidy), 121 (Input1 seats; `SEAT_GATE=false` until RUY-122), 18 (image hardening: LLMNR off, sudo gone, deny own, units, port scope), 21 (Bluetooth leftovers), 629 (player chips, Hub players row), 627 (60 s seat hold; 642 twins with it), 641 (guest hardening), 25 (storage Rescan, backoff), 637 + 653 (ruya-session bounded calls), 636 (Store mock level), 640 (tests pick Settings by key). Also Done: RUY-448 (co-op re-plan), RUY-120 (epic spec). Pushed: e53fe794 (GitHub CI green).
- **Images:** 0.0.83 built (00bbe87) and on the Dell (rollback 0.0.82). Its queue: all PASS except `session display` (RUY-645, needs the VM) and `useractive`/`signals` (a check bug: the 30 s activity gate; fixed in a493b92). RUY-624 proven in the VM. **Nothing merged this session is on an image yet**; RUY-18 changes the image itself: build the next image and run its queue before the Dell gets it.

## In flight (check first)
- **RUY-38** (only player 1's pad navigates; SetNavigator; ForeignInput; lost-pad Hub) round 3: one guard test (a seat 2 pad must not be pulled into seat 1). Has the gate-off fallback: a padless, unheld seat 1 goes to the first unseated pad that presses (until RUY-122). Worktree `RUY-38`. **Don't put it on a daily-use image without the fallback** (it is in round 2+).
- **RUY-651** (Rescan as one atomic call, "Rescan %1"), **RUY-654** (revert-check verdict independent of piping), **RUY-652** (guest polish): builders running.
- Worktree `RUY-549b` (stale): RUY-549 round 3 needs WSL; not now.
- Locked folders to delete by hand: `D:\dev\RuyaOS-worktrees\RUY-403`, `RUY-525`, `RUY-547`, `RUY-590`, `RUY-622`, `RUY-156`, `RUY-636` (the auto-mode classifier refuses).

## Next (Ready, after the in-flight work)
RUY-122 (prompt; turns SEAT_GATE on and drops RUY-38's fallback: see its lead comments) -> RUY-628, 124, 631. Inbox to plan: RUY-638 (notifications), 643 (seat 2-4 own controller profiles), 644 (replay after a restart), 648 (Bluetooth polish), 649 (held chip state), 650 (HubControllers shot fails: check first). Held: RUY-12 (compositor, needs a VM), RUY-407 (needs a design board shared with the game page, ADR-035 amendment).

## Owner decisions open
- **RUY-632:** Guide on player 2-4's pad (recommend: nothing now) and "Use this controller" in the Hub (recommend: no, the prompt's Move is the path).
- RUY-639 (notification policy) and RUY-647 (release support access without sudo) are lead items that may become owner questions.

## Concerns (ranked)
1. Real hardware: nothing since 0.0.83 has run anywhere but the host; RUY-18 could break the compositor boot or the first-boot Flathub remote (watch them in the next VM run).
2. Paper Plane can't remove a `blocks` relation (EnigmaNL/PaperPlane#10): RUY-125 needed an override; stale relations remain on RUY-125.
3. RUY-121 took 529k tokens over two rounds (Opus): split co-op tickets further if the next ones run as long.

## Process changes in lead-21
- Pre-build reviews delegated to read-only Explore agents (one per 1-2 tickets, <= 40 lines back); the lead writes the ruling comment. Caught a stale ticket (RUY-407), a split (RUY-156 -> RUY-625) and done items (RUY-402 Scope 3).
- Big re-plans: an Opus planner drafts the ticket rewrites into the scratchpad; the lead checks one and applies them with a script over `POST /api/tools/update` (two passes: create, then bodies with the real ids).
- Paper Plane: issue #10 commented (blocks=[] does not clear).

## Host facts learned
- Git Bash rewrites `/mnt/c/...` arguments to `wsl`: prefix `MSYS_NO_PATHCONV=1`. `git` inside WSL cannot read a Windows worktree's `.git` file.
- In PowerShell `git worktree remove` is devkitPro's git: use the Bash tool.
- `pkill -f image-chain.sh` inside `wsl bash -lc` also kills that bash (exit 15): check with `ps | grep [i]mage-chain`.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-14 (lead-20) | a1f1299..00bbe87 | 11 merged | round 2 for 41; 4 VM-check bugs fixed; 624 found in the VM; 12 inbox filed | 1680 QML + 144 skips | 0.0.81, 0.0.82 queues; 0.0.82 on the Dell |
| 2026-11-15 (lead-21, so far) | 00bbe87..HEAD | 8 merged + 448 re-plan | round 2 for 404, 621, 121, 21; lead fixes in 404, 402, 18 docs; 1 VM check bug fixed; ~25 inbox filed | 1718 QML + 146 skips | 0.0.83 queue (3 FAIL: 1 check bug fixed, 1 open RUY-645, 1 shared cause); Dell on 0.0.83 |
