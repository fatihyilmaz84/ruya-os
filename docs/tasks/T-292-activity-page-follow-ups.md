# T-292 — Activity page follow-ups: refresh only when visible, paging, retry, icons, focus order

Status: todo · Phase: 2 · Depends: — · Area: api, services (ruya-session usage), shell (usage, Activity pages) · Size: M · Owner: builder

## Goal
The Activity pages stay cheap and honest on long histories: the ledger is read only while an Activity page is on screen, history pages in, a failed read can be retried, "Most played" shows the game's icon, and the game page is reachable in a sensible focus order.

## Read first
- `docs/specs/02-shell.md` and `03-services-and-apps.md` (play statistics), `api/dbus/org.ruyaos.Session1.xml` (`GetUsage`, `ListSessions`)
- T-247 Outcome; `services/ruya-session/src/usage.rs`, `usage_store.rs`; `shell/src/usage/` (`Usage`, `UsageStats`, mock and D-Bus backends); `shell/qml/ActivityPage.qml`, `ActivityGamePage.qml`
- `shell/tests/tst_activity.qml`; STATUS-parked.md "Inbox triage 2026-11-07", bullets T-292

## Scope
1. **Refresh only when visible:** `Usage` refreshes the full ledger on every 30 s heartbeat while a game runs; refresh only while an Activity page is on screen (and once when one opens).
2. **Paging:** `ListSessions` is capped at 60. Extend the contract (XML first, service and tests, mock, D-Bus client): an offset or "before" argument and a `more` flag; the history list loads the next page when focus reaches its end.
3. **Retry:** after a failed read the page shows the existing error line and a "Try again" row that re-reads.
4. **"Clear my activity"** is reachable in one step on a long history (a pinned first row or a jump from the end), keeping its confirm dialog.
5. **Game page focus order:** the stat rows on a game page are not focus stops before the strip (the strip is first); Back returns to the row the player came from.
6. **Most played** shows the game's icon (`AppArt`/the library's icon path) next to the name; unknown game: the generic icon.
7. **Copy:** reword the empty-state privacy sentence so it says what is stored, that it stays on this console, and where to clear it (en and tr).

## Out of scope
- Steam play time, the parent report and what a child's clear deletes (T-211), the chart look and contrast (T-283), the hint bar (T-285), the idle clock.

## Acceptance criteria
- [ ] `tst_activity.qml::test_no_refresh_while_hidden` (heartbeat with no Activity page: backend read count unchanged; with one: increases) and `::test_next_page_on_end`.
- [ ] Rust: `ListSessions(offset)` returns the next 60 in newest-first order, `more` false at the end; XML, mock and client agree.
- [ ] `tst_activity.qml::test_retry_after_failed_read`, `::test_clear_reachable_in_one_step`, `::test_game_page_focus_starts_on_strip`, `::test_most_played_icon`.
- [ ] `tst_i18n.qml`: the new strings exist in tr.
- [ ] Screenshots (Activity with a 200-session mock history, an error state, a game page) reviewed.
- [ ] UX: from every new state Back leaves; focus lands sensibly after open/close/error; readable at 10 ft; Outcome has a `UX notes:` line.
- [ ] VM (lead run): `scripts/vm-usage-check.sh` gains a paging case (insert 70 sessions via the check's fixture, two pages); Outcome `Verified: host (vm pending: vm-usage-check.sh)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- 03 / Session1.xml (`ListSessions` paging), 02 (Activity).

## Hints
- Keep the paging argument small (offset plus a `more` flag in the reply); for guarded replies copy `RequestSequence` (T-181).
- Overlaps T-290 (services/ruya-session): different files (`usage.rs` vs `session.rs`), safe in parallel; T-283 touches `BarChart.qml` only.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
