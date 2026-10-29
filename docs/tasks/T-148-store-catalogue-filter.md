# T-148 — Store: filter the catalogue in the service, re-read it only when it changes

Status: done · Phase: 3 · Depends: T-140 · Area: api, services, shell · Size: M

## Goal
With Flathub's 3405 apps in the image, the shell no longer re-reads the whole catalogue (a 6 MB `Search("")` reply, seconds of work) after every install or uninstall, and the Store UI (T-111) can ask the service for controller-capable apps only, as spec 03 §4.2 requires by default.

## Read first
- `docs/specs/03-services-and-apps.md` §4.2 (controller filter, "Show all apps"), §4.3 (as built)
- `api/dbus/org.ruyaos.Store1.xml` (`Search`, `ListInstalled`, `InstalledChanged`)
- `services/ruya-store/src/service.rs`, `src/dbus.rs`; `shell/src/store/` (`Store.cpp` re-reads on `installedChanged`, `DBusStoreBackend.cpp`, `MockStoreBackend.cpp`)
- `docs/tasks/T-140-store-remotes-and-progress.md` Outcome (where `InstalledChanged` is sent today)
- Root `CLAUDE.md` "Crossing the shell/service boundary" (XML first; XML, service, mock and client in one commit)

## Scope
1. **Contract** (`Store1.xml`): a new signal `CatalogChanged` ("the catalogue was (re)read: call Search again"), sent after the first catalogue read, after an AppStream refresh and after `AddRemote`. `InstalledChanged` then means only what its name says. `Search` gains filter options, e.g. `Search(query s, options a{sv})` with `controller` = `"any"` (default) or `"gamepad"` (`full` or `partial`) and `limit` u (0 = no limit). Extend the contract differently if that is cleaner; say why in the Outcome.
2. **Service:** `ruya-store` applies the options in the pure core (unit-tested), sends `CatalogChanged`/`InstalledChanged` as above.
3. **Shell:** `Store` re-reads the installed list (`ListInstalled`) on `InstalledChanged` and patches the `installed`/`update_available` flags of the apps it holds, and repeats its last search on `CatalogChanged`. The mock and `DBusStoreBackend` follow the contract. `Store` exposes the controller filter so T-111's "Show all apps" toggle needs no further backend work.
4. `scripts/vm-store-check.sh`: assert that an install sends `InstalledChanged` but not `CatalogChanged`, and that `Search` with `controller=gamepad` returns fewer apps than without.

## Out of scope
- The Store UI itself (T-111), paging in the UI, featured lists, the `ruyaos` remote.

## Acceptance criteria
- [ ] Rust unit tests: the controller filter and `limit`; which signal each event sends (fake flatpak).
- [ ] Shell test (`tst_store.qml` or a new test): after an install in the mock, the app's `installed` flag flips without a new full search (count the mock's search calls); `CatalogChanged` repeats the last query.
- [ ] VM (image from this commit, `smoke-test.ps1 -Keep`, `vm-store-check.sh`): all checks pass, including the two new ones; time from the test install's `JobFinished` to the shell probe seeing the app installed, before/after, in the Outcome.
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
# WSL: scripts/build.sh, make-disk.sh qcow2; then
.\scripts\smoke-test.ps1 -Keep    # and scripts/vm-store-check.sh in the guest (dev-setup.md, "Store check")
```

## Docs to update
- Spec 03 §4.3 (signals, filter); `docs/dev-setup.md` "Store check" (new assertions).

## Hints
- The `controller` value is already in every app record (`full | partial | none`); unknown counts as `none`.
- Keep `Search("")` working with no options for existing callers until they are all migrated in this commit; then drop the old signature (contracts are drafts until release).

## Outcome
Verified: vm (image `0.0.19-t148` booted `RUYA_BOOT_OK`; `vm-store-check.sh` ALL CHECKS PASSED over the real system bus, 3419-app catalogue). `dev.ps1 test` ALL GREEN (198 QML, Rust incl. 5 new store tests).

- **Contract:** `Search(query s, options a{sv})` with `controller` (`any` | `gamepad` = `full` or `partial`; unknown counts as none) and `limit` u (0 = none); a bad value of a known key gives `InvalidArgs`. New signal `CatalogChanged`. The old one-argument `Search` is gone (the only callers, the D-Bus client and the VM script, were migrated in the same commit).
- **Service:** `SearchOptions` and `Store::search(query, &options)` in `service.rs`; `Store::sync` (first read, then AppStream refresh) replaces the thread body of `spawn_sync` and is unit-tested: it sends `CatalogChanged` after each step and `InstalledChanged` only when the installed set or an update flag differs. Jobs send `InstalledChanged` only. `Event::CatalogChanged` is forwarded in `dbus.rs`.
- **Shell:** `StoreBackend::search(query, gamepadOnly, limit)`, `searchFinished` carries `gamepadOnly`, new `catalogChanged`. `Store` patches the flags of `catalogue`/`results` when `ListInstalled` arrives (no `Search`), repeats the catalogue read and the last query on `CatalogChanged`, and has `controllerFilter` (default `any`, so existing UI is unchanged; T-111 sets `gamepad` and offers "Show all apps"). The filter applies to `search()` results; `catalogue` stays whole so `Store.app()` finds every app. Replies that do not match the last query and filter are ignored for `results`.
- **Tests:** `tst_store_backend.qml` (+3: flags flip with no new search, `CatalogChanged` repeats the query, filter); Rust: filter, limit, option parsing, signals per event. `vm-store-check.sh`: gamepad filter returns fewer apps (127 of 3419), `limit=1` returns one, an install sends no `CatalogChanged` (it first waits for the sync signals to settle).
- **Timing:** the shell saw the installed app within the check's 1 s polling step ("after about 0 s") after the install; before this task it re-read the 6 MB catalogue and T-140 recorded "seconds" without a number, so there is no measured before-value.
- **Files:** `api/dbus/org.ruyaos.Store1.xml`, `services/ruya-store/src/{service,dbus}.rs`, `shell/src/store/*`, `shell/tests/tst_store_backend.qml`, `scripts/vm-store-check.sh`, spec 03 §4.3, `dev-setup.md`.
- `shots` not run: no UI change.
