# T-342 - Store follow-ups: every OARS attribute, the long Turkish badge, installed-list reads in order

Status: todo · Phase: 2 · Depends: — · Area: services (ruya-store), shell (store pages, tests) · Size: S · Owner: builder

## Goal
Findings of the T-291 reviews that weaken tests or can show a wrong list: one OARS attribute is not covered by the age mapping test, the longest Turkish age badge was never looked at, and two overlapping installed-list reads can apply out of order.

## Read first
- The Inbox line tagged T-291 in `docs/STATUS-parked.md`, "Inbox triage 2026-11-08 (lead-5)" (verbatim); `docs/tasks/T-291-*.md` Outcome
- `services/ruya-store/src/appstream.rs` (`age_rating`, the OARS table, test `every_oars_attribute_gives_its_age` at ~line 448), `service.rs` (`sync_installed` ~line 301, the ticket idea), `shell/qml/AppDetailPage.qml` (age badge), `shell/tests/tst_store_ui.qml`, `tst_i18n.qml`
- malcontent's OARS-to-age table (the reference for the mapping; read it from the freedesktop `appstream` OARS 1.1 documentation, not from memory)

## Scope
1. Add `violence-worship` to `every_oars_attribute_gives_its_age` (and any other OARS 1.1 attribute missing from the list: list them in the test from the spec, not from the code under test). Check each attribute's age mapping against the malcontent table; fix a difference and record it in the Outcome.
2. A Turkish detail screenshot for the longest badge ("DERECELENDIRILMEMIS" with the Turkish characters of the real string) in `tst_store_ui.qml` shots; fix the badge if it clips or overflows its card at 1080p and 720p.
3. `sync_installed`: tickets are taken before the read starts; serialise the reads (one at a time, a second request while one runs sets a "again" flag) so an older read can never apply after a newer one.
4. Note for T-211 (its Hints get the same line): an empty `age_rating` means unrated; the parental-controls policy treats unrated as 18+ for child profiles. "Not rated" meaning line for child profiles waits for T-211.

## Out of scope
- The parental-controls service (T-211), changing the badge design, new ratings sources.

## Acceptance criteria
- [ ] Rust: `every_oars_attribute_gives_its_age` covers the full OARS 1.1 attribute list (test builds the list from a constant copied from the spec; revert: delete one mapping arm, test red), `overlapping_reads_apply_in_order` (fake source with a slow first read: the final list is the newer one), `a_request_during_a_read_runs_once_more`.
- [ ] `tst_store_ui.qml::test_long_turkish_age_badge_fits` at the real card size (geometry assert) plus the screenshot read against `04` §8.
- [ ] VM (lead run): `scripts/vm-store-check.sh` unchanged and green on the next image. Outcome `Verified: host (vm pending: vm-store-check.sh)`.
- [ ] UX: readable at 10 ft; Outcome has a `UX notes:` line (badge).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/03-services-and-apps.md` (the age mapping paragraph, if a mapping changes).

## Hints
- Copy the ticket pattern of `RequestSequence` on the shell side for the idea; here it is a Rust-side guard.

## Outcome
_Filled in by the implementer._
