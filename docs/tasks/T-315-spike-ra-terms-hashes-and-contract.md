# T-315 — Spike: RetroAchievements terms, hash rules, supported systems and the service contract

Status: todo · Phase: 5 · Depends: T-314, T-302, T-303 · Area: api, docs · Size: M · Owner: lead

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** The claim of 2026-11-08 was stale (no work, empty Outcome) and is reset. The spike also draws how an unlock reported through the hub is checked against the set cached in the RA service (T-317/T-318).

## Goal
Replace the unverified facts in T-314 with checked ones and fix the contract the children build on: what the site allows (terms, rate limits, API key rules, logo use), how a ROM is hashed per console, which of our systems (T-303 list) have sets, how credentials are exchanged, and the D-Bus contract for the RA service and the hub additions. Written, not coded, apart from XML and a hash prototype.

## Read first
- T-314, T-246, T-302/T-303/T-304/T-306, 02 settings and profile pages, `api/dbus/*.xml` (style), `docs/developers/permissions-and-sandbox.md`

## Scope
1. **Read** the public RetroAchievements documentation, API terms and the `rcheevos` repository (licence, hashing rules per console, the client-side integration guide). Record in a new `docs/research/retro-achievements.md`: terms that bind us (rate limits, user agent, attribution, account and key rules), the token login flow, hash rules per system, how multi-disc and headered/headerless ROMs are handled, the list of systems with sets, licence of `rcheevos`.
2. **Hash prototype:** a Rust function that gives the RA hash for two or three systems from fixture files we build ourselves (never real ROMs); the hub's `Identify` (T-304) gets an `ra_hash` field only if the cost is small, else a separate call.
3. **Contract** `org.ruyaos.RetroAchievements1` (system service, root as the only token reader; shell and root on the bus): `Link(profile, username, password)` (password never stored, returns status), `LinkToken(profile, username, token)`, `Unlink`, `GetAccount(profile)` (name, linked, no token), `GetProgress(profile, game)`, `ListGames(profile)`, `Refresh`, signals `Updated`, `Unlocked`; statuses `ok|bad-credentials|offline|rate-limited|unsupported|failed`. Plus the `GameData1` additions (credentials hand-over, `Report` event). Write the XML, a mock stub list for the shell, and update 03.
4. **Findings** that change the epic go back into T-314/ADR-021 and the Inbox; anything owner-level goes into Open owner decisions, not decided here.

## Out of scope
- The service, UI, toast (children); contacting the site for permission (the owner or a human does that).

## Acceptance criteria
- [ ] `docs/research/retro-achievements.md` exists with sources (URLs and the date read) and says what was **not** verified.
- [ ] XML validates (`dev.ps1 docs`), the hash prototype has unit tests with generated fixtures; no ROM or set data is committed.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer. First line: `Verified: host`._
