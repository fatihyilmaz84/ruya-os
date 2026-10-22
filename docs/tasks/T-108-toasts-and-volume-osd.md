# T-108 — Toast notifications and volume OSD

Status: todo · Phase: 1 · Depends: — · Area: shell · Size: S

## Goal
The system can show short, non-blocking messages ("Controller connected", "Update ready") and a volume indicator. Neither ever takes focus from what the user is doing.

## Read first
- `docs/specs/02-shell.md` §1 ("System UI" row), §5 (volume OSD)
- `shell/CLAUDE.md`

## Scope
1. `Notifications` QML singleton (pure QML is fine) with `show(text, kind)`, where kind is `info | success | warning | error`, plus an optional `iconText`. It queues messages.
2. `ToastLayer.qml` in `Shell.qml`, above pages and below modals:
   - toasts stack at the top-right inside the safe area, at most 3 visible;
   - each auto-dismisses after `Theme.toastMs` (4000 ms; a new token);
   - slide/fade in and out, respecting reduced motion if T-102 is done (otherwise use Theme durations).
3. Volume, with a C++ `Audio` singleton using the same backend pattern:
   - mock only for now (`volume` 0–100, `muted`), with `setVolume`, `stepVolume(delta)` and `toggleMute()`;
   - a D-Bus backend is **not** part of this task (T-113 defines the contract).
4. `VolumeOsd.qml`: appears on any volume change (bottom-centre), shows the level and the mute state, and hides after 1500 ms.
5. Keys `Qt.Key_VolumeUp`, `Key_VolumeDown` and `Key_VolumeMute` are handled at the `Shell` root in **every** state, including modals, and step by 5. Focus must not move.
6. Toasts and the OSD are not focusable (`activeFocusOnTab: false`, no `focus: true`).

## Out of scope
- Persistent notification centre / history.
- Real PipeWire volume (T-113 and the services).

## Acceptance criteria
- [ ] `Notifications.show()` while the PIN pad is open does not change `activeFocusItem` (test `tst_system_ui.qml::test_toast_never_steals_focus`).
- [ ] 5 rapid toasts → at most 3 visible; all 5 are shown eventually (test `test_toast_queue`).
- [ ] VolumeUp from home raises the mock volume by 5 and shows the OSD; the OSD hides by itself (test `test_volume_keys`).
- [ ] Volume keys work while a modal is open, and the modal keeps focus (test `test_volume_keys_in_modal`).
- [ ] Volume clamps at 0 and 100 (test `test_volume_clamps`).
- [ ] Screenshot `14-toast-and-osd.png`.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/02-shell.md` §1, §5: describe what exists.

## Hints
- Handle volume keys in `Keys.onPressed` of the `Shell` root **and** make modals forward them. Modals accept all keys, so they must explicitly let volume keys through, or call `Audio` themselves. A tiny shared JS helper (`SystemKeys.js`) avoids duplication.

## Outcome
_Filled in by the implementer._
