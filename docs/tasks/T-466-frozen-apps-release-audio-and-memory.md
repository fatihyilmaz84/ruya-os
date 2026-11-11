# T-466 — Frozen apps release their audio stream and, after a while, their memory

Status: todo · Phase: 2 · Depends: T-465 · Area: services (ruya-session) · Size: M · Owner: builder · Complexity: complex · Developer surface: none

## Goal
A frozen game costs no CPU or GPU, but it still keeps the audio graph busy and holds all its memory. Make a frozen app as cheap as it can be without making Resume slow or noisy.

## Found (lead-11 study on the Dell, 0.0.64, 2026-11-11)
- PipeWire keeps a frozen app's stream and the ALSA sink `running`: about 1.4 % of a core, about 1000 more context switches and 300 interrupts per second, +0.15 W at idle (0.79 -> 0.95 W). The sound itself is silent.
- With zram (T-465), `memory.reclaim` on a frozen STK race moved 261 MB of anon into 77 MB, at about 1.8 s of kernel CPU; Thaw then took 198 ms and the game resumed at once. Without swap it only drops clean cache (no gain).

## Scope
1. **Audio:** on Freeze, ruya-session detaches the app's playback streams so the sink can suspend (unlink its output links, or move them to a null sink); on Thaw it restores them to where they were. No click or burst on Resume; nothing changes for an app that is not frozen.
2. **Memory:** an app frozen for about 30 s while not under the Hub gets `memory.reclaim` on its cgroups (an amount that leaves Resume fast; measure). Never when the Hub opens (the Hub must stay instant). Only when swap exists.
3. Contract: if the shell needs to know (e.g. a "Paused" state that now also means "memory released"), extend `Session1` first (CLAUDE.md); otherwise say why not.

## Acceptance criteria
- [ ] Rust unit tests for the audio detach/restore and the reclaim timing (pure core, as in `services/CLAUDE.md`)
- [ ] VM (lead run): `vm-session-check.sh` frozen app: its stream is not linked and the sink suspends; after the delay its cgroup's anon memory drops; Thaw restores the stream; `Verified: host (vm pending: <check>)`
- [ ] Dell numbers in the Outcome later (lead): idle power with a frozen game, Resume time
- [ ] `dev.ps1 test` ALL GREEN

## Hints
- Planned by lead-11 from the frozen-game study. Releasing the compositor's buffers of a hidden frozen window was measured and rejected (0-30 MB gain, a black frame on Resume). A cap on the number of frozen games is an owner decision (STATUS).

## Outcome
_Filled in by the implementer._
