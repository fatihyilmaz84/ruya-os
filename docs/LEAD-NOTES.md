# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Lanes at handoff (2026-11-04, late)

None running: every worktree is merged and removed. `git worktree list` shows only the main checkout.

## Review range

- **Last reviewed commit: the handoff commit of 2026-11-04 (late)**. Everything from `2c134ce` was merged only after a `ruya-reviewer` verdict; the lead checked small round 2s itself (T-168, T-170, T-144, T-175, T-145) and re-ran the reviewer on the rest.
- Last VM verification: lead image `0.0.37` of main at `0fe2337` (devices check incl. BlueZ, T-173/T-177). Builders verified `0.0.34-t161`, `0.0.36-t145` (Inter round 1 only), `0.0.39-t174` (udisks2). **No image of current main has been booted**: it combines T-145 round 2 fonts (Bold, ‹ ›) and T-174; the next lead VM run should boot it once (smoke + `vm-devices-check.sh check` + `vm-storage-check.ps1` + a VM home shot with a library entry, Inbox).

## Concerns (ranked)

1. **Critical path is still T-162 → T-164 → T-165/T-147** (`[lead]`, `ruya-session` in the image). Not started: the build loop took the session. **NEXT is T-162**; builders have no ready task left. Do T-162 first, with one builder on Inbox host work beside it.
2. **The board needs planning.** Every open builder task waits on T-164; the Inbox has ~20 lines (shell polish, backend stale replies, network polkit audit, vm-check gaps, design calls). Run PLANNING.md: 3-5 host tasks for the builder lane while T-162 holds the image lane.
3. **Security follow-up:** `50-ruyaos-network.rules` returns `NOT_HANDLED` like the storage rule did before T-174 round 2, so NetworkManager defaults stay open to `ruya-shell` (Inbox). Treat as the first planned task.
4. **Reviews earn their cost.** 10 of 19 branches came back CHANGES_REQUESTED: tests that couldn't fail, VM steps that couldn't pass, two real security gaps (udisks2 defaults, a redundant bus rule), real-hardware bugs in BlueZ (Discovering never announced, Pair > 25 s). Keep revert checks mandatory on both sides.
5. **STATUS is ~13 KB** (budget ~10 KB), mostly the Inbox: planning empties it.
6. Older, unchanged: compositor gaps (B-003, suspend → T-166), high-risk gate enforced by the shell only, `caller_is_admin` copied in two services, stale canvas boards, Settings scroll affordance (design), Turkish wording review (owner).
7. **Owner question open:** a spare Dell (regulatory model D14U001, likely an OptiPlex Micro) offered as hardware; lead recommends it as the B-002 real-hardware test machine (dev ISO, SSH-driven checks), not a build host. Awaiting the owner's choice.

## Host facts learned this session (also in LEAD.md / the builder file)

- In PowerShell, `git` and `cmake` are devkitPro's MSYS2 builds (first on PATH). Worktrees: Git Bash only. CMake: `dev.ps1` finds the real one; by hand use `& "$env:ProgramFiles\CMake\bin\cmake.exe"`.
- Every fresh VM disk has a new SSH host key. The `ssh` on PATH is MSYS2's too: `UserKnownHostsFile=NUL` writes a file named `NUL`; the vm scripts now use `output\vm-known_hosts` (by hand: `/dev/null`). Never edit `~/.ssh/known_hosts` (a builder ran `ssh-keygen -R` once; backup `known_hosts.old`).
- `make-disk.sh` once failed with "Cannot allocate memory" writing to `/mnt/d`; a plain retry passed.
- A file named `NUL` in a worktree blocks its removal: `rm -rf` from Git Bash works.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-01 | 300245c..e19899f | T-149, T-151, T-113, T-152, T-146 | 8 / 4 (T-153, T-156) | 242 + 20 skipped QML, 207 Rust | not run |
| 2026-11-02 | e5c2ab3..ac6e5b1 | T-153, T-156, T-154 | 2 / 0; process: log capped | 255 + 21 skipped QML, 242 Rust | not run |
| 2026-11-02 | 39b25f2..9b77857 | T-130 (lead task) | 0 / 3 filed | 256 + 21 skipped QML | `0.0.26-t130` ✅, drill ✅ |
| 2026-11-04 | 9b77857..b4733f4 | T-155, T-157, T-159 (+ T-130 fresh read) | 0 / 7 tasks planned (T-162..T-168). Process: builder/reviewer agents, worktree lanes, lead-only STATUS, VM queue, `free-space.ps1`, shots lock (owner) | 271 + 22 skipped QML, 242 Rust | not run (`0.0.29-t159a` built, not booted) |
| 2026-11-04 | 2c134ce..handoff | 12 merged: T-167, T-168, T-136, T-158, T-137, T-169, T-163, T-160, T-171, T-172, T-170, T-144 | 6 CHANGES_REQUESTED, 3 lead fixes (T-169 exit codes, T-160 drill, T-171 VM step); 7 tasks planned (T-169..T-175). Process: devkitPro git/cmake, per-checkout test log, .ts recipe, lane counts to merge, scratch files in worktree | 327 + 28 skipped QML | `0.0.32`/`0.0.33` ✅: store 48 PASS, update drill + idle reboot ✅ |
| 2026-11-04 (late) | handoff..223d7ed | +7: T-175, T-176, T-161, T-173, T-145, T-177, T-174 (19 in the session) | 10 CHANGES_REQUESTED in the session; lead fixes: T-173 stop_scan, T-176 shots log, scratch known_hosts; 3 tasks planned (T-175..T-177) | 346 + 28 skipped QML, 118 Rust in ruya-devices | lead `0.0.37` ✅; builders `0.0.34`, `0.0.36`, `0.0.38/.39` ✅ |

Older rows: git history of this file.
