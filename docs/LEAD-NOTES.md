# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2); clean up every merged worktree with `scripts\worktree-done.ps1`**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-39 (Opus, 2026-11-21, overnight; the owner asked for .play first; the Dell was offline)

- **Review range:** 6a4b709f..HEAD (all reviewed this session). **Paper Plane `changes` cursor:** 7251.
- **Merged and Done (15):** RUY-35 (Steam uses GE-Proton), 36 (developer chapter windows-games.md + hello-runner sample + manifest lint), 854 (.play apps in the permission list), 37 (Wine11, licence texts shipped, retention test), 923 (new crate **ruya-flatpak**: Flatpak argv, app-id rule, OARS table; Play1.Remove resets the override), 959 (Library1 ListRunners, per-profile runner choice, ResolveRunner; About reads it), 969 (Proton outside Steam: SteamAppId/SteamGameId=0, PWD), 902 (vm-play-check launch, launch-windows), 904 (session passes `--runner`, asked before the session lock), 914 (Inspect serves signer_name, age_label), 925 (Uninstall on a .play page; UninstallConfirm owns the rule), 980 (Proton checks on x11-run's display, file marker), 905 (Compatibility screen; Library1 resolve codes + fallback; dimmed ChoiceRow), 911 (new crate **ruya-fs**: openat no-follow walk; launcher and session use it), 804 (CapsText: caps in the UI language). Lead fixes: RUY-891 flake, three `review:` commits, `scripts/worktree-done.ps1` (RUY-862 part 1). Last gate on main 3875b06a: **2357 passed, 0 failed**.
- **Images:** 0.0.97 (24/28) and **0.0.98** (main eba76e75): **26 of 30 PASS**. Proven on 0.0.98: Proton through vm-runner-check on display :0 (969+980), the sample, Wine11 x86_64, launch, remove (override reset), store perms. **Failing, filed high and Ready:** RUY-999 (lead: a .play Windows game crashes on GE-Proton in `launch-windows`: the top .play problem), RUY-1000 (Wine11 i386 cmd.exe), RUY-1001 (library runners: sample install invalid-package), RUY-1002 (perms: metadata-unchanged step). `vm-runner-check steam` needs Steam installed by hand. Detail in RUY-390's comments.
- **Lead decisions:** ruya-flatpak and ruya-fs as the shared homes (services/CLAUDE.md "Shared homes"); RUY-905's options follow 05 §6.2 (Bundled only with a bundled copy) and the shell translates resolve codes; no profile ids in QML; rustix accepted for ruya-fs; one licence limit (256 bytes) for play.json and runner.json; protonfixes stays on.

## In flight
Nothing. No worktrees, no running builders. D: 62 GB free. WSL vhdx 68 GB (compact not run after 0.0.98: run `wsl --manage FedoraLinux-44 --compact` when nobody needs WSL for ~2 h, RUY-957).

## Next (.play path, RUY-780: 44/60 done)
1. **RUY-999** first (lead, VM debugging: the launcher's log in `${data}/.ruya-play`, the unit's journal, PROTON_LOG; a debugging subagent with the VM worked well for RUY-980). Then 1000, 1001, 1002 (builders), image 0.0.99, VM queue.
2. Ready .play follow-ups: RUY-995 (high: ruya-fs remove regression on a 0o000 folder), 989, 982, 968, 963, 973, 993, 996.
3. Then the owner's next goal: **RUY-956 "Steam is first-class"** (owner 2026-11-21).
4. The inbox holds ~190 tickets: **a planning pass is overdue** (owner wishlist 931-955 needs canvases).

## Concerns (ranked)
1. A .play Windows game has never launched end to end (RUY-999).
2. Disk: four Rust lanes filled D: to 0 twice; always `worktree-done.ps1` after a merge gate; RUY-862's dev.ps1 disk guard is still open.
3. Long-lived branches collide in vm-*.sh, test-vm-checks.sh, dev-setup.md: have builders `git merge main` before review (done 4 times tonight).
4. Flakes under load: RUY-880 (notifications fixture, 4 times), RUY-992, the devkitPro git crash (RUY-905 review).

## Process changes in lead-39
- **Lead:** `scripts\worktree-done.ps1` replaces hand cleanup (LEAD.md 4b.6). A round past ~300k tokens went to a fresh builder with the round list on the ticket (902, 905): it worked. A stalled builder ("waiting on background work") with its round committed went straight to review (902, 904, 804). VM failures went to a debugging subagent with a booted VM (RUY-980: cause found in 30 min).
- **Tests:** a check that SKIPs on a missing precondition can hide a failure: the runner checks now FAIL unless nobody is signed in (RUY-980 review).
- **Paper Plane:** an `update` batch entry takes no `formation` (use `formation add`); creating a ticket without "## Acceptance criteria" in Ready is refused (fine, but the error comes after the create is attempted).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-19/20 (lead-37) | 09c9c08..58bb188 | 11 tickets merged + 4 lead review commits; ADR-037/038 | rounds 2-3 on 855, 898, 900, 901, 890, 886/887 (all real) | 2275 passed, 0 failed | RUY-899 spike ALL PASS (0.0.96) |
| 2026-11-20/21 (lead-38) | 58bb188..6a4b709 | 5 tickets merged + 4 lead review/docs commits | rounds 2-3 on 816, 744, 909, 35 (all real) | 2305 passed, 0 failed | 0.0.97 failed twice (musl; F: full) |
| 2026-11-21 (lead-39) | 6a4b709..HEAD | 15 tickets merged + 3 review commits + RUY-891 + worktree-done.ps1; filed 959-1002 | round 2+ on 36, 854, 37, 969, 902, 904, 914, 925 (x2), 980, 905 (x2), 804: all real (licence texts, a lock stall, a false-green SKIP, a relaunch bug) | 2357 passed, 0 failed | 0.0.97 24/28; 0.0.98 26/30 (4 filed) |
