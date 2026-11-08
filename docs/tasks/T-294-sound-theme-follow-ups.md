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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
