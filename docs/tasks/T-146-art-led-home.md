# T-146 — Art-led Home: hero, Recent art row, section nav

Status: done · Phase: 5 · Depends: T-113, T-143 · Area: shell · Size: M

## Goal
Home looks and works like a game console: the focused game's key art fills the screen, its title and a Play button sit over it, recent games run along the bottom as art cards, and the sections (Home, Games, Media, Store, Settings) live in a glass bar at the top. Owner decision 2026-10-28 (ADR-012 amendment).

## Read first
- `docs/specs/04-design-system.md` §1, §2 (Home anatomy), §3.1 (primary, scrims), §3.6 (glass and blur), §4, §5 (Hero block, Art card, Buttons, Section nav), §8
- `docs/specs/02-shell.md` §1 (Home row), §1.1 (page model, focus restoration), §3 (blur pattern)
- `shell/qml/Shell.qml` (home, shelf, `tiles`, `routeFocus`), `shell/qml/Backdrop.qml`, `shell/qml/ArtCard.qml` and the `Library` singleton (T-113)

## Scope
1. **Tokens** (in the same commit, per `04` §8): `primaryFill`, `onPrimary`, `heroScrim`, `artCaptionFade`, `glassStrong`; mark them built in `04`.
2. **Components:** `HeroBlock.qml`, `PrimaryButton.qml`, `SecondaryButton.qml`, `SectionNav.qml` as specified in `04` §5.
3. **Home layout** (`04` §2): L0 = hero art of the focused Recent item (art from the Library mock's art fallback until the art pipeline exists; cross-fade over `tintMs`), `heroScrim` and bottom fade; top bar (section nav left, controller/clock/profile right) on `glassStrong` sampling the shared blurred backdrop (`blurMax` by tier, `glassOpaque` at 0); hero block; Recent row of `ArtCard`s (`Library.recent`).
4. **Focus and keys:** focus starts on Play. Down → Recent row, Up → hero, Up from the hero → section nav. Moving along Recent changes the hero. LB/RB switch sections from anywhere on Home (opening the section's page as the tiles do today); Accept on a nav pill opens it. Play and Accept on a card → `Library.launch(id)` (the launch flow itself is T-147). Details → placeholder page ("Coming soon"). Back on Home does nothing. Focus restoration on page close returns to the item that opened it (nav pill, Play or card).
5. **Remove** the five home tiles (`Tile.qml` stays for now; delete only if unused). Power stays reachable from the Guide overlay; Settings via the nav icon.
6. **Empty library:** the hero shows "Your library is empty" with a primary "Open Store".

## Out of scope
- Launching, splash, Running state from `Session` (T-147); the art pipeline and real art (02-shell §6); Cover cards and the Library grid; hint bar (proposed).

## Acceptance criteria
- [ ] `tst_home.qml`: focus starts on Play; Down/Up/LB/RB move as in Scope 4, with `activeFocus` asserted after each step; moving along Recent updates the hero title.
- [ ] Opening Games with RB then Back returns focus to where it was (nav or card) (test).
- [ ] Play emits `Library.launchRequested` for the hero's item (test).
- [ ] Empty library shows the empty hero and its button opens the Store (test).
- [ ] Performance tier (`--effects performance`): no `MultiEffect` visible, top bar uses `glassOpaque`, layout identical (test asserts properties; screenshot).
- [ ] Screenshots `01-home.png` (High), `01-home-performance.png`, `01-home-empty.png`, Turkish home, reviewed against `04` §8 and the canvas board "Home (art-led)".
- [ ] `dev.ps1 test` ALL GREEN; every existing home/page test that used the tiles updated to the new navigation (say which in the Outcome; no assertion weakened).

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `04-design-system.md` §2, §3.1, §5 statuses; `02-shell.md` §1 Home row and §1.1 (tiles → section nav); `shell/PATTERNS.md` "How to add a page" (pages open from the section nav).

## Hints
- `Shell.tiles` and `tileTitle` are the keys-only model pattern: keep it for the nav (`04` translations rule: models hold keys).
- The blur pattern is `02-shell` §3.1: one quarter-resolution `ShaderEffectSource` of the backdrop, shared by the top bar and any glass.

## Outcome
Verified: host (offscreen `dev.ps1 test` ALL GREEN, 241 QML tests). **Screenshots unverified:** `dev.ps1 shots` refused to run (the Windows session was locked), so `01-home.png`, `01-home-recent.png`, `01-home-performance.png`, `01-home-empty.png` and `01-home-tr.png` are written (`tst_home.qml`) but were never rendered or reviewed against `04` §8. The blur, mask and layout on a real GPU are unchecked; re-run `shots` first thing in the next session.

Built: tokens `primaryFill`, `onPrimary`, `heroScrim`, `artCaptionFade` (also used by `ArtCard`) and `glassStrong`; `PrimaryButton`, `SecondaryButton`, `HeroBlock`, `SectionNav` and `GlassPill` (the glass behind the nav and the status cluster); `LibraryDetailsPage` ("Coming soon", key `details`). Home in `Shell.qml`: hero art of `Library.recent`'s current item in a new `l0` layer with the backdrop (two `AppArt` layers cross-fading over `tintMs`, left scrim, bottom fade), top bar (nav left, profile and clock right on glass), hero block, Recent row of `ArtCard`s. The five tiles and `tileTitle` are gone; `Tile.qml` stays unused. Focus: starts on Play; Down/Up as specified; PageUp/PageDown step the sections (from the focused nav pill, else from Home); `homeSavedFocus` restores the item that had focus after a page, Details or the Guide overlay. Empty library: "Your library is empty" with Open Store. Translations (tr) added; `Tile` section strings moved to `SectionNav`.

Tests: new `tst_home.qml` (13 tests: focus start, arrows, hero follows Recent, Play/Accept launch, RB/LB with focus restore, nav Accept, Details, Back, overlay restore, empty, Performance tier keeps the layout). Existing tests moved off the tiles, assertions kept: every `find("tiles").activeFocus` is `find("homePlay").activeFocus`; opening Settings/Store/Games is Up, Right x n, Accept on the nav (tst_audio, network, update, profile_admin, settings, store_ui, games, i18n, motion, pages); "Back returns to the tile (`currentIndex`)" is now "the nav has focus on the same `currentKey`" (pages, settings, i18n RTL); `shelfBlur` is `glassBlur`; the header `brand` x test uses `sectionNav` x (the brand text is gone); the two "key swallowed by the overlay" checks assert Details did not get focus; the tile-pulse check builds a stand-alone `Tile`; Power is not in the nav, so `tst_power` and `tst_pages` call `Shell.openPage("power")`.

Deviations: Left/Right are mirror-aware in `SectionNav` and `HeroBlock`. Each `GlassPill` blurs its own quarter-resolution crop of L0 (through a rounded mask) rather than sharing one texture. The Settings pill is a gear glyph (U+2699), the status cluster has no controller battery yet, no hint bar. LB/RB from content open the section after Home (Games), from the nav the one after the focused pill; LB at Home does nothing. `Theme.hairline` (named in `04` §3.3) does not exist in `Theme.qml`; the buttons use `Math.max(1, u)` like the rest.
