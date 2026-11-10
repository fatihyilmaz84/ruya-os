# T-404 - Ruya Web: threat model, the bus allow-list per service, pairing and session design

Status: todo · Phase: 6 · Depends: — · Area: docs, api (bus policies) · Size: M · Owner: lead · Complexity: hard · Developer surface: internal

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** Output: the threat model, the allow-list and the test list only (the wire protocol, pairing messages and sessions are T-411's). One name: the service, unit, user and bus-policy subject are `ruya-link` (root `CLAUDE.md`); "ruya-web" is the page. Must state explicitly: how an admin action in the browser proves the PIN although `Profiles1` and PINs stay shell-only (which single verify method is on the allow-list, PIN in transit and in memory, never in logs, attempts counted with the TV's lockout but without letting the network lock the admin out); the attackers "remote input" (T-412) and "another device on the LAN"; where the console key and TLS key live (runtime state under `/var`, never in the image), backup and rotation; how `require_admin_to_install` (T-211) applies to web installs. The reviewable bar: every allow-listed method is listed with the id of its refusal test.

## Goal
For both remote clients of the one gateway (`ruya-link`: Ruya Web and the Companion app, ADR-029/ADR-030), before any code: a written threat model and the exact list of methods `ruya-web` may call on each service, so the invariant change the owner approves is as small as possible and testable.

## Read first
- ADR-029, ADR-022 (never-public list), ADR-023, the root `CLAUDE.md` security invariants; every `api/dbus/*.xml` and `image/rootfs/usr/share/dbus-1/system.d/*` policy; the proposal `docs/archive/research/ruya-web-proposal.md` §3, §16, §22.3

## Scope
1. Threat model: attacker on the LAN (no pairing), a paired but stolen browser token, a malicious page in the same browser (CSRF, DNS rebinding), a compromised `ruya-web` process (what can it reach: the allow-list is the blast radius), a malicious upload (archive, path, size); a lost phone with a paired Companion and the remote-input permission; a VPN path (T-415) that must never reach Web.
2. Per service, the allowed methods by phase, with the admin-PIN rule per method; what stays shell-only forever (profiles, PINs, updates/rollback in v1).
3. Pairing and sessions: code on the TV, admin PIN, token storage and revocation, expiry, rate limits, audit log of admin actions.
4. The security test list every later task must carry.

## Acceptance criteria
- [ ] A spec `docs/specs/09-ruya-web.md` with the threat model, the allow-list table and the tests; ADR-029 updated with the owner's answers; T-405..T-410 rewritten.
- [ ] `dev.ps1 docs` ALL GREEN.

## Outcome
_Filled in by the implementer._
