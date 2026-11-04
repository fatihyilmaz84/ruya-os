# T-171 — Store: no ghost jobs when the service restarts; no null-binding warnings

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: S · Owner: builder

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
- [ ] VM (lead run): `scripts/vm-store-check.sh` gains a step that restarts `ruya-store` during an install; afterwards the shell's job list is empty (Outcome: `Verified: host (vm pending: vm-store-check.sh)`).
- [ ] `dev.ps1 test` ALL GREEN.

## Docs to update
- `03` Store section: what the shell does when the service goes away.

## Hints
- Qt 6.8 has `QTest::failOnWarning` and QML `TestCase.failOnWarning`: use them to make the warning check a real test.

## Outcome
_Filled in by the implementer._
