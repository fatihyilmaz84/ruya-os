# T-191 — Shell backends: Profiles guard, Store reconcile races, `working` from the job list

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: M · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
