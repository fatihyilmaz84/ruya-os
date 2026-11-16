# `.play` as a Flatpak: spike scripts (RUY-91, T-229)

Throw-away scripts for the spike that answers `docs/specs/05-play-packages.md` §16 Q1-Q3 and §18 items 5 and 20. Results: [`RESULTS.md`](RESULTS.md). Nothing here is product code.

All scripts run **as root on the test machine** (the Dell, a RuyaOS image with Flatpak 1.18.4) from one directory, `WORK=/var/tmp/ruy91` by default. A profile must be signed in for the Session1 launches (`PROFILE`, default: the active profile, else `p1`).

## Fetch (once)

```sh
mkdir -p /var/tmp/ruy91/dl /var/tmp/ruy91/x /var/tmp/ruy91/spike && cd /var/tmp/ruy91/dl
flatpak install -y --system flathub app/org.winehq.Wine/x86_64/stable-25.08 runtime/org.freedesktop.Sdk/x86_64/25.08
curl -LO https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-12/GE-Proton11-12-x86_64.tar.gz
curl -LO https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-12/GE-Proton11-12-x86_64.sha512sum
curl -LO https://github.com/Open-Wine-Components/umu-launcher/releases/download/1.4.4/umu-launcher-1.4.4-zipapp.tar
curl -LO https://github.com/jorio/Bugdom/releases/download/1.3.4/Bugdom-1.3.4-windows-x64.zip
sha512sum -c GE-Proton11-12-x86_64.sha512sum && sha256sum *      # compare with RESULTS.md
cd ../x && tar xzf ../dl/GE-Proton11-12-x86_64.tar.gz && tar xf ../dl/umu-launcher-1.4.4-zipapp.tar
mkdir bugdom && cd bugdom && python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(".")' ../../dl/Bugdom-1.3.4-windows-x64.zip
mv Bugdom-1.3.4/* . && rmdir Bugdom-1.3.4
```

Copy the scripts: `scp scripts/spikes/play/* root@<dell>:/var/tmp/ruy91/spike/`.

## Run

| Script | What |
|---|---|
| `common.sh` | Sourced helpers: throw-away GPG key in `$WORK/gnupg`, local OSTree repo, GPG-verified system remote, `build_launcher` (the `org.ruyaos.Play.Launcher` extension), `build_app` (a generated `play.*` app), `prun` (run a command the way `ruya-session` runs an app). |
| `q1-hello.sh` | Q1: launcher extension + `play.test.hello` (native payload), signed, installed, run with `flatpak run` and `Session1.Launch`. |
| `q1-size.sh <GiB> [archive-z2\|bare-user-only]` | Q1 sizes: commit and install time, peak disk, dedup of a second app with the same file. Writes `$WORK/logs/q1-size-*.txt`. Run alone: the peak is the filesystem's, so anything else writing to `/var` inflates it. |
| `q2-wine.sh build` / `run <wl\|x11> [s]` | Q2: Bugdom under Flathub Wine 11 bundled in `play.test.winewl` (Wayland driver) and `play.test.winex11` (X11 through `ruya-session x11-run`); captures the TV with kmsgrab into `$WORK/shots`. Wake the TV first (`python3 wake.py`). |
| `q3-proton.sh build` / `build-x11` / `launch` / `umu` / `umu-noportal` / `direct` / `portal` | Q3: GE-Proton through umu + Steam Linux Runtime in `play.test.proton`, with and without the sub-sandbox portal; GE-Proton direct (no SLR) in `play.test.protonx11`. |
| `q4-limits.sh` | Q4: unit limits, package-chosen `LD_PRELOAD` / `VK_ICD_FILENAMES` / `WINEPREFIX`, 32-bit `cmd.exe` with and without multiarch. |
| `wake.py` | One Left Shift press from a throw-away uinput keyboard (wakes the shell's idle screen). |
| `cleanup.sh` | Uninstalls the test apps and the launcher, removes the remotes, repos, key, builds and the profiles' `~/.var/app/play.test.*`. Keeps the downloads, Wine and the SDK unless `KEEP_FETCHED=0`. |

Order: fetch, `q1-hello.sh`, `q1-size.sh 2 archive-z2`, `q1-size.sh 2 bare-user-only` (then 20), `q2-wine.sh build`, `q3-proton.sh build`, `q3-proton.sh build-x11`, the runs, `q4-limits.sh`, `cleanup.sh`.

Pitfall: `prun` pipes the unit's output through `cat`. With a file under `/var/tmp` as stdout, `systemd-run --machine=... --pipe` fails with "Remote peer disconnected" (the user manager may not receive that fd; 03 §4.1 notes the same for PID 1).
