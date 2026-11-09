# T-397 - One controller drives the UI: owner pads per signed-in profile, takeover when they are gone, Guide on a foreign pad

Status: todo · Phase: 2 · Depends: T-396 · Area: services (ruya-inputd), shell (input, picker, prompts) · Size: M · Owner: builder · Complexity: complex · Developer surface: none

## Goal
After sign-in only the profile's own controller(s) move the focus, as on a PlayStation 5: a second person's pad cannot steer the menus by accident. Guide on that pad offers to switch to its profile; when the owner's pad is gone, the next pad can take over after one A press. The console can never be left with no way to navigate.

## Read first
- ADR-027 and T-396's Outcome (states, prompts, copy), ADR-017; `services/ruya-inputd` (pad identity per event), the shell's input path and profile picker, `docs/specs/02-shell.md` §4.3; T-334..T-337 (two pads, inputd)

## Scope
1. Pad identity on every navigation event (inputd already tells pads apart); the shell keeps the owner set for the active profile (at sign-in: the pad that signed in; T-264's slots replace this later).
2. Foreign pads: navigation ignored; Guide → "Switch to <profile>?" for a pad remembered for another profile, else "Who's playing?" (the picker); the prompts of T-396.
3. Takeover: when no owner pad is connected (or none sent input for the timeout T-396 sets), the next press of a foreign pad shows "Use this controller for <profile>?"; A makes it an owner.
4. Keyboard always navigates; the picker accepts any pad.

## Acceptance criteria
- [ ] Rust (inputd) and QML tests: foreign pad ignored after sign-in, Guide prompt, takeover after the owner disconnects, keyboard always works, picker any pad (red without each).
- [ ] VM (lead run): `vm-devices-check.sh twopads` extended (two virtual pads: the second cannot move the focus after sign-in; takeover after the first is removed); Outcome `Verified: host (vm pending: ...)`. hw (lead, Dell): two DualSense pads.
- [ ] Screenshots of the prompts (en, tr) reviewed; `dev.ps1 test` and `shots` ALL GREEN.

## Outcome
_Filled in by the implementer._
