# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. History lives in the STATUS session log and git.

## State at the end of lead-8 (Opus, 2026-11-09/10, handoff at about 60 % context)

- **Merged and reviewed:** T-363 (ruya-session follows a Flatpak game's own scope), T-377 (Store opens without its 275 ms frame: index, one row-id pass, lazy rows), T-359 (Bluetooth follow-ups; `TailText` keeps the address tail), T-386 (**Play starts the game**: `Library.launchRequested` was never wired), T-387 (**glass sheets keep their blur**: GlassSheet's mask layer toggle; picker tiles' `visible` race; L0 hidden by opacity 0), T-379 closed (shots reds not reproducible). `main` 66d6f25 tested: 1029 QML + 84 skips ALL GREEN; docs commits after it.
- **Images:** 0.0.60 (main 36a14eb) VM queue PASS after three check fixes (`system` one GetInfo snapshot, `display` counts running streams as T-376's criterion says, reboot relaunch with `-Audio`); the Dell runs **0.0.60** (rollback 0.0.59). **0.0.61** (main 66d6f25, with T-363/T-377/T-359/T-386/T-387): build PASS; `make-disk` failed with "Cannot allocate memory" while `dev.ps1 test` ran beside it; re-run started with `SKIP_BUILD=1 scripts/image-chain.sh 0.0.61 oci` (see below whether it finished).
- **Dell findings (owner reports, diagnosed on the Dell):** see T-386/T-387 Outcomes; `bootloader-update.service` fails every boot (Secure Boot, missing MS UEFI CA 2023 in the firmware db: T-299, moved up). The Dell's SSH host key differs from `known_hosts` line 26 (reinstall?).
- **Planning from owner documents** (kept in `docs/archive/research/`): ADR-025 GE-Proton and a runner catalogue (T-381..T-385), ADR-026 downloads (T-388..T-392), ADR-027 controller ownership, family buttons, action glyphs (T-396..T-399), Options menu (T-393..T-395), ADR-028 games and saves (T-400..T-403), **Proposed** ADR-029 Ruya Web (T-404 blocked, T-405..T-410), **Proposed** ADR-030 Companion (T-411..T-415), ADR-031 AI-first developer platform (T-416..T-419); T-378, T-380 from the Inbox. Parental controls stay later (owner).

## Next, in this order
1. **0.0.61:** if `output/chain/summary.txt` ends `CHAIN OK`: `scripts\vm-queue.ps1` with the 0.0.61 queue in STATUS (`check` first: it makes the profile `display` needs), then `scripts/dell-update.sh 0.0.61` (Git Bash), then the owner checks STK from Games, the picker after an app, the T-376 hw items. If `make-disk` failed again: run it alone with nothing beside it.
2. **Owner answers** (STATUS, Open owner decisions): Ruya Web, Companion, GE-Proton codecs, Ludusavi licence, developer platform, Hub naming. Turn answers into ADR status changes and unblock T-404/T-415.
3. **Lead tasks:** T-393 (Options menu design) and T-396 (ADR-027 spec) first: they unblock T-394, T-397, T-398, T-399; then T-366/T-367 (Ruya Input), T-381 (GE-Proton spike), T-380.
4. **Builder lanes:** T-147, T-362, T-378, T-299, T-364, T-339 (backlog order).
5. Triage the Inbox (STATUS is 15 KB, budget 10 KB).

## Concerns (ranked)
1. Games see no pad (T-366/T-367) and launch has no splash or quick menu yet (T-147): the console plays, but not like a console. 2. Profiles share full rights in PipeWire (T-380). 3. Control characters keep reaching main through Bash heredocs (twice by the lead in lead-8): the hook `.githooks/pre-commit` exists but needs `git config core.hooksPath .githooks` (the harness refused it: owner). 4. Two `shots` frames saw the TextEntry keyboard see-through (by design: translucent keys; a T-282 call). 5. CI unverified (gh not installed).

## Host facts learned
- Never put backslashes in a Bash heredoc or a `python -c` string, even inside quotes: use Write/Edit or `chr()`.
- `powershell -File` from Bash joins array arguments into one string: use `-Command "& script -Arg 'a','b'"`.
- PowerShell `-match` is case-insensitive: `-cmatch` when "FAIL" must not match "Failed".
- `make-disk` and `dev.ps1 test` together can exhaust WSL memory ("Cannot allocate memory" on the copy to `/output`).
- `vm-session-check.sh display` needs the profile that `check` creates.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-09 (lead-6) | c5e2d67..d4157dd | T-164, T-322, T-347, T-285, T-358 (lead) | T-164 hidden app vs updates; T-322 silent-pass VM check; T-347 executor blocking; T-285 untested hint | 1001 QML + 77 skips | `0.0.57`, `0.0.58` PASS; Dell STK on GPU |
| 2026-11-09 (lead-7) | d4157dd..36a14eb | T-340, T-348, T-365, T-375, T-376, T-361, T-360 | 5 of 6 needed a round 2 | 1012 QML + 79 skips | `0.0.59` restart FAIL (fixed); Dell 0.0.59 |
| 2026-11-09/10 (lead-8) | 36a14eb..main | T-363, T-377, T-359, T-386, T-387, T-379 | T-359 one design round 2 (tail elision); T-387 lead hypothesis rejected by the builder's GPU repro; two owner-visible bugs found on the Dell (launch never wired, glass); VM checks with wrong criteria (3 fixed); lead put control chars on main twice | 1029 QML + 84 skips | `0.0.60` PASS; `0.0.61` disk re-run |
