# T-129 — Network: Devices contract (network part), mock, and Settings → Network

Status: done · Phase: 2 · Depends: T-114 · Area: api, shell · Size: M

## Goal
Settings → Network shows the wired connection and nearby Wi-Fi networks and lets the user connect to a WPA2/3-Personal network by controller, typing the password on the on-screen keyboard. It is defined by a contract, so `ruya-devices` (NetworkManager) can implement it later, exactly as T-114 did for audio.

## Read first
- `docs/specs/03-services-and-apps.md` §2.5 (scope: Ethernet status, Wi-Fi scan/connect, WPA2/3-Personal only; captive portal and proxy are later)
- `docs/specs/02-shell.md` §2 (Settings two panes), §4.4 (on-screen keyboard)
- `api/dbus/org.ruyaos.Devices1.xml` (header rules: one interface per device class, stable status strings, re-read after `...Changed`)
- `docs/tasks/T-114-audio-contract-and-settings.md` and its Outcome: **copy that structure** (backend interface, mock with test-only invokables, D-Bus client, facade singleton, pane)
- `shell/src/audio/`, `shell/qml/AudioPane.qml`, `shell/qml/TextEntry.qml` (`mask` option for passwords)

## Scope
1. Contract: add interface `org.ruyaos.Devices1.Network` to `Devices1.xml`:
   - property `State` (`s`: `disconnected | connecting | connected | limited` — `limited` = connected without internet), `Primary` (`a{sv}`: kind `ethernet|wifi`, name/SSID, ip, signal 0–100 for Wi-Fi);
   - `ListWifi() → aa{sv}` (`id`, `ssid`, `signal`, `security` `open|wpa-psk|enterprise`, `known` b, `active` b), `Scan() → s status`;
   - `Connect(s id, s password) → s status` (`ok`, `wrong-password`, `unknown-network`, `unsupported` for enterprise, `failed`), `Forget(s id) → s status`;
   - signals `NetworksChanged`, and `PropertiesChanged` for `State`/`Primary`.
   Extend or rename freely if the shell needs it (contracts are drafts), and explain in the Outcome.
2. Shell: a `Network` singleton (`src/network/`) with mock and D-Bus backends, following `src/audio/`. The mock starts wired-connected plus four Wi-Fi networks (one open, two WPA, one enterprise); a test-only invokable unplugs the cable; the mock's password for its WPA networks is fixed and documented in the mock.
3. `NetworkPane.qml` replaces "Coming soon" for Network: the status row (kind, name, state), the Wi-Fi list (signal shown as a level, lock icon or text for secured, "Connected" on the active one), Accept on a secured network opens `TextEntry` masked; on an open network connects at once; wrong password shows the `ProfileStatus`-style message from a single status-to-text mapping; a known network offers "Forget".
4. `Network` defaults to the mock on every OS until the service exists (like `Audio` in T-114), with the same "flip in the service task" note.

## Out of scope
- The NetworkManager service side (later `ruya-devices` task), hidden SSIDs, enterprise, IP/DNS/proxy settings, captive portal, the setup wizard's network step (stays a placeholder; a follow-up can reuse the pane).

## Acceptance criteria
- [ ] Contract present with the network interface; the Outcome lists any change against the scope above (review of `Devices1.xml`).
- [ ] Connect to a WPA network with the right password by keys only, through `TextEntry`: status becomes connected, the entry is marked active (test `tst_network.qml::test_connect_wpa`).
- [ ] A wrong password shows the error and leaves focus on the list row (test `test_wrong_password`); enterprise shows "not supported" (test `test_enterprise_unsupported`).
- [ ] Unplugging the mock cable updates the status row live (test `test_cable_unplugged`); Forget removes `known` (test `test_forget`).
- [ ] Focus is asserted after every step; Back leaves the pane to the category list (tests).
- [ ] New strings translated (`dev.ps1 test` translation lint green, Turkish entries added).
- [ ] Screenshot `23-settings-network.png` shows the list with the focus ring; reviewed.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §2.5 (contract, what is built), `docs/specs/02-shell.md` §2 if the pane differs, `shell/CLAUDE.md` only if a new pattern appears.

## Hints
- A password field must never show in screenshots or logs: use `TextEntry`'s mask, and don't `console.log` it.
- Keep the Wi-Fi list a `ListView` with keys-only model data (`id`), labels as bindings (translation rule in `shell/CLAUDE.md`).
- `tryCompare` on a list's `length` polls a frozen copy (`shell/CLAUDE.md`); use `tryVerify(() => ...)`.

## Outcome
Built the `org.ruyaos.Devices1.Network` interface, `shell/src/network/` (`NetworkBackend`, `MockNetworkBackend`, `DBusNetworkBackend`, `Network` singleton) and `qml/NetworkPane.qml`, wired into `SettingsPage.qml` and `CMakeLists.txt`; `tests/tst_network.qml` (10 tests plus the screenshot `23-settings-network.png`, reviewed: focus ring on a row, status row and list readable). Turkish strings added; `dev.ps1 test` ALL GREEN (164 passed), `shots` ALL GREEN (177; one first run lost desktop focus and was re-run).

Changes against the scope: `Connect` for a secured, not-saved network with an empty password answers `invalid` (the pane never sends that; it is for the service); `Primary` for ethernet has no `signal`; `Forget` rows are one per saved network after a "Scan for networks" row (the contract's `Scan` is used). A cable wins over Wi-Fi as `Primary` in the mock (a joined Wi-Fi network is `active` but `Primary` stays wired until the cable is unplugged, as NetworkManager does). The mock's WPA password is `MockNetworkBackend::password()` ("ruya-wifi-pass"), exposed to tests as `Network.mockPassword()`.

`tst_settings.qml::test_two_pane_navigation` used Network as its "no content yet" category; it now checks that Network has a pane and uses Bluetooth for the "Coming soon" case (the premise changed, no assertion weakened).

Unverified: `DBusNetworkBackend` (compiled only; no service until T-132). The wizard's network step stays a placeholder. Follow-up: the Turkish strings are AI-written (covered by the open owner review).
