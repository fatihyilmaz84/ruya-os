# System dialogs and game settings: review and refined proposal

Input: "Ruya System Dialogs & Game Settings Integration" (owner, 2026-11-12, written with ChatGPT). Reviewed by the lead against `docs/specs/00-overview.md` (ADRs), `02`, `03`, `04`, `docs/developers/api-surface.md` and the code on `main` (35f1930). Part 1 is the review, part 2 the refined proposal, part 3 the decisions it needs from the owner.

---

# Part 1: Review

## 1.1 Verdict

The intent is right and fits RuyaOS: the shell draws every trusted surface, games describe their settings as typed data rather than UI, OS settings and game settings have clearly separate owners, and nothing depends on the game cooperating. Most of the *principles* (§1.1, §5, §14, §18) already hold or are already decided.

The document was written blind, though. It assumes a generic console OS with services RuyaOS does not have (a Settings Service, a Permission Service, a Dialog Service, a Display Service, a C++ SDK, Storage/File APIs), it does not know three Accepted ADRs it collides with (ADR-022, ADR-033, ADR-024), and it misses the one fact that changes the game-settings design most: **opening the Ruya Hub freezes the game** (ADR-033 point 3). As written it would create a second door for apps, a second overlay service and a settings database, all of which the ADRs rule out. About a third of it is generic boilerplate ("follow existing conventions", 13 documentation deliverables, "no TODOs") that the repository's `CLAUDE.md` and ADR-022 already enforce.

## 1.2 What already exists

| The document asks for | What RuyaOS has today | State |
|---|---|---|
| Shell-rendered, trusted dialogs (§3.1 C, §14.1) | The shell is the compositor (ADR-002 A), so it composites every app and nothing can draw above it (ADR-033 point 3). Modals are `ModalLayer` + `GlassSheet` (04 §5); confirmations exist as `PowerConfirm`, `ModeConfirm`; pickers as `ModePicker`, `WallpaperPicker`, `ZonePicker` | **built** (shell-internal only) |
| The "Game Overlay" (§3.1 F, §10) | **Ruya Hub** = `QuickMenu.qml` (ADR-033; 02 §1.6): game card (Resume, Home, Close game), running-apps strip, Volume, panels Audio, Controllers, Performance, Power. Works with any game, frozen or not, with or without an SDK, Proton included | **built** (T-447..T-455, redesigned by T-471) |
| Overlay works if the game is frozen / unresponsive / has no SDK (§10.4) | True by construction: the Hub is shell UI over the app layer; the game is frozen with the cgroup freezer while the Hub is open | **built** |
| Safe display mode change with auto-revert (§11.2) | Settings > Display & motion: `ModePicker`, the service writes the KMS config and a marker, the shell restarts on the new mode, **"Keep this resolution?"** counts down 15 s, focus on Revert, reverts on silence; the service owns the marker, so it survives a crash | **built** (T-198) |
| Display settings (§5.1) | `Devices1.Display`: resolution, refresh rate, brightness (backlight only), UI size, reset. **HDR and VRR: not built** ("HDR later", 02) | partly built |
| Audio settings (§5.1, §13) | `Devices1.Audio` (ADR-010): output device, volume, mute, microphone; Hub Audio panel and Settings > Audio | **built** |
| Controller settings (§5.1, §12) | Settings > Bluetooth & controllers (pairing, rename, forget, battery); Hub Controllers panel. Remapping, dead zones, profiles, per-game bindings are **Ruya Input** (ADR-024, spike T-366 / RUY-2, then T-367..T-374) | pairing built; mapping **planned** |
| Performance (§5.1) | Hub Performance panel and the performance overlay (FPS, frame time, CPU, RAM, temperatures, GPU; ADR-033 point 4). **OS power profiles: none** | monitoring built; profiles **not planned** |
| Accessibility (§5.1, §17) | 02 §7: text scale (UI size), reduced motion, high contrast, focus ring; all strings `qsTr()`, en/tr; screen reader is an open spike | partly built |
| Permission service (§4.2, §14.3) | **None as a service.** The plan: the per-app permission table inside `ruya-platform` (ADR-022), shown in Settings > Privacy (T-220 / RUY-80) | **planned** |
| SDK (§8) | **No C++ SDK.** The app platform is the Flatpak runtime extension `org.ruyaos.Platform` with the **RuyaKit** QML module and the `Platform1` client bindings (ADR-015, spike T-250 / RUY-109); the `ruya` CLI and `llms.txt` for AI agents (ADR-031) | **planned** |
| The app-facing door and caller identity (§9, §14.2) | **`org.ruyaos.Platform1`** (`ruya-platform`, ADR-022, T-352 / RUY-157, phase 7): maps the caller to its Flatpak app id and profile, checks the permission table, rate-limits, forwards to private services. Today **no service is reachable from a sandbox** (bus policy: shell and root only) | **planned** (identity spike first) |
| File picker integrated with Storage APIs (§4.2) | No Storage API. The tier-B list has a **storage picker**; 03 notes the gap: a portal backend (`xdg-desktop-portal-ruya`) so portal dialogs render in the shell | **approved, unplanned** |
| Settings Service and persistence (§16) | **None.** Device settings are `DeviceSettings` in the shell, profile data is in `ruya-profiles`; a game's own config lives in its sandbox (`~/.var/app/<id>/config`, tier C, `saves-and-data.md`) | n/a |
| Steam Input compatibility (§12) | ADR-024: a "Steam-managed" ownership mode per app (T-371) | **planned** |
| Proton baseline (§15.1) | Everything system-side works for Proton games already; GE-Proton is the default runner (ADR-025) | **built / planned** |

