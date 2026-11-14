# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`); `docs/STATUS*.md` and `docs/tasks/T-*.md` are a frozen archive. **Goals are formations** (`formation` lists them; `PLANNING.md` step 4). This file is the lead's session record.

## State of lead-18 (Opus, 2026-11-13/14; the owner let it run overnight)

- **Review range:** 2c83b80..HEAD. Paper Plane `changes` cursor: 1897.
- **Merged and Done** (each reviewed; gate green):
  - RUY-544: CI is green again (Fedora qmllint role clash, the 1 px title box), plus `scripts/ci-shell-linux.sh`.
  - RUY-540: pad1 is the pad that signed the profile in.
  - RUY-546: `\x2d` scope names.
  - RUY-545: one controller profile per slot (device > family > all); Controls in games edits its own pad (the owner's report RUY-538).
  - RUY-87: a profile switch freezes the previous profile's apps (the owner's report RUY-539).
  - RUY-573: reclaim takes escaped names; `twopads` runs with the shell stopped.
  - RUY-550 (lead): `revert-check.ps1` has a Rust mode.
  - Overnight: RUY-561 (an idle inhibitor counts only while its app is in front: the owner's screen saver report), RUY-513 + RUY-514 + RUY-575 (every setting row states its kind; `kind` is required, `inert` gone: the owner's report), RUY-473 (inputd check without the live shell; Verified: vm), RUY-441 (lead), RUY-451 (sheet blur in a Loader; hero decodes at drawn size).
  - Lead review commits: 7ea2600 (a late kill keeps a SIGTERM stop a quit; the inhibit check's waits), 36279a7 (tst_timezone flake), 02-shell fixes.
- **Owner decisions recorded:**
  - ADR-017 amendment 6, the active controller.
  - ADR-035 amendment: game settings from the game page (cache plus queue).
  - Every agent has full rights on the Dell (CLAUDE.md).
  - Formations are used for goals.
  - Ruya Music is parked after v1, with six answers on RUY-565.
  - RUY-562: music allows the screen saver.
- **Images:**
  - 0.0.76 at 9398dda: **on the Dell** (rollback 0.0.75); the owner switched the Dell off for the night.
  - 0.0.77 at 0403ed5: built, not on the Dell. VM: input check/hold/twopads incl. twoprofiles PASS (RUY-540, 545 Verified: vm), the reclaim lines PASS (RUY-573), x11 PASS. Its 2 FAILs are fixed on main in 7ea2600 (an exit-reason race; the inhibit check's wrong `-u`); `inputd` is fixed by RUY-473.
  - **Next image (0.0.78) from main** has everything for the owner's Dell re-check: per-pad controls, freeze on switch, the screen saver, row kinds.
- **In flight:** see the bottom section (kept current while the session runs).

## Next, in this order
1. **Build 0.0.77** from main (once RUY-561 is merged) and run the VM queue. Defaults, plus:
   - `vm-input-check.sh check|hold|twopads` (the twopads run now includes RUY-545's `twoprofiles`);
   - `vm-devices-check.sh gamepads`;
   - `vm-power-saving-check.sh inhibit` (RUY-561).
   `vm-session-check.sh check` must now pass the reclaim lines (RUY-573) and the Lock-freezes steps (RUY-87).
2. **Dell with the owner:**
   - two pads, a Controls in games change on one pad only;
   - a Hub profile switch freezes the game;
   - LibreQuake with two pads;
   - a game behind Home no longer blocks the screen saver;
   - RUY-574: Start doesn't open the Options menu (analyse first).
3. **Owner reports to analyse:** RUY-574 (Start on the DualSense), RUY-575 (row kinds unfinished; dispatch RUY-513 and 514 first, then make `kind` required).
4. **Ready builder work by goal:**
   - RUY-557 row kinds: 513, 514, then 575;
   - RUY-564 idle: 562, 563;
   - RUY-552 controllers: 551, 571, 572, 541;
   - RUY-554 freeze: 568-570, 577;
   - RUY-555 CI: 549, 548, 576 (compile the compositor in CI);
   - RUY-566 game settings: 407.
5. **Lead work:**
   - the RUY-120 spec (local players, amendments 1-6, Claude Design first);
   - RUY-490 (profiles spec, partly covered by RUY-545);
   - RUY-483 (shell wedge);
   - triage of about 40 `inbox` tickets into their formations.

## Concerns (ranked)
1. Input on real hardware with two pads of different families: fixed on main, but only VM-verified, not on the Dell.
2. Compositor C++ is first compiled in the image build (RUY-576). The RUY-561 reviewer compiled it by hand in fedora:44 podman.
3. `shots` needs an unlocked desktop. Overnight builders mark shots unverified when LogonUI runs, so review the RUY-513/514 screenshots in the morning.

## Process changes in lead-18
- Formations for goals: PLANNING.md step 4 (REST fallback `POST /api/tools/formation` while the session's MCP list predates Paper Plane 0.13). A stray `{"title":"x"}` created RUY-560 (closed; formations can't be deleted, issue not filed: the classifier blocked `gh issue create`, owner to decide).
- `scripts/ci-shell-linux.sh` reproduces CI's Fedora shell job in WSL podman; `revert-check.ps1` has a Rust mode.
- The lead reviews a ticket against main before every dispatch, including tickets written the same day: RUY-87's ground had moved a lot.

## Host facts learned
- Backslashes only through Write/Edit; PowerShell 5.1 needs `${var}:` before a colon in strings.
- `gh run watch <id> --exit-status` in a background Bash is the way to wait for CI.
- The Dell's connector is named HDMI-A-1 in DRM (owner: the PC has only DisplayPort).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-13 (lead-17) | 984460e..2c83b80 | 493, 474, 479, 16, 499, 491, 512; designs | round 2 for 16, 491, 499; owner bugs 538-540 | 1588 QML + 137 skips | 0.0.75 12/14 + input PASS |
| 2026-11-14 (lead-18) | 2c83b80..HEAD | 544, 540, 546, 545, 87, 573, 561, 550; analyses 538, 539, screensaver | round 2 for 544, 540, 545, 561; 2 product bugs found by VM (reclaim `\x2d`), 1 check race | 1596 QML + 137 skips | 0.0.76 12/18 (4 explained) |

## In flight (kept current)
- **0.0.78 at dfe06d7 (has everything for the Dell re-check): built and VM-checked.** All 21 queue checks pass except the audio input, which has no microphone without `-Audio` (expected). The session check's Lock step was fixed in d8fa59e and now passes. Not on the Dell yet: `bash scripts/dell-update.sh 0.0.78` once the owner switches it on.
- RUY-571 round 2 (worktree `RuyaOS-worktrees\RUY-571`): the 02 sentence, the mock once-flag reset, a pinned assert.
- RUY-577 round 1 handed over; `ruya-reviewer` is running. Its VM line (the reclaim lines in `vm-session-check.sh check`) is for the next image.
- RUY-583 round 1 (worktree `RuyaOS-worktrees\RUY-583`): Start emits `KEY_COMPOSE`, so Qt sees `Key_Menu`. This is the RUY-574 cause, found in the code: `KEY_MENU` maps to `XF86MenuKB` in xkb.
- Next for the free lane: RUY-562 (planned and reviewed: audio allows the saver, holds screen-off and sleep; a parked stream is not `Playing`).
- `scripts\free-space.ps1` is still to run (it shuts WSL down, so not while a builder uses it).
