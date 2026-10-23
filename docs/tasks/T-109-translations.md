# T-109 — Translations (English, Turkish) with live switching

Status: done · Phase: 2 · Depends: T-103, T-106 (done: `DeviceSettings.language` and the Setup wizard exist) · Area: shell · Size: M

## Goal
Every shell string is translatable. A Turkish translation ships, and switching language in Settings re-translates the UI immediately, without a restart.

## Read first
- `docs/specs/02-shell.md` §7 (i18n: `qsTr`, `.ts` files, RTL readiness; initial locales en, tr)
- Qt docs: `qt_add_translations` (CMake), `QQmlEngine::retranslate()`

## Scope
1. CMake: `qt_add_translations(ruyashell TS_FILES i18n/ruyashell_en.ts i18n/ruyashell_tr.ts …)` so `.qm` files are embedded as resources. Running `lupdate` (the `update_translations` target) must be a documented step.
2. Audit: every user-visible string in QML and C++ goes through `qsTr`/`tr`. Brand names ("RuyaOS") and debug-only text are exempt. Plurals use `%n` (e.g. the PIN pad's "attempt(s) left").
3. Write the Turkish translations for all current strings. Natural, short console-UI Turkish: "Kim oynuyor?", "PIN girin", etc. English source strings stay as they are.
4. Language handling on top of `DeviceSettings.language` (it exists since T-106: `"en"`/`"tr"`, validated, persisted as `general/language`, change signal `languageChanged`; extend `DeviceSettings` or add a small `Language` helper, not a second stored setting):
   - setting it installs the matching `QTranslator` and calls `engine->retranslate()`;
   - the startup default comes from the stored setting, else the system locale, else `en`. **Tests run with `RUYA_SETTINGS_EPHEMERAL=1`: the ephemeral default must be `en` regardless of the machine's locale**, because many existing tests assert English strings (T-105's messages, for one).
5. A "Language" ChoiceRow (English / Türkçe) in Settings → System: the System category is still "Coming soon", so add a `SystemPane.qml` (copy `DisplayPane.qml`: a `SettingsPane` with controls bound to `DeviceSettings`) and register it in `SettingsPage.qml`. The Setup language step (T-106) uses the same property.
6. **Turkish characters in `TextEntry`.** The keyboard has only a–z today, so a Turkish user cannot type ç ğ ı ö ş ü İ. Make the layout locale-aware: when `DeviceSettings.language` is `tr`, the letters page uses the Turkish Q layout (extra keys on rows 2–3, keeping each row at 10 key units) and Shift maps i → İ and ı → I correctly (`toLocaleUpperCase`). The layout stays data (`layoutFor`), so another language is a data addition.
7. RTL readiness check only: launching with `--reverse` (`QGuiApplication::setLayoutDirection(Qt::RightToLeft)`) must not break navigation. Fix anchors that hard-code left/right where trivial; list the rest in the Outcome.

## Out of scope
- More languages (the structure must make them a one-file addition).
- Translating docs.

## Acceptance criteria
- [ ] With language `tr`, the picker title reads "Kim oynuyor?" (or your chosen Turkish string; assert against the `.ts` content) (test `tst_i18n.qml::test_switch_to_turkish`).
- [ ] Switching back to `en` restores English without a restart (test `test_switch_back`).
- [ ] The Turkish `.ts` has **no unfinished entries**: the test or a small check script counts `type="unfinished"` = 0, and the result is noted in the Outcome.
- [ ] The plural form shows correctly for 1 and 3 attempts in both languages (test `test_plurals`).
- [ ] In the first-boot wizard (empty profiles, `Profiles.resetMockForTests("empty")`), choosing Türkçe on the language step re-translates the wizard at once: the step label and the next step's title are Turkish, and going back and choosing English restores them (test `tst_i18n.qml::test_setup_follows_language`).
- [ ] With `tr`, the on-screen keyboard offers ç ğ ı ö ş ü and Shift+i types İ (test `tst_textentry.qml::test_turkish_layout`; the existing English tests still pass).
- [ ] Screenshots `15-picker-tr.png`, `16-settings-tr.png` and `16b-keyboard-tr.png`: no clipped or overlapping Turkish text (Turkish is often longer), keyboard rows still fit.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `shell/CLAUDE.md`: how to add strings and run `lupdate` (exact command), how to add a language.
- `docs/specs/02-shell.md` §7: current state.

## Hints
- The audit must also cover strings added since this task was written: toasts and the volume OSD (T-108), Settings panes and controls (T-103), `TextEntry` key labels (T-104), Profiles pane messages (T-105), the first-boot wizard `Setup.qml` and the shared `ProfileStatus.qml` messages (T-106), and the Power screens if T-107 is done by then. List the files audited in the Outcome.
- In `Setup.qml` the language names "English" and "Türkçe" are intentionally **not** in `qsTr` (each language is shown in itself); keep them that way. "RuyaOS" inside "Welcome to RuyaOS" is a brand name, the sentence around it is translatable.
- `tst_setup.qml` (T-106) asserts English strings and sets `DeviceSettings.language = "tr"` in two tests; its `init()` resets the language to `"en"`, so with live translation those tests keep working. If one of them breaks, fix the cause in the shell, not the assertion.
- `retranslate()` re-evaluates bindings, not values stored earlier. Messages written into a property at event time (`message = qsTr(...)` or `ProfileStatus.describe(...)` in `Setup.qml`, `ProfilesPane.qml`, `PinPad.qml`) keep the old language until the next event. For each, either keep the status and derive the text in a binding, or accept it and say so in the Outcome.
- UI rules since T-117: no literal colours/durations in new QML (the token lint fails the build).
- `lupdate` lives next to the other Qt tools in `D:\dev\Qt\6.10.3\msvc2022_64\bin`. With `qt_add_translations`, the `update_translations` CMake target runs it: `cmake --build shell\build-win --config Release --target update_translations`.

