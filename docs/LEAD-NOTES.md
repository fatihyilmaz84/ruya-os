# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2); clean up every merged worktree with `scripts\worktree-done.ps1`; a Sonnet lead escalates hard-to-undo decisions to an Opus agent ("Model tiers")**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-48 (Opus, 2026-11-24; the owner was present all evening, went to sleep at 23:45 and put the PC to sleep)

- **Owner rules this week (memory `quick-wins-until-reset`):** until the weekly reset **2026-11-27 18:00 UTC** only simple quick-win tickets, Sonnet, two lanes. **The quick-win Ready queue is empty** (next lead plans more from the 246 `inbox` lines, e.g. RUY-1160 (a design call, see its comment), 1180-1182 done/filed, 1185). Run the next lead on **Sonnet high** (owner, 2026-11-24).
- **Review range:** b839c92a..HEAD (every merge reviewed: ruya-reviewer, or a lead review on small diffs). **Paper Plane `changes` cursor:** take the latest at start (last read 8771).
- **Done (14):** 761 (Options-menu rule in 02 §1.7 / 04 §5 + screen audit), 760, 480 (round 2), 634, 675, 1175 (lead fix), 1169, 1165, 725, 423 (honest partial: not reproducible alone; the step names the stalled link), 1179, 701, plus RUY-1182 **approved, not merged** (see In flight). Instruction prune: services/CLAUDE.md 9.3 -> 5.9 KB (`services/PATTERNS.md`), root 10.7 KB.
- **Owner decisions today:** RUY-1176/1177/1178 (Options menu on Settings rows) wait for the reset. **RUY-1183 players' Hub** (high; replaces RUY-687): player 2-4's Guide opens the full Hub on their pad, pausing the game, with Play as <name>, Leave the game, Change controller, **and Power and Close game with a confirm naming player 1's running game**; Home, Switch to, Settings, Notifications, Performance hidden; edge cases in its comments. RUY-132 got the multi-profile memory notes (owner's time-based close idea is an open question there). LEAD.md: Sonnet lead escalates hard decisions to Opus.

## In flight at handoff
- **RUY-701** merged (178c8fff), merge gate **GREEN** (2485 passed, 0 failed), worktree removed.
- **RUY-1182** approved (f3e887f5, worktree `D:\dev\RuyaOS-worktrees\RUY-1182`): merge it, gate (the builder's green run covers it), Done, remove the worktree.
- **Image 0.0.108 at 1a01958b: `build` PASSED (71 min), stopped in `make-disk` by the PC's sleep.** Resume: `wsl -d FedoraLinux-44 -- bash -lc 'cd /mnt/d/dev/RuyaOS && SKIP_BUILD=1 scripts/image-chain.sh 0.0.108 oci'` (only if the built image is still in WSL; else a full chain from HEAD). Then the VM queue (below), `dell-update.sh 0.0.108`, `free-space.ps1`.
- **Unpushed:** main is ahead of origin (lead-48 commits after 3aa6e7e9). Push with `push-main.ps1` after the gates.
- Leftover worktrees: `RUY-28` (round 2 after the reset), `.claude/worktrees/design-*` (another session's, leave).

## Do first
1. The two gates/merges above, push. 2. Image + **VM queue on RUY-390**: the default list plus `vm-store-check.sh` (RUY-634, changed script, never run), the RUY-675 watchdog drop-in try, RUY-717's delete journal line, `vm-update-check.sh download` (needs the update drill); **RUY-666**: on that VM find who starts `accounts-daemon` (likely Flatpak's malcontent D-Bus activation; masking may break installs) and plan the ticket. 3. **Dell:** `dell-update.sh 0.0.108` (also clears the hung Monster Boy, see RUY-1186), then **RUY-1184** (the controller matrix the owner asked for: Steam/native/Wine, Xbox-only vs DualSense-aware, Steam Input on/off, double input) and read RUY-449 with it.
4. **After the reset (Opus planning session):** RUY-1183 lead review + design note; RUY-1176 -> 1177/1178; RUY-28 round 2; ROM chain from RUY-1152; Platform1 1130/1131/1137; RUY-781; RUY-1186 (thaw with no frame).

## Concerns (ranked)
1. **RUY-1186:** a game frozen 71 min under the Hub (Monster Boy, Proton) spun at 100 % after Resume with no frame; `hub-resume firstFrame=timeout` is logged and nothing acts on it. Owner question inside: a limit or warning for long Hub pauses.
2. Steam double input with Steam Input on is unverified (RUY-1184, RUY-44's steam mode is the structural fix).
3. Instruction budgets: shell/CLAUDE.md 7.6 KB (~7), root 10.7 KB (~10).
4. RUY-1187: DRM page-flip error spam on the Dell.

## Process changes in lead-48
- **System:** `dev.ps1 docs` runs the translation and bus-policy self-checks (RUY-1182); one test-name parser for `qml`/`shots` (RUY-725); pad-name lint (RUY-1165). **Lead:** one shots lane at a time (parallel shots collide, RUY-682); reproduce a tooling bug before dispatch (RUY-725 was real only in-process); LEAD.md "Model tiers": Sonnet lead + Opus agent for hard calls. **Tests:** two load flakes fixed at the root (RUY-1169 hold, RUY-423 named links). **Paper Plane:** `create` with a blocked rule returns an id that does not exist (RUY-1184 first attempt): file an issue.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-23 (lead-46) | 22b22f73..35fc3b50 | 7 Done, 1 spike, architect focus audit, ADR-047 | round 2 on 137, 1129, 29: all real; Linux-only crash at push | 2435 QML + ~2760 Rust, 0 failed | 0.0.106 VM 18/22; Dell on 0.0.106 |
| 2026-11-24 (lead-47) | 35fc3b50..b839c92a | 18 merged, 157 + 842 Done, ADR-048 + architect review, 6 owner answers; filed 1151-1175 | round 2 on 1170, 669, 722: all real | 2465 QML, 0 failed; Linux CI job PASS at push | 0.0.107 built; VM 7/8; Dell on 0.0.107 |
| 2026-11-24 (lead-48) | b839c92a..HEAD | 13 merged + 1 approved, 761 spec + audit, 5 owner decisions; filed 1176-1187 | round 2 on 480 (silent drop), 761 (2 spec contradictions): all real | 2485 QML, 0 failed; Linux CI PASS at 3aa6e7e9 | 0.0.108 build PASS, disk/VM/Dell not run (PC slept) |
