# Tasks

Each work item is one file, `T-<nnn>-<slug>.md`, and holds everything an implementer needs. The board in `docs/STATUS.md` lists every task with its status; the task file holds the detail.

## Lifecycle

`todo` → `in-progress` → `done`, or `blocked` (with a reason that names what would unblock it).

- Status lives in **both** places: the task file's header line and the STATUS board. Keep them identical.
- A task is `done` only when its **Definition of done** (root `CLAUDE.md`) holds.
- Never delete a task. To drop one, set it to `done` with Outcome "Dropped: <reason>", or `blocked`.

## Numbering

| Range | Meaning |
|---|---|
| `T-0xx` | Phase 0 (foundation). Done items are recorded in STATUS. |
| `T-1xx` | Phase 1–2 work that can be built and tested on the Windows host |
| `T-2xx` | Phase 3+ work that can be built and tested on the Windows host |
| `B-xxx` | Blocked on a Linux machine, CI or hardware. Kept in STATUS with what they need. |

## Who creates tasks

- **Lead sessions** (Opus, `docs/LEAD.md`) and **planner sessions** create almost all tasks. They turn the Inbox (in `docs/STATUS.md`) and spec gaps into task files, and keep the queue full. The procedure is in [`PLANNING.md`](PLANNING.md).
- **Builder sessions** add one-line Inbox items for anything they discover. They write a task file only when their current task can't be finished without it, using the steps below.
- **The owner** adds Inbox items or asks a planner for features at any time.

## Writing a new task

1. Copy `TEMPLATE.md` to the next free number.
2. Fill in every section. Acceptance criteria must be **observable** (a test assertion or a screenshot check), not vague ("works well").
3. Size it so one session can finish it: about S = < 300 lines, M = 300–800, L = split it.
4. Add it to the STATUS board as `todo` with its dependencies. Don't start it in the same session unless it blocks your current task.

## Sections every task has

| Section | Contents |
|---|---|
| Header line | `Status · Phase · Depends · Area · Size`, plus `· Owner: lead` for tasks builders must skip (default: builder) |
| Goal | One or two sentences: the user-visible result |
| Read first | Spec sections and files to read before starting |
| Scope | Numbered, concrete requirements |
| Out of scope | What not to do, even though it's tempting |
| Acceptance criteria | Checkboxes, each verified by a named test or screenshot |
| Verification | Commands to run |
| Docs to update | Which spec sections and files |
| Hints | Known pitfalls and suggested approach (non-binding) |
| Outcome | **Filled in by the implementer:** what was done, files, verification, deviations, follow-ups |
