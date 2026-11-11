# shell/ — rules for the Qt Quick console UI

Specs: `docs/specs/02-shell.md` (behaviour) and `docs/specs/04-design-system.md` (look: tokens, components, focus, copy). This file covers how the code is built.

## Structure

- `qml/Main.qml`: the window only (fullscreen, or `--windowed`). It hosts `Shell`.
- `qml/Shell.qml`: the whole UI as one `FocusScope`, so tests can host it in their own window. It owns top-level flow: picker → home → overlay, and later pages. App items: `addApp`/`removeApp`, `src/input/KeyRouter`; on Linux `compositor/Compositor.qml` (`RUYA_COMPOSITOR`, image only) feeds them Wayland windows (`PATTERNS.md`).
- `qml/*.qml`: components. `Theme` (design tokens) and `Sfx` (UI sounds) are singletons.
- `src/<area>/`: C++ for QML-exposed services. For each system service:
  - `XxxBackend.h`: an abstract `QObject` with virtual methods and result **signals**.
  - `MockXxxBackend`: in-memory, deterministic, asynchronous (results delivered via `QTimer::singleShot(0, …)`), so QML behaves as it will over D-Bus.
  - `DBusXxxBackend`: a QtDBus client of `api/dbus/org.ruyaos.Xxx1.xml`.
  - **Late replies.** Every async refresh whose reply replaces a model goes through a `RequestSequence` (`src/backend/RequestSequence.h`, T-181): the base class owns one per kind of reply (state, list) and offers `begin…Request()`/`deliver…()` that emit only the newest reply. The D-Bus client and the mock both use them. A failed request counts as an outcome (call `accept` for it), so an older reply arriving after a newer failure is dropped too (T-191). Test: give the mock a reply delay (`mockRefreshDelayed`, see `tst_battery.qml`, `tst_late_replies.qml`) and change the data before the late reply lands. The mock must reach the guard by the same path as the D-Bus client, including the changes it publishes itself (`MockProfilesBackend::publishList` counts as the newest request). The Store's jobs go through `JobBook` (`src/store/JobBook.h`), for both backends.
  - `Xxx`: a `QML_ELEMENT QML_SINGLETON` facade. `create()` picks the backend from `RUYA_SERVICES` (`mock`/`dbus`; the default is D-Bus on Linux, the mock elsewhere). Expose `bool mock`.
  - Follow `src/profiles/` exactly as the reference implementation.
- `tests/`: Qt Quick Test. `tst_main.cpp` forces `RUYA_SERVICES=mock`; each `tst_*.qml` gets a fresh engine (and so fresh singletons).
- Everything except `main.cpp` is the static QML module `RuyaShell`. **Add every new `.qml`, `.h` and `.cpp` to `CMakeLists.txt`.** Singletons need `QT_QML_SINGLETON_TYPE` set in CMake **and** `pragma Singleton` in the file. A build step (`cmake/InvalidateStaleQmlTypes.cmake`, T-116) keeps `QML_ELEMENT` registration fresh; on "X is not defined" see the root `CLAUDE.md` pitfall.

## QML rules

