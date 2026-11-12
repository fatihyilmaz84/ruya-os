# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. **Since 2026-11-12 Paper Plane is the source of truth** (owner): http://192.168.178.164:8687, project `RUY`; `docs/STATUS*.md` and `docs/tasks/T-*.md` are a frozen archive. This file is the lead's session record.

## State at the end of lead-13 (Opus, 2026-11-12; weekly plan 90 %, planning only)

- **Owner, this session:** weekly plan at 90 % (resets 2026-11-13 18:00): **plan only, no builders until the reset.**
- **Review range:** cbf4a4e..f7bf080 was one docs commit; nothing to verify (no test, shots or VM run). Main is still the 0.0.68 image; **the Dell runs 0.0.68** (rollback 0.0.67).
- **Paper Plane MCP tools were missing** in this session: `~/.claude.json` had them only under the project key `D:\dev\RuyaOS`; the desktop app reads `D:/dev/RuyaOS`. Copied to that key (backup `~/.claude.json.bak-lead13`). **They should load in the next session; check first.** Until they load, usage is not attributed to tickets (`summary` showed 0 tickets).
- **Planning pass: the inbox is empty** (22 tickets):
  - New Ready tickets at the top of `next` (sort 11500..11900): **RUY-401** Hub at large UI sizes and focus polish (from 394, 396, 399, 400; lead decision: the Hub never scrolls, the art and strip shrink above 100 %), **RUY-402** tidy after the Hub redesign (392, 393, 397, 398), **RUY-403** contract test: served D-Bus introspection vs `api/dbus` XML (372), **RUY-404** vm-session-check.sh trap and card-suspend half (367, 368), **RUY-405** Hub probe: Resume time and hidden-Hub frame count (365, 366).
  - To the Dell list RUY-391 (comments): 369's Dell half, 370, 375, 395.
  - Kept: RUY-369 (who writes `target.object = null`, lead, needs VM `-Audio`), RUY-371 (known limit, phase 3), RUY-374 (blocked by RUY-11). Cancelled: RUY-373 (lead decision: the overlay stays hidden on Home, as 02 says).
  - RUY-376 / RUY-377 (whole lead-10 / lead-11 batches) are now parking lists titled "Parked follow-ups ..." (owner:lead): read the matching lines when working in an area; not ticketed while the board has 112 Ready.
- **Root `CLAUDE.md`** pruned 12.4 → 11.3 KB (duplicated Paper Plane list, archive row, Dell and image-build bullets, the T-116 pitfall that `dev-setup.md` covers).
- **Paper Plane issues not filed:** the permission check refused `gh issue create`. Drafts in the lead-13 scratchpad: (1) `update` has no `sort_order` (REST PATCH only); (2) `summary`'s "Blocked:" heading lists ~40 Ready tickets that wait on another ticket, uncapped. File them when `gh` is allowed (search first; #1..#6 exist).

## Next, in this order
1. Check the `mcp__paperplane-lead__*` tools are present. If not, look in `~/.claude.json` for the project key the app uses.
2. After the weekly reset: one builder lane while the plan is above 70 %. Order: RUY-401 (Hub at large UI sizes), then **game settings** (owner, late lead-13: ADR-035): RUY-406 schema and mock, then RUY-407 the Hub Game panel (both touch the Hub after RUY-401: run them one after another); RUY-403 (services) is the second lane once two are allowed.
2b. **Platform1 moved forward** (owner, 2026-11-12): T-351 / RUY-156 and T-353 / RUY-158 are phase 3 and near the top; **T-352 / RUY-157 is lead work** (owner:lead, caller-identity spike first): take it as the lead task (LEAD.md step 6) once RUY-156 is merged. RUY-408 (`Platform1.GameSettings`) waits on it.
3. Ask the owner how the new Hub feels on the TV (Dell 0.0.68).
4. The board has **112 Ready** tickets against a target of 8-12 (the cutover moved the old STATUS order over as Ready). A planning pass should move everything beyond the top ~15 back to Backlog, keeping its order.
5. Dell pass (RUY-391): overlay FPS on vs off, the speaker route mute, sound after Resume, the Hub's first frame.

## Concerns (ranked)
1. Usage per ticket is still unproven (no MCP in lead-13); watch the first builder dispatched with MCP tools.
2. 112 Ready tickets make `next` and the board order the only real plan; stale ones get picked without a re-read (LEAD.md 4b says to re-read anything older than a week).
3. T-466's park/restore on real hardware is still unseen (RUY-391, RUY-369).
4. Root `CLAUDE.md` 11.3 KB (budget about 10).
5. `docs/tasks/T-nnn` links (about 4,600) stay valid only because the archive stays; never delete it.

## Process changes in lead-13
- PLANNING.md step 5, LEAD.md step 4 and PAPERPLANE-PILOT.md: ordering is `PATCH /api/tickets/RUY-n {"sort_order": n}` (the `update` tool has none); PAPERPLANE-PILOT.md names the MCP project-key trap.

## Host facts learned
- Never put backslashes in a Bash heredoc, `sed` or a `python -c` string: use Write/Edit. `python -I` ignores `PYTHONIOENCODING`: call `sys.stdout.reconfigure(encoding="utf-8")`.
- Paper Plane REST: `POST /api/tools/<tool>` with JSON; `PATCH /api/tickets/RUY-n`; `POST /api/tickets/RUY-n/relations {"kind":"blocks","ref":"RUY-m"}`. Tool argument names are in `D:\dev\PaperPlane\backend\paperplane\mcp.py`.
- The Dell's host key changes with a reinstall; a builder may bind-mount a shell over `/usr/bin/ruya-shell` (gone at reboot).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-11 (lead-11) | 6cd6b20..main | T-462, T-458, T-452, T-453, T-464, T-465, T-467, T-463, T-468, T-466, T-454 | round 2 for 4; 6 stale VM checks fixed | 1232 QML + 100 skips | `0.0.64`, `0.0.65`; Dell 0.0.65 |
| 2026-11-12 (lead-12) | 7b1e224..main | T-469, T-455, T-470, T-472, T-471 | round 2 for T-469, T-455, T-471; a contract mismatch found only in the VM (RUY-372); T-471 builder 416k tokens | 1249 QML + 103 skips | `0.0.66`, `0.0.67`, `0.0.68` PASS; Dell 0.0.68 |
| 2026-11-12 (lead-13) | cbf4a4e..f7bf080 (docs only) | none (planning only, weekly plan 90 %) | inbox 22 → 0: 5 new Ready, 4 to the Dell list, 1 decided, 2 parked; MCP project-key trap fixed | not run (no code change) | none |
