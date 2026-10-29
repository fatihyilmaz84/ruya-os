# T-148 — Store: filter the catalogue in the service, re-read it only when it changes

Status: todo · Phase: 3 · Depends: T-140 · Area: api, services, shell · Size: M

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
