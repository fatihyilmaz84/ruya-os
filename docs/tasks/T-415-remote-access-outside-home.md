# T-415 - Companion outside the home: the player's own VPN first, a Ruya relay only if the owner decides to run one

Status: blocked (owner 2026-11-10: Companion is for later, not built now) · Phase: 6 · Depends: T-414 · Area: docs, services (ruya-link), image · Size: S · Owner: lead · Developer surface: internal

## Goal
A player away from home can reach their console from the Companion app without exposing anything to the internet.

## Read first
- ADR-030 (remote access), ADR-029 (Ruya Web never remote), T-411's protocol

## Scope (if VPN-only is chosen, as recommended)
1. A user guide: WireGuard or Tailscale on the console (packages in the image or as a Flatpak? decide), the app connects to the VPN address like a LAN one; what changes in the gateway's source check (the VPN interface is allowed for Companion, never for Web).
2. Tests that Web still refuses requests from the VPN interface.

## Acceptance criteria
- [ ] The owner's answer recorded in ADR-030; the guide and the source-check change; `vm-link-check.sh vpn`; `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
