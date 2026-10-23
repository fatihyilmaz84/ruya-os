# shell/ — rules for the Qt Quick console UI

Read `docs/specs/02-shell.md` for the UX spec. This file covers how the code is built.

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
- Everything except `main.cpp` is the static QML module `RuyaShell` (`ruyashell` target). **Add every new `.qml`, `.h` and `.cpp` to `CMakeLists.txt`.** Singletons need `QT_QML_SINGLETON_TYPE` set in CMake **and** `pragma Singleton` in the file. Adding, editing or removing a `QML_ELEMENT` type is safe on the first `dev.ps1` run: a build step (`cmake/InvalidateStaleQmlTypes.cmake`) works around the Visual Studio generator skipping `qmltyperegistrar` (T-116). If you ever see "X is not defined" again, that step is the first suspect, not the tests.

## QML rules

- Start files with `pragma ComponentBehavior: Bound` when they have delegates or inline components. Delegates use `required property`. qmllint runs with zero warnings allowed.
- **Sizes are design pixels at 1080p × `u`** (`u = height / 1080`), passed down as a `u` property. Respect the safe area (`Theme.safeArea`).
- **No literal colours, durations or easing values in components.** Add a token to `Theme.qml` instead. `dev.ps1 shell` (so `test`) and CI run a token lint (`scripts/lint-tokens.ps1`) that fails on `duration: <non-zero number>`, a quoted hex colour or `Qt.rgba(` anywhere but `Theme.qml`; for a rare exception end the line with `// token-ok: <reason>`. (Easing types are still a convention, not linted.) A feedback animation (shake, pulse) must also not run under reduced motion: guard its start on `Theme.reducedMotion`.
- All user-visible strings go through `qsTr()`; use `%n` plurals where counts appear.
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

## How to add a page

1. Create `XxxPage.qml` as a `Page { id: page; title: qsTr("Xxx") … }` (see `Page.qml`, `ComingSoon.qml`). Put one `focus: true` element in it; size from `page.u`.
2. Add the file to `CMakeLists.txt`, and a `Component { id: xxxPage; XxxPage {} }` plus an entry in `pageComponents` in `Shell.qml`.
3. Open it with `Shell.openPage("xxx")` (home tiles do this with their `key` role). Back is handled by `Page`; never steal the Guide keys in a page, so the overlay still works.
4. Test in a `tst_*.qml`: open, assert focus, Back, assert focus restored (see `tst_pages.qml`).

## Controls (`qml/controls/`)

Reusable settings rows. All extend `SettingControl` (a `FocusScope` with the label, the glass bar and a focus ring; pass `u` and `label`). Put rows in a `SettingsPane` (`qml/SettingsPane.qml`): it moves between rows with Up/Down, and Left/Back leave it (`exitRequested`). Rows handle only their own keys and let everything else bubble.

| Control | Keys it consumes | Value and signal |
|---|---|---|
| `SettingRow` | Accept | `value` (text); `activated()` |
| `ToggleRow` | Accept toggles | `checked`; `toggled(checked)` |
| `ChoiceRow` | Left/Right cycle `options` (`[{value, label}]`), wrapping | `value`; `edited(value)` |
| `SliderRow` | Left/Right step by `stepSize` within `from`..`to`, clamped | `value`; `edited(value)` |

A control changes its own value, then emits the signal; the owner writes the setting, resyncs the control, and keeps a `Binding` on it so external changes show (see `DisplayPane.qml`). `Sfx.navigateCount`/`selectCount`/`backCount` count cue requests so tests can check the sound path.

## Modals from pages

A page that needs a full-screen modal (PIN pad, `TextEntry`) declares it as `parent: page.overlay` (the shell's `modalLayer`) with `width/height` taken from that parent, not as a child of the page, so it covers the whole screen and sits above toasts. Save `Window.activeFocusItem` before opening and refocus it when the modal closes (see `ProfilesPane.qml`); `TextEntry` does this itself. `PinPad` has three modes: `open(profile)` verifies with `Profiles.switchTo`; `collect(prompt, confirm)` hands the PIN back through `collected(pin)` (and `cancelled()`), calling no service. Multi-step flows are small state machines in their own non-visual file (`ProfileAddFlow.qml`, `ChangePinFlow.qml`).

Messages for Profiles1 statuses (`invalid`, `wrong-pin`, ...) come from the `ProfileStatus` singleton (`ProfileStatus.describe`); don't write a second mapping. The first-boot wizard (`Setup.qml`, not a page) hosts its own modals in an inner full-screen layer and is shown by `Shell` while no profile exists.

## Text input

Use `TextEntry` (`qml/TextEntry.qml`, spec 02-shell §4.4) for any text input; never a raw `TextInput` without it. Host it as a full-screen child of the screen that needs it, call `open(title, initial, options)`, and handle `accepted(text)`/`cancelled()`. It restores focus to the item that opened it.

## Tests (required for every behaviour you add)

- Drive the UI with `keyClick()` using only the keys listed above, unless a test is specifically about keyboard input.
- Give an `objectName` to every element a test needs to find, and find it with `findChild(shell, "name")`.
- To wait on asynchronous results use `tryCompare(obj, "prop", value)` or `tryVerify(() => …)`. **Never** use `tryCompare` on a `QVariantList` property's `length`: that polls a frozen copy.
- Assert focus explicitly (`find("x").activeFocus`) after every navigation step that matters. A missing focus assertion let a real bug through once.
- State that would leak between tests (lockouts, created profiles) gets its own `tst_*.qml` file.
- UI tasks: extend `test_zz_screenshots` (or add a similar test) so `dev.ps1 shots` captures the new screens, then review the PNGs.

## C++ rules

- C++17 (MSVC). Qt APIs up to 6.8. Use `QStringLiteral` for literals. Use `qWarning("ruya-shell: …")` for failures.
- QtDBus code compiles on Windows but can only run on Linux. Keep it a thin translation of the XML contract, and mark it unverified in STATUS.
