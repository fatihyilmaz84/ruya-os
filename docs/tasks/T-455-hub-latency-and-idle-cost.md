# T-455 — Hub budgets: activation latency, idle cost and the game's FPS with the Hub open, measured on the Dell

Status: todo · Phase: 2 · Depends: T-448 · Area: scripts, shell (fixes only) · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
We know, with numbers from the Dell, how fast Guide opens the Hub over a game, what the Hub costs while hidden and open, and how much the game's FPS drops while it is open; budgets are written down and a script repeats the measurement.

## Read first
- ADR-033; `07-hub-requirements.md` §8; `scripts/dell-glass-check.sh` (uinput keys, drm fdinfo, KMS captures); T-451 (the compositor's FPS counter, if merged)

## Scope
1. `scripts/dell-hub-check.sh`: with STK in front, press Guide through uinput and measure the time to the Hub's first frame (compositor log line with a timestamp, added if missing), the shell's GPU and CPU while the Hub is hidden and open, and the game's FPS before and during.
2. Write the budgets into `02` §1.6 (proposal: open under 100 ms, hidden cost zero frames, game FPS drop under 10 % on the Dell) and the measured numbers into the Outcome.
3. Fix what the numbers show if the fix is small; otherwise an Inbox line.

## Acceptance criteria
- [ ] The script runs on the Dell and prints the numbers with PASS/FAIL against the budgets (output in the Outcome)
- [ ] hw: the numbers are from the Dell; `Verified: hw`
- [ ] `dev.ps1 test` ALL GREEN

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `02` §1.6 (budgets), `docs/dev-setup.md` (the script).

## Hints
- Planned by lead-10 (ADR-033). The builder may use the Dell (CLAUDE.md, Dell rule).

## Outcome
_Filled in by the implementer._
