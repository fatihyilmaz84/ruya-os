# Paper Plane pilot (started 2026-11-12)

Paper Plane (`D:\dev\PaperPlane`, running at http://192.168.178.164:8687, project `RUY`) was tried as the ticketing system and **became the source of truth on 2026-11-12 (owner, lead-12 cutover)**: `CLAUDE.md`, `docs/LEAD.md`, `docs/tasks/PLANNING.md` and the agent files say how work runs now; `docs/tasks/*.md` and `docs/STATUS*.md` are a frozen archive. This file keeps the import history and the known gaps. No token is stored in the repo.

**Cutover (lead-12):** what lived only in STATUS.md became tickets with `scripts/paperplane-migrate-status.py`: 11 inbox lines and the two untriaged lead-10/lead-11 batches (`inbox`, RUY-365..377), the blockers B-002/003/006/007 (`blocker`, Blocked, RUY-378..381), 8 owner decisions (`owner-decision`, RUY-382..389), the VM queue (`vm-queue`, RUY-390) and the Dell look-at list (`dell`, RUY-391). The final Outcomes of T-455, T-469, T-470, T-472 and T-454's VM line are comments on their tickets. `scripts/lint-board.ps1` is gone from `dev.ps1` and CI.

## What was imported (2026-11-12)

- The 176 open tasks (STATUS board plus STATUS-backlog) as tickets `RUY-1..RUY-176`, in board order. The `T-nnn` id starts every title; the task file's text (without its H1 and header line) is the description.
- Labels from the header: `phase:N`, `area:x`, `size:S|M|epic`, `owner:lead|builder`, `complexity:x`, `surface:x`.
- `Depends:` became `blocks` relations (237). Epics became parents of their children (48 links: T-228, T-248, T-263, T-273, T-302, T-314; T-270 and T-426 have no written children yet).
- State: `Blocked` for blocked tasks, `Ready` for todo tasks with an `## Acceptance criteria` section, `Backlog` for the rest. **`owner:lead` tasks are kept in Backlog** so a builder's `next` never offers them (Paper Plane has no per-role label filter); a lead finds them with `list label=owner:lead`.
- The 184 finished task files (T-101 on) were imported afterwards as `Done` tickets `RUY-178..RUY-361`, with their Outcome in the description, so full-text search and the duplicate check cover them (`scripts/paperplane-import-done.py`, re-runnable: it skips ids that already have a ticket). Not imported: the work before T-132 that exists only in `STATUS-done.md` (no task files). The two or three "Dropped" outcomes are `Done`, not `Cancelled`, because their Outcome does not start with "Dropped".
- Re-running the open-task importer needs an empty project.
- The importer is `scripts/paperplane-import.py` (usage: `py -3.12 -I scripts/paperplane-import.py <base url> <token file>`; it refuses a non-empty `RUY`).
- Pilot ticket: `RUY-177` (T-341a, a split-off of T-341 item 4), claimed, handed over, reviewed and merged as 6ffcd85.

## Conventions

- **Priority stays `none`** except for something truly urgent. Paper Plane ranks any set priority above `none`, so a "low" ticket would jump ahead of the whole board. Order is the board order (`sort_order`); to move a ticket up use `update sort_order=...`.
- **Outcome:** a ticket has no Outcome field. The builder's `move ... evidence=` is the `Verified:` line (host / host (vm pending: ...) / vm / unverified / hw), and a `comment` starting `Outcome:` holds the rest; the lead copies both into the task file when it lands, as long as the files exist.
- **Handing over** needs `branch`, `commit` and `evidence`; only the lead moves to `Done`, after a recorded `approve`.
- A split-off item gets its own ticket (a `parent` or `relates` link to the original), not a letter suffix.
- Builders get a token with role `builder` and project `RUY` (the owner creates it, or a lead with the `tokens` permission once that is deployed). Tokens never go in the repo, a commit or a log.

## MCP servers and usage per ticket (lead-12, 2026-11-12, owner's go-ahead)

- Three MCP servers in the **local** scope of this checkout (`~/.claude.json`, not the repo; added with `~/.local/bin/claude.exe mcp add --scope local --transport http paperplane-<role> http://192.168.178.164:8687/mcp --header "Authorization: Bearer <token>"`): `paperplane-lead`, `paperplane-builder`, `paperplane-reviewer`, each with its own role's token, so a builder acts as the builder (`mcp__paperplane-builder__claim`), a reviewer as the reviewer. They load at **session start**: a session older than them still uses curl.
- Usage hooks in `.claude/settings.local.json` (git-ignored; the token is read from `C:\Users\FSYY\.paperplane\ruy-hooks.token`, role lead, made for the hooks): SessionStart registers the session for RUY, PostToolUse on `mcp__paperplane.*` opens and closes the per-ticket windows (claim, a reviewer's `get`, a verdict), Stop posts the token rows (`D:\dev\PaperPlane\scripts\paperplane_usage_hook.py`). **Only MCP calls attribute usage to a ticket**: dispatch builders and reviewers with the MCP tools, not curl. Check with `summary usage=true`.
- Telemetry (owner: always on): OpenTelemetry to Paper Plane is set in the user-level `~/.claude/settings.json` (`CLAUDE_CODE_ENABLE_TELEMETRY=1`, OTLP logs to the Paper Plane URL with the `telemetry` token), so every Claude Code session on this PC reports its token counts; the transcript hook runs as well (rows are keyed by request id, no double count).

## Known gaps (to decide before the files go away)

- No Outcome slot; no custom fields (the header is labels); ticket keys are `RUY-n`, not `T-nnn`.
- The open backlog is in Paper Plane only: the public repo does not show it and it is not exported (owner, 2026-11-12). The board lint is gone (no board file left to check).
- About 4,600 `T-nnn` mentions in specs and docs link to task files.
- Paper Plane creating a ticket with a duplicate label returned a 500 (the importer de-duplicates).
