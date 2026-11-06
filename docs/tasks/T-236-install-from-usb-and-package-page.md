# T-236 — Shell: Install from USB and the package page

Status: todo · Phase: 7 · Depends: T-234, T-235 · Area: shell · Size: M · Owner: builder

## Goal
A player opens "Install from USB", sees the `.play` packages on the drive, opens one to see exactly what it is (art, trust, permissions, size), installs it by controller and gets a clear result. Mock-backed until the service exists (T-238).

## Read first
- `docs/specs/05-play-packages.md` §7.2, §7.3, §8, §12; `docs/specs/02-shell.md` (pages, focus), `shell/PATTERNS.md`
- `docs/specs/04-design-system.md` with T-235's components; `AppDetailPage.qml` (the admin-PIN gate for high-risk permissions is T-111/T-156: reuse it, do not rewrite it)
- `shell/src/play` (T-234), `StoragePane.qml` (drive list pattern)

## Scope
1. Entry points: Store page ("Install from USB") and Settings -> Storage per drive ("Packages on this drive"); both open the source list (`Play.sources`).
2. Package page (Inspect result): all fields of 05 §12's detail page that exist before install; problems from `Inspect` shown in words; Install disabled with the reason when the package is invalid, `needs-developer-mode` (the row offers to explain, admin enables in Settings), revoked or unsupported.
3. Confirm sheet and admin gate: Standard profile + high-risk permission -> admin PIN (existing flow); restricted profiles (T-211 not built yet) simply cannot see the entry once that flag exists: leave a clearly named property.
4. Progress and result screens bound to the job signals; closing the page does not cancel; Cancel is explicit; the Games/Home rows pick the app up through the existing Library/Store refresh (mock raises `InstalledChanged`).
5. Developer mode switch (admin, default off) in Settings with a plain warning; shows the red Unverified badge everywhere an app from that tier appears.
6. Turkish for every string; focus rules: after the result, focus returns to the source list on the next package.

## Out of scope
- Updates (T-241), compatibility screen (T-239), the Home hero (T-242), real service.

## Acceptance criteria
- [ ] Tests (`tst_installusb.qml`): each mock fixture shows the right badge and permission words; the high-risk fixture asks for the admin PIN for a Standard profile and not for an admin; a wrong PIN shows the inline error; the unverified fixture is blocked until developer mode is on; the corrupted one shows its fixable sentence; install runs to the result and focus ends on the next package; leaving mid-install keeps the job.
- [ ] Back/Escape from every screen, no dead ends, hint bar correct on each (`tst_installusb.qml::test_hints`).
- [ ] Screenshots (English, Turkish) of source list, package page (Wine fixture and unverified fixture), confirm, progress, failure: reviewed against `04` §8 (`dev.ps1 shots`).
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- Spec 05 §12; spec 02 (pages list); `shell/PATTERNS.md` only if a new pattern appears.

## Outcome
_Filled in by the implementer._
