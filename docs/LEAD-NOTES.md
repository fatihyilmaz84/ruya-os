# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Paused mid build loop (owner, 2026-11-04): resume here first

The owner stopped the loop for the night. Nothing is running (agents stopped, WSL builds killed, no QEMU). State of each lane:

| Task | Worktree / branch | State | Next step |
|---|---|---|---|
| T-167 test isolation | `D:\dev\RuyaOS-worktrees\T-167`, `t/T-167-test-isolation` | Builder done, commit `f677a8f` (HANDOFF round 1: Store facade kept a stale job across `mockReset`; language leak was a Right on the System pane's Language row; 274 QML green) | Review was stopped before a verdict: dispatch `ruya-reviewer` again (round 1). Its 3 HANDOFF inbox lines (Store jobs after the real service vanishes; translation lint in a fresh worktree; token-lint self-check text) go to the Inbox on merge |
| T-163 + T-160 image pair | `D:\dev\RuyaOS-worktrees\T-163`, `t/T-163-library-in-image` | Builder stopped during its first image build; 15 uncommitted files, no commit | Resume with a fresh `ruya-builder` on the same worktree: read the uncommitted diff first, finish, build `0.0.30-t163` |
| T-168 section nav | `D:\dev\RuyaOS-worktrees\T-168`, `t/T-168-section-nav` | Builder stopped early; 3 uncommitted files | Resume with a fresh builder on the same worktree (or `git checkout .` and restart) |

All three are `in-progress` on the board. The `ruya-builder`/`ruya-reviewer` agent types exist since this session; if a new session doesn't list them, dispatch `general-purpose` on `model: sonnet`/`opus` told to follow `.claude/agents/<name>.md` (that is how this session ran them). A fresh worktree's first `dev.ps1 test` builds from scratch (~10 min) and its translation lint needs `cmake --build shell\build-win --config Release --target update_translations` once (Inbox-to-be, T-167).

## Review range

- **Last reviewed commit: `4bd0c66`** (T-157). T-155, T-157 and the T-130 diff read with fresh eyes: no findings. T-159 (`b4733f4`) was skimmed (schedule core, toast, lint fix): fine; its VM check is on the **VM queue**.
- From now on branches are reviewed per task by `ruya-reviewer` before merge (LEAD.md 4b); the lead review step 3 is a skim of those plus anything from direct builder sessions.
- Last VM verification: `0.0.26-t130` / `0.0.27-t130` (2026-11-02). `0.0.29-t159a` was built (lint fix proven) but not booted.

## Concerns (ranked)

1. **Critical path is now T-162 → T-164 → T-165/T-147** (`ruya-session` in the image, per-profile sockets): both `[lead]`. Do T-162 in the main checkout between merges, but only while no lane runs an image build (one image build at a time).
2. **Disk.** Each image build regrows the WSL disk by 10-20 GB; `scripts\free-space.ps1` gives it back (C: 12 → 24 GB on 2026-11-04). A worktree costs ~4 GB of build output: remove it on merge. D: freed 9 GB by itself when WSL shut down on 2026-11-03 (cause not found).
3. **VM queue:** T-159 (`vm-update-check.sh reboot`, needs build A + build B). Run it after lane A's image work, as one lead VM run.
4. Root `CLAUDE.md` is 11.4 KB (budget ~10 KB): trim at the next session (pitfalls duplicated in `.claude/agents/ruya-builder.md`).
5. Older, unchanged: compositor gaps (B-003, suspend → T-166), high-risk gate enforced by the shell only, `caller_is_admin` copied in two services, stale canvas boards.

## First things the next lead should do

1. `git status` clean in `D:\dev\RuyaOS`; `git worktree list` shows the three lanes above.
2. Resume the lanes (table above); then keep the build loop going (LEAD.md 4b).
3. Push happened at the end of this session if `scan-secrets` passed (see the log); CI of that push.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-10-30 | 4671bb5..e863439 | T-150, T-135, T-148, T-111 | 2 / 0; process: shots screenshot-only, bounded key loops, step 6b | 209 + 15 skipped QML, 178 Rust | not run |
| 2026-11-01 | 300245c..e19899f | T-149, T-151, T-113, T-152, T-146 | 8 / 4 (T-153, T-156) | 242 + 20 skipped QML, 207 Rust | not run |
| 2026-11-02 | e5c2ab3..ac6e5b1 | T-153, T-156, T-154 | 2 / 0; process: log capped | 255 + 21 skipped QML, 242 Rust | not run |
| 2026-11-02 | 39b25f2..9b77857 | T-130 (lead task) | 0 / 3 filed | 256 + 21 skipped QML | `0.0.26-t130` ✅, drill ✅ |
| 2026-11-04 | 9b77857..b4733f4 | T-155, T-157, T-159 (+ T-130 fresh read) | 0 / 7 tasks planned (T-162..T-168). Process: builder/reviewer agents, worktree lanes, lead-only STATUS, VM queue, `free-space.ps1`, shots lock (owner) | 271 + 22 skipped QML, 242 Rust | not run (`0.0.29-t159a` built, not booted) |

Older rows: git history of this file.
