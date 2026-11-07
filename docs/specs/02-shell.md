# RuyaOS — Shell UI/UX

Status: **Draft v1** · Parent: [00-overview](00-overview.md)

The shell (`ruya-shell`) is the only UI the user sees. It's written in Qt 6 Quick/QML with C++ glue. Per ADR-002 (option A, accepted) it is also the Wayland compositor, directly on KMS (T-130; on the Windows host and in the tests it is an ordinary window). It holds no business logic: state and side effects live in the Rust services, which it reaches over D-Bus.

## 1. Information architecture

| Surface | Contents |
|---|---|
| **Profile picker** | Avatars and a guest tile; PIN pad (modal, numeric focus only) |
| **Home** | Art-led (owner, 2026-10-28; built T-146, look in 04 §2): full-bleed hero art of the focused Recent item (`Library.recent`, cross-fade over `tintMs`), hero block with Play and Details, a Recent row of art cards (focus moves the hero), section nav (Home, Games, Media, Store, Settings) in a top bar. Focus starts on Play; Down goes to the Recent row, Up to the hero, then to the nav; LB/RB open the next/previous section (after the focused pill, or after the section on screen when focus is in the content); the top bar (section nav and status cluster) shows on Home and on the four section pages (T-168), not on detail pages, the picker, the wizard or a running app, and the Guide overlay disables it; Accept on Play or a card calls `Library.launch` (launching itself is T-147); Details opens a "Coming soon" page; Back does nothing. Nothing played yet (no item has `last_played`) but something installed (T-183): the row holds the first eight installed items in the library's order (the Games page's: played first, then by title), the eyebrow says "Installed" instead of "Continue playing", and focus and Play work as usual. Only a library with nothing installed shows "Your library is empty" with a primary Open Store. Power is in the Guide overlay; the Power page is still opened with `Shell.openPage("power")`. |
| **Library** | All installed apps and games; filter (Games/Media/Apps/Source) and sort. **As built (T-113):** the `Library` singleton (`org.ruyaos.Library1`: `items`, `games`, `recent` = 8 by last played, `rescan()`, `launch(id)`; launch only emits `launchRequested` until the session service exists) and the Games page: art cards in 4 columns, a source filter (All/Steam/Flatpak), Accept toasts "Starting <title>…"; an empty library offers the Store. Art is the fallback (initials on a tint) until the asset pipeline. Not yet: Home Recent row (T-146), Media/Apps/sort. |
| **Store** | Featured, categories, search, app page (art, screenshots, rating, permissions, source badge Official/Community/Dev), install/update queue. **As built (T-111):** Search and "Show all apps" on top, rows Featured (official), Games (controller `full`), Apps & media (the rest) and Installed; apps without controller support are hidden until "Show all apps" (the service filters). Accept opens the app page (`appDetail`); a search replaces the rows until Back. No screenshots, ratings or categories yet |
| **Settings** | Profiles, Network, Bluetooth & controllers, Display (resolution, refresh, HDR later), Audio (output, volumes per channel), Storage & devices, Parental (later), Accessibility, System (update, channel, rollback, factory reset, about). Built so far (T-103, T-105, T-114, §1.2): the two-pane page, **Profiles**, **Display & motion**, **Audio**, **Bluetooth & controllers** (T-136: power switch, scan and pair by keys, connect/disconnect, forget, battery; low-battery toast at 15 % or less), **Storage** (T-137, T-196: a first group "This console" with the free space ("450 GB free of 464 GB") and a usage bar (the warning colour with less than 10 % free), then "Apps and games" and "Other" (everything used that is not apps; with the profile data known, "Profile data" and "System" instead: today it is not, T-196); under "Drives", USB drives (and an internal disk mounted outside the system paths) with free space, Eject, a reason for unsupported drives; toasts "Drive inserted: <label>" (one per drive; a stick with several partitions adds "(and N more)") and "Safe to remove", no actions yet), **System** (the Language row, T-109, and the Updates group, T-135) and **About**; the other categories show "Coming soon". |
| **Overlay** (Guide button) | Quick menu (planned T-147): over a running app Resume, Home, Close app, Switch to, volume, profile, power, screenshot (later); without an app the same panel minus the app part. Today: the centred system card (§1.4). |
| **System UI** | Volume OSD, toasts (both built, T-108: see §5.1), device-inserted prompt, update-ready prompt, low-battery controller warning. The top-right **status cluster** (T-223) shows one chip per connected wireless device that reports a battery: controllers, headsets, speakers, mice, keyboards. A chip is the icon of the device's kind, a battery glyph that matches the level and the percentage; devices are ordered lowest battery first, at most three chips, the rest collapse into one "+N" (its accessible name lists them; the cluster is sized from the room between the nav and the right margin: the profile name elides, never under about six characters, and when a long name leaves no room fewer than three chips show and the rest join the "+N", so the cluster always keeps a `spaceM` gap to the nav; Settings -> Bluetooth & controllers shows every device's battery). A device that is 100 % on the charger has no chip until it is unplugged; a device that reports no level has none. Discharging at 15 % or less: the alert glyph in the warning colour. Chips are never focusable (the cluster takes no focus) and carry the device name only in the accessible name ("DualSense Wireless Controller battery 62 percent, charging"). The low-battery toast is unchanged: controllers only (`Batteries.batteryLow`); other kinds toast through `Bluetooth.batteryLow`. |
| **OOBE / Installer** | 01 §5. OOBE as built (T-106): see §1.3. |
| **Safe mode** | 01 §2.1 |

