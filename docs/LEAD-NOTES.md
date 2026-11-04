# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Lanes at handoff (2026-11-04)

| Task | Worktree / branch | State |
|---|---|---|
| T-175 Settings list fits, pane hints | `D:\dev\RuyaOS-worktrees\T-175`, `t/T-175-settings-list-fits` | builder dispatched (round 1) |
| T-161 controller battery | `D:\dev\RuyaOS-worktrees\T-161`, `t/T-161-controller-battery` | builder dispatched (round 1); the only image lane (`0.0.34-t161`) |

If a session ends with these running: check `git -C <worktree> log/status`. A commit past `cbb0681` plus a filled Outcome means it needs review (`ruya-reviewer`), otherwise resume a fresh builder on the same worktree and have it read the uncommitted diff first.

## Review range

- **Last reviewed commit: the handoff commit of 2026-11-04** (everything from `2c134ce` was merged only after a `ruya-reviewer` verdict; the lead checked each round 2 itself or re-ran the reviewer).
- Last VM verification: `0.0.32`/`0.0.33` of main at `9212707` (2026-11-04): boot, greenboot, store check incl. the restart step, update drill and idle reboot. T-170, T-172 and T-144 landed after that build (shell only, host-verified).

## Concerns (ranked)

1. **Critical path is still T-162 → T-164 → T-165/T-147** (`[lead]`, `ruya-session` in the image). Nothing of it started this session: the build loop took the whole session. Next lead: do T-162 first, in the main checkout, while builder lanes do host-only work (it needs the image lane).
2. **Image lane is the bottleneck.** T-161, T-173, T-174, T-145 all need it and run one at a time (each ~1-2 h with its VM checks). Keep one image task in flight at all times; pair it with host-only shell work.
3. **Reviews earn their cost.** 6 of 12 branches came back CHANGES_REQUESTED, mostly tests that could not fail (T-168 shot, T-170 geometry, T-144 constant name) and VM steps that could not pass (T-171 twice, T-160's wrong diagnosis). Keep asking builders for revert checks, and keep the reviewer told to run them.
4. **STATUS is 12.6 KB** (budget ~10 KB): the Inbox (9 items) and the long "Decided" line. Empty the Inbox at the next planning pass; consider moving the "Decided" record into `00-overview.md`.
5. Older, unchanged: compositor gaps (B-003, suspend → T-166), high-risk gate enforced by the shell only, `caller_is_admin` copied in two services, stale canvas boards, Settings scroll affordance (design, Inbox).

## Host facts learned this session (also in LEAD.md / the builder file)

- In PowerShell, `git` and `cmake` are devkitPro's MSYS2 builds (first on PATH). Worktrees: Git Bash only. CMake: `dev.ps1` finds the real one; by hand use `& "$env:ProgramFiles\CMake\bin\cmake.exe"`.
- Every fresh VM disk has a new SSH host key: use `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` for the dev VM, never edit `known_hosts` (a builder ran `ssh-keygen -R` once; backup `known_hosts.old`).
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

Older rows: git history of this file.
