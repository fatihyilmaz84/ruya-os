# T-349 - Opening Settings is slow (esp. Store to Settings): build panes and modals lazily, measure on the Dell

Status: in-progress · Phase: 2 · Depends: — · Area: shell (SettingsPage, Shell page open/close, GlassSheet, singletons' first use, probe) · Size: M · Owner: builder (Opus recommended: QML refactor with focus risk)

## Goal
Owner report (Dell, 0.0.55, high tier, aurora wallpaper, 1080p): "a small delay when I go from Store to Settings; opening Settings seems demanding". A read-only analysis of the code (no timings yet) found the causes below. Fix them and prove it with numbers from the Dell.

## Causes (ranked, from the analysis; verify each in the code and measure before you cut)
1. `SettingsPage.qml:189-288` creates all ten panes eagerly (MyProfile, ManageProfiles, Display, Network, Bluetooth, Audio, Storage, PowerSaving, System, About), hidden by `visible: false` (comment at `SettingsPage.qml:8` and `StoragePane.qml:137` say by design): about 76 `SettingControl` rows, each with `GlassLayers` (tint, sheen, rim, grain image), roughly 600-900 items built in the key-press frame; `Shell.qml:31-73` `openPage` calls `component.createObject` synchronously and the 300 ms slide starts in the same call.
2. About 11 hidden modal subtrees are built eagerly: `TextEntry` x3 with the keyboard `Repeater`, `PinPad` x3 flows, `ZonePicker`, 2 x `ModePicker`, `WallpaperPicker` (501 lines, a `GlassSheet` each: a `ShaderEffectSource` of `Shell.l0`, a mask layer FBO, `SmoothMask`). Hypothesis (about 40 %): the first-frame shader/FBO creation stalls.
3. Eager refreshes in `Component.onCompleted` of hidden panes: `NetworkPane:54` `syncNetworks`, `AudioPane:49-55` `syncSinks` + `SoundThemes.refresh(usbMounts())`, `BluetoothPane:67` `syncDevices`, `SystemPane:130` `syncSensors`; and lazy C++ singletons (`Wallpapers`, `SystemDetails`, `Display`, `SoundThemes`) constructed on the first Settings open: check their constructors for synchronous IO.
4. The wallpaper blur fade overlaps the transition (shared cost, not Settings-specific).
5. Why Store to Settings is worse: the Store slot is destroyed at 300 ms (`reapIfDone`, `Shell.qml:1058`) in the middle of the glide, so the Store grid teardown and the Settings build collide.

## Scope
A. **Lazy panes:** `Loader { active: current || loadedOnce }` per pane (latching, so the focused-row memory stays, as `SettingsPage.qml:8` wants); instantiate only the pane named by `params.category`, else the first; `currentPane` returns `loader.item`. Keep focus and Accessible behaviour exactly as `tst_settings.qml` asserts.
B. **Lazy modals:** `Loader { active: opened }` for `TextEntry`, `PinPad` flows, `ModePicker`, `ZonePicker`, `WallpaperPicker` and the flow items (a latch where closing must not lose state); `GlassSheet`: `crop.sourceItem: sheet.shown && sheet.blurred ? sheet.source : null`, layer-enable the mask only while shown.
C. **Defer refreshes** to the first time a pane is shown (like `StoragePane`) and behind `Qt.callLater`; warm the C++ singletons in `Shell.Component.onCompleted` (off the transition) or fix a constructor with synchronous IO.
D. **Stagger the Store teardown:** `Qt.callLater(destroy)` in `reapIfDone`, not mid-glide.
E. Prewarm `SettingsPage` idle on Home only if A-D are not enough (say why).

## Measurement (the Dell, standing permission; the lead can help)
Add a permanent cheap probe in `Shell.openPage`/`openSection`: `ruya-shell: page-open <key> create=<ms> firstSwap=<ms> afterAnim=<ms>` (one `qInfo` line via `onFrameSwapped`, behind an env or always). On the Dell also `QSG_RENDER_TIMING=1` via a transient compositor drop-in. A/B 10 runs each, before and after: Home to Settings, Store to Settings, Store to Games; effects performance vs high; first open after boot vs second. Target: Settings `create` under about 30 ms, no frame over 33 ms in the transition. The Outcome carries the table.

## Acceptance criteria
- [ ] `tst_settings_lazy.qml`: opening Settings creates only `paneMyProfile` (`findChild`); moving to Display creates `paneDisplay`; a pane once shown stays (latch); focus and Accessible as in `tst_settings.qml`. Existing tests that `findChild` a pane before selecting it are updated (`tst_settings`, `tst_glide_settings`, `tst_pages`), not weakened.
- [ ] Modals are not instantiated before their first open (a test per modal family); `GlassSheet`: `crop.sourceItem` is null and the bake count 0 until shown.
- [ ] Mock counters: no Storage/SoundThemes/Bluetooth/Network refresh until their pane is first shown.
- [ ] Store to Settings: the Store slot is destroyed after the glide (a test on the order of `reapIfDone`).
- [ ] The probe line exists and the Outcome has the before/after table from the Dell (or `Verified: host (hw pending: Dell measurements, lead run)` with the probe and the script in place).
- [ ] UX: no visible change; Back and focus unchanged; the Outcome has a `UX notes:` line. `dev.ps1 test` and `shots` ALL GREEN (screenshots of Settings panes are unchanged).

## Out of scope
- Redesigning Settings, changing animations or durations, the wallpaper blur fade.

## Docs to update
- `shell/PATTERNS.md` (lazy panes and modals: how to add one), `docs/specs/02-shell.md` page open, `docs/dev-setup.md` (the probe).

## Hints
- Count objects, not time, in `test` (offscreen software renderer). `MultiEffect` draws nothing offscreen: assert properties.
- Reference: `StoragePane` already defers its refresh to the first show.

## Outcome
_Filled in by the implementer._