Each surface is a separate QML module loaded with `Loader { asynchronous: true }`. Home stays resident.

### 1.1 Page model (as built, T-101)
- Home's section nav carries stable keys: `home`, `games`, `media`, `store`, `settings` (`SectionNav.keys`). Accept on a pill (or LB/RB) calls `Shell.openPage(key)` (`home` just focuses Play); a page key `power` exists too, reached from the Guide overlay's own choices and by code; a page opens a detail page on top of itself with `Shell.openPage(key, params)`. `pageStack` holds `{key, params}` entries; `currentPage` is the top key, `currentParams` its params (also the page's `params` property). `closePage()` pops the top entry.
- A page extends `Page.qml`: title below the header, a content area inside the safe area, and Back (`Escape`/`Back`), which plays `Sfx.back()` and closes the page. The page's `focus: true` element gets focus when it opens. Every stack entry has its own live page item inside a slot item under `pageHost`: only the top slot is shown and enabled, lower ones stay alive hidden and disabled, so their scroll position, state and focused item are kept (the shell notes the focused item when a page is pushed over and restores it on pop). A popped slot fades out, then is destroyed; signing out destroys all of them at once. Pages not in the shell's own list can be registered through `Shell.extraPages` (key -> Component).
- Transition: home fades out and slides left, the page fades in and slides in from the right, over `Theme.pageMs` (`Theme.pageSlide` px); reversed on close. A nested page uses the same fade/slide, cross-fading with the page below. The backdrop stays. While a page is open, home is disabled, so arrow keys cannot reach Home.
- Section nav on pages (T-168): one `SectionNav` instance in the shell's top layer (`navShown`: signed in, no app, and either Home or a section page on top; fades with `pageMs`). Its `section` follows the page on screen (`navSection`), so the Settings gear is filled on Settings. `Page.qml` turns an Up that no content item accepted into `upFromTop` (the shell focuses the nav on the page's pill), and PageUp/PageDown into `stepRequested`; Down from the nav restores the page's saved focus; Back from the nav closes the page. Moving between pills moves one gliding highlight under them (T-205, 04 §3.8): a picture only, focus and the nav's accessible name change at once and stay on the nav. Switching section from a page closes the open pages first, so Back lands on Home.
- Closing a page (or the Guide overlay) restores focus to the Home item that had it (a nav pill, Play, Details or the Recent row at its card): `Shell.homeSavedFocus`, set in `openPage` and when the overlay opens, used once by `focusHome()`. `Shell.routeFocus()`/`focusCurrent()` is the single place that decides where focus goes.
- The Guide overlay opens from home or from any page (the shell handles `HomePage` and `Super` when nothing under focus does; `Menu` is the context-menu key, not Guide). Closing it returns focus to the page. "Switch profile" clears the page stack, so the next sign-in lands on home.
- Games, Media and Store are placeholders ("Coming soon" plus one focusable element) until their tasks land; Settings (§1.2) and Power (§1.4) are real.

