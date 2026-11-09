# T-357 — Headphone virtual surround: a licence-clean HRTF through PipeWire

Status: todo · Phase: 4 · Depends: T-322 · Area: services (ruya-devices audio), api (Devices1), shell (Settings > Audio), image · Size: M · Owner: lead · Developer surface: none

## Goal
A player with ordinary stereo headphones hears games in surround: 5.1/7.1 game audio is rendered binaurally through an HRTF, the way consoles offer "3D audio for headphones". Owner pointer, 2026-11-09: the HRTF Database (Airtable, about 1,745 HRIR sets, https://airtable.com/appayGNkn3nSuXkaz/shruimhjdSakUPg2m/tbloLjoZKWJDnLtTc), which lists each set with its format (HeSuVi WAV, OpenAL Soft `.mhr`, X3DAudio), source and credits. This is the "headphone virtual surround" phase B of T-219, split out.

## What the database is good for (lead, 2026-11-09)
- **Usable after a licence check:** the research measurements it catalogues (MIT KEMAR, SADIE II, CIPIC, ARI, HUTUBS, IRCAM Listen, 3D3A, TU Berlin, ...), published by universities, mostly as SOFA files under open terms.
- **Never shipped:** the captures of commercial virtualisers (Dolby Atmos for Headphones, DTS Headphone:X, Windows Sonic, Razer Surround, CMSS-3D, SBX, Waves Nx, Out Of Your Head, ...): recordings of proprietary products, and their names are trademarks (see T-219's licensing note). They are not offered for download from RuyaOS either.

## Scope
1. **Pick the data (lead, then owner):** two or three candidate sets with their exact licence text, size and a listening note; the owner approves the one we ship (a licence decision: a Proposed line under "Open owner decisions" until then). Ship it under `/usr/share/ruyaos/hrtf/` with its notice in About (like the fonts).
2. **Render it:** a PipeWire `filter-chain` virtual sink (builtin `convolver` with the set as a 7.1 to stereo HRIR, or the SOFA `spatializer` if Fedora's PipeWire has libmysofa) in front of the chosen headphone output; apps see a 7.1 sink. Latency and CPU measured on the Dell (target: under 5 % of one core, no audible delay).
3. **Contract and setting:** `Devices1.Audio` gets a per-output "Headphone surround" on/off (only for headphone-kind outputs, T-322's `kind`), persisted like the saved output; mock, D-Bus client, service and tests agree.
4. **Shell:** a `ToggleRow` "3D audio for headphones" under Settings > Audio for a headphone output, with a short line that it works with games that output surround.

## Out of scope
- Personal HRTF measurement, head tracking, the commercial captures above, speaker virtualisation (crosstalk cancellation), Atmos/DTS:X object audio.

## Acceptance criteria
- [ ] Rust tests: the filter-chain config generated for 5.1 and 7.1, the setting only on headphone outputs, persistence and the late-reply guard.
- [ ] `tst_audio*.qml` (mock): the row appears only for a headphone output, toggles, focus asserted; screenshots (English and Turkish).
- [ ] VM (lead run): `vm-audio-check.sh` section T-357: the virtual sink exists with 8 channels when on, is gone when off, survives a PipeWire restart.
- [ ] Hardware (the Dell, headphones): a 7.1 test file (the database's "7.1 clips") places each channel audibly; CPU and latency recorded. Needs B-007 for games to reach it.
- [ ] The chosen set's licence approved by the owner and its notice in About; `.\scripts\dev.ps1 test` ALL GREEN.

## Hints
- STK uses OpenAL Soft, which has its own HRTF (`.mhr`); with our sink, games should output surround to it and keep their own HRTF off (document in `docs/developers/` audio).
- T-219 (formats, channel layout) and T-347 (card profiles) touch the same Audio area: do not run them in parallel.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
