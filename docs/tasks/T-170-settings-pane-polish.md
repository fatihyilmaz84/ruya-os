# T-170 — Settings panes: no clipped top rows; Bluetooth and Storage pane fixes

Status: todo · Phase: 2 · Depends: T-137 · Area: shell · Size: S · Owner: builder

## Goal
When a Settings pane scrolls, its first rows no longer slide under the header. Pressing Accept on a device that is already pairing does nothing. A failed Disconnect says so.

## Read first
- `docs/specs/04-design-system.md` §2 (Settings two-pane), §5 (rows), §8
- `shell/qml/SettingsPane.qml` (`ensureFocusedVisible`), `SettingsPage.qml`, `BluetoothPane.qml`, `NetworkPane.qml`, `StoragePane.qml`
- `shell/tests/tst_bluetooth.qml`, `tst_network.qml`, `tst_storage.qml`
- Screenshots `23-settings-network.png`, `26-settings-bluetooth.png`, `27-settings-storage.png` (the clipping)

## Scope
1. **Clipping:** a scrolled pane's top rows are drawn under the header (seen in the Network, Bluetooth and Storage shots). Clip the pane's content to its own area, or keep the focused row fully inside it. Fix it once in `SettingsPane`, not per pane.
2. **Bluetooth:** Accept on the row whose device is pairing (`busyId`) is ignored. A failed Disconnect shows a Disconnect-specific message (it says "Could not connect." today). Add Turkish.
3. **Tidy:** remove the unused `setup` parameter of `tst_storage.qml`'s `run()` helper.

## Out of scope
- New rows, panes or tokens.
- The BlueZ and udisks2 services (T-173, T-174).

## Acceptance criteria
- [ ] With focus on the last row of a long pane, every visible row lies inside the pane's area, below the header (property test with `mapToItem`, in `tst_settings.qml` or the pane's test).
- [ ] A second Accept while a device is pairing doesn't call pair again (test in `tst_bluetooth.qml`, counting the mock's pair calls).
- [ ] A failed Disconnect toasts the new message (test in `tst_bluetooth.qml`).
- [ ] Screenshots `23-settings-network.png` and `26-settings-bluetooth.png` re-shot and reviewed: no row under the header.
- [ ] `dev.ps1 test` ALL GREEN.

## Docs to update
- `04` §5 if the pane's clipping rule needs a line.

## Hints
- The mock answers pairing at once. To hold a pairing open in the test, use the mock's existing delay or add a test hook, as `MockStoreBackend` does for jobs.

## Outcome
_Filled in by the implementer._
