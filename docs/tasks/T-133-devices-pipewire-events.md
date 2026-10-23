# T-133 — `ruya-devices`: follow PipeWire by events instead of a 1 s poll

Status: todo · Phase: 2 · Depends: T-128 · Area: services · Size: S

## Goal
`ruya-devices` stops starting `pw-dump` every second. It reacts to PipeWire changes as they happen, so an idle console spends no CPU on audio bookkeeping, and an output change still reaches the shell within a second.

## Read first
- `docs/specs/03-services-and-apps.md` §2.3 (as built: "one poll per second")
- `services/ruya-devices/src/dbus.rs` (`watch`, `POLL`), `src/pipewire.rs` (`parse_dump`, `WpCtl`), `src/audio.rs` (`refresh`, `Changes`)
- `docs/tasks/T-128-devices-audio-service.md` Outcome

## Scope
1. Replace the poll with `pw-dump --monitor --no-colors` as one long-running child: each JSON update batch it prints triggers one `refresh()` (debounced, e.g. 100 ms, so a burst of updates gives one set of signals). Parsing of a batch must not need the whole graph: `refresh()` may still take a full snapshot through the existing `pw-dump` call when the monitor says something changed; that is fine and simple.
2. If the monitor child exits (PipeWire restarted), restart it with a back-off (1 s, doubling to 30 s) and refresh once on reconnect; log each restart once.
3. Keep the trait boundary: the event source is part of the `PipeWire` side (fake in tests emits events on demand); `audio.rs` stays pure.

## Out of scope
- Native PipeWire bindings (the crate stays pure Rust, `services/CLAUDE.md`), applying `ambient`/`media` levels to app streams (needs `ruya-session`).

## Acceptance criteria
- [ ] Unit tests: a burst of events gives one refresh (debounce); a dead event source is restarted with the back-off sequence (tests in `dbus.rs` or a new `events.rs`, time injected).
- [ ] VM (image from this commit, `smoke-test.ps1 -Audio`): `RUYA_BOOT_OK`; `vm-devices-check.sh` still passes; `wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.2` from outside shows in `MasterVolume` within 1 s (add this check to the script); over 60 s idle, no `pw-dump` process is started besides the monitor (`journalctl`/`ps` evidence in the Outcome).
- [ ] `systemctl --user -M ruya-shell@ restart pipewire` → the service recovers and the check passes again (Outcome).
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
# WSL: scripts/build.sh, make-disk.sh qcow2; then
.\scripts\smoke-test.ps1 -Audio -Keep
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §2.3 (event-driven, not polled).

## Hints
- `pw-dump --monitor` prints a JSON array per change batch; split on top-level array boundaries, not on lines.
- The executor is single-threaded `block_on`: read the child's stdout with `async-io`'s `Async<ChildStdout>` (Linux) rather than a blocking read in the async task.

## Outcome
_Filled in by the implementer: what was built, files, how it was verified, deviations, follow-ups._
