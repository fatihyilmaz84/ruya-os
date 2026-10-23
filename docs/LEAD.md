# Lead sessions (Opus)

RuyaOS is built by two kinds of AI session under the owner:

| Role | Model | Started with | Job |
|---|---|---|---|
| **Owner** | human | anything | Product direction, owner-level decisions (legal, licence, scope, spending, publishing), hardware, pushing to GitHub |
| **Lead** | Opus | "Run a lead session following docs/LEAD.md." | Direction, quality, planning, architecture, hard tasks, and keeping this system working |
| **Builder** | Sonnet | "Do the next task from docs/STATUS.md, following CLAUDE.md." | One task per session, exactly as specified |

The lead follows the root `CLAUDE.md` (rules, commit format, definition of done) **plus** this file. Every lead session starts cold, so continuity lives in [`LEAD-NOTES.md`](LEAD-NOTES.md). **Read it first; rewrite it last.**

## When to run a lead session

- After every **3–5 builder tasks** (keeps review diffs reviewable).
- When a builder stops because no task qualifies, or recommends planning (Inbox ≥ 5).
- When a builder marks a task `blocked`, or the same task failed twice.
- After the owner answers an open decision, or wants something new.
- When something is visibly wrong: red CI, a broken build, the app misbehaving.

**Never run a lead and a builder at the same time.** They edit the same files (STATUS, tasks, specs). If `git status` shows uncommitted work you didn't make, stop, tell the owner, and don't touch it.

## Procedure (in order)

### 1. Orient (read only)
- `LEAD-NOTES.md`: the previous lead's concerns and the **review range** (last reviewed commit).
- `docs/STATUS.md`: all of it.
- `git log --oneline <last-reviewed>..HEAD`: everything since the last lead review.
- `git status` must be clean (see the rule above).

### 2. Verify independently (never trust an Outcome on its own)
- `.\scripts\dev.ps1 test` → must be ALL GREEN.
- `.\scripts\dev.ps1 shots`, then **look at the screenshots** of every screen that changed since the last review.
- If anything under `image/`, `services/` or the shell's Linux paths changed since the last VM verification: build the image, `make-disk.sh qcow2`, run `scripts\smoke-test.ps1` (recipe in `docs/dev-setup.md`). Run the update/rollback drill when updates, health checks or greenboot are touched.
- CI on GitHub: if the owner can share the Actions result, or it's visible from a pushed state, record it; otherwise note "CI not checked".
- Write the numbers down (test counts, boot result, timings). They go into the log entry.

### 3. Review each builder commit in the range
For each task commit, read the task file (Scope, criteria, Outcome) and the diff. Check:
- [ ] **Scope:** it did what the task asked, nothing silently extra, and it isn't missing a criterion.
- [ ] **Tests:** each acceptance criterion has a test that would fail without the feature. No assertion weakened, no `skip()`, no deleted test. Focus asserted after navigation.
- [ ] **Patterns:** follows the reference implementations and area `CLAUDE.md` rules (Theme tokens, focus rules, backend pattern, pure Rust core, contract-first).
- [ ] **Contracts:** XML, Rust service, mock and D-Bus client agree.
- [ ] **Security invariants** from `CLAUDE.md` hold.
- [ ] **Docs:** the specs describe what the code does now; the Outcome is honest and complete; every follow-up mentioned is in the Inbox.
- [ ] **Verification claims:** "verified in VM/host" matches what was actually run.

Act on findings:
- **Small and clear** (< ~50 lines, no design question): fix it yourself in a `review:` commit that names the task.
- **Larger:** add a task, or reopen the task with a "Review findings" section, and put it on the board.
- **Repeated mistake** (seen twice): change the system so it can't recur. Prefer an **automated check** (in `dev.ps1`, a test, a lint) over a new rule. If it has to be a rule, add it to the right `CLAUDE.md` and to `docs/tasks/PLANNING.md` "Lessons". Don't let instruction files grow without pruning: when you add a rule, look for one to merge or delete.

### 4. Plan
Run the planner procedure in [`docs/tasks/PLANNING.md`](tasks/PLANNING.md): empty the Inbox, fill the queue to 8–12 ready tasks, order the board, set NEXT. The lead is the default planner. A builder-run planning session is acceptable for routine refills, but the lead re-checks its tasks at the next review.

Mark tasks a builder should not take with `Owner: lead` (see below).

### 5. Direction and architecture
- **Compare progress with the roadmap** (`docs/specs/00-overview.md` §6). Is the current phase converging on its exit criteria, or drifting (lots of mock-only UI, little real integration)? Rebalance the board if so.
- **Technical decisions inside accepted ADRs:** decide, record them in the spec or in a new ADR marked *Accepted (lead, date)*, and move on.
- **Owner-level questions:** add them to "Open owner decisions" in STATUS. Give the options, a recommendation, and what is blocked until then. Ask the owner directly in your final reply.
- **Keep the specs coherent:** they describe what is built and the target, and say clearly which is which.

### 6. Lead-only work (optional, one task)
If time remains, take **one** `Owner: lead` task and do it with the full builder workflow (claim, build, verify, document, commit). Typical lead tasks:
- spikes and architecture prototypes (e.g. the ADR-002 compositor);
- image/platform work that needs VM debugging;
- security-sensitive changes;
- cross-cutting refactors of shared infrastructure;
- anything a builder failed at or blocked on twice.

### 7. Handoff
- **Rewrite** `LEAD-NOTES.md` (don't append forever):
  - the new review range (`HEAD` after your commits);
  - current concerns, ranked;
  - what the next lead should check first;
  - the quality-signal table row for this session.
- STATUS: move session-log entries beyond the newest five to `docs/STATUS-log.md` (top of its list), so builders read a short STATUS.
- STATUS: a session-log entry `· Opus · Lead` with: verification numbers, review findings (count, and what was fixed or filed), planning changes, decisions taken or escalated.
- Commit, as `docs: lead review <range>; plan …` plus any `review:` fix commits. **Do not push** unless the owner asks in this session (`CLAUDE.md` push rule, including the secret scan).

### 8. Report to the owner (final reply, short)
1. What was verified, and the result.
2. Quality findings: what was fixed, and what became tasks.
3. **Decisions needed from the owner:** each a concrete question with your recommendation.
4. What the next builder sessions will do (the top 3 of the board), and when the next lead session is due.

## Authority

| The lead may | The lead may not |
|---|---|
| Reorder the board, write, split, rescope or drop tasks | Push or publish without the owner's request in that session |
| Edit any code, test, spec or instruction file (`CLAUDE.md`s, `PLANNING.md`, this file) | Make owner-level decisions (legal, licence, product scope, spending, publishing) |
| Accept technical ADRs inside the accepted architecture | Change an *Accepted* owner ADR without asking |
| Reopen a builder's task, or revert a commit with a reason | Weaken the security invariants or any test gate |
| Install packages inside the WSL distribution | Install system software on Windows or change system settings |

## Task ownership marker

Task headers carry `Owner: builder` (the default when absent) or `Owner: lead`. Builders skip `Owner: lead` tasks when choosing work. On the STATUS board, lead tasks are prefixed **[lead]** in the title.
