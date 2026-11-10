# T-433 - Dependency upgrades: quick-xml, zbus 6, actions/checkout v5, a checked cargo-deny download

Status: todo · Phase: 2 · Depends: — · Area: services, ci · Size: M · Owner: builder · Complexity: complex · Developer surface: none

## Goal
The five advisory ignores in `services/deny.toml` (T-423) are gone because the crates behind them are upgraded, and CI uses supported actions and checks what it downloads.

## Read first
- `services/deny.toml` (the dated ignores and their reasons), `services/Cargo.toml` files, `services/CLAUDE.md`, `.github/workflows/ci.yml`, `.github/workflows/supply-chain.yml`
- The zbus 6 migration notes (zvariant, zbus_names, zvariant_derive merged into zbus)

## Scope
1. ruya-store: quick-xml 0.37 to >= 0.41; drop the RUSTSEC-2026-0194/0195 ignores.
2. All services to zbus 6; drop the RUSTSEC-2026-0370..0372 ignores. No contract change: the XML in `api/dbus/` and the bus names stay; the services' D-Bus tests stay green unchanged.
3. Every workflow from `actions/checkout@v4` to `@v5` (Node.js 20 is deprecated on the runners), and `upload-artifact` to its current major.
4. `supply-chain.yml` checks the cargo-deny tarball against its published `.sha256` before running it.

## Out of scope
- Other dependency upgrades (root `CLAUDE.md`: no unrelated upgrades).

## Acceptance criteria
- [ ] `cargo deny check` passes with no `ignore` entries for these five advisories.
- [ ] `dev.ps1 test` ALL GREEN (Rust tests unchanged, none weakened).
- [ ] VM (lead run): the `vm-queue.ps1` default checks PASS on the next image (zbus 6 over the real bus); Outcome `Verified: host (vm pending: vm-queue default)`.
- [ ] The next push's `ci` and `supply-chain` runs are green with no Node.js 20 annotation (the lead watches it with `gh`).

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/dev-setup.md` "Local checks and CI" if a step changed.

## Hints
- From the STATUS Inbox (T-423 and its review, lead-9), planned by lead-9 on 2026-11-10. If zbus 6 turns out too large for one round, do items 1, 3, 4 and stop at a clean commit, saying so.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
