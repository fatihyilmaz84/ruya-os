# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; up to four lanes; builders run nothing in WSL since lead-20**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`); `docs/STATUS*.md` and `docs/tasks/T-*.md` are a frozen archive (the owner asked about STATUS.md on 2026-11-15: it is frozen on purpose). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-24 (Opus, 2026-11-15, owner's stop at 00:00)

- **Review range:** f5e0726b..HEAD (every branch merged had a recorded APPROVE; lead commit a01dc799: 04's rows-only sub-page text). Paper Plane `changes` cursor 4049.
- **Merged and Done (5):** 616, 719, 714, 715, 716. Rounds 2 for 719 (the 250 ms window starts at the last *fresh* reading; my pre-build review had it wrong) and 714 (a refused layout save locked the pairing screen). One full merge gate for 719+714+715: 1977 passed, 0 failed, 166 skips (282 s).
- **RUY-716 merged and Done too** (round 1; the Add profile role row is gone: it offered Standard and Guest only). Its `vm-profiles-check.sh create` line only echoes (RUY-728).
- **Image 0.0.87** (f5e0726b = 500, 704, 707, 708, 710): chain OK (build 34, disk 35, oci 16 min). **VM queue: 28 of 28 PASS in 14 min** (lead-23's order, RUY-719's fixed checks; logs `output/vm-queue-087a/`). **The Dell runs 0.0.87** (rollback 0.0.86; updated at 23:34 after the owner switched it on: at 22:36 it was off). Failed: only bootloader-update (RUY-447); shell GPU 9 % at the picker; bluetoothd idle.
- **Pushed:** a01dc799 at 23:19 (Linux CI job warm, 7 min, PASSED); the RUY-716 merge and this handoff with the closing push. GitHub CI was in progress at the handoff: check `gh run list -L 3`.

## First thing next session
1. **Dell (on 0.0.87):** the owner tries the wake flow (RUY-707) with a Bluetooth pad (keyboard and power-button wake; look for the late-wake journal line) and the new profile page (RUY-715).
2. **Image 0.0.88** once there is more on main: owes RUY-616's `vm-security-check.sh` (busrecv) and `vm-security-check.sh signals`, plus RUY-716's profiles check if merged (RUY-390 comments).
3. **Builder lanes (Ready):** RUY-549 (needs WSL: dispatch only when no chain runs; the owner's new scope is in its last comment), then co-op tickets per lead-23's plan: write RUY-633, 686, 687 (canvas first); tuning RUY-530/531/528/526; game page RUY-523/524/532-534. Triage the new inbox tickets (720-728).
4. Owner report RUY-718 (notification bell hard to reach): canvas before a builder ticket.
5. **Architect audit (LEAD.md 5b, new in lead-25): none run yet.** The first one is a general audit at the next natural stop; focus questions: mock-only drift (RUY-730 was found by the owner, not by us), and a check that refuses a "built" spec claim whose contract is in `NOT_SERVED`.
6. **RUY-730** (ruya-notifications service, Ready, reviewed, not dispatched on the owner's word): the owner's empty notification centre on the Dell.

## Concerns (ranked)
1. The wake flow is still unproven on hardware (RUY-707) (the Dell has it since 0.0.87).
2. Nine stuck `python3 -` processes (from agent Git Bash heredocs) burned ~9 cores since 14 Nov; the auto-mode classifier refused the lead's Stop-Process, so the owner was asked (RUY-727).
3. Co-op on real hardware still not tried by the owner (RUY-681).

## Process changes in lead-24
- None in code. Findings filed: RUY-726 (image-chain prunes old oci archives itself: the chain stopped on F: space because free-space.ps1 was skipped after lead-23's chains), RUY-727 (stuck python processes).
- Lead review lesson: when a pre-build review states a service rule, cite the line that *sets* the state, not only the constant (RUY-719 round 2).
- One merge gate for several merges is fine when no commit lands between them; run it after the VM queue, never beside `make-disk` or QEMU.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-15 (lead-23) | 2e79297..f5e0726 | 15 merged, 11 tickets planned | rounds 2 for 8 tickets; 2 lead script bugs fixed; ~20 filed | 1955 QML + 157 skips | 0.0.86 queue clean; Dell on 0.0.86 |
| 2026-11-15 (lead-24) | f5e0726..HEAD | 5 merged, 10 filed (720-728; 729 a duplicate) | rounds 2 for 2 (a wrong lead rule, a pairing-screen lock); 1 spec gap closed; 9 filed | 1977 QML + 166 skips | 0.0.87 queue 28/28; Dell on 0.0.87 |
