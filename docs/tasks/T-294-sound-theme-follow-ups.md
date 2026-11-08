# T-294 — Sound theme follow-ups: delete a saved theme, import limits tested, clear refusal message, one copy of the ambient file

Status: in-progress · Phase: 2 · Depends: — · Area: shell (SoundThemes, SoundThemeCheck, AudioPane, resources), scripts · Size: S · Owner: builder

## Goal
A player can delete a saved sound theme (the console keeps up to 8), a drive theme the checker refuses says why in one line, the import limits are proven by tests, and the 1.1 MB ambient file is not shipped twice.

## Read first
- `docs/specs/02-shell.md` §5.3 (sound themes), `docs/developers/sound-themes.md`, `04-design-system.md` §3.9
- T-227 Outcome (round 2); `shell/src/sound/SoundThemes.cpp` (`importTheme`, `refresh`, limits 8 copies / 100 files / 12 MB), `SoundThemeCheck.cpp` (the `qint64(end.toDouble())` cast), `shell/qml/AudioPane.qml`
- `shell/tests/tst_sounds.qml`, `tst_sound_ui.qml`; `shell/CMakeLists.txt` (resources, install of `sounds/dreamglass`)
- STATUS-parked.md "Inbox triage 2026-11-07", bullets T-294

## Scope
1. **Delete action:** each saved (copied) sound theme can be deleted from the Sound theme choice: a row "Delete “Name”" for the selected saved theme, with the existing confirm dialog style; deleting the active theme falls back to Dreamglass and plays no cue. The bundled theme cannot be deleted. The limit toast then reads "Delete one first" in addition to "Copy over one with the same name".
2. **Refusal message:** when the checker refuses a drive theme the drive row (or the toast on Accept) shows the first problem in plain words (for example "A cue is louder than allowed", built from the checker's problem list), en and tr; no raw path.
3. **Import bounds tested:** fixtures/tests for 101 files and a theme just over 12 MB (refused with the matching message) and exactly at both limits (accepted).
4. **Clamp before the cast:** `qint64(end.toDouble())` in `SoundThemeCheck.cpp` clamps first; fixture with a granule position that overflows.
5. **One copy of the ambient file:** the 1.1 MB resource that duplicates `/usr/share/ruyaos/sounds/dreamglass/ambient.flac` in the binary is shipped once (for instance the resource only in non-Linux builds, since `SoundThemes` reads the installed folder on Linux; pick the smaller change). Check `ruya-shell` size before/after in the Outcome.
6. **Toast language:** the Storage "Drive inserted" toast is translated in the Turkish screenshot (it is English there today).

## Out of scope
- A separate Start-up sound switch and the cues' loudness and character (the owner decides by listening: Dell look-at list), WirePlumber role ducking, importing a theme from the network.

## Acceptance criteria
- [ ] `tst_sound_ui.qml::test_delete_saved_theme` (row exists only for a saved theme, confirm, the list shrinks, active falls back) and `::test_bundled_theme_has_no_delete`.
- [ ] `tst_sounds.qml`: `test_refusal_message_names_the_problem` (three problems, en and tr), `test_import_at_the_limits`, `test_import_over_the_limits`, and a fixture `bad-granule-overflow` ending in "refused" (each red when its guard is removed; revert checks via `scripts\revert-check.ps1` noted).
- [ ] The Outcome states the binary size change for Scope 5 and the checker lint (`scripts\lint-sound-themes.ps1`) passes.
- [ ] Turkish screenshot of Settings > Audio and the Drive-inserted toast reviewed.
- [ ] UX: from every new state Back leaves; focus lands on the Sound theme row after a delete; readable at 10 ft; Outcome has a `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- 02 §5.3, `docs/developers/sound-themes.md` (limits, delete, the Windows directory-junction note below).

## Hints
- A directory junction passes the checker on Windows only (Linux resolves it as a symlink and refuses): state that in the developer doc; no code needed.
- The VM-side checks of the sound files (symlink escape, probe) are in T-296.

## Outcome
Verified: host (vm pending: `scripts/vm-sounds-check.sh`, new line "no second copy of the bundled theme in the binary", on the next image)

**Built**
- **Delete (Scope 1).** `SoundThemes.removeTheme(id)` (only `user:<folder>` copies that exist; never the bundled theme, a drive theme or an id with a path; a symlinked copy loses only the link; refuses while a copy is being written; the chosen copy falls back to the bundled theme first, so its files are let go). `AudioPane`: the row **Delete "Name"** (`rowDeleteSoundTheme`) sits under the Sound theme row and is visible only while the chosen theme is a copy; Accept opens `PowerConfirm` (Cancel focused, B/Back cancels), Confirm resets `DeviceSettings.soundTheme` to Dreamglass, deletes the folder, plays no cue of its own and shows no toast, and puts focus on the Sound theme row. The 8-copies toast reads "... Delete one first, or copy over one with the same name to replace it." `SettingsPage` passes `overlay` to the pane.
- **Refusal message (Scope 2).** New singleton `SoundThemeText.qml` (`describe(problems)`: the checker's first problem as one plain line, en and tr, no path or file name; the last line, "Something in the theme is not right", is the fallback). A drive folder the checker refuses now has a row "Can't use "Name"" whose value is that line (Accept repeats it as a toast), and `importFinished(status, id, problems)` carries the checker's list, so a copy refused after copying says it in its toast. `driveProblems` entries gained `id` and `problems`. A test runs every refused fixture through `describe` and fails on the fallback line.
- **Import bounds (Scope 3).** A copy over a limit now ends with its own status, `too-many-files` or `too-large` (it was `io`), each with its own toast ("That sound theme has more than 100 files." / "... is larger than 12 MB."); the limits are `SoundThemes::MaxCopyFiles` / `MaxCopyMb` (properties `maxCopyFiles`, `maxCopyMb`). Test hook `mockAddDriveTheme(folder, files, bytes)` writes a theme of exactly that many files and bytes on the mock stick.
- **Clamp (Scope 4).** `clampedMs()` in `SoundThemeCheck.cpp` clamps a manifest number to +-10^15 ms (NaN to 0) before `qint64()`. Fixtures `bad-granule-overflow` (an Ogg granule of 2^63-1, refused by the existing granule guard) and `bad-loop-overflow` (a loop end of 1e300; the message shows the clamped 1000000000000000, where the unclamped cast gives -9223372036854775808, so the test sees the clamp).
- **One copy (Scope 5).** CMake option `RUYA_SOUNDS_RESOURCE`: ON by default, OFF by default when `RUYA_COMPOSITOR` is ON (the image build), so `image/Containerfile` is unchanged. The theme resource is added with `qt_target_qml_sources(... RESOURCES ...)` only when ON. `ruya-shell.exe` (Windows, Release): **9,052,160 B with the resource, 7,926,272 B without** (-1,125,888 B, 1.07 MiB; the option flipped in my build tree and flipped back). On the OFF build `--check-sound-theme :/qt/qml/RuyaShell/sounds/dreamglass` exits 1 ("the folder does not exist"); on the ON build it exits 0, so the new VM check is not vacuous. **Not run on Linux:** the image build itself (the VM queue). A Linux build without `RUYA_COMPOSITOR` keeps the resource, so CI's tests still find the bundled theme.
- **Toast language (Scope 6).** The "Drive inserted" toast keeps the language it was written in (PATTERNS: stored text does not re-translate). The Turkish shot is now its own test (`test_zz_screenshots_tr`): the language is chosen first and the stick plugged after, so the toast on the shot is Turkish (asserted on screen). No product change.
- **Layout fix found on the way.** With rows coming and going, the pane's Column stayed unlaid in a real window (a one-row viewport on a first shot, the focused row off screen on others): `afterDriveSync` now calls `pane.reflow()`, as `SettingsPane` documents.

**Revert checks** (`scripts/revert-check.ps1 -Test`, each rebuilt and restored; all CAUGHT): `++files > MaxCopyFiles` to `>=` and `bytes > MaxCopyBytes` to `>=` (`test_import_at_the_limits`); each of the two guards replaced by a huge limit (`test_import_over_the_limits`); `qint64(qBound(...))` to `qint64(value)` and `granule > rate * 86400` to `false` (`bad-loop-overflow` and `bad-granule-overflow` in `test_every_fixture_ends_as_expected` and `test_granule_and_loop_numbers_that_do_not_fit`); the loud-cue pattern of `SoundThemeText` broken (`test_refusal_message_names_the_problem`, `test_every_refused_fixture_gets_a_specific_message`); `visible: pane.savedTheme !== undefined` to `true` (`test_bundled_theme_has_no_delete`, `test_delete_saved_theme`); the setting reset on delete removed (`test_delete_saved_theme`); the refused row's value emptied (`test_a_refused_drive_theme_says_why`); "Delete one first" removed from the limit text (`test_a_theme_over_the_limits_says_how`). `scripts/lint-sound-themes.ps1` passes inside `dev.ps1 test`.

**Tests added:** `tst_sound_ui.qml::test_delete_saved_theme`, `::test_bundled_theme_has_no_delete`, `::test_a_refused_drive_theme_says_why`, `::test_a_theme_over_the_limits_says_how`, `::test_deleting_a_copy_that_is_not_chosen_leaves_the_choice_alone`; `tst_sounds.qml::test_refusal_message_names_the_problem` (three problems, en and tr), `::test_every_refused_fixture_gets_a_specific_message`, `::test_import_at_the_limits` (exactly 100 files and 12 MB), `::test_import_over_the_limits` (101 files; 12 MB + 1 byte), `::test_only_a_copy_can_be_removed`, `::test_granule_and_loop_numbers_that_do_not_fit`; fixtures `bad-granule-overflow`, `bad-loop-overflow`. Found while writing them: an entry taken from `SoundThemes.themes` with `find` reads from the list again later, so tests keep the `path` string, not the entry.

UX notes: states reached: Settings -> Audio with a copy chosen (Delete row under the Sound theme row, focus ring on it); the Delete confirmation (Cancel focused first, Right reaches the red button, B/Back cancels and focus returns to the Delete row); after Confirm (the row is gone, the choice shows Dreamglass, focus is on the Sound theme row, no toast, no extra cue); a refused drive folder ("Can't use "Broken"" with the reason as its value, Accept toasts it, focus stays); a theme over 100 files or 12 MB (a toast naming the limit). Back leaves each of them (the confirmation cancels; in the pane Back goes to the category list, tested). Doubts: the reason is the row's right-hand value, which `SettingRow` does not elide; the lines are at most about 45 characters and the folder name in the label is cut at 24, and the shots show it fits in en and tr at 1920x1080 (same type size as every row), but a longer Turkish line could crowd the label. Shots read in `output/shell-shots/review/`: `sound-settings-en.png`, `sound-settings-tr.png`, `sound-delete-row-en.png`, `sound-delete-confirm-en.png`.

**Deviations:** (1) Scope 3 asked for fixtures; the limit themes are written by a test hook on the mock stick (`mockAddDriveTheme`), not as `fixtureCases`, because they pass the checker (the limits belong to the copy, not to the checker) and `scripts/lint-sound-themes.ps1` expects every fixture to match its verdict. (2) The detail line of the confirmation is one short sentence ("You can copy it again from a USB drive."): a longer one ran past the dialog card in the shot. (3) Scope 1 says "for the selected saved theme": the row names the chosen theme (the choice row's value), the only one a player sees selected; a copy that is not chosen is deleted by choosing it first.

**Files:** `shell/src/sound/SoundThemes.h`, `SoundThemes.cpp`, `SoundThemeCheck.cpp`; `shell/qml/AudioPane.qml`, `SettingsPage.qml`, `SoundThemeText.qml` (new); `shell/CMakeLists.txt`; `shell/i18n/ruyashell_en.ts`, `ruyashell_tr.ts`; `shell/tests/tst_sounds.qml`, `tst_sound_ui.qml`; `scripts/vm-sounds-check.sh`; `docs/specs/02-shell.md` (5.3), `docs/specs/04-design-system.md` (component row), `docs/developers/sound-themes.md` (limits, delete, refusal, the Windows junction note).
