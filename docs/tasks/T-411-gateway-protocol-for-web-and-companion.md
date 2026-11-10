# T-411 - The `ruya-link` gateway protocol for Ruya Web and Companion: identities, pairing, permissions, events, capabilities

Status: todo · Phase: 6 · Depends: T-404 · Area: api, docs · Size: M · Owner: lead · Complexity: hard · Developer surface: internal

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** The wire protocol for the Web half only (the Companion half waits for ADR-030): pairing, sessions, events. One pairing model for a browser, which has no client key store: the browser shows a code confirmed on the TV (ADR-029); QR with mutual verification is the Companion's. The file is `docs/specs/09-ruya-web.md` (a section), no `10-ruya-link.md`.

## Goal
One written protocol that both remote clients use: console and client identities, QR pairing with mutual verification, per-device permissions, the event stream with cursors and a full-state call, capability negotiation, and the mapping from D-Bus contracts to the gateway's HTTPS/WebSocket API.

## Read first
- ADR-029, ADR-030, T-404's threat model (`09-ruya-web.md`), ADR-026 (job record), ADR-022; `api/dbus/*.xml`; the two proposals in `docs/archive/research/` (`ruya-web-proposal.md` §17-§18, `ruya-companion-proposal.md` §4-§8)

## Scope
1. Identities: a console key made on first enable (where it lives, reset on factory reset), a key per client; pairing messages, expiry, replay protection.
2. Permissions per paired client (the Companion categories plus Web's), each mapped to the allow-listed D-Bus methods of T-404; the admin PIN rule per action.
3. Events: ids, schema version, a sequence cursor, at-least-once delivery, the full-state call; capabilities and API version negotiation.
4. The D-Bus-to-API mapping and how its OpenAPI document is generated from the XML (one source of truth).

## Acceptance criteria
- [ ] `docs/specs/09-ruya-web.md` grows a "Gateway protocol" part (or a new `10-ruya-link.md`) with message examples; T-405, T-406, T-412..T-414 rewritten; `dev.ps1 docs` ALL GREEN.

## Outcome
_Filled in by the implementer._
