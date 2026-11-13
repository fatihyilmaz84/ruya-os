# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`); `docs/STATUS*.md` and `docs/tasks/T-*.md` are a frozen archive. This file is the lead's session record.

## State at the end of lead-16 (Opus, 2026-11-13)

- **Review range:** 72b5cb5..HEAD (this commit). Paper Plane `changes` cursor: **1463**.
- **Merged and Done (each reviewed, its merge gate green):**
  - RUY-42 (split by the lead): the mapping engine, profiles and Input1 profile methods.
  - RUY-465: the Controls in games pages.
  - RUY-413: the notification centre (round 2: the restart confirm, and app actions no longer run as console actions).
  - RUY-444: the Bluetooth keyboard Connect gate (round 2: the VM check fixed, overlapping Pairs).
  - RUY-472: X11 mode waits for the satellite's READY; the X lock it waited for never exists.
  - RUY-40: the confirm button per family, plus ActiveInputChanged.
  - RUY-486: the Button test layouts and the Wii U Pro (owner report).
- **Images:**
  - 0.0.73: queue 10/14; x11 FAIL led to RUY-472.
  - **0.0.74 (main bdde129): x11 118 PASS, confirm 23 PASS, the rest as on RUY-390.** FAIL: RUY-493 (live remap) and RUY-441 (known).
  - **The Dell runs 0.0.74** (rollback 0.0.73). RUY-486 is not in it.
- **Pushed:** 40c8322; this handoff commit is pushed with push-main. CI was green for 9252ba9.
- **Nothing in flight; no worktrees.** Branch `claude/design-pad-silhouettes-559410` (12dff12): 28 controller SVGs from the design session ([pad-silhouettes]), not merged. RUY-491 integrates them.

## Owner decisions this session
1. **Review every ticket before dispatching it** (LEAD.md 4b.1): a "Lead review before the build" comment. RUY-40 is the example.
2. Controller profiles, all six recommendations accepted (06 §7, RUY-43's comments):
   - USB-only sharing;
   - no shipped per-game defaults;
   - macros and turbo deferred and off for imports;
   - the guest rule;
   - several device profiles by `match`;
   - a hidden platform level.

   **RUY-490 (lead)** writes the spec and contract and blocks RUY-43.

## Next, in this order
1. **Dell, with the owner:** Alien Arena and AAAAXY (X11), a Nintendo pad confirms with A, the Controllers page. Then build the next image (RUY-486), and check the owner's Wii U Pro and DualSense in the Button test.
2. **RUY-493 (high):** after a live profile swap the next press is lost. A product bug or the probe's timing.
3. RUY-41 (glyphs follow the controller; reads RUY-40's `activeFamily` and seam `routing.rs mapper_events`), RUY-479 (left-stick navigation in the stick editor), RUY-474 (GPU shots red on main), RUY-473 (VM check hygiene), RUY-441.
4. Lead work:
   - RUY-490 (profiles spec);
   - RUY-483 (shell CPU wedge plus a watchdog; it did not reproduce on 0.0.74);
   - RUY-448 and RUY-449 (from lead-15);
   - RUY-487 (two family tables).
5. File the xwayland-satellite upstream PR (owner approved; RUY-434's Outcome has the text). It has now passed the VM.
6. The owner should answer RUY-387 (pad art licence) before RUY-491 ships the silhouettes.

## Concerns (ranked)
1. The shell wedge (RUY-483): seen once, with no sound card. There is no watchdog yet.
2. Lanes: two complex Opus builders took about 450-550k tokens per round. A split along contract and UI (RUY-42 → RUY-465) halved the risk; split earlier.
3. Agents touching main by relative paths (lead-15). None seen this session.

## Process changes in lead-16
- Owner rule: review before dispatch (LEAD.md, memory).
- `free-space.ps1` keeps only the two newest Dell OCI archives. Fourteen had filled F:, and make-disk refused to run.
- `shell/CLAUDE.md` pruned from 13.2 to 8.8 KB: how-tos moved to `shell/PATTERNS.md`.
- VM queue: when main's scripts are ahead of the image, run them from a detached worktree at the image's commit with an `output` junction. **Delete the junction with `(Get-Item ...).Delete()` before removing the worktree** (`cmd /c rmdir` did not remove it).
- Paper Plane: no new problems found.

## Host facts learned
- Never put backslashes in a Bash heredoc, `sed` or `python -c`: use Write/Edit. PowerShell 5.1 strips quotes and expands `$(...)` inside ssh arguments: put probes in a script file and scp it.
- The Dell's `bootloader-update.service` fails on every boot (RUY-24, harmless).
- Paper Plane REST: `POST /api/tools/<tool>`. A batch `update` is atomic: one refusal (e.g. missing criteria) stops all of it.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-12/13 (lead-15) | 7a46c55..72b5cb5 | RUY-1 (lead); 409, 410, 425, 421, 415, 422, 424, 430, 22, 435, 434, 436, 459, 406, 39 | round 2 for 409, 410; virtual-pad toast bug | 1310 QML + 107 skips | 0.0.71 queue 11/14 |
| 2026-11-13 (lead-16) | 72b5cb5..HEAD | 42 (split), 465, 413, 444, 472, 40, 486 | round 2 for 413 (restart confirm, app actions) and 444 (VM check, overlapping Pairs); x11 never worked (RUY-472); shell wedge (RUY-483); live remap (RUY-493) | 1465 QML + 126 skips | 0.0.73 10/14; 0.0.74 x11 118 PASS, 2 FAIL filed |
