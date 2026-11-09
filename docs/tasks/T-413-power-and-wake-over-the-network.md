# T-413 - Power over the network: sleep, restart, shut down from a paired client; Wake-on-LAN where the hardware does it

Status: todo · Phase: 6 · Depends: T-411, T-262 · Area: services (ruya-link, Devices1 power, image: WoL), docs · Size: S · Owner: builder · Developer surface: internal

## Goal
From the phone or the web page an admin puts the console to sleep, restarts or shuts it down; a sleeping console that supports it wakes from the phone; the app says plainly when wake is not possible (powered off, no WoL support).

## Read first
- ADR-030, T-411, T-166 (suspend), T-262 (wake: what is honest), `Devices1` power calls, `image/CLAUDE.md`

## Scope
1. The power permission and the admin PIN for shutdown and restart; the console shows a toast "Restarting from <client name>" first.
2. WoL: enable it on the NIC where supported (ethtool in the image, a udev or NetworkManager setting), report `wake_supported` through the gateway; the magic packet is sent by the client.

## Acceptance criteria
- [ ] Rust: permission and PIN checks; the `wake_supported` decision from fixtures (red without each).
- [ ] VM (lead run): `vm-link-check.sh power` (sleep and restart from a scripted client); hw (lead, Dell): WoL from a phone; `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
