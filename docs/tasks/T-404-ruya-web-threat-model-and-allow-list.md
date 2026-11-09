# T-404 - Ruya Web: threat model, the bus allow-list per service, pairing and session design

Status: blocked (owner decision: ADR-029 changes the invariant "D-Bus policies stay restrictive: the shell and root only") · Phase: 6 · Depends: — · Area: docs, api (bus policies) · Size: M · Owner: lead · Complexity: hard · Developer surface: internal

## Goal
Before any web code: a written threat model and the exact list of methods `ruya-web` may call on each service, so the invariant change the owner approves is as small as possible and testable.

## Read first
- ADR-029, ADR-022 (never-public list), ADR-023, the root `CLAUDE.md` security invariants; every `api/dbus/*.xml` and `image/rootfs/usr/share/dbus-1/system.d/*` policy; the proposal `docs/archive/research/ruya-web-proposal.md` §3, §16, §22.3

## Scope
1. Threat model: attacker on the LAN (no pairing), a paired but stolen browser token, a malicious page in the same browser (CSRF, DNS rebinding), a compromised `ruya-web` process (what can it reach: the allow-list is the blast radius), a malicious upload (archive, path, size).
2. Per service, the allowed methods by phase, with the admin-PIN rule per method; what stays shell-only forever (profiles, PINs, updates/rollback in v1).
3. Pairing and sessions: code on the TV, admin PIN, token storage and revocation, expiry, rate limits, audit log of admin actions.
4. The security test list every later task must carry.

## Acceptance criteria
- [ ] A spec `docs/specs/09-ruya-web.md` with the threat model, the allow-list table and the tests; ADR-029 updated with the owner's answers; T-405..T-410 rewritten.
- [ ] `dev.ps1 docs` ALL GREEN.

## Outcome
_Filled in by the implementer._
