# T-200 — System monitoring: temperatures, fans and drive health, with safe defaults and a place to see them

Status: done · Phase: 2 · Depends: — · Area: api, services, shell, image · Size: M · Owner: builder

## Goal
The console watches its own temperatures. Owner request, 2026-11-06: "when devices reach certain temperatures, what should it do; give it good defaults; also show the values somewhere to the user". Normal use shows nothing; a warm console says so, a hot one protects itself in steps the owner can predict, and a critical one never ends in a surprise hard crash without warning. The values are visible in Settings.

## Read first
- `docs/specs/01-platform.md` (services, power), `docs/specs/02-shell.md` (Settings, System), `docs/specs/04-design-system.md` §8 (tokens/components; warning colours exist, new ones need the spec update in the same commit)
- `services/ruya-devices` (pure core + trait + Linux source + thin `dbus.rs`: copy `battery.rs`/`storage.rs`), `api/dbus/org.ruyaos.Devices1.xml`
- Kernel: `/sys/class/hwmon/*/{name,temp*_input,temp*_crit,temp*_max,temp*_label,fan*_input}`, `/sys/class/thermal/thermal_zone*/{type,temp,trip_point_*}`; NVMe: `/sys/class/nvme/*/hwmon*`, drive temperature via `drivetemp` (SATA) if loaded
- Facts from the Dell (Core i5-10500T, `0.0.44`): hwmon `coretemp` (package + 6 cores, ~30-33 °C idle), `acpitz`, `pch_cometlake`, `dell_smm` (several temps, one fan at 1820 rpm, **one bogus 126 °C reading**), thermal zones with trip points, `/dev/watchdog`; no `lm_sensors`, `thermald` or `smartctl` installed (read sysfs directly: no new packages)

## Decided defaults (lead, 2026-11-06; thresholds live in one file so the owner can change them)
Hysteresis 5 °C below a level before it clears; a level needs 10 s above its threshold to count; readings outside -20..125 °C, or from a sensor that never changes while the CPU is busy, are ignored (the bogus `dell_smm` value).

| Sensor class | warm | hot | critical |
|---|---|---|---|
| CPU package (`coretemp`/`k10temp`, thermal zone `x86_pkg_temp`) | 80 °C | 90 °C | the sensor's own `crit`/last trip point minus 5 (fallback 100 °C) |
| GPU (`amdgpu`, `nouveau`, `nvidia` hwmon) | 80 °C | 90 °C | `crit` minus 5 (fallback 100 °C) |
| NVMe/SSD | 70 °C | 75 °C | 80 °C |
| SATA HDD (`drivetemp`) | 50 °C | 55 °C | 60 °C |
| Battery of a pad | not monitored here (UPower, T-161) | | |

