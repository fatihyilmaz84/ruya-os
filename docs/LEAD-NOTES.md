# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2); clean up every merged worktree with `scripts\worktree-done.ps1`; a Sonnet lead escalates hard-to-undo decisions to an Opus agent ("Model tiers")**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-50 (Sonnet, 2026-11-25; the owner was present, asked for no image yet and two lanes)

- **Owner rules (memory `quick-wins-until-reset`):** until the weekly reset **2026-11-27 18:00 UTC** only simple quick-win tickets, Sonnet. The weekly plan was at 77 % at the start (over the 70 % line: the owner asked for the second lane anyway). **First ticket after the reset: RUY-1190** (slow app-permissions page: Privacy pane N+1 plus the Store1 lock, 2.2 s on the Dell). Then RUY-1191, RUY-1192, the RUY-1183 players' Hub review, RUY-1176 -> 1177/1178, RUY-28 round 2 (worktree `RUY-28` stays), ROM chain from RUY-1152, Platform1 1130/1131/1137, RUY-781, RUY-1186.
- **Review range:** ab058821..60632baa. **Paper Plane `changes` cursor:** 9134.
- **Done (3):** RUY-1066 (set-aside ledger names never go backwards with the clock), RUY-986 (dead name-only "Signed by" line), RUY-994 (`dev.ps1`: a missing test program fails at once, an empty lupdate project is regenerated). All three: reviewer APPROVE in round 1, merge gate green (last full run 2496 QML, 0 failed, 256 s). Filed: **RUY-1201** (play.rs:208 serves the key id as the signer name: the shell shows the 32-hex id; remove the fallback, small), RUY-1202 (CI `run-qml-tests.sh` one named line for a missing program), RUY-1203 (`revert-check.ps1` reports an aborted child as NOT CAUGHT).
- **Image 0.0.108** is on the Dell and passed the VM queue 21/22; the 22nd, `vm-library-check.sh steam`, was fixed by RUY-1196 (Session1.conf allow for `ruya-library`'s signal) and is **still unproved inside an image**.

## In flight at handoff
Nothing: no builder, no review, no image build, no VM. Leftover worktrees: `RUY-28`; `.claude/worktrees/design-*` (another session's, leave). The Dell runs 0.0.108.

## Do first
1. **Build image 0.0.109 from `main`** (the owner postponed it in lead-50): `wsl -d FedoraLinux-44 -- bash -lc 'cd /mnt/d/dev/RuyaOS && scripts/image-chain.sh 0.0.109 oci'` (about 3 h; run it alone, no `dev.ps1 test` meanwhile: WSL memory), then the VM queue (the default list plus `vm-store-check.sh check`, `vm-store-check.sh perms`, `vm-profiles-check.sh create`; **`vm-library-check.sh steam` must be green**: it proves the Session1 policy file in an image), then `dell-update.sh 0.0.109` and `free-space.ps1`. Record the numbers on RUY-390 and RUY-1196. 2. **RUY-1197** (ruya-session scans only the active profile on the signal: services, normal) and RUY-1198 (lint rule 6, subscribers). 3. More quick wins from the inbox: `list label=inbox,complexity:simple state=Backlog` gives about 54, titles are enough to pick (lead-50 took 1066, 986, 994 that way); RUY-1201/1202/1203 are small. 4. RUY-666: who starts `accounts-daemon` (VM).

## Concerns (ranked)
1. **Costs nobody measures:** RUY-1190 shows a screen can fire 74 calls with every test green; RUY-1191/1192 are the answer. Read every ticket for N+1 at planning.
2. RUY-1186: a game frozen 71 min under the Hub spun at 100 % after Resume with no frame (owner question inside).
3. Steam double input with Steam Input on is unverified (RUY-1184).
4. Instruction budgets: root `CLAUDE.md` 10.9 KB (about 10), shell/CLAUDE.md 7.6 KB (about 7): prune at the next chance (not done in lead-50).
5. RUY-1187: DRM page-flip spam on the Dell.

## Process in lead-50
- **A review comment that prescribes an algorithm can be wrong:** mine said "max(unix, newest) and keep the `-n` loop" on RUY-1066; the builder found the loop hands out a name that sorts below a surviving `-300-2` (pruned gap) and dropped it (n = newest n + 1), the reviewer confirmed. Write the invariant ("the file just moved sorts newest and nothing is overwritten"), not the steps. **Method that worked:** three quick wins picked from titles, each rewritten with Scope and criteria plus a "Lead review before the build" comment, 25-30 min per builder, one reviewer each; a lead's own review-note fix to `dev.ps1` costs a full gate (4 min), so touch only docs when a note allows it. **Paper Plane:** `update state=Ready` needs `## Acceptance criteria` (the override reason works); `create` returns the new id and a "similar" list.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-24 (lead-48) | b839c92a..29a9374a | 13 merged + 1 approved, 761 spec + audit, 5 owner decisions; filed 1176-1187 | round 2 on 480 (silent drop), 761 (2 spec contradictions): all real | 2485 QML, 0 failed; Linux CI PASS at 3aa6e7e9 | 0.0.108 build PASS, disk/VM/Dell not run (PC slept) |
| 2026-11-25 (lead-49) | 29a9374a..ab058821 | 9 merged (8 quick wins + 1196), 2 Dell/VM diagnoses, 1 architect ruling; filed 1188-1200 | round 2 on 1196 (lint bindings untested): real | 2494 QML, 0 failed | 0.0.108 queue 21/22 (steam red -> 1196); Dell on 0.0.108 |
| 2026-11-25 (lead-50) | ab058821..60632baa | 3 merged (1066, 986, 994), all APPROVE in round 1; filed 1201-1203 | 1 reviewer note fixed (stale wording), 1 own review-comment defect caught by the builder | 2496 QML, 0 failed | no image built (owner: not yet) |
