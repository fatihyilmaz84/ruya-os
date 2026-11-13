# Full screen and lifecycle

How your game is started, what the screen looks like to it, how it is stopped, and how to build screens that read from the sofa. The short version: **you get the whole screen, you do not choose the size, you stop when asked, you can be frozen at any moment (the Guide button's Hub pauses you), and the player's way back is the Guide button, not yours.**

*Checked against the code as of 2026-11-11. Items marked **planned** are not built yet.*

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
- **Display (T-164, *experimental*).** Your game should use the Flatpak permission `--socket=wayland`. Inside the sandbox you see `WAYLAND_DISPLAY=wayland-0`, a socket only your profile can open, and `SDL_VIDEODRIVER=wayland` is set for SDL games. Your window is shown only while your profile is signed in; when the console is locked or another profile signs in it is hidden (what then happens to the running game is not settled yet). There is no GPU buffer sharing with the compositor yet, so a GL game is expected to render in software (slowly; not yet confirmed on hardware). Pads reach the game as keyboard keys (arrows, Return, Escape) through the window, not as a gamepad device. A game that cannot open a window should exit with an error (the sample does) rather than hang.
- **X11-only games (ADR-034, *experimental*; measured once on the test machine through a prototype, RUY-1; the VM check is pending, RUY-436).** X11 mode applies only when your `sockets` list `x11` or `fallback-x11` and not `wayland`; a game that lists both stays on Wayland. Such a game still runs: the console starts a private X server (Xwayland through xwayland-satellite) for that one instance and stops it when the game ends. Your game sees `DISPLAY=:99`, its own cookie in `XAUTHORITY=/run/flatpak/Xauthority`, `SDL_VIDEODRIVER=x11` and `XDG_SESSION_TYPE=x11`, and no `WAYLAND_DISPLAY`. The X screen is the full display, your window is shown full screen like a Wayland one, and the Hub, the pause and Close work the same. Pads reach an X11 game the same way as a Wayland one (the virtual pad, through evdev). No other app, not even another of the same profile, can reach that X server. Relative pointer motion (mouse-look, pointer lock) may not work until RUY-437. Prefer Wayland: X11 is a compatibility layer, not a second display path.

## Full screen is not optional

Your game is a Wayland client (xdg-shell; through Xwayland for X11-only games). The console's compositor is the shell itself, and for every toplevel window it sends the **fullscreen** state with the size of the output and puts the window in the shell's app layer. So:

- Do not try to be windowed, maximise, set a size or position yourself, or open extra top-level windows.
- Draw at whatever size you are told. The display is a TV: 1280x720, 1920x1080 or 3840x2160. Render at a fixed logical size and let the toolkit scale (SDL: `SDL_SetRenderLogicalPresentation`), or lay out relative to the window, and handle a resize. Picking the resolution and refresh rate in Settings is **planned** (T-198); the game follows whatever mode the output has.
- Do not draw your own close or home button. The shell draws nothing over a running game except Ruya Hub (which pauses it, next section), the volume indicator, urgent notices (with the player's "Don't interrupt games" setting on, the default, only critical ones: an update restart about to happen, the console overheating, the battery of the only controller running low; a small card in the top right corner inside the safe area that takes no input and no focus; the rest waits in the notification centre, RUY-413) and, only when the player switches it on in Ruya Hub > Performance, the performance overlay: small blocks of numbers (FPS, frame time, CPU, GPU, memory, temperatures, power) in both top corners inside the safe area. The overlay takes no input and no focus; your game keeps every key. (Built, T-469.)

## The Guide button and Ruya Hub: your game is paused

The Guide button (Super on a keyboard) is taken by the shell before your game sees it. A short press opens **Ruya Hub**, the shell's control panel, over your game. **While the Hub is open your game is frozen**: the console does not ask you to pause, it stops your processes. (ADR-033 point 3, owner decision 2026-11-10; built in T-457; hardware check pending.) Holding Guide for 2 seconds switches the open Hub to the power choices.

### What the player sees

- Your **last frame stays on screen** under the Hub, and your **sound stops**. The Hub's header names the game, shows its running time and, once the console knows the game is frozen, says "Paused". No key or pad button reaches your game while the Hub is open.
- **Resume** (focused when the Hub opens), **B** or **Guide** again close the Hub and thaw the game, which gets the keyboard focus back at once.
- **Home** leaves the game **frozen** behind Home. It shows as "Running" on Home and in the Hub, and it stays frozen, for minutes or hours, until the player brings it back with Play on its card or "Switch to" in the Hub. Hold on to that: a game is not only paused for the seconds a menu is open.
- **Switch to** another running game thaws that game and leaves yours frozen.
- **Close game** thaws your game, then stops it (see [Stopping](#stopping-quit-crashed-killed)); the player sees "Closing <name>..." until it has ended.
- **Not frozen:** the player can turn the setting **"Pause games when Ruya Hub opens"** off (Settings, System; on by default; meant for online games). If the console fails to freeze the game (the service refuses or does not answer in time), the Hub opens anyway and nothing is shown as paused. In both cases your game keeps running under the Hub, sees no input, and is never told. **Write for both**: frozen is the normal case, running without input is the other.
- The game **in front** is the one frozen: any game the console started for the signed-in profile, including SDL and pygame games whose window the shell cannot match to a running app (T-467).
- Time under the Hub does not count as play time ([What the console records](play-time.md)).

### What your game experiences while it is frozen

The freeze is the Linux cgroup freezer (`systemctl freeze` on the game's unit and on every active Flatpak scope of the app, so both scopes of an Electron app are frozen). It is **not** `SIGSTOP`: no signal arrives and there is no handler to run. Your threads simply do not get the CPU. The table says what that means; "measured" is explained below the table.

| Aspect | What happens | Basis |
|---|---|---|
| Code | Nothing runs: no thread, no timer callback, no signal handler, no frame. The process cannot save, answer or draw. | measured |
| The clocks | `CLOCK_MONOTONIC`, `CLOCK_REALTIME` and `CLOCK_BOOTTIME` keep running: after 6 s frozen all three had advanced 6.085 s between two loop iterations. The CPU-time clock (`CLOCK_PROCESS_CPUTIME_ID`, `clock()`) did not move. SDL's tick counter and Qt's `QElapsedTimer` are monotonic: they jump too. | measured |
| Timers | They expire while you are frozen and fire late, once you run. A `timerfd` with a 1 s period reported 6 expirations in its first read after the thaw (one read, count 6); a `select` or `sleep` returns when you run, not when it was due. | measured |
| Sockets | They stay open and keep their queued data. After the thaw you read everything that arrived, at once (6 pings in one read). The peer sees silence: a peer with a 3 s timeout would have dropped you (in the test it only noted that, and the game was answered normally afterwards). A real server, a NAT or a Wi-Fi access point may drop the connection sooner or later, **so treat every network connection as lost after a pause** and expect a reset or end-of-file on your first read. | measured on loopback; the rest is how TCP and servers behave |
| Signals | A signal sent to a frozen process is delivered when it runs again. The console never relies on that: **Close game thaws first** and then sends `SIGTERM`. | measured |
| Window | The connection to the compositor stays open and the compositor keeps showing your last committed frame. You commit nothing while frozen. | the compositor code |
| Sound | Your PulseAudio stream is not fed. The console also **parks your playback stream** (T-466): it moves it to a silent null sink, so the sound card has nothing to play and goes idle, and moves it back where it was when you are thawed (back to the console's default output, or to the output it had been moved to). Your stream stays open; you see no error, no disconnect and no event. After **5 s** with no sound from you, the sound server **pauses your stream** (it stops reading it, so its read position stops) and resumes it at your next write; at the thaw you are asked for at most about 5 s of sound, however long the freeze (RUY-425: before, a stream with `prebuf` 0, such as OpenAL-soft's, was asked for the whole freeze's worth at once, and a game aborted inside libpulse after almost 2 hours). The same pause applies to any stream of yours that underruns for 5 s while you run; the 5 s are a tuning value that may change. A stream is parked only while no other game of the same profile runs, so a game that plays is never silenced by a frozen one. The console thaws you first and moves the stream back right after, so the sound you write in the first moment after the thaw (until the stream is back, expected well under a second) goes to the null sink and is not heard; there is no burst of old sound. Your code does nothing. While a game is parked, a null sink `ruya-parked` can appear in the sink list: do not enumerate, select or rely on it; its name and existence are not an API. Do not move your stream by hand. Not yet heard on hardware. | the code (`ruya-devices` `park.rs`; the pause: `pulse.idle.timeout` in `ruya-profile-pulse.conf`); VM check pending, not yet heard on hardware |
| Memory | When you have been frozen for **30 seconds** and the console has swap (the image has compressed zram swap since T-465), the console asks the kernel to move about half of your memory out to it (`memory.reclaim`, T-466; "about half" and the 30 seconds are tuning values that may change); the kernel takes the pages you used least recently. Nothing is lost and you are not told: the pages come back when you touch them, so the first frames after a long pause can take a little longer (the lead's study on the test machine: the thaw of a racing game of about 1 GB took about 0.2 s and 42 MB came back within 0.4 s). Never at the moment the Hub opens, and not without swap. The console cannot tell whether the Hub is still open over you, so 30 seconds under the Hub count too. | the code (`ruya-session` `session.rs`, `RECLAIM_AFTER`); study (lead); VM check pending |
| Files | Nothing happens to open files. A write in flight is not completed by anyone, so your data on disk is whatever you had flushed. | how the freezer works |

*Measured:* a stand-in game (a Python 3 program in a transient systemd user service, fed by a TCP peer outside it) was frozen with `systemctl --user freeze` for 6 s and thawed, on Fedora 44 under WSL, systemd 259, on 2026-11-11. It is not a Flatpak and not a Wayland client, so the Wayland rows are not in it. The freeze call took 0.5 s that run (the machine was busy building an image); the thaw call took 7 ms.

**How long the freeze and the thaw take.** The Hub opens at once and then asks the session service to freeze you: the freeze lands a moment later (in the test above 0.5 s, and the service gives up on each step after 5 s, an internal limit that may change), so your game can run for a few frames under the open Hub before it stops. The thaw is quick (7 ms in the test above; about 200 ms for a large game on the test machine). A key the player presses in that moment waits in your Wayland connection until you run (expected from how sockets work; not checked on the console).

### What your game is told

**Nothing you can rely on.** The compositor's Wayland code sends your window the fullscreen state and a size when it is created, and never the `activated` or `suspended` `xdg_toplevel` states or any other state change ([spec 03 section 4.6](../specs/03-services-and-apps.md) plans them; do not use them). When the Hub opens the shell moves the keyboard focus from your window to the Hub. Whether your toolkit then reports a focus loss to you (`SDL_EVENT_WINDOW_FOCUS_LOST`, Qt's `applicationStateChanged`, Godot's `NOTIFICATION_APPLICATION_FOCUS_OUT`) has **not been checked on the console yet**: it may arrive just before the freeze, or not at all; and if it is sent while you are frozen you receive it after the thaw, in order, with the focus coming back right behind it. After the thaw you get no "resumed" call. What you can always see is the **gap**: your loop ran, and the monotonic clock says several seconds, minutes or hours have passed.

### What to do

1. **Detect the pause from the clock, not from an event.** Measure the time between iterations of your main loop. A gap longer than about a second (a frame is never that long) means the console had you frozen (or suspended). Handle it in one place.
2. **Clamp the time step.** Use `min(gap, 0.1 s)` for simulation and physics so nothing teleports and no timer fast-forwards. The sample does this (`dt`), and with it the player's play time in the game does not grow while the game is frozen.
3. **Do not resume gameplay by itself after a long gap.** Pause your own game on the gap (a pause menu, the way every console game does) and let the player press a button to continue. Do the same on a focus-loss event **if** your toolkit sends one: that is also the only signal you get when the setting is off or the freeze failed, where you keep running with no input under the Hub.
4. **Re-check the clocks your game keeps.** Cooldowns, timeouts, "daily" resets and cut-scene timers that compare against the monotonic clock all see the gap. Wall-clock time (`CLOCK_REALTIME`) also advanced, as it does on any pause. A video or audio stream that follows a clock should seek or restart, not fast-forward to catch up.
5. **Treat network connections as dropped.** Online games: after a gap, check the connection, reconnect and re-sync with the server before play continues; keep any "you were disconnected" screen short. Do not hold a lock or a lobby slot on the server that needs your replies in time. Offline games need nothing.
6. **Save at safe points.** A frozen game cannot react to anything. Close game does thaw it first and gives it the 5 seconds of [Stopping](#stopping-quit-crashed-killed), but a power cut, the out-of-memory killer or a crash while you are frozen give you no chance. Write the player's progress at checkpoints ([Saves and data](saves-and-data.md)) instead of counting on being told.
7. **Do not try to refuse or prevent the pause.** There is no call to say "do not freeze me" (the player's setting is the only switch), and the Hub is the player's way out.

```python
import time

MAX_STEP = 0.1       # the longest time step the simulation takes, in seconds
PAUSED_GAP = 1.0     # a gap this long means the console had us frozen

last = time.monotonic()     # set this again just before your main loop, so loading is not taken for a pause

def frame_step():
    global last
    now = time.monotonic()
    gap, last = now - last, now
    if gap > PAUSED_GAP:
        on_resumed(gap)          # your function: pause menu, check the connection, re-sync clocks
    return min(gap, MAX_STEP)
```

**Test it:** on a RuyaOS dev machine, as root, freeze and thaw your running game the way the Hub does ([Testing and debugging](testing-and-debugging.md)). **Planned:** lifecycle events for apps ("going to the background", "frozen", "closing") are a possible public API (T-279, [The public surface](api-surface.md)); today there are none.

## Stopping: quit, crashed, killed

When the player chooses "Close game" in Ruya Hub, or the console must stop it, the shell calls `Session1.Stop(instance)`. `ruya-session` then:

1. if your game is frozen (the Hub froze it, or it sat frozen behind Home), **thaws it first**, so that it can handle the signal;
2. stops the unit and the scope with `systemctl --user stop`: **SIGTERM** to every process of your app;
3. waits **5 seconds** (`STOP_GRACE`, counted from the moment the `SIGTERM` is sent, after the thaw (T-466), so a slow thaw of a large game does not shorten the time you get);
4. if anything is still running, sends **SIGKILL** to the whole group.

Then it announces `AppExited(instance, app_id, exit_code, reason)` and the shell updates. The `reason`:

| reason | When | What the player sees |
|---|---|---|
| `quit` | after `Stop`, the app ended within the grace (by itself with any exit code, or by the SIGTERM); or, without a `Stop`, exit status 0 | nothing |
| `killed` | the 5 seconds passed and the console had to kill it; or something outside killed it (a signal, the out-of-memory killer) | nothing in v1, an unsaved game may be lost |
| `crashed` | it exited with a non-zero status without being stopped | the toast "<name> stopped unexpectedly" |
| `launch-failed` | it never got as far as running (for instance its Flatpak runtime is missing; a game that starts and then fails exits non-zero and is `crashed`) | the same toast |

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
- **Switching profiles:** **planned** (T-165): the previous profile's apps are suspended and hidden, and come back when that profile signs in again. A suspended game is frozen, not told: save when the player reaches a checkpoint instead of relying on being warned. Today, "Switch profile" in the Hub closes the Hub first (your game is thawed) and your game keeps running behind the profile picker; a game already frozen behind Home stays frozen until its profile is signed in again and the player brings it to the front.
- **A game frozen for a long time:** besides a Hub that is left open, a game can sit frozen behind Home for as long as the console runs. If the console restarts its shell meanwhile, the frozen game is thawed at the next sign-in (the shell's sweep, `02` section 1.6), and you simply see a long gap.

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
- [ ] The time step is clamped, and a gap of a second or more (the Hub froze the game) pauses your own game or at least re-syncs timers, instead of fast-forwarding or teleporting.
- [ ] The game pauses by itself when its toolkit reports a focus loss (the Hub with "Pause games" off leaves it running under the Hub, without input).
- [ ] After a long gap every network connection is checked and, if needed, re-established before play continues; offline play needs nothing.
- [ ] Progress is saved at checkpoints, not only on `SIGTERM`: a frozen game can also be ended by a power cut or the out-of-memory killer.
- [ ] Tested with a freeze of 10 seconds and one of 10 minutes ([Testing and debugging](testing-and-debugging.md)).
- [ ] `SIGTERM` saves within a second or two and exits with status 0, also as the first thing it sees after a long freeze; nothing waits for a dialog on shutdown.
- [ ] No exit button, no "home" button, no use of Esc or B to quit.
- [ ] A game that cannot open a window exits with an error message, it does not hang.
- [ ] Menus work with a controller only, with a visible focus.

## Sources

Checked on 2026-11-11 against: `api/dbus/org.ruyaos.Session1.xml`; `services/ruya-session/src/spawner.rs` (`launch_command`, `unit_name`), `systemd.rs` (stop and kill through `systemctl`), `session.rs` (`STOP_GRACE`, `exit_reason`), `main.rs` (no display env outside the dev mode); `shell/compositor/Compositor.qml` (`sendFullscreen`); `shell/src/input/KeyRouter.h`; `docs/specs/02-shell.md` sections 1.5, 4.3; `docs/specs/04-design-system.md` sections 1, 2; `docs/specs/00-overview.md` ADR-002 (T-123 result), ADR-004; `docs/specs/03-services-and-apps.md` sections 4.1, 4.6; task files T-147, T-164, T-165, T-166, T-198; `docs/dev-setup.md` (display and T-166 status); the SIGTERM tests described above (WSL, `samples/hello-game`); for the pause (T-468): `services/ruya-session/src/session.rs` (`freeze`, `thaw`, `stop` thawing first, the grace's clock read after the thaw since T-466; `RECLAIM_AFTER`, `tick`, `sync_audio`), `spawner.rs` (`reclaim_command`, `RECLAIM_PERCENT`, `park_audio_command`), `services/ruya-devices/src/park.rs` (which streams are parked and how they go back), `systemd.rs` (`freezer`: `systemctl --user freeze|thaw` on the unit and its active scopes, each bounded to 5 s), `dbus.rs` (Freeze and Thaw in order); `shell/qml/HubPause.qml`, `shell/qml/Shell.qml` (`hubPause`, `closeApp`, `foregroundInstance`: no play time while the Hub is open, `fallbackFront`), `shell/src/settings/DeviceSettings.cpp` (`hub/pauseGames`); `shell/compositor/Compositor.qml` (only `sendFullscreen`, no `activated` or `suspended` state); `docs/specs/02-shell.md` section 1.6; ADR-033; `docs/specs/03-services-and-apps.md` section 4.1; `samples/hello-game/src/main.c` (`dt` clamp); a freeze test on 2026-11-11 (Fedora 44 under WSL, systemd 259, a Python stand-in game in a transient user service: clocks, timers, sockets, signals, freeze 0.5 s and thaw 7 ms). **Not checked:** what a Wayland client receives around the freeze (keyboard leave and enter, frame callbacks), a Flatpak game, a game's sound, and the numbers on real hardware.
