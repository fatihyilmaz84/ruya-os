# T-406 - Ruya Web foundation: the service, Settings > Web management, pairing, sessions, a read-only dashboard

Status: todo · Phase: 6 · Depends: T-405 · Area: services (ruya-web), image, shell (Settings pane, pairing prompt) · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** Service name `ruya-link`. Changes the image guards that forbid Avahi (`image/build/98-guard.sh`, `50-slim.sh`). `vm-web-check.sh` also tests: session expiry, the rate limit, PIN attempts over the network, the TLS protocol floor, and that the listening ports are exactly the expected set with Web on and off (T-424's list).

## Goal
An admin turns on Web management on the TV, opens the shown address on a phone, confirms the code on the TV with the admin PIN, and sees a dashboard: version, uptime, CPU, memory, storage, network, library counts and recent events, all read from the existing services.

## Read first
- ADR-029, `09-ruya-web.md` (T-404), the T-405 Outcome; `Devices1.System` (T-226), `Devices1.Storage`, `Library1`, `Update1`

## Scope
1. `ruya-web` unit, user, bus allow-list for the dashboard reads, nftables rule, certificate, Avahi; off by default.
2. Settings > Web management: on/off (admin), address and QR, paired browsers with Revoke; the pairing prompt on the TV.
3. The page: layout and navigation (only sections whose backend exists), dashboard, error and empty states, reduced motion, keyboard navigation.

## Acceptance criteria
- [ ] Security tests (Rust and a VM script): unpaired request refused, wrong `Host`/`Origin` refused, CSRF token required, token revoke works, non-LAN source dropped, service off means no listener.
- [ ] VM (this task): `vm-web-check.sh`: enable, pair through a scripted TV confirmation, read the dashboard JSON; `RUYA_BOOT_OK`.
- [ ] Shell tests and screenshots of the Settings pane and the pairing prompt; `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
