# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`); `docs/STATUS*.md` and `docs/tasks/T-*.md` are a frozen archive. **Goals are formations** (`formation` lists them; `PLANNING.md` step 4). This file is the lead's session record.

## State after lead-18 (Opus, 2026-11-13/14; ran overnight)

- **Review range:** 2c83b80..e962e98. Paper Plane `changes` cursor: **2217**.
- **Merged and Done (27 tickets), each reviewed and gated green:**
  - Owner reports: RUY-545 (per-pad controls), RUY-87 (switch freezes), RUY-561 + RUY-562 (screen saver: inhibitors only in front; audio lets the saver start), RUY-513/514/575 (row kinds; `kind` required), **RUY-583 (Start opens Options: Start emits `KEY_COMPOSE`, because `KEY_MENU` reaches Qt as `Key_MenuKB`)**.
  - Controllers: RUY-540, 551, 571, 572, 446 (pad nodes 0600, no uaccess), 11 (Guide never reaches a game).
  - Idle: RUY-588 (pad input to a game counts as activity: `Input1.UserActive`), 563 (saver log lines).
  - Freeze: RUY-546, 573, 577, 584 (reclaim ledger with tokens), 568 (an app that starts after its profile left is frozen).
  - CI and checks: RUY-544, 576 (CI compiles the compositor), 473, 441, 550 (Rust revert-check), 451.
- **Owner decisions:**
  - ADR-017 amendment 6 (the active controller).
  - ADR-035 amendment (game settings from the game page).
  - All agents have full rights on the Dell.
  - Formations are used for goals.
  - Ruya Music is parked after v1 (RUY-565).
  - Music allows the screen saver.
  - **GitHub issues may always be filed** (2026-11-14; Paper Plane: [EnigmaNL/PaperPlane#11](https://github.com/EnigmaNL/PaperPlane/issues/11), formation deletion).
- **Lead decisions to confirm with the owner:**
  - Audio holds screen-off and sleep (TVs on HDMI go to standby and cut the sound).
  - An import lands in the page's own slot (RUY-572).
- **Images:**
  - **0.0.79 at fd8548e: built; VM 25/25 PASS**, the new checks included (input `start`, `useractive`; power-saving `padactive`, `audio`; reclaim lines). One timing flake passed on a re-run (RUY-597).
  - 0.0.79 doesn't contain RUY-568 or RUY-572 (merged after it).
  - **The Dell still runs 0.0.76.** Next: `bash scripts/dell-update.sh 0.0.79` when the owner has it on (the oci archive is in `output/`; check it survived free-space).

## Next, in this order
1. **Dell with the owner on 0.0.79:**
   - a Controls in games change on one pad only;
   - a Hub switch freezes the game;
   - LibreQuake with two pads;
   - the saver behind Home and with music playing (the Power saving note "Sound doesn't stop the screen saver.": its shot is unverified);
   - **Start on the DualSense and `+` on the Wii U Pro** (RUY-574 is still open for this);
   - a game played with a pad and no inhibitor gets no saver.
   - Owner question: should "All controllers" empty the family slot too (RUY-572 point 3)?
2. **Next image (0.0.80)** for RUY-568's start-race step and RUY-572.
3. **Ready builder work by goal:**
   - controllers (RUY-552): 586, 595, 596, 594 (Input1 receive policy, image change), 503/500/504;
   - freeze (RUY-554): 569, 570, 585, 593;
   - CI (RUY-555): 549, 548, 591, 592 (lost-tests.sh hangs in Git Bash), 597;
   - row kinds (RUY-557): 589 (cap long values), 590 (a shared SettingNote: the owner's "do we declare them every time?");
   - menus (RUY-559): 587.
   - Most of these are `inbox`: plan them first (acceptance criteria and a lead review).
4. **Lead work:**
   - the RUY-120 spec (local players; RUY-551's notes are on it);
   - RUY-490;
   - RUY-483 (shell wedge);
   - triage of about 45 `inbox` tickets.

## Concerns (ranked)
1. Real hardware still lags the VM: the Dell is on 0.0.76. Everything owner-facing since then is VM-verified only.
2. Builders' scripted edits. One `replace` rewrote 100 lines of dev-setup.md (fixed in 28f3b2a; the brief now asks for `git diff --stat`). Reviewers compare word-diffs.
3. `shots` needs an unlocked desktop. Several overnight shots are unverified (RUY-562's note).
4. Three builders ran at once twice tonight (small tickets). Keep to two.

## Process changes in lead-18
- Formations for goals, with a REST fallback (`POST /api/tools/formation`).
- `scripts/ci-shell-linux.sh`; `revert-check.ps1` Rust mode; the mandatory HANDOFF `revert:` line.
- The builder brief: read `git diff --stat main` before each commit, and never global-replace prose.
- A lead review of every ticket before dispatch (kept). The lead re-reviews round 2s itself when the diff is small.
- Don't run `lost-tests.sh` in builders until RUY-592 is fixed. Compare test names with `git grep`.

## Host facts learned
- The VM queue copies scripts from main: merge script changes only after the queue ends.
- A queue run clears `output\vm-queue`: copy the logs first. `summary.txt` holds only 15 lines.
- The merge gate refuses a dirty main tree, so commit the notes before gating.
- `wsl ... pgrep -fa "podman build"` before any WSL-heavy step.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-13 (lead-17) | 984460e..2c83b80 | 493, 474, 479, 16, 499, 491, 512; designs | round 2 for 16, 491, 499; owner bugs 538-540 | 1588 QML + 137 skips | 0.0.75 12/14 + input PASS |
| 2026-11-14 (lead-18) | 2c83b80..e962e98 | 27 merged (above) | round 2 for 544, 540, 545, 561, 571, 562, 588, 568; RUY-588 found in review (a saver over games); a bad replace caught; about 20 inbox tickets filed | 1625 QML + 137 skips | 0.0.79 25/25 (1 re-run) |

## In flight
- None. No builder is running, and every worktree is removed.
