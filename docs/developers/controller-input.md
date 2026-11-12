# Controller input and the Guide button

A console game is played with a controller from the sofa. This chapter says what your game receives, what the console keeps for itself (the Guide button), and what is not finished: **a game running as a profile does not yet get access to the pads** (see "What is built"). The input code in the sample game works on any Linux desktop today.

*Checked against the code as of 2026-11-12. Items marked **planned** are not built yet.*

## The rules

1. **Use SDL's gamepad API** (or the engine's, which wraps it): it knows hundreds of controllers, gives you the same button names for all of them (`SOUTH` is A on an Xbox pad and Cross on a PlayStation pad) and tells you when a pad is plugged in or unplugged.
2. **Support hot-plug.** The player turns a controller on after the game started, and a Bluetooth pad sleeps and reconnects. Open a pad when it is added, close it when it is removed, never assume pad 0 exists.
3. **A controller must be enough.** Menus, dialogs and the first start included. Keyboard and mouse are a fallback; do not assume a keyboard is attached ([Full screen and lifecycle](fullscreen-and-lifecycle.md) has the menu rules).
4. **Never use the Guide button** (the logo button in the middle: Xbox, PlayStation, Home). It belongs to the console: it opens Ruya Hub, which freezes your game ([Full screen and lifecycle](fullscreen-and-lifecycle.md)). Do not bind it, do not show "press Guide" hints.
5. **Use a dead zone** (about 20 %) on sticks, and let the D-pad do the same job as the left stick in menus.
6. **When a controller is connected, ignore the keyboard for gameplay** (see "What is built" for why). Keep keyboard and mouse for when there is no pad.
7. **Do not quit on Esc or Back.** On the console the B button also arrives as the Esc key. Leaving a game is the Guide's job; handle `SDL_EVENT_QUIT` and `SIGTERM` ([Full screen and lifecycle](fullscreen-and-lifecycle.md)).

## Example: SDL 3

Open and close pads as they come and go (from `samples/hello-game/src/main.c`):

```c
/* sample: samples/hello-game/src/main.c */
            case SDL_EVENT_GAMEPAD_ADDED: /* hot-plug: a pad appears at any time */
                if (!pad) {
                    pad = SDL_OpenGamepad(e.gdevice.which);
                    printf("hello-game: controller connected: %s\n", pad ? SDL_GetGamepadName(pad) : "?");
                }
                break;
            case SDL_EVENT_GAMEPAD_REMOVED:
                if (pad && SDL_GetGamepadID(pad) == e.gdevice.which) {
                    SDL_CloseGamepad(pad);
                    pad = NULL;
                    printf("hello-game: controller removed\n");
                }
                break;
            case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
                if (e.gbutton.button == SDL_GAMEPAD_BUTTON_SOUTH) { /* A / Cross */
```

Read the sticks and the D-pad each frame, and fall back to the keyboard only when there is no pad:

```c
/* sample: samples/hello-game/src/main.c */
        if (!pad) { /* with a controller, ignore the keys: today the console also sends the pad as arrow keys */
            if (keys[SDL_SCANCODE_LEFT] || keys[SDL_SCANCODE_A]) dx -= 1;
        } else {
            dx += deadzone((float)SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX) / 32767.0f);
            dy += deadzone((float)SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTY) / 32767.0f);
            if (SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_LEFT)) dx -= 1;
```

SDL already includes mappings for common controllers. For one it does not know, add a mapping line (SDL's `SDL_GAMECONTROLLERCONFIG` format: GUID, name, then `button:source` pairs). An example line (an Xbox 360 pad on Linux; take real lines from SDL's `gamecontrollerdb.txt`):

```sh
export SDL_GAMECONTROLLERCONFIG='030000005e0400008e02000014010000,Xbox 360 Controller,a:b0,b:b1,back:b6,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b8,leftshoulder:b4,leftstick:b9,lefttrigger:a2,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b10,righttrigger:a5,rightx:a3,righty:a4,start:b7,x:b2,y:b3,platform:Linux,'
```

In a Flatpak set it with `--env=SDL_GAMECONTROLLERCONFIG=...` in `finish-args`, or call `SDL_AddGamepadMapping` from code. Unity, Godot, Unreal and SDL-based engines have the same idea in their own input settings.

## What the console does with the same controllers

`ruya-inputd` is a small service that reads every gamepad and re-emits **navigation as keyboard keys** on a virtual keyboard, so that the shell (which only understands keys) can be driven by a pad. It does **not grab** the pads: your game sees the real device as well. The mapping:

| Pad | Key the shell receives |
|---|---|
| D-pad, left stick | arrow keys |
| A (south) | Enter |
| B (east) | Esc |
| Start | Menu |
| LB / RB | Page Up / Page Down |
| Guide (Mode) | the `HomePage` key, which the shell takes |

What this means for a game **today** (until the virtual pads above are switched on, RUY-409):

- **Every pad press can reach your window twice**: as the pad's own events and as a key press. If you read both, a held stick moves the player twice as fast and A fires twice. Read the pad when there is one (rule 6).
- **B arrives as Esc** (rule 7).
- **The Guide key never reaches you as a key.** The shell's `KeyRouter` takes it first while an app is in front (Ruya Hub opens and, by default, freezes the app; the app gets nothing while the Hub is open and receives input again when it closes). The real pad still reports its Guide button through evdev, because nothing grabs it yet: ignore it.

## What your game will see: a virtual pad of its own (planned)

