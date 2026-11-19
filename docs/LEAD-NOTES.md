# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2)**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-36 (Opus, 2026-11-18/19)

- **Review range:** d0b97cdb..HEAD. **Paper Plane `changes` cursor:** 5103 (not re-read since the start).
- **Lanes:** one, then two (owner, mid-session). None open at handoff; no builder worktrees. The old `.claude/worktrees/design-pad-silhouettes-559410` is still there (lead-34 note).
- **Merged and Done (17):** RUY-877 (+876, VM-proven), 869, 867, 873, 870, 875, 871, 872, 879+878, 882, 860, 884, 889, 888. Rounds 2: 869 (Debug-string compare), 871 (unknown-app regression), 884 (lead's copy broke with verb phrases), 889 (culture sort, grown-pair test), 888 (developer page). Every merge gate green; two gate re-runs were load flakes (RUY-891 tst_wallpaper, RUY-794 tst_player_chips), not code.
- **Lead `review:` commits:** 02/04 art crop and saver order (873), 04 Turkish key line and sheet rows (872), PlayCopy fallback and the capital rule (884), vm-session-check.sh `sign_in`/`start_monitor` (the new duplicate lint caught RUY-888's copy on main).
- **Owner rules this session (2026-11-19):** no hacks, no duplicate code, for lead and builders. Now enforced: the reviewer blocks on a workaround or a second copy, the builder's HANDOFF has a `reuse:` line (with "could be shared"), LEAD.md 4b.1's lead review names the shape and the code to reuse, "Shared homes" in `services/CLAUDE.md` and `shell/PATTERNS.md`, and `scripts/lint-duplicates.ps1` (80-token blocks, baseline of 98 pairs that only shrinks) in `dev.ps1 test` and CI. Debt tickets RUY-892/893/894.

## The .play VM state
- **0.0.95** (48a03781): `check` 36/0/2 (Library1 lists the app: RUY-876 done), `perms` 6/0, `library play` 10/0, `helper` 11/0, `verify` 10/1 (fixed by RUY-882), a second `check` failed (fixed by RUY-879). Results on RUY-100.
- **0.0.96** (7aa116df: has 867, 869-873, 875, 877-879, 882; **not** 860/884/888/889): image, qcow2 and oci on F: built. **`vm-queue.ps1` .play run all PASS** (check twice, verify, perms, helper, library play; 2 min): RUY-100 proven in the VM except Launch with a profile.
- The Dell runs **0.0.95** (rollback 0.0.94); only failed unit the known `bootloader-update.service`.

## First thing next session
1. RUY-100's last step: Launch of a .play app with a profile (create one in the VM, or let `vm-queue.ps1` make one as it does for the x11 check). Then unblock RUY-102/104's children.
2. Next image (from HEAD: 888, 884, 860, 889): `vm-reboot-check.ps1 -Shutdown` (RUY-888, needs a profile), then the Dell: update, then the owner's case (an Ironwail setting survives a reboot while LibreQuake is frozen behind the Hub) and RUY-867's old folders on an upgraded console.
3. `.play` lanes left (Backlog, need a lead review): RUY-880/891/794 (flakes), 881 (Store art), 885, 886, 887, 890, 874 (design: genre tint), 883 (format: what's new, needs a decision), then RUY-101 (runners), 103 (updates). Also RUY-895/896 (888 follow-ups), 892-894 (duplicate debt).

## Owner direction (in force)
- **.play first (2026-11-18).** Two lanes (2026-11-19).
- **Maintainers; no hacks, no duplicate code (2026-11-18/19).**
- Performance goal RUY-558 (measure first, RUY-842); RUY-838 game options; Steam first-class (RUY-815).

## Concerns (ranked)
1. Load flakes in the full gate while builders and an image build run (two this session): RUY-891, RUY-794.
2. RUY-888 is unproven on a real shutdown (logind fd passing under the unit's hardening and SELinux).
3. `merge-gate.ps1` hides which `dev.ps1` step failed (a red gate cost a full extra run to find "duplicate lint").

## Process changes in lead-36
- **Lead:** lead reviews now fix the shape and the code to reuse (owner); several tickets were widened or narrowed before dispatch (860, 870, 872, 882) and RUY-876/882's causes were found by reading code before any builder ran.
- **Builders:** `reuse:` HANDOFF line; "Genuine fix, one copy" self-check.
- **Tests:** `lint-duplicates.ps1` in `test` and CI; `vm-queue.ps1` reads `# modes:` lines and runs the `.play` checks (`scripts/play-vm-files.sh` builds the files).
- **Paper Plane:** none.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-18 (lead-34) | 4582246..486cc14 | 4 merged + 2 lead commits | 834, 840, 852: round 2 (all real) | 2216 passed, 0 failed | 0.0.92: vm-play-check 20/12 (SELinux, fixed by ADR-036) |
| 2026-11-18 (lead-35) | 486cc14..d0b97cd | 7 tickets merged in 5 branches (866 lead) + 2 lead docs commits; filed 866-875 | 866, 853, 856: round 2; 1 lead review fix | 2247 passed, 0 failed | 0.0.94: check 33/2 (installs work; RUY-876, 877 filed) |
| 2026-11-19 (lead-36) | d0b97cd..HEAD | 17 tickets merged (16 branches) + 4 lead review commits + 3 docs commits; filed 878-896 | 869, 871, 884, 889, 888: round 2 (all real); 2 gate load flakes | 2274 passed, 0 failed (last gate) | 0.0.95: check 36/0, perms 6/0, library 10/0, helper 11/0, verify 10/1 (fixed); 0.0.96: .play queue all PASS |
