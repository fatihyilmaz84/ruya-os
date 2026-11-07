# T-281 — Cards glow in the colour of their art (Hue-style shadow), and one standard set of card sizes

Status: todo · Phase: 2 · Depends: — · Area: shell · Size: M · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host (hw pending: Dell frame times)`._
