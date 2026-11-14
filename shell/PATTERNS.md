# shell/ — patterns reference

Read this when your task adds a page, a settings row, a modal, text input or a translated string. The rules every shell change must follow are in `shell/CLAUDE.md`; this file is the how-to and the component catalogue (moved out of `CLAUDE.md` in the 2026-10-27 docs slimming, so the rules file stays short).

## How to add a page

1. Create `XxxPage.qml` as a `Page { id: page; title: qsTr("Xxx") … }` (see `Page.qml`, `ComingSoon.qml`). Put one `focus: true` element in it; size from `page.u`.
2. Add the file to `CMakeLists.txt`, and a `Component { id: xxxPage; XxxPage {} }` plus an entry in `pageComponents` in `Shell.qml`.
3. Open it with `Shell.openPage("xxx")`; a section of Home's nav does this with its key (`SectionNav.keys`, `Shell.openSection`). Add a pill to `SectionNav.keys` and a label in `SectionNav.label()`. Back is handled by `Page`; elsewhere test for it with `BackKey.isBackOrBackspace(event.key)` (text fields use `BackKey.isBack`), never by listing keys; never steal the Guide keys in a page, so the overlay still works.
4. **Hints:** the hint bar shows `page.hints` (default `A` Select, `B Back`, a list of `{ button, text }`, at most four, short translated verbs). On Settings the focused pane supplies them: set `hints` on the `SettingsPane` (default `A Select`, `B Back`; a pane with nothing to select: `hints: [{ button: "B", text: qsTr("Back") }]`; none does today, `AboutPane` has a row to open System information); `SettingsPage` shows `currentPane.hints` while the pane has focus. Override it on a page with nothing to select or with other actions (`hints: backOnlyHints` shows only `B Back`; a hint with two buttons and one verb is `{ buttons: ["LB", "RB"], text }`). Content that does not use Up or LB/RB lets them bubble to `Page`: Up at a page's top row emits `upFromTop` (the shell moves focus to the nav), LB/RB (PageUp/PageDown) emit `stepRequested(+1/-1)` (next/previous section), and `Page` swallows an unaccepted Up/PageUp/PageDown so they never reach the Guide or Home. Test in a `tst_*.qml`: open, assert focus, Back, assert focus restored (see `tst_pages.qml`).
5. **Nested pages:** `Shell.openPage(key, params)` pushes a page over the current one (`params` is a plain object, available as `page.params`; `Shell.currentParams` is the top entry's). The page below stays alive, hidden and disabled, and gets its focus item back on Back. A test or module registers a page without editing `Shell.qml` through `Shell.extraPages = ({ key: component })` (see `tst_pages.qml`, `detailPage`). Keep `pageStack` a plain array and reassign it. A page opens another page with its `openRequested(key, params)` signal (`Page.qml`; `StorePage` -> `appDetail`).
6. **A covered page never takes the focus (T-356).** When the page on top's fade-in ends, the page below hides all its items, and its `onVisibleChanged` handlers run too. Qt lets a hidden item keep or receive the active focus, so `forceActiveFocus()` from such a handler (or from a data handler of a covered page) pulls the focus out of the page on top: every key is lost. Inside a page, move the focus with `item.focus = true` (it only changes the page's own focus item unless the page has the focus), or check `page.enabled` first (a covered page is disabled). The shell repairs a focus that fell out of the page on top anyway (never while anything in the modal layer shows; it checks after a focus change with a 0 ms Timer, because a `Qt.callLater` per focus change reordered the pages' own deferred focus calls) and logs `ruya-shell: the focus fell out of page <key>`; tests assert `Shell.focusRepairs` stays 0 so the net never hides a page's own bug (`tst_pages.qml`, `test_every_page_owns_the_focus`).

## Controls (`qml/controls/`)

Reusable settings rows. All extend `SettingControl` (a `FocusScope` with the label, the glass bar and a focus ring; pass `u` and `label`). Put rows in a `SettingsPane` (`qml/SettingsPane.qml`): it moves between rows with Up/Down, and Left/Back leave it (`exitRequested`). Rows handle only their own keys and let everything else bubble. Rows may hide with the data (loading, a failed read): the pane never leaves the focus on a hidden or disabled row (it moves to the nearest visible row, or with none holds the focus itself, so Back still leaves; T-356), so a data-dependent first row is fine. A pane taller than the screen shows its scroll cue by itself (T-185: the first / last visible row is dimmed while more rows exist beyond it); nothing to set, but do not bind `opacity` on a row, the pane owns it.

**A new Settings pane (T-349).** Settings builds a pane the first time its category is selected and keeps it (hidden) afterwards, so opening Settings builds one pane and each pane remembers its last focused row. Add the category key to `SettingsPage.buildCategories` and `labelFor`, then a `PaneSlot` (a latching `Loader`) in `paneArea` with `selected: page.ready && page.current.key === "xxx"` and the pane in its `sourceComponent` (`objectName: "paneXxx"`, `anchors.fill: parent`, `u`, `overlay` if it has modals, `onExitRequested: page.leavePane()`), and its line in `currentPane`. The pane is created visible, in the key frame that selects it: do no service call in its `Component.onCompleted` that can wait (`Qt.callLater`, as `AudioPane` does for the sound themes), and build its modals on their first opening (below). A test finds a pane only after selecting it (`find("paneXxx")` is `null` before).

| Control | Keys it consumes | Value and signal |
|---|---|---|
| `SettingRow` | Accept (not on `kind: "info"`) | `value` (text), `kind` (`item`, `page`, `action`, `info`), `emphasis`, `current`; `activated()` |
| `ToggleRow` | Accept toggles | `checked`; `toggled(checked)` |
| `ChoiceRow` | Left/Right cycle `options` (`[{value, label}]`), wrapping; Accept steps to the next | `value`; `edited(value)` |
| `SliderRow` | Left/Right step by `stepSize` within `from`..`to`, clamped | `value`; `edited(value)` |
| `GroupLabel` | none (never focusable) | `text` |

**Which row kind (RUY-512 built the controls; RUY-513/514 move the panes; 04 §5 "Setting row kinds").** Pick the control by what A does, so the row's right end tells the player before they press it:

| A does | Use | Looks like |
|---|---|---|
| Nothing: the row states a fact | `SettingRow { kind: "info" }` | No pill; hairline between facts; hint `B Back` |
| Acts on a thing in a list (join a network, connect a device, pick a profile) | `SettingRow` (`kind: "item"`; `kind` is always set) | Pill, value at the right; name the verb in `hints` if it is not Select |
| Is the one in use, in a list where only one can be (default output, connected Wi-Fi, current mode) | `SettingRow { current: true }` (an item) | DemiBold label, its word, filled check at the right |
| Opens a page, a picker or the keyboard to change this row's value | `SettingRow { kind: "page" }` | Pill, value, chevron |
| Does something now or after a confirm (a verb: Scan, Rename, Forget, Reset) | `SettingRow { kind: "action" }` | Centred DemiBold label; a status goes in `value`, drawn under it |
| The one main step of a flow | `kind: "action"; emphasis: "primary"` | `primaryFill` pill |
| Flips on/off | `ToggleRow` | Outlined switch, filled when on |
| Picks one of a few values in place | `ChoiceRow` | Value between two round arrows; Left/Right, A next |
| Sets a number in a range | `SliderRow` | Outlined track with a thumb |
| Cannot be used and says why, with nothing to focus | `SettingRow { enabled: false }` | Flat line with an info icon |
| Names the rows below it | `GroupLabel { text: ... }` | `typeHeadline` DemiBold heading, never focused |
| One sentence about the row above (a consequence, not a value) | `SettingNote { u: pane.u; text: ... }` (RUY-590) | `typeCaption` `text`, wrapped, full column width, not focusable; never a raw `Text` (the test lint rejects it) |

`SettingControl.flat` (no fill and no layers at rest) and `ruleBelow` (the hairline) are the fact look; `SettingRow` sets `flat` for `kind: "info"` and `enabled: false`, and any other `SettingControl` can set it (System information's inline row). `SettingsPane` sets `ruleBelow` after each layout of its column: true on a fact whose next visible item is also a fact. `SettingControl.hints` defaults by kind (fact `B Back`; item and action `A Select`; page `A Open`; toggle `A Toggle`; choice `Left/Right Change`, `A Next`; slider `Left/Right Adjust`) and `SettingsPane.hints` shows the focused row's; a row names its own verb with `hints: [{ button: "A", text: qsTr("Connect") }, { button: "B", text: qsTr("Back") }]`, and a pane that sets `hints:` itself still wins.

A label is a noun with a value (Wallpaper, Resolution) for `page`, `item` and `info`; a verb (Scan for networks, Forget %1) for `action`. A row that would be a verb *and* show a value is an action with a status line ("Add a device" / "Scanning…").

`Badge` (`qml/Badge.qml`, 04 §5): `text`, `kind` (`neutral | success | info | warning`), `u`. Static, never focused; its `Accessible.name` is its text.

A control changes its own value, then emits the signal; the owner writes the setting, resyncs the control, and keeps a `Binding` on it so external changes show (see `DisplayPane.qml`). `Sfx.navigateCount`/`selectCount`/`backCount` count cue requests so tests can check the sound path.

## Colour themes (T-209)

Colours live in `qml/themes/` and nowhere else: `ThemeSet.qml` (every themeable token as a `required property`), `Themes.qml` (the five sets and `tokenNames`), `Theme.qml` (the same names components always used, `readonly property color x: tok("x")`, blended during a switch). `scripts/lint-tokens.ps1` rejects a hex colour, a quoted colour name (`"transparent"` is fine), `Qt.rgba`, `Qt.hsla` and `Qt.hsva` outside `Theme.qml` and `qml/themes/`.
- **New colour token:** a `required property color` in `ThemeSet.qml`, its name in `Themes.tokenNames`, a value in every set in `Themes.qml` (the compiler and the lint stop you if one is missing), a `tok("name")` property in `Theme.qml`, and a row in `tests/tst_theme_contrast.qml` for the surface it is drawn on.
- **Text colour follows the surface.** A light theme (Daylight) turns `text` dark, so `Theme.text` is only for `background`, glass, `panel`, scrims, the hero and caption washes, toasts. On a fill of its own use the matching token (`onPrimary` on `primaryFill`; `text` on `dangerFill` is gated) and add the pair to the gate. Art placeholders take their lightness from `Theme.artTop()`/`artBottom()`.
- **A white overlay is not a token of its own:** use `focusFill`, `selectedFill` or the key fills (they are dark on Daylight). The art effects `cardSheen`, `glarePeak` and `shimmerPeak` stay white (they sit on art).
- **Switching** is `DeviceSettings.theme = key`; `Theme` cross-fades over `tintMs` and is immediate under reduced motion. A component never needs to know; if it computes a colour from a token, derive it in a binding (it re-evaluates on every blend step), as `Backdrop.qml` does with `Theme.backdropTop(tint)`.

## Pitfall: a ternary inside a product in an anchor offset (T-260, T-297)

`anchors.verticalCenterOffset: (picker.needsController ? -150 : 40) * picker.u` did not update in the offscreen build: the item stayed at the first value after the condition changed. Put the multiplication inside the branches, `anchors.verticalCenterOffset: controllerHint.visible ? -150 * picker.u : 40 * picker.u` (as `ProfilePicker.qml` does), or bind a property (`readonly property real offset: cond ? -150 * u : 40 * u`) and use that, or give an `Item` an explicit `y`. `scripts/lint-qml-members.ps1` rejects the parenthesised form for `verticalCenterOffset` and `horizontalCenterOffset` on one line; a ternary in a product elsewhere is not caught, so assert the moved position in a test (`tryCompare` on `y`).

## Text from outside is plain text (T-286)

Qt's default `Text.AutoText` renders anything that looks like HTML: a Bluetooth device called `<b>x</b>` turns bold and `<img src=...>` makes Qt fetch the file. So **every `Text` that can show a string the shell did not write says `textFormat: Text.PlainText`**: profile names (cards, avatars' first letter, status bar, PIN pad, Profiles pane), Bluetooth, audio and network names (SSIDs), volume and drive labels, wallpaper and sound-theme names, app names, summaries, developers and descriptions from AppStream, error and sensor text from a service, anything the user typed, and every toast. Shared controls (`SettingControl` label, `SettingRow` value, `ChoiceRow`, `Badge`, `Page` title, `ArtCard`) already do it: a row you build from them is covered. A `Text` of your own that shows such a string needs the line itself, and `Text.StyledText` is only for strings the shell composes (`ControllerPairHint`). `tests/tst_plain_text.qml` feeds `<b>x</b><img src="qrc:/none.png">` through the mock profile, Bluetooth, storage, network and store backends (the `mockSet...` hooks) and walks the shown items: add a case when a new screen shows a new kind of outside name.

## Modals from pages

A page that needs a full-screen modal (PIN pad, `TextEntry`) declares it as `parent: page.overlay` (the shell's `modalLayer`) with `width/height` taken from that parent, not as a child of the page, so it covers the whole screen and sits above toasts.

**Build a modal on its first opening (T-349).** A modal costs its whole tree (a keyboard `Repeater`, a `GlassSheet` with its crop and mask, a thumbnail grid) when its screen is built, so a Settings pane or page puts it in a `Loader` and switches it on just before the first `open()`; the `Loader` latches (it stays active), so the modal keeps its state between openings. The `Loader` is what sits on the overlay and sizes the modal:

```qml
Loader {
    id: entrySlot
    parent: pane.overlay
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0
    active: false                       // built on the first opening, then kept
    sourceComponent: Component {
        TextEntry { objectName: "xxxEntry"; u: pane.u; onAccepted: text => pane.use(text) }
    }
}
readonly property TextEntry entry: entrySlot.item as TextEntry
// where it opens:
entrySlot.active = true
entry.open(qsTr("Name"), "", {})
```

Keep per-opening data (the id a confirmation is for) on the pane, not as an extra property of the modal (`BluetoothPane.forgetId`). Modals that one flow drives together are built together (`ProfilePaneBase.modalsBuilt`, set in `beginModal()`). Anything that must exist before the first opening (a row's value, like the wallpaper's name: `DisplayText.wallpaperName`) lives outside the modal. A test finds the modal only after it opened (`find("xxxEntry")` is `null` before); `tst_settings_lazy.qml` asserts each family is not built with its pane. Save `Window.activeFocusItem` before opening and refocus it when the modal closes (see `ProfilePaneBase.qml`); `TextEntry` does this itself. `PinPad` has three modes: `open(profile)` verifies with `Profiles.switchTo`; `collect(prompt, confirm)` hands the PIN back through `collected(pin)` (and `cancelled()`), calling no service. Multi-step flows are small state machines in their own non-visual file (`ProfileAddFlow.qml`, `ChangePinFlow.qml`).

Messages for Profiles1 statuses (`invalid`, `wrong-pin`, ...) come from the `ProfileStatus` singleton (`ProfileStatus.describe`); don't write a second mapping. The first-boot wizard (`Setup.qml`, not a page) hosts its own modals in an inner full-screen layer and is shown by `Shell` while no profile exists.

## The Options menu and Accept on release (RUY-16, `02` §1.7, `04` §5)

One `OptionsMenu` lives in the Shell's modal layer for every surface; a surface never builds its own. Home asks it directly (`Shell.openOptions(surface, id, anchor, kind, page)`), a **page** asks through `Page.optionsRequested(surface, itemId, anchor, kind)` (kind `"card"`, `"pill"` or `"row"`) and gets, set by the Shell, `Page.optionRows` (a function that lists an item's rows: use it for the Options hint) and `Page.optionsOpenFor` (the id whose menu is open: the card sets `ArtCard.anchored` from it). The rows of a surface come from `Shell.optionRows(surface, id)` (`gameRows` for a game or app card), the note from `optionNote`, what a row does from `runOption`: **add a surface by adding a case to those three**, not by a second menu. Rows are `{ id, label, icon, divider }`; they are bound while the menu is open, so a changed condition rebuilds them in place.

An item that has a menu acts on **release** with `AcceptHold.qml`: forward the item's `Keys.onPressed` / `Keys.onReleased` to `hold.press(event)` / `hold.release(event)`, handle `tapped()` (what a press did before) and `longPressed()` (open the menu), call `hold.cancel()` when the current card or focused button changes or the focus leaves, and give the card `holdShown` / `holdProgress` (the Hold ring). The hold sees only presses delivered to the item itself, which is what makes a release whose press began elsewhere do nothing; never record a press from anywhere else. Open with `Qt.Key_Menu` on the press (ignore auto-repeat). A button that sits in such an item sets `acceptOnRelease` and lets Return through (`event.accepted = false`), as `HeroBlock` does. Test: `tst_options_menu` (the component, with the numbers), `tst_options_shell` (a surface).

## Text input

Use `TextEntry` (`qml/TextEntry.qml`, spec 02-shell §4.4) for any text input; never a raw `TextInput` without it. Host it as a full-screen child of the screen that needs it, call `open(title, initial, options)`, and handle `accepted(text)`/`cancelled()`. It restores focus to the item that opened it.

## Tests that look at geometry or focus after a change (T-361)

- A binding re-evaluates at once, but a `Row`/`Column` lays out on the next frame and a pane hands the focus on in a `Qt.callLater`: a plain `verify` right after the change can read the old state under load (the battery chip gap read 23 or 25 px against 24; a pane's focus was still on a hidden row). Wait for the state that matters: `tryVerify` for a yes/no, or (settled geometry only) re-read for up to about 2 s, or a few drawn frames for a deferred focus hand-on, and then `compare(problem, "")` with a function that returns what is wrong (`tst_battery_cluster.clusterProblem`, `tst_pages.focusProblem`), so a real failure still reports its numbers. A check of an in-between state (the focus while replies are due) stays a single read: a retry would hide the bug it is there for. Never loosen the number.
- Long fades make a test slow, not right. `Theme.motionFactor = 0.03` shortens every fade to a few milliseconds and keeps them real (reduced motion removes them, which changes what the focus tests are about); put `Theme.motionFactor = 1.0` back in `cleanup()`. A negative check ("it is not destroyed yet") does the opposite: `Theme.motionFactor = 4` and waits for drawn frames (`test_reap_waits_for_the_top_to_settle`).

## Translations

- Strings are translated with Qt `.ts` files in `shell/i18n/` (`ruyashell_en.ts`, `ruyashell_tr.ts`), compiled by `qt_add_translations` into resources `:/i18n/ruyashell_<lang>.qm`. English is the source language; its `.ts` only exists for the plural forms (`%n`), so every English entry's translation is its own source text.
- `DeviceSettings.language` is the one place the language lives. Setting it installs the `QTranslator` and calls `QQmlEngine::retranslate()`, so the UI changes live. Defaults: the stored value, else the system locale, else `en`; with `RUYA_SETTINGS_EPHEMERAL=1` (tests) always `en`.
- **Refreshing the files** (the command and the lint) is in `shell/CLAUDE.md`, "Translations". CI's `lint` job checks the committed files only; `dev.ps1 shell`/`test` first refresh temporary copies, so a forgotten refresh fails locally.
- **Bindings re-translate; stored values don't.** `retranslate()` re-evaluates bindings that call `qsTr`. A message written into a property at event time (`message = qsTr(...)`, `ProfileStatus.describe(...)` results kept in `Setup`, `ProfilePaneBase` and its two panes, `PinPad`; toast text in `Notifications`) keeps its language until the next event. That is accepted for transient messages; for anything long-lived derive the text in a binding.
- **A model must not change with the language.** Assigning a new array to a `ListView`/`Repeater` model resets `currentIndex` (and so focus). Models hold keys only (`SectionNav.keys`, `SettingsPage.categories`); the visible text is a binding in the delegate (`SectionNav.label`, `SettingsPage.labelFor`). Add new translated lists the same way.
- **Text built from data (T-226, `SystemInfoRows.qml`).** When labels come from a table or a function, mark each source string with `QT_TR_NOOP("...")` (lupdate extracts it) and translate the value at the use with `qsTr(variable)`; the same code can return the English source for a file someone else reads (a report) by skipping `qsTr`. A page with headings and rows of different kinds in one scrolling `SettingsPane` uses one `Repeater` over an ids-only `ListModel` with a `DelegateChooser` (`role: "kind"`), and rows read their text through a binding on the id, so the model never changes with the language or a live value (`SystemInfoPage.qml`). Never `move` in such a model (a Repeater does not reorder items), and call `SettingsPane.reflow()` after rows come or go: a Column filled after the page opened stayed unlaid in a real window.
- **Do not translate** the brand "RuyaOS" and the language names ("English", "Türkçe", each shown in its own language).
- **Add a language:** add `i18n/ruyashell_<code>.ts` to `qt_add_translations` in `CMakeLists.txt`; add the code to `DeviceSettings::isValidLanguage`; add an option to the language `ChoiceRow`s (`SystemPane.qml`, `Setup.qml`); add a `letterSets` entry in `TextEntry.qml` if its letters differ from a-z.
- **RTL check:** `ruya-shell --reverse` lays the UI out right-to-left (`Main.qml` sets `LayoutMirroring` from `Application.layoutDirection`). Left/Right then mean the visual direction on horizontal lists. It is a readiness check only: before an RTL language ships, review RTL screenshots of every screen (the PIN pad's digit grid must stay left to right; the toast layer, sliders and `ProfileCard` badges were never examined).

## App layer, key router and the compositor (T-150, T-130)

- `Shell.addApp(item, profile)` reparents an app item into `appLayer` (z 5: above home and pages, below toasts, modals, the Guide overlay and the OSD), fills it and focuses it; `profile` is whose app it is (T-164; omitted or "" = the shell's own, shown to whoever is signed in). Only `shownApps` (someone signed in, and the app is theirs) are visible and focusable; the others are hidden until their profile signs in again. `focusApp(item)` switches (a hidden app is refused); `removeApp(item)` (also run when the item is destroyed) hands focus to the newest shown app, else the page or the home tiles. Never keep a destroyed item in a JS array and touch it (QML throws): `Shell` keeps `{item, id, profile}` records and a guard child per item.
- `KeyRouter` (`src/input/`, instantiated in `Shell`) is an event filter on the window. While `appItem` or an item inside it has active focus it takes the Guide keys (`isGuideKey`: HomePage, Super, Meta) and emits `guidePressed/Released`; all other keys reach the app by normal focus delivery, volume keys are application `Shortcut`s. Test with a stand-in item: `tests/tst_compositor_layers.qml`.
- **The compositor** (Linux, `compositor/Compositor.qml`, module `RuyaCompositor`, built only with `-DRUYA_COMPOSITOR=ON`, as the image does): a `WaylandCompositor` (socket `ruya-0`) whose output window is `Main`; each xdg toplevel becomes a fullscreen `ShellSurfaceItem` passed to `Main.shell.addApp`. With the option on, `main.cpp` loads it instead of `Main` (`--load` still loads a file). Connect a surface item's `surfaceDestroyed` from the compositor's scope, never as a handler in the delegate (T-123: dead context). qmllint, lupdate and the Windows tests never see it; the image build compiles it, and `scripts/vm-app-check.sh` exercises it in the VM (`docs/dev-setup.md`).

## Late replies (T-181, T-191)

Every async refresh whose reply replaces a model goes through a `RequestSequence` (`src/backend/RequestSequence.h`): the base class owns one per kind of reply (state, list) and offers `begin…Request()`/`deliver…()` that emit only the newest reply. The D-Bus client and the mock both use them. A failed request counts as an outcome (call `accept` for it), so an older reply arriving after a newer failure is dropped too. Test: give the mock a reply delay (`mockRefreshDelayed`, see `tst_battery.qml`, `tst_late_replies.qml`) and change the data before the late reply lands. The mock must reach the guard by the same path as the D-Bus client, including the changes it publishes itself (`MockProfilesBackend::publishList` counts as the newest request). The Store's jobs go through `JobBook` (`src/store/JobBook.h`), for both backends.

## Glass and motion (T-204, `04` §3.8)

A glass surface gets its sheen, grain and lit rim from `GlassLayers` (no flat `glassBorder` on glass) and its drop shadow from `GlassShadow` (placed before the surface; only the outside is drawn; a focus-dependent one sets `active`, and a card's shadow follows the art's `scale`); a focusable card gets `CardFocusLayers` inside its art. Page and overlay transitions use `easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap`, lifts `Theme.easeGlide`, pops `OutBack` with `easing.overshoot: Theme.popOvershoot`. Every duration is a `Theme` token, already scaled by `motionScale` (0 under reduced motion), so never multiply again. A decorative animation (glare, shimmer) is also guarded on `Theme.glareOn` / `Theme.shimmerOn` (motion on, not Performance). Tests of these assert properties and animation state (`running`, counters); `GlareGate.fakeNow` fixes the clock of the 300 ms glare rule.

## Gliding highlight and liquid pill (T-205, `04` §3.8)

A single-row selector uses `FocusGlide.qml` (never `Behavior on color` per row): declare it in the items' coordinate space below them (`ListView`: `parent: list.contentItem`, since declared children are not put there), `target` the focused item, `shown` the owner's `activeFocus`, and let each item drop its own focus fill while `glide.active`. The highlight is a picture: it never takes focus, and the ring and the accessible name stay on the real items. Shaders are `shaders/*.frag` compiled by `qt_add_shaders` (`shell/CMakeLists.txt`, optional ShaderTools) and loaded by relative `.qsb` URL from a ShaderEffect; a missing one must leave the plain look (`LiquidGlass.compiled`). Nothing decorative may animate forever on a still screen: the specular clock obeys `LiquidGate` (no app, window shown, input in the last 30 s). Tests read `targetX/Y`, `x/y`, `gliding`, `stretch` and `stepStretch`; the offscreen software renderer draws no shader, so only `shots` shows the liquid pill.

## Test motion scale (T-463)

`windowGuard.ensureActive()` (so every `init()`) sets `Theme.motionFactor` to 0.1 (all duration tokens a tenth; `shots` keeps 1, `RUYA_TEST_MOTION=<f>` overrides), because offscreen tests only look at where an animation ends. A test (or a file) whose **subject is a duration** (a token's value, a mid-fade sample, glide timing, the shimmer period, an order relative to the glide's duration) sets `Theme.motionFactor = 1.0` itself, in `init()` after the windowGuard line or at the top of the test, with a comment saying so (`tst_motion`, `tst_glide`, single tests in `tst_glass`/`tst_themes`/`tst_appflow`/`tst_wallpaper`, `tst_settings_lazy` `test_a_replaced_page_goes_after_the_glide`). A `cleanup()` that resets it to 1.0 is harmless. A wait on a short fade is `tryVerify`/`tryCompare` or `Theme.pageMs + n`, never a literal `wait(300)` (waits of 1 s or more are conditions). A time that is **not** a `Theme` token (`Sfx` ducking, the ambient bed's 800 ms fade, a hold time, a mock's 300 ms pairing window) is not scaled: a negative check ("nothing happens within X") keeps its wait.

## Test member lint (T-189, `scripts/lint-test-members.ps1`)

qmllint runs over `tests/*.qml` and any finding fails. A read of a member QML cannot see (a C++ constant without `Q_PROPERTY`, a typo, `tc.shell.foo` on a `property Shell shell`) is `undefined` at run time, so `wait(x + 200)` waits nothing and `verify(x !== y)` is always true. Fix: expose the member or the name; never silence it. Type a test's shell as `property Shell shell` (a `var` or `Item` is not checked). qmllint goes silently blind on a file with a local (`const`, `let`, `for (const ..)`) inside a nested function or block-bodied arrow; a canary read per file catches that: lift the function to a top-level function of the `TestCase`. `windowGuard` and `shotsDir` (context properties) are not checked.

## A `shots` window that presents no frames (T-460, T-462)

With the display asleep `frameSwapped` never fires and `update()` brings no frame, yet animations, timers and `grabImage` still work. Product code that waits for a presented frame needs a path for that case (the page slots go at once when no frame came while closing), and a test that must see a frame proves it offscreen, where frames are drawn. `dev.ps1 shots` probes for a presented frame first (2 s) and stops with "The display is asleep: wake it and run shots again." The same stall can start after the probe passed (RUY-474: a window that swapped its first frame and then none; `update()` and `requestUpdate()` draw nothing, a resize or hide/show does): no item is polished, so a `ListView` makes no delegates (`contentHeight` 0, a toast stack that "is never at rest") and animations stand still. In `shots` the `WindowGuard` (`tst_main.cpp`) therefore posts the update request itself when no window has swapped a frame for 250 ms, so a wait on a layout or a fade does not depend on the desktop. A shots check that waits on a layout is still a check of the product: the pump only supplies the frames.
