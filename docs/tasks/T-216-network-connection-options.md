# T-216 — Network connection options: IP (DHCP or manual), DNS, device name, metered, proxy, test

Status: todo · Phase: 2 · Depends: — · Area: api, services, shell, image · Size: M · Owner: lead

## Goal
Settings -> Network offers what a console or TV box usually offers beyond "connect": per connection, IP settings (automatic DHCP or manual), DNS (automatic or manual servers), a proxy, a metered-connection switch, the connection's details, a connection test, and the console's name on the network. Owner request, 2026-11-06. Today `Devices1.Network` has `State`, `Primary`, `ListWifi`, `Scan`, `Connect(id, password)` and `Forget(id)`; the pane shows the status, the Wi-Fi list and a Forget row.

## What "usual" means (the set to build)
Console and TV network settings (PlayStation, Xbox, Switch, Apple TV, Android TV) converge on this; build it per connection (Ethernet, or a saved Wi-Fi network):
1. **IP address:** Automatic (DHCP) or Manual: address, subnet (prefix length or mask shown as a prefix), gateway. IPv6: Automatic or Off (default Automatic).
2. **DNS:** Automatic (from DHCP) or Manual: primary and secondary server (a third optional); validated; plus **DNS over TLS** as Off / Opportunistic (default Off; systemd-resolved supports it).
3. **Proxy:** None (default) or Manual (host, port); no authentication UI in v1.
4. **Metered connection:** Automatic / Yes / No. A metered connection is not used for automatic update downloads and large Store downloads ask first (`ruya-update` and the Store read the flag: see Scope 5).
5. **Wi-Fi extras:** connect to a **hidden network** (enter the name), auto-connect on/off per network, **MAC address randomisation** for Wi-Fi (default Off for a console that may be filtered by MAC on a router; a switch per network; "Fixed" / "Random").
6. **Details (read-only):** IP address, subnet, gateway, DNS servers, MAC address, link speed and, for Wi-Fi, SSID, signal strength (as bars and dBm), band/channel, security type.
7. **Test connection:** runs in order (link up, DHCP address, gateway reachable, DNS resolves, internet reachable, optionally "NAT type" later) and shows which step failed in plain words.
8. **Console name** (hostname, shown to routers and used as the Bluetooth name): validated (`a-z0-9-`, 1 to 32, not starting or ending with `-`), default `ruyaos` (today the Dell's name became its IPv6-derived address from DHCP, and BlueZ used that as the Bluetooth device name: Inbox, first Dell run).
9. **Safety:** a change that can cut the console off (manual IP, DNS, proxy) is applied, then the shell asks "Keep these settings?" for 20 s and reverts to the previous settings if nobody confirms (same pattern as T-198's display change); a failed connection falls back to automatic settings on the next boot only if the owner asks (no silent rewrite).

Out of the first version (Inbox): Wake-on-LAN, Wi-Fi 802.1X/enterprise (out of MVP, spec), VPN, static routes, per-app firewall, Wi-Fi hotspot, MTU (offer only under an "Advanced" row if cheap), port forwarding hints, NAT type.

## Read first
- `docs/specs/03-services-and-apps.md` §2.5 Network and the "As built (T-129, T-132, T-180)" paragraphs, `api/dbus/org.ruyaos.Devices1.xml` (Network), `services/ruya-devices/src/network.rs` (+ the NetworkManager client), `shell/qml/NetworkPane.qml`, `scripts/vm-devices-check.sh` network part, `image/rootfs/usr/share/polkit-1/rules.d/50-ruyaos-network.rules` (T-180: `ruya-devices` runs as `ruya-shell` and only specific NetworkManager polkit actions are allowed, the others refused: this task needs the settings-modify actions and must add them narrowly)
- NetworkManager D-Bus: `org.freedesktop.NetworkManager.Settings` and `Settings.Connection.Update`/`GetSettings` (ipv4, ipv6, 802-11-wireless, connection `metered`, `autoconnect`, `ipv4.dns`, `ipv4.dns-priority`, `ipv4.ignore-auto-dns`), `Device`, `ActiveConnection`, `IP4Config`; `systemd-resolved` (`DNSOverTLS`) and how NetworkManager hands DNS to it; polkit actions `org.freedesktop.NetworkManager.settings.modify.system` and `.own`, `network-control`
- `services/CLAUDE.md`, T-196's `sysusage.rs` and T-192 (blocking calls off the D-Bus executor); `ruya-update` schedule (the metered flag)

## Scope
1. **Contract first (`Devices1.Network`):** `GetConnections() -> aa{sv}` (id, name, kind, active, autoconnect, metered, and the current effective summary), `GetConnectionConfig(id) -> a{sv}` and `SetConnectionConfig(id, config a{sv}) -> status` (keys: `ipv4.method` `auto|manual`, `ipv4.address`, `ipv4.prefix`, `ipv4.gateway`, `ipv6.method` `auto|off`, `dns.method` `auto|manual`, `dns.servers` as, `dns.over_tls` `off|opportunistic`, `proxy.method` `none|manual`, `proxy.host`, `proxy.port`, `metered` `auto|yes|no`, `autoconnect`, `wifi.mac_randomization` `fixed|random`), `GetConnectionDetails(id) -> a{sv}`, `ConnectHidden(ssid, password)`, `TestConnection() -> job` with progress/finished signals (`TestStep(step, ok, detail)`), `GetHostname`/`SetHostname(name) -> status`, `RevertPending`/`ConfirmPending` for the keep-or-revert window. New statuses (`invalid-address`, `invalid-prefix`, `gateway-not-in-subnet`, `invalid-dns`, `invalid-hostname`, `needs-admin`, `unknown-connection`, `failed`); validation lives in the pure core.
2. **Service (`ruya-devices`):** a pure core for validation and for the keep-or-revert state machine (fake clock), a NetworkManager client that reads/writes the connection settings (never touching secrets it does not need; the Wi-Fi password stays in NM's keyfile as today), apply and re-activate, hostname through `org.freedesktop.hostname1` (`SetStaticHostname`; also what BlueZ and the router see). **Admin only** for every write (as the other admin calls); reads open to the shell. Narrow polkit additions in `50-ruyaos-network.rules` for exactly the settings-modify and hostname actions the service needs, for `ruya-shell` only; keep the "other actions refused" test and extend `pkcheck` checks in `vm-devices-check.sh`.
3. **Metered:** `ruya-update` does not auto-download on a metered primary connection (Check still works; Download asks), and `Store` shows a confirmation for downloads above 100 MB on metered connections; both read `Primary.metered`.
4. **Shell:** Settings -> Network gets, for the connected Ethernet and each saved Wi-Fi network, an "Advanced" page with the rows above (IP settings, DNS, Proxy, Metered, MAC randomisation, Auto-connect, Details, Test connection) and a "Console name" row; the on-screen keyboard for text, a numeric entry component for addresses (octet by octet, controller-first), the "Keep these settings?" countdown dialog; "Connect to a hidden network..."; results of the connection test as a checklist (one row per step with a mark and a plain sentence); copy per `04` §6; Turkish; mocks with scripted failures.
5. **VM check** in `vm-devices-check.sh` (network part): `SetConnectionConfig` to a manual IP/DNS on the VM's Ethernet and back (the VM has user-mode NAT: use `10.0.2.x` values), the details match `nmcli`/`ip`, DNS servers appear in `resolvectl`, the revert after no confirmation, invalid input is refused with the right status, the hostname change shows in `hostnamectl` and as the Bluetooth alias, a non-admin or other user is refused, `pkcheck` as the service's process: new actions allowed, the others still refused.

## Acceptance criteria
- [ ] Rust tests: address/prefix/gateway/DNS/hostname validation (valid, malformed, gateway outside the subnet, broadcast/network addresses, duplicate DNS, too many), the keep-or-revert machine (confirm, timeout, a second change during a pending one), mapping to and from NetworkManager settings dictionaries (fixtures), `needs-admin`, the test-connection step order with fakes (each step failing), no secret in any reply or log.
- [ ] `tst_network*.qml` (mock): every row writes its setting and updates in place; invalid input shows the status message and keeps focus; the numeric address entry works with the controller keys; the keep-or-revert dialog counts down and reverts; the connection test shows each step; the hostname row validates; admin-only rows are hidden or disabled for non-admins; late replies guarded; everything operable without a keyboard with focus asserted.
- [ ] Screenshots of the Advanced page, the manual IP entry, the keep-or-revert dialog, the test result (pass and a failed DNS step), English and Turkish, read against `04` §8.
- [ ] VM (this task or lead run): `vm-devices-check.sh` network part passes as described; `systemd-analyze --user security ruya-devices` not worse; `Verified: ...` states what ran where. Hardware (lead, the Dell): a manual IP and DNS round trip, the hostname and Bluetooth name.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `03` §2.5 and the Network "As built" paragraphs, the XML, `02-shell.md` (Settings -> Network), `01-platform.md` (polkit rules), `docs/dev-setup.md`, `docs/developers/` if a developer-visible networking fact changes.

## Hints
- NetworkManager keeps the last working profile: a bad manual IP is recoverable by re-activating the stored settings; the keep-or-revert dialog should snapshot `GetSettings` before the change, not guess defaults.
- `ipv4.dns-priority` and `ignore-auto-dns` are how "manual DNS" works when DHCP also gives servers.
- Test the keep-or-revert path where the shell survives a link change (the D-Bus path is local, so the dialog stays up).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
