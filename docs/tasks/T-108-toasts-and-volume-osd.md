# T-108 — Toast notifications and volume OSD

Status: done · Phase: 1 · Depends: — · Area: shell · Size: S

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
- [x] `Notifications.show()` while the PIN pad is open does not change `activeFocusItem` (test `tst_system_ui.qml::test_toast_never_steals_focus`).
- [x] 5 rapid toasts → at most 3 visible; all 5 are shown eventually (test `test_toast_queue`).
- [x] VolumeUp from home raises the mock volume by 5 and shows the OSD; the OSD hides by itself (test `test_volume_keys`).
- [x] Volume keys work while a modal is open, and the modal keeps focus (test `test_volume_keys_in_modal`).
- [x] Volume clamps at 0 and 100 (test `test_volume_clamps`).
- [x] Screenshot `14-toast-and-osd.png`.

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
Built toasts, the volume OSD and a mock `Audio` singleton.

- `shell/qml/Notifications.qml` (singleton, `QT_QML_SINGLETON_TYPE` in CMake): `show(text, kind, iconText)`, an on-screen `model` (max 3), a `pending` queue, `dismiss(id)`, `shownCount`, and `durationMs` (defaults to `Theme.toastMs`; the queue test shortens it).
- `shell/qml/ToastLayer.qml`: non-focusable `ListView` with add/remove/displaced transitions; each toast has a timer that dismisses it.
- `shell/qml/VolumeOsd.qml`: shows on `Audio.adjusted`, hides after `Theme.osdMs`.
- `shell/src/audio/`: `AudioBackend.h`, `MockAudioBackend`, `Audio` facade (`volume`, `muted`, `mock`, `setVolume`, `stepVolume`, `toggleMute`, `adjusted()`). Same pattern as Profiles, but `create()` always builds the mock because no D-Bus backend exists yet (out of scope).
- `Theme.qml`: `toastMs`, `osdMs`, toast kind colours and background.
- `Shell.qml`: `ToastLayer` (z 10), `VolumeOsd` (z 30), picker and Guide overlay at z 20, and three `Shortcut`s for the volume keys.
- `tests/tst_system_ui.qml`: `test_toast_never_steals_focus`, `test_toast_queue`, `test_toast_kind_falls_back_to_info`, `test_volume_keys`, `test_volume_keys_in_modal` (PIN pad and Guide overlay), `test_volume_clamps`, `test_zz_screenshots` (`14-toast-and-osd.png`).
- Docs: `02-shell.md` §1 and new §5.1; `shell/CLAUDE.md` build pitfall.

Verification: `dev.ps1 test` → ALL GREEN (38 passed, 4 screenshot tests skipped without `RUYA_SHOTS_DIR`); `dev.ps1 shots` → 42 passed. `14-toast-and-osd.png` reviewed: three stacked toasts with kind colours, OSD bottom-centre, text readable, focus ring still on the tile.

Deviations and notes:
- **Volume keys use `Shortcut`, not key handlers in each modal.** A `Shortcut` is matched before key delivery, so no modal can swallow the keys and nothing needs forwarding (this replaces the `SystemKeys.js` hint). Context is `Qt.ApplicationShortcut`. Verified under the QtQuickTest window on Windows; on a Wayland compositor with an app window focused it is unverified.
- The task text says the audio contract comes from T-113; on the board it is T-114.
- The OSD overlaps the bottom edge of the shelf while visible; it is transient, so left as is.
- Stepping the volume while muted does not unmute (not specified).
- Toasts have no Back/dismiss key by design (not focusable); they time out.
