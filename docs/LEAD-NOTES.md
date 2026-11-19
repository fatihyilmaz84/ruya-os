# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2)**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State during lead-37 (Opus, 2026-11-19), written at the 5-hour limit (97 %)

- **Review range:** 09c9c084..HEAD. **Paper Plane `changes` cursor:** 5163 (not re-read).
- **Merged and Done:** RUY-885 (+ lead review: one "absent" rule), RUY-855 (round 2: the VM check reads the kernel's memory.max/pids.max), RUY-898 (round 2 + lead review: `read_within`, the guide test can't skip a broken example). Every merge gate green (2274 passed). Pushed up to 1c5df772; later commits are **not pushed** yet.
- **Lead work:** RUY-100 closed (all but launch proven; launch moves to RUY-101). Architect audit of RUY-101 led to ADR-037 (runner.json v1, the launch protocol) and ADR-038 (launcher and runners as /usr files, shown to Flatpak as unmaintained extensions), both committed. RUY-899 proved ADR-038 in the VM (`scripts/spikes/play/q5-unmaintained-ext.sh`, ALL PASS; the Dell's SSH timed out). RUY-906 docs done.
- **Owner decisions (2026-11-19):** RUY-897: GE-Proton is always in the OS image and updates with it; packagers may bundle another version. Then: **every Windows runner ships in the image** (GE-Proton, Wine stable and staging, Wine-GE, UMU-Proton), and an app picks its own runner (RUY-37 rescoped; ADR-025 amended). No Store channel for runners.

## In flight at the pause (worktrees under D:\dev\RuyaOS-worktrees)
- **RUY-900** (runner metadata, generation, recommit), round 2 with its builder: forward-compatible installed.json/jobs.json, `runners` and `lib/i386-linux-gnu` reserved in the format crate, the guide sentence on /app/runners, no-autodownload for Compat.i386/GL32, a free-space check before the recommit. Then a delta review (code and API).
- **RUY-886+887** (one branch, t/RUY-886-887-play-vm-checks), round 2: one id-suffix helper for every mode; no dangling mock paths, plus a test.
- **RUY-890** (modes lint), round 3, the last: one canonical dispatch form, everything else fails. If it still leaks: the lead finishes it or splits it.
- **RUY-901** (ruya-play-launch crate), round 1 in review (code + API). Open question: the re-parse with official=true vs the deployment's trust.json tier.
- Any agent cut off by the limit: look at its worktree's last commit and resume it with SendMessage, or start a fresh builder on the same branch.

## Next
1. Finish the four lanes above; merge in order 900, 901 (both touch ruya-play-format; re-run the gate after each).
2. Then: RUY-34 (the image's Play platform on /usr: musl launcher, GE-Proton, tmpfiles, Platform 26.08 + Compat.i386/GL32), RUY-903 (Library1 dry-run), RUY-902 (VM launch end to end), RUY-37 (the other runners), RUY-904/905 (the choice and the screen; 905 needs a canvas first). RUY-909 (generation must not widen permissions) is the lead's to decide before RUY-900's recommit reaches a release.
3. VM queue (RUY-390): RUY-855 `vm-session-check.sh check` on an image from 1c5df772 or later.

## Concerns (ranked)
1. Plan limits: four lanes plus Opus reviewers used the 5-hour window in about 4 hours.
2. D: disk (31-49 GB free with four lanes); clean worktrees and the main `services\target` after merges.
3. Regex-based shell linting (RUY-890) leaked twice; prefer enforcing one form over reading many.

## Process changes in lead-37
- **Lead:** owner-level questions about the product set (runners) asked in plain words; "Store runners" was jargon. A builder's inbox line that closes a gap inside its own ticket goes back to the builder, not to the inbox (RUY-886/887).
- **Tests:** none yet.
- **Paper Plane:** none.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-18 (lead-35) | 486cc14..d0b97cd | 7 tickets merged in 5 branches (866 lead) + 2 lead docs commits; filed 866-875 | 866, 853, 856: round 2; 1 lead review fix | 2247 passed, 0 failed | 0.0.94: check 33/2 (installs work; RUY-876, 877 filed) |
| 2026-11-19 (lead-36) | d0b97cd..09c9c08 | 17 tickets merged (16 branches) + 4 lead review commits + 3 docs commits; filed 878-896 | 869, 871, 884, 889, 888: round 2 (all real); 2 gate load flakes | 2274 passed, 0 failed (last gate) | 0.0.95/0.0.96: .play queue all PASS |
| 2026-11-19 (lead-37, at the pause) | 09c9c08..HEAD | 3 merged (885, 855, 898) + 2 lead review commits; ADR-037/038; RUY-100/899/906 closed; filed 897-910 | 855, 898, 890, 900 round 2 (all real; 890 round 3) | 2274 passed, 0 failed (each gate) | RUY-899 spike ALL PASS (0.0.96) |
