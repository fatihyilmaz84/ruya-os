# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2); clean up every merged worktree with `scripts\worktree-done.ps1`**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-42 (Opus, 2026-11-22; the owner was present most of the day)

- **Review range:** 52e84073..HEAD (all reviewed; every builder branch had an Opus review or a lead review). **Paper Plane `changes` cursor:** about 7990.
- **Merged and Done (11):** RUY-1038 (pre-install art under /run/ruya-play), 920, 52, 1044, 1042, 1039 (GE-Proton's libxkbcommon pruned: Proton pads work), 1040 (pad flap at launch), 1050 (B1 app table, ruya-keyfile), 960 (B7a ruya-vdf), 1051 (B2 Session1 item/parent, LaunchItem, rollback-safe ledger), 1052 (B3a Steam children). Closed: 813 (disproved on the Dell), 1043 (superseded), 1047 (spike S1). Last gates on main: **2371 QML + 2540 Rust, 0 failed**. Pushed 6d01cbfa; main is ahead by the B3a merge and two docs commits.
- **Architect audit (Steam, RUY-815):** ADR-041..045 committed, ADR-041 amended twice from Dell evidence (point 2: the game scope's top process is the oldest with `FLATPAK_ID`, carrying SteamAppId and SteamGameId; point 7: parent/child rules). Plan = formation RUY-956 (B1..B12, spikes S2/S3).
- **Owner decisions today:** RUY-1060 = a **public "do not freeze me"** declaration (against the recommendation; ADR-042 point 4 superseded; its ADR is RUY-1062, lead). RUY-1061 = uinput for the active profile only plus a compositor rule (B9, RUY-1063). RUY-1007: no repack of UT99/Anno (keyboard games); an RPCS3 + ROM pack is parked. Focus: **Steam**.
- **Image:** 0.0.103 built but skipped (owner). **0.0.104 (dfd2b15b) is building** (`output\chain\summary.txt`; `oci` to F:). The Dell still runs 0.0.102.

## In flight
- Image chain 0.0.104 (build + disk + oci). Nothing else: no worktrees left.

## Next
1. When the chain says CHAIN OK: the VM queue (list on RUY-390), then `dell-update.sh 0.0.104`, then the Dell list on RUY-390 (Monster Boy with a pad, install art, no pad flap, a Steam game as a child). Run `free-space.ps1` after.
2. Steam, in order: **B3b RUY-1067** (LaunchItem for steam: items) and **B7 RUY-1056** (per-profile Library reader) are next; both need a lead review first. Then B6 RUY-1055 (shell keyed by item; needs a Claude Design pass for Close game / Close Steam), S3 RUY-1049 then B4/B5, S2 RUY-1048 (gamescope).
3. RUY-1062 (lead): the public no-freeze ADR under ADR-022, with ruya-api-reviewer.
4. RUY-1059 (lead docs): spec 03 Steam row and roadmap §6 still describe a gamescope path that was never built.

## Concerns (ranked)
1. The Steam children logic (B3a) is host-tested only; the Dell is its first real test (exit code 3 through `systemd-run --wait --pipe` unverified).
2. F: holds the WSL distro: with F: unplugged there are no image builds at all (happened today).
3. An image build reads the main checkout for 80+ minutes, and merges must wait (today: 3 approved branches waited). Fix idea: build from a throw-away worktree at the commit.

## Process changes in lead-42
- **Lead:** I wrote "you have no Dell access" into a builder brief (RUY-1039); the owner corrected it. Builders on Dell-relevant tickets get the SSH line, never a restriction (LEAD.md 4b.3 now says so).
- **Lead:** Dell diagnostic agents (Opus) settled four questions today (1039 cause, 813 disproved, 1040 cause, S1) in 10-16 min each; keep using them before writing tickets.
- **Builders:** two tests that could not fail (RUY-1038 weakened to a RIFF prefix; RUY-960 an all-spaces "oversized" file), both caught by reviewers' revert checks. Reviewers keep doing their own revert check.
- **Tests:** none new. **Paper Plane:** none.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-21 (lead-40) | d639cdb..502020d | 19 tickets done + ADR-039/040 + 2 lead docs/review commits; filed 1003-1023 | round 2 on 995, 996, 1018, 1004: all real | 2361 passed, 0 failed | 0.0.99 32/32, 0.0.100 32/32; Dell: sample + UT |
| 2026-11-21/22 (lead-41) | 502020d..52e8407 | 14 merged + 102 closed + 2 lead commits; filed 1024-1039 | round 2 on 1021, 799, 1019, 1029, 1034, 1028: all real | 2362 passed, 0 failed | 0.0.101 17/17 + 13/13; 0.0.102 6/6; Dell: X11 10/10, Monster Boy installs |
| 2026-11-22 (lead-42) | 52e8407..HEAD | 11 merged, 3 closed, architect audit (ADR-041..045), 4 Dell diagnoses; filed 1040-1069 | round 2+ on 1038 (x2), 1039, 1050, 960, 1051, 1052, 52: all real | 2371 QML + 2540 Rust, 0 failed | 0.0.103 built, skipped; 0.0.104 building |
