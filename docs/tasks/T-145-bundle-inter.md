# T-145 — Bundle the Inter typeface

Status: in-progress · Phase: 2 · Depends: T-142 · Area: shell, image · Size: S

Owner decision 2026-10-28: yes, bundle Inter as a Qt resource.

## Goal
The shell renders in Inter on every machine (Windows dev host, offscreen tests, the image), so screenshots match the device and Turkish glyphs render from one font.

## Read first
- `docs/specs/04-design-system.md` §3.2, ADR-012 in `docs/specs/00-overview.md`
- `docs/specs/02-shell.md` §6 (shell assets are Qt resources)

## Scope
1. Add Inter (static or variable TTF, regular/light/semibold, Latin + Latin Extended-A) under `shell/fonts/` with its `OFL.txt`, as a Qt resource; load it with `QFontDatabase::addApplicationFont` in `main.cpp` before the engine starts.
2. Set `Theme.fontFamily` to `"Inter"` and apply it once at the window root (`Main.qml` / the test host) so components inherit it.
3. Licence: the OFL text ships in the repo and the image (`/usr/share/licenses/ruyaos/`), and the About pane's licence line mentions it.

## Out of scope
- Other scripts (Arabic, CJK): later, with the languages that need them.

## Acceptance criteria
- [ ] `tst_theme.qml::test_font_loaded`: `Qt.fontFamilies()` contains `Inter`, and a `Text` in the shell reports it.
- [ ] Screenshots reviewed (home, Settings, keyboard with ç ğ ı İ ö ş ü).
- [ ] Image builds and boots (`RUYA_BOOT_OK`), VM screenshot of home shows Inter.
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `04-design-system.md` §3.2, ADR-012 (font no longer open), `docs/dev-setup.md` if anything changes.

## Hints
- T-157 created the pattern for the licence: `install(FILES fonts/<licence> DESTINATION share/licenses/ruyaos)` in `shell/CMakeLists.txt`, and the fonts are loaded in `main.cpp` and in `tst_main.cpp`'s `qmlEngineAvailable` (not the `Setup` constructor: no `QGuiApplication` yet).
- Fedora also packages it (`rsms-inter-fonts`), but a Qt resource keeps Windows, CI and the image identical.

## Outcome
Verified: vm (0.0.36-t145: RUYA_BOOT_OK, /usr/share/licenses/ruyaos/OFL-Inter.txt present, VM home screenshot shows Inter); shots: host, reviewed 01-home.png and 7-settings-display.png in round 2

Built: Inter 4.1 Regular, Light, SemiBold and Bold (round 2), subset to Latin + Latin Extended-A plus common punctuation (about 48 KB each), in `shell/fonts/` with the upstream OFL text as `OFL-Inter.txt`. `scripts/fetch-inter.sh` downloads the pinned release zip (github.com/rsms/inter v4.1; SHA-256 recorded from the first download, 9883fdd4...) into a temporary directory, verifies it, extracts a fixed list of five members and cuts the subsets. `main.cpp` and `tst_main.cpp` register the fonts and call `QGuiApplication::setFont(Inter)`, so every Text inherits it (Window has no font property, so the application font is the "root" application); `Theme.fontFamily` is `"Inter"`. The licence is installed by `cmake --install` (already used by the Containerfile) into `/usr/share/licenses/ruyaos/`; the About licence line now names Inter (en and tr strings, `tst_settings` updated).

Test: `tst_theme::test_font_loaded` (Qt.fontFamilies contains Inter, `Theme.fontFamily`, a Text reports Inter). Revert test: removing the `setFont` call in `tst_main.cpp` made it fail (1 failed); restored. `dev.ps1 test`: ALL GREEN, 343 passed, 28 skips (screenshot tests).

Round 2 (review): added U+2039/203A (the choice-row chevrons), the Bold cut, `python -I` in the cut script, and `scripts/check-font-coverage.py` (pure Python cmap check of every character in shell/qml, src and i18n against the four cuts; run by fetch-inter.sh and `dev.ps1 test`). Revert test: the old Regular cut fails it on U+2039/203A. No new image: the VM boot and home screenshot are from round 1 (glyph coverage and one more font only).

Deviations: the licence file is `OFL-Inter.txt` (not `OFL.txt`) to sit beside `LICENSE-MaterialSymbols.txt`. Bold added in round 2 (lead decision). The ADR-012 text needed no change (it already says Inter is decided); 04 section 3.2 and dev-setup are updated.
