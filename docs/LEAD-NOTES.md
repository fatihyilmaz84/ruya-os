# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-32 (Opus, 2026-11-17/18)

- **Review range:** 11ae518f..HEAD. **Paper Plane `changes` cursor:** 4808.
- **Merged (2 tickets), both with a green merge gate:**
  - RUY-822: CI job `samples` and `scripts/ci-samples-linux.sh` compile both `.play` samples, then build and inspect their zips with the real `ruya-pack`. The samples compiled clean the first time. Lead fix: the script removes the git-ignored outputs on exit, because leftovers fail `ruya-pack`'s tests/samples.rs.
  - RUY-504: Rename and Forget on the controller page for a Bluetooth pad. The shared `BluetoothDeviceActions.qml` is used by the Bluetooth pane too, and RUY-17 must reuse it. Round 2 added the screenshots.
- **Housekeeping:** removed 5 stale, fully merged `.claude/worktrees`.
  - **Kept:** `claude/design-pad-silhouettes-559410`, which has 11 unmerged commits: 28 source SVGs in `shell/art/pads/` and a method doc. RUY-491 already wired silhouettes into the icon font. Decide whether the sources belong in `main`.
- **No lanes or worktrees open.**

## Owner direction (in force)
- **Steam is first-class, no hacks** (RUY-815, owner's words there):
  - Steam games are Library items on the regular game page;
  - Steam itself is an app;
  - freezing must not break Steam (RUY-817).
- **One game page for `.play` (lead proposal, the owner said to leave it for the next lead).** A `.play` game uses the shared game page once installed, but `InstallPackagePage.qml` copies its layout. Spec 05 §16 wants source/trust, signer, runner and update state on the installed game's page, and no ticket does that.
  - Proposal: the shared game page gets these rows for `.play` items, and the install page reuses the game page's parts.
  - Plan it as one design-first ticket after RUY-104, in formation RUY-780.
- **Architect audit after the weekly reset** (2026-11-20 18:00). Focus questions:
  - RUY-812 / **RUY-825** (below): which X window of the Steam app is the game;
  - RUY-817;
  - RUY-820;
  - RUY-815's instance model.
- `.play` only, foundations first (RUY-780). Weekly plan at 86 %: cheap work only until the reset.

## First thing next session
1. **RUY-825 (high, new, lead):** Steam drops a game's controller config, and the pad goes dead in Bastion.
   - Cause: at every screen-saver wake, Steam switches to its Desktop config (413080). Home and back hands focus to `app:steam`, whose Big Picture window is on top, never to Bastion's window.
   - inputd forwards correctly. Evidence and Steam log lines are on the ticket. Likely the same root as RUY-812 and RUY-786.
   - Decide the fix with the architect: re-focus the game's X window, or keep X focus on it under the saver.
2. **After the reset:** the architect audit, then **RUY-100** (lead, VM: the `ruya-play` service).
   - Fold in: RUY-805, the developer-mode calls, `Play1.Remove`, and installing `hello-play-native` (built by `ci-samples-linux.sh`) in `vm-play-check.sh`.
   - It unblocks RUY-102 and RUY-104 (builders), and RUY-101, 103 and 106.
3. **The Dell** runs 0.0.90, without RUY-814. Bastion was ended by the lead; Steam is still running. The next image brings RUY-814, after which RUY-825 must be re-checked on it. Temp files are in `/tmp` (`rd*.py`, `g.py`, `x*.sh`). The idle shell measured 0 % CPU, 0 ms GPU in 10 s and 354 MB RSS.
4. **Owner-pending:**
   - RUY-786: the sleep test;
   - RUY-776: a free Proton game;
   - the Nintendo-layout default (RUY-820).
5. **Parked inbox:** RUY-799, 800, 803, 804, 806-808, 810, 811, 816, 824, 825.
6. **Stale Ready tickets to re-plan or close:**
   - RUY-26 (lead-21 note);
   - RUY-13 (plan lint of the frozen `.md` headers: likely obsolete).

## Concerns (ranked)
1. **Steam focus (RUY-825, RUY-812):** a pad dead after a saver wake, or after Home and back, makes Steam games unplayable without a restart.
2. **Weekly plan at 86 %** (resets 2026-11-20 18:00).
3. **The `.play` Linux paths** have run only in WSL and the mock until RUY-100.
4. **Flaky tests under load:** RUY-794, RUY-784.

## Process changes in lead-32
- **Builders:** RUY-504's builder reported `done` without the shots the ticket required ("no existing shot shows it"). `ruya-builder.md` now says to add a shots function for a new state; a HANDOFF without the ticket's shots is `partial`.
- **Lead:** a Dell diagnostic agent misread a Steam Big Picture screen as the shell's own. **Grep the shell for a screen's text before believing an agent's "this is our UI".**
- **Reviews:** RUY-504 was reviewed by a Sonnet reviewer in parallel with the builder's shots round, with no design reviewer (rows and a confirm in existing patterns). The lead read the shots.
- **Tests:** none changed. One full gate took 242 s; RUY-504's gate reused the builder's green run.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-17 (lead-30) | e4df6f6..09defa5 | 2 lead (801, 97) + 3 merged (802, 98, 809); 17 filed (800, 803-816) | 802: one round 2 (solid badges, TR label, held keys); 98 and 809 clean; 801 review fix; a flaky 98 test fixed | 2198 passed, 0 failed (RUY-809 gate) | Dell: Steam by hand, BioShock under Proton (hw); no image |
| 2026-11-17 (lead-31) | 09defa5..11ae518 | 6 merged (814, 105, 818, 819, 823, 821); 9 filed (817, 820, 821-824 and 818, 819 from reviews) | 105: one round 2 (fractional integer in the lint); 1 lead review fix; the rest clean | 2207 passed, 0 failed (RUY-823 gate); Linux CI job 2207 passed; GitHub CI green | none (Dell checks queued) |
| 2026-11-18 (lead-32) | 11ae518..HEAD | 2 merged (822, 504); 1 filed (825, Dell diagnosis) | 822: 1 lead fix (clean-up on exit); 504: round 2 for missing shots | 2207 passed, 0 failed (RUY-822 gate); RUY-504 builder's green run reused | Dell: RUY-825 diagnosis (hw); no image |
