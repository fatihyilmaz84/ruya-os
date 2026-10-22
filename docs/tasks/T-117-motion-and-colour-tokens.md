# T-117 — Honour reduced motion in feedback animations; move literal durations and colours into Theme tokens

Status: done · Phase: 1 · Depends: — · Area: shell · Size: M

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
**Built (host-verified).** The PIN-pad shake and the tile pulse no longer run under reduced motion, every literal duration and colour outside `Theme.qml` is a token, and `dev.ps1 shell` fails if one comes back.

### Files
- `shell/qml/Theme.qml`: feedback tokens (`shakeDistance`, `shakeQuickMs`, `shakeSlowMs`, `pulseScale`, `pulseDownMs`, `pulseUpMs`; the ms ones are 0 under reduced motion); colour tokens (`focusFill`, `selectedFill`, `keyFocusFill`, `entryKeyFocusFill`, `entryKeyActiveFill`, `scrim`, `scrimOverlay`, `panel`, `errorText`, `warningText`, `blobHighlight`, `defaultTint`) and `tileAccent(key)`. Every value equals the literal it replaced.
- `PinPad.qml` (new `shakeDots()` guard; the three `shake.restart()` sites use it; animation `objectName: "pinShake"`), `Tile.qml` (`pulse()` guard; `objectName: "pulseAnimation"`; `accent` is now derived from `key`), and the literals in `Shell.qml`, `Backdrop.qml`, `Setup.qml`, `ProfilesPane.qml`, `SettingsPage.qml`, `TextEntry.qml`, `controls/SettingControl.qml`.
- `shell/qml/Shell.qml`: the tiles' `accent` role is gone from the `ListElement`s (they only carry `key` and `title`).
- `scripts/dev.ps1`: `Test-Tokens`, run by `dev.ps1 shell` before qmllint.
- `shell/tests/tst_motion.qml`: `test_feedback_animations_respect_reduced_motion`.
- Docs: spec 02 §3.2, `shell/CLAUDE.md`.

### Decisions
- The lint also flags `Qt.rgba(` (the task's audit mentioned it, and the white fills were the main remaining literals); the opt-out comment covers a future dynamic use. **No `token-ok` markers are used.**
- The guards sit at the call sites (`shakeDots()`, `pulse()`), as the hint advised; the tokens are also 0 under reduced motion so a stray start would still be instant.
- Tile accents became `Theme.tileAccent(key)`, because a `ListElement` cannot read a token. Same colours; an unknown key gets the Power grey.
- Left alone on purpose: easing types (`Easing.OutCubic` ...; not in the task's lint), and the backdrop drift periods (`property int period: 18000`, not a `duration:` literal; they already stop with reduced motion).

### Verification
- `.\scripts\dev.ps1 test` → ALL GREEN (88 passed). No existing test was edited.
- The new test spies on `runningChanged` of both animations: with reduced motion on nothing starts after a wrong PIN or `tile.pulse()` (`count` stays 0), with it off both start. To prove it can fail I removed the `Tile.pulse()` guard once: `FAIL! ... test_feedback_animations_respect_reduced_motion() no pulse under reduced motion`; restored.
- Lint demonstration: I added `Behavior on opacity { NumberAnimation { duration: 120 } }` to `Backdrop.qml`; `dev.ps1 shell` printed `shell\qml\Backdrop.qml:10: Behavior on opacity { NumberAnimation { duration: 120 } }`, `Move these into Theme.qml tokens, or add '// token-ok: <reason>'.` and `FAILED: token lint`. Removed again; the tree passes.
- `dev.ps1 shots` → ALL GREEN (96 passed). `3-home.png`, `2-pin.png`, `10-settings-profiles.png` reviewed by eye: tile gradients and accents, the PIN-pad scrim, key fills, focus rings and the error colours look as before. I did not diff against pre-change images: they were overwritten, and the drifting backdrop makes pixel diffs noisy.

### Not verified
- That the shake and pulse feel right to a human with motion on (only that they start). Real hardware as always.

### Follow-ups
None.
