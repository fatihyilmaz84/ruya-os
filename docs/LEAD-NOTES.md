# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; up to four lanes; builders run nothing in WSL since lead-20**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`); `docs/STATUS*.md` and `docs/tasks/T-*.md` are a frozen archive. **Goals are formations** (`formation` lists them; `PLANNING.md` step 4). This file is the lead's session record.

## State after lead-20 (Opus, 2026-11-14)

- **Review range:** a1f1299..HEAD. Paper Plane `changes` cursor: read from **2600**.
- **Merged and Done (11):** RUY-609, 610, 403, 611, 594, 525, 527, 41 (2 rounds), 23, 622 (owner report: Wii U Pro button names), 624 (inputd node reuse, found by the 0.0.82 queue). Also Done: 589, 542 (lead-19 leftovers).
- **Images:** 0.0.81 (a1f1299) and 0.0.82 (bc27ce4) built, CHAIN OK; queues below. **0.0.82 is on the Dell** (rollback 0.0.80; `bootloader-update` red as before). **0.0.83 is not built yet**: it brings RUY-622, 624 and the check fixes.
- **Owner decisions (2026-11-14):** "Who's playing?" answered in two rounds (RUY-448 comments): only the new pad answers; the game resumes by itself; PIN on the TV with the new pad; players in the top bar and the Hub, no toast; Guest 2/3; 60 s seat hold for every player; profile first, then Join focused; Add profile behind an admin PIN; a guest only joins; player 1 stays in the list with a Move confirm.

## In flight at handoff (check first)
1. **RUY-611 is Verified: hw** (owner: LibreQuake with the Wii U Pro survives Hub quit + relaunch on 0.0.82; `joy_device` reset by the lead). The DualSense not reaching LibreQuake is by design (am. 6; joins need RUY-448). Still to look at on the Dell with 0.0.83: the Wii U Pro's Button test "Last input" (RUY-622), PlayStation glyphs, the journal line `key events come from` with a USB keyboard (RUY-619). Dell SSH: use `dell-update.sh`'s options (`UserKnownHostsFile=/dev/null`); the host key in `~/.ssh/known_hosts` is stale.
2. **Build 0.0.83 first** (`image-chain.sh 0.0.83 oci`), then its VM queue: the default list plus `vm-input-check.sh shell` then `confirm` and `twopads` back to back (RUY-624), `close`, `useractive`, `vm-security-check.sh signals` (now detected by the queue), `vm-gaming-check.sh` (open fixed).
3. **RUY-549 round 3** (Changes Requested): proof runs failed (stale cache across trees, 51 changed, git in WSL can't read a worktree); the ticket comment has the plan. Needs WSL: dispatch after the image chain. Worktree `RUY-549b` still exists (stale branch: rebase on main).
4. **RUY-448 re-plan** (lead work, high): design is final, canvas https://claude.ai/artifact/5zf92tZ5rCh2ajvsZqJGKC, every number in the RUY-448 comments. Next: rewrite RUY-121, 122, 38, 124, 125 and 06 §11.3; settle per-pad routing of the prompt's input and the guest user lifecycle; add the six 04 §8 proposals (player chip, Hub players row, PinPad pad line, ProfileCard player badge, `add` icon, paused pill).
5. Locked worktree folders to delete by hand: `D:\dev\RuyaOS-worktrees\RUY-403`, `RUY-525`, `RUY-547`, `RUY-590`, `RUY-622` (the auto-mode classifier refused `rm -rf`).

## VM results (RUY-390 has them)
0.0.81: all PASS except two check bugs (session probe `timeout 100`, `close` journal lookup: both fixed); `close` then reproduced the RUY-611 bug. 0.0.82: RUY-611 `close`, RUY-23 session checks, RUY-594 `signals` (by hand: only root and ruya-shell hear Input1), sysctls PASS; ntsync open was a check bug (fixed); confirm/twopads failed on RUY-624 (fixed, unproven).

## Next (Ready, ordered)
RUY-448 re-plan (lead) -> RUY-621 (session late-adoption time limits, high) -> RUY-414, RUY-402, RUY-407 (shell, now that RUY-41 is in) -> RUY-156 -> gaming tuning 528-531 (Backlog, need Dell numbers). New inbox today: 612-621, 623.

## Concerns (ranked)
1. Real hardware: nothing since 0.0.80 has run on the Dell; RUY-611 and 41 are proven only in the VM and on the host.
2. Keyboard glyphs may be dead on eglfs (RUY-619).
3. A warm Linux CI cache can still test stale code until RUY-549 lands; use `ci-shell-linux.sh --cold` when in doubt (cold is 12 min, not 20-40).

## Process changes in lead-20
- **Builders run nothing in WSL** (CLAUDE.md, ruya-builder.md, LEAD.md 4b): every VM criterion is `vm pending` and rides on the lead's chain. Four lanes ran without WSL contention.
- Never merge into main while a merge gate runs (lead-20 did once: qmllint saw the new Shell.qml against the old build; re-ran).
- A check that compares timestamps must refuse a non-numeric one (the `close` check passed vacuously on a missing journal).
- Paper Plane: no new issue.

## Host facts learned
- Git Bash rewrites `/mnt/c/...` arguments to `wsl`: prefix `MSYS_NO_PATHCONV=1`. `git` inside WSL cannot read a Windows worktree's `.git` file.
- In PowerShell `git worktree remove` is devkitPro's git: use the Bash tool.
- The VM queue copies scripts from main; the image chain builds from the main checkout (merging shell code after its build step is safe).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-14 (lead-19) | e962e98..a1f1299 | 17 merged (+6 absorbed) | round 2+ for 595, 589 (x2), 541, 542, 549; 11 inbox filed | 1641 QML + 138 skips | 0.0.80 built, queue not run |
| 2026-11-14 (lead-20) | a1f1299..HEAD | 11 merged | round 2 for 41; 4 VM-check bugs fixed by the lead; 1 product bug found in the VM (624, fixed); 549 sent back; 12 inbox filed | 1680 QML + 144 skips; Fedora cold 1680/0 | 0.0.81 and 0.0.82 queues run; 0.0.82 on the Dell, RUY-611 hw-verified |
