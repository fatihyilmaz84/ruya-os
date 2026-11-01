# T-157 — Icon font (Material Symbols Rounded) and `Icon`

Status: todo · Phase: 2 · Depends: — · Area: shell, image · Size: M · Owner: builder

Owner decision 2026-11-01 (ADR-013): Material Symbols Rounded, bundled.

## Goal
The shell draws its icons from one bundled font, so the Settings pill shows a white gear on every machine (today Windows draws a colour emoji) and the volume OSD gets the speaker icon its spec asks for.

## Read first
- ADR-013 in `docs/specs/00-overview.md`; `docs/specs/04-design-system.md` §3.7 (all icon rules), §5 rows Icon, Section nav, Volume OSD, §8
- `docs/tasks/T-145-bundle-inter.md` (the same bundling pattern: Qt resource, `addApplicationFont`, licence in the image)
- `shell/qml/SectionNav.qml` (the gear), `shell/qml/VolumeOsd.qml`, `shell/qml/AboutPane.qml`, `shell/main.cpp`, `shell/CMakeLists.txt`
- Tokens this task may add: `iconFamily` (and `iconFamilyFilled` if the cuts get separate family names), `iconM` 40, `iconL` 64. Components: `Icon.qml` only.

## Scope
1. **Font:** from the official repository (`github.com/google/material-design-icons`, `variablefont/MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf`), pinned to a commit with its SHA-256 in the script. A script `scripts/subset-icons.sh` (runs in the WSL distribution; `dnf install python3-fonttools` is fine) cuts two static instances (wght 400, GRAD 0, opsz 40; FILL 0 and FILL 1) with `fonttools varLib.instancer`, subsets them to the code points listed in one file (`shell/fonts/icons.txt`: name and code point per line) with `pyftsubset`, and writes them to `shell/fonts/`. Commit the outputs (small TTFs), the list and the upstream `LICENSE` (Apache-2.0).
2. **Loading:** Qt resource, `QFontDatabase::addApplicationFont` in `main.cpp` and in the test host (`tst_main.cpp`), before the engine starts.
3. **`Icon.qml`:** `name`, `size` (default `Theme.iconM`), `color` (default `Theme.text`), `filled`; looks the name up in a table generated from or kept in step with `icons.txt` (a lint or test fails if they differ); unknown name → draws nothing, one `console.warn`. `Accessible.ignored: true` (the owner of the icon carries the name).
4. **Adopt:** the Settings pill uses `Icon { name: "settings" }` (filled while Settings is the current section); the volume OSD shows `volume_up` / `volume_off` before the bar instead of the word "Volume" ("Muted" stays in words, 04 §5). Start the list with: `settings`, `volume_up`, `volume_off`.
5. **Licence:** Apache-2.0 text in the repo next to the fonts and in the image (`/usr/share/licenses/ruyaos/`, as T-145 does for Inter, whichever lands first creates the pattern); the About pane's licence value mentions the bundled fonts.
6. Specs: 04 §3.7 and the rows become *built*; ADR-013 unchanged.

## Out of scope
- Icons anywhere else (toasts, Settings rows, Store): later tasks pick them from the set.
- Controller button glyphs and the hint bar (T-158).
- Inter (T-145).

## Acceptance criteria
- [ ] `Qt.fontFamilies()` contains the icon family, and `Icon { name: "settings" }` has a non-zero `implicitWidth` while an unknown name has zero (test, e.g. `tst_icon.qml`).
- [ ] The Settings pill holds an `Icon` named `settings`, filled exactly when Settings is the current section (test in `tst_home.qml` or `tst_settings.qml`).
- [ ] The OSD shows `volume_up`, and `volume_off` with "Muted" when muted (test in `tst_audio.qml` or the OSD's test).
- [ ] `icons.txt` and the `Icon` table agree (test or lint).
- [ ] Screenshots reviewed: `01-home.png` (white gear, same weight as the labels' optical size) and `14-toast-and-osd.png`.
- [ ] VM: image built, `RUYA_BOOT_OK`, the licence file present in `/usr/share/licenses/ruyaos/` (command in the Outcome).

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```
Then the image recipe in `docs/dev-setup.md`.

## Docs to update
- `04-design-system.md` §3.7 and §5 (built marks, the as-built note on Home), `docs/dev-setup.md` (how to add an icon: edit `icons.txt`, run the script in WSL).

## Hints
- Material Symbols code points are in the repository's `.codepoints` file next to the font; use them, not ligatures (04 §3.7).
- Static cuts avoid `font.variableAxes` and render the same on Qt 6.8 (the image) and 6.10 (the host).
- The download is a build input: write it with `curl -fL` into a fresh temporary directory inside WSL and check the SHA-256 before using it.

## Outcome
_Filled in by the implementer. Start with a `Verified:` line._
