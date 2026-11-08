# Dreamglass

The sound theme RuyaOS ships. Soft glassy bells for the interface cues and a slow pad for the
ambient bed behind Home and the menus. Made by `scripts/make-sounds.py` from numbers alone (sine
partials, no recordings, no samples from anywhere else), so it is our own work: **CC0 1.0** (public
domain dedication, https://creativecommons.org/publicdomain/zero/1.0/). Do what you like with it.

- `theme.json`: the manifest (cue names to files, the ambient loop).
- `*.wav`: the cues, mono 16-bit 48 kHz, each under 1.5 s.
- `ambient.flac`: the pad, mono 24 kHz, a loop of about 75 s.

To change it, edit the numbers at the top of the script and run it with `--out <folder>`. How to
make a theme of your own is in docs/developers/sound-themes.md.
