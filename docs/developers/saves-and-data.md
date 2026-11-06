# Saves and data

Where your game writes things, and what the console does with them. The short version: **use the XDG directories, save atomically, finish within five seconds of `SIGTERM`, keep rebuildable stuff out of the saves.** Games that do this get backup, restore, clean uninstall and safe updates for free. Games that do not are still handled safely (see "If your app does not follow this").

*Checked against the console as of 2026-11-06. Items marked **planned** are not built yet.*

## The rule: everything is per profile

RuyaOS profiles are real Unix users. Your Flatpak is installed once for the whole console, but every profile that plays it gets its **own** data directory:

```
/var/home/ruya-p<N>/.var/app/<your-app-id>/     (the profile's home is private: mode 0700)
  data/      your $XDG_DATA_HOME   saves, save states, player profile, downloaded content
  config/    your $XDG_CONFIG_HOME settings
  cache/     your $XDG_CACHE_HOME  anything you can rebuild
```

Inside your sandbox you never need these paths: read the environment variables.

```sh
echo $XDG_DATA_HOME     # e.g. /home/ruya-p3/.var/app/org.example.Game/data
```

Use your toolkit's "user data directory" call (`QStandardPaths::AppDataLocation`, SDL's `SDL_GetPrefPath`, Godot's `user://`, Rust's `dirs::data_dir()`, Python's `platformdirs`): inside Flatpak they resolve to a folder **under** the directories above (`SDL_GetPrefPath(org, app)` returns `$XDG_DATA_HOME/<org>/<app>/`, which is inside `data/` and fine). Check where your engine's call really points; the test at the end of this page shows what your game wrote. Nobody else can read a profile's directory, not other profiles and not an administrator; only the console's own services can, to back it up or delete it.

## What goes where

| Kind | Put it in | Notes |
|---|---|---|
| Save games, battery saves | `$XDG_DATA_HOME/saves/` | One file or folder per slot |
| Save states (emulators, snapshots) | `$XDG_DATA_HOME/states/` | |
| Screenshots you take | `$XDG_DATA_HOME/screenshots/` | |
| Player profile, stats, unlocks, downloaded content you cannot easily re-fetch | `$XDG_DATA_HOME/profile/` or your own subfolder | Counts as saves for backup |
| Settings (graphics, audio, controls) | `$XDG_CONFIG_HOME/` | Backed up with the saves |
| Shader caches, thumbnails, downloaded files you can fetch again, logs | `$XDG_CACHE_HOME/` | **Never backed up.** The console may delete it when space runs short |

The subfolder names `saves/`, `states/`, `screenshots/` and `profile/` are a convention, not a rule: following them lets the console list your saves and your states separately later. Emulators: point "saves" and "states" at those folders by default.

**Do not** write saves to `cache/`, to `/tmp`, next to the executable (`/app` is read-only), or to a host path. Do not ask for `--filesystem=home` or `--filesystem=host` to store saves: those permissions are shown to players as "High risk" and are not needed.

## Write saves atomically

A console loses power at any moment: a plug pulled, a power strip switched off. The filesystem is journaled, so it stays consistent, but your file can still be half written. Do this:

1. Write the new save to a temporary file **in the same directory**.
2. `fsync` it (flush file data to disk).
3. Keep the previous save as a `.bak` (rename it).
4. Rename the temporary file to the final name (a rename is atomic).
5. (Optional but good) `fsync` the directory.

Python:

```python
import os, tempfile

def save_atomic(path: str, data: bytes) -> None:
    folder = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".save-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        if os.path.exists(path):
            os.replace(path, path + ".bak")
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    dfd = os.open(folder, os.O_DIRECTORY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
```

On load: if the save is missing or fails its checksum, fall back to the `.bak`. A checksum or version field at the start of your save makes that easy.

The same in C, which is **the sample game's own code** (`samples/hello-game/src/save.c`; the tests in `samples/hello-game/tests/test_game.c` cover it: a first save has no `.bak`, the second keeps the first as the `.bak`, a torn newest file falls back to the `.bak`, no temporary file is left):

```c
/* sample: samples/hello-game/src/save.c */
int save_atomic(const char *path, const void *data, size_t len)
{
    char tmp[PATH_MAX], bak[PATH_MAX], dir[PATH_MAX];
    if (snprintf(tmp, sizeof tmp, "%s.tmp-XXXXXX", path) >= (int)sizeof tmp ||
        snprintf(bak, sizeof bak, "%s.bak", path) >= (int)sizeof bak ||
        snprintf(dir, sizeof dir, "%s", path) >= (int)sizeof dir) {
        errno = ENAMETOOLONG;
        return -1;
    }
    char *slash = strrchr(dir, '/');
    if (slash) {
        *slash = '\0';
    } else {
        strcpy(dir, ".");
    }

    /* 1. A temporary file in the same directory (a rename across directories is not atomic). */
    int fd = mkstemp(tmp);
    if (fd < 0)
        return -1;
    const char *p = data;
    size_t left = len;
    while (left > 0) {
        ssize_t n = write(fd, p, left);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0) {
            int e = errno ? errno : EIO;
            close(fd);
            unlink(tmp);
            errno = e;
            return -1;
        }
        p += n;
        left -= (size_t)n;
    }
    /* 2. Flush the data to disk before it gets its final name. */
    if (fsync(fd) != 0) {
        int e = errno;
        close(fd);
        unlink(tmp);
        errno = e;
        return -1;
    }
    close(fd);

    /* 3. Keep the previous save as .bak, 4. give the new one the final name (atomic). */
    if (access(path, F_OK) == 0 && rename(path, bak) != 0) {
        int e = errno;
        unlink(tmp);
        errno = e;
        return -1;
    }
    if (rename(tmp, path) != 0) {
        int e = errno;
        unlink(tmp);
        errno = e;
        return -1;
    }

    /* 5. Flush the directory entry too. */
    int dfd = open(dir, O_RDONLY | O_DIRECTORY);
    if (dfd >= 0) {
        fsync(dfd);
        close(dfd);
    }
    return 0;
}
```

