# T-281 — Cards glow in the colour of their art (Hue-style shadow), and one standard set of card sizes

Status: in-progress · Phase: 2 · Depends: — · Area: shell · Size: M · Owner: builder

## Goal
Game and app cards cast a soft shadow in the dominant colours of their own picture, like a Philips Hue sync box lighting the wall behind a TV: a red game glows red, a blue one blue, and the glow follows the focused card smoothly. And every kind of card uses one small, documented set of sizes and proportions instead of ad-hoc numbers. Owner request, 2026-11-07: "give the game/app cards a hue shadow ... the shadow color based on the card's colours ... changes based on the image ... also standardize the card sizes etc".

## Read first
- `docs/specs/04-design-system.md` §3.8 (shadows `shadowLift`, glare, card focus), §4 (cards, focus ring, scale 1.08), §5 (Art card, App art, Profile card, Store cards), §7 (contrast), §8; Theme sizes (`tileWidth` 400 × `tileHeight` 260, `avatarSize`), the `Theme.tileAccent(key)` / `defaultTint` logic and Backdrop (`blobTintA`, T-271)
- `shell/qml/ArtCard.qml`, `AppArt.qml`, `CardFocusLayers.qml`, `GlassShadow.qml`, `ProfileCard.qml`; where cards are used: `GamesPage.qml`, `Shell.qml` (Home Recent row), the Store rows and app detail page, Library
- T-204 (shadow tokens, per-frame blur is out: "bake, don't redraw"), T-205 (frame-time budget), `shell/CLAUDE.md` (offscreen has no `MultiEffect`; assert properties)

## Scope
1. **Art colour:** derive one or two representative colours per card picture once, when the image first loads (downscale to a tiny sample, average with saturation weighting, clamp lightness and chroma so a white or grey picture gives a neutral glow and a very dark one a faint one). Cache per art id; no per-frame work; the fallback for a card without a picture is its tile accent. Put the sampler in one place (C++ helper or a tiny offscreen `ShaderEffectSource` read-back decided in the Outcome with the cost measured) and reuse it for the Home hero and the Backdrop tint if that is a one-line change (otherwise Inbox).
2. **Hue shadow:** the focused card's lift shadow (`shadowLift`) is tinted with that colour at a themed strength (a new theme token only if needed, `04` §8), plus a wider, softer second halo behind it on the High tier (none on Performance); unfocused cards keep the neutral shadow or a very faint tint. The colour cross-fades over `tintMs` when focus moves, 0 under reduced motion. Daylight (light theme): the glow must read on a pale ground (the shadow colour darkens or multiplies, check in a screenshot).
3. **Standard sizes:** define the card family in `Theme` and 04 §5: art card (16:9 key art) in three sizes (hero row, shelf, compact), the square app icon card, the profile card, with corner radius `radiusM`, caption height and the gap between cards all derived from tokens; replace the ad-hoc numbers in `GamesPage`, Home, Store and Library rows with those sizes, keep the focus scale and ring rules. Document the table (size, aspect, where used) in 04.
4. Screenshots of Games, Home and Store show the glow on cards with red, blue, green, white and dark art in Dreamglass and Daylight.

## Out of scope
- Live ambient lighting from the running video or game (a different feature), per-profile glow settings, hardware lights (Hue bridge, LED strips).

## Acceptance criteria
- [ ] Tests (properties, not pixels): the sampler returns the expected colour family for fixture images (red, blue, green, white, black, a two-colour image) and is bounded in lightness/chroma; the shadow colour of the focused card equals the sampled colour and cross-fades to the next card's on focus move; no tint under reduced motion transitions; the Performance tier draws no halo; every card kind uses the documented size tokens (a test reads the token for each).
- [ ] Frame cost: the sampler runs once per picture and the glow adds no per-frame work (state the measurement; on the Dell the lead checks the T-205 frame times).
- [ ] Screenshots (`shots`) read against 04 §7/§8 in Dreamglass and Daylight; UX: focus ring, scale and legibility of captions unchanged; Outcome has a `UX notes:` line.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- 04 §3.8 (hue shadow), §5 (card sizes table, App art/Art card rows), token notes.

