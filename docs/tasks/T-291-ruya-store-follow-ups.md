# T-291 — ruya-store follow-ups: ordered installed-set reads, the age label, "Not rated"

Status: done · Phase: 2 · Depends: — · Area: services (ruya-store), shell (AppDetailPage, store backend mock) · Size: S · Owner: builder

## Goal
The Store never shows a stale installed set because of two overlapping reads, an app rated for gambling or intense content gets the right age, and an unrated app says "Not rated" instead of "All ages".

## Read first
- `docs/specs/03-services-and-apps.md` (Store, ratings), `api/dbus/org.ruyaos.Store1.xml`
- `services/ruya-store/src/service.rs` (`State.generation`, `sync_installed`, `refresh`, ~lines 68-335), `appstream.rs` (`severity`, the `adult` rule ~line 207), `shell/qml/AppDetailPage.qml` (~line 59), `shell/src/store/` mock
- T-192, T-214 Outcomes; STATUS-parked.md "Inbox triage 2026-11-07", bullets T-291 (and "Inbox lines parked 2026-11-06", T-214 findings)

## Scope
1. **Tickets for installed reads:** `sync_installed` handlers run concurrently, so two overlapping `flatpak list` reads can apply out of order and a stale one undo a newer correction. Give each read a ticket (a counter taken before the read, applied only if no newer read has already applied); `refresh`'s `generation` check stays.
2. **Gambling and intense ratings:** OARS 1.1 uses `money-gambling`, not `gambling`: fix the `adult` prefix list and add a table test over the real OARS attribute ids (`sex-*`, `violence-*`, `drugs-*`, `money-gambling`, `social-*`) with the age each should give; "intense" must not give 16+ where the rule says 18+.
3. **Not rated:** an app with no `content_rating` shows "Not rated" (en and tr strings) in `AppDetailPage`; the contract keeps carrying an empty rating for it (T-211 will treat it as 18+ for children). A rated "all ages" app still says "All ages".
4. **Apps installed outside the Store:** `sync_installed` corrects removals and flags but never adds an app installed from a remote the Store did not add. Keep that (the Store lists its own catalogue) and fix the comment and 03 so they say so.

## Out of scope
- Showing foreign apps, the Flatpak runtime in the image (owner decision), `x-ruya-launch-mode`, codecs on first boot, the developer remote UI.

## Acceptance criteria
- [ ] Rust test with a fake Flatpak whose first read is slow and second fast: the final state is the second's (red when the ticket is removed).
- [ ] Rust table test of rating ids to ages incl. `money-gambling` at `intense` (red with the old prefix).
- [ ] `tst_store_ui.qml::test_unrated_app_says_not_rated` and `::test_all_ages_stays` (mock apps with and without rating); `tst_i18n.qml` has the Turkish string.
- [ ] Screenshot: app detail of an unrated app (reviewed).
- [ ] UX: nothing new to navigate; Outcome has a `UX notes:` line.
- [ ] VM (lead run): none needed beyond the next `vm-store-check.sh` run; Outcome `Verified: host (vm pending: vm-store-check.sh)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- 03 (ratings table, installed-set sync note).

## Hints
- Reference: the `generation` counter already in `State` (T-192); the tests in `service.rs` fake Flatpak, extend that fake with a gate to make a read slow.
- No overlap with open tasks.

## Outcome
Verified: host (vm pending: vm-store-check.sh). `dev.ps1 test` ALL GREEN (861 QML passed, 66 skips for screenshots, Rust 690 passed), `dev.ps1 shots` ALL GREEN (141); nothing ran in the VM.

UX notes: nothing new to navigate. The only change on screen is the age badge of the app page: an app with no rating reads "Not rated" (tr "Derecelendirilmemiş"), a rated "all" app still "All ages". States reached: the app page of Racer Beta (unrated, reviewed in `57-store-detail-unrated.png`); Back leaves it to the Store as before and focus lands on Install (`detailPrimary`) when the page opens, unchanged. Nothing doubted: the badge is the same component, only its text changes.

What was built
1. **Tickets** (`service.rs`): `State.last_ticket` / `applied_ticket`; `sync_installed` takes a ticket before `flatpak list` and applies its answer only if no read that started later has applied (`applied_ticket > ticket` drops it), besides the existing `generation` check. Test `a_slow_list_read_does_not_undo_a_newer_one`: the first read's hook (`after_next_installed`, the fake's gate) runs a whole second read that removes the app and announces it; the first read's stale "installed" answer is then dropped and says nothing; a later read still applies.
2. **Ratings** (`appstream.rs`): `adult_attribute()` uses `money-gambling` instead of `gambling`. Table test `every_oars_attribute_gives_its_age` runs 26 OARS 1.1 attribute ids (`violence-*`, `drugs-*`, `sex-*`, `language-*`, `money-*`, `social-*`) at none/mild/moderate/intense; `intense` gives 18+ for `sex-*`, `violence-sexual`, `drugs-*`, `money-gambling` and 16+ for the rest. The rule itself is unchanged (it was already 16+ vs 18+); only the gambling id was wrong.
3. **Not rated**: `AppDetailPage.ageText` returns "Not rated" for an empty rating; the badge has `objectName: detailAge`. `StoreBackend.h` `AppInfo.ageRating` now defaults to empty (it defaulted to "all", so a service reply without `age_rating` would have shown "All ages"); the contract XML says `age_rating` is absent for an unrated app. The mock's Racer Beta is now unrated (was 7+). Tests `tst_store_ui::test_unrated_app_says_not_rated`, `::test_all_ages_stays` (Open Player "all", Turbo Racer "Ages 7+"), `tst_i18n::test_unrated_app_age_is_translated` (en, tr, en), plus the screenshot `57-store-detail-unrated.png`.
4. **Foreign apps**: comment on `sync_installed` and 03 now say the Store lists its own catalogue and `sync_installed` never adds an app; test `an_app_installed_outside_the_store_is_not_added` (new fake helper `FakeFlatpak::add_installed`).

Revert checks: (a) `sync_installed` ticket check disabled (`if false && ...`): `a_slow_list_read_does_not_undo_a_newer_one` fails; (b) `money-gambling` back to `gambling`: `every_oars_attribute_gives_its_age` fails ("money-gambling intense"); both done by hand with `cargo test`, files restored. (c) `ageText` back to `"all" || !rating ? "All ages"` via `revert-check.ps1 -Test tst_store_ui,tst_i18n`: `test_unrated_app_says_not_rated` and `test_unrated_app_age_is_translated` fail. `test_all_ages_stays` and `an_app_installed_outside_the_store_is_not_added` are guards of behaviour that was already right, so they pass without the change by design.

Files: `services/ruya-store/src/{service,appstream,flatpak}.rs`, `api/dbus/org.ruyaos.Store1.xml`, `shell/qml/AppDetailPage.qml`, `shell/src/store/{StoreBackend.h,MockStoreBackend.cpp}`, `shell/i18n/ruyashell_{en,tr}.ts`, `shell/tests/{tst_store_ui,tst_i18n}.qml`, `docs/specs/03-services-and-apps.md`.

Deviations: the XML comment for `age_rating` was extended (absent = not rated); the mock app without a rating is Racer Beta, not an app hidden by the controller filter, so tests can reach it by card.
