# T-451 — Performance metrics: FPS and frame time from the compositor, CPU, RAM, temperatures, GPU from `Devices1`

Status: in-progress · Phase: 2 · Depends: — · Area: api, services (ruya-devices), shell (compositor, client, mock) · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

## Goal
The shell can show honest performance numbers for the game in front: FPS and frame time, CPU and GPU load, RAM and VRAM, CPU and GPU temperature and power, each with a state that says whether it is supported, and no cost while nobody looks.

## Read first
- ADR-033 point 4; `07-hub-requirements.md` §5.3, §8; `api/dbus/org.ruyaos.Devices1.xml` (`System`, `Thermal.ListSensors`)
- `shell/qml/compositor/` and the shell's frame timing; T-421's Outcome (drm fdinfo as a GPU measure on the Dell); `services/CLAUDE.md`

## Scope
1. Compositor: count the app surface's commits and the shell's presented frames for the app in front; expose FPS and frame time (mean and 99th percentile over the last second) to QML; zero cost while no one subscribes.
2. Contract first, `Devices1.System`: `GetPerformance` returning a map of metrics (`cpu_percent`, `ram_used`, `ram_total`, `gpu_percent`, `vram_used`, `vram_total`, `cpu_temp`, `gpu_temp`, `power_w`), each value with a state `supported | unsupported | unavailable | stale`; read from `/proc`, hwmon, the DRM driver's sysfs and fdinfo where the kernel offers them; never an estimate.
3. Shell client and mock (the mock offers each state); the shell polls only while a consumer is open, interval a setting (default 1 s, bounded 0.5-5 s).

## Out of scope
- The panel UI (T-452); per-process GPU of another profile's game where the kernel needs root (state `unsupported`, an Inbox line if it matters); FPS limiting, overlays inside games.

## Acceptance criteria
- [ ] XML, service, mock and client agree; Rust tests per metric source with fixture files, incl. a missing hwmon and a driver without VRAM numbers (test names in the Outcome)
- [ ] The compositor's FPS counter: a QML or C++ test with a test surface that commits at a known rate (test)
- [ ] No polling and no commit counting while no consumer exists (test)
- [ ] hw (lead run or the builder on the Dell): STK in front, the numbers next to `intel_gpu_top`/`top` within 10 %; `Verified: host (vm pending: vm-devices-check system)` until then
- [ ] VM (lead run): `vm-devices-check.sh system` extended: `GetPerformance` answers with sane states in QEMU
- [ ] `dev.ps1 test` ALL GREEN

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `03` (Devices1.System), `02` §1.6 (where the numbers come from).

## Hints
- Planned by lead-10 (ADR-033). The UHD 630 shows GPU busy in fdinfo per client; system-wide busy may need the i915 PMU (perf, root): use what the service (root) can read and say which in the Outcome.

## Outcome
_Filled in by the implementer._
