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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
