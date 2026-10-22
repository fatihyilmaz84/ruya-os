# T-111 — Store UI: browse, detail page, install with progress

Status: todo · Phase: 3 · Depends: T-101, T-110 (T-104 optional, for search) · Area: shell · Size: M

## Goal
From the Store tile, the user browses apps, opens a detail page that explains the source and permissions plainly, and installs or uninstalls with visible progress, entirely by controller.

## Read first
- `docs/specs/03-services-and-apps.md` §4.2 (source badges, controller filter) and §4.4 (permission language, high risk)
- `docs/specs/02-shell.md` §1 (Store row), §2 (visual language)
- `docs/tasks/T-110-store-contract-and-mock.md` Outcome (what the `Store` singleton actually exposes)

## Scope
1. `StorePage.qml` (replacing the T-101 placeholder):
   - rows "Featured" (official apps), "Games", "Apps & media", and "Installed";
   - Up/Down between rows, Left/Right within a row.
2. Controller filter: apps with controller support `none` are hidden by default. A "Show all apps" toggle at the top (or in a row header) reveals them.
3. Search: if T-104 is `done`, a Search row opens `TextEntry`, and the results replace the rows until Back. Otherwise show the row disabled and add a follow-up task.
4. `AppDetailPage.qml`, opened with Accept on any app (nested page, using T-101's push/pop):
   - hero area (generated art), name, developer;
   - **source badge**: Official / Community / Developer, with distinct colours (new Theme tokens);
   - controller support line and age rating;
   - permissions in plain language (spec §4.4); `all-devices`, `host-files` and `session-bus` are flagged **high risk** with a warning colour and icon text;
   - primary button: Install / Open (disabled placeholder) / Update; secondary: Uninstall, which asks for confirmation with a "Also delete my data" toggle;
   - a progress bar plus phase text while a job runs; errors are shown inline.
5. Back from the detail page restores focus to the tile that opened it.

## Out of scope
- Launching apps (needs the session service).
- Admin PIN gating of high-risk installs (create a follow-up task referencing T-105).

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
- **The T-101 page host shows only the top page.** `Shell.qml` has one `Loader` driven by `shownPage`, so pushing `AppDetailPage` destroys `StorePage`, and popping recreates it from scratch: focused row and tile index are lost. To meet "Back restores focus to the same tile", first extend the host so lower pages stay alive while hidden, for example by instantiating one item per `pageStack` entry and disabling all but the top one. Keep `focusCurrent()` as the single focus authority, and add a test to `tst_pages.qml` that pushes two pages and pops back. Saving and restoring an index by hand is the weaker fallback; if you use it, explain why in the Outcome.

## Outcome
_Filled in by the implementer._
