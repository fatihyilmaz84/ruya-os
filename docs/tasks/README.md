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

1. Copy `TEMPLATE.md` to the next free number; fill in every section. The quality bar and the sizes (S, M, split anything bigger) are in [`PLANNING.md`](PLANNING.md) only.
2. Add it to the board as `todo`. The board's Depends column lists the header's dependencies that are not yet `done` (plus `owner`); a task that waits for the owner is `blocked`, not `todo`. Don't start it in the same session unless it blocks your current task.

The header line is `Status · Phase · Depends · Area · Size`, plus `· Owner: lead` for tasks builders must skip (board title prefixed **[lead]**), plus `· Complexity: simple | normal | complex | hard` (default normal; the model tier, `LEAD.md` "Lead efficiency"), plus `· Developer surface: none | internal | public-API | public-format` (ADR-022, `docs/developers/api-surface.md`). The planner sets the surface when the task is written; **a missing field means `none`**, so older task files stay valid (`lint-board.ps1` reads only `Status:`). `public-API` and `public-format` add to the Definition of done: the XML carries the stability tag, a paragraph in `docs/developers/`, a minimal sample, mock support for off-device testing and a conformance test; the implementing builder writes them in the same commit and `ruya-api-reviewer` checks the diff.
