# Hello Runner

The sample of the developer guide's chapter [Windows games](../../docs/developers/windows-games.md): a Flatpak that uses **the console's own GE-Proton** to run a Windows program, with no Wine of its own and no RuyaOS D-Bus call. It is what a launcher (a Heroic-like app) does, reduced to the part that matters. It is meant to be copied. It is **experimental** (tier C): the extension ids and `runner.json` format 1 may change before the first release.

| What the chapter asks | Where it is here |
|---|---|
| Declare the console's runner extension point, so every runner it has is mounted under `/app/runners/<Name>` | `add-extensions` in `org.ruyaos.HelloRunner.json` |
| The permissions a Proton game needs (X11, graphics, sound, 32-bit programs) | `finish-args` in the manifest |
| Read `runner.json` of each runner instead of guessing a path, skip what you did not test, take the newest | `read_runner`, `pick_runner` in `run-windows.py` |
| Start the program the way the console's own launcher does: `<proton> waitforexitandrun <exe>` with `STEAM_COMPAT_DATA_PATH` and `STEAM_COMPAT_CLIENT_INSTALL_PATH` in your data folder (one prefix per profile) | `proton_environment`, `main` |

It is a command-line check, not a game: it has no desktop entry, so it is not listed in the Games row.

## Layout

```
org.ruyaos.HelloRunner.json   the Flatpak manifest
run-windows.py                installed as /app/bin/hello-runner
test_run_windows.py           its logic on the host; `make test` (no Wine, Proton or Flatpak needed)
Makefile                      `make test`
```

No Windows program is committed. `--self-test` runs the runner's own `cmd.exe` (`echo`), so the sample needs nothing but a console that has the runner.

## Build and run

Build it like [Hello Game](../hello-game/README.md) (`flatpak-builder`, then install the repository), then on a RuyaOS machine:

```sh
flatpak run org.ruyaos.HelloRunner --self-test         # prints which runner it took, then RUYA_HELLO_RUNNER_OK
flatpak run org.ruyaos.HelloRunner /path/to/game.exe   # a program you made available to the sandbox
```

The first start creates the prefix at `~/.var/app/org.ruyaos.HelloRunner/data/proton/pfx` (one per profile). The `scripts/vm-runner-check.sh sample` check runs `run-windows.py` against the image's runners as a profile user without network; the lead runs it on an image.

## Licence

CC0 1.0 (public domain, SPDX `CC0-1.0`): copy any file, change it, ship it, no attribution needed. See `LICENSE`.
