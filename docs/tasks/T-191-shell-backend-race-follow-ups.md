# T-191 — Shell backends: Profiles guard, Store reconcile races, `working` from the job list

Status: done · Phase: 2 · Depends: — · Area: shell · Size: M · Owner: builder

## Goal
Close the races the T-181 and T-188 reviews found in the shell's D-Bus clients, so a late reply or a signal that crosses a reply can't leave a hung progress bar or a stale page.

## Read first
- `docs/tasks/T-181-shell-backend-stale-replies.md` and `T-188-store-jobs-survive-restart.md` Outcomes; `shell/src/backend/RequestSequence.h`
- `shell/src/profiles/DBusProfilesBackend.cpp` (line ~59: `listed` emitted straight from the async `ListProfiles` reply), `shell/src/store/DBusStoreBackend.cpp` (`listJobs`, `m_early`, `m_jobApps`), `shell/src/store/Store.cpp` (`m_lost`, the job-table correction); the Store page(s) that own a local `working` flag
- `shell/CLAUDE.md` (backend pattern, late replies)

## Scope
1. **Profiles:** give `DBusProfilesBackend` (and its mock) a `RequestSequence` for the list refresh; check the Library, Update and Store backends for any other async reply that replaces a model and guard it too (list what you checked and found fine in the Outcome).
2. **Store ListJobs races:** buffer `JobProgress`/`JobFinished` for unknown jobs while a `ListJobs` is pending (like `m_early`); for a tracked job the table reports `finished`, emit its `jobFinished` instead of silently forgetting it; a failed newer `ListJobs` must not let an older in-flight reply apply (advance the sequence on error, or discard on failure).
3. **Lost jobs by id:** correct a lost job by its id (the backend knows it), not "the last job of the app"; drop `m_lost` once a later job of the app is reported.
4. **`working` from `Store.jobs`:** a page for an app derives `working` from `Store.jobs`, so a job adopted at shell start (or by `ListJobs`) shows as working on that app's page, not only on the page that started it.

## Notes from the T-192 review (lead, 2026-11-06)
- `ruya-store` now runs its handlers concurrently on the blocking pool, so (a) `InstalledChanged` can arrive **before** the reply of the call that caused it (documented in `Store1.xml`) and (b) two `ListInstalled` replies can arrive out of order. Scope 1 therefore includes `DBusStoreBackend::refresh` (`ListInstalled` -> `installedListed`): guard it with a `RequestSequence` like the other list refreshes. The signal only triggers a fresh `ListInstalled`, which finds nothing to correct and sends no signal, so there is no loop: keep it that way.

## Out of scope
- Any contract change (`Store1.xml`), service changes, new UI.

## Acceptance criteria
- [ ] Each of 1-4 has a test that fails when the fix is undone (mock-driven: a delayed list reply, a `JobFinished` that arrives before the table reply, an old reply after a failed newer one, an adopted job on the detail page). Revert checks noted.
- [ ] Existing T-171/T-188 tests unchanged and green.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.
- [ ] VM (lead run): `scripts/vm-store-check.sh` or a probe run covers a refresh triggered by a D-Bus signal in the real client (Outcome: `Verified: host (vm pending: vm-store-check.sh)`).

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `shell/CLAUDE.md` if the late-reply rule changes; `03-services-and-apps.md` §4.3 only if behaviour described there changes.

## Outcome
Verified: host (vm pending: vm-store-check.sh). `dev.ps1 test` is green on Windows with the mock backends; the D-Bus clients compile but only run on Linux, where `vm-store-check.sh` (one check added) is the proof.

**What was built**