## 1.3 What is missing (genuinely new)

1. **Game settings integration** (§6, §7): no part of RuyaOS has it, no ADR mentions it, and it is **not on the approved tier-B list** (ADR-022).
2. **App-requested system dialogs** (§4): apps cannot ask the shell for anything today. Of the dialogs listed, only the **storage picker** is approved; a confirmation dialog, a device picker and "open a system settings page" are not.
3. HDR and VRR settings; OS power profiles. They are OS features, not part of this framework, and need their own tickets.

## 1.4 Conflicts with Accepted decisions

| # | The document says | The decision it meets | Resolution in part 2 |
|---|---|---|---|
| C1 | A new **Ruya Dialog Service** that authenticates apps and checks permissions | ADR-022: **one** door for sandboxed apps, `Platform1`; ADR-033: no Hub service, no second process | Dialogs and game settings are **interfaces on `Platform1`**; the shell renders. No new daemon |
| C2 | Apps may **modify OS settings** through dialogs (§14.3 "modifying an OS setting" as a capability) | ADR-022 **never public**: "system settings writes" | An app can only **ask the shell to show** a system page; the player changes it there; the app gets no write and at most a read-only result it is already allowed to read (display information is tier B, read-only) |
| C3 | Live preview and immediate apply while the overlay is open (§7.2) | ADR-033 point 3: **the Hub freezes the game** (default on) | Changes are **staged** and delivered when the game is thawed (Resume); no live preview in V1 (decision D2) |
| C4 | Settings stored through the "existing Settings Service"; migration of game settings (§16) | No such service; a game's config is its own file in its sandbox (tier C) | **The game persists its own values.** Ruya stores nothing per game, so there is nothing to migrate |
| C5 | Display mode changes through dialogs over a running game (§4.2, §11) | 02, T-454/T-471: a mode change **restarts the shell and ends every game**, so it is never offered mid-game | Display stays in Settings > Display & motion; the Hub offers no display mode, and an app cannot request one |
| C6 | Controller remapping, dead zones, profiles, game bindings in this framework (§12) | ADR-024 (Ruya Input owns them) and ADR-027; T-374 is "semantic actions and glyphs for apps" | Out of this proposal; game bindings come through T-374's actions, not the settings schema |
| C7 | A C++ SDK (§8) | ADR-015: the client bindings ship in the `org.ruyaos.Platform` runtime extension; RuyaKit is QML | Bindings in the runtime extension; plain D-Bus documented for engines (Godot, SDL, Unity) that won't link Qt; a C++ wrapper later if a sample needs it |
| C8 | "Priority: core OS infrastructure", start now | `Platform1` is phase 7 and not started; nothing app-facing can work before it | Phase after T-352; the shell-side pieces can be built earlier against the mock (T-353) |

## 1.5 Over-specification (cut or defer)

- Transactions with begin/stage/commit/rollback, a dependency graph, a `Range` type, per-setting preview, three persistence scopes, API negotiation per call: a console overlay over a **frozen** game needs far less. V1 below has staged changes, apply on Resume, and a "restart needed" flag.
- 13 documentation deliverables and an "AI-readable guide": ADR-022 already requires a chapter, sample, mock and conformance test per public element, and ADR-031 already generates `llms.txt`. One chapter, `docs/developers/game-settings.md`, plus the sample covers it.
- §2, §23 (inspect the repo, follow conventions, no TODOs): already the repository's `CLAUDE.md`; drop from a product proposal.
- "Native application" outside Flatpak: third-party apps are Flatpaks only (ADR-005, security invariant); there is no other kind.

## 1.6 Smaller corrections

- §5.2 lists "game render resolution" and "internal frame limit" as examples. Correct (game-owned), but the overlay should not suggest that Ruya can change them for a game that did not register them (§11.3 says so; keep it).
- §13: "Master volume" as game-owned is confusing next to the system volume; call it "game master volume" or leave it to the game's own list.
- §14.4 "a game must not forge user confirmation": already true, since the compositor routes input and the Hub takes the pad (ADR-024 routing; Guide always to the shell). Keep it as an invariant, not as work.
- §15.2 a Proton bridge: agree it is separate and later; note it would be a Wine-side D-Bus shim talking to `Platform1`, with the same permission table.

