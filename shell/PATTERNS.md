# shell/ — patterns reference

Read this when your task adds a page, a settings row, a modal, text input or a translated string. The rules every shell change must follow are in `shell/CLAUDE.md`; this file is the how-to and the component catalogue (moved out of `CLAUDE.md` in the 2026-10-27 docs slimming, so the rules file stays short).

## How to add a page

1. Create `XxxPage.qml` as a `Page { id: page; title: qsTr("Xxx") … }` (see `Page.qml`, `ComingSoon.qml`). Put one `focus: true` element in it; size from `page.u`.
2. Add the file to `CMakeLists.txt`, and a `Component { id: xxxPage; XxxPage {} }` plus an entry in `pageComponents` in `Shell.qml`.
3. Open it with `Shell.openPage("xxx")` (home tiles do this with their `key` role). Back is handled by `Page`; never steal the Guide keys in a page, so the overlay still works.
4. Test in a `tst_*.qml`: open, assert focus, Back, assert focus restored (see `tst_pages.qml`).
5. **Nested pages:** `Shell.openPage(key, params)` pushes a page over the current one (`params` is a plain object, available as `page.params`; `Shell.currentParams` is the top entry's). The page below stays alive, hidden and disabled, and gets its focus item back on Back. A test or module registers a page without editing `Shell.qml` through `Shell.extraPages = ({ key: component })` (see `tst_pages.qml`, `detailPage`). Keep `pageStack` a plain array and reassign it.

## Controls (`qml/controls/`)

Reusable settings rows. All extend `SettingControl` (a `FocusScope` with the label, the glass bar and a focus ring; pass `u` and `label`). Put rows in a `SettingsPane` (`qml/SettingsPane.qml`): it moves between rows with Up/Down, and Left/Back leave it (`exitRequested`). Rows handle only their own keys and let everything else bubble.

| Control | Keys it consumes | Value and signal |
|---|---|---|
| `SettingRow` | Accept | `value` (text); `activated()` |
| `ToggleRow` | Accept toggles | `checked`; `toggled(checked)` |
| `ChoiceRow` | Left/Right cycle `options` (`[{value, label}]`), wrapping | `value`; `edited(value)` |
| `SliderRow` | Left/Right step by `stepSize` within `from`..`to`, clamped | `value`; `edited(value)` |

`Badge` (`qml/Badge.qml`, 04 §5): `text`, `kind` (`neutral | success | info | warning`), `u`. Static, never focused; its `Accessible.name` is its text.

A control changes its own value, then emits the signal; the owner writes the setting, resyncs the control, and keeps a `Binding` on it so external changes show (see `DisplayPane.qml`). `Sfx.navigateCount`/`selectCount`/`backCount` count cue requests so tests can check the sound path.

## Modals from pages

A page that needs a full-screen modal (PIN pad, `TextEntry`) declares it as `parent: page.overlay` (the shell's `modalLayer`) with `width/height` taken from that parent, not as a child of the page, so it covers the whole screen and sits above toasts. Save `Window.activeFocusItem` before opening and refocus it when the modal closes (see `ProfilesPane.qml`); `TextEntry` does this itself. `PinPad` has three modes: `open(profile)` verifies with `Profiles.switchTo`; `collect(prompt, confirm)` hands the PIN back through `collected(pin)` (and `cancelled()`), calling no service. Multi-step flows are small state machines in their own non-visual file (`ProfileAddFlow.qml`, `ChangePinFlow.qml`).

Messages for Profiles1 statuses (`invalid`, `wrong-pin`, ...) come from the `ProfileStatus` singleton (`ProfileStatus.describe`); don't write a second mapping. The first-boot wizard (`Setup.qml`, not a page) hosts its own modals in an inner full-screen layer and is shown by `Shell` while no profile exists.

## Text input

Use `TextEntry` (`qml/TextEntry.qml`, spec 02-shell §4.4) for any text input; never a raw `TextInput` without it. Host it as a full-screen child of the screen that needs it, call `open(title, initial, options)`, and handle `accepted(text)`/`cancelled()`. It restores focus to the item that opened it.

## Translations

- Strings are translated with Qt `.ts` files in `shell/i18n/` (`ruyashell_en.ts`, `ruyashell_tr.ts`), compiled by `qt_add_translations` into resources `:/i18n/ruyashell_<lang>.qm`. English is the source language; its `.ts` only exists for the plural forms (`%n`), so every English entry's translation is its own source text.
- `DeviceSettings.language` is the one place the language lives. Setting it installs the `QTranslator` and calls `QQmlEngine::retranslate()`, so the UI changes live. Defaults: the stored value, else the system locale, else `en`; with `RUYA_SETTINGS_EPHEMERAL=1` (tests) always `en`.
- **Refreshing the files** (the command and the lint) is in `shell/CLAUDE.md`, "Translations". CI's `lint` job checks the committed files only; `dev.ps1 shell`/`test` first refresh temporary copies, so a forgotten refresh fails locally.
- **Bindings re-translate; stored values don't.** `retranslate()` re-evaluates bindings that call `qsTr`. A message written into a property at event time (`message = qsTr(...)`, `ProfileStatus.describe(...)` results kept in `Setup`, `ProfilesPane`, `PinPad`; toast text in `Notifications`) keeps its language until the next event. That is accepted for transient messages; for anything long-lived derive the text in a binding.
- **A model must not change with the language.** Assigning a new array to a `ListView`/`Repeater` model resets `currentIndex` (and so focus). Models hold keys only (`Shell.tiles`, `SettingsPage.categories`); the visible text is a binding in the delegate (`Shell.tileTitle`, `SettingsPage.labelFor`). Add new translated lists the same way.
- **Do not translate** the brand "RuyaOS" and the language names ("English", "Türkçe", each shown in its own language).
- **Add a language:** add `i18n/ruyashell_<code>.ts` to `qt_add_translations` in `CMakeLists.txt`; add the code to `DeviceSettings::isValidLanguage`; add an option to the language `ChoiceRow`s (`SystemPane.qml`, `Setup.qml`); add a `letterSets` entry in `TextEntry.qml` if its letters differ from a-z.
- **RTL check:** `ruya-shell --reverse` lays the UI out right-to-left (`Main.qml` sets `LayoutMirroring` from `Application.layoutDirection`). Left/Right then mean the visual direction on horizontal lists. It is a readiness check only: before an RTL language ships, review RTL screenshots of every screen (the PIN pad's digit grid must stay left to right; the toast layer, sliders and `ProfileCard` badges were never examined).

## App layer and key router (T-150)

- `Shell.addApp(item)` reparents an app item into `appLayer` (z 5: above home and pages, below toasts, modals, the Guide overlay and the OSD), fills it and focuses it; `focusApp(item)` switches; `removeApp(item)` (also run when the item is destroyed) hands focus to the next app, else the page or the home tiles. Never keep a destroyed item in a JS array and touch it (QML throws): `Shell` keeps `{item, id}` records and a guard child per item.
- `KeyRouter` (`src/input/`, instantiated in `Shell`) is an event filter on the window. While `appItem` has active focus it takes the Guide keys (`isGuideKey`: HomePage, Super, Meta) and emits `guidePressed/Released`; all other keys reach the app by normal focus delivery, volume keys are application `Shortcut`s. Test with a stand-in item: `tests/tst_compositor_layers.qml`.
