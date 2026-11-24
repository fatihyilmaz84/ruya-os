# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2); clean up every merged worktree with `scripts\worktree-done.ps1`**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-47 (Opus, 2026-11-24; the owner was present most of the day)

- **Owner rules this week (memory `quick-wins-until-reset`):** until the weekly reset **2026-11-27 18:00 UTC** builders take **simple quick-win tickets only**, Sonnet, **two lanes even past 70 % weekly** (owner: "do two lanes"). RUY-28, the ROM door chain, spikes and architect audits wait. **No new image until the owner says so** ("wait with the new image for now"; 0.0.108 was started and stopped).
- **Review range:** 35fc3b50..HEAD (every merge had a reviewer APPROVE; UI ones also design/UX). **Paper Plane `changes` cursor:** 8767.
- **Done (19 merges):** 722, 1136 + 1159 + 1170 (top bar: no shade, per-item ink, the bell at the tray's left on its own pill and still the last LB/RB section, owner), 502 (Button test readings), 602, 928, 1164, 919 (one `useMockServices()`), 683, 669, 717, 767, 763, 1171, 1173, 709 (anchoredPattern + `lint-regex-anchors.ps1`); 842 (Dell perf baseline on 0.0.106: STK 60 FPS 0 stutters, UT 48 FPS p99 34 ms 40 stutters) and **157 (Platform1: check/identity/deputy all PASS in the 0.0.107 VM)**.
- **ROM Manager: ADR-048 Accepted** (architect amendments A1-A9 + owner decisions 2026-11-24: no BIOS in the OS, libretro-database, libretro-thumbnails, admins delete, kids see all, one shared collection). Build order: RUY-1152 spike → 1153 (+141) + 1154 → 1155 → picker → ROM Manager (118); 1156 import helper; 1157 RUY-453 contract. Canvas BIOS boards are void.
- **Image 0.0.107** at 35fc3b50 (lead-46 merges only); the Dell runs it (rollback 0.0.106; `bootloader-update.service` fails = known shim/CA 2023, RUY-24). Today's merges are **not** in any image.

## In flight at handoff
- Nothing building. **RUY-722** (round 2 dropped the unreachable last-admin note by lead ruling; the role/PIN fact row stays) was approved and merged right after this file; its gate result is in the next lead's first `git log`/ticket (if the gate was red, the merge is reverted and the ticket reopened).
- Leftover worktrees: `RUY-28` (round 2 waits for the reset), `.claude/worktrees/design-*` (merged; another session's, leave).

## Do first
1. Check RUY-722's gate (above). Then the quick-win queue: RUY-760, 675, 423, 480, 634, 1165, 1160, 1175, 1169; RUY-725 last (may be fixed already).
2. **When the owner allows the image:** 0.0.108 from main, then the VM queue on RUY-390 (lead-47 comment): `vm-update-check.sh download` (needs the update drill: a VM tracking the WSL registry with a newer image), RUY-602's Dell journal line (`dell-perf-bench.sh` relay step), RUY-717's delete journal line; `dell-update.sh 0.0.108`. The owner will see the new top bar and bell then.
3. **After the reset:** RUY-28 round 2 (fresh Opus builder, plan in its comments); ROM door chain from RUY-1152; Platform1 RUY-1130, 1131, 1137 (+1145); **RUY-781** (perf overlay GPU % and watts via a bus-less root helper, shape on the ticket; owner wants it).

## Concerns (ranked)
1. **Load flakes:** six found and fixed today; open: RUY-1169 (tst_bluetooth), RUY-880 (vm-notifications fixture, ~26 min loaded), RUY-1167 (Wii U, keep the log). Two lanes plus a gate load the machine; a red gate on an unrelated test: rerun the file alone, then the gate, and file the flake.
2. **Instruction budgets:** root `CLAUDE.md` 11.0 KB (budget ~10), `services/CLAUDE.md` 9.3 KB (~7): prune next session (the "Shared homes" paragraph could move to a reference file).
3. RUY-1141: Flatpak triggers fail inside ruya-store.service.

## Process changes in lead-47
- **System:** `lint-regex-anchors.ps1` (RUY-709, a mistake at 10 sites); VM queue signs a profile in for the platform/installations checks (lasting fix RUY-1163: `# needs: profile` lines). **Lead:** each ticket got a "Lead review before the build" against main; three caught a wrong shape before dispatch (RUY-763's `tx`, RUY-709's lint, RUY-1170's LB/RB wrap); builders' honest partials (RUY-683, 722) were ruled on, not forced. A `pkill -f` pattern killed its own shell: match a pid file or the exact process name. **Tests:** fuzz bounded per case (RUY-1171); shard self-check limit measured (RUY-928). **Paper Plane:** none.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-23 (lead-44/45) | e6c8d60..22b22f73 | 5 merged + design merge, RUY-157 split, 1 lead fix (957) | round 2+ on 1063, 1098, 1099 (x2) | 2384 QML, 0 failed | 0.0.105 VM 17/17; 0.0.106 building |
| 2026-11-23 (lead-46) | 22b22f73..35fc3b50 | 7 Done, 1 spike, architect focus audit, ADR-047 | round 2 on 137, 1129, 29: all real; Linux-only crash at push | 2435 QML + ~2760 Rust, 0 failed | 0.0.106 VM 18/22; Dell on 0.0.106 |
| 2026-11-24 (lead-47) | 35fc3b50..HEAD | 18 merged, 157 + 842 Done, ADR-048 + architect review, 6 owner answers; filed 1151-1175 | round 2 on 1170 (stray disc, duplicate walk), 669, 722 (dead UI): all real | 2465 QML, 0 failed; Linux CI job PASS at push | 0.0.107 built; VM 7/8 checks PASS (update download needs the drill); Dell on 0.0.107 |
