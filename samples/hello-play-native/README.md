# Hello Play Native

The native sample of the [`.play` developer guide](../../docs/developers/play-packages.md): the [Hello Game](../hello-game/README.md) sources packaged as a `.play` instead of a Flatpak. A tiny Linux game with a controller, saves in `$XDG_DATA_HOME/saves/` and no permission beyond input.

| What it shows | Where |
|---|---|
| A native runner (`run.runner: native`), no component | `package/play.json` |
| Argument-list command and `${payload}` | `run.command` |
| Saves listed for backup with the `data:` root | `data.saves` |
| The closed permission list (`network` off, `input`) | `permissions` |
| Art that passes the console's vetting: icon 512x512, hero 1920x1080 | `package/art/`, made by `make-art.py` |

## Layout

```
package/            what is committed
  play.json
  art/icon.png, art/hero.png
package/payload/    NOT committed: build.sh puts the compiled game here
build.sh            compile the game, then build the zip with ruya-pack
make-art.py         draws the two PNGs (Python standard library, same bytes every run)
```

No binary is committed. The tests (`services/ruya-pack/tests/samples.rs`) copy `package/` to a scratch folder, write a stand-in file where the compiled game goes and run `ruya-pack build`, `validate` and `inspect` on it, so they need no compiler.

## Build

On Linux with a C compiler and SDL3 development files (Fedora: `sudo dnf install gcc SDL3-devel pkgconf`), and `ruya-pack` on the PATH (`cargo build -p ruya-pack` in `services/`):

```sh
./build.sh                  # compiles package/payload/hello-game, then builds hello-play-native.play.zip
./build.sh --payload-only   # compile only
```

Then sign it with your own key (never commit a key; the folder's `.gitignore` excludes `*.key`):

```sh
ruya-pack keygen mykey
ruya-pack sign hello-play-native.play.zip --key mykey.key
ruya-pack inspect hello-play-native.play.zip
```

The game links SDL3 dynamically and relies on the Play platform providing it at run time. That is not checked yet: the install-and-run check on a console is **planned** (RUY-100 for the install, RUY-101 for the launcher). The Hello Game sources pass their own `make test`; `build.sh` itself was **not run** on the machine this was written on (no C compiler, no SDL3 there), so run it once before relying on it.

## Licence

CC0 1.0 (public domain, SPDX `CC0-1.0`); see `LICENSE`.
