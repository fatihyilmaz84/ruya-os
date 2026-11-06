# Getting started

From nothing to your game installed on a RuyaOS machine, in four steps: build a Flatpak, put it in a local repository, copy it to a dev machine, install it. The sample game in [`samples/hello-game/`](../../samples/hello-game/README.md) does all of it; this chapter explains each step and says where RuyaOS is not finished yet.

*Checked against the code as of 2026-11-06. Items marked **planned** are not built yet.*

## What works today, and what does not

| Step | Status |
|---|---|
| Build a Flatpak with `flatpak-builder`, install it on a RuyaOS dev machine | works (the sample was built and installed this way) |
| Your game appears in the **Games** row of the shell | works (the library service lists installed Flatpaks whose desktop entry has `Categories=Game;`) |
| Press Play and the game's window appears full screen | **planned** (T-164 per-profile Wayland sockets, T-147 launch flow). Today **Play does nothing** and a game started for a profile has no display |
| Controller input inside the game | **planned** (see [Controller input](controller-input.md)) |
| Sound inside the game | **planned** (see [Audio and video](audio-and-video.md)) |
| Start, stop, saves and uninstall as the console does them | works, and is what `scripts/vm-sample-check.sh` exercises |

So you can build and test the logic of your game on any Linux desktop today, and on a RuyaOS machine you can check everything except picture, sound and controller. This chapter is updated when T-164 lands.

## 1. Prerequisites

A Linux machine, or WSL with a Linux distribution (the project uses Fedora 44 in WSL). Install the tools and add Flathub, where the runtimes come from:

```sh
sudo dnf install flatpak flatpak-builder appstream
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
```

**Which runtime.** A Flatpak runs on a *runtime*: the libraries your game does not ship itself. RuyaOS has no runtime of its own and does not preinstall one; when a game is installed, Flatpak fetches its runtime from Flathub (the image has the `flathub` remote, spec 03 section 4.2), so **a console needs a network connection the first time it installs a game that uses a runtime it does not have**. Use the current stable **freedesktop runtime**, `org.freedesktop.Platform` and `org.freedesktop.Sdk`, branch **26.08** (25.08 is also on Flathub). It contains SDL 3 (and SDL 2 through `sdl2-compat`), Mesa, Wayland, PulseAudio client libraries and a C and C++ toolchain in the SDK. Qt games use `org.kde.Platform`, GNOME games `org.gnome.Platform`; engines such as Godot and Unity export their own Flatpaks.

## 2. A minimal manifest

The manifest says what your app is and what it may do. This is the sample's, complete:

```json
{
  "app-id": "org.ruyaos.HelloGame",
  "runtime": "org.freedesktop.Platform",
  "runtime-version": "26.08",
  "sdk": "org.freedesktop.Sdk",
  "command": "hello-game",
  "finish-args": [
    "--socket=wayland",
    "--device=dri",
    "--device=input",
    "--socket=pulseaudio"
  ],
  "modules": [
    {
      "name": "hello-game",
      "buildsystem": "simple",
      "build-commands": [
        "make test",
        "make",
        "make install PREFIX=/app"
      ],
      "sources": [
        { "type": "dir", "path": ".", "skip": ["output", ".flatpak-builder", "build-dir", "repo"] }
      ]
    }
  ]
}
```

- **`app-id`**: reverse DNS of a domain you control (`org.example.MyGame`), at least three parts, no part starting with a digit, letters, digits, `_` and `-` only, at most 120 characters (what `ruya-session` accepts). The sample uses `org.ruyaos.*`, which is only for samples and tests.
- **`finish-args`** are the sandbox permissions. Games usually need exactly these four. Each one, and what the player is told, is in [Permissions](permissions-and-sandbox.md). Ask for nothing else.
- Your build installs three more files that RuyaOS reads: a **desktop entry** (`share/applications/<app-id>.desktop`, with `Categories=Game;`), an **AppStream file** (`share/metainfo/<app-id>.metainfo.xml`, see [AppStream metadata](appstream-metadata.md)) and an **icon**. The sample's `Makefile` installs them.

## 3. Build into a local repository

In the folder with the manifest:

