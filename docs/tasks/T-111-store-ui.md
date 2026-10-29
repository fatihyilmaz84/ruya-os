# T-111 — Store UI: browse, detail page, install with progress

Status: done · Phase: 3 · Depends: T-110, T-119, T-148 · Area: shell · Size: M

## Goal
From the Store tile, the user browses apps, opens a detail page that explains the source and permissions plainly, and installs or uninstalls with visible progress, entirely by controller.

## Read first
- `docs/specs/03-services-and-apps.md` §4.2 (source badges, controller filter) and §4.4 (permission language, high risk)
- `docs/specs/02-shell.md` §1 (Store row); `docs/specs/04-design-system.md` §3, §5 (source badges use `Badge` from T-143 if it has landed; new components allowed: none without the lead, §8)
- `docs/tasks/T-110-store-contract-and-mock.md` Outcome (what the `Store` singleton actually exposes)

## Scope
1. `StorePage.qml` (replacing the T-101 placeholder):
   - rows "Featured" (official apps), "Games", "Apps & media", and "Installed";
   - Up/Down between rows, Left/Right within a row.
2. Controller filter: apps with controller support `none` are hidden by default. A "Show all apps" toggle at the top (or in a row header) reveals them. Use the filter `Store` exposes since T-148 (the service filters; don't filter 3405 apps in QML).
3. Search: a Search row opens `TextEntry` (T-104, done; parent it to `page.overlay`), and the results replace the rows until Back.
4. `AppDetailPage.qml`, opened with Accept on any app (`Shell.openPage("appDetail", {appId})`, using T-119's nested pages; register it in `pageComponents`):
   - hero area (generated art), name, developer;
   - **source badge**: Official / Community / Developer as `Badge` (T-143) kinds `success` / `info` / `warning`; no new tokens;
   - controller support line and age rating;
   - permissions in plain language (spec §4.4); `all-devices`, `host-files` and `session-bus` are flagged **high risk** with a warning colour and icon text;
   - primary button: Install / Open (disabled placeholder) / Update; secondary: Uninstall, which asks for confirmation with a "Also delete my data" toggle;
   - a progress bar plus phase text while a job runs; errors are shown inline.
5. Back from the detail page restores focus to the tile that opened it.

## Out of scope
- Launching apps (needs the session service).
- Admin PIN gating of high-risk installs (add an Inbox line; the `PinPad` `collect` mode and `Profiles` admin flow from T-105 are the building blocks).

## Acceptance criteria
- [ ] Rows render from the mock catalogue; the controller-filter toggle changes the visible count (test `tst_store_ui.qml::test_controller_filter`).
- [ ] Install from the detail page shows progress, then the button becomes Open/Uninstall (test `test_install_from_detail`).
- [ ] The broken app shows an inline error and stays installable (test `test_install_error_inline`).
- [ ] High-risk permissions are visibly flagged (test asserts the flag via `objectName`; screenshot confirms).
- [ ] Uninstall confirmation defaults to Cancel and passes `deleteData` correctly (test `test_uninstall_confirm`).
- [ ] Back from the detail page restores tile focus (test `test_detail_back_restores_focus`).
- [ ] Screenshots `17-store-home.png`, `18-store-detail.png`, `19-store-installing.png` reviewed: badges legible, nothing clipped at 1280×720.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/02-shell.md` §1 Store row; `docs/specs/03-services-and-apps.md` §4.4: what the UI shows.

## Hints
- **UI rules since T-117:** every colour and duration comes from `Theme` (badges and the high-risk warning use the existing `Badge` kinds and toast colours), and the token lint in `dev.ps1 shell` fails on literals (quoted hex, `Qt.rgba(`, `duration: 120`). Generated art colours can come from `Qt.hsla(...)` of the id hash, which the lint does not flag. A new feedback animation must not run under reduced motion.
- Nested pages, `params` and state keeping come from T-119; do not re-solve them here. Back from the detail page must return to the Store page with the same row and item focused (`test_detail_back_restores_focus` relies on it).
- Reuse the Settings controls (`ToggleRow` for "Also delete my data") and the generated-art idea from `ProfileCard`.
- Use `Notifications.show` for "Installed" / "Update available"-style messages if useful, never for errors the user must act on (show those inline).
- **The real service exists since T-134** (`ruya-store`, VM-verified). It answers `Install` with only 0 and 100 progress (T-140 adds real percentages), and it delays a job's start by 100 ms so that `DBusStoreBackend::startJob` has the job id before the first signal. Make the client robust anyway: in `DBusStoreBackend`, keep `JobProgress`/`JobFinished` for a job id it doesn't know yet and replay them once the reply maps the id (add a test with a fake bus order if feasible, or say in the Outcome why not).

## Outcome
Verified: host (`test` ALL GREEN, `shots` ALL GREEN on the first run, `17` and `18` reviewed); the D-Bus replay of early job signals is unverified (QtDBus runs only on Linux, no test with a fake bus order).

Built: `StorePage.qml` (toolbar with Search and "Show all apps"; rows Featured = official, Games = controller `full`, Apps & media = the rest, Installed; a search replaces the rows with a results grid until Back; the page sets `Store.controllerFilter = "gamepad"` while open and restores `any`), `AppDetailPage.qml` (art, source `Badge`, controller and age lines, permissions in plain words with `High risk` flags, Install / Update / Open (disabled), Uninstall dialog with "Also delete my data", phase text and progress bar, inline errors), `AppArt.qml` (generated art from the id hash), `Page.openRequested(key, params)` wired in `Shell.openPage`, `appDetail` registered in `builtinPages`. `DBusStoreBackend` keeps `JobProgress`/`JobFinished` that arrive while an Install/Uninstall/Update reply is pending and replays them when the reply names the job. Tests: `tests/tst_store_ui.qml` (all named criteria plus search); `tst_pages.qml` now expects `storeCards_featured` on the Store tile. Turkish and English strings added.

Screenshot `19-store-installing.png`: the reviewed one (first `shots` run) showed the progress bar and "Downloading... 5%" but was caught mid-fade of the page transition; I added waits in the test to fix that, and two later `shots` runs hung on this desktop (timer stalls, see the 2026-10-29 T-150 note), so the fixed capture was never seen. Re-take it on an unlocked desktop.

Deviations / notes: rows follow the record (no genre field exists), so "Games" is controller `full`. Cards look the app up in `Store.catalogue` with `find()`; a bare `Store.catalogue;` statement is dropped by the QML compiler and the binding never updated. Search text is handed to `TextEntry.accepted` in the test (on-screen typing is `tst_textentry`'s job). `AppArt` is a new component the task did not list (Inbox). Admin PIN for high-risk installs not done (Inbox).

