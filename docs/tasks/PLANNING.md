# Planning sessions: who creates tasks

Roles are defined in [`docs/LEAD.md`](../LEAD.md). **The Opus lead is the default planner**: planning is step 4 of every lead session. A standalone planning session (any model) is fine for a routine refill; the next lead re-checks its tasks.

| Role | Started with | Creates tasks? |
|---|---|---|
| **Lead** (Opus) | "Run a lead session following docs/LEAD.md." | Yes. It also reviews, verifies, decides technical questions and marks tasks `Owner: lead`. |
| **Builder** (normal) | "Do the next task from docs/STATUS.md, following CLAUDE.md." | No. It only adds one-line items to the **Inbox** in `docs/STATUS.md`, except when a new task is required to finish its own (see `README.md`). |
| **Planner** | "Run a planning session following docs/tasks/PLANNING.md." | Yes. It turns Inbox items and spec gaps into task files and orders the board. It writes no product code. |
| **Owner** (you) | Anything | Can add Inbox items, ask the planner for features, change priorities, and answer open decisions |

## When to run a planner session

Run one when any of these is true. Builders check this at session start and stop if they find nothing to do.
- Fewer than **3** `todo` tasks have all their dependencies `done`.
- The Inbox has **5 or more** items.
- Every task of the current roadmap phase (`docs/specs/00-overview.md` §6) is `done`.
- The owner asks, or answers an open decision that unlocks new work.

## Planner procedure

1. **Read:**
   - `docs/STATUS.md` (board, Inbox, blockers, open decisions, last ~5 log entries);
   - the Outcomes of tasks done since the last planning entry;
   - `docs/specs/00-overview.md` §2 (scope/MVP) and §6 (roadmap, exit criteria);
   - the spec sections for the current phase.
2. **Empty the Inbox.** For every item:
   - **turn it into a task**, or merge it into an existing `todo` task's Scope;
   - or **drop it**, with a one-line reason in the planning log entry;
   - or **escalate** it to "Open owner decisions" when it needs one.
   Remove each item from the Inbox once it is handled.
3. **Fill the queue.** Compare the phase exit criteria with what exists. Write tasks for the missing pieces until there are **8–12 ready-or-nearly-ready `todo` tasks**. Prefer:
   - work that **can be built and tested on this host** (see `CLAUDE.md`);
   - contracts (`api/dbus`) before UI that depends on them;
   - small fixes and debt from the Inbox before new features, when they touch code that upcoming tasks will build on.
4. **Write each task with `TEMPLATE.md`:**
   - concrete Scope;
   - acceptance criteria that each name a test or a screenshot;
   - "Read first" pointing at the exact spec sections and existing code;
   - Hints carrying lessons from previous Outcomes (pitfalls found, patterns established);
   - size S or M (split anything bigger).
   Number tasks from the next free id in their range (`README.md`).
5. **Order the board:** dependencies first, then value. Set **NEXT**. Re-check that every existing `todo` task is still accurate against what was actually built, and fix stale scope or hints.
6. **Never** plan around an owner-level question (legal, licence, product scope, publishing, spending). Add it to "Open owner decisions" with options and a recommendation instead.
7. **Log and commit.** Add a session-log entry "Planning" (tasks added, Inbox items handled or dropped and why, decisions escalated), then commit as `docs: plan <short summary>`. Run `dev.ps1 test` before committing; it must stay green, even though planning touches docs only.

## Lessons from past sessions (apply when writing tasks)

- **Split shared infrastructure from features.** T-105 had to invent a page modal layer and scrollable settings panes on the way, and grew to about 1,500 lines. When a feature needs new shared plumbing, make the plumbing its own small task that the feature depends on.
- **Don't freeze contracts in task text.** Write "extend the contract if needed", not "do not change the contract". Contracts are drafts until release (`CLAUDE.md`).
- **Prefer visible-behaviour criteria over implementation details.** A criterion like "signal X has args (a, b)" forced a deviation in T-105. State what the user sees, and leave the signatures to the builder.

## Quality bar for a task (the planner checks every task against this)

- A builder who has never seen the conversation that produced it can finish it from the file and the linked docs alone.
- Every acceptance criterion is observable by a test or screenshot. "Works", "looks good" and "is robust" are not criteria.
- It names the reference pattern to copy (e.g. `shell/src/profiles`, `ruya-profiles`, `PinPad.qml`).
- It says what's out of scope, especially the tempting next step.