The format the sample writes is a text file with a version line and a CRC-32 on the last line (`game.c`: `game_serialise`, `game_parse`, `game_load`), so a half-written or damaged file is recognised and the `.bak` is used.

## Stopping: you have five seconds

When the player closes the game from the Guide overlay (planned: T-147), or the console has to stop it (time limits: planned, T-211), the console asks your app to stop:

1. It sends `SIGTERM` to every process of your app (the unit and the sandbox's scope).
2. It waits **5 seconds**.
3. It sends `SIGKILL` (no chance to save).

Handle `SIGTERM` like "quit now": write the pending save (atomically, as above), then exit. Most frameworks turn it into a normal quit event (`SDL_EVENT_QUIT`, `QCoreApplication::aboutToQuit`, Godot's `NOTIFICATION_WM_CLOSE_REQUEST` or `get_tree().quit()`); check that yours does. After a stop the console reports the app as having quit, whatever its exit status; only an app that is still running after the 5 seconds is reported as killed (and may lose an unfinished save). Exit status `0` is still the right thing to return.

Python:

```python
import signal, sys

def on_term(signum, frame):
    save_game_state()     # your function, atomic
    sys.exit(0)

signal.signal(signal.SIGTERM, on_term)
```

Do not wait for the player to confirm a dialog on shutdown: nobody is there to press it.

Known about the Flatpak sandbox: `SIGTERM` sent to all processes of a running sandbox at once (what stopping the scope does) was tried three times in a Fedora 44 WSL distribution with the sample game, and it saved each time. `flatpak kill <app-id>` is a hard kill with no signal for your handler: use it to test a power cut, not a stop. [Full screen and lifecycle](fullscreen-and-lifecycle.md) has the details, and `scripts/vm-sample-check.sh` runs the real stop through the console's session service.

## Suspend and resume

Apps keep running across suspend (the console does not stop them). Nothing special is needed; do not rely on wall-clock time continuing smoothly across a resume.

## What the console does with your data

- **Updates** never touch it. The OS can be updated or rolled back without losing a save.
- **Uninstall** keeps it by default: the Store's uninstall has an "Also delete my data" switch that starts off, so reinstalling finds the player's progress again. Deleting the data is an explicit choice, and removes only your app's directory (of every profile; the "Keep saves?" wording and a per-profile choice are **planned**, T-215).
- **Deleting a profile** removes that profile's whole home, including your data in it.
- **Backup and restore to a USB drive** (**planned**, T-215): the console will copy `data/` and `config/` of your app (never `cache/`) for a profile into a `.tar.zst` archive with a `manifest.json` (app id, app version, profile name, time, sizes, SHA-256) on the player's drive, and restore it later; it restores only into an installed app and keeps the previous data aside first.
- **Cloud saves:** not provided by the console. If your game has its own cloud sync, it works over the normal network permission.

## If your app does not follow this

Many games and emulators write wherever they like inside their own data directory. That is fine: the console treats **all of `data/` and `config/`** as your saves for backup, and `cache/` as disposable. What goes wrong is writing saves into `cache/` (they can be cleared when space is short and are never backed up) or outside your data directory (they are not backed up and are not kept per profile). Check where your game really writes: play for a minute, save, then look at what changed in the last five minutes:

```sh
flatpak run --command=sh org.example.Game
# inside the sandbox:
find $XDG_DATA_HOME $XDG_CONFIG_HOME $XDG_CACHE_HOME -type f -mmin -5
```

**Planned:** two AppStream custom keys to narrow the backup when your layout is unusual: `x-ruya-save-paths` (a comma-separated list of paths relative to `$XDG_DATA_HOME`: only these are backed up) and `x-ruya-cache-paths` (extra paths under `data/` to leave out). Until they exist, the whole of `data/` and `config/` is used.

## Checklist before you publish

- [ ] Saves are under `$XDG_DATA_HOME` (not cache, not `/tmp`, not a host path).
- [ ] Saves are written atomically and the previous slot is kept as `.bak`.
- [ ] `SIGTERM` writes any pending save and exits (status `0`) well within 5 seconds.
- [ ] Rebuildable data is in `$XDG_CACHE_HOME`.
- [ ] No `--filesystem=home` or `--filesystem=host` in the Flatpak manifest.
- [ ] You tested pulling the plug: kill the app with `SIGKILL` during a save (`flatpak kill <your-app-id>`, a hard kill) and check the next start loads the previous good save.

## Sources

Checked on 2026-11-06 against: `docs/specs/03-services-and-apps.md` sections 4.1, 4.4, 4.5a, 5 (Saves); `services/ruya-session/src/session.rs` (`STOP_GRACE`, `exit_reason`) and `systemd.rs` (stop and kill); `services/ruya-store` (`Uninstall` with `delete_data`); `shell/qml/AppDetailPage.qml` ("Also delete my data", off on open); `services/ruya-profiles` (homes in `/var/home`, mode 0700); `samples/hello-game/` (`save.c` and `tests/test_game.c` pass `make test`; SIGTERM and `flatpak kill` tried on the built Flatpak in WSL, Flatpak 1.18.4); `docs/tasks/T-215-save-backup-and-keep-data.md` (planned backup, restore, "Keep saves?").
