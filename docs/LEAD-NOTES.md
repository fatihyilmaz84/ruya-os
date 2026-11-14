# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; up to four lanes since 2026-11-14**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`); `docs/STATUS*.md` and `docs/tasks/T-*.md` are a frozen archive. **Goals are formations** (`formation` lists them; `PLANNING.md` step 4). This file is the lead's session record.

## State after lead-19 (Opus, 2026-11-14)

- **Review range:** e962e98..HEAD. Paper Plane `changes` cursor: about **2600** (read `changes` from 2218 if unsure).
- **Merged and Done (16):** RUY-603, 593 (+585), 595 (+586), 570, 590, 592, 597 (+587), 541, 569, 596, 591 (+600), 547, 582 (+439), 549 round 1, 605, plus RUY-589 and RUY-542, which are merged but **not Done: their shots are unread** (the Windows session was locked).
- **Owner report fixed:** LibreQuake lost the pad after a Hub open (RUY-541: pads kept through a Hub Freeze; pad1 made ready before the others). Diagnosed on the Dell by an agent; the DualSense not reaching a one-pad game after a Wii U Pro sign-in is by design (ADR-017 am. 6, owner confirmed).
- **Owner decisions (2026-11-14):**
  - up to four builder lanes (LEAD.md 4b);
  - keep player 1 = the pad that signed in; "All controllers" keeps family slots; audio keeps the TV on; an import lands in the page's own slot;
  - the Confirm button per controller per profile (RUY-603);
  - **stay on Fedora's kernel** (01, Kernel row).
- **Images:** 0.0.80 built at 588f81e (CHAIN OK; build 57 min, disk 27, oci 11) and installed on the Dell; it lacks RUY-603.

## In flight at handoff (check first)
1. **LibreQuake still gets no pad input from launch on 0.0.80** (Wii U Pro only, no Hub; owner report 2026-11-14 ~16:30, the part the first diagnosis couldn't explain). A diagnostic agent was capturing the live state when lead-19 handed off: read its result on the latest owner-report ticket, or re-run the diagnosis (route, virtual pad + ACL + the game's fd, FreezerState, physical presses) and file the fix as high priority. RUY-603 (Confirm per controller) is merged and Done (needs 0.0.81 and `vm-input-check.sh confirm`); RUY-500 has the re-plan comment.
2. **RUY-549 round 2** (`t/RUY-549b-fresh-cache`, worktree RUY-549b): the warm cache's stale-QML fix (hash manifest). Code done, test green; **proof runs B/C/D pending** (in the builder's HANDOFF on the ticket: unchanged tree, a changed file with an old mtime must turn tst_settings red, then green). Run them when WSL is idle, then merge. Until then push-main's Linux step may test stale QML on a warm run: run `ci-shell-linux.sh --cold` if a Linux result looks wrong.
3. **0.0.80 is on the Dell** (rollback 0.0.79; `bootloader-update` red as before); **its VM queue has not run**: `vm-queue.ps1` (the RUY-390 comments list the new checks: session freeze-then-thaw, input shell/twopads/check/start/confirm, journal lines) -> `dell-update.sh 0.0.80` -> owner on the Dell: LibreQuake with both pads, Hub twice, Guide -> "Use this controller" on the DualSense.
4. **Shots read (lead-19):** RUY-589's large-UI shot shows the value over the label -> **RUY-609** (high, Ready); RUY-542's row-kinds shot fails on the GPU -> **RUY-610** (Ready). 589 and 542 go to Done with those.
5. Worktree folders `RUY-547`, `RUY-590` could not be deleted (locked files): remove them.

## Next (Ready, ordered)
- **RUY-594** (Input1 signals only to the shell; VM this task) -> **RUY-525 + 527** paired (ntsync, gaming sysctls; one image build) -> the rest of the gaming tuning (528-531, each with a Dell number).
- Lead work: **RUY-483** (shell watchdog, owner asked), RUY-490, RUY-120; the game page needs RUY-523 and a design board first (RUY-524 comment).
- Inbox: about 45 tickets; new today: 598, 601, 602, 604, 606, 607, 608.

## Concerns (ranked)
1. Real hardware: nothing since 0.0.79 is on the Dell; RUY-541's fix is unchecked there.
2. A locked desktop blocks every `shots` run: UI tickets pile up merged-but-not-Done.
3. Builders ran WSL work during the lead's image build (RUY-549): WSL contention slowed the chain past an hour. Tell builders the WSL order explicitly.

## Process changes in lead-19
- Four lanes (owner). Small diffs (scripts, < 100 lines) reviewed by the lead itself, larger ones by reviewers.
- `lost-tests.ps1` replaces the hanging `.sh` (RUY-592); `lint-ci-lines.ps1` and a wider `lint-setting-notes.ps1` in CI (RUY-591); push-main runs CI's Fedora shell job once per push (RUY-549; its first use caught its own stale-cache bug).
- Paper Plane: [EnigmaNL/PaperPlane#12](https://github.com/EnigmaNL/PaperPlane/issues/12) (batch entries can't carry `override`).

## Host facts learned
- The VM queue copies scripts from main: merge script changes only after the queue ends.
- The image chain builds from the main checkout: no merge into main while it runs.
- The merge gate refuses a dirty main tree, so commit the notes before gating.
- `wsl ... pgrep -fa "podman build|make-disk|ci-shell"` before any WSL-heavy step.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-14 (lead-18) | 2c83b80..e962e98 | 27 merged | round 2 for 8; about 20 inbox | 1625 QML + 137 skips | 0.0.79 25/25 |
| 2026-11-14 (lead-19) | e962e98..HEAD | 17 merged (+6 absorbed) | round 2+ for 595, 589 (x2), 541, 542, 549; About licence cut found in review; stale CI cache found by its first use; 11 inbox filed | 1641 QML + 138 skips; Fedora cold 1641/0 | 0.0.80 built, on the Dell; queue not run |
