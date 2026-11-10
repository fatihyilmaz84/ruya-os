# T-422 - Plan lint: the board and the task headers agree on more than Status

Status: todo · Phase: 2 · Depends: — · Area: scripts, docs · Size: S · Owner: builder · Complexity: simple · Developer surface: none

## Goal
The mistakes the plan audit of 2026-11-10 found by hand are refused by `lint-board.ps1`: a lead task without its `[lead]` mark, board dependencies that differ from the header, a parked task still `todo`, a claim nobody works on, instruction files over their budget.

## Read first
- `scripts/lint-board.ps1` (it reads only `Status:` today), `docs/tasks/README.md`, `docs/LEAD.md` 3b (budgets)
- `docs/tasks/PLANNING.md` (header fields, sizes)

## Scope
1. Parse the whole header line of every task file: `Status`, `Depends`, `Size`, `Owner`, `Complexity`, `Developer surface`.
2. New failures (one line each, naming the task and the fix):
   - a dependency that names no task file;
   - a dependency cycle among open tasks;
   - a board row whose Depends column is not "the header's dependencies that are not `done`, plus `owner`" (the convention since 2026-11-10);
   - `Owner: lead` without `**[lead]**` in the board title, or the reverse;
   - `Depends:` contains `owner` and the status is not `blocked`;
   - a `todo` or `in-progress` task without an `## Out of scope` or `## Acceptance criteria` section, for task ids from T-422 on (older files are not rewritten for this).
3. Warnings (printed, not failing): an `in-progress` task whose claim commit (`git log -1 --format=%cI -S"Status: in-progress" -- <file>`) is older than 3 days; an open task file over 8 KB; root `CLAUDE.md`, area `CLAUDE.md`s and `docs/STATUS.md` over the budgets of `LEAD.md` 3b (the table is read from one place in the script).
4. `-Ready` switch: print the open tasks whose dependencies are all `done`, builders and lead apart (what the planner counts by hand today).

## Out of scope
- Rewriting old task files to pass (rule 6 of scope 2 starts at T-422).
- Any check of task prose quality.

## Acceptance criteria
- [ ] Each failure of scope 2 has a fixture test: a temporary board and task directory that the lint refuses with the expected line (test: `scripts/tests/lint-board.tests.ps1` or the existing lint self-test pattern; say which in the Outcome). Revert check: removing a rule makes its fixture pass the lint.
- [ ] `.\scripts\dev.ps1 docs` and `test` run the lint on the real tree and it is green at merge time (fix the real tree's failures in this task if any remain; list them in the Outcome).
- [ ] `lint-board.ps1 -Ready` prints two lists that match a hand count for three sampled tasks (in the Outcome).

## Verification
```powershell
.\scripts\dev.ps1 docs
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/tasks/README.md` (what the lint enforces), `docs/LEAD.md` 3b (the budget check is now the lint's warning; delete the manual `wc -c` step).

## Hints
- PowerShell 5.1 and `pwsh` both run it (CI uses `pwsh`). No `jq`.
- Status may carry a reason in brackets: `blocked (owner ...)`.

## Outcome
_Filled in by the implementer. First line: `Verified: host`._
