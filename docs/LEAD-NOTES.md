# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets: stop at 75 % context**). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## State at the end of the 2026-11-07/08 session (lead-3, handoff at ~75 % context)

- **`main` is pushed** (test ALL GREEN, 858 QML + 65 skips) and **nothing is in flight**: no builders running, no worktrees, `git status` clean. Merged since the last notes: T-296 (VM check scripts + `lint-vm-checks`), T-281 (art-colour glow, card sizes, the focus ring now an overlay, rounded AppArt, `Theme.glowPad`). **CI is not verified from this host: the owner confirms the Actions run** (new CI steps: spec lint, boot lint, VM check lint, `qt6-qtbase-private-devel`, `LANGUAGES C CXX`).
- **Images:** `0.0.53` (T-198..T-227) is built, VM-verified and its ISO is on `F:\RuyaOSuyaos-0.0.53-install.iso` (older ISOs deleted). It lacks T-281, T-296's script fixes and T-287. Build `0.0.54` when a worthwhile set has merged (about 20 min image, 17 min disk, 4 min ISO; VM queue: run the checks with fresh boots, the sounds probe and `wake_check` verdicts are open: see STATUS Inbox T-296 line).
- **Dell** (owner's test machine): `192.168.178.109` (`ssh -i ~/.ssh/ruyaos_dev root@...`, DHCP: may change; candidates in `~/.ssh/known_hosts`), RuyaOS 0.0.53 installed; UHD 630 on `i915`, Mesa 26.2.6, the shell renders on the GPU. The owner's Gigabyte G32QC (2560x1440@144) sits behind a **DP-to-HDMI type 1 adapter (165 MHz)** so only 1080p60 is offered: a DisplayPort cable fixes it; the Display service listed a pruned `1920x1080@143.85` (T-287 has the fix and the hint text).

## Process changes this session (owner: "take the lead for the rest")
Short HANDOFF/REVIEW formats; `lint-spec-components.ps1` (every `shell/qml` file named in 04 or on a baseline); `revert-check.ps1 [-Test tst_x]`; `dev.ps1 qml tst_x` (PARTIAL fast mode, never ALL GREEN) and `dev.ps1 docs`; `dev.ps1 test` writes `output\last-green-test.txt`, `push-main.ps1 [-DryRun]` uses it; reviewers run the full test in round 2 only when code changed; visual-only tasks get one test per behaviour plus screenshots; builders keep `output\shell-shots\review` until merged. **Next lever (Opus lead's proposal, not done):** run the QML test files in parallel processes (4 processes: 89 s instead of about 240 s; needs a flakiness audit and a check for state shared on disk); 212 fixed `wait()` sleeps (a 7 s one at `tst_glide.qml:551`); the 19 s sound-theme lint. Not applied (owner): moving worktrees to C:.

## Queued for the next lead, in this order
1. Dispatch builder lanes in the order of the NEXT paragraph in STATUS: `T-297`, `T-290`, `T-291`, `T-285`, `T-286`, `T-293` (rebase on T-296's `vm-power-saving-check.sh`), `T-287` (Dell display finding), ... (first rows of `STATUS-backlog.md`); two lanes, one image build at a time. T-281's Dell check (T-205 frame times with the halo and the picture mask) is a hardware item.
2. The next image (0.0.54) should carry T-281 and the T-287 fix; repeat `vmchain.sh`-style runs (usage needs a fresh boot; display switch needs 2 minutes after boot; the sounds probe needs the XDG fix from T-296).
3. **T-164** (per-profile Wayland sockets, lead, critical path, Dell for the GL test; Opus recommended). It gates multitasking (T-273..T-279, ADR-019 Proposed), T-147, T-165, captures (T-305). Waiting epics (written, owner decisions in STATUS): multi-controller T-263..T-268 (ADR-017 Accepted), multitasking T-273..T-279, game data hub T-302..T-308 (ADR-020 Proposed, external drives included), saves manager T-309..T-311, first-party apps T-248.., `.play` T-228... **T-270 (Epic Games Store) is parked by the owner: do not plan or spike it until they raise it.**
4. T-282 (lead): design decisions queue (glass text contrast, theme looks, dialogs, Tab).

## Owner-level items (STATUS "Open owner decisions" has the text)
ADR-018 Epic (parked), ADR-019 gesture and background apps, ADR-020 hub permissions/shared ROM folder/captures local/saves stay on the console, pad-glyph licence and boot wordmark, ControllerCons licence (OFL file vs homepage text; ask the author first), telemetry, Dolby/DTS, ADR-015/016, HDR/VRR. Dell look-at list: one paragraph in STATUS (add: DisplayPort cable for 1440p144).

## Concerns (ranked)
1. CI unverified (Rust 1.92 clippy gate is T-298). 2. The Wayland idle-inhibit runtime with a real client (mpv) and the DPMS wake by key are unverified. 3. The lead should be Opus for T-164 (this session ran on Sonnet 5.5). 4. STATUS.md about 17 KB (budget about 10): keep Inbox lines short and let a planner triage at 5 lines. 5. Context cost: HANDOFFs are short now; keep it so.

## Host facts learned
- WSL through PowerShell: `$` in `bash -c "..."` is mangled; put commands in a script file and run `wsl -d FedoraLinux-44 -- bash /mnt/c/...` (Git Bash rewrites `/mnt/...`). A heavy dnf can drop the connection (WSAETIMEDOUT): rerun. WSL background processes die with the session. An image build takes about 20 min, make-disk about 17 min, the ISO about 4 min (vhdx on F:).
- A WSL compile of only the static `ruyacompositor` target does not link; the link failure (`LANGUAGES CXX` ignoring the wayland-scanner `.c`) appeared only in the image build. WSL has `qt6-qtwayland-devel qt6-qtbase-private-devel qt6-qtdeclarative-devel qt6-qtmultimedia-devel qt6-qttools-devel qt6-linguist qt6-qtshadertools-devel qt6-qtsvg-devel cmake ninja-build gcc-c++` installed.
- QEMU virtio GPU has no `/sys/class/graphics/fb0`: use `/sys/kernel/debug/dri/*/state` (`mode:`). Qt eglfs follows `QT_QPA_EGLFS_KMS_CONFIG` with names like `Virtual1`/`HDMI1` and `"WxH@Hz"` (proved).
- VM driver pattern used this session: `scratchpad\vmrun.sh <script> [args]` (scp + ssh as root with the dev key) and `scratchpad\vmchain.sh` (the whole queue, summary in `scratchpad\chain\summary.txt`); both are in the session scratchpad and are easy to recreate. `vm-usage-check.sh` needs an empty profile store; after a failed run reboot the VM.
- A subagent's long worktree `shell\build-win` costs ~250 MB-4 GB: remove worktrees right after merging. D: had been at 99 %; the owner freed space.
- Older notes (SELinux/PID 1 pipes, `bootc usroverlay` loop, `busctl --json=short`, `QSettings`, heredocs and backslashes) are in `image/CLAUDE.md`, `docs/dev-setup.md` and git history of this file.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-06/07 (build loop) | e73e081..e7f7aff | T-200, T-214, T-206, T-204, T-209, T-208, T-205 merged | 6 of 7 needed a round 2 | 544 QML + 50 skips | `0.0.48-lead`: queue all PASS; `0.0.49` ISO verified |
| 2026-11-07/08 (lead-3) | 273d3bc..d07a52b | T-247, T-198, T-271, T-272, T-202, T-269, T-227 merged | 5 of 7 needed a round 2; real defects: Qt screen names, start limit, revert not restarting (T-198), a guard test that could not fail (T-247), 5 compile/logic blockers in Linux code (T-202), hostile WAV hang/crash (T-227), lint-weak rollback guard (T-269); lead found `LANGUAGES C CXX` in the image build and a default-mode bug on the VM | 829 QML + 63 skips | `0.0.51`/`0.0.53` queue PASS (see above), ISO `0.0.53` checked |
