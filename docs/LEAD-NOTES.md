# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. **Since 2026-11-12 Paper Plane is the source of truth** (owner): http://192.168.178.164:8687, project `RUY`; `docs/STATUS*.md` and `docs/tasks/` are a frozen archive. This file is the lead's session record.

## State at the end of lead-12 (Opus, 2026-11-12; weekly plan 88 %)

- **Merged (all through Paper Plane tickets):** T-469 / RUY-9 (performance overlay over a running game, toggled in Hub > Performance; round 2 for developer docs), T-455 / RUY-10 (Hub budgets: `dell-hub-check.sh`; round 2 for a trap), T-470 / RUY-362 (the T-466 Thaw "failure" was the check: ruya-shell's manager stopped 10 s after the shell), T-472 / RUY-364 (decision in 03: no linger; a game does not outlive the compositor; the relaunch gets sound). Lead fixes: `review:` GetBrightness returned `su` instead of the contract's `(su)` (7597ee7); the Thaw check accepts `target=null` (57c61cd); tst_perf_overlay cleanup.
- **Images:** 0.0.66 (VM queue: brightness and Thaw failures, both fixed), 0.0.67 (queue PASS after the fixes), **0.0.68** at bce3cf1 (the new Hub; VM queue 16/16 PASS). **The Dell runs 0.0.68** (rollback 0.0.67); `dell-hub-check.sh` 4/4 PASS with the new Hub (first frame 16 ms, FPS drop 0 %); the picker 0 % GPU.
- **Owner, this session:** the Hub is too crowded: **T-471 / RUY-363 merged** (layout A: game card = Resume, Home|Close, running-apps art strip, Volume, panel icons Audio/Controllers/Performance/Power; removed Recent, Wi-Fi/Bluetooth/Mute tiles, Display entry; Switch profile in Power; brightness moved to Settings > Display & motion; two review rounds, 9 inbox tickets RUY-392..400). Paper Plane bugs and feature requests go to GitHub issues on `EnigmaNL/PaperPlane` (owner; #1..#6 filed; rule in LEAD.md 6b). **Paper Plane is the source of truth** (cutover done, see below). Telemetry always on. One builder lane while the weekly plan is above 70 %.
- **Cutover:** STATUS-only items are tickets (`inbox` RUY-365..377, `blocker` 378..381, `owner-decision` 382..389, `vm-queue` 390, `dell` 391; `scripts/paperplane-migrate-status.py`); CLAUDE.md, LEAD.md, PLANNING.md, tasks/README.md and all agent files rewritten for tickets; `lint-board.ps1` removed from dev.ps1 and CI.
- **Paper Plane access:** MCP servers `paperplane-lead`, `-builder`, `-reviewer` (local scope of this checkout, one token each) load at session start; usage hooks in `.claude/settings.local.json` (token `ruy-hooks`); OpenTelemetry in `~/.claude/settings.json` (token `telemetry`). Token files: `C:\Users\FSYY\.paperplane\ruy-{lead,builder,reviewer,hooks}.token`, `telemetry.token`.

## Next, in this order
1. **First check the new setup works** in this fresh session: the `mcp__paperplane-lead__*` tools are present; `summary usage=true` shows tokens after a claim through MCP; a builder dispatched with the MCP tools records its usage on the ticket. If the MCP servers are missing, re-add them (`PAPERPLANE-PILOT.md`, MCP section) with the app's own `claude` (the one in `~/.local/bin` is 2.0.30).
2. Ask the owner how the new Hub feels on the TV (Dell 0.0.68); the Hub-at-large-UI-size scroll (RUY-394) is the likely next Hub ticket.
3. **Planning pass** (overdue): `list label=inbox` (22 tickets, two of them whole lead-10/lead-11 batches), turn them into Ready tickets; the board order is the old STATUS order. Nothing is in flight: no worktree, no builder.
4. On the Dell (`dell` ticket RUY-391): the performance overlay over STK, on vs off FPS (RUY-375); the speaker route muted? (RUY-370); sound back after Resume with a real card (RUY-369).

## Concerns (ranked)
1. The cutover is untested by a fresh session: the agent files now say "use MCP tools, else curl"; watch the first builder through it.
2. `docs/tasks/T-nnn` links (about 4,600) stay valid only because the archive stays; never delete it. The open backlog lives in Paper Plane only; the public repo does not show it and is not exported (owner, 2026-11-12).
3. T-466's park/restore on real hardware is still unseen (RUY-369).
4. Root `CLAUDE.md` is 12.4 KB (budget 10): prune at the next lead session.

## Process changes in lead-12
- Paper Plane is the source of truth; the board lint is gone; reviewers record verdicts on the ticket; the builder claims its own ticket (no claim commit on main).
- `dell-update.sh` measures the picker only after the shell is 40 s old.

## Host facts learned
- Never put backslashes in a Bash heredoc, `sed` or a `python -c` string: use Write/Edit (hit again this session). `python -I` ignores `PYTHONIOENCODING`: call `sys.stdout.reconfigure(encoding="utf-8")`.
- The Dell's host key changes with a reinstall; a builder may bind-mount a shell over `/usr/bin/ruya-shell` (gone at reboot).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-10 (lead-10) | 8e02406..main | T-434, T-435, T-449, T-451, T-448, T-429, T-457, T-450 | 5 of 8 needed a round 2; 4 stale VM check patterns fixed | 1134 QML + 95 skips | `0.0.62`, `0.0.63` PASS; Dell 0.0.63 |
| 2026-11-11 (lead-11) | 6cd6b20..main | T-462, T-458, T-452, T-453, T-464, T-465, T-467, T-463, T-468, T-466, T-454 | round 2 for 4; 6 stale VM checks fixed | 1232 QML + 100 skips | `0.0.64`, `0.0.65`; Dell 0.0.65 |
| 2026-11-12 (lead-12) | 7b1e224..main | T-469, T-455, T-470, T-472, T-471 | round 2 for T-469, T-455, T-471 (the lead's own task text dropped brightness); a contract mismatch found only in the VM (RUY-372); T-471 builder 416k tokens | 1249 QML + 103 skips | `0.0.66`, `0.0.67`, `0.0.68` PASS; Dell 0.0.68 |