## Outcome
Verified: host (hw pending: Dell frame times)

UX notes: states reached: a card at rest (no shadow, as before), a focused card (ring, 1.08 scale, sheen and glare unchanged, now a lift shadow in the colour of its picture and, on High, a wider halo), a card whose picture is still loading or missing (the glow is its placeholder hue), and the same on Games, Home's Recent row and the Store rows, in Dreamglass and Daylight (`output\shell-shots\art-glow-*.png`, reviewed: gallery, Home red/blue, Games, Store). Back and focus are untouched: the pages, their keys and `Sfx` are as before, and `test_focus_moves_the_glow_with_the_selection` asserts the Recent row keeps `activeFocus` while the glow moves from one card to the next. Captions keep `Theme.text` on the unchanged caption fade. Doubts: the strengths (`glowShare` 0.9, halo alpha 0.45, Daylight boost x2) were set by eye on a 1080p capture and not on a TV; the halo is faint on the dark themes (it reads as haze above and beside the card); on Home a red card over the red hero shows the glow less than on the other pages because the hero art already floods the screen in the same colour.

### What was built
- **Sampler (`shell/src/art/ArtPalette.{h,cpp}`, C++ singleton).** Decided against a `ShaderEffectSource` read-back: it would need a GPU frame, a visible item and a stall, and would not work offscreen; a worker-thread decode needs none of that. `colorsOf(source)` returns `{ color, secondary, strength, neutral }` from a cache or an empty map, and starts a `QThreadPool` job (path, `file:`, `qrc:`, or `http(s)` through the engine's network manager, 8 MB cap); `sampled(source)` follows. The job decodes (JPEG is decoded at reduced size), shrinks to at most 32 x 32, buckets by hue (12) weighted saturation squared x value, takes the primary and (at least 90 degrees away, 30 % of the score) the secondary hue, conditions both (lightness 0.40-0.60, saturation 0.35-0.90) and sets a strength 0.2-1 (brightness and colourfulness; a neutral grey, from a white, grey or black picture, is capped at 0.6). Cache of 256 pictures, one analysis per source. Measured on the 160 x 90 fixtures: 28-65 microseconds for the analysis itself (`lastAnalyseUs`, decode excluded), run once per picture off the GUI thread; the GUI thread only does a hash lookup (`colorsOf`) and receives one queued signal per picture.
- **Hue shadow.** `AppArt` (`glowing`, `sample`, `glowColor`, `glowStrength`); `GlassShadow` (`glow`, `glowStrength`, `halo`, `glowMix`, `tint`, `haloShown`); `Theme` (`glowShare`, `glowDarken`, `glowBoost`, `haloOn`, `glowHalo`, `glowFallback`, `glowFallbackStrength`, `glowShadow()`). No theme-set token was added: the Daylight behaviour follows the existing `lightness` token (art colour darkened, shadow alpha x2). `ArtCard` and the Store card turn it on. Frame cost: nothing runs per frame; the colour change is a `Behavior` (a number and a colour animation over `tintMs`) on the focused card only; the halo is one more `MultiEffect` of the same cached texture and exists only while a card is focused on High. The Dell frame times are for the lead (T-205 budget).
- **Card family (`Theme`, 04 section 5.2).** `cardWidthHero` 400 (Games), `cardWidthShelf` 320 (Home Recent, `ArtCard` default), `cardWidthCompact` 288 (Store), `cardIconSize` 160, `cardProfileWidth` 260 x `cardProfileHeight` 320, `cardGap` = `spaceM`, `cardCaptionHeight` 72, `cardArtHeight(width)`. Games, Home, Store and the profile card use them.
- **Test support.** `tst_main.cpp` writes the colour fixtures (red, blue, green, white, dark, grey, pastel, darkred, redblue) into a temporary directory (`artFixtures`), so no binary is committed; the mock library (`resetMockForTests("art:<dir>")`) and the mock store (`Store.mockArtDir(dir)`) give their items those pictures (`src/art/MockArt.h`) for the screenshots.

### Tests (`shell/tests/tst_artglow.qml`, 24 + 2 shots)
Sampler families and bounds, neutral and faint cases, two-colour picture, once per picture (analysed counter and microseconds), unreadable picture, the card's glow and fallback, the focused shadow's tint equals the sampled colour, cross-fade to the next card (mid-fade `glowMix < 1`, then the new colour, the old back to neutral), no fade under reduced motion, halo per tier, Daylight, every card kind's tokens and sizes on the real pages (Home, Games, Store, profile picker), focus kept while the glow moves.

Revert checks (`scripts\revert-check.ps1`, each CAUGHT): A `ArtCard` hands `Theme.shadowColor` to the shadow instead of the art colour; B `GlassShadow` halo without the `Theme.haloOn` tier test; C `GamesPage.cardWidth` 360 instead of the token; D `ArtPalette` without the lightness clamp; E `ArtPalette` decodes on every ask (`test_each_picture_is_analysed_once`); F `GlassShadow` `glowMix` with a 0 ms animation (no cross-fade).

### Deviations
- The task says a card without a picture falls back to "its tile accent". The tile accents belong to the Home section tiles; a card has no section key, and a glow in the accent colour would not match the visible placeholder. The fallback is the placeholder's own hue (`Theme.glowFallback(hue)`, strength 0.7).
- The Games grid fills with as many 400-wide columns as fit (4 at 1080p) instead of a fixed 4 columns that stretch the cards; the Store card is 288 x (162 + 72) instead of 300 x 290 (the art is now 16:9 instead of 300 x 190); Home's Recent row gap is `cardGap` (24) instead of `spaceL` (36).
- `AppArt` turns a Windows drive path (`C:/...`) into a `file:///` URL like a `/...` path (needed for the screenshot pictures; no effect on Linux).
- `Qt6::Network` is now a link dependency (the sampler's http(s) path; Fedora's `qt6-qtbase-devel` has it, and Qt Qml needs it at run time anyway).
- Home hero and Backdrop tint do not read the palette yet (the task allowed an Inbox line if it was not a one-line change: the hero's two `ArtLayer`s and the backdrop's profile tint each need their own design).

### Not verified
- The Dell frame times and the look on a TV (shots are 1280 x 720 windows scaled to 1920 x 1080).
- The http(s) branch of the sampler (no server in the tests; the file branch is tested).
- **`shots` is red in one test**: `Wallpaper::test_zz_screenshots` (`tst_wallpaper.qml`, "captured once, not per frame": `wallpaperPanel.bakeCount` is 2, expected 1). The other 136 screenshot tests pass, `test` is ALL GREEN, and the same test passes on `main`'s build (run twice, isolated, with a real window). On this branch it fails every time (full run, twice; isolated, five times). What I found: the sheet's height changes once after it is shown (605 to 453 design px at the test size, `GlassSheet` re-captures on a size change), and it is not the Home row (`Shell.qml` reverted: still red) and not the user copies arriving late (a `tryVerify` on `Wallpapers.user.length === 5` before opening changed nothing; reverted). I could not find which part of this diff changes the order of events there. It needs a look by someone who can bisect on a fresh build: `git stash` the pieces of the diff one at a time and run `tst_ruyashell.exe -input tests\tst_wallpaper.qml` with `RUYA_SHOTS_DIR` set and `QSG_RENDER_LOOP=basic` (50 s).

### Files
`shell/src/art/{ArtPalette.h,ArtPalette.cpp,MockArt.h}`, `shell/CMakeLists.txt`, `shell/qml/{AppArt,ArtCard,GlassShadow,Theme,GamesPage,StorePage,Shell,ProfileCard}.qml`, `shell/src/library/{Library.h,MockLibraryBackend.h,MockLibraryBackend.cpp}`, `shell/src/store/{Store.h,Store.cpp,MockStoreBackend.h,MockStoreBackend.cpp}`, `shell/tests/{tst_main.cpp,tst_artglow.qml}`, `docs/specs/{04-design-system.md,02-shell.md}`.
