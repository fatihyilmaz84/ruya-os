# Sound themes: make the console sound like your own

RuyaOS plays short cues for what you do in the shell (moving, selecting, going back, a toast, a wrong PIN) and a quiet ambient bed behind Home and the menus. All of it comes from a **sound theme**: a folder with a manifest and some audio files. The console ships one, **Dreamglass** (soft glassy bells and a slow pad, CC0). Anyone can make another one and put it on a USB drive. This chapter says what a theme is, the limits, how to try yours, and how the shipped one is made so you can start from it.

Themes are for the **console's own interface sounds**. They do not change what a game plays, and nothing in a theme can run code: the console reads the folder as data only.

## A theme folder

```text
my-theme/
  theme.json      the manifest (required)
  README.md       who made it and under which licence
  select.wav      one file per cue you want to change
  back.wav
  ambient.ogg     the ambient loop (optional)
```

`theme.json`:

```json
{
  "name": "My theme",
  "author": "Your name",
  "licence": "CC0-1.0",
  "version": "1.0.0",
  "cues": {
    "navigate": "navigate.wav",
    "select": "select.wav",
    "back": "back.wav"
  },
  "ambient": {
    "file": "ambient.ogg",
    "loop": { "start": 0, "end": 60000 },
    "gain": 0.7
  }
}
```