What it does at each level:
1. **warm:** a small status mark on Settings → System and a line in the health pane; no toast, nothing changes.
2. **hot:** one toast "The console is running hot"; the shell drops to the `performance` effects quality (no blur) until it is back to normal (session override, the owner's setting is not rewritten); the toast names the sensor.
3. **critical:** a blocking notice (a modal that says what is happening), every running app is asked to stop (`Session1.Stop`), the shell shows the picker/home without effects; if the level still holds 60 s later, `systemctl poweroff`. The kernel's own hard limit still applies underneath. Fans are never controlled here (the firmware does it).
4. Fan stuck: a fan that reads 0 rpm for 30 s while the CPU is above warm counts as `hot` for the CPU class.

## Scope
1. **Contract first:** `org.ruyaos.Devices1.Thermal`: `ListSensors() -> aa{sv}` (`id`, `label` e.g. "Processor", "Graphics", "Drive", "Fan", `class`, `value` in °C or rpm, `level` "normal|warm|hot|critical", `max_seen`), `Level` property (the worst level), signals `LevelChanged(s level, s sensor_id)` and `SensorsChanged`. Status strings in the header.
2. **Service (`ruya-devices`):** pure core (classification with the table above read from `/usr/lib/ruyaos/thermal.toml`, optional override `/etc/ruyaos/thermal.toml`; hysteresis, debounce, implausible-reading filter; fake clock tests), a sysfs source (read-only; discovery by hwmon name; thermal zones as fallback), polled every 5 s on the blocking pool (every 1 s while a level above normal), only emitting on change. No new privilege; check `systemd-analyze --user security ruya-devices` before/after.
3. **Shell:** a `Thermal` facade (mock/D-Bus pair, late-reply guard) with a `level` property; the policy actions above live in the shell (effects override, toast, modal, `Session.stop` of all running apps, the poweroff request through the existing Power path); a **Settings → System "Device health" section**: one row per sensor ("Processor 33 °C", "Fan 1820 rpm", "Drive 41 °C") with a level mark, updating in place; copy in `qsTr` + Turkish; existing components only (a bar or mark may be a small spec addition).
4. **Docs:** thresholds and actions in `01-platform.md` (a "Thermal policy" section: the table above), the contract, `02-shell.md` System page, `docs/dev-setup.md` (how to fake a hot sensor in the VM).

## Out of scope
- Fan control, undervolting, power profiles (`power-profiles-daemon`), SMART health prediction, GPU load/clock graphs, logging history (a later "stats" task), notifying other users.

## Acceptance criteria
- [ ] Rust tests: levels for each class at, below and above each threshold, hysteresis (a level clears only 5 °C lower), the 10 s debounce, the implausible-reading filter (126 °C and -50 °C ignored), sysfs discovery against a fake `/sys` tree (the Dell's layout as a fixture), override file replaces a threshold.
- [ ] `tst_thermal.qml`: with the mock, `hot` switches the effects quality override and shows one toast, returning to normal restores the owner's quality, `critical` shows the modal and requests stopping the apps (spy on the mock Session) and the poweroff after 60 s (fake timer), a repeat of the same level does not toast twice; the health rows show label/value/mark and update in place with focus kept.
- [ ] Screenshots: health section normal, warm, hot; the critical modal; read against `04` §8.
- [ ] VM (lead run): `vm-devices-check.sh` thermal part: `ListSensors` has a CPU entry whose value is within 3 °C of `/sys` (QEMU may expose none: then the call returns an empty list and `Level` is `normal`); a fixture sysfs mounted over `/sys` is not possible, so the policy is proven by the host tests. Hardware (lead): the Dell shows its sensors; the owner's idle CPU matches `coretemp`.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `api/dbus/org.ruyaos.Devices1.xml`, `01-platform.md`, `02-shell.md`, `docs/dev-setup.md`.

## Hints
- Watch for sensors that appear late (hot-plugged NVMe) and for hwmon index renumbering across boots: key sensors by `name` + `label` + device path, not by `hwmonN`.
- Prefer the sensor's own `temp*_crit`/`_max` when present; the table is the fallback.
- The Dell test machine is a good fixture source: capture its `/sys` hwmon layout into `services/ruya-devices/tests/fixtures/` (names, labels, values only).

## Outcome
Verified: vm (lead run, 2026-11-06). vm-devices-check.sh thermal PASS (QEMU has no sensor: empty list, Level normal); thermal-fake: the level walk passed (normal at 40, hot after 14 s, critical after 11 s, normal again, 3 LevelChanged); its one FAIL was the script: busctl prints doubles as 4.0e+01, now parsed. Not yet run on the Dell hardware sensors. Earlier line: host (vm pending: vm-devices-check

**Built.**
- **Contract** (`api/dbus/org.ruyaos.Devices1.xml`, interface `org.ruyaos.Devices1.Thermal`): `ListSensors() -> aa{sv}` (`id`, `label`, `class` `cpu|gpu|ssd|hdd|fan`, `value` d, `level`, `max_seen` d), property `Level`, signals `LevelChanged(level, sensor_id)` and `SensorsChanged`. No status strings (nothing can fail).
- **Service** (`services/ruya-devices/src/thermal.rs`, wired in `dbus.rs` and `main.rs`): a pure `Engine` (levels per class, hysteresis, 10 s debounce, implausible-reading filter, stuck fan, stuck-sensor filter, 30 s staleness, all on a passed-in `Duration`); `Config` (built-in defaults, then `/usr/lib/ruyaos/thermal.toml`, then `/etc/ruyaos/thermal.toml`, layered value by value; a file with a mistake or an unknown key is refused whole); `SysfsSource` (hwmon by chip name, label and device, the thermal zone `x86_pkg_temp` as the processor fallback, `/proc/stat` for "the processor is busy"); `Monitor` (source + engine + clock). The poll runs on the blocking pool (5 s, 1 s while a level above normal holds) and emits only on change; `ListSensors` and `Level` read the last result under a short lock, so no handler touches sysfs. `RUYA_THERMAL_SYSFS` points the real source at another tree (how the VM check fakes a hot sensor); `--session` serves three fixed fake sensors. The unit file is unchanged (reading sysfs needs nothing new), so there is no before/after for `systemd-analyze --user security`; `vm-devices-check.sh security` stays the check. `image/rootfs/usr/lib/ruyaos/thermal.toml` ships the defaults (a test asserts it equals the built-in ones).
- **Shell:** `Thermal` facade (`src/thermal/`, mock and D-Bus backends, `RequestSequence` guard including a failed request), `ThermalText` (words by class, singleton), `ThermalPolicy` and `ThermalNotice` (in `Shell.qml`, z 26), `DeviceSettings.thermalLimited` and `storedEffectsQuality`, Settings -> System "Device health" (one row per sensor with a mark and a word, a line for the worst level, a "no sensors" text) and a mark on the System category. Turkish and English strings are in the `.ts` files.
- **Docs:** `01-platform.md` §2.4 (the policy and the table), `02-shell.md` §1.2 and §3.3, `04-design-system.md` (two component rows), `docs/dev-setup.md` ("Fake a hot sensor", the VM check).

**Tests.** Rust, `thermal::tests` (53, one is unix-only): each class at, below and above each threshold, a fixed and a sensor-derived critical, hysteresis (clears at threshold minus 5; a wobble does not flap), the 10 s debounce (9 s no, 10 s yes, a dip restarts it, each level counts on its own), 126, -50 and NaN ignored (also a spike on a live sensor), a stuck sensor, the stuck fan (needs a warm processor and 30 s; a fan that never turned is no fault), the configuration (an override replaces one value, integers and decimals, twelve kinds of mistake refused, the shipped file equals the defaults, layering), `/proc/stat`, discovery against the Dell fixture (coretemp package + 6 cores, acpitz, pch_cometlake, `dell_smm` with the bogus 126 degree temperature and one fan at 1820 rpm, two thermal zones; **built in the test from the task's description, not captured from the machine, which was offline**; it is a function that writes the tree into a temp dir, not files under `tests/fixtures/`), the zone fallback, a SATA SSD behind `drivetemp`, duplicate ids, the id following the device link, the monitor. `tst_thermal.qml` (15 tests and 5 screenshot functions): warm changes nothing; hot switches the quality to `performance` with one toast naming the sensor, the owner's `high` is back at normal, a repeat, another sensor at the same level, and a warm/hot wobble inside one incident toast nothing more, a new incident toasts again; a quality chosen while limited survives; critical shows the notice, asks the mock Session to stop the app (`stopFinished` spy, the running list empties), and the power-off request comes only after `poweroffMs` (700 ms in the test; `Power.actionCount` 0 before, 1 with `poweroff` after); an app started while critical is stopped too; cooling below critical closes the notice and cancels the power-off; OK and Back dismiss the notice with focus returning to Home while the countdown goes on; the seconds count down; the health rows (label, value, order, mark, accessible text), in-place updates (the same row object, focus kept), a vanishing focused row, numbering of several drives, "no sensors", Turkish, the category mark, and a late reply.

**Revert tests** (each undone, seen to fail, restored). Rust: the hysteresis comparison (3 tests fail), the debounce (6), the plausibility filter (3), the `warm` override (5), the stuck fan without the warm-processor condition (3), listing the cores as processors (4). QML (all four undone together, each seen to fail its own test): `deliver()` ignoring the sequence guard (`test_a_late_list_is_dropped`), the power-off timer not stopped when the level falls (`test_critical_that_cools_down_does_not_power_off`), the hot toast without the once-per-incident flag (`test_hot_drops_the_effects_and_says_so_once`), the rows rebuilt instead of updated in place (`test_rows_update_in_place_and_focus_stays`).

**Decisions where the task was open** (the lead may disagree):
- *Which sensors are listed:* only the classes in the table (processor package, graphics, drives, fans). Cores, `acpitz`, `pch_*` and the other `dell_smm` temperatures have no threshold and are not listed, so the bogus 126 degree reading never shows (the filter still guards a listed sensor).
- *The stuck fan:* the fan's own row becomes `hot` (so the user sees which part is wrong and the toast names "Fan"), on the condition "seen spinning, 0 rpm for 30 s, processor warm or worse". "Counts as hot for the CPU class" is read as: the console's level is hot.
- *The stuck-sensor filter* ("never changes while the CPU is busy"): a temperature below its warm threshold with no change for 5 minutes while the processor was busy the whole time is ignored; a reading at or above warm is believed, because a processor held at its limit under load really stands still.
- *Hot lasts until normal:* the effects limit and "no second toast" stay through warm and end only when the level is normal, as the task says.
- *The level in the shell* is derived from the list (`Thermal.level` and `levelSensor`), so one reply carries both; `LevelChanged` and `SensorsChanged` both mean "read the list again". The service's `Level` property is for other clients (`vm-devices-check.sh`).
- *Display & motion* keeps showing the owner's quality (`storedEffectsQuality`) while the console is limited, so the owner never sees a setting they did not make.
- The power-off goes through `Power.powerOff()` (logind), "the existing Power path".

**Not verified here.** Everything on Linux: the real sysfs read, the D-Bus method, property and signals on the system bus (the XML, the zbus adapter and the QtDBus client follow each other but were never run together), the unit under its hardening, `RUYA_THERMAL_SYSFS` through the user manager, and the shell commands in `vm-devices-check.sh` (syntax checked only). Lead VM run: `scripts/vm-devices-check.sh check` (thermal part) and `thermal-fake`. Hardware (lead): the Dell shows its sensors and the idle processor matches `coretemp`. Not tested anywhere: the real critical path (apps stopped through `ruya-session`, the power-off through logind).

**Files.** `api/dbus/org.ruyaos.Devices1.xml`; `services/ruya-devices/src/{thermal,dbus,main,lib}.rs`; `image/rootfs/usr/lib/ruyaos/thermal.toml`; `scripts/vm-devices-check.sh`; `shell/src/thermal/*`, `shell/src/settings/DeviceSettings.{h,cpp}`, `shell/qml/{ThermalText,ThermalNotice,ThermalPolicy,SystemPane,SettingsPage,DisplayPane,Shell}.qml`, `shell/CMakeLists.txt`, `shell/i18n/*.ts`, `shell/tests/tst_thermal.qml`; the docs above.

**Review (lead, 2026-11-06).** Round 1 asked for two fixes, made by the lead in a `review:` commit: `thermal_cpu_value` in `vm-devices-check.sh` read the last sensor's value (the `a{sv}` dictionaries share one JSON array; now split per dictionary, checked on a two-sensor sample); the spec said the critical level "shows Home", but `ThermalPolicy` never navigates, so 01 §2 now says the notice opens over the current page. Follow-ups are in the Inbox: the hint bar under `ThermalNotice`, a test that Display shows the owner's quality while limited, the fixture captured from the Dell.
