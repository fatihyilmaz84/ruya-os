# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-31 (Opus, 2026-11-17)

- **Review range:** 09defa56..HEAD. **Paper Plane `changes` cursor:** 4775.
- **Merged (6 tickets), all with a green merge gate; pushed, GitHub CI green (ci, supply-chain):**
  - RUY-814: a game keeps its pad when focus moves between its windows (shell only: no `shell` route while a window's instance is looked up, plus a 3 s `windowGapMs` hold).
  - RUY-105: the `.play` developer guide (`docs/developers/play-packages.md`) and samples `hello-play-native` and `hello-play-wine` (not compiled: RUY-822). Two rounds: the lint accepted fractional integers.
  - RUY-818 and RUY-819 (follow-ups to RUY-814), RUY-823 (`art.no_screenshots`) and RUY-821 (the guide's field table): small pairs.
- **Lead commits:** root `CLAUDE.md` 11.3 → 10.6 KB and `shell/CLAUDE.md` 8.0 → 7.7 KB; `scripts/lead-clock.ps1` plus the autonomy rule; a review fix on RUY-105.
- **No worktrees or lanes are open.** The stale `.claude/worktrees/*` (6, not lead sessions') are still there: look before removing.

## Owner direction (lead-31, in force)
- **Steam must be first-class and not hacky** (RUY-815, owner's words quoted there):
  - Steam games are Library items on the **regular game detail page**, with as much data from Steam's local files as possible and little custom work;
  - Steam itself is an app;
  - the Dell hand fixes (usroverlay, `-gamepadui` wrapper) are scaffolding only.
- **Freezing must not break the Steam client** (RUY-817). Fallback, by the owner: a mechanism for apps to ask not to be frozen (public, so an ADR first).
- **Steam's own UI** has A/B swapped on a Nintendo pad, shows the wrong PlayStation glyphs, and stays on the first pad seen (RUY-820). Likely cause: Steam only sees our virtual pad's fixed identity. RUY-449 (the virtual pad matches the controller) is the lead's recommended fix.
- **Architect audit after the weekly reset** (2026-11-20 18:00, owner): focus questions are RUY-812 (satellite or gamescope), RUY-817, RUY-820 and the instance model of RUY-815.
- `.play` only, foundations first (formation RUY-780). Two lanes are allowed (owner, lead-31); the weekly plan is at 85 %.

## First thing next session
1. **Before the reset:** cheap work only. The `.play` formation's open builder tickets (RUY-102, RUY-104) wait on **RUY-100** (lead, VM: the `ruya-play` service). That is the next real step, but it needs image builds.
   - Fold into RUY-100: RUY-805, the developer-mode calls RUY-98 drafted, `Play1.Remove` (RUY-816 item 3), and installing `hello-play-native` in `vm-play-check.sh` (RUY-822 compiles it).
2. **After the reset:** the architect audit above, then plan RUY-815 into tickets (design first for any new Hub or game-page state).
3. **The Dell:**
   - RUY-814's real check (Steam installer to game; `journalctl -u ruya-inputd` must show no `virtual pad ... destroyed`). It is on RUY-390.
   - RUY-813 diagnosis (comment on the ticket: on `main` Freeze already names every scope of the app, so find where Steam's game really lives).
   - RUY-786 may share RUY-814's cause.
   - The Dell needs the usroverlay by hand after each reboot (RUY-801 recipe).
4. **Owner-pending:**
   - RUY-786: the sleep test;
   - RUY-776: a free Proton game;
   - the Nintendo-layout default, now part of RUY-820.
5. **Parked inbox:** RUY-799, 800, 803, 804, 806-808, 810, 811, 816, 824.

## Concerns (ranked)
1. **Weekly plan at 85 %** (resets 2026-11-20 18:00).
2. **RUY-786:** pad not moving LibreQuake after sleep. Not reproduced; RUY-814's fix may cover it.
3. **The `.play` Linux paths** have run only in WSL `cargo test` and the mock; RUY-100's `vm-play-check.sh` is the first real run.
4. **Flaky tests under load:** RUY-794, RUY-784.

## Process changes in lead-31
- **Lead (owner):** after 60 min with no owner message the lead asks nothing and runs to the handoff (`lead-clock.ps1`, LEAD.md). The prompt cache lives one hour, and a cold turn costs about 40x a warm one (Opus 5.5: 2x write against 0.05x read).
- **Builders:** small follow-ups went out as **pairs** in one session (818+819: 52k tokens; 823+821: 100k). A 50-line follow-up diff was reviewed by the lead itself.
- **Builders:** RUY-105's builder sent an empty handback ("placeholder") mid-run, and its later report was refused (one per result). The lead found the work from the worktree and the ticket's handoff instead. **If a HANDOFF looks empty, read the ticket's handoff and the branch before waiting.**
- **Reviews:** on RUY-823 one Sonnet reviewer also did the API check (weekly plan at 85 %), with no separate API reviewer. That was enough for a schema-plus-docs diff.
- **Tests:** none changed. The full gate took 231-281 s each time.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-17 (lead-29) | 9392257..e4df6f6 | 7 merged (501, 92, 94, 96, 93, 95, 99); 16 filed (784-799) | 2-3 review rounds on each .play crate; 5 lead fixes; bubblewrap#835 | 2106 passed, 0 failed (RUY-99 gate) | 0.0.90: 17/18 + kill PASS; Dell on 0.0.90 |
| 2026-11-17 (lead-30) | e4df6f6..09defa5 | 2 lead (801, 97) + 3 merged (802, 98, 809); 17 filed (800, 803-816) | 802: one round 2 (solid badges, TR label, held keys); 98 and 809 clean; 801 review fix; a flaky 98 test fixed | 2198 passed, 0 failed (RUY-809 gate) | Dell: Steam by hand, BioShock under Proton (hw); no image |
| 2026-11-17 (lead-31) | 09defa5..HEAD | 6 merged (814, 105, 818, 819, 823, 821); 9 filed (817, 820, 821-824 and 818, 819 from reviews) | 105: one round 2 (fractional integer in the lint); 1 lead review fix; the rest clean | 2207 passed, 0 failed (RUY-823 gate); Linux CI job 2207 passed; GitHub CI green | none (Dell checks queued) |
