# T-286 — Names from outside are drawn as plain text everywhere; wallpaper copy edge cases

Status: done · Phase: 2 · Depends: — · Area: shell (QML text surfaces, Wallpapers.cpp, tests) · Size: S · Owner: builder

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

Verified: host (`dev.ps1 test` ALL GREEN: 871 QML passed + 66 skips, Rust all ok; `dev.ps1 shots` ALL GREEN, 143 passed). Nothing here needs the VM.

UX notes: nothing new to navigate. The Dim row is reached and left as before (Down from Wallpaper, Back leaves the pane); focus stays on the row while Left/Right step the slider. Its bar and number now show the applied dim: Left/Right still move the slider's own position (steps of 5), so on a bright picture (Daybreak under Dreamglass: slider 20, shown 54 %) a key press changes nothing visible until the slider passes the rule. I doubted that and kept it because the spec calls the slider "a minimum" (04 3.5); a caption explaining it would be a new string in every language, so it is an inbox line. No caption exists today, so "keeps the existing style" holds trivially. Screenshots read: `72-plain-text-profile-picker.png` (both hostile names drawn literally, `<b>x</b><img src="qrc:/n.png">`), `72-plain-text-home-status.png` (status bar), `70-wallpaper-page-daybreak.png` (Dim wallpaper 54 %).

**Scope 1, surfaces audited and fixed** (`textFormat: Text.PlainText` added; the 14 existing ones stay): profile name and first letter (`ProfileCard`, `Shell` status bar and avatar, `PinPad` "Enter PIN for", `ProfilesPane` message, `Setup` welcome and message); Bluetooth/audio/network/volume/sound-theme/wallpaper names go through `SettingControl` label, `SettingRow` value (both already plain) and now `ChoiceRow` current label; app names, summaries, developer, description and errors (`ArtCard` title, `AppDetailPage` developer/description/error/uninstall title, permission ids and "The update adds" (a raw id from the service, round 2), `StorePage` card name, developer line, row title and "No apps found", `AppArt` monogram, `HeroBlock`, `Page` title); `Badge`; the toast (already plain); service text in dialogs (`PowerConfirm` title/detail and the confirm button's label ("Forget %1" / "Delete %1", round 2), `ThermalNotice` sensor text, `SystemPane` messages); what the user types (`TextEntry` title and display text); `WallpaperPicker` message; `ControllerPairHint` message. Found by a script that lists every `Text {` block without `textFormat` and its `text:` binding, then read by hand; two (StorePage developer line, AppArt monogram) were missed by the first grep and the new test found the first. Left as they are: texts the shell composes from its own strings and numbers.

**Scope 2.** `shell/tests/tst_plain_text.qml` (tests are discovered from `shell/tests`, there is no list in `CMakeLists.txt`): 13 cases (two added in round 2), each feeds the string through a mock backend and walks the item tree (`children` and `contentItem`) for Text items containing it, asserts `PlainText` and a minimum count (and named surfaces where it pins them): profile status bar, Profiles pane, picker cards, PIN pad; Bluetooth row and pad toast; volume label in the Storage pane and the drive toast; SSID in the Network pane (rows and primary status); store card and app detail; store search message; the Forget confirmation of a hostile device (title and confirm label); a permission id from the service in the app detail (`Store.mockSetAppText` takes optional permissions); a service toast; the shared row controls (the audio outputs, sound-theme and wallpaper rows are built from them). New test-only mock hooks: `Storage.mockSetLabel`, `Network.mockSetSsid`, `Store.mockSetAppText` (Bluetooth had `mockSetName`, profiles use `renameProfile`). The shipped mock data is unchanged. PATTERNS.md has the rule.

**Scope 3.** `safeName` (Wallpapers.cpp) walks code points: printable filter and the 40-character cut count code points, so an emoji is kept or cut whole. `Wallpapers.mockPlantPicture(baseName)` (a picture named as given, different bytes per name) and `mockSafeName` are test hooks. `tst_wallpaper.qml::test_safe_name_code_points`: the filter on 300 characters and on an emoji at the cut (39 letters + emoji), and copies of files named "Holiday <emoji> 2026", three emoji, and 150 characters: all succeed, no lone surrogate, names as expected.

**Scope 4.** `SliderRow.shownValue` (defaults to `value`; bar, number and accessible value use it; the bar's fill ratio is clamped to 0..1 because the rule can ask for up to 85 % on a row that ends at 60, round 2); `DisplayPane` sets it to `max(slider, Wallpapers.requiredDim(...) * 100)` for the current picture and theme. `tst_wallpaper.qml::test_dim_row_shows_effective_dim`: dusk shows the slider, daybreak raises it, the number equals `layer.effectiveDim`, an owner dim of 60 shows 60. The Performance tier's extra darkening on pages (35 %) is deliberately not in the number (it depends on the page, the rule does not); 02 and 04 say so.

**Revert checks** (`revert-check.ps1`, each caught): removing `PlainText` from `ProfileCard` name, `SettingControl` label, `ToastLayer` text, `StorePage` developer line, `Page` title, `PinPad` title, `ChoiceRow` current label, the `PowerConfirm` confirm label, the two permission Texts of `AppDetailPage` (all `tst_plain_text`); `SliderRow`'s fill clamp (`test_dim_row_shows_effective_dim`: `shownValue` 85 against `to` 60 keeps the fill at the track width, -20 gives 0); removing the `shownValue` binding in `DisplayPane` (`test_dim_row_shows_effective_dim`); cutting by UTF-16 units again in `safeName` (`test_safe_name_code_points`).

**Deviations.** (1) The profile cases use `<b>x</b><img src="qrc:/n.png">` (31 characters): a profile name holds at most 32 and the task's string has 33; the other cases use the task's string. (2) "A 300-character name" is tested on the filter directly (`mockSafeName`): a 300-character file name cannot exist on this Windows host (255 limit); copies of a 150-character name are tested end to end. (3) No audio-sink or sound-theme hostile name goes through a mock: those mocks have no name hook and the rows are the shared controls, covered by the component case; adding hooks was left out (inbox). (4) Spec 04 got a sentence in the Wallpaper section and 02 one in Display & motion; no component-table row changed.

**Files.** QML: AppArt, AppDetailPage, ArtCard, Badge, ControllerPairHint, DisplayPane, HeroBlock, Page, PinPad, PowerConfirm, ProfileCard, ProfilesPane, Setup, Shell, StorePage, SystemPane, TextEntry, ThermalNotice, WallpaperPicker, controls/ChoiceRow, controls/SliderRow. C++: Wallpapers.{h,cpp}; Mock{Storage,Network,Store}Backend and their facades (hooks). Tests: tst_plain_text.qml (new), tst_wallpaper.qml. Docs: shell/PATTERNS.md, specs 02 and 04, this file.

**Follow-ups (inbox).** Long profile names overlap each other on the picker (31 characters at 1080p, see `72-plain-text-profile-picker.png`): `ProfileCard` has no width limit or elide. A caption or hint on the Dim row when the rule raises it. Name hooks for the audio and sound-theme mocks to make those two surfaces end-to-end cases.
