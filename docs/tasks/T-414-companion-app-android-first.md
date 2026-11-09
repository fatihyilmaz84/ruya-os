# T-414 - Ruya Companion app v1 (Flutter, Android first): discovery, pairing, Home, Library, Downloads, System, Remote

Status: blocked (owner 2026-11-10: Companion is for later, not built now) · Phase: 6 · Depends: T-411, T-406, T-412, T-413 · Area: new `companion/` (Flutter), docs · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

## Goal
A side-loaded Android app finds the console on the LAN, pairs with the QR code on the TV, and shows the console's state: what is running, recent games with a Launch button, downloads with their actions, system information, power, and the remote. Publishing in the stores is the owner's decision (ADR-030 question 1).

## Read first
- ADR-030, T-411's protocol, `docs/specs/04-design-system.md` (tokens; exported as in T-405), the proposal `docs/archive/research/ruya-companion-proposal.md` §2-§3, §10

## Scope
1. A Flutter project in `companion/` built in WSL (Android SDK there, never installed on Windows), its own `CLAUDE.md`, a `dev.ps1` step that builds and tests it.
2. Discovery (mDNS, then a manual address), QR pairing, secure key storage (Android Keystore), several consoles.
3. The five sections at their v1 depth, every screen only for capabilities the console reports; reconnect with the event cursor and the full-state call.

## Acceptance criteria
- [ ] Flutter unit and widget tests (pairing flow, capability-driven navigation, reconnect); a protocol test against a scripted `ruya-link`.
- [ ] VM (lead run): the app against the VM's gateway; hw (lead): a phone with the Dell. iOS: unverified (no Mac).
- [ ] `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