### 1.5 Full-screen apps (target; owner 2026-10-28; T-130, T-138, T-147)
- Every app and game runs full screen in the shell's app layer (ADR-002 A, T-130). As built (T-150): `Shell.addApp(item)`, `focusApp`, `removeApp` manage the layer (`appLayer`, z 5: above home and pages, below toasts, modals, the Guide overlay and the volume OSD); the last app item removed or destroyed gives focus back to the page or Home. While an app is in front the shell draws nothing over it except the quick menu, the volume OSD and critical toasts (errors, low controller battery); other toasts wait until the user is back in the shell.
- Launch (Play on Home, a card, or the Store's Open): input to the shell locks, the launch transition and splash run (04 §5.1) until the app maps its first window, then the app gets focus. Failure: error toast, focus back where Play was. After 20 s without a window the splash offers Close.
- Guide (short press) opens the quick menu over the live app; Back or Resume closes it and returns focus to the app; holding Guide still opens the power choices. Home leaves the app running (it becomes the Running card in Recent; Accept on it resumes). Close app asks `Session.stop` and confirms only when the app reports unsaved state (later). One app is in front; others keep running until closed (memory limits: later).

### 1.2 Settings page (as built, T-103)
- Two panes. Left: the category list (Profiles, Network, Bluetooth & controllers, Display & motion, Audio, Storage, Accessibility, System, About). Right: the selected category's pane. Up/Down choose a category and swap the pane at once; Right or Accept enters the pane (only if it has content); Left or Back returns to the list; Back on the list closes the page. Panes stay alive, and each remembers its last focused row.
- Inside a pane, Up/Down move between rows (clamped, no wrap); a pane with more rows than fit scrolls to keep the focused row visible, and if the focused row disappears focus moves to a nearby row. A row keeps the keys it uses: a ChoiceRow or SliderRow consumes Left/Right, so those never leave the pane (leave with Back); ToggleRow and SettingRow leave Left to the pane, which returns to the list.
- **Profiles** (T-105): the list of profiles, Add profile (admins), Change/Remove my PIN; see 03 §1.1 "UI flows". Its modals (PIN pad, on-screen keyboard) live in the shell's `modalLayer` (above pages and toasts, below the picker and the Guide overlay); a page reaches it through `Page.overlay`.
- **Display & motion** writes live to `DeviceSettings`: Effects quality (High/Balanced/Performance, cycling), Reduced motion (toggle), Screen edge (overscan, 0-10 % in 1 % steps), **Theme** (T-209: Dreamglass, Midnight, Aurora, Ember, Daylight, cycling with Left/Right; three small chips before the name show the ground, the glass over it and the tint of the theme shown; applies at once with a cross-fade, focus stays on the row; `04` §3.1), and (T-208) **Wallpaper** and **Dim wallpaper**. The rows follow the setting, including changes made elsewhere.
  **Wallpaper** (T-208; decided to live here rather than in a new "Appearance" category: the list already scrolls at nine, and the wallpaper is a display look like the effects tier): the row shows the current name ("Default (animated blobs)", "Dusk", a copy's file name) and Accept opens the picker, a modal in the `modalLayer` (hint bar: B Cancel). The grid has four columns of 320 px thumbnails: the default look, the six bundled pictures, then the owner's copies (at most 12), the current one badged "Current", focus on it when the picker opens (the focus ring is drawn outside the art at `focusRingOffset`, like the primary buttons, so it reads on a white thumbnail and in the dark Daylight ring). Arrows move (clamped, no wrap), Accept chooses it and closes, Back closes without choosing; Down from the last row goes to the buttons under the grid: **Add from USB drive...** (only while a mounted removable drive has pictures: the shell scans every mounted removable volume, again whenever the volume list changes) and **Delete** (only while a copy is highlighted; the wallpaper falls back to the default look when the deleted copy was the current one; a toast "Wallpaper deleted"). Add shows the drive's pictures in the same grid (title "Pictures on the USB drive", listed by file name with a thumbnail, sorted by name: jpg, png and webp files (webp only where Qt's image-formats plugin is installed: the image does not carry it yet, so there a webp file is simply not listed) directly inside a folder named `Wallpapers` or `Pictures` of the volume, any case, no deeper, regular files only, at most 25 MB and 40 megapixels each, at most 60 listed; nothing on the drive is ever run). Accept on one (only a picture of the current list is accepted; names are drawn as plain text, never markup; at most 200 files are looked at per folder) copies it into the shell's own state directory (`Wallpapers.directory`: `~/.local/share/ruya-shell/wallpapers`, or `RUYA_WALLPAPER_DIR`) with the grid showing "Copying..." and every key swallowed until it ends: the picture is scaled to cover the screen (never enlarged, at most 3840x2160), flattened and re-encoded as JPEG quality 88 on a worker thread, named by the hash of the result (the same picture twice is one copy), and listed in `index.json` with its name and brightness. On success the copy becomes the wallpaper, a toast "Wallpaper added", and the picker returns to the library on it; on failure the grid stays with the reason ("You can keep up to 12 wallpapers. Delete one first." at the limit, "This picture is too large.", "This kind of picture is not supported.", "This picture could not be copied.") and a toast "Could not add the wallpaper". Back in the drive's pictures returns to the library. Removing the drive loses nothing (the copy is ours) and hides Add. **Dim wallpaper** (shown while a wallpaper is set): a slider 0-60 % in 5 % steps, default 20 %; a bright picture (or, under Daylight, a dark one) is veiled further than the slider says (`04` §3.5). If the drive is pulled while Add from USB drive has focus, focus moves to the grid. Per-profile wallpapers are not built: profile homes are 0700 and the shell cannot read them.
