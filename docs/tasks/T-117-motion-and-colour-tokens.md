# T-117 — Honour reduced motion in feedback animations; move literal durations and colours into Theme tokens

Status: todo · Phase: 1 · Depends: — · Area: shell · Size: M

## Goal
With reduced motion on, nothing in the shell shakes, pulses or fades by surprise: the PIN pad's wrong-PIN shake and the tile "pulse" respect the setting. The rule "no literal colours, durations or easing in components" becomes machine-checked instead of a convention that was already broken in a few places.

## Read first
- `shell/CLAUDE.md` ("QML rules": no literal colours or durations in components)
- `docs/specs/02-shell.md` §3.2 (durations, reduced motion) and §3.3
- `shell/qml/Theme.qml`, `PinPad.qml` (the `shake` animation), `Tile.qml` (`pulseAnimation`)
- `docs/tasks/T-102-motion-and-quality.md` Outcome (what reduced motion already covers and what it left alone)

## Scope
1. **Feedback animations.** Add Theme tokens for the PIN-pad shake (distance, step durations) and the tile pulse (scale, down/up durations). Under reduced motion the shake does not run at all (the error message and the error sound already say it) and the pulse is skipped (the page change that follows is the feedback).
2. **Audit literals.** Find every literal duration and colour used in components (`rg "duration: \d" shell/qml`, `rg '"#[0-9a-fA-F]{6,8}"|Qt\.rgba\(' shell/qml`), excluding `Theme.qml`. Move each into a named Theme token (for example scrim, panel background, error text, warning text, avatar fallback). Rendering must not change visibly.
3. **Token lint.** Add a step to `dev.ps1 shell` (so it runs in `dev.ps1 test`) that fails when a QML file other than `Theme.qml` contains a literal `duration: <number>` other than `0`, or a quoted hex colour. Allow an explicit opt-out marker comment (`// token-ok: <reason>`) for the rare case, and list any used in the Outcome.

## Out of scope
- New visual design or colour changes.
- The sound effects (`Sfx`) and the effects quality tiers (T-102).

## Acceptance criteria
- [ ] With `DeviceSettings.reducedMotion = true`, a wrong PIN does not start the PIN-pad shake, and `Tile.pulse()` does not run its animation (test `tst_motion.qml::test_feedback_animations_respect_reduced_motion`; give the animations `objectName`s and assert `running`).
- [ ] With reduced motion off, both animations still run (same test file).
- [ ] The lint step fails on a file that contains `duration: 120` (demonstrate once by adding the line, show the failure in the Outcome, then remove it) and passes on the tree.
- [ ] Existing tests pass unmodified, and screenshots `3-home.png`, `2-pin.png` and `10-settings-profiles.png` look unchanged (compare by eye; say so in the Outcome).

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/02-shell.md` §3.2: remove the sentence that says the shake and pulse are not yet tied to reduced motion.
- `shell/CLAUDE.md`: one line saying the lint exists and how to opt out.

## Hints
- `Theme` already has `reducedMotion`, `focusMs`, `pageMs`. Follow that style: `readonly property int pulseDownMs: reducedMotion ? 0 : 70`.
- `SequentialAnimation.running` bound to a token is not enough to stop a restart: guard the `restart()` call sites.
- The lint can be a few lines of PowerShell with `Select-String`; keep it readable.

## Outcome
_Filled in by the implementer: what was built, files, how it was verified, deviations, follow-ups._
