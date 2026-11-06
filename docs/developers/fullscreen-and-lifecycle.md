# Full screen and lifecycle

How your game is started, what the screen looks like to it, how it is stopped, and how to build screens that read from the sofa. The short version: **you get the whole screen, you do not choose the size, you stop when asked, and the player's way back is the Guide button, not yours.**

*Checked against the code as of 2026-11-06. Items marked **planned** are not built yet.*

## How your game is started

The shell asks the session service (`org.ruyaos.Session1`, `Launch(app_id, profile)`). `ruya-session` runs, as the root-owned service it is, one command that starts your app **as the profile's own Unix user** in that user's systemd manager:

```sh
systemd-run --user --wait --collect --property=Type=exec --property=KillMode=control-group \
    --machine=ruya-p3@.host --unit=ruya-app-ruya-p3-org.example.Game.service -- flatpak run org.example.Game
```

So:

- Your game runs as `ruya-p<N>`, never as root and never as the shell's user, inside the Flatpak sandbox, in the unit `ruya-app-ruya-p<N>-<app-id>.service` (the sandbox itself is in `app-flatpak-<app-id>-<n>.scope`).
- It is started as `flatpak run <app-id>` **with no arguments**. Anything you need to configure goes in your config file, not on a command line.
- There is **one instance per profile and app**: starting a game that is already running for that profile is refused (`already-running`).
- Each profile has its own data ([Saves and data](saves-and-data.md)).
- **Display: planned (T-164).** The unit is meant to get `WAYLAND_DISPLAY` pointing at a socket only that profile can open. Today it gets none, so no game window appears yet; a game that cannot open a window should exit with an error (the sample does) rather than hang.

## Full screen is not optional

Your game is a Wayland client (xdg-shell). The console's compositor is the shell itself, and for every toplevel window it sends the **fullscreen** state with the size of the output and puts the window in the shell's app layer. So:

- Do not try to be windowed, maximise, set a size or position yourself, or open extra top-level windows.
- Draw at whatever size you are told. The display is a TV: 1280x720, 1920x1080 or 3840x2160. Render at a fixed logical size and let the toolkit scale (SDL: `SDL_SetRenderLogicalPresentation`), or lay out relative to the window, and handle a resize. Picking the resolution and refresh rate in Settings is **planned** (T-198); the game follows whatever mode the output has.
- Do not draw your own close or home button. The shell draws nothing over a running game except its overlay, the volume indicator and urgent notices.

## The Guide button and the overlay

The Guide button (Super on a keyboard) is taken by the shell before your game sees it. While your game is in front, a short press opens the shell's overlay **over** the live game; Back or Close closes it and input returns to the game, and while it is open your game receives no input. Holding Guide opens the power choices. (As built: T-123, T-150. The nicer quick menu with Resume, Home, Close and the running apps is **planned**, T-147; "Home" will leave the game running as the "Running" card and Accept on that card will bring it back.)

What your game should do:

- **Keep running** behind the overlay, but **pause the game** when it loses focus (SDL: `SDL_EVENT_WINDOW_FOCUS_LOST`; Qt: `applicationStateChanged`; Godot: `NOTIFICATION_APPLICATION_FOCUS_OUT`): a menu that opens over a running game must not leave the player to die. This is the rule; whether the compositor reports focus changes to clients in every case is not yet checked on the console, so also pause when your own input is quiet for a long time if your game is dangerous.
- **Do not require a response** to the overlay. The app is not told it opened.
- **Planned:** the spec describes `xdg_toplevel` suspended and visibility events for apps (spec 03 section 4.6). The compositor does not send them yet; do not rely on them.

## Stopping: quit, crashed, killed

When the player closes the game from the overlay ("Close game": **planned**, T-147), or the console must stop it, the shell calls `Session1.Stop(instance)`. `ruya-session` then:

1. stops the unit and the scope with `systemctl --user stop`: **SIGTERM** to every process of your app;
2. waits **5 seconds** (`STOP_GRACE`);
3. if anything is still running, sends **SIGKILL** to the whole group.

Then it announces `AppExited(instance, app_id, exit_code, reason)` and the shell updates. The `reason`:

| reason | When | What the player sees |
|---|---|---|
| `quit` | after `Stop`, the app ended within the grace (by itself with any exit code, or by the SIGTERM); or, without a `Stop`, exit status 0 | nothing |
| `killed` | the 5 seconds passed and the console had to kill it; or something outside killed it (a signal, the out-of-memory killer) | nothing in v1, an unsaved game may be lost |
| `crashed` | it exited with a non-zero status without being stopped | the toast "<name> stopped unexpectedly" |
| `launch-failed` | it never got as far as running (for instance no window could be opened) | the same toast |