- Start files with `pragma ComponentBehavior: Bound` when they have delegates or inline components. Delegates use `required property`. qmllint runs with zero warnings allowed.
- **Sizes are design pixels at 1080p × `u`** (`u = height / 1080`), passed down as a `u` property. Respect the safe area (`Theme.safeArea`).
- **No literal colours, durations or easing values in components** (and font sizes, and, since T-143, spacing, radii and the standard control sizes: `spaceXs`.., `radiusS..L`, `rowHeight`, `focusRingWidth`; spacing is not linted): use the `Theme` tokens listed in `04-design-system.md` §3. **Builders don't invent tokens or components:** take the closest existing one and add an Inbox line (`04` §8); the lead changes the system. `dev.ps1 shell` (so `test`) and CI run a token lint (`scripts/lint-tokens.ps1`) that fails on `duration: <non-zero number>`, a quoted hex colour, `Qt.rgba(` or a literal `font.pixelSize: <number>` anywhere but `Theme.qml`; for a rare exception end the line with `// token-ok: <reason>`. (Easing types are still a convention, not linted.) A feedback animation (shake, pulse) must also not run under reduced motion: guard its start on `Theme.reducedMotion`.
- User-visible strings: `qsTr()`, with `%n` plurals where counts appear (see Translations below).
- Effects: `MultiEffect` or precompiled `.qsb` shaders only. Never inline GLSL. Blur the shared backdrop; never stack more fullscreen blurs.
- **Glass and motion (T-204, `04` §3.8):** a glass surface gets its sheen, grain and lit rim from `GlassLayers` (no flat `glassBorder` on glass) and its drop shadow from `GlassShadow` (placed before the surface; only the outside is drawn; a focus-dependent one sets `active`, and a card's shadow follows the art's `scale`); a focusable card gets `CardFocusLayers` inside its art. Page and overlay transitions use `easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap`, lifts `Theme.easeGlide`, pops `OutBack` with `easing.overshoot: Theme.popOvershoot`. Every duration is a `Theme` token, which is already scaled by `motionScale` (0 under reduced motion), so never multiply again. A decorative animation (glare, shimmer) is also guarded on `Theme.glareOn` / `Theme.shimmerOn` (motion on, not Performance). Tests of these assert properties and animation state (`running`, counters); `GlareGate.fakeNow` fixes the clock of the 300 ms glare rule.
- **Gliding highlight and liquid pill (T-205, `04` §3.8):** a single-row selector uses `FocusGlide.qml` (never `Behavior on color` per row): declare it in the items' coordinate space below them (`ListView`: `parent: list.contentItem`, since declared children are not put there), `target` the focused item, `shown` the owner's `activeFocus`, and let each item drop its own focus fill while `glide.active`. The highlight is a picture: it never takes focus, and the ring and the accessible name stay on the real items. Shaders are `shaders/*.frag` compiled by `qt_add_shaders` (`shell/CMakeLists.txt`, optional ShaderTools) and loaded by relative `.qsb` URL from a ShaderEffect; a missing one must leave the plain look (`LiquidGlass.compiled`). Nothing decorative may animate forever on a still screen: the specular clock obeys `LiquidGate` (no app, window shown, input in the last 30 s). Tests read `targetX/Y`, `x/y`, `gliding`, `stretch` and `stepStretch`; the offscreen software renderer draws no shader, so only `shots` shows the liquid pill.
- Never block the GUI thread: service calls are asynchronous (invoke, then react to a signal).

## Focus and input rules (the most common source of bugs)

- **Controller → key mapping** (from `ruya-inputd`):

  | Controller | Key |
  |---|---|
  | D-pad / left stick | Arrow keys |
  | A | `Key_Return` |
  | B | `Key_Escape` |
  | Start | `Key_Menu` |
  | Guide | `Key_HomePage` |
  | LB / RB | `Key_PageUp` / `Key_PageDown` |

  Keyboards also send `Key_Enter` (keypad), digits, `Key_Backspace`. Every flow must work with the controller keys alone.
- Each screen or modal is a `FocusScope`. Exactly one item has active focus, and the focused item always shows a visible focus ring or scale.
- `ListView`/`GridView` with `interactive: false` **also turns off key navigation**, so set `keyNavigationEnabled: true` explicitly.
- **Modals** (PIN pad, overlay, dialogs) accept *every* key in their `Keys.onPressed` (`event.accepted = true`), so nothing leaks underneath.
  Accepting every key also skips a `ListView`'s own key navigation, so a modal list handles Up/Down itself (`incrementCurrentIndex()`), as the Guide overlay does.
- **A held key repeats** (`event.isAutoRepeat`). Ignore repeats in handlers that toggle or close (a held Guide used to close the overlay it had just opened); time long presses from the first press and the release (`Shell.qml`, `guideHoldTimer`).
- **Focus restoration:** when a modal or page closes, return focus to where it was. Guard any re-focus with a check that the target is still enabled; otherwise you will steal focus after state changes (see `ProfilePicker.onClosed`).
- `Sfx.navigate()` on focus moves, `Sfx.select()` on Accept, `Sfx.back()` on Back or errors.

## Patterns (read `shell/PATTERNS.md` when your task touches one)

`PATTERNS.md` has the how-to for: **adding a page** (and nested pages), the **settings controls** (`SettingRow`, `ToggleRow`, `ChoiceRow`, `SliderRow`), **modals from pages** (PIN pad modes, flows), **text input** (`TextEntry`, never a raw `TextInput`) and the **translation details** (live switching, models that must not change with the language, adding a language, RTL check).

## Translations (every UI task)

All user-visible strings use `qsTr()`. After adding or changing one, refresh the `.ts` files, translate the new entries (Turkish for real, and the English copy), then check:

```powershell
cmake --build shell\build-win --config Release --target update_translations
.\scripts\lint-translations.ps1
```

