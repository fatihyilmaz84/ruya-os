# T-282 — Design decisions queue: glass text contrast, theme looks, dialogs, Tab, display recovery

Status: todo · Phase: 2 · Depends: — · Area: docs (04 design system, 02 shell) · Size: M · Owner: lead

## Goal
Every open design question that review rounds of T-190..T-272 left behind has a written decision in `04-design-system.md` or `02-shell.md`, so the builder tasks T-283, T-284, T-285 and T-288 can implement instead of guess. Owner **lead** because each decision needs screenshots and taste, and the owner's veto comes on the Dell (STATUS, Dell look-at list). No product code.

## Read first
- `docs/specs/04-design-system.md` §3.5 (glass layers), §3.8, §5 (components), §7 (contrast gate), §8; `02-shell.md` §4.2 (keys)
- `shell/tests/tst_theme_contrast.qml`, `shell/qml/Theme.qml`, `shell/qml/themes/`
- The full text of the source lines: `docs/STATUS-parked.md`, section "Inbox triage 2026-11-07", bullets T-282

## Scope
Decide each of these, write the decision (with the measured figure or screenshot name) into the spec as "Decided (lead, date)", and name the task that implements it:
1. **`glassTint` and white text** (T-204): 44 % tint gives 2.5:1 over pure-white art, 04 §7 wants 4.5:1. Options: stronger tint (~60 %) where text sits, a lightness cap on hero art, a dark text variant. Recommendation: stronger tint on sheets plus a lightness cap on hero art; keep art-led Home.
2. **Dark themes over bright wallpaper or hero art** (T-209): glass text 0.9:1 over white (T-208's dim rule covers wallpapers only). Recommendation: extend the dim rule to hero art, and fall back to `glassOpaque` below the floor.
3. **Avatar palette vs themes**: initials on orange/cyan/green avatars 2.2-2.9:1; blob overlap on bright tints gives glass text 2.5-2.8:1. Recommendation: an `avatarInitial` token chosen by luminance.
4. **Theme looks** (T-271): Home looks alike across themes (hero art dominates): a theme-tinted hero scrim (04 §3.5)?; Dreamglass takes the profile tint fully so a red profile resembles Ember (`blobTintShare` below 1 for Dreamglass?); Midnight's blobs are visible grey discs and its tile accents bluish/reddish greys; Dreamglass/Midnight is the closest pair (88.7 vs the 80 floor). Decide with five-theme screenshots.
5. **High-contrast as a sixth theme**, one shared `FocusRing` with a 2 px halo (T-209). Recommendation: High-contrast yes (its shot is a deferred criterion), halo yes if frame times allow (Dell).
6. **Liquid pill** (T-205): should it match the plain High pill's brightness exactly (`liquidBrightnessLift`)? `Theme.liquidPill` default waits for Dell frame times: write the rule ("on if the 30 s idle pause and frame times hold"), not the value.
7. **Dialog cards**: PowerConfirm, ModeConfirm, ThermalNotice, the uninstall dialog and ControllerOnboarding are flat `panel` while pickers are glass (T-272). Recommendation: glass over a scrim, one component (implemented by T-284).
8. **Tab key** on non-pane row lists (T-190 dropped `activeFocusOnTab`): Tab = Down there, or record Tab as unmapped in 02 §4.2. Recommendation: unmapped (controller-first).
9. **Recovery from a confirmed display mode the screen cannot show** (T-198; a different TV later): recommendation: kernel argument `ruya.display_reset=1` from the boot menu entry (T-269) that the display guard honours once. Write the contract line; the build goes into T-287.
10. **Copy rule for percentages**: "5%" vs "150 %" (en `150%`, tr `%150`); one rule in 04 §5.
11. **04 §7 wording**: the general 4.5:1 bullet contradicts the large-text exceptions; peek rows over a wallpaper are unmeasured; `tst_theme_contrast`'s peek model assumes group opacity (Daylight slightly optimistic); Store/Games peek still open. Reword and state which rows the gate must have (T-283).

## Out of scope
- Any change to QML or C++ (the builder tasks do that). Brand art and logos (owner decisions). A new theme's palette beyond what item 5 needs.

## Acceptance criteria
- [ ] Each of items 1-11 has a "Decided (lead, <date>)" line in 04 or 02 (grep for the item's keyword shows it), with a figure or a screenshot name where it concerns colour.
- [ ] For every decision that needs code, the implementing task's Scope (T-283, T-284, T-285, T-287, T-288) says so, or a new task exists with a board row (`scripts/lint-board.ps1` exits 0).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN (docs lint only).

## Verification
```powershell
.\scripts\dev.ps1 test
powershell -File scripts\lint-board.ps1
```

## Docs to update
- `04-design-system.md` (§3.5, §5, §7), `02-shell.md` §4.2, STATUS Dell look-at list (owner's veto items).

## Hints
- Measure with `ThemeMath` and `tst_theme_contrast.qml` figures, not by eye. Five themes: Dreamglass, Midnight, Aurora, Ember, Daylight (plus Performance tier).
- Items 7 and 8 are quick; 1-4 need screenshots of `dev.ps1 shots` (themes board).

- (owner question 2026-11-09; added lead-7) **Card styles.** The owner sees three card types (Home, Store, Games). By design (04 5.2, T-281) one family in three sizes (Games hero 400x225, Home shelf 320x180, Store compact 288x162), same radius, ring, glare and glow; the visible difference is the caption (over the art on Home/Games, below it in the Store). Run `ruya-design-reviewer` + `ruya-ux-reviewer` on screenshots of the three pages, decide whether the Store caption and the three sizes stay or unify, answer the owner. Also: a drive with six scan categories adds seven Storage rows; a collapsed "Show details" needs a component (T-364 left it out).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
