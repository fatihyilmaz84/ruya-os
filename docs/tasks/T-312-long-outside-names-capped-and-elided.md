# T-312 — Long names from outside are capped and elided: profile card, status cluster, PIN pad title, Dim row caption

Status: in-progress · Phase: 2 · Depends: T-286 · Area: shell (ProfileCard, Shell status cluster, PinPad title, DisplayPane) · Size: S · Owner: builder

## Goal
A 32-character profile name (the shipped maximum) no longer runs into the next card, and a name that is too wide for its container ends in an ellipsis everywhere it is drawn. The Dim wallpaper row explains why Left/Right can look dead.

## Read first
- T-286 Outcome and its reviews (screenshots `72-plain-text-profile-picker.png`, `72-plain-text-home-status.png`, `70-wallpaper-page-daybreak.png`); `docs/specs/04-design-system.md` §5 (profile card, status cluster) and §3.5 (Dim row)
- `shell/qml/ProfileCard.qml` (name Text ~line 41), `shell/qml/Shell.qml` (`activeProfileName`, `nameFull`), the PIN pad title, `shell/qml/DisplayPane.qml` (Dim row)

## Scope
1. **Cap and elide** the profile name on `ProfileCard` (`width: card.width`, `elide: Text.ElideRight`, centred; at most `Theme.cardProfileWidth`), on the status-cluster name in `Shell.qml` (the pill stops growing at 220 px; `nameFull` keeps feeding the narrow-screen rule) and the PIN pad title. The full name stays in the accessible name.
2. **Spec text** in `04` §5 (the lead has decided to take the design reviewer's proposal): "Names that come from outside (profile, device, drive, Wi-Fi) are one line, capped to their container's width and elided at the end; the full name is in the accessible name."
3. **Dim row caption:** when the applied dim (`shownValue`) is above the slider's own value, show a short secondary caption on the row ("Raised for this picture", Turkish too) so Left/Right that change nothing visible are explained. Reuse the row's existing caption slot; no new component.

## Out of scope
- Elide in other lists (rows already elide); changing the 32-character limit.

## Acceptance criteria
- [ ] A test with a 32-character name proves `implicitWidth` of the card name Text stays within its width (it fails without the elide) on `ProfileCard`, the status cluster and the PIN pad title.
- [ ] A test: with a picture that raises the dim, the caption is visible; with the owner's dim above the rule, it is not.
- [ ] Screenshots of the picker with two 32-character names and of the Dim row at 1080p reviewed.
- [ ] `04` §5 has the sentence above; `.\scripts\dev.ps1 test` ALL GREEN; `shots` green.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/04-design-system.md` §5 and §3.5; `shell/i18n` translations (en and tr) for the caption.

## Hints
- Use `Theme` tokens only. The hostile test strings live in `tst_plain_text.qml` (T-286); reuse its mock hooks.

## Outcome
Verified: host

**Built.** A name from outside is one line, capped and elided at the end:
- `ProfileCard`: the name Text (`profileCardName`) is `card.width` wide, centred, `ElideRight`; the accessible name of the card already held the whole name.
- Status cluster (`Shell.qml`): new `statusGlass.nameCap` (220 px x `u`); `nameWidth` is `max(nameMin, min(nameFull, nameCap, room - ...))`. `nameFull` is unchanged and still feeds the narrow-screen rule and `nameMin`.
- `PinPad`: the title (`pinTitle`) is at most three `cardProfileWidth` x `u` wide (two looked too short). Round 2 (review): only the name is elided, not the end of the title. `frameMetrics` (a `TextMetrics`) measures the title around an empty name, `nameMetrics` elides the name to the rest of the cap, and the title is `qsTr("Enter PIN for %1").arg(elidedName)`, so Turkish keeps "... için PIN girin". A caller's prompt (collect modes) still gets `ElideRight` on the Text. `Accessible.role: StaticText`, `Accessible.name` the whole untruncated title.
- Dim row: `SliderRow` got an optional `caption` (one line, `typeCaption`, right-aligned between the label and the bar, elided, appended to the accessible value); `DisplayPane` sets it to "Raised for this picture" while `shownValue > value`. `SettingControl` exposes `labelRight` for the placement. English and Turkish ("Bu resim için artırıldı") in `shell/i18n`.
- Specs: `04` §5 has the sentence of the task (as a paragraph under the intro, plus the profile card and PIN pad rows), §3.5 (Wallpaper paragraph) the caption; `02` §Display has one clause.

**Tests** (new file `shell/tests/tst_long_names.qml`, 1920x1080, 32-character names): cards (width <= card, `truncated`, accessible name has the whole name), status cluster (width <= 220 x u, `truncated`; short name keeps its full width), PIN pad title (English: starts with the instruction, the name ends in an ellipsis, title width <= cap, accessible name complete; Turkish: still ends with " için PIN girin", name cut inside, width <= cap, accessible name complete; Back closes and focus returns to the picker), Dim caption (hidden for a dark picture, visible for Daybreak, hidden when the owner's dim is above the rule, visible again, translated to Turkish and back; the accessible name carries it).

**Revert checks** (`revert-check.ps1 -Test tst_long_names`, each CAUGHT by the named test): removing `width: card.width` + elide in `ProfileCard.qml`; dropping `nameCap` in `Shell.qml`; round 2: feeding the title the whole name instead of `nameMetrics.elidedText` in `PinPad.qml` (round 1: replacing the width cap and elide by `ElideNone`); setting `caption: ""` in `DisplayPane.qml`.

**Screenshots** (`output/shell-shots/review/`, read): `73-long-names-picker.png` (two 32-character names, "Mehmet Ali Yi..." and "Zeynep Su Ak..." centred under their circles, no overlap), `73-long-names-pin-pad.png`, `73-long-names-status.png` and `73-long-names-status-crop.png` (status cluster with a 32-character name), `73-dim-row-caption-tr.png` (Turkish caption), `73-dim-row-caption.png` (Daybreak at 1080p: "Raised for this picture" between the label and the bar, 54 %, no overlap with the label or the bar).

**UX notes:** no new state or navigation: the caption is plain text on the row (not focusable); focus stays where it was (Dim row focused: the keys still step the slider); the PIN pad Back path is unchanged and tested.

**Test change (round 2):** `tst_plain_text.qml` looked for the PIN pad title with the whole 30-character hostile name; the title now cuts a long name, so it looks for "Enter PIN for <b>x</b>" (the start of the markup, still proving the Text is plain). No assertion on plain text was removed.

**Deviations.** (1) The task says to reuse the row's "existing caption slot": `SliderRow` has none (only `ChartRow` does), so a minimal `caption` property was added to `SliderRow`, no new component. (2) The task cites `04` §3.5 for the Dim row: the Dim text lives in the Wallpaper paragraph of §3.5, which is where it was edited. (3) The task's "implicitWidth within its width" cannot hold for an elided Text (its implicitWidth is the full text); the tests assert `width <= cap` and `truncated`, which fail without the elide. (4) In the screenshot test the Settings rows stayed unlaid (all at y 0) in the real window until `Column.forceLayout()`; the shot calls it, as `SettingsPane.reflow()` documents. `tst_wallpaper`'s same sequence at 720p does not show it.
