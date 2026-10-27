# Planning: how tasks are created

Roles are in [`docs/LEAD.md`](../LEAD.md). **The Opus lead is the default planner** (step 4 of every lead session). A standalone planning session ("Run a planning session following docs/tasks/PLANNING.md.", any model) is fine for a routine refill; the next lead re-checks its tasks. A planner writes no product code.

## When to plan

Any of these is true (builders check at session start and stop if they find nothing to do):
- fewer than **3** `todo` tasks have all dependencies `done`;
- the Inbox has **5 or more** items;
- every task of the current roadmap phase (`docs/specs/00-overview.md` §6) is `done`;
- the owner asks, or answers a decision that unlocks work.

## Procedure

1. **Read:** `docs/STATUS.md` (all of it is short now), the Outcomes of tasks finished since the last planning entry, `00-overview.md` §2 (MVP) and §6 (roadmap, exit criteria), and the spec sections of the current phase.
2. **Empty the Inbox.** Each item becomes a task, is merged into a `todo` task's Scope, is dropped (one-line reason in the log entry), or is escalated to "Open owner decisions". Remove it from the Inbox.
3. **Fill the queue** to **8–12 ready or nearly ready `todo` tasks** by comparing the phase exit criteria with what exists. Prefer work that can be built **and verified on this host**, contracts before the UI that depends on them, and small debt that upcoming tasks build on. Keep every mock-only UI task paired with the task that builds its real service.
4. **Write each task from `TEMPLATE.md`** (quality bar below), numbered from the next free id.
5. **Order the board** (dependencies first, then value), set **NEXT**, and re-check every existing `todo` task against what was actually built; fix stale scope and hints. Board rows list open tasks only (`scripts/lint-board.ps1`).
6. **Never plan around an owner-level question** (legal, licence, product scope, publishing, spending): add it to "Open owner decisions" with options and a recommendation.
7. **Log and commit:** a session-log entry (at most 4 lines: tasks added, Inbox items handled or dropped, decisions escalated), commit as `docs: plan <summary>`, `dev.ps1 test` green first.

## Quality bar for a task

- A builder who never saw the conversation can finish it from the file and the linked docs alone.
- Every acceptance criterion is observable by a named test or screenshot ("works", "looks good", "is robust" are not criteria).
- It names the reference pattern to copy (`shell/src/network`, `ruya-profiles`, `PinPad.qml`, …) and what is out of scope, especially the tempting next step.
- Size S or M.

## Lessons from past sessions (apply when writing tasks)

- **Split shared infrastructure from features.** T-105 invented a modal layer and scrollable panes on the way and grew to ~1,500 lines.
- **Don't freeze contracts in task text.** Write "extend the contract if needed" (contracts are drafts until release).
- **Service-facing work gets a VM criterion** naming the check (`smoke-test.ps1`, a `scripts/vm-*` script, a VM screenshot): a task that changes a service, a unit, the image or a D-Bus client is not verified by mocks. Pure mock-only UI tasks don't need one.
- **Prefer visible-behaviour criteria** over signatures: state what the user sees, leave the signatures to the builder.
- **Host-only is a phase, not a plan.** When the VM is unavailable, keep real-service tasks queued behind the blocker and fill the gap with contract + mock + UI tasks, but each contract task should name its service task so the mock can't drift unnoticed.
