# shell/ — rules for the Qt Quick console UI

Specs: `docs/specs/02-shell.md` (behaviour) and `docs/specs/04-design-system.md` (look: tokens, components, focus, copy). This file covers how the code is built.

## Structure

- `qml/Main.qml`: the window only (fullscreen, or `--windowed`). It hosts `Shell`.
- `qml/Shell.qml`: the whole UI as one `FocusScope`, so tests can host it in their own window. It owns top-level flow: picker → home → overlay, and later pages.
- `qml/*.qml`: components. `Theme` (design tokens) and `Sfx` (UI sounds) are singletons.
- `src/<area>/`: C++ for QML-exposed services. For each system service:
  - `XxxBackend.h`: an abstract `QObject` with virtual methods and result **signals**.
  - `MockXxxBackend`: in-memory, deterministic, asynchronous (results delivered via `QTimer::singleShot(0, …)`), so QML behaves as it will over D-Bus.
  - `DBusXxxBackend`: a QtDBus client of `api/dbus/org.ruyaos.Xxx1.xml`.
  - `Xxx`: a `QML_ELEMENT QML_SINGLETON` facade. `create()` picks the backend from `RUYA_SERVICES` (`mock`/`dbus`; the default is D-Bus on Linux, the mock elsewhere). Expose `bool mock`.
  - Follow `src/profiles/` exactly as the reference implementation.
- `tests/`: Qt Quick Test. `tst_main.cpp` forces `RUYA_SERVICES=mock`; each `tst_*.qml` gets a fresh engine (and so fresh singletons).
- Everything except `main.cpp` is the static QML module `RuyaShell` (`ruyashell` target). **Add every new `.qml`, `.h` and `.cpp` to `CMakeLists.txt`.** Singletons need `QT_QML_SINGLETON_TYPE` set in CMake **and** `pragma Singleton` in the file. A build step (`cmake/InvalidateStaleQmlTypes.cmake`, T-116) keeps `QML_ELEMENT` registration fresh; on "X is not defined" see the root `CLAUDE.md` pitfall.

## QML rules

- Start files with `pragma ComponentBehavior: Bound` when they have delegates or inline components. Delegates use `required property`. qmllint runs with zero warnings allowed.
- **Sizes are design pixels at 1080p × `u`** (`u = height / 1080`), passed down as a `u` property. Respect the safe area (`Theme.safeArea`).
- **No literal colours, durations or easing values in components** (and font sizes, and, since T-143, spacing, radii and the standard control sizes: `spaceXs`.., `radiusS..L`, `rowHeight`, `focusRingWidth`; spacing is not linted): use the `Theme` tokens listed in `04-design-system.md` §3. **Builders don't invent tokens or components:** take the closest existing one and add an Inbox line (`04` §8); the lead changes the system. `dev.ps1 shell` (so `test`) and CI run a token lint (`scripts/lint-tokens.ps1`) that fails on `duration: <non-zero number>`, a quoted hex colour, `Qt.rgba(` or a literal `font.pixelSize: <number>` anywhere but `Theme.qml`; for a rare exception end the line with `// token-ok: <reason>`. (Easing types are still a convention, not linted.) A feedback animation (shake, pulse) must also not run under reduced motion: guard its start on `Theme.reducedMotion`.
- User-visible strings: `qsTr()`, with `%n` plurals where counts appear (see Translations below).
- Effects: `MultiEffect` or precompiled `.qsb` shaders only. Never inline GLSL. Blur the shared backdrop; never stack more fullscreen blurs.
- Never block the GUI thread. Service calls are asynchronous: invoke them, then react to a signal.

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

  Keyboards also send `Key_Enter` (keypad), digits and `Key_Backspace`. Every flow must be completable with the controller keys alone.
- Each screen or modal is a `FocusScope`. Exactly one item has active focus, and the focused item always shows a visible focus ring or scale.
- `ListView`/`GridView` with `interactive: false` **also turns off key navigation**, so set `keyNavigationEnabled: true` explicitly.
- **Modals** (PIN pad, overlay, dialogs) accept *every* key in their `Keys.onPressed` (`event.accepted = true`), so nothing leaks underneath.
  Accepting every key also skips a `ListView`'s own key navigation, so a modal list handles Up/Down itself (`incrementCurrentIndex()`), as the Guide overlay does.
- **A held key repeats** (`event.isAutoRepeat`). Ignore repeats in handlers that toggle or close (a held Guide used to close the overlay it had just opened); time long presses from the first press and the release (`Shell.qml`, `guideHoldTimer`).
- **Focus restoration:** when a modal or page closes, return focus to where it was. Guard any re-focus with a check that the target is still enabled; otherwise you will steal focus after state changes (see `ProfilePicker.onClosed`).
- Use `Sfx.navigate()` on focus moves, `Sfx.select()` on Accept, and `Sfx.back()` on Back or errors.

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

- Every `init()` starts with `verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())` (T-127): it re-activates the test window, or fails with "test window is not active" instead of a later `activeFocus` assertion. Copy it into new test files.
- Drive the UI with `keyClick()` using only the keys listed above, unless a test is specifically about keyboard input.
- Give an `objectName` to every element a test needs to find, and find it with `findChild(shell, "name")`.
- To wait on asynchronous results use `tryCompare(obj, "prop", value)` or `tryVerify(() => …)`. **Never** use `tryCompare` on a `QVariantList` property's `length`: that polls a frozen copy.
- Assert focus explicitly (`find("x").activeFocus`) after every navigation step that matters. A missing focus assertion let a real bug through once.
- State that would leak between tests (lockouts, created profiles) gets its own `tst_*.qml` file.
- UI tasks: extend `test_zz_screenshots` (or add a similar test) so `dev.ps1 shots` captures the new screens, then review the PNGs.

## C++ rules

- C++17 (MSVC). Qt APIs up to 6.8. Use `QStringLiteral` for literals. Use `qWarning("ruya-shell: …")` for failures.
- QtDBus code compiles on Windows but can only run on Linux. Keep it a thin translation of the XML contract, and mark it unverified in STATUS.