---

# Part 2: Refined proposal

**Status:** game settings Accepted (ADR-035, owner 2026-11-12); "show a system page" Proposed. **Phase:** 3: the schema and the Hub panel against a mock first, the delivery to real games after `Platform1` (T-352). **Owner of the design:** the lead.

## 2.1 Goal

A game that wants to can hand its settings to the console: in the Ruya Hub, over the paused game, the player sees **Game settings** with the game's own options as normal Ruya rows (toggles, choices, sliders, actions), reads them at 10 ft with any controller, changes them, and goes back to the game, which applies them. A game that does nothing still gets the whole Hub, as today. Separately, an app can ask the console to show a few trusted system surfaces (the storage picker, a system settings page) instead of drawing its own.

## 2.2 Principles (kept from the input, trimmed)

1. **The shell draws everything trusted.** Apps send typed data; never markup, QML, HTML, images in trusted dialogs (an icon is a named Material Symbol at most).
2. **Owners stay owners.** The OS owns display, audio devices, system volume, controllers and accessibility; the game owns its settings, their meaning, their storage and their application.
3. **No app writes a system setting** (ADR-022 "never public"). An app may ask for a system page to be shown; the player decides there.
4. **Nothing needs the game.** The Hub and every system panel work for a frozen, hung, Proton or SDK-less game (true today).
5. **One door.** Everything app-facing is an interface on `org.ruyaos.Platform1`, identified by Flatpak app id and profile, rate-limited, per-app permission in Settings > Privacy.

## 2.3 Game settings (V1)

**Declaration: a data file, not a runtime registration.** The game ships `/app/share/ruya/settings.json` in its Flatpak (tier C, data only): a versioned schema validated by `ruya app validate` (ADR-031) at build time and by the shell when the game starts. No runtime registration means no registration flood, no oversized-schema-at-runtime class of bugs, and a schema the Store can show before install.

**Values and changes: a small tier-B interface**, `org.ruyaos.Platform1.GameSettings` (names illustrative; contract first, XML before code):

| Element | Direction | Meaning |
|---|---|---|
| `PublishValues(a{sv} values)` | game → OS | Current values, sent at start and whenever the game changes one itself. The shell keeps them in memory only |
| `SetAvailable(as ids, b available, s reason)` | game → OS | Grey out a row ("Needs ray tracing hardware") |
| `ChangesRequested(a{sv} changes)` | OS → game, signal | Sent **once, on thaw** (Resume), with every staged change; never while frozen |
| `ChangesResult(a{sv} applied, a(ss) refused)` | game → OS | What the game took; refused ids with a reason the Hub shows as a toast |
| `ActionRequested(s id)` | OS → game, signal | An action row ("Reset to defaults", "Recalibrate"), delivered on thaw like changes |

**Types in V1:** `bool` (toggle row), `enum` (choice row), `int` and `float` with min, max, step and unit (slider row), `action` (button row), `info` (read-only row). Every one is an existing 04 component (`ToggleRow`, `ChoiceRow`, `SliderRow`), so no new component. `range` and free text are out of V1.

**Per setting:** `id`, `label` and `description` (localised: the file carries `{ "en": ..., "tr": ... }`, the shell picks the profile's language, falling back to `en`), `type`, `default`, constraints, `options` for enums, optional `category`, optional `visibleWhen` (**one** condition: another setting's id equals a value; no expressions, no scripts), optional `restart: true` (the Hub says "Applies after a restart of the game").

**Categories:** a fixed set the Hub orders and names (Graphics, Display, Controls, Audio, Gameplay, Interface, Accessibility, Advanced); a game may not invent new ones in V1, so the Hub never shows a game's own heading text.

**Flow:**
1. Guide → the Hub opens, the game freezes (unchanged).
2. If the game ships a schema and has published values since it started, the Hub's game card offers **Game settings** (a panel, 02 §1.6 pattern). If it never published, the entry is absent, not greyed.
3. The panel shows the categories, then rows with the published values. Changes are staged in the shell and marked as changed.
4. Back leaves the panel and keeps the staged changes; Resume thaws the game and sends `ChangesRequested` once.
5. The game applies what it can and answers `ChangesResult` within 5 s; refused ids toast with the game's reason (≤ 60 characters). No answer: a toast "<Game> did not confirm the changes" and the published values stay authoritative.
6. **Close game** with staged changes drops them (the game is not thawed to receive them).

