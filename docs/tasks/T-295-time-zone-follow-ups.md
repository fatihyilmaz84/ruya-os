# T-295 — Time zone follow-ups: say it when Setup cannot set the zone, type to filter the chooser

Status: todo · Phase: 2 · Depends: — · Area: shell (Setup, ZoneChooser, TimeZone, tests) · Size: S · Owner: builder

## Goal
First-boot Setup tells the player when the time zone could not be set (and that Settings can change it), and a player can type a few letters to find a city instead of scrolling about 150 entries.

## Read first
- `docs/specs/02-shell.md` (first boot, System > time zone), `04-design-system.md` §5 (captions, `errorText`, text entry)
- T-213 Outcome; `shell/qml/Setup.qml` (the zone step, `TimeZone.setTimezone(zone)` ~line 134), `ZoneChooser.qml`, `ZonePicker.qml`, `SystemPane.qml` (`onSetTimezoneFinished`), `TextEntry.qml`; `shell/src/time/TimeZone.h` (`mockFailNext`, `mockSetCallerAllowed`)
- `shell/PATTERNS.md` (text input); `shell/tests/tst_timezone.qml`, `tst_setup.qml`; STATUS-parked.md "Inbox triage 2026-11-07", bullets T-295

## Scope
1. **Setup message:** Setup waits for `setTimezoneFinished`; on any status but `ok` the Done step shows a caption in `errorText` style under the button: "Could not set the time zone. You can change it in Settings > System." (en and tr). Done is not blocked: a second Accept finishes Setup.
2. **Type to filter:** the zone chooser gets a "Search" row above the lists that opens the on-screen keyboard (`TextEntry` pattern); typing filters cities (case- and diacritic-insensitive on the city and region name, `_` shown as space); Accept on a result chooses it; an empty result shows "No match"; Back clears the filter first, then leaves.
3. Both chooser hosts (Setup and Settings > System) get the same behaviour.

## Out of scope
- Turkish city names (a CLDR table), a manual clock for a console that never gets online, services calling `tzset()` (T-211 hint), more zone data.

## Acceptance criteria
- [ ] `tst_setup.qml::test_zone_refused_shows_message` (mock `mockFailNext()`: caption visible, second Accept finishes) and `::test_zone_ok_shows_no_message`.
- [ ] `tst_timezone.qml::test_filter_finds_istanbul` ("ist" lists Istanbul), `::test_filter_ignores_case_and_diacritics` ("izmir" finds Izmir), `::test_no_match_row`, `::test_back_clears_filter_then_leaves`.
- [ ] `tst_i18n.qml`: new strings in tr. Screenshots of Setup with the message and of the chooser mid-search (en, tr) reviewed.
- [ ] UX: from every new state Back leaves; focus lands on the first result after typing and back on Search after clearing; readable at 10 ft; Outcome has a `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- 02 (first boot step, System time zone).

## Hints
- Reference: `ProfileAddFlow.qml` name entry for opening the keyboard from a row; `ZoneChooser.qml` keeps `prefix` object names for two instances.
- Overlaps T-285 (`Setup.qml` hints): run after it or merge carefully.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