- **System** (T-109, T-135): the Language row, then an "Updates" group over `Update1` (mock only for now): a read-only Version row ("0.0.18 · Stable"), an admin-only "Update channel" row (Stable/Beta), an admin-only "Restart automatically for updates" switch (on by default: the service restarts into a staged update at night when the console is idle, `01` §4), and one update row that follows the state: "Check for updates" (value: last check / "Up to date" / "Failed"), "Download version X" once a check found one, "Downloading version X" with the percentage, then "Restart to finish" (Accept opens the restart confirm; the row keeps focus through all of it). Admins also get "Roll back to the previous version" when `rollback_available`: admin PIN (`Profiles.verifyAdmin`), then a confirm, then `Update.rollback()`. When an update becomes `staged` a toast "Update ready. Restart to finish." appears once.
  **Device health** (T-200, `Thermal`, `org.ruyaos.Devices1.Thermal`) is the last group of System: one read-only row per sensor, named by class and numbered when there are several ("Processor 33 °C", "Drive 41 °C", "Fan 1820 rpm"), in the service's order (processor, graphics, drives, fans), updated in place (focus stays on a row while its value changes; if the focused row goes away focus moves to a neighbour). A sensor whose level is not normal gets a small round mark and the word ("Warm" in `warningText`, "Hot" or "Critical" in `errorText`; colour is never the only signal). While the worst level is not normal a line under the heading says what the console does (warm: nothing needs to be done; hot: effects are reduced; critical: apps are closed and it may power off), and the **System category** in the list carries the same mark. No sensors (a VM): "No temperature sensors were found on this device." What the shell does at each level is in `01` §2.4; **Display & motion** keeps showing the owner's quality while the console is limited for heat.
- **About** (read-only): image version (the `version` the shell was started with), Qt version (runtime, from the `SystemInfo` singleton), services mode (mock or D-Bus), and the licence line.
- Reusable controls live in `shell/qml/controls/` (`SettingControl` base, `SettingRow`, `ToggleRow`, `ChoiceRow`, `SliderRow`); see `shell/CLAUDE.md`.

### 1.4 Power (as built, T-107)
- The **Power page** has three rows: Suspend, Restart, Power off. Accept opens `PowerConfirm` ("Restart now?", Cancel and a button that names the action: "Restart now", "Power off now", "Suspend now"). **Cancel has focus when it opens**; Left/Right move between the buttons, Back cancels, and the dialog swallows every other key. The action button's visible label is also its accessible name (T-186, T-194); a long label (a profile name in "Delete <name>", Turkish) widens the button and elides only when the dialog is full. Only Confirm reaches the `Power` singleton (`suspend()`, `restart()`, `powerOff()`). A row whose action logind does not allow (`CanSuspend` etc. is not `yes`) shows "Not available" and opens nothing.
- The **Guide overlay** has "Switch profile", **Power** and "Close". "Power" switches the overlay to the power choices (Suspend, Restart, Power off, Back; actions logind refuses are hidden), and a choice opens the same `PowerConfirm` above the overlay. Cancel returns to the choices; Back in the choices returns to the system actions; Confirm closes the overlay.
- **Holding Guide** for `Theme.guideHoldMs` (2 s) switches the open overlay to the power choices. A short press still opens the overlay at once (on press); the hold is timed from that press, and the release cancels it. Autorepeat events of a held key are ignored (they used to close the overlay: the overlay treated them as a second Guide press). Only Guide holds (the controller button or Super); Start/Menu is not Guide at all (T-124).
- A refused or failed action shows an error toast ("Could not restart."). Idle auto-suspend and wake sources are not part of this task (01 §2.2).

### 1.3 First-boot setup (as built, T-106)
- `Setup.qml` is a full-screen modal (z 20, like the picker). The shell shows it when `Profiles.available && Profiles.profiles.length === 0` and keeps it up until its Done step, so the picker never flashes in between "profile created" and "all set". If a profile appears some other way before the account is being created, the shell drops setup.
- Five steps with a progress indicator ("Step n of 5"): Welcome, Language, Network (placeholder), Create admin, Done. Accept (Return) continues, Back (Escape) goes to the previous step with its state kept; there is no Back on the first step, or once the account exists (Done).
- Create admin: a Name row (opens the on-screen keyboard, 32 characters) and a "Choose a PIN and finish" row (PIN pad in collect-and-confirm mode, then `Profiles.createProfile("", "", name, "admin", pin)`). A missing name or a service refusal is shown as a message on the step (messages come from the shared `ProfileStatus` singleton, also used by Settings → Profiles) and the user can retry. Cancelling the PIN pad creates nothing.
- After Done the shell shows the picker with the new profile; nobody is signed in automatically.
- For development, `RUYA_MOCK_PROFILES=empty` starts the mock services without profiles (see `docs/dev-setup.md`).

## 2. Visual language
Defined in [`04-design-system.md`](04-design-system.md) ("Dreamglass", ADR-012): principles, colour/type/spacing/radius/motion tokens, focus, depth, the component catalogue, copy rules and the screenshot review list. In short: dark theme, 10-foot type (body 30 px, min 24 px at 1080p), 5 % safe area, frosted glass over blurred hero art, the focused item scales to 1.08 with a white ring that is never hidden, and every value is a `Theme` token.

