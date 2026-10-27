# T-137 — USB storage: `Devices1.Storage` contract, mock, Settings → Storage and the inserted toast

Status: todo · Phase: 2 · Depends: — · Area: api, shell · Size: M

## Goal
Plugging in a USB drive shows a toast; Settings → Storage lists the internal disk and removable volumes with free space and lets the user eject, against a mock. The udisks2 service part is a later task.

## Read first
- `docs/specs/03-services-and-apps.md` §2.2 (storage: auto-mount, the insert toast, nothing runs automatically; usage per app is later) and `docs/specs/02-shell.md` §5.1 (toasts)
- `api/dbus/org.ruyaos.Devices1.xml` and `docs/tasks/T-129-network-contract-and-settings.md` Outcome (the pattern for a new interface, mock, client, pane)
- `shell/src/network/`, `shell/qml/NetworkPane.qml`, `shell/qml/SettingsPage.qml` (`storage` placeholder), `shell/src/power/` (a confirm-free simple backend)
- `CLAUDE.md` security invariants (**nothing auto-runs from removable media**)

## Scope
1. **Contract:** `org.ruyaos.Devices1.Storage`: `ListVolumes()` (dictionaries: `id`, `label`, `filesystem`, `size_bytes`, `free_bytes`, `removable`, `mounted`, `mount_point`, `read_only`), `Eject(id)`, `VolumesChanged` signal, and `VolumeAdded(id)` so the shell can toast. Statuses: `ok`, `unknown-volume`, `busy`, `unsupported` (unknown filesystem), `failed`. Extend rather than work around.
2. **Shell `Storage` singleton** in `shell/src/storage/` (mock by default off Linux; D-Bus client compiled, **unverified**), same structure as `shell/src/network/`.
3. **Settings → Storage pane** (`StoragePane.qml`, in `CMakeLists.txt`): one row per volume with label, filesystem and "x GB free of y"; Accept on a removable volume offers Eject (action row); a simulated "unsupported" drive explains why it can't be used. Sizes use a locale-aware formatter in one place.
4. **Toast** "Drive inserted: <label>" on `VolumeAdded` and "Safe to remove" after a successful eject. No action buttons yet.
5. The mock has an internal disk, a USB exFAT stick that appears after a delay (`RUYA_MOCK_FAST` shortens it), and a drive with an unsupported filesystem.

## Out of scope
- udisks2 service, mounting policy and mount points per profile, Browse media, Install package, per-app usage, uninstall/clear data, optical media.
- Anything that executes content from a volume (the invariant above: no autorun, not even in the mock).

## Acceptance criteria
- [ ] Contract and mock agree (a test goes through every status string).
- [ ] A volume appearing in the mock raises the toast once, and the pane list updates with focus kept on a valid row (test, focus asserted).
- [ ] Eject by keys: the volume disappears, the "safe to remove" toast shows; ejecting a `busy` volume shows the message and leaves it listed (tests in `tst_storage.qml`).
- [ ] Focus is never stuck: on the unsupported drive's row Back still leaves the pane and focus returns to the category list (test).
- [ ] Screenshot `27-settings-storage.png` reviewed.
- [ ] `dev.ps1 test` ALL GREEN, `dev.ps1 shots` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §2.2 (as built, shell side only), `docs/specs/02-shell.md`, the XML header.

## Hints
- Format sizes with `Qt.locale()`-aware code; add a test with 0, 1023 and 1 500 000 000 bytes.
- Refresh translations; give Turkish a real translation.

## Outcome
_Filled in by the implementer. Start with a `Verified:` line._
