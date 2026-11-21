# Windows games: use the console's runner from your own Flatpak

How a launcher (a Heroic-like app, a store client) or any Flatpak that starts Windows programs uses **the Windows runner the console already has**: GE-Proton, and Wine stable once it ships. You declare one extension point in your manifest, read a small `runner.json` to find the runner, and start the program yourself. You carry no Wine, and you call no RuyaOS D-Bus method. The short version: **declare `org.ruyaos.Play.Runner` in `add-extensions`, scan `/app/runners/*/runner.json`, take the newest runner of your family that you tested, and run `<proton> waitforexitandrun <program.exe>` with `STEAM_COMPAT_DATA_PATH` in your own data folder.**

*Status: **experimental** (tier C of the [public surface](api-surface.md), ADR-022). The extension ids, the branch and `runner.json` format 1 may change before the first release. Checked against the code and specs as of 2026-11-21. Items marked **planned** are not built yet.*

**What exists today, and what does not.** The image ships GE-Proton 11 (`GE-Proton11-12`) as files on `/usr` and links it into Flatpak's extension folder at every boot (RUY-34, ADR-038); the check on a booted image (`scripts/vm-runner-check.sh`) is the lead's and is pending for this chapter's sample. The previous GE-Proton major and Wine stable are **planned** (RUY-915, RUY-37): this chapter is written for them, but a console cannot offer them yet. The sample's manifest and its runner choice are checked on the host (the lint and the sample's unit tests). **Not run yet:** building the sample with `flatpak-builder` and running it on a console image; that is pending the VM check `scripts/vm-runner-check.sh sample`, which itself runs the script against the image's runners and does not build the Flatpak.

**Making a `.play` package?** You do not need this chapter. A package names a component (`type: proton` or `wine`, `source: system`) and the console's launcher does everything below for you: [Play packages](play-packages.md#choosing-a-runner-source).

**No D-Bus call starts a program for you.** A call that ran a Windows program for an app would launch code outside the caller's sandbox, so the console offers none and will not (ADR-025, [The public surface](api-surface.md#never-public)). You start the runner yourself, inside your own sandbox, with your own permissions. That is also why the choice of runner is yours: the per-game runner choice that is planned for `.play` games (RUY-904) does not apply to an app that starts a runner itself.

## The runners in the image

| Runner | Extension id | `runner.json`: `family`, `kind` | State |
|---|---|---|---|
| GE-Proton, current major | `org.ruyaos.Play.Runner.ProtonGE11` | `proton-ge`, `proton` | in the image (RUY-34); VM check pending |
| GE-Proton, previous major | `org.ruyaos.Play.Runner.ProtonGE10` (the major before the current one) | `proton-ge`, `proton` | **planned** (RUY-915) |
| Wine stable | `org.ruyaos.Play.Runner.Wine<major>` | `wine`, `wine` | **planned** (RUY-37) |

- **One id per family and major, branch `1`.** The id is `org.ruyaos.Play.Runner.<Family><major>` and the branch is always `1`: the branch is the ABI of the layout described here, not the runner's version (ADR-038). A new major is a new id, so every major in the image is mounted at once.
- **The image keeps two GE-Proton majors.** The current one and the previous one. A major leaves the image two GE-Proton majors after it appeared: an OS update can take away the runner you tested on. Plan for it (see [When a runner goes away](#when-a-runner-goes-away)).
- **They arrive with the OS.** There is no Store channel for runners and nothing is downloaded at run time. Wine staging, Wine-GE and UMU-Proton are not shipped. If you need one, you bundle it, like a `.play` package would.
- **Read-only, and shared.** The runner is a folder of the signed image, mounted read-only into every app that declares the extension. Nothing you write reaches it.

## Declare the extension point

Add the console's runner point to your manifest. Flatpak then mounts every installed extension named `org.ruyaos.Play.Runner.<Name>` at branch `1` into your sandbox at `/app/runners/<Name>`:

```json
{
  "add-extensions": {
    "org.ruyaos.Play.Runner": {
      "directory": "runners",
      "version": "1",
      "subdirectories": true,
      "no-autodownload": true,
      "autodelete": false
    }
  }
}
```

- `directory` is where the runners appear under `/app`; the sample and the console's own launcher use `runners`, so `/app/runners/ProtonGE11/`. The folder name is the end of the extension id and **is not an API**: read `runner.json` (next section) to learn the family and version.
- `version` is the branch, `"1"`. `subdirectories` mounts each runner in a folder of its own. `no-autodownload` is required: the image links its runners in, and no remote has them. `autodelete` is `false`: uninstalling your app must not try to remove the runners, which are files of the console's image.
- **Alternatively, one runner by id.** An app that tested exactly one major may declare `org.ruyaos.Play.Runner.ProtonGE11` itself (`directory` `runners/ProtonGE11`, the same `version` and `no-autodownload`, no `subdirectories`). The folder then disappears when the major leaves the image, so the point above is the better default. (The sample uses the point; the lint checks the id form, nothing has run it on a console.)
- **Sandbox permissions.** A Windows program under Proton needs the same grants the console gives its own Windows games: `--socket=x11` (they run on X11), `--share=ipc`, `--device=dri`, `--socket=pulseaudio` and `--allow=multiarch` (Proton starts 32-bit programs). Add `--share=network` only if your launcher needs it.
- **32-bit games.** Proton can only run 32-bit Windows programs with the runtime's 32-bit libraries. The console's own Windows games also declare `org.freedesktop.Platform.Compat.i386` and `org.freedesktop.Platform.GL32`; their exact lines are `extension_points` in `services/ruya-play/src/service/commit.rs`. The sample runs 64-bit programs only and does not cover them.

`scripts/lint-dev-docs.ps1` checks the sample's manifest against the image: the point and the branch are the ones the console's `ruya-play` service writes into its own apps (`commit.rs`), and an id of the form `org.ruyaos.Play.Runner.<Name>` must have a folder `<Name>` under `image/play/runners/`.

## Find the runner: `runner.json`

Every runner has a `runner.json` at the root of its folder. This is the real one of GE-Proton 11:

```json
{
  "format": 1,
  "family": "proton-ge",
  "kind": "proton",
  "version": "GE-Proton11-12",
  "arch": "x86_64",
  "entry": { "proton": "proton" },
  "capabilities": ["multiarch", "dxvk", "vkd3d"],
  "licence": "BSD-3-Clause AND LGPL-2.1-or-later AND LGPL-2.0-or-later AND Zlib AND MIT AND OFL-1.1",
  "source_url": "https://github.com/GloriousEggroll/proton-ge-custom/releases/tag/GE-Proton11-12"
}
```

The file is checked against [`api/play/runner.schema.json`](../../api/play/runner.schema.json) and described in `05` section 6.2.1 of the specs; the [Play packages](play-packages.md#the-bundled-runners-runnerjson) chapter covers it for packagers. What you read:

| Key | What to do with it |
|---|---|
| `format` | `1`. A higher number may mean something else: skip that runner. |
| `family` | Which runner this is (`proton-ge`, `wine`). Versions compare only inside one family. |
| `kind` | `proton` or `wine`: how to start it (next section). |
| `version` | Text holding numbers. Compare the numbers in order: `GE-Proton11-12` is 11, 12, so it is newer than `GE-Proton10-34`. The first number is the major. |
| `arch` | `x86_64`. |
| `entry` | The file to start, relative to the runner's folder. Proton: `{"proton": "proton"}`. Wine: `{"wine": "bin/wine", "wineserver": "bin/wineserver"}`. Never join a path you did not read from here. |
| `capabilities`, `licence`, `source_url` | Informational. |

Scan `/app/runners/*/runner.json` (the console's own launcher reads at most 32 folders and follows no links) and keep the runners you can use. The sample does it like this:

```python
# sample: samples/hello-runner/run-windows.py
def read_runner(folder):
    ...
    fmt = r.get("format")
    # A format above 1 may mean something else: skip it, as the console's launcher would refuse it.
    if not isinstance(fmt, int) or isinstance(fmt, bool) or fmt != 1:
        return None
    if r.get("family") != FAMILY or r.get("kind") != "proton" or r.get("arch") != "x86_64":
        return None
    ...
    nums = numbers(version)
    if not nums or not MIN_MAJOR <= nums[0] <= MAX_MAJOR:
        return None
    ...
    if os.path.islink(proton) or not os.path.isfile(proton):
        return None
    return nums, version, proton
...
def pick_runner(root):
    best = None
    ...
    for name in names:
        found = read_runner(folder)
        if found and (best is None or found[0] > best[0]):
            best = (found[0], name, found[1], found[2])
    return best[1:] if best else None
```

The file is data from the signed image and read-only, but read it as data anyway: a missing key, a wrong type or a path that leaves the folder skips that runner and never stops your app.

## Start a game

You start the runner's entry yourself. The argv and environment below are what the console's launcher uses for `.play` games (ADR-037), so a game behaves the same either way.

**Proton** (`kind` `proton`, GE-Proton). The entry is a Python script that runs through its own shebang (the freedesktop runtime has `python3`):

- argv: `<runner folder>/<entry.proton>`, `waitforexitandrun`, your program (a `.exe`), its arguments. `waitforexitandrun` returns when the game and its helpers have exited.
- `STEAM_COMPAT_DATA_PATH`: a folder in your data, `$XDG_DATA_HOME/proton`. Proton keeps its prefix in `pfx` below it.
- `STEAM_COMPAT_CLIENT_INSTALL_PATH`: an existing folder, `$XDG_DATA_HOME/proton/client`.
- **No `WINEPREFIX`**: Proton derives its own from `STEAM_COMPAT_DATA_PATH`; remove an inherited one.
- `SteamAppId` and `SteamGameId` set to `0`: outside Steam the game has no Steam id. GE-Proton's `protonfixes` looks for one and, when none of `SteamAppId`, `SteamGameId` or `UMU_ID` is set, parses a number out of `STEAM_COMPAT_DATA_PATH`; a folder without digits makes Proton stop with a Python `IndexError`. `0` makes it apply its defaults only. Do not set `UMU_ID`: your game has no umu id.
- `PWD`: the working folder you start Proton in. Proton reads it without a fallback, so a `KeyError: 'PWD'` means it was missing (a shell sets it; a launcher that starts a program directly does not). Set it to the folder you give the process (`os.getcwd()` when you do not change it).

```python
# sample: samples/hello-runner/run-windows.py
def proton_environment(data):
    ...
    compat = os.path.join(data, "proton")
    client = os.path.join(compat, "client")
    os.makedirs(client, exist_ok=True)
    env = dict(os.environ)
    env.pop("WINEPREFIX", None)
    env["STEAM_COMPAT_DATA_PATH"] = compat
    env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = client
    env["SteamAppId"] = env["SteamGameId"] = "0"
    env["PWD"] = os.getcwd()
    return env
...
def main(argv):
    ...
    try:
        os.execve(proton, [proton, "waitforexitandrun", program] + args, env)
    except OSError as e:
        ...
```

**Wine** (`kind` `wine`; **planned**, RUY-37). The entry gives two programs, `wine` and `wineserver`. Start `<runner folder>/<entry.wine> <your program> ...` with `WINEPREFIX` set to a folder in your data (the launcher uses `$XDG_DATA_HOME/prefix`), `WINELOADER` to the `wine` path and `WINESERVER` to the `wineserver` path. Set `WINEARCH` (for example `win64`) only on the start that creates the prefix. Nothing in this paragraph is exercised yet: test it when a Wine runner ships.

**The prefix, per profile.** Every profile is a Unix user, so `$XDG_DATA_HOME` is already the profile's own folder of your app, `~/.var/app/<your-app-id>/data/` ([Saves and data](saves-and-data.md)): a prefix there is per profile and per app, exactly like the console's own `.play` prefixes (`proton/pfx` for Proton, `prefix` for Wine). Keep it in the data folder, not the cache: a game's saves live inside it. A prefix is created by the first start and takes a moment; do not delete it to "fix" a game without telling the player.

## When a runner goes away

An OS update replaces the runners in the image, and the oldest GE-Proton major leaves two majors after it appeared. So:

- **Read `runner.json` at every start.** Do not store the runner's path or folder name, and do not assume the runner you used last time is still there.
- **Accept the newest runner you support.** List the majors you tested (the sample has `MIN_MAJOR` and `MAX_MAJOR`; raise `MAX_MAJOR` after you test a newer GE-Proton) and take the newest one of your family inside that range. A major newer than you tested is a risk you may choose to take; the sample does not.
- **A new major can change how a game behaves in an existing prefix.** Keep a copy of the old prefix until the game has started once on the new runner.
- **If nothing fits**, say so in your own interface ("this console has no runner this app was tested with") and keep running. You may also bundle your own Wine or Proton, as a `.play` package does; then the licence duty is yours (see [Play packages](play-packages.md#legal-duties-for-what-you-bundle)).

## What is experimental, and what is not public

Experimental (tier C, may change before the first release): the extension point and ids (`org.ruyaos.Play.Runner`, `...<Family><major>`), the branch `1`, `runner.json` format 1 and the argv and environment above.

Not an API, so do not rely on it: the folder names below `/app/runners`, anything in a runner's folder except `runner.json` and the files its `entry` names (the sample's `--self-test` uses GE-Proton's own `cmd.exe`, which is an implementation detail of that build), `.ruya-runner-hash`, the links under `/var/lib/flatpak/extension`, and the runners' link into Steam. There is no RuyaOS call to list, start or choose a runner, and the console will not add one that runs a program for you.

## Try the sample

[`samples/hello-runner/`](../../samples/hello-runner/README.md) (CC0): a manifest that declares the point and a script that reads `runner.json` and runs a program. The script has a `--self-test` mode that runs the runner's own `cmd.exe`, so no Windows binary is needed; it needs an X display (below). It is a command-line check, not a game: it needs no desktop entry and no AppStream file. **Not run yet** (neither the build nor the run below; pending the VM check). On a build machine with `flatpak` and `flatpak-builder` (see [Getting started](getting-started.md)), in `samples/hello-runner/`:

```sh
flatpak-builder --force-clean --user --install-deps-from=flathub --repo=repo build-dir org.ruyaos.HelloRunner.json
flatpak --user remote-add --if-not-exists --no-gpg-verify hello-local repo
flatpak --user install -y hello-local org.ruyaos.HelloRunner
```

The runner exists only on a console, so copy `repo` there and install it system-wide as Getting started shows for the sample game (`flatpak install --system`), then:

```sh
flatpak run org.ruyaos.HelloRunner --self-test
```

It should print `hello-runner: using ProtonGE11 (GE-Proton11-12)` and then `RUYA_HELLO_RUNNER_OK` (printed by the script once the runner's own `cmd.exe` has written it to a file); this output is what the script is written to produce, not something seen on an image yet. `--self-test` needs an X display: Proton starts every program with its own console window, and Wine cannot open one without a display, so the program would never return. The script stops with `--self-test needs an X display` when `DISPLAY` is not set, and it reads the marker from a file because `cmd.exe`'s `echo` goes to that console window, never to your standard output. Flatpak gives the sandbox a `DISPLAY` (the manifest's `--socket=x11`) only when the process that runs `flatpak` has one; a login over `ssh` has none. A launcher that starts the program for a player does not have this problem: the console runs a Windows game on X11 already. To try the script's runner choice off a console, point it at any folder of runners: `python3 run-windows.py --runners DIR --self-test` (the tests do this with made-up folders).

**Your own `.exe`.** The sandbox can read only what the manifest grants, and the sample grants no `--filesystem`. A launcher keeps its games under its own data folder, which is always readable, so put the program there and pass its path:

```sh
cp game.exe ~/.var/app/org.ruyaos.HelloRunner/data/
flatpak run org.ruyaos.HelloRunner ~/.var/app/org.ruyaos.HelloRunner/data/game.exe
```

Anything outside the app's own folders (a USB drive, a shared library folder) needs a `--filesystem=` grant in your manifest ([Permissions and sandbox rules](permissions-and-sandbox.md)); the sample does not ask for one.

- [ ] The manifest declares `org.ruyaos.Play.Runner` with `version` `1`, `subdirectories` and `no-autodownload`.
- [ ] The app reads `runner.json` for the family, version and entry; no path is built from a folder name.
- [ ] The prefix and `STEAM_COMPAT_DATA_PATH` are under `$XDG_DATA_HOME`.
- [ ] The app starts when no runner of its family is mounted, and says why it cannot run a game.

## Sources

Checked on 2026-11-21 against: `docs/specs/00-overview.md` ADR-022, ADR-025, ADR-037 and ADR-038; `docs/specs/05-play-packages.md` sections 6.2.1 (`runner.json`), 6.3 and 6.4; `api/play/runner.schema.json`; `image/play/runners/ProtonGE11/runner.json` (the file quoted above) and `pin`; `image/rootfs/usr/lib/tmpfiles.d/ruya-play-platform.conf` (the links); `services/ruya-play/src/service/commit.rs` (`RUNNER_EXTENSION`, `PLAY_EXTENSION_BRANCH`, `extension_points`, the point written into the console's own apps); `services/ruya-play-launch/src/plan.rs` and `runners.rs` (argv, environment, the scan); `services/ruya-play-trust/src/permissions.rs` (`multiarch`, X11 for Windows runners); `samples/hello-runner/` (`run-windows.py` exercised on the host against runner folders of several versions, formats and families; not yet run on a console image: `scripts/vm-runner-check.sh sample`, pending). The previous GE-Proton major and Wine stable are planned (RUY-915, RUY-37).
