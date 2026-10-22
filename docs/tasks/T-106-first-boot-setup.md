# T-106 — First-boot setup (OOBE)

Status: todo · Phase: 2 · Depends: T-102, T-104, T-105 (T-115 first, so the error handling is written once) · Area: shell · Size: M

## Goal
On a fresh install (no profiles), the shell runs a short controller-only setup instead of the picker, and finishes on the picker with the new admin profile.

## Read first
- `docs/specs/01-platform.md` §5.2 (OOBE steps)
- `services/ruya-profiles/src/service.rs`: the first profile must be an admin with a PIN, and no admin credentials are needed
- `shell/qml/Shell.qml` (`routeFocus`, `signedIn`)
- T-105 Outcome and code: `PinPad.qml` (`collect-confirm` mode), `TextEntry.qml`, `ProfilesPane.qml` + `ProfileAddFlow.qml` (the same name → PIN → `createProfile` steps, and how statuses become messages), `Profiles.resetMockForTests`

## Scope
1. Starting state: `Profiles.resetMockForTests("empty")` already exists (T-105) for tests. Add `RUYA_MOCK_PROFILES=empty` so a human can run the shell in first-boot state (`dev.ps1 run`); the default stays the 3 seeded profiles. Add `DeviceSettings.language` (`"en"` or `"tr"`, default `"en"`, validated and persisted like the other settings; T-109 makes it translate).
2. Trigger: `Profiles.available && Profiles.profiles.length === 0`. The shell shows `Setup.qml` instead of the picker. `routeFocus()` handles this state.
3. Steps (each a full-screen panel; Back goes to the previous step, Accept continues):
   1. **Welcome**: product name, "Press A to start".
   2. **Language**: ChoiceRow with English / Türkçe. This only stores the choice (`DeviceSettings.language`); actual translation comes in T-109.
   3. **Network**: placeholder panel ("Network setup comes later"), Continue.
   4. **Create admin**: name via `TextEntry`, PIN via `PinPad` `collect-confirm` (page-owned modals use `Page.overlay`; Setup is not a page, so parent them to a full-screen layer inside `Setup.qml`), then `Profiles.createProfile("", "", name, "admin", pin)` (first boot needs no admin credentials).
   5. **Done**: "You're all set", Accept goes to the picker.
5. Errors from `createProfile` are shown on step 4 with a retry (`invalid`: name or PIN rejected; `failed`: try again). Reuse the status-to-message mapping idea of `ProfilesPane.describe`; extract it if it is cleaner than copying.
6. A progress indicator shows step n of 5.

## Out of scope
- Real network configuration, time zone, controller pairing and the update check (later tasks, once services exist).
- Running setup again after a factory reset (it will happen naturally, because profiles will be empty).
- Creating extra profiles during setup (spec 01 §5.2 lists it; the Settings → Profiles flow already covers it later).

## Acceptance criteria
- [ ] With no profiles (`Profiles.resetMockForTests("empty")`), the shell shows Setup, not the picker (test `tst_setup.qml::test_setup_shown_when_no_profiles`).
- [ ] Choosing Türkçe stores `DeviceSettings.language = "tr"`; an invalid value is rejected (test `test_language_choice`).
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
- `docs/specs/02-shell.md`: Setup surface (as built).

## Hints
- Reset the mock in `init()` of every test in `tst_setup.qml` (and back to `"seeded"` at the end), as `tst_profile_admin.qml` does; the next test file gets a fresh engine anyway.
- When the last profile appears, the shell must leave Setup by itself (`Profiles.profiles` becomes non-empty); the Done step should not depend on that to avoid a flash of the picker.

## Outcome
_Filled in by the implementer._
