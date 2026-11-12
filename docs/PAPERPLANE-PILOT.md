# Paper Plane pilot (started 2026-11-12)

Paper Plane (`D:\dev\PaperPlane`, running at http://192.168.178.164:8687, project `RUY`) is being tried as the ticketing system. **Until the owner says the migration is complete, the `docs/tasks/*.md` files and the `docs/STATUS.md` board stay the source of truth.** Nothing here replaces `CLAUDE.md` or `docs/LEAD.md`. No token is stored in the repo.

## What was imported (2026-11-12)

- The 176 open tasks (STATUS board plus STATUS-backlog) as tickets `RUY-1..RUY-176`, in board order. The `T-nnn` id starts every title; the task file's text (without its H1 and header line) is the description.
- Labels from the header: `phase:N`, `area:x`, `size:S|M|epic`, `owner:lead|builder`, `complexity:x`, `surface:x`.
- `Depends:` became `blocks` relations (237). Epics became parents of their children (48 links: T-228, T-248, T-263, T-273, T-302, T-314; T-270 and T-426 have no written children yet).
- State: `Blocked` for blocked tasks, `Ready` for todo tasks with an `## Acceptance criteria` section, `Backlog` for the rest. **`owner:lead` tasks are kept in Backlog** so a builder's `next` never offers them (Paper Plane has no per-role label filter); a lead finds them with `list label=owner:lead`.
- Not imported: the finished tasks (their files remain the only record). Re-running the importer needs an empty project.
- The importer is `scripts/paperplane-import.py` (usage: `py -3.12 -I scripts/paperplane-import.py <base url> <token file>`; it refuses a non-empty `RUY`).
- Pilot ticket: `RUY-177` (T-341a, a split-off of T-341 item 4), claimed, handed over, reviewed and merged as 6ffcd85.

## Conventions while both systems exist

- **Priority stays `none`** except for something truly urgent. Paper Plane ranks any set priority above `none`, so a "low" ticket would jump ahead of the whole board. Order is the board order (`sort_order`); to move a ticket up use `update sort_order=...`.
- **Outcome:** a ticket has no Outcome field. The builder's `move ... evidence=` is the `Verified:` line (host / host (vm pending: ...) / vm / unverified / hw), and a `comment` starting `Outcome:` holds the rest; the lead copies both into the task file when it lands, as long as the files exist.
- **Handing over** needs `branch`, `commit` and `evidence`; only the lead moves to `Done`, after a recorded `approve`.
- A split-off item gets its own ticket with the next letter (`T-341a`) and a line in the parent task file saying so.
- Builders get a token with role `builder` and project `RUY` (the owner creates it, or a lead with the `tokens` permission once that is deployed). Tokens never go in the repo, a commit or a log.

## Known gaps (to decide before the files go away)

- No Outcome slot; no custom fields (the header is labels); ticket keys are `RUY-n`, not `T-nnn`.
- CI (`lint-board.ps1`) cannot see Paper Plane; the public repo no longer shows the open backlog to contributors.
- About 4,600 `T-nnn` mentions in specs and docs link to task files.
- Paper Plane creating a ticket with a duplicate label returned a 500 (the importer de-duplicates).
