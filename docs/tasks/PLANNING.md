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
7. **Log and commit:** a session-log entry (at most 700 characters: tasks added, Inbox items handled or dropped, decisions escalated), commit as `docs: plan <summary>`, `dev.ps1 test` green first.

## Quality bar for a task

- A builder who never saw the conversation can finish it from the file and the linked docs alone.
- Every acceptance criterion is observable by a named test or screenshot ("works", "looks good", "is robust" are not criteria).
- **Visual-only tasks** (card look, colours, spacing): one test per behaviour (a token applied, a state that changes the look, geometry at a real caller's size: screenshots passed 2.2:1 "16:9" cards, T-113) plus the screenshots, not a test per tier/theme pair.
- It names the reference pattern to copy (`shell/src/network`, `ruya-profiles`, `PinPad.qml`, …) and what is out of scope, especially the tempting next step.
- **UI tasks** link the `04-design-system.md` sections and components they use, and say which tokens or components (if any) the task may add. A screen that needs a component not in `04` §5 gets a design step first (lead or a `design:` task), not an improvised one.
- **UI tasks also carry a "UX" acceptance line** (owner, 2026-11-07): "UX: from every new state Back leaves; focus lands sensibly after open/close/error; readable at 10 ft; the Outcome has a `UX notes:` line". The UX and design reviewers (`.claude/agents/`) check it on the branch.
- **Developer surface (ADR-022):** the header says `Developer surface: none | internal | public-API | public-format`. Ask of every task: can an app, a modder or a player's tool see or call this? If yes it is `public-*`, the capability must be on the approved list in `docs/developers/api-surface.md` (a new one needs the owner first, rule 6), and the task carries the extra Definition of done there (XML tag, developer-guide paragraph, sample, mock, conformance test, with a test or script named). A public task is never planned without its doc and sample in the same task or a named sibling. A first-party app task may use only the public surface.
- Size S (up to ~150 changed lines) or M (up to ~400); split anything bigger.
- Its Area and named files let the lead tell whether two tasks can run in parallel (LEAD.md 4b).

## Lessons from past sessions (apply when writing tasks)

- **Split shared infrastructure from features.** T-105 invented a modal layer and scrollable panes on the way and grew to ~1,500 lines.
- **Don't freeze contracts in task text.** Write "extend the contract if needed" (contracts are drafts until release).
- **Service-facing work gets a VM criterion** naming the check (`smoke-test.ps1`, a `scripts/vm-*` script, a VM screenshot): a task that changes a service, a unit, the image or a D-Bus client is not verified by mocks. Pure mock-only UI tasks don't need one. Label it **"VM (this task)"** when the risk is in the image (packaging, units, bus policy, hardening) or **"VM (lead run)"** for service or shell logic (owner, 2026-11-03; root `CLAUDE.md`, Host).
- **Prefer visible-behaviour criteria** over signatures: state what the user sees, leave the signatures to the builder.
- **Host-only is a phase, not a plan.** When the VM is unavailable, keep real-service tasks queued behind the blocker and fill the gap with contract + mock + UI tasks, but each contract task should name its service task so the mock can't drift unnoticed.
- **VM checks parse JSON, never key order.** `busctl` text output lists `a{sv}` keys in service-defined order (a Rust `HashMap` reorders them per process): use `busctl --json=short` and python3 (`vm-update-check.sh`), or the check fails on a correct service (T-188).
- **A test that cannot fail is the commonest review finding** (T-167, T-176, T-184: a wait on an undefined QML property is `wait(NaN)`, i.e. no wait). A task's criteria name the revert that must turn each new test red (`revert-check.ps1`).
