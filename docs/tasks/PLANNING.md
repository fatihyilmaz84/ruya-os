# Planning: how tasks are created

Roles are in [`docs/LEAD.md`](../LEAD.md). **The Opus lead is the default planner** (step 4 of every lead session). A standalone planning session ("Run a planning session following docs/tasks/PLANNING.md.", any model) is fine for a routine refill; the next lead re-checks its tasks. A planner writes no product code.

## When to plan

Any of these is true (builders check at session start and stop if they find nothing to do):
**Paper Plane is the source of truth (owner, 2026-11-12):** tasks are tickets in project `RUY` (http://192.168.178.164:8687); `docs/tasks/T-*.md` and `docs/STATUS*.md` are a frozen archive, never edited. A planner uses the lead token (`create`, `update`, `move`).

- fewer than **3** Ready tickets (`next` offers nothing, or almost nothing);
- **5 or more** tickets labelled `inbox`;
- every ticket of the current roadmap phase (`docs/specs/00-overview.md` §6, label `phase:N`) is Done;
- the owner asks, or answers a decision that unlocks work.

## Procedure

1. **Read:** `summary`, the `Outcome:` comments of tickets finished since the last planning pass (`changes`), `00-overview.md` §2 (MVP) and §6 (roadmap, exit criteria), and the spec sections of the current phase.
2. **Empty the inbox** (`list label=inbox`). Each ticket becomes a Ready task (rewrite its description from the template, remove the `inbox` label), is merged into another ticket's Scope (comment there, Cancelled here), is dropped (Cancelled with a one-line reason), or becomes an `owner-decision` ticket.
3. **Fill the queue** to **8–12 Ready tickets** by comparing the phase exit criteria with what exists. Prefer work that can be built **and verified on this host**, contracts before the UI that depends on them, and small debt that upcoming tasks build on. Keep every mock-only UI task paired with the task that builds its real service.
4. **Write each ticket from `TEMPLATE.md`** (quality bar below; `create` shows similar tickets, so check for duplicates): the description holds Goal, Read first, Scope, Out of scope, Acceptance criteria, Hints; the header becomes labels (`phase:N`, `area:x`, `size:S|M|epic`, `owner:builder|lead`, `complexity:x`, `surface:x`); dependencies are `blocks` relations; an epic is the `parent` of its children. Titles are plain (no `T-nnn`: new tickets are known by `RUY-n`). **Horizon:** a full description only for work that can start within about two lead sessions; anything further is a short Backlog ticket under its epic. A spike or spec ticket lists, as a criterion, the tickets it must rewrite.
5. **Order the queue** (dependencies first, then value; `sort_order`, which the `update` tool lacks: `PATCH /api/tickets/RUY-n` with `{"sort_order": n}`, `next` takes the lowest; priority stays `none`), move what is ready to Ready (lead tickets stay in Backlog), and re-check every Ready ticket against what was actually built; fix stale scope and hints.
6. **Never plan around an owner-level question** (legal, licence, product scope, publishing, spending): `create` an `owner-decision` ticket with options and a recommendation.
7. **Record:** the planning pass goes into `LEAD-NOTES.md` (tickets added, inbox handled or dropped, decisions escalated); commit any spec changes as `docs: plan <summary>`.

## Quality bar for a task

- A builder who never saw the conversation can finish it from the file and the linked docs alone.
- Every acceptance criterion is observable by a named test or screenshot ("works", "looks good", "is robust" are not criteria).
- **Visual-only tasks** (card look, colours, spacing): one test per behaviour (a token applied, a state that changes the look, geometry at a real caller's size: screenshots passed 2.2:1 "16:9" cards, T-113) plus the screenshots, not a test per tier/theme pair.
- It names the reference pattern to copy (`shell/src/network`, `ruya-profiles`, `PinPad.qml`, …) and what is out of scope, especially the tempting next step.
- **UI tasks** link the `04-design-system.md` sections and components they use, and say which tokens or components (if any) the task may add. A screen that needs a component not in `04` §5 gets a design step first (lead or a `design:` task), not an improvised one.
- **UI tasks also carry a "UX" acceptance line** (owner, 2026-11-07): "UX: from every new state Back leaves; focus lands sensibly after open/close/error; readable at 10 ft; the Outcome has a `UX notes:` line". The UX and design reviewers (`.claude/agents/`) check it on the branch.
- **Developer surface (ADR-022):** the header says `Developer surface: none | internal | public-API | public-format`. Ask of every task: can an app, a modder or a player's tool see or call this, **or does it change what a running app experiences** (lifecycle, focus, freezing, input routing, audio, windowing, sandbox; T-457 froze games and was planned `none`, so the developer guide went stale)? If yes it is `public-*`, the capability must be on the approved list in `docs/developers/api-surface.md` (a new one needs the owner first, rule 6), and the task carries the extra Definition of done there (XML tag, developer-guide paragraph, sample, mock, conformance test, with a test or script named). A public task is never planned without its doc and sample in the same task or a named sibling. A first-party app task may use only the public surface.
- **One owner per thing.** Before writing, grep the open tasks for the same contract, table, store, screen or dialog; a second task reads or extends the first one's and says so. When a new ADR lands, the same session rewrites or marks every open task it contradicts (a ruling line under the header).
- **Trust boundaries (security):** a task that adds a unit or bus policy, a network listener, a parser of outside data (files from USB, the web, an app, another profile) or lets a privileged service touch a profile's files names the attacker and carries the template's abuse-test line; a system service never gets a path into a profile's home (`03`); a new unit or policy is "VM (this task)"; `Complexity: complex` or higher, so the reviewer is Opus.
- An app-facing call depends on T-352 (`Platform1`) or is cut into its own task; the internal service half does not wait for it.
- Size S (up to ~150 changed lines) or M (up to ~400), in one service or one screen; split anything bigger.
- Its Area and named files let the lead tell whether two tasks can run in parallel (LEAD.md 4b).

## Lessons from past sessions (apply when writing tasks)

- **Split shared infrastructure from features.** T-105 invented a modal layer and scrollable panes on the way and grew to ~1,500 lines.
- **Don't freeze contracts in task text.** Write "extend the contract if needed" (contracts are drafts until release).
- **Service-facing work gets a VM criterion** naming the check (`smoke-test.ps1`, a `scripts/vm-*` script, a VM screenshot): a task that changes a service, a unit, the image or a D-Bus client is not verified by mocks. Pure mock-only UI tasks don't need one. Label it **"VM (this task)"** when the risk is in the image (packaging, units, bus policy, hardening) or **"VM (lead run)"** for service or shell logic (owner, 2026-11-03; root `CLAUDE.md`, Host).
- **Prefer visible-behaviour criteria** over signatures: state what the user sees, leave the signatures to the builder.
- **Host-only is a phase, not a plan.** When the VM is unavailable, keep real-service tasks queued behind the blocker and fill the gap with contract + mock + UI tasks, but each contract task should name its service task so the mock can't drift unnoticed.
- **VM checks parse JSON, never key order.** `busctl` text output lists `a{sv}` keys in service-defined order (a Rust `HashMap` reorders them per process): use `busctl --json=short` and python3 (`vm-update-check.sh`), or the check fails on a correct service (T-188).
- **A test that cannot fail is the commonest review finding** (T-167, T-176, T-184: a wait on an undefined QML property is `wait(NaN)`, i.e. no wait). A task's criteria name the revert that must turn each new test red (`revert-check.ps1`). Its cousins: a VM step that SKIPs when a tool is missing (T-322, T-376; `lint-vm-checks.ps1` now refuses `jq`, the image has none) and a test retry that waits out a wrong in-between state (T-361; `shell/PATTERNS.md`: in-between states are one read).
- **Safety and comfort defaults are written per device kind** (lead-7: T-360's task said "new outputs start at 100 %", which would have meant 100 % in headphones). For volumes, brightness, rumble, timeouts: name the safe default for the risky kinds and say that unknown counts as risky.