## 3. Motion & effects

### 3.1 Techniques
| Technique | Use | Caveats |
|---|---|---|
| `Behavior on x/opacity/scale` | Implicit motion for focus, cards | Don't combine with an explicit animation on the same property |
| `states` + `transitions` | Page and panel layouts | Keep the state count small and named |
| `Sequential/ParallelAnimation` | Choreographed sequences (launch, boot-in) | Must be interruptible: a new input cancels and settles |
| Animate `opacity`, `scale`, `x/y`, `rotation` only | GPU-cheap | Avoid animating `width/height`, layout or text |
| `layer.enabled` / `ShaderEffectSource` | Cache static subtrees and the **single shared blurred backdrop** | Costs VRAM; invalidate rarely |
| `MultiEffect` (blur, shadow, colourise) | Frosted panels, glow | Keep `blurMax` low on low tier; blur a downscaled source |
| Custom `ShaderEffect` | Special effects | Shaders precompiled to `.qsb` via `qt_add_shaders()` in CMake; **no inline GLSL in Qt 6** |

Blur pattern: render the backdrop (hero art) once to a quarter-resolution `ShaderEffectSource`, apply `MultiEffect` blur to that, and share the result among all panels. Re-blur only when the hero art changes, with a crossfade.

### 3.2 Durations
Focus move 120–160 ms, page transition 250–350 ms, overlay open 200 ms, all ease-out. These are defined as tokens. **Reduced motion** sets the `focusMs`, `pageMs` and `tintMs` tokens to 0, removes the page slide (`pageSlide` = 0) and stops the backdrop drift. (Implemented as 0, not 60 ms crossfades.) Every duration token is its base value times `motionScale`, which is 0 under reduced motion (T-204). The card glare and the art-placeholder shimmer (04 §3.8) do not run either, while shadows stay. The feedback animations are also off under reduced motion: the PIN-pad wrong-PIN shake and the Accept pulse on art cards do not run at all (the error message and sound, or the launch toast, remain). Their sizes and durations are `Theme` tokens (`shakeDistance`, `shakeQuickMs`, `shakeSlowMs`, `pulseScale`, `pulseDownMs`, `pulseUpMs`). The setting is per device (`DeviceSettings`), and `--reduced-motion` forces it for a session.

### 3.3 Quality tiers
`Effects = High | Balanced | Performance`, chosen automatically at first boot from the GPU (renderer string plus a quick benchmark) and overridable in Settings. **Implemented so far:** the per-device `effectsQuality` setting and the `--effects` flag; automatic detection is still open (needs real hardware).

