# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2)**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-37 (Opus, 2026-11-19/20)

- **Review range:** 09c9c084..HEAD. **Paper Plane `changes` cursor:** 5163 (not re-read).
- **Merged and Done (11 tickets):** RUY-885 (+ lead review: one "absent" rule), 855 (round 2: the VM check reads the kernel's memory.max/pids.max), 898 (round 2 + lead review: `read_within`), 900 (round 2 + lead review: GL32 prefix test), 890 (round 3 + the lead closed the last lint hole, da3780f6), 886+887 (round 3, lead delta check), 901 (round 3: the launcher crate; Linux tests run green in WSL), 907+908. Last full test on main: **2275 passed, 0 failed**. All pushed at handoff.
- **A merge-order lesson:** RUY-900 added `shift; generation "$@"` and RUY-890's new lint refuses it. Each branch was green alone; the gate after both was red until RUY-886/887's branch (which had merged main) fixed the line. Run the full test after merging two branches that touch the same scripts.
- **Lead work:** RUY-100 closed (all but launch proven; launch moves to RUY-101). Architect audit of RUY-101 led to ADR-037 (runner.json v1, the launch protocol) and ADR-038 (launcher and runners as /usr files, shown to Flatpak as unmaintained extensions), both committed. RUY-899 proved ADR-038 in the VM (`scripts/spikes/play/q5-unmaintained-ext.sh`, ALL PASS; the Dell's SSH timed out). RUY-906 docs done.
- **Owner decisions (2026-11-19):** RUY-897: GE-Proton is always in the OS image and updates with it; packagers may bundle another version. Then: **every Windows runner ships in the image** (GE-Proton, Wine stable and staging, Wine-GE, UMU-Proton), and an app picks its own runner (RUY-37 rescoped; ADR-025 amended). No Store channel for runners.

## Between sessions (owner session, 2026-11-20): read first
- **Labels cleaned on RUY:** seven stray labels deleted (``area:` ``, `area:cmakelists.txt`, `area:new`, `area:no`, `area:ruya`, ``area:ruya` ``, `area:the`); RUY-175 got `area:apps`, RUY-160 `area:tools`. Left for you: `size:L` on RUY-117 (not in the template).
- **New label `spike`** on the 18 real spikes (not RUY-58, RUY-157 or the cancelled RUY-32/843). Every new spike carries it; `PLANNING.md` step 4 and step 2 (read the label list each pass) say so.
- **Paper Plane 0.27.0** is in production: Telegram messages for a session waiting on a permission or an answer, and a daily digest of what waits on the owner. Paper Plane has no ADR or spike type and needs none: ADRs stay in `00-overview.md`, their tickets name `(ADR-n)` in the title.
- **Blueprint:** this way of working is written up for other projects in `D:\dev\Synsi_Flow\WORK-PLAN.md` (outside this repo). A process change here that would help any project goes there too.

## In flight
- Nothing. No builder worktrees (only the old `.claude/worktrees/design-pad-silhouettes-559410`). The owner stopped new work at the plan limit (2026-11-20).

## Next (the .play launch path, RUY-101 umbrella)
1. **RUY-34** (Ready): the image's Play platform on /usr: the musl `ruya-play-launch` build, GE-Proton with runner.json and `.ruya-runner-hash`, tmpfiles links, Platform 26.08 + Compat.i386/GL32 preinstalled; it removes the `#[ignore]` in ruya-play/tests/platform.rs. Then an image build and the VM queue.
2. **RUY-903** (Ready, lead review on it): Library1 dry-run; reuse the launcher's resolution (now merged).
3. **RUY-902**: VM launch end to end, after RUY-34. Then RUY-37 (the other four runners), RUY-904 (`--runner`), RUY-905 (Compatibility screen; canvas first).
4. **RUY-909** (lead, high): a generation bump must not widen an installed app's permissions; decide before a release carries RUY-900's recommit.
5. VM queue (RUY-390 comments): 855, 900, 886/887, the five scripts RUY-890 converted.

## Concerns (ranked)
1. Plan limits: four lanes plus Opus reviewers used the 5-hour window in about 4 hours.
2. D: disk (31-49 GB free with four lanes); clean worktrees and the main `services\target` after merges.
3. Regex-based shell linting (RUY-890) leaked twice; prefer enforcing one form over reading many.

## Process changes in lead-37
- **Lead:** owner-level questions about the product set (runners) asked in plain words; "Store runners" was jargon. A builder's inbox line that closes a gap inside its own ticket goes back to the builder, not to the inbox (RUY-886/887).
- **Tests:** the VM-check lint now enforces one dispatch form (RUY-890); the record-key check covers every contract (RUY-907). Builders can't run Linux-only tests; the lead ran ruya-play-launch's in WSL (`CARGO_TARGET_DIR=/tmp/...`, from `services`). An inbox line: revert-check.ps1 has no mode for lint-vm-checks.ps1.
- **Paper Plane:** none.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-18 (lead-35) | 486cc14..d0b97cd | 7 tickets merged in 5 branches (866 lead) + 2 lead docs commits; filed 866-875 | 866, 853, 856: round 2; 1 lead review fix | 2247 passed, 0 failed | 0.0.94: check 33/2 (installs work; RUY-876, 877 filed) |
| 2026-11-19 (lead-36) | d0b97cd..09c9c08 | 17 tickets merged (16 branches) + 4 lead review commits + 3 docs commits; filed 878-896 | 869, 871, 884, 889, 888: round 2 (all real); 2 gate load flakes | 2274 passed, 0 failed (last gate) | 0.0.95/0.0.96: .play queue all PASS |
| 2026-11-19/20 (lead-37) | 09c9c08..HEAD | 11 tickets merged (8 branches) + 4 lead review commits; ADR-037/038; RUY-100/899/906 closed; filed 897-914 | rounds 2-3 on 855, 898, 900, 901, 890, 886/887 (all real); 1 red gate from a merge-order clash | 2275 passed, 0 failed (last) | RUY-899 spike ALL PASS (0.0.96) |