## Outcome
**Built.**
- **Translations:** `shell/i18n/ruyashell_en.ts` and `ruyashell_tr.ts` (140 messages each), `qt_add_translations` in `CMakeLists.txt` (resource prefix `/i18n`; `LinguistTools` is now a build dependency: `qt6-qttools-devel qt6-linguist` added to the CI `shell` job, the image's `shell-build` stage and `dev-setup.md`). The `.ts` files are refreshed with the `update_translations` target. The English file is only there for the `%n` plural forms ("1 attempt left" / "3 attempts left"); every English entry's translation is its own source, so a source string is never "unfinished".
- **Language handling:** `DeviceSettings` owns it (no second setting). `setLanguage` installs the `QTranslator` (`:/i18n/ruyashell_<lang>.qm`) and calls `QQmlEngine::retranslate()`; the engine is taken in `create()`, which also installs the startup translator and queues one `retranslate()` (bindings evaluated before the singleton existed used English). Startup default: stored value, else system locale (`tr_*` gives `tr`), else `en`; ephemeral mode (tests) is always `en`.
- **UI:** `SystemPane.qml` (Settings -> System, one "Language" `ChoiceRow`, registered in `SettingsPage.qml`); the Setup wizard's language step uses the same property.
- **Turkish keyboard:** `TextEntry.letterSets` is data per language; with `tr` the letters page has `qwertyuıopğü` / `asdfghjklşi` / `zxcvbnmöç`, the rows are narrowed so each stays 10 key units, and Shift maps i -> İ and ı -> I (an explicit `upper` table, because the QML engine's `toUpperCase()` is not locale aware; the task hinted `toLocaleUpperCase`).
- **RTL check:** `--reverse` (`main.cpp`, `QGuiApplication::setLayoutDirection`) and `Main.qml` sets `LayoutMirroring` from `Application.layoutDirection`.
- **Lint:** `scripts/lint-translations.ps1` (no `type="unfinished"` in `shell/i18n`), called by `dev.ps1 shell` and the CI `lint` job. Result: **0 unfinished in both files**.

**Bugs found on the way (fixed).** A live language change must not rebuild a list model: `SettingsPage.categories` and the home tiles' `ListModel` carried the translated labels, so `retranslate()` replaced the model and reset `currentIndex` (focus left the language row; the home tiles would have jumped back to "Games"). Both models are now key lists with the label as a binding (`SettingsPage.labelFor`, `Shell.tileTitle`); `shell/CLAUDE.md` records the rule. Tested (`test_settings_language_row`, `test_home_tiles_follow_language`).

**Audit** (every user-visible string goes through `qsTr`; checked by grepping all `text:`/`title:`/`label:` literals and by the `lupdate` count): AboutPane, AudioPane, ChangePinFlow, ComingSoon, DisplayPane, GamesPage, MediaPage, StorePage, PinPad, PowerConfirm, PowerPage, ProfileAddFlow, ProfileCard, ProfilePicker, ProfileStatus, ProfilesPane, SettingsPage, Setup, Shell (tiles, overlay, toasts), SystemPane, TextEntry, VolumeOsd, plus `main.cpp` (no user-visible text). Not translated on purpose: "RuyaOS", the language names, the `FpsMeter` unit "FPS" (debug). The tile titles in `Shell.qml` were plain `ListElement` strings, now `qsTr`.

**Verification.** `dev.ps1 test` ALL GREEN and `dev.ps1 shots` ALL GREEN (143 tests; the first `shots` run hit the known `Power` guide-key flake and passed on the re-run). New: `tst_i18n.qml` (`test_default_is_english`, `test_switch_to_turkish`, `test_switch_back`, `test_plurals`, `test_settings_language_row`, `test_setup_follows_language`, `test_home_tiles_follow_language`, `test_rtl_navigation`), `tst_textentry.qml::test_turkish_layout`. Screenshots `15-picker-tr.png`, `16-settings-tr.png`, `16b-keyboard-tr.png` reviewed: no clipped or overlapping text, keyboard rows fit (the letter keys are narrower, labels stay legible).

**Image.** Built in WSL as `0.0.7-t109` (`bootc container lint --fatal-warnings` clean; the first attempt failed in the shell stage because Fedora's `Qt6LinguistTools` CMake config is in `qt6-qttools-devel`, so both `qt6-qttools-devel` and `qt6-linguist` are installed), disk made, `smoke-test.ps1` printed `RUYA_BOOT_OK 0.0.7-t109`. **Unverified:** switching the language inside the VM and the shell journal's absence of `no translation for` warnings (the VM boots in `en`; I did not open an SSH session), Turkish rendering with the image's fonts.

**Deviations and known gaps.**
- **Stored messages keep their language** until the next event (as the task allowed): `PinPad.message` ("Wrong PIN..."), `Setup.message`, the Profiles pane status line, and toast text. The lockout countdown and all labels are bindings and do change at once.
- **RTL is a readiness check, not finished work.** Tested: sign-in (mirrored picker), home tiles and Settings navigation. Not checked by eye (no RTL screenshots reviewed) and likely wrong: the PIN pad's `GridView` mirrors, so the digits would appear reversed (digits should stay left to right); the on-screen keyboard positions keys with explicit `x`, so it stays left to right (acceptable). Slider/toggle rows, the toast layer and `ProfileCard` badges were not examined. One Inbox line added.
- `qt_add_translations` also hands `sounds/*.wav` to `lupdate`, which prints a harmless "Excess closing parenthesis" warning per file.
- Turkish text is mine (natural, short console-UI wording); it has not had a native review. One Inbox line.