| Key | Rule |
|---|---|
| `name` | 1 to 48 characters; shown in Settings -> Audio -> Sound theme |
| `author` | 1 to 80 characters |
| `licence` | an [SPDX](https://spdx.org/licenses/) identifier such as `CC0-1.0`, `CC-BY-4.0`, `MIT`; the licence of the audio. Share only sounds you are allowed to share: do not ship samples from games, films or other people's music |
| `version` | `1.0.0` style |
| `cues` | cue name to file name; a path inside the theme folder (`sounds/ok.wav` is fine, `../x.wav`, absolute paths and links are refused) |
| `ambient` | optional; `file`, an optional `loop` (`start` and `end` in milliseconds, inside the file; omitted: the whole file), an optional `gain` from 0 to 1 (default 1) |

## The cues

The names are fixed; a theme supplies the files.

| Cue | When it plays |
|---|---|
| `navigate` | focus moves (a quiet tick; it plays a lot) |
| `select` | Accept on a row, a button, a tile |
| `back` | Back |
| `error` | a wrong PIN, a refused action |
| `notification` | a toast appears |
| `warning` | a warning or error toast, a toast that stays until it is dealt with |
| `open` | the Guide overlay opens |
| `close` | the Guide overlay closes |
| `page` | a section changes (Home, Games, Store, Settings, ...) |
| `volume` | the volume bar changes (one tick per change) |
| `startup` | once, when the console's shell first appears |
| `toggle-on` | a switch goes on |
| `toggle-off` | a switch goes off |

A cue your theme does not name plays from the bundled theme, so a theme may change only some. A name that is not in this list is ignored with a warning.

No cue is ever the only signal: every cue has something on screen next to it (a focus ring, a toast, a message). The player's **UI sounds** level (Settings -> Audio) scales every cue, and at 0 they are silent. Reduced motion does not silence them. No cue plays while the screen saver or a dark screen is up.

## Limits

The console checks these before it uses a theme, and ignores a theme that breaks one (it writes a line to the log and plays the bundled theme; it never stops booting for a theme).

- **Cues:** WAV, PCM 16-bit, mono or stereo, **48 kHz**, at most **1.5 s** and **200 KB** each, **peak below -3 dBFS** (0.708 of full scale). Start and end on silence: a cue that ends on a step clicks.
- **Ambient:** Ogg Vorbis, Ogg Opus or FLAC (`.ogg`, `.opus`, `.flac`), mono or stereo, 8 to 96 kHz, at most **3 MB**, a loop of at least **5 s**. The loop must lie inside the file. A FLAC file's frames must name their sample rate (the `flac` tool and `ffmpeg` always do; a frame that says "the rate is in the header" plays as silence on the console and is refused). Aim for a minute or more so that the repeat is not noticed.
- `theme.json` at most 64 KB; at most 64 cue entries; text fields as in the table.
- **Copying:** a theme folder may hold at most **100 files** and **12 MB** in all (every regular file counts, also the ones the manifest does not name). Exactly 100 files and exactly 12 MB are accepted; one more of either is refused and the console says which ("That sound theme has more than 100 files." / "... is larger than 12 MB."). Links are not copied.
- Numbers in `theme.json` (the loop's `start` and `end`) are read as milliseconds up to 10^15; a larger one is treated as 10^15 and the loop is then "not inside the file".

Loudness: the console plays a cue at the player's UI level and the ambient at the player's Ambient level times your `gain`. Master your cues for a living room, not for headphones: short, soft, low in the mix. Test them at low volume on a TV.

## The ambient loop

The ambient plays on Home and the menus. It fades out over 800 ms when a game is in front or the screen saver starts, and back in when the player returns, and it is lowered by about 8 dB under every cue so the cues stay clear. It is never played on top of a game.

Make the loop **seamless**. The console plays two copies and cross-fades them for 1.5 s at the loop end, which hides small differences, but a loop whose end does not match its start in tone still wobbles. The easiest way is to build the loop from sines and slow level changes that each take a whole number of cycles over the length of the loop, as the generator below does. If you edit a recording, loop it and cross-fade it in your editor first.

## Trying a theme

On a RuyaOS console or a dev machine:

1. Copy your folder to a USB drive as `RuyaOS/sounds/<folder>/` (so `RuyaOS/sounds/my-theme/theme.json`). The folder name uses letters, digits, `.`, `_` and `-`.
2. Put the drive in. Open **Settings -> Audio**. Under the **Sound theme** row a row "Use "My theme" from the USB drive" appears for every valid theme on the drive. A theme that fails a check is not listed (the shell's log says why: the journal on the console, the terminal in the dev build).
3. Press Accept on that row. The console **copies** the theme to its own data directory and switches to it, so it keeps working when you take the drive out. Nothing is ever loaded from the drive in place.
   A theme the checks refuse gets a row of its own, "Can't use "My theme"", that says in one plain line what is wrong ("A cue is louder than allowed", "The ambient loop does not fit the file", ...); the shell's log has the exact reason, with the file.
4. Use the **Sound theme** row to switch between the bundled theme and the copies. The console keeps at most 8 copies. To delete one, choose it in the **Sound theme** row and press Accept on the row **Delete "My theme"** just under it; the bundled theme cannot be deleted, and a deleted theme is offered again from the drive while it is still plugged in.

In the Windows dev build (`.\scripts\dev.ps1 run`) the mock USB stick has no real folder. Put your theme folder inside a folder of your choice, start the shell with the environment variable `RUYA_SOUND_DIR` set to that folder, and the theme is listed in the **Sound theme** row like a copy. The quicker check is the checker itself:

```powershell
.\shell\build-win\Release\ruya-shell.exe --check-sound-theme path\to\my-theme
```

It prints `ok` or the reasons, with the exit code 0 or 1. It is the same function the console uses.

On Windows only: a directory junction (`mklink /J`) inside a theme folder passes the checker (Windows does not report it as a link), while on the console, which is Linux, the same folder is a symlink and is refused (`'...' is a link`). Make a theme from plain files and check it on the console before you share it.

## How Dreamglass is made, and how to start from it

Dreamglass is generated by one script from numbers: sine partials with a short rounded attack and an exponential tail for the bells, a few detuned sine layers whose levels drift slowly for the pad. No recording and no sample from anywhere else is used, which is why it can be CC0.

```sh
python -I scripts/make-sounds.py                  # rewrites shell/sounds/dreamglass and the example theme
python -I scripts/make-sounds.py --out my-theme   # writes a copy of Dreamglass to start from
python -I scripts/make-sounds.py --verify         # determinism, limits, seams, files up to date
```

You need Python 3 with numpy. At the top of `scripts/make-sounds.py` the `CUES` table holds, for each cue, the loudest sample it may reach, the partials of a note (ratio to the pitch, level, how long it rings) and the notes (start time, pitch in Hz, length, level); a cue made of a sweep gives its start and end pitch. `PAD` is the chord of the ambient with the rate at which each layer swells. Change the numbers and run it with `--out`. The ambient is written as FLAC by a small encoder inside the script, because numpy has no Ogg Vorbis encoder; if you have `oggenc` or `ffmpeg` you can encode the pad as `.ogg` yourself and name it in `theme.json`.

The script is deterministic: two runs give the same bytes, and `--verify` (part of `dev.ps1 test`) fails if the files in the repository are not what the script writes.

An example theme, as small as a theme can be (a short tone per cue and an 8 s ambient), is in [`samples/sound-theme-example/`](../../samples/sound-theme-example/theme.json). It passes the checker; copy it and replace the files.

## Checklist

- [ ] `theme.json` has name, author, an SPDX licence, version and the cues you change.
- [ ] You made the sounds yourself or the licence lets you share them; the licence is in `theme.json` and the README.
- [ ] Every cue is under 1.5 s and 200 KB, 48 kHz, peaks below -3 dBFS, and starts and ends on silence.
- [ ] The ambient (if any) is at most 3 MB, loops without a bump, and sounds fine under a cue.
- [ ] `ruya-shell --check-sound-theme <folder>` says `ok`.
- [ ] You listened on a TV at low volume.

## Sources

Checked on 2026-11-08 against: `docs/specs/02-shell.md` sections 5 and 5.3 (channels, ducking, the theme format); `shell/src/sound/SoundThemeCheck.cpp` (the limits and the cue names) and `SoundThemes.cpp` (where themes are looked for and copied); `shell/qml/Sfx.qml` and `AmbientLoop.qml`; `scripts/make-sounds.py` and `scripts/lint-sound-themes.ps1`; `samples/sound-theme-example/`. Not tried on a console with audio output: the cue levels and the loop's cross-fade are checked by properties and by the generator, not by ear (owner listening pending).
