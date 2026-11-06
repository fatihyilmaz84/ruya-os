# T-226 — System information: what the console is made of and how it is doing

Status: todo · Phase: 2 · Depends: — · Area: api, services, shell · Size: M · Owner: builder

## Goal
A read-only **System information** screen shows what the console is made of and how it is doing, readable from the sofa, for the owner and for support (owner request, 2026-11-06). Settings -> About keeps its short summary and opens it; if `02` puts it better under System, say so in the Outcome and in the spec. It can also be saved to a USB drive as a report.

## Read first
- `docs/specs/03-services-and-apps.md` (Devices1, the T-196 storage numbers), `02-shell.md` (Settings, About, System), `04-design-system.md` §8; `shell/PATTERNS.md` (settings rows, panes), `shell/CLAUDE.md`, `services/CLAUDE.md`
- `api/dbus/org.ruyaos.Devices1.xml`; `services/ruya-devices` (the pure-core pattern, `battery.rs`/`thermal.rs`), `shell/src/network` (newest complete backend with a pane)
- T-200 (Device health rows: link to them, do not duplicate), T-196 (storage numbers), T-223 (controller batteries)

## Scope
1. **Contract first** (`Devices1.xml`): `System.GetInfo() -> a{sv}` with grouped keys; a value that cannot be read is **absent**, never zero. `SystemInfoChanged` for the live fields only.
2. **Collector** as a small pure-core crate `ruya-sysinfo`, so that the telemetry hardware report (T-224) uses the same code: this screen is the full local view, telemetry is the consented closed subset. Reads `/proc/cpuinfo`, `/proc/meminfo`, `/sys/class/drm`, `/sys/class/dmi/id`, `/sys/class/nvme`, udev/PCI data for the GPU, `uname`, `bootc status`. Blocking reads stay off the D-Bus executor. Wired into `ruya-devices`.
3. **Sections** (label/value rows, grouped):
   - **Console:** name, RuyaOS version and channel, image digest/deployment, kernel, uptime, install month, Secure Boot, firmware (UEFI/BIOS), machine vendor/model.
   - **Processor:** model, cores/threads, current and max frequency, temperature (from T-200).
   - **Memory:** total, used, available, swap/zram, with a usage bar.
   - **Graphics:** GPU vendor and model, kernel driver and version, Mesa or NVIDIA version, OpenGL/Vulkan renderer string, the effects tier in use, display connector, resolution and refresh rate (HDR/VRR rows appear once T-218/T-222 know).
   - **Storage:** per internal drive: model, type (NVMe/SSD/HDD), size, free (T-196 numbers), health only where sysfs gives it (NVMe); no `smartctl`.
   - **Network:** active connection, IP, MAC, link speed or signal (`Devices1.Network`). **Bluetooth:** adapter chipset and address. **Audio:** output devices. **Controllers:** connected, with battery (T-223).
   - Live values (RAM use, frequency, temperature) refresh every 2 s while the page is visible, never when hidden.
4. **Shell:** read-only page; rows are focusable only to scroll, B goes back; existing components and tokens; a late-reply guard; a mock with three machine profiles (Dell-like, AMD APU, NVIDIA desktop); Turkish.
5. **Export:** "Save report to USB drive" writes `RuyaOS-system-report.txt` and `.json` to a mounted drive through the Storage service, with a choice "Include network addresses" (default off: MAC, IP and SSID are removed), and a note that this is a local file and nothing is sent anywhere (telemetry is separate, T-224).

## Out of scope
- Benchmarks, live graphs or history, remote access, anything sent over the network, SMART tools, GPU load or clock monitoring.

## Acceptance criteria
- [ ] Rust tests for each parser and the grouping, with the Dell's real files as fixtures (Core i5-10500T, UHD 630, 8 GB, 465 GB SATA, Intel Bluetooth dongle) and a stripped-down machine (no GPU info, no swap): absent, not zero.
- [ ] QML tests (mock): sections and rows; live fields update in place with focus kept; the export flow; "without addresses" really removes MAC, IP and SSID from both files; controller-only operation; a late reply is dropped.
- [ ] Screenshots (English and Turkish) read against `04` §8.
- [ ] VM (lead run): `vm-devices-check.sh` compares the values with `/proc` and `/sys` inside the guest. Hardware (lead): the Dell's page matches `lscpu`, `free`, `lspci`.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `02-shell.md` (About / System information), `03-services-and-apps.md` (the interface), `Devices1.xml`, `docs/dev-setup.md`.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
