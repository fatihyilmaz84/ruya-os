# RUY-91 (T-229) spike results: `.play` as a generated Flatpak, Windows display, Proton nesting

Dell, 2026-11-16, RuyaOS image 0.0.89 (Fedora 44 bootc), Flatpak 1.18.4, bubblewrap 0.12.0, `/var` on XFS with `reflink=1`, Intel GPU, TV at 1080p60. Scripts and how to re-run: [`README.md`](README.md). Raw logs: `output/ruy91-logs/` (not committed).

## Downloads (official sources)

| What | URL | sha256 |
|---|---|---|
| Wine 11.0 (Flathub) | `app/org.winehq.Wine/x86_64/stable-25.08`, commit `467682d9dc00...41566e` | (OSTree, GPG-verified by Flatpak) |
| Freedesktop SDK 25.08 (Flathub, for `gcc` only) | `runtime/org.freedesktop.Sdk/x86_64/25.08` | (OSTree) |
| GE-Proton11-12 | https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-12/GE-Proton11-12-x86_64.tar.gz | `0595159e417c3dbbfb7cc3ae0d3ed15a617cc607aa23ef756ea79029d7af5d70` (upstream sha512 matched) |
| umu-launcher 1.4.4 zipapp | https://github.com/Open-Wine-Components/umu-launcher/releases/download/1.4.4/umu-launcher-1.4.4-zipapp.tar | `eb590691841f7fad3fc3ad8fd5db4ccb87849fe7948e62b28ece7a4ee48cc851` |
| Bugdom 1.3.4 for Windows x64 (SDL2 + OpenGL, gamepad) | https://github.com/jorio/Bugdom/releases/download/1.3.4/Bugdom-1.3.4-windows-x64.zip | `ae75d5d6ad9a4557600cd4cb4d5c8518a3b8bae0bae27fa216e4936d5a7a727d` |
| Steam Linux Runtime 4 (`steamrt4_platform_4.0.20261110.268882`) | fetched by umu at first run from `repo.steampowered.com/steamrt4/images/` | not recorded (umu's own download) |

## Q1: import as a Flatpak: **works**, no `--no-gpg-verify` anywhere

Commands (`q1-hello.sh`): a throw-away ed25519 key (`gpg --quick-gen-key ... ed25519 sign never` in a temp `GNUPGHOME`), `ostree init --mode=archive-z2`, then

```sh
flatpak build-init --type=extension $d org.ruyaos.Play.Launcher org.freedesktop.Platform org.freedesktop.Platform 25.08
flatpak build-export --gpg-sign=$KEY --gpg-homedir=$GNUPGHOME $REPO $d 1
flatpak build-init $d play.test.hello org.freedesktop.Platform org.freedesktop.Platform 25.08   # Platform as "SDK": no SDK needed
flatpak build-finish $d --command=/app/launcher/bin/ruya-play-launch \
  --extension=org.ruyaos.Play.Launcher=directory=launcher --extension=org.ruyaos.Play.Launcher=version=1 \
  --extension=org.ruyaos.Play.Launcher=no-autodownload=false --socket=wayland --socket=pulseaudio --device=dri --share=ipc
flatpak build-export --gpg-sign=$KEY --gpg-homedir=$GNUPGHOME $REPO $d stable
flatpak remote-add --system --gpg-import=key.gpg ruy91-local file://$REPO   # gpg-verify=true, gpg-verify-summary=true
flatpak install --system ruy91-local play.test.hello
```

- **Install pulled the launcher by itself** (related ref of the declared extension point): `Installing runtime/org.ruyaos.Play.Launcher/x86_64/1`, then the app, 0.4 s. Export of each: 0.1 s.
- `command=` may be an **absolute path into the extension** (`/app/launcher/bin/ruya-play-launch`); it ran under `flatpak run` and under `Session1.Launch(play.test.hello, p1)` (status `ok`, `ruya-app-ruya-p1-play.test.hello.service`, the payload in `app-flatpak-play.test.hello-<n>.scope`, uid 1000, `WAYLAND_DISPLAY=wayland-0`).
- **What Flatpak required:** (1) every extension point's mount directory must exist in the app's `/app` (`mkdir -p files/<directory>` before export), else `bwrap: Can't mkdir parents for /app/lib/i386-linux-gnu: Read-only file system` at run time. (2) The build-export summary signing needs the same key (done by build-export). (3) An app without `share/applications/<id>.desktop` exports nothing ("Please review the exported files"): the importer must write the desktop file (`Game` category) for `ruya-library`. (4) Files under `share/applications` and icons not named after the app id are refused ("non-allowed export filename"): only the importer's own desktop entry and art may be exported. Nothing was refused otherwise; `--no-gpg-verify` was never needed.
- `flatpak install` of an already installed ref is a no-op: re-imports need `install --or-update` (or `update`).

**Sizes** (`q1-size.sh`, incompressible payload from `/dev/urandom`, staging hardlinked into the build dir, peak = highest `df` used bytes on `/var`, sampled every 0.5 s, minus the value before the payload was written):

| Payload, local repo mode | Commit (build-export) | Install | Peak extra disk | Second app, same file |
|---|---|---|---|---|
| 2 GiB, `archive-z2` | 47.6 s | 12.2 s | 6144 MiB (3x: staging + compressed repo + system repo) | +0 MiB, but 46.6 s (recompresses to hash) |
| 2 GiB, `bare-user-only` | 5.3 s | 0.6 s | 2048 MiB (1x) | +0 MiB, 5.3 s |
| 20 GiB, `bare-user-only` | 51.6 s | 0.4 s | 21084 MiB (1.03x) | +0 MiB, 49.8 s |
| 20 GiB, `archive-z2` | 472.3 s | 117.4 s | 63556 MiB (3.1x) | +709 MiB fs, +0 MiB in `/var/lib/flatpak`, 481 s |

The 20 GiB `archive-z2` run overlapped the Q2/Q3 builds and a Proton prefix, so its last two figures carry about 2 GiB of noise; the 2 GiB runs and the 20 GiB `bare-user-only` run were alone.
- **Why `bare-user-only` costs nothing:** the system repo is `bare-user-only`; on XFS with reflinks ostree's copies of the staged file are reflinks (`fs +0 MiB over staging` after the commit), the `file://` pull imports objects without copying, and the deploy hardlinks into the repo. The peak is the staged tree alone. **This depends on the staging dir, the local repo and `/var/lib/flatpak` being on one reflink-capable filesystem** (XFS here; on a filesystem without reflinks the commit copies: not measured). `--link-checkout-speedup` was not needed. A kept `.play.zip` adds one payload size on top, and the shell's free-space check (§18 item 20) should ask for archive + payload + 5 % on XFS, archive + 2x payload otherwise.
- **Deduplication:** a second app with the same 20 GiB file added 0 bytes. Bundling Flathub's Wine 11 tree (430 MB) in two apps added **23 MiB** to `/var/lib/flatpak`: identical files share objects with the installed `org.winehq.Wine` too.
- After uninstalling both apps the space came back (2 GiB runs: 0 / -7 MiB).

## Q2: Wine display

Wine 11.0 from Flathub (`org.winehq.Wine//stable-25.08`), its `/app` tree copied (hardlinked) into the generated app, Bugdom 1.3.4 as payload, launched with `Session1.Launch` as profile p1 (`q2-wine.sh`).

- **(a) `winewayland` on the per-profile socket: does not start.** `wl_registry#2: error 0: invalid version for global wl_data_device_manager (5): expected at most 1, got 2`, then `nodrv_CreateWindow ... no driver could be loaded`, Bugdom `Couldn't create SDL window.` Wine binds `wl_data_device_manager` v2 unconditionally and our Qt compositor offers v1. GE-Proton11-12's driver (`PROTON_ENABLE_WAYLAND=1`) fails the same way and also reports `Failed to create wayland_output` (our `wl_output` v2) and, after the protocol error, `doesn't support xdg_wm_base`. Wine also logs missing `zwp_pointer_constraints_v1` and `zwp_relative_pointer_manager_v1` (mouse-look), `zwp_text_input_manager_v3`, `zwlr_data_control_manager_v1`, `xdg_toplevel_icon_manager_v1` (optional). These are the same qtwayland hard-coded versions that needed the two xwayland-satellite patches (ADR-034).
- **(b) X11 through the ADR-034 path: works.** Metadata `sockets=x11` made `ruya-session` run `ruya-session x11-run` (`xwayland-satellite :0 -nolisten local -auth ...`, `Xwayland :0 -rootless`), Bugdom showed **full screen at 1080p**, the shell's own performance overlay read **60 FPS, 17 ms frames, slowest 17 ms; 1 % low 30 FPS** (one capture about 30 s after launch, the low includes the loading). Rootless Xwayland presents through the compositor, so there is no tearing path (every frame is composited at the TV's 60 Hz); no other vsync measurement was possible. Game RSS 99 MB, 12 threads; the satellite's cost is ADR-034's (about 35 MB, 0 % CPU idle).
- **Controller: unverified: no pad.** The Wii U Pro controller listed at the start had disconnected (Bluetooth idle) before the run; Wine's prefix had no `WINEBUS` device. `/dev/input/event*` and `/dev/hidraw0` were visible in the sandbox (`--device=all`); there is no `/run/udev` in the sandbox, so Wine's hidraw/udev backend cannot enumerate and the SDL backend (runtime's SDL2 2.32) is the one that would have to find it. A virtual uinput pad was not tried (time).
- **Recommendation: (b), X11 through xwayland-satellite, for v1.** It works today with no compositor change; cost per Windows game is one satellite + Xwayland in the game's unit. (a) needs the compositor to offer `wl_data_device_manager` >= 2 (or a Wine patch), `wl_output` >= 3 and `xdg_wm_base` >= 2 (or newer qtwayland), plus pointer constraints / relative pointer for mouse-look; that is a compositor task, and Wine's driver is still marked experimental upstream. The importer should give a Windows package `sockets=x11` (not `wayland`) so `ruya-session` picks the X11 mode.

## Q3: bundled GE-Proton + umu + Steam Linux Runtime in the sandbox: **does not run; GE-Proton without the SLR does**

`play.test.proton` bundles `/app/components/proton` (GE-Proton11-12, 1.6 GB, exported in 38.7 s) and `/app/components/umu`; finish args `--socket=wayland --socket=pulseaudio --device=all --share=ipc --share=network --allow=multiarch` plus the Compat.i386 and GL32 extension points (`q3-proton.sh`).

- **The sub-sandbox portal is reachable** from a `ruya-session`-style launch: the profile's manager has `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`, `flatpak-portal.service` is D-Bus activated, and `flatpak-spawn --sandbox sh -c ...` inside `play.test.hello` ran (0.14 s). `--no-talk-name=org.freedesktop.portal.Flatpak` does **not** block it (portals are always allowed); only `--no-session-bus` does.
- **With the portal, umu + SLR fails** on this Flatpak: umu fetched `steamrt4` (GE-Proton11 needs app 4183110, SteamLinuxRuntime_4; **696 MB, downloaded per profile and per app** into the app's data dir) and pressure-vessel connected to `org.freedesktop.portal.Flatpak`, then the portal's bwrap failed: `bwrap: Can't find source path /proc/self/fd/26: No such file or directory`. Minimal reproduction without Proton: `flatpak-spawn --sandbox --app-path=/var/data/t/app true` and `--usr-path=/usr true` both fail the same way (`/proc/self/fd/23`, `/proc/self/fd/29`); `--app-path=` (empty) works. SELinux permissive changed nothing. So **Flatpak 1.18.4-1.fc44's sub-sandbox `--app-path`/`--usr-path` is broken**, which is exactly what pressure-vessel needs (it replaces `/usr` with the SLR). The AlmaLinux packaging of the CVE-2026-34078 fix series carries a follow-up patch "run: fix checking wrong variable in runtime fd selection" for sub-sandboxes with `--app-path` ([patch](https://git.almalinux.org/rpms/flatpak/src/branch/c10/CVE-2026-34078-10-run-fix-checking-wrong-variable-in-runtime-fd-selection.patch)); whether Fedora's 1.18.4 lacks it is not confirmed.
- Also found on the way: umu inside Flatpak stores the SLR in `$HOST_XDG_DATA_HOME` else `~/.local/share` of the sandbox, which is **not persistent** (the first run re-downloaded into a tmpfs home and the portal could not see it); `--env=HOST_XDG_DATA_HOME=/var/data` puts it in the app's data dir.
- **Without the portal** (`--no-session-bus`): `steam-runtime-launch-client: E: Can't find session bus`, exit 125 in 1.3 s. pressure-vessel cannot make its own container inside Flatpak (no user namespaces), so there is no portal-less SLR path.
- **GE-Proton direct (no umu, no SLR) works**: `python3 /app/components/proton/proton waitforexitandrun Bugdom.exe` with `STEAM_COMPAT_DATA_PATH=${data}/compat`, `STEAM_COMPAT_CLIENT_INSTALL_PATH=${data}/steam`, inside the freedesktop 25.08 runtime with Compat.i386, launched by `Session1.Launch(play.test.protonx11)` with `sockets=x11`: **full screen, 60 FPS, 1 % low 58 FPS**. Start to the game's `OPENGL32.dll` load: **2.2 s with a fresh prefix** (GE-Proton ships `default_pfx`; the per-profile prefix is 280 MB) and **1.6 s warm**. Its Wayland driver fails as in Q2. Nothing in the read-only `/app` was written to.
- **Answer for §18 item 5:** the default runner (GE-Proton) works for `.play` today only **without** the Steam Linux Runtime, as a plain Wine-style runner on the X11 path. umu + SLR needs a Flatpak whose portal `--usr-path` works (re-test after a Flatpak update) and costs 696 MB per profile and app unless the SLR is shipped once as an extension. Plain Wine (Flathub Wine 11, Q2 b) is an equal fallback.

## Q4: limits and sandbox

- **Unit limits** (`systemctl --user -M ruya-p1@.host show`, both `ruya-app-ruya-p1-play.test.hello.service` and `app-flatpak-play.test.hello-<n>.scope`): `MemoryMax=infinity`, `MemoryHigh=infinity`, `MemorySwapMax=infinity`, `CPUQuotaPerSecUSec=infinity`, `CPUWeight`/`IOWeight` unset, `TasksMax=8848`, `OOMPolicy=stop`, `ManagedOOMMemoryPressure=auto`, `Slice=app.slice` (no limits); `user-1000.slice`: `MemoryMax=infinity`, `TasksMax=19466`. A game can take all memory.
- **Package-chosen environment** (`flatpak run --env=...`, what `run.env` would pass): `LD_PRELOAD` reaches the sandboxed process (`ld.so` tries to load it); `VK_ICD_FILENAMES=/nonexistent.json` makes `vkCreateInstance` return -9 and 0 physical devices (4 by default): a package can break its own GPU access, nothing outside its sandbox. `WINEPREFIX=/app/prefix` fails (`'/app' is not owned by you`); `WINEPREFIX=/tmp/prefix` silently makes a prefix in the sandbox tmpfs, so **saves are lost** at exit and the `epoch`/`data.saves` logic of §6.3 is bypassed. `WINE*` must not include `WINEPREFIX` (the launcher owns it), and `VK_*`/`__GLX_*`/`__EGL_*`/`MESA_*`/`LIBGL_*` are worth adding to the deny list as foot-guns (`LD_*` already is).
- **32-bit Windows programs:** Flathub Wine 11 is the old WoW64 layout (`lib/wine/i386-unix` present). `C:\windows\syswow64\cmd.exe /c echo` printed `32-bit cmd ok` with `--allow=multiarch` (and the Compat.i386 extension point); with `--disallow=multiarch` it died with exit 159 (SIGSYS, Flatpak's seccomp refuses 32-bit syscalls). So a package with 32-bit Windows code needs `multiarch` + Compat.i386 (and GL32 for 32-bit GL) unless its runner is a pure "new WoW64" build. GE-Proton11 also ships `i386-unix`.
- **Stop:** `Session1.Stop` of the Wine/Proton game took 31.5 s: Bugdom under Wine did not end on SIGTERM and the 30 s kill backstop ended it (`Killed unit cgroup`). A relaunch inside that window answers `already-running`.
