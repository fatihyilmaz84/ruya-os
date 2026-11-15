# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; up to four lanes; builders run nothing in WSL since lead-20**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`); `docs/STATUS*.md` and `docs/tasks/T-*.md` are a frozen archive. **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-23 (Opus, 2026-11-15)

- **Review range:** 2e79297c..HEAD (every branch merged this session had a recorded APPROVE; lead review commits 47c03f52, 2f1d9b3a, badfa274). Paper Plane `changes` cursor 3978.
- **Merged and Done (16):** 685, 581, 503, 703, 578, 694, 691, 468, 692, 693, 710, 708, 500, 704, 707 (+509 closed by the owner's answer). Rounds 2 for 503 (split into 703), 578, 694, 703, 468, 693, 708, 707. Lead fixes: merge-gate.ps1 runs without -Worktree (it exited 0 untested), vm-queue.ps1 finds `if [ "$1" = mode ]` modes (watchdog was SKIPPED), 04 layer draw order, inhibitor doc per app.
- **Planning:** a planner turned lead-22's 15 decisions into tickets (RUY-688..698; 500 and 468 rewritten; 506/516 cancelled; RUY-81 needs a design). New Ready from today: 715, 716 (owner), 549 (re-scoped), 714, 701 (Backlog).
- **Images:** 0.0.85 VM queue: no product failure (co-op checks coop/seathold/twopads/players/guests PASS; watchdog PASS on a re-run; 3 check races fixed in RUY-708). **0.0.86 built (fc24e9c9); the Dell runs 0.0.86** (rollback 0.0.85; only bootloader-update failed, RUY-447; shell GPU 7 % at Home). The owner deleted tyx on it: a Dell check found the deletion clean (RUY-685 hw).
- **0.0.86 VM queue (main fc24e9c9, checks from 5b297b80): no product failure.** 26 of 28 in one boot (inhibit, profiles forget, input check, nodes last all PASS); seathold and devices system failed on check order and PASS alone (RUY-719).

## First thing next session
1. **Image 0.0.87** (main has 500, 704, 707, 708, 710 since 0.0.86): build, then its VM queue in the 0.0.86 order (`vm-boot-check.sh watchdog` first, `vm-input-check.sh nodes` last) with RUY-719's fixed checks; Dell update; the owner tries the wake flow (RUY-707) with a Bluetooth pad: keyboard wake and power-button wake; look for the late-wake journal line.
2. **Owner priority (2026-11-15): co-op, then gaming tuning, then the game page.** After the owner fixes 715/716/549 (sort 0-1): write the co-op builder tickets: RUY-633 (owner: refuse the join of a player below the game's age rating, a message says why), RUY-686 (pads made at launch, contract first), RUY-687 (Guide menu for players 2-4: canvas first); then tuning RUY-530/531/528/526 (sort 10-13); then the game page RUY-523/524/532/533/534 (sort 20-24).
3. Owner report RUY-718 (Backlog, lead): reaching the notification bell is hard; find how it is reached today and design a quicker path on a canvas before a builder ticket.

## Owner decisions taken today
Wake-from-sleep "Who's playing?" (RUY-707, ADR-017 amendment 7); no PIN on wake (RUY-712); age limit refuses the join (RUY-633); DualShock 3 over Bluetooth: Dell spike first (RUY-673); Wii U Pro sync button on the back (RUY-509); no new kept guests (RUY-716); RUY-549: clean build each run, only the package image cached.

## Concerns (ranked)
1. The wake flow is unproven on hardware: the Bluetooth pad's removal vs the resume (10 s watch, RUY-707).
2. Co-op on real hardware still not tried by the owner (STK split-screen, RUY-681).
3. Load flakes: parallel builders' `dev.ps1 test` slow image decodes (RUY-704 fixed one); never run a gate during `make-disk`.

## Process changes in lead-23
- merge-gate.ps1: -Worktree optional (missing = full test). Before: a silent exit 0 with nothing tested.
- vm-queue.ps1: if-test modes recognised.
- Reviewer findings that a builder's round 2 still fails narrowly: split into a new ticket instead of a round 3 (RUY-503 -> 703).
- Removing a worktree whose builder still runs a background test fails ("Permission denied"): retry after its last notification (RUY-578, RUY-710 left over: `git worktree prune`).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-15 (lead-22) | ab99589..2e79297 | 13 merged, 87 inbox triaged | rounds 2 for 6; 2 Linux-only reds fixed; ~20 filed | 1884 QML + 152 skips | 0.0.84; Dell on 0.0.84 |
| 2026-11-15 (lead-23) | 2e79297..HEAD | 15 merged, 11 tickets planned | rounds 2 for 8 tickets (2 wrong-pad bugs, 1 Bluetooth wake race, 3 vacuous tests); 2 lead script bugs fixed; ~20 filed | 1955 QML + 157 skips | 0.0.85 queue clean; 0.0.86 queue clean (2 check-order fails, RUY-719); Dell on 0.0.86 |
