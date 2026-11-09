# T-405 - Spike: Ruya Web stack, TLS certificate, TV pairing, LAN-only enforcement, design tokens as CSS

Status: todo · Phase: 6 · Depends: T-404 · Area: services (new ruya-web), image, shell (tokens export), docs · Size: M · Owner: lead · Complexity: hard · Developer surface: internal

## Goal
A prototype on the Dell: `ruya-web` serves one page over HTTPS on the LAN only, a phone pairs with a code confirmed on the TV, and the page uses the console's colours and type from `Theme.qml`.

## Read first
- ADR-029, T-404's spec (`09-ruya-web.md`), `services/CLAUDE.md` (service pattern, hardening), `image/CLAUDE.md`, `docs/specs/04-design-system.md` §2-§3 (tokens)

## Scope
1. Backend: an HTTP server in Rust (axum or hyper; justify), static files from the image, a session store, the zbus client with only the allow-listed calls; systemd hardening equal to the other services.
2. Front end: the framework (React + TypeScript + Vite as proposed, or something smaller) built in WSL (never installed on Windows), bundle size, how `dev.ps1` builds and tests it.
3. TLS: a self-signed certificate made on first enable, its fingerprint on the TV, renewal, behaviour in Chrome/Safari/Firefox on a phone and a laptop.
4. LAN-only: bind addresses, an nftables rule, the request checks (source, `Host`, `Origin`), DNS-rebinding test; Avahi `ruya.local`.
5. `Theme.qml` tokens exported to a CSS file at build time (one source).

## Acceptance criteria
- [ ] Spike report in this Outcome with measurements; ADR-029 and T-406..T-410 rewritten; `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
