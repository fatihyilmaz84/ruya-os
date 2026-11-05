# T-181 — Shell D-Bus backends: a late reply never overwrites newer data

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: M · Owner: builder

## Goal
The Network, Bluetooth, Storage and Audio D-Bus clients refresh asynchronously. A slow reply to an old request must not replace what a newer request (or a pushed signal) already delivered. The battery backend got this guard in T-177; give the other four the same, from one shared piece instead of five copies.

## Read first
- `shell/src/battery/` (`BatteryBackend`: `beginRequest`/`deliver`) and the T-177 Outcome (`docs/tasks/T-177-devices-watchers-and-battery-polish.md`) for why
- `shell/src/network`, `shell/src/bluetooth`, `shell/src/storage`, `shell/src/audio` (each `DBus*Backend.cpp` and its base class) and `shell/CMakeLists.txt`
- `shell/CLAUDE.md` (backend pattern)

## Scope
1. Lift the request-sequence guard out of `BatteryBackend` into a small shared helper (a header-only class or a base-class mixin; your call) and use it in battery, network, bluetooth, storage and audio backends for every async refresh whose reply replaces a model.
2. Each backend gets a test with a **fake bus reply that arrives out of order** (older reply delivered after the newer one): the model keeps the newer data. Use the pattern T-177 used for batteries.

## Out of scope
- New backend features, signal handling changes, contract changes.

## Acceptance criteria
- [ ] For each of network, bluetooth, storage, audio: a test delivers reply 2 then reply 1 and asserts the model shows reply 2 (`tst_*.qml` or the C++ test the battery one uses).
- [ ] Revert check: each of those tests fails when the guard is removed from that backend.
- [ ] `BatteryBackend` uses the shared helper and its T-177 test still passes unchanged.
- [ ] New files are in `shell/CMakeLists.txt`. `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `shell/CLAUDE.md` or `shell/PATTERNS.md`: one line on using the helper in a new backend.

## Hints
- If a backend has no seam to feed a fake reply, add the smallest one the battery test uses; don't restructure the backend.

## Outcome
Verified: host (`dev.ps1 test` ALL GREEN, offscreen; the D-Bus clients themselves cannot run on this machine, see below).

Built:
- `shell/src/backend/RequestSequence.h`: a header-only class, `begin()` numbers a request, `accept(n)` is true only for a reply newer than any already reported. Moved out of `BatteryBackend`, which now holds one.
- Each backend base class (`NetworkBackend`, `BluetoothBackend`, `StorageBackend`, `AudioBackend`, like `BatteryBackend` already) owns one `RequestSequence` per kind of reply that replaces a model: Network state + networks, Bluetooth state + devices, Storage volumes, Audio state + sinks. It offers `begin...Request()` and `deliver...()` that emit the signal only for the newest reply. The D-Bus client (`refreshState`, `refreshNetworks`, `refreshDevices`, `refreshSinks`, `refresh`) numbers the request when it sends it and delivers through the base class; so does the mock, so a test with the mock exercises the same guard.
- Seam, copied from the battery test: each mock got `setReplyDelay(ms)`/`pendingReplies()` (only `refresh()` replies are delayed; the mock's own change notifications stay immediate), and each facade `mockRefreshDelayed(ms)`/`mockPendingReplies()`. Bluetooth's mock now sends its state and its device list as two requests, like the bus.
- Tests (`test_an_older_reply_arriving_late_is_dropped` in `tst_network`, `tst_bluetooth`, `tst_storage`, `tst_audio`): the reply to an old refresh is held back, the data changes (cable unplugged and Cafe Guest joined; Bluetooth switched off; stick plugged in; volume raised and headset plugged in), the late reply lands and the model keeps the newer data. `tst_battery` is unchanged and passes.
- Docs: one bullet in `shell/CLAUDE.md` (backend pattern).

Revert check (done twice): (1) removed the `accept()` guard from all four base classes, so the four tests failed (Audio "the late state was dropped", Bluetooth "the late powered state was dropped", Network "the late wired state was dropped", Storage "the late two-volume reply was dropped"), everything else passed; (2) removed it only from the second kind of reply (networks, devices, sinks), so the Network, Bluetooth and Audio tests failed on their list assertion ("the late output list was dropped", ...). Guards restored afterwards.

Not verifiable here: the guard code in the `DBus*Backend.cpp` files is exercised only on Linux (no bus on this host); the tests cover the shared guard through the mock, which calls the same base-class `deliver` functions. The D-Bus clients are a mechanical change (number at send, deliver at reply).

Files: see the commit. Deviations: none. No contract change. A signal-driven refresh (`NetworksChanged`, `PropertiesChanged`, ...) is itself a new request, so a pushed update is also protected against an older reply.
