# T-106 — First-boot setup (OOBE)

Status: done · Phase: 2 · Depends: T-102, T-104, T-105 (T-115 first, so the error handling is written once) · Area: shell · Size: M

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
**Built (mock path, host-verified).** With no profiles the shell shows a five-step controller-only wizard instead of the picker, and ends on the picker with the new admin.

### Files
- `shell/qml/Setup.qml` (new): the wizard (welcome, language, network placeholder, create admin, done), progress dots with "Step n of 5", its own modal layer for `TextEntry` and `PinPad` (`collect-confirm`).
- `shell/qml/ProfileStatus.qml` (new singleton): the status-to-message mapping extracted from `ProfilesPane.describe`, which now delegates to it. Setup uses it for the error on step 4.
- `shell/qml/Shell.qml`: `setupNeeded` / `setupActive`, `routeFocus()` knows the setup state, the picker is disabled while setup is active.
- `shell/src/settings/DeviceSettings.{h,cpp}`: `language` (`"en"`/`"tr"`, default `"en"`, validated, persisted as `general/language`).
- `shell/src/profiles/MockProfilesBackend.cpp`: `RUYA_MOCK_PROFILES=empty` starts without profiles.
- `shell/CMakeLists.txt`: the two new QML files; `ProfileStatus.qml` is a singleton.
- `shell/tests/tst_setup.qml` (new, 8 tests plus the screenshot test). Docs: spec 01 §5.2, spec 02 §1.3, `dev-setup.md`, `shell/CLAUDE.md`.

### Decisions where the task left room
- **Leaving setup.** Setup stays up until the Done step is accepted, even though the profile list is non-empty from the moment the account exists. The shell drops setup early only if a profile appears some other way before the account is being created (`Setup.committed` = creating or created). This is the "no flash of the picker" hint.
- **Back.** Escape does nothing on step 1, and also on Done and while the account is being created (there is nothing to go back to). Back from step 3 to 1 keeps the name and the language.
- **Focus on the key-only steps** (welcome, network, done) goes to an empty `keySink` item whose keys bubble to the wizard's handler, because a `FocusScope` would remember the last focused row.
- **Step 4 layout.** Two rows (Name, "Choose a PIN and finish") instead of a third "Continue" button; Accept on the first opens the keyboard, on the second the PIN pad. Choosing a name moves focus to the second row.
- Setup does not sign the new admin in (the task says it ends on the picker).
- Language names (`English`, `Türkçe`) are not wrapped in `qsTr`; they are shown in their own language on purpose.

### Verification
- `.\scripts\dev.ps1 test` → ALL GREEN. New tests: `test_setup_shown_when_no_profiles`, `test_language_choice` (including the rejected value), `test_full_setup_flow` (admin "Owner", PIN 2468, picker shows exactly that profile and the PIN works), `test_back_navigation`, `test_seeded_mock_never_shows_setup`, `test_name_is_required`, `test_cancelling_the_pin_pad_creates_nothing`, `test_error_is_shown_and_can_be_retried` (a 40-character name is refused by the mock as the service does, then corrected). No existing test was edited.
- `.\scripts\dev.ps1 shots` → ALL GREEN; `11-setup-welcome.png` and `12-setup-admin.png` reviewed: focus rings visible, text readable over the backdrop.
- `RUYA_MOCK_PROFILES=empty` was smoke-run with the real executable (starts, no QML errors). Whether that run really showed the wizard was not looked at; the test path `resetMockForTests("empty")` covers the same state.
- The new QML singleton and the changed header built and tested green on the first run (T-116 fix, as intended).

### Not verified
- The wizard against the real `ruya-profiles` over D-Bus (no bus on this host). The same first-boot rule is covered by the Rust tests (`first_profile_must_be_admin_with_pin`).
- A real controller; keys only.
- Translations: language is stored but the UI does not change yet (T-109).

### Follow-ups
None new (T-109 already covers translation, T-114 audio, B-001 notes the VM runs with an empty profile store, which this wizard now serves).
