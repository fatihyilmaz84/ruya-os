# T-139 — `ruya-session`: pure core and D-Bus adapter (dev mode, not yet in the image)

Status: done · Phase: 3 · Depends: T-138 · Area: services · Size: M

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
Verified: host (core and command builder unit-tested; the D-Bus adapter compiles for Windows and Linux but was not run over a bus). Not in the image.

Built `services/ruya-session` (workspace member, `Cargo.lock` updated; no new external crate: zbus, futures-lite, async-io, async-channel were already in the tree).
- `session.rs`: pure core. `Session<S: Spawner, D: ProfileDirectory>`; `launch`, `stop`, `list`, `on_event(UnitEvent) -> Option<Notice>`, `tick(now)` (kills after `STOP_GRACE` = 5 s). Time (`Instant`, unix seconds) is passed in. 18 tests: every status string, every exit reason, double launch, stop of an unknown instance, `root`/`ruya-shell`/`ruya-p1`/`nobody` refused as `unknown-profile`, app ending by itself, kill escalation, stop while starting.
- `spawner.rs`: `Spawner` trait, `UnitEvent`, `FakeSpawner` (records calls, emits events on a channel), the id grammars and `launch_command`, the exact `systemd-run` argument list (tested for the exact list and for rejecting spaces, quotes, `;`, `--`, `$`, bad users and bad env). The real spawner that runs it is NOT written.
- `directory.rs`: `ProfileDirectory` + `ProfileSnapshot`.
- `dbus.rs` / `main.rs`: thin adapter on the session bus with `--session` only; without it the binary exits with a message. `forward` turns events into `AppStarted`/`AppExited` and ticks once a second.
- `tests/flow.rs`: Launch, AppStarted, Stop, AppExited through the core and the fake.

Decisions:
- **ProfileDirectory via `Profiles1.ListProfiles`, not by reading the store.** `profiles.toml` is root-only and holds PIN hashes, which must never leave `ruya-profiles`. The adapter fetches the ids before each Launch (system mode) into a snapshot the sync core reads; `--session` uses a fixed `p1`, `p2`, `guest`. The fetch is untested (no bus here).
- `exited` is not a listed state: an exited instance is reported once and removed.
- After `Stop`, a non-zero exit that is not a signal is still `quit` (apps answer SIGTERM with 143).
- Contract XML unchanged.

Review (lead, 2026-10-28): while `stopping`, any signal exit was reported `killed`, so an app dying of the Stop's own SIGTERM (no handler) would differ from the mock and the contract ("`killed` after the kill"). Now `killed` only once `tick` sent the kill; test `dying_of_the_stop_signal_is_quit_not_killed`, XML comment clarified.

Deviations: criterion 3 uses the allowed fallback: Windows has no session bus, so the Launch, AppStarted, Stop, AppExited sequence is proven by `tests/flow.rs` over the core with the fake, not by `busctl`. Unverified: the zbus adapter at runtime (also the shell's D-Bus client from T-138), `fetch_profile_ids`, and everything about the real spawner (does `systemd-run --machine=<user>@.host` work from the service's user, where the Wayland socket lives, how exits and `signaled` are read from the unit). Left for the VM task after T-130: unit, policy, hardening, Containerfile, `vm-session-check.sh`, the real spawner.
