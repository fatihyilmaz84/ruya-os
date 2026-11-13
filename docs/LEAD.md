# Lead sessions (Opus)

RuyaOS is built by two kinds of AI session under the owner:

| Role | Model | Started with | Job |
|---|---|---|---|
| **Owner** | human | anything | Product direction, owner-level decisions (legal, licence, scope, spending, publishing), hardware |
| **Lead** | Sonnet high for the loop, Opus for architecture-level planning ("Lead efficiency") | "Run a lead session following docs/LEAD.md." | Direction, quality, planning, architecture, hard tasks, and keeping this system working |
| **Builder** | by the ticket's `complexity:` label (Sonnet; Opus for complex and hard) | The lead dispatches the `ruya-builder` agent (`.claude/agents/`) into a worktree; or the owner: "Do the next task from docs/STATUS.md, following CLAUDE.md." | One task, exactly as specified, ending in a HANDOFF |
| **Reviewer** | Opus | The lead dispatches the `ruya-reviewer` agent on a builder's branch | A verdict (APPROVE or CHANGES_REQUESTED) before the branch is merged; never edits |
| **UX / design reviewers** | Sonnet | The lead dispatches `ruya-ux-reviewer` and `ruya-design-reviewer` on UI diffs only, in parallel with the reviewer | Read-only findings: dead ends and spec violations (blocking), spec gaps, notes; capped (4b) |
| **API reviewer / devdocs auditor** | Sonnet | The lead dispatches `ruya-api-reviewer` on diffs that touch a public API or format, and `ruya-devdocs-auditor` before a release (ADR-022) | Read-only findings: least privilege, abuse cases, per-profile privacy, docs/sample/mock coverage (blocking vs notes); the auditor follows `docs/developers` as a newcomer and reports gaps as Inbox lines; capped (4b) |

The lead follows the root `CLAUDE.md` (rules, commit format, definition of done) **plus** this file. Every lead session starts cold, so continuity lives in [`LEAD-NOTES.md`](LEAD-NOTES.md). **Read it first; rewrite it last.**

## When to run a lead session

- After every **3–5 builder tasks** (keeps review diffs reviewable).
- When a builder stops because no task qualifies, or recommends planning (5 or more `inbox` tickets).
- When a builder marks a task `blocked`, or the same task failed twice.
- After the owner answers an open decision, or wants something new.
- When something is visibly wrong: red CI, a broken build, the app misbehaving.

**Builders the lead dispatches work only in their own worktrees; nobody else edits the main checkout while a lead session runs, and a builder session the owner starts directly never runs alongside a lead.** Two writers in one checkout mixed three tasks' work on 2026-10-28. If `git status` shows uncommitted work you didn't make, stop, tell the owner, and don't touch it.

## Procedure (in order)

### 1. Orient (read only)
- `LEAD-NOTES.md`: the previous lead's concerns and the **review range** (last reviewed commit).
- Paper Plane (the source of truth since 2026-11-12, `CLAUDE.md`): `summary usage=true` (counts, in flight, blocked, waiting on the owner, stale claims, tokens), `list label=inbox`, `list label=owner-decision`, `list label=vm-queue`, `formation` with no arguments (the goals and their progress; `PLANNING.md` step 4), `changes` since the cursor in `LEAD-NOTES.md`. Pick builder work goal by goal: finish a formation's ready tickets before opening the next one. `docs/STATUS*.md` and `docs/tasks/` are a frozen archive: never edit them.
- `git log --oneline <last-reviewed>..HEAD`: everything since the last lead review.
- `git status` must be clean (see the rule above).

### 2. Verify independently (never trust an Outcome on its own)
- `.\scripts\dev.ps1 test` → must be ALL GREEN.
- `.\scripts\dev.ps1 shots`, then **look at the screenshots** of every screen that changed since the last review. Skip `shots` when no `.qml` file changed in the range.
- **VM queue** (the `vm-queue` ticket): build one image of `main`, `make-disk.sh qcow2`, `scripts\smoke-test.ps1` (recipe in `docs/dev-setup.md`), then each queued task's check. Record each result as a comment on its ticket (`Verified: vm`, with the numbers) and update the `vm-queue` ticket; a failed check reopens its ticket or files a new one. Also build when anything under `image/`, `services/` or the shell's Linux paths changed since the last VM verification and nothing in the range was VM-verified. Run the update/rollback drill when updates, health checks or greenboot are touched. End with `scripts\free-space.ps1`.
  - **ISO only when needed (owner, 2026-11-09):** each image build ends with the oci-archive update of the Dell (`docs/dev-setup.md`, "When to build the ISO"); build the ISO and run `vm-iso-check.ps1` only when installer, kickstart, first-boot, partitioning or `bib` config changed, for a milestone or release candidate, or when the owner asks. First-boot features are tested on a fresh qcow2 or after a scripted factory reset of the Dell.
