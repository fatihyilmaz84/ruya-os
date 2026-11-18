# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-34 (Opus, 2026-11-18)

- **Review range:** 45822466..HEAD. **Paper Plane `changes` cursor:** 5043.
- **Stopped by the owner:** the weekly plan is at 94 % (reset 2026-11-20 18:00). No lanes, no worktrees open (four locked leftover folders under `D:\dev\RuyaOS-worktrees`, RUY-862).
- **Merged (4 tickets + 2 lead commits):** RUY-834 (Play1.Verify; Flatpak's empty `/app/.ref` is left out), RUY-840 (a held game's pads are set aside, closed to the new game, and given back on a failed launch), RUY-851 (one `.play` permission table, metadata from it, update diff, `trust.json`), RUY-852 (Library1 lists `.play` art, facts, tier and signer, only for origin `ruyaos-play-local`). Lead: `shell/CLAUDE.md` pruned to 7.3 KB; 46dcb90e is the SELinux module (ADR-036). Every review asked for a round 2 except RUY-851's; all were real bugs.
- **No merge gate ran for RUY-851/852** (the image's make-disk was running; I removed their worktrees before the gate). `dev.ps1 rust` is green on the merge. `push-main.ps1` runs the full test itself.

## The .play blocker (owner: ".play first")
- 0.0.92 VM: every USB install failed. PID 1 (`init_t`) opens the helper's `OpenFile=` source and SELinux denies `dosfs_t`/`fusefs_t`; `graceful` makes that look like "missing", so Inspect said `unknown-source`. The `incoming/` and 209/STDOUT failures were the check's `/tmp` file (fixed: `/run`).
- **Fix: ADR-036, Accepted (lead)**, a two-rule CIL module (`image/rootfs/usr/share/selinux/packages/ruyaos/ruya_play_openfile.cil`, `semodule -i` in the Containerfile). It was measured live in the VM: helper 7/0; Inspect parses on vfat, exfat, ntfs3 and ntfs-3g. The alternative with no policy is an SCM_RIGHTS socket (in ADR-036). **The architect should check the ADR at the next audit.**
- **Image 0.0.93** (46dcb90e, has the module, not 851/852) was making its disk at handoff (`output/chain/summary.txt`; then the oci for the Dell).

## First thing next session
1. If 0.0.93 finished: `vm-play-check.sh check <zip> <ruya-pack>` and `helper` on a fresh VM. The packages come from `scripts/ci-samples-linux.sh` in WSL at the image's commit (header of `vm-play-check.sh`); `vm-queue.ps1` can't pass them (RUY-860). If it passes, RUY-100 is proven: comment, and unblock RUY-102/104's children.
2. Image 0.0.94 from HEAD, then `vm-play-check.sh perms` (RUY-851) and `vm-library-check.sh play` (RUY-852), all on RUY-390.
3. `.play` lanes, in order: RUY-863 (high: ruya-play ignores a Flathub `play.*` app), RUY-853 + RUY-864 (PIN gate, mock gate), RUY-856 (Home/detail visuals; UI reviews), RUY-861, RUY-848, RUY-865. Then RUY-101 (runners) and RUY-103 (updates).
4. Dell is on 0.0.92 (`bootloader-update` still red, RUY-24). The owner was asked to try Neverball/Starfighter with a pad; if the pad works from the start, remove the `devices=input` overrides for `org.neverball.Neverball` and `io.github.pr_starfighter.starfighter`.
5. Ask the owner about the old `.claude/worktrees/design-pad-silhouettes-559410` (its usage hooks double Paper Plane's events).

## Owner direction (in force)
- **.play first (2026-11-18):** `.play` lanes before any other goal (memory `play-packages-first`). The two lanes that weren't `.play` (RUY-842, RUY-24) were stopped and are Ready again with their lead reviews.
- **Performance goal (2026-11-18), measure first:** formation RUY-558. RUY-842 (Dell baseline) blocks the tuning tickets. Direct scanout is RUY-783. Not done: `mitigations=off`, a third-party kernel, forced clocks, `isolcpus`.
- RUY-838 game options (design first, after the reset); Code Mode trial after the reset; Steam first-class (RUY-815).

## Concerns (ranked)
1. `.play` USB installs are unproven until 0.0.93's VM run.
2. A `play.*` id is not enough to trust a deployment (RUY-863).
3. D: free space (7.9 GB; builds need about 4 GB per worktree). RUY-862.
4. Godot 3 X11 games (RUY-494), Steam focus (RUY-825/812).

## Process changes in lead-34
- **Lead:** my design notes missed two attack paths (a new game opening the stashed pads; a `play.*` Flathub app spoofing a tier). Reviewers caught both. **Write the hostile case into the ticket's criteria.** I also removed worktrees before their merge gate; the order is gate, then remove.
- **Builders:** none. Two builders' second hand-back was refused by the harness: read the worktree's commits instead of waiting.
- **Tests:** `vm-play-check.sh` fails on any `init_t` AVC during its run (a denied `OpenFile=` is otherwise invisible).
- **Paper Plane:** two transient ECONNRESET/ECONNREFUSED; the retries worked.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-18 (lead-32) | 11ae518..acb7d04 | 2 merged (822, 504); 1 filed (825) | 822: 1 lead fix; 504: round 2 for missing shots | 2207 passed, 0 failed | Dell: RUY-825 diagnosis (hw) |
| 2026-11-18 (lead-33) | acb7d04..4582246 | 6 merged (826, 832, 828, 829, 837, 839) + 1 lead commit; 13 filed | 829: round 2; 1 gate flake | 2216 passed, 0 failed | 0.0.91 boot OK; vm-play-check 12/25 (SELinux) |
| 2026-11-18 (lead-34) | 4582246..HEAD | 4 merged (834, 840, 851, 852) + 2 lead commits; filed 842-865 (performance goal, .play splits, follow-ups); 2 lanes stopped | 834, 840, 852: round 2 (all real: .ref, stashed-pad ACL, origin spoof) | 2216 passed, 0 failed (RUY-840 gate); rust green on 852's merge | 0.0.92: startpad PASS, vm-play-check 20/12 FAIL (SELinux, fixed by ADR-036, unverified); Dell 0.0.92 |
