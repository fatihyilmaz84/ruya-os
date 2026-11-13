# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`); `docs/STATUS*.md` and `docs/tasks/T-*.md` are a frozen archive. This file is the lead's session record.

## State at the end of lead-17 (Opus, 2026-11-13)

- **Review range:** 984460e..HEAD (this commit). Paper Plane `changes` cursor: **1685**.
- **Merged and Done** (each reviewed; merge gate green; UI ones with design and, for new flows, UX reviews):
  - RUY-493: live remap (one router call per evdev frame). **Verified: vm on 0.0.75.**
  - RUY-474: the shots harness kicks a stalled GPU window (the cause is not proven: RUY-510).
  - RUY-479: StartTest's `hold_left_stick` (VM pending).
  - RUY-16 and RUY-499 (split by the lead): the Options menu, the Hold ring, Accept on release, Uninstall… with the shared confirm and the admin PIN.
  - RUY-491: 28 controller silhouettes, with one model table in the new crate `ruya-pads` (VM and Dell pending).
  - RUY-512: one look per setting row kind (RUY-505 closed with it).
- **Design sessions** (Claude Design canvases on Dreamglass; specs merged as planned, tickets filed):
  - RUY-4, the Options menu: done.
  - Controller menus: RUY-500..509.
  - Control kinds: RUY-512..517.
  - The game page, which merges Store and Details: RUY-523/524/532-534; no ratings, RUY-535.
  - A gaming tuning audit (Opus): RUY-522, with RUY-525..531.
- **Images:** 0.0.75 at aa1ad56 (RUY-486, RUY-493): 12/14 in the queue plus `vm-input-check check` PASS. The 2 FAILs are diagnosed and not regressions (RUY-473, RUY-521). **The Dell runs 0.0.75** (rollback 0.0.74).
- **Nothing in flight; no builder worktrees.** The design sessions' worktrees (`.claude/worktrees/*`) are merged; archive them with the owner. `inspiring-chebyshev-c1c08c` (4402db0) is unknown; the owner was asked.
- **Pushed:** ce7e315 mid-session; this handoff is pushed with push-main. CI was not checked.

## Owner decisions this session
1. The silhouettes may ship (RUY-387, part answered).
2. Nintendo pads stay positional in games, with a one-time question after pairing (RUY-503).
3. No ratings on the game page for now (RUY-535; revisit with RUY-386).
4. `split_lock_mitigate=0` as SteamOS does it (RUY-527).
5. "One active controller per profile" (RUY-540 comment). Check it against ADR-017 and local co-op before building.

## Next, in this order
1. **The owner's two reports (analyse first, owner's request):**
   - **RUY-538:** with two pads, a Controls in games change applies to both.
   - **RUY-539:** a Hub profile switch doesn't freeze the running game (see RUY-87).
2. **RUY-540 (high):** virtual pad numbering. pad1 is the BTreeMap-first pad, so LibreQuake listened to the idle Wii U Pro (live diagnosis on the Dell). Then RUY-541 (pads destroyed at every overlay).
3. **Build the next image** (main has RUY-479, 16, 499, 491, 512). VM queue: RUY-479 `vm-input-check.sh hold`, RUY-491 `vm-devices-check.sh gamepads`. **Dell with the owner:**
   - silhouettes for the DualSense and the Wii U Pro (Bluetooth pane, Controllers, toasts, Input1 `model`);
   - the Options menu, Uninstall;
   - the Button test layouts, the confirm button on a Nintendo pad.
4. Ready builder work:
   - RUY-513 and RUY-514 (row-kind migrations; parallel, now unblocked);
   - RUY-523 → RUY-524 (game page);
   - RUY-41 → RUY-500;
   - RUY-17 (with RUY-520);
   - RUY-525..531 (tuning, VM this task);
   - RUY-494 (X11 shm crash).
5. Lead work: RUY-490 (profiles spec), RUY-483 (shell wedge), RUY-519/543/516 (design follow-ups), and triage of about 30 `inbox` tickets.

## Concerns (ranked)
1. Input on real hardware: three owner-visible input bugs this session (RUY-538, 539, 540). The VM checks don't cover two pads of different families.
2. `shots` is flaky on the shared desktop: two builders lose activation (RUY-511). Run at most one shots user at a time when possible.
3. The shell wedge (RUY-483) has no watchdog yet.

## Process changes in lead-17
- Split big UI tickets before dispatch (RUY-16 → RUY-499): each builder round stayed under about 430k.
- VM queue for an image older than main: run from a detached worktree at the image's commit with an `output` junction (delete the junction first). The default queue omits `vm-input-check.sh`: run it explicitly.
- Design sessions create their own follow-up tickets. Notes left in "shared notes" files are unreadable for the lead.
- `.ts` merge recipe (LEAD.md 4b.1) gains `lconvert -no-obsolete`: the RUY-512 gate went red on four obsolete entries kept by lconvert.
- Paper Plane: same-state move drops the new commit (EnigmaNL/PaperPlane#9, commented).

## Host facts learned
- Never put backslashes in a Bash heredoc, `sed` or `python -c`: use Write/Edit. PowerShell 5.1 strips quotes inside ssh arguments: scp a script.
- The Dell's `bootloader-update.service` fails on every boot (RUY-24, harmless).
- Paper Plane REST: `POST /api/tools/<tool>`; a batch `update` is atomic.
- `start_session`'s `model` was ignored for Fable (it started on Opus).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-13 (lead-16) | 72b5cb5..984460e | 42 (split), 465, 413, 444, 472, 40, 486 | round 2 for 413, 444; x11 never worked (RUY-472); RUY-483; RUY-493 | 1465 QML + 126 skips | 0.0.74 x11 118 PASS |
| 2026-11-13 (lead-17) | 984460e..HEAD | 493, 474, 479, 16, 499, 491, 512; designs 4, 500-509, 512-517, 523-535 | round 2 for 16 (tests), 491 (Wii U Pro evdev name), 499 (hint band, PIN clear); owner bugs 538-540 | 1588 QML + 137 skips (RUY-512 gate) | 0.0.75 12/14 + input check PASS |