- CI on GitHub: if the owner can share the Actions result, or it's visible from a pushed state, record it; otherwise note "CI not checked".
- Write the numbers down (test counts, boot result, timings). They go into the log entry.

### 3. Review each builder commit in the range
Branches merged by the build loop (4b) already carry a `ruya-reviewer` APPROVE: skim their diff and the review, and spend the time on commits from direct builder sessions. For those, read the task file (Scope, criteria, Outcome) and the diff. With four or more commits, hand the reading to parallel read-only subagents (one per area, each given this checklist and its commits), then verify every finding in the code before acting on it. Check:
- [ ] **Scope:** it did what the task asked, nothing silently extra, and it isn't missing a criterion.
- [ ] **Tests:** each acceptance criterion has a test that would fail without the feature. No assertion weakened, no `skip()`, no deleted test. Focus asserted after navigation. Visual-only work: one test per behaviour plus screenshots (`PLANNING.md`, Quality bar).
- [ ] **Patterns:** follows the reference implementations and area `CLAUDE.md` rules (Theme tokens, focus rules, backend pattern, pure Rust core, contract-first).
- [ ] **Contracts:** XML, Rust service, mock and D-Bus client agree.
- [ ] **Security invariants** from `CLAUDE.md` hold.
- [ ] **Design:** UI matches `docs/specs/04-design-system.md`: tokens and components only, the §8 screenshot review list holds; any new token or component came with the spec update in the same commit (§8). Builder Inbox lines `design: needs …` are design decisions for you.
- [ ] **Docs:** the specs describe what the code does now; the Outcome comment is honest and complete; every follow-up mentioned is an `inbox` ticket.
- [ ] **Verification claims:** "verified in VM/host" matches what was actually run.

Act on findings:
- **Small and clear** (< ~50 lines, no design question): fix it yourself in a `review:` commit that names the task.
- **Larger:** `create` a ticket, or reopen the ticket (`move` it back with a "Review findings" comment).
- **Repeated mistake** (seen twice): change the system so it can't recur. Prefer an **automated check** (in `dev.ps1`, a test, a lint) over a new rule. If it has to be a rule, add it to the right `CLAUDE.md` and to `docs/tasks/PLANNING.md` "Lessons". Don't let instruction files grow without pruning: when you add a rule, look for one to merge or delete.

### 3b. Keep the instructions lean (every lead session, five minutes)
Every builder session pays to read these files again on every turn, so they have size budgets. Check them (`wc -c`) and prune when over:

| File | Budget |
|---|---|
| root `CLAUDE.md` | about 10 KB |
| area `CLAUDE.md` (`shell/`, `services/`, `image/`) | about 7 KB each |
| a ticket's description | about 8 KB; split bigger |

How-tos and catalogues belong in a reference file that a task links (`shell/PATTERNS.md`, `docs/dev-setup.md`), rules belong in `CLAUDE.md`, and a rule that a script can enforce belongs in a script (`scripts/lint-*.ps1`), not in prose. When you add a rule, delete or merge one.

### 4. Plan
Run the planner procedure in [`docs/tasks/PLANNING.md`](tasks/PLANNING.md): turn the `inbox` tickets into Ready tickets (or close them), keep 8–12 Ready tickets, order them (`sort_order`, via REST `PATCH`: `PLANNING.md` step 5). The lead is the default planner. A builder-run planning session is acceptable for routine refills, but the lead re-checks its tasks at the next review.

Lead tickets carry the label `owner:lead` and stay in Backlog, so a builder's `next` never offers them.