`dev.ps1 shell` and `test` also fail on an unfinished, `vanished` or `obsolete` entry (delete those).

## Tests (required for every behaviour you add)

- Every `init()` starts with `verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())` (T-127: re-activates the window or fails clearly). Copy it into new test files.
- **Test motion scale (T-463):** `windowGuard.ensureActive()` (so every `init()`) sets `Theme.motionFactor` to 0.1 (all duration tokens a tenth; `shots` keeps 1, `RUYA_TEST_MOTION=<f>` overrides), because offscreen tests only look at where an animation ends and would spend most of their time waiting for fades. A test (or a file) whose **subject is a duration** (a token's value, a mid-fade sample, glide timing, the shimmer period) sets `Theme.motionFactor = 1.0` itself, in `init()` after the windowGuard line or at the top of the test, with a comment saying so (`tst_motion`, `tst_glide`, single tests in `tst_glass`/`tst_themes`/`tst_appflow`/`tst_wallpaper`, and `tst_settings_lazy` `test_a_replaced_page_goes_after_the_glide`: an order relative to the glide's duration, red 2 of 21 at 0.1). A `cleanup()` that resets it to 1.0 is harmless: the next `init()` sets 0.1 again. A wait on a short fade is `tryVerify`/`tryCompare` or `Theme.pageMs + n`, never a literal `wait(300)` (waits of 1 s or more are conditions). A time that is **not** a `Theme` token (`Sfx` ducking, the ambient bed's 800 ms fade, a hold time, a mock's 300 ms pairing window) is not scaled: a negative check ("nothing happens within X") keeps its wait.
- Drive the UI with `keyClick()` using only the keys listed above, unless a test is specifically about keyboard input.
- **Test member lint (T-189, `scripts/lint-test-members.ps1`, in `dev.ps1 shell`/`test`; `.sh` twin in CI):** qmllint runs over `tests/*.qml` and any finding fails. A read of a member QML cannot see (a C++ constant without `Q_PROPERTY`, a typo, `tc.shell.foo` on a `property Shell shell`) is `undefined` at run time, so `wait(x + 200)` waits nothing and `verify(x !== y)` is always true. Fix: expose the member or the name; never silence it. Type a test's shell as `property Shell shell` (a `var` or `Item` is not checked). qmllint goes silently blind on a file with a local (`const`, `let`, `for (const ..)`) inside a nested function or block-bodied arrow; a canary read per file catches that: lift the function to a top-level function of the `TestCase`. `windowGuard` and `shotsDir` (context properties) are not checked.
- Iterate with `dev.ps1 qml tst_x` (PARTIAL: that file only, no lints); `test` still gates.
- Give an `objectName` to every element a test needs to find, and find it with `findChild(shell, "name")`.
- To wait on asynchronous results use `tryCompare(obj, "prop", value)` or `tryVerify(() => …)`. **Never** use `tryCompare` on a `QVariantList` property's `length`: that polls a frozen copy. `tryCompare(x, "opacity", 1)` is fuzzy (0.99999 passes): a property derived from the exact end (`opacity >= 1`) gets its own `tryVerify` (T-421, red twice on loaded hosts).
- Assert focus explicitly (`find("x").activeFocus`) after every navigation step that matters. A missing focus assertion let a real bug through once.
- State that would leak between tests (lockouts, created profiles) gets its own `tst_*.qml` file.
- UI tasks: extend `test_zz_screenshots` (or add a similar test) so `dev.ps1 shots` captures the new screens, then review the PNGs. `shots` runs only functions that save to `shotsDir`, so a screenshot must not rely on an earlier test function.
- **A `shots` window may present no frames at all (T-460):** with the display asleep (an idle desktop past its screen timeout) `frameSwapped` never fires, `update()` brings no frame, yet animations, timers and `grabImage` still work. Product code that waits for a presented frame needs a path for that case (the page slots go at once when no frame came while closing), and a test that must see a frame proves it offscreen, where frames are drawn. `dev.ps1 shots` probes for a presented frame first (2 s) and stops with "The display is asleep: wake it and run shots again." instead of running tests that would fail for no code reason (T-462).

## C++ rules

- C++17 (MSVC). Qt APIs up to 6.8. Use `QStringLiteral` for literals. Use `qWarning("ruya-shell: …")` for failures.
- QtDBus code compiles on Windows but can only run on Linux. Keep it a thin translation of the XML contract, and mark it unverified in STATUS.
