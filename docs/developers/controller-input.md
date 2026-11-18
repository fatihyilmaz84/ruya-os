# Controller input and the Guide button

A console game is played with a controller from the sofa. This chapter says what your game receives (a virtual Xbox 360 pad per controller, while your game is in front), what the console keeps for itself (the Guide button), and what is not finished (see "What is built"). The input code in the sample game works on any Linux desktop as well.

*Checked against the code as of 2026-11-13. Items marked **planned** are not built yet.*

## The rules

1. **Use SDL's gamepad API** (or the engine's, which wraps it): it knows hundreds of controllers, gives you the same button names for all of them (`SOUTH` is A on an Xbox pad and Cross on a PlayStation pad) and tells you when a pad is plugged in or unplugged.
2. **Support hot-plug.** The player turns a controller on after the game started, and a Bluetooth pad sleeps and reconnects. Open a pad when it is added, close it when it is removed, never assume pad 0 exists.
3. **A controller must be enough.** Menus, dialogs and the first start included. Keyboard and mouse are a fallback; do not assume a keyboard is attached ([Full screen and lifecycle](fullscreen-and-lifecycle.md) has the menu rules).
4. **Never use the Guide button** (the logo button in the middle: Xbox, PlayStation, Home). It belongs to the console: it opens Ruya Hub, which freezes your game ([Full screen and lifecycle](fullscreen-and-lifecycle.md)). Do not bind it, do not show "press Guide" hints.
5. **Use a dead zone** (about 20 %) on sticks, and let the D-pad do the same job as the left stick in menus.
6. **When a controller is connected, ignore the keyboard for gameplay.** Outside your game (the Hub over it, a desktop with a key-mapping tool) the same pad also types arrow keys and Enter; reading both moves a player twice. Keep keyboard and mouse for when there is no pad.
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
        if (!pad) { /* with a controller, ignore the keys (rule 6): outside the game the pad also types arrow keys */
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

## Xbox 360 wireless receiver

The Xbox 360 Wireless Gaming Receiver for Windows (Microsoft's, or a clone with the same USB ids) works with the in-kernel `xpad` driver (the image installs Fedora's `kernel-modules-extra` for it): nothing for you or the player to install, no firmware. The player pairs a pad with the sync button on the receiver and then the one on the controller; the console only explains this on its "no controller" screens. Your game sees each pad as an ordinary "Xbox 360 Controller" (one device per pad, up to four; the d-pad may be reported as four buttons), which SDL already maps, and pads come and go while the receiver stays plugged in. Nothing about the receiver reaches you. Not tested on real hardware yet (planned: the Dell). The Xbox One/Series Wireless Adapter is a different device and is not supported.

## What the console does with the same controllers

`ruya-inputd` is a small service that reads every gamepad and re-emits **navigation as keyboard keys** on a virtual keyboard, so that the shell (which only understands keys) can be driven by a pad. Your game never opens the physical pads (it has no access to them); it gets a virtual pad of its own (next section). The mapping, used while the console's own screens are in front:

| Pad | Key the shell receives |
|---|---|
| D-pad, left stick | arrow keys |
| A (south) | Enter |
| B (east) | Esc |
| Start | Menu |
| LB / RB | Page Up / Page Down |
| Guide (Mode) | the `HomePage` key, which the shell takes |

What this means for a game:

- **While your game is in front the pads type no keys** (only Guide, which goes to the console): the press arrives once, on your virtual pad.
- **B is Esc on the console's screens**, not in your game; still, do not quit on Esc (rule 7: a keyboard has one).
- **The Guide key never reaches you**, neither as a key nor as a pad button. The shell's `KeyRouter` takes it while your game is in front (Ruya Hub opens and, by default, freezes your game; it gets nothing while the Hub is open and receives input again when it closes).
- **This holds for every connected controller, and for a long press** *(experimental, RUY-11)*. Any pad's Guide button is the console's: a short press opens or closes Ruya Hub, holding it for 2 seconds switches the Hub to the power choices. Neither the press, the hold nor the release is sent to your virtual pads (`BTN_MODE` is declared on them so SDL's mapping applies, but it is never pressed), whichever pad it came from and whatever the player's controller profile says. **You cannot rebind, intercept or time it**, and a controller profile cannot map another button onto it. Do not wait for a Guide event to pause: the Hub freezes you (unless the player turned that off), it does not ask. Your game gets neither a Guide event nor any warning: under the Hub, frozen or not, your pads stay and are held in neutral (see "The pad comes and goes" below); only Home, the lock, a profile switch or the end of your game removes them. *VM check pending: `vm-input-check.sh guide`.*

## What your game sees: a virtual pad of its own

The console's input service (`ruya-inputd`, since RUY-3) makes the pads below, and the shell tells it which app is in front on every change (RUY-409: the route `app` while your game has the screen, `overlay` under the Hub or a system dialog, `locked` at the profile picker, `shell` at Home). Built and tested on the development machine against a mock service; the run in the VM (`scripts/vm-input-check.sh shell`) and the real-pad test on hardware (SuperTuxKart with a DualSense) are still to come, so treat the timings below as targets.

- **One virtual pad per player who joined**, while your game is in front: an Xbox 360 wired pad as far as your game can tell *(experimental, built RUY-121, VM check pending: `vm-input-check.sh players`)*. Pad *n* is player *n*, and pad 1 is the player who signed in. A controller that has not joined is not a player and **is not seen by your game** *(experimental, RUY-122)*: a new controller joins through the console's "Who's playing?" prompt, which opens when it connects or presses a button (your game is frozen meanwhile, see [Full screen and lifecycle](fullscreen-and-lifecycle.md)). **Do not build your own join flow** ("press A to join"): a controller that has not joined never reaches you, so such a screen would wait for nothing. A player who joins reaches you as a **new pad** `ruya-input/pad<n>` appearing while you run (hotplug), and a player who leaves through the Hub as that pad's **removal**; a controller that drops removes nothing while your game runs (below, *experimental, RUY-681*). If the player chooses **Not now**, that controller stays invisible to your game, and its button presses ask no more while this instance of your game runs; unplugging it and plugging it in again, or pressing its Guide button, asks again. The right design is a controller screen that follows hotplug: list the pads that are there and react when one appears or is removed (a removal is a player who left through the Hub, or the end of your run; a controller that drops is only silence, below). **Current limit** *(experimental, until RUY-628)*: a profile with a PIN, or one that is already playing, cannot join through the prompt yet. A player who leaves through the Hub is a removed pad; a dropped controller is not (its pad only goes silent). **The player key is the `phys` name, not the index**: `ruya-input/pad<n>` stays player *n* for the session. **Pad *n* is a seat, not a person** *(experimental, RUY-681)*: after a quiet phase another player may carry it, and your game gets no signal when that happens. Treat a pad as a controller slot (what your game binds to a player's car or character), not as a person's identity: do not keep per-person data (names, saves, unlocks) keyed on pad *n*. SDL's device index and instance id follow the order in which pads were made. **Player 1 is created first** *(experimental, built RUY-540, VM check pending)*: when your game comes to the front, every joined player's pad is made at once *(experimental, RUY-681, VM check pending: `vm-input-check.sh coop`)*, by player number: the pad that signed the profile in first (`ruya-input/pad1`, the lowest event node, SDL index 0, so a game that opens one pad gets it). Your game can open the others only once it can open player 1's pad, or after 2 s if the console could not confirm that *(experimental, RUY-541, VM check pending)*. SDL index 0 is pad 1 only for pads made together like this: a player who joins while your game is in front is added at once, as a new device with the next SDL index and the lowest player number your game has no pad for; a player whose pad is still there, quiet, from earlier in this run gets that pad back (below). Numbers can have gaps (player 2 left, player 3 stays pad 3), and live pads are never renumbered. **A player who moves to another controller** keeps the same pad *(experimental, RUY-627)*: the same device, node and SDL instance id, now fed by the other controller; a button the player holds on it as they move waits until it is let go. If the player signed in with the keyboard, there is no pad 1 until they pick a controller. Name `Ruya Xbox 360 Pad`, USB, vendor `045e`, product `028e`, version `0114`; the buttons A, B, X, Y, LB, RB, Back, Start, the Guide button (declared, never pressed), the two stick clicks; both sticks (-32768..32767), both triggers (0..255), the D-pad as a hat. SDL picks its built-in "Xbox 360 Controller" mapping for it, so you do not need a mapping line. Buttons follow their **position**: whatever the player holds (a DualSense, a Switch pad), the bottom button is A.
- **Only your game's profile can open it.** The node gets one access entry, for the Unix user of the profile your game runs as; another profile's game and the shell are refused. The physical pads stay closed to every game.
- **A controller that drops stays as an idle pad for up to 60 s and comes back as the same pad** *(experimental, RUY-627, VM check pending: `vm-input-check.sh seathold`)*. When a player's controller turns off, sleeps or runs flat, your pad is **not** removed: it stays, the same device and node, with one neutral frame (sticks centred, nothing pressed) and then nothing; rumble you play meanwhile is dropped, while effects you upload are kept. If that controller (or, for a serial-less USB pad plugged into another socket, the one like it) comes back within 60 s, the same pad carries its input again and your uploaded rumble effects work on it; you see no removal and no addition. After 60 s without it the player's seat ends, but **the pad stays, quiet, until your game ends** *(experimental, RUY-681, VM check pending: `vm-input-check.sh coop`)*: a game that does not survive a pad removed and made again (SuperTuxKart) keeps every pad it saw. When player 1's controller drops, the Hub opens over your game and pauses it *(experimental, RUY-38, VM check pending)*, which you see as any overlay; a dropping controller of players 2 to 4 pauses nothing. Your game is paused only when the Hub opens and when a controller that has not joined asks "Who's playing?" (below); a seated player's own play never pauses it. In detail:
  - **Rumble.** The effect ids you uploaded stay valid across the hold, the quiet phase after it and the return: do not upload them again. Plays are dropped while the pad is held or quiet. An effect playing when the controller dropped, or when the pad is taken over by another controller, is stopped and does not resume: send a new play. If uploading your effects to the returning controller fails, that effect is lost (the console only logs it); a play of it then does nothing.
  - **You cannot tell a held pad from an idle one.** There is no event and no flag: one neutral frame is written when the controller drops, and its return sends no event either, so whatever your game keeps of the pad's buttons and sticks is only as fresh as the last event you read.
  - **The same pad, maybe another controller.** After the return (also to another controller, a like USB pad or a player who moved), the pad keeps its `phys` (`ruya-input/pad<n>`), its event node and its fixed capabilities (the virtual pad's are always the same).
  - **After 60 s** the pad still stays, quiet, while your game runs *(experimental, RUY-681)*. When the player joins again ("Who's playing?"), the same pad carries their input again; a new player takes a player number your game has no pad for, and takes a quiet pad over only when every free number has one. The pad is removed when your game ends, the console locks or the profile switches, or the player leaves through the Hub.
  - **Off the console** your game sees no virtual pad, so nothing of this can be reproduced there; the shell's input mock models the seats only, not the quiet pads after the hold (`Input.mockRemoveDevice(id)`, then `Input.mockAddDevice({id: ...})` within the hold; `Input.mockSeatHoldMs(ms)` shortens it). To test your side, stop feeding your game input from a pad for a while without closing it: it must cope with no event at all.
- **The pad comes and goes**: it is destroyed when the player locks the console, switches profile, ends your game (after it has exited), or goes to another game, and a new one is made when your game is in front again. **Your own windows do not count as going away** *(experimental, RUY-814)*: the pad survives focus moving between the windows of your game (a launcher and the game it starts, a settings window), and when the last window closes while your game still runs it stays for up to 3 seconds (`windowGapMs`), so a game that closes one window and maps the next keeps the same pad. The 3 seconds end early when the next window appears, when your game exits, or when the player opens the Hub or goes Home on purpose; then the pad goes as above. Going Home while your game waits frozen, and Close game from the Hub or a card's Options menu, do **not** remove it before your game exits *(experimental, RUY-611, VM check pending: `vm-input-check.sh close`)*: a game that saves its controller choice on quit (LibreQuake wrote `joy_device -1` after seeing its pad removed) finds the pad it had. A game that is not frozen when the player goes Home loses its pad then, as before. On a removal your open descriptor reads `ENODEV` and SDL reports the pad as removed: rule 2 (hot-plug) is what keeps your game working. The new pad is a new device to SDL: its instance id (`SDL_JoystickID`) and its player index are new each time, so never cache them, a device path or a node name across a removal; keep your own per-player state and give it to whichever pad is added next. Ruya Hub does **not** remove it, also when it freezes your game *(experimental, RUY-541, VM check pending: `vm-input-check.sh shell`)*: after the Hub you read the same pad, with nothing but one neutral frame (sticks centred, nothing pressed) queued from the time you were frozen.
- **How soon it is back.** Under an overlay, whether it leaves your game running or freezes it, the pad stays (held in neutral) and nothing comes or goes. After Home with a game that was not frozen, the lock or a profile switch, the new pad is made the moment your game is in front again and can be opened as soon as the console has set its access entry, typically well under a second (measured in the VM, `scripts/vm-input-check.sh`); SDL's hot-plug sees it then.
- **While an overlay is open** over your game (Ruya Hub, a system dialog), the pad is held in neutral: sticks centred, nothing pressed, written once when the overlay opens and then nothing until your game is back in front. When your game is back in front, a button the player still holds (the A that closed the Hub) does not reach you until it is let go.
- **Guide never reaches you**, and while your game is in front the pads produce **no keyboard keys** any more (only Guide, for the shell): the double input of the table above ends.
- **No legacy joystick API.** There are no `/dev/input/js*` nodes on RuyaOS (the `joydev` module is never loaded: those nodes would be readable by every user). Read pads through evdev, as SDL, Wine and Proton do.
- **Without `--device=input` (or `all`) there is no pad at all** on another system: the sandbox then has no `/dev/input`. On RuyaOS the console adds `--device=input` to every app it starts *(experimental, RUY-837, VM check pending: `vm-input-check.sh startpad`)*, because many games are packaged without it; still ask for it in your manifest (see "Flatpak permission" below), so your game works everywhere and the Store tells the player it uses controllers. The grant shows you only your own player pads: every other node in `/dev/input` stays closed to your user.
- **Your pad is there before your first frame** *(experimental, RUY-837, VM check pending: `vm-input-check.sh startpad`)*: the console makes the player pads, and sets their access, before it starts your game (it waits at most a second for that), so a game that looks for controllers only once at start-up finds them. Rule 2 (hot-plug) still matters: a pad can come and go later (below).
- **Rumble**: the basic left and right motors (`FF_RUMBLE`), forwarded to the physical pad while your game is in front, when that pad can rumble. Gyro, touchpad, lights and adaptive triggers are not there (T-373).

## The player's controls: what your game sees is already remapped

> **Experimental.** The behaviour and the file format below are public ([tier C](api-surface.md#tier-c-data-only-formats), ADR-022) but may change without notice until the first release. Built in the service (RUY-42) and tested on the development machine; the run in the VM is pending (`scripts/vm-input-check.sh`), and the player edits these settings in Settings > Controllers > Controls in games (RUY-465).

The player can change their controls for every game at once: a Nintendo button layout, any button moved to another, and per stick a dead zone, a response curve, a sensitivity and inverted axes. The console applies this **before** your game reads the virtual pad, so you receive the player's choice and must not undo it:

- **The sticks arrive with a dead zone already applied** (by default 8 % in the middle and 2 % at the edge, round, rescaled so that the full range still reaches ±32767). Keep your own dead zone small (rule 5's 20 % is for pads that reach you raw); on RuyaOS a resting stick reads exactly 0.
- **A button may not be where its label is.** With the Nintendo layout the bottom button (A on your Xbox-style pad) is what the player presses on the right. Show button hints by function and position ("A"), as rule 1 says; never print a physical label you guessed from the controller's name.
- **Guide is never remapped onto your pad**, and the console's own screens keep their buttons whatever the player set for games.
- **Changes apply at once**, also while your game is running: a pad's state can change between two frames without the player touching it (a button the player holds is released and the new one pressed). Treat it like any other input change.

**The profile format** is the one the console stores and will export to a USB drive, so a player can keep and share their controls: JSON, `schema_version` 1, described by [`docs/specs/schemas/input-profile-v1.json`](../specs/schemas/input-profile-v1.json) (the design is `06-input.md` section 7). A profile lists only what differs from its parent (`inherits`; the console's built-ins are `default` and `nintendo`), may be limited to one controller family or one controller (`match`), and holds data only: nothing in it is ever run. Each controller is mapped by its own profile *(built RUY-545, VM check pending)*: the player's profile for that controller, else for its family, else for all controllers, so two virtual pads in your game can map the same button differently. A profile without `match` is the one for all controllers. The console checks every file on load, save and import, refuses unknown fields and says why in `path: message` lines; it also refuses what a schema cannot express: more than 64 KiB, macro waits over 10 s in all, a macro step without its target or `ms`, a macro inside a macro, a `button` or `axis` target that is not one of the pad's, inner and outer dead zones that leave nothing between them, a profile that inherits from itself, an `id` starting with `controls-` on a profile that is not global (below), and names with control or text-direction characters. What the console applies today: buttons and sticks to buttons, sticks, triggers or nothing (with `invert`, `scale` and `threshold`), the stick settings and `trigger_threshold`. Keys, mouse, layers, chords, macros, turbo and the other modes, motion and `smoothing` are stored and checked but not applied yet (planned: T-372, T-373); the input then keeps its default.

This file is also `samples/controller-profile-example/profile.json`, and the console's checks run on it (`services/ruya-inputd/tests/profile_schema.rs`):

```json
{
  "schema_version": 1,
  "id": "my-controls",
  "name": "My controls",
  "description": "Nintendo layout, jump on L1, a softer left stick, the right stick's up and down inverted.",
  "scope": { "type": "global" },
  "inherits": "nintendo",
  "match": { "family": "playstation" },
  "mappings": [
    { "from": "l1", "to": { "type": "button", "code": "south" } },
    { "from": "right_y", "to": { "type": "axis", "code": "right_y", "invert": true } }
  ],
  "settings": {
    "left_stick": { "inner_deadzone": 0.12, "curve": "precise" },
    "trigger_threshold": 0.1
  }
}
```

**Stick maths** (06-input.md section 7): with `r` the stick's distance from the centre (0..1), `r' = clamp((r - inner_deadzone) / (1 - inner_deadzone - outer_deadzone), 0, 1)`; the curve gives `c` = `r'` (linear), `r'²` (precise) or `√r'` (aggressive); the output is 0 when `r'` is 0, else `anti_deadzone + (1 - anti_deadzone) · c`, times `sensitivity`, at most 1, in the stick's own direction; `invert_x` and `invert_y` flip an axis afterwards. A trigger uses `trigger_threshold` as its dead zone.

**Reserved ids:** an `id` starting with `controls-` names the console's own global slots, so only a profile with `scope.type` `global` may use it; the console refuses any other scope with such an id (`/id: the "controls-" prefix is reserved for global profiles`), so an imported file can never replace a controller's own profile. A stored file that breaks the rule is skipped at load with a journal line and left on disk unchanged. A plain schema validator does not catch this rule.

**To check a file off the console:** any JSON Schema 2020-12 validator with the schema above covers everything but the extra rules; `ruya-inputd --session` (on a Linux desktop) answers `org.ruyaos.Input1.ValidateProfile` on the session bus with the console's own verdict. Games do not read or write these files; the console's settings do.

## What is built, and what is not

**Verified in the VM** (T-130, `scripts/vm-app-check.sh` with `vm-key-client.qml`): a Wayland client full screen in the shell receives keyboard events (letters from the keyboard), and the Guide key (Super, or the pad's `HomePage`) opens the overlay over the client instead of reaching it.

**Built, VM check pending:** pad access for a game running as a profile. The physical pads stay closed to profile users (the device rules, `70-ruya-input.rules`, spec 01 section 2.1, give only the shell's session and `ruya-input` an access entry); the virtual pad of the section above is the way in. The service half is checked in the VM with a test pad (`scripts/vm-input-check.sh check`); the shell's half (who is in front) is tested on the host against the mock service (`shell/tests/tst_input_route.qml`), and its VM run (`vm-input-check.sh shell`: the test app in front gets a virtual pad, the Hub's pause keeps the same one, RUY-541, and Lock takes it away) and the hardware race are pending.

**Conformance (ADR-022):** the virtual pad is the public raw surface; `scripts/vm-input-check.sh` is its conformance test. `vm-input-probe.py check` opens the pad as the game's profile user and checks its name `Ruya Xbox 360 Pad`, id `0003:045e:028e:0114`, keys, axes and rumble, that another profile's user and the shell are refused, that Lock makes an open descriptor read `ENODEV`, and that no `js*` node exists; `vm-input-check.sh shell` checks that the shell's route makes the pad when your game is in front, keeps the same pad (event node) under the Hub's pause with no `destroyed` in the journal (RUY-541), and removes it at Lock.

**Not built, so not verified:**
- **A game window at all** (T-164). Without it no input path can be tested end to end.
- **Steam Input.** Steam grabs controllers too; it will consume the virtual Xbox-style pads normally (spec 03 section 5) or own the pads in its own mode (06-input.md section 5.3). **Planned**, together with the check that nothing is handled twice.
- Rumble, gyro, touchpad, LEDs, battery of a pad from inside a game: not tested. The console shows each pad's battery itself (spec 03 section 2.1).
- Player assignment *(experimental, built RUY-540 and RUY-121, VM check pending)*: the pad that signed the profile in is "player 1" for that profile (spec 03) and is the game's `ruya-input/pad1`; the other players are the pads that joined, `ruya-input/pad<n>` for player *n*. Read the player number from the `phys` name, not from the SDL index: the index is 0 for pad 1 only when the pads were made together (your game came to the front), and a pad made later (a join, a move, a reconnect) gets the next index. Choosing who joins happens in the console's "Who's playing?" prompt *(experimental, RUY-122)*; a controller that did not join never reaches your game. Every player's pad belongs to your game's user: you cannot tell which profile a player is, and their input is just another pad to you. A game gets no player-number API yet. If a player's controller is unplugged while your game is in front, their pad stays for 60 s and is the same pad when the controller comes back *(experimental, RUY-627)*; after that it goes away and does not come back by itself.

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

Checked on 2026-11-13 against: `man flatpak-build-finish` (Flatpak 1.18.4); `services/ruya-inputd/src/mapping.rs` (the key map), `routing.rs` (routes, virtual pads, rumble, the profile applied), `pad.rs` (the virtual pad's identity, keys and axes), `profile.rs`, `engine.rs` and `book.rs` (the profile format, the stick maths, the built-in profiles), `tests/profile_schema.rs`; `image/rootfs/usr/lib/udev/rules.d/70-ruya-input.rules` and `74-ruya-input-acl.rules`, `image/rootfs/usr/lib/modprobe.d/ruya-no-joydev.conf`; `scripts/vm-input-check.sh` and `vm-input-probe.py` (what a profile user can open and read); `docs/specs/06-input.md` sections 1, 3, 5; `services/ruya-profiles/src/accounts.rs` (`useradd` with no extra groups); `shell/src/input/KeyRouter.h`, `shell/qml/InputRoute.qml` and `shell/src/input/Input.cpp` (the route the shell sends), `shell/tests/tst_input_route.qml`; `docs/specs/00-overview.md` ADR-003; `docs/specs/01-platform.md` section 2.1; `docs/specs/03-services-and-apps.md` sections 2.1, 5; `services/ruya-store/src/appstream.rs` (`--device=input` is "gamepad", `all` is "all-devices"); `scripts/vm-app-check.sh`; `docs/STATUS.md` (B-006); the sample's input code, built against SDL 3.4 in the freedesktop 26.08 runtime and exercised headless (hot-plug and the pad paths were not run: no pad in the test environment).
