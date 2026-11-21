# Hello Runner

The sample of the developer guide's chapter [Windows games](../../docs/developers/windows-games.md): a Flatpak that uses **the console's own GE-Proton** to run a Windows program, with no Wine of its own and no RuyaOS D-Bus call. It is what a launcher (a Heroic-like app) does, reduced to the part that matters. It is meant to be copied. It is **experimental** (tier C): the extension ids and `runner.json` format 1 may change before the first release.

| What the chapter asks | Where it is here |
|---|---|
| Declare the console's runner extension point, so every runner it has is mounted under `/app/runners/<Name>` | `add-extensions` in `org.ruyaos.HelloRunner.json` |
| The permissions a Proton game needs (X11, graphics, sound, 32-bit programs) | `finish-args` in the manifest |
| Read `runner.json` of each runner instead of guessing a path, skip what you did not test, take the newest | `read_runner`, `pick_runner` in `run-windows.py` |
| Start the program the way the console's own launcher does: `<proton> waitforexitandrun <exe>` with `STEAM_COMPAT_DATA_PATH` and `STEAM_COMPAT_CLIENT_INSTALL_PATH` in your data folder (one prefix per profile), `SteamAppId` and `SteamGameId` set to `0`, and `PWD` | `proton_environment`, `main` |

It is a command-line check, not a game: it has no desktop entry, so it is not listed in the Games row.

## Layout

```
org.ruyaos.HelloRunner.json   the Flatpak manifest
run-windows.py                installed as /app/bin/hello-runner
test_run_windows.py           its logic on the host; `make test` (no Wine, Proton or Flatpak needed)
Makefile                      `make test`
```

No Windows program is committed. `--self-test` runs the runner's own `cmd.exe` (`echo`, into a file it reads back), so the sample needs nothing but a console that has the runner and an X display: Proton gives every program a console window, which Wine cannot open without one. Without `DISPLAY` the script says so and stops.

## Build and run

On a build machine with `flatpak` and `flatpak-builder` (see the guide's [Getting started](../../docs/developers/getting-started.md)), in this folder (no desktop entry or AppStream file is needed: it is not a game):

```sh
flatpak-builder --force-clean --user --install-deps-from=flathub --repo=repo build-dir org.ruyaos.HelloRunner.json
flatpak --user remote-add --if-not-exists --no-gpg-verify hello-local repo
flatpak --user install -y hello-local org.ruyaos.HelloRunner
```

The runner exists only on a RuyaOS console: copy `repo` there and install it with `flatpak install --system` as [Hello Game](../hello-game/README.md) shows, then:

```sh
flatpak run org.ruyaos.HelloRunner --self-test         # (needs a display) should print which runner it took, then RUYA_HELLO_RUNNER_OK
cp game.exe ~/.var/app/org.ruyaos.HelloRunner/data/    # the sandbox reads its own data folder; the manifest grants no --filesystem
flatpak run org.ruyaos.HelloRunner ~/.var/app/org.ruyaos.HelloRunner/data/game.exe
```

**Not run yet:** the build and these runs wait for the VM check. Off a console, `python3 run-windows.py --runners DIR --self-test` reads the runners from any folder `DIR` (this is how the tests work, with made-up runner folders; `make test`).

`MAX_MAJOR` in `run-windows.py` is the newest GE-Proton major you tested: raise it after you test a newer one.

The first start creates the prefix at `~/.var/app/org.ruyaos.HelloRunner/data/proton/pfx` (one per profile). The `scripts/vm-runner-check.sh sample` check runs `run-windows.py` against the image's runners as a profile user without network; the lead runs it on an image.

## Licence

CC0 1.0 (public domain, SPDX `CC0-1.0`): copy any file, change it, ship it, no attribution needed. See `LICENSE`.
