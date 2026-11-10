# T-221 — App management: see what is installed, free space, remove games and apps

Status: todo · Phase: 3 · Depends: T-394, T-215 · Area: shell, services · Size: M · Owner: builder

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** Item 2 (the Options menu on cards) is T-393/T-394's and is removed here, with its tests and screenshots; the uninstall confirm is T-393's component with T-215's semantics, and the "keep data, reinstall finds it" VM criterion stays in T-215 only. Split the rest if pane, bulk remove and update management exceed size M.

## Goal
A player can find an installed game or app, see what it costs, update it and remove it, from the controller, in two places: Settings -> Apps (the full list) and the Options menu on any game or app card. Owner question, 2026-11-06: "how does the user remove installed games and apps?" Today the Store has `Uninstall(id, delete_data)` and an uninstall action on the app page; there is no overview of installed apps, no sizes, and no context menu on cards (the context-menu key is part of B-006).

## Read first
- `docs/specs/03-services-and-apps.md` §4.3 (`ruya-store`: jobs, `ListInstalled`, `Uninstall`, updates), §4.5a (data; T-215 adds "Keep saves?" and per-app data sizes), `docs/specs/02-shell.md` §4.3 (the Options/context key: long Accept or Y/Triangle; see B-006), Home/Games cards, `AppDetailPage.qml`, `StorePage.qml`, `StoragePane.qml` (T-196)
- `api/dbus/org.ruyaos.Store1.xml` (`ListInstalled`, `Uninstall`, `Update`, `InstalledChanged`, job signals), `Library1` (`ListItems`, last played), `Session1` (is it running: an app that runs cannot be removed)
- T-215 (data sizes and the Keep-saves question), T-196 (free space), T-220 (permissions list), T-211 (a restricted profile needs a parent to remove)

## Scope
1. **Settings -> Apps** (new pane, or the top of Storage if the design review prefers): the list of installed apps and games with icon, name, size (app + the active profile's data, from T-215 when present; app size alone before), last played, version and an "Update available" mark; sort by name / size / last played; a **"Free up space"** view that sorts by size and highlights apps not played for 60 days. Per app a page with: **Open**, **Update** (or "Up to date"), **Remove** (confirmation: "Remove <name>? Your saves are kept." with Keep saves as the default, Delete saves explicit, per T-215; the confirm button says the action, T-194), **Clear cache** (when T-215 exists), **Permissions** (read-only list now, toggles with T-220), **Details** (opens the Store page). Removing runs as a Store job with progress and the existing toast on finish; an app that is running says "Close it first" with a button to close it (`Session.stop`).
2. **Options menu on cards** (Home, Games, Store): the Options key opens a small glass menu at the card: **Open**, **Details**, **Remove...** (same confirmation), **Update** when one exists; keys and focus rules per 02 §4.3 and `04` §4 (the menu takes focus, B closes it, focus returns to the card); a keyboard equivalent (the Menu key) and long-press Accept if B-006 decides it; hidden entries for actions the profile may not do (restricted profiles: "Ask a parent", T-211).
3. **Bulk remove:** select several apps in the list (a toggle mode: A selects, Options -> "Remove selected") with a total size shown before confirming; one job per app, one summary toast.
4. **Update management:** "Update all" and per-app update in the list; "Updates" shows apps with updates and their sizes; respects the metered-connection rule (T-216) once it exists.
5. **Service additions only if needed:** `ListInstalled` already carries ids and names; add `installed_size`, `version` and `last_updated` to its records if missing (contract change in the same commit, mock and client updated); last played comes from `Library1`.
6. **Mocks and tests;** Turkish strings.

## Out of scope
- Moving apps between drives, installing from USB (a later task), app permissions toggles (T-220), per-app data backup/restore (T-215), uninstalling system components, rolling back an app to an older version (Flatpak supports it: Inbox).

## Acceptance criteria
- [ ] `tst_apps.qml` (mock): the list shows installed apps with sizes and marks, sorting works, "Free up space" ordering, the app page actions run the right Store calls, Remove shows the confirmation with Keep saves as default and calls `Uninstall` with the right flag, a running app offers Close first, bulk select shows the total and removes each; an update marks and applies; the Options menu on a card opens, takes focus, closes with B and returns focus to the card; hidden actions for a restricted profile; everything reachable with the controller keys, focus asserted after each step; late replies guarded.
- [ ] Screenshots: Settings -> Apps (list, app page, confirmation, free-up-space), the card Options menu on Home and Games, bulk mode; English and Turkish; read against `04` §8.
- [ ] Rust tests for any `ListInstalled` record additions (and the XML, mock and D-Bus client agree).
- [ ] VM (lead run): through the real bus with the `org.ruyaos.Test*` apps: the list matches `flatpak list`, `Uninstall` with keep leaves the data and reinstall finds it, an uninstall while the app runs is refused with the right status; `Verified: host (vm pending: ...)`.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `02-shell.md` (Settings -> Apps, the Options menu), `03` §4.3, the Store XML if changed, `docs/developers/` (what players can do with your app: remove, keep saves), `docs/dev-setup.md`.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
