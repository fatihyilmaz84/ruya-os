# T-463 — A faster Qt Quick test run: shards, a test motion scale, condition waits

Status: in-progress · Phase: 2 · Depends: — · Area: scripts (dev.ps1), shell (tests) · Size: M · Owner: builder · Complexity: normal · Developer surface: none

## Goal
`dev.ps1 test` spends about 330 s in the offscreen Qt Quick tests (1198 tests). Every builder round, review and merge gate waits for it (owner, 2026-11-11: "do we lose time with unnecessary tests?"). Make the same tests, with the same assertions, finish in well under half the wall time.

## Found (lead-11 profile, 2026-11-11; raw data `output\perf-times.xml` on the lead's checkout, not tracked)
- 1265 functions, 329.9 s in total. 59 functions of 1 s or more take 139.9 s (42 %); start-up per file is negligible. The exe runs every `tst_*.qml` in one process.
- Slowest TestCases (s): SoundAmbient 33.5, Wallpaper 32.2, Bluetooth 17.0, Storage 16.5, Settings 15.1, SoundChecker 13.7, Power 13.1, Pages 11.9, Display 9.5, AppFlow 9.0.
- Causes: real animations at full duration (only 4 of about 170 files set `Theme.motionFactor`); 322 literal `wait(N)` calls (18 of 1 s or more, 29 s, e.g. `tst_glide.qml:555` wait(7000), `tst_wallpaper.qml:1001-1136` wait(600..1500)); timer-bound waits (`Theme.guideHoldMs` in `tst_Power.qml:309,328`, three real pairing time-outs in `tst_picker_pairing.qml:83-93`); `SoundThemes.fuzz(60000)` at `tst_sounds.qml:125` is 13.5 s of real CPU work.

## Scope
1. **Shards.** `dev.ps1 test` (and CI's shell job) runs the offscreen Qt Quick tests in N processes (default 3; `-Shards`), each with its own subset of the test files through the runner's `-input`, its own log, balanced by the measured times (a checked-in list or a simple size heuristic), and one combined pass/fail with the totals of all shards. A shard that crashes or hangs is a failure with its log named. `qml tst_x`, `shots` and the green marker work as before.
2. **A test motion scale.** Tests whose subject is not timing run with a short motion scale (e.g. `Theme.motionFactor` 0.05-0.1, set once in a shared place); tests whose subject is a duration (the ambient bed fade at `tst_sound_ui.qml:173`, which asserts reduced motion does not shorten it; glide timing; long press) keep real time and say so in a comment.
3. **Condition waits.** Replace the fixed waits of 1 s or more with `tryVerify`/`tryCompare` on the condition they wait for. A negative check ("nothing happens within X") keeps its wait but may shorten X when X is a tunable time the test sets (hold time, pairing window).
4. Leave `SoundThemes.fuzz` unless a cheap, assertion-preserving cut is obvious (its `cases > 1500` floor stays).

## Out of scope
- Removing, skipping or loosening any test (CLAUDE.md, Hard rules). `shots` speed.

## Acceptance criteria
- [ ] `lost-tests.sh` prints nothing; the same number of functions pass as on main (1198 + skips today; name any difference)
- [ ] The offscreen Qt Quick step of `dev.ps1 test` takes at most 45 % of main's time on the same machine (both numbers in the Outcome, measured back to back)
- [ ] A shard that fails or crashes fails `test` and names its log (test of the script path, like T-462's probe self-check)
- [ ] Three `dev.ps1 test` runs in a row ALL GREEN (no new flake from the shorter times)
- [ ] CI's shell job passes with the shards (or stays serial there, with the reason in the Outcome)

## Verification
```powershell
.\scripts\dev.ps1 test
bash scripts/lost-tests.sh
```

## Docs to update
- `docs/dev-setup.md` (test), `shell/CLAUDE.md` (Tests: the motion scale and when a test keeps real time).

## Hints
- Planned by lead-11 from a profile run. `Run-QmlTests` in `scripts/dev.ps1` already passes `-input` for one file (`qml` mode). Tests that read the screen size or a window may need their own window per process: they already do (offscreen). Other builders' test processes may run at the same time: never kill them.

## Outcome
_Filled in by the implementer._
