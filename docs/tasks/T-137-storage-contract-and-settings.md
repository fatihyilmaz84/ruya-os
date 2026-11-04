# T-137 — USB storage: `Devices1.Storage` contract, mock, Settings → Storage and the inserted toast

Status: in-progress · Phase: 2 · Depends: — · Area: api, shell · Size: M

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
Verified: host (D-Bus client and the real udisks2 service unverified: none exists yet)

Built `org.ruyaos.Devices1.Storage` in the shared XML (`ListVolumes`, `Eject`, signals `VolumesChanged` and `VolumeAdded(id)`; statuses `ok`, `unknown-volume`, `busy`, `unsupported`, `invalid`, `failed`, documented in the header: `unsupported` is also what Eject answers for a listed-but-never-mounted drive, `failed` for a non-removable volume), `shell/src/storage/` (`StorageBackend`, `MockStorageBackend`, `DBusStorageBackend`, `Storage` facade; same structure as `bluetooth/`), `qml/StoragePane.qml` wired into `SettingsPage.qml`, and the two toasts in `ToastLayer.qml` ("Drive inserted: <label>" once the volume is in the list, "Safe to remove" after an ok eject). Turkish and English strings filled. `tests/tst_storage.qml`: 8 tests plus the screenshot `27-settings-storage.png` (reviewed: three volumes, free space, focus ring, Eject row, insert toast).

Decisions: the facade emits `volumeAdded(id, label)` only when the list holding the volume arrives (the signal itself carries just the id), so the toast has a label and appears once. Sizes: `Storage.formatBytes()` (QLocale, SI units), the only formatter. Eject rows follow the volume rows (as Forget does in Bluetooth); Accept on a removable volume moves focus to its Eject row, on the unsupported drive it toasts the reason. A new env `RUYA_MOCK_NO_STICK=1` (set in `tst_main.cpp`) stops the mock stick plugging itself in, otherwise it would toast inside every test; tests plug it with `Storage.mockPlugStick()` and one test uses `mockReset(true)` for the delayed insert. The mock's delay is 3 s, 30 ms with `RUYA_MOCK_FAST`.

`tst_settings.qml` `test_two_pane_navigation` used Storage as its "Coming soon" row: it now asserts Storage has a pane and uses Accessibility (the remaining empty category) for the same check, nothing weakened.

Revert test: with the "Safe to remove" toast removed and the mock's busy check removed, `test_eject_by_keys`, `test_busy_volume_shows_message_and_stays` and `test_contract_statuses` failed. `dev.ps1 test`: ALL GREEN (301 passed, 26 skips are the screenshot tests), `shots` ALL GREEN.

Files: `api/dbus/org.ruyaos.Devices1.xml`, `shell/src/storage/*`, `shell/qml/StoragePane.qml`, `SettingsPage.qml`, `ToastLayer.qml`, `shell/CMakeLists.txt`, `shell/tests/tst_storage.qml`, `tst_settings.qml`, `tst_main.cpp`, `shell/i18n/*.ts`, specs 02 and 03.
