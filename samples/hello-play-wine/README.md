# Hello Play Wine

The Windows sample of the [`.play` developer guide](../../docs/developers/play-packages.md): a small Windows program, cross-compiled on Linux and packaged to run on the **OS's Wine**. It is the smallest package that shows a Windows runner, a saves path inside the Wine prefix and a first-run setup step.

| What it shows | Where |
|---|---|
| A Wine component from the OS, `source: system`, with `min` and `tested` | `components[]` in `package/play.json` |
| `run.runner: wine` and a `.exe` as the command | `run` |
| A prefix without a template (`arch`, `epoch`) | `run.prefix` |
| A saves folder inside the prefix, listed for backup | `data.saves`: `prefix:drive_c/users/steamuser/Documents/Hello Play` |
| A first-run setup step that does nothing | `run.setup[]` runs `setup.exe` once per prefix |
| Art that passes the console's vetting | `package/art/`, made by `make-art.py` |

`source: system` is on purpose: `newest` and `prefer-system` need a bundled Wine, which would put a large LGPL program in git. The guide shows a `newest` manifest with a bundled Wine as a text example.

## Layout

```
package/            what is committed
  play.json
  art/icon.png, art/hero.png
package/payload/    NOT committed: build.sh puts hello.exe and setup.exe here
src/hello.c         the game: a window, a square, a step counter saved to Documents\Hello Play\save.txt
src/setup.c         the no-op setup step
build.sh            cross-compile, then build the zip with ruya-pack
make-art.py         draws the two PNGs
```

No binary is committed. The tests (`services/ruya-pack/tests/samples.rs`) copy `package/` to a scratch folder, write stand-in files for the two programs and run `ruya-pack build`, `validate` (with `--system-wine`) and `inspect`, so they need no compiler.

## Build

On Linux with a MinGW-w64 cross compiler (Fedora: `sudo dnf install mingw64-gcc`) and `ruya-pack` on the PATH:

```sh
./build.sh                  # cross-compiles package/payload/*.exe, then builds hello-play-wine.play.zip
./build.sh --payload-only   # cross-compile only
```

Sign it with your own key before you give it to anyone (`ruya-pack keygen`, `ruya-pack sign`; never commit a key). To check the runner choice against a Wine version: `ruya-pack validate hello-play-wine.play.zip --system-wine 10.2`.

The two C programs were **not compiled** on the machine this was written on; run `./build.sh` once before relying on them. Running the package on a console is **planned** (RUY-100, RUY-101). The `steamuser` folder in `data.saves` is the user name the Proton-style runners use; confirm it on a console when the launcher exists.

## Licence

CC0 1.0 (public domain, SPDX `CC0-1.0`); see `LICENSE`.