### 4b. Build loop: dispatch, review, merge (owner, 2026-11-04)
Keep going while ready tasks remain and the owner hasn't said stop.
1. **Pick** up to **two** ready builder tasks in different areas whose files don't overlap; a task written more than a week ago is re-read against the ADRs and its header ruling first, and fixed before the claim (a lane counts from claim to merge, also while its branch is in review: a round 2 resumes its builder); at most one with a "VM (this task)" criterion in flight (one image build at a time). **Review every ticket before dispatching it (owner, 2026-11-13):** read it against the code it will change on today's `main` (contracts, the existing tables and helpers it must reuse, merged tickets that moved its ground, the VM check it names) and write the findings as a "Lead review before the build" comment; RUY-40's comment is the example. `Cargo.lock`, translations and `shell/CMakeLists.txt` are shared, append-mostly files: the branch merged second resolves them. A `.ts` conflict: `git show :2:<ts> > ours`, `:3:` > theirs, `lconvert -i ours -i theirs -o <ts>`, then `lconvert -no-obsolete -i <ts> -o <ts>` (strings that moved files stay as obsolete entries, which the translation lint refuses; lead-17), then `& "$env:ProgramFiles\CMake\bin\cmake.exe" --build shell\build-win --config Release --target update_translations` to refresh the `.ts` files from the sources (a bare `cmake` is devkitPro's here). `dev.ps1` finds the real CMake itself and regenerates the lupdate project when `shell\CMakeLists.txt` is newer (T-169): no manual step after a merge that adds a `.qml`.
2. **Worktree:** the builder claims the ticket itself (no claim commit on `main`). `git worktree add D:\dev\RuyaOS-worktrees\RUY-n -b t/RUY-n-slug main` (make worktrees yourself, so the path is known; not the Agent tool's `isolation`). Run every `git worktree` command from the **Bash tool** (Git for Windows): in PowerShell `git` resolves to devkitPro's MSYS2 git, which writes `/d/...` link paths the other git can't read, and back (T-163, T-167 on 2026-11-04; fix: rewrite `<worktree>\.git` and `.git\worktrees\<name>\gitdir` with `D:/...` paths).
3. **Dispatch** the `ruya-builder` agent in the background (if the type isn't loaded in this session, a `general-purpose` agent on `model: sonnet` told to follow `.claude/agents/ruya-builder.md`) with: the ticket `RUY-n`, worktree path, branch, round 1 (the agent file tells it how to reach Paper Plane). The ticket must be Ready (a lead-made ticket in Backlog: `update state=Ready` first).
4. **HANDOFF `done`:** the ticket is In Review; dispatch `ruya-reviewer` (Opus) with the ticket, worktree, branch and the HANDOFF; it records its verdict on the ticket. `partial`/`blocked`: answer and resume the same builder, split the ticket, or move it to Blocked. **A builder notification "waiting on its own background work" with no HANDOFF is a stall** (T-322, T-285, T-360): look at the worktree's last commit at once; if the round's work is committed, send the branch to the reviewer with "verify everything yourself" instead of waiting.
   - **Merging:** run `git merge` alone and check its exit before any bookkeeping commit; never chain `git add -A && git commit` after a merge (lead-7 sealed conflict markers in 03 that way; `lint-text.ps1` now refuses markers). A process started by hand on the Dell is stopped by its `app-flatpak-*.scope`, not its unit.
   - **Keep the lead's context lean (lead, 2026-11-07, retrospective):** HANDOFFs and REVIEWs are short by their agent files (the proofs live in the Outcome); a round 2 goes to the same agent with only the blocking list; in round 2 the reviewer runs `dev.ps1 docs` instead of `test` when only `docs/**/*.md` changed since its round 1 (`ruya-reviewer.md` step 3). A builder that cannot run a `vm-*-check.sh` for lack of an image gets a booted VM of the last image from the lead to try the script on (script-level bugs only: the product part stays `vm pending`).
   - **Review cost (owner, 2026-11-10, after lead-10 measured it):** reviewers run targeted checks, not the full `test` (`ruya-reviewer.md` step 3); the merge gate on `main` after each merge (`merge-gate.ps1`: the builder's green run of the same code, else the full `test`) is the gate (red: revert). Round 2+ is a delta check of the fix. A builder commits before its `shots` run: when its worktree has the round's commit and only `shots` is left, start the review from that commit.
   - **UI diffs (owner, 2026-11-07; narrowed 2026-11-10):** only when the diff **changes what a screen looks like or adds a component, token, icon or copy** (a logic-only change in `shell/qml` gets the code review alone), dispatch `ruya-design-reviewer` (read-only, Sonnet, <= 150k tokens / 10 min) **in parallel** with `ruya-reviewer`, same inputs; add `ruya-ux-reviewer` (same limits) only for a **new screen, flow, modal or navigation path** (owner, 2026-11-11: on panels and rows that follow an existing pattern it found nothing blocking three times in lead-11, and its notes repeated the design review's). Only a clear dead end (UX) or a clear spec violation (design) blocks; the rest are notes and Inbox lines. Their blocking items go to the builder together with the code review's, in the same round; at most **one extra round** for them. A `SPEC GAP` finding is yours to decide: add the proposed text to `04` (or reject it in one line). Skip them for docs-only, service-only or test-only diffs.
   - **API diffs (ADR-022):** when the ticket has the label `surface:public-API` or `surface:public-format`, the HANDOFF has a `possibly public:` line, or the diff touches app-reachable XML, a bus policy, Flatpak permissions or an element tagged `org.ruyaos.Stability`, `docs/developers/` or `samples/`, or changes what a running app experiences (lifecycle, focus, freezing, input routing, audio, windowing, sandbox), also dispatch `ruya-api-reviewer` (read-only, Sonnet, <= 150k tokens / 10 min), in parallel with `ruya-reviewer`, same inputs. A clear charter violation, privilege or cross-profile leak, or a public element with no doc, sample or conformance test blocks; the rest are notes. Same one-extra-round rule. **The lead alone sets the `surface:` label** when planning (missing means `none`; tickets in flight are not changed). A `possibly public:` line in a HANDOFF is yours to decide at merge: keep it experimental and write the follow-up ticket (doc, sample, mock, conformance) if the capability is inside the owner-approved list in ADR-022 / `api-surface.md`; anything outside the list needs a Proposed ADR first, never a silent exposure. Before each release dispatch `ruya-devdocs-auditor` once and turn its inbox lines into tickets.
5. **CHANGES_REQUESTED:** send the blocking findings to the **same** builder (SendMessage, round + 1; it keeps its context). After round 2 still fails: fix it yourself, split it, or reopen it.
6. **APPROVE:** in the main checkout `git merge --no-ff t/RUY-n-slug`; `move` the ticket to Done; `create` one ticket labelled `inbox` (Backlog) per HANDOFF and review `inbox` line; if the evidence says `vm pending`, add the check to the `vm-queue` ticket (a comment); **then** `.\scripts\merge-gate.ps1 -Worktree <worktree>` on `main`, before removing the worktree (red: revert the merge and move the ticket back to Changes Requested). Lead verification after the merge (a VM run, a Dell run) is a comment on the ticket. It reuses the builder's green `dev.ps1 test` when main differs from that commit only in `docs\*.md` (then only `dev.ps1 docs` runs; owner, 2026-11-11: the same code was tested twice per merge), else runs the full `test`; either way it leaves the green marker that lets `push-main.ps1` skip its own run. While a full gate runs you may make the next worktree and dispatch its builder, but commit nothing on `main` until the gate ends (a commit, or an edit, during the run means no green marker). Remove the worktree (`git worktree remove --force`, then `git branch -d`): its `shell\build-win` and `services\target` cost ~4 GB.
7. The lead's handoff (`LEAD-NOTES.md`) lists the tickets merged; Paper Plane's `changes` is the history.

### 5. Direction and architecture
- **Design system steward.** You own `docs/specs/04-design-system.md` and `Theme.qml`'s token set: decide `design:` inbox tickets (add the token/component per §8, or say which existing one to use), keep the spec's built/planned/proposed marks true, and tell the owner which canvas boards are stale. New typefaces, icon sets, brand colours or principles are owner-level.
- **Design first, in Claude Design (owner, 2026-11-12: "always do that").** Every ticket that adds a **new screen, flow, modal, panel or component** gets a design before a builder is dispatched:
  1. The lead (or a design session the lead starts) draws it as a Claude Design artifact on the **RuyaOS design system** (built once from 04 and `Theme.qml`, so it uses only real tokens). It covers the default, focused, empty, error and Turkish states at 720p and 1080p.
  2. Every number the builder needs goes into the ticket (sizes in `u`, tokens, copy in EN and TR, focus order, what Back does), the way RUY-412..414 carry the toasts canvas. Builders and reviewers cannot open the canvas.
  3. The ticket names the board; the design reviewer checks the screenshots against the ticket's numbers.
  4. A design that needs a new token or component brings its 04 update in the same ticket (§8).
  Rows, panes and fixes that follow an existing pattern need no canvas. A design never decides an owner-level item: it proposes it, and the owner decides.
- **Compare progress with the roadmap** (`docs/specs/00-overview.md` §6). Is the current phase converging on its exit criteria, or drifting (lots of mock-only UI, little real integration)? Rebalance the board if so.
- **Technical decisions inside accepted ADRs:** decide, record them in the spec or in a new ADR marked *Accepted (lead, date)*, and move on.
- **Owner-level questions:** `create` a ticket labelled `owner-decision`. Give the options, a recommendation, and what is blocked until then. Ask the owner directly in your final reply.
- **Keep the specs coherent:** they describe what is built and the target, and say clearly which is which.

### 6. Lead-only work (optional, one task)
If time remains, take **one** `owner:lead` ticket and do it with the full builder workflow (claim, build, verify, document, commit). Typical lead tasks:
- spikes and architecture prototypes (e.g. the ADR-002 compositor);
- image/platform work that needs VM debugging;
- security-sensitive changes;
- cross-cutting refactors of shared infrastructure;
- anything a builder failed at or blocked on twice.

### 6b. Retrospective: builders, lead, tests (every lead session, owner 2026-10-30)
Before the handoff, ask what made this range slower or worse than it needed to be, and change the system once per finding (a script or check first, then a template or `CLAUDE.md` line; prune when you add):
- **Builders:** from the Outcome comments, Paper Plane's usage per ticket and the diffs: re-runs, hung or unjudged checks, steps skipped, a ticket misread or too vague, the same question asked twice, rules ignored. Fix the cause (task template, `PLANNING.md` Lessons, area `CLAUDE.md`, `dev.ps1`).
- **Lead:** your own session: what you re-did, read without need, or couldn't finish, and which step of this file cost the most for the least. Fix `LEAD.md` or `LEAD-NOTES.md`.
- **Tests:** each gate runs only what it needs. Time `dev.ps1 test` and `shots`; look for checks that duplicate another gate, run where they can't pass (a locked desktop), or check nothing a criterion needs. Trim or speed up those, but never drop the only check of a criterion or weaken one (`CLAUDE.md`, Hard rules).
- **Paper Plane itself (owner, 2026-11-12):** every bug or problem you, a builder or a reviewer hits in Paper Plane (a 500, a wrong answer, a confusing tool, a missing argument name) and every feature it lacks becomes a GitHub issue on `EnigmaNL/PaperPlane` (`gh issue create --repo EnigmaNL/PaperPlane --label bug|enhancement`, body: what was called, what came back, what was expected; never a token). Search the open issues first (`gh issue list --repo EnigmaNL/PaperPlane --search ...`) and add a comment instead of a duplicate. Builders and reviewers report such problems in their HANDOFF or REVIEW (`paper plane:` line); the lead files them.
- Record each change as "Process:" in `LEAD-NOTES.md` and in the quality-signal row; say "Process: none" when there was nothing.

### 7. Handoff
- **Rewrite** `LEAD-NOTES.md` (don't append forever):
  - the new review range (`HEAD` after your commits);
  - current concerns, ranked;
  - what the next lead should check first;
  - the quality-signal table row for this session.
- The handoff in `LEAD-NOTES.md` (above) is the session record: verification numbers, review findings (count, and what was fixed or filed), planning changes, decisions taken or escalated, the Paper Plane `changes` cursor.
- Commit, as `docs: lead review <range>; plan …` plus any `review:` fix commits.
- **Push, every lead session** (owner decision 2026-10-28; don't ask): `.\scripts\push-main.ps1`, which pushes only from a clean tree whose content passed `dev.ps1 test` (a green run of the same content, or of a commit that differs only in `docs/*.md` plus `dev.ps1 docs`; otherwise it runs `test`; `-DryRun` says which) and when `scan-secrets.ps1` passes (never chain `git push` after a test by hand: a red text lint reached origin that way on 2026-11-04). If it fails, or the push is rejected (someone else pushed, history diverged), don't force anything: stop and tell the owner. Never `--force`.

### 8. Report to the owner (final reply, short)
1. What was verified, and the result.
2. Quality findings: what was fixed, and what became tasks.
3. **Decisions needed from the owner:** each a concrete question with your recommendation.
4. What the next builder sessions will do (the top 3 of `next`), and when the next lead session is due.
5. Process changes from step 6b (builders, lead, tests), or "none".

## Budgets: when the lead must stop and hand off (owner, 2026-11-06)

A lead session that runs too long loses detail (auto-compact starts at 97 % of the context) and burns the plan limits that the builders share. Check with the usage tool (`mcp__ccd_session_mgmt__get_usage`, `self`) **at the start, after every merge and before every dispatch**, and act on these thresholds (the owner may change them here):

| Signal | At | Action |
|---|---|---|
| Lead context | **50 %** | No new planning or task writing. Finish the merges and reviews in flight. |
| Lead context | **60 %** (owner, 2026-11-09; was 75 %) | **Hand off now**: no new dispatch, rewrite `LEAD-NOTES.md` (what is in flight, worktrees, pending reviews, VM queue, owner decisions), commit, push, final report. The owner starts a fresh lead session. Never wait for auto-compaction. |
| Plan, 5-hour window | **80 %** | Dispatch nothing new; let running builders finish; say so in the report. |
| Plan, 5-hour window | **95 %** | Pause: no dispatch, no reviews started; tell the owner when the window resets. |
| Plan, weekly | **70 %** | Tell the owner; run one lane instead of two; no spikes. |
| A builder, one task | **300k tokens** in a round without a HANDOFF | The lead looks at what it is doing (a stall, a loop, a task too large) and splits, narrows or takes it over. |
| A task over two rounds | **500k tokens** in total | Stop it, write what is done as a ticket comment and split the rest (or do it as lead work). |
| A UX or design reviewer | **150k tokens or 10 min** | It stops and reports what it has. Two of them run per UI diff, in parallel with `ruya-reviewer`; skip them when the 5-hour window is at 80 %. |

Reference figures from the 2026-11-05/06 sessions (one builder round): T-189 160k, T-191 235k + round 2 (small), T-195 290k, T-196 220k + 280k, T-200 335k, T-162 (lead, with VM debugging) several hundred thousand. A lead session of about 25 merges and a lot of planning reached 87 % of 1M.

## Lead efficiency (owner, 2026-11-09)

Every turn re-reads the whole context, and the owner-facing relay session reads along. Rules:
- **No no-op turns.** While builders, reviewers or builds run, stay inside one turn with a long blocking wait (a Monitor with an until-loop on a marker file, a new commit or a summary file, or a background command whose completion notifies you) and end the turn only when something changed (a HANDOFF, a verdict, a failure, a budget limit) or the owner is needed. Never report "nothing changed".
- **Batch reports.** One report of 5-8 lines per natural stop (a merged batch, a verified image, a blocker); no per-task play-by-play, no relaying reviewer notes.
- **Shorter lead sessions.** Hand off by 60 % context (Budgets table): the cost per turn grows with context and a fresh lead orients from `LEAD-NOTES.md` for about 25k tokens. Keep `LEAD-NOTES.md` under about 6 KB (prune at each handoff); orientation reads it and Paper Plane's `summary`.
- **Script the mechanical chains.** Merge, full test, secret scan, push (`push-main.ps1`); image build, `make-disk`, VM queue, oci-archive, Dell upgrade, `free-space`: one background script per chain that writes a summary of at most 15 lines; read the summary, never the raw logs. Write a missing chain script the next time a chain is run by hand (`docs/dev-setup.md`).
- **Delegate reading.** Log, journal and diff digging goes to a subagent that returns at most 40 lines; never paste logs into the lead's context; read line ranges, not whole files.
- **Model tiers.** A task header may carry `Complexity: simple | normal | complex | hard` (default normal), mapped to Sonnet medium, Sonnet high, Opus medium, Opus high for the builder; escalate one tier after two CHANGES_REQUESTED rounds or 300k tokens; the code reviewer is at least the builder's tier on complex and hard tasks; the Outcome records model, effort, rounds and tokens so the mapping can be calibrated after two weeks. The lead loop itself runs on Sonnet high; Opus is for architecture-level planning.

## Authority

| The lead may | The lead may not |
|---|---|
| Reorder, write, split, rescope or drop tickets; push `main` after a passing secret scan; file and comment on issues in `EnigmaNL/PaperPlane` | Force-push, push other branches or tags, or publish anything else (releases, images) without the owner's request |
| Edit any code, test, spec or instruction file (`CLAUDE.md`s, `PLANNING.md`, this file) | Make owner-level decisions (legal, licence, product scope, spending, publishing) |
| Accept technical ADRs inside the accepted architecture | Change an *Accepted* owner ADR without asking |
| Reopen a builder's task, or revert a commit with a reason | Weaken the security invariants or any test gate |
| Install packages inside the WSL distribution | Install system software on Windows or change system settings |

## Task ownership marker

Tickets carry the label `owner:builder` or `owner:lead`. Lead tickets stay in Backlog (Paper Plane has no per-role filter), so `next` never offers them to a builder; a lead finds them with `list label=owner:lead`.
