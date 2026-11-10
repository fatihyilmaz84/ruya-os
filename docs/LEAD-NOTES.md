# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. History lives in the STATUS session log and git.

## State at the end of lead-9 (Opus, 2026-11-10, handoff at the weekly plan limit, 70 %, context 35 %)

- **Merged and reviewed:** T-423 (CI gates: cargo-deny, secret scan in CI and the hook, bus-policy lint), T-421 (glass on the Dell: default-look blobs blurred on pages; the drift rests under the hero and 30 s after input, owner-confirmed), T-424 (`vm-security-check.sh`, baseline measured on 0.0.61), T-147 (launch splash, quick menu, Home with the app running, Close; Running pill opaque). No worktrees left; no VM running.
- **CI on GitHub is now visible:** `gh` is signed in (the owner did `gh auth login`); `push-main.ps1` says how to watch a run. The owner had red CI for three pushes: a host-dependent battery-cluster test (fixed: it finds its narrowest room per host), then two T-421 test races (fixed). **The `image` job runs only by hand now** (owner: runner time costs money). The commit hook is active (`core.hooksPath` set by the owner).
- **Not image-verified:** T-421, T-147 and T-424 are in no image yet; the Dell runs 0.0.61. The next image's queue is in STATUS (VM queue line): `dell-glass-check.sh` on the Dell, `vm-app-check.sh flow`, `vm-security-check.sh check`, plus the older items.

## Next, in this order
1. **Weekly plan at 70 % (3 days to reset):** one builder lane at a time, no spikes (LEAD.md budgets); ask the owner before a second lane.
2. **Build image 0.0.62** from main (`scripts/image-chain.sh`, then `vm-queue.ps1` with the queue line in STATUS, then `dell-update.sh`), and run `dell-glass-check.sh` on the Dell: T-421 and T-147 reach the owner's TV only with it. The owner checks the quick menu over STK and the blur.
3. **Builder lane:** NEXT T-434 (glass cost, Performance-tier rows: lead decision recorded in it), then T-435 (ACBR shows no window, orphaned scopes), T-429, T-427, T-428, T-431 (image hardening, VM this task), T-433 (zbus 6), T-432 (SELinux, Opus, after T-431).
4. **Lead tasks:** T-393 (Options menu design) and T-396 (ADR-027 spec), then T-366/T-367 (Ruya Input), T-381, T-380.
5. The Inbox holds the T-147 review follow-ups (one line) and the second-triage pointer; plan them when it reaches 5 lines.

## Concerns (ranked)
1. Games see no pad (T-366/T-367): the console plays, but not like a console. 2. SELinux protects none of our services (T-424: every ruya-* runs `unconfined_service_t`; T-432). 3. `shots` has a flaky pixel test at its threshold on this GPU (`test_zz_sheet_after_an_app`, main red 3 of 8; T-430 item 5): a red `shots` there is not proof of a branch fault. 4. Builders' "fails on main too" claims need a measured comparison (T-147 was right, the lead's first green run was luck). 5. Profiles share full rights in PipeWire (T-380).

## Host facts learned
- Never put backslashes in a Bash heredoc or a `python -c` string, even inside quotes: use Write/Edit or `chr()`.
- `powershell -File` from Bash joins array arguments into one string: use `-Command "& script -Arg 'a','b'"`. `wsl.exe` from Git Bash needs `MSYS_NO_PATHCONV=1` for `/mnt/...` paths.
- PowerShell `-match` is case-insensitive: `-cmatch` when "FAIL" must not match "Failed".
- `make-disk` and `dev.ps1 test` together can exhaust WSL memory ("Cannot allocate memory" on the copy to `/output`).
- `vm-session-check.sh display` needs the profile that `check` creates.
- CI's shell job reproduces in WSL: Fedora 44 with the `ci.yml` dnf packages, build `tst_ruyashell`, run it offscreen with `-input <file>` (lead-9 scratch script; Inter renders differently from Windows).
- One `shots` function alone: `tst_ruyashell.exe -o log,txt "Case::test_zz_name"` with `QSG_RENDER_LOOP=basic` and `RUYA_SHOTS_DIR` set, no `QT_QPA_PLATFORM` (no `-input`).
- `tryCompare(x, "opacity", 1)` is fuzzy: wait on a derived exact property with `tryVerify` (shell/CLAUDE.md).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-09 (lead-7) | d4157dd..36a14eb | T-340, T-348, T-365, T-375, T-376, T-361, T-360 | 5 of 6 needed a round 2 | 1012 QML + 79 skips | `0.0.59` restart FAIL (fixed); Dell 0.0.59 |
| 2026-11-09/10 (lead-8) | 36a14eb..66d6f25 | T-363, T-377, T-359, T-386, T-387, T-379 | T-387 lead hypothesis rejected by the builder's GPU repro; two owner-visible bugs on the Dell; VM checks with wrong criteria (3 fixed) | 1029 QML + 84 skips | `0.0.60` PASS; `0.0.61` |
| 2026-11-10 (lead-9) | 66d6f25..main | T-423, T-421, T-424, T-147 | T-423 CI step red on Linux pwsh + wildcard bypass (round 2); T-424 baseline hid weaknesses (round 3); T-147 deleted 9 tests silently (round 2; `lost-tests.sh` added); CI red from a host-dependent test and two T-421 races (fixed); a yanked crate caught by the new gate | 1063 QML + 89 skips | none built; 0.0.61 VM for T-424 (security check PASS) |
