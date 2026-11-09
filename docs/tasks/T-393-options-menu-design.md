# T-393 - Design: the Options (context) menu: component, contents per surface, motion, focus

Status: todo · Phase: 3 · Depends: — · Area: docs (04, 02), design · Size: S · Owner: lead · Complexity: complex · Developer surface: none

## Goal
A carefully designed Options menu exists on paper before anyone builds it: what it looks like, how it opens and closes, and exactly which actions each surface offers. Owner request 2026-11-09: "in the games section we can only start games; there is no context menu for removing, stats, etc. The context menu should be carefully designed."

## Read first
- `docs/specs/02-shell.md` §4.2, §4.3 (Menu/Options button and long-press A already open "the context menu": never built), §1 surfaces; `docs/specs/04-design-system.md` §3 (type, glass), §5 (components; GlassSheet, Toast, the confirm dialogs), §8; `06-input-requirements.md` (semantic actions)
- What each action needs: Store1 `Uninstall(delete_data)` (admin), the play ledger (T-247, `ActivityPage`), T-385 (Compatibility), T-370 (Controller entry), T-391 (Downloads rows), T-147 (quick menu: a menu over a running game is the quick menu, not this)

## Scope
1. **Component** (`OptionsMenu`, 04 §5 entry, status planned): a glass sheet anchored beside the focused card (falls back to the screen edge), title (item name, `TailText` rule), one column of rows (icon + label, at most 8, a divider before destructive rows, `dangerFill` only on the confirm dialog, not the row), opening/closing motion with existing tokens (or a `design:` decision for one new duration), focus on the first row, Back and the Menu button close it, the hint bar shows A Select / B Close. Long-press A: the progress ring of 02 §4.3.
2. **Contents per surface** (a table in 02): game card in Home / Games / Library (Play or Resume, Details, Activity for this game, Compatibility for Windows games, Controller, Open in Store, Hide from Home, Uninstall...), Store card, an app (non-game), a Downloads row, a running app's card (Close), a controller or Bluetooth device row. Who may do what (Uninstall: admin PIN; a child profile later: T-211).
3. Copy in en (sentence case, no "please"), the Uninstall confirm with a "Also delete saved data" choice and its warning.
4. A canvas board or mock screenshot set for the owner; rewrite T-394/T-395 from the result.

## Acceptance criteria
- [ ] 04 §5 entry and 02 table written; `lint-spec-components.ps1` passes (planned component).
- [ ] T-394/T-395 rewritten with exact rows per surface.
- [ ] `dev.ps1 docs` ALL GREEN.

## Outcome
_Filled in by the implementer._
