# Testing and debugging

How to run your game on a RuyaOS machine, watch what it does, break it on purpose, and fix the usual problems. Most of this is plain Flatpak and systemd; the RuyaOS parts are where things live and how the console starts and stops your game.

*Checked against the code as of 2026-11-06. Items marked **planned** are not built yet.*

## Get a dev machine

There is no downloadable image yet. You build one, or borrow one from a RuyaOS developer:

- **In QEMU on your PC:** build the image and a disk, then `smoke-test.ps1 -Work -Keep` (Windows host) or `scripts/run-vm.sh` (Linux): [`docs/dev-setup.md`](../dev-setup.md), "Build, disk, boot". The VM forwards SSH to `127.0.0.1` port 2222. Use `-Work` to keep profiles and installed games across boots.
- **On real hardware:** write the installer ISO to a USB stick ([`docs/dev-setup.md`](../dev-setup.md), "Installer ISO"). It erases every disk in the machine.
- Both carry the **developer SSH key** for `root`: create one with `ssh-keygen -t ed25519 -N "" -f ~/.ssh/ruyaos_dev` and put its public half in `image/bib/config.toml` before building. **A dev image is for test machines only**: anyone with the private key is root on it.

```sh
ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1
```

(Use `127.0.0.1`, not `localhost`: IPv6 breaks the forward.) Create a profile through the first-boot wizard first; games are launched for a profile.

## Install, run, stop, from SSH

Install a build: [Getting started](getting-started.md). To start the game for a profile exactly as the shell will (`p1` is the profile id from `Profiles1.ListProfiles`), and stop it:

```sh
runuser -u ruya-shell -- busctl --system call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 Launch ss org.example.Game p1
runuser -u ruya-shell -- busctl --system call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 ListRunning
runuser -u ruya-shell -- busctl --system call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 Stop s ruya-app-ruya-p1-org.example.Game.service
busctl --system monitor org.ruyaos.Session1
```

`Launch` answers `ss "ok" "<instance>"`; the last command prints `AppStarted` and `AppExited` with the reason (`quit`, `crashed`, `killed`, `launch-failed`). The statuses `Launch` can answer instead are in the problems table below. Only `ruya-shell` and `root` may call the service; that is why the commands run as `ruya-shell`.

**Running `flatpak run` yourself** (as root, over SSH) is fine for a quick look, but it is not what the console does: it runs as root, with root's data directory, and it is not your profile's game. Use it for `--command=sh` and for quick output; use the commands above to test lifecycle and saves.

## Where things are

| What | Where |
|---|---|
| Profiles | Unix users `ruya-p<N>`; homes `/var/home/ruya-p<N>` (mode 0700, readable by root) |
| Your game, installed | `/var/lib/flatpak/app/<app-id>` (system-wide) |
| Your game's data | `/var/home/ruya-p<N>/.var/app/<app-id>/{data,config,cache}`; inside the sandbox the `$XDG_*` variables point at them |
| The unit | `ruya-app-ruya-p<N>-<app-id>.service`, in the profile's own systemd user manager; the sandbox is in `app-flatpak-<app-id>-<n>.scope` |
| Console logs | `journalctl -b --no-pager` |

Look at the unit from root (the `| cat` matters in scripts: a call over `-M` hands its stderr to PID 1, and SELinux only lets it write a pipe):

```sh
systemctl --user -M ruya-p1@.host status ruya-app-ruya-p1-org.example.Game.service 2>&1 | cat
systemctl --user -M ruya-p1@.host list-units 'app-flatpak-*' 'ruya-app-*' 2>&1 | cat
```

**Your game's own output** (stdout, stderr) goes to the unit's journal. The filter the project uses for the shell is by user: `journalctl -b _UID=$(id -u ruya-p1) --no-pager | tail -50`. For a profile's game this is what `scripts/vm-sample-check.sh` tries and reports as a note, not a failure, when it finds nothing; **confirm on your first run** that your lines appear there.

## Inside the sandbox

```sh
flatpak run --command=sh org.example.Game                  # a shell in your sandbox
flatpak run --env=SDL_VIDEODRIVER=dummy org.example.Game   # one run with an environment variable
flatpak ps                                                  # running sandboxes
flatpak info --show-permissions org.example.Game            # your permissions as Flatpak sees them
flatpak override --show org.example.Game                    # overrides on top of them
flatpak kill org.example.Game                               # a hard kill, see below
```

Inside the sandbox `echo $XDG_DATA_HOME` shows your data directory and `find $XDG_DATA_HOME $XDG_CONFIG_HOME $XDG_CACHE_HOME -type f -mmin -5` shows what your game wrote in the last five minutes ([Saves and data](saves-and-data.md)).

## Break it on purpose

