# T-346 - Sound theme checker: cap the decode work, fuzz the decoder's inner paths, FLAC fixtures from real encoders

Status: todo · Phase: 2 · Depends: T-330 · Area: shell (SoundThemeCheck, SoundThemes, tests/fixtures) · Size: S · Owner: builder

## Goal
Review findings of T-330 (APPROVE with notes): the bed checker has its own bounded FLAC decoder. It is hostile-file safe, but (1) a crafted file that still passes costs about 1.35 s per check here (several seconds on the console CPU) and `SoundThemes::reload()` runs the check on the GUI thread, (2) the in-tree fuzz mutates the first 128 bytes, so almost every mutation fails a CRC and the decoder's inner paths are never reached in `test`, (3) the `makeFlac` fixture writes only FIXED order-2 Rice, so LPC, VERBATIM, CONSTANT, wasted bits and escaped residuals (what flac and ffmpeg write) have no fixture.

## Read first
- `docs/tasks/T-330-ambient-bed-must-be-audible-on-small-speakers.md` Outcome; `shell/src/sound/SoundThemeCheck.cpp` (`MaxDecodedMs`, the decoder, `makeFlac` lives in the test), `shell/src/sound/SoundThemes.cpp` (`reload()`), `shell/tests/` sound theme tests and fuzz, `docs/developers/sound-themes.md`.
- `shell/CLAUDE.md` (threading, test rules), `docs/specs/02-shell.md` sound themes paragraph.

## Scope
1. **Cap the work:** a budget on decoded samples times predictor order (or a decode window of loop start + 60 s) so the worst accepted file costs well under 200 ms here; a file over the budget is refused with a clear reason ("bed too long to check"), shown the way other refusals are. Keep `MaxDecodedMs` behaviour for the loop length rule unless the cap replaces it; say which in the Outcome.
2. **Checker off the GUI thread** only if the cap alone leaves a check above ~100 ms for a shipped or realistic file; otherwise leave it and say so.
3. **Fuzz that reaches the decoder:** a test generator that writes random but valid FLAC frames (all subframe types, LPC precision and shift, escapes, wasted bits, odd partition orders, mid/side channels) with CRC-8/CRC-16 recomputed, run in `test` with a fixed seed and a case count that keeps the file under ~3 s; every case ends with a verdict, never a hang or crash.
4. **Fixtures:** `makeFlac` (or a new helper) writes LPC, VERBATIM, CONSTANT, wasted bits and escaped residuals, and a small checked-in ffmpeg-encoded fixture (a 1 s tone made for this project) decodes to the expected level.
5. Reject a frame-number lead byte `0xFF` (invalid UTF-8-style number) instead of reading 7 bytes.

## Out of scope
- Ogg/Vorbis/Opus bed measurement (needs a decoder: owner or planning call), changing the level or band rules.

## Acceptance criteria
- [ ] `tst_sound_theme_check` (or the existing test file): `test_a_file_over_the_work_budget_is_refused` (revert: raise the budget, red), `test_worst_accepted_bed_checks_fast` (assert on the counted work, not wall time), `test_every_predictor_kind_decodes_to_the_same_audio` (FIXED, LPC, VERBATIM, CONSTANT, wasted bits, escapes), `test_ffmpeg_encoded_fixture_has_the_expected_level`, `test_valid_frame_fuzz_always_gets_a_verdict`, `test_frame_number_lead_byte_ff_is_refused`.
- [ ] The shipped beds still pass; `make-sounds.py --verify` green; no existing test weakened.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/developers/sound-themes.md` (the work budget and its refusal text), `docs/specs/02-shell.md`.

## Hints
- Count work in the decoder (samples x order) rather than timing it, so the test is deterministic.
- Overlaps T-344 (`AudioPane` delete) only in `SoundThemes.cpp`: sequence by the board.

## Outcome
_Filled in by the implementer._
