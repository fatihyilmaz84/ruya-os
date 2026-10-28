# T-132 — `ruya-devices`: the network part of `Devices1` over NetworkManager, in the VM

Status: done · Phase: 2 · Depends: T-129, T-128 · Area: services, image, shell · Size: M

## Goal
Settings → Network shows the VM's real wired connection: `ruya-devices` implements `org.ruyaos.Devices1.Network` (contract from T-129) over NetworkManager, and the Linux shell uses it over D-Bus instead of the mock.

## Read first
- `docs/specs/03-services-and-apps.md` §2.5 (network scope) and §2.3 (how the audio part is built)
- `api/dbus/org.ruyaos.Devices1.xml` (the network interface T-129 wrote; extend it if needed, `CLAUDE.md` step 4)
- `services/CLAUDE.md` (crate structure, the ADR-010 user-unit exception), `services/ruya-devices/` (**the audio part is the pattern**: pure core, side-effect trait with a fake, `dbus.rs` adapter, `--session` with the fake)
- `docs/tasks/T-128-devices-audio-service.md` Outcome (system-bus name from a user unit, `Type=simple`, the D-Bus policy, the shell's name watcher)
- `shell/src/network/` (T-129's backends and facade), `shell/src/audio/Audio.cpp` (`create`: D-Bus on Linux unless `RUYA_SERVICES=mock`)
- `scripts/vm-devices-check.sh`

## Scope
1. **Core `network.rs`:** state (`disconnected | connecting | connected | limited`), the primary connection, the Wi-Fi list (dedupe by SSID, strongest signal wins, `known`/`active` flags), the status mapping of `Connect`/`Forget` (`wrong-password`, `unknown-network`, `unsupported` for enterprise, `failed`). Every rule unit-tested on Windows.
2. **Side effects:** a `NetworkManager` trait with a fake and a Linux implementation that talks to NetworkManager's own D-Bus API with zbus (system bus, `org.freedesktop.NetworkManager`; no `nmcli` parsing: NM's API is stable and zbus is already a dependency). Signals from NM drive `NetworksChanged`/`PropertiesChanged`; no polling. Connectivity (`limited`) comes from NM's `Connectivity` property.
3. **Same service, same object:** add the interface to the existing `ruya-devices` binary and object path; the audio part keeps working.
4. **Permissions (image):** NetworkManager authorizes through polkit. Add the narrowest polkit rule that lets `ruya-shell` (the user the service runs as) scan, add/activate a Wi-Fi connection and delete one; nothing else (no system connection editing beyond that, no hostname). Record the rule in the Outcome.
5. **Shell:** `Network::create` defaults to D-Bus on Linux (like `Audio`), with a name watcher re-reading the state.
6. `scripts/vm-devices-check.sh` gains network checks: `State` is `connected`, `Primary` is the VM's ethernet with an IP, `ListWifi` answers (empty in the VM is fine), a call from another user is refused.

## Out of scope
- Real Wi-Fi in the VM (QEMU has none; Wi-Fi rules are proven by unit tests and the fake), Bluetooth, captive portal, hidden SSIDs, enterprise, the setup wizard's network step.

## Acceptance criteria
- [ ] Core rules (state mapping, dedupe, known/active, every status) have unit tests (`dev.ps1 rust` green on both targets).
- [ ] VM (image from this commit): `RUYA_BOOT_OK`; `vm-devices-check.sh` passes both the audio and the new network checks (output in the Outcome).
- [ ] VM: in the running shell, Settings → Network shows the wired connection as connected (`vm-screenshot.ps1` image in the Outcome); unplugging the link (`set_link <name> off` in the QEMU monitor on `127.0.0.1:4444`; `info network` shows the name, or give the `-nic` in `smoke-test.ps1` an `id=`) turns it to disconnected live, and `on` brings it back.
- [ ] `systemd-analyze --user security ruya-devices` still "OK" (number in the Outcome).
- [ ] `dev.ps1 test` ALL GREEN; the mock path on Windows is unchanged.

## Verification
```powershell
.\scripts\dev.ps1 test
# WSL: scripts/build.sh, make-disk.sh qcow2; then
.\scripts\smoke-test.ps1 -Keep
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §2.5 (what is built), `docs/specs/01-platform.md` (polkit rule), `docs/dev-setup.md` (the new checks, `set_link`), STATUS B-007 (network part done; Bluetooth left).

## Hints
- The NM D-Bus API: `GetDevices`, `Device.Wireless.RequestScan`/`GetAllAccessPoints`, `AddAndActivateConnection`, `Settings.Connection.Delete`; a wrong PSK shows as the device going to `failed` with reason `NO_SECRETS` / `SUPPLICANT_DISCONNECT`.
- Keep the PSK out of logs and errors (`services/CLAUDE.md` secrets rule).
- The shell already has one `QDBusServiceWatcher` pattern in `DBusAudioBackend`; copy it.

## Outcome
Verified: vm (image `0.0.17-t134`, `RUYA_BOOT_OK`), 2026-10-28. Code by a Sonnet builder (commit `7392be4`); the builder stopped before the VM run, so the lead ran it and wrote this Outcome.

- **Built** (`7392be4`): `network.rs` (pure core: state mapping incl. `limited` from NM `Connectivity`, primary connection, Wi-Fi dedupe by SSID with the strongest signal, `known`/`active`, every `Connect`/`Forget` status), `networkmanager.rs` (the `NetworkManager` trait, a fake, and the Linux side over NM's D-Bus API with zbus; NM signals, debounced, drive `NetworksChanged` and the property changes; no polling, no `nmcli`), the interface on the existing `ruya-devices` object, `Network::create` D-Bus by default on Linux, `smoke-test.ps1` names the NIC `net0`. New dependency `blocking` (already in the tree).
- **polkit rule** `image/rootfs/usr/share/polkit-1/rules.d/50-ruyaos-network.rules`: user `ruya-shell` only, actions `wifi.scan`, `network-control`, `settings.modify.system`, `settings.modify.own`; everything else keeps NM's default. polkit cannot tell connection types apart, so the service only ever touches Wi-Fi connections. Spec 01 §2.2 records it.
- **VM checks** (`vm-devices-check.sh check`, all PASS): NetworkManager active; `State` connected; `Primary` ethernet `Wired` with 10.0.2.15; `ListWifi` (empty) and `Scan` answer; unknown networks refused for `Connect` and `Forget`; a call from `nobody` refused; the audio checks still pass. `systemd-analyze --user security ruya-devices`: 3.4 OK.
- **Link test:** `set_link net0 off` in the QEMU monitor turned `State` to `disconnected` after 6 s (NM's carrier delay); `set_link net0 on` brought `connected` back within 1 s.
- **Shell over the real bus** (first runtime check of `DBusNetworkBackend`): `scripts/vm-network-probe.qml` (the shell's `Network` singleton, offscreen, as `ruya-shell`) showed `mock=false state=connected primary={"ip":"10.0.2.15","kind":"ethernet","name":"Wired"}`, then `stateChanged disconnected` with an empty primary during the unplug and `stateChanged connected` on replug.
- **Deviation:** no `vm-screenshot.ps1` image of Settings → Network. A fresh VM shows the first-boot wizard, and reaching Settings means driving five wizard steps by key injection. The probe exercises the same singleton the pane binds to (`NetworkPane.qml` reads `Network.state`/`primary`; the pane itself is covered by host tests and `shots`). A VM navigation helper is in the Inbox.
- `dev.ps1 test` ALL GREEN (164 QML passed, 13 skipped offscreen; 117 Rust). Real Wi-Fi stays unverified (QEMU has none): rules are covered by unit tests and the fake.
