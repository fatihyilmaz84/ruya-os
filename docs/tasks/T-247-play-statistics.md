# T-247 — Play statistics: a per-profile ledger of play sessions and the Activity pages

Status: todo · Phase: 2 · Depends: — · Area: api, services, shell · Size: M · Owner: builder

## Goal
Each profile sees how it plays: a recent history, time per game, when it plays, simple highlights (owner request, 2026-11-07). Private to the profile. Today the only data is `Library` last-played and recent; there is no play time or history. **One ledger for everything that needs play time:** T-211 (parental play-time limits and the parent's weekly report), the retention rules of T-220 ("Clear my play history") and T-224 (telemetry; "App usage" is a separate owner decision, not built here). Decision recorded here: **this task builds the ledger in `ruya-session`; T-211's counter reads it** (T-211's item 4 and its Depends were changed accordingly). The lead reviews the data-model decision.

## Read first
- `docs/tasks/T-211-parental-controls-service.md` (item 4, `GetUsage`, `PlaytimeEnded`), T-220 (clear my activity), T-224 (what is never sent), T-213 (time zone), T-202 (the idle clock), T-165 (profile switch stops the profile's apps), T-221 (free-up-space hint)
- `docs/specs/03-services-and-apps.md` (`ruya-session`, `Session1`), `services/CLAUDE.md`, `api/dbus/org.ruyaos.Session1.xml`, `02-shell.md` (profile pages), `04-design-system.md` §8; `ruya-profiles` for the store pattern

## Scope
1. **Ledger (contract first, `Session1.xml`):** per profile, play sessions: `app_id`, `app_version`, `start`, `end` (UTC unix s), `foreground_seconds` (the app was the foreground, not suspended or idle), `exit_reason` (`quit`, `crashed`, `killed`, `time-limit`, `bedtime`). Stored under `/var/lib/ruya-session/usage/<profile>/` (root-only 0600, atomic append, size caps). Accounting rules, written in `03` and tested: counts only while the profile is active and not locked or suspended; suspend and a long no-input idle period (the T-202 clock, default 10 min with no input and no audio playing) are excluded; durations from the monotonic clock (clock changes do not matter); a heartbeat every 30 s while running, so a crash, kill or power cut ends the session at the last heartbeat; sessions under 10 s are dropped; only the foreground app accrues when several run; an app update mid-session continues the session; a profile switch ends it (T-165); time-limit endings come from T-211; day boundaries use the device time zone (T-213).
2. **Retention:** raw sessions 90 days, then rolled up into daily totals per app kept 24 months. Deleted with the profile; not in the save backup by default; never in telemetry.
3. **Interface:** `ListSessions(profile, since, limit)`, `GetTotals(profile, from, to) -> per app and per day`, `ClearHistory(profile)` (the profile's own PIN or an admin), `UsageChanged` signal; T-211's `GetUsage` is a view of the same data. Callers as elsewhere (`ruya-shell` and root only); the shell asks for the active profile only.
4. **Activity (shell):** Settings -> Profiles -> you -> **Activity** (or a profile "Activity" page on Home: decide per `02`/`04`): (a) **This week**: total time, a bar chart by day (7 bars, today highlighted, an accessible text alternative "Mon 1 h 20 min, Tue ..."), one plain sentence against last week; (b) **Most played**: top 5 with icon, total time, last played; (c) **History**: a scrollable list, newest first: game, "Yesterday 19:40", duration; (d) **per game** (also a "Your activity" row on the app page): total time, number of sessions, first and last played, longest and average session, a 30-day strip; (e) modest, kind highlights: longest session this month, a streak of days played, "You have not played X for 60 days" (feeds T-221). Empty state for a new profile; durations in plain words ("1 h 20 min"), Turkish plural and format rules; **"Clear my activity"** (confirmation, only the active profile; the same call T-220 uses: ONE implementation). No gamification pressure, no ranking between profiles.
5. **New components (spec `04` update in the same commit, §8):** `BarChart.qml` (tokens only, rounded bars, optionally focusable bars to read values with the controller, reduced motion = no animation) and a `DurationText` helper.
6. **Privacy:** the shell shows the active profile only; an admin cannot browse another profile's history here; parents get T-211's weekly report from the same ledger, totals only. Docs for developers: what the console records about a game (only times and the exit reason) in `docs/developers/`.

## Edge cases to cover
Steam and other launchers (time counts for the launcher until a later task reads Steam's own playtime: Inbox), several apps at once, an update mid-session, clock changes, a profile switch while a game runs, time-limit endings.

## Out of scope
- Online leaderboards, friends, sharing or a "year in review" image, per-session screenshots, FPS or performance statistics, analytics sent to the project (T-224).

## Acceptance criteria
- [ ] Rust tests (ledger core, fake clock): foreground-only accounting, idle and suspend exclusion, heartbeat end after a crash, short sessions dropped, roll-up at 90 days, totals per day and app in a non-UTC zone and on a DST day, clear history, caps, no cross-profile reads, file modes and atomicity.
- [ ] QML tests (mock): the week chart values and the text alternative, top-list order, history grouping by day, per-game numbers, empty state, the clear flow, focus asserted, controller-only.
- [ ] Screenshots (English and Turkish) against `04` §8.
- [ ] VM (lead run): a Flatpak test app is started and stopped as a profile user; the session appears with the right duration (small real waits and an injectable day); a kill ends it at the last heartbeat; `ClearHistory` empties it; another profile sees nothing. `scripts/vm-usage-check.sh`.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `03` (ledger and interface), `Session1.xml`, `02-shell.md` (Activity), `04` (BarChart), T-211's task, `docs/developers/`, `dev-setup.md`.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
