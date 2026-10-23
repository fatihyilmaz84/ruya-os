# T-119 — Page host: nested pages that keep their state

Status: done · Phase: 3 · Depends: T-101 · Area: shell · Size: M

## Goal
A page can open a detail page on top of itself (store app → app detail, later game → detail), and Back returns to the page below exactly as it was left: same scroll position, same focused item, same state. This is shared infrastructure; T-111 builds on it.

## Read first
- `docs/specs/02-shell.md` §1.1 (page model as built)
- `shell/qml/Shell.qml` (`pageStack`, `currentPage`, `shownPage`, `openPage`, `closePage`, `focusCurrent`, `pageHost` with its single `Loader`)
- `shell/qml/Page.qml`, `shell/tests/tst_pages.qml`
- `shell/CLAUDE.md` ("How to add a page", "Modals from pages")

## Scope
1. **One live item per stack entry.** Replace the single `Loader` with a `Repeater` (or equivalent) over `pageStack`: every entry has its own page item. Only the top one is visible and enabled; lower ones stay alive but hidden and disabled, so their state is kept. A closed page is destroyed after its fade-out.
2. **`openPage(key, params)`.** Entries are `{key, params}`. A page receives `params` (a plain object) as a property. `currentPage` stays the top entry's key (a string) so existing tests and code keep working; add `currentParams`.
3. **Transition.** The new top page uses the existing fade/slide (`Theme.pageMs`, `Theme.pageSlide`); on pop, the page below comes back the same way. Home stays as it is (hidden while any page is open). Respect reduced motion through the tokens.
4. **Focus.** `focusCurrent()` remains the single authority. After a pop, the page below regains focus on the item that had it before the push (rely on the page being a `FocusScope` that remembers its focus item).
5. **Registration.** Pages are still declared in `pageComponents`. Add `property var extraPages: ({})` on `Shell`, merged into the lookup, so tests (and later modules) can register a page without editing `Shell.qml`.
6. Signing out (`Profiles.lock()`) clears the whole stack and destroys every page item.

## Out of scope
- A real detail page (T-111 adds `AppDetailPage`).
- Animations between two non-home pages beyond reusing the existing one.
- Deep links or a back-stack UI.

## Acceptance criteria
- [ ] Open Settings, move to the "About" category and into its pane (down two rows), push a test page registered through `extraPages`, pop it: the Settings page is the same item, the category is still About, and the same row has focus (test `tst_pages.qml::test_nested_page_keeps_state`).
- [ ] Back from a nested page returns to the page below, not to home; Back again returns to home with the originating tile focused (test `test_back_walks_the_stack`).
- [ ] While a nested page is open, the lower page receives no keys (`enabled` false) and is not visible; the Guide overlay still opens over the nested page and Back from the overlay returns focus to it (test `test_overlay_over_nested_page`).
- [ ] `params` reach the page and `currentParams` reflects the top entry (test).
- [ ] Switching profile with two pages open leaves no page items behind (test checks `pageHost` has no page children after sign-out).
- [ ] All existing `tst_pages.qml` tests pass unmodified.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/02-shell.md` §1.1; `shell/CLAUDE.md` "How to add a page" (nested pages, `params`, `extraPages`).

## Hints
- Today the single `Loader`'s `onLoaded` hands every page its `objectName` (`"page_" + key`), `u`, `version`, `overlay` (the shell's `modalLayer`), `marginX` and `marginY`. Each stack entry needs the same wiring (for example in the delegate's `Component.onCompleted` with bindings); keep the `page_<key>` object names, tests rely on them (`find("page_settings")`).
- Setup (T-106) is not a page: `signedIn` is false while it shows, so `openPage` is already a no-op then.
- UI rules since T-117: the token lint fails on literal colours/durations in QML; use `Theme` tokens.
- Keep `pageStack` a plain array of objects and reassign it (QML change notification).
- The old code resets `shownPage` after the fade-out; with one item per entry, destroy the popped item when its opacity animation ends (or when it has been hidden), not before, or the fade-out disappears.
- A test page is a small `Page { … }` component in the test file; give it an `objectName` and one `focus: true` element.

## Outcome
Built:
- `Shell.qml`: the single `Loader` is gone. Each `pageStack` entry (`{key, params}`) has a slot (`pageSlot` component, a `FocusScope` child of `pageHost`) holding its page. Only the top slot is `shown` (visible, enabled, opacity 1, no slide); others fade out and stay alive. A popped slot (`closing`) destroys itself when its opacity reaches 0. `openPage(key, params)`, `currentParams`, `extraPages` (merged with `builtinPages` into `pageComponents`), `dropAllPages()` on sign-out. Page items keep the `page_<key>` object names; slots are `pageSlot_<key>`.
- `Page.qml`: `params` property.
- Focus: `focusCurrent()` calls the top slot's `restoreFocus()`. Because disabling a slot drops its active focus, the slot below notes `Window.activeFocusItem` in `rememberFocus()` on push and refocuses it on pop (falls back to the page).
- Tests in `tst_pages.qml`: `test_nested_page_keeps_state`, `test_back_walks_the_stack`, `test_overlay_over_nested_page`, `test_params_reach_the_page`, `test_sign_out_leaves_no_pages`. Existing tests unmodified.
- Docs: spec 02 §1.1, `shell/CLAUDE.md` "How to add a page".

Verification: `dev.ps1 test` ALL GREEN (138 passed); `dev.ps1 shots` ALL GREEN (149 passed; first run hit `TEST WINDOW LOST ACTIVATION` in a Power test, second run clean). No screenshot changed by design, so none re-reviewed.

Deviations / notes:
- `pageHost` no longer fades itself; the slots do (so the first page's fade is the same as before). `pageHost.visible` is now `slotCount > 0`.
- The lower page's `visible` turns false only after its fade-out (criterion "not visible" is checked with `tryCompare`), `enabled` is false at once.
- A slot popped before its fade-in progressed (opacity still 0) is destroyed straight away; the first version waited for an opacity change that never came.
- A QML slot property named `top` is a FINAL `Item` property; the flag is called `shown`.
