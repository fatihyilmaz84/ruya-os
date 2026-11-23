# Hello Play Wine

The Windows sample of the [`.play` developer guide](../../docs/developers/play-packages.md): a small Windows program, cross-compiled on Linux and packaged to run on the **OS's GE-Proton**. It is the smallest package that shows a Windows runner, a saves path inside the Wine prefix and a first-run setup step.

| What it shows | Where |
|---|---|
| A Proton component from the OS (GE-Proton, the image's Windows runner), `source: system`, with `min` and `tested` | `components[]` in `package/play.json` |
| `run.runner: proton` and a `.exe` as the command | `run` |
| A prefix without a template (`arch`, `epoch`) | `run.prefix` |
| A saves folder inside the prefix, listed for backup | `data.saves`: `prefix:drive_c/users/steamuser/Documents/Hello Play` |
| A first-run setup step that does nothing | `run.setup[]` runs `setup.exe` once per prefix |
| A folder the game writes into next to its programs, as Unreal Tournament does with its ini (*experimental*, ADR-040) | `run.writable: ["Program"]`; the programs run from `${game}/Program`, and `data.saves` lists `game:Program/beside.txt` |
| A 32-bit command-line program for the console's VM check | `src/check.c`, built as `check.exe`; not run by the manifest, see below |
| Art that passes the console's vetting | `package/art/`, made by `make-art.py` |

`source: system` is on purpose: `newest` and `prefer-system` need a bundled runner, which would put a large program in git. The guide shows a `newest` manifest with a bundled Wine as a text example. The image ships GE-Proton only (a plain Wine arrives with RUY-37), so the component is `type: proton`; `min` is a GE-Proton release the pinned one satisfies, and a test (`services/ruya-pack/tests/samples.rs`) reads the pinned version from `image/play/runners/ProtonGE11/runner.json`.

## Layout

```
package/            what is committed
  play.json
  art/icon.png, art/hero.png
package/payload/    NOT committed: build.sh puts Program/hello.exe, setup.exe, check.exe and check.ini here
src/hello.c         the game: a window, a square, a step counter saved to Documents\Hello Play\save.txt
src/setup.c         the no-op setup step
src/check.c         check.exe: a 32-bit console program that counts its launches in Documents\Hello Play\check.txt
                    and in beside.txt next to itself, and reads check.ini there
build.sh            cross-compile, then build the zip with ruya-pack
make-art.py         draws the two PNGs
```

No binary is committed. The tests (`services/ruya-pack/tests/samples.rs`) copy `package/` to a scratch folder, write stand-in files for the three programs and run `ruya-pack build`, `validate` (with `--system-proton-ge`, the version the image ships) and `inspect`, so they need no compiler.

## Build

On Linux with the MinGW-w64 cross compilers for 64 and 32 bit (Fedora: `sudo dnf install mingw64-gcc mingw32-gcc`) and `ruya-pack` on the PATH:

```sh
./build.sh                  # cross-compiles package/payload/*.exe, then builds hello-play-wine.play.zip
./build.sh --payload-only   # cross-compile only
```

Sign it with your own key before you give it to anyone (`ruya-pack keygen`, `ruya-pack sign`; never commit a key). To check the runner choice against a GE-Proton version: `ruya-pack validate hello-play-wine.play.zip --system-proton-ge GE-Proton11-13`.

CI compiles the three programs and builds and inspects the zip on every push (`scripts/ci-samples-linux.sh`).

## The VM check

`hello.exe` waits for the arrow keys, which a headless machine cannot press, so the console's VM check (`scripts/vm-play-check.sh launch-windows`, RUY-902) installs a copy of this package whose command is `check.exe` and which also asks for `"multiarch": true` (32-bit code needs it; the sample itself is 64-bit and asks for nothing more). `check.exe` writes `Documents\Hello Play\check.txt` (`launches`, `pointer_bits`, `wow64`, `network`, `module`, `edition`, `beside`), exits `0` and is started a second time to show the save in the prefix survived. The check runs offline and expects `launches=1`, `pointer_bits=32`, `wow64=1`, `network=closed`, then `launches=2`.

`Program/` is the package's `run.writable` folder (RUY-1019): the console gives each profile its own copy of it, so `check.exe` reads `check.ini` and writes `beside.txt` next to itself, the way a Windows game keeps its ini in its install folder. `module` is the path `GetModuleFileNameW` gives (it must be in the profile's game tree, not the read-only `/app/payload`), `edition` the number in `check.ini` and `beside` the count `check.exe` wrote to `beside.txt`. The check then installs the next build of the package with `check.ini` changed and starts it a third time: `edition=2` (the file the game never changed was replaced) and `beside=3` (what the game wrote was kept). It is written and tested on the host; the run on a console is pending. The `steamuser` folder in `data.saves` is the user name the Proton-style runners use; that run confirms it.

## Licence

CC0 1.0 (public domain, SPDX `CC0-1.0`); see `LICENSE`.
