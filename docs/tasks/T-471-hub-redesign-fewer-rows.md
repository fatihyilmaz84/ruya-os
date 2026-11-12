# T-471 — Ruya Hub redesign: five focus stops, game art for running apps, fewer options

Status: todo · Phase: 2 · Depends: T-470 · Area: shell · Size: M · Owner: builder · Complexity: complex · Developer surface: none

## Goal
Owner, 2026-11-12: the Hub is "too crowded, too many options"; running games should show their **art, not just names**; and decide what can go. Over a game the Quick Hub has about 18 full-width rows that scroll (status, header, Resume, Home, Close game, one row per running app, two Recent rows, Volume, three tiles, six panel entries, Switch profile): the tiles and every panel entry are below the fold. Layout A was chosen (owner, 2026-11-12): **one screen, no scroll, five focus stops at most**. The Hub is an interruption: get back to the game, leave or switch it, change what matters mid-game. Everything else is one Home press away.

## The design (lead-12, owner-approved layout A)

**Over a game, top to bottom:**
1. **Status row** (not focusable), as now (clock, network, pad batteries).
2. **Game card = Resume.** The header becomes the Resume control: the game's art (`AppArt`, larger than today's header art), title, "Paused · 12 min". Focus lands here on every open; A resumes. There is no separate Resume button.
3. **Home | Close game**: one row of two buttons, Left/Right between them (Close game keeps its current behaviour and closing screen).
4. **Running strip**: one tile per *other* running app, its **art** (`AppArt`, the Library card's crop) with the title under the focused tile only; Left/Right along the strip; A switches to it (today's Switch to). The row is absent when nothing else runs.
5. **Volume** (as now: Left/Right by 5, A mutes; the muted state shows in the row).
6. **Panel icons**: one row of icon buttons, Left/Right between them; the focused one shows its name under it; A opens the panel (the panels themselves are unchanged). In order: **Audio, Controllers, Performance, Power** (Notifications joins when T-245 builds it). Power's panel gets **Switch profile** as its last row.

**Without a game** (Hub over Home): status row, the running strip (if any), Volume, Panel icons. Focus starts on the first of these that exists.

**Removed from the Hub** (owner approved this list, 2026-11-12; the reason in brackets; each stays in Settings or Home):
- **Recent games** (Home is one press away; launching a new game mid-game is rare and the rows pushed the tiles off screen).
- **Wi-Fi and Bluetooth tiles** (turning them off mid-game drops an online session or every Bluetooth pad: a dangerous toggle one press from the game; Settings keeps them).
- **Mute tile** (duplicate: A on Volume mutes). **Mute mic tile** moves into the Audio panel as its Mute microphone row; the status row shows the muted-mic glyph while muted.
- **Display entry** (a mode change restarts the console: never mid-game; Settings > Display keeps it, brightness included).
- **Switch profile row** (into the Power panel).

## Read first
- `02` §1.6 (the Hub as built), `04` §5 (Quick menu, Quick tile, the Hub rows), §3.7 (icons and the subset), §4 (focus), §8 (new components)
- `shell/qml/QuickMenu.qml`, `QuickTile.qml`, `AppArt.qml`, `Icon.qml`, the Hub tests (`tst_hub_*.qml`, `tst_quickmenu*.qml`)

## Scope
1. Rebuild the Quick Hub as above. New components (`04` §8, spec text in the same commit): **Hub game card** (art + title + state, the Resume control), **Running strip** (art tiles), **Hub icon row** (icon buttons with the focused name). Existing tokens only; icons from the Material Symbols set, adding the needed glyphs to `fonts/icons.txt` and the subset (`scripts/subset-icons.sh`, `lint-icons.ps1`).
2. Remove the items listed above from the Hub; move Mute microphone into the Audio panel and Switch profile into the Power panel.
3. Update `02` §1.6 and `04` §5 to describe the built Hub (and remove the tile rules that no longer apply to the Hub; the Quick tile component may stay if Settings or another surface uses it, else mark it retired).
4. Tests: rewrite the Hub tests for the new layout. A test that checked a removed item is deleted **only** with its item and named in the Outcome; behaviour that remains (focus on open, Guide then A resumes, B resumes, Close game, Switch to, Volume, panel open and Back to its icon) keeps a test.

## Out of scope
- New panels, Notifications (T-245), the panels' contents (except the two moved rows), the performance overlay (T-469).

## Acceptance criteria
- [ ] Over a game the Quick Hub has at most five focus stops and never scrolls at 720p and 1080p (a test counts the focusable rows and checks the panel's content fits)
- [ ] Every open focuses the game card; Guide then A resumes; B resumes
- [ ] Running apps show their art in the strip; A switches; the strip is absent with one app
- [ ] The panel icons open Audio, Controllers, Performance and Power; B in a panel returns focus to that icon
- [ ] Recent, the Wi-Fi, Bluetooth and Mute tiles, the Display entry and the Switch profile row are gone from the Hub; Mute microphone is in Audio; Switch profile is in Power
- [ ] Screenshots: the Hub over a game with two other apps running, without a game, a panel open, reviewed against `04` §8
- [ ] `dev.ps1 test` ALL GREEN; `02` §1.6 and `04` §5 describe what is built

## Hints
- Depends on T-470 only to keep one builder lane this week (no file overlap).
- Planned by lead-12 with the owner's choice of layout A.

## Outcome
