# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. History lives in the STATUS session log and git.

## State at the end of the 2026-11-09 session (lead-5, handoff at 61 % context)

- **`main` is pushed through `dae44c0`**, `dev.ps1 test` ALL GREEN (987 QML + 77 skips, Rust green). CI is **not verified from this host** (the owner pastes the Actions result; CI uses Rust 1.92 clippy and Fedora Qt qmllint).
- **Merged by lead-5 (all reviewed):** T-330, T-336, T-335, T-337, T-334, T-166 (suspend verified, marker in the image), T-262 mechanism (udev wake rule), **T-356** (the focus-loss dead end the owner hit on the STK Activity screen: a covered page's buttons pulled the window focus into the hidden page; plus a narrower safety net in `Shell`), **T-349** (lazy Settings panes/modals, page-open probe; Dell A/B still to run), **T-331** (what RuyaOS finds on a removable drive), the planning and decision batches (T-331..T-356; ADR-015/016/019/020/022 accepted, owner decisions in `STATUS-parked.md`).
- **Images:** `0.0.55`, `0.0.56` built and VM-verified (ISO checks passed). **The Dell runs 0.0.56** (does NOT have T-356/T-349/T-331/T-334 shell fixes: the STK Activity dead end is still there). Update route (about 5 min, no owner needed): in WSL `podman save --format oci-archive -o /mnt/f/RuyaOS-tmp/x.oci localhost/ruyaos:dev`, `scp` to `/var/tmp` on the Dell, `bootc switch --transport oci-archive /var/tmp/x.oci`, `systemctl reboot`. **ISO only when needed (owner, 2026-11-09)**: see `docs/dev-setup.md` "When to build the ISO"; latest ISO `F:\RuyaOS\ruyaos-0.0.56-install.iso`.
- **Owner instruction: no new task files; follow-ups are Inbox lines only; at most TWO builder lanes (weekly usage 54 %: one lane at 70 %).**

## In flight (the only open branch)
- **T-164** per-profile Wayland sockets (the critical path), branch `t/T-164-wayland-sockets` commit `4d7a433`, worktree `D:\dev\RuyaOS-worktrees\T-164`: design in **ADR-023** (`/run/ruya-wayland/ruya-<id>`, owner ruya-shell, 0600 + ACL for the profile user, peer-uid `AppGate`, `SDL_VIDEODRIVER=wayland`). Host test green. **The image 0.0.57 built in WSL (`localhost/ruyaos:dev` = 0c6bc410c343) but it predates T-356/T-349/T-331: rebuild after merging main into the branch.** Left: merge main into the branch, `ruya-reviewer` (+ UX/design if UI), `make-disk.sh qcow2`, `smoke-test.ps1 -Keep`, `vm-goto.ps1 home`, `vm-session-check.sh display` + screenshot (Outcome 'Next steps'), merge, then the Dell STK acceptance (**T-355**, STK `net.supertuxkart.SuperTuxKart` is installed on the Dell in the system installation). **Limit (B-003):** Fedora's Qt has no `linux-dmabuf-unstable-v1` plugin: GL apps like STK would software-render (too slow to play): decide with the owner; pads reach games only as keys (B-006).

## Next, in this order
1. T-164 as above (one lane). 2. One image build `0.0.57+` from main (WSL; no heavy tests during `make-disk`), VM queue (`vm-storage-check.ps1` incl. step `scan`, `vm-devices-check.sh twopads|inputd|bluetooth`, T-164's checks), oci-archive to the Dell, `scripts\free-space.ps1` afterwards (it prunes the podman images). 3. On the Dell: STK Activity screen (pad B/Esc go back), Settings/Store speed with `scripts/page-open-bench.py` (before = `0a3e4f4`, after = main), then T-355. 4. Owner question to answer (Inbox line): are the three card sizes/caption placements on Home, Games, Store justified? Design + UX reviewers from screenshots. 5. Then the backlog (`STATUS-backlog.md`): T-322/T-347/T-348 (audio output; first output at full volume once), T-332/T-333 (format drives), T-263.. multi-controller, T-338, T-354 (Xbox research), T-350..T-353 (platform API), T-248.. first-party apps, T-262 UI part, T-346.

## Dell (192.168.178.109, root with `~/.ssh/ruyaos_dev`; `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`; standing permission in CLAUDE.md, report `Dell: ...`)
0.0.56; one Bluetooth adapter (Intel AX201 hci0, USB 1-14); two DualSense bonded (24:A6:FA:AD:DD:EA original, 88:03:4C:3F:60:E1); STK + runtimes in the system Flatpak installation; `/var/tmp/ruyaos-0.0.56.oci` (2.5 GB) can be deleted; the udev wake rule is in its `/etc/udev/rules.d` too. Suspend (`rtcwake -m mem -s 20`) works, a PS press during sleep wakes it, a pad reconnects about 1 s after a press (btmon-proven).

## Owner-level items (STATUS "Open owner decisions")
Open: ADR-018 Epic (parked), pad-glyph licence and wordmark, ControllerCons licence, Dolby/DTS, HDR/VRR, update size, the Xbox adapter legal question (T-354). Decided 2026-11-08/09: see `STATUS-parked.md`.

## Concerns (ranked)
1. T-164 GL limit (no dmabuf plugin) may make STK unplayable: decide early. 2. CI unverified. 3. `tst_battery_cluster::test_the_chip_shrinks_to_plus_n_in_a_narrow_room` fails in about half of the full runs on this host (gap 23-25 px against 24), passes alone: find the real margin (Inbox). 4. STATUS.md is 16 KB (budget 10-14): triage the Inbox first. 5. Four stale hung test processes of an old builder (PIDs 9924, 69752, 87328, 72840, harmless; the owner may kill them). 6. Reviewers sometimes leave empty stray files in the main checkout (found `drive_scan.rs`, deleted): `git status` before merging.

## Host facts learned
- WSL via PowerShell: put commands in a script file and run `wsl -d FedoraLinux-44 -- bash /mnt/c/...`; `pkill -f name` over ssh kills the ssh shell itself; WSL jobs die with the session; `wsl --shutdown` before the PC sleeps (vhdx on F:). `date -u` in the Bash tool is UTC, the Dell and Windows run CET.
- Image timings with the WSL disk on F:: build 15-22 min, qcow2 18 min, ISO 19 min. Waiting: use one long blocking command or a Monitor, not many empty turns.
- Older notes (SELinux/PID 1 pipes, `bootc usroverlay`, `busctl --json=short`, heredocs and backslashes) are in `image/CLAUDE.md`, `docs/dev-setup.md` and the git history of this file.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-06/07 | e73e081..e7f7aff | T-200..T-205, T-208, T-209, T-214 | 6 of 7 needed a round 2 | 544 QML | `0.0.48`/`0.0.49` PASS |
| 2026-11-07/08 (lead-3) | 273d3bc..d07a52b | T-247, T-198, T-271, T-272, T-202, T-269, T-227 | 5 of 7 round 2: Qt screen names, a guard test that could not fail, 5 Linux compile blockers, hostile WAV hang | 829 QML | `0.0.51`/`0.0.53` PASS |
| 2026-11-08 (lead-4) | d09da99..01f31ca | T-290..T-324 (13) | 8 of 13 round 2; FLAC sample-rate-0 bed bug found | 931 QML | `0.0.54` PASS |
| 2026-11-08/09 (lead-5) | 01f31ca..dae44c0 | T-330, T-336, T-335, T-337, T-334, T-356, T-349, T-331 (+T-166, T-262 mechanism) | T-336 (Pairable on the wrong adapter), T-337 (unseen release), T-331 (unbounded listing, Eject vs scan), T-349 (probe per-frame cost) and T-356 (net broke Store tests) needed rounds; the lead found the dead-end focus bug with the owner; inputd proven innocent with a raw capture | 987 QML + 77 skips | `0.0.55`, `0.0.56` PASS, both ISO checks |
