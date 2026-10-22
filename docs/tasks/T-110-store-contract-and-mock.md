# T-110 — Store: D-Bus contract and mock backend

Status: todo · Phase: 3 · Depends: — · Area: api, shell · Size: M

## Goal
A written `org.ruyaos.Store1` contract, plus a shell-side `Store` singleton with a mock backend (fake catalogue, simulated installs) and a D-Bus client, so the store UI (T-111) can be built and tested on Windows. The real Rust service needs Linux and libflatpak (blocked item B-004).

## Read first
- `docs/specs/03-services-and-apps.md` §4, especially §4.2 (sources), §4.3 (method list) and §4.4 (permissions)
- `api/dbus/org.ruyaos.Profiles1.xml` (contract style, status-string header)
- `shell/src/profiles/` (the backend pattern to copy) and `shell/CLAUDE.md`

## Scope
1. `api/dbus/org.ruyaos.Store1.xml`:
   - methods: `Search(s query)`, `GetApp(s id)`, `ListInstalled()`, `Install(s id) → s job`, `Uninstall(s id, b delete_data) → s job`, `Update(s id) → s job`, `ListRemotes()`;
   - signals: `JobProgress(s job, u percent, s phase)`, `JobFinished(s job, s status)`, `InstalledChanged()`.
   - App record fields:
     - id, name, summary, description, developer;
     - source (`official|community|developer`);
     - controller support (`full|partial|none`);
     - OARS age rating;
     - permissions as stable keys: `network`, `home-files`, `host-files`, `all-devices`, `audio`, `gamepad`, `session-bus` …;
     - installed size;
     - art (icon/tile/hero URLs);
     - installed (bool) and update-available (bool).
   - Document the status strings in the header, as in Profiles1, and choose D-Bus types explicitly (an `a{sv}` dict per app is acceptable and future-proof).
2. `shell/src/store/`: `StoreBackend`, `MockStoreBackend`, `DBusStoreBackend` and the `Store` QML singleton (backend choice via `RUYA_SERVICES` like Profiles).
   - Mock catalogue: about 12 apps spread over all sources and controller levels. A few are installed initially, and one has an update available.
   - Mock install: progress 0→100 over about 2 s, phases `download → install`, then `JobFinished ok` and `InstalledChanged`.
   - The app with id `org.example.Broken` always finishes with `failed`.
   - Uninstall finishes quickly; `delete_data` is recorded so tests can assert it.
   - Art: no network. QML generates tile art from a colour and initials keyed by id (reuse the idea in `ProfileCard`). The mock returns empty art URLs.
3. `Store` facade properties and methods for QML:
   - `catalogue`, `installed`, `jobs` (map id → `{percent, phase}`), `available`, `mock`;
   - invokables `search()`, `install()`, `uninstall()`, `update()`;
   - signal `jobFinished(appId, status)`.

## Out of scope
- Any UI beyond what a test needs (T-111).
- The Rust service (B-004).

## Acceptance criteria
- [ ] `Store1.xml` covers every method listed in spec §4.3. The Outcome contains a table mapping spec item → XML member.
- [ ] Mock install of a non-installed app: progress values are monotonic, reach 100, the app appears in `installed`, and `jobFinished(id, "ok")` is emitted (test `tst_store_backend.qml::test_install_lifecycle`).
- [ ] Installing `org.example.Broken` → `jobFinished(..., "failed")`, and the app is not installed (test `test_install_failure`).
- [ ] Uninstall with `deleteData = true` is recorded and the app leaves `installed` (test `test_uninstall`).
- [ ] `search("")` returns the whole catalogue; `search("xyz-none")` returns nothing (test `test_search`).
- [ ] The D-Bus client compiles (Windows build) and its method names match the XML. List them side by side in the Outcome. **Runtime unverified.**

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §4.3: point to the XML and note any naming differences.
- `docs/STATUS.md`: D-Bus client unverified; B-004 is still blocked.

## Hints
- Adding the new C++ `QML_ELEMENT` types is safe on the first `dev.ps1` run since T-116 (the stale type-registration step is handled in CMake); you do not need to build twice.
- Make the mock's progress timer interval injectable (e.g. `RUYA_MOCK_FAST=1` → 10 ms steps) so tests stay fast.

## Outcome
_Filled in by the implementer._
