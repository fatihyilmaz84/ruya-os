# T-200 — System monitoring: temperatures, fans and drive health, with safe defaults and a place to see them

Status: todo · Phase: 2 · Depends: — · Area: api, services, shell, image · Size: M · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
