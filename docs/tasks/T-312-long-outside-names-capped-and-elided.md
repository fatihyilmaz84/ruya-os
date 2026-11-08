# T-312 — Long names from outside are capped and elided: profile card, status cluster, PIN pad title, Dim row caption

Status: todo · Phase: 2 · Depends: T-286 · Area: shell (ProfileCard, Shell status cluster, PinPad title, DisplayPane) · Size: S · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
