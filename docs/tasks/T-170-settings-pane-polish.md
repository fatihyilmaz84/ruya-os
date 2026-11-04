# T-170 — Settings panes: no clipped top rows; Bluetooth and Storage pane fixes

Status: done · Phase: 2 · Depends: T-137 · Area: shell · Size: S · Owner: builder

## Goal
When a Settings pane scrolls, its first rows no longer slide under the header. Pressing Accept on a device that is already pairing, or a drive that is ejecting, does nothing. A failed Disconnect says so. Drive sizes follow the shell language.

## Read first
- `docs/specs/04-design-system.md` §2 (Settings two-pane), §5 (rows), §8
- `shell/qml/SettingsPane.qml` (`ensureFocusedVisible`), `SettingsPage.qml`, `BluetoothPane.qml`, `NetworkPane.qml`, `StoragePane.qml`
- `shell/tests/tst_bluetooth.qml`, `tst_network.qml`, `tst_storage.qml`
- Screenshots `23-settings-network.png`, `26-settings-bluetooth.png`, `27-settings-storage.png` (the clipping)

## Scope
1. **Clipping:** a scrolled pane's top rows are drawn under the header (seen in the Network, Bluetooth and Storage shots). Clip the pane's content to its own area, or keep the focused row fully inside it. Fix it once in `SettingsPane`, not per pane.
2. **Bluetooth:** Accept on the row whose device is pairing (`busyId`) is ignored. A failed Disconnect shows a Disconnect-specific message (it says "Could not connect." today). Add Turkish.
3. **Storage (T-137 review):** an in-flight guard on Eject like Bluetooth's `busyId`, so a second Accept or a key repeat doesn't send a second Eject (a real unmount takes seconds). A test proves "Drive inserted" stays one toast when the volume list is published again after the insert (`Storage.cpp` `m_pendingAdded`: changing `remove` to `contains` must fail it). Sizes: `formatBytes` uses the system `QLocale`, so English UI shows "318,0 GB" on this host. Make sizes follow the shell language and drop a trailing ",0"/".0".
4. **Tidy:** remove the unused `setup` parameter of `tst_storage.qml`'s `run()` helper.

## Out of scope
- New rows, panes or tokens.
- The BlueZ and udisks2 services (T-173, T-174).

## Acceptance criteria
- [ ] With focus on the last row of a long pane, every visible row lies inside the pane's area, below the header (property test with `mapToItem`, in `tst_settings.qml` or the pane's test).
- [ ] A second Accept while a device is pairing doesn't call pair again (test in `tst_bluetooth.qml`, counting the mock's pair calls).
- [ ] A failed Disconnect toasts the new message (test in `tst_bluetooth.qml`).
- [ ] A second Accept on Eject while ejecting sends no second Eject; a republished list after an insert keeps one "Drive inserted" toast; in English, 1 500 000 000 bytes reads "1.5 GB", and in Turkish "1,5 GB" (`tst_storage.qml`).
- [ ] Screenshots `23-settings-network.png` and `26-settings-bluetooth.png` re-shot and reviewed: no row under the header.
- [ ] `dev.ps1 test` ALL GREEN.

## Docs to update
- `04` §5 if the pane's clipping rule needs a line.

## Hints
- The mock answers pairing at once. To hold a pairing open in the test, use the mock's existing delay or add a test hook, as `MockStoreBackend` does for jobs.

## Outcome
Verified: host (Qt Quick tests offscreen ALL GREEN; `shots` reviewed for 23 and 26).

**Clipping (`SettingsPane`, once).** The pane now scrolls in whole rows: `ensureFocusedVisible` puts the top edge on a row's top and the clip (`viewport`, a clipping Item around the Flickable) ends at the bottom of the last row that fits whole, so no row is drawn cut, under the header or at the bottom edge. `relayout()` re-aligns after rows change or the pane is resized. Cost: a little empty space under the last whole row. Test `tst_settings.qml` `test_scrolled_pane_draws_only_whole_rows` (Bluetooth pane after two scans, pane shrunk to leave a half row). Note: in the old shots the cut rows were at the bottom edge; at that size nothing was under the top edge, so I read "no clipped rows" as "no row drawn partly".

**Bluetooth.** `activate` ignores the row whose device is `busyId`; `statusText("disconnect", ...)` gives "Could not disconnect." (Turkish "Bağlantı kesilemedi."). Tests: `test_second_accept_while_pairing_does_not_pair_again`, `test_failed_disconnect_says_so`. Test hooks: `Bluetooth.mockHoldPairing(bool)` and `mockPairCalls()` (mock only).

**Storage.** `StoragePane.ejectVolume` guards with `ejectingId` (cleared on the eject answer). Hooks: `Storage.mockHoldEject`, `mockEjectCalls`, `mockRepublish`. Tests `test_eject_in_flight_sends_one_eject`, `test_republished_list_keeps_one_inserted_toast` (fails with `remove` changed to `contains` in `Storage.cpp`, tried), `test_format_bytes` ("1.5 GB" en, "1,5 GB" tr, "32 GB"). `formatBytes` uses `QLocale()`; `DeviceSettings::applyLanguage` now calls `QLocale::setDefault(QLocale(language))` so it follows the shell language, and drops a trailing ",0"/".0". The unused `setup` parameter of `run()` is gone.

Revert checks (round 2): the Settings test now shrinks the pane (bottomMargin) so a half row is left over, and asserts `viewport.height` equals the bottom of the last whole row, `scrollY` is some row's y, and the viewport ends at a row bottom after scrolling. It fails with `updateView` always setting `view.height = pane.height` (reverted a) and with `ensureFocusedVisible` bottom-aligned as on main (reverted b: "btDev_bt-flaky starts below the top edge"). Round 1's claim that it failed with the QML stashed was only because `viewport` did not exist on main. The Bluetooth and Storage tests fail with BluetoothPane/StoragePane stashed; the republish test fails with `contains` in `Storage.cpp`. Side effect of `QLocale::setDefault`: `Qt.formatDateTime` in SystemPane.qml now uses the shell language's month names (Turkish when the language is tr).

Files: shell/qml/SettingsPane.qml, BluetoothPane.qml, StoragePane.qml; shell/src/bluetooth/{Bluetooth,MockBluetoothBackend}.{h,cpp}; shell/src/storage/{Storage,MockStorageBackend}.{h,cpp}; shell/src/settings/DeviceSettings.cpp; shell/tests/tst_settings.qml, tst_bluetooth.qml, tst_storage.qml; shell/i18n/*.ts; docs/specs/03, 04.