Test these before you publish; each takes a minute. (The sample's `scripts/vm-sample-check.sh` does 1, 3 and 4 for you.)

1. **Stop it as the console does.** Send `SIGTERM` to your game's own process, not to the `flatpak run` command: `kill -TERM $(pgrep -u ruya-p1 -x my-game)` (the process name is your binary's). Then look at the save. Or use `Session1.Stop`, which sends it to every process of the app and kills after 5 seconds. Your game must save, exit with status 0 and be gone well inside 5 seconds; `AppExited` must say `quit`, not `killed`. In our test, sending `SIGTERM` only to the `flatpak run` command did **not** stop the sandbox, so that is not a valid test.
2. **Pull the plug.** `flatpak kill <app-id>` ends the sandbox at once, with no signal your game can handle (a real power cut is the same, or worse). Do it while the game is saving: add a long pause between writing the temporary file and renaming it in a test build, or just hammer the save button and kill. Start again: the previous good save must load. For a whole-machine cut, `quit` in the QEMU monitor (`127.0.0.1:4444`) ends the VM without a shutdown.
3. **Damage the newest save**: overwrite it with a few bytes and start the game; it must start from the `.bak`.
4. **Quit and start again**: the progress is still there.
5. **Uninstall and reinstall**: with "keep data" (the default) the save is still there; the Store does it with `Uninstall(id, false)`.
6. **No audio device, no controller, no network** (when you do not ask for it): the game starts and plays.
7. **A second profile**: it starts with an empty save of its own; the first profile's save is unchanged.

## Headless testing

A display is not needed to test logic and saves. SDL has dummy drivers:

```sh
flatpak run --env=SDL_VIDEODRIVER=dummy --env=SDL_AUDIODRIVER=dummy org.example.Game
```

Engines have headless modes too (`--headless` in Godot). The sample game has `make test`, a unit test of its save code with no SDL, which also runs inside the Flatpak build.

## Common problems

| Symptom | Cause and fix |
|---|---|
| The game is not in the Games row | The *desktop entry* needs `Categories=Game;` (the metainfo's category is another file); it must be installed **system-wide** (`flatpak install --system`; `--user` installs are not seen); wait a few seconds (the list refreshes every 2 s) |
| `Launch` answers `unknown-app` | Not installed system-wide: check `flatpak list --system --app` |
| `Launch` answers `unknown-profile` | The profile id is wrong; use an id from `Profiles1.ListProfiles` |
| `Launch` answers `already-running` | One instance per profile and app; `Stop` it first |
| `Launch` answers `invalid` | The app id is not a valid Flatpak id |
| `AppExited` with `launch-failed` or `crashed` right after start | Read the journal. A frequent cause is no display: the app lacks `--socket=wayland` (an X11-only app finds no display: there is no Xwayland), or its window came while its profile was not the signed-in one (the shell's journal says `ruya-compositor: refused ... of uid N`) |
| No window, no picture | The same: **planned** (T-164). Test headless meanwhile |
| The game does not see the controller | Not built for profile games yet (B-006): [Controller input](controller-input.md) |
| No sound | Not built for profile games yet (B-007): [Audio and video](audio-and-video.md) |
| Install fails with `missing-runtime` | The machine is offline or cannot reach Flathub; the runtime is fetched on install |
| Install fails with `signature` | The remote is unsigned or its key is wrong; see [Publishing](publishing.md) |
| `AppExited` says `killed` | The game ignored `SIGTERM` for 5 seconds (or something killed it); fix the save and exit path |
| Saves are gone after reinstalling | The data was deleted ("also delete my data" on uninstall), or the game wrote saves in the cache directory; [Saves and data](saves-and-data.md) |
| A save is half written after a kill | The save is not atomic; [Saves and data](saves-and-data.md) |
| `systemctl --user -M ...` hangs or says "Connection reset by peer" in a script | stderr must go to a pipe: `2>&1 | cat` |

## Checklist

- [ ] The game runs from a clean install on a dev machine, for a profile, through `Session1`.
- [ ] You sent it `SIGTERM` the way the console does and it saved and exited with status 0 in a second or two.
- [ ] You killed it during a save and the next start loaded the previous save.
- [ ] A damaged newest save falls back to the `.bak`.
- [ ] It runs with no audio device and with no controller, and starts headless for your own tests.
- [ ] You looked at the unit's log and it says nothing alarming.

## Sources

Checked on 2026-11-06 against: `docs/dev-setup.md` (dev image, SSH, VM, monitor port, `-Work`, installer ISO); `scripts/vm-session-check.sh` and `scripts/vm-sample-check.sh` (the `Session1` calls, the unit and scope names, the `2>&1 | cat` pitfall); `api/dbus/org.ruyaos.Session1.xml` (statuses); `services/ruya-session/src/spawner.rs` (`unit_name`, `scope_pattern`), `session.rs`; `services/ruya-library/src/watch.rs` (2 s refresh) and `flatpak.rs`; `docs/specs/03-services-and-apps.md` sections 4.1, 4.3 (job error statuses); `image/CLAUDE.md` (the `-M` stderr rule); `flatpak run --command=sh`, `--env`, `ps`, `kill`, `info --show-permissions` and `override --show` run on the sample (Flatpak 1.18.4, WSL), including a SIGTERM to all sandbox processes (saved, 3 of 3), to the game only (saved) and to `flatpak run` only (the sandbox kept running), and `flatpak kill` (no save line). Not run on a RuyaOS machine yet: the journal filter for a profile's game, `list-units` over `-M` (the sample check, a lead run, will show).
