# T-109 — Translations (English, Turkish) with live switching

Status: todo · Phase: 2 · Depends: T-103 (language selector lives in Settings) · Area: shell · Size: M

## Goal
Every shell string is translatable. A Turkish translation ships, and switching language in Settings re-translates the UI immediately, without a restart.

## Read first
- `docs/specs/02-shell.md` §7 (i18n: `qsTr`, `.ts` files, RTL readiness; initial locales en, tr)
- Qt docs: `qt_add_translations` (CMake), `QQmlEngine::retranslate()`

## Scope
1. CMake: `qt_add_translations(ruyashell TS_FILES i18n/ruyashell_en.ts i18n/ruyashell_tr.ts …)` so `.qm` files are embedded as resources. Running `lupdate` (the `update_translations` target) must be a documented step.
2. Audit: every user-visible string in QML and C++ goes through `qsTr`/`tr`. Brand names ("RuyaOS") and debug-only text are exempt. Plurals use `%n` (e.g. the PIN pad's "attempt(s) left").
3. Write the Turkish translations for all current strings. Natural, short console-UI Turkish: "Kim oynuyor?", "PIN girin", etc. English source strings stay as they are.
4. A C++ `Language` singleton (or extend `DeviceSettings`):
   - `language` property (`"en"`, `"tr"`), persisted with the other device settings;
   - setting it installs the matching `QTranslator` and calls `engine->retranslate()`;
   - the startup default comes from the stored setting, else the system locale, else `en`.
5. Settings → Accessibility, or a "Language" row in System, uses a ChoiceRow (English / Türkçe).
6. RTL readiness check only: launching with `--reverse` (`QGuiApplication::setLayoutDirection(Qt::RightToLeft)`) must not break navigation. Fix anchors that hard-code left/right where trivial; list the rest in the Outcome.

## Out of scope
- More languages (the structure must make them a one-file addition).
- Translating docs.

## Acceptance criteria
- [ ] With language `tr`, the picker title reads "Kim oynuyor?" (or your chosen Turkish string; assert against the `.ts` content) (test `tst_i18n.qml::test_switch_to_turkish`).
- [ ] Switching back to `en` restores English without a restart (test `test_switch_back`).
- [ ] The Turkish `.ts` has **no unfinished entries**: the test or a small check script counts `type="unfinished"` = 0, and the result is noted in the Outcome.
- [ ] The plural form shows correctly for 1 and 3 attempts in both languages (test `test_plurals`).
- [ ] Screenshots `15-picker-tr.png` and `16-settings-tr.png`: no clipped or overlapping Turkish text (Turkish is often longer).

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `shell/CLAUDE.md`: how to add strings and run `lupdate` (exact command), how to add a language.
- `docs/specs/02-shell.md` §7: current state.

## Hints
- `lupdate` lives next to the other Qt tools in `D:\dev\Qt\6.10.3\msvc2022_64\bin`. With `qt_add_translations`, the `update_translations` CMake target runs it: `cmake --build shell\build-win --config Release --target update_translations`.

## Outcome
_Filled in by the implementer._
