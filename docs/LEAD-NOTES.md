# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. History lives in the STATUS session log and git.

## State at the end of lead-10 (Opus, 2026-11-10, handoff at 55 % context; weekly plan 77 %)

- **Owner priorities (2026-11-10):** Ruya Hub first (ADR-033, T-447..T-458), then Ruya Input (T-366, T-367, T-396, T-456). The owner said two builder lanes are fine. **The Hub pauses the game** (owner; ADR-033 point 3, T-457 merged). XWayland: owner said yes as a compatibility layer (ADR-034); lead spike T-461 on the board (after the Hub, before or beside T-366).
- **Merged this session:** T-434, T-435, T-449, T-451, T-448, T-429, T-457, T-450 (+ lead T-447 design, review fixes). Image **0.0.63** built (main at 9c885c3: no T-457, no T-450), VM queue PASS, **the Dell runs 0.0.63** (rollback 0.0.62).
- **In flight when this was written** (worktrees under `D:\dev\RuyaOS-worktrees`): **T-459** (window ↔ instance by pid, Close never dropped; Opus builder), **T-428 round 2** (Store slotY must follow `u`; then merge, add the 04 §3.8 glare sentence if the builder did not). If their sessions are gone, look at each worktree's last commit: committed work goes to `ruya-reviewer` with "verify everything yourself". Remove worktrees after merge.

## Next, in this order
1. **T-460 is merged:** shots failed because the display slept (no frames); a sleeping display now reaps pages at once. The remaining shots red is the old `test_zz_sheet_after_an_app` flake (T-430 item 5).
2. Finish T-459 and T-428 (review, merge). Then **build 0.0.64** (`scripts/image-chain.sh 0.0.64 oci`), `vm-queue.ps1` (default list + `vm-devices-check.sh check`/`security`; `vm-session-check.sh check` now has Freeze/Thaw), `dell-update.sh 0.0.64`, then on the Dell: the Hub over a frozen STK (**does the sound stop, and come back after thaw?** the stream stayed `running` in a manual test), Close of Asteroid Shooter (T-459), the FrameMeter vs top with STK (T-451), Resume from Home for ACBR (T-435), `dell-glass-check.sh` (T-434; needs a signed-in profile; `RUYA_PIN`). Then `free-space.ps1`.
3. Builder lane order: T-462 (shots you can run once), T-458 (Closing screen), T-452 (starts with the QuickMenu row-descriptor refactor), T-453, T-454, T-455 — all edit QuickMenu.qml or Shell.qml: **one at a time**; a second lane takes T-427 / T-431 / T-433.
4. Lead: T-366 (Ruya Input spike) when the Hub lane is moving.

## Concerns (ranked)
1. Hub/compositor matching by xdg app_id is wrong for pygame/SDL games (T-459 fixes); X11-only games cannot run at all (owner question). 2. `shots` cannot be trusted while T-460 is open: don't accept "known reds" beyond those four. 3. Freeze and sound on hardware unverified (T-457). 4. GPU load and package power need a root reader (T-451 Inbox; security call). 5. SELinux protects none of our services (T-432); profiles share full PipeWire rights (T-380).

## Host facts learned
- Never put backslashes in a Bash heredoc or a `python -c` string: use Write/Edit. A Bash heredoc with many `'` in a single command can fail to parse: write task files with Write.
- PowerShell `-like` treats `[` as a wildcard: use `.StartsWith()` or `-match` with escaping.
- `powershell -File` from Bash joins array arguments into one string: use `-Command "& script -Arg 'a','b'"`. `wsl.exe` from Git Bash needs `MSYS_NO_PATHCONV=1` for `/mnt/...` paths.
- Never `Stop-Process tst_ruyashell` blindly: it kills builders' runs too.
- `make-disk` and `dev.ps1 test` together can exhaust WSL memory (it worked this session, but watch it).
- The VM now has a microphone (`hda-duplex`); the idle-spawn check waits 2 s after its own volume change.
- One `shots` function alone: `tst_ruyashell.exe -o log,txt "Case::test_zz_name"` with `QSG_RENDER_LOOP=basic` and `RUYA_SHOTS_DIR` set, no `QT_QPA_PLATFORM`.
- `tryCompare(x, "opacity", 1)` is fuzzy: wait on a derived exact property with `tryVerify`.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-09/10 (lead-8) | 36a14eb..66d6f25 | T-363, T-377, T-359, T-386, T-387, T-379 | VM checks with wrong criteria (3 fixed) | 1029 QML + 84 skips | `0.0.60` PASS; `0.0.61` |
| 2026-11-10 (lead-9) | 66d6f25..main | T-423, T-421, T-424, T-147 | T-147 deleted 9 tests silently (round 2); CI red fixed | 1063 QML + 89 skips | none built |
| 2026-11-10 (lead-10) | 8e02406..main | T-434, T-435, T-449, T-451, T-448, T-429, T-457, T-450 | 5 of 8 needed a round 2 (sibling-scope glob, unserved contract, frozen-game traps, Store `u`); 4 stale VM check patterns fixed; T-448 broke shots (bisected, T-460); Close dropped for pygame windows (Dell, T-459) | 1134 QML + 95 skips | `0.0.62` PASS, `0.0.63` PASS; Dell 0.0.63 |
