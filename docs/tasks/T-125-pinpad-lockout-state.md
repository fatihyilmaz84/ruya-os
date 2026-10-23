# T-125 — PIN pad: a visible locked-out state

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: S

## Goal
While a profile is locked out, the PIN pad clearly looks and behaves locked: digits are not accepted, OK is visibly disabled, and the countdown is the only message. Today (found in the VM, T-120) digits are still entered and OK silently does nothing until the countdown ends, which reads as "wrong PIN".

## Read first
- `docs/specs/02-shell.md` (profile picker and PIN entry), `docs/specs/03-services-and-apps.md` §1 (lockout policy)
- `shell/qml/PinPad.qml` (`lockSecs`, the countdown `Timer`, the submit guard), `shell/qml/ProfileStatus.qml`
- `shell/tests/tst_shell.qml` / the lockout tests (`Lockout` test case), `tst_profile_admin.qml` (collect modes share the pad)

## Scope
1. While `lockSecs > 0`: digit keys and Backspace do nothing, the entered digits are cleared, the digit row and OK use a disabled look (Theme tokens; add one if none fits), and the message shows the countdown.
2. When the countdown reaches 0 the pad is usable again without any other action, with focus where it was.
3. The same holds in every pad mode that checks a PIN against the service (sign-in, the admin PIN in Settings → Profiles, the old PIN in Change PIN), since they all get `locked-out` replies.

## Out of scope
- Changing the lockout policy or the service.
- Sounds for the locked state.

## Acceptance criteria
- [ ] Locked: pressing digits leaves `entered` empty and Accept on OK sends nothing to the backend (test: `test_locked_pad_ignores_input`; the mock counts calls).
- [ ] The disabled look is on while locked and off after the countdown (test asserts the property the visuals bind to, not pixels).
- [ ] After the countdown the right PIN signs in (test, with the mock's lockout shortened or time advanced the way existing lockout tests do it).
- [ ] Screenshot `15-pin-locked.png` shows the locked pad with the countdown; reviewed by eye.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/02-shell.md`, the PIN-entry paragraph, if it describes lockout feedback.

## Hints
- Reduced motion: no shake while locked (T-117 guards).
- Tests must not wait the real 30 s lockout; see how the existing `Lockout` test drives `retryAfterSecs`.

## Outcome
_Filled in by the implementer: what was built, files, how it was verified, deviations, follow-ups._
