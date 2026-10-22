# T-106 — First-boot setup (OOBE)

Status: todo · Phase: 2 · Depends: T-102, T-104, T-105 · Area: shell · Size: M

## Goal
On a fresh install (no profiles), the shell runs a short controller-only setup instead of the picker, and finishes on the picker with the new admin profile.

## Read first
- `docs/specs/01-platform.md` §5.2 (OOBE steps)
- `services/ruya-profiles/src/service.rs`: the first profile must be an admin with a PIN, and no admin credentials are needed
- `shell/qml/Shell.qml` (`routeFocus`, `signedIn`)

## Scope
1. Make the mock's starting state configurable: `RUYA_MOCK_PROFILES=empty` starts with no profiles; the default stays the 3 seeded profiles.
2. Trigger: `Profiles.available && Profiles.profiles.length === 0`. The shell shows `Setup.qml` instead of the picker. `routeFocus()` handles this state.
3. Steps (each a full-screen panel; Back goes to the previous step, Accept continues):
   1. **Welcome**: product name, "Press A to start".
   2. **Language**: ChoiceRow with English / Türkçe. This only stores the choice (`DeviceSettings.language`); actual translation comes in T-109.
   3. **Network**: placeholder panel ("Network setup comes later"), Continue.
   4. **Create admin**: name via `TextEntry`, PIN via `PinPad` `collect-confirm`, then `createProfile("", "", name, "admin", pin)`.
   5. **Done**: "You're all set", Accept goes to the picker.
4. Errors from `createProfile` are shown on step 4 with a retry.
5. A progress indicator shows step n of 5.

## Out of scope
- Real network configuration, time zone, controller pairing and the update check (later tasks, once services exist).
- Running setup again after a factory reset (it will happen naturally, because profiles will be empty).

## Acceptance criteria
- [ ] With `RUYA_MOCK_PROFILES=empty`, the shell starts in Setup, not the picker (test `tst_setup.qml::test_setup_shown_when_no_profiles`). Set the env in this test file's setup or via a test-only API on the mock.
- [ ] The full flow by controller creates an admin named "Owner" with PIN 2468, and the picker then shows exactly that profile (test `test_full_setup_flow`).
- [ ] Back on each step returns to the previous step with its state kept (test `test_back_navigation`).
- [ ] The seeded mock (default) never shows Setup (existing tests unaffected).
- [ ] Screenshots `11-setup-welcome.png` and `12-setup-admin.png`.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/01-platform.md` §5.2: mark which steps exist and which are placeholders.
- `docs/dev-setup.md`: document `RUYA_MOCK_PROFILES=empty`.

## Hints
- `tst_main.cpp` sets the env for the whole runner. For a per-file empty state, prefer a test-only invokable on the mock facade (e.g. `Profiles.resetMockForTests("empty")`, compiled in only for the mock backend) over env juggling.

## Outcome
_Filled in by the implementer._
