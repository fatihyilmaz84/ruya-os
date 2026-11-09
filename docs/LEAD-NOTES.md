# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. History lives in the STATUS session log and git.

## State at the end of the 2026-11-09 session (lead-6, Opus, handoff at about 40 % context on the owner's request: keep lead sessions short)

- **`main` is pushed** (see the last commit), `dev.ps1 test` ALL GREEN (1001 QML + 77 skips, Rust green). CI not verified from this host (the owner pastes the Actions result).
- **Merged and reviewed:** T-164 (per-profile Wayland sockets; review fix: a hidden app still counts as running for updates), T-322 (output policy, saved choice, ListOutputs/SetOutput/TestOutput), T-347 (card profiles, 100 % first volume once), T-285 (hint bar truth; interim D-pad hint rule in 04 §3.7). **Lead work:** T-358 done: the image builds Qt's linux-dmabuf compositor plugin from the installed SRPM with our v4 feedback patch (`image/qt/`, stage `qt-dmabuf`, version guard); STK through the shell now renders on the Dell's UHD 630 at about 15 % CPU (was llvmpipe at 563 %). T-355 first pass recorded. T-357 (headphone virtual surround, owner's HRTF Database pointer) written.
- **Images:** 0.0.57 and 0.0.58 VM-verified; **the Dell runs 0.0.58** (oci-archive route; `scripts/image-chain.sh <ver> oci` writes the archive). No ISO built (none needed).
- **No branches or worktrees open.** No builder in flight.

## Next, in this order
1. **Triage the Inbox** (STATUS is 21 KB, budget about 10 KB): fold lines into tasks or move them to `STATUS-parked.md`.
2. **B-007, sound for profile apps**: STK has no sound device (no Pulse/PipeWire for `ruya-p1`). The next blocker for real games; probably lead work (ADR-010: PipeWire runs as `ruya-shell`; give profile apps a pulse socket per profile, like ADR-023's Wayland sockets).
3. **T-355 second pass on the Dell** with the owner at the TV: race frame times, pads (hotplug, split screen, rumble), suspend with the game running, save isolation; and the `app-flatpak-*.scope` accounting gap (Inbox).
4. Builder lanes from `STATUS-backlog.md` (T-348 Audio output pane is next on the audio line; T-332/T-333 drive format; T-263.. multi-controller).
5. The VM queue items (STATUS) at the next image build.

## Dell (192.168.178.109, root with `~/.ssh/ruyaos_dev`; `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`; standing permission in CLAUDE.md, report `Dell: ...`)
0.0.58 (rollback 0.0.57); profile p1 "Fatih" (admin, has a PIN: never type it; ask the owner to sign in); STK 1.5 in the system Flatpak installation; one Intel AX201 Bluetooth adapter, two DualSense bonded. Scripts that worked this session (in WSL, `MSYS_NO_PATHCONV=1 wsl.exe ... bash <script>` from the Bash tool, or Git Bash rewrites `/mnt/c`): launch through Session1 as `ruya-shell` (`Launch ss net.supertuxkart.SuperTuxKart p1`), read `journalctl _UID=1000`, `top`.

## Concerns (ranked)
1. Profile apps have no sound (B-007). 2. Builders end their turn on a background test and never send a HANDOFF (T-322, T-285; the rule in `ruya-builder.md` was added mid-session and T-285 still stalled): if it recurs, the lead runs the test itself, as done twice. 3. The dmabuf plugin uses private Qt API: every Fedora Qt update needs the image rebuilt (the build refuses a mismatch, which is the intended failure); `external_only` modifiers, explicit sync (NVIDIA), multi-GPU are open. 4. Load-flaky QML tests: `tst_battery_cluster` narrow-room chip, `tst_settings::test_a_hidden_focused_row_hands_the_focus_on`. 5. CI unverified.

## Host facts learned
- Git Bash rewrites `/mnt/c/...` arguments of `wsl.exe`: prefix `MSYS_NO_PATHCONV=1`. A worktree made by Git for Windows has a `D:/` gitdir Linux git cannot read (image-chain.sh says so instead of failing).
- `vm-goto.ps1` needed the time-zone wizard step (fixed); `vm-session-check.sh check` needs `vm-session-probe.qml` copied too (now fails clearly).
- Image timings: build 10-23 min (a Containerfile change rebuilds from the base), qcow2 17 min, oci 7 min, Dell switch + reboot about 5 min. `make-disk.sh` must run alone (WSL memory).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-07/08 (lead-3) | 273d3bc..d07a52b | T-247, T-198, T-271, T-272, T-202, T-269, T-227 | 5 of 7 round 2 | 829 QML | `0.0.51`/`0.0.53` PASS |
| 2026-11-08 (lead-4) | d09da99..01f31ca | T-290..T-324 (13) | 8 of 13 round 2; FLAC sample-rate-0 bed bug found | 931 QML | `0.0.54` PASS |
| 2026-11-08/09 (lead-5) | 01f31ca..dae44c0 | T-330, T-336, T-335, T-337, T-334, T-356, T-349, T-331 | most needed rounds; the dead-end focus bug found with the owner | 987 QML + 77 skips | `0.0.55`, `0.0.56` PASS |
| 2026-11-09 (lead-6) | c5e2d67..main | T-164, T-322, T-347, T-285, T-358 (lead) | T-164 hidden app vs updates (lead fix); T-322 silent-pass VM check; T-347 executor blocking and lost signals; T-285 untested hint; 3 VM-script drifts | 1001 QML + 77 skips | `0.0.57`, `0.0.58` PASS; Dell STK on GPU |
