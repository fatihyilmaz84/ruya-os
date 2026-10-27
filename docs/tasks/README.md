# Tasks

One file per work item, `T-<nnn>-<slug>.md`, holding everything an implementer needs. The board in `docs/STATUS.md` lists the **open** tasks in recommended order; the task file holds the detail and, once finished, the record of what was done.

## Lifecycle

`todo` → `in-progress` → `done`, or `blocked` (with a reason that names what would unblock it).

- The **file header** (`Status: …`) is the truth. While a task is open the board row must show the same status; when it becomes `done`, **delete its board row**. `scripts/lint-board.ps1` (part of `dev.ps1 test` and CI) fails on a mismatch, a missing row or a done row.
- `done` only when the **Definition of done** (root `CLAUDE.md`) holds. The Outcome starts with `Verified:` using the STATUS legend (host / vm / unverified / hw), so the lead can see at a glance what ran where.
- Never delete a task. To drop one, set it `done` with Outcome "Dropped: <reason>", or `blocked`.

## Numbering

`T-0xx` Phase 0 (all done, history in `docs/STATUS-done.md`) · `T-1xx` the host/VM work of Phases 1–3 so far (numbers continue upward, whatever the phase; the header says the phase) · `B-xxx` blockers that need hardware or a decision, kept in STATUS with what they need.

## Who writes tasks

Lead and planner sessions write almost all of them (procedure and quality bar: [`PLANNING.md`](PLANNING.md); roles: `docs/LEAD.md`). Builders add one-line Inbox items, and write a task file only when their own task can't finish without it. The owner can add Inbox items or ask for features at any time.

## Writing a task

1. Copy `TEMPLATE.md` to the next free number; fill in every section.
2. Acceptance criteria must be **observable**: a named test, or a screenshot and what it must show. Not "works well".
3. Size it for one session: S < 300 lines, M 300–800, L = split it.
4. Add it to the STATUS board as `todo` with its dependencies. Don't start it in the same session unless it blocks your current task.

The header line is `Status · Phase · Depends · Area · Size`, plus `· Owner: lead` for tasks builders must skip (board title prefixed **[lead]**).