```sh
flatpak-builder --force-clean --user --install-deps-from=flathub --repo=repo build-dir org.ruyaos.HelloGame.json
```

The first run downloads the runtime and SDK (about 1 GB). The result is a Flatpak repository in `repo/`. Check the metadata before you go on:

```sh
appstreamcli validate --no-net data/org.ruyaos.HelloGame.metainfo.xml
```

(`--no-net` skips the check that your screenshot URLs exist, which is only true once you have published them.) Try the game on your own machine first: `flatpak --user remote-add --if-not-exists --no-gpg-verify hello-local repo`, `flatpak --user install hello-local org.ruyaos.HelloGame`, `flatpak run org.ruyaos.HelloGame`.

## 4. Get it onto a RuyaOS machine

You need a **RuyaOS dev machine**: the dev image in QEMU, or real hardware installed from the installer ISO. There is no download yet: you build the image as described in [`docs/dev-setup.md`](../dev-setup.md) (Build, disk, boot; Installer ISO). Both carry the project's developer SSH key for `root`, **for test machines only**. The VM answers on `127.0.0.1` port 2222:

```sh
tar -czf hello-repo.tgz repo
scp -i ~/.ssh/ruyaos_dev -P 2222 hello-repo.tgz root@127.0.0.1:/root/
ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1
```

On the machine, install the game **system-wide**: the console installs apps for every profile, and the library service only looks at the system installation.

```sh
tar -xzf hello-repo.tgz -C /root
flatpak remote-add --system --if-not-exists --no-gpg-verify hello-local /root/repo
flatpak install --system -y hello-local org.ruyaos.HelloGame
```

(`--no-gpg-verify` is for your own test repository only. The console's Store refuses unsigned remotes; see [Publishing](publishing.md).) The runtime comes from Flathub, so the machine must be online.

## 5. See it in the shell

Sign in on the console (the first boot wizard creates a profile). Open **Games**: the game is listed within a couple of seconds of the install, by the name the catalogue gives it, or by the `Name=` of its desktop entry when the app comes from a repository without catalogue data, such as your local one. The list is read from the system Flatpak installation: an app is a game when its exported desktop entry has `Game` in `Categories`, otherwise it is listed as an app. Apps installed with `--user` are not shown.

Starting it: **planned** (Play, T-147 and T-164). Until then, start it the way the shell will, through the session service, from the SSH session. `p1` is a profile id (`busctl --system call org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 ListProfiles` lists them):

```sh
runuser -u ruya-shell -- busctl --system call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 Launch ss org.ruyaos.HelloGame p1
```

It answers `ss "ok" "ruya-app-ruya-p1-org.ruyaos.HelloGame.service"` and the game runs as the Unix user `ruya-p1` in its own systemd unit. With no display for profile apps yet the game cannot open a window: the sample prints `hello-game: SDL_Init failed: No available video device` and exits with status 1, as a real game would. `scripts/vm-sample-check.sh` runs it with SDL's dummy video driver so the lifecycle and the saves can be checked; see [Testing and debugging](testing-and-debugging.md).

## Checklist

- [ ] `flatpak-builder` ends without error and `appstreamcli validate --no-net` passes.
- [ ] The app id follows the rule above and matches the names of your desktop entry, metainfo and icon files.
- [ ] The desktop entry has `Categories=Game;`.
- [ ] Only the `finish-args` you need.
- [ ] Installed system-wide on a dev machine, the game appears in the Games row.
- [ ] You followed this chapter from a clean machine at least once.

## Sources

Checked on 2026-11-06 against: `samples/hello-game/` (built with flatpak-builder 1.4.12, Flatpak 1.18.4, runtime 26.08 in a Fedora 44 WSL distribution); `docs/specs/03-services-and-apps.md` sections 4.1, 4.2, 5 (Library); `services/ruya-library/src/flatpak.rs` (`Categories=Game`); `services/ruya-session/src/spawner.rs` (`valid_app_id`, `launch_command`); `api/dbus/org.ruyaos.Session1.xml`; `docs/dev-setup.md`; `shell/qml/Shell.qml` (`playHero` only calls `Library.launch`, which only emits `launchRequested`; nothing handles it yet); `docs/tasks/T-164-per-profile-wayland-sockets.md`.
