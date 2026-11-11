# T-456 — Guide on every pad: long press for Power, Guide never reaches the game, a keyboard shortcut

Status: todo · Phase: 2 · Depends: T-367, T-396 · Area: shell, services (Ruya Input) · Size: S · Owner: builder · Complexity: normal · Developer surface: public-format

## Goal
Any connected pad's Guide/Home button opens and closes the Hub, a long press opens Power, the game never sees that press, and a keyboard opens the Hub too.

## Read first
- ADR-033 point 5, ADR-024, ADR-027; `07-hub-requirements.md` §4.1; `06-input.md` (written by T-366); `shell/src/` KeyRouter

## Scope
1. Use Ruya Input's semantic actions (T-367) for Guide short and long press on every pad; no per-model button ids in the shell.
2. The Guide press is consumed: the game's virtual pad never receives it.
3. Long press (duration from `06-input.md`) opens the Power page over the game; the keyboard shortcut (Super and the HomePage key today) stays.
4. Configurable shortcuts are not here (a later task after T-366's design).

## Acceptance criteria
- [ ] Developer guide (lead-11 rule: it changes what a running app experiences): `docs/developers/controller-input.md` and `fullscreen-and-lifecycle.md`: the Guide button and its long press never reach the game; `ruya-api-reviewer` at merge
- [ ] Short and long press from two pads on the mock open the Hub and Power (tests)
- [ ] The game's virtual pad sees no Guide event (test in the input service or the VM)
- [ ] VM (lead run): extend `vm-app-check.sh` or the input check: Guide over the test client opens the Hub and the client logs no Guide key
- [ ] `dev.ps1 test` ALL GREEN

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `02` §1.6, `06-input.md`.

## Hints
- Planned by lead-10 (ADR-033). Re-read against T-366's design before the claim: the action names and the long-press rule come from there.

## Outcome
_Filled in by the implementer._
