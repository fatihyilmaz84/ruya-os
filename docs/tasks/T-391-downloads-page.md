# T-391 - The Downloads page: current, queued and finished downloads, speed, actions; a status pill

Status: todo · Phase: 3 · Depends: T-389, T-390 · Area: shell · Size: M · Owner: builder · Complexity: normal · Developer surface: none

## Goal
One page shows everything the console is downloading: the running job with its speed, bytes and time left, the queue in order, and recent finished or failed ones; the player can pause, resume, cancel, move to the top and retry with the pad. A small pill in the status cluster shows that something is downloading.

## Read first
- ADR-026; `docs/specs/02-shell.md` (Store, status cluster, quick menu), `docs/specs/04-design-system.md` §3, §5, §8 (list rows, progress, a speed figure: tokens and components only; a missing one is a `design:` Inbox line); `shell/PATTERNS.md` (pages, modals)
- The shell's Store and Update clients (v2 fields from T-389/T-390)

## Scope
1. `Downloads` C++ facade merging both sources into one model (order: running, queued by position, finished newest first), with the summed rate.
2. The page (from the Store's header, the Guide quick menu and the status pill): rows with art, title, state, bytes ("1.2 of 4.0 GB"), speed, time left (or "unknown"), and actions in an Options menu (Pause/Resume, Cancel with a confirm, Move to top, Retry, Open in Store); a small speed line chart of the last minutes if `04` has a component for it, else an Inbox line and a plain figure.
3. Status pill: shown while a download runs (percent of the running job), hidden behind an app.
4. Copy in en and tr; errors in plain words.

## Acceptance criteria
- [ ] QML: model order and merge, each action calls the right client method, Back leaves every state, focus after Cancel lands on the next row (tests red without each).
- [ ] Screenshots (en, tr): a running job with queue, a paused job, a failed job, the empty page, the pill; reviewed; `UX notes:` line.
- [ ] `dev.ps1 test` and `shots` ALL GREEN.

## Outcome
_Filled in by the implementer._
