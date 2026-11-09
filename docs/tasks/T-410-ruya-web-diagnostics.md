# T-410 - Ruya Web: logs and a diagnostic report, redacted

Status: todo · Phase: 6 · Depends: T-406, T-225 · Area: services (a diagnostics reader, ruya-web), web front end · Size: S · Owner: builder · Developer surface: internal

## Goal
An admin can read recent errors of the console's services and download a diagnostic report to attach to a bug, with secrets, tokens, addresses and profile names removed.

## Read first
- ADR-029 (logs are the most sensitive part: last in the order), T-225 (crash reporting: the same redaction), `09-ruya-web.md`

## Scope
1. A small reader (root side, fixed units only, no free-form journal queries) that returns redacted entries by time, severity and service.
2. The page and the report download.

## Acceptance criteria
- [ ] Rust: the redaction rules on fixtures with tokens, Wi-Fi keys, IPs, profile names (red without each); only the fixed units can be read.
- [ ] VM (lead run): `vm-web-check.sh diagnostics`; `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
