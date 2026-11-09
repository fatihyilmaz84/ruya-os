# T-392 - Download stats and policy: per-day totals and history; pause while playing, download in standby

Status: todo · Phase: 3 · Depends: T-389, T-390, T-391 · Area: services (ruya-store, ruya-update), shell (Downloads page, Settings) · Size: M · Owner: builder · Developer surface: internal

## Goal
The Downloads page shows how much was downloaded per day and per source over the last weeks and a history of finished jobs; Settings > Downloads lets an admin pause downloads while a game is in front and allow updates to download in standby.

## Read first
- ADR-026 and the T-388 Outcome (bandwidth-limit finding), T-389/T-390 Outcomes, `docs/specs/03-services-and-apps.md` §4, T-166 (suspend) and T-262 (wake), T-376 (`appOpen`: a game in front)

## Scope
1. Each service appends finished jobs and per-day byte totals (device time zone, T-213) to a root-only ledger, 90 days; `GetDownloadStats(days)` from T-388's draft.
2. Page: a "This week" summary and a per-day bar chart (existing chart component), a history list.
3. Policy (stored by the services, admin-gated like other system settings): "Pause downloads while playing" (default on: the shell tells the services when a game is in front; they pause running jobs and resume after), "Download updates in standby" (offered only where wake works), a bandwidth limit only if T-388 found a mechanism.

## Acceptance criteria
- [ ] Rust: ledger roll-up with a fake clock and a time-zone change, 90-day pruning, policy pause/resume ordering (red without each).
- [ ] QML: stats page and the Settings rows; screenshots reviewed.
- [ ] VM (lead run): `vm-store-check.sh downloads` extended: a game in front pauses a running job and it resumes after; Outcome `Verified: host (vm pending: ...)`.
- [ ] `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
