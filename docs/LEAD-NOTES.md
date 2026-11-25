# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2); clean up every merged worktree with `scripts\worktree-done.ps1`; a Sonnet lead escalates hard-to-undo decisions to an Opus agent ("Model tiers")**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-52 (Sonnet, 2026-11-25; the owner was present: "always do two lanes", then "keep another hour, then hand off")

- **Owner rules (memory `quick-wins-until-reset`):** until the weekly reset **2026-11-27 18:00 UTC** only simple quick-win tickets, Sonnet, **always two lanes** (dispatch the next ticket the moment a lane frees; lead-52 ran one lane for the last half hour so the handoff fit the hour). Weekly plan 80 % at the end. **First ticket after the reset: RUY-1190** (slow app-permissions page). Then RUY-1191, 1192, the RUY-1183 players' Hub review, RUY-1176 -> 1177/1178, RUY-28 round 2 (worktree `RUY-28` stays), ROM chain from RUY-1152, Platform1 1130/1131/1137, RUY-781, RUY-1186.
- **Review range:** ae2f9c41..HEAD (this handoff commit). **Paper Plane `changes`:** not read to the end (a long list); everything of lead-52 is in the tickets named here, so read `list` by number from RUY-1204.
- **Done (10), every merge gate green (2498 QML, 0 failed):** RUY-1207 (lint-bus-policies: one `Read-Baseline`, one FAIL line for bad JSON or duplicate keys), 759 (AppStream chapter), 1204 (`Test-RevertCheckPiping` helper), 1209 (Store1.xml screenshot comment), 1208 (baseline root must be an object; round 2: the raw text must start with `{`, since pwsh 7 unwraps `[{...}]`), 1197 (`ProfileScanWanted` scans only the active profile; **VM check pending**), 756 (notifications fixtures 26 s -> 8 s), 612 (contract registry: one unit-tested lexer for `#[interface(..)]`; round 2: escaped char literal), 488 (inputd journals an unreadable directory once per streak), 728 (guest follow-ups; **VM check pending**: `vm-profiles-check.sh create`). APPROVE in round 1 except 1208 and 612 (one real finding each).
- **GitHub CI** on 8cd7d11d (1207 + 1208): `ci` and `supply-chain` success, so the lint passes under pwsh 7. The push of this handoff is the next check (`gh run list -L 3`).
- **Filed:** RUY-1210 (owner-lead: AppStream release without a date; does `Game` do anything), 1211 (pwsh 7 edition gap; has not bitten yet), 1212 (`macro_rules!` blind spot of the registry), 1213 (time every `test-vm-checks.sh` section; the VM check lint step took 321 s), 1214 (run `test-vm-checks.sh` under Linux bash in WSL), 1215 (inputd leftovers). **Skipped on purpose, with a comment:** RUY-1198 (sender names are consts: complex, architect first), 1205 (needs test bodies), 775 (the mock hides fields on purpose: decide first).
- **Image 0.0.109 is built** from ae2f9c41 (`CHAIN OK`: build 136 min, drivers, disk 61 min, oci 21 min; image id 80f3237ed193). **The VM queue and the Dell update are not done.** The image has neither RUY-1197's adapter log nor RUY-728 (scripts only, plus mock and service); the next image carries them.

## In flight at handoff
Nothing: no builder, no review, no VM, no WSL job. Leftover worktrees: `RUY-28`; `.claude/worktrees/design-*` (another session's, leave).

## Do first
1. **VM queue on 0.0.109** (`docs/dev-setup.md`; WSL is idle): the default list plus `vm-store-check.sh check`, `vm-store-check.sh perms`, `vm-profiles-check.sh create`, **`vm-library-check.sh steam` (must be green: it proves the Session1 policy in an image)**. Then `dell-update.sh 0.0.109` and `free-space.ps1`. Record on RUY-390 and RUY-1196.
2. **RUY-1214** while the VM is up: `test-vm-checks.sh` under Linux bash in WSL (RUY-756's `export -f` fakes ran only under Git Bash).
3. CI on the handoff push; then quick wins: `list label=inbox,complexity:simple state=Backlog` (RUY-1215, 1212, 1213 are ready to plan; 1210 and 1211 are yours to decide).

## Concerns (ranked)
1. **Costs nobody measures:** RUY-1190 (74 calls on one screen); RUY-1213 (the test gate itself).
2. RUY-1186: a game frozen 71 min under the Hub spun at 100 % after Resume (owner question inside).
3. Steam double input with Steam Input on is unverified (RUY-1184).
4. Instruction budgets: root `CLAUDE.md` 10.9 KB, shell/CLAUDE.md 7.6 KB: still over (every cut removes an owner-dated rule; do it with the owner's eye).
5. An architect audit is due (none recorded since lead-49's); RUY-1198 needs one.

## Process in lead-52
- **Worked:** read the code before writing a ticket (1198 and 1205 looked simple by title and were not: two comments instead of two wasted builders); a hard "test-weakening" brief to the reviewer for 756; a reviewer that reasons about the other PowerShell edition caught what no host run could (1208); merges serialised on the gate (no commit on `main` while it runs; the next worktree is made meanwhile).
- **Cost:** an unfiltered `dev.ps1 docs` and a read of the single huge spec-03 line cost about 15 KB each: filter with `Select-Object -Last 2` and `grep -o`. A docs-only merge still ran the full gate when the builder had no green marker (5 min).
- Process: none changed in files.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-25 (lead-50) | ab058821..60632baa | 3 merged (1066, 986, 994), all APPROVE in round 1; filed 1201-1203 | 1 reviewer note fixed, 1 own review-comment defect caught by the builder | 2496 QML, 0 failed | no image built |
| 2026-11-25 (lead-51) | 60632baa..ae2f9c41 | 9 merged quick wins; filed 1204, 1205, 1207 | round 2 on 1203 and 1045: both real; 2 reviewer nits fixed | 2498 QML, 0 failed | no image built |
| 2026-11-25 (lead-52) | ae2f9c41..HEAD | 10 merged (1207, 759, 1204, 1209, 1208, 1197, 756, 612, 488, 728); filed 1208-1215 | round 2 on 1208 (pwsh 7 root array) and 612 (escaped char literal): both real; API-review doc notes fixed | 2498 QML, 0 failed | image 0.0.109 built (CHAIN OK); VM queue not run |