So: **exit with status 0 when you finish normally**, and handle `SIGTERM` by saving and exiting ([Saves and data](saves-and-data.md)). The sample's handler only sets a flag; the main loop sees it within a frame, saves, closes the window and returns 0:

```c
/* sample: samples/hello-game/src/main.c */
static volatile sig_atomic_t g_terminate;

static void on_term(int sig)
{
    (void)sig;
    g_terminate = 1; /* only set a flag here; the main loop does the work */
}
```

Some toolkits turn `SIGTERM` into their own quit event (SDL does, as `SDL_EVENT_QUIT`, unless you turn its handler off, as the sample does to keep one code path); Qt does not, so a Qt game installs a signal handler that calls `QCoreApplication::quit()`. Check what yours does. **Test it**: [Testing and debugging](testing-and-debugging.md) shows how to send exactly the console's signal.

What we know about SIGTERM and the Flatpak sandbox: sending `SIGTERM` to **all** processes of a running sandbox at once (what stopping the scope does) was tried three times in a Fedora 44 WSL distribution with Flatpak 1.18.4, and the sample saved each time. The same stop through `ruya-session` and systemd is checked by `scripts/vm-sample-check.sh` (a lead run on the VM; not yet run when this was written). Sending `SIGTERM` only to the `flatpak run` command is **not** a stop: the sandbox kept running in our test.

## Suspend, profile switch and sleep

- **Suspend/resume:** the console does not stop apps when it goes to sleep, so you resume where you were. Do not rely on wall-clock time being continuous across a resume (clamp your frame time, as the sample does). Suspending with the shell on the real display is **not working yet** (T-166).
- **Switching profiles:** **planned** (T-165): the previous profile's apps are suspended and hidden, and come back when that profile signs in again. A suspended game is frozen, not told: save when the player reaches a checkpoint instead of relying on being warned.

## Screens for the sofa

The player sits about 3 m from a TV. These rules are the console's own design rules ([04 design system](../specs/04-design-system.md), [02 shell](../specs/02-shell.md) section 4.3); follow them in your menus too:

- **Text:** body text 30 px at 1080p, **nothing smaller than 24 px**. Scale everything with the window (720p and 4K must look the same). The built-in 8 px font of `SDL_RenderDebugText` at scale 3 is exactly 24 px, which is why the sample draws it at 3x.
- **Safe area:** keep everything the player must read or press **inside 5 % of the screen at every edge** (96 by 54 px at 1080p). TVs crop their edges (overscan), and the player can set the console's screen edge from 0 to 10 %. Backgrounds fill the whole screen, text and buttons do not.
- **Focus is never ambiguous:** the focused item has an obvious ring or highlight; some item is always focused when a menu opens; moving off the edge does not lose focus; focus is restored when a menu closes.
- **Controller conventions:** A accepts, B goes back, D-pad and left stick move, Start opens a menu. Hold Up or Down: the focus repeats after about 400 ms, then accelerates.
- **Back from your top menu is not "quit":** there is nothing to quit to; the Guide is the way out.
- **No pointer and no keyboard needed.** If you need text (a name), use your own on-screen keyboard: the console does not offer one to apps.
- **Hide the mouse cursor** unless the mouse moved recently (the shell shows its own pointer only after movement and hides it after 3 seconds).

## Checklist

- [ ] The game draws full screen at any size (test 720p, 1080p and 4K) and does not ask to be windowed.
- [ ] Nothing the player must read or press is closer than 5 % to an edge; text is at least 24 px at 1080p.
- [ ] The game pauses when its window loses focus.
- [ ] `SIGTERM` saves within a second or two and exits with status 0; nothing waits for a dialog on shutdown.
- [ ] No exit button, no "home" button, no use of Esc or B to quit.
- [ ] A game that cannot open a window exits with an error message, it does not hang.
- [ ] Menus work with a controller only, with a visible focus.

## Sources

Checked on 2026-11-06 against: `api/dbus/org.ruyaos.Session1.xml`; `services/ruya-session/src/spawner.rs` (`launch_command`, `unit_name`), `systemd.rs` (stop and kill through `systemctl`), `session.rs` (`STOP_GRACE`, `exit_reason`), `main.rs` (no display env outside the dev mode); `shell/compositor/Compositor.qml` (`sendFullscreen`); `shell/src/input/KeyRouter.h`; `docs/specs/02-shell.md` sections 1.5, 4.3; `docs/specs/04-design-system.md` sections 1, 2; `docs/specs/00-overview.md` ADR-002 (T-123 result), ADR-004; `docs/specs/03-services-and-apps.md` sections 4.1, 4.6; task files T-147, T-164, T-165, T-166, T-198; `docs/dev-setup.md` (display and T-166 status); the SIGTERM tests described above (WSL, `samples/hello-game`).
