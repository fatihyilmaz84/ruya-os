# T-133 — `ruya-devices`: follow PipeWire by events instead of a 1 s poll

Status: done · Phase: 2 · Depends: T-128 · Area: services · Size: S

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
Verified: vm (image `0.0.17-t134`, `smoke-test.ps1 -Audio -AudioBackend wav`, `RUYA_BOOT_OK`), 2026-10-28. Built by a Sonnet builder session; it stopped before documenting, so the lead verified it and wrote this Outcome.

- **Built:** `services/ruya-devices/src/events.rs`: `BatchSplitter` cuts the stream into top-level JSON arrays across reads (strings and escapes skipped), `Backoff` (1 s doubling to 30 s, reset once a source delivers), and `follow()`, which refreshes once per (re)connect and once per quiet burst (100 ms debounce); time and sleep are injected. `Relevance` skips batches that only update PipeWire clients: `pw-dump --monitor` is itself a client and re-reports clients about 500 times in 12 s on an idle system, which would have turned the monitor into a busier poll; unreadable text counts as a change (costs CPU, never correctness). The Linux `PwMonitor` runs `pw-dump --monitor --no-colors` as one child, read through `Async<ChildStdout>` and killed on drop. `dbus.rs` `watch` uses it instead of the 1 s `POLL`; the `--session` fakes just stay up (nothing to follow). `audio.rs` is unchanged (pure). Deviation: the event source is its own trait in `events.rs`, not part of the `PipeWire` trait; the boundary (fake source in tests, pure core) is the same.
- **Unit tests** (`events.rs`): splitter across reads and inside strings, client chatter is not a change, unreadable text is, back-off sequence and reset, a burst gives one refresh, a quiet event refreshes after the window, a dead source and a failing start back off (1, 2, 4, 8 s), delivering resets the back-off.
- **VM** (`IDLE=60 vm-devices-check.sh check`, all PASS): exactly one `pw-dump` (the monitor); `wpctl set-volume` from outside shows in `MasterVolume` after about 0.1 s; over 60 s idle no `pw-dump` or `wpctl` was started and the service used 2 ms of CPU; after `systemctl --user restart pipewire` the service recovered (`MasterVolume` followed in about 0.1 s) with one monitor again. The audio checks of T-128 still pass. `systemd-analyze --user security ruya-devices`: 3.4 OK.
- `scripts/vm-devices-check.sh` gained `events_check` (part of `check`; `events` runs it alone). Spec 03 §2.3 describes the event-driven design.
- `dev.ps1 test` ALL GREEN (164 QML passed, 13 skipped offscreen; 117 Rust).
