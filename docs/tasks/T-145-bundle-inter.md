# T-145 — Bundle the Inter typeface

Status: todo · Phase: 2 · Depends: T-142 · Area: shell, image · Size: S

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
- Fedora also packages it (`rsms-inter-fonts`), but a Qt resource keeps Windows, CI and the image identical.

## Outcome
_Filled in by the implementer. Start with a `Verified:` line._
