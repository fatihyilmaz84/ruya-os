# T-286 — Names from outside are drawn as plain text everywhere; wallpaper copy edge cases

Status: in-progress · Phase: 2 · Depends: — · Area: shell (QML text surfaces, Wallpapers.cpp, tests) · Size: S · Owner: builder

## Goal
A profile, device, drive, Wi-Fi or app name that contains `<b>` or `<img>` is drawn as the characters it is, on every screen. A wallpaper copied from a USB stick with an emoji in its name keeps a sensible name, and the Dim row shows the dim actually applied.

## Read first
- `shell/PATTERNS.md` (text), `docs/specs/04-design-system.md` §8; `shell/qml/BarChart.qml` and `ControllerOnboarding.qml` (the 14 existing `textFormat: Text.PlainText` uses)
- `shell/src/wallpaper/Wallpapers.cpp` (`safeName`), `shell/qml/WallpaperPicker.qml`, `SettingsPage.qml` (Dim row)
- `shell/tests/tst_wallpaper.qml`; STATUS-parked.md "Inbox triage 2026-11-07", bullets T-286

## Scope
1. **Audit and fix:** every `Text` that shows a string from outside the shell uses `textFormat: Text.PlainText` (Qt's default `AutoText` renders HTML-looking names): profile names (cards, picker, status), Bluetooth and audio device names, volume labels (Storage, toasts), Wi-Fi SSIDs, app names and summaries from AppStream, wallpaper and sound-theme names from a drive, the Notifications text from services. List the surfaces in the Outcome.
2. **Guard:** a test that feeds the hostile string `<b>x</b><img src="qrc:/none.png">` through each mock backend (profile, Bluetooth, storage, network, store) and walks the item tree for `Text` items whose text equals it, asserting `textFormat === Text.PlainText`. A short rule goes into `shell/PATTERNS.md`.
3. **`safeName`** iterates code points, not UTF-16 units (an emoji is kept or removed whole, never split into a lone surrogate), tested for a name with an emoji, one with only emoji, and a 300-character name.
4. **Dim row:** shows the effective dim (after the bright-wallpaper rule of T-208), not only the slider position; the caption keeps the existing style.

## Out of scope
- Flattening transparent PNGs differently, PNG decode cost, accent from the wallpaper, per-profile wallpapers (need profile preferences). `qt6-qtimageformats` is an image change: T-299.

## Acceptance criteria
- [ ] `tst_plain_text.qml` (new, in `shell/CMakeLists.txt` test list) has one case per surface of Scope 1 and fails when one of those `PlainText` lines is removed (revert check noted).
- [ ] `tst_wallpaper.qml::test_safe_name_code_points`: no lone surrogate for the three names; the copy succeeds.
- [ ] `tst_wallpaper.qml::test_dim_row_shows_effective_dim`: a bright wallpaper raises the shown value above the slider's.
- [ ] Screenshot of the profile picker with the hostile name shows it literally (reviewed).
- [ ] UX: nothing new to navigate; Outcome has a `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `shell/PATTERNS.md` (plain text rule); 04 §5 if the Dim row copy changes.

## Hints
- Mock backends already take names from their model; add the hostile entry only inside the test, never to the shipped mock data.
- Overlaps nothing in flight; it touches many QML files by one line each, so merge it early.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