1. **Late list replies (Scope 1).** Every async reply that replaces a model now goes through a `RequestSequence`, in the backend base class and used by both the D-Bus client and the mock. A failed request counts as an outcome (`accept` is called for it), so an older reply that arrives after a newer failure is dropped too.
   - Profiles: `DBusProfilesBackend::refresh` (`ListProfiles`) and `MockProfilesBackend` (`refresh`, and `publishList`, which the mock uses where the service would say `ProfilesChanged`, counts as the newest request). Availability follows the same outcome as the list.
   - Store: `ListInstalled` (`refresh`, the T-192 review note: `InstalledChanged` can precede a reply and two replies can arrive out of order; the refresh it triggers still finds nothing to correct and sends nothing, so no loop) and `Search` (one sequence per query and filter, because the catalogue and the last query are different questions).
   - Checked and **not** fine, so guarded too: Library `ListItems` (`itemsListed`) and Update `GetStatus` (`statusChanged`; the mock's `publish()` is a request). Checked and fine: Library `Rescan`, Update `Check`/`Download`/`Rollback`/`SetChannel`/`SetAutoRestart` (they report a result of a call, they do not replace a model), Store `GetApp` (merges one record by id, answers `appLoaded`/`appLoadFailed` per call), Profiles' `fetchActive` (a property read after an accepted list; a second one only repeats the newest value). **Not done:** Session `ListRunning` -> `runningListed` has the same shape but interacts with `AppStarted`/`AppExited`; Inbox line.
2. **Job table races (Scopes 2 and 3).** The job bookkeeping moved out of `DBusStoreBackend` into `JobBook` (`src/store/JobBook.{h,cpp}`), owned by `StoreBackend`, so that the mock runs the same code and the races are testable. It keeps: the early buffer for signals that overtake the reply naming their job (`m_early`, as before); a **log of every signal while a `ListJobs` is pending**, with which the reply is brought up to date (a job that finished after the request is not "running"); tracking of jobs the table lists as running; the verdict for a **tracked job that the table lists as finished** (its `jobFinished` is emitted, not forgotten); `listFailed` (advances the sequence). `serviceLost` now carries job id -> app id, and `Store::m_lost` is `app -> job id`: the correction after a restart looks the lost job up **by its id** in the table, and an app leaves `m_lost` as soon as the backend reports a later job (`jobProgress` or `jobFinished`) of it.
3. **`working` from `Store.jobs` (Scope 4).** `AppDetailPage.working` is now `requested || job !== null`; `requested` is the old local flag (an unanswered request, which can be queued without progress), `job` is `Store.jobs[appId]`. A job found by the Store at start, or started elsewhere, shows progress on the app's page and disables its buttons.

**Tests** (each fails when its fix is undone; revert check = temporarily replace the guard by `return true`, drop the log catch-up / the advance on failure / the verdict in `JobBook`, use the last job of the app, drop the `m_lost.remove`, or take `working` from `requested` only, rebuild and run the three files; every test below failed, then all were restored):
- `tst_late_replies.qml` (new): Profiles (`mockRefreshDelayed`, then a rename), Library (`mockListDelayed`, then `resetMockForTests("empty")`), Update (`mockRefreshDelayed`, then `mockSetRollbackAvailable`). Reverted: `acceptList`/`acceptStatus` always true.
- `tst_store_backend.qml`: `test_a_job_finished_before_the_table_reply_stays_finished` (log catch-up undone), `test_an_old_job_table_after_a_failed_newer_one_is_dropped` (`listFailed` not advancing), `test_a_tracked_job_the_table_lists_as_finished_is_reported` (verdict undone), `test_a_lost_job_is_corrected_by_its_id` (last-job-of-app logic put back), `test_a_lost_job_is_forgotten_when_the_app_gets_a_new_one` (`m_lost.remove` undone), `test_a_late_installed_list_is_dropped` and `test_a_late_catalogue_is_dropped` (`acceptInstalled`/`acceptSearch` always true).
- `tst_store_ui.qml`: `test_a_job_the_page_did_not_start_shows_as_working` (the job is paused with `mockPauseJobs`, the page opens, `working`, the progress bar and the disabled buttons are asserted; `working` from `requested` only undone).
- Existing T-171/T-188 tests are unchanged and green. One mock detail keeps `test_job_table_replaces_a_stale_entry` unchanged: `mockForgetJobs()` now also untracks the jobs ("the shell never knew them"; no verdict, as that test expects); the new `mockEndJobsUnheard(status)` is the tracked variant (the shell started the job, the signal is lost) that Scope 2 is about.

**Mock hooks added** (tests only): `Store.mockEndJobsUnheard`, `mockRecordFinishedJob`, `mockListJobsFailing`, `mockInstalledDelayed`, `mockCatalogueDelayed`, `mockPendingReplies`, `mockPauseJobs`; `Profiles.mockRefreshDelayed`/`mockPendingReplies`; `Library.mockListDelayed`/`mockPendingReplies`; `Update.mockRefreshDelayed`/`mockPendingReplies`.

**VM (lead run):** `scripts/vm-store-check.sh` gets one check in the restart section: the shell reports the cut-short install exactly once (`jobFinished ... failed` count is 1), i.e. the job table read after the restart does not repeat the verdict. The refresh triggered by a D-Bus signal in the real client (`InstalledChanged` -> `ListInstalled` -> `installed=1`, then back to `installed=0`) is already asserted by the existing probe checks and now runs through the new sequence. Nothing was built or booted here.

**Files:** `shell/src/store/{JobBook.h,JobBook.cpp,StoreBackend.h,DBusStoreBackend.h,DBusStoreBackend.cpp,MockStoreBackend.h,MockStoreBackend.cpp,Store.h,Store.cpp}`, `shell/src/profiles/{ProfilesBackend.h,DBusProfilesBackend.cpp,MockProfilesBackend.h,MockProfilesBackend.cpp,Profiles.h,Profiles.cpp}`, `shell/src/library/{LibraryBackend.h,DBusLibraryBackend.cpp,MockLibraryBackend.h,MockLibraryBackend.cpp,Library.h,Library.cpp}`, `shell/src/update/{UpdateBackend.h,DBusUpdateBackend.cpp,MockUpdateBackend.h,MockUpdateBackend.cpp,Update.h,Update.cpp}`, `shell/qml/AppDetailPage.qml`, `shell/CMakeLists.txt`, `shell/tests/{tst_late_replies.qml,tst_store_backend.qml,tst_store_ui.qml}`, `scripts/vm-store-check.sh`, `shell/CLAUDE.md`, `docs/specs/03-services-and-apps.md`.

**Deviations / notes**
- Scope was "Profiles, check Library/Update/Store"; the Library and Update guards and the `Search` guard are the result of that check. Session `ListRunning` was left out (Inbox).
- No contract (`Store1.xml`) or service change. `StoreBackend::serviceLost` (internal signal) changed its argument from a list of app ids to job id -> app id, which the by-id correction needs.
- The StoreJob struct moved from `StoreBackend.h` to `JobBook.h` (still included by `StoreBackend.h`).

**Known limits**
- A queued job adopted at start (found by `ListJobs`) does not show as working on its app's page: `Store.jobs` holds running jobs only.
- A `ListJobs` reply drops the progress of a job started after the request was sent, until that job's next `JobProgress`.

**Round 2 (review):** `init()` of `tst_store_backend.qml` now also waits for `Store.mockPendingReplies() === 0`, so `test_a_late_installed_list_is_dropped` and `test_a_late_catalogue_is_dropped` no longer depend on test order. Comments added in `Store.cpp` (one tracked job per app) and on `test_job_table_replaces_a_stale_entry`.

**Follow-ups (Inbox)**
- (T-191) The two known limits above.
- (T-191) Session `ListRunning` -> `runningListed` is an unguarded model-replacing reply; guard it together with its `AppStarted`/`AppExited` interplay.