**Heat (T-200):** when the console runs hot the shell drops to Performance for the session (`DeviceSettings.thermalLimited`: `effectsQuality` reads `performance`, `storedEffectsQuality` keeps the owner's choice) until the temperatures are normal again (`01` §2.4).

Token values per tier (`Theme.qml`): `blurMax` is 64 / 32 / 0, and the glass `MultiEffect`s (`GlassPill`) are hidden at 0, where the pills use the more opaque `glassOpaque` token. Ambient drift of the backdrop runs on High and Balanced, and stops on Performance. On High the glass pills also draw the liquid look (`Theme.liquidPill`, 04 §3.8). Overscan (`safeArea`) is a per-device fraction 0.0 to 0.10, default 0.05.

| | High | Balanced | Performance |
|---|---|---|---|
| Backdrop blur | Full, ½-res source | ¼-res source | None (dim + static pre-blurred image) |
| Parallax / ambient motion | On | Reduced | Off |
| Art resolution | 4K variants | 1080p | 720p |

## 4. Input & focus model

### 4.1 Event path
Physical pad → input daemon (ADR-003) → shell. While the shell has input focus, the daemon emits navigation as key events (Up/Down/Left/Right, Accept, Back, Menu, Guide, LB/RB, LT/RT) to the compositor's seat. While an app is focused, only **Guide** (and the volume keys) reach the shell. As built (T-150): the C++ `KeyRouter` (event filter on the window, `shell/src/input/`) takes the Guide keys, including Super and the Guide hold, from a focused app item and hands them to the shell; the volume keys are application shortcuts matched before any key event; every other key reaches the app by normal focus delivery (the router counts focus on the app item or any item inside it). In the image (T-130) the app items are `ShellSurfaceItem`s, one per xdg toplevel, which forward the keys they get to their Wayland client. `KeyRouter.isGuideKey` is the one definition of which keys are Guide. Keyboard and mouse go through libinput and the compositor as normal.

### 4.2 Mapping
| Action | Xbox | PlayStation | Keyboard |
|---|---|---|---|
| Accept | A | ✕ (configurable to ○ for JP layout) | Enter |
| Back | B | ○ | Esc / Backspace |
| Context menu | Menu (☰) | Options | `M` / context key |
| Guide / overlay | Xbox | PS | `Super` (left or right; holding it opens the power choices) |
| Tab switch | LB/RB | L1/R1 | `Q`/`E`, PgUp/PgDn |
| Fast scroll | LT/RT, stick held | L2/R2 | Home/End |

As built (T-179): the singleton `BackKey` (`shell/qml/BackKey.qml`) is the one definition of which keys are Back. `BackKey.isBackOrBackspace(key)` (Back, Esc, Backspace) is what pages, Settings panes, the section nav, the setup wizard, the Guide overlay and the confirm dialogs use. The text fields (`TextEntry`, `PinPad`) use `BackKey.isBack(key)` (Back, Esc) only, because there Backspace deletes a character and never goes back. Back acts on every key event, as Esc always did; it does not filter auto-repeat.

### 4.3 Rules
- Every screen has exactly one `FocusScope` root, and every interactive item is reachable with the D-pad. Directional navigation uses `KeyNavigation` or a small spatial-navigation helper (nearest item in the direction pressed).
- Focus is never lost. When the focused item disappears, focus moves to the nearest sibling, else to the scope's default.
- Focus is restored per surface and per profile (returning to Home focuses the last-launched tile).
- Key repeat on hold: 400 ms delay, then accelerating repeat. The analog stick maps to the same, with speed proportional to deflection.
- Long-press (≥ 500 ms) on Accept opens the context menu, with a visible progress ring.
- Modal dialogs trap focus. The PIN pad accepts only digits, Back and Accept. While its profile is locked out the digits, Del and OK are dimmed and ignored, and the only message is the countdown; the pad works again when it reaches 0.
- On the profile picker, any controller may act. After login, the logged-in profile's controller is "player 1".
- **Hint bar (T-158).** One `HintBar` in the shell's top layer says what the buttons do on the screen on top. The screen supplies the hints: a page through `Page.hints` (default `A` Select, `B` Back; a page may override it), Home `A` Select and one `LB RB` Sections hint (two glyphs, one verb), the setup wizard its own hints (`Setup.hints`: `A` Next, or Select on the profile step, `B` Back except on the first and last step; `B` Cancel over its keyboard or PIN pad), a page with nothing to select (placeholder pages, Settings > About and categories without a pane) only `B` Back (`Page.backOnlyHints`), the Guide overlay `A` Select and `B` Close (`B` Back in the power choices), a modal whose focus is in the modal layer or the picker's PIN pad `B` Cancel (the on-screen keyboard says `B` Delete while a controller's Back would delete a letter and `B` Cancel when the field is empty or after typing on a physical keyboard; it supplies that itself as `TextEntry.entryHints`, T-194), the picker `A` Select. It is hidden while an app is focused (a Guide overlay over an app still shows its own), never takes focus, and on Home sits under the Recent row.
- The pointer is shown only after mouse movement and hidden after 3 s idle.

### 4.4 Text entry (as built, T-104)
`TextEntry.qml` is the modal on-screen keyboard; every flow that needs text uses it. `open(title, initialText, { maxLength, mask, layout })`, signals `accepted(text)` and `cancelled()`. `layout` is `text`, `email` (adds `@`, `.`, `.com`) or `url` (adds `/`, `.`, `.com`); `mask` shows dots but `accepted` carries the real text; `maxLength` 0 means unlimited. The layout is data (`layoutFor`): rows of keys with a width in key units, on a letters page and a symbols page (the `#+=`/`ABC` key switches).

| Input | Action |
|---|---|
| D-pad / stick | Move over the keys. Left/Right wrap within a row; Up/Down go to the key whose centre is nearest in x (ties go left; no wrap vertically) |
| Accept (A, `Return`) | Press the focused key |
| Back (B, `Escape`) | Delete one character; cancel when the field is empty (`Backspace` never cancels, see below) |
| Start (`Menu`) / keypad `Enter` | Done (does nothing while the field is empty) |
| LB / RB (`PageUp` / `PageDown`) | Jump to Del / Space |
| Shift key | One-shot capital for the next character |
| Physical keyboard | Printable characters insert; `Backspace` deletes |

A controller's A and B arrive as `Return` and `Escape`, the same keys a keyboard sends. So once the user types on a physical keyboard (a printable key or `Backspace`), `Return` means Done and `Escape` means Cancel, until the next D-pad key switches back to controller behaviour. The field is append/delete at the end only. The component swallows every key (including Guide and volume keys' key events) and returns focus to the item that had it when it opened. Not yet used by any flow (T-105 is the first).

## 5. Audio (UI side)
- Channels: **UI SFX** (navigate, select, back, error, notification), **Ambient** (optional loop; default on/off is an open UX question), **Media/App** (everything else).
- These are implemented as PipeWire stream roles (`media.role = Notification|Music|Game|Movie`). WirePlumber policy does **ducking**: Ambient is lowered by about 8 dB while a UI cue or app audio plays, and Ambient is muted whenever an app is in the foreground.
- SFX playback uses `QSoundEffect` with preloaded WAVs. Configure a low PipeWire quantum for the SFX stream to hit the latency KPI.
- Separate volume sliders for UI, Ambient and Master. The volume OSD appears on any volume change, including controller or keyboard media keys.
- Mild stereo panning of navigation SFX by focus x-position (on in High, off otherwise).
- Output switching (HDMI / analog / USB / Bluetooth) follows WirePlumber defaults with a "prefer most recently connected" rule. The shell shows a toast. Covered in 03 §2.3.

### 5.1 Toasts and volume OSD (as built, T-108)
- `Notifications.show(text, kind, iconText)` (QML singleton; kind `info|success|warning|error`, unknown kinds become `info`) queues a toast. `ToastLayer` shows at most 3 at the top right, below the header and inside the safe area; the rest wait in order. Each toast dismisses itself after `Theme.toastMs` (4000 ms), fading and sliding with `Theme.pageMs`/`pageSlide` (so reduced motion removes the movement).
- **Sticky toasts (T-159):** `Notifications.showSticky(key, text, kind)` shows a toast that does not dismiss itself (no timer) and stays until `Notifications.remove(key)`; one per key (showing the key again replaces it), and it can be removed while it still waits in the queue. The first user is the restart notice: while `Update.restartPending` (the service's `restart_at` is set, `01` §4) a `warning` toast "Restarting to finish the update in 2 minutes. Press any button to wait." is up, and it goes when the record clears it. `Update.noteActivity` reports every input to the service while a restart is pending (instead of once a minute), because that press is the one that calls the restart off.
- `Audio` (C++ singleton over `org.ruyaos.Devices1.Audio`, see §5.2) holds the master `volume` (0-100) and `muted`, with `setVolume`, `stepVolume(delta)`, `toggleMute()` and `setMuted()`. `adjusted()` fires after every master command, even a clamped one (and when the master level or mute changes from outside), but not for a channel volume alone.
- **Volume keys while muted** (T-114): Volume Up unmutes and raises; Volume Down stays muted and changes nothing (the OSD shows "Muted"); Mute toggles only the mute.
- `VolumeOsd` (bottom centre) appears on `Audio.adjusted` and hides `Theme.osdMs` (1500 ms) after the last one. It shows the level and a "Muted" state.
- Volume Up/Down/Mute are `Shortcut`s (application context) at the `Shell` root, so they work in every state, modals included, step by 5, and never move focus. Toasts and the OSD are display-only and never take focus.
- Stacking: toasts (z 10) sit above pages and below the modals (profile picker, Guide overlay: z 20); the OSD is on top (z 30).

## 6. Asset pipeline
- Per app, the art set (from AppStream/`x-ruya-*` keys, or our fallback generator) is icon (SVG or 256 px), tile (16:9), hero (16:9, ≥ 1920 px), logo (transparent), and an optional background.
- On install, `ruya-store` produces resized variants (720p/1080p/2160p) in WebP into `/var/cache/ruyaos/art/`. The shell loads only the variant matching the quality tier and display, via a `QQuickImageProvider` (`image://art/<appid>/<kind>`).
- `Image { asynchronous: true; cache: true; sourceSize: … }` always. Show a placeholder or blurhash while loading.
- **Budget:** ≤ 100 MB of textures on the low tier and ≤ 300 MB on mid/high. Off-screen rows unload their art. One shared blurred backdrop.
- Shell-owned assets (sounds, icons, fonts) are compiled into the binary as Qt resources.

## 7. Accessibility & internationalisation
- Text scale (100–200%), high-contrast theme, reduced motion, mono audio, focus-ring size.
- Screen reader: expose `Accessible.*` properties everywhere. Orca support on a custom compositor is **unknown**, so spike it in Phase 2 and record the result.
- Subtitles are app-owned. The shell only offers a system-wide preference that it passes to apps where a standard exists.
- All strings use `qsTr()`. Translations are Qt `.ts` files managed in a translation platform. Layouts use anchors/`LayoutMirroring` so RTL works (tested with a pseudo-RTL locale). Initial locales: en, tr (others later).
- **Built (T-109).** Translations are `shell/i18n/ruyashell_<lang>.ts` (`qt_add_translations`, embedded as `:/i18n/ruyashell_<lang>.qm`; English is the source language and its file carries the plural forms). `DeviceSettings.language` (`en`/`tr`) installs the `QTranslator` and calls `QQmlEngine::retranslate()`, so changing it in Settings -> System (or the first-boot language step) re-translates the open UI at once. Default: the stored value, else the system locale, else `en`. Messages stored in a property when an event happened (PIN-pad and Settings status lines, toasts) keep their language until the next event. Lists that are models never change with the language (they hold keys; the labels are bindings), because a changed model would reset `currentIndex` and lose focus. The on-screen keyboard follows the language: Turkish adds ç ğ ı ö ş ü and the Q layout's extra keys (narrower keys, rows stay 10 units); Shift maps i to İ and ı to I. `ruya-shell --reverse` lays the UI out right-to-left (`LayoutMirroring`), a readiness check: sign-in, the home tiles and Settings stay navigable (tested); the remaining RTL gaps are listed in the T-109 Outcome. A completeness lint (`scripts/lint-translations.ps1`) fails on unfinished entries.

## 8. KPIs (measured on real hardware; QEMU numbers don't count)

| KPI | Target (mid tier) | Low tier | How measured |
|---|---|---|---|
| Frame rate in shell scenarios (home scroll, page transition, overlay open) | 60 FPS, p99 frame time < 20 ms | ≥ 30 FPS, no hitch > 50 ms | `QSG_RENDER_TIMING`/custom frame-swap timestamps → CSV, scripted input |
| Input → photon (in our stack) | < 50 ms, evdev timestamp → page flip | < 70 ms | Timestamp the evdev event and the presentation feedback |
| UI SFX latency | < 30 ms action → audio | same | Loopback capture |
| Shell visible after kernel start | < 8 s | < 15 s | `systemd-analyze` + shell "ready" mark |
| Resume from suspend → interactive | < 3 s | < 5 s | Scripted |
| App launch → first frame (simple Flatpak) | < 2 s | < 4 s | Compositor surface-map timestamp |
| Idle RSS, shell + ruya services | < 250 MB | < 250 MB | `smem` |
| Shell GPU memory | < 300 MB | < 100 MB | `radeontop` / `intel_gpu_top` / `nvidia-smi` |
| Memory growth in 24 h soak | < 5% | < 5% | Soak test |

The UX gate is a moderated test with ≥ 5 people who rate "smooth / modern / immersive" ≥ 4/5 and can complete the core tasks (launch a game, switch profile, install an app) with the controller alone and no help.

## 9. Performance rules
1. Never block the GUI thread. All I/O goes over async D-Bus calls. `WorkerScript` is for pure CPU work only.
2. Bindings and JavaScript should take ≤ 2 ms per frame. Profile with the QML Profiler, GammaRay and `perf` after each feature.
3. Hide off-screen items (`visible: false`). Don't put alpha on fullscreen layers except the one backdrop.
4. Keep V-Sync on. Never set a custom render loop frame rate.
5. Test every effect change on the low tier before merging (CI KPI job on the reference box).

## 10. Risks
| Risk | Mitigation |
|---|---|
| Building a compositor (ADR-002 A) costs more than expected | Phase 1 spike with a timebox; fallback is option B (gamescope + shell client) |
| Blur cost on the low tier | Quality tiers; pre-blurred static fallback |
| Focus bugs in nested scopes and popups | Spatial nav helper plus QML tests that walk every screen with key events and assert `activeFocusItem` is never null |
| Controller double input (shell and game, or Steam Input) | ADR-003 grab/re-emit; Steam Input configuration (03 §5) |
| VRAM pressure from art | Budgets, tiered variants, unload off-screen |

### 5.2 Settings -> Audio and output switching (as built, T-114)
- `Audio` also exposes `channelVolumes` (`ui`, `ambient`, `media`, 0-100, all always present), `sinks` (`[{id, name, kind, isDefault}]`), `defaultSink`/`defaultSinkName`, and `setChannelVolume(channel, value)` (clamped; an unknown channel is ignored) and `setDefaultSink(id)` (result: `setDefaultSinkFinished(id, status)`). Backend: the mock by default on every OS, `RUYA_SERVICES=dbus` for the D-Bus client (the service `ruya-devices` does not exist yet, blocker B-007).
- **Settings -> Audio** (`AudioPane.qml`): one row per output (Accept makes it the default; the default shows "Default"; rows follow hot-plug in place, so focus stays on the row), then sliders for Master volume, UI sounds, Ambient and Media (step 5), then a Mute switch. Changes apply live and the rows follow changes made elsewhere (volume keys, hot-plug).
- `Sfx` scales every cue by the **UI sounds** channel (`Sfx.gain`, navigate keeps its 0.6 base).
- When the default output changes after start-up (a headset plugged in or removed, or the user's choice), `Shell` shows the toast "Audio output: <name>" (the name comes from the service and is not translated).
- The mock mirrors the policy of 03 §2.3: a plugged-in USB or Bluetooth headset becomes the default; when the default disappears the previous default returns. Tests use `Audio.mockPlug("usb-headset" | "bt-headphones")`, `mockUnplug(id)` and `mockReset()`.
