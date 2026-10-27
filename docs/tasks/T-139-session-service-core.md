# T-139 — `ruya-session`: pure core and D-Bus adapter (dev mode, not yet in the image)

Status: todo · Phase: 3 · Depends: T-138 · Area: services · Size: M

## Goal
A new crate `services/ruya-session` implements `org.ruyaos.Session1` (T-138) with all rules in a pure, unit-tested core and the OS calls behind a trait, so the later VM task only adds the real spawner, the unit and the policy. It runs on this host with `--session` and a fake spawner.

## Read first
- `api/dbus/org.ruyaos.Session1.xml` (T-138; extend it if the service needs more, `CLAUDE.md` step 4)
- `services/CLAUDE.md` (**crate structure and rules**) and `services/ruya-profiles/` (the reference: pure core, `Accounts` trait with a no-op and a Linux impl, thin `dbus.rs`, `--session`)
- `services/ruya-devices/src/` (`--session` with fakes; a second example of the pattern)
- ADR-004 and ADR-005 in `docs/specs/00-overview.md`; `docs/specs/03-services-and-apps.md` §4.1
- `CLAUDE.md` security invariants (apps never run as root or as `ruya-shell`)

## Scope
1. **Core (`session.rs`):** the instance registry and state machine (`starting → running → stopping → exited`), one instance per (profile, app id), every status of the contract, the exit reasons, and a time source passed in. Launch is refused for non-profile accounts: the core asks a `ProfileDirectory` trait ("is this a RuyaOS profile, and which Unix user?"), with a fake in tests and a Linux implementation that reads the `ruya-profiles` store (read-only) or calls `Profiles1` (choose, and say why in the Outcome).
2. **Spawner trait:** `Spawner::start(user, app_id, env) -> unit_name`, `stop(unit)`, and a stream of unit-exit events. A **fake** for tests and `--session`; the real one (`systemd-run --user --machine=<user>@ … flatpak run <id>` with `WAYLAND_DISPLAY`) is **designed and written as a command builder with tests of the argument list only** (a pure function), not executed here.
3. **`dbus.rs`:** thin zbus 5 adapter on the session bus in `--session` mode (type conversion, signals; no rules). `main.rs` as in `ruya-profiles`.
4. **Not in the image yet:** no unit, no policy, no Containerfile change. Say so in the crate's `README` header comment and the Outcome; the VM task follows T-130.

## Out of scope
- The systemd unit, D-Bus policy, hardening and the VM check (next task), per-profile Wayland sockets (T-130 follow-up), app windows, PipeWire for apps, restart-on-crash.

## Acceptance criteria
- [ ] Unit tests for every contract status and every exit reason, double launch, stop of an unknown instance, refusing `root` and `ruya-shell`, and an app that exits by itself (fake emits an exit event). `dev.ps1 rust` green on both targets (clippy `-D warnings`).
- [ ] The command builder test asserts the exact argument list and that no argument comes from unescaped user text (an app id with spaces, quotes or `;` is rejected as `invalid` before it reaches the builder).
- [ ] In `--session` mode with the fake: `busctl --user` (or a Rust integration test over the session bus) shows `Launch` then `AppStarted` then `Stop` then `AppExited`; output in the Outcome. If no session bus is available on Windows, the integration test over the core with the fake is enough: say which.
- [ ] No `unwrap()`/`expect()` on D-Bus-reachable paths; `Cargo.lock` updated and builds `--locked`.
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 rust
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §4.1 (what is built: core only), `services/CLAUDE.md` only if the crate list is mentioned, `docs/specs/01-platform.md` §6.3 if it lists crates.

## Hints
- Validate the app id against the Flatpak id grammar (reverse-DNS, `[A-Za-z0-9_.-]`, at least two dots, length cap) in the core; reuse nothing from the shell.
- Keep the event stream a channel the adapter drains, so the core stays synchronous and testable.

## Outcome
_Filled in by the implementer. Start with a `Verified:` line._