**Validation on the OS side:** the shell checks every staged value against the schema before sending; `ruya-platform` checks the schema size (64 KiB), the number of settings (200), id format, and rate-limits `PublishValues` (10 per second). The game must validate again: the schema is a hint, not a guarantee.

**Persistence:** none in the OS. The game stores its values in its own `config/` (tier C, `saves-and-data.md`), so backups (T-215) carry them and a schema update cannot overwrite them.

**Hub "Pause games" off** (the Settings switch for online games): the game is not frozen, but V1 still stages and sends on Resume, so one code path. Live apply is a V2 question.

## 2.4 App-requested system surfaces

| Surface | V1? | Why |
|---|---|---|
| **Storage picker** (open file, open folder, save) | yes, already approved | A portal-style call (`xdg-desktop-portal` FileChooser backend rendered by the shell, 03 §4.4); returns a document-portal handle, never a raw path outside the sandbox |
| **Show a system page** (Audio output, Controllers, Display & motion, Accessibility) | yes, **new tier-B line** | The app asks; the shell opens that Hub panel or Settings pane over the app; the result is only "closed". No write, no read beyond tier-B display information |
| **Device picker** (choose an audio output, a controller) | **no**: covered by "show a system page" | The choice is a system setting (ADR-022) |
| **Confirmation dialog** | **no** | It needs no trust: apps draw it with RuyaKit's dialog component (ADR-015), which looks the same. A system-drawn confirm adds an API without a security gain |
| **Permission prompt** | not an app call | `ruya-platform` raises it itself the first time an app uses a capability that needs it (T-220); an app never draws or triggers it directly |

## 2.5 Security (what is new)

- Identity comes from `Platform1`'s caller mapping (T-352 step one), never from a parameter.
- Game settings need no permission (they only affect the game itself), but `Platform1` drops `PublishValues` from an app that is not the one in front of the Hub's game card.
- Labels are plain text, length-capped (label 40, description 160, reason 60), stripped of control and bidi override characters; the Hub never renders rich text from an app.
- Abuse tests (ADR-022 conformance): an oversized schema, a cyclic `visibleWhen`, a value outside its range, a flood of `PublishValues`, a `ChangesResult` for ids never sent, another app's id.

## 2.6 Order of work

| Step | What | Depends on | Surface |
|---|---|---|---|
| 0 | Owner: the two tier-B lines (D1), the frozen-game rule (D2) | none | none |
| 1 | Lead: ADR-035 and a `08-game-settings.md` spec section; schema file `api/settings/game-settings.schema.json` | D1, D2 | public-format |
| 2 | Shell: the Game settings panel against a **mock** game (schema file + fake values), rows from 04 only | step 1 | none |
| 3 | `Platform1.GameSettings` XML, `ruya-platform` half, mock for developers, conformance tests | T-352, T-353 | public-API |
| 4 | Sample game (the SuperTuxKart-style sample or the T-252 template) and `docs/developers/game-settings.md` | step 3 | public-API |
| 5 | "Show a system page" call | T-352 | public-API |
| 6 | Storage picker portal backend | T-352 (identity), the 03 §4.4 spike | public-API |
| later | Live apply while unpaused; a Wine-side bridge for Proton games; HDR, VRR, power profiles as their own OS features | V1 used by a real game | n/a |

Step 2 can start before `Platform1` exists and is the first visible result.

## 2.7 Done when (V1)

- A sample Flatpak game with a schema shows Game settings in the Hub; a changed toggle, choice and slider reach the game once on Resume, and the game's refusal shows as a toast (VM check plus a Dell run).
- A game without a schema shows no entry, and the Hub is unchanged for it.
- Close game drops staged changes; a game that never answers leaves its published values on screen.
- The abuse tests of 2.5 pass; the chapter, sample and mock exist and `lint-dev-docs.ps1` runs the sample.
- An app can open Settings > Audio over itself and gets "closed" back, and cannot change a setting through `Platform1`.

---

# Part 3: Decisions (owner, 2026-11-12; recorded as ADR-035)

- **D1a, game settings: approved** ("the game settings can be shown in the Ruya Hub"; "file them"). The entry is a **Game** icon, first in the Hub's panel icon row, shown only for a game with settings (owner chose it over a new box and over a game-card button).
- **D1b, show a system page: still open** (not asked separately; stays Proposed in ADR-035).
- **D2, changes reach the game on Resume: approved** (no live preview in V1).
- **D3, timing: build it, and move `Platform1` forward** (owner: "would it not be wise to implement it?"). Tickets: RUY-406 (schema, loader, mock game), RUY-407 (the Hub Game panel against the mock), RUY-408 (`Platform1.GameSettings`, after RUY-157 and RUY-158); T-351, T-352, T-353 (RUY-156..158) moved from phase 7 to phase 3.
- Not added to the tier-B list: app-requested confirmation and device-picker dialogs.
