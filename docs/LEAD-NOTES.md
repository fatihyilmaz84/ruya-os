# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2); clean up every merged worktree with `scripts\worktree-done.ps1`; a Sonnet lead escalates hard-to-undo decisions to an Opus agent ("Model tiers")**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-49 (Sonnet, 2026-11-25; the owner was present and asked for two or three lanes all day)

- **Owner rules (memory `quick-wins-until-reset`):** until the weekly reset **2026-11-27 18:00 UTC** only simple quick-win tickets, Sonnet, two lanes (the owner asked for a third at times). **First ticket after the reset: RUY-1190** (the slow app-permissions page: Privacy pane N+1 plus the Store1 lock, 2.2 s measured on the Dell; it waits in Backlog). Then RUY-1191 (call-budget tests) and RUY-1192 (Dell audit of every screen's cost), the RUY-1183 players' Hub review, RUY-1176 -> 1177/1178, RUY-28 round 2 (worktree `RUY-28` stays), ROM chain from RUY-1152, Platform1 1130/1131/1137, RUY-781, RUY-1186.
- **Review range:** 29a9374a..HEAD. **Paper Plane `changes` cursor:** take the latest at start.
- **Done (10):** RUY-1182, 671, 677, 752, 711, 1189, 1194, 1103 (all quick wins, all gates green, last gate 2494+ QML), **1196** (lead + Opus-reviewed security fix), 1195 (owner decision). RUY-922 cancelled (dup of 1190). Instruction changes: builder self-check and reviewer checklist now count the **cost of a path at 40 items** (calls, spawns, locks; a defect in the diff's own design is CHANGES_REQUESTED, never an inbox line).
- **Image 0.0.108** (built from 1a01958b) is on the Dell (only `bootloader-update` fails: Secure Boot, known) and passed the VM queue 21/22. The 22nd, `vm-library-check.sh steam`, failed because **`Library1.ProfileScanWanted` never reached ruya-session** (Session1.conf default deny drops a non-root sender's broadcast). Fixed by RUY-1196: Session1.conf allow for `ruya-library` (exact signal), `security-baseline.json` `service_signals`, lint rule 2 + 20 fixtures, ADR-045 amendment (architect), CLAUDE.md invariant sentence (owner approved 2026-11-25), spec 01. Proved as an /etc drop-in in a fresh VM (steam check ALL PASSED); **the file inside an image is still unproved**: the 0.0.109 chain's VM queue (Do first, 1) must show `vm-library-check.sh steam` green.

## In flight at handoff
Nothing: no builder, no review, no image build, no VM; `main` is pushed (3985b4a7, Linux CI job PASSED, 2496 QML). The owner asked that the **next lead builds the image** (none was started here). Leftover worktrees: `RUY-28`; `.claude/worktrees/design-*` (another session's, leave). The Dell runs 0.0.108.

## Do first
1. **Build image 0.0.109 from `main`** (`wsl -d FedoraLinux-44 -- bash -lc 'cd /mnt/d/dev/RuyaOS && scripts/image-chain.sh 0.0.109 oci'`, about 3 h with disk and oci; run it alone, no `dev.ps1 test` meanwhile: WSL memory), then the VM queue (the default list plus `vm-store-check.sh check`, `vm-store-check.sh perms`, `vm-profiles-check.sh create`; **`vm-library-check.sh steam` must be green**: it proves the Session1 policy file in an image), then `dell-update.sh 0.0.109` and `free-space.ps1`. Record the numbers on RUY-390 and RUY-1196. 2. **RUY-1197** (ruya-session scans only the active profile on the signal: a hint, not a command; services, normal) and RUY-1198 (lint rule 6, subscribers) now that 1196 is in. 3. Plan more quick wins from the inbox (about 250 lines; reading the titles for cost defects found nothing by keyword). 4. RUY-666: who starts `accounts-daemon` (VM).

## Concerns (ranked)
1. **Costs nobody measures:** RUY-1190 shows a screen can fire 74 calls and queue on a lock with every test green; RUY-1191/1192 are the automated and the manual answer. Read every ticket for N+1 at planning.
2. RUY-1186: a game frozen 71 min under the Hub spun at 100 % after Resume with no frame (owner question inside).
3. Steam double input with Steam Input on is unverified (RUY-1184).
4. Instruction budgets: root `CLAUDE.md` 10.9 KB (about 10), shell/CLAUDE.md 7.6 KB (about 7): prune at the next chance.
5. RUY-1187: DRM page-flip spam on the Dell.

## Process changes in lead-49
- **Rules:** cost of the path (builder + reviewer). **Method that worked:** a Sonnet diagnostic agent on the Dell or a kept VM with a "report at most 40 lines, root cause with file:line" brief found two root causes in 25-35 min each (RUY-1190, the policy gap); an Opus `ruya-architect` agent for the bus-policy question gave an Accepted ADR amendment, one owner question and a lint check (RUY-1198). **Process:** a lead's own security change goes to `ruya-reviewer` (round 1 found real fixture gaps). `find()` also returns delegates waiting for deleteLater: `tests/LiveRows.js` (RUY-1189). **Paper Plane:** an `update` to Ready needs a `## Acceptance criteria` heading (override with a reason otherwise); `create` prints a new id for each call: read it before referencing tickets (I mis-referenced RUY-1195/1196 once).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-24 (lead-47) | 35fc3b50..b839c92a | 18 merged, 157 + 842 Done, ADR-048 + architect review, 6 owner answers; filed 1151-1175 | round 2 on 1170, 669, 722: all real | 2465 QML, 0 failed; Linux CI job PASS at push | 0.0.107 built; VM 7/8; Dell on 0.0.107 |
| 2026-11-24 (lead-48) | b839c92a..29a9374a | 13 merged + 1 approved, 761 spec + audit, 5 owner decisions; filed 1176-1187 | round 2 on 480 (silent drop), 761 (2 spec contradictions): all real | 2485 QML, 0 failed; Linux CI PASS at 3aa6e7e9 | 0.0.108 build PASS, disk/VM/Dell not run (PC slept) |
| 2026-11-25 (lead-49) | 29a9374a..HEAD | 9 merged (8 quick wins + 1196), 2 Dell/VM diagnoses, 1 architect ruling; filed 1188-1200 | round 2 on 1196 (lint bindings untested): real | 2494 QML, 0 failed | 0.0.108 queue 21/22 (steam red -> 1196); Dell on 0.0.108 |
