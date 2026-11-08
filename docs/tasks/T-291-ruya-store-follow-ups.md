# T-291 — ruya-store follow-ups: ordered installed-set reads, the age label, "Not rated"

Status: in-progress · Phase: 2 · Depends: — · Area: services (ruya-store), shell (AppDetailPage, store backend mock) · Size: S · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
