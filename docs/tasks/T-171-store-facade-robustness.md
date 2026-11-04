# T-171 — Store: no ghost jobs when the service restarts; no null-binding warnings

Status: done · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

## Goal
If `ruya-store` restarts or vanishes mid-install, the Store stops showing a job that will never finish. The Store page no longer logs TypeErrors while pages are pushed and popped.

## Read first
- `docs/specs/03-services-and-apps.md` (Store)
- `shell/src/store/Store.cpp` (`m_jobs`, filled on jobProgress, removed on jobFinished; `mockReset` since T-167), `DBusStoreBackend.cpp`
- `shell/src/network/DBusNetworkBackend.cpp` (how a backend watches its service's name owner, if it does; otherwise `QDBusServiceWatcher`)
- `shell/qml/StorePage.qml` lines 180–190; `shell/tests/tst_pages.qml::test_back_walks_the_stack`

## Scope
1. **Ghost jobs:** when the service's bus name loses its owner (or gets a new one), the facade drops its jobs and the UI shows none. The backend interface gets a "service went away" signal; the mock gets a way to simulate it for tests.
2. **Null bindings:** `StorePage.qml:185/186` read `sourceText`/`sourceKind` of a null item about 30 times during `test_back_walks_the_stack`. Guard the binding (or fix its lifetime) so the run logs no `TypeError`.

## Out of scope
- Resuming a job after the service comes back.
- Other Store UI changes.

## Acceptance criteria
- [ ] With a job running in the mock, a simulated service loss leaves `Store.jobs` empty and the row's progress hidden (test in `tst_store_backend.qml` or `tst_store_ui.qml`; it fails without the fix).
- [ ] `tst_pages` runs without a `StorePage.qml` `TypeError` in the log (the Outcome quotes the grep; if a test can assert it with `ignoreWarning`/`failOnWarning`, do so).
- [ ] VM (lead run): `scripts/vm-store-check.sh` gains a step that restarts `ruya-store` during an install; afterwards the shell's job list is empty (Outcome: `Verified: vm (lead, 2026-11-04: image 0.0.32 of main, `RUYA_BOOT_OK 0.0.32`; `vm-store-check.sh check` ALL CHECKS PASSED, 48 passes. The restart step, as rewritten by the lead in ac31a3b: the probe's Store requested the install, the job reached `Store.jobs`, `systemctl restart ruya-store` ended it as `failed`, no `ok` for it, `jobs={}` afterwards.)`).
- [ ] `dev.ps1 test` ALL GREEN.

## Docs to update
- `03` Store section: what the shell does when the service goes away.

## Hints
- Qt 6.8 has `QTest::failOnWarning` and QML `TestCase.failOnWarning`: use them to make the warning check a real test.

## Outcome
Verified: host (vm pending: vm-store-check.sh)

- `StoreBackend::serviceLost(appIds)` (new). `DBusStoreBackend` now watches the name with `WatchForOwnerChange`; on `serviceOwnerChanged` with a non-empty old owner (loss or direct handover) it reports every app in its job map (running and queued) and clears its job map and early-signal buffer and emits it. `MockStoreBackend::loseService()` simulates it; `Store.mockServiceLost()` exposes that to tests.
- `Store` on `serviceLost`: clears `jobs`, emits `jobsChanged`, then `jobFinished(id, "failed")` for every job the service ran or queued (the backend's app ids plus the facade's running ones). A queued job has no progress yet, so the facade's own map alone would miss it (round 2); `test_service_loss_ends_a_queued_job` covers it. Without that, `AppDetailPage` kept `working` true with its progress bar (it only leaves that state on `jobFinished`), so clearing `jobs` alone would not hide the row's progress. This is the one choice beyond the literal scope.
- `StorePage.qml` card badge: `page ? page.sourceText(..) : ""` (and `"info"` for kind).
- Tests: `tst_store_backend::test_service_loss_drops_running_jobs`, `tst_store_ui::test_service_loss_ends_the_job` (both fail when the `serviceLost` handler is made a no-op: undone change, checked); `tst_pages::test_back_walks_the_stack` now calls `failOnWarning(/StorePage\.qml.*TypeError/)` (checked it bites by logging a matching warning: FAIL).
- Honest note on the TypeError: I could not reproduce it offscreen on this checkout. With the QML guard reverted, `grep -c TypeError shell/build-win/ruya-qmltest.txt` was 0 for the whole suite, so the `failOnWarning` test passes with and without the guard; the guard is defensive and the test a tripwire. The warning may only occur under `shots` or different timing.
- VM: `scripts/vm-store-check.sh` (check mode), last step: a fresh probe, Install, `systemctl restart ruya-store` right after the reply, then expects the probe line `jobFinished <app> failed` (only the service-lost path produces it for a cut-short install), no `jobFinished ... ok`, and `jobs={}`. Not run (lead run).
- Spec: `03` Store paragraph.
- Files: shell/src/store/{StoreBackend.h,DBusStoreBackend.cpp,MockStoreBackend.h,Store.h,Store.cpp}, shell/qml/StorePage.qml, shell/tests/{tst_store_backend,tst_store_ui,tst_pages}.qml, scripts/vm-store-check.sh, docs/specs/03-services-and-apps.md.
