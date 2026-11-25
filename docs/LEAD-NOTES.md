# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2); clean up every merged worktree with `scripts\worktree-done.ps1`; a Sonnet lead escalates hard-to-undo decisions to an Opus agent ("Model tiers")**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-51 (Sonnet, 2026-11-25; the owner was present: "keep going with new tickets; the new build can be done with the new lead")

- **Owner rules (memory `quick-wins-until-reset`):** until the weekly reset **2026-11-27 18:00 UTC** only simple quick-win tickets, Sonnet, two lanes (weekly plan 78 % all session). **First ticket after the reset: RUY-1190** (slow app-permissions page: Privacy pane N+1 plus the Store1 lock, 2.2 s on the Dell). Then RUY-1191, RUY-1192, the RUY-1183 players' Hub review, RUY-1176 -> 1177/1178, RUY-28 round 2 (worktree `RUY-28` stays), ROM chain from RUY-1152, Platform1 1130/1131/1137, RUY-781, RUY-1186.
- **Review range:** 60632baa..HEAD (the lead-51 handoff commit). **Paper Plane `changes` cursor:** 9135 (nothing relevant was missed; use `changes since=9135`).
- **Done (8, all quick wins):** RUY-1202 (CI `run-qml-tests.sh` names a missing test program once), RUY-1201 (a key-only `.play` signer serves no name; Library1 XML and specs 03/05 say so), RUY-1203 (`revert-check.ps1`: an aborted child is CAUGHT in every mode; round 2 for the Rust-mode order), RUY-987 (docs: OARS gambling 18+, unrated = "Not rated"; lead's own docs commit), RUY-1199 (`lint-bus-policies.ps1` compares every policy value case-sensitively; a rule element not exactly allow/deny is refused), RUY-1118 (Platform1 status list checked against the XML both ways), RUY-1206 (lint: a Caller annotation other than exactly `root` is refused; ordinal door table), RUY-1181 (Store mock hook `mockSetMinApiLevel` + the update "incompatible" test), RUY-1045 (a CR in a runner pin is refused by `Pin::parse` AND by `check_pin`; the mock's GE-Proton versions are tied to the pin; round 2: the builder found the shell verdict was an accident of the sha256 regex, so `install-runners.sh` was widened). Every merge gate green (last full run 2497-2498 QML, 0 failed). Reviews: APPROVE in round 1 except RUY-1203 (one real finding) and RUY-1045 (builder's own round 2).
- **Filed:** RUY-1204 (helper for the repeated block in `Test-RevertCheckPiping`), RUY-1205 (`lost-tests.ps1` rename-aware), RUY-1207 (lint: a malformed baseline JSON prints a FAIL line, a lost space at ~line 433). **Skipped on purpose:** RUY-1200 (2-3 battery chips rebuild, not worth it), RUY-1185 (merging ControllerPage's `pad` into PadGone's `seen` is not simple: `seen` only updates on `devicesChanged`, `pad` follows every change of `current`; re-title it complexity normal).
- **Image 0.0.108** is on the Dell (queue 21/22; `vm-library-check.sh steam` fixed by RUY-1196, still unproved inside an image). **No image was built in lead-51** (the owner left it to the next lead). `install-runners.sh` changed (RUY-1045): the 0.0.109 build and the runner pin check cover it.

## In flight at handoff
Nothing: no builder, no review, no image build, no VM. Leftover worktrees: `RUY-28`; `.claude/worktrees/design-*` (another session's, leave).

## Do first
1. **Build image 0.0.109 from `main`** (owner: "the new build can be done with the new lead"): `wsl -d FedoraLinux-44 -- bash -lc 'cd /mnt/d/dev/RuyaOS && scripts/image-chain.sh 0.0.109 oci'` (about 3 h; run it alone, no `dev.ps1 test` meanwhile: WSL memory), then the VM queue (the default list plus `vm-store-check.sh check`, `vm-store-check.sh perms`, `vm-profiles-check.sh create`; **`vm-library-check.sh steam` must be green**: it proves the Session1 policy file in an image), then `dell-update.sh 0.0.109` and `free-space.ps1`. Record the numbers on RUY-390 and RUY-1196. While it builds, spend the tokens on reading and planning, not on Windows tests.
2. **Check CI after the push** (reviewer's note on RUY-1206): CI runs the lint self-test with pwsh 7 (`ci.yml:32`), this machine only has Windows PowerShell 5.1.
3. **RUY-1197** (ruya-session scans only the active profile on the signal) and RUY-1198 (lint rule 6, subscribers). Then more quick wins: `list label=inbox,complexity:simple state=Backlog` (about 50); RUY-1204/1205/1207 are small; RUY-666 (VM).

## Concerns (ranked)
1. **Costs nobody measures:** RUY-1190 shows a screen can fire 74 calls with every test green; RUY-1191/1192 are the answer. Read every ticket for N+1 at planning.
2. RUY-1186: a game frozen 71 min under the Hub spun at 100 % after Resume with no frame (owner question inside).
3. Steam double input with Steam Input on is unverified (RUY-1184).
4. Instruction budgets: root `CLAUDE.md` 10.9 KB (about 10), shell/CLAUDE.md 7.6 KB (about 7): still over, not pruned in lead-50 or 51 (every cut removes an owner-dated rule; do it with the owner's eye, or move the "Environment pitfalls" block into `docs/dev-setup.md`).
5. RUY-1187: DRM page-flip spam on the Dell.

## Process in lead-51
- **Method that worked again:** pick quick wins from titles, read the code, rewrite the ticket with Scope, invariant and criteria plus a "Lead review before the build" comment (25-60 min per builder), one Opus reviewer each, two lanes, a full gate per merge run in the background while the next lane's HANDOFF is read. **A ticket's "unchanged" clause can be wrong** (RUY-1045): when a builder shows the root cause is in a file the ticket forbids, widen the ticket (the lead's decision) instead of leaving the accident in place. **Security lint changes (RUY-1199, 1206):** the reviewer re-ran fixtures by mutation; a "refuse what you cannot read exactly" rule beats a plain `-ceq`.
- Process: none (no step of LEAD.md cost more than it gave; the merge-gate output file plus one `Get-Content | Select -Last 3` is the cheapest way to read it).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-25 (lead-49) | 29a9374a..ab058821 | 9 merged (8 quick wins + 1196), 2 Dell/VM diagnoses, 1 architect ruling; filed 1188-1200 | round 2 on 1196 (lint bindings untested): real | 2494 QML, 0 failed | 0.0.108 queue 21/22 (steam red -> 1196); Dell on 0.0.108 |
| 2026-11-25 (lead-50) | ab058821..60632baa | 3 merged (1066, 986, 994), all APPROVE in round 1; filed 1201-1203 | 1 reviewer note fixed (stale wording), 1 own review-comment defect caught by the builder | 2496 QML, 0 failed | no image built (owner: not yet) |
| 2026-11-25 (lead-51) | 60632baa..HEAD | 9 merged quick wins (1202, 1201, 1203, 987, 1199, 1118, 1206, 1181, 1045); filed 1204, 1205, 1207 | round 2 on 1203 (Rust-mode abort) and 1045 (check_pin CR, widened): both real; 2 reviewer comment nits fixed | 2498 QML, 0 failed | no image built (left to lead-52) |
