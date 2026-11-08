# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets: stop at 75 % context**). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## State at the end of the 2026-11-08/09 session (lead-5)

- **`main` is pushed through the last push of lead-5** (check `git log origin/main..` first). CI is still **not verified from this host** (the owner pastes the Actions result; CI uses Rust 1.92 clippy and Fedora Qt qmllint).
- **Merged by lead-5, all reviewed:** T-330 (audible ambient bed, checker rules), T-336 (Bluetooth with several adapters; the review found Pairable on the wrong adapter), T-335 (INFO logging), T-337 (inputd releases keys; the review found an unseen-release bug), T-334 (two-pad tests + same-name tails; `shownName` fixed for `%n` aliases), T-166 (suspend verified on the Dell; the marker `/usr/share/ruyaos/suspend-verified` ships in the image), the T-262 mechanism (udev rule `71-ruya-bluetooth-wakeup.rules`; a PS press wakes the Dell, owner confirmed), the planning and decision batches (T-331..T-355, ADR-015/016/019/020/022 Accepted, owner decisions of 2026-11-08 recorded in `STATUS-parked.md`).
- **Images:** `0.0.55` and `0.0.56` built and VM-verified (boot, sounds, usage, session, library, store, bluetooth incl. two-adapter fake, boot, display, storage, inputd; ISO install check PASSED for both). Build speed with the WSL disk on F: and builders testing at the same time: image 15-22 min, qcow2 18 min, ISO 19 min (not 4). ISO `F:\RuyaOS\ruyaos-0.0.56-install.iso`. **The Dell runs 0.0.56** (upgraded with `podman save --format oci-archive` in WSL, `scp` to `/var/tmp`, `bootc switch --transport oci-archive /var/tmp/ruyaos-0.0.56.oci`, reboot: 5 minutes, no owner needed; 0.0.55 stays as the rollback deployment). 0.0.56 lacks: the udev rule (it is also in the Dell's `/etc/udev/rules.d`), T-334, T-356.
- **In flight at the handoff** (worktrees in `D:\dev\RuyaOS-worktrees\`): see "In flight" below, updated at the end of the session.
- **Owner instruction (2026-11-09): no new task files or dispatches; follow-ups are Inbox lines only; the owner continues tomorrow.**

## In flight (fill from the final state)
(see the last edit of this file)

## Next, in this order
1. Review and merge what is in flight (T-356 focus bug first, then T-331 round 2, T-349, T-164). Each in its worktree branch; `ruya-reviewer` (+ UX/design reviewers on UI diffs) before merging; then `dev.ps1 test` on main, `scripts\push-main.ps1`.
2. Build image `0.0.57` (WSL: `scratchpad` script like `build056.sh`; one build at a time; no heavy tests during `make-disk`), VM queue (`vm-storage-check.ps1` incl. `scan`, `vm-devices-check.sh twopads|inputd|bluetooth`, T-164's checks), ISO check, OCI route to the Dell, `scripts\free-space.ps1`.
3. **T-355** STK acceptance test on the Dell after T-164 (`net.supertuxkart.SuperTuxKart` is installed on the Dell, system installation; launching by hand as `ruya-p1` fails with "No available video device" until T-164). Then T-349 results (Settings/Store slowness; the owner says the Store page is also slow with the dummy items: measure), the multi-controller epic T-263.., removable-drive format T-332/T-333, Xbox adapter research T-354, platform API T-350..T-353, first-party apps T-248.., T-322/T-347/T-348 (audio output policy, first output starts at full volume once, picker), T-262 UI part, T-338 (Dell repro of the 21 s pad drop, needs T-335 logs: now available on the Dell).
4. Backlog order: `STATUS-backlog.md`. STATUS is 15 KB (budget about 10-14): triage the Inbox at 5+ lines.

## Dell (192.168.178.109, root with `~/.ssh/ruyaos_dev`; `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`; standing permission in CLAUDE.md, report `Dell: ...`)
- 0.0.56, one Bluetooth adapter (Intel AX201, hci0, USB 1-14), two DualSense bonded (24:A6:FA:AD:DD:EA original, 88:03:4C:3F:60:E1), sink volume was set by the owner, STK + runtime installed in the system Flatpak installation (not part of any image).
- Runtime-only leftovers (gone at reboot): the compositor drop-in `/run/systemd/system/ruya-compositor@tty1.service.d/91-inputlog.conf` (Qt input logging), `/tmp/cap*.py`, `/tmp/btmon-wake*.btsnoop`, `/var/tmp/ruyaos-0.0.56.oci` (2.5 GB, can be deleted after the next upgrade).
- Suspend: `rtcwake -m mem -s 20` works (4 cycles clean); a PS press during sleep wakes the machine (adapter wakeup enabled by the udev rule); after a plain resume the pad reconnects about 1 s after a press (btmon proved it).

## Owner-level items (STATUS "Open owner decisions" has the rest)
Decided 2026-11-08: ADR-015 (runtime extension + RuyaKit), ADR-016 (no browser first), ADR-019, ADR-020, ADR-022, volume high once, telemetry consent, Xbox adapter: investigate (T-354, legal question stays the owner's). Still open: ADR-018 Epic (parked), pad-glyph licence and wordmark, ControllerCons licence, Dolby/DTS, HDR/VRR, update size.

## Concerns (ranked)
1. **Focus loss on pages** (T-356): found on the Dell; the generic fix must hold for every `SettingsPane` page. 2. CI unverified. 3. Four writers touched `SettingsPane`/`StoragePane`/`Shell.qml` at once (T-349, T-356, T-331): expect merge conflicts; merge T-356 first. 4. Load flake `tst_battery_cluster::test_the_chip_shrinks_to_plus_n_in_a_narrow_room` (nav gap 23 against 24 px under CPU load; passes alone). 5. The builder of T-331 left stale hung `cargo`/`ruya_devices` test processes it could not kill (PIDs 9924, 69752, 87328, 72840, harmless; the owner may kill them; I did not, because the request came from a builder whose sandbox had denied it). 6. The lead model was Sonnet 5.5 again; T-164 is Opus-built.

## Host facts learned
- WSL through PowerShell: put commands in a script file and run `wsl -d FedoraLinux-44 -- bash /mnt/c/...`; `pkill -f name` over ssh kills the ssh shell itself (match by pid). WSL background processes die with the session. `date -u` in the Bash tool is UTC; the Dell and Windows run CET (UTC+1).
- `scp` of the OCI archive to the Dell takes 3.5 minutes over LAN; `bootc switch --transport oci-archive` only needs the 5 missing layers.
- Older notes (SELinux/PID 1 pipes, `bootc usroverlay`, `busctl --json=short`, `QSettings`, heredocs and backslashes) are in `image/CLAUDE.md`, `docs/dev-setup.md` and the git history of this file.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-06/07 (build loop) | e73e081..e7f7aff | T-200, T-214, T-206, T-204, T-209, T-208, T-205 merged | 6 of 7 needed a round 2 | 544 QML + 50 skips | `0.0.48-lead`: queue all PASS; `0.0.49` ISO verified |
| 2026-11-07/08 (lead-3) | 273d3bc..d07a52b | T-247, T-198, T-271, T-272, T-202, T-269, T-227 merged | 5 of 7 needed a round 2; real defects: Qt screen names, start limit, revert not restarting (T-198), a guard test that could not fail (T-247), 5 compile/logic blockers in Linux code (T-202), hostile WAV hang/crash (T-227), lint-weak rollback guard (T-269) | 829 QML + 63 skips | `0.0.51`/`0.0.53` PASS, ISO `0.0.53` checked |
| 2026-11-08 (lead-4) | d09da99..01f31ca | T-290..T-324 (13 tasks) | 8 of 13 needed a round 2: PIN title lost in Turkish, Guide key swallowed by a chip, a VM check that could never pass, dark glyph on glass; lead found the FLAC sample-rate-0 bed bug and lint-text skipping lone-CR files | 931 QML + 73 skips | `0.0.54`: usage 33, session 37, store 70, library 34, bluetooth 21, boot 21, display 40, power-saving |
| 2026-11-08/09 (lead-5) | 01f31ca..(see git) | T-330, T-336, T-335, T-337, T-334 (+ T-166, T-262 mechanism) merged | T-336 and T-337 needed a round 2 with real defects (Pairable on the wrong adapter; unseen release lifting another pad's key); T-331 round 2 (unbounded listing, Eject vs scan); lead found the dead-end focus bug on the Dell with the owner (T-356) and that inputd was innocent | 947+ QML + 76 skips | `0.0.55` and `0.0.56` queues PASS, both ISO checks PASSED |