The console's input service (`ruya-inputd`) has the parts below since RUY-3, but the shell does not tell it yet which app is in front (RUY-409). Until then the service stays in its "shell" route and **creates no virtual pad**: everything in this section is **planned**, and the description is what the code does once the shell drives it.

- **One virtual pad per connected controller**, while your game is in front: an Xbox 360 wired pad as far as your game can tell. Name `Ruya Xbox 360 Pad`, USB, vendor `045e`, product `028e`, version `0114`; the buttons A, B, X, Y, LB, RB, Back, Start, the Guide button (declared, never pressed), the two stick clicks; both sticks (-32768..32767), both triggers (0..255), the D-pad as a hat. SDL picks its built-in "Xbox 360 Controller" mapping for it, so you do not need a mapping line. Buttons follow their **position**: whatever the player holds (a DualSense, a Switch pad), the bottom button is A.
- **Only your game's profile can open it.** The node gets one access entry, for the Unix user of the profile your game runs as; another profile's game and the shell are refused. The physical pads stay closed to every game.
- **The pad comes and goes**: it is destroyed when the player locks the console, switches profile, ends your game, or Ruya Hub freezes it, and a new one is made when your game is in front again. Your open descriptor then reads `ENODEV` and SDL reports the pad as removed: rule 2 (hot-plug) is what keeps your game working. Never keep a device path or a player number across a removal.
- **While an overlay is open** over your game (Ruya Hub, a system dialog), the pad is held in neutral: sticks centred, nothing pressed. When your game is back in front, a button the player still holds (the A that closed the Hub) does not reach you until it is let go.
- **Guide never reaches you**, and while your game is in front the pads produce **no keyboard keys** any more (only Guide, for the shell): the double input of the table above ends.
- **Rumble**: the basic left and right motors (`FF_RUMBLE`), forwarded to the physical pad while your game is in front, when that pad can rumble. Gyro, touchpad, lights and adaptive triggers are not there (T-373).

## What is built, and what is not

**Verified in the VM** (T-130, `scripts/vm-app-check.sh` with `vm-key-client.qml`): a Wayland client full screen in the shell receives keyboard events (letters from the keyboard), and the Guide key (Super, or the pad's `HomePage`) opens the overlay over the client instead of reaching it.

**Not built, so not verified:**

- **Pad access for a game running as a profile.** The device rules (`70-ruya-input.rules`, spec 01 section 2.1) give the *shell's session* an access control entry on the physical pads; profile users are not in the `input` group. So a game that `ruya-session` starts as `ruya-p<N>` cannot open a pad today, even with `--device=input` in its Flatpak. The virtual pad of the section above is the way in (**planned**: the service is built and checked in the VM with a test pad, `scripts/vm-input-check.sh`; the shell's half is RUY-409). Until then, the controller code in your game can be tested on a desktop, and on a RuyaOS machine only through the key events above.
- **A game window at all** (T-164). Without it no input path can be tested end to end.
- **Steam Input.** Steam grabs controllers too; it will consume the virtual Xbox-style pads normally (spec 03 section 5) or own the pads in its own mode (06-input.md section 5.3). **Planned**, together with the check that nothing is handled twice.
- Rumble, gyro, touchpad, LEDs, battery of a pad from inside a game: not tested. The console shows each pad's battery itself (spec 03 section 2.1).
- Player assignment: the first pad that presses Accept on the profile picker is "player 1" for that profile (spec 03); a game gets no player-number API yet.

**Flatpak permission:** ask for `--device=input` (Flatpak 1.18, the version in Fedora 44, lists `input` among the devices in `flatpak-build-finish(1)`; older Flatpaks only know `--device=all`). The Store shows it as "Uses game controllers". `--device=all` is shown as "High risk" and Standard profiles need an admin PIN to install it; do not use it for pads ([Permissions](permissions-and-sandbox.md)).

## Checklist

- [ ] Pads are opened on `SDL_EVENT_GAMEPAD_ADDED` and closed on `..._REMOVED`; the game starts and plays with no pad and with a pad plugged in later.
- [ ] Everything, menus included, can be done with a controller (A accept, B back, D-pad move).
- [ ] The Guide button is not bound anywhere.
- [ ] With a pad connected, keyboard input does not also move or act.
- [ ] Esc and B do not quit the game.
- [ ] Stick dead zone, and the D-pad works like the left stick in menus.
- [ ] No hint text names a keyboard key when a pad is in use (show "A", not "Enter").

## Sources

Checked on 2026-11-12 against: `man flatpak-build-finish` (Flatpak 1.18.4); `services/ruya-inputd/src/mapping.rs` (the key map), `routing.rs` (routes, virtual pads, rumble), `pad.rs` (the virtual pad's identity, keys and axes); `image/rootfs/usr/lib/udev/rules.d/70-ruya-input.rules` and `74-ruya-input-acl.rules`; `scripts/vm-input-check.sh` and `vm-input-probe.py` (what a profile user can open and read); `docs/specs/06-input.md` sections 1, 3, 5; `services/ruya-profiles/src/accounts.rs` (`useradd` with no extra groups); `shell/src/input/KeyRouter.h`; `docs/specs/00-overview.md` ADR-003; `docs/specs/01-platform.md` section 2.1; `docs/specs/03-services-and-apps.md` sections 2.1, 5; `services/ruya-store/src/appstream.rs` (`--device=input` is "gamepad", `all` is "all-devices"); `scripts/vm-app-check.sh`; `docs/STATUS.md` (B-006); the sample's input code, built against SDL 3.4 in the freedesktop 26.08 runtime and exercised headless (hot-plug and the pad paths were not run: no pad in the test environment).
